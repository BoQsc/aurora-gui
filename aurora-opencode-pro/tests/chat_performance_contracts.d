module chat_performance_contracts;

import aurora;
import auroraopencode.core : ChatSession, deepestDescendant;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.outputguard : agentOutputIssue;
import auroraopencode.transcriptpresenter : TranscriptPresenter, DeferredTranscriptRow;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime;
import core.time : msecs, seconds;
import std.algorithm : sort;
import std.array : replicate;
import std.conv : to;
import std.stdio : writeln;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.string : indexOf;
import std.utf : validate;

private long median(void delegate() operation, int repeats = 5)
{
    long[] samples;
    foreach (_; 0 .. repeats)
    {
        const start = MonoTime.currTime;
        operation();
        samples ~= (MonoTime.currTime - start).total!"usecs";
    }
    samples.sort();
    return samples[samples.length / 2];
}

private class CountedRow : Widget
{
    protected override Size onMeasure(Size available) { return Size(available.width, 60); }
}
private class RowFactory
{
    size_t created;
    Widget create() { ++created; return new CountedRow(); }
}

int main()
{
    ChatSession session;
    session.messages.length = 12_000;
    foreach (i, ref message; session.messages)
    {
        message.id = "m" ~ to!string(i);
        if (i) message.parentId = session.messages[i - 1].id;
    }
    writeln("branch_12000_median_us=", median({
        assert(deepestDescendant(session, 0) == session.messages.length - 1);
    }, 3));
    // Last-appended branches win, even when a later branch is shorter.
    session.messages.length += 2;
    session.messages[$ - 2].id = "branch";
    session.messages[$ - 2].parentId = "m4";
    session.messages[$ - 1].id = "branch-child";
    session.messages[$ - 1].parentId = "branch";
    assert(deepestDescendant(session, 0) == session.messages.length - 1);
    assert(deepestDescendant(session, 5) == 11_999);
    session.messages[$ - 1].parentId = session.messages[$ - 1].id;
    assert(deepestDescendant(session, session.messages.length - 1) == session.messages.length - 1);
    assert(deepestDescendant(session, session.messages.length) == session.messages.length);

    auto client = new OpenCodeClient("http://127.0.0.1:9", "");
    scope(exit) client.closeSession();
    OpenCodeEvent[] events;
    OpenCodeEvent usage;
    usage.kind = OpenCodeEventKind.usage;
    writeln("queue_4000_ticks_median_us=", median({
        foreach (i; 0 .. 4000)
        {
            usage.requestId = i + 1;
            client.pushLocalEvent(usage);
            client.drain(events, 64, 256 * 1024);
            assert(events.length == 1 && events[0].requestId == i + 1);
        }
        assert(client.queuedBytes() == 0);
    }));
    OpenCodeEvent preview;
    preview.kind = OpenCodeEventKind.toolResult;
    preview.toolRunning = true;
    preview.toolCallId = "call-a";
    preview.toolName = "run";
    preview.requestId = 99;
    preview.text = "earlier output";
    client.pushLocalEvent(preview);
    preview.text = "latest output";
    client.pushLocalEvent(preview);
    preview.toolRunning = false;
    preview.text = "terminal output";
    client.pushLocalEvent(preview);
    client.drain(events, 64, 256 * 1024);
    assert(events.length == 2 && events[0].text == "latest output" &&
        events[0].toolRunning && !events[1].toolRunning && events[1].text == "terminal output");
    preview.toolRunning = true;
    preview.toolCallId = "call-b";
    client.pushLocalEvent(preview);
    preview.toolCallId = "call-c";
    client.pushLocalEvent(preview);
    preview.requestId = 100;
    client.pushLocalEvent(preview);
    client.drain(events, 64, 256 * 1024);
    assert(events.length == 3, "Snapshot coalescing crossed call/request identities");
    preview.toolCallId = "";
    client.pushLocalEvent(preview);
    client.pushLocalEvent(preview);
    client.drain(events, 64, 256 * 1024);
    assert(events.length == 2, "Uncorrelated tool snapshots were merged");
    // A provider burst crosses the fragment cap and bounded drain several
    // times. UTF-8 bytes, channels and the terminal barrier must all survive.
    OpenCodeEvent delta;
    delta.kind = OpenCodeEventKind.delta;
    delta.text = "Привіт 🌍 ".replicate(800);
    string expected;
    foreach (_; 0 .. 24) { client.pushLocalEvent(delta); expected ~= delta.text; }
    delta.reasoning = true;
    delta.text = "reasoning";
    client.pushLocalEvent(delta);
    OpenCodeEvent done;
    done.kind = OpenCodeEventKind.done;
    client.pushLocalEvent(done);
    string assembled;
    bool reasoning, ended;
    while (client.hasPendingEvents())
    {
        client.drain(events, 4, 4097);
        foreach (event; events)
        {
            assert(!ended);
            if (event.kind == OpenCodeEventKind.done) { ended = true; continue; }
            validate(event.text);
            if (event.reasoning) { assert(!reasoning); reasoning = true; }
            else { assert(!reasoning); assembled ~= event.text; }
        }
    }
    assert(assembled == expected && reasoning && ended && client.queuedBytes() == 0);
    writeln("PASS bounded burst draining, tool progress snapshots and terminal ordering");

    string[] names;
    foreach (i; 0 .. 32) names ~= "tool" ~ to!string(i);
    const prose = replicate("A distinct paragraph describing useful progress and implementation.\n", 3000);
    writeln("output_guard_200kb_32_tools_median_us=", median({
        assert(agentOutputIssue(prose, names).length == 0);
    }));
    assert(agentOutputIssue("<invoke name=\"tool3\">\n".replicate(3), names) == "text_tool_calls");
    assert(agentOutputIssue("```\n<invoke name=\"tool3\">\n".replicate(1) ~ "```", names).length == 0);
    assert(agentOutputIssue("> <invoke name=\"tool3\">\n".replicate(4), names).length == 0);
    const invocation = "  <invoke name=\"tool3\">\n<parameter name=\"x\">yes</parameter>\n</invoke>";
    assert(agentOutputIssue(invocation, names).length == 0);
    assert(agentOutputIssue(invocation, names, true) == "text_tool_calls");
    assert(agentOutputIssue(invocation, names, true, true).length == 0);
    assert(agentOutputIssue("<invoke name=\"unknown\">\n".replicate(4), names).length == 0);
    assert(agentOutputIssue(("A repeated paragraph with enough meaningful text to exceed the detector's minimum normalized paragraph length.\n\n").replicate(4), names) == "repeated_prose");

    WindowOptions options;
    options.width = 800;
    options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options);
    auto presenter = new TranscriptPresenter(6);
    auto view = new ScrollView(presenter);
    window.setRoot(view);
    auto factory = new RowFactory();
    foreach (_; 0 .. 250) presenter.add(new DeferredTranscriptRow(&factory.create));
    auto driver = new UiTestDriver(window);
    const start = MonoTime.currTime;
    foreach (_; 0 .. 3) assert(driver.paint());
    writeln("transcript_250_first_paints_us=", (MonoTime.currTime - start).total!"usecs",
        " materialized=", factory.created);
    assert(factory.created < 80, "Medium histories constructed offscreen rows");
    view.setScrollY(view.maxScroll());
    foreach (_; 0 .. 3) assert(driver.paint());
    assert((cast(DeferredTranscriptRow) presenter.children()[$ - 1]).materialized() !is null);
    window.close();

    // Exercise the desktop root as well as the presenter: project rich history,
    // paint a streamed reply, and verify that append-only text reaches the UI.
    const state = buildPath("chat-perf-state-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","model":"fixture","toolsEnabled":false}`);
    auto chatWindow = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(chatWindow);
    chatWindow.setRoot(root);
    scope(exit) root.shutdownClient();
    auto chatDriver = new UiTestDriver(chatWindow);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { root.tickTree(0.02); Thread.sleep(5.msecs); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    string[] roles, bodies;
    foreach (i; 0 .. 250)
    {
        roles ~= i % 2 ? "assistant" : "user";
        bodies ~= "Message " ~ to!string(i) ~ "\n\n" ~
            "Text with **formatting**, a [link](https://example.com), and `inline code`.\n\n".replicate(8);
    }
    const projection = MonoTime.currTime;
    root.addConversationForTesting(roles, bodies);
    root.projectTranscriptForTesting();
    foreach (_; 0 .. 3) assert(chatDriver.paint());
    writeln("real_chat_250_project_paint_us=", (MonoTime.currTime - projection).total!"usecs",
        " materialized=", root.materializedTranscriptRowsForTesting());
    assert(root.materializedTranscriptRowsForTesting() < 80);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    const stream = MonoTime.currTime;
    string answer;
    foreach (_; 0 .. 60)
    {
        const chunk = "More **streamed** text with UTF-8: žą 🌍.\n\n";
        answer ~= chunk;
        root.streamContentForTesting(chunk);
        root.projectTranscriptForTesting();
        assert(chatDriver.paint());
    }
    assert(root.lastAssistantContentForTesting() == answer);
    writeln("real_chat_60_stream_project_paint_us=", (MonoTime.currTime - stream).total!"usecs");
    chatWindow.close();
    return 0;
}

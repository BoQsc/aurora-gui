module grep_dispatch_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.execution;
import auroraopencode.repository;
import auroraopencode.opencode_client;
import auroraopencode.searchprogress;
import auroraopencode.logging : setLogDirectory, flushLogs;
import auroraopencode.lifecyclediagnostics : logAgentLifecycle;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.file : mkdirRecurse, write, readText;
import std.path : absolutePath, buildPath;
import std.json : JSONValue, parseJSON;
import std.conv : to;
import std.string : indexOf, splitLines;
import std.stdio : writeln;

int main()
{
    const workspace = absolutePath("grep-dispatch-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    const diagnosticsDirectory = buildPath(workspace, "diagnostics");
    mkdirRecurse(diagnosticsDirectory);
    setLogDirectory(diagnosticsDirectory);
    JSONValue privateDetails;
    privateDetails["arguments"] = "PRIVATE_ARGUMENTS";
    privateDetails["content"] = "PRIVATE_CONTENT";
    logAgentLifecycle("diag-thread", 10, "privacy_probe", privateDetails);
    mkdirRecurse(buildPath(workspace, ".git"));
    setOpencodeStateDirectoryForTesting(buildPath(workspace, "state"));
    scope (exit) setOpencodeStateDirectoryForTesting("");
    developerSourceDirectoryHandler = () => workspace;
    scope (exit) developerSourceDirectoryHandler = null;
    foreach (name; ["one.d", "two.d", "three.d"])
        write(buildPath(workspace, name), "match needle\nsecond needle\n");
    auto repository = new ConversationRepository();
    scope (exit) repository.close();
    auto journal = new RepositoryRuntime(repository, buildPath(workspace, "journal.jsonl"));
    auto engine = new ThreadEngine("http://127.0.0.1:9", "");
    engine.threadId = "diag-thread";
    scope (exit) engine.close();
    OpenCodeToolCall[] calls;
    foreach (i, name; [".", "one.d", "two.d", "three.d"])
    {
        JSONValue args;
        args["path"] = buildPath(workspace, name);
        args["pattern"] = "needle|other";
        args["timeout"] = 2000;
        calls ~= OpenCodeToolCall("grep-" ~ to!string(i), "grep", args.toString());
    }
    engine.acceptRequest(10);
    ChangeContext diagnosticContext;
    diagnosticContext.conversationId = "diag-thread";
    diagnosticContext.turnId = "diag-turn";
    assert(engine.dispatchAfterCommit(journal, 10, delegate() {
        scheduleToolBatch(engine.client, 10, calls, workspace, new ToolCancellation(), diagnosticContext);
    }));
    const deadline = MonoTime.currTime + 8.seconds;
    size_t results, progress;
    bool[string] complete;
    while (results < 4 && MonoTime.currTime < deadline)
    {
        OpenCodeEvent[] events; engine.client.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.toolResult)
            {
                if (event.toolRunning) ++progress;
                else
                {
                    writeln("Result ", event.toolCallId, ": ", event.toolFailed, " ", event.text);
                    assert(!event.toolFailed && event.text.indexOf("needle") >= 0);
                    assert(event.toolCallId !in complete); complete[event.toolCallId] = true;
                    ++results;
                }
            }
        Thread.sleep(5.msecs);
    }
    assert(results == 4, "Four grep requests never reached terminal results");
    assert(progress > 0);
    assert(flushLogs());
    const diagnostics = readText(buildPath(diagnosticsDirectory, "errors.log"));
    assert(diagnostics.indexOf("PRIVATE_ARGUMENTS") < 0 && diagnostics.indexOf("PRIVATE_CONTENT") < 0);
    bool[string] queued, started, finished;
    foreach (line; splitLines(diagnostics))
    {
        const offset = line.indexOf("agent-lifecycle ");
        if (offset < 0) continue;
        const row = parseJSON(line[cast(size_t) offset + "agent-lifecycle ".length .. $]);
        if (auto id = "toolCallId" in row.object)
        {
            assert(row["thread"].str == "diag-thread" && row["request"].integer == 10);
            const stage = row["stage"].str;
            if (stage == "tool.queued") queued[id.str] = true;
            if (stage == "tool.started") { assert(id.str in queued); started[id.str] = true; }
            if (stage == "tool.finished") { assert(id.str in started); finished[id.str] = true; }
        }
    }
    assert(finished.length == 4, "Every search needs correlated queue/start/end diagnostics");
    writeln("PASS tool lifecycle records correlate four searches without persisting tool arguments or result text");
    repository.flush();
    writeln("PASS durable dispatch starts all four source-tree greps and returns each result with live activity");
    developerSourceDirectoryHandler = null;
    Settings settings; settings.workspace = workspace; settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false; saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 5.seconds;
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting());
    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Ground recommendations in these four searches.", ""]);
    root.injectToolCallsForTesting(calls);
    const completed = MonoTime.currTime + 8.seconds;
    while (root.pendingToolResultsForTesting() && MonoTime.currTime < completed) pump();
    assert(root.pendingToolResultsForTesting() == 0 && root.toolMessageCountForTesting() == 4,
        "Actual chat dispatch left four grep rows running indefinitely");
    writeln("PASS actual chat dispatcher completes four searches and replaces every live row with its result");
    return 0;
}

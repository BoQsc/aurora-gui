module lazy_tool_group_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import core.memory : GC;
import std.json : JSONValue;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.array : replicate;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = absolutePath("lazy-tool-state");
    mkdirRecurse(buildPath(state, "threads"));
    setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9";
    settings.toolsEnabled = false; settings.quickTitle = false;
    settings.experimentalChatRedesign = false; settings.experimentalFollowUpDivider = false;
    saveSettings(settings);
    JSONValue history, index, metadata;
    JSONValue[] messages, calls;
    string previous;
    void add(string role, string content)
    {
        JSONValue message;
        message["id"] = "m" ~ to!string(messages.length);
        message["parentId"] = previous; previous = message["id"].str;
        message["role"] = role; message["content"] = content;
        messages ~= message;
    }
    add("user", "Inspect the saved tool history");
    add("assistant", "Inspecting the files");
    foreach (i; 0 .. 180)
    {
        JSONValue call;
        call["id"] = "call-" ~ to!string(i); call["name"] = "read";
        call["arguments"] = `{"filePath":"fixture.txt"}`;
        calls ~= call;
        add("tool", "unique-proof-" ~ to!string(i) ~ "\n" ~ "Saved detail line.\n".replicate(1800));
        messages[$ - 1]["toolCallId"] = call["id"];
        messages[$ - 1]["toolName"] = "read";
        messages[$ - 1]["toolArgs"] = call["arguments"];
        messages[$ - 1]["failed"] = i == 7;
        messages[$ - 1]["toolElapsedMs"] = cast(long) i;
    }
    messages[1]["toolCalls"] = JSONValue(calls);
    add("assistant", "The saved results are available above.");
    history["messages"] = JSONValue(messages);
    metadata["id"] = "large-tools"; metadata["title"] = "Large tools";
    metadata["activeLeafId"] = previous;
    index["version"] = 2; index["current"] = 0; index["currentId"] = "large-tools";
    index["sessions"] = JSONValue([metadata]);
    write(buildPath(state, "threads", "large-tools.json"), history.toString());
    write(buildPath(state, "threads.index.json"), index.toString());
    WindowOptions options; options.width = 1050; options.height = 750;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 8.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    while (root.hiddenHistoryCountForTesting()) root.loadOlderHistoryForTesting();
    root.projectTranscriptForTesting(); root.scrollToForTesting(0);
    assert(driver.paint());
    assert(root.toolDetailsForTesting(false) == 180);
    assert(root.toolDetailsForTesting() == 0, "Collapsed tools eagerly constructed their large details");
    assert(root.toolGroupHeaderTextsForTesting()[0].indexOf("1 failed") >= 0,
        "Deferred details concealed failure metadata");
    const before = GC.allocatedInCurrentThread();
    const started = MonoTime.currTime;
    root.rebuildForTesting(); root.projectTranscriptForTesting(); assert(driver.paint());
    writeln("collapsed_rebuild_paint_us=", (MonoTime.currTime - started).total!"usecs",
        " allocated_bytes=", GC.allocatedInCurrentThread() - before);
    assert(root.toolDetailsForTesting() == 0);
    root.toggleFirstToolGroupForTesting();
    foreach (_; 0 .. 4) { root.scrollToForTesting(0); assert(driver.paint()); }
    assert(root.toolDetailsForTesting() > 0 && root.toolDetailsForTesting() < 100,
        "Expanded group materialized every offscreen detail");
    root.scrollToForTesting(int.max);
    foreach (_; 0 .. 4) assert(driver.paint());
    assert(root.toolDetailsForTesting() < 100, "Scrolling retained unbounded detail widgets");
    root.toggleFirstToolGroupForTesting(); assert(driver.paint());
    assert(root.toolDetailsForTesting() == 0, "Collapse retained hidden large detail payloads");
    root.setChatSearchQueryForTesting("unique-proof-145");
    foreach (_; 0 .. 8) { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); }
    assert(root.chatSearchMatchCountForTesting() == 1);
    assert(root.messageInViewportForTesting(147), "Search did not reveal the deferred result");
    assert(root.toolDetailsForTesting() < 100);
    writeln("PASS 180 large results: collapsed metadata, bounded expanded viewport, eviction and exact search reveal");
    return 0;
}

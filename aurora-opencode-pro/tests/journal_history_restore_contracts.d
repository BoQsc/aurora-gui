module journal_history_restore_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.runtime : readAgentRuntimeEvents, projectAgentRuntimeEvents;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.conv : to;
import std.json : JSONValue;
import std.file : mkdirRecurse, write, readText;
import std.path : buildPath, absolutePath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    auto state = environment.get("AURORA_HISTORY_RESTORE_FIXTURE", "");
    const scenario = environment.get("AURORA_HISTORY_RESTORE_CASE", "unfolded");
    if (!state.length)
    {
        state = absolutePath("journal-history-" ~ to!string(MonoTime.currTime.ticks));
        mkdirRecurse(buildPath(state, "threads"));
        write(buildPath(state, "settings.json"), `{"baseUrl":"http://127.0.0.1:9","quickTitle":false,"toolsEnabled":false}`);
        write(buildPath(state, "threads.index.json"),
            `{"version":2,"current":0,"currentId":"saved-chat","sessions":[{"id":"saved-chat","title":"Saved chat","activeLeaf":"failed-read","turnStatus":"interrupted"}]}`);
        write(buildPath(state, "threads", "saved-chat.json"),
            `{"messages":[{"id":"prompt","role":"user","content":"Keep the entire chat"},` ~
            `{"id":"request","parentId":"prompt","role":"assistant","content":"Read the current source","toolCalls":[{"id":"read-call","name":"read","arguments":"{\"filePath\":\"source.d\"}"}]},` ~
            `{"id":"branch","parentId":"prompt","role":"assistant","content":"Previous response branch"},` ~
            `{"id":"failed-read","parentId":"request","role":"tool","toolName":"read","toolCallId":"read-call","failed":true,"content":"Read failed"}]}`);
        write(buildPath(state, "runtime-events.jsonl"),
            `{"schema":1,"sequence":1,"type":"item.added","threadId":"saved-chat","itemId":"failed-read","payload":{"role":"tool","parentId":"request","toolName":"read","toolCallId":"read-call","failed":true,"content":"Read failed"}}` ~ "\n");
        write(buildPath(state, "journal.folded"), "0 0\n");
        auto projected = projectAgentRuntimeEvents(readAgentRuntimeEvents(buildPath(state, "runtime-events.jsonl")), true);
        assert(projected.length == 1 && projected[0].messages[0].parentId == "request",
            "An incremental projection must preserve a parent held in the snapshot");
        if (scenario == "unfolded")
        {
            import std.stdio : File;
            import std.array : replicate;
            // Keep the event outside the bounded repair lookup. Correct tail
            // replay must preserve its parent without relying on that repair.
            auto journal = File(buildPath(state, "runtime-events.jsonl"), "a");
            foreach (sequence; 2 .. 1102)
            {
                JSONValue filler;
                filler["schema"] = 1; filler["sequence"] = sequence;
                filler["type"] = "thread.updated"; filler["threadId"] = "unrelated";
                JSONValue payload; payload["ignored"] = "x".replicate(8192);
                filler["payload"] = payload;
                journal.writeln(filler.toString());
            }
            journal.close();
        }
        if (scenario == "folded")
        {
            import std.string : replace;
            const threadPath = buildPath(state, "threads", "saved-chat.json");
            write(threadPath, readText(threadPath).replace(`"id":"failed-read","parentId":"request"`, `"id":"failed-read","parentId":""`));
            const bytes = readText(buildPath(state, "runtime-events.jsonl")).length;
            write(buildPath(state, "journal.folded"), "1 " ~ to!string(bytes) ~ "\n");
        }
        else if (scenario == "result-in-journal")
        {
            import std.json : parseJSON;
            const threadPath = buildPath(state, "threads", "saved-chat.json");
            auto saved = parseJSON(readText(threadPath));
            saved["messages"].array.length--;
            write(threadPath, saved.toString());
        }
    }
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 1200; options.height = 800; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.02); root.projectTranscriptForTesting(); assert(driver.paint()); Thread.sleep(5.msecs); }
    const deadline = MonoTime.currTime + 10.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline) pump();
    assert(!root.startupPendingForTesting()); pump();
    const expectedText = environment.get("AURORA_HISTORY_EXPECTED_ACTIVE", "3");
    const expected = to!int(expectedText);
    writeln("RESTORE active=",root.messageCountForTesting()," total=",root.totalMessageCountForTesting()," visuals=",root.messageColumnVisualCountForTesting());
    assert(root.messageCountForTesting() == expected,
        "Journal replay disconnected the result from its saved history: active=" ~ to!string(root.messageCountForTesting()));
    assert(root.messageColumnVisualCountForTesting() > 1, "Only the Read failure is rendered");
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.messageCountForTesting() == expected, "History disappeared after save/reload");
    if (expected == 3)
    {
        assert(root.totalMessageCountForTesting() == 4, "An inactive response branch was lost");
        assert(root.messageContentForTesting(0) == "Keep the entire chat");
        assert(root.toolMessageCountForTesting() == 1, "Recovery duplicated the Read result");
    }
    else
    {
        const older = root.hiddenHistoryCountForTesting();
        assert(older > 0);
        root.loadOlderHistoryForTesting(); pump();
        assert(root.hiddenHistoryCountForTesting() < older && root.messageCountForTesting() == expected);
        window.saveScreenshot("build/restored-archived-chat.ppm");
    }
    writeln("PASS incremental journal restore keeps the full branch, Read result and inactive history after save/reload");
    return 0;
}

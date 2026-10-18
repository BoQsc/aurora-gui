module journal_history_restore_folded;

// Folded-journal variant of tests/journal_history_restore_contracts.d: the
// snapshot has already folded the journal, so the parent link of the Read
// result can only come from the bounded journal tail that the restore path
// reads. That is the scenario the incremental-restore repair depends on, so it
// is kept as its own contract instead of being selected by an environment
// variable, which a verification recipe cannot set.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.runtime : readAgentRuntimeEvents, projectAgentRuntimeEvents;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.conv : to;
import std.file : mkdirRecurse, write, readText;
import std.path : buildPath, absolutePath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    auto state = environment.get("AURORA_HISTORY_RESTORE_FIXTURE", "");
    if (!state.length)
    {
        state = absolutePath("journal-history-folded-" ~ to!string(MonoTime.currTime.ticks));
        mkdirRecurse(buildPath(state, "threads"));
        write(buildPath(state, "settings.json"), `{"baseUrl":"http://127.0.0.1:9","quickTitle":false,"toolsEnabled":false}`);
        write(buildPath(state, "threads.index.json"),
            `{"version":2,"current":0,"currentId":"saved-chat","sessions":[{"id":"saved-chat","title":"Saved chat","activeLeaf":"failed-read","turnStatus":"interrupted"}]}`);
        const threadPath = buildPath(state, "threads", "saved-chat.json");
        // The snapshot records the Read result, but its parent link is missing:
        // only the folded-away journal tail still proves it belongs to `request`.
        write(threadPath,
            `{"messages":[{"id":"prompt","role":"user","content":"Keep the entire chat"},` ~
            `{"id":"request","parentId":"prompt","role":"assistant","content":"Read the current source","toolCalls":[{"id":"read-call","name":"read","arguments":"{\"filePath\":\"source.d\"}"}]},` ~
            `{"id":"branch","parentId":"prompt","role":"assistant","content":"Previous response branch"},` ~
            `{"id":"failed-read","parentId":"","role":"tool","toolName":"read","toolCallId":"read-call","failed":true,"content":"Read failed"}]}`);
        const journal = buildPath(state, "runtime-events.jsonl");
        write(journal,
            `{"schema":1,"sequence":1,"type":"item.added","threadId":"saved-chat","itemId":"failed-read","payload":{"role":"tool","parentId":"request","toolName":"read","toolCallId":"read-call","failed":true,"content":"Read failed"}}` ~ "\n");
        write(buildPath(state, "journal.folded"), "1 " ~ to!string(readText(journal).length) ~ "\n");
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
    const expected = to!int(environment.get("AURORA_HISTORY_EXPECTED_ACTIVE", "3"));
    writeln("RESTORE folded active=",root.messageCountForTesting()," total=",root.totalMessageCountForTesting(),
        " visuals=",root.messageColumnVisualCountForTesting());
    assert(root.messageCountForTesting() == expected,
        "The folded snapshot lost the parent link of the Read result: active=" ~ to!string(root.messageCountForTesting()));
    assert(root.toolMessageCountForTesting() == 1, "The recovered Read result is not on the active path");
    assert(root.messageContentForTesting(0) == "Keep the entire chat");
    root.persistForTesting(); root.reloadSessionsForTesting(); pump();
    assert(root.messageCountForTesting() == expected, "History disappeared after save/reload");
    assert(root.totalMessageCountForTesting() == 4, "An inactive response branch was lost");
    writeln("PASS folded-journal restore recovers the parent link from the bounded journal tail");
    return 0;
}

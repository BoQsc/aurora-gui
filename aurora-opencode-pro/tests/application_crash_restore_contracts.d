module application_crash_restore_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.runtime : readAgentRuntimeEvents, projectAgentRuntimeEvents;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.file : mkdirRecurse, write, readText, exists;
import std.path : absolutePath, buildPath;
import std.process : spawnProcess, kill, wait, tryWait;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;

private OpenCodeRoot open(string state, out GuiWindow window)
{
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 900; options.height = 600;
    options.renderer = RendererPreference.software;
    window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    const ready = MonoTime.currTime + 10.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    return root;
}

private void child(string state)
{
    GuiWindow window;
    auto root = open(state, window);
    // Hold all compatibility snapshots until this process is killed. Only
    // acknowledged journal events may account for the recovered work.
    auto gate = new Semaphore(), entered = new Semaphore();
    assert(root.queueSnapshotWorkForTesting({ entered.notify(); gate.wait(); }));
    entered.wait();
    root.duplicateSessionForTesting(0);
    const copyId = root.sessionIdForTesting(root.currentSessionForTesting());
    root.duplicateSessionCompactedForTesting(0);
    const compactId = root.sessionIdForTesting(root.currentSessionForTesting());
    const workspace = buildPath(state, "workspace");
    root.startConversationInProject("Crash fixture", workspace);
    root.addConversationForTesting(["user"], ["Read input, write output, and read it back."]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.pauseToolContinuationForTesting();
    JSONValue readArgs, writeArgs, afterArgs;
    readArgs["filePath"] = buildPath(workspace, "input.txt");
    writeArgs["filePath"] = buildPath(workspace, "output.txt");
    writeArgs["content"] = "verified after crash";
    afterArgs["filePath"] = buildPath(workspace, "output.txt");
    root.injectToolCallsForTesting([
        OpenCodeToolCall("before", "read", readArgs.toString()),
        OpenCodeToolCall("mutation", "write", writeArgs.toString()),
        OpenCodeToolCall("after", "read", afterArgs.toString())]);
    const complete = MonoTime.currTime + 15.seconds;
    while (root.pendingToolResultsForTesting() && MonoTime.currTime < complete)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(root.pendingToolResultsForTesting() == 0 && root.toolMessageCountForTesting() == 3);
    assert(readText(buildPath(workspace, "output.txt")) == "verified after crash");
    root.flushJournalForTesting();
    JSONValue ready;
    ready["copy"] = copyId; ready["compact"] = compactId;
    ready["tools"] = root.sessionIdForTesting(root.currentSessionForTesting());
    write(buildPath(state, "ready.json"), ready.toString());
    Thread.sleep(60.seconds);
}

int main(string[] args)
{
    if (args.length == 3 && args[1] == "--child") { child(args[2]); return 0; }
    ChatSession live;
    live.goalHistory = [GoalHistoryEntry("Goal", "active")];
    auto detached = snapshotChatSessions([live]);
    live.goalHistory[0].outcome = "completed";
    assert(detached[0].goalHistory[0].outcome == "active", "Writer snapshot shared mutable goal history");
    const state = absolutePath("application-crash-state");
    mkdirRecurse(buildPath(state, "threads"));
    mkdirRecurse(buildPath(state, "workspace"));
    write(buildPath(state, "workspace", "input.txt"), "read before mutation");
    setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false; settings.toolsEnabled = true; settings.apiKey = "";
    settings.model = "fixture";
    settings.contextBudgets = [ModelContextBudget("http://127.0.0.1:9", "fixture", 60_000)];
    settings.workspace = buildPath(state, "workspace"); saveSettings(settings);
    const index = buildPath(state, "threads.index.json");
    const original = `{"version":2,"currentId":"source","sessions":[{"id":"source","title":"Source","model":"fixture","activeLeaf":"second","goal":"Preserve every branch","goalStatus":"paused"}]}`;
    write(index, original);
    write(buildPath(state, "threads", "source.json"),
        `{"messages":[{"id":"prompt","role":"user","content":"Original request"},{"id":"first","parentId":"prompt","role":"assistant","content":"Earlier version"},{"id":"second","parentId":"prompt","role":"assistant","content":"Current version"}]}`);
    auto process = spawnProcess([args[0], "--child", state]);
    const deadline = MonoTime.currTime + 25.seconds;
    while (!exists(buildPath(state, "ready.json")) && MonoTime.currTime < deadline)
        Thread.sleep(10.msecs);
    const ready = exists(buildPath(state, "ready.json"));
    if (!tryWait(process).terminated) { kill(process); wait(process); }
    assert(ready, "Application child did not durably settle its mixed tool batch");
    assert(readText(index) == original, "The test accidentally saved a compatibility snapshot");
    const identities = parseJSON(readText(buildPath(state, "ready.json")));
    const events = readAgentRuntimeEvents(buildPath(state, "runtime-events.jsonl"), true);
    const replay = projectAgentRuntimeEvents(events);
    foreach (key; ["copy", "compact"])
    {
        bool found;
        foreach (session; replay)
            if (session.id == identities[key].str)
            {
                found = true;
                assert(session.messages.length == 3 && activeMessagePath(session).length == 2);
                assert(session.messages[1].content == "Earlier version" && session.messages[2].content == "Current version");
                assert(session.goal == "Preserve every branch" && session.goalStatus == "paused");
                if (key == "compact") assert(session.compactionSummary.length);
            }
        assert(found, "A copied conversation disappeared from the journal");
    }
    GuiWindow window;
    auto root = open(state, window);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    foreach (key; ["copy", "compact"])
    {
        root.selectSessionForTesting(root.sessionIndexForTesting(identities[key].str));
        assert(root.totalMessageCountForTesting() == 3 && root.messageCountForTesting() == 2);
        assert(root.lastAssistantContentForTesting() == "Current version");
    }
    root.selectSessionForTesting(root.sessionIndexForTesting(identities["tools"].str));
    assert(root.toolMessageCountForTesting() == 3);
    assert(driver.paint());
    root.persistForTesting(); root.reloadSessionsForTesting();
    assert(root.toolMessageCountForTesting() == 3, "Reload duplicated or dropped settled tool results");
    writeln("PASS forced application death restores copied branches, compacted copy, goal and ordered read/write/read results without a snapshot");
    window.close();
    return 0;
}

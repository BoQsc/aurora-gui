module history_mailbox_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.historymailbox;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    HistoryMailbox mailbox;
    foreach (i; 0 .. mailbox.maxPending)
        assert(mailbox.enqueue(HistoryAction("chat", HistoryActionKind.duplicate)));
    assert(!mailbox.enqueue(HistoryAction("overflow", HistoryActionKind.duplicate)));
    mailbox.cancel("chat"); assert(!mailbox.length);
    const state = absolutePath("history-mailbox-state");
    mkdirRecurse(buildPath(state, "threads"));
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","quickTitle":false,"toolsEnabled":false}`);
    write(buildPath(state, "threads.index.json"),
        `{"version":2,"currentId":"selected","sessions":[{"id":"selected","title":"Selected"},{"id":"remove","title":"Remove"},{"id":"source","title":"Source"},{"id":"corrupt","title":"Corrupt"},{"id":"cancel","title":"Cancel"}]}`);
    foreach (id; ["selected", "remove", "source", "cancel"])
        write(buildPath(state, "threads", id ~ ".json"),
            `{"messages":[{"id":"prompt","role":"user","content":"Original prompt"},{"id":"answer","parentId":"prompt","role":"assistant","content":"` ~ id ~ ` answer"}]}`);
    write(buildPath(state, "threads", "corrupt.json"), "broken");
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 900; options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump() { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting() && root.sessionCountForTesting() == 5);

    auto entered = new Semaphore(), release = new Semaphore();
    assert(root.queueSnapshotWorkForTesting({ entered.notify(); release.wait(); }));
    entered.wait();
    auto rescue = new Thread({ Thread.sleep(2000.msecs); release.notify(); });
    rescue.start(); scope(exit) rescue.join();
    const started = MonoTime.currTime;
    root.duplicateSessionForTesting(2);
    root.deleteSessionForTesting(1);
    assert(driver.paint());
    assert((MonoTime.currTime - started).total!"msecs" < 500,
        "Duplicate blocked the window waiting for history");
    assert(root.pendingHistoryActionsForTesting() == 1 && root.sessionCountForTesting() == 4);
    release.notify();
    const copied = MonoTime.currTime + 5.seconds;
    while (root.pendingHistoryActionsForTesting() && MonoTime.currTime < copied) pump();
    assert(!root.pendingHistoryActionsForTesting() && root.sessionCountForTesting() == 5);
    assert(root.sessionTitleForTesting(root.currentSessionForTesting()) == "Source (copy)");
    assert(root.lastAssistantContentForTesting() == "source answer",
        "Sidebar deletion redirected a deferred action to the wrong thread");

    auto corrupt = root.sessionIndexForTesting("corrupt");
    root.duplicateSessionForTesting(corrupt);
    foreach (_; 0 .. 40) pump();
    assert(root.sessionCountForTesting() == 5 && root.pendingHistoryActionsForTesting() == 1,
        "Failed history produced an empty duplicate or dropped the action");
    write(buildPath(state, "threads", "corrupt.json"),
        `{"messages":[{"id":"repaired","role":"assistant","content":"Recovered answer"}]}`);
    root.selectSessionForTesting(corrupt);
    const repaired = MonoTime.currTime + 5.seconds;
    while (root.pendingHistoryActionsForTesting() && MonoTime.currTime < repaired) pump();
    assert(!root.pendingHistoryActionsForTesting() && root.sessionCountForTesting() == 6);
    assert(root.lastAssistantContentForTesting() == "Recovered answer");

    auto cancel = root.sessionIndexForTesting("cancel");
    root.duplicateSessionForTesting(cancel);
    root.deleteSessionForTesting(cancel);
    foreach (_; 0 .. 20) pump();
    assert(!root.pendingHistoryActionsForTesting() && root.sessionCountForTesting() == 5,
        "A late history load resurrected a deleted conversation");
    assert(driver.paint());
    writeln("PASS asynchronous history actions preserve identity, retry intent and deletion cancellation");
    window.close();
    return 0;
}

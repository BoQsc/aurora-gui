module execution_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.runtime : readAgentRuntimeEvents, AgentEventKind;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write, rename, rmdir;
import std.json : parseJSON;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = buildPath("ui-contract-state-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        "{\"baseUrl\":\"http://127.0.0.1:9\",\"model\":\"fixture\",\"toolsEnabled\":false}");
    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        root.tickTree(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting());

    root.newChatForTesting();
    const idle = root.currentSessionForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["live work"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.streamContentForTesting("before deletion");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    root.deleteSessionForTesting(idle);
    root.streamContentForTesting(" after deletion");
    assert(root.lastAssistantContentForTesting() == "before deletion after deletion");
    assert(root.hasLiveBubbleForTesting(),
        "Deleting an unrelated chat dropped the active stream bubble");

    const owner = root.currentSessionForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["another live work"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    const other = root.currentSessionForTesting();
    root.delayPartialCheckpointForTesting();
    root.projectTranscriptForTesting();
    assert(driver.paint());
    Event resize;
    resize.type = EventType.resizeStarted;
    window.onNativeEvent(resize);
    root.queueContentInSessionForTesting(owner, " resize owner");
    root.queueContentInSessionForTesting(other, " resize other");
    // Only the native timer runs here; widget tick/layout is suspended.
    foreach (_; 0 .. 4) window.onNativeTick(0.02);
    assert(root.lastMessageContentInSessionForTesting(owner).indexOf("resize owner") >= 0);
    assert(root.lastMessageContentInSessionForTesting(other) == " resize other");
    root.flushRepositoryForTesting();
    foreach (event; readAgentRuntimeEvents(buildPath(state, "runtime-events.jsonl")))
        assert(event.kind != AgentEventKind.itemUpdated ||
            event.payloadJson.indexOf("resize other") < 0);
    root.agePartialCheckpointForTesting();
    window.onNativeTick(0.02);
    root.flushRepositoryForTesting();
    bool checkpoint;
    foreach (event; readAgentRuntimeEvents(buildPath(state, "runtime-events.jsonl")))
        if (event.kind == AgentEventKind.itemUpdated &&
            event.payloadJson.indexOf("resize other") >= 0) checkpoint = true;
    assert(checkpoint, "Quiet partial output did not reach the durable journal");
    resize.type = EventType.resizeEnded;
    window.onNativeEvent(resize);
    root.stopTurnClockForTesting();
    root.finishStreamInSessionForTesting(owner);
    root.finishStreamForTesting();
    root.selectSessionForTesting(owner);
    root.stopTurnClockForTesting();
    root.selectSessionForTesting(other);
    root.persistForTesting();

    // Corrupt an unloaded indexed conversation, then select it through the
    // real asynchronous loader. Sending must not replace missing history.
    const saved = root.sessionIdForTesting(owner);
    const thread = buildPath(state, "threads", saved ~ ".json");
    write(thread, "{broken");
    root.reloadSessionsForTesting();
    root.selectSessionForTesting(owner);
    const loaded = MonoTime.currTime + 5.seconds;
    while (root.historyPendingForTesting() && MonoTime.currTime < loaded)
    {
        root.tickTree(0.02);
        Thread.sleep(5.msecs);
    }
    root.tickTree(0.02);
    assert(root.historyUnavailableForTesting() && !root.sendEnabledForTesting());
    root.setInputForTesting("must stay in composer");
    root.sendForTesting();
    assert(root.inputTextForTesting() == "must stay in composer");
    writeln("PASS chat deletion, two-chat progress during native resize, quiet partial durability, failed history blocks Send");

    root.newChatForTesting();
    root.flushRepositoryForTesting();
    const journal = buildPath(state, "runtime-events.jsonl");
    rename(journal, journal ~ ".backup");
    mkdirRecurse(journal);
    root.setInputForTesting("Storage failure must not start this request");
    root.sendForTesting();
    assert(root.storageBlockedForTesting() && !root.turnBusyForTesting());
    assert(root.lastAssistantErrorForTesting().indexOf("not started") >= 0);
    rmdir(journal);
    rename(journal ~ ".backup", journal);
    root.newChatForTesting();
    const recovered = MonoTime.currTime + 7.seconds;
    while (root.storageBlockedForTesting() && MonoTime.currTime < recovered)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    assert(!root.storageBlockedForTesting());
    writeln("PASS storage failure refuses effects and recovers after durable snapshot acknowledgement");

    root.newChatForTesting();
    string[] roles, bodies;
    foreach (i; 0 .. 1502)
    {
        roles ~= i % 2 ? "assistant" : "user";
        bodies ~= i == 33 ? "unique-search-target" : "Message " ~ to!string(i);
    }
    root.addConversationForTesting(roles, bodies);
    root.projectTranscriptForTesting();
    assert(driver.paint());
    root.openChatSearchForTesting();
    root.setChatSearchQueryForTesting("unique-search-target");
    foreach (_; 0 .. 4)
    {
        root.tickTree(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
    }
    assert(root.chatSearchMatchCountForTesting() == 1 &&
        root.chatSearchCurrentMessageForTesting() == 33);
    assert(root.messageInViewportForTesting(33));
    assert(root.materializedTranscriptRowsForTesting() < 100);
    root.setChatSearchQueryForTesting("");
    root.clickFollowPillForTesting();
    root.projectTranscriptForTesting();
    assert(driver.paint());
    writeln("PASS search reveal through a virtualized 1502-message transcript with bounded materialization");
    return 0;
}

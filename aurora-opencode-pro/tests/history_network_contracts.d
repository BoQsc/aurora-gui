module history_network_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_latency_transport.py --history");
    const state = absolutePath("history-http-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "fixture"; settings.model = "history";
    settings.workspace = state; settings.toolsEnabled = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1000; options.height = 700; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    void until(bool delegate() done)
    {
        const deadline = MonoTime.currTime + 8.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), "Network history scenario did not reach its expected state");
    }
    until(delegate() { return !root.startupPendingForTesting(); });
    root.newChatForTesting();
    root.setInputForTesting("Answer once.");
    root.sendForTesting();
    until(delegate() { return !root.turnBusyForTesting() && root.lastAssistantContentForTesting() == "originallast"; });
    assert(root.invokeBubbleActionForTesting(1)); // actual Regenerate callback
    assert(root.bubbleActionForTesting(1) == "View response");
    until(delegate() { return root.lastAssistantContentForTesting() == "replacement2"; });
    assert(root.bubbleVersionForTesting(1) == "2/2");
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "originallast");
    assert(!root.turnBusyForTesting());
    const drainDeadline = MonoTime.currTime + 700.msecs;
    while (MonoTime.currTime < drainDeadline) pump();
    assert(root.lastAssistantContentForTesting() == "originallast",
        "Late output or failure overwrote the restored response");
    assert(root.messageContentForTesting(1) == "originallast");
    assert(root.messageContentForTesting(2) == "replacement2");
    assert(root.totalMessageCountForTesting() == 3);
    assert(root.invokeBubbleVersionNextForTesting(1));
    assert(root.lastAssistantContentForTesting() == "replacement2");
    assert(root.invokeBubbleActionForTesting(1));
    // Allow admission, but restore before this response's delayed headers.
    const admission = MonoTime.currTime + 150.msecs;
    while (MonoTime.currTime < admission) pump();
    assert(root.bubbleActionForTesting(1) == "View response");
    assert(root.activityRowVisualIndexForTesting() == 2,
        "Regeneration activity appeared above the preserved response");
    assert(root.bubbleBoundsForTesting(1).bottom() <= root.bubbleBoundsForTesting(2).y);
    root.setActivityForTesting("Working…");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    assert(root.activityRowVisualIndexForTesting() == 2,
        "Working status moved above the preserved response");
    assert(root.bubbleBoundsForTesting(1).bottom() <= root.bubbleBoundsForTesting(2).y);
    window.saveScreenshot(buildPath(state, "regenerate-working-below.ppm"));
    assert(root.invokeBubbleActionForTesting(1));
    assert(!root.turnBusyForTesting());
    const lateDeadline = MonoTime.currTime + 600.msecs;
    while (MonoTime.currTime < lateDeadline) pump();
    assert(root.lastAssistantContentForTesting() == "replacement2");
    assert(root.totalMessageCountForTesting() == 3);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "originallast");
    assert(root.invokeBubbleVersionNextForTesting(1));
    assert(root.lastAssistantContentForTesting() == "replacement2");
    writeln("PASS real HTTP regeneration retains original/partial replies, cancels promptly on navigation and rejects stale events after restore/reload");
    return 0;
}

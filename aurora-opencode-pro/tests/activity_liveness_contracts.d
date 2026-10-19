module activity_liveness_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = buildPath(tempDir(), "aurora-liveness-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    write(buildPath(state, "fixture.txt"), "recorded fixture evidence");
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(settings.baseUrl.length);
    settings.apiKey = "fixture"; settings.model = "liveness-fixture";
    settings.workspace = state; settings.toolsEnabled = true; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1100; options.height = 700; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void until(bool delegate() ready, bool serviceOnly = false)
    {
        const deadline = MonoTime.currTime + 12.seconds;
        while (!ready() && MonoTime.currTime < deadline)
        {
            if (serviceOnly) window.onNativeService();
            else window.onNativeTick(0.02);
            Thread.sleep(5.msecs);
        }
        assert(ready(), "Activity liveness condition was not reached: " ~
            root.activityTextForTesting() ~ " answer=" ~ root.lastAssistantContentForTesting() ~
            " error=" ~ root.lastAssistantErrorForTesting());
    }
    void send(string prompt)
    {
        root.setInputForTesting(prompt); root.sendForTesting();
    }
    until(delegate() { return !root.startupPendingForTesting(); });
    root.newChatForTesting();
    const alpha = root.currentSessionForTesting();
    send("probe alpha: read fixture.txt then report");
    root.newChatForTesting();
    const beta = root.currentSessionForTesting();
    send("probe beta: read fixture.txt then report");
    // Drain provider/tool events without a widget tick. Both completed tool
    // rounds must remain independently queued before either continuation runs.
    until(delegate() { return root.toolContinuationPendingForTesting(alpha) &&
        root.toolContinuationPendingForTesting(beta); }, true);
    assert(root.activityTextForTesting() == "Continuing after tools…");
    root.newChatForTesting();
    root.stopActiveTurnForTesting(); // selected chat's Stop must not cancel alpha/beta
    until(delegate() { return !root.toolContinuationPendingForTesting(alpha) &&
        !root.toolContinuationPendingForTesting(beta); });
    foreach (index; [alpha, beta])
    {
        root.selectSessionForTesting(index);
        until(delegate() { return !root.turnBusyForTesting(); });
        assert(root.lastAssistantErrorForTesting().length == 0);
        assert(root.lastAssistantContentForTesting().indexOf("Finished probe") == 0);
        assert(root.toolMessageCountForTesting() == 1 && !root.activityVisibleForTesting());
    }
    writeln("PASS simultaneous tool completions resume both chats while selected chat is stopped");

    // Runtime ownership survives session indices moving after deletion.
    root.newChatForTesting();
    const removed = root.currentSessionForTesting();
    send("probe removed: read fixture.txt then report");
    root.newChatForTesting();
    const survivor = root.currentSessionForTesting();
    send("probe survivor: read fixture.txt then report");
    until(delegate() { return root.toolContinuationPendingForTesting(removed) &&
        root.toolContinuationPendingForTesting(survivor); }, true);
    root.selectSessionForTesting(removed);
    root.stopActiveTurnForTesting();
    root.deleteSessionForTesting(removed);
    root.selectSessionForTesting(survivor - 1);
    until(delegate() { return !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Finished probe survivor.");
    writeln("PASS queued continuation follows its runtime across another chat's deletion");

    root.newChatForTesting();
    send("quiet provider");
    until(delegate() { return root.activityTextForTesting().indexOf("Waiting for provider response") == 0; }, true);
    until(delegate() { return root.lastAssistantContentForTesting() == "Partial response."; });
    root.ageStreamOutputForTesting(31);
    until(delegate() { return root.activityTextForTesting().indexOf("No new output for 31s") == 0; }, true);
    root.projectTranscriptForTesting(); assert(driver.paint());
    window.saveScreenshot("build/activity-liveness-quiet.ppm");
    assert(root.turnBusyForTesting(), "Silence advisory stopped a live provider");
    until(delegate() { return !root.turnBusyForTesting(); });
    assert(root.lastAssistantContentForTesting() == "Partial response. Resumed.");
    assert(!root.activityVisibleForTesting());
    writeln("PASS provider response phase, silence advisory, resumed output and terminal cleanup");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["preserve my work"]);
    root.startTurnClockForTesting(); root.beginStreamForTesting();
    root.streamContentForTesting("Preserved partial answer.");
    root.ageMissingOperationForTesting();
    until(delegate() { return !root.turnBusyForTesting(); }, true);
    assert(!root.turnBusyForTesting() && root.sendButtonTextForTesting() == "Send");
    assert(root.lastAssistantErrorForTesting().indexOf("no active operation") >= 0);
    assert(root.lastAssistantContentForTesting() == "Preserved partial answer.");
    assert(!root.activityVisibleForTesting());
    root.projectTranscriptForTesting(); assert(driver.paint());
    window.saveScreenshot("build/activity-liveness-recovered.ppm");
    writeln("PASS orphan busy flags become a visible retryable failure with partial output preserved");
    return 0;
}

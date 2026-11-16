module recovery_graceful_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;

/// The recovery budget must end a turn without painting a failed/error state
/// over the delivered answer. This runs the real UI, actor, HTTP and done
/// handler path for a model that keeps reporting no progress.
int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run through the task-continuation fixture provider");
    const state = buildPath(tempDir(), "aurora-recovery-ui-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "fixture"; settings.model = "continuation-fixture";
    settings.workspace = workspace; settings.toolsEnabled = true; settings.quickTitle = false;
    settings.legacyTools = false;
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
        const deadline = MonoTime.currTime + 20.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), "Did not settle: " ~ root.lastAssistantContentForTesting() ~
            " error=" ~ root.lastAssistantErrorForTesting());
    }
    until(delegate() { return !root.startupPendingForTesting(); });

    root.newChatForTesting();
    root.setInputForTesting("Implement the fixture stalled task.");
    root.sendForTesting();
    until(delegate() { return !root.turnBusyForTesting(); });

    assert(root.turnStatusForTesting() == "completed",
        "Recovery exhaustion stopped the chat: " ~ root.turnStatusForTesting() ~
        " error=" ~ root.lastAssistantErrorForTesting());
    assert(root.failedMessageCountForTesting() == 0 &&
        root.lastAssistantErrorForTesting().length == 0,
        "Internal recovery exhaustion surfaced as a failed/error bubble");
    assert(root.taskStatusForTesting() != "completed" &&
        root.taskStatusForTesting() != "blocked",
        "Unfinished work was relabeled " ~ root.taskStatusForTesting());
    assert(root.taskStepStatusForTesting(0) == "in_progress",
        "The unfinished recorded outcome was lost");
    assert(root.lastBubbleSecondaryActionForTesting() == "Continue",
        "The unfinished turn lost its Continue affordance: " ~
        root.lastBubbleSecondaryActionForTesting());
    writeln("PASS exhausted recovery ends normally, keeps the answer and offers Continue");
    return 0;
}

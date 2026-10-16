module quick_title_agent_turn_contracts;

// Regression: a brand-new conversation whose opening turn runs real tool
// rounds still gets its quick chat-name rewrite.
//
// The rewrite used to be gated on runtime.busy(), which stays true for the
// whole turn (turnInFlight, turnTiming and pending tools across every tool
// round and task-continuation round). A plain single-round chat could slip
// through in the gaps, but an agent turn that keeps working never left room,
// so the raw first message stayed as the name forever. The gate must wait only
// for this conversation's own in-flight provider request (runtime.client).

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : buildPath, absolutePath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run with tests/test_quick_title_agent_turn.py");
    const directory = absolutePath(
        "quick-title-agent-turn-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    const state = buildPath(directory, "state");
    mkdirRecurse(workspace);
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base;
    settings.apiKey = "local-fixture";
    settings.model = "fixture";
    settings.workspace = workspace;
    // Tools ON so the opening turn really spans several rounds and the
    // conversation stays busy while the rewrite is pending.
    settings.toolsEnabled = true;
    settings.legacyTools = false;
    settings.quickTitle = true;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }

    root.newChatForTesting();
    const titledIndex = root.currentSessionForTesting();
    root.setInputForTesting("List the workspace, then reply TITLE_TURN_DONE.");
    root.sendForTesting();

    // The fixture provider drips its opening tool call over several seconds, so
    // the turn is still running (turnBusyForTesting true) while the rewrite is
    // pending. The rewrite must land DURING that busy window; asserting it only
    // after the turn settles would pass even under the old whole-turn gate.
    const titleDeadline = MonoTime.currTime + 30.seconds;
    while (root.sessionTitleForTesting(titledIndex) != "Fixture" &&
        MonoTime.currTime < titleDeadline)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(root.sessionTitleForTesting(titledIndex) == "Fixture",
        "quick title was starved while the opening turn was still busy; title='" ~
        root.sessionTitleForTesting(titledIndex) ~ "' turnBusy=" ~
        (root.turnBusyForTesting() ? "true" : "false"));

    // The turn must still be running, proving the rewrite did not merely wait
    // for it to finish - the exact starvation the gate used to cause.
    assert(root.turnBusyForTesting(),
        "the rewrite only appeared after the turn ended, so the busy-turn " ~
        "starvation case is untested");

    // Let the turn finish so the provider's DONE reply is exercised too.
    const settleDeadline = MonoTime.currTime + 60.seconds;
    while (MonoTime.currTime < settleDeadline)
    {
        window.onNativeTick(0.02);
        if (!root.turnBusyForTesting() &&
            root.lastAssistantContentForTesting() == "TITLE_TURN_DONE")
            break;
        Thread.sleep(10.msecs);
    }
    assert(root.lastAssistantContentForTesting() == "TITLE_TURN_DONE",
        "the agent turn did not settle; last='" ~
        root.lastAssistantContentForTesting() ~ "' error='" ~
        root.lastAssistantErrorForTesting() ~ "'");
    assert(root.toolMessageCountForTesting() >= 1,
        "the opening turn ran no tool round, so the busy-turn case is untested");
    writeln("PASS quick title generated for a new chat whose opening turn " ~
        "ran tool rounds");
    return 0;
}

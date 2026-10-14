module quick_title_contracts;

// Proves a brand-new conversation's quick chat-name rewrite still runs when
// ANOTHER conversation is mid-turn. The deferral must wait only for the new
// conversation's own opening turn; keying it on anyTurnIsBusy() starved the
// name whenever any other chat was busy, leaving the raw first message.

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
    assert(base.length, "Run with tests/test_quick_title.py");
    const directory = absolutePath(
        "quick-title-" ~ to!string(MonoTime.currTime.ticks));
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
    settings.toolsEnabled = false;
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

    // Conversation A: opened and left mid-turn for the whole test, without a
    // real request, so anyTurnIsBusy() stays true while B is titled.
    root.newChatForTesting();
    const busyIndex = root.currentSessionForTesting();
    root.startTurnClockForTesting();
    assert(root.turnBusyForTesting(), "conversation A was not marked busy");

    // Conversation B: a brand-new chat. Its quick title must run once B's own
    // opening turn settles, even though A is still busy.
    root.newChatForTesting();
    const titledIndex = root.currentSessionForTesting();
    assert(titledIndex != busyIndex, "second conversation did not open");
    root.setInputForTesting(
        "Describe the new engine module design and then reply DONE.");
    root.sendForTesting();
    const settleDeadline = MonoTime.currTime + 30.seconds;
    while (MonoTime.currTime < settleDeadline)
    {
        window.onNativeTick(0.02);
        if (!root.turnBusyForTesting() &&
            root.lastAssistantContentForTesting() == "DONE")
            break;
        Thread.sleep(10.msecs);
    }
    assert(root.lastAssistantContentForTesting() == "DONE",
        "the second conversation's turn did not settle");
    assert(root.turnBusyForTesting() == false,
        "the second conversation is still busy after its turn");

    const titleDeadline = MonoTime.currTime + 3.seconds;
    while (root.sessionTitleForTesting(titledIndex) != "Fixture" &&
        MonoTime.currTime < titleDeadline)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(root.sessionTitleForTesting(titledIndex) == "Fixture",
        "quick title was starved while another conversation was busy; title='" ~
        root.sessionTitleForTesting(titledIndex) ~ "'");
    writeln("PASS quick title generated for a new chat while another " ~
        "conversation stayed busy");
    return 0;
}

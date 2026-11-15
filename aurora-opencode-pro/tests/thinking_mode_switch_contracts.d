module thinking_mode_switch_contracts;

// Regression: the composer Thinking selector must show the mode that is
// actually in effect for the open conversation, and switching conversations
// must not rewrite the saved app-wide mode.
//
// A per-route Off has to win over a conversation's older `true` flag. Otherwise
// the selector printed "Thinking: Low" (thinkingEffortLabel's fallback for the
// route's "off" record) while the request sent the model's default effort, and
// the label changed on every switch between that chat and one whose flag was
// already false.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets \
//       -of=build/thinking_mode_switch_contracts.exe \
//       aurora-opencode-pro/tests/thinking_mode_switch_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/thinking_mode_switch_contracts.exe

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, loadSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.time : MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

int main()
{
    const stateDir = buildPath(tempDir, "aurora-opencode-thinking-switch");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    // Point the app's settings at a throwaway directory.
    setOpencodeStateDirectoryForTesting(stateDir);

    Settings seeded;
    seeded.model = "deepseek-v4.1-flash";
    seeded.thinking = true;
    saveSettings(seeded);

    WindowOptions options;
    options.title = "thinking mode switch contracts";
    options.width = 1100;
    options.height = 800;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit)
    {
        root.shutdownClient();
        window.close();
    }
    const deadline = MonoTime.currTime + seconds(30);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
        root.tickTree(0.02);
    assert(!root.startupPendingForTesting(), "startup restore did not finish");

    // Chat A: choose High. The selector must show it immediately, check it in
    // the dropdown, and the next request must carry high effort.
    root.newChatForTesting();
    root.tickTree(0.02);
    const chatA = root.currentSessionForTesting();
    assert(chatA >= 0, "chat A was not created");
    root.setThinkingModeForTesting("high");
    root.tickTree(0.02);
    assert(root.thinkingControlTextForTesting() == "Thinking: High",
        "selector did not show the chosen High mode: " ~
        root.thinkingControlTextForTesting());
    assert(root.thinkingMenuModeForTesting() == "high",
        "dropdown did not mark High as chosen: " ~
        root.thinkingMenuModeForTesting());
    assert(root.requestReasoningForTesting() == "on:high",
        "request did not carry High: " ~ root.requestReasoningForTesting());

    // Chat B: inherits the mode in effect, then the user turns it Off. The
    // label and the request must both read Off; the label must not keep the
    // previous value until the next chat switch.
    root.newChatForTesting();
    root.tickTree(0.02);
    const chatB = root.currentSessionForTesting();
    assert(chatB >= 0, "chat B was not created");
    assert(root.thinkingControlTextForTesting() == "Thinking: High",
        "a new chat did not show the mode in effect: " ~
        root.thinkingControlTextForTesting());
    root.setThinkingModeForTesting("off");
    root.tickTree(0.02);
    assert(root.thinkingControlTextForTesting() == "Thinking: Off",
        "selector did not show Off after choosing it: " ~
        root.thinkingControlTextForTesting());
    assert(root.requestReasoningForTesting() == "off",
        "request still carried reasoning after choosing Off: " ~
        root.requestReasoningForTesting());

    // Back to chat A. Its own flag is still `true`, but the explicit per-route
    // Off is what is actually sent. The label used to fall back to "Thinking:
    // Low" here (and the dropdown marked no row at all), which is the change
    // seen when switching conversations.
    root.selectSessionForTesting(chatA);
    root.tickTree(0.02);
    assert(root.activeSessionThinkingForTesting(),
        "fixture lost chat A's own Thinking flag");
    assert(root.thinkingControlTextForTesting() == "Thinking: Off",
        "route Off did not win over the chat's stale flag: " ~
        root.thinkingControlTextForTesting());
    assert(root.thinkingMenuModeForTesting() == "off",
        "dropdown did not mark Off for the route: " ~
        root.thinkingMenuModeForTesting());
    assert(root.requestReasoningForTesting() == "off",
        "request did not follow the route Off: " ~ root.requestReasoningForTesting());

    // Opening a conversation must not rewrite the saved app-wide mode. Before
    // the fix, selecting chat A copied its `true` flag into Settings, and the
    // next debounced settings write persisted it.
    assert(!root.settingsThinkingForTesting(),
        "opening a conversation rewrote the in-memory Thinking switch");
    root.flushSettingsForTesting();
    auto saved = loadSettings();
    assert(!saved.thinking,
        "opening a conversation rewrote the saved Thinking switch");
    assert(!saved.reasoningControls.length ||
        saved.reasoningControls[0].effort == "off",
        "opening a conversation changed the saved route record");

    // And the switch the other way keeps the same mode: no chatter between the
    // two conversations.
    root.selectSessionForTesting(chatB);
    root.tickTree(0.02);
    assert(root.thinkingControlTextForTesting() == "Thinking: Off",
        "switching back to chat B changed the displayed mode: " ~
        root.thinkingControlTextForTesting());
    assert(root.requestReasoningForTesting() == "off",
        "chat B stopped following the chosen Off: " ~
        root.requestReasoningForTesting());

    writeln("PASS thinking mode stays Off across a conversation switch and " ~
        "matches the saved choice");
    writeln("PASS a per-route Off wins over a chat's stale Thinking flag");
    writeln("thinking_mode_switch_contracts: PASS");
    return 0;
}

module console_default_contracts;

// Focused verification of the non-GUI (cmd/console) default model: a console
// session must default to the lowest-latency DeepSeek 4.1 route with reasoning
// off, while the saved Settings keep the user's own choice. A normal session
// must still use the saved model. This drives the real widgets offscreen.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets -of=build/console_default_contracts.exe \
//       aurora-opencode-pro/tests/console_default_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/console_default_contracts.exe

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, loadSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.time : MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

// Mirrors app.d's non-GUI default so the test pins the same values the console
// path applies. Kept as literals so a drift in app.d is caught here too.
enum string consoleModel = "deepseek/deepseek-v4.1-flash-fast";

int main()
{
    const stateDir = buildPath(tempDir, "aurora-opencode-console-default");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    // Point the app's settings at a throwaway directory.
    setOpencodeStateDirectoryForTesting(stateDir);

    Settings seeded;
    seeded.model = "deepseek-v4.1-flash";
    seeded.thinking = true;
    saveSettings(seeded);

    WindowOptions options;
    options.title = "console default contracts";
    options.width = 1100;
    options.height = 800;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    scope (exit)
    {
        root.shutdownClient();
        window.close();
    }
    // Wait out the deferred history load so newChat() can run, exactly as the
    // real console entry path does before creating its conversation.
    const deadline = MonoTime.currTime + seconds(30);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        driver.paint();
    }

    const savedBefore = root.settingsModelForTesting();
    writeln("Saved model before console run: ", savedBefore);

    // Apply the console default, exactly as beginConsoleConversation does.
    root.setConsoleDefaultModel(consoleModel, false);
    root.newChatForTesting();

    assert(root.activeSessionModelForTesting() == consoleModel,
        "console session did not use the fast route: " ~
        root.activeSessionModelForTesting());
    assert(!root.activeSessionThinkingForTesting(),
        "console session should run with thinking off");
    writeln("Console session uses ", root.activeSessionModelForTesting(),
        ", thinking off");
    // The composer selector must agree with the low-latency route even though
    // the saved Settings above enable Thinking: otherwise a console run would
    // read "Thinking: High" while every request still sends no reasoning.
    assert(root.thinkingModeLabelForTesting() == "Thinking: Off",
        "console conversation should read Thinking: Off, not " ~
        root.thinkingModeLabelForTesting());
    writeln("Console conversation reads ",
        root.thinkingModeLabelForTesting());

    // The saved Settings must be untouched by the console session.
    assert(root.settingsModelForTesting() == savedBefore,
        "a console session leaked its model into saved Settings");
    root.flushSettingsForTesting();
    assert(loadSettings().model == savedBefore,
        "persisted Settings changed after a console run");
    writeln("Saved Settings keep the user's model after a console run");

    // A normal (GUI) session must still use the saved model.
    root.setConsoleDefaultModel("", false);
    root.newChatForTesting();
    assert(root.activeSessionModelForTesting() == savedBefore,
        "a normal session should use the saved model");
    writeln("A normal session still uses the saved model: ",
        root.activeSessionModelForTesting());
    // Thinking is enabled in the seeded Settings, and DeepSeek 4.1 Flash has no
    // per-route record here, so the GUI conversation reads the model default.
    assert(root.thinkingModeLabelForTesting() == "Thinking: High",
        "a GUI conversation on DeepSeek 4.1 Flash should read Thinking: High, " ~
        "not " ~ root.thinkingModeLabelForTesting());
    writeln("GUI conversation reads ", root.thinkingModeLabelForTesting());

    writeln("console_default_contracts: PASS");
    return 0;
}

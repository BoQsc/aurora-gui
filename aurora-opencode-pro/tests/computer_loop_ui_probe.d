module computer_loop_ui_probe;

// Verification for the streaming computer loop's USER-VISIBLE surface: the
// Settings switch exists with its label, it paints, and flipping it through the
// checkbox's own handler wires the loop presentation and computer use together.
// The widgets here are the same ones the desktop window draws; the screenshot is
// the rendered dialog.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.computeruse : experimentalComputerUseEnabled,
    setComputerUseSetting;
import auroraopencode.sentenceloop : experimentalSentenceLoopEnabled;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

int main()
{
    const directory = buildPath(tempDir(),
        "aurora-loop-ui-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    // D forbids try/catch inside a scope guard, so the cleanup is a function.
    void cleanup()
    {
        setComputerUseSetting(false);
        try { rmdirRecurse(directory); }
        catch (Exception) {}
    }
    scope (exit) cleanup();
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:1/v1";
    settings.apiKey = "";
    settings.quickTitle = false;
    settings.workspace = directory;
    settings.experimentalComputerUse = true;
    settings.experimentalReactiveParagraph = false;
    saveSettings(settings);

    WindowOptions options;
    options.title = "Aurora loop UI probe";
    options.width = 1200;
    options.height = 900;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 15.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting(), "the offscreen UI never finished starting");

    auto switcher = root.computerLoopCheckboxForTesting();
    assert(switcher !is null, "Settings has no streaming computer loop switch");
    const label = root.computerLoopSwitchLabelForTesting();
    writeln("switch label: ", label);
    assert(label.indexOf("Experimental streaming computer loop") >= 0,
        "unexpected loop switch label: " ~ label);
    assert(label.indexOf("reactive paragraph") < 0,
        "the old reactive-paragraph wording is still on the switch");

    auto driver = new UiTestDriver(window);
    // The switch lives in the Options section; collapse the two long sections
    // above it and expand Options so the rendered frame contains the row being
    // verified instead of the top of the dialog.
    assert(root.toggleSettingsSectionForTesting("oc-settings-connection"),
        "Settings has no Connection section");
    assert(root.toggleSettingsSectionForTesting("oc-settings-project"),
        "Settings has no Project section");
    assert(root.toggleSettingsSectionForTesting("oc-settings-options"),
        "Settings has no Options section");
    assert(driver.paint(), "painting Settings failed");
    // Fixed location outside the run directory: it survives the cleanup so the
    // rendered dialog can be inspected afterwards.
    const shot = buildPath(tempDir(), "aurora-loop-ui-shot", "loop-switch.png");
    mkdirRecurse(buildPath(tempDir(), "aurora-loop-ui-shot"));
    window.saveScreenshot(shot);
    assert(exists(shot), "no screenshot was written");
    writeln("screenshot: ", shot);

    // Flip it exactly as a click does: the checkbox's own handler runs.
    assert(!experimentalSentenceLoopEnabled(), "the loop presentation started enabled");
    switcher.setChecked(true);
    assert(experimentalSentenceLoopEnabled(),
        "the switch did not turn the loop presentation on");
    assert(experimentalComputerUseEnabled(),
        "the switch did not keep computer use enabled");
    assert(switcher.checked(), "the checkbox did not stay checked");
    assert(driver.paint(), "repainting after the toggle failed");
    switcher.setChecked(false);
    assert(!experimentalSentenceLoopEnabled(),
        "the switch did not turn the loop presentation off again");
    writeln("PASS loop switch label, rendering and wiring");
    return 0;
}

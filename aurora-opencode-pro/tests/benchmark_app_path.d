module auroraopencode_pro_benchmark_app_path;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, loadSettings, opencodeTheme,
    saveSettings, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText;
import std.process : environment;
import std.stdio : stderr, writeln;

// Drives the same conversation root as the desktop app with a software window.
// The Python benchmark owns fresh workspace/state directories and removes the
// state directory, which temporarily contains a copy of the configured key.
int main(string[] args)
{
    if (args.length != 6)
    {
        stderr.writeln("usage: benchmark_app_path <workspace> <state> " ~
            "<prompt-file> <model> <timeout-seconds>");
        return 2;
    }
    const workspace = args[1];
    const stateDir = args[2];
    const promptFile = args[3];
    const model = args[4];
    int timeoutSeconds;
    try timeoutSeconds = to!int(args[5]);
    catch (Exception)
    {
        stderr.writeln("invalid timeout");
        return 2;
    }
    if (!exists(workspace) || exists(stateDir) || !exists(promptFile) ||
        timeoutSeconds < 1)
    {
        stderr.writeln("workspace/prompt missing, state already exists, or " ~
            "timeout invalid");
        return 2;
    }

    const saved = loadSettings();
    auto apiKey = environment.get("AURORA_BENCH_KEY", saved.apiKey);
    if (apiKey.length == 0)
    {
        stderr.writeln("Aurora has no configured API key");
        return 3;
    }
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    Settings settings;
    settings.baseUrl = saved.baseUrl;
    settings.apiKey = apiKey;
    settings.model = model;
    settings.thinking = saved.thinking;
    settings.verbosity = saved.verbosity;
    settings.toolsEnabled = true;
    settings.legacyTools = false;
    settings.workspace = workspace;
    saveSettings(settings);

    WindowOptions options;
    options.title = "Aurora benchmark";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    root.tickTree(0.02);
    root.setInputForTesting(readText(promptFile));
    root.sendForTesting();

    const deadline = MonoTime.currTime + timeoutSeconds.seconds;
    while (MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        if (root.currentSessionForTesting() >= 0 &&
            !root.turnBusyForTesting() &&
            root.lastAssistantContentForTesting().length > 0)
            break;
        Thread.sleep(20.msecs);
    }
    root.persistForTesting();
    const completed = !root.turnBusyForTesting() &&
        root.lastAssistantContentForTesting().length > 0;
    writeln(completed ? "completed" : "incomplete");
    return completed ? 0 : 4;
}

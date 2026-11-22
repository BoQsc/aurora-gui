module hostlite;

import aurorahost.runtime : runHostWindow;
import aurorahost.scene : createWindow, loadScene, NodeRegistry;
import opencodelite.controller : LiteController;
import opencodelite.pluginloader : LitePlugin;
import opencodelite.registryview : RegistryLiteView;
import opencodelite.settings : LiteSettings, loadSettings;
import std.conv : to;
import std.file : exists, mkdirRecurse, thisExePath, write;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : stderr;

private enum EmbeddedScene = import("lite.scene.json");

private string embeddedScenePath()
{
    auto root = environment.get("LOCALAPPDATA", "");
    if (root.length == 0)
        root = ".";
    const directory = buildPath(root, "AuroraOpenCodeLite");
    if (!exists(directory))
        mkdirRecurse(directory);
    const path = buildPath(directory, "lite.scene.json");
    if (!exists(path))
        write(path, EmbeddedScene);
    return path;
}

int main(string[] args)
{
    string scenePath;
    bool watch = true;
    bool externalController;
    ushort listenPort;
    string pluginPath;
    for (size_t index = 1; index < args.length; ++index)
    {
        if (args[index] == "--scene" && index + 1 < args.length)
        {
            scenePath = args[index + 1];
            ++index;
        }
        else if (args[index] == "--external-controller")
            externalController = true;
        else if (args[index] == "--listen" && index + 1 < args.length)
        {
            listenPort = to!ushort(args[index + 1]);
            externalController = true;
            ++index;
        }
        else if (args[index] == "--plugin" && index + 1 < args.length)
        {
            pluginPath = args[index + 1];
            ++index;
        }
    }
    if (scenePath.length == 0)
        scenePath = embeddedScenePath();

    try
    {
        const scene = loadScene(scenePath);
        auto registry = new NodeRegistry();
        const settings = loadSettings();
        environment["AURORA_RENDERER"] = "software";
        auto window = createWindow(scene, registry);
        if (externalController)
            return runHostWindow(window, registry, true, scenePath, watch,
                listenPort);
        if (pluginPath.length == 0)
        {
            auto bundled = buildPath(dirName(thisExePath()),
                "opencode-lite-controller.dll");
            if (exists(bundled))
                pluginPath = bundled;
        }
        if (pluginPath.length != 0)
        {
            try
            {
                auto plugin = new LitePlugin(registry, pluginPath);
                return runHostWindow(window, registry, false, scenePath, watch);
            }
            catch (Exception error)
            {
                // A broken optional plugin must not prevent the embedded
                // controller from starting.
                stderr.writeln("hostlite: plugin fallback: " ~ error.msg);
            }
        }
        auto controller = new LiteController(
            new RegistryLiteView(registry), settings);
        registry.onAction = &controller.handleAction;
        registry.onService = &controller.service;
        registry.onAfterApply = &controller.refreshView;
        controller.refreshView();
        return runHostWindow(window, registry, false, scenePath, watch);
    }
    catch (Exception error)
    {
        stderr.writeln("hostlite: " ~ error.msg);
        return 1;
    }
}

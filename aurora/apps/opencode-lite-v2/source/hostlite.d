module hostlite;

import aurorahost.runtime : runHostWindow;
import aurorahost.scene : createWindow, loadScene, NodeRegistry;
import aurorahost.console : errLine;
import aurorahost.controller_supervisor : ControllerSupervisor;
import aurorahost.single_instance : HostInstance, activateWindow;
import aurorahost.lifecycle : HostRunJournal;
import opencodelite.controller : LiteController;
import opencodelite.pluginloader : LitePlugin;
import opencodelite.registryview : RegistryLiteView;
import opencodelite.settings : LiteSettings, loadSettings;
import opencodelite.widgets : universalWidgetFactory;
import std.conv : to;
import std.file : exists, mkdirRecurse, thisExePath, write;
import std.path : buildPath, dirName;
import std.process : environment;


private enum EmbeddedScene = import("lite.scene.json");

private string embeddedScenePath()
{
    auto root = environment.get("LOCALAPPDATA", "");
    if (root.length == 0)
        root = ".";
    const directory = buildPath(root, "AuroraOpenCodeLiteV2");
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
    bool pluginDisabled;
    bool singleInstance = true;
    bool allowDuplicateInstance;
    string instanceGroup;
    bool noActivate;
    ushort controllerPort = 8792;
    bool startMinimized;
    bool allowTermination;
    bool allowInjectedInput;
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
        else if (args[index] == "--no-plugin")
            pluginDisabled = true;
        else if (args[index] == "--no-single-instance")
            singleInstance = false;
        else if (args[index] == "--allow-duplicate-instance")
            allowDuplicateInstance = true;
        else if (args[index] == "--instance-group" && index + 1 < args.length)
        {
            instanceGroup = args[index + 1];
            ++index;
        }
        else if (args[index] == "--no-activate")
            noActivate = true;
        else if (args[index] == "--controller-port" && index + 1 < args.length)
        {
            controllerPort = to!ushort(args[index + 1]);
            ++index;
        }
        else if (args[index] == "--start-minimized")
            startMinimized = true;
        else if (args[index] == "--allow-termination")
            allowTermination = true;
        else if (args[index] == "--allow-injected-input")
            allowInjectedInput = true;
    }
    if (scenePath.length == 0)
        scenePath = embeddedScenePath();
    const journalAppId = "AuroraOpenCodeLiteV2" ~
        (instanceGroup.length > 0 ? "-" ~ instanceGroup : "");
    // The production window rejects external force-kill; tests and isolated
    // groups are disposable, and the flags mark an intentional disposable run.
    const allowForcedTermination = allowTermination || !singleInstance ||
        allowDuplicateInstance || instanceGroup.length > 0;

    try
    {
        const scene = loadScene(scenePath);
        HostInstance instance;
        if (singleInstance)
        {
            const instanceKey = "AuroraOpenCodeLiteV2|" ~ scene.window.title ~
                (instanceGroup.length > 0 ? "|" ~ instanceGroup : "");
            if (allowDuplicateInstance)
                instance.release(); // Explicitly intentional multi-instance run.
            else
            if (!instance.acquire(instanceKey))
            {
                if (!activateWindow(scene.window.title))
                    errLine("hostlite: existing instance has no visible window");
                return 0;
            }
        }
        HostRunJournal journal;
        journal.begin(journalAppId);
        if (journal.previousUnclean)
            errLine("hostlite: previous run ended without an intentional close");
        auto registry = new NodeRegistry();
        registry.components.register("opencode.universal", universalWidgetFactory());
        const settings = loadSettings();
        environment["AURORA_RENDERER"] = "software";
        auto window = createWindow(scene, registry, startMinimized, false,
            noActivate);
        const controllerExe = buildPath(dirName(thisExePath()),
            "aurora-opencode-lite-v2-controller.exe");
        // Production default: isolate the controller in its own process so a
        // native fault in a network worker cannot take down the host window.
        // In-process plugins remain an explicit `--plugin` live-dev opt-in.
        if (!externalController && pluginPath.length == 0 &&
            !pluginDisabled && exists(controllerExe))
        {
            auto supervisor = new ControllerSupervisor(controllerExe,
                controllerPort, 10, 500,
                delegate(string text) { errLine("hostlite: " ~ text); });
            supervisor.start();
            const result = runHostWindow(window, registry, true, scenePath,
                watch, controllerPort, allowForcedTermination,
                allowInjectedInput);
            journal.close("window closed");
            return result;
        }
        if (externalController)
        {
            const result = runHostWindow(window, registry, true, scenePath,
                watch, listenPort, allowForcedTermination,
                allowInjectedInput);
            journal.close("window closed");
            return result;
        }
        if (pluginPath.length == 0 && !pluginDisabled)
        {
            auto bundled = buildPath(dirName(thisExePath()),
                "opencode-lite-v2-controller.dll");
            if (exists(bundled))
                pluginPath = bundled;
        }
        if (pluginPath.length != 0)
        {
            try
            {
                errLine(
                    "hostlite: loading in-process plugin (not process-isolated): " ~
                    pluginPath);
                auto plugin = new LitePlugin(registry, pluginPath);
                errLine("hostlite: plugin initialized");
                const result = runHostWindow(window, registry, false,
                    scenePath, watch, 0, allowForcedTermination,
                    allowInjectedInput);
                errLine("hostlite: plugin host loop returned " ~
                    to!string(result));
                journal.close("window closed");
                return result;
            }
            catch (Exception error)
            {
                // A broken optional plugin must not prevent the embedded
                // controller from starting.
                errLine("hostlite: plugin fallback: " ~ error.msg);
            }
        }
        auto controller = new LiteController(
            new RegistryLiteView(registry), settings);
        registry.onAction = &controller.handleAction;
        registry.onService = &controller.service;
        registry.onAfterApply = &controller.refreshView;
        controller.refreshView();
        const result = runHostWindow(window, registry, false, scenePath, watch,
            0, allowForcedTermination, allowInjectedInput);
        journal.close("window closed");
        return result;
    }
    catch (Exception error)
    {
        HostRunJournal.recordFailure(journalAppId, error.msg);
        errLine("hostlite: " ~ error.msg);
        return 1;
    }
}

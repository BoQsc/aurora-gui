module aurorahost.runtime;

import aurorahost.control : ControlServer;
import aurorahost.console : errLine, outLine;

import aurorahost.events : HostEvent;
import aurorahost.host_module : HostModule;
import aurorahost.live_guard : liveGuardError, protectLiveWindow;
import aurorahost.runtime_policy : FileRuntimePolicy;
import aurorahost.scene : applyScene, describeScene, loadScene, NodeRegistry, Scene;
import aurorahost.tcp_control : TcpControl;
import aurora : GuiWindow;
import std.conv : to;
import std.datetime : SysTime;
import std.file : dirEntries, exists, SpanMode, timeLastModified, write;
import std.path : buildPath, extension;
import std.process : environment;
private void reportService(string where, Throwable error)
{
    errLine("aurora-host: " ~ where ~ " failed: " ~ error.msg);
}

/**
 * A reusable scene file watcher. It applies a changed scene to an existing
 * host window without recreating the process or the retained root.
 */
final class SceneWatcher
{
    private string _path;
    private GuiWindow _window;
    private NodeRegistry _registry;
    private SysTime _stamp;

    this(string path, GuiWindow window, NodeRegistry registry)
    {
        _path = path;
        _window = window;
        _registry = registry;
        _stamp = timeLastModified(path);
    }

    void poll()
    {
        SysTime stamp;
        try
            stamp = timeLastModified(_path);
        catch (Exception)
            return;
        if (stamp == _stamp)
            return;
        _stamp = stamp;
        try
        {
            const scene = loadScene(_path);
            applyScene(_window, scene, _registry);
            errLine("reloaded: " ~ describeScene(scene));
        }
        catch (Exception error)
        {
            errLine("aurora-host: reload failed: " ~ error.msg);
        }
    }
}

/**
 * Run a constructed host window with the optional control channel and scene
 * watcher. This is the one loop shared by the host CLI and embedded hosts.
 */
int runHostWindow(GuiWindow window, NodeRegistry registry, bool control,
    string scenePath, bool watch, ushort listenPort = 0,
    bool allowForcedTermination = false, bool allowInjectedInput = false)
{
    // Keep the live window owned by this process. Tests, isolated instance
    // groups, and explicitly disposable sessions opt out; the production host
    // refuses an external TerminateProcess while a normal window close still
    // exits. This is what makes "never kill the development window" enforceable
    // instead of a rule an automated tool can ignore.
    auto runtimePolicy = new FileRuntimePolicy();
    if (!allowForcedTermination && runtimePolicy.current.protectHost)
    {
        if (protectLiveWindow())
            errLine("aurora-host: live window protected from forced termination");
        else
            errLine("aurora-host: live-window protection unavailable: " ~
                liveGuardError());
    }
    HostModule[] hostModules;
    auto moduleRoot = environment.get("LOCALAPPDATA", ".");
    if (moduleRoot.length == 0)
        moduleRoot = ".";
    const moduleDir = buildPath(moduleRoot, "AuroraHost", "modules");
    if (exists(moduleDir))
    {
        foreach (entry; dirEntries(moduleDir, SpanMode.shallow))
        {
            if (extension(entry.name) != ".dll")
                continue;
            try
            {
                auto hostModule = new HostModule();
                hostModule.load(entry.name);
                auto abi = cast(int function() @system)
                    hostModule.symbol("aurora_module_abi");
                if (abi is null || abi() != 2)
                {
                    hostModule.unload();
                    continue;
                }
                hostModules ~= hostModule;
            }
            catch (Exception error)
                reportService("host module load", error);
        }
    }
    scope (exit)
        foreach (hostModule; hostModules)
            hostModule.unload();
    try
        write(buildPath(moduleRoot, "AuroraHost", "host-modules.loaded"),
            "loaded=" ~ to!string(hostModules.length) ~ "\n");
    catch (Exception error)
        reportService("host module marker", error);
    // Do not install global low-level mouse/keyboard hooks. They run for every
    // desktop input event and can make the whole computer's pointer feel slow.
    // Input policy remains on the control channel; desktop injection is not
    // part of the supported development path.
    ControlServer server;
    if (control || listenPort != 0)
    {
        server = new ControlServer(window, registry, scenePath);
        server.stdoutEnabled(control);
        registry.onActivate = delegate(string id)
        {
            try
                server.eventActivated(id);
            catch (Throwable error)
                reportService("activate event", error);
        };
        registry.onAction = delegate(string node, string action)
        {
            try
                server.eventAction(node, action);
            catch (Throwable error)
                reportService("action event", error);
        };
        registry.onEvent = delegate(HostEvent event)
        {
            try
                server.eventInput(event);
            catch (Throwable error)
                reportService("input event", error);
        };
    }
    TcpControl tcp;
    if (listenPort != 0)
    {
        tcp = new TcpControl(server, listenPort);
        tcp.start();
    }
    SceneWatcher watcher;
    if (watch)
        watcher = new SceneWatcher(scenePath, window, registry);
    if (control || listenPort != 0 || watch || registry.onService !is null)
    {
        window.applicationService = delegate(double delta)
        {
            if (runtimePolicy.changed() && runtimePolicy.reload())
            {
                auto root = environment.get("LOCALAPPDATA", ".");
                if (root.length == 0)
                    root = ".";
                try
                    write(buildPath(root, "AuroraHost",
                        "runtime-policy.reload"), "reloaded\n");
                catch (Exception error)
                    reportService("runtime policy marker", error);
            }
            if (registry.onService !is null)
            {
                try
                    registry.onService(delta);
                catch (Throwable error)
                    reportService("service callback", error);
            }
            if (watcher !is null)
            {
                try
                    watcher.poll();
                catch (Throwable error)
                    reportService("scene watcher", error);
            }
            if (server !is null)
            {
                try
                    server.service(delta);
                catch (Throwable error)
                    reportService("control service", error);
                try
                    server.drain();
                catch (Throwable error)
                    reportService("control drain", error);
            }
        };
    }
    if (server !is null)
    {
        server.start();
        outLine("READY");
        if (listenPort != 0)
            outLine("LISTEN 127.0.0.1:" ~ to!string(listenPort));
    }
    outLine("aurora-host: renderer=" ~ window.rendererName() ~
        " hardware=" ~ to!string(window.hardwareAccelerated()) ~
        " fallback=" ~ window.rendererFallbackReason());
    const result = window.run();
    if (tcp !is null)
        tcp.stop();
    if (server !is null)
        server.stop();
    return result;
}

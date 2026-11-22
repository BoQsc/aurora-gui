module aurorahost.runtime;

import aurorahost.control : ControlServer;
import aurorahost.events : HostEvent;
import aurorahost.scene : applyScene, describeScene, loadScene, NodeRegistry, Scene;
import aurorahost.tcp_control : TcpControl;
import aurora : GuiWindow;
import std.datetime : SysTime;
import std.file : timeLastModified;
import std.stdio : stderr, stdout, writeln;

private void reportService(string where, Throwable error)
{
    stderr.writeln("aurora-host: " ~ where ~ " failed: " ~ error.msg);
    stderr.flush();
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
        if (stamp <= _stamp)
            return;
        _stamp = stamp;
        try
        {
            const scene = loadScene(_path);
            applyScene(_window, scene, _registry);
            stderr.writeln("reloaded: " ~ describeScene(scene));
            stderr.flush();
        }
        catch (Exception error)
        {
            stderr.writeln("aurora-host: reload failed: " ~ error.msg);
            stderr.flush();
        }
    }
}

/**
 * Run a constructed host window with the optional control channel and scene
 * watcher. This is the one loop shared by the host CLI and embedded hosts.
 */
int runHostWindow(GuiWindow window, NodeRegistry registry, bool control,
    string scenePath, bool watch, ushort listenPort = 0)
{
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
        writeln("READY");
        if (listenPort != 0)
            writeln("LISTEN 127.0.0.1:", listenPort);
        stdout.flush();
    }
    stdout.writeln("aurora-host: renderer=", window.rendererName(),
        " hardware=", window.hardwareAccelerated(),
        " fallback=", window.rendererFallbackReason());
    stdout.flush();
    const result = window.run();
    if (tcp !is null)
        tcp.stop();
    if (server !is null)
        server.stop();
    return result;
}

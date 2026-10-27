module experiment.aurorahost.main;

version (Windows)
    import experiment.aurorahost.crt.msvcrt_shim;

import experiment.aurorahost.control : ControlServer;
import experiment.aurorahost.dev_panel : DevPanel, DevProject;
import experiment.aurorahost.tcp_control : TcpControl;
import experiment.aurorahost.events : HostEvent;
import experiment.aurorahost.protocol : Capabilities, ExperimentVersion,
    NodeTypes, ProtocolVersion, SchemaVersion;
import experiment.aurorahost.scene : applyScene, createWindow, describeScene,
    loadScene, NodeRegistry, Scene;
import aurora.standard.text.unicode.properties : UnicodeDataVersion;
import aurora : GuiWindow;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.datetime : SysTime;
import std.file : exists, getcwd, mkdirRecurse, readText, timeLastModified, write;
import std.path : buildPath, dirName;
import std.stdio : stderr, stdout, writeln;

private enum StarterScene = import("starter.scene.json");

private void usage()
{
    writeln("aurora-host-experiment — isolated Aurora retained-scene host");
    writeln("");
    writeln("  --version");
    writeln("  --capabilities");
    writeln("  --check <scene>");
    writeln("  --render <scene> [--out <file.ppm>]");
    writeln("  --run <scene> [--control] [--watch]");
    writeln("  --dev [scene] [--control] [--listen <port>]");
    writeln("  --run <scene> [--listen <port>]");
}

private string optionValue(string[] args, string name, string fallback)
{
    foreach (index; 0 .. args.length - 1)
        if (args[index] == name)
            return args[index + 1];
    return fallback;
}

private int renderScene(const Scene scene, string outputPath)
{
    auto registry = new NodeRegistry();
    auto window = createWindow(scene, registry);
    registry.refreshSurfaces();
    const parent = dirName(outputPath);
    if (parent.length > 0 && parent != ".")
        mkdirRecurse(parent);
    window.saveScreenshot(outputPath);
    return 0;
}

private class SceneWatcher
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

private int runWindowed(GuiWindow window, NodeRegistry registry, bool control,
    string scenePath, bool watch, ushort listenPort = 0)
{
    ControlServer server;
    if (control || listenPort != 0)
    {
        server = new ControlServer(window, registry, scenePath);
        server.stdoutEnabled(control);
        registry.onActivate = delegate(string id)
        {
            server.eventActivated(id);
        };
        registry.onAction = delegate(string node, string action)
        {
            server.eventAction(node, action);
        };
        registry.onEvent = delegate(HostEvent event)
        {
            server.eventInput(event);
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
                registry.onService(delta);
            if (watcher !is null)
                watcher.poll();
            if (server !is null)
            {
                server.service(delta);
                server.drain();
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
    const result = window.run();
    if (tcp !is null)
        tcp.stop();
    if (server !is null)
        server.stop();
    return result;
}

int main(string[] args)
{
    if (args.length < 2 || args[1] == "--help" || args[1] == "-h")
    {
        usage();
        return args.length < 2 ? 2 : 0;
    }

    try
    {
        ushort listenPort = 0;
        foreach (index, arg; args)
        {
            if (arg == "--listen")
            {
                if (index + 1 >= args.length)
                    throw new Exception("--listen requires a port");
                listenPort = to!ushort(args[index + 1]);
            }
        }
        switch (args[1])
        {
            case "--version":
                writeln("aurora-host-experiment " ~ ExperimentVersion);
                writeln("protocol " ~ to!string(ProtocolVersion) ~
                    " schema " ~ to!string(SchemaVersion));
                writeln("aurora-standard Unicode " ~ UnicodeDataVersion);
                return 0;

            case "--capabilities":
                writeln("capabilities: " ~ join(Capabilities, ", "));
                writeln("node types: " ~ join(NodeTypes, ", "));
                return 0;

            case "--check":
                if (args.length < 3)
                {
                    usage();
                    return 2;
                }
                writeln("scene OK: " ~ describeScene(loadScene(args[2])));
                return 0;

            case "--render":
            {
                if (args.length < 3)
                {
                    usage();
                    return 2;
                }
                const scene = loadScene(args[2]);
                const outputPath = optionValue(args, "--out", "build/scene.ppm");
                const result = renderScene(scene, outputPath);
                writeln("rendered: " ~ describeScene(scene) ~ " -> " ~ outputPath);
                return result;
            }

            case "--run":
                if (args.length < 3)
                {
                    usage();
                    return 2;
                }
            {
                const scene = loadScene(args[2]);
                auto registry = new NodeRegistry();
                auto window = createWindow(scene, registry);
                return runWindowed(window, registry, args.canFind("--control"),
                    args[2], args.canFind("--watch"), listenPort);
            }

            case "--dev":
            {
                string scenePath;
                if (args.length >= 3 && args[2].length > 0 && args[2][0] != '-')
                    scenePath = args[2];
                else
                    scenePath = buildPath(getcwd(), "aurora-scene.json");
                if (!exists(scenePath))
                    write(scenePath, StarterScene);
                const scene = loadScene(scenePath);
                auto registry = new NodeRegistry();
                auto window = createWindow(scene, registry);
                auto project = new DevProject(window, registry, scenePath,
                    StarterScene);
                auto panel = new DevPanel(project, readText(scenePath));
                registry.onAfterApply = delegate()
                {
                    panel.attach(window.root);
                };
                registry.onService = delegate(double delta)
                {
                    panel.service(delta);
                };
                panel.attach(window.root);
                return runWindowed(window, registry, args.canFind("--control"),
                    scenePath, false, listenPort);
            }


            default:
                stderr.writeln("unknown option: " ~ args[1]);
                usage();
                return 2;
        }
    }
    catch (Exception error)
    {
        stderr.writeln("aurora-host: error: " ~ error.msg);
        return 1;
    }
}

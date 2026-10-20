module experiment.aurorahost.main;

import experiment.aurorahost.control : ControlServer;
import experiment.aurorahost.events : HostEvent;
import experiment.aurorahost.protocol : Capabilities, ExperimentVersion,
    NodeTypes, ProtocolVersion, SchemaVersion;
import experiment.aurorahost.scene : createWindow, describeScene, loadScene,
    NodeRegistry, Scene;
import aurora.standard.text.unicode.properties : UnicodeDataVersion;
import aurora : GuiWindow;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : dirName;
import std.stdio : stderr, stdout, writeln;

private void usage()
{
    writeln("aurora-host-experiment — isolated Aurora retained-scene host");
    writeln("");
    writeln("  --version");
    writeln("  --capabilities");
    writeln("  --check <scene>");
    writeln("  --render <scene> [--out <file.ppm>]");
    writeln("  --run <scene> [--control]");
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

private int runWindowed(GuiWindow window, NodeRegistry registry, bool control)
{
    ControlServer server;
    if (control)
    {
        server = new ControlServer(window, registry);
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
        window.applicationService = delegate(double delta)
        {
            server.service(delta);
            server.drain();
        };
        server.start();
        writeln("READY");
        stdout.flush();
    }
    const result = window.run();
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
                return runWindowed(window, registry, args.canFind("--control"));
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

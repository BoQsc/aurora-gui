module aurorahost.main;

version (Windows)
    import aurorahost.crt.msvcrt_shim;

import aurorahost.dev_panel : DevPanel, DevProject;
import aurorahost.protocol : Capabilities, HostVersion,
    NodeTypes, ProtocolVersion, SchemaVersion;
import aurorahost.runtime : runHostWindow;
import aurorahost.scene : createWindow, describeScene,
    loadScene, NodeRegistry, Scene;
import aurora.standard.text.unicode.properties : UnicodeDataVersion;
import aurora : GuiWindow;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, readText, write;
import std.path : buildPath, dirName;
import std.stdio : stderr, stdout, writeln;

pragma(lib, "winmm.lib");
pragma(lib, "avrt.lib");

private extern(Windows) uint timeBeginPeriod(uint);
private extern(Windows) uint timeEndPeriod(uint);
private extern(Windows) void* GetCurrentProcess();
private extern(Windows) void* GetCurrentThread();
private extern(Windows) int SetPriorityClass(void*, uint);
private extern(Windows) int SetThreadPriority(void*, int);
private extern(Windows) void* AvSetMmThreadCharacteristicsW(wchar*, uint*);
private extern(Windows) int AvRevertMmThreadCharacteristics(void*);

private enum StarterScene = import("starter.scene.json");

private void usage()
{
    writeln("aurora-host — isolated Aurora retained-scene host");
    writeln("");
    writeln("  --version");
    writeln("  --capabilities");
    writeln("  --check <scene>");
    writeln("  --render <scene> [--out <file.ppm>]");
    writeln("  --run <scene> [--control] [--watch]");
    writeln("  --dev [scene] [--control] [--listen <port>]");
    writeln("  --run <scene> [--listen <port>]");
    writeln("  (no arguments)  open the starter scene in --dev mode");
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

int runCli(string[] args)
{
    timeBeginPeriod(1);
    scope(exit) timeEndPeriod(1);
    SetPriorityClass(GetCurrentProcess(), 0x80);
    SetThreadPriority(GetCurrentThread(), 2);
    wchar[] avTask = "Games"w.dup;
    uint avIndex;
    void* avHandle = AvSetMmThreadCharacteristicsW(avTask.ptr, &avIndex);
    scope(exit)
        if (avHandle !is null) AvRevertMmThreadCharacteristics(avHandle);
    // A double-click supplies no arguments. Opening the embedded starter in
    // --dev mode is more useful than printing usage to a console that closes
    // immediately with the process. The headless build keeps its usage path.
    if (args.length < 2)
    {
        version (AuroraHeadless)
        {
            usage();
            return 2;
        }
        else
            args ~= "--dev";
    }
    if (args[1] == "--help" || args[1] == "-h")
    {
        usage();
        return 0;
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
                writeln("aurora-host " ~ HostVersion);
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
                auto window = createWindow(scene, registry,
                    args.canFind("--minimized"), args.canFind("--maximized"),
                    args.canFind("--no-activate"));
                return runHostWindow(window, registry, args.canFind("--control"),
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
                return runHostWindow(window, registry, args.canFind("--control"),
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

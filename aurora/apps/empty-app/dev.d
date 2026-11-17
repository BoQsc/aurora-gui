module live_dev;

import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, getcwd, mkdirRecurse, readText, rename, write;
import std.json : JSONValue, toJSON;
import std.path : buildPath, isAbsolute;
import std.process : Pid, kill, spawnProcess, wait;
import std.stdio : stdout;

private string absolutePathOf(string path)
{
    return isAbsolute(path) ? path : buildPath(getcwd(), path);
}

private bool buildLogic(string source, string dll)
{
    auto process = spawnProcess([
        "dmd", "-betterC", "-shared", "-L/NOENTRY",
        "-L/EXPORT:aurora_logic_frame", "-of=" ~ dll, source
    ]);
    return wait(process) == 0;
}

private void stopQuietly(Pid process)
{
    if (process.processID == 0) return;
    try { kill(process); } catch (Exception) {}
    try { wait(process); } catch (Exception) {}
}

private void writeScene(string path, string surface, string title)
{
    auto scene = JSONValue(string[string].init);
    scene.object["schemaVersion"] = JSONValue(2);
    auto window = JSONValue(string[string].init);
    window.object["title"] = JSONValue(title);
    window.object["width"] = JSONValue(320);
    window.object["height"] = JSONValue(272);
    window.object["decorated"] = JSONValue(false);
    scene.object["window"] = window;
    auto root = JSONValue(string[string].init);
    root.object["id"] = JSONValue("root");
    root.object["type"] = JSONValue("column");
    root.object["spacing"] = JSONValue(0);
    root.object["padding"] = JSONValue(0);
    auto bar = JSONValue(string[string].init);
    bar.object["id"] = JSONValue("titlebar");
    bar.object["type"] = JSONValue("titleBar");
    bar.object["text"] = JSONValue(title);
    bar.object["height"] = JSONValue(32);
    bar.object["background"] = JSONValue("#0f172a");
    bar.object["border"] = JSONValue("#1e293b");
    bar.object["textColor"] = JSONValue("#e2e8f0");
    auto node = JSONValue(string[string].init);
    node.object["id"] = JSONValue("module");
    node.object["type"] = JSONValue("surface");
    node.object["path"] = JSONValue(surface);
    node.object["width"] = JSONValue(320);
    node.object["height"] = JSONValue(240);
    node.object["staleMs"] = JSONValue(1000);
    node.object["events"] = JSONValue([JSONValue("pointer")]);
    JSONValue[] children;
    children ~= bar;
    children ~= node;
    root.object["children"] = JSONValue(children);
    scene.object["root"] = root;
    write(path, scene.toJSON());
}

void main(string[] args)
{
    string hostPath = "../../aurora-host/aurora-host.exe";
    string runtimePath = "build/runtime.exe";
    string source = "logic.d";
    string outDir = "build/live-dev";
    int watchSeconds;
    for (size_t i = 0; i < args.length; ++i)
    {
        if (args[i] == "--host" && i + 1 < args.length)
            hostPath = args[++i];
        else if (args[i] == "--runtime" && i + 1 < args.length)
            runtimePath = args[++i];
        else if (args[i] == "--source" && i + 1 < args.length)
            source = args[++i];
        else if (args[i] == "--out" && i + 1 < args.length)
            outDir = args[++i];
        else if (args[i] == "--watch" && i + 1 < args.length)
            watchSeconds = to!int(args[++i]);
    }
    hostPath = absolutePathOf(hostPath);
    runtimePath = absolutePathOf(runtimePath);
    source = absolutePathOf(source);
    const outRoot = absolutePathOf(outDir);
    if (!exists(hostPath)) throw new Exception("missing host: " ~ hostPath);
    if (!exists(runtimePath)) throw new Exception("missing runtime: " ~ runtimePath);
    if (!exists(source)) throw new Exception("missing logic source: " ~ source);
    mkdirRecurse(outRoot);

    const surface = buildPath(outRoot, "live.surface");
    const state = buildPath(outRoot, "live.state.json");
    const signal = buildPath(outRoot, "reload.signal");
    const scene = buildPath(outRoot, "live.scene.json");
    writeScene(scene, surface, "D Live Dev");

    int build = 1;
    auto firstDll = buildPath(outRoot, "logic-1.dll");
    if (!buildLogic(source, firstDll))
        throw new Exception("initial logic build failed");
    auto runtime = spawnProcess([runtimePath, "--surface", surface,
        "--state", state, "--logic", firstDll, "--signal", signal,
        "--seconds", "86400"]);
    scope (exit) stopQuietly(runtime);
    auto host = spawnProcess([hostPath, "--run", scene]);
    scope (exit) stopQuietly(host);

    stdout.writeln("host=", host.processID, " runtime=",
        runtime.processID, " watching ", source);
    stdout.flush();

    auto last = readText(source);
    auto watch = StopWatch(AutoStart.yes);
    while (watchSeconds <= 0 ||
        watch.peek.total!"seconds" < watchSeconds)
    {
        auto current = readText(source);
        if (current != last)
        {
            last = current;
            const next = build + 1;
            auto dll = buildPath(outRoot, "logic-" ~ to!string(next) ~ ".dll");
            if (!buildLogic(source, dll))
            {
                stdout.writeln("[", next, "] build failed; keeping build ",
                    build, " runtime=", runtime.processID);
                stdout.flush();
            }
            else
            {
                auto request = JSONValue(string[string].init);
                request.object["path"] = JSONValue(dll);
                request.object["build"] = JSONValue(next);
                const temporary = signal ~ ".tmp";
                write(temporary, request.toJSON());
                rename(temporary, signal);
                build = next;
                stdout.writeln("[", build, "] reload signal sent runtime=",
                    runtime.processID);
                stdout.flush();
            }
        }
        Thread.sleep(200.msecs);
    }
}

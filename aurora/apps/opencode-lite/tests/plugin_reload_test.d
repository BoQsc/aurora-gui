module plugin_reload_test;

import aurorahost.scene : createWindow, loadScene, NodeRegistry;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;
import opencodelite.pluginloader : LitePlugin;
import std.datetime : Clock;
import std.file : copy, exists, read, remove, setTimes, tempDir,
    timeLastModified, write;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : startsWith;

int main(string[] args)
{
    if (args.length < 3)
    {
        stderr.writeln("usage: plugin-reload-test <scene> <controller.dll>");
        return 2;
    }
    const working = buildPath(tempDir(),
        "aurora-lite-plugin-" ~ Clock.currTime.stdTime.to!string ~ ".dll");
    try
    {
        write(working, read(args[2]));
        auto scene = loadScene(args[1]);
        auto registry = new NodeRegistry();
        auto window = createWindow(scene, registry);
        auto plugin = new LitePlugin(registry, working);
        const initial = registry.text("lite-status");
        if (initial != "Ready")
        {
            stderr.writeln("initial plugin status: " ~ initial);
            window.close();
            return 1;
        }
        const originalStamp = timeLastModified(working);

        write(working, "not a controller dll");
        Thread.sleep(30.msecs);
        registry.onService(0.016);
        const broken = registry.text("lite-status");

        write(working, read(args[2]));
        setTimes(working, originalStamp, originalStamp);
        Thread.sleep(30.msecs);
        registry.onService(0.016);
        const restored = registry.text("lite-status");
        writeln("broken=", broken);
        writeln("restored=", restored);
        window.close();
        return broken.startsWith("Controller error") && restored == "Ready"
            ? 0 : 1;
    }
    finally
    {
        if (exists(working))
            remove(working);
    }
}

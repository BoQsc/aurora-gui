module plugin_smoke;

import aurorahost.scene : createWindow, loadScene, NodeRegistry;
import opencodelite.pluginloader : LitePlugin;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    if (args.length < 3)
    {
        stderr.writeln("usage: plugin-smoke <scene> <controller.dll>");
        return 2;
    }
    auto scene = loadScene(args[1]);
    auto registry = new NodeRegistry();
    auto window = createWindow(scene, registry);
    auto plugin = new LitePlugin(registry, args[2]);
    const status = registry.text("lite-status");
    writeln("status=", status);
    window.close();
    return status == "Ready" ? 0 : 1;
}

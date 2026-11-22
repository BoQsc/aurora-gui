module live_smoke;

import aurora : GuiWindow;
import aurorahost.scene : applyScene, createWindow, loadScene, NodeRegistry;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import opencodelite.controller : LiteController;
import opencodelite.registryview : RegistryLiteView;
import opencodelite.settings : LiteSettings;
import std.file : remove, tempDir;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : indexOf, strip;

private bool waitFor(NodeRegistry registry, string needle, double secondsLeft)
{
    const deadline = MonoTime.currTime + seconds(cast(long) secondsLeft);
    while (MonoTime.currTime < deadline)
    {
        registry.onService(0.01);
        if (registry.text("lite-transcript").indexOf(needle) >= 0)
            return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

int main(string[] args)
{
    if (args.length < 4)
    {
        stderr.writeln("usage: live-smoke <sse-url> <scene-a> <scene-b>");
        return 2;
    }
    // Keep the test settings out of the real user profile.
    environment["APPDATA"] = tempDir();

    LiteSettings settings;
    settings.baseUrl = args[1];
    settings.model = "mock";
    auto registry = new NodeRegistry();
    auto controller = new LiteController(new RegistryLiteView(registry), settings);
    registry.onAction = &controller.handleAction;
    registry.onService = &controller.service;
    registry.onAfterApply = &controller.refreshView;
    auto scene = loadScene(args[2]);
    auto window = createWindow(scene, registry);
    controller.refreshView();

    registry.setText("lite-input", "hello");
    registry.dispatchAction("lite-send", "send");
    if (!waitFor(registry, "Hello", 10))
    {
        stderr.writeln("live-smoke: first delta did not arrive");
        window.close();
        return 1;
    }

    // Simulate editing the scene while the stream is still in flight.
    const reloaded = loadScene(args[3]);
    applyScene(window, reloaded, registry);
    controller.refreshView();

    if (!waitFor(registry, "Hello world", 15))
    {
        stderr.writeln("live-smoke: stream did not survive scene reload");
        window.close();
        return 1;
    }
    registry.onService(0.05);
    const transcript = registry.text("lite-transcript");
    const status = registry.text("lite-status");
    writeln("transcript=", transcript.strip);
    writeln("status=", status);
    window.close();
    return transcript.indexOf("Hello world") >= 0 && status == "Complete"
        ? 0 : 1;
}

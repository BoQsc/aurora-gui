module startup_responsiveness_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    const state = absolutePath("startup-responsive-state");
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options; options.width = 900; options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Preserve this", "Accepted answer"]);
    root.persistForTesting();
    auto entered = new Semaphore(), release = new Semaphore();
    assert(root.queueRepositoryWorkForTesting({ entered.notify(); release.wait(); }));
    entered.wait();
    auto rescue = new Thread({ Thread.sleep(2000.msecs); release.notify(); });
    rescue.start();
    scope(exit) rescue.join();
    const started = MonoTime.currTime;
    root.reloadStartupAsyncForTesting();
    foreach (i; 0 .. 650)
    {
        root.tickTree(0.001);
        if (i % 100 == 0) assert(driver.paint());
    }
    const elapsed = (MonoTime.currTime - started).total!"msecs";
    assert(elapsed < 1000, "Startup timeout fell back to blocking journal I/O");
    assert(root.startupPendingForTesting() && !root.sendEnabledForTesting(),
        "Pending recovery allowed a request with incomplete history");
    release.notify();
    const restored = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < restored)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    assert(root.lastAssistantContentForTesting() == "Accepted answer");
    assert(driver.paint());
    writeln("PASS 650 recovery ticks remain responsive behind stalled storage; elapsed_ms=", elapsed,
        "; accepted history restored before Send");
    window.close();
    return 0;
}

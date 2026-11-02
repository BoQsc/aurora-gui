module exit_checkpoint_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write, readText, rmdir;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    const state = absolutePath("exit-checkpoint-state");
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","apiKey":"fixture","model":"fixture","toolsEnabled":false,"quickTitle":false}`);
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
    root.setInputForTesting("Unsent draft survives restart");
    root.persistForTesting();

    void waitCheckpoint()
    {
        const deadline = MonoTime.currTime + 5.seconds;
        while (root.exitCheckpointPendingForTesting() && MonoTime.currTime < deadline)
        { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
        assert(!root.exitCheckpointPendingForTesting());
    }

    foreach (snapshotOwner; [false, true])
    {
        auto entered = new Semaphore(), release = new Semaphore();
        auto stall = { entered.notify(); release.wait(); };
        assert(snapshotOwner ? root.queueSnapshotWorkForTesting(stall) : root.queueRepositoryWorkForTesting(stall));
        entered.wait();
        auto rescue = new Thread({ Thread.sleep(1500.msecs); release.notify(); });
        rescue.start();
        scope(exit) rescue.join();
        bool launched;
        const started = MonoTime.currTime;
        assert(root.beginExitCheckpointForTesting({
            assert(readText(buildPath(state, "threads.index.json")).indexOf("Unsent draft survives restart") >= 0);
            launched = true;
            throw new Exception("Fixture helper unavailable");
        }));
        foreach (i; 0 .. 100)
        {
            window.onNativeTick(0.001);
            if (i % 10 == 0) assert(driver.paint());
        }
        const elapsed = (MonoTime.currTime - started).total!"msecs";
        assert(elapsed < 1000 && root.exitCheckpointPendingForTesting() && !launched,
            "Exit waited on storage or launched its effect before saving");
        release.notify();
        waitCheckpoint();
        assert(launched && root.exitCheckpointFailedForTesting() && root.enabled());
        assert(root.lastAssistantContentForTesting() == "Accepted answer");
        writeln("PASS responsive exit behind ", snapshotOwner ? "snapshot" : "journal", " owner; elapsed_ms=", elapsed);
    }

    // A physical snapshot failure must never launch the replacement helper.
    const badTemporary = buildPath(state, "threads.index.json.tmp");
    mkdirRecurse(badTemporary);
    bool launched;
    assert(root.beginExitCheckpointForTesting({ launched = true; }));
    waitCheckpoint();
    assert(root.exitCheckpointFailedForTesting() && !launched && root.enabled());
    rmdir(badTemporary);
    assert(root.beginExitCheckpointForTesting());
    waitCheckpoint();
    assert(root.exitCheckpointCommittedForTesting());
    assert(readText(buildPath(state, "threads.index.json")).indexOf("Unsent draft survives restart") >= 0);
    writeln("PASS failed snapshots gate helper launch; recovery closes only after a durable final snapshot");
    return 0;
}

module provider_roundtrip;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.opencode_client : OpenCodeClient, ChatStartResult, OpenCodeEvent;
import auroraopencode.workerbudget : WorkerBudget;
import auroraopencode.retrypolicy : ProviderRetryPolicy;
import auroraopencode.core : Settings, saveSettings, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, readText;
import std.path : buildPath, absolutePath;
import std.process : environment;
import std.stdio : writeln;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run with test_provider_roundtrip.py");
    const directory = absolutePath("roundtrip-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    const state = buildPath(directory, "state");
    mkdirRecurse(workspace);
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base;
    settings.apiKey = "local-fixture";
    settings.model = "fixture";
    settings.workspace = workspace;
    settings.toolsEnabled = true;
    settings.legacyTools = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    root.newChatForTesting();
    root.setInputForTesting("Write out.txt containing success, verify its contents with unittest, then reply READY.");
    root.sendForTesting();
    const deadline = MonoTime.currTime + 30.seconds;
    while (MonoTime.currTime < deadline)
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        if (!root.turnBusyForTesting() && root.lastAssistantContentForTesting() == "READY")
            break;
        Thread.sleep(10.msecs);
    }
    assert(!root.turnBusyForTesting() && root.lastAssistantContentForTesting() == "READY",
        "Round trip did not settle: " ~ root.lastAssistantContentForTesting());
    assert(readText(buildPath(workspace, "out.txt")) == "success");
    assert(root.verificationStatusForTesting() == "passed");
    assert(root.taskStatusForTesting() == "completed");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.lastAssistantContentForTesting() == "READY");
    writeln("PASS composer -> HTTP/SSE -> plan/write/run -> verification -> final UI -> persisted reload");
    auto budget = new WorkerBudget(2);
    long worstCancelMs;
    foreach (_; 0 .. 12)
    {
        auto client = new OpenCodeClient(base, "local-fixture",
            ProviderRetryPolicy(1.seconds), budget);
        assert(client.startChatMessages(null, null, "cancel-fixture", false) ==
            ChatStartResult.accepted);
        const first = MonoTime.currTime + 5.seconds;
        OpenCodeEvent[] pending;
        bool received;
        while (!received && MonoTime.currTime < first)
        {
            client.drain(pending);
            foreach (event; pending) if (event.text == "partial") received = true;
            if (!received) Thread.sleep(5.msecs);
        }
        assert(received);
        const cancelStarted = MonoTime.currTime;
        client.cancel();
        client.closeSession();
        const elapsed = (MonoTime.currTime - cancelStarted).total!"msecs";
        if (elapsed > worstCancelMs) worstCancelMs = elapsed;
        assert(elapsed < 1000, "Cancellation blocked the caller for more than a second");
        const closed = MonoTime.currTime + 2.seconds;
        while (budget.active() && MonoTime.currTime < closed) Thread.sleep(5.msecs);
        assert(budget.active() == 0, "Canceled HTTP worker retained a physical slot");
    }
    writeln("PASS twelve actual stalled-stream cancellations; worst_cancel_ms=", worstCancelMs);

    return 0;
}

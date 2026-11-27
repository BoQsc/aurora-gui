module provider_roundtrip;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.opencode_client : OpenCodeClient, ChatStartResult, OpenCodeEvent;
import auroraopencode.workerbudget : WorkerBudget;
import auroraopencode.retrypolicy : ProviderRetryPolicy;
import auroraopencode.latency : LatencyStage;
import auroraopencode.core : Settings, saveSettings, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, readText, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : startsWith;

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run with test_provider_roundtrip.py");
    // Keep the fixture's scratch checkout outside the live Aurora checkout: a
    // checked parent command already holds that checkout lease, and sharing it
    // made the fixture's own tools wait until their deadline.
    const directory = buildPath(tempDir(),
        "roundtrip-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(directory, "workspace");
    const state = buildPath(directory, "state");
    mkdirRecurse(workspace);
    mkdirRecurse(state);
    // Declare a scratch developer source for this image. Otherwise the fixture
    // resolves the live checkout from its executable path and leases it too.
    const scratchSource = buildPath(state, "source", "aurora-gui");
    mkdirRecurse(buildPath(scratchSource, "source"));
    write(buildPath(scratchSource, "source", "app.d"), "");
    write(buildPath(scratchSource, "dub.json"), `{"name":"aurora-opencode-pro"}`);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base;
    settings.apiKey = "local-fixture";
    settings.model = "fixture";
    settings.workspace = workspace;
    settings.toolsEnabled = true;
    settings.legacyTools = false;
    settings.quickTitle = true;
    settings.developerSourceDir = scratchSource;
    const stalledGoal = environment.get("AURORA_CONTRACT_GOAL_STALL", "") == "1";
    const auditStall = environment.get("AURORA_CONTRACT_GOAL_AUDIT_STALL", "") == "1";
    const completeGoal = environment.get("AURORA_CONTRACT_COMPLETE_GOAL", "") == "1";
    settings.autoGoalFromFirstMessage = stalledGoal || auditStall || completeGoal;
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
    int proseTurns()
    {
        int count;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageRoleForTesting(i) == "assistant" &&
                root.messageContentForTesting(i).startsWith("READY"))
                ++count;
        return count;
    }
    // A persistent goal never settles after a prose-only turn. The fixture
    // therefore waits for more prose turns than the old three-recovery stop and
    // checks that the goal is still running, then stops it explicitly.
    const goalAuditFixture = stalledGoal || auditStall;
    const deadline = MonoTime.currTime + 30.seconds;
    bool reachedAuditLimit;
    while (MonoTime.currTime < deadline)
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        if (goalAuditFixture)
        {
            if (root.turnBusyForTesting() && proseTurns() >= 6)
            {
                assert(root.goalStatusForTesting() == "active",
                    "The active goal was paused while it still owned its work");
                assert(root.failedMessageCountForTesting() == 0,
                    "A prose-only goal turn surfaced a failure row");
                assert(root.taskStatusForTesting() != "completed",
                    "A stalled goal fabricated completion of its work");
                reachedAuditLimit = true;
                break;
            }
            if (!root.turnBusyForTesting()) break;
            Thread.sleep(10.msecs);
            continue;
        }
        if (!root.turnBusyForTesting() &&
            root.lastAssistantContentForTesting() == "READY")
            break;
        Thread.sleep(10.msecs);
    }
    if (goalAuditFixture)
    {
        assert(reachedAuditLimit,
            "The active goal stopped before six prose-only turns: " ~
            root.lastAssistantContentForTesting());
        root.stopActiveTurnForTesting();
        const stopDeadline = MonoTime.currTime + 5.seconds;
        while (root.turnBusyForTesting() && MonoTime.currTime < stopDeadline)
        {
            window.onNativeTick(0.02);
            root.projectTranscriptForTesting();
            Thread.sleep(10.msecs);
        }
        assert(readText(buildPath(workspace, "out.txt")) == "success");
        assert(root.verificationStatusForTesting() == "passed");
        writeln("PASS active goal ran past the old recovery limit and stayed active until stopped");
        return 0;
    }
    assert(!root.turnBusyForTesting() &&
        root.lastAssistantContentForTesting() == "READY",
        "Round trip did not settle: " ~ root.lastAssistantContentForTesting());
    assert(readText(buildPath(workspace, "out.txt")) == "success");
    assert(root.verificationStatusForTesting() == "passed");
    assert(root.taskStatusForTesting() == "completed");
    if (completeGoal) assert(root.goalStatusForTesting() == "completed",
        "Verified completion was blocked by a stale advisory plan");
    const latency = root.latencyPaintForTesting();
    assert(latency.microseconds[LatencyStage.firstToken] >= 0 &&
        latency.microseconds[LatencyStage.applied] >= latency.microseconds[LatencyStage.firstToken] &&
        latency.microseconds[LatencyStage.paintSubmitted] >= latency.microseconds[LatencyStage.applied],
        "Request trace did not follow its first token into a completed render submission");
    writeln("client_first_token_to_apply_us=",
        latency.microseconds[LatencyStage.applied] - latency.microseconds[LatencyStage.firstToken],
        " client_apply_to_paint_us=",
        latency.microseconds[LatencyStage.paintSubmitted] - latency.microseconds[LatencyStage.applied]);
    const titleDeadline = MonoTime.currTime + 3.seconds;
    while (root.sessionTitleForTesting(root.currentSessionForTesting()) != "Fixture" &&
        MonoTime.currTime < titleDeadline)
    {
        window.onNativeService();
        Thread.sleep(5.msecs);
    }
    assert(root.sessionTitleForTesting(root.currentSessionForTesting()) == "Fixture",
        "Deferred optional title did not run after foreground work completed");
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

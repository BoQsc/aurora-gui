module auroraopencode_pro_queued_approval_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

int main()
{
    const stateDir = buildPath(tempDir(),
        "aurora-opencode-pro-queued-approval-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode Pro queued approval contracts";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    const startupDeadline = Clock.currTime + 5.seconds;
    while (root.startupPendingForTesting() && Clock.currTime < startupDeadline)
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    assert(!root.startupPendingForTesting(), "startup history did not finish");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Analyze the parser failure."]);
    root.setTaskStateForTesting("Analyze the parser failure.", "active",
        "not_required");

    // Action requests typed during a live turn are queued guidance. When
    // injected, they must retarget the durable task to implementation.
    foreach (approval; ["do it", "Please do it."])
    {
        root.setTaskIntentForTesting("analysis", "analysis");
        root.queueGuidanceForTesting(approval);
        assert(root.consumeGuidanceForTesting(),
            "queued approval was not injected: " ~ approval);
        assert(root.taskCurrentIntentForTesting() == "implementation",
            "queued approval did not authorize implementation: " ~ approval);
    }

    root.setTaskIntentForTesting("analysis", "analysis");
    root.queueGuidanceForTesting("What failed in the parser?");
    assert(root.consumeGuidanceForTesting());
    assert(root.taskCurrentIntentForTesting() != "implementation",
        "a queued question authorized implementation");
    assert(root.taskObjectiveForTesting() == "Analyze the parser failure.",
        "queued approval replaced the task objective");

    writeln("PASS queued approvals authorize implementation after analysis");
    return 0;
}
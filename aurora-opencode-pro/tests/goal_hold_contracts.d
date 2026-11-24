module goal_hold_contracts;

// Progress audits recover and never paint a failure row. An active goal is
// never parked: a goal that keeps answering without a useful action receives an
// escalated directive and keeps running until it validates complete or the
// user pauses it. The reported chat replied "pause the active goal, this
// session cannot call goal_complete" on every retry; the app must not adopt
// that refusal as its own stop.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, OpenCodeToolCall,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, replace;

int main()
{
    const state = buildPath(tempDir(),
        "aurora-goal-hold-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    write(buildPath(workspace, "note.txt"), "readable note");
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture",` ~
        `"model":"fixture","toolsEnabled":true,"workspace":` ~
        `"` ~ workspace.replace("\\", "\\\\") ~ `"}`);
    WindowOptions options;
    options.width = 900;
    options.height = 640;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(2.msecs);
    }
    assert(!root.startupPendingForTesting(), "Conversation startup did not settle");

    void pump()
    {
        window.onNativeTick(0.02);
        Thread.sleep(2.msecs);
    }
    foreach (issue; ["goal_audit_stalled", "task_audit_stalled"])
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"], ["Finish the parser fix", "It is done."]);
        root.setGoalForTesting("Finish the parser fix", "active");
        root.setTaskStateForTesting("Finish the parser fix", "active", "required");
        root.applyPlanForTesting(`{"plan":[{"step":"Verify the fix","status":"in_progress"}]}`);
        root.pauseToolContinuationForTesting();
        root.startTurnClockForTesting();
        root.injectOutputFailureForTesting(issue);
        assert(root.goalStatusForTesting() == "active" && root.turnStatusForTesting() == "running",
            "An unfinished task/goal silently paused instead of recovering");
        assert(root.taskStatusForTesting() == "active" && root.failedMessageCountForTesting() == 0,
            "Recoverable no-action output lost the task or created a failure bubble");
        bool recovery;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf("Agent output recovery:") >= 0) recovery = true;
        assert(recovery);
        foreach (_; 0 .. 6)
        {
            root.addConversationForTesting(["assistant"], ["Still done without a check."]);
            root.startTurnClockForTesting();
            root.injectOutputFailureForTesting(issue);
            assert(root.goalStatusForTesting() == "active",
                "A repeated goal audit paused the user's goal");
            assert(root.turnStatusForTesting() == "running",
                "A repeated goal audit left the active goal idle");
        }
        assert(root.taskStatusForTesting() != "completed",
            "Repeated recovery fabricated completion of the unfinished task");
        assert(root.failedMessageCountForTesting() == 0,
            "Repeated recovery painted a failure over the delivered answer");
        bool visible;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf("Agent output stalled") >= 0) visible = true;
        assert(!visible, "Repeated recovery leaked a failure notice into the transcript");
        pump();
    }
    writeln("PASS goal audits keep recovering without a failure row or a goal pause");
    return 0;
}

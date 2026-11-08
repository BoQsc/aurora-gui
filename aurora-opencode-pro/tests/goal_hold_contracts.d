module goal_hold_contracts;

// An audit hold ends automatic continuation. It must not leave the persistent
// goal advertising itself as active while no turn runs, and an explicit Start
// must clear the hold instead of re-recording the work as blocked one settle
// later. Both cases were observed in saved conversations as "the goal is active
// but the chat was not continued".

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
    void holdOnActiveGoal(string issue)
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"],
            ["continue the work", "I will."]);
        root.setGoalForTesting("continue the work", "active");
        root.setTaskStateForTesting("continue the work", "active", "not_required");
        root.applyPlanForTesting(
            `{"plan":[{"step":"Finish the work","status":"in_progress"}]}`);
        root.pauseToolContinuationForTesting();
        root.startTurnClockForTesting();
        root.injectOutputFailureForTesting(issue);
    }

    // A prose-only goal continuation is first repaired, not stopped: the goal
    // may already be finished and merely unrecorded, and pausing it there is the
    // "goal is partially completed with limitations and remaining work" state.
    // One completion audit turn must ask for `goal_complete` or further work.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"],
            ["fix the parser crash", "Result: patched.\nRemaining: the suite is unverified."]);
        root.setGoalForTesting("fix the parser crash", "active");
        root.setTaskStateForTesting("fix the parser crash", "active", "not_required");
        root.applyPlanForTesting(
            `{"plan":[{"step":"Fix the parser crash","status":"in_progress"}]}`);
        root.addInternalNoteForTesting("Persistent goal continuation: fix the parser crash");
        root.startTurnClockForTesting();
        root.injectOutputFailureForTesting("goal_audit_stalled");
        bool audit;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf(
                "Persistent goal completion audit:") >= 0) audit = true;
        assert(audit, "a prose-only goal continuation was stopped without its completion audit");
        assert(root.goalStatusForTesting() == "active",
            "the completion audit paused the goal it was still repairing: "
            ~ root.goalStatusForTesting());
        assert(root.goalHistoryOutcomesForTesting()[$ - 1] == "active",
            "the completion audit recorded a settled outcome while the goal kept working");
        assert(!root.auditHoldForTesting(),
            "the completion audit held automatic continuation immediately");
        assert(root.failedMessageCountForTesting() == 0,
            "the completion audit surfaced a failure row");
        root.stopActiveTurnForTesting();
        pump();
        writeln("PASS a prose-only goal continuation gets one completion audit, not a pause");
    }

    // The hold itself: hidden, no recovery round, unfinished work kept, and the
    // goal paused so the bar never claims an active goal that is not running.
    foreach (issue; ["goal_audit_stalled", "task_audit_stalled"])
    {
        holdOnActiveGoal(issue);
        bool recovery;
        foreach (i; 0 .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf("Agent output recovery:") >= 0)
                recovery = true;
        assert(!recovery, issue ~ " launched a no-action recovery round");
        assert(root.failedMessageCountForTesting() == 0,
            issue ~ " surfaced a failure row");
        assert(root.taskStatusForTesting() == "active", issue ~ " dropped the work");
        assert(root.auditHoldForTesting(), issue ~ " did not hold continuation");
        assert(root.goalStatusForTesting() == "paused",
            issue ~ " left the goal claiming to be active with no running turn");
        assert(root.turnStatusForTesting() == "idle",
            issue ~ " left a phantom running turn");
        assert(root.goalHistoryOutcomesForTesting()[$ - 1] == "paused",
            issue ~ " did not record the goal as paused");

        // Start is the explicit way back: it clears the hold and appends the
        // goal continuation, so the chat continues instead of staying stopped.
        const before = root.totalMessageCountForTesting();
        root.resumeGoalForTesting();
        assert(!root.auditHoldForTesting(),
            issue ~ " hold survived an explicit goal resume");
        assert(root.goalStatusForTesting() == "active",
            issue ~ " Start did not reactivate the goal");
        assert(root.totalMessageCountForTesting() > before,
            issue ~ " Start did not continue the chat");
        bool continued;
        foreach (i; before .. root.totalMessageCountForTesting())
            if (root.messageContentForTesting(i).indexOf(
                "Persistent goal continuation:") >= 0) continued = true;
        assert(continued, issue ~ " Start appended no goal continuation");
        root.stopActiveTurnForTesting();
        pump();
    }
    writeln("PASS an audit hold pauses the active goal, keeps the work and Start continues it");


    // Whatever the hold does later, a settle must never leave the conversation
    // in the reported state: goal active with nothing running.
    holdOnActiveGoal("goal_audit_stalled");
    root.setGoalForTesting("continue the work", "active");
    root.setTaskStateForTesting("continue the work", "active", "not_required");
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    assert(root.turnBusyForTesting() || root.goalStatusForTesting() != "active",
        "settling left an active goal with no running turn: task=" ~
        root.taskStatusForTesting() ~ " turn=" ~ root.turnStatusForTesting());
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS no settle leaves an active goal with a stopped chat");

    // A turn that recorded useful tool evidence has left the stalled interval,
    // so the earlier hold must not veto its continuation. The tool result is
    // appended through the same message path the scheduler uses.
    holdOnActiveGoal("goal_audit_stalled");
    root.setGoalForTesting("continue the work", "active");
    root.setTaskStateForTesting("continue the work", "active", "not_required");
    root.addConversationForTesting(["tool"], ["Read note.txt: readable note"]);
    const before = root.totalMessageCountForTesting();
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    assert(root.totalMessageCountForTesting() > before,
        "a completed hold vetoed the continuation of a turn with useful tool evidence: "
        ~ root.taskStatusForTesting() ~ "/" ~ root.turnStatusForTesting());
    root.stopActiveTurnForTesting();
    writeln("PASS useful work after a hold continues the chat");
    writeln("goal hold contracts passed");
    return 0;
}

module goal_settle_ui_contracts;

// A settled turn must never leave an active goal with nothing running. The
// reported state was "the goal keeps stopping without reaching the goal, the
// goal is active but doing nothing": an answered question or side investigation
// inside a goal thread held the continuation forever, and an answer-shaped goal
// was never closed after its reply.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, toLower;
import std.utf : toUTF8;

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

int main()
{
    const state = buildPath(tempDir(),
        "aurora-goal-settle-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture",` ~
        `"model":"fixture","toolsEnabled":true}`);
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
    void pump(int ticks = 12)
    {
        foreach (_; 0 .. ticks)
        {
            window.onNativeTick(0.02);
            Thread.sleep(2.msecs);
        }
    }

    // An answer-shaped goal is finished by its delivered reply: it completes
    // instead of staying active with no turn running.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Why did the goal stop?", "Because the settle left it active."]);
    root.setGoalForTesting("Why did the goal stop?", "active");
    root.setTaskStateForTesting("Why did the goal stop?", "active", "not_required");
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    assert(!root.turnBusyForTesting(), "an answered goal left a running turn");
    assert(root.goalStatusForTesting() == "completed",
        "an answered goal stayed active with no running turn: task=" ~
        root.taskStatusForTesting() ~ " turn=" ~ root.turnStatusForTesting());
    assert(root.goalHistoryOutcomesForTesting()[$ - 1] == "completed",
        "the completed answer goal was not recorded in goal history");
    // The painted goal row must show that outcome, not a stale "active".
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "goal row paint failed after the goal completed");
    assert(toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()).toLower()
        .indexOf("complete") >= 0,
        "the goal row still did not show the completed goal: " ~
        toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()));
    writeln("PASS an answered goal completes instead of idling as active");

    // An explicit restriction keeps the goal's work. The agent's turn settling
    // must not pause the goal: only the user pauses, and Continue is the way
    // back while the work stays active.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Just explain the failure. Do not edit anything.", "The step was never recorded."]);
    root.setGoalForTesting("Fix the parser crash", "active");
    root.setTaskStateForTesting("Fix the parser crash", "active", "not_required");
    root.applyPlanForTesting(
        `{"plan":[{"step":"Fix the parser crash","status":"in_progress"}]}`);
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    assert(!root.turnBusyForTesting(), "the restricted turn kept running");
    assert(root.goalStatusForTesting() == "active",
        "the agent paused a goal the user had not paused");
    assert(root.taskStatusForTesting() == "active",
        "the restricted settle dropped the goal's work");
    assert(root.goalHistoryOutcomesForTesting()[$ - 1] == "active",
        "the settle rewrote the goal's recorded outcome");
    assert(driver.paint(), "goal row paint failed after the restricted settle");
    assert(toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()).toLower()
        .indexOf("active") >= 0,
        "the goal row did not show the goal as active: " ~
        toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()));
    assert(toUTF8(requireWidget!Label(root, "oc-goal-text").text()).indexOf(
        "Fix the parser crash") >= 0,
        "the active goal lost the user's completion condition");
    writeln("PASS an explained goal stays active; only the user pauses it");

    // Reported: the goal continuation was answered with prose only while a
    // checklist outcome and verification remained. The app must spend a bounded
    // recovery turn on real work and must not pause the user's goal.
    root.newChatForTesting();
    const stalledGoal = "Reach 100% stable 60 fps while moving the camera.";
    root.addConversationForTesting(["user", "assistant"], [stalledGoal, "I will."]);
    root.addInternalNoteForTesting("Persistent goal continuation: " ~ stalledGoal);
    root.addConversationForTesting(["assistant"],
        ["The last change is live; the strict target remains open."]);
    root.setGoalForTesting(stalledGoal, "active");
    root.setTaskIntentForTesting("implementation", "analysis");
    root.setTaskStateForTesting(stalledGoal, "active", "required");
    root.applyPlanForTesting(
        `{"plan":[{"step":"Reach the strict target","status":"in_progress"}]}`);
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    bool recovered;
    foreach (i; 0 .. root.totalMessageCountForTesting())
        if (root.messageContentForTesting(i).indexOf("Agent output recovery:") >= 0)
            recovered = true;
    assert(recovered, "a stalled goal continuation did not get a recovery turn");
    assert(root.turnBusyForTesting(), "the stalled goal recovery did not keep running");
    assert(root.goalStatusForTesting() == "active",
        "the app paused a goal the user had not paused: task=" ~
        root.taskStatusForTesting() ~ " turn=" ~ root.turnStatusForTesting());
    assert(root.goalHistoryOutcomesForTesting()[$ - 1] == "active",
        "the goal recovery rewrote the goal's recorded outcome");
    assert(driver.paint(), "goal row paint failed after the goal recovery");
    assert(toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()).toLower()
        .indexOf("active") >= 0,
        "the goal row did not show the recovering goal as active: " ~
        toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()));
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a stalled goal continuation recovers without pausing the goal");

    // A question answered inside an action goal no longer ends it: the goal
    // continues and the turn stays busy.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["What is left?", "Two outcomes remain."]);
    root.setGoalForTesting("Fix the parser crash", "active");
    root.setTaskStateForTesting("Fix the parser crash", "active", "not_required");
    root.applyPlanForTesting(
        `{"plan":[{"step":"Fix the parser crash","status":"in_progress"}]}`);
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    pump();
    bool continued;
    foreach (i; 0 .. root.totalMessageCountForTesting())
        if (root.messageContentForTesting(i).indexOf("Persistent goal continuation:") >= 0)
            continued = true;
    assert(continued, "an answered question inside the goal stopped it");
    assert(root.goalStatusForTesting() == "active",
        "the continuing goal was not left active: " ~ root.goalStatusForTesting());
    assert(driver.paint(), "goal row paint failed for the continuing goal");
    assert(toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()).toLower()
        .indexOf("active") >= 0,
        "the goal row did not show the running goal: " ~
        toUTF8(requireWidget!Label(root, "oc-goal-prefix").text()));
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a question inside an action goal keeps the goal running");

    writeln("goal settle UI contracts passed");
    return 0;
}

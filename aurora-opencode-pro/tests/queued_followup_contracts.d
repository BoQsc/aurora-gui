module auroraopencode_pro_queued_followup_contracts;

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
        "aurora-opencode-pro-queued-followup-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode Pro queued follow-up contracts";
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

    // An explicit queued follow-up must not end authorized work early. While
    // the plan is unfinished the agent continues, exactly as it would with no
    // message queued, and the pending message waits.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Implement and verify the feature."]);
    root.setTaskStateForTesting("Implement and verify the feature.", "active",
        "not_required");
    root.applyPlanForTesting(
        `{"plan":[{"step":"Implement the feature","status":"in_progress"},` ~
        `{"step":"Verify the feature","status":"pending"}]}`);
    root.queueFollowUpForTesting("Plan the next release.");
    root.projectTranscriptForTesting();
    assert(root.queuedFollowUpCountForTesting() == 1 &&
        root.queuedPromptBubbleCountForTesting() == 1,
        "the queued follow-up was not shown as pending");
    root.startTurnClockForTesting();
    assert(root.completionWouldContinueForTesting(),
        "a queued follow-up settled unfinished work instead of continuing it");
    root.settleTaskAfterDoneForTesting();
    assert(root.turnBusyForTesting() && root.queuedFollowUpCountForTesting() == 1,
        "the queued follow-up was sent while the agent still had work: busy=" ~
        (root.turnBusyForTesting() ? "yes" : "no") ~ " queue=" ~
        (root.queuedFollowUpCountForTesting() ? "1" : "0"));
    root.stopActiveTurnForTesting();
    assert(root.queuedFollowUpCountForTesting() == 1,
        "the queued follow-up was consumed before the work finished");

    // Completing the planned work stops the chat. Only then does the queued
    // follow-up open as the next turn.
    root.setTaskStateForTesting("Implement and verify the feature.", "active",
        "not_required");
    root.applyPlanForTesting(
        `{"plan":[{"step":"Implement the feature","status":"completed"},` ~
        `{"step":"Verify the feature","status":"completed"}]}`);
    root.setTaskStateForTesting("Implement and verify the feature.", "completed",
        "passed");
    assert(!root.completionWouldContinueForTesting(),
        "completed work still reported a scheduled continuation");
    root.startTurnClockForTesting();
    root.settleTaskAfterDoneForTesting();
    assert(root.queuedFollowUpCountForTesting() == 0 &&
        root.lastSubmittedUserMessageForTesting() == "Plan the next release." &&
        root.turnBusyForTesting(),
        "the queued follow-up did not start when the chat stopped: queue=" ~
        (root.queuedFollowUpCountForTesting() ? "1" : "0") ~ " user=" ~
        root.lastSubmittedUserMessageForTesting());
    root.stopActiveTurnForTesting();

    // A plain chat has no scheduled continuation, so its queued message is
    // sent on the first stop.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Hello there."]);
    root.startTurnClockForTesting();
    root.queueFollowUpForTesting("Summarize this chat.");
    assert(!root.completionWouldContinueForTesting(),
        "a plain answer manufactured a continuation");
    root.settleTaskAfterDoneForTesting();
    assert(root.queuedFollowUpCountForTesting() == 0 &&
        root.lastSubmittedUserMessageForTesting() == "Summarize this chat.",
        "a plain chat did not send its queued follow-up on stop");
    root.stopActiveTurnForTesting();

    writeln("PASS queued follow-ups wait for the chat stop and then open");
    return 0;
}

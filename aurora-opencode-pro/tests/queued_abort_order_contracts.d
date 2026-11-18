module auroraopencode_pro_queued_abort_order_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.outputguard : outputRecoveryMarker;
import auroraopencode.outputrecovery : maxOutputRecoveries;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

/// A steering prompt typed during a turn belongs to that turn. Both terminal
/// output aborts must drain it before a queued follow-up opens the next turn,
/// or the later-typed follow-up lands above earlier steering text.
int main()
{
    const stateDir = buildPath(tempDir(),
        "aurora-opencode-pro-queued-abort-order-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode Pro queued abort order contracts";
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

    int indexOf(string content)
    {
        foreach (i; 0 .. root.messageCountForTesting())
            if (root.messageContentForTesting(i) == content) return i;
        return -1;
    }

    // The terminal abort branch is chosen only once the shared recovery budget
    // is spent; seed it exactly as the recovery path records itself.
    void exhaustRecovery()
    {
        foreach (_; 0 .. maxOutputRecoveries)
            root.addInternalNoteForTesting(
                outputRecoveryMarker ~ " seeded recovery budget");
    }

    void checkOrder(string steering, string followUp, string site)
    {
        assert(root.queuedGuidanceCountForTesting() == 0,
            "the " ~ site ~ " settle did not drain queued guidance");
        assert(root.queuedFollowUpCountForTesting() == 0,
            "the " ~ site ~ " settle did not start the queued follow-up");
        const steerIndex = indexOf(steering);
        const followIndex = indexOf(followUp);
        assert(steerIndex >= 0,
            "queued guidance was lost at the " ~ site ~ " settle");
        assert(followIndex >= 0,
            "the queued follow-up was lost at the " ~ site ~ " settle");
        assert(followIndex > steerIndex,
            "typed order was inverted at the " ~ site ~ " settle: guidance=" ~
            to!string(steerIndex) ~ " follow-up=" ~ to!string(followIndex));
        assert(root.lastSubmittedUserMessageForTesting() == followUp,
            "the queued follow-up did not open the next turn at the " ~
            site ~ " settle");
    }

    // 1. Ordinary output abort ("Stopped repeated agent output.").
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Fix the failing test."]);
    root.startTurnClockForTesting();
    exhaustRecovery();
    root.queueGuidanceForTesting("STEER: keep the change small.");
    root.queueFollowUpForTesting("FOLLOW: summarize the result.");
    root.projectTranscriptForTesting();
    assert(root.queuedGuidanceCountForTesting() == 1 &&
        root.queuedFollowUpCountForTesting() == 1,
        "the fixture did not populate both queues");
    assert(root.queuedPromptBubbleCountForTesting() == 2,
        "both pending prompts must be visible before the abort");

    root.injectOutputFailureForTesting("provider_error");
    root.projectTranscriptForTesting();

    checkOrder("STEER: keep the change small.", "FOLLOW: summarize the result.",
        "output-abort");
    assert(root.queuedPromptBubbleCountForTesting() == 0,
        "the abort settle left a pending prompt bubble behind");
    root.stopActiveTurnForTesting();

    // 2. Exhausted progress audit ("Unfinished work remains recorded.").
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Audit the unfinished task."]);
    root.startTurnClockForTesting();
    exhaustRecovery();
    root.queueGuidanceForTesting("STEER: record what is left.");
    root.queueFollowUpForTesting("FOLLOW: then stop.");
    root.projectTranscriptForTesting();
    assert(root.queuedGuidanceCountForTesting() == 1 &&
        root.queuedFollowUpCountForTesting() == 1,
        "the audit fixture did not populate both queues");

    root.injectOutputFailureForTesting("task_audit_stalled");
    root.projectTranscriptForTesting();

    checkOrder("STEER: record what is left.", "FOLLOW: then stop.",
        "stalled-audit");
    root.stopActiveTurnForTesting();

    // 3. Promoted prompt: "Send now" on an earlier steering entry must not let
    // later steering jump ahead of it. The later entry stays queued for the new
    // turn instead of being drained into the turn being interrupted.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Start the work."]);
    root.startTurnClockForTesting();
    root.queueGuidanceForTesting("STEER A: promote me.");
    root.queueGuidanceForTesting("STEER B: typed later.");
    root.projectTranscriptForTesting();
    assert(root.queuedPromptBubbleCountForTesting() == 2,
        "both steering entries must be pending before the promotion");
    assert(root.clickQueuedPromptActionForTesting(0),
        "the Send now action did not fire");

    assert(indexOf("STEER A: promote me.") == -1,
        "the promoted prompt was applied to the stopped turn instead of opening the next turn");
    assert(indexOf("STEER B: typed later.") == -1 &&
        root.queuedGuidanceCountForTesting() == 1,
        "guidance typed after the promoted prompt was drained ahead of it");
    assert(root.queuedFollowUpCountForTesting() == 1,
        "the promoted prompt did not become the queued next turn");

    // Release the stopped turn and let the promotion open; the later guidance
    // then applies inside it, after the promoted prompt in the transcript.
    root.cancelStreamForTesting();
    const promoteDeadline = Clock.currTime + 2.seconds;
    while (root.lastSubmittedUserMessageForTesting() != "STEER A: promote me." &&
        Clock.currTime < promoteDeadline)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    assert(root.lastSubmittedUserMessageForTesting() == "STEER A: promote me.",
        "the promoted prompt did not open the next turn");
    const promoted = indexOf("STEER A: promote me.");
    assert(promoted >= 0, "the promoted prompt is missing from the transcript");
    assert(root.queuedGuidanceCountForTesting() == 1,
        "later guidance was not kept for the new turn");
    assert(root.consumeGuidanceForTesting(), "kept guidance could not be applied");
    const later = indexOf("STEER B: typed later.");
    assert(later > promoted,
        "typed order was inverted after the promotion: promoted=" ~
        to!string(promoted) ~ " later=" ~ to!string(later));
    root.stopActiveTurnForTesting();

    // 4. Promoted follow-up: same rule when the promoted entry is a follow-up.
    // Pending guidance cannot be drained ahead of the prompt that now opens
    // the next turn; it stays queued for that turn.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Keep working."]);
    root.startTurnClockForTesting();
    root.queueGuidanceForTesting("STEER C: applies to the next turn.");
    root.queueFollowUpForTesting("FOLLOW D: promoted.");
    root.projectTranscriptForTesting();
    assert(root.queuedPromptBubbleCountForTesting() == 2,
        "both pending prompts must be visible before the follow-up promotion");
    assert(root.clickQueuedPromptActionForTesting(1),
        "the Send now action on the follow-up did not fire");
    assert(indexOf("STEER C: applies to the next turn.") == -1 &&
        root.queuedGuidanceCountForTesting() == 1,
        "guidance was drained ahead of the promoted follow-up");

    root.cancelStreamForTesting();
    const followDeadline = Clock.currTime + 2.seconds;
    while (root.lastSubmittedUserMessageForTesting() != "FOLLOW D: promoted." &&
        Clock.currTime < followDeadline)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    assert(root.lastSubmittedUserMessageForTesting() == "FOLLOW D: promoted.",
        "the promoted follow-up did not open the next turn");
    const followPromoted = indexOf("FOLLOW D: promoted.");
    assert(followPromoted >= 0);
    assert(root.consumeGuidanceForTesting(), "kept guidance could not be applied");
    const followLater = indexOf("STEER C: applies to the next turn.");
    assert(followLater > followPromoted,
        "typed order was inverted after the follow-up promotion: promoted=" ~
        to!string(followPromoted) ~ " guidance=" ~ to!string(followLater));
    root.stopActiveTurnForTesting();

    writeln("PASS queued guidance flushes before a queued follow-up on both abort settles");
    return 0;
}

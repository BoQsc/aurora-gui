module goal_rebuild_contracts;

// A rebuild ends the transport turn, not the persistent goal. The restart note
// is written for the requesting conversation, and the shutdown then cancels the
// turn; the saved status is therefore `interrupted` (or `completed` when the
// cancellation was processed before the snapshot), not proof the agent finished.
// The note must continue its chat unless the user stopped it and no turn was
// running, or the task is waiting for a required answer. Before this, a settled
// or cancelled turn was reopened and dropped ("the chat did not continue after
// rebuild").

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = buildPath(tempDir(),
        "aurora-goal-rebuild-" ~ to!string(MonoTime.currTime.ticks));
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
    void settleIdleGoal(string goalStatus)
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Rebuild and verify the parser."]);
        root.setGoalForTesting("Rebuild and verify the parser.", goalStatus);
        root.setTaskStateForTesting("Rebuild and verify the parser.", "active",
            "not_required");
        root.applyPlanForTesting(
            `{"plan":[{"step":"Verify the parser","status":"in_progress"}]}`);
        // The turn settled before the app closed: nothing is `running` at restart.
        root.setSessionTurnStatusForTesting(root.currentSessionForTesting(), "completed");
    }
    void noteForCurrent(string reason)
    {
        const id = root.sessionIdForTesting(root.currentSessionForTesting());
        write(buildPath(state, "restart-resume.json"),
            `{"cause":"rebuild","reason":"` ~ reason ~ `","session":"` ~ id ~ `"}`);
    }

    // An active goal keeps working across the rebuild even though its turn had
    // already settled.
    settleIdleGoal("active");
    noteForCurrent("apply the fix");
    const before = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() > before,
        "a rebuild dropped an active goal because its turn had already settled");
    assert(root.turnBusyForTesting(),
        "the resumed goal did not start a turn");
    assert(root.goalStatusForTesting() == "active",
        "the resume changed the goal state");
    bool continued;
    foreach (i; before .. root.totalMessageCountForTesting())
        if (root.messageContentForTesting(i).indexOf("durable objective") >= 0)
            continued = true;
    assert(continued, "the resumed turn carried no continuation instruction");
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a rebuild continues an active goal whose turn had settled");

    // A paused goal stays paused: only the user resumes it. This note does not
    // record an interrupted turn, so nothing was cut short.
    settleIdleGoal("paused");
    noteForCurrent("apply the fix");
    const pausedBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() == pausedBefore,
        "a rebuild resumed a goal the user had paused");
    assert(root.goalStatusForTesting() == "paused",
        "the resume reactivated a paused goal");
    writeln("PASS a rebuild leaves a paused goal stopped");

    // The live failure: the goal was stopped earlier in this conversation, and
    // the user then started a turn of their own that the rebuild cut off. The
    // note records that interrupted turn, so the chat continues; the pause keeps
    // its meaning (no automatic goal continuation) and is never cleared here.
    settleIdleGoal("paused");
    {
        const id = root.sessionIdForTesting(root.currentSessionForTesting());
        write(buildPath(state, "restart-resume.json"),
            root.rebuildResumeNoteForTesting("apply the fix", id, true));
    }
    const runningBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() > runningBefore,
        "a rebuild dropped the chat whose interrupted turn was running while its goal was paused");
    assert(root.turnBusyForTesting(),
        "the interrupted turn of a paused-goal chat did not continue");
    assert(root.goalStatusForTesting() == "paused",
        "continuing an interrupted turn resurrected the paused goal");
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a rebuild continues an interrupted turn whose goal was paused");

    // The same chat, with a note that records no interrupted turn: the pause is
    // still authoritative, so the writer and the resume reader stay in step.
    settleIdleGoal("paused");
    {
        const id = root.sessionIdForTesting(root.currentSessionForTesting());
        write(buildPath(state, "restart-resume.json"),
            root.rebuildResumeNoteForTesting("apply the fix", id, false));
    }
    const idleBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() == idleBefore,
        "a rebuild note without an interrupted turn resumed a paused goal");
    assert(root.goalStatusForTesting() == "paused",
        "the resume reactivated a paused goal with no interrupted turn");
    writeln("PASS a rebuild note without an interrupted turn leaves a paused goal stopped");

    // The live failure: the shutdown cancelled the turn, so it is saved as
    // `interrupted` while the durable checklist has nothing pending. The chat
    // still continues; the turn was cut short, not finished.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Deploy the rebuilt binary."]);
    root.setGoalForTesting("Deploy the rebuilt binary.", "active");
    root.setTaskStateForTesting("Deploy the rebuilt binary.", "active",
        "not_required");
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(),
        "interrupted");
    noteForCurrent("deploy the rebuilt binary");
    const interruptedBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() > interruptedBefore,
        "a rebuild dropped the cancelled chat that requested it");
    assert(root.turnBusyForTesting(),
        "the cancelled rebuild chat did not continue");
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a rebuild continues a cancelled chat with no pending checklist item");

    // The note is authoritative for its named chat even when the turn was
    // recorded as completed before the app exited.
    settleIdleGoal("completed");
    noteForCurrent("apply the fix");
    const completedBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() > completedBefore,
        "a rebuild dropped the chat that requested it after its goal completed");
    assert(root.turnBusyForTesting(),
        "the completed rebuild chat did not continue");
    root.stopActiveTurnForTesting();
    pump();
    writeln("PASS a rebuild continues the requesting chat after its goal completed");

    // The requesting chat is not the restored selection and its messages are
    // only on disk: the on-demand thread store keeps every other conversation's
    // transcript out of memory. A restart decision that reads that empty
    // placeholder as "this chat was never used" consumes the note and leaves the
    // rebuild's own conversation idle - the reported "the chat did not continue
    // after rebuild". The decision must read the saved history first.
    {
        root.newChatForTesting();
        const background = root.currentSessionForTesting();
        root.addConversationForTesting(["user"], ["Rebuild this app after the fix."]);
        root.setGoalForTesting("Rebuild this app after the fix.", "completed");
        root.setTaskStateForTesting("Rebuild this app after the fix.", "completed",
            "not_required");
        root.setSessionTurnStatusForTesting(background, "interrupted");
        // The user watches another chat while the rebuild runs, so that chat is
        // the restored selection on the next launch.
        root.newChatForTesting();
        const viewer = root.currentSessionForTesting();
        root.addConversationForTesting(["user"], ["opened while the rebuild ran"]);
        assert(viewer != background,
            "the viewer chat is not distinct from the rebuild owner");
        root.selectSessionForTesting(viewer);
        root.persistForTesting();
        root.reloadSessionsForTesting();
        assert(root.currentSessionForTesting() == viewer,
            "the restored selection is not the chat the user was viewing");
        assert(root.sessionMessageCountForTesting(background) == 0,
            "the fixture kept the background transcript in memory, so it does not exercise the on-demand store");
        write(buildPath(state, "restart-resume.json"),
            `{"cause":"rebuild","reason":"apply the fix","session":"` ~
            root.sessionIdForTesting(background) ~ `"}`);
        const onDiskBefore = root.sessionMessageCountForTesting(background);
        root.prepareResumeForTesting();
        pump();
        assert(root.sessionMessageCountForTesting(background) > onDiskBefore,
            "a rebuild dropped the requesting chat whose transcript was only on disk");
        assert(root.sessionTurnBusyForTesting(background),
            "the requesting chat whose transcript was only on disk did not continue");
        root.stopActiveTurnForTesting();
        pump();
        writeln("PASS a rebuild continues a requesting chat whose transcript is only on disk");
    }

    // Without a note (a plain relaunch) nothing is replayed.
    settleIdleGoal("active");
    root.clearPendingResumeForTesting();
    const notePath = buildPath(state, "restart-resume.json");
    if (exists(notePath)) remove(notePath);
    const plainBefore = root.totalMessageCountForTesting();
    root.prepareResumeForTesting();
    pump();
    assert(root.totalMessageCountForTesting() == plainBefore,
        "a plain relaunch started an unsolicited goal turn");
    writeln("goal rebuild contracts passed");
    return 0;
}

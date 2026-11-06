module goal_rebuild_contracts;

// A rebuild ends the transport turn, not the persistent goal. The restart note
// is written for the requesting conversation, and the shutdown then cancels the
// turn; the saved status is therefore `interrupted` (or `completed` when the
// cancellation was processed before the snapshot), not proof the agent finished.
// The note must continue its chat unless the user paused the goal or the task is
// waiting for a required answer. Before this, a settled or cancelled turn was
// reopened and dropped ("the chat did not continue after rebuild").

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

    // A paused goal stays paused: only the user resumes it.
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

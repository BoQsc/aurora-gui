module output_recovery_contracts;

import auroraopencode.core : ChatMessage, ChatSession;
import auroraopencode.outputrecovery;
import auroraopencode.outputguard : outputFailurePrefix, outputIssueDescription,
    outputRecoveryMarker;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import std.stdio : writeln;
import std.conv : to;
import std.string : indexOf;

int main()
{
    ChatSession session;
    session.goal = "Write and verify the requested artifact";
    session.goalStatus = "active";
    void add(string role, string content, bool internal = false, string tool = "",
        bool failed = false, string error = "")
    {
        ChatMessage message;
        message.role = role; message.content = content;
        message.internal = internal; message.toolName = tool;
        message.failed = failed; message.error = error;
        message.id = "m" ~ to!string(session.messages.length);
        message.parentId = session.activeLeafId;
        session.activeLeafId = message.id;
        session.messages ~= message;
    }
    add("user", session.goal);
    add("assistant", "READY");
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "READY");
    assert(answerReplayed(session), "Short goal replies must not escape the replay guard");
    foreach (_; 0 .. maxOutputRecoveries)
        add("user", outputRecoveryMarker ~ " use the function-call channel", true);
    assert(outputRecoveryCount(session) == maxOutputRecoveries);
    add("tool", "Plan unchanged", false, "update_plan");
    assert(outputRecoveryCount(session) == maxOutputRecoveries, "Plan chatter reset the failure circuit");
    add("tool", "Saved the artifact", false, "write");
    assert(outputRecoveryCount(session) == 0 && !goalAuditStalled(session));
    foreach (_; 0 .. 100)
    {
        add("user", "Persistent goal continuation: finish remaining work", true);
        add("tool", "A useful result", false, "read");
        assert(!goalAuditStalled(session), "Useful long-horizon work hit an arbitrary turn cap");
    }
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "Finished the work");
    add("user", "Persistent goal continuation: audit the result", true);
    add("assistant", "Everything looks good");
    assert(goalAuditStalled(session), "Varying prose must not create an endless goal audit");
    assert(auditStallIssue("goal_audit_stalled") &&
        auditStallIssue("task_audit_stalled") && !auditStallIssue("replayed_prose"));
    assert(!outputRecoveryAllowed("goal_audit_stalled", false, true, false, false, false),
        "A goal audit must not launch a recovery request");
    assert(!outputRecoveryAllowed("task_audit_stalled", false, true, false, false, false),
        "A task audit must not launch a recovery request");
    assert(outputRecoveryAllowed("replayed_prose", false, true, false, false, false),
        "A real replay still gets bounded recovery");
    assert(!outputRecoveryAllowed("replayed_prose", true, true, false, false, false),
        "Exhausted recovery stays stopped");
    assert(suppressAuditContinuation(true, true),
        "An audit stop must pause automatic continuation");
    assert(!suppressAuditContinuation(true, false),
        "Queued user guidance still applies after an audit stop");
    assert(!suppressAuditContinuation(false, true),
        "Ordinary automatic continuation is unchanged");
    assert(outputIssueDescription("goal_audit_stalled").indexOf("goal") >= 0);
    assert(outputIssueDescription("replayed_prose").indexOf("same prose") >= 0,
        "A real replay keeps its explicit description");
    // A surfaced failure ends its audit interval. A retry then needs fresh
    // no-action continuations instead of inheriting the stale counter.
    add("assistant", "Agent output stalled: goal audit", false, "", true,
        outputFailurePrefix ~ outputIssueDescription("goal_audit_stalled"));
    assert(!goalAuditStalled(session), "A surfaced failure must end its audit interval");
    add("user", "Persistent goal continuation: fresh interval", true);
    add("user", "Persistent goal continuation: still no action", true);
    assert(goalAuditStalled(session),
        "Two fresh no-action continuations must still trip the goal guard");
    add("user", "Reply READY again");
    add("assistant", "READY");
    assert(!answerReplayed(session) && !goalAuditStalled(session));
    session.goal = ""; session.goalStatus = "";
    add("user", "Finish the outstanding verification");
    add("assistant", "Done");
    add("user", taskContinuationMarker ~ "verification remains", true);
    add("assistant", "Still done");
    add("user", taskContinuationMarker ~ "verification still remains", true);
    add("assistant", "Everything is complete");
    assert(taskAuditStalled(session), "Short or varied no-action replies escaped the continuation guard");
    add("assistant", "Agent output stalled: task audit", false, "", true,
        outputFailurePrefix ~ outputIssueDescription("task_audit_stalled"));
    assert(!taskAuditStalled(session), "A surfaced failure must end its task audit interval");
    foreach (_; 0 .. 100)
    {
        add("tool", "A concrete attempt or observation", false, "read");
        add("user", taskContinuationMarker ~ "continue useful work", true);
        add("assistant", "Continuing");
        assert(!taskAuditStalled(session), "Useful long-horizon work hit a total-turn cap");
    }
    add("user", "Explain the result"); add("assistant", "Done");
    assert(!taskAuditStalled(session));
    session.goal="Deliver after obtaining the customer rate";session.goalStatus="active";
    foreach (_;0..2)
    {
        add("user",taskContinuationMarker~"still pending",true);
        add("user","Persistent goal continuation: awaiting useful action",true);
        add("assistant","The customer rate is missing.");
    }
    assert(taskAuditStalled(session) && goalAuditStalled(session));
    add("tool","Required customer rate",false,"request_input");
    session.messages[$-1].toolArgs=`{"required_fact":"Billing rate","reason":"Customer-owned rate absent from local configuration","question":"What billing rate applies?","checked":["README and inputs"],"independent_work_complete":true}`;
    session.taskStatus="waiting_input";
    add("assistant","What billing rate applies?");
    assert(!taskAuditStalled(session) && !goalAuditStalled(session),"A validated input wait inherited an earlier prose-stall counter");
    writeln("PASS bounded unusable output, varied goal chatter, useful long-horizon work and new-user boundaries");
    return 0;
}

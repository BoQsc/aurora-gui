module task_continuation_contracts;
import auroraopencode.core;
import auroraopencode.taskcontinuation;
import auroraopencode.requestintent;
import std.conv : to;
import std.stdio : writeln;

void append(ref ChatSession session, string role, string content, bool internal = false,
    string name = "", string arguments = "{}", bool failed = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role; message.content = content; message.internal = internal;
    message.toolName = name; message.toolArgs = arguments; message.failed = failed;
    session.messages ~= message;
    session.activeLeafId = message.id;
}

ChatSession pending()
{
    ChatSession session;
    session.taskStatus = "active";
    session.taskSteps = [TaskStep("Implement", "in_progress"), TaskStep("Verify", "pending")];
    append(session, "user", "Implement and verify the feature.");
    return session;
}

int main()
{
    auto session = pending();
    auto decision = taskContinuation(session, true);
    assert(decision.action == TaskContinuationAction.continueWork);
    // Old verification/reconciliation markers cannot exhaust the new work policy.
    append(session, "user", "Continuation: outstanding verification. report results", true);
    append(session, "user", "Plan reconciliation checkpoint: report remaining work", true);
    foreach (i; 0 .. 8)
    {
        decision = taskContinuation(session, true);
        assert(decision.action == TaskContinuationAction.continueWork);
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "new source " ~ to!string(i), false, "edit",
            "edit-" ~ to!string(i));
        session.taskSteps ~= TaskStep("Verified outcome " ~ to!string(i), "completed",
            "outcome-" ~ to!string(i), "edit", "Source changed", [session.messages[$ - 1].id]);
        append(session, "assistant", "Partial result. May I continue?");
    }
    assert(taskContinuation(session, true).stalled == 0);
    writeln("PASS productive work continues beyond a fixed reply count");

    session = pending();
    append(session, "tool", "same contents", false, "read", "same file");
    foreach (i; 0 .. taskStallLimit)
    {
        decision = taskContinuation(session, true);
        assert(decision.action == TaskContinuationAction.continueWork);
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "same contents", false, "read", "same file");
        append(session, "tool", "bad input " ~ to!string(i), false, "run", "different", true);
        append(session, "tool", "Plan reworded", false, "update_plan", to!string(i));
        append(session, "user", "Durable task-state checkpoint. Task active", true);
        append(session, "assistant", "Still pending " ~ to!string(i));
    }
    assert(taskContinuation(session, true).action == TaskContinuationAction.replan);
    append(session, "user", taskContinuation(session, true).guidance(), true);
    foreach (i; 0 .. taskStallLimit)
    {
        decision = taskContinuation(session, true);
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "same contents", false, "read", "varied query " ~ to!string(i));
    }
    int diagnoses;
    foreach (_; 0 .. 25)
    {
        decision = taskContinuation(session, true);
        assert(decision.action != TaskContinuationAction.settle);
        if (decision.action == TaskContinuationAction.replan) ++diagnoses;
        append(session, "user", decision.guidance(), true);
    }
    assert(diagnoses >= 6, "Repeated stalls did not change diagnosis again");
    // Recovery persists through reload without exhausting the task.
    auto restored = session;
    assert(taskContinuation(restored, true).action != TaskContinuationAction.settle);
    const exhaustedLeaf = session.activeLeafId;
    session.activeLeafId = "m0";
    assert(taskContinuation(session, true).stalled == 0, "Other branch leaked its budget");
    session.activeLeafId = exhaustedLeaf;
    append(session, "user", "Continue and complete the task.");
    assert(taskContinuation(session, true).stalled == 0, "New human turn did not reset retries");
    assert(taskContinuation(session, false).action == TaskContinuationAction.settle);
    session.queuedFollowUps = ["Next request"];
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    session.queuedFollowUps = null;
    session.taskStatus = "waiting_input";
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    writeln("PASS repeated prose/tools/failed calls/planning do not mask a stall; branch and human boundaries reset it");

    session = pending();
    decision = taskContinuation(session, true);
    append(session, "user", decision.guidance(), true);
    session.taskSteps[0].status = "completed";
    append(session, "tool", "Source changed", false, "edit", "changed");
    session.taskSteps[0].evidence = [session.messages[$ - 1].id];
    assert(taskContinuation(session, true).stalled == 0);
    session.taskSteps[1].status = "completed";
    session.verificationStatus = "required";
    assert(taskContinuation(session, true).action == TaskContinuationAction.continueWork);
    session.verificationStatus = "passed";
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    session = pending();
    append(session, "user", "What happened to the unfinished plan?");
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    foreach (question; ["What is left?", "How would we fix it?", "Why did it stop?"])
        assert(answerOnlyRequest(question));
    foreach (request; ["Can you fix the remaining work?", "Could you implement it?",
            "What happened? Please finish the task.", "Why did it stop? Fix it.",
            "Why is it stopping? Let's resolve it."])
        assert(!answerOnlyRequest(request), request);
    assert(taskBlockerError(`{"reason":"Deployment address missing","required_fact":"Deployment destination","question":"Which server?","checked":["Local deployment configuration has no destination"],"independent_work_complete":true}`) == "");
    assert(taskBlockerError(`{"kind":"external","reason":"Server offline"}`).length);
    assert(taskBlockerError(`{"reason":"Verification pending","required_fact":"Permission","question":"Should I run tests?","checked":["Tests exist"],"independent_work_complete":true}`).length);
    assert(taskBlockerError(`{"kind":"input","reason":"Deployment address missing"}`).length);
    assert(taskBlockerError(`{"kind":"external","reason":""}`).length);
    assert(taskBlockerError("broken").length);
    writeln("PASS recurring recovery, focused required input, verification/questions and Stop boundaries");
    return 0;
}

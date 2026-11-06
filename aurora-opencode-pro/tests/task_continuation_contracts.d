module task_continuation_contracts;
import auroraopencode.core;
import auroraopencode.taskcontinuation;
import auroraopencode.taskflow : acceptTaskRequest;
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
    {
        auto progress = pending();
        const checkpoint = taskContinuation(progress, true);
        append(progress, "user", checkpoint.guidance(), true);
        progress.taskSteps[0].status = "completed";
        assert(taskContinuation(progress, true).stalled == 0,
            "Completed outcome progress was ignored when the normal checklist carried no receipt IDs");
    }
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
    // A queued follow-up waits for the agent to stop working; it never ends
    // authorized work early.
    session.queuedFollowUps = ["Next request"];
    assert(taskContinuation(session, true).action != TaskContinuationAction.settle,
        "a queued follow-up settled unfinished work");
    session.queuedFollowUps = null;
    session.taskStatus = "waiting_input";
    append(session, "tool", "Essential destination missing", false, "request_input",
        `{"reason":"Deployment destination is absent","required_fact":"Deployment destination","question":"Which deployment server should I use?","checked":["Local deployment configuration"],"independent_work_complete":true,"blocked_steps":["Implement","Verify"]}`);
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

    // Missing verification changes the diagnosis rather than abandoning the
    // authorized task after an arbitrary number of checker attempts.
    session = pending();
    session.taskSteps[0].status = "completed";
    session.taskSteps[1].status = "completed";
    session.verificationStatus = "required";
    foreach (i; 0 .. taskStallLimit)
    {
        decision = taskContinuation(session, true);
        assert(decision.action == TaskContinuationAction.continueWork);
        assert(decision.verificationAttempts == i + 1);
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "Rerun " ~ to!string(i), false, "run",
            "run-" ~ to!string(i));
    }
    decision = taskContinuation(session, true);
    assert(decision.action == TaskContinuationAction.replan,
        "Verification-only churn did not change diagnosis");
    foreach (i; 0 .. 20)
    {
        append(session, "user", decision.guidance(), true);
        append(session, "tool", "Checker still failing", false, "run", "checker");
        decision = taskContinuation(session, true);
        assert(decision.action != TaskContinuationAction.settle,
            "Outstanding verification was silently abandoned");
    }
    session.verificationStatus = "passed";
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);

    session = pending();
    append(session, "user", "What happened to the unfinished plan?");
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    session = pending();
    append(session, "user", "So what's the future of this project?");
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle,
        "Conversation follow-up resumed unfinished work");

    // A fact supplied after a required-input pause is the next step of the
    // same task, not a conversational detour.
    ChatSession supplied;
    append(supplied, "user", "Deploy the prepared fixture.");
    acceptTaskRequest(supplied, supplied.messages[$ - 1].content,
        supplied.messages[$ - 1].id);
    supplied.taskStatus = "waiting_input";
    append(supplied, "user", "The deployment destination is fixture.example.");
    acceptTaskRequest(supplied, supplied.messages[$ - 1].content,
        supplied.messages[$ - 1].id);
    assert(supplied.contract.currentIntent == "continuation",
        "A supplied fact was recorded as unrelated conversation");
    assert(taskContinuation(supplied, true).action ==
        TaskContinuationAction.continueWork,
        "Supplying the missing fact did not resume the task");

    // Explicit approval of the next step is also a directive to act.
    foreach (approval; ["go ahead", "please proceed", "yes", "sounds good",
            "go for it", "make it so"])
        assert(actionApprovalRequest(approval), approval);
    assert(!actionApprovalRequest("What should happen next?"));
    assert(!actionApprovalRequest("go for"));
    ChatSession approved;
    append(approved, "user", "Fix the parser.");
    acceptTaskRequest(approved, approved.messages[$ - 1].content,
        approved.messages[$ - 1].id);
    append(approved, "user", "Go ahead.");
    acceptTaskRequest(approved, approved.messages[$ - 1].content,
        approved.messages[$ - 1].id);
    assert(approved.contract.currentIntent == "continuation");
    assert(taskContinuation(approved, true).action ==
        TaskContinuationAction.continueWork,
        "Approval after a permission question did not resume work");

    foreach (reply; ["Would you like me to continue?",
            "Should I run the tests now?",
            "I can apply the patch. Do you want me to proceed?"])
        assert(permissionQuestionReply(reply), reply);
    assert(!permissionQuestionReply("The parser is fixed; tests pass."));

    foreach (question; ["What is left?", "How would we fix it?", "Why did it stop?"])
        assert(answerOnlyRequest(question));
    foreach (request; ["Can you fix the remaining work?", "Could you implement it?",
            "What happened? Please finish the task.", "Why did it stop? Fix it.",
            "Why is it stopping? Let's resolve it."])
        assert(!answerOnlyRequest(request), request);
    assert(taskBlockerError(`{"reason":"Deployment address missing","required_fact":"Deployment destination","question":"Which server?","checked":["Local deployment configuration has no destination"],"independent_work_complete":true}`) == "");
    assert(taskBlockerError(`{"kind":"external","reason":"Server offline"}`).length);
    assert(taskBlockerError(`{"reason":"Verification pending","required_fact":"Permission","question":"Should I run tests?","checked":["Tests exist"],"independent_work_complete":true}`).length);
    assert(taskBlockerError(`{"reason":"Implementation choice unresolved","required_fact":"Preferred implementation approach","question":"Which approach should I use?","checked":["Source inspected"],"independent_work_complete":true}`).length,
        "A routine implementation choice was accepted as missing user information");
    assert(taskBlockerError(`{"kind":"input","reason":"Deployment address missing"}`).length);
    assert(taskBlockerError(`{"kind":"external","reason":""}`).length);
    assert(taskBlockerError("broken").length);
    import auroraopencode.inputcontract : settleInputRequestSteps;
    import auroraopencode.taskflow : supportedStep, compatibleEvidence;
    ChatSession rate;
    rate.taskStatus="active";
    rate.taskSteps=[TaskStep("Request billing rate via request_input","in_progress","ask","other"),
                    TaskStep("Generate real invoice.json once rate known","pending","invoice","edit")];
    const question=`{"required_fact":"Billing rate (currency per unit)","reason":"Invoice totals depend on the customer-owned rate, absent from every local source.","question":"What billing rate should the invoice use?","checked":["README.md: no value given","events.jsonl: events only"],"independent_work_complete":true,"blocked_steps":["invoice"]}`;
    assert(!taskInputError(rate,question).length,"Request-input bookkeeping blocked its own input operation");
    append(rate,"tool","Required billing rate",false,"request_input",question);
    rate.messages[$-1].toolCallId="input-receipt";
    settleInputRequestSteps(rate,"input-receipt");
    assert(rate.taskSteps[0].status=="completed" && supportedStep(rate,rate.taskSteps[0]));
    assert(rate.taskSteps[1].status=="pending" && !compatibleEvidence(rate.taskSteps[1],"input",false));
    rate.taskSteps~=TaskStep("Independent README usage","pending","readme","edit");
    assert(taskInputError(rate,question).length,"Asking for a fact hid independent implementation work");
    rate.taskSteps[0]=TaskStep("Request billing rate via request_input and implement package","pending","mixed","other");
    settleInputRequestSteps(rate,"input-receipt");
    assert(rate.taskSteps[0].status=="pending","A mixed implementation outcome was completed as input bookkeeping");
    writeln("PASS recurring recovery, focused required input, verification/questions and Stop boundaries");
    return 0;
}

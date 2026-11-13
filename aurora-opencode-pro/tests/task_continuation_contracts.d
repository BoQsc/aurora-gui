module task_continuation_contracts;
import auroraopencode.core;
import auroraopencode.taskcontinuation;
import auroraopencode.taskflow : acceptTaskRequest;
import auroraopencode.requestintent;
import auroraopencode.turnpolicy : decideTurn, TurnPolicy, TurnAction;
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
    assert(taskContinuation(session, true).action == TaskContinuationAction.continueWork);
    assert(taskContinuation(session, false).action == TaskContinuationAction.settle);
    session.taskSteps = null;
    session.objective = "Implement the feature";
    session.contract.id = "m0";
    session.contract.intent = "implementation";
    session.contract.currentIntent = "implementation";
    append(session,"tool","Source changed",false,"edit");
    session.verificationStatus = "passed";
    assert(taskContinuation(session,true).action == TaskContinuationAction.settle,
        "An absent plan became a prerequisite to completing verified work");
    foreach (reply; ["Would you like me to continue?",
            "Should I run the tests now?",
            "I can apply the patch. Do you want me to proceed?"])
        assert(permissionQuestionReply(reply), reply);
    assert(!permissionQuestionReply("The parser is fixed; tests pass."));

    foreach (question; ["What is left?", "How would we fix it?"])
        assert(answerOnlyRequest(question));
    assert(requestIntent("Why did it stop?") == RequestIntent.diagnosis);
    assert(!answerOnlyRequest("Why did it stop?"),
        "A why-question was treated as an answer-only explanation");
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

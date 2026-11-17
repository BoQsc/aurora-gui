module diagnosis_intent_contracts;

import auroraopencode.core;
import auroraopencode.requestintent;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.contextpolicy : durableTaskPrompt;
import auroraopencode.answercontract : answerContract;
import auroraopencode.tools : toolSteeringPrompt;
import auroraopencode.goalmode : goalIsAnswerOnly, goalIsAnswerTurn;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession s, string role, string text)
{
    ChatMessage m;
    m.id = "m" ~ to!string(s.messages.length);
    m.parentId = s.activeLeafId;
    m.role = role;
    m.content = text;
    s.messages ~= m;
    s.activeLeafId = m.id;
}

void request(ref ChatSession s, string text)
{
    append(s, "user", text);
    acceptTaskRequest(s, text, s.activeLeafId);
}

int main()
{
    // A why-question authorizes diagnosis and resolution; it is not an
    // answer-only explanation and it must not detach the unfinished task.
    assert(requestIntent("Why did it stop?") == RequestIntent.diagnosis);
    assert(!answerOnlyRequest("Why did it stop?"));
    assert(!explanationOnlyRequest("Why did it stop?"));
    assert(diagnosticFollowUpRequest("Why did it stop?"),
        "A why-question would resume stopped desktop input");
    assert(requestIntent("Why does the provider stall?") == RequestIntent.diagnosis);
    assert(requestIntent("Why is it still not switching immediately?") == RequestIntent.diagnosis);

    // Explicit explanation-only instructions and explicit repairs keep their
    // prior classification.
    assert(requestIntent("Explain why, and don't implement anything.") == RequestIntent.clarification);
    assert(requestIntent("Why did it stop? Just explain.") == RequestIntent.clarification);
    assert(explanationOnlyRequest("Explain why the build failed."));
    assert(requestIntent("Why did it stop? Fix it.") == RequestIntent.implementation);
    assert(requestIntent("Analyze why it failed; do not edit files.") == RequestIntent.analysis);

    // A why-question about the agent's own authorization asks for an account of
    // what happened. Treating it as a repair authorized a destructive rollback
    // of work the user had already requested and received.
    const accountability = "So why implementation began without approval or question";
    assert(requestIntent(accountability) == RequestIntent.clarification);
    assert(answerOnlyRequest(accountability));
    assert(!diagnosticFollowUpRequest(accountability),
        "an accountability question would resume stopped desktop input");
    ChatSession accountabilitySession;
    request(accountabilitySession, "Add splitpane and progressbar.");
    accountabilitySession.taskSteps =
        [TaskStep("Add splitpane", "pending", "splitpane")];
    request(accountabilitySession, accountability);
    const accountabilityPrompt = durableTaskPrompt(accountabilitySession, true);
    assert(accountabilityPrompt.indexOf("asks for an explanation") >= 0, accountabilityPrompt);
    assert(accountabilityPrompt.indexOf("resolve it with the correct change") < 0,
        "an accountability question still authorized a repair");
    const inactivity = "so why nothing is being done by you now";
    assert(requestIntent(inactivity) == RequestIntent.clarification,
        "an inactivity question authorized another repair");
    assert(answerOnlyRequest(inactivity));

    // A review phrased as a question still asks for inspection work. It must
    // not reach the tool-free final-answer handoff, which previously left the
    // model no channel for its folder lookup and made it print XML call text.
    const reviewRequest = "is it organized well, do quick review with quick summary";
    assert(requestIntent(reviewRequest) == RequestIntent.analysis);
    assert(!answerOnlyRequest(reviewRequest));
    assert(requestIntent("take a quick look at the folder") == RequestIntent.analysis);
    assert(answerOnlyRequest("what is left?"),
        "a completed task can still answer a status question without tools");

    // The prompt and per-request contract must require resolution rather than a
    // bare explanation, while the explicit explanation request stays answer-only.
    // The system prompt itself no longer carries the old "Why = diagnose" line;
    // diagnosis is enforced per request by the answer contract below.
    assert(toolSteeringPrompt(false).indexOf("don't assume every question authorizes a repair") >= 0);
    assert(toolSteeringPrompt(false).indexOf("reported failure authorizes diagnosing") >= 0,
        "The system prompt does not authorize resolving a reported failure");
    assert(answerContract("Why does the provider stall?", "").indexOf("Do not stop at an explanation") >= 0);
    assert(answerContract("Explain why the provider stalls.", "").indexOf("Do not stop at an explanation") < 0);
    assert(goalIsAnswerOnly("Why did it stop?"),
        "A diagnosis goal would acquire a forced work turn after its answer");
    assert(goalIsAnswerTurn("Why did it stop?"), "A diagnosis goal would auto-loop without resolving");

    // Mid-task: a why-question keeps the contract and unfinished checklist and
    // continues the fix instead of settling into an explanation.
    ChatSession task;
    request(task, "Fix the parser.");
    task.taskSteps = [TaskStep("Fix parser", "in_progress", "fix", "edit", "Reject invalid input")];
    task.verificationStatus = "required";
    const id = task.contract.id;
    request(task, "Why did it stop?");
    assert(task.contract.id == id && task.taskSteps.length == 1);
    assert(task.contract.currentIntent == "diagnosis" && task.taskStatus == "active",
        "A why-question stopped instead of continuing the fix");
    assert(taskContinuation(task, true).action == TaskContinuationAction.continueWork,
        "A why-question settled into an explanation");
    const prompt = durableTaskPrompt(task, true);
    assert(prompt.indexOf("The latest request asks why") >= 0, prompt);
    assert(prompt.indexOf("do not stop at an explanation") >= 0, prompt);

    // Explicit explanation still preserves the task without resuming it.
    request(task, "Explain why it stopped; do not edit anything.");
    assert(task.contract.id == id && task.taskSteps.length == 1);
    assert(taskContinuation(task, true).action == TaskContinuationAction.settle,
        "An explicit explanation request resumed the implementation");
    assert(durableTaskPrompt(task, true).indexOf("The latest request asks for an explanation") >= 0);

    writeln("PASS why-question diagnosis authorizes resolution, preserves desktop stops, " ~
        "and explicit explanation requests remain answer-only");
    return 0;
}
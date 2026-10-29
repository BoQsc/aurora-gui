module conversation_quality_contracts;

import auroraopencode.core;
import auroraopencode.requestintent;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.taskpolicy;
import auroraopencode.planmode : setStrictPlanSetting;
import auroraopencode.runtime;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;
import std.string : indexOf;
import core.time : MonoTime;
import core.time : seconds, msecs;
import core.thread : Thread;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.toolscheduler : scheduleToolBatch;
import auroraopencode.tools : ChangeContext, ToolCancellation;
import std.file : tempDir, mkdirRecurse, write, exists;
import std.path : buildPath;
import std.process : environment;

void append(ref ChatSession s, string role, string text, string tool = "", bool failed = false)
{
    ChatMessage m;
    m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = text; m.toolName = tool; m.failed = failed;
    if (tool.length) m.toolCallId = "call-" ~ m.id;
    s.messages ~= m; s.activeLeafId = m.id;
}
void request(ref ChatSession s, string text)
{
    append(s, "user", text); acceptTaskRequest(s, text, s.activeLeafId);
}

int main()
{
    environment["AURORA_STRICT_PLAN"] = "0";
    setStrictPlanSetting(false);
    scope(exit) setStrictPlanSetting(false);
    const started = MonoTime.currTime;
    foreach (text; ["Can you refactor the remaining implementation?", "Could you optimize it?",
            "Explain the failure and refactor it.", "Help me fix this.", "I want you to improve this.",
            "What happened? Please finish the task."])
        assert(requestIntent(text) == RequestIntent.implementation, text);
    foreach (text; ["What is left?", "How would we fix it?", "Why did it stop?",
            "Explain why, and don't implement anything."])
        assert(answerOnlyRequest(text), text);
    foreach (text; ["do it", "Do that.", "Please do it.", "Yes, do it."])
        assert(requestIntent(text) == RequestIntent.implementation, text);
    foreach (text; ["Stop asking and just do the work.",
            "Be proactive and figure it out.",
            "It's always clarifying and annoyances instead of figuring out and doing things."])
        assert(requestIntent(text) == RequestIntent.implementation, text);
    assert(!answerOnlyRequest("do it"), "An action approval was treated as an answer-only question");
    assert(!answerOnlyRequest("go ahead"));
    assert(requestIntent("Analyze the conversation flow.") == RequestIntent.analysis);
    assert(requestIntent("Continue the task.") == RequestIntent.continuation);
    ChatSession casual;
    request(casual, "Continue in this chat while I open another.");
    assert(!unfinishedTask(casual), "Casual continuation manufactured an action task");

    ChatSession s;
    request(s, "Fix browser rendering.");
    auto visual = s.contract.id;
    s.taskSteps = [TaskStep("Render", "pending", "render", "edit", "Reference image matches")];
    s.verificationStatus = "required";
    request(s, "What remains?");
    assert(s.contract.id == visual && s.taskSteps.length == 1 && s.verificationStatus == "required");
    assert(taskContinuation(s, true).action == TaskContinuationAction.settle);
    s.taskStatus = "blocked";
    request(s, "Why did it stop?");
    assert(s.taskStatus == "blocked" && s.taskSteps.length == 1);
    request(s, "New task: fix the backend parser.");
    assert(s.contract.id != visual && s.taskArchive.length == 1);
    assert(requiredEvidence(s).length == 0 && s.taskSteps.length == 0);
    const parserTask = s.contract.id;
    request(s, "Now fix the remaining parser case.");
    assert(s.contract.id == parserTask, "A phase transition discarded unfinished work");
    request(s, "How does rendering work?");
    assert(requiredEvidence(s).length == 0, "A question contaminated the active task's verification requirements");
    request(s, "Continue the parser task.");
    assert(unfinishedTask(s), "An untracked action request silently completed");
    s.taskStatus = "waiting_input";
    request(s, "The deployment destination is fixture.example.");
    assert(s.taskStatus == "active" && s.contract.id == parserTask,
        "Supplied information failed to resume the existing task");
    assert(s.contract.currentIntent == "continuation",
        "Supplied information was not recorded as task continuation");
    append(s, "assistant", "Done.");
    assert(taskContinuation(s, true).action == TaskContinuationAction.continueWork);
    append(s, "tool", "Build passed", "run");
    s.messages[$ - 1].toolArgs = `{"program":"dmd","args":["old.d"]}`;
    assert(unfinishedTask(s), "Compiling unchanged code completed an implementation request");
    append(s, "tool", "parser changed", "edit");
    assert(!unfinishedTask(s), "A trivial completed action was forced into a plan");
    ChatSession unplanned;
    request(unplanned, "Write seven Markdown documents.");
    foreach (i; 0 .. 7)
    {
        append(unplanned, "tool", "Document written", "write");
        unplanned.messages[$ - 1].toolArgs = `{"filePath":"document-` ~ to!string(i) ~ `.md"}`;
    }
    assert(!taskRequiresPlan(unplanned) && !unfinishedTask(unplanned),
        "Multi-file completed work was forced into a planning ceremony");
    assert(taskContinuation(unplanned, true).action == TaskContinuationAction.settle,
        "Missing optional plan added a completion round");
    unplanned.verificationStatus = "required";
    assert(unfinishedTask(unplanned), "Optional planning bypassed required verification");
    unplanned.verificationStatus = "passed";
    assert(!unfinishedTask(unplanned));
    setStrictPlanSetting(true);
    assert(taskRequiresPlan(unplanned) && unfinishedTask(unplanned),
        "Explicit strict mode no longer requires its checklist");
    setStrictPlanSetting(false);
    writeln("PASS multi-file work finishes without a plan; verification and opt-in strict mode remain effective");
    s.taskStatus = "completed";
    request(s, "Analyze the parser.");
    assert(s.contract.intent == "analysis");
    assert(explorationGuidance(s).indexOf("supported findings") >= 0);
    assert(explorationGuidance(s).indexOf("Prefer the smallest correct edit") < 0);
    request(s, "do it");
    assert(s.contract.intent == "implementation" && s.contract.currentIntent == "implementation",
        "Approving the analysis did not authorize implementation");
    assert(!taskInvestigation(s));

    request(s, "Now implement and verify the parser.");
    const initial = parseJSON(`[{"id":"fix","step":"Fix parser","kind":"edit","done":"Reject invalid input","status":"in_progress"},{"id":"verify","step":"Verify parser","kind":"verify","done":"Regression tests pass","status":"pending"}]`);
    s.taskSteps = normalizedPlan(s, initial, null);
    s.contract.constraints = ["Preserve public API"];
    s.contract.decisions = ["Rejected a permissive fallback"];
    append(s, "user", "Do not discard the plan.");
    const replacement = `{"replace_entire_plan":true,"plan":[{"id":"fix","step":"Fix parser","status":"in_progress"}]}`;
    assert(planUpdateError(s, replacement, s.taskSteps).length, "Negation authorized discarding unfinished outcomes");
    append(s, "user", "Replace the plan.");
    assert(!planUpdateError(s, replacement, s.taskSteps).length);
    request(s, "Continue implementing and verifying the parser.");
    const dropped = `{"plan":[{"id":"fix","step":"Fix parser","status":"in_progress"}]}`;
    assert(planUpdateError(s, dropped, s.taskSteps).length, "A short plan lost unfinished work");
    const fabricated = `{"plan":[{"id":"fix","step":"Fix parser","status":"completed"},{"id":"verify","step":"Verify parser","status":"pending"}]}`;
    assert(planUpdateError(s, fabricated, s.taskSteps).length);
    append(s, "tool", "failed edit", "edit", true);
    assert(planUpdateError(s, fabricated, s.taskSteps).length, "A failed tool certified completion");
    append(s, "tool", "parser fixed", "edit");
    assert(!planUpdateError(s, fabricated, s.taskSteps).length);
    s.taskSteps = normalizedPlan(s, parseJSON(fabricated)["plan"], s.taskSteps);
    assert(s.taskSteps[0].done == "Reject invalid input" && s.taskSteps[0].evidence.length == 1);
    auto before = taskContinuation(s, true);
    append(s, "user", before.guidance()); s.messages[$ - 1].internal = true;
    auto duplicate = s.taskSteps[0]; duplicate.id = "claimed-extra"; duplicate.text = "Extra claim";
    s.taskSteps ~= duplicate;
    assert(taskContinuation(s, true).stalled == 1, "Reusing evidence reset stagnation");
    s.taskSteps = s.taskSteps[0 .. 2];
    s.taskSteps[1].status = "completed";
    s.nestedPlans = [NestedPlan(1, [TaskStep("Edge case", "pending")])];
    assert(unfinishedTask(s), "Pending substeps were ignored");

    JSONValue state;
    writeTaskContract(state, s);
    ChatSession restored;
    readTaskContract(restored, parseJSON(state.toString()));
    assert(restored.contract == s.contract && restored.taskSteps == s.taskSteps);
    assert(restored.nestedPlans == s.nestedPlans && restored.taskArchive == s.taskArchive);
    auto copy = snapshotChatSessions([s]);
    s.nestedPlans[0].steps[0].evidence = ["child-proof"];
    auto nestedCopy = snapshotChatSessions([s]);
    s.nestedPlans[0].steps[0].evidence[0] = "changed-child-proof";
    assert(nestedCopy[0].nestedPlans[0].steps[0].evidence[0] == "child-proof");
    s.taskSteps[0].evidence[0] = "different";
    assert(copy[0].taskSteps[0].evidence[0] != "different", "Snapshot evidence aliases live state");
    AgentRuntimeEvent event;
    event.kind = AgentEventKind.threadUpdated; event.threadId = "quality-fixture";
    event.payloadJson = state.toString();
    auto projection = projectAgentRuntimeEvents([event]);
    assert(projection.length == 1 && projection[0].contract.id == restored.contract.id);
    assert(projection[0].taskSteps[0].done == "Reject invalid input");
    auto branch = copy[0];
    branch.messages[$ - 1].taskStateJson = activeTaskStateJson(branch);
    const originalLeaf = branch.activeLeafId;
    const originalTask = branch.contract.id;
    request(branch, "New task: fix another component.");
    const retainedMessages = branch.messages.length;
    branch.activeLeafId = originalLeaf;
    restoreBranchTask(branch);
    assert(branch.contract.id == originalTask && branch.taskSteps[0].done == "Reject invalid input");
    assert(branch.messages.length == retainedMessages, "Branch selection erased history");
    ChatSession loop;
    request(loop, "Implement the missing feature.");
    foreach (i; 0 .. 16)
    {
        append(loop, "tool", "No matches for query " ~ to!string(i), "grep");
        loop.messages[$ - 1].toolArgs = "query-" ~ to!string(i);
    }
    assert(stalledExecutionTools(loop) == 16);
    append(loop, "tool", "New relevant source", "read");
    assert(stalledExecutionTools(loop) == 0);
    foreach (i; 0 .. 17) append(loop, "tool", "New relevant source", "read");
    assert(stalledExecutionTools(loop) == 17);
    ChatSession verifying;
    request(verifying, "Test the parser.");
    verifying.taskSteps = [TaskStep("Verify parser", "in_progress", "test", "verify", "Regression tests pass")];
    append(verifying, "tool", "Compiler passed", "run");
    verifying.messages[$ - 1].toolArgs = `{"program":"dmd","args":["parser.d"]}`;
    verifying.messages[$ - 1].verificationCheck = "dmd compile";
    verifying.verificationStatus = "required";
    verifying.verificationScope = "current";
    verifying.messages[$ - 1].verificationScope = "current";
    const finishTests = `{"plan":[{"id":"test","step":"Verify parser","status":"completed"}]}`;
    assert(planUpdateError(verifying, finishTests, verifying.taskSteps).length,
        "Compilation certified a required behavioral test outcome");
    append(verifying, "tool", "Tests passed", "run");
    verifying.messages[$ - 1].toolArgs = `{"program":"python","args":["-m","pytest"]}`;
    verifying.messages[$ - 1].verificationCheck = "pytest";
    verifying.messages[$ - 1].verificationScope = "current";
    assert(!planUpdateError(verifying, finishTests, verifying.taskSteps).length);
    const sandbox = buildPath(tempDir(), "aurora-quality-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(sandbox);
    setOpencodeStateDirectoryForTesting(buildPath(sandbox, "state"));
    const fixture = buildPath(sandbox, "input.txt");
    const forbidden = buildPath(sandbox, "forbidden.txt");
    write(fixture, "available evidence");
    auto client = new OpenCodeClient("", "");
    scope(exit) client.closeSession();
    ChangeContext context;
    auto batch = scheduleToolBatch(client, 1, [
        OpenCodeToolCall("write_allowed", "write", `{"filePath":` ~ JSONValue(forbidden).toString() ~ `,"content":"authorized"}`),
        OpenCodeToolCall("read_allowed", "read", `{"filePath":` ~ JSONValue(fixture).toString() ~ `}`)],
        sandbox, new ToolCancellation(), context);
    int toolResults;
    const deadline = MonoTime.currTime + 5.seconds;
    while (toolResults < 2 && MonoTime.currTime < deadline)
    {
        OpenCodeEvent[] events; client.drain(events);
        foreach (toolEvent; events)
            if (toolEvent.kind == OpenCodeEventKind.toolResult && !toolEvent.toolRunning)
            {
                ++toolResults;
                if (toolEvent.toolCallId == "write_allowed") assert(!toolEvent.toolFailed && toolEvent.workspaceChanged, toolEvent.text);
                if (toolEvent.toolCallId == "read_allowed") assert(!toolEvent.toolFailed && toolEvent.text.indexOf("available evidence") >= 0, toolEvent.text);
            }
        Thread.sleep(1.msecs);
    }
    assert(toolResults == 2 && exists(forbidden), "Analysis intent still blocked a mutation");
    foreach (_; 0 .. 5000) append(branch, "assistant", "Preserved earlier conversation");
    const evaluationStarted = MonoTime.currTime;
    foreach (_; 0 .. 100) taskContinuation(branch, true);
    const evaluationMs = (MonoTime.currTime - evaluationStarted).total!"msecs";
    assert(evaluationMs < 2000, "Task gates repeatedly scanned outcomes quadratically");
    writeln("PASS intent, task switches, questions, blockers, analysis, completion, stable criteria, evidence, nested plans, snapshots and journal replay");
    writeln("MEASURE contract_scenarios=15 provider_requests=0 history_messages=", branch.messages.length,
        " completion_decisions=100 decision_milliseconds=", evaluationMs,
        " total_milliseconds=", (MonoTime.currTime - started).total!"msecs");
    return 0;
}

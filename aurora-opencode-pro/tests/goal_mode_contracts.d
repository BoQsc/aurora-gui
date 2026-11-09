module goal_mode_contracts;

import auroraopencode.core : ChatMessage, ChatSession, Settings, TaskStep,
    ensureMessageGraph, goalHistoryFromJson, goalHistoryToJson;
import auroraopencode.goalmode;
import auroraopencode.goalmutation : resetTaskForNewGoal;
import std.json : parseJSON;
import auroraopencode.runtime : AgentEventKind, AgentRuntimeEvent,
    projectAgentRuntimeEvents;
import auroraopencode.tools : builtinToolDefinitions, executeTool,
    nativeOnlyToolDefinitions;
import auroraopencode.core : OpenCodeToolCall, loadSettings,
    setOpencodeStateDirectoryForTesting;
import auroraopencode.opencode_client : OpenCodeEvent;
import auroraopencode.toolsettlement : ToolResultPolicy, settleToolResult;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.utf : toUTF32;
import std.uuid : randomUUID;

void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

ChatMessage msg(string role, string content, bool internal = false)
{
    ChatMessage result;
    result.role = role;
    result.content = content;
    result.internal = internal;
    return result;
}

int main()
{
    auto set = parseGoalCommand("/goal all tests pass and lint is clean");
    require(set.kind == GoalCommandKind.set &&
        set.text == "all tests pass and lint is clean",
        "goal text was not parsed");
    require(parseGoalCommand("/goal pause").kind == GoalCommandKind.pause,
        "pause alias was not parsed");
    require(parseGoalCommand("/goal resume").kind == GoalCommandKind.resume,
        "resume alias was not parsed");
    require(parseGoalCommand("/goal clear").kind == GoalCommandKind.clear,
        "clear alias was not parsed");
    require(parseGoalCommand("/goal").kind == GoalCommandKind.show,
        "bare /goal should open/show the goal");
    require(parseGoalCommand("goals are useful").kind == GoalCommandKind.none,
        "ordinary prose must not become a goal command");
    string longGoal;
    foreach (_; 0 .. maxGoalLength + 10) longGoal ~= "é";
    const clamped = clampGoalText(longGoal);
    require(toUTF32(clamped).length == maxGoalLength,
        "goal clamp split or exceeded the character budget");
    Settings defaults;
    require(defaults.autoGoalFromFirstMessage,
        "the first message must become a persistent goal by default");
    // The previous release persisted the old off default, so the settings
    // migration must turn first-message goals on once. An explicit opt-out
    // saved by the current version stays off.
    const migrationDir = buildPath(tempDir(),
        "aurora-goal-settings-" ~ randomUUID().toString());
    mkdirRecurse(migrationDir);
    scope (exit) rmdirRecurse(migrationDir);
    setOpencodeStateDirectoryForTesting(migrationDir);
    const settingsPath = buildPath(migrationDir, "settings.json");
    write(settingsPath,
        `{"settingsVersion":2,"autoGoalFromFirstMessage":false}`);
    require(loadSettings().autoGoalFromFirstMessage,
        "an older settings file did not migrate to first-message goals");
    write(settingsPath,
        `{"settingsVersion":3,"autoGoalFromFirstMessage":false}`);
    require(!loadSettings().autoGoalFromFirstMessage,
        "an explicit opt-out was overwritten");
    writeln("PASS goal commands set/show/pause/resume/clear");

    ChatSession session;
    session.goal = "Ship the goal bar";
    session.goalStatus = "active";
    auto prompt = goalPromptBlock(session);
    require(prompt.indexOf("request_input") >= 0 && goalContinuationInstruction(session).indexOf("request_input") >= 0,
        "Goal instructions omitted the validated input boundary");
    require(prompt.indexOf("Ship the goal bar") >= 0 &&
        prompt.indexOf("goal_complete") >= 0,
        "active-goal prompt lacks the goal or completion instruction");
    session.goalStatus = "paused";
    prompt = goalPromptBlock(session);
    require(prompt.indexOf("user paused") >= 0,
        "paused goal prompt must not drive another turn");
    writeln("PASS prompt state follows active/paused goals");

    session.goalStatus = "active";
    session.verificationStatus = "required";
    const recovery = goalCompletionError(session,
        `{"summary":"Archive passed manual checks","evidence":["CRC and hashes PASS"]}`);
    require(recovery.indexOf("Use the verify tool") >= 0 && recovery.indexOf("not a successful recorded result") < 0,
        "Completion sent the agent hunting receipt IDs before reporting the actual remaining verification work");
    session.verificationStatus = "not_required";
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "invented completion evidence was accepted");
    auto receipt = msg("tool", "Saved the requested change");
    receipt.toolName = "write"; receipt.toolCallId = "call-1";
    session.messages ~= receipt;
    ensureMessageGraph(session);
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length == 0,
        "a verified, evidence-backed completion was rejected");
    session.messages[$ - 1].failed = true;
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "failed completion evidence was accepted");
    session.messages[$ - 1].failed = false;
    require(goalCompletionError(session,
        `{"summary":"done","evidence":[]}`).length > 0,
        "completion without evidence was accepted");
    session.taskSteps = [TaskStep("finish the UI", "pending")];
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "completion with an open checklist item was accepted");
    session.taskSteps = null;
    session.verificationStatus = "required";
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "completion with outstanding verification was accepted");
    session.verificationStatus = "not_required";
    writeln("PASS goal completion requires evidence and finished checks");

    // Completion must also audit the prose that declares the result. A final
    // answer that names remaining work, a limitation or a follow-up cannot be
    // followed by goal_complete: the checklist may be complete while the agent
    // itself is still reporting unfinished outcomes.
    ChatSession limited;
    limited.goal = "Fix the parser crash";
    limited.goalStatus = "active";
    limited.objective = limited.goal;
    limited.contract.id = "task-limited";
    limited.contract.intent = "implementation";
    limited.contract.currentIntent = "implementation";
    limited.taskSteps =
        [TaskStep("Fix the parser crash", "completed", "fix", "", "Parser tests pass", [])];
    limited.messages ~= msg("user", "Fix the parser crash");
    auto fix = msg("tool", "Patched the parser");
    fix.toolName = "edit";
    fix.toolCallId = "call-fix";
    fix.workspaceChanged = true;
    limited.messages ~= fix;
    limited.messages ~= msg("assistant",
        "Result: patched.\nRemaining: the suite is unverified.");
    limited.messages ~= msg("user", goalCompletionAuditMarker ~ limited.goal, true);
    ensureMessageGraph(limited);
    require(goalCompletionError(limited,
        `{"summary":"Patched the parser","evidence":["call-fix"]}`)
        .indexOf("unresolved work") >= 0,
        "completion was accepted while its answer declared remaining work");
    require(goalCompletionError(limited,
        `{"summary":"Patched the parser.\nLimitations: the GUI is still unverified.","evidence":["call-fix"]}`)
        .length > 0,
        "completion was accepted with a limitation in its summary");
    require(goalCompletionError(limited,
        `{"summary":"Patched the parser.\nFollow-up: run the full suite.","evidence":["call-fix"]}`)
        .length > 0,
        "completion was accepted with a follow-up in its summary");
    OpenCodeEvent completion;
    completion.toolName = "goal_complete";
    completion.toolCallId = "call-done";
    ToolResultPolicy completionPolicy;
    auto settledRejection = settleToolResult(limited, completion,
        `{"summary":"Patched the parser","evidence":["call-fix"]}`, completionPolicy);
    require(settledRejection.message.failed &&
        settledRejection.message.content.indexOf("unresolved work") >= 0,
        "the completion tool accepted an answer that declared remaining work");
    // A later successful result ends the stale prose interval: work happened
    // after the declaration, so the plan and receipts decide completion.
    auto rerunCall = msg("assistant", "");
    rerunCall.id = "rerun-call";
    rerunCall.parentId = limited.activeLeafId;
    rerunCall.toolCalls = [OpenCodeToolCall("call-rerun", "write",
        `{"filePath":"parser.d","content":"fix"}`)];
    limited.messages ~= rerunCall;
    limited.activeLeafId = rerunCall.id;
    auto rerun = msg("tool", "Ran the parser suite");
    rerun.id = "rerun-result";
    rerun.parentId = rerunCall.id;
    rerun.toolName = "write";
    rerun.toolCallId = "call-rerun";
    limited.messages ~= rerun;
    limited.activeLeafId = rerun.id;
    ensureMessageGraph(limited);
    const emptyRemaining = goalCompletionError(limited,
        `{"summary":"Patched the parser.\nRemaining: none.","evidence":["call-fix"]}`);
    require(emptyRemaining.length == 0,
        "a completion whose remaining section is explicitly empty was rejected: " ~
        emptyRemaining);
    require(goalCompletionError(limited,
        `{"summary":"Patched the parser and reran the suite.","evidence":["call-fix"]}`)
        .length == 0,
        "completion after acting on the declared work was rejected");
    writeln("PASS goal completion refuses answers that declare unfinished work");

    // An answer-only goal is proved by its answer. No receipt is required for a
    // question that never needed tool work.
    ChatSession answerGoal;
    answerGoal.goal = "What is compaction?";
    answerGoal.goalStatus = "active";
    require(goalCompletionError(answerGoal,
        `{"summary":"Compaction summarizes older context."}`).length == 0,
        "an answer-only goal was blocked for lacking a tool receipt");
    answerGoal.goal = "Remember this reference for later.";
    require(goalCompletionError(answerGoal,
        `{"summary":"Noted for this conversation."}`).length == 0,
        "a conversational goal was blocked for lacking a tool receipt");
    writeln("PASS answer-only goals complete from their answer");

    ChatSession history;
    history.goal = "first durable goal";
    history.goalStatus = "paused";
    history.goalStartedAt = 10;
    recordGoalSet(history, 10);
    require(history.goalHistory.length == 1 &&
        history.goalHistory[0].outcome == "paused",
        "setting a goal did not append history");
    history.goal = "second durable goal";
    history.goalStatus = "active";
    history.goalStartedAt = 20;
    recordGoalSet(history, 20);
    require(history.goalHistory.length == 2 &&
        history.goalHistory[0].outcome == "replaced" &&
        history.goalHistory[0].closedAt == 20 &&
        history.goalHistory[1].outcome == "active",
        "replacing a goal did not preserve the previous record");
    recordGoalOutcome(history, "completed", 30);
    require(history.goalHistory[1].outcome == "completed" &&
        history.goalHistory[1].closedAt == 30,
        "completion did not close the goal history record");
    const encodedHistory = goalHistoryToJson(history.goalHistory);
    const decodedHistory = goalHistoryFromJson(encodedHistory);
    require(decodedHistory.length == 2 &&
        decodedHistory[0].text == "first durable goal" &&
        decodedHistory[1].outcome == "completed",
        "goal history did not survive JSON round-trip");
    history.goal = "second durable goal";
    history.goalStatus = "active";
    history.goalStartedAt = 40;
    recordGoalSet(history, 40);
    require(history.goalHistory.length == 3,
        "reusing a completed goal text did not create a new history entry");
    writeln("PASS every goal set is retained in per-conversation history");

    ChatSession humanHelp;
    humanHelp.goal = "finish the task";
    humanHelp.goalStatus = "active";
    humanHelp.messages ~= msg("user", "Install and verify the app.");
    humanHelp.messages ~= msg("assistant",
        "I need you to provide the signing certificate before I can continue.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp),
        "unvalidated prose paused the goal");
    humanHelp.messages ~= msg("user",
        "The user action above is still required.", true);
    humanHelp.messages ~= msg("assistant",
        "I need you to provide the signing certificate before I can continue.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp),
        "repeated prose bypassed the validated input tool");
    ChatSession progressing;
    progressing.goal = "finish the task";
    progressing.goalStatus = "active";
    progressing.messages ~= msg("user", "Install and verify the app.");
    progressing.messages ~= msg("assistant",
        "Installed, ran the checks, and verified the result.");
    ensureMessageGraph(progressing);
    require(!goalNeedsHumanInput(progressing),
        "normal completion prose was mistaken for a human-help request");
    humanHelp.taskStatus = "waiting_input";
    auto input = msg("tool", "Signing identity required");
    input.toolName = "request_input";
    input.toolArgs = `{"reason":"Signing identity is absent from configuration","required_fact":"Signing identity","question":"Which signing identity should be used?","checked":["Signing configuration"],"independent_work_complete":true}`;
    humanHelp.messages ~= input;
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(goalNeedsHumanInput(humanHelp), "validated missing information did not suspend goal continuation");
    humanHelp.messages ~= msg("user", "Use the configured test identity.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp), "a user reply did not release the input boundary");
    require(humanHelp.goalStatus == "active", "waiting for input altered the user's goal");
    foreach (text; ["Hello", "What is compaction?", "Remember this reference for later.",
            "Explain how the renderer works", "Plan the migration without changing files",
            "Ship the first-message goal", "Implement the migration",
            "Fix the broken renderer"])
        require(automaticGoalRequest(text),
            "first message lost automatic goal adoption: " ~ text);
    require(!automaticGoalRequest("   "), "an empty first message became a goal");
    writeln("PASS every first message becomes the goal; validated input suspends continuation and a reply releases it");

    foreach (definitions; [nativeOnlyToolDefinitions(), builtinToolDefinitions()])
    {
        size_t found;
        foreach (tool; definitions)
            if (tool.name == "goal_complete") ++found;
        require(found == 1, "goal_complete must be advertised exactly once");
    }
    auto accepted = executeTool(OpenCodeToolCall("g1", "goal_complete",
        `{"summary":"done","evidence":["call-1"]}`), ".");
    require(!accepted.failed, "valid goal_complete was rejected by the tool");
    auto rejected = executeTool(OpenCodeToolCall("g2", "goal_complete",
        `{"summary":"done"}`), ".");
    require(!rejected.failed, "Session-independent executor blocked answer-only completion before intent validation");
    writeln("PASS goal_complete is advertised; session settlement owns intent-dependent evidence validation");

    AgentRuntimeEvent started;
    started.kind = AgentEventKind.threadStarted;
    started.threadId = "t-goal";
    started.payloadJson =
        `{"title":"Goal","goal":"finish it","goalStatus":"paused","goalStartedAt":42,"goalTurns":3,"goalHistory":[{"text":"finish it","outcome":"paused","startedAt":42,"closedAt":0}]}`;
    auto restored = projectAgentRuntimeEvents([started]);
    require(restored.length == 1 && restored[0].goal == "finish it" &&
        restored[0].goalStatus == "paused" &&
        restored[0].goalStartedAt == 42 && restored[0].goalTurns == 3 &&
        restored[0].goalHistory.length == 1 &&
        restored[0].goalHistory[0].text == "finish it",
        "journal projection lost persistent goal state");
    writeln("PASS durable goal state survives journal projection");
    ChatSession contractOnly;
    contractOnly.contract.id = "prior-analysis";
    contractOnly.contract.intent = "analysis";
    contractOnly.contract.requestedOutcome = "Inspect the saved evidence";
    contractOnly.goal = "Deliver the replacement objective";
    resetTaskForNewGoal(contractOnly);
    require(contractOnly.taskArchive.length == 1 &&
        parseJSON(contractOnly.taskArchive[0])["taskContract"]["id"].str == "prior-analysis",
        "Replacing a goal lost an existing task contract with an empty display objective");
    writeln("goal mode contracts passed");
    return 0;
}

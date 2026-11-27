module agent_control_turn_contracts;

/// Regression contract for the reported "loops of not doing enough when asked,
/// never trying to self verify or do anything to prove" behaviour.
///
/// One real task recorded 1,170 durable checkpoints, 486 plan reminders and 2,866
/// of 3,482 assistant messages under 220 characters. 366 checkpoint transitions
/// differed only in "Verification: required/passed", so the app appended a
/// supervisor turn after nearly every tool round and the model answered it with
/// a short status line instead of continuing the work. Its receipts also said
/// "physicalInteraction: not established by a checker receipt" on every attempt
/// (555 times) while naming no concrete next proof, so the cheapest check was
/// repeated (294 compile receipts against 36 behavioral ones).
///
/// The contract here: derived execution status never manufactures a new control
/// turn, a durable plan change still re-anchors the state, and a verification
/// receipt states what it establishes plus the exact missing proof.

import aurora;
import auroraopencode.core;
import auroraopencode.appui;
import auroraopencode.events : OpenCodeEvent;
import auroraopencode.executioncontrol : executionState;
import auroraopencode.turnpolicy : decideTurn, TurnPolicy, TurnAction;
import auroraopencode.toolsettlement : settleToolResult, ToolResultPolicy;
import auroraopencode.tools : runFilesystemHelperMode;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.stdio : writeln;

int main(string[] arguments)
{
    const helper = runFilesystemHelperMode(arguments); if (helper >= 0) return helper;
    const directory = absolutePath(buildPath(tempDir(),
        "aurora-control-turn-" ~ to!string(MonoTime.currTime.ticks)));
    const workspace = buildPath(directory, "checkout");
    const state = buildPath(directory, "state");
    mkdirRecurse(buildPath(workspace, ".git"));
    mkdirRecurse(state);

    // A compile-only receipt must not claim the model's proof did not count, and
    // it must name the behavioral check the task still needs.
    ChatSession session;
    ChatMessage request; request.id = "u1"; request.role = "user";
    request.content = "Implement the reported mouse-look fix.";
    session.messages ~= request; session.activeLeafId = request.id;
    session.objective = request.content;
    session.contract.intent = "implementation";
    session.contract.currentIntent = "implementation";
    session.verificationScope = "test-scope";

    OpenCodeEvent compileEvent;
    compileEvent.toolName = "run"; compileEvent.toolCallId = "compile-1";
    compileEvent.verificationCheck = "dmd compile";
    compileEvent.verificationPassed = true; compileEvent.verificationExitCode = 0;
    compileEvent.verificationWorkspace = workspace; compileEvent.verificationRevision = 7;
    compileEvent.text = "(no output)";
    ToolResultPolicy policy;
    policy.workspace = workspace; policy.verificationWorkspace = workspace;
    policy.currentRevision = 7;
    auto compiled = settleToolResult(session, compileEvent,
        `{"check":"compile","program":"dmd","args":["-c","source/app.d"]}`, policy);
    assert(compiled.scopedVerification, "current-source compile was not scoped evidence");
    assert(!compiled.acceptedVerification,
        "A compile-only receipt satisfied a behavioral requirement");
    assert(compiled.message.content.indexOf("physicalInteraction") < 0,
        "The receipt still told the model its proof did not count");
    assert(compiled.message.content.indexOf("nextProof") >= 0,
        "An incomplete receipt named no next proof");
    assert(compiled.message.content.indexOf("tests") >= 0,
        "The next proof did not name the outstanding behavioral check");
    assert(compiled.message.content.indexOf("does not establish behavior") >= 0,
        "The receipt did not state what compilation fails to establish");

    // A checked run reports no revision of its own; its recipe already locked
    // the declared inputs. It must still count after the workspace changed, or
    // every self-check an agent runs after its first edit is rejected and the
    // task keeps asking for proof it already produced.
    OpenCodeEvent afterEdit = compileEvent;
    afterEdit.toolCallId = "compile-after-edit";
    afterEdit.verificationRevision = 0;
    auto rechecked = settleToolResult(session, afterEdit,
        `{"check":"compile","program":"dmd","args":["-c","source/app.d"]}`, policy);
    assert(rechecked.scopedVerification,
        "A checked run was rejected after the workspace changed");
    assert(rechecked.message.verificationScope.length,
        "Accepted checked-run evidence carried no scope");

    OpenCodeEvent wrongRevision = compileEvent;
    wrongRevision.toolCallId = "compile-stale";
    wrongRevision.verificationRevision = 3;
    auto stale = settleToolResult(session, wrongRevision,
        `{"check":"compile","program":"dmd","args":["-c","source/app.d"]}`, policy);
    assert(!stale.scopedVerification,
        "A check from a different source revision was accepted");

    OpenCodeEvent testsEvent = compileEvent;
    testsEvent.toolName = "verify";
    testsEvent.toolCallId = "tests-1"; testsEvent.verificationCheck = "verify:tests";
    testsEvent.text = `{"passed":true}`;
    auto tested = settleToolResult(session, testsEvent, `{"check":"tests"}`, policy);
    assert(tested.acceptedVerification,
        "Behavioral evidence did not satisfy the required verification");
    assert(tested.message.content.indexOf("behavioral test execution") >= 0,
        "The accepted receipt did not state what it established");
    assert(tested.message.content.indexOf("nextProof") < 0,
        "A complete receipt still demanded another proof");
    writeln("PASS receipts state what a check establishes and name the missing proof");

    // A failure recorded through a checked `run` ("python tests") must be
    // clearable by a later passing `verify` of the same command
    // ("verify:tests"). Comparing the raw labels left permanent failures that
    // no passing rerun could resolve.
    ChatSession ledger;
    ChatMessage ask; ask.id = "ask"; ask.role = "user";
    ask.content = "Fix the loader and prove it.";
    ledger.messages ~= ask; ledger.activeLeafId = ask.id;
    ledger.contract.intent = "implementation";
    ledger.contract.currentIntent = "implementation";
    ledger.verificationStatus = "required";
    ledger.verificationScope = "ledger-scope";
    ChatMessage bad; bad.id = "bad"; bad.parentId = ask.id; bad.role = "tool";
    bad.toolName = "run"; bad.toolCallId = "bad-call"; bad.failed = true;
    bad.verificationCheck = "python tests"; bad.verificationScope = "ledger-scope";
    bad.toolArgs = `{"program":"python","args":["tests/run_architecture_checks.py","fixture"],"timeout":1000,"workdir":"w"}`;
    bad.content = "AssertionError: the loader fixture failed";
    ledger.messages ~= bad; ledger.activeLeafId = bad.id;
    assert(executionState(ledger).remaining.indexOf("Behavioral check") >= 0,
        "A failed behavioral check was not recorded");
    ChatMessage good; good.id = "good"; good.parentId = bad.id; good.role = "tool";
    good.toolName = "verify"; good.toolCallId = "good-call";
    good.verificationCheck = "verify:tests"; good.verificationScope = "ledger-scope";
    good.content = `{"passed":true,"steps":[{"kind":"tests","command":{"program":"python","args":["tests/run_architecture_checks.py","fixture"],"timeout":1000,"workdir":"w"}}]}`;
    ledger.messages ~= good; ledger.activeLeafId = good.id;
    assert(executionState(ledger).remaining.indexOf("Behavioral check") < 0,
        "A passing verify could not clear the same checked-run failure");
    writeln("PASS a later passing check clears the same behavioral failure across surfaces");

    // Live long-goal regression: passing Python tests wrote __pycache__, so the
    // input snapshot was invalidated. The final task checks later passed and
    // goal_complete succeeded, yet these two historical receipts vetoed every
    // final reply. They must remain unaccepted evidence without manufacturing
    // behavioral failures that an unrelated current checker cannot resolve.
    ChatSession invalidated;
    invalidated.messages ~= ask; invalidated.activeLeafId = ask.id;
    invalidated.verificationStatus = "failed";
    ChatMessage rejected = bad;
    rejected.id = "rejected-snapshot"; rejected.parentId = ask.id;
    rejected.toolCallId = "rejected-call";
    rejected.content = `{"passed":false,"error":"Source inputs or recipe changed during verification; results are stale.","failedStep":{"command":{"program":"python","args":["-m","unittest","-q","test_public","test_billing"]}},"steps":[{"passed":true,"command":{"program":"python","args":["-m","unittest","-q","test_public","test_billing"]}}]}`;
    invalidated.messages ~= rejected; invalidated.activeLeafId = rejected.id;
    auto rejectedState = executionState(invalidated);
    assert(rejectedState.verificationRequired && !rejectedState.verified,
        "An invalidated receipt counted as current verification");
    assert(rejectedState.remaining.indexOf("Behavioral check") < 0,
        "Passing tests with an invalidated snapshot created a permanent behavioral failure");
    auto finalProof = good;
    finalProof.id = "final-proof"; finalProof.parentId = rejected.id;
    finalProof.content = `{"passed":true,"steps":[{"passed":true,"command":{"program":"python","args":["-B","run_checks.py","--phase","6"]}}]}`;
    invalidated.messages ~= finalProof; invalidated.activeLeafId = finalProof.id;
    ChatMessage finalAnswer;
    finalAnswer.id = "final-answer"; finalAnswer.parentId = finalProof.id;
    finalAnswer.role = "assistant"; finalAnswer.content = "All six milestones and final checks passed.";
    invalidated.messages ~= finalAnswer; invalidated.activeLeafId = finalAnswer.id;
    invalidated.verificationStatus = "passed";
    invalidated.goal = "Implement the entire billing delivery.";
    invalidated.goalStatus = "completed";
    TurnPolicy completionPolicy; completionPolicy.toolsEnabled = true;
    auto completed = decideTurn(invalidated, completionPolicy);
    assert(completed.action == TurnAction.settle && completed.turnStatus == "completed",
        "A completed verified goal still loops on an invalidated historical receipt");

    // Actual failing behavior remains an obligation until that check passes.
    // Neither a different successful checker nor a source-staleness label can
    // conceal it.
    invalidated.messages[1].content = `{"passed":false,"error":"Source inputs or recipe changed during verification; results are stale.","steps":[{"passed":false}]}`;
    assert(executionState(invalidated).remaining.indexOf("Behavioral check") >= 0,
        "A stale-input label erased a real failed test");
    invalidated.messages[1].content = `{"passed":false,"error":"Verification step failed.","steps":[{"passed":false}]}`;
    assert(decideTurn(invalidated, completionPolicy).action == TurnAction.request,
        "A different current check erased an actual failed behavior");
    writeln("PASS invalidated proof requires current verification without looping after verified goal completion");

    // Derived status churn must not append a new user turn; a durable plan change
    // must still re-anchor the state the model reads.
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9/v1"; settings.apiKey = "fixture";
    settings.workspace = workspace; settings.toolsEnabled = true;
    settings.legacyTools = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto deadline = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    {
        window.onNativeTick(0.05); root.projectTranscriptForTesting();
        Thread.sleep(2.msecs);
    }
    assert(!root.startupPendingForTesting());

    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"], [request.content]);
    root.setTaskStateForTesting(request.content, "active", "not_required");
    assert(root.ensureDurableTaskCheckpointForTesting(),
        "The turn opened without a durable task checkpoint");
    assert(!root.ensureDurableTaskCheckpointForTesting(),
        "Unchanged task state appended a duplicate checkpoint");

    const before = root.totalMessageCountForTesting();
    root.setTaskStateForTesting(request.content, "completed", "passed");
    assert(!root.ensureDurableTaskCheckpointForTesting(),
        "A verification status change manufactured a new supervisor turn");
    root.setTaskStateForTesting(request.content, "active", "required");
    assert(!root.ensureDurableTaskCheckpointForTesting(),
        "The required/passed flip manufactured a new supervisor turn");
    assert(root.totalMessageCountForTesting() == before,
        "Derived execution status appended messages the model must answer");

    root.applyPlanForTesting(
        `{"plan":[{"id":"mouse","step":"Fix the mouse-look path","status":"in_progress"}]}`);
    assert(root.ensureDurableTaskCheckpointForTesting(),
        "A changed durable plan did not re-anchor the checkpoint");
    root.setTaskStateForTesting(request.content, "completed", "passed");
    assert(!root.ensureDurableTaskCheckpointForTesting(),
        "Status churn re-appended the checkpoint after a plan change");
    writeln("PASS one control turn per durable state change; derived status stays silent");
    return 0;
}

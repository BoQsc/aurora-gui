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

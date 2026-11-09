module auroraopencode.toolsettlement;

import auroraopencode.core : ChatSession, ChatMessage;
import auroraopencode.opencode_client : OpenCodeEvent;
import auroraopencode.toolstate : terminalToolState;
import auroraopencode.orchestrator : OrchestratorDirective, parseOrchestratorDirective,
    orchestratorDirectiveError, experimentalOrchestratorIsRoutingTool;
import auroraopencode.taskflow : planUpdateText;
import auroraopencode.taskmutation : nestedPlanError, planReplacementError;
import auroraopencode.imagecontext : retireImagesSessionError;
import auroraopencode.worktracking : readPlanText;
import auroraopencode.historyrecall : readHistory;
import auroraopencode.taskcontinuation : taskInputError;
import auroraopencode.goalmode : goalCompletionError;
import auroraopencode.taskpolicy : verificationCoverage, requiredEvidence, satisfiesEvidence, sameCheckout;
import std.json : JSONValue, parseJSON;
import std.string : startsWith, indexOf;

struct ToolResultPolicy
{
    bool nestedPlans;
    string workspace, verificationWorkspace, timestamp;
    ulong currentRevision;
    bool orchestratorEnabled, routingHalted;
}

struct ToolSettlement
{
    ChatMessage message;
    bool checkerAttempt, scopedVerification, acceptedVerification;
    OrchestratorDirective routing;
}

/// Resolve semantic validation and receipt coverage from one captured state.
/// Receipt coverage may inspect recipe inputs; callers must account for this
/// filesystem effect. No scheduler, widgets, clock or settings are consulted.
ToolSettlement settleToolResult(const ref ChatSession session,
    const ref OpenCodeEvent event, string toolArgs, const ref ToolResultPolicy policy)
{
    OrchestratorDirective routing;
    string routingError;
    if (!event.toolFailed && experimentalOrchestratorIsRoutingTool(event.toolName))
    {
        routing = parseOrchestratorDirective(event.toolName, toolArgs);
        routingError = orchestratorDirectiveError(session, event.toolName, toolArgs,
            routing, policy.orchestratorEnabled, policy.routingHalted);
    }
    const planError = !event.toolFailed && event.toolName == "update_plan"
        ? planReplacementError(session, toolArgs) : "";
    const subplanError = !event.toolFailed &&
        event.toolName == "update_subplan"
        ? nestedPlanError(session, toolArgs, policy.nestedPlans) : "";
    const imageError = !event.toolFailed && event.toolName == "retire_images"
        ? retireImagesSessionError(session, toolArgs) : "";
    const planView = event.toolFailed ? "" : event.toolName == "read_plan"
        ? readPlanText(session, toolArgs) : event.toolName == "read_history"
        ? readHistory(session, toolArgs) : "";
    const planViewError = planView.startsWith("Error:") ? planView : "";
    const blockerError = !event.toolFailed && (event.toolName == "task_blocker" || event.toolName == "request_input")
        ? taskInputError(session, toolArgs) : "";
    const goalError = !event.toolFailed && event.toolName == "goal_complete"
        ? goalCompletionError(session, toolArgs) : "";
    const toolFailed = event.toolFailed || planError.length > 0 ||
        subplanError.length > 0 || imageError.length > 0 ||
        blockerError.length > 0 || goalError.length > 0 ||
        planViewError.length > 0 || routingError.length > 0;
    string toolText = routingError.length > 0 ? routingError : planViewError.length > 0 ? planViewError : planError.length > 0 ? planError :
        subplanError.length > 0 ? subplanError :
        imageError.length > 0 ? imageError :
        blockerError.length > 0 ? blockerError :
        goalError.length > 0 ? goalError :
        !toolFailed && event.toolName == "update_plan" ? planUpdateText(session, toolArgs) :
        !toolFailed && (event.toolName == "read_plan" || event.toolName == "read_history") ? planView : event.text;
    const scopedVerification = !toolFailed && event.verificationPassed && event.verificationExitCode == 0 &&
        event.verificationCheck.length > 0 &&
        sameCheckout(policy.verificationWorkspace, policy.workspace) &&
        event.verificationRevision == policy.currentRevision;
    const checkerAttempt = event.verificationCheck.length || event.toolName == "verify";
    const coverage = checkerAttempt ? verificationCoverage(session, scopedVerification ? event.verificationCheck : "") : "";
    const acceptedVerification = scopedVerification && satisfiesEvidence(coverage, requiredEvidence(session));
    if (checkerAttempt)
    {
        JSONValue receipt;
        receipt["toolCallId"] = event.toolCallId;
        receipt["check"] = event.verificationCheck;
        receipt["acceptedForCurrentSource"] = scopedVerification;
        receipt["coverageComplete"] = acceptedVerification;
        receipt["coverage"] = coverage;
        string[] remaining;
        foreach (kind; requiredEvidence(session))
            if (!satisfiesEvidence(coverage, [kind])) remaining ~= kind;
        receipt["remaining"] = JSONValue(remaining);
        if (!scopedVerification) receipt["reason"] = toolFailed ? "The checker failed." : "Checker workspace or source revision does not match the current task.";
        else if (!acceptedVerification) receipt["reason"] = "This check is valid evidence; overall task verification still needs the remaining required categories.";
        if (event.toolName == "verify" || event.verificationCheck.startsWith("verify:"))
        {
            try { auto result = parseJSON(toolText); result["receipt"] = receipt; toolText = result.toPrettyString(); }
            catch (Exception) {}
        }
        else toolText ~= "\nVerification receipt: " ~ receipt.toString();
    }
    if (toolFailed && (checkerAttempt || event.toolName == "run") &&
        (event.text.indexOf("AssertionError") >= 0 || event.text.indexOf("FAIL:") >= 0 ||
         event.text.indexOf("assertion failed") >= 0))
        toolText ~= "\nAssistant check-recovery guidance (not program output): " ~
            "A failed assertion establishes a mismatch, not which side is wrong. " ~
            "Recover the original requirement, identify exact inputs and units, and compute the expected result independently " ~
            "with calculator or a small standard-library calculation before editing. Compare that result with the observed implementation. " ~
            "Generated test expectations can be wrong: correct them when the original rule and independent calculation justify it. " ~
            "Preserve user-owned tests unless changing them is authorized. Do not infer stale code or a runtime defect solely from a bad expectation. " ~
            "For an analysis-only request, explain the evidence without starting a repair.";
    ChatMessage toolMessage;
    toolMessage.role = "tool";
    toolMessage.content = toolText;
    toolMessage.toolCallId = event.toolCallId;
    toolMessage.toolName = event.toolName;
    toolMessage.toolArgs = toolArgs;
    toolMessage.failed = toolFailed;
    toolMessage.toolState = terminalToolState(event.toolState, toolFailed);
    toolMessage.diffAdditions = event.diffAdditions;
    toolMessage.diffDeletions = event.diffDeletions;
    toolMessage.toolDiff = event.diffText;
    toolMessage.workspaceChanged = event.workspaceChanged;
    toolMessage.verificationCheck = scopedVerification ? event.verificationCheck : "";
    toolMessage.verificationScope = checkerAttempt ? session.verificationScope : "";
    toolMessage.toolElapsedMs = event.elapsedMs;
    toolMessage.time = policy.timestamp;
    return ToolSettlement(toolMessage, checkerAttempt, scopedVerification, acceptedVerification,
        toolFailed ? OrchestratorDirective.init : routing);
}

/// The execution owner calls this after appending the result and applying plan
/// changes. Desktop and headless execution share one completion/verification
/// transition; presentation and runtime receipt bookkeeping stay with the owner.
bool advanceToolTaskState(ref ChatSession session, const ref ToolSettlement settled,
    const ref OpenCodeEvent event, string arguments, string priorStatus, string priorScope)
{
    import auroraopencode.toolprogresspolicy : isPlainDocumentMutation, isSubstantiveMutation;
    import auroraopencode.turnpolicy : hasIncompleteTaskSteps;
    import auroraopencode.taskflow : taskInvestigation;
    const oldStatus = session.verificationStatus;
    const oldTask = session.taskStatus;
    void requireCheck()
    {
        session.verificationStatus = "required";
        if (session.taskStatus != "waiting_input") session.taskStatus = "active";
    }
    void passCheck()
    {
        session.verificationStatus = "passed";
        if (session.taskStatus != "waiting_input" && !taskInvestigation(session))
            session.taskStatus = hasIncompleteTaskSteps(session) ? "active" : "completed";
    }
    const prose = !settled.message.failed && isPlainDocumentMutation(event.toolName, arguments);
    if (!prose && (event.workspaceChanged || isSubstantiveMutation(event.toolName,
        settled.message.failed, event.diffAdditions, event.diffDeletions, event.diffText))) requireCheck();
    else if (settled.acceptedVerification) passCheck();
    else if (settled.checkerAttempt && !settled.scopedVerification &&
        !(priorStatus == "passed" && priorScope == session.verificationScope)) requireCheck();
    // A revision is conservative; explicit recipe inputs can establish that
    // cleanup did not alter the checked deliverable or checker source.
    if (!settled.message.failed && event.toolName == "remove" && session.verificationStatus == "required")
    {
        const coverage = verificationCoverage(session);
        if (coverage.length > "verify:".length && satisfiesEvidence(coverage, requiredEvidence(session))) passCheck();
    }
    return oldStatus != session.verificationStatus || oldTask != session.taskStatus;
}

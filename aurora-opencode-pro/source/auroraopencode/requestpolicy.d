module auroraopencode.requestpolicy;

import auroraopencode.core : ChatSession, ChatRequestMessage, OpenCodeToolDef, activeMessagePath;
import auroraopencode.agentloop : observationRecovery;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.contextpolicy;
import auroraopencode.projectioncache : projectContext, RequestProjectionCache, ProjectionRevision;
import auroraopencode.goalmode : goalActive;
import auroraopencode.taskpolicy : diagnosticToolAllowed;
import auroraopencode.completionhandoff : completionHandoffInstruction;
import auroraopencode.turnpolicy : hasIncompleteTaskSteps;
import auroraopencode.taskflow : taskInvestigation, missingVerificationInput;
import auroraopencode.taskcontext : taskExcerpt;
import auroraopencode.requestintent : answerOnlyRequest, directQuestionRequest,
    explanationOnlyRequest, requestIntent, stateQuestionRequest, RequestIntent;
import auroraopencode.orchestrator : experimentalOrchestratorFilterTools;
import std.json : JSONValue, JSONType, parseJSON;

// Small contexts need room for the files the tools return. Keep the complete
// schema contract (fields/types/enums/requirements), reducing prose only.
private void compactSchemaDescriptions(ref JSONValue value)
{
    if (value.type == JSONType.object)
    {
        auto object = value.object;
        object.remove("description");
        foreach (key, ref child; object)
            compactSchemaDescriptions(child);
        value = JSONValue(object);
    }
    else if (value.type == JSONType.array)
    {
        auto items = value.array;
        foreach (ref child; items) compactSchemaDescriptions(child);
        value = JSONValue(items);
    }
}

OpenCodeToolDef compactContextTool(OpenCodeToolDef tool, int contextLimit)
{
    if (contextLimit <= 0 || contextLimit > 32_768) return tool;
    tool.description = checkpointSnippet(tool.description, 600);
    try
    {
        auto schema = parseJSON(tool.parametersJson);
        compactSchemaDescriptions(schema);
        tool.parametersJson = schema.toString();
    }
    catch (Exception) {} // A malformed schema retains its original data.
    return tool;
}

/// Capabilities and prompt configuration are captured at command admission.
/// Preparation reads neither application globals nor widgets/provider clients.
struct RequestPolicy
{
    bool toolsEnabled, finalAnswer, summaryOnly, diagnosticReview;
    bool nestedPlans, orchestratorEnabled, orchestratorRouter;
    bool compactionEnabled, forceCompact;
    int contextLimit;
    size_t imageLimit = 2;
    string baseSystemPrompt, identityBlock, planPrompt, reviewPrompt, verbosity;
    string contextAnchor;
    OpenCodeToolDef[] availableTools;
    ProjectionRevision revision;
}

struct PreparedRequest
{
    size_t summaryByteBudget;
    ChatRequestMessage[] messages;
    OpenCodeToolDef[] tools;
    bool checkpointCreated, fallbackCompacted, contextCompacted;
    string oldAnchor, oldSummary;
}

PreparedRequest prepareAgentRequest(ref ChatSession session, const ref RequestPolicy policy,
    RequestProjectionCache projection = null)
{
    PreparedRequest result;
    import auroraopencode.executioncontrol : executionReadyToAnswer;
    import auroraopencode.contextpolicy : latestActualUserRequest;
    const requestText = latestActualUserRequest(session);
    const ready = executionReadyToAnswer(session);
    bool goalReply;
    if (!policy.diagnosticReview && session.goalStatus == "completed" && ready)
        foreach_reverse (index; activeMessagePath(session))
        {
            const ref message = session.messages[index];
            if (message.role == "user" && !message.internal) break;
            if (message.role == "tool" && message.toolName == "goal_complete" && !message.failed)
            { goalReply = true; break; }
        }
    const focus = !policy.diagnosticReview && !taskInvestigation(session) &&
        session.contract.intent == "implementation" && session.contract.currentIntent != "analysis" &&
        !ready && observationRecovery(session).focused();
    bool trackedChecks;
    foreach (tool; policy.availableTools) if (tool.name == "verify") trackedChecks = true;
    // Ready-to-answer means "produce the reply". Only an answer-only direct
    // question gets the tool-less handoff; a review, inspection, diagnosis or
    // repair still needs the tools to deliver a result, even when it is phrased
    // as a question. Withholding them made the model print its lookup as XML
    // call text, which the transcript then showed as the answer.
    // Answer-only means "no code change", not "no tools". Only a question whose
    // answer is recorded state, or an explicit explanation request, can be
    // answered without a lookup; otherwise a completed task left "what's in the
    // log?" with no channel to read the log.
    const finalAnswer = policy.finalAnswer || goalReply || (policy.toolsEnabled && !policy.diagnosticReview &&
        !policy.orchestratorEnabled && ready &&
        answerOnlyRequest(requestText) &&
        (explanationOnlyRequest(requestText) || stateQuestionRequest(requestText)));
    import auroraopencode.answercontract : answerContract;
    const responseContract = answerContract(requestText, policy.verbosity,
        policy.toolsEnabled && !policy.diagnosticReview && !policy.summaryOnly && !finalAnswer);
    if (policy.toolsEnabled)
    {
        ChatRequestMessage system;
        system.role = "system";
        if (finalAnswer || policy.summaryOnly)
            system.content = "Produce the final response now from " ~
                "the evidence already gathered. No tools are available in " ~
                "this request. Give the concise useful result and accurately state " ~
                "any remaining outcome. Do not ask permission to call tools." ~
                (policy.summaryOnly ? "\n" ~ completionHandoffInstruction : "") ~
                policy.reviewPrompt ~ policy.verbosity;
        else
        {
            system.content = policy.baseSystemPrompt;
            if (policy.nestedPlans)
                system.content ~= "\n# Experimental nested plans\n" ~
                    "When one existing plan step needs a detailed " ~
                    "checklist, use update_subplan with its 1-based " ~
                    "parent_step. This adds one collapsible level without " ~
                    "replacing the main plan. Keep the parent step " ~
                    "in_progress until its outcome is complete.\n";
            import auroraopencode.planprogress : initialPlanSuggestion;
            if (!policy.diagnosticReview && !focus)
                foreach (tool; policy.availableTools)
                    if (tool.name == "update_plan") { system.content ~= "\n" ~ initialPlanSuggestion ~ "\n"; break; }
            system.content ~= policy.planPrompt;
            if (focus)
                system.content ~= "\nRepeated unchanged inspection has not advanced the task. " ~
                    "For this decision use a command/check or a small necessary edit. Run the next " ~
                    "declared acceptance check" ~ (trackedChecks ? " through verify" : "") ~
                    ", or implement its specific missing behavior. Repeated passing checks and " ~
                    "Python/shell file viewers do not advance this outcome. " ~
                    "The supplied tools focus on execution and delivery for this step; normal inspection " ~
                    "returns after a real edit, new verification result or concrete checker failure. Do not ask for Continue or routine approval.\n";
        }
        system.content ~= policy.identityBlock ~ sessionInstructionsBlock(session);
        result.messages ~= system;
    }
    else
    {
        const prompt = durableTaskPrompt(session, policy.nestedPlans) ~
            policy.reviewPrompt ~ policy.planPrompt ~ sessionInstructionsBlock(session) ~ policy.verbosity;
        if (prompt.length)
        {
            ChatRequestMessage system;
            system.role = "system"; system.content = prompt;
            result.messages ~= system;
        }
    }
    if (policy.diagnosticReview)
    {
        ChatRequestMessage review;
        review.role = "system";
        review.content = "Perform an independent read-only diagnosis. Identify the exact failing outcome, " ~
            "contradictory evidence, rejected hypotheses and a reduced reproducer or concrete next fix. " ~
            "Do not edit files or mark the task complete. Report your findings for the main model to apply. " ~
            "Use at most four focused tool rounds. Source and screenshots are evidence; prior claims are not proof.";
        result.messages ~= review;
    }
    if (policy.toolsEnabled && !finalAnswer && !policy.summaryOnly)
        foreach (tool; policy.availableTools)
        {
            if (policy.diagnosticReview && !diagnosticToolAllowed(tool.name)) continue;
            if (!policy.nestedPlans && tool.name == "update_subplan") continue;
            if (!goalActive(session) && tool.name == "goal_complete") continue;
            if (focus)
            {
                import std.algorithm : canFind;
                if (trackedChecks && (tool.name == "run" || tool.name == "bash")) continue;
                if (!["run", "bash", "verify", "write", "edit", "apply_patch", "patch",
                    "process", "tool_status", "calculate", "goal_complete", "request_input", "task_blocker"].canFind(tool.name)) continue;
            }
            result.tools ~= compactContextTool(tool, policy.contextLimit);
        }
    if (policy.orchestratorEnabled)
        result.tools = experimentalOrchestratorFilterTools(result.tools, policy.orchestratorRouter);


    // The answer contract is fixed for this user request. Keep it ahead of
    // append-only tool history: the single-system compatibility projection
    // otherwise inserts each new checkpoint before it and rewrites the prefix.
    ChatRequestMessage contract;
    contract.role = "system"; contract.content = responseContract;
    result.messages ~= contract;
    const fixedBytes = requestMessageBytes(result.messages) + requestToolDefinitionBytes(result.tools) + 64;
    result.summaryByteBudget = compactionSummaryCapacity(policy.contextLimit, fixedBytes);
    result.oldAnchor = checkpointOnActivePath(session) ? session.compactedThroughMessageId : "";
    result.oldSummary = result.oldAnchor.length ? session.compactionSummary : "";
    ChatRequestMessage[] history;
    if (policy.contextAnchor.length)
        history = projectContext(session, policy.contextAnchor, false, policy.imageLimit, projection, policy.revision);
    else if (policy.orchestratorRouter)
        history = projectContext(session, "", true, policy.imageLimit, projection, policy.revision);
    else if (policy.compactionEnabled)
        history = prepareCompactedRequest(session, policy.contextLimit, fixedBytes,
            result.checkpointCreated, result.fallbackCompacted, policy.imageLimit, projection, policy.revision);
    else if (policy.forceCompact)
        history = compactRequestMessages(projectContext(session, "", false, policy.imageLimit, projection, policy.revision),
            policy.contextLimit, fixedBytes);
    else history = projectContext(session, "", false, policy.imageLimit, projection, policy.revision);
    result.contextCompacted = policy.compactionEnabled &&
        (checkpointOnActivePath(session) || result.fallbackCompacted);
    result.messages ~= history;
    return result;
}

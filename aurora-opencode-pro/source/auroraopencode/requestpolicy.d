module auroraopencode.requestpolicy;

import auroraopencode.core : ChatSession, ChatRequestMessage, OpenCodeToolDef;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.contextpolicy;
import auroraopencode.projectioncache : projectContext, RequestProjectionCache, ProjectionRevision;
import auroraopencode.goalmode : goalActive;
import auroraopencode.taskpolicy : diagnosticToolAllowed;
import auroraopencode.completionhandoff : completionHandoffInstruction;
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
    import auroraopencode.answercontract : answerContract;
    const responseContract = answerContract(latestActualUserRequest(session), policy.verbosity);
    if (policy.toolsEnabled)
    {
        ChatRequestMessage system;
        system.role = "system";
        if (policy.finalAnswer || policy.summaryOnly)
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
            system.content ~= policy.planPrompt;
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
    if (policy.toolsEnabled && !policy.finalAnswer && !policy.summaryOnly)
        foreach (tool; policy.availableTools)
        {
            if (policy.diagnosticReview && !diagnosticToolAllowed(tool.name)) continue;
            if (!policy.nestedPlans && tool.name == "update_subplan") continue;
            if (!goalActive(session) && tool.name == "goal_complete") continue;
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

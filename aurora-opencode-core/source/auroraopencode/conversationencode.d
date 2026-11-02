module auroraopencode.conversationencode;

import auroraopencode.core;
import std.json : JSONValue;
import std.math : isFinite;

public JSONValue messageToJson(const ref ChatMessage message)
{
    JSONValue messageJson;
    if (message.id.length > 0)
        messageJson["id"] = message.id;
    if (message.parentId.length > 0)
        messageJson["parentId"] = message.parentId;
    if (message.authorId.length > 0)
        messageJson["authorId"] = message.authorId;
    messageJson["role"] = message.role;
    messageJson["content"] = message.content;
    if (message.retiredImages.length) messageJson["retiredImages"] = message.retiredImages;
    if (message.reasoning.length > 0)
        messageJson["reasoning"] = message.reasoning;
    if (message.time.length > 0)
        messageJson["time"] = message.time;
    if (message.failed)
        messageJson["failed"] = true;
    if (message.error.length > 0) messageJson["error"] = message.error;
    if (message.finishReason.length > 0)
        messageJson["finishReason"] = message.finishReason;
    if (message.internal)
        messageJson["internal"] = true;
    if (message.contextCompacted)
        messageJson["contextCompacted"] = true;
    if (message.taskStateJson.length) messageJson["taskStateJson"] = message.taskStateJson;
    if (message.workspaceChanged) messageJson["workspaceChanged"] = true;
    if (message.verificationCheck.length) messageJson["verificationCheck"] = message.verificationCheck;
    if (message.verificationScope.length) messageJson["verificationScope"] = message.verificationScope;
    if (message.totalTokens > 0 || message.completionTokens > 0)
    {
        messageJson["promptTokens"] = message.promptTokens;
        messageJson["completionTokens"] = message.completionTokens;
        messageJson["totalTokens"] = message.totalTokens;
    }
    if (message.tokensPerSecondTenths > 0)
        messageJson["tokensPerSecondTenths"] =
            message.tokensPerSecondTenths;
    if (message.toolCalls.length > 0)
    {
        JSONValue calls = JSONValue(string[].init);
        foreach (call; message.toolCalls)
        {
            JSONValue callJson;
            callJson["id"] = call.id;
            callJson["name"] = call.name;
            callJson["arguments"] = call.arguments;
            calls.array ~= callJson;
        }
        messageJson["toolCalls"] = calls;
    }
    if (message.toolCallId.length > 0)
        messageJson["toolCallId"] = message.toolCallId;
    if (message.toolName.length > 0)
        messageJson["toolName"] = message.toolName;
    if (message.toolArgs.length > 0)
        messageJson["toolArgs"] = message.toolArgs;
    // File-mutating tools carry a computed diff. It must survive a
    // restart: without it an expanded edit loses its green/red `+N -M`
    // counters and its line-numbered unified body (the old behavior
    // showed only the one-line tool summary).
    if (message.diffAdditions > 0)
        messageJson["diffAdditions"] = message.diffAdditions;
    if (message.diffDeletions > 0)
        messageJson["diffDeletions"] = message.diffDeletions;
    if (message.toolDiff.length > 0)
        messageJson["toolDiff"] = message.toolDiff;
    // The tool's wall-clock duration must also survive a restart, so a
    // reloaded transcript still shows how long each command took.
    if (message.toolElapsedMs > 0)
        messageJson["toolElapsedMs"] = message.toolElapsedMs;
    if (message.toolState != ToolState.unspecified)
        messageJson["toolState"] = toolStateName(message.toolState);
    // Inline images are part of the conversation: a continued or
    // replayed turn must still reach the model as a vision request.
    if (message.images.length > 0)
    {
        JSONValue images = JSONValue(string[].init);
        foreach (image; message.images)
        {
            images.array ~= imageAttachmentToJson(image);
        }
        messageJson["images"] = images;
    }
    // A finished turn's working time is stored on its opening user
    // message, so the conversation timer survives a restart.
    if (isFinite(message.workedSeconds) && message.workedSeconds > 0)
        messageJson["workedSeconds"] = message.workedSeconds;
    return messageJson;
}

public JSONValue messagesToJson(const ChatMessage[] messages)
{
    JSONValue array = JSONValue(string[].init);
    foreach (message; messages)
        array.array ~= messageToJson(message);
    return array;
}

public JSONValue sessionMetaToJson(const ref ChatSession session, bool includePlanHistory = true)
{
    JSONValue root;
    if (session.id.length > 0) root["id"] = session.id;
    root["title"] = session.title;
    root["model"] = session.model;
    root["thinking"] = session.thinking;
    if (session.instructions.length > 0)
        root["instructions"] = session.instructions;
    if (session.toolsMode >= 0)
        root["toolsMode"] = session.toolsMode;
    if (session.projectId.length > 0)
        root["project"] = session.projectId;
    if (session.objective.length > 0) root["objective"] = session.objective;
    if (session.goal.length > 0)
    {
        root["goal"] = session.goal;
        root["goalStatus"] = session.goalStatus;
        if (session.goalStartedAt > 0)
            root["goalStartedAt"] = session.goalStartedAt;
        if (session.goalTurns > 0) root["goalTurns"] = session.goalTurns;
    }
    if (session.goalHistory.length > 0)
        root["goalHistory"] = goalHistoryToJson(session.goalHistory);
    if (session.taskStatus.length > 0)
        root["taskStatus"] = session.taskStatus;
    if (session.turnStatus.length > 0)
        root["turnStatus"] = session.turnStatus;
    if (session.unread) root["unread"] = true;
    if (session.verificationStatus.length > 0)
        root["verificationStatus"] = session.verificationStatus;
    if (session.taskSteps.length > 0)
    {
        JSONValue steps = JSONValue(string[].init);
        foreach (step; session.taskSteps)
        {
            JSONValue value;
            value["text"] = step.text;
            value["status"] = step.status;
            steps.array ~= value;
        }
        root["taskSteps"] = steps;
    }
    if (session.nestedPlans.length > 0)
        root["nestedPlans"] = nestedPlansToJson(session.nestedPlans);
    writeTaskContract(root, session, includePlanHistory);
    if (session.queuedGuidance.length > 0)
    {
        JSONValue guidance = JSONValue(string[].init);
        foreach (item; session.queuedGuidance)
            guidance.array ~= JSONValue(item);
        root["queuedGuidance"] = guidance;
    }
    if (session.queuedFollowUps.length > 0)
    {
        JSONValue followUps = JSONValue(string[].init);
        foreach (item; session.queuedFollowUps)
            followUps.array ~= JSONValue(item);
        root["queuedFollowUps"] = followUps;
    }
    if (session.queuedGuidanceContext.length)
        root["queuedGuidanceContext"] = promptContextsToJson(session.queuedGuidanceContext);
    if (session.queuedFollowUpContext.length)
        root["queuedFollowUpContext"] = promptContextsToJson(session.queuedFollowUpContext);
    // experimental: orchestrator - persist the participant roster and the
    // active speaker so a multi-agent conversation resumes correctly.
    if (session.agents.length > 0)
    {
        JSONValue agents = JSONValue(string[].init);
        foreach (agent; session.agents)
        {
            JSONValue item;
            item["id"] = agent.id;
            item["name"] = agent.name;
            if (agent.persona.length > 0) item["persona"] = agent.persona;
            if (agent.model.length > 0) item["model"] = agent.model;
            if (agent.router) item["router"] = true;
            agents.array ~= item;
        }
        root["agents"] = agents;
        if (session.activeAgentId.length > 0)
            root["activeAgentId"] = session.activeAgentId;
    }
    // experimental: orchestrator - a subagent nested chat records its parent
    // so the plan UI can list it and reopening it restores the link.
    if (session.parentSessionId.length > 0)
    {
        root["parentSession"] = session.parentSessionId;
        if (session.subagentId.length > 0)
            root["subagentId"] = session.subagentId;
    }
    if (session.nextSpeakerId.length) root["nextSpeakerId"] = session.nextSpeakerId;
    if (session.agentHops) root["agentHops"] = session.agentHops;
    if (session.activeLeafId.length > 0)
        root["activeLeaf"] = session.activeLeafId;
    // An unsubmitted prompt must survive a restart or rebuild; without this
    // the text the user was typing is lost with the process.
    if (session.draft.length > 0)
        root["draft"] = session.draft;
    // Last-activity stamp, so the sidebar can list conversations by
    // recency across a restart instead of falling back to creation order.
    if (session.updatedAt > 0)
        root["updatedAt"] = session.updatedAt;
    if (session.compactionSummary.length > 0 &&
        session.compactedThroughMessageId.length > 0)
    {
        root["compactionSummary"] = session.compactionSummary;
        root["compactedThroughMessageId"] =
            session.compactedThroughMessageId;
    }
    return root;
}

public JSONValue sessionToJson(const ref ChatSession session)
{
    auto root = sessionMetaToJson(session);
    root["messages"] = messagesToJson(session.messages);
    return root;
}

public string runtimeThreadPayload(const ref ChatSession session)
{ return runtimeThreadJson(session).toString(); }

public JSONValue runtimeThreadJson(const ref ChatSession session, bool complete = false)
{
    JSONValue payload;
    payload["title"] = session.title;
    payload["draft"] = session.draft;
    payload["model"] = session.model;
    payload["thinking"] = session.thinking;
    payload["projectId"] = session.projectId;
    payload["activeLeafId"] = session.activeLeafId;
    payload["objective"] = session.objective;
    payload["goal"] = session.goal;
    payload["goalStatus"] = session.goalStatus;
    payload["goalStartedAt"] = session.goalStartedAt;
    payload["goalTurns"] = session.goalTurns;
    payload["goalHistory"] = goalHistoryToJson(session.goalHistory);
    payload["taskStatus"] = session.taskStatus;
    payload["turnStatus"] = session.turnStatus;
    payload["verificationStatus"] = session.verificationStatus;
    // History is recorded only when it changes. Do not build hundreds of
    // revisions just to remove them from every ordinary metadata event.
    writeTaskContract(payload, session, false);
    JSONValue guidance = JSONValue(string[].init);
    foreach (item; session.queuedGuidance) guidance.array ~= JSONValue(item);
    payload["queuedGuidance"] = guidance;
    JSONValue followUps = JSONValue(string[].init);
    foreach (item; session.queuedFollowUps)
        followUps.array ~= JSONValue(item);
    payload["queuedFollowUps"] = followUps;
    payload["queuedGuidanceContext"] = promptContextsToJson(session.queuedGuidanceContext);
    payload["queuedFollowUpContext"] = promptContextsToJson(session.queuedFollowUpContext);
    if (complete)
    {
        payload["instructions"] = session.instructions;
        payload["toolsMode"] = session.toolsMode;
        payload["unread"] = session.unread;
        payload["updatedAt"] = session.updatedAt;
        payload["compactionSummary"] = session.compactionSummary;
        payload["compactedThroughMessageId"] = session.compactedThroughMessageId;
        payload["activeAgentId"] = session.activeAgentId;
        payload["nextSpeakerId"] = session.nextSpeakerId;
        payload["agentHops"] = session.agentHops;
        payload["parentSession"] = session.parentSessionId;
        payload["subagentId"] = session.subagentId;
        payload["agents"] = JSONValue.emptyArray;
        foreach (agent; session.agents)
        {
            JSONValue item; item["id"] = agent.id; item["name"] = agent.name;
            item["persona"] = agent.persona; item["model"] = agent.model; item["router"] = agent.router;
            payload["agents"].array ~= item;
        }
    }
    return payload;
}

public string runtimeMessagePayload(const ref ChatMessage message)
{
    JSONValue payload;
    payload["role"] = message.role;
    payload["content"] = message.content;
    if (message.retiredImages.length) payload["retiredImages"] = message.retiredImages;
    payload["parentId"] = message.parentId;
    if (message.reasoning.length > 0)
        payload["reasoning"] = message.reasoning;
    if (message.time.length > 0) payload["time"] = message.time;
    if (message.failed) payload["failed"] = true;
    if (message.error.length > 0) payload["error"] = message.error;
    if (message.finishReason.length > 0)
        payload["finishReason"] = message.finishReason;
    if (message.internal) payload["internal"] = true;
    if (message.contextCompacted) payload["contextCompacted"] = true;
    if (message.taskStateJson.length) payload["taskStateJson"] = message.taskStateJson;
    if (message.workspaceChanged) payload["workspaceChanged"] = true;
    if (message.verificationCheck.length) payload["verificationCheck"] = message.verificationCheck;
    if (message.verificationScope.length) payload["verificationScope"] = message.verificationScope;
    if (message.toolCallId.length > 0)
        payload["toolCallId"] = message.toolCallId;
    if (message.toolName.length > 0) payload["toolName"] = message.toolName;
    if (message.toolArgs.length > 0) payload["toolArgs"] = message.toolArgs;
    if (message.toolCalls.length > 0)
    {
        JSONValue calls = JSONValue(string[].init);
        foreach (call; message.toolCalls)
        {
            JSONValue value;
            value["id"] = call.id;
            value["name"] = call.name;
            value["arguments"] = call.arguments;
            calls.array ~= value;
        }
        payload["toolCalls"] = calls;
    }
    if (message.totalTokens > 0 || message.completionTokens > 0)
    {
        payload["promptTokens"] = message.promptTokens;
        payload["completionTokens"] = message.completionTokens;
        payload["totalTokens"] = message.totalTokens;
    }
    if (message.tokensPerSecondTenths > 0)
        payload["tokensPerSecondTenths"] = message.tokensPerSecondTenths;
    if (message.diffAdditions > 0)
        payload["diffAdditions"] = message.diffAdditions;
    if (message.diffDeletions > 0)
        payload["diffDeletions"] = message.diffDeletions;
    if (message.toolDiff.length > 0) payload["toolDiff"] = message.toolDiff;
    if (message.toolElapsedMs > 0)
        payload["toolElapsedMs"] = message.toolElapsedMs;
    if (message.toolState != ToolState.unspecified)
        payload["toolState"] = toolStateName(message.toolState);
    // Inline images are part of the item: the journal replays items over
    // the snapshot on restore, so omitting them here silently dropped a
    // vision turn back to text on the next launch.
    if (message.images.length > 0)
    {
        JSONValue images = JSONValue(string[].init);
        foreach (image; message.images)
        {
            images.array ~= imageAttachmentToJson(image);
        }
        payload["images"] = images;
    }
    if (isFinite(message.workedSeconds) && message.workedSeconds > 0)
        payload["workedSeconds"] = message.workedSeconds;
    return payload.toString();
}

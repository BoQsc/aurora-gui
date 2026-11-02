module auroraopencode.conversationcodec;

import auroraopencode.core;
import std.json : JSONValue, JSONType;

/// Metadata fields of one session object, matching `sessionMetaToJson`.
public void decodeSessionMetadata(JSONValue sessionValue,
    ref ChatSession session)
{
    if (auto field = "id" in sessionValue.object)
        session.id = field.str;
    if (auto field = "title" in sessionValue.object)
        session.title = field.str;
    if (auto field = "parentDispatchId" in sessionValue.object) session.parentDispatchId = field.str;
    if (auto field = "orchestrationState" in sessionValue.object) session.orchestrationState = field.str;
    if (auto field = "titleManual" in sessionValue.object)
        session.titleManual = field.boolean;
    if (auto field = "titleAttempts" in sessionValue.object)
        if (field.integer >= 0 && field.integer <= uint.max) session.titleAttempts = cast(uint) field.integer;
    if (auto field = "model" in sessionValue.object)
        session.model = field.str;
    if (auto field = "thinking" in sessionValue.object)
        session.thinking = field.type == JSONType.true_;
    if (auto field = "instructions" in sessionValue.object)
        if (field.type == JSONType.string)
            session.instructions = field.str;
    if (auto field = "toolsMode" in sessionValue.object)
        if (field.type == JSONType.integer)
            session.toolsMode = cast(int) field.integer;
    if (auto field = "project" in sessionValue.object)
        session.projectId = field.str;
    if (auto field = "objective" in sessionValue.object)
        session.objective = field.str;
    if (auto field = "goal" in sessionValue.object)
        if (field.type == JSONType.string) session.goal = field.str;
    if (auto field = "goalStatus" in sessionValue.object)
        if (field.type == JSONType.string) session.goalStatus = field.str;
    if (auto field = "goalStartedAt" in sessionValue.object)
        if (field.type == JSONType.integer) session.goalStartedAt = field.integer;
    if (auto field = "goalTurns" in sessionValue.object)
        if (field.type == JSONType.integer) session.goalTurns = cast(int) field.integer;
    if (auto field = "goalHistory" in sessionValue.object)
        session.goalHistory = goalHistoryFromJson(*field);
    if (auto field = "taskStatus" in sessionValue.object)
        session.taskStatus = field.str;
    if (auto field = "turnStatus" in sessionValue.object)
        session.turnStatus = field.str;
    if (auto field = "unread" in sessionValue.object)
        session.unread = field.type == JSONType.true_;
    if (auto field = "verificationStatus" in sessionValue.object)
        session.verificationStatus = field.str;
    readTaskContract(session, sessionValue);
    if (auto field = "queuedGuidance" in sessionValue.object)
        if (field.type == JSONType.array)
        {
            session.queuedGuidance = null;
            foreach (item; field.array)
                if (item.type == JSONType.string)
                    session.queuedGuidance ~= item.str;
        }
    if (auto field = "queuedFollowUps" in sessionValue.object)
        if (field.type == JSONType.array)
        {
            session.queuedFollowUps = null;
            foreach (item; field.array)
                if (item.type == JSONType.string)
                    session.queuedFollowUps ~= item.str;
        }
    if (auto field = "queuedGuidanceContext" in sessionValue.object)
        session.queuedGuidanceContext = promptContextsFromJson(*field);
    if (auto field = "queuedFollowUpContext" in sessionValue.object)
        session.queuedFollowUpContext = promptContextsFromJson(*field);
    if (auto field = "activeLeaf" in sessionValue.object)
        session.activeLeafId = field.str;
    if (auto field = "draft" in sessionValue.object)
        if (field.type == JSONType.string) session.draft = field.str;
    if (auto field = "updatedAt" in sessionValue.object)
        if (field.type == JSONType.integer && field.integer >= 0)
            session.updatedAt = field.integer;
    if (auto field = "compactionSummary" in sessionValue.object)
        if (field.type == JSONType.string)
            session.compactionSummary = field.str;
    if (auto field = "compactedThroughMessageId" in sessionValue.object)
        if (field.type == JSONType.string)
            session.compactedThroughMessageId = field.str;
    // experimental: orchestrator - read the persisted roster/speaker.
    if (auto field = "agents" in sessionValue.object)
        if (field.type == JSONType.array)
        {
            session.agents = null;
            foreach (item; field.array)
            {
                if (item.type != JSONType.object) continue;
                AgentSpec agent;
                if (auto f = "id" in item.object) agent.id = f.str;
                if (auto f = "name" in item.object) agent.name = f.str;
                if (auto f = "persona" in item.object) agent.persona = f.str;
                if (auto f = "model" in item.object) agent.model = f.str;
                if (auto f = "router" in item.object)
                    agent.router = f.type == JSONType.true_;
                if (agent.id.length > 0) session.agents ~= agent;
            }
        }
    if (auto field = "activeAgentId" in sessionValue.object)
        if (field.type == JSONType.string)
            session.activeAgentId = field.str;
    if (auto field = "parentSession" in sessionValue.object)
        if (field.type == JSONType.string)
            session.parentSessionId = field.str;
    if (auto field = "subagentId" in sessionValue.object)
        if (field.type == JSONType.string)
            session.subagentId = field.str;
    if (auto field = "nextSpeakerId" in sessionValue.object)
        if (field.type == JSONType.string) session.nextSpeakerId = field.str;
    if (auto field = "agentHops" in sessionValue.object)
        if (field.type == JSONType.integer) session.agentHops = cast(int) field.integer;
}

/// Message fields of one conversation's `messages` array, matching
/// `messageToJson`.
public void decodeMessages(JSONValue field,
    ref ChatSession session)
{
    if (field.type != JSONType.array) return;
    foreach (messageValue; field.array)
    {
        if (messageValue.type != JSONType.object) continue;
        ChatMessage message;
        if (auto f = "id" in messageValue.object)
            message.id = f.str;
        if (auto f = "parentId" in messageValue.object)
            message.parentId = f.str;
        if (auto f = "authorId" in messageValue.object)
            message.authorId = f.str;
        if (auto f = "role" in messageValue.object)
            message.role = f.str;
        if (auto f = "content" in messageValue.object)
            message.content = f.str;
        if (auto f = "reasoning" in messageValue.object)
            message.reasoning = f.str;
        if (auto f = "time" in messageValue.object)
            message.time = f.str;
        if (auto f = "failed" in messageValue.object)
            message.failed = f.type == JSONType.true_;
        if (auto f = "error" in messageValue.object)
            if (f.type == JSONType.string) message.error = f.str;
        if (auto f = "finishReason" in messageValue.object)
            if (f.type == JSONType.string) message.finishReason = f.str;
        if (auto f = "internal" in messageValue.object)
            message.internal = f.type == JSONType.true_;
        if (auto f = "contextCompacted" in messageValue.object)
            message.contextCompacted = f.type == JSONType.true_;
        if (auto f = "taskStateJson" in messageValue.object)
            if (f.type == JSONType.string) message.taskStateJson = f.str;
        if (auto f = "workspaceChanged" in messageValue.object)
            message.workspaceChanged = f.type == JSONType.true_;
        if (auto f = "verificationCheck" in messageValue.object)
            if (f.type == JSONType.string) message.verificationCheck = f.str;
        if (auto f = "verificationScope" in messageValue.object)
            if (f.type == JSONType.string) message.verificationScope = f.str;
        if (auto f = "promptTokens" in messageValue.object)
            if (f.type == JSONType.integer)
                message.promptTokens = cast(int) f.integer;
        if (auto f = "completionTokens" in messageValue.object)
            if (f.type == JSONType.integer)
                message.completionTokens = cast(int) f.integer;
        if (auto f = "totalTokens" in messageValue.object)
            if (f.type == JSONType.integer)
                message.totalTokens = cast(int) f.integer;
        if (auto f = "tokensPerSecondTenths" in messageValue.object)
            if (f.type == JSONType.integer)
                message.tokensPerSecondTenths = cast(int) f.integer;
        if (auto f = "toolCallId" in messageValue.object)
            message.toolCallId = f.str;
        if (auto f = "toolName" in messageValue.object)
            message.toolName = f.str;
        if (auto f = "toolArgs" in messageValue.object)
            message.toolArgs = f.str;
        if (auto f = "diffAdditions" in messageValue.object)
            if (f.type == JSONType.integer)
                message.diffAdditions = cast(int) f.integer;
        if (auto f = "diffDeletions" in messageValue.object)
            if (f.type == JSONType.integer)
                message.diffDeletions = cast(int) f.integer;
        if (auto f = "toolDiff" in messageValue.object)
            message.toolDiff = f.str;
        if (auto f = "toolElapsedMs" in messageValue.object)
            if (f.type == JSONType.integer)
                message.toolElapsedMs = cast(long) f.integer;
        if (auto f = "toolState" in messageValue.object)
            if (f.type == JSONType.string) message.toolState = parseToolState(f.str);
        if (auto f = "workedSeconds" in messageValue.object)
        {
            if (f.type == JSONType.integer)
                message.workedSeconds = cast(double) f.integer;
            else if (f.type == JSONType.float_)
                message.workedSeconds = f.floating;
        }
        if (auto f = "retiredImages" in messageValue.object)
            if (f.type == JSONType.array)
                foreach (id; f.array)
                    if (id.type == JSONType.string) message.retiredImages ~= id.str;
        if (auto f = "images" in messageValue.object)
        {
            if (f.type == JSONType.array)
                foreach (imageValue; f.array)
                {
                    if (imageValue.type != JSONType.object) continue;
                    auto image = imageAttachmentFromJson(imageValue);
                    if (image.base64Data.length > 0 || image.blob.length > 0 || image.originalBlob.length > 0)
                        message.images ~= image;
                }
        }
        if (auto f = "toolCalls" in messageValue.object)
        {
            if (f.type == JSONType.array)
                foreach (callValue; f.array)
                {
                    if (callValue.type != JSONType.object) continue;
                    OpenCodeToolCall call;
                    if (auto c = "id" in callValue.object)
                        call.id = c.str;
                    if (auto c = "name" in callValue.object)
                        call.name = c.str;
                    if (auto c = "arguments" in callValue.object)
                        call.arguments = c.str;
                    message.toolCalls ~= call;
                }
        }
        session.messages ~= message;
    }
}


module auroraopencode.provideradapter;

import core.sync.mutex : Mutex;

private __gshared Mutex schemaMutex;
private __gshared JSONValue[string] schemaCache;
private __gshared size_t schemaBytes;
private __gshared ulong schemaParses;
shared static this() { schemaMutex = new Mutex(); }

/// Content identity includes every schema byte. Cached JSON is only read by
/// serialization; callers cannot mutate it through the public string API.
private JSONValue toolParameters(string json)
{
    synchronized (schemaMutex)
    {
        if (auto hit = json in schemaCache) return *hit;
        JSONValue parsed;
        try parsed = parseJSON(json);
        catch (Exception) parsed = JSONValue.emptyObject;
        ++schemaParses;
        if (json.length <= 256 * 1024)
        {
            if (schemaCache.length >= 256 || schemaBytes + json.length > 4 * 1024 * 1024)
            {
                schemaCache = null;
                schemaBytes = 0;
            }
            schemaCache[json] = parsed;
            schemaBytes += json.length;
        }
        return parsed;
    }
}

ulong toolSchemaParsesForTesting() { synchronized (schemaMutex) return schemaParses; }

// Pure provider wire projection. Transport handles and conversation widgets
// stay outside this boundary; captured requests can be replayed in fixtures.
import auroraopencode.core : ChatRequestMessage, OpenCodeToolDef,
    ChatImageAttachment, defaultReasoningEffortForModel,
    isLoopbackApiBaseUrl, isOpenCodeApiBaseUrl;
import std.json : JSONValue, JSONType, parseJSON;
import std.array : appender;
import std.conv : to;

/// Per-client cache of immutable wire projections, bounded by retained input
/// plus encoded output. Keys use string identity; entries retain those strings
/// so allocation reuse cannot alias an older message. Arrays are detached.
public final class WireProjectionCache
{
    private struct Entry { ChatRequestMessage input; string json; }
    private Entry[string] _messages;
    private size_t _bytes;
    private ulong _hits, _misses;
    private enum size_t maxBytes = 8 * 1024 * 1024;
    private static string identity(string value)
    {
        return to!string(cast(size_t) value.ptr) ~ ":" ~ to!string(value.length) ~ ";";
    }
    string message(const ref ChatRequestMessage input, bool reasoning)
    {
        string key = reasoning ? "1;" : "0;";
        foreach (value; [input.role, input.content, input.reasoningContent, input.toolCallId])
            key ~= identity(value);
        key ~= "calls;" ~ to!string(input.toolCalls.length) ~ ";";
        foreach (call; input.toolCalls)
            key ~= identity(call.id) ~ identity(call.name) ~ identity(call.arguments);
        key ~= "images;" ~ to!string(input.images.length) ~ ";";
        foreach (image; input.images)
            key ~= identity(image.mimeType) ~ identity(image.base64Data);
        if (auto entry = key in _messages) { ++_hits; return entry.json; }
        ++_misses;
        const json = chatMessageToJson(input, reasoning).toString();
        size_t size = json.length + key.length + input.content.length + input.reasoningContent.length;
        foreach (call; input.toolCalls) size += call.id.length + call.name.length + call.arguments.length;
        foreach (image; input.images) size += image.base64Data.length;
        if (size <= maxBytes / 2)
        {
            if (_messages.length >= 512 || _bytes + size > maxBytes) { _messages = null; _bytes = 0; }
            ChatRequestMessage copy;
            copy.role = input.role;
            copy.content = input.content;
            copy.reasoningContent = input.reasoningContent;
            copy.toolCallId = input.toolCallId;
            copy.toolCalls = input.toolCalls.dup;
            copy.images = input.images.dup;
            _messages[key] = Entry(copy, json);
            _bytes += size;
        }
        return json;
    }
    struct Stats { ulong hits, misses; size_t bytes, entries; }
    Stats stats() { return Stats(_hits, _misses, _bytes, _messages.length); }
}

public JSONValue chatMessageToJson(
    const ref ChatRequestMessage message, bool forceReasoningReplay = false)
{
    JSONValue json;
    json["role"] = message.role;
    // A user turn with inline images uses the OpenAI-compatible parts
    // array. Text-only messages keep the plain string form, which is what
    // every non-vision route and the local llama.cpp templates expect.
    if (message.images.length > 0)
        json["content"] = chatContentParts(message);
    else
        json["content"] = message.content;
    // DeepSeek/CommandCode-style reasoning models require the assistant's
    // reasoning_content to be echoed on the following tool round. Include
    // an empty value for legacy persisted tool calls: presence is required
    // even when an older Aurora build failed to save the returned text.
    // `forceReasoningReplay` extends that to every assistant message; it is
    // the recovery for a provider that rejected an earlier attempt with
    // exactly this complaint.
    if (message.role == "assistant" &&
        (forceReasoningReplay || message.reasoningContent.length > 0 ||
            message.toolCalls.length > 0))
        json["reasoning_content"] = message.reasoningContent;
    if (message.role == "tool" && message.toolCallId.length > 0)
        json["tool_call_id"] = message.toolCallId;
    if (message.toolCalls.length > 0)
    {
        JSONValue calls = JSONValue(string[].init);
        foreach (call; message.toolCalls)
        {
            JSONValue callJson;
            callJson["id"] = call.id;
            callJson["type"] = "function";
            JSONValue funcDef;
            funcDef["name"] = call.name;
            funcDef["arguments"] = call.arguments;
            callJson["function"] = funcDef;
            calls.array ~= callJson;
        }
        json["tool_calls"] = calls;
    }
    return json;
}

/// The multimodal `content` array: the text (when present) first, then one
/// `image_url` part per image as a base64 data URL.
public JSONValue chatContentParts(
    const ref ChatRequestMessage message)
{
    JSONValue parts = JSONValue(string[].init);
    if (message.content.length > 0)
    {
        JSONValue text;
        text["type"] = "text";
        text["text"] = message.content;
        parts.array ~= text;
    }
    foreach (image; message.images)
    {
        if (image.base64Data.length == 0) continue;
        JSONValue part;
        part["type"] = "image_url";
        JSONValue url;
        url["url"] = chatImageDataUrl(image);
        part["image_url"] = url;
        parts.array ~= part;
    }
    return parts;
}

/// `data:<mime>;base64,<payload>`, defaulting the mime type so a caller
/// that only captured bytes still produces a valid URL.
public string chatImageDataUrl(const ref ChatImageAttachment image)
{
    const mime = image.mimeType.length > 0
        ? image.mimeType : "image/png";
    return "data:" ~ mime ~ ";base64," ~ image.base64Data;
}

/// llama.cpp chat templates (including Qwen 3/3.5 templates) commonly
/// require the system/developer instruction to be the first message and
/// allow only one such block. Aurora can add later system checkpoints when
/// compacting a long tool history, so fold every instruction block into a
/// single leading system message before serialization. Removing them from
/// their old positions also preserves assistant tool_calls -> tool result
/// adjacency for strict OpenAI-compatible validators.
///
/// Folding the instruction blocks out of their positions can, however, leave
/// two assistant turns adjacent: Aurora appends hidden guidance, durable-task
/// and compaction checkpoints between continuation rounds, so removing those
/// system-role messages joins the replies they sat between. llama.cpp's Qwen
/// template runs with `prefill_assistant`, which pops a trailing assistant and
/// then rejects the request with "Cannot have 2 or more assistant messages at
/// the end of the list." Coalesce every run of adjacent assistant turns into
/// one (keeping their text, reasoning and tool calls) so the folded list never
/// ends - or continues - with two assistant messages.
public ChatRequestMessage[] normalizeSystemMessages(
    const(ChatRequestMessage)[] messages, bool strictSingleSystem)
{
    // Hosted OpenAI-compatible providers accept instruction checkpoints in
    // chronological order. Preserve them there: moving a newly appended
    // checkpoint into message zero rewrites the prefix and defeats provider
    // KV caches. Only the detected llama.cpp compatibility path needs the
    // destructive single-leading-system fold below.
    if (!strictSingleSystem)
    {
        ChatRequestMessage[] preserved;
        foreach (message; messages)
        {
            ChatRequestMessage copy;
            copy.role = message.role;
            copy.content = message.content;
            copy.reasoningContent = message.reasoningContent;
            copy.toolCallId = message.toolCallId;
            copy.toolCalls = message.toolCalls.dup;
            copy.images = message.images.dup;
            preserved ~= copy;
        }
        return preserved;
    }
    ChatRequestMessage combined;
    combined.role = "system";
    ChatRequestMessage[] ordinary;
    foreach (message; messages)
    {
        if (message.role == "system" || message.role == "developer")
        {
            if (message.content.length == 0) continue;
            if (combined.content.length > 0) combined.content ~= "\n\n";
            combined.content ~= message.content;
        }
        else
        {
            ChatRequestMessage copy;
            copy.role = message.role;
            copy.content = message.content;
            copy.reasoningContent = message.reasoningContent;
            copy.toolCallId = message.toolCallId;
            copy.toolCalls = message.toolCalls.dup;
            // The fold rebuilds every non-system message, so inline images
            // must be copied here too: dropping them silently turned a
            // vision turn into a text turn with no error anywhere.
            copy.images = message.images.dup;
            ordinary ~= copy;
        }
    }
    ChatRequestMessage[] projected;
    foreach (message; ordinary)
    {
        if (projected.length > 0 && projected[$ - 1].role == "assistant" &&
            message.role == "assistant")
        {
            auto previous = &projected[$ - 1];
            if (message.content.length > 0)
            {
                if (previous.content.length > 0) previous.content ~= "\n\n";
                previous.content ~= message.content;
            }
            if (message.reasoningContent.length > 0)
            {
                if (previous.reasoningContent.length > 0)
                    previous.reasoningContent ~= "\n\n";
                previous.reasoningContent ~= message.reasoningContent;
            }
            if (message.toolCalls.length > 0)
                previous.toolCalls ~= message.toolCalls;
            if (message.images.length > 0)
                previous.images ~= message.images;
            continue;
        }
        projected ~= message;
    }
    if (combined.content.length == 0) return projected;
    return [combined] ~ projected;
}

public string buildChatBody(const(ChatRequestMessage)[] messages,
    const(OpenCodeToolDef)[] tools, string model, bool thinking,
    string baseUrl, bool forceReasoningReplay = false,
    string reasoningEffort = "", int thinkingBudgetTokens = 0,
    bool llamaCppServer = false, WireProjectionCache cache = null)
{
    JSONValue root;
    root["model"] = model;
    const(ChatRequestMessage)[] projected = llamaCppServer
        ? normalizeSystemMessages(messages, true) : messages;
    auto messageList = appender!string();
    messageList.put("[");
    bool first = true;
    foreach (message; projected)
    {
        if (!first) messageList.put(",");
        first = false;
        messageList.put(cache is null ? chatMessageToJson(message, forceReasoningReplay).toString()
            : cache.message(message, forceReasoningReplay));
    }
    messageList.put("]");
    if (tools.length > 0)
    {
        JSONValue toolList = JSONValue(string[].init);
        foreach (tool; tools)
        {
            JSONValue toolJson;
            toolJson["type"] = "function";
            JSONValue funcDef;
            funcDef["name"] = tool.name;
            funcDef["description"] = tool.description;
            funcDef["parameters"] = toolParameters(tool.parametersJson);
            toolJson["function"] = funcDef;
            toolList.array ~= toolJson;
        }
        root["tools"] = toolList;
        // Match Codex's request contract: let the model return independent
        // tool calls in one response instead of paying for a fresh model
        // round-trip for every read/search. The Pro runtime still decides
        // which calls are actually safe to execute concurrently.
        root["parallel_tool_calls"] = true;
    }
    root["stream"] = true;
    // Most OpenAI-compatible servers omit usage from streamed chunks unless
    // explicitly asked. This lets the UI replace its live estimate with the
    // provider tokenizer's authoritative counts.
    JSONValue streamOptions;
    streamOptions["include_usage"] = true;
    root["stream_options"] = streamOptions;
    // Thinking on maps the composer's effort onto `reasoning_effort`. The
    // DeepSeek-class routes over-think at the provider's own default, so an
    // unset effort resolves to `low` there -- except DeepSeek 4.1 Flash,
    // which the user wants to think high by default (see
    // defaultReasoningEffortForModel).
    if (thinking)
    {
        root["reasoning_effort"] = reasoningEffort == "low" ||
            reasoningEffort == "medium" || reasoningEffort == "high"
            ? reasoningEffort : defaultReasoningEffortForModel(model);
        if (llamaCppServer && thinkingBudgetTokens > 0)
            root["thinking_budget_tokens"] = thinkingBudgetTokens;
    }
    // Thinking off must actually disable reasoning. Local llama-server and
    // the OpenCode Zen gateway both accept `reasoning_effort: "none"`
    // (Zen's validator lists none/minimal/low/medium/high/xhigh/max), so
    // send it there. CommandCode's OpenAI route accepts only
    // low/medium/high/xhigh/max -- `none` is an HTTP 400 -- so omit the
    // option there; the provider's own default applies instead. api.
    // deepseek.com is the same story via a different switch.
    else if (llamaCppServer || isLoopbackApiBaseUrl(baseUrl) ||
        isOpenCodeApiBaseUrl(baseUrl))
        root["reasoning_effort"] = "none";
    // Assemble already escaped message fragments once. Never replace strings
    // inside arbitrary JSON, where a schema or user text could match a marker.
    const options = root.toString();
    return options[0 .. $ - 1] ~ ",\"messages\":" ~ messageList.data ~ "}";
}


module auroraopencode_core_tool_sse;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind, condenseUpstreamDetailForTesting,
    persistentRateLimitForTesting, recoverableReasoningErrorForTesting,
    transientChatStatusForTesting, transientRetryAllowedForTesting,
    transientRetryBackoffMsForTesting;
import auroraopencode.core : ChatRequestMessage, OpenCodeToolCall,
    OpenCodeToolDef;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : writeln;
import std.string : indexOf, strip;

/// Feed an SSE fixture with tool-call fragments (mirrors the live probe) and
/// return only the terminal event (done/toolCalls).
private OpenCodeEvent[] runFixture(OpenCodeClient client, string payload)
{
    client.resetStreamStateForTesting();
    client.feedSseForTesting(payload);
    auto events = client.finishStreamForTesting();
    OpenCodeEvent[] terminal;
    foreach (event; events)
    {
        if (event.kind == OpenCodeEventKind.done ||
            event.kind == OpenCodeEventKind.toolCalls)
            terminal ~= event;
    }
    return terminal;
}

private void assertToolCallFixture()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");
    // DeepSeek-style stream: role header, reasoning, then fragmented tool_calls.
    const payload =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"\"}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"The\"}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\" user\"}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_00_abc\",\"type\":\"function\",\"function\":{\"name\":\"sum\",\"arguments\":\"\"}}]}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"a\\\": 1\"}}]}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\", \\\"b\\\": 2}\"}}]}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n" ~
        "data: [DONE]\n";
    auto events = runFixture(client, payload);
    assert(events.length == 1, "Expected one terminal event");
    const event = events[0];
    assert(event.kind == OpenCodeEventKind.toolCalls,
        "Expected toolCalls terminal event");
    assert(event.finishReason == "tool_calls",
        "provider finish reason was not preserved");
    assert(event.toolCalls.length == 1, "Expected one accumulated tool call");
    assert(event.toolCalls[0].id == "call_00_abc", "Tool call id lost");
    assert(event.toolCalls[0].name == "sum", "Tool call name lost");
    assert(event.toolCalls[0].arguments == "{\"a\": 1, \"b\": 2}",
        "Tool call arguments not stitched: " ~ event.toolCalls[0].arguments);
    writeln("SSE tool_calls accumulation OK: ",
        event.toolCalls[0].arguments);
    client.closeSession();
}

private void assertFinishReasonFixture()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");
    const payload =
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ~
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n" ~
        "data: [DONE]\n";
    const events = runFixture(client, payload);
    assert(events.length == 1 && events[0].kind == OpenCodeEventKind.done);
    assert(events[0].text == "partial");
    assert(events[0].finishReason == "length",
        "truncation finish reason was lost");
    writeln("Provider finish reasons survive SSE parsing");
    client.closeSession();
}

/// A few OpenAI-compatible proxies close immediately after the final data
/// event instead of writing the customary newline. The EOF path must still
/// deliver that event; it is often only the answer's last character.
private void assertFinalLineWithoutNewline()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");
    client.resetStreamStateForTesting();
    client.feedSseEofForTesting(
        `data: {"choices":[{"delta":{"content":"Z"}}]}`);
    const events = client.finishStreamForTesting();
    bool sawDelta;
    bool sawDone;
    foreach (event; events)
    {
        if (event.kind == OpenCodeEventKind.delta && event.text == "Z")
            sawDelta = true;
        if (event.kind == OpenCodeEventKind.done && event.text == "Z")
            sawDone = true;
    }
    assert(sawDelta && sawDone,
        "an unterminated final SSE line lost the last content character");
    writeln("Final SSE content survives EOF without a trailing newline");
    client.closeSession();
}

/// Build a request body with tool definitions and a tool-role message, then
/// assert the serialized JSON carries tools and tool_call_id.
private void assertRequestBody()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");

    ChatRequestMessage user;
    user.role = "user";
    user.content = "Add 1 and 2";

    ChatRequestMessage assistant;
    assistant.role = "assistant";
    assistant.content = "I'll sum.";
    assistant.reasoningContent = "I should add the numbers.";
    OpenCodeToolCall call;
    call.id = "call_00_abc";
    call.name = "sum";
    call.arguments = "{\"a\": 1, \"b\": 2}";
    assistant.toolCalls ~= call;

    ChatRequestMessage toolResult;
    toolResult.role = "tool";
    toolResult.toolCallId = "call_00_abc";
    toolResult.content = "3";

    OpenCodeToolDef sumTool;
    sumTool.name = "sum";
    sumTool.description = "Add two integers";
    sumTool.parametersJson =
        `{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}`;

    const body = client.buildBodyForTesting(
        [user, assistant, toolResult], [sumTool], "deepseek/deepseek-v4.1-flash", true);
    auto value = parseJSON(body);
    assert(value.type == JSONType.object, "Body is not an object");
    auto tools = "tools" in value.object;
    assert(tools !is null && tools.type == JSONType.array,
        "Body missing tools array");
    assert(tools.array.length == 1, "Expected one tool definition");
    assert(value.object["parallel_tool_calls"].type == JSONType.true_,
        "Tool-enabled request did not permit parallel tool calls");
    auto funcDef = "function" in tools.array[0].object;
    assert(funcDef !is null && funcDef.type == JSONType.object,
        "Tool definition missing function");
    assert(funcDef.object["name"].str == "sum", "Tool name missing");
    assert(funcDef.object["parameters"].type == JSONType.object,
        "Tool parameters not embedded as an object");

    auto messages = "messages" in value.object;
    assert(messages !is null && messages.type == JSONType.array,
        "Body missing messages");
    assert(messages.array.length == 3, "Expected 3 messages");
    // assistant message carries tool_calls
    auto assistantJson = messages.array[1];
    auto toolCalls = "tool_calls" in assistantJson.object;
    assert(toolCalls !is null && toolCalls.type == JSONType.array,
        "Assistant message missing tool_calls");
    auto replayedReasoning = "reasoning_content" in assistantJson.object;
    assert(replayedReasoning !is null &&
        replayedReasoning.type == JSONType.string &&
        replayedReasoning.str == "I should add the numbers.",
        "Assistant reasoning state was not replayed with tool_calls");
    // tool message carries tool_call_id
    auto toolJson = messages.array[2];
    assert(toolJson.object["role"].str == "tool", "Tool role wrong");
    assert(toolJson.object["tool_call_id"].str == "call_00_abc",
        "Tool message missing tool_call_id");
    writeln("Request body with tools serializes correctly");
    client.closeSession();
}

/// Plain chat (no tools) must serialize exactly like before: messages only.
private void assertPlainBody()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");
    ChatRequestMessage user;
    user.role = "user";
    user.content = "Hi";
    const body = client.buildBodyForTesting([user], null,
        "deepseek/deepseek-v4.1-flash", true);
    auto value = parseJSON(body);
    assert(("tools" in value.object) is null, "Plain chat sent tools");
    assert(("parallel_tool_calls" in value.object) is null,
        "Plain chat sent a tool-only request option");
    assert(value.object["reasoning_effort"].str == "high",
        "Thinking=on did not request hosted reasoning");
    auto thinkingOff = parseJSON(client.buildBodyForTesting([user], null,
        "deepseek/deepseek-v4.1-flash", false));
    assert(("reasoning_effort" in thinkingOff.object) is null,
        "Thinking=off still enabled hosted reasoning");
    writeln("Plain chat body stays tool-free");
    client.closeSession();
}

/// The failure this recovery exists for: the OpenCode Go route refused a
/// thinking-mode continuation because the assistant's `reasoning_content` was
/// not replayed. It is a repairable request-shape problem, not a fatal upstream
/// error, and any text that does reach the transcript must be the provider's
/// own sentence instead of the gateway's wrapper chain.
private void assertReasoningReplayRecovery()
{
    const live =
        "HTTP 400: Error from provider (Console Go): Upstream request failed: " ~
        "[invalid_request_error] The `reasoning_content` in the thinking mode " ~
        "must be passed back to the API.";
    assert(recoverableReasoningErrorForTesting(live),
        "A missing reasoning_content replay was treated as fatal");
    assert(recoverableReasoningErrorForTesting(
        `{"error":{"message":"The reasoning_content in the thinking mode ` ~
        `must be passed back to the API."}}`),
        "The raw JSON envelope hid the reasoning replay failure");
    assert(!recoverableReasoningErrorForTesting("HTTP 401: invalid api key"),
        "An unrelated auth failure was misread as a reasoning problem");
    assert(!recoverableReasoningErrorForTesting(
        "rate limit exceeded for reasoning tokens"),
        "A rate limit was misread as a reasoning replay problem");

    assert(condenseUpstreamDetailForTesting(live) ==
        "HTTP 400: Error from provider (Console Go): Upstream request failed: " ~
        "[invalid_request_error] The `reasoning_content` in the thinking mode " ~
        "must be passed back to the API.",
        "A message that is not a bare gateway wrapper was rewritten");
    // The client condenses the provider's own message (already unwrapped from
    // the HTTP status and JSON envelope by `formatHttpErrorDetail`).
    const providerMessage =
        "Error from provider (Console Go): Upstream request failed: " ~
        "[invalid_request_error] The `reasoning_content` in the thinking mode " ~
        "must be passed back to the API.";
    assert(condenseUpstreamDetailForTesting(providerMessage) ==
        "The `reasoning_content` in the thinking mode must be passed back to " ~
        "the API.",
        "Gateway wrapping still leaks into the transcript: " ~
        condenseUpstreamDetailForTesting(providerMessage));
    assert(condenseUpstreamDetailForTesting(
        "[invalid_request_error] tool_call_id must follow a tool_calls " ~
        "message") == "tool_call_id must follow a tool_calls message",
        "A provider error code prefix was left in the message");
    assert(condenseUpstreamDetailForTesting("HTTP 500: server exploded") ==
        "HTTP 500: server exploded",
        "A plain provider message was rewritten");
    writeln("Reasoning replay rejections are recognized and condensed");
}

/// A provider that rejected an attempt for a missing reasoning replay gets the
/// field forced onto every assistant message, including ones whose reasoning
/// text was never captured (a Thinking=off turn, or a legacy saved chat).
private void assertForcedReasoningReplayBody()
{
    auto client = new OpenCodeClient("https://example.com/v1", "test-key");

    ChatRequestMessage user, assistant, toolResult;
    user.role = "user";
    user.content = "Continue";
    assistant.role = "assistant";
    assistant.content = "Working on it.";
    OpenCodeToolCall call;
    call.id = "call_1";
    call.name = "read";
    call.arguments = "{}";
    assistant.toolCalls ~= call;
    toolResult.role = "tool";
    toolResult.toolCallId = "call_1";
    toolResult.content = "ok";

    const plain = parseJSON(client.buildBodyForTesting(
        [user, assistant, toolResult], null, "deepseek/x", true));
    auto plainAssistant = plain.object["messages"].array[1];
    assert(("reasoning_content" in plainAssistant.object) !is null &&
        plainAssistant.object["reasoning_content"].str == "",
        "A tool round stopped replaying an (empty) reasoning_content");

    // An assistant answer with no reasoning and no tool calls is normally sent
    // without the field; only the recovery path forces its presence.
    ChatRequestMessage answer;
    answer.role = "assistant";
    answer.content = "Earlier answer";
    const omitted = parseJSON(client.buildBodyForTesting(
        [user, answer], null, "deepseek/x", true));
    assert(("reasoning_content" in
        omitted.object["messages"].array[1].object) is null,
        "The first attempt sent a reasoning field it did not need");
    const forced = parseJSON(client.buildBodyForTesting(
        [user, answer], null, "deepseek/x", true, true));
    auto forcedAssistant = forced.object["messages"].array[1];
    assert(("reasoning_content" in forcedAssistant.object) !is null &&
        forcedAssistant.object["reasoning_content"].str == "",
        "The recovery body did not replay reasoning_content");
    writeln("Reasoning replay recovery serializes a repairable body");
    client.closeSession();
}

/// llama-server's conventional local endpoint uses HTTP, needs no key, and
/// accepts reasoning_effort=none for Qwen's non-thinking mode.
private void assertLlamaServerCompatibility()
{
    auto client = new OpenCodeClient("http://127.0.0.1:8080/v1", "");
    assert(!client.secureTransportForTesting(client.baseUrl()),
        "local llama-server was incorrectly forced through TLS");
    assert(client.secureTransportForTesting("https://example.com/v1"),
        "HTTPS provider lost TLS transport");

    ChatRequestMessage user;
    user.role = "user";
    user.content = "Hi";
    auto off = parseJSON(client.buildBodyForTesting([user], null,
        "qwen-local", false));
    assert(off.object["reasoning_effort"].str == "none",
        "local Thinking=off did not disable llama-server reasoning");
    auto on = parseJSON(client.buildBodyForTesting([user], null,
        "qwen-local", true));
    assert(on.object["reasoning_effort"].str == "high",
        "local Thinking=on did not request reasoning");

    // Aurora's long-history compactor can contribute later instruction
    // checkpoints. Qwen's llama.cpp Jinja template rejects a second/midstream
    // system or developer message, so the wire payload must contain one merged
    // system block at index zero.
    ChatRequestMessage initial, checkpoint, developer, assistant;
    initial.role = "system";
    initial.content = "Primary instructions";
    assistant.role = "assistant";
    assistant.content = "Earlier answer";
    checkpoint.role = "system";
    checkpoint.content = "Compaction checkpoint";
    developer.role = "developer";
    developer.content = "Durable task state";
    auto strict = parseJSON(client.buildBodyForTesting(
        [user, initial, assistant, checkpoint, developer], null,
        "qwen-local", false));
    const wireMessages = strict.object["messages"].array;
    assert(wireMessages.length == 3,
        "system/developer blocks were not folded into one message");
    assert(wireMessages[0].object["role"].str == "system",
        "merged system message is not first");
    assert(wireMessages[0].object["content"].str ==
        "Primary instructions\n\nCompaction checkpoint\n\nDurable task state",
        "merged system message lost or reordered instructions");
    foreach (index, message; wireMessages)
        if (index > 0)
            assert(message.object["role"].str != "system" &&
                message.object["role"].str != "developer",
                "llama-server payload still contains a later instruction");
    writeln("llama-server HTTP and reasoning compatibility serialize correctly");
    client.closeSession();
}

int main()
{
    assertReasoningReplayRecovery();
    assert(transientChatStatusForTesting(500));
    assert(transientChatStatusForTesting(502));
    assert(transientChatStatusForTesting(503));
    assert(transientChatStatusForTesting(504));
    assert(!transientChatStatusForTesting(400));
    assert(!transientChatStatusForTesting(401));
    // 429 ("provider temporarily unavailable / rate limited") is replayed
    // instead of failing the turn.
    assert(transientChatStatusForTesting(429));
    // A 5xx keeps its short bounded budget: three attempts, then the turn fails
    // rather than hanging on a request the server refuses every time.
    assert(transientRetryAllowedForTesting(500, 1));
    assert(transientRetryAllowedForTesting(500, 2));
    assert(!transientRetryAllowedForTesting(500, 3));
    assert(!transientRetryAllowedForTesting(400, 1));
    // A 429 is replayed until it succeeds, at a steady three-second interval:
    // frequent enough to catch the provider the moment it returns, and slow
    // enough not to hammer a gateway that is already refusing requests.
    assert(transientRetryAllowedForTesting(429, 1));
    assert(transientRetryAllowedForTesting(429, 50));
    assert(transientRetryBackoffMsForTesting(429, 1) == 3_000);
    assert(transientRetryBackoffMsForTesting(429, 2) == 3_000);
    assert(transientRetryBackoffMsForTesting(429, 500) == 3_000);
    // Walk a real sequence: ten attempts are ten three-second pauses, with no
    // growing gap that would delay the reply once the provider recovers.
    {
        int waitedMs;
        uint attempts;
        foreach (uint attempt; 1 .. 11)
        {
            if (!transientRetryAllowedForTesting(429, attempt)) break;
            ++attempts;
            waitedMs += transientRetryBackoffMsForTesting(429, attempt);
        }
        assert(attempts == 10, "every 429 attempt is allowed");
        assert(waitedMs == 30_000, "429 replays every 3 s");
    }
    writeln("HTTP 429 is replayed every 3 s until the provider answers");
    // The two 429 bodies the app actually receives. A provider that is merely
    // busy is replayed until it answers; a 429 that says the caller is out of
    // quota is not, because the reason and its reset time are the point of the
    // message and an endless replay would hide them.
    assert(!persistentRateLimitForTesting(
        "Upstream model provider is temporarily unavailable. Please try " ~
        "again in a moment."));
    assert(persistentRateLimitForTesting(
        "5-hour usage limit reached. Resets in 3hr 52min. To continue using " ~
        "this model now, enable usage from your available balance: " ~
        "https://opencode.ai/workspace/wrk_01KZ5XCHTZX2Q3GZA0Q6JWAYQG/go"));
    assert(persistentRateLimitForTesting(
        "Weekly quota exhausted; reset in 2 days."));
    writeln("A quota 429 keeps its reason; a busy provider is retried");
    assertToolCallFixture();
    assertFinishReasonFixture();
    assertFinalLineWithoutNewline();
    assertRequestBody();
    assertPlainBody();
    assertForcedReasoningReplayBody();
    assertLlamaServerCompatibility();
    writeln("aurora-opencode-core tool SSE tests passed.");
    return 0;
}

module auroraopencode_core_tool_sse;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind, transientChatStatusForTesting;
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
    assert(event.toolCalls.length == 1, "Expected one accumulated tool call");
    assert(event.toolCalls[0].id == "call_00_abc", "Tool call id lost");
    assert(event.toolCalls[0].name == "sum", "Tool call name lost");
    assert(event.toolCalls[0].arguments == "{\"a\": 1, \"b\": 2}",
        "Tool call arguments not stitched: " ~ event.toolCalls[0].arguments);
    writeln("SSE tool_calls accumulation OK: ",
        event.toolCalls[0].arguments);
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
    assert(transientChatStatusForTesting(500));
    assert(transientChatStatusForTesting(502));
    assert(transientChatStatusForTesting(503));
    assert(transientChatStatusForTesting(504));
    assert(!transientChatStatusForTesting(400));
    assert(!transientChatStatusForTesting(401));
    assert(!transientChatStatusForTesting(429));
    writeln("Only transient upstream server failures are retried");
    assertToolCallFixture();
    assertRequestBody();
    assertPlainBody();
    assertLlamaServerCompatibility();
    writeln("aurora-opencode-core tool SSE tests passed.");
    return 0;
}

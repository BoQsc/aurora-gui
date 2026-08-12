module auroraopencode_core_tool_sse;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
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
        [user, assistant, toolResult], [sumTool], "deepseek-v4-flash", true);
    auto value = parseJSON(body);
    assert(value.type == JSONType.object, "Body is not an object");
    auto tools = "tools" in value.object;
    assert(tools !is null && tools.type == JSONType.array,
        "Body missing tools array");
    assert(tools.array.length == 1, "Expected one tool definition");
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
        "deepseek-v4-flash", true);
    auto value = parseJSON(body);
    assert(("tools" in value.object) is null, "Plain chat sent tools");
    writeln("Plain chat body stays tool-free");
    client.closeSession();
}

int main()
{
    assertToolCallFixture();
    assertRequestBody();
    assertPlainBody();
    writeln("aurora-opencode-core tool SSE tests passed.");
    return 0;
}

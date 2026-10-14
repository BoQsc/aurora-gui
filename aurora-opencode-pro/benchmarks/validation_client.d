module validation_client;

import auroraopencode.core : ChatRequestMessage;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind, ChatStartResult;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.process : environment;
import std.stdio : writeln;

// Only synthetic fixture messages enter this client. Credentials stay in the
// environment; the caller removes the scenario file and isolated app state.
int main(string[] args)
{
    const scenario = parseJSON(readText(args[1]));
    ChatRequestMessage[] messages;
    foreach (item; scenario["messages"].array)
    {
        ChatRequestMessage message;
        message.role = item["role"].str; message.content = item["content"].str;
        messages ~= message;
    }
    auto client = new OpenCodeClient(environment.get("AURORA_BENCH_BASE"), environment.get("AURORA_BENCH_KEY"));
    scope(exit) client.closeSession();
    const effort = scenario["effort"].str;
    const began = MonoTime.currTime;
    const started = client.startChatMessages(messages, null, scenario["model"].str,
        effort != "off", 1, effort == "off" ? "low" : effort);
    assert(started == ChatStartResult.accepted);
    JSONValue result;
    result["first_token_ms"] = -1; result["first_content_ms"] = -1;
    result["reasoning_chars"] = 0; result["errors"] = JSONValue.emptyArray;
    string content;
    bool done;
    const deadline = began + 90.seconds;
    OpenCodeEvent[] events;
    while (!done && MonoTime.currTime < deadline)
    {
        client.drain(events);
        foreach (event; events)
        {
            if (event.kind == OpenCodeEventKind.delta)
            {
                const elapsed = (MonoTime.currTime - began).total!"msecs";
                if (result["first_token_ms"].integer < 0) result["first_token_ms"] = elapsed;
                if (event.reasoning)
                    result["reasoning_chars"] = result["reasoning_chars"].integer + cast(long) event.text.length;
                else
                {
                    if (result["first_content_ms"].integer < 0) result["first_content_ms"] = elapsed;
                    content ~= event.text;
                }
            }
            if (event.kind == OpenCodeEventKind.usage)
            {
                result["prompt_tokens"] = event.promptTokens;
                result["cached_tokens"] = event.cachedPromptTokens;
                result["completion_tokens"] = event.completionTokens;
            }
            if (event.kind == OpenCodeEventKind.error) result["errors"].array ~= JSONValue(event.text);
            if (event.kind == OpenCodeEventKind.done) done = true;
        }
        if (!done) Thread.sleep(1.msecs);
    }
    const wait = client.waitBreakdown();
    result["uploaded_ms"] = wait.sent; result["headers_ms"] = wait.headers;
    result["request_bytes"] = wait.requestBytes;
    result["total_ms"] = (MonoTime.currTime - began).total!"msecs";
    result["completed"] = done && result["errors"].array.length == 0;
    result["content"] = content;
    writeln(result.toString());
    return done ? 0 : 4;
}

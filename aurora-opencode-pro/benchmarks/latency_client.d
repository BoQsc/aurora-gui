module latency_client;

import auroraopencode.core : ChatRequestMessage, ChatImageAttachment;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : writeln;

int main(string[] args)
{
    auto scenario = parseJSON(readText(args[3]));
    ChatRequestMessage user;
    user.role = "user";
    user.content = scenario["messages"][0]["content"].str;
    foreach (index, image; scenario["image_files"].array)
    {
        ChatImageAttachment attachment;
        attachment.mimeType = "image/png";
        if (auto mimes = "image_mimes" in scenario.object)
            attachment.mimeType = mimes.array[index].str;
        attachment.base64Data = readText(image.str);
        user.images ~= attachment;
    }
    auto client = new OpenCodeClient(args[1], environment.get("AURORA_BENCH_KEY"));
    client.setOpenCodeSession(args[2]);
    string effort;
    if (auto value = "reasoning_effort" in scenario.object) effort = value.str;
    const start = MonoTime.currTime;
    client.startChatMessages([user], null, "deepseek-v4.1-flash",
        effort.length > 0 && effort != "none", 0, effort);
    JSONValue result;
    result["first_token_ms"] = -1;
    result["content_chars"] = 0;
    result["errors"] = JSONValue(string[].init);
    bool done;
    const deadline = start + 90.seconds;
    while (!done && MonoTime.currTime < deadline)
    {
        OpenCodeEvent[] events;
        client.drain(events);
        foreach (event; events)
        {
            if (event.kind == OpenCodeEventKind.delta ||
                event.kind == OpenCodeEventKind.toolCallDelta)
            {
                if (result["first_token_ms"].integer < 0)
                    result["first_token_ms"] = (MonoTime.currTime - start).total!"msecs";
                result["content_chars"] = result["content_chars"].integer + cast(long) event.text.length;
            }
            if (event.kind == OpenCodeEventKind.usage)
            {
                result["prompt_tokens"] = event.promptTokens;
                result["cached_tokens"] = event.cachedPromptTokens;
                result["completion_tokens"] = event.completionTokens;
            }
            if (event.kind == OpenCodeEventKind.error)
            {
                result["errors"].array ~= JSONValue(event.text);
                done = true;
            }
            if (event.kind == OpenCodeEventKind.done) done = true;
        }
        Thread.sleep(5.msecs);
    }
    const wait = client.waitBreakdown();
    result["sent_ms"] = wait.sent;
    result["headers_ms"] = wait.headers;
    result["first_byte_ms"] = wait.firstByte;
    result["request_bytes"] = wait.requestBytes;
    result["total_ms"] = (MonoTime.currTime - start).total!"msecs";
    result["completed"] = done;
    client.closeSession();
    writeln(result.toString());
    return done ? 0 : 1;
}

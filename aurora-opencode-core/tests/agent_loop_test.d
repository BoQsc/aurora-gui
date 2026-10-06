module agent_loop_test;

import auroraopencode.outputguard;
import auroraopencode.providerstream;
import auroraopencode.events;
import auroraopencode.provideraudit;
import std.json : JSONValue;
import std.string : indexOf;
import std.stdio : writeln;
import std.file : readText;
import std.array : replicate;
import std.json : parseJSON;
import std.string : replace;

private OpenCodeEvent[] decode(string text, bool structured = false)
{
    auto decoder = new ProviderStreamDecoder();
    decoder.guardToolNames = ["grep", "run"];
    OpenCodeEvent[] events;
    decoder.emit = (OpenCodeEvent event) { events ~= event; };
    // Exercise token-sized fragmentation, including splits inside XML markers.
    for (size_t start = 0; start < text.length; start += 17)
    {
        JSONValue delta, choice, chunk;
        delta["content"] = text[start .. (start + 17 < text.length ? start + 17 : text.length)];
        choice["delta"] = delta;
        chunk["choices"] = JSONValue([choice]);
        decoder.feedLine("data: " ~ chunk.toString());
    }
    if (structured)
        decoder.feedLine(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"real","function":{"name":"grep","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}`);
    else
        decoder.feedLine(`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`);
    decoder.feedLine("data: [DONE]");
    decoder.finish();
    return events;
}

int main(string[] args)
{
    const call = "<invoke name=\"grep\">\n<parameter name=\"pattern\">test</parameter>\n</invoke>\n";
    auto events = decode("Let me actually run it.\n" ~ call ~ call ~ call);
    assert(events[$ - 1].kind == OpenCodeEventKind.error &&
        events[$ - 1].outputIssue == "text_tool_calls");
    foreach (event; events) assert(event.kind != OpenCodeEventKind.toolCalls);
    assert(decode(call)[$ - 1].outputIssue == "text_tool_calls",
        "A settled response containing one unexecuted invocation was accepted");
    assert(decode("Example:\n```xml\n" ~ call ~ call ~ call ~ "```\n")[$ - 1].kind == OpenCodeEventKind.done);
    assert(decode("> <invoke name=\"grep\">\n> <parameter name=\"pattern\">x</parameter>\n> </invoke>\n")[$ - 1].kind == OpenCodeEventKind.done);
    assert(decode(call, true)[$ - 1].kind == OpenCodeEventKind.toolCalls,
        "A real structured call alongside a printed example was discarded");
    enum paragraph = "Still crashing before printf. Let me check the runtime again. " ~
        "Actually the isolated tests passed, so let me try a different approach.\n\n";
    events = decode(paragraph ~ paragraph ~ paragraph ~ paragraph);
    assert(events[$ - 1].kind == OpenCodeEventKind.error &&
        events[$ - 1].outputIssue == "repeated_prose");
    assert(agentOutputIssue((paragraph ~ paragraph ~ paragraph ~ paragraph)
        .replace("\n", "\r\n"), ["run"]) == "repeated_prose");
    assert(agentOutputIssue(("Unique opening sentence.\n".replicate(3500)) ~ "\n" ~
        paragraph ~ paragraph ~ paragraph ~ paragraph, ["run"]) == "repeated_prose",
        "A loop after 64 KiB escaped detection");
    const redacted = redactProviderPayload(
        `{"apiKey":"secret","messages":[{"content":"secret"},{"content":"data:image/png;base64,PRIVATE"}],` ~
        `"tool_calls":[{"function":{"arguments":"{\"password\":\"private\",\"pattern\":\"<invoke>\"}"}}]}`, "secret");
    assert(redacted.indexOf("secret") < 0 && redacted.indexOf("private") < 0 &&
        redacted.indexOf("PRIVATE") < 0 && redacted.indexOf("<invoke>") >= 0);
    assert(redactProviderPayload("malformed secret", "secret").indexOf("secret") < 0);
    JSONValue unicode;
    unicode["content"] = "a".replicate(2047) ~ "€";
    assert(parseJSON(redactProviderPayload(unicode.toString()))["content"].str
        .indexOf("[text truncated]") >= 0, "UTF-8 truncation lost the diagnostic");
    if (args.length > 1)
    {
        assert(agentOutputIssue(readText(args[1]), ["grep", "run"], true).length > 0,
            "The archived loop response escaped detection");
        writeln("PASS archived response detected");
    }
    writeln("PASS fragmented XML, prose loops, fenced/quoted examples, real calls and diagnostic redaction");
    return 0;
}

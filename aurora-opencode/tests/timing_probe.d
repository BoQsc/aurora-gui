module auroraopencode_timing_probe;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import core.thread : Thread;
import core.time : msecs, MonoTime, Duration;
import std.file : exists, readText;
import std.stdio : writeln, writefln;
import std.string : strip;

string readKey()
{
    foreach (candidate; [
        "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode-api/data/key.txt",
        "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode/data/arena/key.txt"
    ])
    {
        if (exists(candidate))
        {
            const value = readText(candidate).strip();
            if (value.length > 0) return value;
        }
    }
    return "";
}

void measureChat(OpenCodeClient client, string label)
{
    string[] roles = ["user"];
    string[] contents = ["Reply with the single word OK."];
    auto start = MonoTime.currTime;

    Duration toBegin = Duration.zero;
    Duration toFirstDelta = Duration.zero;
    bool sawBegin;
    bool sawDelta;
    bool receivedTerminal;
    string finish = "pending";
    int deltaCount;

    client.startChat(roles, contents, "deepseek-v4-flash", false);
    OpenCodeEvent[] events;
    while (!receivedTerminal)
    {
        client.drain(events);
        foreach (event; events)
        {
            if (event.kind == OpenCodeEventKind.chatBegin && !sawBegin)
            {
                toBegin = MonoTime.currTime - start;
                sawBegin = true;
            }
            if (event.kind == OpenCodeEventKind.delta && !sawDelta)
            {
                toFirstDelta = MonoTime.currTime - start;
                sawDelta = true;
                ++deltaCount;
            }
            else if (event.kind == OpenCodeEventKind.delta)
            {
                ++deltaCount;
            }
            if (event.kind == OpenCodeEventKind.done)
            {
                finish = "done";
                receivedTerminal = true;
            }
            if (event.kind == OpenCodeEventKind.error)
            {
                finish = "error: " ~ event.text;
                receivedTerminal = true;
                break;
            }
        }
        if (!receivedTerminal)
            Thread.sleep(10.msecs);
    }

    writefln("%s -> first event: %s ms | first delta: %s ms | deltas: %s | %s",
        label,
        sawBegin ? toBegin.total!"msecs" : -1,
        sawDelta ? toFirstDelta.total!"msecs" : -1,
        deltaCount,
        finish);
}

int main()
{
    const baseUrl = "https://opencode.ai/zen/go/v1";
    const key = readKey();
    if (key.length == 0)
    {
        writeln("No API key found.");
        return 1;
    }

    // A session is reused across messages 1..3 (new behavior).
    auto reused = new OpenCodeClient(baseUrl, key);
    measureChat(reused, "REUSED msg1");
    measureChat(reused, "REUSED msg2");
    measureChat(reused, "REUSED msg3");

    // Fresh sessions interleaved (old behavior: brand-new session each time).
    auto freshA = new OpenCodeClient(baseUrl, key);
    measureChat(freshA, "FRESH   msg1 (new session)");
    auto freshB = new OpenCodeClient(baseUrl, key);
    measureChat(freshB, "FRESH   msg1 (new session)");

    reused.closeSession();
    freshA.closeSession();
    freshB.closeSession();
    return 0;
}

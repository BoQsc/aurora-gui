module auroraopencode_http_stream_test;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.core : ChatRequestMessage;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;
import std.string : indexOf;

private OpenCodeEvent waitForEnd(OpenCodeClient client)
{
    const deadline = MonoTime.currTime + seconds(10);
    OpenCodeEvent result;
    bool sawEnd;
    OpenCodeEvent[] events;
    while (MonoTime.currTime < deadline)
    {
        client.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.done || event.kind == OpenCodeEventKind.error ||
                event.kind == OpenCodeEventKind.toolCalls)
            {
                assert(!client.busy(), "Terminal event arrived before the worker released its request");
                result = event;
                sawEnd = true;
            }
        if (sawEnd && !client.busy()) return result;
        Thread.sleep(5.msecs);
    }
    assert(false, "Local stream fixture timed out");
    return OpenCodeEvent.init;
}

int main(string[] args)
{
    assert(args.length == 2);
    const base = args[1];
    auto client = new OpenCodeClient(base, "original-key");
    scope (exit) client.closeSession();
    ChatRequestMessage message;
    message.role = "user";
    message.content = "exercise the real network reader";
    ulong id;
    auto run = delegate(string model)
    {
        client.setCredentials(base, "original-key");
        const began = MonoTime.currTime;
        client.startChatMessages([message], null, model, false, ++id);
        // The launched request must retain its endpoint/key even if settings
        // change before its worker is scheduled.
        client.setCredentials(base ~ "/wrong-provider", "new-key");
        auto event = waitForEnd(client);
        writeln(model, " completed in ", (MonoTime.currTime - began).total!"msecs", " ms");
        assert(event.requestId == id, "Terminal event lost request identity");
        if (model == "keep-open" || model == "provider-error")
            assert((MonoTime.currTime - began).total!"msecs" < 1500,
                "Completion waited for an open HTTP connection to close");
        return event;
    };
    auto event = run("keep-open");
    assert(event.kind == OpenCodeEventKind.done && event.text == "Hello 😀世界",
        "Fragmented UTF-8 or completion marker was lost");
    event = run("truncated");
    assert(event.kind == OpenCodeEventKind.error && event.text.indexOf("before the reply finished") >= 0);
    event = run("provider-error");
    assert(event.kind == OpenCodeEventKind.error && event.text.indexOf("quota exhausted") >= 0);
    event = run("tool-length");
    assert(event.kind == OpenCodeEventKind.error, "Incomplete tool request was accepted");

    client.setCredentials(base, "original-key");
    const firstTokenStart = MonoTime.currTime;
    client.startChatMessages([message], null, "slow-stream", false, ++id);
    bool sawDelta;
    OpenCodeEvent[] chunks;
    while (!sawDelta && MonoTime.currTime - firstTokenStart < 500.msecs)
    {
        client.drain(chunks);
        foreach (chunk; chunks)
            if (chunk.kind == OpenCodeEventKind.delta) sawDelta = true;
        if (!sawDelta) Thread.sleep(5.msecs);
    }
    assert(sawDelta && client.busy(), "Short tokens were buffered until completion");
    assert(waitForEnd(client).kind == OpenCodeEventKind.done);

    client.setCredentials(base, "original-key");
    client.startChatMessages([message], null, "cancel", false, ++id);
    Thread.sleep(100.msecs);
    const stoppedAt = MonoTime.currTime;
    client.cancel();
    event = waitForEnd(client);
    assert(event.kind == OpenCodeEventKind.done && event.cancelled && event.requestId == id);
    assert((MonoTime.currTime - stoppedAt).total!"msecs" < 1500);
    event = run("keep-open");
    assert(event.kind == OpenCodeEventKind.done, "A stopped handle broke the next request");
    auto closing = new OpenCodeClient(base, "original-key");
    closing.startChatMessages([message], null, "cancel", false, ++id);
    Thread.sleep(100.msecs);
    closing.closeSession();
    event = waitForEnd(closing);
    assert(event.cancelled && !closing.busy(), "Shutdown did not release the worker");
    closing.closeSession();
    auto models = new OpenCodeClient(base, "original-key");
    scope (exit) models.closeSession();
    models.fetchModels();
    models.setCredentials(base ~ "/next", "new-key");
    models.fetchModels();
    bool sawOldModels, sawNewModels;
    const modelsDeadline = MonoTime.currTime + seconds(5);
    while (!sawNewModels && MonoTime.currTime < modelsDeadline)
    {
        models.drain(chunks);
        foreach (chunk; chunks)
            if (chunk.kind == OpenCodeEventKind.models)
            {
                if (chunk.text == base) sawOldModels = chunk.modelIds == ["old-model"];
                if (chunk.text == base ~ "/next") sawNewModels = chunk.modelIds == ["new-model"];
            }
        Thread.sleep(5.msecs);
    }
    assert(sawOldModels && sawNewModels, "Provider switching lost the model refresh or mixed credentials");
    writeln("Real HTTP: keep-alive completion, UTF-8 fragmentation, provider errors, EOF, " ~
        "tool truncation, credential isolation, short tokens, cancel/resend, shutdown " ~
        "and model refresh passed");
    return 0;
}

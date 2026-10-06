module latency_transport_contracts;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind, ChatStartResult;
import auroraopencode.httptransport : AsyncHttpRequest, transportPoolStats;
import auroraopencode.latency : LatencyStage, LatencySnapshot;
import auroraopencode.provideradapter : buildChatBody, toolSchemaParsesForTesting;
import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt,
    setSystemPromptModules, textModule;
import auroraopencode.core : ChatRequestMessage, OpenCodeToolDef;
import auroraopencode.workerbudget : WorkerBudget;
import auroraopencode.retrypolicy : ProviderRetryPolicy;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.json : parseJSON;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

LatencySnapshot complete(string base, string model, ulong id, bool local = false)
{
    auto budget = new WorkerBudget(1);
    auto client = new OpenCodeClient(base, "fixture-key", ProviderRetryPolicy(5.seconds), budget);
    scope(exit) client.closeSession();
    size_t wakes;
    import core.atomic : atomicOp, atomicLoad;
    shared size_t notifications;
    client.setEventWake(delegate() { atomicOp!"+="(notifications, 1); });
    assert(client.startChatMessages(null, null, model, false, id, "", 0, local) == ChatStartResult.accepted);
    const deadline = MonoTime.currTime + 8.seconds;
    bool done, sawFirstBeforeDone;
    string text;
    OpenCodeEvent[] events;
    while (!done && MonoTime.currTime < deadline)
    {
        client.drain(events);
        foreach (event; events)
        {
            if (event.kind == OpenCodeEventKind.delta)
            {
                text ~= event.text;
                if (!client.busy()) continue;
                sawFirstBeforeDone = true;
            }
            if (event.kind == OpenCodeEventKind.error) assert(false, event.text);
            if (event.kind == OpenCodeEventKind.done) done = true;
        }
        if (!done) Thread.sleep(1.msecs);
    }
    assert(done && text == "firstlast" && sawFirstBeforeDone,
        "Stream buffered its first chunk until completion, or lost bytes");
    assert(atomicLoad(notifications) >= 2, "Empty-to-nonempty queue notifications were lost");
    const released = MonoTime.currTime + 2.seconds;
    while (budget.active() && MonoTime.currTime < released) Thread.sleep(1.msecs);
    assert(budget.active() == 0);
    return client.latency().snapshot();
}

int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length);
    environment["AURORA_HTTP_TRANSPORT"] = "winhttp";
    environment.remove("AURORA_TOKEN_PREFLIGHT");
    const before = transportPoolStats();
    const fast = complete(base, "skip-count", 1001, true);
    const warm = complete(base, "warm", 1002);
    const reused = transportPoolStats();
    assert(reused.created == before.created + 1 && reused.activeLeases == 0,
        "Sequential clients did not retain one shared connection handle");
    assert(fast.requestId == 1001 && warm.requestId == 1002);
    assert(fast.microseconds[LatencyStage.firstToken] >= fast.microseconds[LatencyStage.firstByte]);
    assert(fast.microseconds[LatencyStage.firstByte] >= fast.microseconds[LatencyStage.headers]);
    assert(fast.microseconds[LatencyStage.serialized] >= fast.microseconds[LatencyStage.accepted]);
    environment["AURORA_TOKEN_PREFLIGHT"] = "1";
    const counted = complete(base, "counted", 1003, true);
    assert(counted.microseconds[LatencyStage.firstToken] >= 450_000,
        "Opt-in exact preflight did not preserve authoritative token counting");
    environment.remove("AURORA_TOKEN_PREFLIGHT");
    const retried = complete(base, "retry", 1004);
    assert(retried.microseconds[LatencyStage.firstToken] >= 0);

    // All eight requests must reach the server before it releases any headers.
    // Cancel one stream after their first chunks; the remaining seven survive.
    auto parallelBudget = new WorkerBudget(8);
    OpenCodeClient[] parallel;
    bool[8] first;
    bool[8] settled;
    string[8] output;
    foreach (i; 0 .. 8)
    {
        auto client = new OpenCodeClient(base, "fixture-key", ProviderRetryPolicy(5.seconds), parallelBudget);
        parallel ~= client;
        assert(client.startChatMessages(null, null, "parallel-" ~ to!string(i), false,
            2000 + i) == ChatStartResult.accepted);
    }
    const together = MonoTime.currTime + 5.seconds;
    size_t received;
    OpenCodeEvent[] batch;
    while (received < 8 && MonoTime.currTime < together)
    {
        foreach (i, client; parallel)
        {
            client.drain(batch);
            foreach (event; batch)
            {
                assert(event.kind != OpenCodeEventKind.error, event.text);
                if (event.kind == OpenCodeEventKind.delta)
                {
                    output[i] ~= event.text;
                    if (!first[i]) { first[i] = true; ++received; }
                }
                if (event.kind == OpenCodeEventKind.done) settled[i] = true;
            }
        }
        Thread.sleep(1.msecs);
    }
    assert(received == 8, "Shared transport serialized independent foreground requests");
    parallel[0].closeSession();
    const finish = MonoTime.currTime + 3.seconds;
    bool all;
    while (!all && MonoTime.currTime < finish)
    {
        all = true;
        foreach (i; 1 .. 8)
        {
            parallel[i].drain(batch);
            foreach (event; batch)
            {
                assert(event.kind != OpenCodeEventKind.error, event.text);
                if (event.kind == OpenCodeEventKind.delta) output[i] ~= event.text;
                if (event.kind == OpenCodeEventKind.done) settled[i] = true;
            }
            if (!settled[i]) all = false;
        }
        if (!all) Thread.sleep(1.msecs);
    }
    assert(all);
    foreach (i; 1 .. 8) { assert(output[i] == "firstlast"); parallel[i].closeSession(); }
    const parallelReleased = MonoTime.currTime + 2.seconds;
    while (parallelBudget.active() && MonoTime.currTime < parallelReleased) Thread.sleep(1.msecs);
    assert(parallelBudget.active() == 0 && transportPoolStats().activeLeases == 0);

    auto budget = new WorkerBudget(1);
    auto cancelled = new OpenCodeClient(base, "fixture-key", ProviderRetryPolicy(5.seconds), budget);
    assert(cancelled.startChatMessages(null, null, "hold-headers", false, 1005) == ChatStartResult.accepted);
    Thread.sleep(100.msecs);
    const stopped = MonoTime.currTime;
    cancelled.cancel();
    cancelled.closeSession();
    const stopMs = (MonoTime.currTime - stopped).total!"msecs";
    assert(stopMs < 1000);
    const released = MonoTime.currTime + 2.seconds;
    while (budget.active() && MonoTime.currTime < released) Thread.sleep(1.msecs);
    assert(budget.active() == 0 && transportPoolStats().activeLeases == 0,
        "Cancellation before headers leaked a callback context or connection lease");

    // Compatibility path must decode the same bytes and report its transport.
    environment["AURORA_HTTP_TRANSPORT"] = "wininet";
    const fallback = complete(base, "fallback", 1006);
    assert(fallback.transport == "wininet");

    // Schema content, rather than tool name alone, controls cache invalidation.
    OpenCodeToolDef tool;
    tool.name = "schema-test";
    tool.parametersJson = `{"type":"object","properties":{"n":{"type":"integer"}}}`;
    const cold = toolSchemaParsesForTesting();
    const body1 = buildChatBody(null, [tool], "fixture", false, base);
    const body2 = buildChatBody(null, [tool], "fixture", false, base);
    assert(body1 == body2 && toolSchemaParsesForTesting() == cold + 1);
    assert(parseJSON(body2)["parallel_tool_calls"].boolean);
    tool.parametersJson = `{"type":"object","properties":{"n":{"type":"string"}}}`;
    const body3 = buildChatBody(null, [tool], "fixture", false, base);
    assert(body3 != body2 && toolSchemaParsesForTesting() == cold + 2);

    setSystemPromptModules([textModule("fixture-awareness", "\nStable fixture awareness.\n")]);
    SystemPromptContext context;
    context.workspace = "workspace-a";
    context.today = "2026-10-06";
    const prompt1 = renderSystemPrompt(context);
    context.workspace = "workspace-b";
    context.today = "2026-10-07";
    const prompt2 = renderSystemPrompt(context);
    const boundary = prompt1.indexOf("# Environment");
    assert(boundary > prompt1.indexOf("Stable fixture awareness."));
    assert(prompt1[0 .. boundary] == prompt2[0 .. boundary]);
    setSystemPromptModules(null);

    // A large number of idle origins cannot grow the retained pool forever.
    foreach (port; 20000 .. 20036)
    {
        auto request = new AsyncHttpRequest("127.0.0.1", cast(ushort) port,
            "/unused", false, true);
        request.finish();
    }
    assert(transportPoolStats().handles <= 32 && transportPoolStats().activeLeases == 0);
    writeln("PASS first-chunk delivery, shared connections, opt-in preflight, 503 retry, header cancellation, fallback, schema identity, stable prompt prefix, idle pool bound");
    writeln("MEASURE fast_first_token_us=", fast.microseconds[LatencyStage.firstToken],
        " counted_first_token_us=", counted.microseconds[LatencyStage.firstToken],
        " warm_first_token_us=", warm.microseconds[LatencyStage.firstToken],
        " cancel_before_headers_ms=", stopMs);
    return 0;
}

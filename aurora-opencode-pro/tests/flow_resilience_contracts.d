module flow_resilience_contracts;

import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import auroraopencode.execution;
import auroraopencode.repository;
import auroraopencode.runtime;
import auroraopencode.provideradapter;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import core.atomic : atomicOp, atomicLoad;
import std.base64 : Base64;
import std.conv : to;
import std.file : mkdirRecurse, write, readText, dirEntries, SpanMode, rename, rmdir;
import std.json : parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.stdio : writeln;
import std.string : indexOf, endsWith;

private class Gate
{
    Mutex mutex;
    Condition changed;
    bool open;
    this() { mutex = new Mutex(); changed = new Condition(mutex); }
    void wait() { synchronized (mutex) while (!open) changed.wait(); }
    void release() { synchronized (mutex) { open = true; changed.notifyAll(); } }
}

int main()
{
    const directory = buildNormalizedPath(buildPath("flow-resilience-" ~ to!string(MonoTime.currTime.ticks)));
    mkdirRecurse(directory);
    setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    write(buildPath(directory, "ordinary.txt"), "fresh tool remains usable");
    OpenCodeClient[4] clients;
    ToolCancellation[4] tokens;
    foreach (i; 0 .. 4)
    {
        clients[i] = new OpenCodeClient("http://127.0.0.1:9", "");
        tokens[i] = new ToolCancellation();
        scheduleToolBatch(clients[i], i + 1,
            [OpenCodeToolCall("blocked-" ~ to!string(i), "read",
                `{"filePath":"ordinary.txt","_fixtureBlocked":true,"timeout":6000}`)],
            directory, tokens[i], ChangeContext.init);
    }
    string[] markers;
    const launched = MonoTime.currTime + 4.seconds;
    while (MonoTime.currTime < launched)
    {
        markers = null;
        foreach (entry; dirEntries(directory, "*.pid", SpanMode.shallow)) markers ~= entry.name;
        if (markers.length == 4) break;
        Thread.sleep(5.msecs);
    }
    assert(markers.length == 4, "Four supervised filesystem hosts did not start");
    const cancelledAt = MonoTime.currTime;
    tokens[0].cancel();
    auto fresh = new OpenCodeClient("http://127.0.0.1:9", "");
    scheduleToolBatch(fresh, 50, [OpenCodeToolCall("fresh", "read", `{"filePath":"ordinary.txt"}`)],
        directory, new ToolCancellation(), ChangeContext.init);
    bool recovered;
    const recoveryDeadline = MonoTime.currTime + 2.seconds;
    OpenCodeEvent[] events;
    while (!recovered && MonoTime.currTime < recoveryDeadline)
    {
        fresh.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning)
            {
                assert(!event.toolFailed && event.text.indexOf("fresh tool remains usable") >= 0);
                recovered = true;
            }
        if (!recovered) Thread.sleep(5.msecs);
    }
    assert(recovered, "Cancelling a blocked host did not free the shared scheduler for a fifth chat");
    const recoveryMs = (MonoTime.currTime - cancelledAt).total!"msecs";
    int settled;
    const completed = MonoTime.currTime + 8.seconds;
    while (settled < 4 && MonoTime.currTime < completed)
    {
        foreach (client; clients)
        {
            client.drain(events);
            foreach (event; events)
                if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning)
                {
                    assert(event.toolFailed);
                    ++settled;
                }
        }
        Thread.sleep(5.msecs);
    }
    assert(settled == 4, "A blocked filesystem call never published a terminal result");
    version (Windows)
    {
        import core.sys.windows.windows : OpenProcess, SYNCHRONIZE, WaitForSingleObject,
            WAIT_OBJECT_0, CloseHandle;
        import std.path : baseName;
        foreach (marker; markers)
        {
            const name = baseName(marker);
            const pid = to!uint(name[5 .. $ - 4]);
            auto handle = OpenProcess(SYNCHRONIZE, false, pid);
            if (handle !is null)
            {
                assert(WaitForSingleObject(handle, 0) == WAIT_OBJECT_0, "Timed-out host is still alive");
                CloseHandle(handle);
            }
        }
    }
    writeln("PASS four blocked hosts, cancellation releases a worker for a fifth chat, hard deadlines, zero surviving hosts; recovery_ms=",
        recoveryMs);
    const pixels = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");
    write(buildPath(directory, "image.png"), pixels);
    const image = executeTool(OpenCodeToolCall("image", "view_image", `{"filePath":"image.png"}`), directory);
    assert(!image.failed && image.images.length == 1 && image.images[0].name == "image.png" &&
        image.images[0].mimeType == "image/png" && Base64.decode(image.images[0].base64Data) == pixels);
    writeln("PASS image evidence retains name, MIME type and exact pixels across host IPC");

    auto repository = new ConversationRepository();
    scope(exit) repository.close();
    const journalPath = buildPath(directory, "events.jsonl");
    auto journal = new RepositoryRuntime(repository, journalPath);
    auto engine = new ThreadEngine("http://127.0.0.1:9", "");
    auto gate = new Gate();
    assert(repository.submit(&gate.wait));
    shared int effects;
    const enqueuedAt = MonoTime.currTime;
    assert(engine.dispatchAfterCommit(journal, 100, delegate() { atomicOp!"+="(effects, 1); }));
    assert((MonoTime.currTime - enqueuedAt).total!"msecs" < 100,
        "Effect admission waited for a blocked journal writer");
    engine.stop();
    gate.release();
    repository.flush();
    assert(atomicLoad(effects) == 0, "Stop failed to revoke an effect waiting for durable admission");
    AgentRuntimeEvent intent;
    intent.kind = AgentEventKind.turnStarted;
    intent.threadId = "fixture";
    assert(journal.enqueue(intent));
    assert(engine.dispatchAfterCommit(journal, 101, delegate() {
        assert(readAgentRuntimeEvents(journalPath).length == 1);
        atomicOp!"+="(effects, 1);
    }));
    repository.flush();
    assert(atomicLoad(effects) == 1);
    rename(journalPath, journalPath ~ ".backup");
    mkdirRecurse(journalPath);
    assert(journal.enqueue(intent));
    assert(engine.dispatchAfterCommit(journal, 102, delegate() { atomicOp!"+="(effects, 1); }));
    repository.flush();
    assert(atomicLoad(effects) == 1 && journal.effectsBlocked());
    engine.client.drain(events);
    assert(events.length == 1 && events[0].kind == OpenCodeEventKind.error && events[0].requestId == 102);
    rmdir(journalPath);
    rename(journalPath ~ ".backup", journalPath);
    writeln("PASS nonblocking admission, Stop before acknowledgement, durable ordering, failed journal prevents effects");

    auto cache = new WireProjectionCache();
    ChatRequestMessage message;
    message.role = "assistant";
    message.content = "quoted \"body\"";
    message.toolCalls = [OpenCodeToolCall("call", "read", "old")];
    const cold = buildChatBody([message], null, "fixture", false, "http://127.0.0.1", false, "", 0, false, cache);
    const warm = buildChatBody([message], null, "fixture", false, "http://127.0.0.1", false, "", 0, false, cache);
    assert(parseJSON(cold) == parseJSON(warm) && cache.stats().hits == 1);
    message.toolCalls[0].arguments = "new";
    const changed = buildChatBody([message], null, "fixture", false, "http://127.0.0.1", false, "", 0, false, cache);
    assert(parseJSON(changed)["messages"][0]["tool_calls"][0]["function"]["arguments"].str == "new");
    assert(parseJSON(cold)["messages"][0]["tool_calls"][0]["function"]["arguments"].str == "old");
    assert(cache.stats().misses == 2 && cache.stats().bytes <= 8 * 1024 * 1024);
    writeln("PASS unchanged wire cache hit, changed tool argument invalidation, detached input and bounded retention");
    return 0;
}

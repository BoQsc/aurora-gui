module developer_context_contracts;

import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import auroraopencode.workscheduler;
import auroraopencode.conversationconfiguration;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time : MonoTime;
import std.file : exists, mkdirRecurse, readText;
import std.path : absolutePath, buildPath;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

private final class HeldWorker : WorkItem
{
    Mutex mutex; Condition wake; bool entered, released;
    this(string directory) { mutex = new Mutex(); wake = new Condition(mutex); workspace = directory; exclusive = true; }
    override void execute() { synchronized (mutex) { entered = true; wake.notifyAll(); while (!released) wake.wait(); } }
    override void settle(ulong revision) {}
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
}
int main()
{
    const directory = absolutePath("developer-context-" ~ to!string(MonoTime.currTime.ticks));
    const source = buildPath(directory, "source"), other = buildPath(directory, "other");
    mkdirRecurse(buildPath(source, ".git")); mkdirRecurse(other); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    developerSourceDirectoryHandler = () { assert(false, "A worker read host source settings"); return ""; };
    developerSourceEditCheckHandler = (string, string[], bool) { assert(false, "A worker invoked the host source guard"); return ""; };
    rebuildSourceCheckHandler = () { assert(false, "A worker invoked host rebuild preflight"); return ""; };
    syncRequestHandler = (string) { assert(false, "A worker invoked host sync settings"); return ""; };
    rebuildRequestHandler = (string) { assert(false, "A blocked rebuild reached host launch"); return false; };
    auto client = new OpenCodeClient("", ""); auto scheduler = new WorkScheduler(1, 8); auto gate = new HeldWorker(directory);
    scope (exit) { gate.release(); scheduler.close(); client.closeSession(); }
    assert(scheduler.submit(gate)); gate.waitEntered();
    ChangeContext captured; captured.developerCaptured = true; captured.developer.source = source;
    captured.developer.requireLatest = false; captured.developer.operationPending = true;
    auto blocked = new ToolBatch(client, 1, [OpenCodeToolCall("blocked", "write", `{"filePath":"blocked.md","content":"never"}`)],
        source, new ToolCancellation(), captured);
    blocked.workspaceLane = scheduler; blocked.controlLane = scheduler; blocked.start();
    captured.developer.source = other; captured.developer.operationPending = false;
    assert(blocked.developerSource == source && blocked.context.developer.operationPending, "Caller changed a queued effect's captured source policy");
    ChangeContext ordinary; ordinary.developerCaptured = true;
    auto allowed = new ToolBatch(client, 2, [OpenCodeToolCall("allowed", "write", `{"filePath":"allowed.md","content":"captured empty source"}`)],
        other, new ToolCancellation(), ordinary);
    allowed.workspaceLane = scheduler; allowed.controlLane = scheduler; allowed.start();
    gate.release(); blocked.wait(); allowed.wait();
    OpenCodeEvent[] events; client.drain(events); bool rejected, accepted;
    foreach (event; events) if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning)
    {
        if (event.toolCallId == "blocked") rejected = event.toolFailed && event.text.indexOf("operation or rebuild is pending") >= 0;
        if (event.toolCallId == "allowed") accepted = !event.toolFailed;
    }
    assert(rejected && accepted && !exists(buildPath(source, "blocked.md")));
    assert(readText(buildPath(other, "allowed.md")) == "captured empty source");
    ChangeContext pending; pending.developerCaptured = true; pending.developer = blocked.context.developer;
    assert(executeTool(OpenCodeToolCall("sync", "sync", "{}"), source, null, pending).failed);
    // Rebuild validates source-package identity before preflight. A pinned empty
    // source lets this fixture reach the captured busy guard without a real app.
    pending.developer.source = "";
    auto previous = installDeveloperToolSource(""); scope (exit) restoreDeveloperToolSource(previous);
    assert(executeTool(OpenCodeToolCall("rebuild", "rebuild", "{}"), source, null, pending).failed);
    ActorConfiguration config; config.developer = blocked.context.developer;
    auto behavior = actorBehaviorJson(config);
    auto decoded = decodeActorBehavior(ActorConfiguration.init, behavior);
    assert(decoded.developer.source == source && decoded.developer.operationPending && !decoded.developer.requireLatest);
    writeln("PASS queued source scope/settings are detached, explicit empty source bypasses host globals, captured sync/rebuild guards and configuration roundtrip");
    return 0;
}

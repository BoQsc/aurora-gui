module architecture_contracts;

import auroraopencode.attachmentstore;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.execution;
import auroraopencode.executionstate;
import auroraopencode.logging;
import auroraopencode.opencode_client;
import auroraopencode.repository;
import auroraopencode.retrypolicy;
import auroraopencode.runtime;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext,
    prepareNativeMutationIntentForTesting, pendingNativeMutationIntents;
import auroraopencode.verification;
import auroraopencode.workscheduler;
import auroraopencode.workerbudget;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write, dirEntries, SpanMode;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : spawnProcess, kill, wait;
import std.stdio : writeln;
import std.string : indexOf;
import std.utf : validate;

private final class EventProducer
{
    OpenCodeClient client;
    size_t count;
    this(OpenCodeClient client, size_t count) { this.client = client; this.count = count; }
    void run()
    {
        foreach (i; 0 .. count)
        {
            OpenCodeEvent event;
            event.kind = OpenCodeEventKind.delta;
            event.requestId = 77;
            event.reasoning = (i % 2) != 0;
            event.text = "x".replicate(2048);
            client.pushLocalEvent(event);
        }
        OpenCodeEvent done;
        done.kind = OpenCodeEventKind.done;
        done.requestId = 77;
        client.pushLocalEvent(done);
    }
}

private final class LogProducer
{
    string tag;
    this(string tag) { this.tag = tag; }
    void run() { foreach (i; 0 .. 100) logInfo(tag ~ "-" ~ to!string(i)); }
}

private final class Gate
{
    Mutex mutex;
    Condition changed;
    bool open;
    int active, peak, finished;
    this() { mutex = new Mutex(); changed = new Condition(mutex); }
    void enter()
    {
        synchronized (mutex)
        {
            ++active;
            if (active > peak) peak = active;
            changed.notifyAll();
            while (!open) changed.wait();
        }
        Thread.sleep(5.msecs);
        synchronized (mutex) { --active; ++finished; }
    }
    void release() { synchronized (mutex) { open = true; changed.notifyAll(); } }
}

private final class GateJob : WorkItem
{
    Gate gate;
    this(Gate gate, string workspace, bool writer, string resource = "")
    {
        this.gate = gate;
        this.workspace = workspace;
        exclusive = writer;
        this.resource = resource;
    }
    override void execute() { gate.enter(); changed = exclusive; }
    override void settle(ulong revision) {}
}

private void writeCheckpointChild(string directory)
{
    auto repository = new ConversationRepository();
    auto runtime = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    AgentRuntimeEvent started;
    started.kind = AgentEventKind.threadStarted;
    started.threadId = "crash-thread";
    started.payloadJson = `{"title":"Crash recovery","turnStatus":"running"}`;
    assert(runtime.publish(started));
    AgentRuntimeEvent message;
    message.kind = AgentEventKind.itemAdded;
    message.threadId = "crash-thread";
    message.itemId = "partial-message";
    message.payloadJson = `{"role":"assistant","content":""}`;
    assert(runtime.publish(message));
    message.kind = AgentEventKind.itemUpdated;
    message.payloadJson = `{"role":"assistant","content":"durable partial answer"}`;
    assert(runtime.checkpoint(message));
    repository.flush();
    write(buildPath(directory, "ready"), "ready");
    // Parent terminates this process without destructors or orderly shutdown.
    Thread.sleep(60.seconds);
}

private void writeMutationChild(string directory)
{
    setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    const workspace = buildPath(directory, "workspace");
    mkdirRecurse(workspace);
    const target = buildPath(workspace, "crash.txt");
    write(target, "original content");
    ChangeContext context;
    context.conversationId = "crash-thread";
    prepareNativeMutationIntentForTesting(OpenCodeToolCall("crash-edit", "write",
        "{\"filePath\":\"crash.txt\",\"content\":\"changed content\"}"), workspace, context);
    write(target, "changed content");
    write(buildPath(directory, "mutation-ready"), "ready");
    Thread.sleep(60.seconds);
}

int main(string[] args)
{
    if (args.length == 3 && args[1] == "--checkpoint-child")
    { writeCheckpointChild(args[2]); return 0; }
    if (args.length == 3 && args[1] == "--mutation-child")
    { writeMutationChild(args[2]); return 0; }
    const directory = buildPath("contract-state-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory);

    ExecutionState state;
    ExecutionCommand[] trace = [
        ExecutionCommand(ExecutionCommandKind.accept, 11),
        ExecutionCommand(ExecutionCommandKind.delta, 11),
        ExecutionCommand(ExecutionCommandKind.toolsRequested, 11),
        ExecutionCommand(ExecutionCommandKind.stop),
        ExecutionCommand(ExecutionCommandKind.delta, 11),
        ExecutionCommand(ExecutionCommandKind.accept, 12),
        ExecutionCommand(ExecutionCommandKind.complete, 11),
        ExecutionCommand(ExecutionCommandKind.complete, 12),
    ];
    ExecutionState replay;
    foreach (command; trace)
    {
        state = reduceExecution(state, command).state;
        replay = reduceExecution(replay, command).state;
    }
    assert(state == replay && state.phase == RequestPhase.completed && state.revision == 6);
    auto engine = new ThreadEngine("http://127.0.0.1:9", "");
    engine.pendingToolCalls = [OpenCodeToolCall("a", "read", "owned arguments")];
    assert(!engine.admitToolResult("unknown").accepted);
    assert(engine.admitToolResult("a").arguments == "owned arguments");
    assert(!engine.admitToolResult("a").accepted);
    engine.activeRequestSession = 2;
    engine.turnSessionIndex = 2;
    engine.autoResendSession = 2;
    engine.autoContinuePendingSession = 2;
    engine.remapSessionInsertion(1);
    assert(engine.activeRequestSession == 3 && engine.autoResendSession == 3 &&
        engine.autoContinuePendingSession == 3);
    engine.remapSessionRemoval(0);
    assert(engine.activeRequestSession == 2 && engine.autoResendSession == 2 &&
        engine.autoContinuePendingSession == 2);
    engine.remapSessionRemoval(2);
    assert(engine.activeRequestSession == -1 && engine.autoResendSession == -1 &&
        engine.autoContinuePendingSession == -1);
    engine.client.closeSession();
    assert(engine.client.startChatMessages(null, null, "fixture", false) == ChatStartResult.closed);
    writeln("PASS deterministic replay, Stop isolation, exactly-once result admission, launch rejection");
    auto physicalBudget = new WorkerBudget(2);
    assert(physicalBudget.acquire() && physicalBudget.acquire());
    foreach (_; 0 .. 64)
    {
        auto rejected = new OpenCodeClient("http://127.0.0.1:9", "",
            ProviderRetryPolicy(100.msecs), physicalBudget);
        assert(rejected.startChatMessages(null, null, "fixture", false) ==
            ChatStartResult.capacity);
        rejected.cancel();
        rejected.closeSession();
        assert(!rejected.busy() && physicalBudget.active() == 2);
    }
    physicalBudget.release();
    physicalBudget.release();
    assert(physicalBudget.active() == 0);
    writeln("PASS repeated stop/retry preserves physical provider worker admission bounds");


    auto client = new OpenCodeClient("http://127.0.0.1:9", "");
    auto producer = new EventProducer(client, 4096);
    auto worker = new Thread(&producer.run);
    worker.start();
    Thread.sleep(50.msecs);
    assert(client.queuedBytes() <= 8 * 1024 * 1024);
    OpenCodeEvent[] events;
    size_t bytes;
    bool ended;
    const due = MonoTime.currTime + 10.seconds;
    while (!ended && MonoTime.currTime < due)
    {
        client.drain(events, 16, 64 * 1024);
        assert(events.length <= 16);
        foreach (event; events)
        {
            if (event.kind == OpenCodeEventKind.done) ended = true;
            else { assert(event.text.length <= 64 * 1024); bytes += event.text.length; }
        }
        if (!events.length) Thread.sleep(1.msecs);
    }
    assert(ended && bytes == 4096 * 2048);
    worker.join();
    client.closeSession();
    auto cancelled = new OpenCodeClient("http://127.0.0.1:9", "");
    auto waitingProducer = new EventProducer(cancelled, 4096);
    auto waitingWorker = new Thread(&waitingProducer.run);
    waitingWorker.start();
    Thread.sleep(50.msecs);
    cancelled.cancel();
    const cancelDue = MonoTime.currTime + 2.seconds;
    while (waitingWorker.isRunning && MonoTime.currTime < cancelDue) Thread.sleep(5.msecs);
    assert(!waitingWorker.isRunning, "Cancellation did not release a backpressured producer");
    waitingWorker.join();
    cancelled.closeSession();
    auto unicode = new OpenCodeClient("http://127.0.0.1:9", "");
    OpenCodeEvent text;
    text.kind = OpenCodeEventKind.delta;
    text.text = "Привіт 🌍 ".replicate(1000);
    const original = text.text;
    unicode.pushLocalEvent(text);
    string assembled;
    while (unicode.hasPendingEvents())
    {
        unicode.drain(events, 2, 257);
        foreach (event; events) { validate(event.text); assembled ~= event.text; }
    }
    assert(assembled == original);
    text.text = "\U0001F30D";
    unicode.pushLocalEvent(text);
    unicode.drain(events, 1, 1);
    assert(events.length == 1 && events[0].text == text.text && !unicode.hasPendingEvents());
    unicode.closeSession();
    writeln("PASS queue backpressure, bounded draining, complete output, cancellation wake, UTF-8 boundaries");

    auto policy = ProviderRetryPolicy(100.msecs);
    assert(policy.decide(429, 50, 50.msecs).retry);
    assert(!policy.decide(429, 50, 100.msecs).retry);
    assert(!policy.decide(429, 1, 1.msecs, true).retry);
    assert(!policy.decide(500, 3, 1.msecs).retry);
    assert(!policy.decide(400, 1, 1.msecs).retry);
    assert(verificationCheck("echo", ["build", "test"]) == "");
    assert(verificationCheck("python", ["-c", "print('tests passed')"]) == "");
    assert(verificationCheck("python", ["-m", "unittest", "test_actual"]) == "unittest");
    assert(verificationCheck("python", ["-u", "-B", "-m", "unittest", "test_actual"]) == "unittest");
    assert(verificationCheck("python", ["-X", "dev", "-W", "ignore", "-m", "pytest"]) == "pytest");
    assert(verificationCheck("python", ["-u", "-c", "print('ok')", "-m", "unittest"]) == "");
    assert(verificationCheck("python", ["-B", "script.py", "-m", "unittest"]) == "");
    assert(verificationCheck("python", ["-u", "-m", "pytest", "--collect-only"]) == "");
    const commandDirectory = buildPath(directory, "commands");
    mkdirRecurse(commandDirectory);
    write(buildPath(commandDirectory, "test_actual.py"),
        "import unittest\nclass Actual(unittest.TestCase):\n def test_actual(self): self.assertEqual(2+2,4)\n");
    auto actual = executeTool(OpenCodeToolCall("check", "run",
        `{"program":"python","args":["-m","unittest","test_actual"]}`), commandDirectory);
    assert(!actual.failed && actual.verification.passed && actual.verification.exitCode == 0);
    auto falseEvidence = executeTool(OpenCodeToolCall("echo", "run",
        `{"program":"python","args":["-c","print('tests passed')"]}`), commandDirectory);
    assert(!falseEvidence.failed && !falseEvidence.verification.passed);
    writeln("PASS finite provider recovery, quota handling, real process verification and false-positive rejection");

    auto attachments = AttachmentStore(buildPath(directory, "attachments"));
    auto image = parseJSON(`{"images":[{"mimeType":"image/png","base64Data":"YWJj"},{"mimeType":"image/png","base64Data":"YWJj"}]}`);
    attachments.externalize(image);
    assert(image.toString().indexOf("base64Data") < 0);
    size_t blobs;
    foreach (entry; dirEntries(attachments.directory, SpanMode.shallow)) if (entry.isFile) ++blobs;
    assert(blobs == 1);
    attachments.hydrate(image);
    assert(image["images"].array[0]["base64Data"].str == "YWJj");
    const blob = image["images"].array[0]["blob"].str;
    write(buildPath(attachments.directory, blob ~ ".b64"), "corrupted");
    auto damaged = parseJSON("{\"content\":\"keep this visible text\",\"images\":[{\"mimeType\":\"image/png\"}]}");
    damaged["images"].array[0]["blob"] = blob;
    attachments.hydrate(damaged);
    assert(damaged["content"].str == "keep this visible text" &&
        damaged["images"].array[0]["attachmentError"].str.length);
    attachments.externalize(damaged);
    assert(damaged["images"].array[0]["blob"].str == blob,
        "Saving a missing image replaced its durable reference");
    bool corruptRejected;
    try attachments.put("YWJj");
    catch (Exception) { corruptRejected = true; }
    assert(corruptRejected);
    auto repository = new ConversationRepository();
    scope (exit) repository.close();
    int[] order;
    assert(repository.submit(delegate() { order ~= 1; }));
    repository.commit(delegate() { order ~= 2; });
    assert(order == [1, 2]);
    bool failed;
    try repository.commit(delegate() { throw new Exception("expected repository failure"); });
    catch (Exception) { failed = true; }
    assert(failed);
    repository.commit(delegate() { order ~= 3; });
    assert(order == [1, 2, 3]);
    writeln("PASS immutable attachment deduplication, ordered storage, error acknowledgement and recovery");

    auto scheduler = new WorkScheduler(2, 4);
    auto gate = new Gate();
    assert(scheduler.submit(new GateJob(gate, "workspace", false)));
    assert(scheduler.submit(new GateJob(gate, "workspace", false)));
    Thread.sleep(50.msecs);
    synchronized (gate.mutex) assert(gate.active == 2);
    foreach (_; 0 .. 4) assert(scheduler.submit(new GateJob(gate, "workspace", true)));
    assert(!scheduler.submit(new GateJob(gate, "workspace", true)));
    gate.release();
    scheduler.close();
    assert(gate.finished == 6 && gate.peak == 2 && scheduler.revision("workspace") == 4);
    auto desktopScheduler = new WorkScheduler(3, 8);
    auto desktopGate = new Gate();
    foreach (i; 0 .. 3)
        assert(desktopScheduler.submit(new GateJob(desktopGate, "workspace-" ~ to!string(i), true, "desktop")));
    Thread.sleep(50.msecs);
    synchronized (desktopGate.mutex) assert(desktopGate.active == 1);
    desktopGate.release();
    desktopScheduler.close();
    assert(desktopGate.peak == 1 && desktopGate.finished == 3);
    writeln("PASS worker and queue bounds, workspace mutation barriers, global desktop lease");

    const logs = buildPath(directory, "logs");
    setLogDirectory(logs);
    Thread[] loggers;
    foreach (i; 0 .. 6)
    {
        auto writer = new LogProducer("worker-" ~ to!string(i));
        auto logger = new Thread(&writer.run);
        logger.start();
        loggers ~= logger;
    }
    foreach (logger; loggers) logger.join();
    assert(flushLogs(5000));
    const written = readText(buildPath(logs, "errors.log"));
    foreach (i; 0 .. 6)
        assert(written.indexOf("worker-" ~ to!string(i) ~ "-99") >= 0);
    assert(queuedLogBytes() == 0);
    setLogDirectory("");
    writeln("PASS shared lock initialization across worker startup and asynchronous logging flush");

    const crashDirectory = buildPath(directory, "crash");
    mkdirRecurse(crashDirectory);
    auto child = spawnProcess([args[0], "--checkpoint-child", crashDirectory]);
    const childDue = MonoTime.currTime + 5.seconds;
    while (!exists(buildPath(crashDirectory, "ready")) && MonoTime.currTime < childDue)
        Thread.sleep(10.msecs);
    const ready = exists(buildPath(crashDirectory, "ready"));
    kill(child);
    wait(child);
    assert(ready, "Checkpoint subprocess did not become ready");
    const recovered = projectAgentRuntimeEvents(readAgentRuntimeEvents(buildPath(crashDirectory, "events.jsonl")));
    assert(recovered.length == 1 && recovered[0].messages.length == 1 &&
        recovered[0].messages[0].content == "durable partial answer");
    writeln("PASS forced process death preserves accepted intent and partial response checkpoint");
    const mutationDirectory = buildPath(directory, "mutation-crash");
    mkdirRecurse(mutationDirectory);
    auto mutationChild = spawnProcess([args[0], "--mutation-child", mutationDirectory]);
    const mutationDue = MonoTime.currTime + 5.seconds;
    while (!exists(buildPath(mutationDirectory, "mutation-ready")) &&
        MonoTime.currTime < mutationDue) Thread.sleep(10.msecs);
    assert(exists(buildPath(mutationDirectory, "mutation-ready")));
    kill(mutationChild);
    wait(mutationChild);
    setOpencodeStateDirectoryForTesting(buildPath(mutationDirectory, "state"));
    const crashedWorkspace = buildPath(mutationDirectory, "workspace");
    const intents = pendingNativeMutationIntents(crashedWorkspace);
    assert(intents.length == 1 && intents[0]["toolCallId"].str == "crash-edit");
    assert(readText(intents[0]["before"].array[0]["blob"].str) == "original content");
    assert(readText(buildPath(crashedWorkspace, "crash.txt")) == "changed content");
    writeln("PASS forced death during native mutation preserves its before-image and uncertain intent");
    return 0;
}

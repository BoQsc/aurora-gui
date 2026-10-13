module auroraopencode.toolscheduler;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.tools : ToolCancellation, ToolExecution, ChangeContext, executeTool,
    toolStatusHandler, developerToolSourceDirectory, installDeveloperToolSource, restoreDeveloperToolSource;
import std.json : JSONValue, JSONType;
import auroraopencode.workscheduler : WorkItem, WorkScheduler;
import auroraopencode.computeruse : installComputerUseContext;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time : MonoTime, seconds;
import auroraopencode.lifecyclediagnostics : logAgentLifecycle;
import auroraopencode.searchprogress : SearchProgress, decodeSearchProgress;

private __gshared Mutex _instanceMutex;
private __gshared WorkScheduler _scheduler;
private __gshared WorkScheduler _processScheduler;
shared static this()
{
    _instanceMutex = new Mutex();
    toolStatusHandler = () => toolStatus();
}

private string toolStatus()
{
    JSONValue result;
    foreach (index, lane; [scheduler(), processScheduler()])
    {
        JSONValue info;
        info["queued"] = cast(long) lane.pending();
        info["running"] = JSONValue.emptyArray;
        foreach (item; lane.status())
        {
            JSONValue row;
            row["tool"] = item.tool;
            row["workspace"] = item.workspace;
            row["exclusive"] = item.exclusive;
            row["elapsedMs"] = item.elapsedMs;
            info["running"].array ~= row;
        }
        result[index == 0 ? "workspace" : "control"] = info;
    }
    return result.toString();
}

private bool controlTool(string name)
{
    return name == "process" || name == "tool_status" || name == "update_plan" ||
        name == "update_subplan" || name == "open";
}

private WorkScheduler scheduler()
{
    synchronized (_instanceMutex)
    {
        if (_scheduler is null) _scheduler = new WorkScheduler();
        return _scheduler;
    }
}

private WorkScheduler processScheduler()
{
    synchronized (_instanceMutex)
    {
        if (_processScheduler is null) _processScheduler = new WorkScheduler(2);
        return _processScheduler;
    }
}

public ulong toolWorkspaceRevision(string workspace) { return scheduler().revision(workspace); }
public void invalidateToolWorkspace(string workspace) { scheduler().invalidate(workspace); }

public bool parallelTool(const ref OpenCodeToolCall call)
{
    return call.name == "read" || call.name == "glob" || call.name == "grep" ||
        call.name == "dshell" || call.name == "view_image" || call.name == "process" || call.name == "checksum";
}

public ToolBatch scheduleToolBatch(OpenCodeClient client, ulong requestId,
    const(OpenCodeToolCall)[] calls, string workspace,
    ToolCancellation cancellation, ChangeContext context)
{
    auto batch = new ToolBatch(client, requestId, calls, workspace, cancellation, context);
    batch.start();
    return batch;
}

public final class ToolBatch
{
    Mutex mutex;
    Condition settled;
    OpenCodeClient client;
    ulong requestId;
    OpenCodeToolCall[] calls;
    string workspace;
    string developerSource;
    ToolCancellation cancellation;
    ChangeContext context;
    size_t cursor, remaining;

    this(OpenCodeClient client, ulong requestId, const(OpenCodeToolCall)[] calls,
        string workspace, ToolCancellation cancellation, ChangeContext context)
    {
        mutex = new Mutex();
        settled = new Condition(mutex);
        this.client = client;
        this.requestId = requestId;
        this.calls = calls.dup;
        this.workspace = workspace;
        this.developerSource = developerToolSourceDirectory();
        this.cancellation = cancellation;
        this.context = context;
    }

    void start()
    {
        size_t first, end;
        synchronized (mutex)
        {
            if (cursor == calls.length) return;
            first = cursor;
            end = first + 1;
            if (parallelTool(calls[first]))
                while (end < calls.length && parallelTool(calls[end])) ++end;
            remaining = end - first;
            cursor = end;
        }
        foreach (i; first .. end)
        {
            // Each receiver owns its call. No reused loop delegate captures.
            auto job = new ToolJob(this, calls[i]);
            job.diagnostic("tool.queued");
            job.progress("Queued: waiting for a tool worker or workspace lease. Stop cancels this turn.");
            // Process inspection and termination must remain available while
            // workspace commands occupy the normal workers and writer lease.
            auto lane = controlTool(job.call.name) ? processScheduler() : scheduler();
            if (!lane.submit(job))
            {
                job.result = ToolExecution(job.call.name, "Error: tool queue is at capacity; retry this call.", true);
                job.settle(scheduler().revision(workspace));
            }
        }
    }

    void completed()
    {
        bool next;
        synchronized (mutex)
        {
            assert(remaining > 0);
            next = --remaining == 0;
            settled.notifyAll();
        }
        if (next) start();
    }

    void wait()
    {
        synchronized (mutex)
            while (cursor < calls.length || remaining > 0) settled.wait();
    }
}

private final class ToolJob : WorkItem
{
    ToolBatch batch;
    OpenCodeToolCall call;
    ToolExecution result;
    MonoTime queueDeadline;
    MonoTime queuedAt, startedAt, lastDiagnosticAt;
    this(ToolBatch batch, const ref OpenCodeToolCall call)
    {
        this.batch = batch;
        this.call = call;
        label = call.name;
        queuedAt = MonoTime.currTime;
        queueDeadline = queuedAt + 30.seconds;
        workspace = batch.workspace;
        exclusive = !parallelTool(call) && !controlTool(call.name);
        if (call.name == "computer") resource = "desktop";
    }

    override bool abandonQueued()
    {
        return batch.cancellation.cancelled() || MonoTime.currTime >= queueDeadline;
    }

    override void queueAbandoned()
    {
        diagnostic(batch.cancellation.cancelled() ? "tool.cancelled_before_start" : "tool.queue_deadline");
        result = ToolExecution(call.name, batch.cancellation.cancelled()
            ? "Stopped: queued tool cancelled before it started."
            : "Error: tool could not acquire a worker or workspace lease within 30 seconds; " ~
              "it was not executed. Use tool_status to inspect active native tools and " ~
              "process to inspect commands. Stop the owning turn before retrying; " ~
              "removing finished process records does not release an active tool's lease.", true);
    }

    override void execute()
    {
        startedAt = MonoTime.currTime;
        diagnostic("tool.started");
        auto previousSource = installDeveloperToolSource(batch.developerSource);
        scope (exit) restoreDeveloperToolSource(previousSource);
        if (batch.cancellation.cancelled())
        {
            result = ToolExecution(call.name, "Stopped: tool cancelled before it started.", true);
            return;
        }
        // A failed exclusive effect may have changed files before reporting
        // failure. Keep earlier evidence invalidated in that case.
        changed = mutationCandidate();
        auto previous = installComputerUseContext(batch.context.computer);
        scope (exit) installComputerUseContext(previous);
        try
        {
            result = executeTool(call, workspace, batch.cancellation, batch.context, &progress);
            changed = mutationCandidate() && result.verification.check.length == 0;
            if (changed && batch.developerSource.length && (call.name == "sync" || call.name == "run" || call.name == "bash"))
                invalidateToolWorkspace(batch.developerSource);
        }
        catch (Throwable error)
        {
            result = ToolExecution(call.name, "Error: tool failed: " ~ error.msg, true);
        }
    }

    private bool mutationCandidate()
    {
        if (batch.context.computer.explanationOnly && (call.name == "run" || call.name == "bash")) return false;
        return exclusive && call.name != "update_plan" && call.name != "update_subplan" &&
            call.name != "open" && call.name != "webfetch" && call.name != "websearch" && call.name != "computer";
    }

    private void progress(string output)
    {
        SearchProgress search;
        const decoded = decodeSearchProgress(output, search);
        if (lastDiagnosticAt == MonoTime.init ||
            MonoTime.currTime - lastDiagnosticAt >= 5.seconds || (decoded && search.terminal))
        {
            JSONValue details;
            if (decoded)
            {
                details["scope"] = search.root;
                details["path"] = search.path;
                details["phase"] = search.phase;
                details["files"] = cast(long) search.files;
                details["folders"] = cast(long) search.directories;
                details["bytes"] = cast(long) search.bytes;
                details["matches"] = cast(long) search.matches;
                details["candidateFiles"] = cast(long) search.candidateFiles;
                details["processedFiles"] = cast(long) search.processedFiles;
                details["totalsKnown"] = search.totalsKnown;
                details["lastActivityMs"] = search.lastActivityMs;
                details["partial"] = search.partial;
            }
            diagnostic("tool.progress", details);
            lastDiagnosticAt = MonoTime.currTime;
        }
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.toolResult;
        event.toolRunning = true;
        event.text = output;
        event.toolName = call.name;
        event.toolCallId = call.id;
        event.requestId = batch.requestId;
        batch.client.pushLocalEvent(event);
    }

    override void settle(ulong revision)
    {
        scope (exit) batch.completed();
        JSONValue details;
        details["failed"] = result.failed;
        details["cancelled"] = batch.cancellation.cancelled();
        details["outputBytes"] = cast(long) result.output.length;
        details["verificationPassed"] = result.verification.passed;
        diagnostic("tool.finished", details);
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.toolResult;
        event.text = result.output;
        event.toolName = call.name;
        event.toolCallId = call.id;
        event.toolFailed = result.failed;
        event.diffAdditions = result.additions;
        event.diffDeletions = result.deletions;
        event.diffText = result.diff;
        event.elapsedMs = result.elapsedMs;
        event.images = result.images.dup;
        event.requestId = batch.requestId;
        event.verificationCheck = result.verification.check;
        event.verificationWorkspace = result.verification.workspace;
        event.verificationRevision = revision;
        event.verificationPassed = result.verification.passed;
        event.verificationExitCode = result.verification.exitCode;
        event.effectWorkspace = workspace;
        event.effectRevision = revision;
        event.workspaceChanged = changed;
        batch.client.pushLocalEvent(event);
    }

    private void diagnostic(string stage, JSONValue details = JSONValue.init)
    {
        if (details.type != JSONType.object) details = JSONValue.emptyObject;
        details["toolCallId"] = call.id;
        details["tool"] = call.name;
        details["workspace"] = workspace;
        details["turn"] = batch.context.turnId;
        details["queuedMs"] = ((startedAt == MonoTime.init ? MonoTime.currTime : startedAt) - queuedAt).total!"msecs";
        if (startedAt != MonoTime.init)
            details["elapsedMs"] = (MonoTime.currTime - startedAt).total!"msecs";
        logAgentLifecycle(batch.context.conversationId, batch.requestId, stage, details);
    }
}

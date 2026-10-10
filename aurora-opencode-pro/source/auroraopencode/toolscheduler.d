module auroraopencode.toolscheduler;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.tools : ToolCancellation, ToolExecution, ChangeContext, executeTool;
import auroraopencode.workscheduler : WorkItem, WorkScheduler;
import auroraopencode.computeruse : installComputerUseContext;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

private __gshared Mutex _instanceMutex;
private __gshared WorkScheduler _scheduler;
shared static this() { _instanceMutex = new Mutex(); }

private WorkScheduler scheduler()
{
    synchronized (_instanceMutex)
    {
        if (_scheduler is null) _scheduler = new WorkScheduler();
        return _scheduler;
    }
}

public ulong toolWorkspaceRevision(string workspace) { return scheduler().revision(workspace); }

public bool parallelTool(const ref OpenCodeToolCall call)
{
    return call.name == "read" || call.name == "glob" || call.name == "grep" ||
        call.name == "dshell" || call.name == "view_image";
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
            job.progress("Queued: waiting for a tool worker or workspace lease. Stop cancels this turn.");
            if (!scheduler().submit(job))
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
    this(ToolBatch batch, const ref OpenCodeToolCall call)
    {
        this.batch = batch;
        this.call = call;
        workspace = batch.workspace;
        exclusive = !parallelTool(call);
        if (call.name == "computer") resource = "desktop";
    }

    override void execute()
    {
        if (batch.cancellation.cancelled())
        {
            result = ToolExecution(call.name, "Stopped: tool cancelled before it started.", true);
            return;
        }
        // A failed exclusive effect may have changed files before reporting
        // failure. Keep earlier evidence invalidated in that case.
        changed = exclusive && call.name != "update_plan" && call.name != "update_subplan" &&
            call.name != "open" && call.name != "webfetch" &&
            call.name != "websearch" && call.name != "computer";
        auto previous = installComputerUseContext(batch.context.computer);
        scope (exit) installComputerUseContext(previous);
        try
        {
            result = executeTool(call, workspace, batch.cancellation, batch.context, &progress);
            changed = exclusive &&
                result.verification.check.length == 0 && call.name != "update_plan" &&
                call.name != "update_subplan" && call.name != "open" && call.name != "webfetch" &&
                call.name != "websearch" && call.name != "computer";
        }
        catch (Throwable error)
        {
            result = ToolExecution(call.name, "Error: tool failed: " ~ error.msg, true);
        }
    }

    private void progress(string output)
    {
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
}

module scheduler_shutdown_contracts;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeClient;
import auroraopencode.tools : ToolCancellation, ChangeContext, toolStatusHandler;
import auroraopencode.toolscheduler : scheduleToolBatch, shutdownToolSchedulers;
import core.time : MonoTime;
import std.file : exists, mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.conv : to;
import std.stdio : writeln;

int main(string[] args)
{
    const workspace = buildPath(tempDir(), "aurora-scheduler-shutdown-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    write(buildPath(workspace, "input.txt"), "retained input");
    auto client = new OpenCodeClient("", "");
    auto cancellation = new ToolCancellation();
    // Exercise both pools, including chained settlement from control to workspace.
    if (args.length == 1)
    {
        auto batch = scheduleToolBatch(client, 1,
            [OpenCodeToolCall("control", "read_history", "{}"),
             OpenCodeToolCall("workspace", "read", `{"filePath":"input.txt"}`)],
            workspace, cancellation, ChangeContext.init);
        batch.wait();
    }
    cancellation.cancel();
    const began = MonoTime.currTime;
    shutdownToolSchedulers();
    shutdownToolSchedulers();
    assert((MonoTime.currTime - began).total!"msecs" < 2000);
    // Also covers shutdown before either pool was ever initialized (any arg).
    auto late = scheduleToolBatch(client, 2,
        [OpenCodeToolCall("late-control", "read_history", "{}"),
         OpenCodeToolCall("late-write", "write", `{"filePath":"must-not-exist.txt","content":"late effect"}`)],
        workspace, cancellation, ChangeContext.init);
    late.wait();
    assert(!exists(buildPath(workspace, "must-not-exist.txt")));
    client.closeSession();
    writeln("PASS scheduler shutdown joins both pools, settles late admissions, and is idempotent");
    return 0;
}

module directory_scan_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ToolCancellation, ToolExecution, executeTool;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, splitLines;

private OpenCodeToolCall list(JSONValue args)
{
    args["command"] = "list";
    return OpenCodeToolCall("scan-test", "dshell", args.toString());
}

private string continuation(string output)
{
    const start = output.indexOf("<continuation>");
    if (start < 0) return "";
    const end = output.indexOf("</continuation>");
    assert(end > start);
    return output[start + "<continuation>".length .. end];
}

private string recovery(string output)
{
    const start = output.indexOf(`"cursor":"`);
    assert(start >= 0, output);
    return output[start + `"cursor":"`.length .. start + `"cursor":"`.length + 36];
}

private size_t collectEntries(string output, ref bool[string] seen)
{
    size_t count;
    foreach (line; output.splitLines())
        if (line.indexOf("[f] ") == 0 || line.indexOf("[d] ") == 0)
        {
            assert(line !in seen, "Entry repeated across continuation batches: " ~ line);
            seen[line] = true;
            ++count;
        }
    return count;
}

int main()
{
    const root = buildPath(tempDir(), "aurora-scan-test-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(root, "workspace");
    mkdirRecurse(workspace);
    scope (exit) rmdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    foreach (i; 0 .. 3)
    {
        const folder = buildPath(workspace, "folder" ~ to!string(i));
        mkdirRecurse(folder);
        foreach (j; 0 .. 4)
            write(buildPath(folder, to!string(j) ~ ".d"), "module fixture;\n");
        write(buildPath(folder, "skip.txt"), "skip\n");
    }
    JSONValue args;
    args["recursive"] = true;
    args["pattern"] = "**/*.d";
    args["limit"] = 2;
    args["yieldMs"] = 5000;
    bool[string] seen;
    auto result = executeTool(list(args), workspace);
    string firstCursor = continuation(result.output);
    assert(firstCursor.length == 36, result.output);
    size_t pages;
    while (true)
    {
        assert(!result.failed, result.output);
        assert(collectEntries(result.output, seen) <= 2);
        assert(result.output.indexOf("skip.txt") < 0);
        assert(++pages < 30, "Scan did not make progress");
        const cursor = continuation(result.output);
        if (cursor.length == 0) break;
        JSONValue next;
        next["cursor"] = cursor;
        next["limit"] = 2;
        next["yieldMs"] = 5000;
        result = executeTool(list(next), workspace);
    }
    assert(seen.length == 12, "Continuation lost files");
    assert(result.output.indexOf("Scan complete.") >= 0);
    writeln("PASS recursive filtered paging: no dropped or repeated entries");

    // A killed helper must leave its input checkpoint valid. The fixture host
    // simulates an uninterruptible OS directory call before the first result.
    JSONValue blocked;
    blocked["cursor"] = firstCursor;
    blocked["_fixtureBlocked"] = true;
    blocked["timeout"] = 100;
    auto interrupted = executeTool(list(blocked), workspace);
    assert(interrupted.failed && interrupted.output.indexOf("timed out") >= 0, interrupted.output);
    JSONValue retry;
    retry["cursor"] = recovery(interrupted.output);
    auto resumed = executeTool(list(retry), workspace);
    assert(!resumed.failed && resumed.output.indexOf("[f]") >= 0, resumed.output);

    // Initial scans also acquire a checkpoint before the helper starts.
    blocked.object.remove("cursor");
    auto initialTimeout = executeTool(list(blocked), workspace);
    assert(initialTimeout.failed, initialTimeout.output);
    retry["cursor"] = recovery(initialTimeout.output);
    resumed = executeTool(list(retry), workspace);
    assert(!resumed.failed && resumed.output.indexOf("folder0") >= 0, resumed.output);

    auto cancellation = new ToolCancellation();
    ToolExecution stopped;
    auto worker = new Thread({ stopped = executeTool(list(blocked), workspace, cancellation); });
    blocked["timeout"] = 30_000;
    worker.start();
    Thread.sleep(150.msecs);
    cancellation.cancel();
    worker.join();
    assert(stopped.failed && stopped.output.indexOf("cancelled") >= 0, stopped.output);
    retry["cursor"] = recovery(stopped.output);
    resumed = executeTool(list(retry), workspace);
    assert(!resumed.failed, resumed.output);
    writeln("PASS timeouts and cancellations preserve resumable checkpoints");

    JSONValue foreign;
    foreign["cursor"] = firstCursor;
    const other = buildPath(root, "other");
    mkdirRecurse(other);
    auto denied = executeTool(list(foreign), other);
    assert(denied.failed && denied.output.indexOf("another workspace") >= 0, denied.output);
    foreign["cursor"] = "../../settings.json";
    assert(executeTool(list(foreign), workspace).failed);
    writeln("PASS cursor validation and workspace isolation");

    // A sparse search must return control even before it finds its first match.
    const sparse = buildPath(workspace, "sparse");
    mkdirRecurse(sparse);
    foreach (i; 0 .. 2050) write(buildPath(sparse, to!string(i) ~ ".txt"), "");
    JSONValue sparseArgs;
    sparseArgs["path"] = "sparse";
    sparseArgs["pattern"] = "*.d";
    sparseArgs["yieldMs"] = 5000;
    result = executeTool(list(sparseArgs), workspace);
    assert(!result.failed && result.output.indexOf("[f]") < 0, result.output);
    assert(continuation(result.output).length == 36, "Sparse scan did not yield");
    retry["cursor"] = continuation(result.output);
    result = executeTool(list(retry), workspace);
    assert(!result.failed && result.output.indexOf("Scan complete.") >= 0, result.output);
    writeln("PASS sparse scans yield with zero matches");

    const wide = buildPath(workspace, "wide");
    mkdirRecurse(wide);
    foreach (i; 0 .. 230)
        write(buildPath(wide, replicate("x", 100) ~ to!string(i) ~ ".txt"), "");
    JSONValue wideArgs;
    wideArgs["path"] = "wide";
    wideArgs["yieldMs"] = 5000;
    seen = null;
    result = executeTool(list(wideArgs), workspace);
    pages = 0;
    while (true)
    {
        assert(!result.failed && result.output.length < 40_000, result.output);
        collectEntries(result.output, seen);
        assert(++pages < 20);
        const cursor = continuation(result.output);
        if (cursor.length == 0) break;
        retry["cursor"] = cursor;
        result = executeTool(list(retry), workspace);
    }
    assert(seen.length == 230, "Output cap dropped entries or the continuation cursor");
    writeln("PASS byte-limited batches preserve every entry and continuation");
    return 0;
}

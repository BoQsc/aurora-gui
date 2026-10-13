module read_progress_contracts;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext;
import auroraopencode.readprogress;
import core.time : MonoTime;
import std.file : mkdirRecurse, rmdirRecurse, write, dirEntries, SpanMode;
import std.path : absolutePath, buildPath, baseName;
import std.conv : to;
import std.string : indexOf;
import std.stdio : writeln;
import std.array : replicate;

int main()
{
    const workspace = absolutePath("read-progress-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    scope (exit) rmdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(workspace, "state"));
    write(buildPath(workspace, "ordinary.txt"), "first\r\nsecond\r\nthird\r\n");
    ReadProgress last;
    size_t events;
    void observe(string payload)
    {
        ReadProgress update;
        assert(decodeReadProgress(payload, update), "Unstructured Read observer: " ~ payload);
        last = update; ++events;
    }
    auto result = executeTool(OpenCodeToolCall("normal", "read", `{"filePath":"ordinary.txt"}`),
        workspace, null, ChangeContext.init, &observe);
    assert(!result.failed && result.output.indexOf("2: second") >= 0, result.output);
    assert(last.terminal && last.totalKnown && last.fraction() == 1 && last.collected == 3 && events >= 2);
    assert(last.path == buildPath(workspace, "ordinary.txt") && last.preview[1] == "2: second");
    assert(last.phase.indexOf("end of file") >= 0 && last.bytesRead == 22);
    result = executeTool(OpenCodeToolCall("page", "read", `{"filePath":"ordinary.txt","offset":2,"limit":1}`),
        workspace, null, ChangeContext.init, &observe);
    assert(!result.failed && last.offset == 2 && last.limit == 1 && last.collected == 1);
    assert(last.preview == ["2: second"] && last.phase.indexOf("window returned") >= 0);
    auto absent = executeTool(OpenCodeToolCall("absent", "read", `{"filePath":"absent.txt"}`),
        workspace, null, ChangeContext.init, &observe);
    assert(absent.failed && last.terminal && !last.totalKnown && last.phase.indexOf("not found") >= 0);
    write(buildPath(workspace, "large.txt"), "abcdefghij\n".replicate(400000));
    result = executeTool(OpenCodeToolCall("large-page", "read", `{"filePath":"large.txt","limit":2}`),
        workspace, null, ChangeContext.init, &observe);
    assert(!result.failed && last.collected == 2 && last.bytesRead == 65536 && last.fraction() < 0.02);
    assert(last.terminal && last.phase.indexOf("window returned") >= 0, "Paging incorrectly claims the whole file was read");
    write(buildPath(workspace, "long-line.txt"), "x".replicate(2 * 1024 * 1024) ~ "\nlast\n");
    result = executeTool(OpenCodeToolCall("long-line", "read", `{"filePath":"long-line.txt"}`),
        workspace, null, ChangeContext.init, &observe);
    assert(!result.failed && last.collected == 2 && result.output.indexOf("line truncated") >= 0 && result.output.indexOf("2: last") >= 0);
    writeln("PASS real Read host IPC: measured bytes, resolved file, numbered preview, CRLF, paging and missing-file failure");
    writeln("PASS large-file paging returns two lines after one chunk; oversized lines stay bounded without losing the following line");

    bool quiet;
    auto token = new ToolCancellation();
    auto stopped = executeTool(OpenCodeToolCall("stop", "read",
        `{"filePath":"ordinary.txt","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":5000}`),
        workspace, token, ChangeContext.init, (string payload) {
            observe(payload);
            if (last.lastActivityMs >= 1000 && last.bytesRead == 2500) { quiet = true; token.cancel(); }
        });
    assert(quiet && stopped.failed && last.terminal && last.fraction() == 0.25, stopped.output);
    assert(stopped.output.indexOf("second returned line") >= 0 && stopped.output.indexOf("incomplete") >= 0);
    auto timedOut = executeTool(OpenCodeToolCall("timeout", "read",
        `{"filePath":"ordinary.txt","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":1400}`),
        workspace, null, ChangeContext.init, &observe);
    assert(timedOut.failed && last.terminal && last.fraction() == 0.25 && last.phase.indexOf("timed out") >= 0);
    assert(timedOut.output.indexOf("host was terminated") >= 0 && timedOut.output.indexOf("ordinary.txt") >= 0);
    version (Windows)
    {
        import core.sys.windows.windows : OpenProcess, SYNCHRONIZE, WaitForSingleObject, WAIT_OBJECT_0, CloseHandle;
        foreach (entry; dirEntries(workspace, "*.pid", SpanMode.shallow))
        {
            const name = baseName(entry.name);
            auto handle = OpenProcess(SYNCHRONIZE, false, to!uint(name[5 .. $ - 4]));
            if (handle !is null) { assert(WaitForSingleObject(handle, 0) == WAIT_OBJECT_0); CloseHandle(handle); }
        }
    }
    result = executeTool(OpenCodeToolCall("after", "read", `{"filePath":"ordinary.txt"}`), workspace);
    assert(!result.failed && result.output.indexOf("3: third") >= 0);
    writeln("PASS blocked Read heartbeat, retained partial preview, cancellation, timeout, no surviving hosts and successful next read");

    ReadProgress malicious, decoded;
    malicious.phase = "Reading"; malicious.path = "file";
    foreach (i; 0 .. 20) malicious.preview ~= to!string(i);
    assert(decodeReadProgress(encodeReadProgress(malicious), decoded));
    assert(decoded.preview == ["14", "15", "16", "17", "18", "19"]);
    assert(!decodeReadProgress("\x1eaurora-read {}", decoded));
    malicious.elapsedMs = -1;
    assert(!decodeReadProgress(encodeReadProgress(malicious), decoded));
    writeln("PASS bounded previews and invalid progress rejection");
    return 0;
}

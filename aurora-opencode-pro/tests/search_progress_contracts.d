module search_progress_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, ToolCancellation, ToolExecution, ChangeContext;
import auroraopencode.searchprogress;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, write;
import std.json : JSONValue;
import std.path : buildPath, absolutePath;
import std.stdio : File, writeln;
import std.string : indexOf;

int main()
{
    const root = absolutePath("search-progress-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(root, "workspace");
    mkdirRecurse(buildPath(workspace, "src"));
    mkdirRecurse(buildPath(workspace, "build"));
    scope (exit) rmdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    write(buildPath(workspace, "src", "main.d"), "before\r\nneedle\r\nneedle\r\n");
    write(buildPath(workspace, "readme.txt"), "nothing here\n");
    write(buildPath(workspace, "build", "generated.d"), "needle\n");
    write(buildPath(workspace, "binary.exe"), "needle\n");
    write(buildPath(workspace, "unknown.txt"), [cast(ubyte) 0, 1, 2]);
    auto oversized = File(buildPath(workspace, "oversized.log"), "wb");
    oversized.seek(9 * 1024 * 1024);
    oversized.rawWrite([cast(ubyte) 0]);
    oversized.close();

    SearchProgress last;
    size_t events;
    void observe(string payload)
    {
        SearchProgress update;
        assert(decodeSearchProgress(payload, update), "Search host leaked unstructured diagnostics: " ~ payload);
        last = update;
        ++events;
    }
    ToolExecution run(string name, string args, ToolCancellation cancellation = null)
    {
        last = SearchProgress.init;
        events = 0;
        return executeTool(OpenCodeToolCall("search", name, args), workspace, cancellation,
            ChangeContext.init, &observe);
    }

    auto grep = run("grep", `{"pattern":"^needle$"}`);
    assert(!grep.failed && grep.output.indexOf("main.d:2: needle") >= 0, grep.output);
    assert(last.terminal && !last.partial && last.matches == 2 && last.files == 2 && events >= 1);
    assert(last.skippedDirectories == 1 && last.skippedBinary == 2 && last.skippedLarge == 1, grep.output);
    assert(last.lines == 4 && last.root.length && last.query == "^needle$");
    assert(grep.output.indexOf("aurora-search") < 0);
    writeln("PASS real helper IPC: scope, CRLF matches, files, lines and skip reasons reach the observer");

    auto filtered = run("grep", `{"pattern":"needle","include":"*.d"}`);
    assert(!filtered.failed && last.skippedFiltered >= 3 && last.filter.indexOf("include *.d") >= 0, filtered.output);
    auto capped = run("grep", `{"pattern":"needle","limit":1}`);
    assert(!capped.failed && last.partial && last.terminal && last.matches == 1);
    assert(last.phase.indexOf("incomplete") >= 0 && capped.output.indexOf("capped at 1") >= 0, capped.output);
    auto absent = run("grep", `{"pattern":"never-present"}`);
    assert(!absent.failed && absent.output.indexOf("No matches") >= 0 && !last.partial && last.terminal);
    writeln("PASS filtered scans, match limits and completed zero-match searches remain distinguishable");

    auto paths = run("glob", `{"pattern":"**/*","limit":2}`);
    assert(!paths.failed && last.terminal && last.partial && last.matches == 2, paths.output);
    assert(paths.output.indexOf("Results capped at 2") >= 0 && paths.output.indexOf("Search complete") < 0);
    auto completePaths = run("glob", `{"pattern":"**/*.d"}`);
    assert(!completePaths.failed && last.terminal && !last.partial && last.matches == 2, completePaths.output);
    writeln("PASS glob reports actual completion separately from a result cap");

    auto listing = run("dshell", `{"command":"list","recursive":true,"pattern":"**/*.d","limit":1,"yieldMs":5000}`);
    assert(!listing.failed && last.partial && last.pending > 0 && last.terminal, listing.output);
    ulong previousEntries = last.entries, previousFiles = last.files;
    while (true)
    {
        auto at = listing.output.indexOf("<continuation>");
        if (at < 0) break;
        const cursor = listing.output[at + "<continuation>".length .. at + "<continuation>".length + 36];
        listing = run("dshell", `{"command":"list","cursor":"` ~ cursor ~ `","limit":1,"yieldMs":5000}`);
        assert(!listing.failed && last.entries >= previousEntries && last.files >= previousFiles, listing.output);
        previousEntries = last.entries; previousFiles = last.files;
    }
    assert(last.terminal && !last.partial && last.matches == 2 && last.skippedFiltered > 0);
    writeln("PASS directory continuation keeps cumulative progress and labels paused checkpoints");

    version (Windows)
    {
        import core.sys.windows.windows : CreateFileW, CloseHandle, GENERIC_WRITE,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, INVALID_HANDLE_VALUE;
        import std.utf : toUTF16z;
        const lockedPath = buildPath(workspace, "locked.txt");
        auto handle = CreateFileW(lockedPath.toUTF16z, GENERIC_WRITE, 0, null,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        assert(handle != INVALID_HANDLE_VALUE);
        scope (exit) CloseHandle(handle);
        auto unreadable = run("grep", `{"pattern":"missing","path":"locked.txt"}`);
        assert(unreadable.failed && last.errors == 1 && last.partial, unreadable.output);
        assert(unreadable.output.indexOf("search incomplete") >= 0 && unreadable.output.indexOf("Last read error") >= 0);
        writeln("PASS an unreadable explicit file cannot produce a complete no-match result");
    }

    auto cancellation = new ToolCancellation();
    bool observedQuiet;
    auto interrupted = executeTool(OpenCodeToolCall("blocked", "glob",
        `{"pattern":"**/*","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":5000}`),
        workspace, cancellation, ChangeContext.init, (string payload) {
            observe(payload);
            if (last.lastActivityMs >= 1000 && last.files == 77)
            { observedQuiet = true; cancellation.cancel(); }
        });
    assert(observedQuiet && interrupted.failed && last.partial && last.terminal, interrupted.output);
    assert(interrupted.output.indexOf("77 files") >= 0 && interrupted.output.indexOf("large-log.txt:29") >= 0);
    auto timeout = run("glob", `{"pattern":"**/*","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":1400}`);
    assert(timeout.failed && last.partial && last.phase.indexOf("timed out") >= 0, timeout.output);
    assert(timeout.output.indexOf("77 files") >= 0 && timeout.output.indexOf("partial results") >= 0);
    writeln("PASS quiet-host heartbeats, Stop and hard timeouts preserve the last reported partial evidence");

    SearchProgress malicious;
    malicious.phase = "Searching"; malicious.query = "one\ntwo";
    malicious.root = "workspace"; malicious.latest = ["a", "b", "c"];
    SearchProgress decoded;
    assert(decodeSearchProgress(encodeSearchProgress(malicious), decoded));
    assert(decoded.latest == ["b", "c"] && decoded.query == "one two");
    assert(!decodeSearchProgress("\x1eaurora-search {}", decoded));
    writeln("PASS progress encoding bounds previews and rejects malformed payloads");
    return 0;
}

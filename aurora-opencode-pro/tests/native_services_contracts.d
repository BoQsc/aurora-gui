module native_services_contracts;

import auroraopencode.archives;
import auroraopencode.structureddata;
import auroraopencode.environmentinspect;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, ToolCancellation, killAllSupervisedProcesses;
import auroraopencode.toolscheduler : parallelTool;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, read, readText, tempDir, write;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath;
import std.stdio : stdin, stdout, writeln;
import std.string : strip, indexOf;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;

private string root;
private JSONValue call(string name, string arguments)
{
    const result = executeTool(OpenCodeToolCall("native", name, arguments), root);
    assert(!result.failed, result.output);
    return parseJSON(result.output);
}

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--driver")
    {
        foreach (line; stdin.byLine())
        {
            auto request = parseJSON(line.idup);
            root = request["workspace"].str;
            setOpencodeStateDirectoryForTesting(buildPath(root, ".isolated-state"));
            const result = executeTool(OpenCodeToolCall("real-task", request["tool"].str, request["arguments"].toString()), root);
            JSONValue response;
            response["failed"] = result.failed;
            try response["result"] = parseJSON(result.output);
            catch (Exception) response["output"] = result.output;
            stdout.writeln(response.toString()); stdout.flush();
        }
        killAllSupervisedProcesses();
        return 0;
    }
    root = buildPath(tempDir(), "aurora-native-services-" ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "source", "empty"));
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    write(buildPath(root, "source", "hello.txt"), "hello 世界\n");
    foreach (suffix; ["zip", "tar"])
    {
        const path = "handoff." ~ suffix;
        auto created = call("archive", `{"action":"create","path":"` ~ path ~ `","paths":["source"]}`);
        assert(created["entries"].integer == 3);
        auto checked = call("archive", `{"action":"validate","path":"` ~ path ~ `"}`);
        assert(checked["valid"].type == JSONType.true_);
        call("archive", `{"action":"extract","path":"` ~ path ~ `","destination":"restored-` ~ suffix ~ `"}`);
        assert(readText(buildPath(root, "restored-" ~ suffix, "source", "hello.txt")) == "hello 世界\n");
        assert(exists(buildPath(root, "restored-" ~ suffix, "source", "empty")));
        // Private updater/provisioning callers can resume an interrupted
        // extraction; assistant extraction still requires a new destination.
        write(buildPath(root, "restored-" ~ suffix, "source", "hello.txt"), "partial prior install");
        extractArchive(buildPath(root, path), buildPath(root, "restored-" ~ suffix), false, null, null, true);
        assert(readText(buildPath(root, "restored-" ~ suffix, "source", "hello.txt")) == "hello 世界\n");
        assert(executeTool(OpenCodeToolCall("overwrite", "archive", `{"action":"extract","path":"` ~ path ~ `","destination":"source"}`), root).failed);
    }
    foreach (name; ["../outside", "/absolute", "C:/outside", "ok/../../outside", "a\\..\\outside"])
        assertThrown!Exception(archiveRelativePath(name));
    // Unsafe entries must fail before producing an extraction directory.
    import std.zip : ZipArchive, ArchiveMember;
    auto malicious = new ZipArchive();
    auto member = new ArchiveMember(); member.name = "../outside.txt"; member.expandedData = cast(ubyte[])"bad".dup;
    malicious.addMember(member); write(buildPath(root, "unsafe.zip"), malicious.build());
    assert(executeTool(OpenCodeToolCall("unsafe", "archive", `{"action":"extract","path":"unsafe.zip","destination":"unsafe-result"}`), root).failed);
    assert(!exists(buildPath(root, "unsafe-result")));
    assert(executeTool(OpenCodeToolCall("outside", "archive", `{"action":"create","path":"outside.zip","root":"source","paths":["../handoff.zip"]}`), root).failed);
    // A stored ZIP payload with a flipped byte must fail CRC validation.
    import std.zip : CompressionMethod;
    auto damaged = new ZipArchive();
    member = new ArchiveMember(); member.name = "payload.txt";
    member.compressionMethod = CompressionMethod.none;
    member.expandedData = cast(ubyte[])"unique crc payload".dup;
    damaged.addMember(member);
    auto bytes = cast(ubyte[])damaged.build().dup;
    const payloadAt = (cast(string)bytes).indexOf("unique crc payload");
    assert(payloadAt >= 0); bytes[payloadAt] ^= 1;
    write(buildPath(root, "damaged.zip"), bytes);
    assert(executeTool(OpenCodeToolCall("crc", "archive", `{"action":"validate","path":"damaged.zip"}`), root).failed);
    assert(executeTool(OpenCodeToolCall("crc-extract", "archive", `{"action":"extract","path":"damaged.zip","destination":"crc-result"}`), root).failed);
    assert(!exists(buildPath(root, "crc-result")), "Failed extraction left its destination behind");
    writeln("PASS shared ZIP/TAR round trips, empty folders, traversal and overwrite rejection");

    write(buildPath(root, "config.json"), `{"settings":{"timeout":10},"a/b":{"~key":true},"list":[1,2]}`);
    auto initial = call("data", `{"action":"query","path":"config.json","pointer":"/settings/timeout"}`);
    assert(initial["value"].integer == 10);
    assert(call("data", `{"action":"query","path":"config.json","pointer":"/a~1b/~0key"}`)["value"].type == JSONType.true_);
    call("data", `{"action":"set","path":"config.json","changes":[{"pointer":"/settings/timeout","value":30},{"pointer":"/list/-","value":3}]}`);
    assert(call("data", `{"action":"query","path":"config.json","pointer":"/list","offset":1,"limit":1}`)["value"].array[0].integer == 2);
    const before = readText(buildPath(root, "config.json"));
    auto stale = parseJSON(`{"action":"set","path":"config.json","pointer":"/settings/timeout","value":99}`);
    stale["expectedSha256"] = initial["sha256"];
    assert(executeTool(OpenCodeToolCall("stale", "data", stale.toString()), root).failed);
    assert(executeTool(OpenCodeToolCall("atomic", "data", `{"action":"set","path":"config.json","changes":[{"pointer":"/settings/timeout","value":99},{"pointer":"/missing/child","value":1}]}`), root).failed);
    assert(readText(buildPath(root, "config.json")) == before);
    call("data", `{"action":"set","path":"config.json","pointer":"/complete","valueJson":"true"}`);
    assert(call("data", `{"action":"query","path":"config.json","pointer":"/complete"}`)["value"].type == JSONType.true_);
    call("data", `{"action":"remove","path":"config.json","pointer":"/complete"}`);
    assert(!("complete" in parseJSON(readText(buildPath(root, "config.json"))).object));
    call("data", `{"action":"remove","path":"config.json","pointer":"/list/1"}`);
    assert(call("data", `{"action":"query","path":"config.json","pointer":"/list"}`)["count"].integer == 2);
    write(buildPath(root, "table.csv"), "name,note\r\nA,\"line1\nline2\"\r\nB,\"say \"\"hello\"\"\"\r\n");
    assert(call("data", `{"action":"query","path":"table.csv","pointer":"/2/1"}`)["value"].str == "say \"hello\"");
    call("data", `{"action":"set","path":"table.csv","pointer":"/1/1","value":"comma, quote\" and newline\n"}`);
    assert(call("data", `{"action":"query","path":"table.csv","pointer":"/1/1"}`)["value"].str == "comma, quote\" and newline\n");
    call("data", `{"action":"set","path":"table.csv","pointer":"/-","valueJson":"[\"review.zip\",\"digest\"]"}`);
    assert(call("data", `{"action":"query","path":"table.csv","pointer":"/3/0"}`)["value"].str == "review.zip");
    write(buildPath(root, "bad.csv"), "a,b\n\"unterminated");
    assert(executeTool(OpenCodeToolCall("invalid-csv", "data", `{"action":"validate","path":"bad.csv"}`), root).failed);
    auto queryCall = OpenCodeToolCall("query", "data", `{"action":"query"}`);
    auto setCall = OpenCodeToolCall("set", "data", `{"action":"set"}`);
    assert(parallelTool(queryCall));
    assert(!parallelTool(setCall));
    writeln("PASS JSON pointer edits, stale guards, atomic batch failure and quoted CSV round trips");

    assert(call("environment", `{"action":"system"}`)["architectureBits"].integer == size_t.sizeof * 8);
    assert(call("environment", `{"action":"disk"}`)["availableBytes"].integer > 0);
    auto executables = call("environment", `{"action":"executables","names":["python","aurora-missing-tool-123456"]}`);
    assert(executables["executables"].array[0]["found"].type == JSONType.true_);
    assert(executables["executables"].array[1]["found"].type == JSONType.false_);
    import std.process : thisProcessID;
    assert(call("environment", `{"action":"processes","pid":` ~ to!string(thisProcessID) ~ `}`)["matches"].integer == 1);
    version (Windows) call("environment", `{"action":"ports","limit":2}`);
    writeln("PASS native executable, process, disk and TCP inspection");

    JSONValue launch;
    launch["program"] = "python";
    launch["args"] = JSONValue([JSONValue("-u"), JSONValue("-c"), JSONValue("import time; print('early 世界',flush=True); time.sleep(1.2); print('late',flush=True)")]);
    launch["background"] = true;
    auto started = executeTool(OpenCodeToolCall("start", "run", launch.toString()), root);
    assert(!started.failed, started.output);
    auto id = started.output[started.output.indexOf("processId: ") + 11 .. $];
    id = id[0 .. id.indexOf('\n')].strip();
    JSONValue waiting;
    waiting["action"] = "wait"; waiting["processId"] = id;
    waiting["event"] = "output"; waiting["timeout"] = 5000;
    auto early = call("process", waiting.toString());
    assert(early["output"].str.canFind("early 世界"));
    assert(early["status"].str == "running");
    waiting["offset"] = early["nextOffset"];
    waiting["event"] = "exit"; waiting["timeout"] = 0;
    assert(call("process", waiting.toString())["deadlineReached"].type == JSONType.true_);
    waiting["timeout"] = 5000;
    auto done = call("process", waiting.toString());
    assert(done["exitCode"].integer == 0 && done["output"].str.canFind("late") && !done["output"].str.canFind("early"));
    // Cancellation interrupts the wait promptly without orphaning its process.
    launch["args"].array[2] = JSONValue("import time; time.sleep(10)");
    started = executeTool(OpenCodeToolCall("start2", "run", launch.toString()), root);
    id = started.output[started.output.indexOf("processId: ") + 11 .. $];
    id = id[0 .. id.indexOf('\n')].strip();
    waiting["processId"] = id; waiting["offset"] = 0;
    auto cancelled = new ToolCancellation();
    auto worker = new Thread({ Thread.sleep(100.msecs); cancelled.cancel(); }); worker.start();
    const clock = MonoTime.currTime;
    assert(executeTool(OpenCodeToolCall("cancel", "process", waiting.toString()), root, cancelled).failed);
    assert(MonoTime.currTime - clock < 2.seconds);
    worker.join();
    killAllSupervisedProcesses();
    writeln("PASS event/completion waits, incremental output, zero-deadline and cancellation");
    writeln("ARTIFACTS ", root);
    return 0;
}

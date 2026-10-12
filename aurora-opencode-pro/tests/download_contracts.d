module download_contracts;

import auroraopencode.download;
import auroraopencode.transferprogress;
import auroraopencode.tools : executeTool, ToolCancellation;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, write, getSize;
import std.json : parseJSON, JSONValue;
import std.path : absolutePath, buildPath, dirName;
import std.process : spawnProcess, Config, kill, wait, environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const root = absolutePath("download-contracts-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    const portPath = buildPath(root, "port.json");
    const script = absolutePath(buildPath(dirName(__FILE__), "download_fixture_server.py"));
    auto server = spawnProcess(["python", "-B", script, portPath], null, Config.suppressConsole);
    scope (exit) { kill(server); wait(server); }
    const deadline = MonoTime.currTime + 5.seconds;
    while (!exists(portPath) && MonoTime.currTime < deadline) Thread.sleep(10.msecs);
    assert(exists(portPath), "HTTP fixture server did not start");
    const url = "http://127.0.0.1:" ~ to!string(parseJSON(readText(portPath))["port"].integer);
    const source = buildPath(root, "expected.bin");
    write(source, replicate("fixture bytes\n", 65536));
    const digest = checksumFile(source);
    TransferProgress[] updates;
    void observe(string text)
    {
        TransferProgress progress;
        if (decodeTransferProgress(text, progress)) updates ~= progress;
    }
    const redirected = buildPath(root, "redirected.bin");
    auto result = downloadFile(url ~ "/redirect", redirected, digest, true, null, &observe);
    assert(!result.failed && read(redirected) == read(source), result.output);
    assert(updates.length && updates[$ - 1].filesDone == 1 && updates[$ - 1].fraction() == 1);
    auto overwrite = downloadFile(url ~ "/data", redirected);
    assert(overwrite.failed && read(redirected) == read(source));
    writeln("Redirected HTTP download verifies SHA-256 and never overwrites destinations");

    const resumable = buildPath(root, "resumable.bin");
    auto broken = downloadFile(url ~ "/truncated", resumable, digest, true, null, &observe);
    assert(broken.failed && !exists(resumable) && exists(resumable ~ ".aurora-download.part"), broken.output);
    const partialSize = getSize(resumable ~ ".aurora-download.part");
    assert(partialSize > 0 && partialSize < getSize(source));
    auto resumed = downloadFile(url ~ "/truncated", resumable, digest, true, null, &observe);
    assert(!resumed.failed && read(resumable) == read(source), resumed.output);
    bool sawResume;
    foreach (update; updates) if (update.phase == "Resuming download") sawResume = true;
    assert(sawResume && !exists(resumable ~ ".aurora-download.part"));
    writeln("An interrupted download resumes with validated HTTP range and exact final bytes");

    auto token = new ToolCancellation();
    const cancelled = buildPath(root, "cancelled.bin");
    auto stopped = downloadFile(url ~ "/data", cancelled, digest, true, &token.cancelled, (string text) {
        TransferProgress progress;
        if (decodeTransferProgress(text, progress) && progress.bytesDone > 0) token.cancel();
    });
    assert(stopped.failed && !exists(cancelled) && exists(cancelled ~ ".aurora-download.part"), stopped.output);
    auto retry = downloadFile(url ~ "/data", cancelled, digest, true, null, &observe);
    assert(!retry.failed && read(cancelled) == read(source), retry.output);
    writeln("Stop keeps resumable data; retry completes and verifies it");

    token = new ToolCancellation();
    const completePartial = buildPath(root, "complete-partial.bin");
    auto interruptedCheck = downloadFile(url ~ "/data", completePartial, digest, true, &token.cancelled, (string text) {
        TransferProgress progress;
        if (decodeTransferProgress(text, progress) && progress.phase == "Checking SHA-256") token.cancel();
    });
    assert(interruptedCheck.failed && getSize(completePartial ~ ".aurora-download.part") == getSize(source));
    auto completedRetry = downloadFile(url ~ "/data", completePartial, digest);
    assert(!completedRetry.failed && read(completePartial) == read(source), completedRetry.output);
    writeln("A complete partial download stopped during checksum recovers from HTTP 416");

    token = new ToolCancellation();
    const ignoresRange = buildPath(root, "ignores-range.bin");
    auto ignoredStopped = downloadFile(url ~ "/ignore-range", ignoresRange, digest, true, &token.cancelled, (string text) {
        TransferProgress progress;
        if (decodeTransferProgress(text, progress) && progress.bytesDone > 0) token.cancel();
    });
    assert(ignoredStopped.failed && exists(ignoresRange ~ ".aurora-download.part"));
    auto restarted = downloadFile(url ~ "/ignore-range", ignoresRange, digest);
    assert(!restarted.failed && read(ignoresRange) == read(source), restarted.output);
    writeln("A server ignoring Range restarts without appending duplicate bytes");

    const bad = buildPath(root, "bad.bin");
    auto mismatch = downloadFile(url ~ "/data", bad, replicate("0", 64));
    assert(mismatch.failed && !exists(bad) && !exists(bad ~ ".aurora-download.part"));
    auto denied = downloadFile(url ~ "/forbidden", buildPath(root, "denied.bin"));
    assert(denied.failed && denied.output.indexOf("403") >= 0);
    auto unknown = downloadFile(url ~ "/unknown", buildPath(root, "unknown.bin"), digest, true, null, &observe);
    assert(!unknown.failed, unknown.output);
    writeln("Checksum mismatches and HTTP errors fail safely; unknown lengths still stream");

    JSONValue args;
    args["filePath"] = source;
    args["sha256"] = digest;
    auto check = executeTool(OpenCodeToolCall("checksum", "checksum", args.toString()), root);
    assert(!check.failed && check.output.indexOf("Checksum matched") >= 0, check.output);
    args["sha256"] = replicate("0", 64);
    auto rejected = executeTool(OpenCodeToolCall("checksum", "checksum", args.toString()), root);
    assert(rejected.failed);
    writeln("Agent checksum tool compares expected values using streamed reads");
    return 0;
}

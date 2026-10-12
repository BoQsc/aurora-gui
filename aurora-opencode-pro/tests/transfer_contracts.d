module transfer_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool, ChangeContext, ToolCancellation,
    listChangeRecords, revertChangeRecord, safetySnapshotFileLimit;
import auroraopencode.filetransfer : transferFiles;
import auroraopencode.transferprogress;
import auroraopencode.toolscheduler : scheduleToolBatch;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, write, getSize, dirEntries, SpanMode;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.stdio : File, writeln;
import std.string : indexOf;

private OpenCodeToolCall call(string name, string[] sources, string destination)
{
    JSONValue args;
    args["sources"] = sources;
    args["destinationFolder"] = destination;
    return OpenCodeToolCall("transfer-test-" ~ to!string(MonoTime.currTime.ticks), name, args.toString());
}

int main()
{
    const root = absolutePath(buildPath("transfer-contracts-" ~ to!string(MonoTime.currTime.ticks)));
    mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    mkdirRecurse(buildPath(root, "target"));
    const big = buildPath(root, "multi-gigabyte.gguf");
    auto sparse = File(big, "wb");
    version (Windows)
    {
        import core.sys.windows.windows : DeviceIoControl, DWORD;
        import core.sys.windows.winioctl : FSCTL_SET_SPARSE;
        DWORD returned;
        assert(DeviceIoControl(sparse.windowsHandle, FSCTL_SET_SPARSE, null, 0, null, 0, &returned, null));
    }
    enum ulong hugeSize = 8UL * 1024 * 1024 * 1024 + 17;
    sparse.seek(hugeSize - 1);
    sparse.rawWrite([cast(ubyte) 42]);
    sparse.close();
    ChangeContext context;
    context.conversationId = "test-chat";
    context.turnId = "test-turn";
    TransferProgress[] progress;
    void observe(string text)
    {
        TransferProgress update;
        if (decodeTransferProgress(text, update)) progress ~= update;
    }
    auto moved = executeTool(call("move", [big], buildPath(root, "target")), root,
        null, context, &observe);
    assert(!moved.failed, moved.output);
    assert(!exists(big) && getSize(buildPath(root, "target", "multi-gigabyte.gguf")) == hugeSize);
    assert(progress.length > 0 && progress[$ - 1].totalBytes == hugeSize && progress[$ - 1].fraction() == 1);
    assert(progress[$ - 1].metadataOnly && progress[$ - 1].bytesPerSecond == 0);
    ulong historyBytes;
    foreach (entry; dirEntries(buildPath(root, "state"), SpanMode.depth))
        if (entry.isFile) historyBytes += entry.size;
    assert(historyBytes < 1024 * 1024, "Moving a GGUF duplicated large file bytes into history");
    auto records = listChangeRecords(root);
    assert(records.length == 2 && records[0].restoreUnavailable.length && records[1].restoreUnavailable.length);
    auto restored = revertChangeRecord(root, records[0].id, true, context);
    assert(!restored.succeeded && exists(buildPath(root, "target", "multi-gigabyte.gguf")));
    writeln("8 GiB same-volume move uses metadata only and bounded, non-restorable history");

    const source = buildPath(root, "tree");
    mkdirRecurse(buildPath(source, "nested", "empty"));
    write(buildPath(source, "nested", "text.txt"), "exact bytes\n");
    auto copied = executeTool(call("copy", [source], buildPath(root, "target")), root,
        null, context, &observe);
    assert(!copied.failed, copied.output);
    assert(readText(buildPath(root, "target", "tree", "nested", "text.txt")) == "exact bytes\n");
    assert(exists(buildPath(root, "target", "tree", "nested", "empty")));
    auto conflict = executeTool(call("copy", [source], buildPath(root, "target")), root);
    assert(conflict.failed && exists(source));
    records = listChangeRecords(root);
    auto undoCopy = revertChangeRecord(root, records[$ - 1].id, true, context);
    assert(undoCopy.succeeded && !exists(buildPath(root, "target", "tree")) && exists(source));
    writeln("Folder copies preserve empty directories, reject collisions, and retain small-file restore");

    const empty = buildPath(root, "empty");
    mkdirRecurse(empty);
    auto emptyCopy = executeTool(call("copy", [empty], buildPath(root, "target")), root,
        null, ChangeContext.init, &observe);
    assert(!emptyCopy.failed && progress[$ - 1].fraction() == 1, "Empty-folder completion did not reach 100%");

    const input = buildPath(root, "data.bin");
    auto file = File(input, "wb");
    auto chunk = new ubyte[1024 * 1024];
    chunk[] = 39;
    foreach (_; 0 .. 64) file.rawWrite(chunk);
    file.close();
    const crossTarget = buildPath(root, "target", "cross.bin");
    auto cross = transferFiles([input], [crossTarget], true, null, &observe, true);
    assert(!cross.failed && !exists(input) && getSize(crossTarget) == 64 * 1024 * 1024, cross.output);
    auto check = File(crossTarget, "rb");
    assert(check.rawRead(new ubyte[32]) == chunk[0 .. 32]);
    check.close();
    writeln("Cross-volume move path copies bytes before source deletion");

    auto cancellation = new ToolCancellation();
    const cancelledTarget = buildPath(root, "target", "cancelled.bin");
    auto cancelled = transferFiles([crossTarget], [cancelledTarget], true,
        &cancellation.cancelled, (string text) {
            TransferProgress update;
            if (decodeTransferProgress(text, update) && update.bytesDone > 0) cancellation.cancel();
        }, true);
    assert(cancelled.failed && exists(crossTarget) && !exists(cancelledTarget), cancelled.output);
    foreach (entry; dirEntries(buildPath(root, "target"), SpanMode.shallow))
        assert(entry.name.indexOf(".aurora-part-") < 0, "Partial transfer file was left behind");
    writeln("Cancellation keeps cross-volume sources and cleans incomplete destinations");

    const collisionTarget = buildPath(root, "target", "new-user-file.bin");
    bool inserted;
    auto racing = transferFiles([crossTarget], [collisionTarget], false, null, (string text) {
        TransferProgress update;
        if (!inserted && decodeTransferProgress(text, update) && update.phase == "Copying")
        { write(collisionTarget, "new user contents"); inserted = true; }
    });
    assert(racing.failed && readText(collisionTarget) == "new user contents", racing.output);
    writeln("A destination created during copying is never overwritten or removed");

    auto status = executeTool(OpenCodeToolCall("status", "tool_status", "{}"), root);
    assert(!status.failed && parseJSON(status.output)["workspace"]["running"].array.length == 0);
    TransferProgress large;
    large.totalBytes = 14UL * 1024 * 1024 * 1024;
    large.bytesDone = large.totalBytes / 2;
    large.bytesPerSecond = 150 * 1024 * 1024;
    large.remainingSeconds = 45;
    large.totalsKnown = true;
    large.phase = "Copying";
    TransferProgress decoded;
    assert(decodeTransferProgress(encodeTransferProgress(large), decoded));
    assert(decoded.fraction() == 0.5 && decoded.totalBytes == large.totalBytes);
    assert(transferProgressText(decoded).indexOf("150.0 MiB/s") >= 0);
    writeln("Progress carries 64-bit sizes, rate and ETA; scheduler inspection is available");
    return 0;
}

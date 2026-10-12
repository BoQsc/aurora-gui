module auroraopencode.filetransfer;

import auroraopencode.transferprogress;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : dirEntries, exists, getSize, isDir, isFile, isSymlink,
    mkdir, remove, rename, rmdirRecurse, SpanMode;
import std.path : baseName, buildPath;
import std.stdio : File;
import std.utf : toUTF16z;

public struct TransferOutcome { bool failed; string output; }
private struct Entry { size_t root; string source, target; bool directory; ulong size; }

private final class TransferState
{
    bool delegate() cancelled;
    void delegate(string) observer;
    TransferProgress progress;
    MonoTime started, nextReport;
    ulong copiedBytes, currentBase;
    Throwable callbackError;

    this(bool delegate() cancelled, void delegate(string) observer)
    {
        this.cancelled = cancelled;
        this.observer = observer;
        started = MonoTime.currTime;
    }
    void check()
    {
        if (cancelled !is null && cancelled()) throw new Exception("Stopped: transfer cancelled.");
    }
    void report(bool force = false)
    {
        if (observer is null || (!force && MonoTime.currTime < nextReport)) return;
        observer(encodeTransferProgress(progress));
        nextReport = MonoTime.currTime + 150.msecs;
    }
    void advanced(ulong current)
    {
        progress.bytesDone = currentBase + current;
        const elapsed = (MonoTime.currTime - started).total!"msecs";
        progress.bytesPerSecond = elapsed > 0 ? cast(double) (copiedBytes + current) * 1000 / elapsed : 0;
        progress.remainingSeconds = progress.bytesPerSecond > 0 && progress.totalsKnown && progress.bytesDone <= progress.totalBytes ?
            (progress.totalBytes - progress.bytesDone) / progress.bytesPerSecond : -1;
        report();
    }
}

version (Windows)
{
    import core.sys.windows.windows : CopyFileExW, COPY_FILE_FAIL_IF_EXISTS,
        MoveFileExW, GetLastError, ERROR_NOT_SAME_DEVICE, ERROR_FILE_EXISTS,
        ERROR_ALREADY_EXISTS, PROGRESS_CONTINUE, PROGRESS_CANCEL,
        LARGE_INTEGER, DWORD, HANDLE, LPVOID;

    private extern (Windows) DWORD copied(LARGE_INTEGER total, LARGE_INTEGER done,
        LARGE_INTEGER streamTotal, LARGE_INTEGER streamDone, DWORD stream,
        DWORD reason, HANDLE source, HANDLE target, LPVOID data)
    {
        auto state = cast(TransferState) data;
        try
        {
            state.check();
            state.advanced(cast(ulong) done.QuadPart);
            return PROGRESS_CONTINUE;
        }
        catch (Throwable error)
        {
            state.callbackError = error;
            return PROGRESS_CANCEL;
        }
    }

    private bool moveName(string source, string target)
    {
        if (MoveFileExW(source.toUTF16z, target.toUTF16z, 0)) return true;
        const error = GetLastError();
        if (error == ERROR_NOT_SAME_DEVICE) return false;
        throw new Exception("Windows move failed (" ~ to!string(error) ~ "): " ~ source ~ " -> " ~ target);
    }
}
else
{
    private bool moveName(string source, string target)
    {
        if (exists(target)) throw new Exception("Destination already exists: " ~ target);
        try { rename(source, target); return true; }
        catch (Exception) return false;
    }
}

private void copyFile(string source, string target, ulong expectedSize, TransferState state)
{
    state.check();
    state.progress.path = source;
    state.currentBase = state.progress.bytesDone;
    state.report(true);
    // Install only a completed file. The final rename never replaces a target
    // created by another program after the initial batch preflight.
    const partial = target ~ ".aurora-part-" ~ to!string(MonoTime.currTime.ticks);
    bool ownPartial;
    scope (exit) if (ownPartial && exists(partial)) remove(partial);
    version (Windows)
    {
        const ok = CopyFileExW(source.toUTF16z, partial.toUTF16z, &copied,
            cast(void*) state, null, COPY_FILE_FAIL_IF_EXISTS);
        const error = ok ? 0 : GetLastError();
        ownPartial = ok || (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS);
        if (state.callbackError !is null) throw state.callbackError;
        if (!ok) throw new Exception("Windows copy failed (" ~ to!string(error) ~ "): " ~ source);
    }
    else
    {
        if (exists(partial)) throw new Exception("Partial path already exists: " ~ partial);
        auto input = File(source, "rb");
        auto output = File(partial, "wb");
        ownPartial = true;
        auto buffer = new ubyte[1024 * 1024];
        ulong done;
        while (true)
        {
            state.check();
            const chunk = input.rawRead(buffer);
            if (!chunk.length) break;
            output.rawWrite(chunk);
            done += chunk.length;
            state.advanced(done);
        }
        output.close();
        input.close();
    }
    state.check();
    if (getSize(partial) != expectedSize)
        throw new Exception("Source size changed during transfer: " ~ source);
    if (!moveName(partial, target)) throw new Exception("Could not install completed copy: " ~ target);
    ownPartial = false;
    const size = getSize(target);
    state.progress.bytesDone = state.currentBase + size;
    state.copiedBytes += size;
    ++state.progress.filesDone;
    state.report(true);
}

/// Byte transfers use bounded native I/O. Same-volume moves use the OS rename
/// path; cross-volume moves copy every item before deleting any source.
public TransferOutcome transferFiles(const string[] sources, const string[] targets,
    bool moving, bool delegate() cancelled = null, void delegate(string) observer = null,
    bool forceCopyMoveForTesting = false)
{
    auto state = new TransferState(cancelled, observer);
    Entry[] entries;
    size_t[] renamed, copiedRoots, createdRoots;
    bool committing;
    try
    {
        state.progress.phase = "Scanning transfer";
        void scan(size_t root, string source, string target, int depth = 0)
        {
            state.check();
            state.progress.path = source;
            state.report();
            if (depth > 256 || entries.length >= 100_000)
                throw new Exception("Transfer exceeds 100,000 entries or 256 folder levels; split it into smaller batches.");
            if (isSymlink(source)) throw new Exception("Symbolic links and junctions are not supported: " ~ source);
            const directory = isDir(source);
            if (!directory && !isFile(source)) throw new Exception("Unsupported entry: " ~ source);
            const size = directory ? 0 : getSize(source);
            entries ~= Entry(root, source, target, directory, size);
            state.progress.totalBytes += size;
            if (!directory) ++state.progress.totalFiles;
            else foreach (entry; dirEntries(source, SpanMode.shallow))
                scan(root, entry.name, buildPath(target, baseName(entry.name)), depth + 1);
        }
        if (sources.length != targets.length) throw new Exception("Mismatched transfer paths.");
        foreach (i, source; sources)
        {
            if (exists(targets[i])) throw new Exception("Destination already exists: " ~ targets[i]);
            scan(i, source, targets[i]);
        }
        state.progress.totalsKnown = true;
        state.started = MonoTime.currTime;
        foreach (i, source; sources)
        {
            state.check();
            state.progress.path = source;
            state.progress.phase = moving ? "Moving" : "Copying";
            state.progress.metadataOnly = moving && !forceCopyMoveForTesting;
            state.report(true);
            if (moving && !forceCopyMoveForTesting && moveName(source, targets[i]))
            {
                renamed ~= i;
                foreach (entry; entries) if (entry.root == i && !entry.directory)
                {
                    state.progress.bytesDone += entry.size;
                    ++state.progress.filesDone;
                }
                state.report(true);
                continue;
            }
            state.progress.metadataOnly = false;
            bool rootCreated;
            foreach (entry; entries) if (entry.root == i)
            {
                state.check();
                if (entry.directory)
                {
                    if (exists(entry.target)) throw new Exception("Destination appeared during transfer: " ~ entry.target);
                    mkdir(entry.target);
                }
                else copyFile(entry.source, entry.target, entry.size, state);
                if (!rootCreated) { createdRoots ~= i; rootCreated = true; }
            }
            copiedRoots ~= i;
        }
        state.check();
        if (moving)
        {
            // All destination copies are complete before source cleanup starts.
            // A cleanup failure keeps those copies and reports partial completion.
            committing = true;
            state.progress.phase = "Finishing move";
            state.report(true);
            foreach (i; copiedRoots)
            {
                if (isDir(sources[i])) rmdirRecurse(sources[i]);
                else remove(sources[i]);
            }
        }
        state.progress.phase = moving ? "Move complete" : "Copy complete";
        state.report(true);
        string output = (moving ? "Moved " : "Copied ") ~ to!string(sources.length) ~ " item(s), " ~
            transferBytes(state.progress.totalBytes) ~ ".";
        foreach (i, source; sources) output ~= "\n- " ~ source ~ " -> " ~ targets[i];
        return TransferOutcome(false, output);
    }
    catch (Throwable error)
    {
        string output = "Error: " ~ error.msg;
        if (committing)
            output ~= "\nMove cleanup was incomplete. Completed destination copies were kept; inspect source and destination before retrying.";
        else
        {
            foreach_reverse (i; renamed)
                try
                {
                    if (!moveName(targets[i], sources[i])) throw new Exception("Cannot restore renamed item.");
                }
                catch (Exception rollback) { output ~= "\nCould not restore " ~ targets[i] ~ ": " ~ rollback.msg; }
            foreach_reverse (i; createdRoots)
                try
                {
                    if (isDir(targets[i])) rmdirRecurse(targets[i]);
                    else if (exists(targets[i])) remove(targets[i]);
                }
                catch (Exception cleanup) { output ~= "\nCould not remove partial copy " ~ targets[i] ~ ": " ~ cleanup.msg; }
            output ~= "\nUnfinished copies were cleaned up; no cross-volume source was deleted.";
        }
        state.progress.phase = "Transfer stopped";
        state.report(true);
        return TransferOutcome(true, output);
    }
}

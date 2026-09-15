module auroraopencode.crashguard;

import auroraopencode.core : opencodeStateDirectory;
import auroraopencode.logging : logError, logInfo, setLogDirectory;
import std.algorithm : sort, splitter;
import std.conv : parse, to;
import std.datetime : SysTime;
import std.file : copy, dirEntries, exists, mkdirRecurse, readText, remove,
    SpanMode, thisExePath, timeLastModified;
import std.path : baseName, buildPath, dirName, setExtension;
import std.stdio : stderr;
import std.string : indexOf, lastIndexOf;

// ---------------------------------------------------------------------------
// Crash reporting
// ---------------------------------------------------------------------------
// The app writes app-level errors with auroraopencode.logging, but a crash
// never reaches those call sites. Two failure modes need catching, and they
// need different hooks:
//
//   * an uncaught D Throwable (`Error` subclasses such as AssertError and
//     RangeError, or a stray Exception) - caught by `runGuarded`, which wraps
//     the whole application body;
//   * a native structured exception (access violation, stack overflow), which
//     is not a D exception at all and unwinds nothing - caught by
//     `SetUnhandledExceptionFilter` on Windows.
//
// Both append to `<stateDir>/logs/errors.log` through the existing logger, so
// crashes sit in the same file as ordinary errors and are easy to correlate.
// `installCrashHandler` resolves and sets the log directory itself, so a crash
// during startup is logged even though the UI (which normally sets the log
// directory) has not been constructed yet.
//
// A native fault carries no D trace, only the faulting address, so the filter
// captures the faulting thread's stack (druntime's `StackTrace`) and logs each
// frame as a bare address. It deliberately does not resolve those addresses
// here: dbghelp reaches for a symbol server when it cannot satisfy a lookup
// locally, and this code runs while the process is dying, so a lookup that
// blocks means the report is never written at all - which is how a crash ends
// up logged with an address and no stack.
//
// Addresses are symbolized afterwards with
// `crashsym/symlookup.exe <exe> <address>`, turning "crash at 0x1402E7ED2"
// into function, file and line with no debugger installed.
//
// Resolution needs the .pdb to match the running executable, which needs the
// build to emit debug info: the `release` build type in dub.json therefore
// lists the `debugInfo` build option. `warnAboutMissingSymbols` reports a
// missing or stale .pdb at startup rather than leaving it to be discovered
// after a crash.

private __gshared bool _installed;

/// Last activity recorded by `noteActivity`, so the native filter can report
/// how far the process got before it faulted.
private __gshared string _lastActivity;

/// The most recent marker already written to the log, so repeated identical
/// activity does not become repeated flushed writes.
private __gshared string _lastLoggedActivity;

/// Identifies the build the archived symbols belong to, so a crash report can
/// be matched to the `.pdb` that describes it.
private __gshared string _buildKey;

/// How many archived symbol files to keep. Each is the size of the `.pdb`, so
/// the archive is trimmed rather than allowed to grow per build.
private enum int keepSymbolArchives = 3;

/**
 * Record what the app is doing, cheaply enough to call on any path that could
 * fault.
 *
 * A native access violation unwinds nothing and carries no D trace: the only
 * way to know which step was running when it died is for the app to have said
 * so beforehand. `noteActivity` writes that marker to the log immediately
 * rather than keeping it in memory, because the crash handler may be as
 * broken as the faulting code. It also stamps the value into `_lastActivity`
 * for the uncaught-Throwable path.
 */
public void noteActivity(string what)
{
    _lastActivity = what;
    // `rebuildMessageColumn` runs several times per interaction, and every
    // entry is a flushed write, so repeat the same marker only once. The
    // marker only has to name the step that was running, and consecutive
    // identical calls are the same step.
    if (what == _lastLoggedActivity) return;
    _lastLoggedActivity = what;
    logInfo("activity: " ~ what);
}

/// The last value passed to `noteActivity`, or "" when none was recorded.
public string lastActivity()
{
    return _lastActivity;
}

/**
 * `--resolve-crash <exe> <address-hex>`: resolve one address against the
 * executable's own symbols and log the result. Returns true when the process
 * handled this mode and must exit. The executable exists to be running the
 * same build the address came from; the symbols beside it are the ones that
 * describe it.
 */
public bool runResolveCrashMode(string[] args)
{
    if (args.length < 2 || args[1] != "--resolve-crash") return false;
    installCrashHandler();
    if (args.length < 4)
    {
        logError("resolve-crash: missing exe or address");
        return true;
    }
    version (Windows)
    {
        try
        {
            auto digits = args[3];
            const shown = digits;
            if (digits.length > 2 && (digits[0 .. 2] == "0x" ||
                digits[0 .. 2] == "0X"))
                digits = digits[2 .. $];
            const address = parse!size_t(digits, 16);
            auto resolved = StackTrace.resolve([address]);
            if (resolved.length == 0)
                logError("crash resolver: no symbol for " ~ shown);
            else
                logError("crash resolver: " ~ shown ~ " -> " ~
                    resolved[0].idup);
        }
        catch (Throwable error)
        {
            try logError("crash resolver failed: " ~ error.toString());
            catch (Throwable) {}
        }
    }
    return true;
}

/// Idempotent: safe to call from every entry path.
public void installCrashHandler()
{
    if (_installed) return;
    _installed = true;
    const logs = buildPath(opencodeStateDirectory(), "logs");
    setLogDirectory(logs);
    logInfo("crash handler installed; log: " ~
        buildPath(logs, "errors.log"));
    warnAboutMissingSymbols();
    archiveSymbols();
    version (Windows) installNativeFilter();
    resolvePreviousCrash();
}

/// Matches `native crash: ... at HEX` in the log.
private enum crashAddressMarker = " at ";

/**
 * Resolve the faulting address from the previous run's crash, from a healthy
 * process running the same code.
 *
 * The crash handler cannot do this itself: a stack walk in a process that has
 * already faulted tends to fault again, and that second fault kills the
 * process before the report is written - which is exactly how crashes ended
 * up recorded as a bare address with nothing after it. Here the frames are
 * walked from a normal start-up, where the stack is intact, so the function,
 * file and line that the handler could not produce are appended to the log on
 * the next launch.
 */
private void resolvePreviousCrash() nothrow
{
    version (Windows)
    {
        import core.sys.windows.stacktrace : StackTrace;
        resolvePreviousCrashImpl!StackTrace();
    }
}

private void resolvePreviousCrashImpl(StackTrace)() nothrow
{
    try
    {
        const logPath = buildPath(opencodeStateDirectory(), "logs",
            "errors.log");
        if (!exists(logPath)) return;
        const text = readText(logPath);
        const index = text.lastIndexOf("native crash:");
        if (index < 0) return;
        // Only act on a crash that has not been named yet: stop at the last
        // banner, and skip anything already resolved.
        const tail = text[index .. $];
        // Skip a crash that has already been dealt with, so an old entry does
        // not re-report on every launch and bury the next real one.
        if (tail.indexOf("crash resolver:") >= 0 ||
            tail.indexOf("native fault stack") >= 0)
            return;
        const at = tail.indexOf(crashAddressMarker);
        if (at < 0) return;
        // Only resolve when this process is the same build that crashed. The
        // symbol tables of a different build describe different addresses, so
        // resolving across a rebuild names an unrelated function with total
        // confidence - worse than reporting nothing. `build key:` is written
        // by the handler, and the archived `.pdb` for other builds is left for
        // an offline lookup.
        const keyMarker = "build key: ";
        const keyAt = tail.indexOf(keyMarker);
        if (keyAt < 0) return;
        const loggedKey = tail[keyAt + keyMarker.length .. $].splitter(" ").front;
        if (_buildKey.length == 0 || loggedKey != _buildKey)
        {
            logError("previous crash was from build " ~ loggedKey ~
                "; not resolving against this build (" ~ _buildKey ~
                "). Use logs/symbols/" ~ loggedKey ~ ".pdb");
            return;
        }
        auto digits = tail[at + crashAddressMarker.length .. $];
        size_t end;
        while (end < digits.length && (digits[end] == '0' || digits[end] == 'x' ||
            digits[end] == 'X' || (digits[end] >= '0' && digits[end] <= '9') ||
            (digits[end] >= 'A' && digits[end] <= 'F') ||
            (digits[end] >= 'a' && digits[end] <= 'f')))
            ++end;
        if (end == 0) return;
        digits = digits[0 .. end];
        if (digits.length > 2 && (digits[0 .. 2] == "0x" ||
            digits[0 .. 2] == "0X"))
            digits = digits[2 .. $];
        const address = parse!size_t(digits, 16);
        auto resolved = StackTrace.resolve([address]);
        if (resolved.length == 0)
        {
            logError("previous crash address could not be resolved");
            return;
        }
        logError("previous crash resolved: " ~ resolved[0].idup);
    }
    catch (Throwable error)
    {
        try logError("previous crash resolution failed: " ~ error.toString());
        catch (Throwable) {}
    }
}

/**
 * Archive the `.pdb` describing this build, once per build.
 *
 * Crash addresses can only be resolved against the `.pdb` of the executable
 * that produced them, and the next rebuild overwrites that file in place. A
 * crash is therefore unresolvable after the rebuild that follows it unless the
 * symbols were copied out first. The copy happens here, at startup, because a
 * dying process is the wrong place to move 12 MB: this runs while the process
 * is still healthy.
 */
private void archiveSymbols()
{
    try
    {
        const exe = thisExePath();
        const pdb = buildPath(dirName(exe), baseName(exe).setExtension("pdb"));
        if (!exists(pdb)) return;
        const key = buildKey(timeLastModified(exe), timeLastModified(pdb));
        _buildKey = key;
        mkdirRecurse(buildPath(opencodeStateDirectory(), "logs", "symbols"));
        const archive = buildPath(opencodeStateDirectory(), "logs", "symbols",
            key ~ ".pdb");
        if (!exists(archive))
        {
            copy(pdb, archive);
            logInfo("archived crash symbols for this build: " ~ archive);
        }
        pruneSymbols(buildPath(opencodeStateDirectory(), "logs", "symbols"),
            archive);
    }
    catch (Exception error)
        logInfo("symbol archive failed: " ~ error.msg);
}

/// A stable name for one build: both file timestamps identify an executable
/// and the `.pdb` that describes it.
private string buildKey(SysTime exeStamp, SysTime pdbStamp)
{
    return to!string(exeStamp.toUnixTime()) ~ "-" ~
        to!string(pdbStamp.toUnixTime());
}

/// Keep the most recent archives, oldest removed first.
private void pruneSymbols(string archiveDir, string current)
{
    string[] found;
    foreach (entry; dirEntries(archiveDir, "*.pdb", SpanMode.shallow))
        if (entry.isFile) found ~= entry.name;
    if (found.length <= keepSymbolArchives) return;
    sort!((a, b) => timeLastModified(a) < timeLastModified(b))(found);
    foreach (old; found[0 .. $ - keepSymbolArchives])
    {
        if (old == current) continue;
        try remove(old);
        catch (Exception) {}
    }
}

/**
 * A native crash can only be attributed to a function when dbghelp can find
 * symbols for the running executable, so say up front when it cannot. A stale
 * .pdb is the quiet failure mode: it exists, so symbol lookup succeeds, but it
 * describes a different binary and resolves to unrelated - and therefore
 * actively misleading - function names.
 */
private void warnAboutMissingSymbols()
{
    try
    {
        const exe = thisExePath();
        const pdb = buildPath(dirName(exe), baseName(exe).setExtension("pdb"));
        if (!exists(pdb))
            logInfo("native crash reports will show addresses only: no " ~ pdb);
        else if (timeLastModified(pdb) < timeLastModified(exe))
            logInfo("native crash symbols are stale: " ~ pdb ~
                " predates " ~ exe ~ "; rebuild with debug info enabled");
    }
    catch (Exception error)
        logInfo("symbol check failed: " ~ error.msg);
}

/**
 * Run the application body, recording any uncaught Throwable before the
 * process dies. `Error`s cannot be recovered from, so this always re-exits with
 * a failure code and never returns normally on a throw; a launcher can then
 * tell a crash apart from a normal window close (exit code 0).
 *
 * The log is appended per call, so the crash entry is already on disk by the
 * time control leaves.
 */
public int runGuarded(scope int delegate() body)
{
    try
        return body();
    catch (Throwable error)
    {
        reportUncaught(error);
        return 1;
    }
}

/// Log an uncaught Throwable with its stack trace, then terminate.
public void reportUncaught(Throwable error) nothrow
{
    try
    {
        const kind = cast(Error) error !is null ? "Error" : "Exception";
        auto trace = error.info is null ? "(no trace)" : error.info.toString();
        logError("uncaught " ~ kind ~ ": " ~ error.toString() ~ "\n" ~ trace);
    }
    catch (Throwable) {}
    try
    {
        stderr.writeln("uncaught ", error.toString());
        stderr.flush();
    }
    catch (Throwable) {}
    import core.stdc.stdlib : exit;
    exit(1);
}

version (Windows)
{
    import core.sys.windows.stacktrace : StackTrace;
    import core.sys.windows.windows : EXCEPTION_POINTERS, LONG,
        SetUnhandledExceptionFilter;
    import core.sys.windows.winbase : GetModuleHandleA;
    import core.sys.windows.winnt : CONTEXT, DWORD;

    /// `EXCEPTION_EXECUTE_HANDLER`: claim the exception and let Windows
    /// terminate the process now that it has been recorded.
    private enum LONG exceptionExecuteHandler = 1;

    /// EXCEPTION_STACK_OVERFLOW. The stack has no room left, so walking it
    /// would fault again; only the code is recorded.
    private enum DWORD statusStackOverflow = 0xC00000FD;

    /// Frames are captured into memory reserved at startup rather than
    /// allocated in the handler. A native fault usually leaves the heap
    /// suspect, so asking the allocator for 504 bytes at that moment can fail
    /// or fault again - and that failure is exactly what loses the stack being
    /// recorded. `.length` is set once here and only read afterwards.
    private __gshared ulong[] frameBuffer;

    private enum size_t frameBufferLength = 63;

    private void prepareFrameBuffer() nothrow
    {
        try
            if (frameBuffer.length < frameBufferLength)
                frameBuffer = new ulong[frameBufferLength];
        catch (Throwable) {}
    }

    private void installNativeFilter() nothrow
    {
        prepareFrameBuffer();
        try SetUnhandledExceptionFilter(&nativeCrashFilter);
        catch (Throwable) {}
    }

    /**
     * A structured exception is not a D exception, so there is no trace info:
     * record the code and faulting address, then reconstruct a symbolized stack
     * from the faulting context.
     */
    private extern (Windows) LONG nativeCrashFilter(EXCEPTION_POINTERS* info)
    {
        try
        {
            auto record = info !is null ? info.ExceptionRecord : null;
            if (record is null)
                logError("native crash: exception pointers unavailable");
            else
            {
                logError("native crash: " ~ describe(record.ExceptionCode) ~
                    " (code " ~ toHex(record.ExceptionCode) ~ ") at " ~
                    toHex(cast(size_t) record.ExceptionAddress));
                // Restated here so the crash entry is self-contained: the
                // matching `activity:` line is already above it, but this is
                // the value to read first.
                if (_lastActivity.length > 0)
                {
                    try logError("last activity: " ~ _lastActivity);
                    catch (Throwable) {}
                }
                // The archived `.pdb` that resolves this address is named
                // after the build key, so record which one to use.
                if (_buildKey.length > 0)
                {
                    try logError("build key: " ~ _buildKey ~
                        " (symbols archived under logs/symbols)");
                    catch (Throwable) {}
                }
                if (record.ExceptionCode == statusStackOverflow)
                    logError("stack overflow: frames skipped, the stack cannot " ~
                        "be walked");
                else if (info.ContextRecord is null)
                    logError("no context record: frames unavailable");
                else
                {
                    // The stack is deliberately NOT walked here. Walking the
                    // stack of a process that has already taken an access
                    // violation faults again inside this handler, and that
                    // second fault kills the process before the rest of the
                    // report is written - which is why crashes showed an
                    // address and then nothing. The faulting address above is
                    // the recoverable evidence; it is resolved at the next
                    // startup by `resolvePreviousCrash`, from a healthy
                    // process running the same code.
                    try logError("module base: " ~ toHex(cast(size_t) moduleBase()));
                    catch (Throwable) {}
                    // Resolution is handed to a fresh process of this same
                    // build. The symbols only match while exe and .pdb are the
                    // same pair, and the next rebuild replaces both, so an
                    // address recorded now is unresolvable later - the earlier
                    // crashes were lost exactly that way. This handler cannot
                    // walk its own stack (that is what killed the report), but
                    // a new process can walk nothing and simply resolve one
                    // address it was handed.
                    spawnResolver(cast(size_t) record.ExceptionAddress);
                }
            }
        }
        catch (Throwable) {}
        return exceptionExecuteHandler;
    }

    private string describe(DWORD code)
    {
        switch (code)
        {
            case 0xC0000005: return "access violation";
            case 0xC00000FD: return "stack overflow";
            case 0xC000001D: return "illegal instruction";
            case 0xC0000094: return "integer divide by zero";
            case 0xC0000096: return "privileged instruction";
            case 0x80000003: return "breakpoint";
            default: return "structured exception";
        }
    }

    /**
     * The captured frames, one bare address per line, for offline resolution
     * with `crashsym/symlookup.exe <exe> <address>`.
     */
    private string formatFrames(const(ulong)[] addresses)
    {
        if (addresses.length == 0)
            return "\n  (no frames captured)";
        string text;
        foreach (index, address; addresses)
            text ~= "\n  #" ~ to!string(index) ~ " " ~ toHex(address);
        return text;
    }

    /// The loaded base of this executable, for rebasing captured addresses.
    private size_t moduleBase()
    {
        return cast(size_t) GetModuleHandleA(null);
    }

    /**
     * Start `--resolve-crash <exe> <address>`, which resolves the address and
     * logs the result. Output is discarded: `spawnProcess` on Windows otherwise
     * waits for the child's streams to close, and this handler is about to end
     * the process.
     */
    private void spawnResolver(size_t address) nothrow
    {
        try
        {
            import std.process : Config, spawnProcess;
            import std.stdio : File;
            const exe = thisExePath();
            File nul;
            try nul = File("NUL", "w");
            catch (Exception) return;
            spawnProcess([exe, "--resolve-crash", exe, toHex(address)],
                nul, nul, nul, null,
                Config.detached | Config.suppressConsole);
        }
        catch (Throwable) {}
    }

    private string toHex(size_t value) nothrow
    {
        char[] digits = "0123456789ABCDEF".dup;
        char[2 * size_t.sizeof] buffer;
        foreach (index; 0 .. buffer.length)
        {
            buffer[buffer.length - 1 - index] =
                digits[cast(size_t)(value & 0xF)];
            value >>= 4;
        }
        return buffer.idup;
    }
}

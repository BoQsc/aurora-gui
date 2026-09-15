module auroraopencode.crashguard;

import auroraopencode.core : opencodeStateDirectory;
import auroraopencode.logging : logError, logInfo, setLogDirectory;
import std.conv : to;
import std.file : exists, thisExePath, timeLastModified;
import std.path : baseName, buildPath, dirName, setExtension;
import std.stdio : stderr;
import std.string : indexOf;

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
// A native fault carries no D trace, only a faulting address, so the filter
// walks the faulting thread's stack itself (druntime's dbghelp-backed
// `StackTrace`) and resolves each frame against the `.pdb` next to the
// executable. That turns "crash at 0x1400038D4" into function, file and line
// without needing a debugger installed.
//
// Resolution needs the .pdb to match the running executable, which needs the
// build to emit debug info: the `release` build type in dub.json therefore
// lists the `debugInfo` build option. Without it dbghelp finds no symbols and
// every frame degrades to a bare address, so `warnAboutMissingSymbols` reports
// that mismatch at startup rather than leaving it to be discovered after a
// crash.

private __gshared bool _installed;

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
    version (Windows) installNativeFilter();
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
    import core.sys.windows.winnt : CONTEXT, DWORD;

    /// `EXCEPTION_EXECUTE_HANDLER`: claim the exception and let Windows
    /// terminate the process now that it has been recorded.
    private enum LONG exceptionExecuteHandler = 1;

    /// EXCEPTION_STACK_OVERFLOW. The stack has no room left, so walking it
    /// would fault again; only the code is recorded.
    private enum DWORD statusStackOverflow = 0xC00000FD;

    private void installNativeFilter() nothrow
    {
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
                if (record.ExceptionCode != statusStackOverflow &&
                    info.ContextRecord !is null)
                    logError("native fault stack:\n" ~ symbolize(info.ContextRecord));
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
     * Walk the faulting thread's stack and resolve it through dbghelp, which
     * finds `aurora-opencode-pro.pdb` next to the executable.
     */
    private string symbolize(CONTEXT* context)
    {
        auto addresses = StackTrace.trace(new ulong[63], 0, context);
        if (addresses.length == 0)
            return "  (no frames captured; dbghelp or symbols unavailable)";
        auto resolved = StackTrace.resolve(addresses);
        if (resolved.length == 0)
            return "  (symbol resolution unavailable)";
        string text;
        bool named;
        foreach (index, frame; resolved)
        {
            const line = frame.idup;
            text ~= "  #" ~ to!string(index) ~ " " ~ line ~ "\n";
            // StackTrace prints "0xADDRESS in SYMBOL ..." once a frame
            // resolves; a bare address means no symbol was found for it.
            if (line.indexOf(" in ") >= 0) named = true;
        }
        if (!named)
            text ~= "  (no symbols resolved; the .pdb does not match this build)\n";
        return text;
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

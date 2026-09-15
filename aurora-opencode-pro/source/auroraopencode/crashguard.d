module auroraopencode.crashguard;

import auroraopencode.core : opencodeStateDirectory;
import auroraopencode.logging : logError, logInfo, setLogDirectory;
import std.path : buildPath;
import std.stdio : stderr;

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
    version (Windows) installNativeFilter();
}

/**
 * Run the application body, recording any uncaught Throwable before the
 * process dies. `Error`s cannot be recovered from, so this always re-exits with
 * a failure code and never returns normally on a throw; the launcher can then
 * tell a crash apart from a normal window close (exit code 0).
 *
 * The log is flushed before exiting: the logger appends per call, so the crash
 * entry is already on disk by the time control leaves.
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
        logInfo("crash: uncaught " ~ kind);
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
    import core.sys.windows.windows : EXCEPTION_POINTERS, LONG,
        SetUnhandledExceptionFilter;

    /// `EXCEPTION_EXECUTE_HANDLER`: claim the exception and let Windows
    /// terminate the process now that it has been recorded.
    private enum LONG exceptionExecuteHandler = 1;

    private void installNativeFilter() nothrow
    {
        try SetUnhandledExceptionFilter(&nativeCrashFilter);
        catch (Throwable) {}
    }

    /**
     * A structured exception is not a D exception, so there is no trace info:
     * log the code and faulting address instead. The address pairs with the
     * fault offsets Windows Error Reporting prints, which is what makes a
     * native fault attributable to a build.
     */
    private extern (Windows) LONG nativeCrashFilter(EXCEPTION_POINTERS* info)
    {
        try
        {
            auto record = info !is null ? info.ExceptionRecord : null;
            if (record is null)
                logError("native crash: exception pointers unavailable");
            else
                logError("native crash: code 0x" ~
                    toHex(record.ExceptionCode) ~ " at " ~
                    toHex(cast(size_t) record.ExceptionAddress));
        }
        catch (Throwable) {}
        return exceptionExecuteHandler;
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

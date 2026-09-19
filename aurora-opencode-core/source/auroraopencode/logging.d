module auroraopencode.logging;

import core.stdc.stdio : fclose, fflush, fopen, fwrite;
import core.sync.mutex : Mutex;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.path : buildPath;

// ---------------------------------------------------------------------------
// Minimal thread-safe file logger. The app points it at its state directory
// (plus a "logs" subfolder) once at startup; every entry is appended to
// errors.log with a timestamp, and each launch writes a banner line so the
// most recent session is easy to find.
// ---------------------------------------------------------------------------

private __gshared Mutex _logMutex;
private __gshared string _logsDir;
private __gshared bool _ready;

static this()
{
    _logMutex = new Mutex();
    _ready = true;
}

/// The app sets this once at startup, normally to `<stateDir>/logs`.
public void setLogDirectory(string directory)
{
    _logsDir = directory;
    rotateOversizedLog();
}

private enum ulong maxLogBytes = 8UL * 1024 * 1024;

/// Keep diagnostic logging bounded. A paint storm once grew errors.log past
/// 160 MB; retain one previous file for crash forensics, then start clean.
private void rotateOversizedLog()
{
    if (_logsDir.length == 0) return;
    try
    {
        const current = logFilePath();
        if (!exists(current) || getSize(current) <= maxLogBytes) return;
        const previous = buildPath(_logsDir, "errors.previous.log");
        if (exists(previous)) remove(previous);
        rename(current, previous);
    }
    catch (Throwable) {}
}

public string logDirectory()
{
    return _logsDir;
}

public void logError(string message)
{
    writeLine("ERROR", message);
}

public void logInfo(string message)
{
    writeLine("INFO", message);
}

/// Writes a banner so each launch has an easy-to-spot section in the log.
public void logLaunch(string appName)
{
    writeLine("LAUNCH", "========== " ~ appName ~ " started ==========");
}

private void writeLine(string level, string message)
{
    if (!_ready) return;
    _logMutex.lock();
    scope (exit) _logMutex.unlock();
    if (_logsDir.length == 0) return;
    // Each entry is appended and flushed before the handle closes. The point
    // of this file is to outlive a crash, so the write must not be left in a
    // buffer: the entry written just before a crash is the one that says what
    // the process was doing when it died.
    try
    {
        try mkdirRecurse(_logsDir);
        catch (Exception) {}
        auto file = fopen((logFilePath() ~ "\0").ptr, "ab");
        if (file is null) return;
        scope (exit) fclose(file);
        const line = timestamp() ~ " [" ~ level ~ "] " ~ message ~ "\n";
        fwrite(line.ptr, 1, line.length, file);
        fflush(file);
    }
    catch (Throwable) {}
}

/// The file every entry is appended to.
private string logFilePath()
{
    return buildPath(_logsDir, "errors.log");
}

private string timestamp()
{
    auto now = Clock.currTime;
    string pad2(int value)
    {
        return value < 10 ? "0" ~ to!string(value) : to!string(value);
    }
    return to!string(now.year) ~ "-" ~ pad2(cast(int) now.month) ~
        "-" ~ pad2(now.day) ~ " " ~ pad2(now.hour) ~ ":" ~
        pad2(now.minute) ~ ":" ~ pad2(now.second);
}

module auroraopencode.logging;

import core.sync.mutex : Mutex;
import std.conv : to;
import std.datetime : Clock;
import std.file : append, mkdirRecurse;
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
    try
    {
        try mkdirRecurse(_logsDir);
        catch (Exception) {}
        auto now = Clock.currTime;
        string pad2(int value)
        {
            return value < 10 ? "0" ~ to!string(value) : to!string(value);
        }
        const stamp = to!string(now.year) ~ "-" ~ pad2(cast(int) now.month) ~
            "-" ~ pad2(now.day) ~ " " ~ pad2(now.hour) ~ ":" ~
            pad2(now.minute) ~ ":" ~ pad2(now.second);
        append(buildPath(_logsDir, "errors.log"),
            stamp ~ " [" ~ level ~ "] " ~ message ~ "\n");
    }
    catch (Exception) {}
}

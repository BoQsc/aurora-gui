/**
 * Minimal file logger. Written to a plain text file so a run can be inspected
 * after the fact (the GUI executable has no console). Logging failures are
 * swallowed: logging must never break the app.
 */
module auroraiso.logging;

import std.datetime : Clock;
import std.format : format;
import std.stdio : File;

// Module globals are thread-local by default; logging state must be shared so
// the install job (worker thread) and the UI thread write to the same log.
private __gshared string _path;
private __gshared bool _ready;
private __gshared Object _mutex;

private Object logMutex()
{
    if (_mutex is null)
        _mutex = new Object;
    return _mutex;
}

/// Open (append) the log at `path`. Returns true when logging is active.
bool logInit(string path)
{
    synchronized (logMutex())
    {
        try
        {
            _path = path;
            _ready = true;
            // Verify the file is writable now, but keep per-line handles only.
            auto probe = File(path, "a");
            probe.close();
            return true;
        }
        catch (Exception)
        {
            _ready = false;
            return false;
        }
    }
}

string logPath() { return _path; }
bool loggingEnabled() { return _ready; }

void logInfo(string message) { writeLine("INFO", message); }
void logWarn(string message) { writeLine("WARN", message); }
void logError(string message) { writeLine("ERROR", message); }

private void writeLine(string level, string message)
{
    // The install job logs from a worker thread while the UI thread also logs.
    // A single shared File handle is not safe across threads (writes can throw
    // and be swallowed), so append with a fresh handle per line, serialized.
    synchronized (logMutex())
    {
        if (!_ready)
            return;
        try
        {
            auto file = File(_path, "a");
            file.writefln("%s [%s] %s", Clock.currTime().toString(), level, message);
            file.flush();
        }
        catch (Exception)
        {
        }
    }
}

module auroraopencode.logging;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.path : buildPath;
import std.stdio : File;

// Ordinary diagnostics never perform disk I/O on a paint/layout path.
// One bounded queue batches them; errors retain a synchronous crash path.
private __gshared Mutex _queueMutex, _fileMutex;
private __gshared Condition _wake, _flushed;
private __gshared Thread _writer;
private __gshared string _logsDir;
private __gshared string[] _pending;
private __gshared size_t _pendingBytes;
private __gshared ulong _queuedSequence, _writtenSequence, _dropped;
private __gshared bool _stopping;
private enum size_t maxQueueBytes = 512 * 1024;
private enum ulong maxLogBytes = 8UL * 1024 * 1024;

shared static this()
{
    _queueMutex = new Mutex();
    _fileMutex = new Mutex();
    _wake = new Condition(_queueMutex);
    _flushed = new Condition(_queueMutex);
}

shared static ~this()
{
    flushLogs();
    _queueMutex.lock();
    _stopping = true;
    _wake.notifyAll();
    auto worker = _writer;
    _queueMutex.unlock();
    if (worker !is null) worker.join();
}

public void setLogDirectory(string directory)
{
    flushLogs();
    synchronized (_queueMutex)
    {
        _logsDir = directory;
        if (_writer is null && directory.length > 0)
        {
            _writer = new Thread(&writeLoop);
            _writer.isDaemon = true;
            try _writer.start();
            catch (Exception) { _writer = null; }
        }
    }
}

public string logDirectory()
{
    synchronized (_queueMutex) return _logsDir;
}

public void logInfo(string message) { enqueue("INFO", message); }
public void logLaunch(string appName)
{
    enqueue("LAUNCH", "========== " ~ appName ~ " started ==========");
}

public void logError(string message)
{
    // Native exception reporting must not depend on the writer being alive.
    const directory = logDirectory();
    if (directory.length) writeBatch(directory, [formatLine("ERROR", message)]);
}

/// Explicit barrier for orderly shutdown and changing log targets.
public bool flushLogs(int timeoutMs = 1000)
{
    const due = MonoTime.currTime + timeoutMs.msecs;
    _queueMutex.lock();
    scope (exit) _queueMutex.unlock();
    const target = _queuedSequence;
    _wake.notifyAll();
    while (_writtenSequence < target && _writer !is null)
    {
        if (MonoTime.currTime >= due) return false;
        _flushed.wait(10.msecs);
    }
    return _writtenSequence >= target;
}

public size_t queuedLogBytes()
{
    synchronized (_queueMutex) return _pendingBytes;
}

private void enqueue(string level, string message)
{
    auto line = formatLine(level, message);
    synchronized (_queueMutex)
    {
        if (_logsDir.length == 0 || _writer is null || _stopping) return;
        if (line.length > maxQueueBytes || _pendingBytes + line.length > maxQueueBytes)
        {
            ++_dropped;
            return;
        }
        _pending ~= line;
        _pendingBytes += line.length;
        ++_queuedSequence;
        _wake.notify();
    }
}

private void writeLoop()
{
    while (true)
    {
        _queueMutex.lock();
        while (!_pending.length && !_stopping) _wake.wait();
        if (_stopping && !_pending.length) { _queueMutex.unlock(); return; }
        auto batch = _pending;
        const directory = _logsDir;
        const sequence = _queuedSequence;
        const dropped = _dropped;
        _pending = null;
        _pendingBytes = 0;
        _dropped = 0;
        _queueMutex.unlock();
        if (dropped) batch ~= formatLine("INFO", "diagnostic buffer dropped " ~ to!string(dropped) ~ " entries");
        writeBatch(directory, batch);
        _queueMutex.lock();
        _writtenSequence = sequence;
        _flushed.notifyAll();
        _queueMutex.unlock();
    }
}

private void writeBatch(string directory, string[] lines)
{
    synchronized (_fileMutex)
    {
        try
        {
            mkdirRecurse(directory);
            const current = buildPath(directory, "errors.log");
            if (exists(current) && getSize(current) >= maxLogBytes)
            {
                const previous = buildPath(directory, "errors.previous.log");
                if (exists(previous)) remove(previous);
                rename(current, previous);
            }
            auto file = File(current, "a");
            foreach (line; lines) file.write(line);
            file.flush();
        }
        catch (Throwable) {} // Logging must not replace the original failure.
    }
}

private string formatLine(string level, string message)
{
    return Clock.currTime.toISOExtString() ~ " [" ~ level ~ "] " ~ message ~ "\n";
}

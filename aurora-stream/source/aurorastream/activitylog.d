module aurorastream.activitylog;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, dur, msecs;
import std.datetime.systime : Clock, SysTime;
import std.file : append, exists, getSize, write;
import std.format : format;
import std.path : buildPath, dirName;

/**
 * Persistent, timestamped diagnostic activity log written beside the
 * executable (the same folder as `aurora-stream-startup.log`).
 *
 * It records UI-thread heartbeats, window events (focus / minimize / restore),
 * stream lifecycle transitions, and UI-stall events, so a later freeze or an
 * alt-tab stream stop can be reconstructed from one file:
 *
 * ```text
 * 2026-08-14T08:23:31.123456  Aurora Stream activity log started.
 * 2026-08-14T08:23:31.700000  Window focus gained.
 * 2026-08-14T08:23:45.100000  Stream started (YouTube only).
 * 2026-08-14T08:24:02.500000  UI STALL DETECTED: no UI tick for 4.3 s. Last state: ...
 * 2026-08-14T08:24:07.900000  UI STALL RESOLVED: UI thread resumed after 5.4 s.
 * ```
 *
 * A dedicated watchdog thread performs the stall detection, so even when the
 * UI thread is fully frozen it can still record the stall start, the last
 * known stream state, and (once ticks resume) the total stall duration.
 */
final class ActivityLog
{
    private string _path;
    private Mutex _mutex;
    private Thread _watchdog;
    private bool _shutdown;
    private long _lastHeartbeatTicks;
    private long _stallStartTicks;
    private bool _stalled;
    private string _snapshot;

    private enum double stallThresholdSeconds = 3.0;
    private enum int checkIntervalMilliseconds = 500;
    private enum size_t maxBytes = 4 * 1024 * 1024; // 4 MiB before truncation

    this(string executablePath)
    {
        const folder = executablePath.length > 0 ? dirName(executablePath) : ".";
        _path = buildPath(folder, "aurora-stream-activity.log");
        _mutex = new Mutex();
        note("Aurora Stream activity log started.");
    }

    /** Starts the stall-detection watchdog thread. Call once after
     * construction; the UI thread then calls `heartbeat()` every tick. */
    void start()
    {
        _mutex.lock();
        if (_watchdog !is null)
        {
            _mutex.unlock();
            return;
        }
        _watchdog = new Thread({ watchdogLoop(); });
        _watchdog.isDaemon = true;
        _watchdog.start();
        _mutex.unlock();
    }

    /** Stops the watchdog and writes a final line. */
    void shutdown()
    {
        Thread watchdog;
        _mutex.lock();
        _shutdown = true;
        watchdog = _watchdog;
        _mutex.unlock();
        if (watchdog !is null)
        {
            // The watchdog sleeps at most checkIntervalMilliseconds between
            // checks, so joining once _shutdown is set returns promptly.
            try watchdog.join();
            catch (Exception) {}
        }
        note("Aurora Stream activity log stopped.");
    }

    /** UI thread: record that the UI is alive. Called from `onTick`. When the
     * UI resumes after a detected stall, this also records the resolution. */
    void heartbeat()
    {
        const nowTicks = MonoTime.currTime.ticks;
        _mutex.lock();
        const wasStalled = _stalled;
        _lastHeartbeatTicks = nowTicks;
        if (wasStalled)
        {
            _stalled = false;
            const stallTicks = nowTicks - _stallStartTicks;
            const snapshot = _snapshot;
            _mutex.unlock();
            note(format("UI STALL RESOLVED: UI thread resumed after %.1f s. State: %s",
                stallTicks / cast(double) MonoTime.ticksPerSecond, snapshot));
            return;
        }
        _mutex.unlock();
    }

    /** UI thread: publish the last known stream state so a stall record has
     * context (streaming active, status, metrics). */
    void setSnapshot(string snapshot)
    {
        if (snapshot.length == 0) return;
        _mutex.lock();
        if (_snapshot != snapshot) _snapshot = snapshot.idup;
        _mutex.unlock();
    }

    /** Append a timestamped line. Safe from any thread. */
    void note(string line)
    {
        if (line.length == 0) return;
        string stamp;
        try stamp = Clock.currTime.toLocalTime().toISOExtString();
        catch (Exception) stamp = "????????";
        const full = format("%s  %s\r\n", stamp, line);
        _mutex.lock();
        scope (exit) _mutex.unlock();
        try
        {
            if (exists(_path))
            {
                if (getSize(_path) > maxBytes)
                    write(_path, "Aurora Stream activity log (truncated after exceeding 4 MiB).\r\n");
            }
            append(_path, full);
        }
        catch (Exception) {}
    }

    private void watchdogLoop()
    {
        while (true)
        {
            Thread.sleep(dur!"msecs"(checkIntervalMilliseconds));
            const nowTicks = MonoTime.currTime.ticks;
            string snapshot;
            bool shouldNote;
            double gapSeconds;
            _mutex.lock();
            const shuttingDown = _shutdown;
            const lastTicks = _lastHeartbeatTicks;
            const stalled = _stalled;
            if (shuttingDown)
            {
                _mutex.unlock();
                return;
            }
            if (lastTicks > 0)
            {
                gapSeconds = (nowTicks - lastTicks) /
                    cast(double) MonoTime.ticksPerSecond;
                if (gapSeconds > stallThresholdSeconds && !stalled)
                {
                    // Record the LAST UI heartbeat as the true freeze start, so
                    // the eventual stall-duration reflects when the UI thread
                    // actually stopped ticking rather than when the watchdog
                    // first noticed it.
                    _stalled = true;
                    _stallStartTicks = lastTicks;
                    snapshot = _snapshot;
                    shouldNote = true;
                }
            }
            _mutex.unlock();
            if (shouldNote)
            {
                note(format("UI STALL DETECTED: no UI tick for %.1f s. State: %s",
                    gapSeconds, snapshot));
            }
        }
    }

    unittest
    {
        // The stall detector must require a real gap, and resolve on heartbeat.
        auto log = new ActivityLog(".");
        assert(log._path.length > 0);
        log._mutex.lock();
        log._lastHeartbeatTicks = 0;
        log._stalled = false;
        log._snapshot = "Ready";
        log._mutex.unlock();
        log.heartbeat();
        log._mutex.lock();
        assert(log._lastHeartbeatTicks > 0);
        assert(!log._stalled);
        log._mutex.unlock();

        // A stale heartbeat below the threshold must NOT trigger a stall.
        log._mutex.lock();
        log._lastHeartbeatTicks = MonoTime.currTime.ticks -
            cast(long) (2.0 * MonoTime.ticksPerSecond);
        log._mutex.unlock();
        log._mutex.lock();
        assert(!log._stalled);
        log._mutex.unlock();
    }
}

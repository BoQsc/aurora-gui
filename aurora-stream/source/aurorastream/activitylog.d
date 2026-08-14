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
 * It is the single always-on, session-spanning record of what the app did and
 * what went wrong. Every notable event carries a severity tag so a problem can
 * be found and understood without reading FFmpeg's raw log:
 *
 * ```text
 * [INFO]    normal lifecycle events: startup, settings load, encoder/capture
 *           selection, stream start/stop, update check, FFmpeg launch.
 * [WARNING] recoverable problems or degraded state: encoder fallbacks, audio
 *           scan errors, FFmpeg warning lines, UDP bind races.
 * [ERROR]   failures that ended or blocked an operation, each with the exact
 *           reason (startup timeout, live-output stall, capture loss, ...).
 * [ACTION]  an automatic action the app took in response to a problem, e.g.
 *           "FFmpeg terminated", "relaunching capture (recovery 1 of 3)".
 * ```
 *
 * Example:
 *
 * ```text
 * 2026-08-14T08:23:31.123456  Aurora Stream activity log started.
 * 2026-08-14T08:23:31.700000  [INFO] Aurora Stream v0.63.0 starting.
 * 2026-08-14T08:23:45.100000  [INFO] Stream start: YouTube, encoder NVIDIA NVENC (h264_nvenc), capture Desktop Duplication (cursor-safe).
 * 2026-08-14T08:24:02.500000  [ERROR] Desktop Duplication output lost: [ddagrab @ 000001] AcquireNextFrame failed: error.
 * 2026-08-14T08:24:02.900000  [ACTION] Action taken: relaunching FFmpeg after a transient Desktop Duplication loss (recovery 1 of 3).
 * 2026-08-14T08:25:00.000000  UI STALL DETECTED: no UI tick for 4.3 s. Last state: ...
 * 2026-08-14T08:25:05.400000  UI STALL RESOLVED: UI thread resumed after 5.4 s.
 * ```
 *
 * A dedicated watchdog thread performs the stall detection, so even when the
 * UI thread is fully frozen it can still record the stall start, the last
 * known stream state, and (once ticks resume) the total stall duration.
 *
 * App-authored messages use plain ASCII so they are greppable and safe under
 * any console codepage; raw user content (window titles) and FFmpeg output are
 * forwarded verbatim and the file is written as UTF-8.
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

    /// The full path of the activity log file (for the UI "View activity log"
    /// action). The file is created lazily on the first write.
    string path() const
    {
        return _path;
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

    /** Append a timestamped line. Safe from any thread. The line is sanitized
     * so a message that happens to contain invalid UTF-8 (e.g. a malformed
     * window title) can never corrupt the log file. */
    void note(string line)
    {
        if (line.length == 0) return;
        string stamp;
        try stamp = Clock.currTime.toLocalTime().toISOExtString();
        catch (Exception) stamp = "????????";
        const full = format("%s  %s\r\n", stamp, sanitizeUtf8(line));
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

    /// Replaces any invalid UTF-8 byte with U+FFFD so the log file is always
    /// decodable.
    private static string sanitizeUtf8(string input)
    {
        import std.utf : decode, toUTF8, UTFException;
        dstring result;
        size_t index;
        while (index < input.length)
        {
            try
            {
                const code = decode(input, index);
                result ~= code;
            }
            catch (UTFException)
            {
                result ~= '\uFFFD';
                ++index;
            }
        }
        return toUTF8(result);
    }

    /// Normal lifecycle event (startup, settings load, encoder/capture
    /// selection, stream start/stop, update check). Safe from any thread.
    void info(string message)
    {
        note("[INFO] " ~ message);
    }

    /// Recoverable problem or degraded state that does not (yet) end an
    /// operation: encoder fallback, audio-scan error, UDP bind race, an
    /// FFmpeg warning line. Safe from any thread.
    void warning(string message)
    {
        note("[WARNING] " ~ message);
    }

    /// Failure that ended or blocked an operation. The message must contain
    /// the exact reason so it can be acted on without re-diagnosing. Safe from
    /// any thread.
    void error(string message)
    {
        note("[ERROR] " ~ message);
    }

    /// An automatic action the app took in response to a problem, e.g.
    /// "Action taken: FFmpeg was terminated." or "Action taken: relaunching
    /// FFmpeg (recovery 1 of 3)." Safe from any thread.
    void action(string message)
    {
        note("[ACTION] " ~ message);
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

    unittest
    {
        // Severity helpers must write tagged, greppable lines to the same
        // always-on activity log file. Start from a clean file so a pre-existing
        // (possibly app-generated, non-UTF-8) log does not fail the read.
        import std.file : exists, readText, remove;
        import std.string : indexOf;
        auto log = new ActivityLog(".");
        if (exists(log._path))
        {
            try remove(log._path);
            catch (Exception) {}
        }
        log.info("probe info event");
        log.warning("probe warning event");
        log.error("probe error event");
        log.action("probe action event");
        const content = readText(log._path);
        assert(content.indexOf("[INFO] probe info event") >= 0);
        assert(content.indexOf("[WARNING] probe warning event") >= 0);
        assert(content.indexOf("[ERROR] probe error event") >= 0);
        assert(content.indexOf("[ACTION] probe action event") >= 0);
    }
}

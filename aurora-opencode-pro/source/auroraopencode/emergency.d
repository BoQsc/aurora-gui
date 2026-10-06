module auroraopencode.emergency;

// ===========================================================================
// Emergency freeze detection + report, and the trigger the optional overseer
// shares.
//
// The UI is a single Win32 message loop: if the thread that runs it blocks (a
// long synchronous network read, a runaway rebuild, a lock held too long), the
// window stops painting and Windows marks it "Not Responding". Nothing inside
// that thread can report the stall, because the thread is the thing that is
// stuck. So the check runs somewhere else:
//
//   * the UI thread stamps a heartbeat every frame (`emergencyHeartbeat`) - a
//     single timestamp write, no allocation, so it is free at 60 fps;
//   * a daemon watchdog thread wakes about once a second and compares the
//     heartbeat against the clock; when the UI has not ticked for
//     `freezeSeconds` it records an emergency report;
//   * the report is appended to `logs/emergency.log` and written as its own
//     `logs/emergency-<time>.log`, naming the last `noteActivity` marker (the
//     same one the crash handler uses) and the last short UI context;
//   * a "pending" flag is raised so the UI thread, once it ticks again, can
//     start an autonomous diagnostic chat (the app decides whether to, based
//     on the Settings switch and a configured DeepSeek model).
//
// The watchdog only observes: it never touches widgets, the conversation store
// or the network, so it cannot itself freeze the UI. The cost of always-on
// detection is one timestamp write per frame plus one sleeping thread that
// wakes once a second.
//
// To drop the feature: delete this file, the `emergencyReport` /
// `overseerObserver` Settings, and the `emergency`/`overseer` hooks in
// appui.d; nothing else references it.
// ===========================================================================

import auroraopencode.crashguard : lastActivity;
import auroraopencode.logging : logError, logInfo;
import auroraopencode.core : opencodeStateDirectory;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.file : append, mkdirRecurse, write;
import std.path : buildPath;

/// UI ticks are expected within this many seconds; a longer gap is a freeze.
public enum double emergencyFreezeSeconds = 6.0;

/// How long the watchdog sleeps between samples. One wake per second while the
/// app is running is immeasurable next to a frame.
private enum int watchdogPollMs = 1_000;

/// Minimum spacing between two emergency triggers. A stalled UI or a stuck turn
/// stays stuck, so without this the same condition would re-fire forever and
/// start a new diagnostic chat every second.
public enum double emergencyRepeatCooldownSeconds = 120.0;

/// How long a single conversation may stay continuously busy before the
/// overseer calls it a runaway turn. Generous, so a genuinely long generation
/// is not mistaken for a hang.
public enum double overseerStallSeconds = 900.0;

/// True when freeze detection + emergency reports are enabled (Settings).
private __gshared bool _reportEnabled = true;

/// True when the optional overseer watches running conversations (Settings).
private __gshared bool _overseerOn = false;

/// hnsecs of the last UI heartbeat. A plain integral so the UI thread can write
/// it and the watchdog read it without tearing.
private __gshared long _lastBeatHnsecs;
/// The wall-clock time of that heartbeat, for reporting.
private __gshared SysTime _lastBeatTime;
private __gshared bool _haveBeat;

/// Last short description of what the UI is doing. Refreshed only when it
/// changes, so the per-frame heartbeat never allocates a string.
private __gshared string _context = "";

/// Injectable clock for tests; null uses `Clock.currTime`.
private __gshared SysTime function() _clock;

private __gshared bool _watchdogStarted;
private __gshared bool _freezeLogged;
/// The watchdog's own previous wake time. If the gap between two of its own
/// wakes is also long, the whole process was suspended (system sleep or
/// hibernate), not just the UI thread, and the heartbeats must not be read as a
/// freeze.
private __gshared bool _haveWake;
private __gshared SysTime _lastWake;
private __gshared bool _haveTrigger;
private __gshared SysTime _lastTriggerTime;
private __gshared bool _pending;
private __gshared string _pendingReason = "";
private __gshared string _lastReportPath = "";
private __gshared Mutex _mutex;

static this()
{
    _mutex = new Mutex();
}

/// The current wall clock, or the test clock when one is installed.
private SysTime nowTime()
{
    return _clock is null ? Clock.currTime : _clock();
}

public void setEmergencyReportEnabled(bool value)
{
    _reportEnabled = value;
    if (!value) _freezeLogged = false;
}

public bool emergencyReportEnabled()
{
    return _reportEnabled;
}

public void setOverseerEnabled(bool value)
{
    _overseerOn = value;
}

public bool overseerEnabled()
{
    return _overseerOn;
}

/// Start the watchdog once. Repeated calls are ignored; safe from any thread.
public void startEmergencyWatchdog()
{
    if (_watchdogStarted) return;
    _watchdogStarted = true;
    auto thread = new Thread(&watchdogMain);
    thread.isDaemon = true;
    thread.start();
}

/// UI thread: stamp the frame heartbeat. Must stay allocation-free.
public void emergencyHeartbeat()
{
    const now = nowTime();
    _lastBeatTime = now;
    _lastBeatHnsecs = now.stdTime;
    _haveBeat = true;
}

/// UI thread: publish a short description of the current activity. Stored only
/// when it actually changes, so repeated calls with the same text are free.
public void emergencySetContext(string context)
{
    if (context == _context) return;
    _context = context;
}

/// Record one emergency condition: log it, write the report, and raise the
/// pending flag the UI consumes to start a diagnostic chat. Cooldown-guarded,
/// so a condition that persists is reported once, not continuously.
public void emergencyTrigger(string reason)
{
    _mutex.lock();
    scope (exit) _mutex.unlock();
    const now = nowTime();
    if (_haveTrigger &&
        (now - _lastTriggerTime).total!"seconds" <
            emergencyRepeatCooldownSeconds)
    {
        logInfo("emergency: suppressed by cooldown — " ~ reason);
        return;
    }
    _lastTriggerTime = now;
    _haveTrigger = true;
    _pending = true;
    _pendingReason = reason;
    logError("emergency: " ~ reason);
    writeReport(reason, now);
}

/// UI thread: consume a pending emergency exactly once. False when none.
public bool emergencyTakePendingFreeze(out string reason)
{
    _mutex.lock();
    scope (exit) _mutex.unlock();
    if (!_pending) return false;
    _pending = false;
    reason = _pendingReason;
    _pendingReason = "";
    return true;
}

/// Path of the most recent per-incident report, or "" when none was written.
public string emergencyLastReportPath()
{
    _mutex.lock();
    scope (exit) _mutex.unlock();
    return _lastReportPath;
}

/// Write the per-incident report and append it to the rolling log. Best-effort:
/// a failure here must never take the watchdog down.
private void writeReport(string reason, SysTime now)
{
    try
    {
        const dir = buildPath(opencodeStateDirectory(), "logs");
        mkdirRecurse(dir);
        auto text = "Aurora OpenCode emergency report\n";
        text ~= "time: " ~ now.toISOString() ~ "\n";
        text ~= "reason: " ~ reason ~ "\n";
        text ~= "ui context: " ~ _context ~ "\n";
        text ~= "last activity: " ~ lastActivity() ~ "\n";
        text ~= "log: " ~ buildPath(dir, "errors.log") ~ "\n";
        const path = buildPath(dir,
            "emergency-" ~ to!string(now.toUnixTime()) ~ ".log");
        write(path, text);
        append(buildPath(dir, "emergency.log"), text);
        _lastReportPath = path;
        logInfo("emergency report written: " ~ path);
    }
    catch (Throwable error)
    {
        try logError("emergency: could not write report: " ~ error.toString());
        catch (Throwable) {}
    }
}

/// The watchdog loop. Observation only; it never throws out of the thread.
private void watchdogMain()
{
    while (true)
    {
        try Thread.sleep(watchdogPollMs.msecs);
        catch (Throwable) {}
        try
        {
            if (!_reportEnabled || !_haveBeat)
            {
                _freezeLogged = false;
                continue;
            }
            const now = nowTime();
            // A gap between our own wakes that already exceeds the freeze
            // threshold cannot be a UI-thread hang: a hung UI still leaves this
            // loop waking every second. It means the process (and this thread)
            // was suspended - system sleep or hibernate - so the stale heartbeat
            // is expected. Re-baseline and do not report a freeze.
            if (_haveWake &&
                (now - _lastWake).total!"seconds" > emergencyFreezeSeconds)
            {
                _lastWake = now;
                _lastBeatTime = now;
                _haveBeat = true;
                _freezeLogged = false;
                continue;
            }
            _lastWake = now;
            _haveWake = true;
            const stalled = (now - _lastBeatTime).total!"seconds";
            if (stalled >= emergencyFreezeSeconds)
            {
                if (!_freezeLogged)
                {
                    _freezeLogged = true;
                    emergencyTrigger("UI froze for " ~ to!string(stalled) ~
                        " s (last tick " ~ _lastBeatTime.toISOString() ~
                        "); last activity: " ~ lastActivity());
                }
            }
            else
                _freezeLogged = false;
        }
        catch (Throwable) {}
    }
}

version (unittest)
{
    /// Test-only: install a fake clock.
    void setEmergencyClockForTesting(SysTime function() clock)
    {
        _clock = clock;
    }

    /// Test-only: reset the module to a known state.
    void resetEmergencyForTesting()
    {
        _haveBeat = false;
        _freezeLogged = false;
        _haveTrigger = false;
        _pending = false;
        _pendingReason = "";
        _context = "";
        _reportEnabled = true;
        _overseerOn = false;
        _lastReportPath = "";
    }
}

unittest
{
    // A heartbeat is consumed on the next trigger, and taking it clears it.
    resetEmergencyForTesting();
    emergencyHeartbeat();
    string reason;
    assert(!emergencyTakePendingFreeze(reason));
    assert(emergencyReportEnabled());
    assert(!overseerEnabled());
    setOverseerEnabled(true);
    assert(overseerEnabled());
    setOverseerEnabled(false);
}

module auroraweb.eventloop;

/**
 * Aurora Web event loop — the cross-platform scheduler that powers the browser.
 *
 * The HTML standard's *event loop* is the heartbeat of a browser: it decides
 * **when** everything else happens. Script execution, `setTimeout`/`setInterval`,
 * Promise microtasks, `requestAnimationFrame`, input dispatch, network
 * completion and the render step all funnel through one loop, and the subtle
 * ordering between them (a microtask checkpoint after every task, animation
 * callbacks before style/layout/paint, timer clamping to stop tight loops) is
 * exactly what makes a browser feel like a browser.
 *
 * Nothing in this module touches an OS API. The host — an Aurora window, a
 * headless test harness, a future server process — owns the thread and pumps
 * the loop, feeding it a monotonic clock. That is what makes the same code
 * drive Windows, X11, macOS and `dub test` without a single `version` branch.
 *
 * Typical host usage:
 * ---
 * auto loop = new EventLoop();
 * // ... script calls setTimeout()/requestAnimationFrame() ...
 * loop.setNow(monotonicNowMs);      // feed real time each tick
 * loop.runUntilIdle();              // run tasks + due timers + microtasks
 * if (loop.framePending())
 *     loop.runFrame(monotonicNowMs); // rAF + render callbacks, then repaint
 * ---
 */

import std.math : isNaN;

/**
 * The spec's *task source*. Each kind of work lives on its own queue so a flood
 * of one kind (say, parser tasks) cannot starve another (say, user input). The
 * loop picks whichever non-empty queue has the highest priority.
 */
enum TaskSource
{
    /// Pointer/keyboard input; drained first so the UI stays responsive.
    userInteraction,
    /// postMessage / MessageChannel-style cross-context tasks.
    postedMessage,
    /// setTimeout / setInterval callbacks.
    timer,
    /// fetch/XHR completion and other network callbacks.
    networking,
    /// HTML parser and script-execution tasks.
    scripting,
    /// MutationObserver / batched DOM bookkeeping.
    domManipulation,
    /// Navigation and history-traversal work.
    navigation,
}

/// Priority order (highest first) used when more than one queue is non-empty.
/// Mirrors the "task priority" ordering a browser needs to keep input snappy.
private immutable TaskSource[] priorityOrder = [
    TaskSource.userInteraction,
    TaskSource.postedMessage,
    TaskSource.timer,
    TaskSource.networking,
    TaskSource.scripting,
    TaskSource.domManipulation,
    TaskSource.navigation,
];

/**
 * A single-threaded, host-pumped event loop. Create one per document.
 */
final class EventLoop
{
    // --- task queues ---------------------------------------------------------

    private struct Task
    {
        void delegate() run;
        long sequence;      /// global FIFO order, ties broken within a source
    }

    private Task[][] _queues;          /// one FIFO per `TaskSource`, indexed by value
    private long _nextSequence = 1;

    // --- microtasks ----------------------------------------------------------

    private void delegate()[] _microtasks;
    private bool _performingCheckpoint;

    // --- timers --------------------------------------------------------------

    private struct TimerEntry
    {
        long id;
        double dueAt = 0.0;    /// absolute ms on the loop clock
        double interval = 0.0; /// > 0 when repeating
        bool repeating;
        long nesting;          /// HTML "timer nesting level" carried by the task
        void delegate() callback;
        long sequence;
        bool cancelled;
    }

    private TimerEntry[] _timers;
    private long _nextTimerId = 1;
    /// Nesting level of the timer task currently running (0 outside any timer).
    /// A new timer scheduled from inside a timer callback inherits this and
    /// carries level+1, so a self-rescheduling zero-delay timer eventually gets
    /// clamped to 4 ms instead of spinning forever.
    private long _runningTimerNesting;

    // --- animation frames ----------------------------------------------------

    private struct FrameRequest
    {
        long id;
        void delegate(double timestamp) callback;
        bool cancelled;
    }

    private FrameRequest[] _frameRequests;
    private long _nextFrameId = 1;
    private bool _framePending;

    // --- rendering -----------------------------------------------------------

    private void delegate(double timestamp)[] _renderCallbacks;

    // --- clock ---------------------------------------------------------------

    // Explicitly 0.0: in D a bare floating-point field initializes to NaN, and
    // a NaN clock would make every timer "always due".
    private double _nowMs = 0.0;

    /// Safety valves so a buggy page cannot hang the host thread.
    size_t maxIdleTasks = 1_000_000;    /// per `runUntilIdle` call
    size_t maxTimerRuns = 1_000_000;    /// per `runExpiredTimers` call

    this() {}

    /// Construct with a starting clock value (ms), e.g. the host's uptime.
    this(double startMs)
    {
        setNow(startMs);
    }

    // ------------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------------

    /// The current loop time in milliseconds (monotonic; never moves backward).
    double now() const
    {
        return _nowMs;
    }

    /// Set the loop clock (a host feeding real monotonic time each tick). NaN is
    /// ignored; the clock never moves backward.
    void setNow(double ms)
    {
        if (isNaN(ms)) return;
        if (ms > _nowMs) _nowMs = ms;
    }

    /// Advance the loop clock by `ms` (ignored when non-positive or NaN).
    void advance(double ms)
    {
        if (isNaN(ms) || ms <= 0.0) return;
        _nowMs += ms;
    }

    // ------------------------------------------------------------------------
    // Task queues
    // ------------------------------------------------------------------------

    /// Queue `run` on `source`. There is no cancellation for arbitrary tasks —
    /// only timers and animation frames are cancellable, matching the platform.
    void queueTask(TaskSource source, void delegate() run)
    {
        auto idx = cast(size_t) source;
        if (idx >= _queues.length) _queues.length = idx + 1;
        _queues[idx] ~= Task(run, _nextSequence++);
    }

    /// Run one queued task (highest-priority source first, FIFO within a
    /// source), then a microtask checkpoint. Returns true if a task ran.
    bool runOneTask()
    {
        // 1) Queued tasks, by source priority.
        foreach (source; priorityOrder)
        {
            auto idx = cast(size_t) source;
            if (idx < _queues.length && _queues[idx].length)
            {
                auto task = _queues[idx][0];
                _queues[idx] = _queues[idx][1 .. $];
                runTask(task);
                return true;
            }
        }
        // 2) Any queue not named in the priority list (future sources).
        foreach (i, ref q; _queues)
        {
            if (q.length)
            {
                auto task = q[0];
                q = q[1 .. $];
                runTask(task);
                return true;
            }
        }
        // 3) A due timer.
        return runExpiredTimers() > 0;
    }

    private void runTask(Task task)
    {
        if (task.run !is null) task.run();
        performMicrotaskCheckpoint();
    }

    /// Run queued tasks and due timers until nothing is immediately runnable.
    /// Does not advance the clock, so timers whose due time is still in the
    /// future wait for `advanceToNextTimer` or the host's next `setNow`. Returns
    /// the number of tasks/timers that ran. Bounded by `maxIdleTasks` so a
    /// self-requeueing task cannot hang the host.
    size_t runUntilIdle()
    {
        size_t count = 0;
        while (count < maxIdleTasks && runOneTask()) count++;
        return count;
    }

    // ------------------------------------------------------------------------
    // Microtasks
    // ------------------------------------------------------------------------

    /// Queue a microtask. Microtasks run at every checkpoint: after each task,
    /// after script, and between animation-frame callbacks.
    void queueMicrotask(void delegate() run)
    {
        if (run is null) return;
        _microtasks ~= run;
    }

    size_t microtaskCount() const
    {
        return _microtasks.length;
    }

    /// Perform a microtask checkpoint: drain the queue to empty, including
    /// microtasks queued by other microtasks. Re-entrant calls are ignored (the
    /// outer checkpoint will pick up anything they add).
    void performMicrotaskCheckpoint()
    {
        if (_performingCheckpoint) return;
        _performingCheckpoint = true;
        scope(exit) _performingCheckpoint = false;
        while (_microtasks.length)
        {
            auto batch = _microtasks;
            _microtasks = null;
            foreach (t; batch)
            {
                if (t is null) continue;
                t();
            }
        }
    }

    // ------------------------------------------------------------------------
    // Timers
    // ------------------------------------------------------------------------

    /// Run `callback` once after `delayMs`. Returns a timer id for `clearTimeout`.
    long setTimeout(void delegate() callback, double delayMs = 0.0)
    {
        return installTimer(callback, delayMs, false);
    }

    /// Run `callback` repeatedly every `delayMs`. Returns an id for `clearInterval`.
    long setInterval(void delegate() callback, double delayMs)
    {
        return installTimer(callback, delayMs, true);
    }

    /// Cancel a timer created by `setTimeout` or `setInterval`.
    bool clearTimeout(long id)
    {
        return cancelTimer(id);
    }

    /// Alias of `clearTimeout` (both cancel either kind of timer, as on the web).
    bool clearInterval(long id)
    {
        return cancelTimer(id);
    }

    private long installTimer(void delegate() callback, double delayMs, bool repeating)
    {
        auto id = _nextTimerId++;
        // HTML timer nesting: a timer scheduled from inside a timer callback
        // carries level+1, and once that exceeds 5 its delay is raised to >= 4 ms.
        auto incoming = _runningTimerNesting;
        double delay = normalizeDelay(delayMs, incoming);

        TimerEntry t;
        t.id = id;
        t.dueAt = _nowMs + delay;
        t.nesting = incoming + 1;
        t.repeating = repeating;
        if (repeating)
        {
            // A zero-interval repeat must not spin the host; floor it at 1 ms.
            t.interval = normalizeDelay(delayMs, incoming);
            if (t.interval < 1.0) t.interval = 1.0;
        }
        t.callback = callback;
        t.sequence = _nextSequence++;
        _timers ~= t;
        return id;
    }

    /// Clamp a delay: negative/NaN -> 0, truncated to whole ms, and raised to the
    /// 4 ms minimum once timers nest past level 5.
    private double normalizeDelay(double delayMs, long nesting)
    {
        if (isNaN(delayMs) || delayMs < 0.0) delayMs = 0.0;
        long d = cast(long) delayMs;   // truncate toward zero, like the spec
        if (nesting > 5 && d < 4) return 4.0;
        return cast(double) d;
    }

    private bool cancelTimer(long id)
    {
        foreach (ref t; _timers)
        {
            if (t.id == id && !t.cancelled)
            {
                t.cancelled = true;
                return true;
            }
        }
        return false;
    }

    /// The earliest due time among live timers, or `double.infinity` if none.
    double nextTimerDue() const
    {
        double best = double.infinity;
        foreach (t; _timers)
            if (!t.cancelled && t.dueAt < best) best = t.dueAt;
        return best;
    }

    /// Number of live (non-cancelled) timers.
    size_t timerCount() const
    {
        size_t n = 0;
        foreach (t; _timers)
            if (!t.cancelled) n++;
        return n;
    }

    /// Run every timer whose due time is <= the loop clock, earliest first
    /// (ties by insertion order). Each timer runs as its own task followed by a
    /// microtask checkpoint. Returns the number of timers that ran.
    size_t runExpiredTimers()
    {
        size_t ran = 0;
        while (ran < maxTimerRuns)
        {
            auto idx = earliestDueIndex();
            if (idx < 0) break;
            auto entry = _timers[cast(size_t) idx];
            // Reschedule/remove BEFORE running so the callback's own timer edits
            // cannot invalidate the array we are about to touch.
            if (entry.repeating)
                _timers[cast(size_t) idx].dueAt = entry.dueAt + entry.interval;
            else
                _timers = _timers[0 .. cast(size_t) idx] ~ _timers[cast(size_t) idx + 1 .. $];
            runTimerCallback(entry);
            performMicrotaskCheckpoint();
            ran++;
        }
        return ran;
    }

    private long earliestDueIndex() const
    {
        long best = -1;
        foreach (i, const ref t; _timers)
        {
            if (t.cancelled || t.dueAt > _nowMs) continue;
            if (best < 0)
            {
                best = cast(long) i;
                continue;
            }
            const ref b = _timers[cast(size_t) best];
            if (t.dueAt < b.dueAt || (t.dueAt == b.dueAt && t.sequence < b.sequence))
                best = cast(long) i;
        }
        return best;
    }

    private void runTimerCallback(TimerEntry entry)
    {
        auto saved = _runningTimerNesting;
        _runningTimerNesting = entry.nesting;
        scope(exit) _runningTimerNesting = saved;
        if (entry.callback !is null) entry.callback();
    }

    /// Advance the clock to the next pending timer's due time and run it (and
    /// every other timer now due), plus microtask checkpoints. Returns true if
    /// any timer ran. Intended for headless/test driving of a synthetic clock.
    bool advanceToNextTimer()
    {
        auto due = nextTimerDue();
        if (due == double.infinity) return false;
        if (due > _nowMs) _nowMs = due;
        return runExpiredTimers() > 0;
    }

    /// Repeatedly drain runnable work and jump to the next timer until no timers
    /// remain. Bounded by `maxIdleTasks`, so an endless `setInterval` stops and
    /// returns rather than hanging. Handy for tests that want timers to settle.
    size_t runAllTimers()
    {
        size_t rounds = 0;
        while (nextTimerDue() != double.infinity && rounds < maxIdleTasks)
        {
            runUntilIdle();
            if (!advanceToNextTimer()) break;
            rounds++;
        }
        return rounds;
    }

    // ------------------------------------------------------------------------
    // Animation frames & rendering
    // ------------------------------------------------------------------------

    /// Request an animation-frame callback. Callbacks run at the start of the
    /// next render opportunity (inside `runFrame`) with the frame timestamp.
    long requestAnimationFrame(void delegate(double timestamp) callback)
    {
        auto id = _nextFrameId++;
        _frameRequests ~= FrameRequest(id, callback, false);
        _framePending = true;
        return id;
    }

    /// Cancel a pending animation-frame callback.
    bool cancelAnimationFrame(long id)
    {
        foreach (ref r; _frameRequests)
        {
            if (r.id == id && !r.cancelled)
            {
                r.cancelled = true;
                return true;
            }
        }
        return false;
    }

    /// Register a render callback invoked once per frame, after all animation
    /// callbacks. The browser uses this to run its style/layout/paint pipeline.
    void addRenderCallback(void delegate(double timestamp) callback)
    {
        if (callback !is null) _renderCallbacks ~= callback;
    }

    /// Remove a previously registered render callback (matched by identity).
    void removeRenderCallback(void delegate(double timestamp) callback)
    {
        foreach (i, c; _renderCallbacks)
        {
            if (c is callback)
            {
                _renderCallbacks = _renderCallbacks[0 .. i] ~ _renderCallbacks[i + 1 .. $];
                return;
            }
        }
    }

    /// Whether a render opportunity is pending (a queued animation callback).
    bool framePending() const
    {
        if (_framePending) return true;
        foreach (r; _frameRequests)
            if (!r.cancelled) return true;
        return false;
    }

    /// Whether any work — task, microtask, timer or animation frame — is
    /// pending. The host uses this to decide whether to keep the loop warm.
    bool hasPendingWork() const
    {
        if (_microtasks.length) return true;
        if (_timerCountLive()) return true;
        foreach (r; _frameRequests)
            if (!r.cancelled) return true;
        foreach (q; _queues)
            if (q.length) return true;
        return false;
    }

    private bool _timerCountLive() const
    {
        foreach (t; _timers)
            if (!t.cancelled) return true;
        return false;
    }

    /// "Update the rendering": run every queued animation-frame callback with
    /// `timestamp`, then every render callback. Callbacks that request another
    /// frame are deferred to the following frame (matching the platform). A
    /// microtask checkpoint runs after each animation callback. Returns true if
    /// anything ran.
    bool runFrame(double timestamp)
    {
        bool ranAny = false;
        _framePending = false;
        auto frames = _frameRequests;
        _frameRequests = null;
        foreach (r; frames)
        {
            if (r.cancelled || r.callback is null) continue;
            r.callback(timestamp);
            ranAny = true;
            performMicrotaskCheckpoint();
        }
        foreach (cb; _renderCallbacks)
        {
            if (cb is null) continue;
            cb(timestamp);
            ranAny = true;
        }
        return ranAny;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.conv : to;
}

unittest
{
    // Task sources run in priority order; each source is FIFO.
    auto loop = new EventLoop();
    string log;
    loop.queueTask(TaskSource.timer, () { log ~= "t1"; });
    loop.queueTask(TaskSource.userInteraction, () { log ~= "u1"; });
    loop.queueTask(TaskSource.timer, () { log ~= "t2"; });
    loop.queueTask(TaskSource.networking, () { log ~= "n1"; });
    loop.queueTask(TaskSource.userInteraction, () { log ~= "u2"; });
    auto n = loop.runUntilIdle();
    assert(n == 5, "expected 5 tasks, ran " ~ to!string(n));
    assert(log == "u1u2t1t2n1", "priority/FIFO wrong: " ~ log);
}

unittest
{
    // A microtask checkpoint runs after each task, and microtasks queued by
    // microtasks drain in the same checkpoint before the next task starts.
    auto loop = new EventLoop();
    string log;
    loop.queueTask(TaskSource.timer, () {
        log ~= "task";
        loop.queueMicrotask(() {
            log ~= "m1";
            loop.queueMicrotask(() { log ~= "m2"; });
        });
    });
    loop.queueTask(TaskSource.timer, () { log ~= "task2"; });
    loop.runUntilIdle();
    assert(log == "taskm1m2task2", "microtask order wrong: " ~ log);
}

unittest
{
    // Timers fire only once the clock reaches their due time; ordering is by
    // (dueAt, insertion).
    auto loop = new EventLoop();
    string log;
    loop.setTimeout(() { log ~= "a"; }, 30);
    loop.setTimeout(() { log ~= "b"; }, 10);
    loop.setTimeout(() { log ~= "c"; }, 10);
    assert(loop.now() == 0.0);
    loop.advance(5);
    assert(loop.runExpiredTimers() == 0, "timer fired early");
    loop.setNow(10);
    assert(loop.runExpiredTimers() == 2, "expected b and c to fire");
    assert(log == "bc", "timer order wrong: " ~ log);
    assert(loop.advanceToNextTimer());
    assert(log == "bca", "late timer wrong: " ~ log);
    assert(loop.now() == 30.0, "clock did not advance to the last timer");
}

unittest
{
    // clearTimeout cancels before the due time; setInterval repeats until cleared.
    auto loop = new EventLoop();
    string log;
    auto a = loop.setTimeout(() { log ~= "a"; }, 5);
    assert(loop.clearTimeout(a));
    assert(!loop.advanceToNextTimer(), "cleared timer should leave no work");
    assert(log == "", "cleared timer ran: " ~ log);

    int count = 0;
    long iv = loop.setInterval(() { count++; }, 10);
    loop.advanceToNextTimer();  // 10
    loop.advanceToNextTimer();  // 20
    loop.advanceToNextTimer();  // 30
    assert(count == 3, "interval count wrong: " ~ to!string(count));
    assert(loop.clearInterval(iv));
    assert(!loop.advanceToNextTimer(), "cleared interval should stop");
    assert(count == 3, "interval ran after clear: " ~ to!string(count));
}

unittest
{
    // Zero-delay timers that reschedule themselves get clamped once they nest
    // past level 5, so they cannot spin the host forever.
    auto loop = new EventLoop();
    int generation = 0;
    double lastNow = -1.0;
    void chain()
    {
        generation++;
        lastNow = loop.now();
        if (generation < 12) loop.setTimeout(&chain, 0);
    }
    loop.setTimeout(&chain, 0);
    loop.runAllTimers();
    assert(generation == 12, "chain did not complete: " ~ to!string(generation));
    // Only the tail generations cost 4 ms each; the head runs for free.
    assert(lastNow >= 16.0, "nesting clamp not applied, now=" ~ to!string(lastNow));
    assert(lastNow <= 24.0, "unexpected accumulated delay: " ~ to!string(lastNow));
}

unittest
{
    // requestAnimationFrame runs inside a frame; a callback that re-requests is
    // deferred to the next frame; render callbacks run every frame.
    auto loop = new EventLoop();
    string log;
    double seenTs = -1.0;
    loop.requestAnimationFrame((double ts) {
        seenTs = ts;
        log ~= "f1";
        loop.requestAnimationFrame((double ts2) { log ~= "f2"; });
    });
    loop.addRenderCallback((double ts) { log ~= "r"; });
    assert(loop.runFrame(16.5));
    assert(seenTs == 16.5, "timestamp wrong: " ~ to!string(seenTs));
    assert(log == "f1r", "frame order wrong: " ~ log);
    assert(loop.runFrame(33.0));
    assert(log == "f1rf2r", "second frame wrong: " ~ log);
}

unittest
{
    // cancelAnimationFrame drops a queued frame callback.
    auto loop = new EventLoop();
    bool ran = false;
    auto id = loop.requestAnimationFrame((double ts) { ran = true; });
    assert(loop.cancelAnimationFrame(id));
    loop.runFrame(1.0);
    assert(!ran, "cancelled frame ran");
}

unittest
{
    // hasPendingWork reflects tasks, timers and frames.
    auto loop = new EventLoop();
    assert(!loop.hasPendingWork());
    loop.queueTask(TaskSource.timer, () {});
    assert(loop.hasPendingWork());
    loop.runUntilIdle();
    assert(!loop.hasPendingWork());
    loop.setTimeout(() {}, 5);
    assert(loop.hasPendingWork());
    assert(loop.timerCount() == 1);
    loop.advanceToNextTimer();
    assert(!loop.hasPendingWork());
}

unittest
{
    // Microtask checkpoint is re-entrancy safe: a checkpoint triggered from a
    // microtask does not recurse, and the outer drain still completes.
    auto loop = new EventLoop();
    string log;
    loop.queueMicrotask(() {
        log ~= "a";
        loop.performMicrotaskCheckpoint();   // ignored (already draining)
        loop.queueMicrotask(() { log ~= "b"; });
    });
    loop.performMicrotaskCheckpoint();
    assert(log == "ab", "nested checkpoint wrong: " ~ log);
}

module auroracut.playback;

import auroracut.preview : PreviewFrame;
import auroracut.util : formatSeconds;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, hnsecs;
import std.format : format;
import std.process : Config, Pid, ProcessPipes, Redirect, kill, pipeProcess,
    spawnProcess, wait;

/** Lightweight counters used by stress tests and diagnostics. */
struct PlaybackWorkerStats
{
    ulong requests;
    ulong processesStarted;
    ulong framesDecoded;
    ulong framesPublished;
    ulong framesDropped;
    ulong cancellations;
}

private struct AudioRequest
{
    ulong generation;
    string path;
    double startTime;
    double duration;
    double volume;
    ubyte retryCount;
}

/**
 * Asynchronous hidden FFplay controller.
 *
 * Process creation, waiting, and reaping happen only on one daemon worker.
 * The UI thread merely replaces the newest request and asks the current child
 * to terminate. Rapid timeline seeks therefore cannot accumulate process
 * handles or block inside wait()/tryWait().
 */
final class HiddenAudioPlayer
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private Pid _process;
    private AudioRequest _pending;
    private bool _hasPending;
    private bool _shutdown;
    private bool _requestedRunning;
    private ulong _generation;
    private PlaybackWorkerStats _stats;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    bool running()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _requestedRunning;
    }

    bool start(string path, double startTime = 0.0, double duration = 0.0,
        double volume = 1.0)
    {
        if (path.length == 0 || volume <= 0.000_001 || duration <= 0.000_001)
        {
            stop();
            return false;
        }

        Pid process;
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return false;
        }
        AudioRequest request;
        request.generation = ++_generation;
        request.path = path;
        request.startTime = startTime < 0.0 ? 0.0 : startTime;
        request.duration = duration;
        request.volume = volume;
        _pending = request;
        _hasPending = true;
        _requestedRunning = true;
        ++_stats.requests;
        process = _process;
        _condition.notify();
        _mutex.unlock();

        // The worker owns wait()/reaping. Termination itself is non-blocking.
        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        return true;
    }

    /** Compatibility no-op: lifecycle polling is handled by the worker. */
    void poll() {}

    void stop()
    {
        Pid process;
        _mutex.lock();
        ++_generation;
        _hasPending = false;
        _requestedRunning = false;
        process = _process;
        if (process !is null) ++_stats.cancellations;
        _condition.notify();
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
    }

    /** Stop and join the worker during application teardown. Interactive
     * start/stop operations remain non-blocking; only final destruction waits
     * so no decoder thread can outlive the D runtime or its owner object. */
    void shutdown()
    {
        Pid process;
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            ++_generation;
            _hasPending = false;
            _requestedRunning = false;
            process = _process;
            _condition.notifyAll();
        }
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        if (_worker !is null)
        {
            try _worker.join();
            catch (Exception) {}
        }
    }

    PlaybackWorkerStats stats()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _stats;
    }

    private void workerLoop()
    {
        while (true)
        {
            AudioRequest request;
            _mutex.lock();
            while (!_shutdown && !_hasPending)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            request = _pending;
            _hasPending = false;
            _mutex.unlock();

            string[] arguments = [
                "ffplay", "-hide_banner", "-loglevel", "error",
                "-nodisp", "-vn", "-autoexit", "-sync", "audio"
            ];
            if (request.startTime > 0.000_5)
                arguments ~= ["-ss", formatSeconds(request.startTime, 6)];
            if (request.duration > 0.000_5)
                arguments ~= ["-t", formatSeconds(request.duration, 6)];
            if (request.volume < 0.999_5 || request.volume > 1.000_5)
                arguments ~= ["-af", "volume=" ~ formatSeconds(request.volume, 5)];
            arguments ~= request.path;

            Pid process;
            MonoTime processStarted;
            try
            {
                process = spawnProcess(arguments, cast(const string[string]) null,
                    Config.suppressConsole);
                processStarted = MonoTime.currTime;
            }
            catch (Exception)
            {
                _mutex.lock();
                if (request.generation == _generation)
                    _requestedRunning = false;
                _mutex.unlock();
                continue;
            }

            bool stale;
            _mutex.lock();
            stale = request.generation != _generation || _shutdown;
            if (!stale)
            {
                _process = process;
                ++_stats.processesStarted;
            }
            _mutex.unlock();

            if (stale)
            {
                try kill(process);
                catch (Exception) {}
            }
            try wait(process);
            catch (Exception) {}

            const elapsedMs = processStarted == MonoTime.init ? long.max :
                (MonoTime.currTime - processStarted).total!"msecs";
            _mutex.lock();
            if (_process is process) _process = null;
            if (request.generation == _generation && !_hasPending)
            {
                // Some Windows audio-device/seek starts fail immediately while
                // the same request succeeds on the next attempt. Retry once in
                // the worker rather than forcing the editor to click Play or
                // seek to the same position again.
                if (!_shutdown && _requestedRunning && request.retryCount == 0 &&
                    request.duration > 0.5 && elapsedMs >= 0 && elapsedMs < 350)
                {
                    ++request.retryCount;
                    _pending = request;
                    _hasPending = true;
                    _condition.notify();
                }
                else
                    _requestedRunning = false;
            }
            const shouldExit = _shutdown;
            _mutex.unlock();
            if (shouldExit) break;
        }
    }
}

private struct VideoRequest
{
    ulong generation;
    string path;
    double startTime;
    double duration;
    int width;
    int height;
    int fps;
    string title;
    string[] commandArguments;
    double displayStartTime;
}

/**
 * Persistent, asynchronous FFmpeg raw-video controller.
 *
 * start()/stop() are O(1) event-thread operations: requests coalesce to the
 * newest generation and old children are terminated without joining a decoder
 * thread. Four reusable RGB slots avoid full-frame allocation churn while
 * preserving the buffer Aurora is currently painting.
 */
final class VideoFrameStream
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private Pid _process;
    private VideoRequest _pending;
    private bool _hasPending;
    private bool _shutdown;
    private ulong _generation;
    private bool _running;
    private bool _finished;
    private string _error;

    private ubyte[][4] _slots;
    private int _displayedSlot = -1;
    private int _readySlot = -1;
    private int _writingSlot = -1;
    private int _readyWidth;
    private int _readyHeight;
    private int _readyFps;
    private double _readyStartTime;
    private string _readyTitle;
    private long _readyFrameNumber;
    private PlaybackWorkerStats _stats;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    bool start(string path, double startTime, double duration, int width,
        int height, int fps, string title)
    {
        if (path.length == 0 || duration <= 0.0 || width <= 0 || height <= 0 || fps <= 0)
        {
            stop();
            return false;
        }

        width = width % 2 == 0 ? width : width + 1;
        height = height % 2 == 0 ? height : height + 1;

        Pid process;
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return false;
        }
        VideoRequest request;
        request.generation = ++_generation;
        request.path = path;
        request.startTime = startTime < 0.0 ? 0.0 : startTime;
        request.duration = duration;
        request.width = width;
        request.height = height;
        request.fps = fps;
        request.title = title;
        _pending = request;
        _hasPending = true;
        _running = true;
        _finished = false;
        _error = "";
        _readySlot = -1;
        ++_stats.requests;
        process = _process;
        if (process !is null) ++_stats.cancellations;
        _condition.notify();
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        return true;
    }

    /** Start an already-built FFmpeg RGB24 command. This is used by the
     * live timeline compositor and avoids rendering a temporary proxy file. */
    bool startCommand(string[] arguments, double displayStartTime,
        double duration, int width, int height, int fps, string title)
    {
        if (arguments.length == 0 || duration <= 0.0 || width <= 0 ||
            height <= 0 || fps <= 0)
        {
            stop();
            return false;
        }
        width = width % 2 == 0 ? width : width + 1;
        height = height % 2 == 0 ? height : height + 1;

        Pid process;
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return false;
        }
        VideoRequest request;
        request.generation = ++_generation;
        request.commandArguments = arguments.dup;
        request.displayStartTime = displayStartTime < 0.0 ? 0.0 : displayStartTime;
        request.startTime = request.displayStartTime;
        request.duration = duration;
        request.width = width;
        request.height = height;
        request.fps = fps;
        request.title = title;
        _pending = request;
        _hasPending = true;
        _running = true;
        _finished = false;
        _error = "";
        _readySlot = -1;
        ++_stats.requests;
        process = _process;
        if (process !is null) ++_stats.cancellations;
        _condition.notify();
        _mutex.unlock();
        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        return true;
    }

    private void workerLoop()
    {
        while (true)
        {
            VideoRequest request;
            _mutex.lock();
            while (!_shutdown && !_hasPending)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            request = _pending;
            _hasPending = false;
            _mutex.unlock();
            decodeRequest(request);
        }
    }

    private void decodeRequest(VideoRequest request)
    {
        const frameBytes = cast(size_t) request.width *
            cast(size_t) request.height * 3;
        string[] arguments;
        if (request.commandArguments.length > 0)
            arguments = request.commandArguments;
        else
        {
            const videoFilter = format(
                "scale=%d:%d:force_original_aspect_ratio=decrease:flags=fast_bilinear," ~
                "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black,fps=%d",
                request.width, request.height, request.width, request.height,
                request.fps);
            arguments = [
                "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
                "-threads", "2", "-filter_threads", "1",
                "-ss", formatSeconds(request.startTime, 6), "-i", request.path,
                "-t", formatSeconds(request.duration, 6), "-an", "-sn", "-dn",
                "-vf", videoFilter, "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"
            ];
        }

        ProcessPipes pipes;
        try
        {
            pipes = pipeProcess(arguments, Redirect.stdout,
                cast(const string[string]) null, Config.suppressConsole);
        }
        catch (Exception error)
        {
            publishFailure(request.generation, error.msg);
            return;
        }

        bool stale;
        _mutex.lock();
        stale = request.generation != _generation || _shutdown;
        if (!stale)
        {
            _process = pipes.pid;
            ++_stats.processesStarted;
        }
        _mutex.unlock();

        if (stale)
        {
            try pipes.stdout.close();
            catch (Exception) {}
            try kill(pipes.pid);
            catch (Exception) {}
            try wait(pipes.pid);
            catch (Exception) {}
            return;
        }

        long frameNumber;
        bool reachedEof;
        const pacingStarted = MonoTime.currTime;
        while (true)
        {
            const slot = acquireWriteSlot(request.generation, frameBytes);
            if (slot < 0) break;
            size_t received;
            try
            {
                while (received < frameBytes)
                {
                    auto chunk = pipes.stdout.rawRead(
                        _slots[slot][received .. frameBytes]);
                    if (chunk.length == 0) break;
                    received += chunk.length;
                }
            }
            catch (Exception)
            {
                received = 0;
            }

            if (received != frameBytes)
            {
                releaseWriteSlot(slot, request, false, frameNumber);
                reachedEof = true;
                break;
            }
            releaseWriteSlot(slot, request, true, frameNumber++);
            const target = pacingStarted +
                (cast(long) (cast(double) frameNumber * 10_000_000.0 /
                    request.fps)).hnsecs;
            const remaining = target - MonoTime.currTime;
            if (remaining.total!"hnsecs" > 0)
                Thread.sleep(remaining);
        }

        try pipes.stdout.close();
        catch (Exception) {}
        try wait(pipes.pid);
        catch (Exception) {}

        _mutex.lock();
        if (_process is pipes.pid) _process = null;
        if (request.generation == _generation)
        {
            _running = false;
            _finished = reachedEof;
            _writingSlot = -1;
        }
        _mutex.unlock();
    }

    private int acquireWriteSlot(ulong generation, size_t frameBytes)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (generation != _generation || !_running || _shutdown) return -1;

        foreach (slot; 0 .. cast(int) _slots.length)
        {
            if (slot == _displayedSlot || slot == _readySlot ||
                slot == _writingSlot) continue;
            if (_slots[slot].length != frameBytes)
                _slots[slot] = new ubyte[frameBytes];
            _writingSlot = slot;
            return slot;
        }

        if (_readySlot >= 0 && _readySlot != _displayedSlot)
        {
            const slot = _readySlot;
            _readySlot = -1;
            if (_slots[slot].length != frameBytes)
                _slots[slot] = new ubyte[frameBytes];
            _writingSlot = slot;
            ++_stats.framesDropped;
            return slot;
        }
        return -1;
    }

    private void releaseWriteSlot(int slot, const VideoRequest request,
        bool publish, long frameNumber)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_writingSlot == slot) _writingSlot = -1;
        if (!publish || request.generation != _generation || !_running || _shutdown)
        {
            if (publish) ++_stats.framesDropped;
            return;
        }
        ++_stats.framesDecoded;
        if (_readySlot >= 0 && _readySlot != _displayedSlot)
            ++_stats.framesDropped;
        _readySlot = slot;
        _readyWidth = request.width;
        _readyHeight = request.height;
        _readyFps = request.fps;
        _readyStartTime = request.commandArguments.length > 0 ?
            request.displayStartTime : request.startTime;
        _readyTitle = request.title;
        _readyFrameNumber = frameNumber;
        ++_stats.framesPublished;
    }

    private void publishFailure(ulong generation, string message)
    {
        _mutex.lock();
        if (generation == _generation)
        {
            _error = message;
            _running = false;
            _finished = true;
            _process = null;
        }
        _mutex.unlock();
    }

    bool takeReady(out PreviewFrame frame)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_readySlot < 0) return false;
        _displayedSlot = _readySlot;
        _readySlot = -1;
        frame = PreviewFrame.init;
        frame.width = _readyWidth;
        frame.height = _readyHeight;
        frame.rgb = _slots[_displayedSlot];
        frame.title = _readyTitle;
        frame.sourceTime = _readyStartTime +
            cast(double) _readyFrameNumber / _readyFps;
        return true;
    }

    bool running()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _running;
    }

    bool finished()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _finished;
    }

    string error()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _error;
    }

    PlaybackWorkerStats stats()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _stats;
    }

    void stop()
    {
        Pid process;
        _mutex.lock();
        ++_generation;
        _hasPending = false;
        _running = false;
        _finished = false;
        _readySlot = -1;
        _writingSlot = -1;
        process = _process;
        if (process !is null) ++_stats.cancellations;
        _condition.notify();
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
    }

    /** Safe final teardown. Normal stop()/seek operations remain O(1); final
     * shutdown joins the worker after terminating its child process. */
    void shutdown()
    {
        Pid process;
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            ++_generation;
            _hasPending = false;
            _running = false;
            _finished = false;
            _readySlot = -1;
            process = _process;
            _condition.notifyAll();
        }
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        if (_worker !is null)
        {
            try _worker.join();
            catch (Exception) {}
        }
    }
}

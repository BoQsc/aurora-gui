module auroracut.playback;

import auroracut.preview : PreviewFrame;
import auroracut.util : formatSeconds;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, hnsecs, msecs;
import std.format : format;
import std.path : extension;
import std.process : Config, Pid, ProcessPipes, Redirect, kill, pipeProcess,
    wait;
import std.string : toLower;

version (Windows)
{
    import core.sys.windows.mmsystem;
}

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
    string[] commandArguments;
    double startTime;
    double displayStartTime;
    double duration;
    double volume;
    bool startPaused;
}

private enum int previewAudioSampleRate = 48_000;
private enum int previewAudioChannels = 2;
private enum int previewAudioBytesPerSample = 2;
private enum int previewAudioFrameBytes =
    previewAudioChannels * previewAudioBytesPerSample;
private enum int previewAudioChunkFrames = 2_048;
private enum int previewAudioChunkBytes =
    previewAudioChunkFrames * previewAudioFrameBytes;
private enum int previewAudioQueuedBuffers = 6;

version (Windows)
private final class WaveOutBuffer
{
    ubyte[] data;
    WAVEHDR header;
    bool prepared;
}

version (Windows)
private final class WaveOutPcmSink
{
    private HWAVEOUT _handle;
    private WaveOutBuffer[] _queued;

    bool open()
    {
        WAVEFORMATEX format;
        format.wFormatTag = WAVE_FORMAT_PCM;
        format.nChannels = previewAudioChannels;
        format.nSamplesPerSec = previewAudioSampleRate;
        format.wBitsPerSample = previewAudioBytesPerSample * 8;
        format.nBlockAlign = previewAudioFrameBytes;
        format.nAvgBytesPerSec = previewAudioSampleRate * previewAudioFrameBytes;
        format.cbSize = 0;
        return waveOutOpen(&_handle, WAVE_MAPPER, &format, 0, 0,
            CALLBACK_NULL) == MMSYSERR_NOERROR;
    }

    HWAVEOUT handle() @safe pure nothrow @nogc { return _handle; }

    void reset()
    {
        if (_handle !is null)
        {
            waveOutReset(_handle);
        }
    }

    private void removeQueued(size_t index)
    {
        auto item = _queued[index];
        if (_handle !is null && item.prepared)
        {
            waveOutUnprepareHeader(_handle, &item.header, WAVEHDR.sizeof);
            item.prepared = false;
        }
        foreach (shift; index .. _queued.length - 1)
            _queued[shift] = _queued[shift + 1];
        _queued.length = _queued.length - 1;
    }

    private void reapCompleted()
    {
        for (size_t index; index < _queued.length; )
        {
            if ((_queued[index].header.dwFlags & WHDR_DONE) == 0)
            {
                ++index;
                continue;
            }
            removeQueued(index);
        }
    }

    private bool waitForQueueRoom()
    {
        const started = MonoTime.currTime;
        while (_queued.length >= previewAudioQueuedBuffers)
        {
            reapCompleted();
            if (_queued.length < previewAudioQueuedBuffers) return true;
            if ((MonoTime.currTime - started).total!"msecs" > 2_000)
                return false;
            Thread.sleep(2.msecs);
        }
        return true;
    }

    bool writeQueued(const(ubyte)[] data)
    {
        return writeQueued(data, null);
    }

    bool writeQueued(const(ubyte)[] data, void delegate() afterQueued)
    {
        if (_handle is null || data.length == 0) return false;
        reapCompleted();
        if (!waitForQueueRoom()) return false;

        auto buffer = new WaveOutBuffer();
        buffer.data = new ubyte[data.length];
        buffer.data[] = data[];
        buffer.header = WAVEHDR.init;
        buffer.header.lpData = cast(char*) buffer.data.ptr;
        buffer.header.dwBufferLength = cast(uint) buffer.data.length;
        if (waveOutPrepareHeader(_handle, &buffer.header, WAVEHDR.sizeof) !=
            MMSYSERR_NOERROR)
            return false;
        buffer.prepared = true;
        if (waveOutWrite(_handle, &buffer.header, WAVEHDR.sizeof) != MMSYSERR_NOERROR)
        {
            waveOutUnprepareHeader(_handle, &buffer.header, WAVEHDR.sizeof);
            return false;
        }
        _queued ~= buffer;
        if (afterQueued !is null) afterQueued();
        return true;
    }

    bool pause()
    {
        return _handle !is null &&
            waveOutPause(_handle) == MMSYSERR_NOERROR;
    }

    bool restart()
    {
        return _handle !is null &&
            waveOutRestart(_handle) == MMSYSERR_NOERROR;
    }

    bool drain()
    {
        const started = MonoTime.currTime;
        while (_queued.length > 0)
        {
            reapCompleted();
            if (_queued.length == 0) return true;
            if ((MonoTime.currTime - started).total!"msecs" > 2_000)
                return false;
            Thread.sleep(2.msecs);
        }
        return true;
    }

    void close()
    {
        if (_handle is null) return;
        reset();
        while (_queued.length > 0)
            removeQueued(_queued.length - 1);
        waveOutClose(_handle);
        _handle = null;
    }
}

/**
 * Asynchronous PCM preview-audio controller.
 *
 * FFmpeg is used only as the codec decoder/mixer. It writes raw 48 kHz stereo
 * s16le PCM to stdout; Aurora Cut owns the audio-device output and exposes its
 * playback clock to the editor. This avoids using a separate media player with
 * an independent clock for Composition Preview.
 */
final class PcmAudioPlayer
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private Pid _process;
    private AudioRequest _pending;
    private bool _hasPending;
    private bool _shutdown;
    private bool _requestedRunning;
    private bool _resumeRequested;
    private ulong _generation;
    private PlaybackWorkerStats _stats;
    private string _error;
    private double _clockStartTime;
    private MonoTime _fallbackClockStarted;
    private bool _fallbackClockValid;
    version (Windows) private HWAVEOUT _clockHandle;

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

    bool clockPosition(out double position)
    {
        position = 0.0;
        version (AuroraHeadless)
        {
            double startTime;
            MonoTime started;
            bool valid;
            _mutex.lock();
            startTime = _clockStartTime;
            started = _fallbackClockStarted;
            valid = _fallbackClockValid;
            _mutex.unlock();
            if (!valid) return false;
            const elapsed = MonoTime.currTime - started;
            position = startTime +
                cast(double) elapsed.total!"hnsecs" / 10_000_000.0;
            return true;
        }
        else
        version (Windows)
        {
            HWAVEOUT handle;
            double startTime;
            _mutex.lock();
            handle = _clockHandle;
            startTime = _clockStartTime;
            _mutex.unlock();

            if (handle is null) return false;
            MMTIME time;
            time.wType = TIME_SAMPLES;
            if (waveOutGetPosition(handle, &time, MMTIME.sizeof) !=
                MMSYSERR_NOERROR)
                return false;
            position = startTime +
                cast(double) time.sample / cast(double) previewAudioSampleRate;
            return true;
        }
        else
            return false;
    }

    string error()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _error;
    }

    /** Decode from source `startTime`, but publish the transport clock from
     * `displayStartTime`. Direct timeline playback needs this because a clip's
     * media in-point can differ from its sequence time. */
    bool start(string path, double startTime = 0.0, double duration = 0.0,
        double volume = 1.0, double displayStartTime = -1.0,
        bool startPaused = false)
    {
        if (path.length == 0 || volume <= 0.000_001 || duration <= 0.000_001)
        {
            stop();
            return false;
        }

        AudioRequest request;
        request.path = path;
        request.startTime = startTime < 0.0 ? 0.0 : startTime;
        request.displayStartTime = displayStartTime < 0.0 ?
            request.startTime : displayStartTime;
        request.duration = duration;
        request.volume = volume;
        request.startPaused = startPaused;
        return enqueue(request);
    }

    bool startCommand(string[] arguments, double displayStartTime,
        double duration, double volume = 1.0, bool startPaused = false)
    {
        if (arguments.length == 0 || duration <= 0.000_001 ||
            volume <= 0.000_001)
        {
            stop();
            return false;
        }

        AudioRequest request;
        request.commandArguments = arguments.dup;
        request.startTime = displayStartTime < 0.0 ? 0.0 : displayStartTime;
        request.displayStartTime = request.startTime;
        request.duration = duration;
        request.volume = volume;
        request.startPaused = startPaused;
        return enqueue(request);
    }

    private bool enqueue(ref AudioRequest request)
    {
        Pid process;
        version (Windows) HWAVEOUT handle;
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return false;
        }
        request.generation = ++_generation;
        _pending = request;
        _hasPending = true;
        _requestedRunning = true;
        _resumeRequested = false;
        _error = "";
        version (Windows)
        {
            handle = _clockHandle;
            _clockHandle = null;
        }
        _fallbackClockValid = false;
        ++_stats.requests;
        process = _process;
        _condition.notify();
        _mutex.unlock();

        version (Windows)
        {
            if (handle !is null)
            {
                try waveOutReset(handle);
                catch (Throwable) {}
            }
        }
        // The worker owns wait()/reaping. Termination itself is non-blocking.
        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        return true;
    }

    bool resume()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (!_requestedRunning) return false;
        _resumeRequested = true;
        _condition.notifyAll();
        return true;
    }

    /** Compatibility no-op: lifecycle polling is handled by the worker. */
    void poll() {}

    void stop()
    {
        Pid process;
        version (Windows) HWAVEOUT handle;
        _mutex.lock();
        ++_generation;
        _hasPending = false;
        _requestedRunning = false;
        _resumeRequested = false;
        process = _process;
        version (Windows)
        {
            handle = _clockHandle;
            _clockHandle = null;
        }
        _fallbackClockValid = false;
        if (process !is null) ++_stats.cancellations;
        _condition.notify();
        _mutex.unlock();

        version (Windows)
        {
            if (handle !is null)
            {
                try waveOutReset(handle);
                catch (Throwable) {}
            }
        }
        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
    }

    /** Request final teardown without blocking the UI on a stuck audio driver. */
    void shutdown()
    {
        Pid process;
        version (Windows) HWAVEOUT handle;
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            ++_generation;
            _hasPending = false;
            _requestedRunning = false;
            _resumeRequested = false;
            process = _process;
            version (Windows)
            {
                handle = _clockHandle;
                _clockHandle = null;
            }
            _fallbackClockValid = false;
            _condition.notifyAll();
        }
        _mutex.unlock();

        version (Windows)
        {
            if (handle !is null)
            {
                try waveOutReset(handle);
                catch (Throwable) {}
            }
        }
        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        // Do not join here. The worker is daemonized and all owned children are
        // asked to stop above; joining can still hang on a misbehaving audio
        // driver during application exit.
    }

    PlaybackWorkerStats stats()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _stats;
    }

    private string[] decodeArguments(const AudioRequest request)
    {
        if (request.commandArguments.length > 0)
            return request.commandArguments.dup;

        string[] arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
            "-threads", "1",
            "-ss", formatSeconds(request.startTime, 6), "-i", request.path,
            "-t", formatSeconds(request.duration, 6), "-vn", "-sn", "-dn"
        ];
        if (request.volume < 0.999_5 || request.volume > 1.000_5)
            arguments ~= ["-af", "volume=" ~ formatSeconds(request.volume, 5)];
        arguments ~= [
            "-ac", "2", "-ar", "48000", "-sample_fmt", "s16",
            "-f", "s16le", "pipe:1"
        ];
        return arguments;
    }

    private void publishAudioFailure(ulong generation, string message)
    {
        _mutex.lock();
        if (generation == _generation)
        {
            _requestedRunning = false;
            _error = message;
            version (Windows) _clockHandle = null;
            _fallbackClockValid = false;
        }
        _mutex.unlock();
    }

    private void publishMonotonicClock(ulong generation, double startTime)
    {
        _mutex.lock();
        if (generation == _generation && !_shutdown)
        {
            _clockStartTime = startTime;
            _fallbackClockStarted = MonoTime.currTime;
            _fallbackClockValid = true;
        }
        _mutex.unlock();
    }

    version (Windows)
    private void publishAudioClock(ulong generation, HWAVEOUT handle,
        double startTime)
    {
        _mutex.lock();
        if (generation == _generation && !_shutdown)
        {
            _clockHandle = handle;
            _clockStartTime = startTime;
            _fallbackClockStarted = MonoTime.currTime;
            _fallbackClockValid = true;
        }
        _mutex.unlock();
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

            playRequest(request);
        }
    }

    private bool waitForResume(ulong generation)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        while (!_shutdown && generation == _generation && !_resumeRequested)
            _condition.wait();
        return !_shutdown && generation == _generation;
    }

    private void playRequest(AudioRequest request)
    {
        ProcessPipes pipes;
        try
        {
            pipes = pipeProcess(decodeArguments(request), Redirect.stdout,
                cast(const string[string]) null, Config.suppressConsole);
        }
        catch (Exception error)
        {
            publishAudioFailure(request.generation, error.msg);
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

        version (AuroraHeadless)
        {
            auto buffer = new ubyte[previewAudioChunkBytes];
            bool clockPublished;
            while (true)
            {
                _mutex.lock();
                stale = request.generation != _generation || _shutdown;
                _mutex.unlock();
                if (stale) break;

                size_t received;
                try
                {
                    while (received < buffer.length)
                    {
                        auto chunk = pipes.stdout.rawRead(
                            buffer[received .. $]);
                        if (chunk.length == 0) break;
                        received += chunk.length;
                    }
                }
                catch (Exception)
                {
                    received = 0;
                }
                if (received == 0) break;
                if (!clockPublished)
                {
                    publishMonotonicClock(request.generation,
                        request.displayStartTime);
                    clockPublished = true;
                    if (request.startPaused)
                    {
                        if (!waitForResume(request.generation)) break;
                        publishMonotonicClock(request.generation,
                            request.displayStartTime);
                    }
                }
                const frames = received / previewAudioFrameBytes;
                if (frames > 0)
                    Thread.sleep((cast(long) frames * 10_000_000L /
                        previewAudioSampleRate).hnsecs);
            }

            try pipes.stdout.close();
            catch (Exception) {}
            try wait(pipes.pid);
            catch (Exception) {}

            _mutex.lock();
            if (_process is pipes.pid) _process = null;
            if (request.generation == _generation && !_hasPending)
            {
                _requestedRunning = false;
                _fallbackClockValid = false;
            }
            _mutex.unlock();
        }
        else version (Windows)
        {
            auto sink = new WaveOutPcmSink();
            if (!sink.open())
            {
                publishAudioFailure(request.generation,
                    "The Windows PCM audio output could not be opened.");
                try pipes.stdout.close();
                catch (Exception) {}
                try kill(pipes.pid);
                catch (Exception) {}
                try wait(pipes.pid);
                catch (Exception) {}
                return;
            }
            if (request.startPaused && !sink.pause())
            {
                publishAudioFailure(request.generation,
                    "The Windows PCM audio output could not be paused for preroll.");
                try pipes.stdout.close();
                catch (Exception) {}
                try kill(pipes.pid);
                catch (Exception) {}
                try wait(pipes.pid);
                catch (Exception) {}
                return;
            }
            scope (exit) sink.close();

            auto buffer = new ubyte[previewAudioChunkBytes];
            bool clockPublished;
            bool drainSink = true;
            while (true)
            {
                _mutex.lock();
                stale = request.generation != _generation || _shutdown;
                _mutex.unlock();
                if (stale)
                {
                    drainSink = false;
                    break;
                }

                size_t received;
                try
                {
                    while (received < buffer.length)
                    {
                        auto chunk = pipes.stdout.rawRead(
                            buffer[received .. $]);
                        if (chunk.length == 0) break;
                        received += chunk.length;
                    }
                }
                catch (Exception)
                {
                    received = 0;
                }
                if (received == 0) break;
                if (!clockPublished)
                {
                    if (!sink.writeQueued(buffer[0 .. received],
                        delegate()
                        {
                            publishAudioClock(request.generation, sink.handle(),
                                request.displayStartTime);
                            clockPublished = true;
                        }))
                        break;
                    if (request.startPaused)
                    {
                        if (!waitForResume(request.generation))
                        {
                            drainSink = false;
                            break;
                        }
                        if (!sink.restart())
                        {
                            drainSink = false;
                            break;
                        }
                    }
                }
                else if (!sink.writeQueued(buffer[0 .. received])) break;
            }
            if (drainSink) sink.drain();
            else sink.reset();

            try pipes.stdout.close();
            catch (Exception) {}
            try wait(pipes.pid);
            catch (Exception) {}

            _mutex.lock();
            if (_process is pipes.pid) _process = null;
            if (_clockHandle is sink.handle()) _clockHandle = null;
            if (request.generation == _generation && !_hasPending)
                _requestedRunning = false;
            _mutex.unlock();
        }
        else
        {
            publishAudioFailure(request.generation,
                "PCM preview audio is currently implemented for Windows.");
            try pipes.stdout.close();
            catch (Exception) {}
            try kill(pipes.pid);
            catch (Exception) {}
            try wait(pipes.pid);
            catch (Exception) {}
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
    string[] fallbackCommandArguments;
    string[] decodeInputOptions;
    double displayStartTime;
}

private struct ReadyVideoFrame
{
    int slot = -1;
    int width;
    int height;
    int fps;
    double startTime;
    string title;
    long frameNumber;
}

private enum size_t videoFrameSlotCount = 16;

private bool isHardwareDecodeCandidatePath(string path)
{
    const suffix = extension(path).toLower();
    return suffix == ".mp4" || suffix == ".mov" || suffix == ".mkv" ||
        suffix == ".webm";
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

    private ubyte[][videoFrameSlotCount] _slots;
    private int _displayedSlot = -1;
    private int _writingSlot = -1;
    private ReadyVideoFrame[] _readyFrames;
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
        int height, int fps, string title, string[] decodeInputOptions = null)
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
        if (isHardwareDecodeCandidatePath(path))
            request.decodeInputOptions = decodeInputOptions.dup;
        _pending = request;
        _hasPending = true;
        _running = true;
        _finished = false;
        _error = "";
        _readyFrames.length = 0;
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
        double duration, int width, int height, int fps, string title,
        string[] fallbackArguments = null)
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
        request.fallbackCommandArguments = fallbackArguments.dup;
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
        _readyFrames.length = 0;
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
        const arguments = decodeArguments(request);

        ProcessPipes pipes;
        try
        {
            pipes = pipeProcess(arguments, Redirect.stdout,
                cast(const string[string]) null, Config.suppressConsole);
        }
        catch (Exception error)
        {
            if (canRetryWithoutHardwareDecode(request))
            {
                decodeRequest(cpuDecodeFallbackRequest(request));
                return;
            }
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
        }

        try pipes.stdout.close();
        catch (Exception) {}
        try wait(pipes.pid);
        catch (Exception) {}

        bool retryWithoutHardwareDecode;
        _mutex.lock();
        if (_process is pipes.pid) _process = null;
        retryWithoutHardwareDecode = frameNumber == 0 &&
            canRetryWithoutHardwareDecode(request) &&
            request.generation == _generation && !_shutdown;
        if (retryWithoutHardwareDecode)
        {
            _finished = false;
            _writingSlot = -1;
        }
        else if (request.generation == _generation)
        {
            _running = false;
            _finished = reachedEof;
            _writingSlot = -1;
        }
        _mutex.unlock();
        if (retryWithoutHardwareDecode)
            decodeRequest(cpuDecodeFallbackRequest(request));
    }

    private string[] decodeArguments(const VideoRequest request) const
    {
        if (request.commandArguments.length > 0)
            return request.commandArguments.dup;

        const videoFilter = format(
            "scale=%d:%d:force_original_aspect_ratio=decrease:flags=fast_bilinear," ~
            "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black,fps=%d",
            request.width, request.height, request.width, request.height,
            request.fps);
        string[] arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
            "-threads", "2", "-filter_threads", "1"
        ];
        if (request.decodeInputOptions.length > 0)
            arguments ~= request.decodeInputOptions;
        arguments ~= [
            "-ss", formatSeconds(request.startTime, 6), "-i", request.path,
            "-t", formatSeconds(request.duration, 6), "-an", "-sn", "-dn",
            "-vf", videoFilter, "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"
        ];
        return arguments;
    }

    private bool canRetryWithoutHardwareDecode(const VideoRequest request) const
    {
        return request.decodeInputOptions.length > 0 ||
            request.fallbackCommandArguments.length > 0 ||
            commandContainsHardwareDecodeOptions(request.commandArguments);
    }

    private VideoRequest cpuDecodeFallbackRequest(VideoRequest request) const
    {
        request.decodeInputOptions.length = 0;
        if (request.fallbackCommandArguments.length > 0)
        {
            request.commandArguments = request.fallbackCommandArguments.dup;
            request.fallbackCommandArguments.length = 0;
        }
        else if (request.commandArguments.length > 0)
            request.commandArguments =
                commandWithoutHardwareDecodeOptions(request.commandArguments);
        return request;
    }

    private bool commandContainsHardwareDecodeOptions(const string[] arguments) const
    {
        foreach (argument; arguments)
            if (argument == "-hwaccel" || argument == "-hwaccel_output_format")
                return true;
        return false;
    }

    private string[] commandWithoutHardwareDecodeOptions(
        const string[] arguments) const
    {
        string[] result;
        for (size_t index; index < arguments.length; ++index)
        {
            const argument = arguments[index];
            if (argument == "-hwaccel" || argument == "-hwaccel_output_format")
            {
                if (index + 1 < arguments.length) ++index;
                continue;
            }
            result ~= argument;
        }
        return result;
    }

    private int acquireWriteSlot(ulong generation, size_t frameBytes)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        while (true)
        {
            if (generation != _generation || !_running || _shutdown) return -1;

            foreach (slot; 0 .. cast(int) _slots.length)
            {
                if (slot == _displayedSlot || slot == _writingSlot ||
                    slotReady(slot)) continue;
                if (_slots[slot].length != frameBytes)
                    _slots[slot] = new ubyte[frameBytes];
                _writingSlot = slot;
                return slot;
            }

            _condition.wait();
        }
    }

    private bool slotReady(int slot) const
    {
        foreach (ready; _readyFrames)
            if (ready.slot == slot) return true;
        return false;
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
        if (request.generation != _generation || !_running || _shutdown)
        {
            ++_stats.framesDropped;
            return;
        }
        ++_stats.framesDecoded;
        ReadyVideoFrame ready;
        ready.slot = slot;
        ready.width = request.width;
        ready.height = request.height;
        ready.fps = request.fps;
        ready.startTime = request.commandArguments.length > 0 ?
            request.displayStartTime : request.startTime;
        ready.title = request.title;
        ready.frameNumber = frameNumber;
        _readyFrames ~= ready;
        ++_stats.framesPublished;
        _condition.notifyAll();
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
        if (_readyFrames.length == 0) return false;
        auto ready = popReadyFront();
        _condition.notifyAll();
        frame = previewFrame(ready);
        return true;
    }

    /** Return the newest queued frame whose timestamp is not ahead of the
     * caller's clock. Older due frames are dropped here so audio remains the
     * master clock when the UI cannot present every decoded frame. */
    bool takeReadyUpTo(double maximumSourceTime, out PreviewFrame frame)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        bool found;
        while (_readyFrames.length > 0 &&
            readySourceTime(_readyFrames[0]) <= maximumSourceTime)
        {
            if (found) ++_stats.framesDropped;
            auto ready = popReadyFront();
            frame = previewFrame(ready);
            found = true;
        }
        if (found) _condition.notifyAll();
        return found;
    }

    private ReadyVideoFrame popReadyFront()
    {
        auto ready = _readyFrames[0];
        foreach (index; 0 .. _readyFrames.length - 1)
            _readyFrames[index] = _readyFrames[index + 1];
        _readyFrames.length = _readyFrames.length - 1;
        _displayedSlot = ready.slot;
        return ready;
    }

    private double readySourceTime(const ReadyVideoFrame ready) const
    {
        return ready.startTime + cast(double) ready.frameNumber / ready.fps;
    }

    private PreviewFrame previewFrame(const ReadyVideoFrame ready)
    {
        PreviewFrame frame;
        frame.width = ready.width;
        frame.height = ready.height;
        frame.rgb = _slots[ready.slot];
        frame.title = ready.title;
        frame.sourceTime = readySourceTime(ready);
        return frame;
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
        _readyFrames.length = 0;
        _writingSlot = -1;
        process = _process;
        if (process !is null) ++_stats.cancellations;
        _condition.notifyAll();
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
            _readyFrames.length = 0;
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

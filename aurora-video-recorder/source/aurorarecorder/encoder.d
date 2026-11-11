module aurorarecorder.encoder;

/**
 * The recording engine: a worker thread captures the screen every 1/fps and
 * streams raw BGRA frames into `ffmpeg -f rawvideo ... <file>.mp4`.
 *
 * Design notes
 * ------------
 * - ffmpeg is spawned with `CreateProcessW` into a hidden console and put in
 *   a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so a crash of the
 *   recorder cannot leave an orphan `ffmpeg.exe` holding the file.
 * - Only stdin is a pipe. ffmpeg's diagnostics go to `<output>.log` instead of
 *   a pipe nobody drains (a full stderr pipe would block the encoder).
 * - Writing a frame blocks while ffmpeg is busy. That is expected
 *   back-pressure; the loop captures the next frame after the write returns,
 *   so memory use stays flat.
 * - Pacing uses a monotonic clock and never writes duplicate frames to catch
 *   up. A late frame makes the video a few milliseconds short instead of
 *   stalling everything behind an ever-growing backlog.
 * - The worker never touches a widget or a D object whose access is not
 *   atomic. It publishes `RecorderStatus`, a seqlock-style snapshot that the
 *   window's tick timer polls: the writer bumps the sequence counter before
 *   and after mutating, and the reader only accepts an unchanged count.
 */

import aurorarecorder.capture : ScreenSurface;
import aurorarecorder.loopback : SystemAudioCapture;
import aurorarecorder.settings : CaptureRect, stopMarginSeconds;

import core.stdc.stdio : fclose, FILE, fopen;
import core.thread : Thread, dur;
import core.time : MonoTime, msecs;
import std.conv : text;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;

version (Windows)
{
    import core.sys.windows.windows :
        BOOL, CloseHandle, CreateFileW, CreatePipe, CreateProcessW, DWORD,
        FALSE, FILE_APPEND_DATA, FILE_SHARE_READ, FILE_SHARE_WRITE, HANDLE,
        HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, INFINITE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOBOBJECTINFOCLASS,
        LPWSTR, OPEN_ALWAYS, PROCESS_INFORMATION, SECURITY_ATTRIBUTES,
        SetHandleInformation, SetInformationJobObject, STARTF_USESHOWWINDOW,
        STARTF_USESTDHANDLES, STARTUPINFOW, SW_HIDE, TRUE,
        WaitForSingleObject, WriteFile, FlushFileBuffers, CREATE_NO_WINDOW,
        AssignProcessToJobObject, CreateNamedPipeW, ConnectNamedPipe,
        OVERLAPPED, CreateEventW, GetLastError, ERROR_PIPE_CONNECTED,
        FILE_FLAG_OVERLAPPED,
        PIPE_ACCESS_OUTBOUND, PIPE_READMODE_BYTE,
        PIPE_TYPE_BYTE, PIPE_WAIT;
    import std.utf : toUTF16, toUTF16z;

    // druntime declares `CreateJobObjectW` only for `_WIN32_WINNT >= 0x500`
    // and omits `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; declare both here (see
    // the repo's "declare missing Win32 prototypes locally" rule).
    extern(Windows) HANDLE CreateJobObjectW(void*, const(wchar)*);
    enum DWORD JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    enum JOBOBJECTINFOCLASS JobObjectExtendedLimitInformation =
        cast(JOBOBJECTINFOCLASS) 9;
}

/// Current lifecycle of the encoder.
enum RecorderPhase : ubyte
{
    idle,
    starting,  ///< spawning ffmpeg / opening the capture surface
    recording,
    stopping,  ///< stdin closed, waiting for ffmpeg's MP4 trailer
    finished,  ///< the file is closed and playable
    failed
}

/** Everything needed to start one recording. */
struct RecordingJob
{
    string outputPath;
    CaptureRect rect;
    int fps;
    int quality;      ///< x264 CRF (lower is larger and sharper)
    bool drawCursor;  ///< capture through gdigrab so the pointer is included
    /**
     * gdigrab (cursor mode) ignores stdin, so ffmpeg stops itself after
     * `maxSeconds`. 0 means "use the default cap"; the worker stops earlier
     * when the user presses Stop.
     */
    double maxSeconds;
    string ffmpegPath;
    /**
     * Microphone to record, by its `dshow` friendly name. Empty records video
     * only.
     */
    string audioDevice;
    /**
     * Record what the speakers play (WASAPI loopback), captured by this app
     * and piped to ffmpeg's second input. `systemAudioRate`/`Channels` describe
     * that PCM (always float32).
     */
    bool systemAudio;
    uint systemAudioRate;
    uint systemAudioChannels;
}

/** Read-only view of a `RecorderStatus`, copied for the UI thread. */
struct StatusSnapshot
{
    RecorderPhase phase = RecorderPhase.idle;
    long frames;
    string outputPath;
    string error;

    bool active() const
    {
        return phase == RecorderPhase.starting ||
            phase == RecorderPhase.recording ||
            phase == RecorderPhase.stopping;
    }
}

/**
 * Snapshot of the recorder: written by the worker, read by the UI tick.
 *
 * A tiny seqlock rather than a mutex: the worker bumps `_sequence` before and
 * after every write, and readers retry while the counter is odd or changed.
 * Reads are rare (once per frame) and writes are small, so retries are
 * effectively never taken twice; no lock is held by the GUI thread and the
 * worker never touches a D object that needs cross-thread synchronisation.
 */
final class RecorderStatus
{
    private shared size_t _sequence;
    private RecorderPhase _phase = RecorderPhase.idle;
    private long _frames;
    private string _outputPath;
    private string _error;

    /// Fresh copy of the last consistent write.
    StatusSnapshot snapshot()
    {
        StatusSnapshot copy;
        while (true)
        {
            const before = atomicLoad!(MemoryOrder.acq)(_sequence);
            if (before & 1) continue;
            copy.phase = _phase;
            copy.frames = _frames;
            copy.outputPath = _outputPath;
            copy.error = _error;
            const after = atomicLoad!(MemoryOrder.acq)(_sequence);
            if (before == after) break;
        }
        return copy;
    }

    RecorderPhase phase() const { return _phase; }
    long frames() const { return _frames; }
    string outputPath() const { return _outputPath; }
    string error() const { return _error; }

    /// Worker-side write of the full snapshot.
    void set(RecorderPhase phase, long frames, string outputPath, string error)
    {
        bump();
        _phase = phase;
        _frames = frames;
        _outputPath = outputPath;
        _error = error;
        bump();
    }

    /// Worker-side frame counter update (the hot path).
    void setFrames(long frames)
    {
        bump();
        _frames = frames;
        bump();
    }

    /// Advance the seqlock counter; odd marks a write in progress.
    private void bump()
    {
        const next = atomicLoad!(MemoryOrder.raw)(_sequence) + 1;
        atomicStore!(MemoryOrder.rel)(_sequence, next);
    }

    /// True while a recording is starting, running or finalizing.
    bool active() const
    {
        return _phase == RecorderPhase.starting ||
            _phase == RecorderPhase.recording ||
            _phase == RecorderPhase.stopping;
    }
}

/**
 * ffmpeg arguments: raw BGRA frames on stdin, H.264 in MP4 on disk. Screen
 * text is best served by a fast preset and a moderately low CRF; `stillimage`
 * keeps large flat desktop regions from ringing around glyphs.
 */
string[] encoderArguments(RecordingJob job)
{
    string[] args = ["-hide_banner", "-loglevel", "warning", "-y"];
    // Raw BGRA frames on stdin, captured by this app's own thread (the cursor
    // is composited into them). stdin is the only input, so closing it is an
    // unambiguous "stop" that ffmpeg finalizes cleanly.
    args ~= [
        "-f", "rawvideo", "-pixel_format", "bgra",
        "-video_size", text(job.rect.width, "x", job.rect.height),
        "-framerate", text(job.fps),
        "-i", "pipe:0",
    ];
    // Microphone as a second input. Inputs must all precede output options:
    // ffmpeg reads `-c:v` after a second `-i` as that input's decoder.
    if (job.audioDevice.length > 0)
        args ~= ["-f", "dshow", "-i", "audio=" ~ job.audioDevice];
    // Screen sound: raw float32 PCM on a second pipe, captured by WASAPI
    // loopback in this process (ffmpeg's build has no WASAPI input).
    if (job.systemAudio)
    {
        args ~= [
            "-f", "f32le", "-ar", text(job.systemAudioRate),
            "-ac", text(job.systemAudioChannels), "-i", systemAudioUrl(),
        ];
    }

    // `-an` only when nothing supplies audio at all: it would also discard the
    // screen-sound stream below.
    if (job.audioDevice.length == 0 && !job.systemAudio)
        args ~= ["-an"]; // video only
    args ~= [
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "stillimage",
        "-crf", text(job.quality),
        "-pix_fmt", "yuv420p",
    ];
    // Microphone as a second input. `dshow` needs the friendly name exactly as
    // listed, and it must come after the video input so the mapping below is
    // unambiguous.
    if (job.audioDevice.length > 0)
    {
        args ~= [
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:a", "aac", "-b:a", "160k",
            // Stop waiting for audio when the video input ends.
            "-shortest",
        ];
    }
    else if (job.systemAudio)
    {
        args ~= [
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:a", "aac", "-b:a", "160k",
            "-shortest",
        ];
    }
    args ~= ["-movflags", "+faststart", job.outputPath];
    return args;
}

/**
 * Named pipe the screen-sound PCM is written to. A name (not an inherited
 * handle) is used because `pipe:N` numbering depends on the child's inherited
 * handle table, which the shell and other inherited handles can change.
 */
string systemAudioUrl()
{
    return r"\\.\pipe\aurora-video-recorder-audio";
}

/**
 * `exe arg arg ...` with every argument containing spaces or quotes wrapped
 * in double quotes. Trailing backslashes inside a quoted argument are
 * doubled so `CreateProcessW` does not eat the closing quote.
 */
string buildCommandLine(string executable, string[] args)
{
    auto parts = [quoteArgument(executable)];
    foreach (arg; args)
        parts ~= quoteArgument(arg);
    string result;
    foreach (i, part; parts)
    {
        if (i > 0) result ~= " ";
        result ~= part;
    }
    return result;
}

/// Quote one command-line argument for `CreateProcessW`.
string quoteArgument(string arg)
{
    if (arg.length == 0) return "\"\"";
    foreach (c; arg)
    {
        if (c != ' ' && c != '\t' && c != '"') continue;

        string quoted = "\"";
        size_t backslashes;
        foreach (c2; arg)
        {
            if (c2 == '\\')
            {
                backslashes++;
                continue;
            }
            if (c2 == '"')
            {
                // 2n+1 backslashes before an embedded quote.
                foreach (_; 0 .. backslashes * 2 + 1) quoted ~= '\\';
            }
            else
            {
                foreach (_; 0 .. backslashes) quoted ~= '\\';
            }
            quoted ~= c2;
            backslashes = 0;
        }
        // 2n backslashes before the closing quote.
        foreach (_; 0 .. backslashes * 2) quoted ~= '\\';
        return quoted ~ "\"";
    }
    return arg;
}

/**
 * Owns the worker thread and the ffmpeg child for one recording. Create,
 * `start()`, then `stop()` (or `abort()`) exactly once.
 */
final class ScreenEncoder
{
    private RecordingJob _job;
    private RecorderStatus _status = new RecorderStatus();
    private Thread _thread;
    // Cross-thread flags are `shared` so the worker and the GUI thread agree
    // on the memory model; each is written once, so no lock is needed.
    private shared bool _stopRequested;
    private shared bool _abortRequested;

    this(RecordingJob job)
    {
        _job = job;
        _status.set(RecorderPhase.idle, 0, _job.outputPath, "");
    }

    RecorderStatus status() { return _status; }

    RecordingJob job() const { return _job; }

    /// Start the worker thread. Must be called at most once.
    void start()
    {
        _status.set(RecorderPhase.starting, 0, _job.outputPath, "");
        _thread = new Thread(&workerMain).start();
    }

    /// Finish gracefully: the last frame is sent, then the MP4 is closed.
    void stop()
    {
        atomicStore!(MemoryOrder.rel)(_stopRequested, true);
    }

    /// Stop immediately. Frames captured before the worker notices are still
    /// written, so the file stays valid; a worker that has not started ffmpeg
    /// yet never creates one.
    void abort()
    {
        atomicStore!(MemoryOrder.rel)(_abortRequested, true);
        stop();
    }

    /// True once the worker has been asked to finish.
    bool stopRequested() const pure nothrow @safe
    {
        return atomicLoad!(MemoryOrder.acq)(_stopRequested);
    }

    /// True once the worker thread has exited (or never started).
    bool finished() { return _thread is null || !_thread.isRunning; }

    /// Wait up to `timeoutMs` for the worker (<= 0 waits forever).
    bool join(int timeoutMs)
    {
        if (_thread is null) return true;
        const deadline = MonoTime.currTime + msecs(timeoutMs);
        while (_thread.isRunning)
        {
            if (MonoTime.currTime > deadline) return false;
            Thread.sleep(dur!"msecs"(5));
        }
        return true;
    }

    private void workerMain()
    {
        try
        {
            run();
        }
        catch (Exception error)
        {
            _status.set(RecorderPhase.failed, _status.snapshot.frames, _job.outputPath,
                "Recording failed: " ~ error.msg);
        }
    }

    private void run()
    {
        if (_job.ffmpegPath.length == 0)
        {
            fail("ffmpeg.exe was not found. Install FFmpeg or set " ~
                "AURORA_RECORDER_FFMPEG to its path.");
            return;
        }
        version (Windows)
            runWindows();
        else
            fail("Screen recording is implemented on Windows only.");
    }

    private void fail(string message)
    {
        _status.set(RecorderPhase.failed, _status.snapshot.frames, _job.outputPath,
            message);
    }

    version (Windows)
    {
        /// One recording: spawn, capture, finalize.
        private void runWindows()
        {
            HANDLE job = CreateJobObjectW(null, null);
            if (job !is null)
            {
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
                limits.BasicLimitInformation.LimitFlags =
                    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                    &limits, JOBOBJECT_EXTENDED_LIMIT_INFORMATION.sizeof);
            }

            auto surface = new ScreenSurface();
            if (!surface.open(_job.rect))
            {
                if (job !is null) CloseHandle(job);
                fail(text("Could not capture the screen region ",
                    _job.rect.width, "x", _job.rect.height, "."));
                return;
            }
            surface.setDrawCursor(_job.drawCursor);

            // Screen sound is captured here; ffmpeg's build has no WASAPI
            // input, and a machine may expose no Stereo Mix device either.
            SystemAudioCapture audio;
            if (_job.systemAudio)
            {
                audio = new SystemAudioCapture();
                if (!audio.start())
                {
                    // Sound is a convenience: record silently rather than
                    // failing the whole recording.
                    audio = null;
                }
                else
                {
                    // The device decides its own rate/channel layout; the
                    // ffmpeg input must describe exactly what it will receive.
                    _job.systemAudioRate = audio.format().sampleRate;
                    _job.systemAudioChannels = audio.format().channels;
                }
            }
            scope (exit) if (audio !is null) audio.shutdown();

            HANDLE logHandle = openLog(_job.outputPath ~ ".log");
            HANDLE writeEnd;
            HANDLE audioWriteEnd;
            PROCESS_INFORMATION process;
            const started = createProcess(_job.ffmpegPath,
                // Arguments are built after the device reported its format.
                buildCommandLine(_job.ffmpegPath, encoderArguments(_job)),
                logHandle, process, writeEnd, audioWriteEnd, audio !is null);
            closeHandle(logHandle);
            if (!started)
            {
                if (job !is null) CloseHandle(job);
                surface.close();
                fail(text("Could not start ffmpeg.exe at ",
                    _job.ffmpegPath, "."));
                return;
            }
            if (job !is null)
            {
                AssignProcessToJobObject(job, process.hProcess);
                // Closing the last job handle now would terminate the child,
                // so the job handle lives until the process exits.
            }

            const cancelled = atomicLoad!(MemoryOrder.acq)(_abortRequested);
            if (!cancelled)
                _status.set(RecorderPhase.recording, 0, _job.outputPath, "");

            long frames;
            string writeError;
            // Screen sound runs on its own writer thread so the frame cadence
            // above never waits for the audio pipe.
            shared bool stopAudio;
            Thread audioThread;
            if (audio !is null && audioWriteEnd !is null)
            {
                HANDLE audioHandle = audioWriteEnd;
                audioWriteEnd = null; // owned by the thread from here
                audioThread = new Thread({ audioLoop(audio, audioHandle,
                    stopAudio); });
                audioThread.isDaemon = true;
                audioThread.start();
            }
            if (!cancelled)
                recordLoop(surface, writeEnd, frames, writeError);

            // End the audio stream before closing video stdin so ffmpeg keeps
            // the tail of the sound with `-shortest`.
            atomicStore!(MemoryOrder.rel)(stopAudio, true);
            if (audio !is null) audio.requestStop();
            if (audioThread !is null) audioThread.join();

            // Closing stdin makes ffmpeg flush the last frames and write the
            // MP4 trailer; only then is the file playable.
            CloseHandle(writeEnd);
            _status.set(RecorderPhase.stopping, frames, _job.outputPath, "");
            WaitForSingleObject(process.hProcess, INFINITE);
            surface.close();
            CloseHandle(process.hProcess);
            if (job !is null) CloseHandle(job);

            if (cancelled)
                _status.set(RecorderPhase.failed, frames, _job.outputPath,
                    "Recording was cancelled.");
            else if (writeError.length > 0)
                _status.set(RecorderPhase.failed, frames, _job.outputPath,
                    writeError);
            else
                _status.set(RecorderPhase.finished, frames, _job.outputPath,
                    "");
        }

        /**
         * Forward captured PCM to ffmpeg on its own thread.
         *
         * The video loop must keep its frame cadence, so it cannot also block
         * on the audio pipe: a drain here is timed independently and blocks
         * only this thread.
         */
        private static void audioLoop(SystemAudioCapture audio, HANDLE audioEnd,
            ref shared bool stopAudio)
        {
            scope (exit) if (audioEnd !is null) CloseHandle(audioEnd);
            // The pipe was created overlapped, so a client that has not
            // connected yet makes WriteFile return ERROR_IO_PENDING instead of
            // blocking: retry until ffmpeg is listening.
            bool connected;
            while (!atomicLoad!(MemoryOrder.acq)(stopAudio))
            {
                auto pcm = audio.take();
                if (!connected)
                {
                    if (ConnectNamedPipe(audioEnd, null) != FALSE ||
                        GetLastError() == ERROR_PIPE_CONNECTED)
                        connected = true;
                    else if (GetLastError() == ERROR_PIPE_CONNECTED)
                        connected = true;
                    Thread.sleep(dur!"msecs"(20));
                    continue;
                }
                if (pcm.length > 0)
                {
                    if (!writeFrame(audioEnd, pcm.ptr, pcm.length)) return;
                }
                else
                    Thread.sleep(dur!"msecs"(5));
            }
            // Flush what the device produced before the stop request.
            auto tail = audio.take();
            if (tail.length > 0) writeFrame(audioEnd, tail.ptr, tail.length);
        }

        /// Pace, capture and write frames until `stop()`.
        private void recordLoop(ScreenSurface surface, HANDLE writeEnd,
            ref long frames, ref string writeError)
        {
            const long frameIntervalNs = 1_000_000_000L / _job.fps;
            const size_t frameBytes = surface.frameBytes();
            frames = 0;
            writeError = "";

            const started = MonoTime.currTime;
            for (long index = 0; !stopRequested(); index++)
            {
                if (index > 0)
                {
                    const next = started +
                        dur!"nsecs"(index * frameIntervalNs);
                    const now = MonoTime.currTime;
                    if (next > now) Thread.sleep(next - now);
                }

                if (!surface.captureInto())
                    continue; // A skipped frame is never fatal.
                if (!writeFrame(writeEnd, surface.pixels(), frameBytes))
                {
                    writeError = "ffmpeg stopped accepting frames; the " ~
                        "file was closed early (see the .log file).";
                    break;
                }
                frames++;
                _status.setFrames(frames);
            }
        }

        /// Write one frame to ffmpeg's stdin; false when the pipe closed.
        private static bool writeFrame(HANDLE stdinHandle, const void* pixels,
            size_t bytes)
        {
            auto cursor = cast(const(ubyte)*) pixels;
            size_t remaining = bytes;
            while (remaining > 0)
            {
                // A pipe accepts at most 64 KiB per call; slice anyway so the
                // length always fits the DWORD the API expects.
                const uint slice = remaining > 1 << 20 ?
                    1 << 20 : cast(uint) remaining;
                DWORD written;
                const ok = WriteFile(stdinHandle, cursor, slice, &written, null);
                if (ok == FALSE || written == 0)
                    return false;
                cursor = cursor + written;
                remaining -= written;
            }
            return true;
        }

        /// Append handle for `<output>.log`, inheritable by the child only.
        private static HANDLE openLog(string logPath)
        {
            SECURITY_ATTRIBUTES security;
            security.nLength = SECURITY_ATTRIBUTES.sizeof;
            security.lpSecurityDescriptor = null;
            security.bInheritHandle = TRUE;
            return CreateFileW(toUTF16z(logPath), FILE_APPEND_DATA,
                FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_ALWAYS, 0,
                null);
        }

        private static void closeHandle(HANDLE handle)
        {
            if (handle !is null && cast(size_t) handle != cast(size_t) -1)
                CloseHandle(handle);
        }

        /**
         * Spawn ffmpeg with an inheritable stdin pipe and a hidden console.
         * The executable is passed explicitly in `applicationName`; deriving
         * it from a quoted command line makes `CreateProcessW` fail when the
         * first argument contains spaces.
         */
        private static bool createProcess(string applicationName,
            string commandLine, HANDLE logHandle, ref PROCESS_INFORMATION process,
            ref HANDLE writeEnd, ref HANDLE audioWriteEnd, bool audioRequested)
        {
            writeEnd = null;
            audioWriteEnd = null;
            process = PROCESS_INFORMATION.init;

            SECURITY_ATTRIBUTES security;
            security.nLength = SECURITY_ATTRIBUTES.sizeof;
            security.lpSecurityDescriptor = null;
            security.bInheritHandle = TRUE;

            HANDLE readEnd;
            if (CreatePipe(&readEnd, &writeEnd, &security, 0) == FALSE)
                return false;
            // The parent's write end must not leak into the child, or the
            // child would never see EOF after the recorder closes stdin.
            SetHandleInformation(writeEnd, HANDLE_FLAG_INHERIT, 0);

            // Optional screen-sound pipe, as a named pipe server this process
            // writes and ffmpeg reads by URL.
            audioWriteEnd = createAudioPipe(audioRequested);
            if (audioRequested && audioWriteEnd is null)
            {
                CloseHandle(readEnd);
                CloseHandle(writeEnd);
                writeEnd = null;
                return false;
            }

            STARTUPINFOW startup = STARTUPINFOW.init;
            startup.cb = STARTUPINFOW.sizeof;
            startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
            startup.wShowWindow = SW_HIDE;
            startup.hStdInput = readEnd;
            startup.hStdOutput = logHandle is null ? null : logHandle;
            startup.hStdError = logHandle is null ? null : logHandle;

            // Encode both strings up front and keep the arrays alive for the
            // whole call. `toUTF16z` returns a pointer into a temporary GC
            // buffer whose lifetime ends with the statement, so encoding two
            // strings inside one argument list can reuse that buffer and
            // corrupt one of them. `CreateProcessW` may write to its command
            // line buffer, so that one is a mutable copy.
            wchar[] applicationW = toUTF16(applicationName).dup;
            applicationW ~= '\0';
            wchar[] commandLineW = toUTF16(commandLine).dup;
            commandLineW ~= '\0';
            const started = CreateProcessW(applicationW.ptr,
                commandLineW.ptr, null, null, TRUE,
                CREATE_NO_WINDOW, null, null, &startup, &process);
            CloseHandle(readEnd);
            // ffmpeg opens the audio pipe while it starts up. The server must
            // have a client before any PCM is written, so connect here (the
            // call blocks until ffmpeg's open arrives) and give up rather
            // than hang if it never does.
            // The audio pipe is connected lazily by the writer thread, so
            // nothing here can deadlock against ffmpeg's own startup.
            if (started == FALSE)
            {
                CloseHandle(writeEnd);
                writeEnd = null;
                if (audioWriteEnd !is null)
                {
                    CloseHandle(audioWriteEnd);
                    audioWriteEnd = null;
                }
                return false;
            }
            CloseHandle(process.hThread);
            return true;
        }

        /**
         * Create the named-pipe server for screen sound. The caller connects
         * it once ffmpeg is running.
         */
        private static HANDLE createAudioPipe(bool requested)
        {
            if (!requested) return null;
            // FILE_FLAG_OVERLAPPED so connecting never blocks: ffmpeg opens the
            // pipe only once it starts reading, which happens after this call.
            HANDLE pipe = CreateNamedPipeW(toUTF16z(systemAudioUrl()),
                PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
                4 * 1024 * 1024, 4 * 1024 * 1024, 0, null);
            return pipe == INVALID_HANDLE_VALUE ? null : pipe;
        }
    }
}

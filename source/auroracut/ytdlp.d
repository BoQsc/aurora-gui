module auroracut.ytdlp;

import auroracut.util : absoluteNormalized, applicationStateDirectory,
    isSupportedMediaPath, outputTail;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.file : DirEntry, SpanMode, dirEntries, exists, mkdirRecurse,
    remove, rename, thisExePath;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.process : Config, Pid, Redirect, execute, kill, pipeProcess, wait;
import std.stdio : File;
import std.string : indexOf, startsWith, strip;
import std.uuid : randomUUID;

version (Windows)
{
    import core.sys.windows.windef : DWORD;
    import core.sys.windows.wininet : HINTERNET, INTERNET_FLAG_NO_CACHE_WRITE,
        INTERNET_FLAG_PRAGMA_NOCACHE, INTERNET_FLAG_RELOAD,
        INTERNET_OPEN_TYPE_PRECONFIG, InternetCloseHandle, InternetOpenUrlW,
        InternetOpenW, InternetReadFile;
    import std.utf : toUTF16z;
}

private enum string ytDlpOfficialWindowsExecutableUrl =
    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";

string ytDlpAddonDirectory()
{
    const root = buildPath(applicationStateDirectory(), "Tools", "yt-dlp");
    if (!exists(root)) mkdirRecurse(root);
    return absoluteNormalized(root);
}

string ytDlpAddonExecutablePath()
{
    return buildPath(ytDlpAddonDirectory(), "yt-dlp.exe");
}

bool ytDlpCommandWorks(string command)
{
    try
    {
        const result = execute([command, "--version"], null,
            Config.suppressConsole, 1024 * 1024);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

string detectYtDlpCommand()
{
    string[] candidates;
    version (Windows)
    {
        try
        {
            const executableDirectory = dirName(thisExePath());
            if (executableDirectory.length > 0)
            {
                candidates ~= buildPath(executableDirectory, "yt-dlp.exe");
                candidates ~= buildPath(executableDirectory, "bin", "yt-dlp.exe");
            }
        }
        catch (Exception)
        {
        }
        candidates ~= ytDlpAddonExecutablePath();
    }
    candidates ~= "yt-dlp.exe";
    candidates ~= "yt-dlp";

    foreach (candidate; candidates)
        if (ytDlpCommandWorks(candidate)) return candidate;
    return "";
}

enum YtDlpDownloadKind : ubyte
{
    video,
    audio
}

struct YtDlpDownloadRequest
{
    string command;
    string url;
    YtDlpDownloadKind kind;
    int maxHeight = 1080;
}

struct YtDlpDownloadResult
{
    string url;
    string path;
    string error;
    YtDlpDownloadKind kind;

    bool success() const @safe pure nothrow @nogc
    {
        return path.length > 0 && error.length == 0;
    }
}

/** Streamed progress for one active yt-dlp download. */
struct YtDlpDownloadProgress
{
    string url;
    double fraction;    /// 0.0 .. 1.0
    string label;       /// e.g. "Download 45.6%", "Processing…", "Normalizing 12%"
}

struct YtDlpDownloadStats
{
    ulong queued;
    ulong processesStarted;
    ulong completed;
    ulong failed;
    ulong cancelled;
}

struct YtDlpInstallResult
{
    string path;
    string error;

    bool success() const @safe pure nothrow @nogc
    {
        return path.length > 0 && error.length == 0;
    }
}

final class YtDlpInstallService
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private bool _requested;
    private bool _busy;
    private bool _shutdown;
    private YtDlpInstallResult[] _ready;
    private size_t _readyHead;
    version (Windows)
    {
        private HINTERNET _internetSession;
        private HINTERNET _internetRequest;
    }

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    bool install()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_shutdown) return false;
        _requested = true;
        _condition.notify();
        return true;
    }

    bool takeReady(out YtDlpInstallResult result)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_readyHead >= _ready.length) return false;
        result = _ready[_readyHead++];
        if (_readyHead >= _ready.length)
        {
            _ready.length = 0;
            _readyHead = 0;
        }
        return true;
    }

    bool busy()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _busy || _requested;
    }

    void shutdown()
    {
        version (Windows)
        {
            HINTERNET request;
            HINTERNET session;
        }
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            _requested = false;
            _ready.length = 0;
            _readyHead = 0;
            _condition.notifyAll();
        }
        version (Windows)
        {
            request = _internetRequest;
            session = _internetSession;
            _internetRequest = null;
            _internetSession = null;
        }
        _mutex.unlock();

        version (Windows)
        {
            if (request !is null)
            {
                try InternetCloseHandle(request);
                catch (Exception) {}
            }
            if (session !is null)
            {
                try InternetCloseHandle(session);
                catch (Exception) {}
            }
        }

        if (_worker !is null)
        {
            try _worker.join();
            catch (Exception) {}
        }
    }

    private void workerLoop()
    {
        while (true)
        {
            _mutex.lock();
            while (!_shutdown && !_requested)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            _requested = false;
            _busy = true;
            _mutex.unlock();

            auto result = installOne();

            _mutex.lock();
            _busy = false;
            if (!_shutdown)
                _ready ~= result;
            _mutex.unlock();
        }
    }

    private YtDlpInstallResult installOne()
    {
        YtDlpInstallResult result;
        const target = ytDlpAddonExecutablePath();

        try
        {
            if (ytDlpCommandWorks(target))
            {
                result.path = target;
                return result;
            }

            const temporary = target ~ ".download";
            if (exists(temporary)) remove(temporary);
            downloadOfficialExecutable(temporary);

            if (!ytDlpCommandWorks(temporary))
                throw new Exception("Downloaded yt-dlp.exe could not be executed.");

            if (exists(target)) remove(target);
            rename(temporary, target);
            result.path = target;
        }
        catch (Exception error)
        {
            result.path = "";
            result.error = outputTail(error.msg, 1_000);
        }

        return result;
    }

    private void downloadOfficialExecutable(string destination)
    {
        version (Windows)
        {
            auto session = InternetOpenW(toUTF16z("Aurora Cut yt-dlp add-on"),
                INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
            if (session is null)
                throw new Exception("Windows could not open an internet session.");

            _mutex.lock();
            _internetSession = session;
            _mutex.unlock();

            scope (exit)
            {
                bool closeSession;
                _mutex.lock();
                if (_internetSession is session)
                {
                    _internetSession = null;
                    closeSession = true;
                }
                _mutex.unlock();
                if (closeSession) InternetCloseHandle(session);
            }

            const flags = INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE |
                INTERNET_FLAG_PRAGMA_NOCACHE;
            auto request = InternetOpenUrlW(session,
                toUTF16z(ytDlpOfficialWindowsExecutableUrl), null, 0, flags, 0);
            if (request is null)
                throw new Exception("Windows could not open the yt-dlp release download URL.");

            _mutex.lock();
            _internetRequest = request;
            _mutex.unlock();

            scope (exit)
            {
                bool closeRequest;
                _mutex.lock();
                if (_internetRequest is request)
                {
                    _internetRequest = null;
                    closeRequest = true;
                }
                _mutex.unlock();
                if (closeRequest) InternetCloseHandle(request);
            }

            auto file = File(destination, "wb");
            ubyte[64 * 1024] buffer;
            while (true)
            {
                DWORD readBytes;
                if (!InternetReadFile(request, buffer.ptr,
                    cast(DWORD) buffer.length, &readBytes))
                    throw new Exception("Windows failed while reading yt-dlp.exe.");
                if (readBytes == 0) break;
                file.rawWrite(buffer[0 .. cast(size_t) readBytes]);
            }
        }
        else
        {
            throw new Exception("Automatic yt-dlp add-on install is currently implemented for Windows only.");
        }
    }
}

string ytDlpImportDirectory()
{
    const root = buildPath(applicationStateDirectory(), "Downloads");
    if (!exists(root)) mkdirRecurse(root);
    return absoluteNormalized(root);
}

private bool startsWithText(string value, string prefix)
{
    return value.length >= prefix.length && value[0 .. prefix.length] == prefix;
}

private string downloadedPathForPrefix(string directory, string prefix)
{
    foreach (DirEntry entry; dirEntries(directory, SpanMode.shallow))
    {
        bool directoryEntry;
        try directoryEntry = entry.isDir;
        catch (Exception) continue;
        if (directoryEntry) continue;

        const name = baseName(entry.name);
        if (!startsWithText(name, prefix ~ ".")) continue;
        if (!isSupportedMediaPath(entry.name)) continue;
        return absoluteNormalized(entry.name);
    }
    return "";
}

private string[] downloadArguments(YtDlpDownloadRequest request,
    string directory, string prefix)
{
    const outputTemplate = buildPath(directory, prefix ~ ".%(ext)s");
    string[] arguments = [
        request.command,
        "--no-playlist",
        "--newline",
        "--restrict-filenames",
        "-o", outputTemplate
    ];

    final switch (request.kind)
    {
        case YtDlpDownloadKind.video:
            arguments ~= [
                "-f", ytDlpVideoFormatForHeight(request.maxHeight),
                "--format-sort", ytDlpVideoSortForHeight(request.maxHeight),
                "--format-sort-force",
                "--merge-output-format", "mp4"
            ];
            break;
        case YtDlpDownloadKind.audio:
            arguments ~= [
                "--extract-audio",
                "--audio-format", "mp3"
            ];
            break;
    }

    arguments ~= request.url;
    return arguments;
}

/**
 * Parse a yt-dlp progress line such as
 * `[download]  45.6% of 12.34MiB at 1.23MiB/s ETA 00:05`
 * into a 0..1 fraction. Returns false for non-progress lines.
 */
private bool parseDownloadPercent(string line, out double fraction)
{
    fraction = 0.0;
    if (!startsWith(line, "[download]")) return false;
    const percentIndex = indexOf(line, '%');
    if (percentIndex < 0) return false;
    // Skip the "[download]" prefix and any leading spaces before the number.
    const numberText = line[10 .. cast(size_t) percentIndex].strip();
    if (numberText.length == 0) return false;
    double percent;
    try percent = to!double(numberText);
    catch (Exception) return false;
    if (percent < 0.0) return false;
    percent = percent > 100.0 ? 100.0 : percent;
    fraction = percent / 100.0;
    return true;
}

/** Keep video downloads within a predictable preview-friendly ceiling. */
int normalizeYtDlpMaxHeight(int value)
{
    switch (value)
    {
        case 240:
        case 360:
        case 480:
        case 720:
        case 1080:
            return value;
        default:
            return 1080;
    }
}

int ytDlpMaxWidthForHeight(int maxHeight)
{
    final switch (normalizeYtDlpMaxHeight(maxHeight))
    {
        case 240: return 426;
        case 360: return 640;
        case 480: return 854;
        case 720: return 1280;
        case 1080: return 1920;
    }
}

/** Prefer editor-friendly 16:9 media at the selected preview ceiling. */
string ytDlpVideoSortForHeight(int maxHeight)
{
    const height = normalizeYtDlpMaxHeight(maxHeight);
    const width = ytDlpMaxWidthForHeight(height);
    return format("res:%d,width:%d,fps,vcodec:h264,acodec:m4a,ext:mp4:m4a",
        height, width);
}

/** Select exact 16:9 first, then the best video/audio within the selected box. */
string ytDlpVideoFormatForHeight(int maxHeight)
{
    const height = normalizeYtDlpMaxHeight(maxHeight);
    const width = ytDlpMaxWidthForHeight(height);
    return format("bv*[height=%d][width=%d]+ba/b[height=%d][width=%d]/" ~
        "bv*[height<=%d][width<=%d]+ba/b[height<=%d][width<=%d]",
        height, width, height, width, height, width, height, width);
}

string ytDlpVideoNormalizeFilterForHeight(int maxHeight)
{
    const height = normalizeYtDlpMaxHeight(maxHeight);
    const width = ytDlpMaxWidthForHeight(height);
    return format("scale=w='min(%d,iw)':h='min(%d,ih)':" ~
        "force_original_aspect_ratio=decrease:force_divisible_by=2:" ~
        "flags=fast_bilinear,setsar=1,fps=30,format=yuv420p",
        width, height);
}

string[] ytDlpNormalizedVideoArguments(string inputPath, string outputPath,
    int maxHeight)
{
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i", inputPath, "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", ytDlpVideoNormalizeFilterForHeight(maxHeight),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-g", "15", "-keyint_min", "15", "-sc_threshold", "0",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", outputPath
    ];
}

private void runCaptured(string[] arguments, string description)
{
    const result = execute(arguments, null, Config.suppressConsole,
        16 * 1024 * 1024);
    if (result.status != 0)
        throw new Exception(format("%s failed with exit code %d.%s%s",
            description, result.status, result.output.length > 0 ? "\n" : "",
            outputTail(result.output, 16 * 1024)));
}

private void probeDurationSeconds(string path, out double seconds)
{
    seconds = 0.0;
    try
    {
        const result = execute([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "csv=p=0", path
        ], null, Config.suppressConsole, 1024 * 1024);
        if (result.status == 0)
        {
            const text = result.output.strip();
            if (text.length > 0) seconds = to!double(text);
        }
    }
    catch (Exception) {}
}

/**
 * Run the normalization FFmpeg encode while streaming its `-progress`
 * output, reporting "Normalizing NN%" against the source duration so the
 * long re-encode phase never sits at a false 100%.
 */
private void runNormalizeCaptured(string[] baseArguments, string description,
    double durationSeconds, void delegate(double fraction, string label) onProgress)
{
    // ffmpeg -hide_banner -loglevel error -nostdin -y  then progress options.
    string[] arguments;
    arguments ~= baseArguments[0 .. 6];
    arguments ~= ["-progress", "pipe:1", "-nostats"];
    arguments ~= baseArguments[6 .. $];

    auto pipes = pipeProcess(arguments, Redirect.stdout | Redirect.stderrToStdout,
        cast(const string[string]) null, Config.suppressConsole);
    string output;
    int lastPercent = -1;
    try
    {
        foreach (rawLine; pipes.stdout.byLine())
        {
            const line = cast(string) rawLine;
            output ~= line;
            output ~= "\n";
            if (output.length > 4 * 1024 * 1024)
                output = outputTail(output, 512 * 1024);

            if (durationSeconds > 0 && onProgress !is null &&
                (startsWith(line, "out_time_us=") || startsWith(line, "out_time_ms=")))
            {
                const equals = indexOf(line, '=');
                if (equals >= 0)
                {
                    long micros;
                    try micros = to!long(line[cast(size_t) equals + 1 .. $].strip());
                    catch (Exception) micros = 0;
                    double fraction = micros / (durationSeconds * 1_000_000.0);
                    if (fraction < 0.0) fraction = 0.0;
                    else if (fraction > 1.0) fraction = 1.0;
                    const percent = cast(int) (fraction * 100.0 + 0.5);
                    if (percent != lastPercent)
                    {
                        lastPercent = percent;
                        onProgress(fraction, format("Normalizing %d%%", percent));
                    }
                }
            }
        }
    }
    catch (Exception) {}

    int status;
    try status = wait(pipes.pid);
    catch (Exception error)
    {
        throw new Exception(description ~ " could not wait: " ~ error.msg);
    }
    if (status != 0)
        throw new Exception(format("%s failed with exit code %d.%s%s",
            description, status, output.length > 0 ? "\n" : "",
            outputTail(output, 16 * 1024)));
    if (onProgress !is null && durationSeconds > 0)
        onProgress(1.0, "Normalizing 100%");
}

private string normalizeDownloadedVideo(string sourcePath, string directory,
    string prefix, int maxHeight,
    void delegate(double fraction, string label) onProgress = null)
{
    const target = buildPath(directory, prefix ~ ".normalized.mp4");
    const temporary = target ~ ".partial.mp4";
    if (exists(temporary)) remove(temporary);
    if (exists(target)) remove(target);

    double durationSeconds;
    probeDurationSeconds(sourcePath, durationSeconds);
    runNormalizeCaptured(ytDlpNormalizedVideoArguments(sourcePath, temporary,
        maxHeight), "Normalize yt-dlp video", durationSeconds, onProgress);
    if (!exists(temporary))
        throw new Exception("FFmpeg finished but did not create the normalized MP4.");
    rename(temporary, target);
    try if (exists(sourcePath)) remove(sourcePath);
    catch (Exception) {}
    return absoluteNormalized(target);
}

final class YtDlpDownloadService
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private YtDlpDownloadRequest[] _queue;
    private size_t _head;
    private YtDlpDownloadResult[] _ready;
    private size_t _readyHead;
    private YtDlpDownloadProgress[] _progressQueue;
    private size_t _progressHead;
    private Pid _process;
    private bool _busy;
    private bool _shutdown;
    private YtDlpDownloadStats _stats;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    bool enqueue(string command, string url, YtDlpDownloadKind kind,
        int maxHeight = 1080)
    {
        if (command.length == 0 || url.length == 0) return false;

        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_shutdown) return false;

        YtDlpDownloadRequest request;
        request.command = command.idup;
        request.url = url.idup;
        request.kind = kind;
        request.maxHeight = normalizeYtDlpMaxHeight(maxHeight);
        _queue ~= request;
        ++_stats.queued;
        _condition.notify();
        return true;
    }

    bool takeReady(out YtDlpDownloadResult result)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_readyHead >= _ready.length) return false;
        result = _ready[_readyHead++];
        if (_readyHead >= _ready.length)
        {
            _ready.length = 0;
            _readyHead = 0;
        }
        return true;
    }

    /** Drain the latest streamed download progress samples. */
    bool takeProgress(out YtDlpDownloadProgress progress)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_progressHead >= _progressQueue.length) return false;
        progress = _progressQueue[_progressHead++];
        if (_progressHead >= _progressQueue.length)
        {
            _progressQueue.length = 0;
            _progressHead = 0;
        }
        return true;
    }

    bool busy()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _busy || _head < _queue.length;
    }

    size_t pendingCount()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return (_head < _queue.length ? _queue.length - _head : 0) +
            (_busy ? 1 : 0);
    }

    YtDlpDownloadStats stats()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _stats;
    }

    void shutdown()
    {
        Pid process;
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            _queue.length = 0;
            _head = 0;
            _ready.length = 0;
            _readyHead = 0;
            process = _process;
            if (process !is null) ++_stats.cancelled;
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

    private void workerLoop()
    {
        while (true)
        {
            YtDlpDownloadRequest request;
            _mutex.lock();
            while (!_shutdown && _head >= _queue.length)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            request = _queue[_head++];
            if (_head >= _queue.length)
            {
                _queue.length = 0;
                _head = 0;
            }
            _busy = true;
            _mutex.unlock();

            auto result = downloadOne(request);

            _mutex.lock();
            _busy = false;
            if (!_shutdown)
            {
                _ready ~= result;
                if (result.success()) ++_stats.completed;
                else ++_stats.failed;
            }
            _mutex.unlock();
        }
    }

    private YtDlpDownloadResult downloadOne(YtDlpDownloadRequest request)
    {
        YtDlpDownloadResult result;
        result.url = request.url;
        result.kind = request.kind;

        try
        {
            const directory = ytDlpImportDirectory();
            const prefix = "aurora-" ~ randomUUID().toString();
            const arguments = downloadArguments(request, directory, prefix);
            auto pipes = pipeProcess(arguments,
                Redirect.stdout | Redirect.stderrToStdout,
                cast(const string[string]) null, Config.suppressConsole);

            bool cancelNow;
            _mutex.lock();
            _process = pipes.pid;
            cancelNow = _shutdown;
            if (!cancelNow) ++_stats.processesStarted;
            _mutex.unlock();
            if (cancelNow)
            {
                try kill(pipes.pid);
                catch (Exception) {}
            }

            string output;
            size_t downloadedFiles;
            size_t completedFiles;
            bool downloadPhaseDone;
            try
            {
                void pushProgress(string label, double fraction)
                {
                    YtDlpDownloadProgress progress;
                    progress.url = request.url;
                    progress.fraction = fraction;
                    progress.label = label;
                    _mutex.lock();
                    if (!_shutdown) _progressQueue ~= progress;
                    _mutex.unlock();
                }

                foreach (rawLine; pipes.stdout.byLine())
                {
                    const line = cast(string) rawLine;
                    output ~= line;
                    output ~= "\n";
                    if (output.length > 4 * 1024 * 1024)
                        output = outputTail(output, 512 * 1024);

                    if (startsWith(line, "[download] Destination:"))
                        ++downloadedFiles;

                    double fraction;
                    if (parseDownloadPercent(line, fraction))
                    {
                        pushProgress(
                            format("Download %.1f%%", fraction * 100.0),
                            fraction);
                        if (fraction >= 1.0) ++completedFiles;
                    }

                    // With --no-playlist each selected format produces its own
                    // [download] run; only after every file reaches 100% is the
                    // yt-dlp download phase over and post-processing begins.
                    if (downloadedFiles > 0 && completedFiles >= downloadedFiles &&
                        !downloadPhaseDone)
                    {
                        downloadPhaseDone = true;
                        pushProgress("Processing…", 1.0);
                    }
                }
            }
            catch (Exception error)
            {
                if (!_shutdown) result.error = error.msg;
            }

            int status;
            try status = wait(pipes.pid);
            catch (Exception error)
            {
                if (!_shutdown && result.error.length == 0)
                    result.error = error.msg;
            }
            _mutex.lock();
            if (_process is pipes.pid) _process = null;
            const cancelled = _shutdown;
            _mutex.unlock();
            if (cancelled) return result;

            if (status != 0)
                throw new Exception(format("yt-dlp failed with exit code %d.%s%s",
                    status, output.length > 0 ? "\n" : "",
                    outputTail(output, 16 * 1024)));
            if (result.error.length > 0) throw new Exception(result.error);

            result.path = downloadedPathForPrefix(directory, prefix);
            if (result.path.length == 0)
                throw new Exception("yt-dlp finished but did not produce an Aurora-supported media file.");
            if (request.kind == YtDlpDownloadKind.video)
            {
                result.path = normalizeDownloadedVideo(result.path, directory,
                    prefix, request.maxHeight,
                    delegate(double fraction, string label)
                    {
                        YtDlpDownloadProgress progress;
                        progress.url = request.url;
                        progress.fraction = fraction;
                        progress.label = label;
                        _mutex.lock();
                        if (!_shutdown) _progressQueue ~= progress;
                        _mutex.unlock();
                    });
            }
        }
        catch (Exception error)
        {
            result.path = "";
            result.error = outputTail(error.msg, 1_000);
        }

        return result;
    }
}

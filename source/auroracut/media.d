module auroracut.media;

import auroracut.model : MediaAsset;
import auroracut.util : absoluteNormalized, commandAvailable, createWorkspace,
    formatTimecode, isSupportedMediaPath, outputTail, removePathQuietly,
    runChecked;
import auroracut.ytdlp : detectYtDlpCommand;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.file : exists, isDir;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Config, Pid, Redirect, execute, kill, pipeProcess, wait;
import std.string : indexOf, strip;

struct ToolStatus
{
    bool ffmpeg;
    bool ffprobe;
    bool ytDlp;
    string ytDlpCommand;
    string h264Encoder = "libx264";
    string videoAcceleration = "CPU (libx264)";
    bool hardwareVideoEncoding;
    string videoDecodeAcceleration = "CPU decode";
    string[] videoDecodeInputOptions;
    bool hardwareVideoDecoding;

    bool editingReady() const { return ffmpeg && ffprobe; }
}

private string nullVideoOutputPath()
{
    version (Windows)
        return "NUL";
    else
        return "/dev/null";
}

private bool commandWorks(const string[] arguments, size_t maximumOutput = 2 * 1024 * 1024)
{
    try
    {
        const result = execute(arguments, null, Config.suppressConsole,
            maximumOutput);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

/**
 * Verify a hardware encoder with a tiny real encode rather than trusting only
 * FFmpeg's compiled encoder list. This prevents Aurora Cut from selecting an
 * encoder that exists in the build but has no usable device/driver.
 */
private bool encoderWorks(string encoder)
{
    return commandWorks([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "lavfi", "-i", "color=c=black:s=64x64:r=1",
        "-frames:v", "1", "-an", "-c:v", encoder,
        "-f", "null", "-"
    ]);
}

private void selectVideoAcceleration(ref ToolStatus result)
{
    if (!result.ffmpeg) return;

    // Prefer the encoder matching the user's likely discrete GPU, then the
    // integrated-GPU and AMD paths. Each candidate is actually exercised.
    foreach (candidate; [
        ["h264_nvenc", "NVIDIA NVENC"],
        ["h264_qsv", "Intel Quick Sync"],
        ["h264_amf", "AMD AMF"]
    ])
    {
        if (!encoderWorks(candidate[0])) continue;
        result.h264Encoder = candidate[0];
        result.videoAcceleration = candidate[1];
        result.hardwareVideoEncoding = true;
        return;
    }
}

private bool writeDecodeProbeSample(string path)
{
    return commandWorks([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-f", "lavfi", "-i", "testsrc2=s=96x54:r=1:d=0.25",
        "-frames:v", "1", "-an", "-c:v", "libx264",
        "-pix_fmt", "yuv420p", path
    ], 4 * 1024 * 1024) && exists(path);
}

private bool decoderWorks(string accelerator, string samplePath)
{
    if (accelerator.length == 0 || samplePath.length == 0) return false;
    return commandWorks([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
        "-hwaccel", accelerator,
        "-ss", "0", "-i", samplePath,
        "-frames:v", "1", "-an", "-sn", "-dn",
        "-vf", "scale=64:64:flags=fast_bilinear",
        "-pix_fmt", "rgb24", "-f", "rawvideo", nullVideoOutputPath()
    ], 4 * 1024 * 1024);
}

private void selectVideoDecodeAcceleration(ref ToolStatus result)
{
    if (!result.ffmpeg) return;

    string workspace;
    try
    {
        workspace = createWorkspace("decode-probe");
        scope (exit) removePathQuietly(workspace);
        const samplePath = buildPath(workspace, "sample.mp4");
        if (!writeDecodeProbeSample(samplePath)) return;

        version (Windows)
        {
            // Use copy-back hardware decode modes that remain compatible with
            // Aurora Cut's current CPU filter graph and RGB preview pipe.
            foreach (candidate; [
                ["d3d11va", "D3D11VA"],
                ["dxva2", "DXVA2"],
                ["cuda", "NVIDIA CUDA"]
            ])
            {
                if (!decoderWorks(candidate[0], samplePath)) continue;
                result.videoDecodeInputOptions = ["-hwaccel", candidate[0]];
                result.videoDecodeAcceleration = candidate[1];
                result.hardwareVideoDecoding = true;
                return;
            }
        }
        else
        {
            foreach (candidate; [
                ["cuda", "NVIDIA CUDA"],
                ["vaapi", "VAAPI"]
            ])
            {
                if (!decoderWorks(candidate[0], samplePath)) continue;
                result.videoDecodeInputOptions = ["-hwaccel", candidate[0]];
                result.videoDecodeAcceleration = candidate[1];
                result.hardwareVideoDecoding = true;
                return;
            }
        }
    }
    catch (Exception)
    {
        if (workspace.length > 0) removePathQuietly(workspace);
    }
}

ToolStatus inspectToolStatus()
{
    ToolStatus result;
    result.ffmpeg = commandAvailable("ffmpeg");
    result.ffprobe = commandAvailable("ffprobe");
    result.ytDlpCommand = detectYtDlpCommand();
    result.ytDlp = result.ytDlpCommand.length > 0;
    selectVideoAcceleration(result);
    selectVideoDecodeAcceleration(result);
    return result;
}

private double parseDoubleOr(string value, double fallback = 0.0)
{
    if (value.length == 0 || value == "N/A") return fallback;
    try return to!double(value);
    catch (Exception) return fallback;
}

private int parseIntOr(string value, int fallback = 0)
{
    if (value.length == 0 || value == "N/A") return fallback;
    try return to!int(value);
    catch (Exception) return fallback;
}

private double parseRate(string value)
{
    if (value.length == 0 || value == "N/A") return 0.0;
    const separator = value.indexOf('/');
    if (separator < 0) return parseDoubleOr(value);
    const numerator = parseDoubleOr(value[0 .. cast(size_t) separator]);
    const denominator = parseDoubleOr(value[cast(size_t) separator + 1 .. $], 1.0);
    return denominator == 0.0 ? 0.0 : numerator / denominator;
}

/** One compact FFprobe invocation replaces the three synchronous child
 * processes used by the earlier importer. */
private string[] probeArguments(string path)
{
    return [
        "ffprobe", "-v", "error",
        "-show_entries",
        "format=duration:stream=codec_type,codec_name,width,height,r_frame_rate,channels,sample_rate",
        "-of", "json", path
    ];
}

private string valueText(const JSONValue value)
{
    final switch (value.type)
    {
        case JSONType.string: return value.str;
        case JSONType.integer: return format("%d", value.integer);
        case JSONType.uinteger: return format("%d", value.uinteger);
        case JSONType.float_: return format("%.12g", value.floating);
        case JSONType.true_: return "true";
        case JSONType.false_: return "false";
        case JSONType.null_: return "";
        case JSONType.array:
        case JSONType.object:
            return "";
    }
}

private string objectText(const JSONValue[string] object, string key)
{
    auto found = key in object;
    return found is null ? "" : valueText(*found);
}

/** Convert FFprobe JSON into the immutable metadata object handed to the UI. */
private MediaAsset parseProbeJson(string requestedPath, string output)
{
    const path = absoluteNormalized(requestedPath);
    auto asset = new MediaAsset(path);
    JSONValue root;
    try root = parseJSON(output);
    catch (Exception error)
        throw new Exception("FFprobe returned invalid metadata for " ~ path ~ ": " ~ error.msg);
    if (root.type != JSONType.object)
        throw new Exception("FFprobe returned no media metadata for " ~ path);

    const rootObject = root.object;
    auto formatValue = "format" in rootObject;
    if (formatValue !is null && formatValue.type == JSONType.object)
        asset.duration = parseDoubleOr(objectText(formatValue.object, "duration"));

    auto streamsValue = "streams" in rootObject;
    if (streamsValue !is null && streamsValue.type == JSONType.array)
    {
        foreach (streamValue; streamsValue.array)
        {
            if (streamValue.type != JSONType.object) continue;
            const stream = streamValue.object;
            const kind = objectText(stream, "codec_type");
            if (kind == "video" && !asset.hasVideo)
            {
                asset.videoCodec = objectText(stream, "codec_name");
                asset.width = parseIntOr(objectText(stream, "width"));
                asset.height = parseIntOr(objectText(stream, "height"));
                asset.frameRate = parseRate(objectText(stream, "r_frame_rate"));
                asset.hasVideo = asset.width > 0 && asset.height > 0;
            }
            else if (kind == "audio" && !asset.hasAudio)
            {
                asset.audioChannels = parseIntOr(objectText(stream, "channels"));
                asset.sampleRate = parseIntOr(objectText(stream, "sample_rate"));
                asset.hasAudio = asset.audioChannels > 0 || asset.sampleRate > 0;
            }
        }
    }

    if (!asset.hasVideo && !asset.hasAudio)
        throw new Exception("No supported audio or video stream was found in " ~ path);
    if (asset.duration <= 0.0)
    {
        // FFprobe reports no duration for still images. Give them an editable
        // five-second timeline duration; animated GIF/WebP retain probed time.
        import std.path : extension;
        import std.string : toLower;
        const suffix = extension(path).toLower();
        if (asset.hasVideo && !asset.hasAudio &&
            (suffix == ".png" || suffix == ".jpg" || suffix == ".jpeg" ||
             suffix == ".webp" || suffix == ".bmp"))
            asset.duration = 5.0;
        else
            throw new Exception("The media duration could not be read from " ~ path);
    }
    return asset;
}

private void validateMediaPath(string requestedPath)
{
    if (!exists(requestedPath) || isDir(requestedPath))
        throw new Exception("Media file does not exist: " ~ requestedPath);
    if (!isSupportedMediaPath(requestedPath))
        throw new Exception("Aurora Cut imports video, audio, PNG/JPEG/WebP/BMP images and GIF animations.");
}

MediaAsset probeMedia(string requestedPath)
{
    validateMediaPath(requestedPath);
    const output = runChecked(probeArguments(absoluteNormalized(requestedPath)),
        "Inspect media streams");
    return parseProbeJson(requestedPath, output);
}

/** Completed result returned by the asynchronous Project Media importer. */
struct MediaImportResult
{
    string requestedPath;
    MediaAsset asset;
    string error;

    bool success() const @safe pure nothrow @nogc { return asset !is null; }
}

struct MediaImportStats
{
    ulong queued;
    ulong processesStarted;
    ulong completed;
    ulong failed;
    ulong cancelled;
}

/**
 * Single-worker, cancellable FFprobe queue.
 *
 * File Explorer drops and file-dialog imports return to the event loop
 * immediately. The worker probes one path at a time with a single FFprobe
 * process, while the UI drains completed results during normal ticks.
 */
final class MediaImportService
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private string[] _queue;
    private size_t _head;
    private MediaImportResult[] _ready;
    private size_t _readyHead;
    private Pid _process;
    private bool _busy;
    private bool _shutdown;
    private MediaImportStats _stats;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    size_t enqueue(string[] paths)
    {
        if (paths.length == 0) return 0;
        size_t accepted;
        _mutex.lock();
        if (!_shutdown)
        {
            foreach (path; paths)
            {
                if (path.length == 0) continue;
                _queue ~= path.idup;
                ++accepted;
            }
            _stats.queued += accepted;
            if (accepted > 0) _condition.notify();
        }
        _mutex.unlock();
        return accepted;
    }

    bool takeReady(out MediaImportResult result)
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
        return _busy || _head < _queue.length;
    }

    size_t pendingCount()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return (_head < _queue.length ? _queue.length - _head : 0) +
            (_busy ? 1 : 0);
    }

    MediaImportStats stats()
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
            string path;
            _mutex.lock();
            while (!_shutdown && _head >= _queue.length)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            path = _queue[_head++];
            if (_head >= _queue.length)
            {
                _queue.length = 0;
                _head = 0;
            }
            _busy = true;
            _mutex.unlock();

            auto result = probeOne(path);

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

    private MediaImportResult probeOne(string requestedPath)
    {
        MediaImportResult result;
        result.requestedPath = requestedPath;
        try
        {
            validateMediaPath(requestedPath);
            const path = absoluteNormalized(requestedPath);
            auto pipes = pipeProcess(probeArguments(path),
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
            try
            {
                foreach (rawLine; pipes.stdout.byLine())
                {
                    output ~= rawLine;
                    if (output.length > 4 * 1024 * 1024)
                        throw new Exception("FFprobe metadata exceeded 4 MiB.");
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
                throw new Exception("Inspect media streams failed with exit code " ~
                    format("%d", status) ~ ".\n" ~ outputTail(output, 16 * 1024));
            if (result.error.length > 0) throw new Exception(result.error);
            result.asset = parseProbeJson(path, output);
            result.error = "";
        }
        catch (Exception error)
        {
            result.asset = null;
            result.error = outputTail(error.msg, 1_000);
        }
        return result;
    }
}

string mediaSecondaryText(const MediaAsset asset)
{
    if (asset is null) return "Unavailable";
    if (asset.hasVideo)
    {
        const fps = asset.frameRate > 0.0 ? format(" • %.2f fps", asset.frameRate) : "";
        const audio = asset.hasAudio ? " • audio" : " • silent";
        return format("%dx%d%s%s • %s", asset.width, asset.height, fps, audio,
            formatTimecode(asset.duration, false));
    }
    return format("Audio • %d Hz • %d ch • %s", asset.sampleRate,
        asset.audioChannels, formatTimecode(asset.duration, false));
}

module auroracut.exporter;

import auroracut.model : EffectKeyframe, EffectProperty, KeyframeInterpolation,
    TextAlignment;
import auroracut.titlelayer : TitleVisual, renderTitlePam;
import auroracut.util : absoluteNormalized, appLog, createWorkspace,
    ensureExtension, ensureParentDirectory, formatSeconds, outputTail,
    removePathQuietly, runChecked;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.algorithm : min, max;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.format : format;
import std.math : fabs;
import std.path : buildPath, extension, filenameCmp;
import std.process : Config, Pid, Redirect, kill, pipeProcess, wait;
import std.string : join, startsWith, strip, toLower;


enum ExportKind : ubyte
{
    mp4,
    mp3
}

/** One absolute-position timeline clip consumed by the FFmpeg compositor. */
struct ExportClip
{
    ulong clipId;
    string path;
    bool generatedText;
    string titleRasterPath;
    int titleRasterWidth;
    int titleRasterHeight;
    double titleRasterBaseSize;
    double start = 0.0;
    double inPoint = 0.0;
    double outPoint = 0.0;
    double volume = 1.0;
    bool muted;
    double playbackRate = 1.0;
    bool reversed;
    bool cropEnabled;
    double cropX = 0.0;
    double cropY = 0.0;
    double cropWidth = 1.0;
    double cropHeight = 1.0;
    bool hasVideo;
    bool hasAudio;
    string videoCodec;
    int sourceWidth;
    int sourceHeight;
    size_t trackIndex;
    bool trackMuted;
    bool trackDisabled;
    double scale = 1.0;
    double positionX = 0.0;
    double positionY = 0.0;
    double opacity = 1.0;
    double rotation = 0.0;
    double fadeIn = 0.0;
    double fadeOut = 0.0;
    double blur = 0.0;
    double shadowOpacity = 0.0;
    double shadowBlur = 12.0;
    double shadowOffsetX = 12.0;
    double shadowOffsetY = 12.0;
    uint shadowColor = 0xff000000;
    double strokeWidth = 0.0;
    uint strokeColor = 0xffffffff;
    string text = "Title";
    string fontName = "Sans";
    bool textBold;
    bool textItalic;
    bool textUnderline;
    TextAlignment textAlignment = TextAlignment.left;
    double textSize = 96.0;
    uint textColor = 0xffffffff;
    bool textBox;
    uint textBoxColor = 0x80000000;
    EffectKeyframe[] keyframes;

    double duration() const
    {
        const sourceDuration = outPoint > inPoint ? outPoint - inPoint : 0.0;
        const rate = playbackRate > 0.000_001 ? playbackRate : 1.0;
        return sourceDuration / rate;
    }

    double end() const
    {
        return start + duration();
    }

    double baseValue(EffectProperty property) const
    {
        final switch (property)
        {
            case EffectProperty.volume: return volume;
            case EffectProperty.scale: return scale;
            case EffectProperty.positionX: return positionX;
            case EffectProperty.positionY: return positionY;
            case EffectProperty.opacity: return opacity;
            case EffectProperty.rotation: return rotation;
            case EffectProperty.textSize: return textSize;
        }
    }

    double evaluatedValue(EffectProperty property, double localTime) const
    {
        double previousTime;
        double previousValue = baseValue(property);
        KeyframeInterpolation previousInterpolation = KeyframeInterpolation.linear;
        bool havePrevious;
        foreach (keyframe; keyframes)
        {
            if (keyframe.property != property) continue;
            if (keyframe.time <= localTime + 0.000_000_5)
            {
                previousTime = keyframe.time;
                previousValue = keyframe.value;
                previousInterpolation = keyframe.interpolation;
                havePrevious = true;
                continue;
            }
            if (!havePrevious) return keyframe.value;
            const span = keyframe.time - previousTime;
            if (span <= 0.000_000_5) return keyframe.value;
            if (previousInterpolation == KeyframeInterpolation.hold)
                return previousValue;
            double amount = (localTime - previousTime) / span;
            if (amount < 0.0) amount = 0.0;
            else if (amount > 1.0) amount = 1.0;
            if (previousInterpolation == KeyframeInterpolation.bezier)
                amount = amount * amount * (3.0 - 2.0 * amount);
            return previousValue + (keyframe.value - previousValue) * amount;
        }
        return previousValue;
    }
}

struct ExportPreset
{
    int width = 1280;
    int height = 720;
    int fps = 30;
    int crf = 20;
    string videoPreset = "veryfast";
    bool previewOptimized;

    string label() const
    {
        return format("%dp", height);
    }

    static ExportPreset hd()
    {
        ExportPreset result;
        result.width = 1280;
        result.height = 720;
        return result;
    }

    static ExportPreset fullHd()
    {
        ExportPreset result;
        result.width = 1920;
        result.height = 1080;
        return result;
    }

    static ExportPreset quadHd()
    {
        ExportPreset result;
        result.width = 2560;
        result.height = 1440;
        result.crf = 19;
        return result;
    }

    static ExportPreset ultraHd()
    {
        ExportPreset result;
        result.width = 3840;
        result.height = 2160;
        result.crf = 18;
        result.videoPreset = "fast";
        return result;
    }

    static ExportPreset custom(int requestedWidth, int requestedHeight)
    {
        ExportPreset result;
        result.width = evenDimension(requestedWidth);
        result.height = evenDimension(requestedHeight);
        result.crf = result.height >= 2160 ? 18 :
            result.height >= 1440 ? 19 : 20;
        result.videoPreset = result.height >= 2160 ? "fast" : "veryfast";
        return result;
    }

    static ExportPreset previewForHeight(int requestedHeight)
    {
        ExportPreset result;
        switch (requestedHeight)
        {
            case 720: result = hd(); break;
            case 1080: result = fullHd(); break;
            case 1440: result = quadHd(); break;
            case 2160: result = ultraHd(); break;
            default: result = hd(); break;
        }
        result.crf = requestedHeight >= 2160 ? 25 : 23;
        result.videoPreset = "ultrafast";
        result.previewOptimized = true;
        return result;
    }
}

struct ExportRequest
{
    ExportKind kind;
    string outputPath;
    ExportClip[] video;
    ExportClip[] audio;
    ExportPreset preset;
    double rangeStart = 0.0;
    double rangeEnd = 0.0;
    ulong cacheKey;
    string videoEncoder = "libx264";
    string videoAcceleration = "CPU (libx264)";
    bool hardwareVideoEncoding;
    string videoDecodeAcceleration = "CPU decode";
    string[] videoDecodeInputOptions;
    bool hardwareVideoDecoding;
    // Interactive preview supplies live Aurora title widgets. Final export
    // prepares Aurora-rendered RGBA title inputs when this remains true.
    bool renderTitles = true;

    bool hasRange() const
    {
        return rangeEnd > rangeStart + 0.000_001;
    }

    double sequenceDuration() const
    {
        if (hasRange()) return rangeEnd - rangeStart;
        double result = 0.0;
        foreach (clip; video) if (!clip.trackDisabled && clip.end() > result) result = clip.end();
        foreach (clip; audio) if (!clip.trackDisabled && clip.end() > result) result = clip.end();
        return result;
    }
}

struct ExportState
{
    bool running;
    bool done;
    bool success;
    bool cancelled;
    double progress = 0.0;
    string status = "Ready";
    string error;
    string outputPath;
}

private struct InputClip
{
    ExportClip clip;
    bool videoTrack;
    int inputIndex;
    string[] decodeInputOptions;
}

private struct RecompressRequest
{
    string inputPath;
    string outputPath;
    int crf;
}

final class ExportJob
{
    private Mutex _mutex;
    private ExportState _state;
    private Thread _thread;
    private Pid _process;
    private bool _cancelRequested;
    private bool _shutdown;

    this()
    {
        _mutex = new Mutex();
        _state.done = true;
    }

    bool start(ExportRequest request)
    {
        _mutex.lock();
        if (_state.running || _shutdown)
        {
            _mutex.unlock();
            return false;
        }
        _state = ExportState.init;
        _state.running = true;
        _state.status = request.kind == ExportKind.mp4 ?
            "Preparing composed MP4 render…" : "Preparing mixed MP3 render…";
        _state.outputPath = request.outputPath;
        _cancelRequested = false;
        _process = null;
        _mutex.unlock();

        request.video = request.video.dup;
        request.audio = request.audio.dup;
        _thread = new Thread({ runRequest(request); });
        _thread.isDaemon = true;
        _thread.start();
        return true;
    }

    bool startRecompress(string inputPath, string outputPath, int crf)
    {
        _mutex.lock();
        if (_state.running || _shutdown)
        {
            _mutex.unlock();
            return false;
        }
        _state = ExportState.init;
        _state.running = true;
        _state.status = "Preparing MP4 recompression…";
        _state.outputPath = outputPath;
        _cancelRequested = false;
        _process = null;
        _mutex.unlock();

        RecompressRequest request;
        request.inputPath = inputPath;
        request.outputPath = outputPath;
        request.crf = crf;
        _thread = new Thread({ runRecompressRequest(request); });
        _thread.isDaemon = true;
        _thread.start();
        return true;
    }

    ExportState state()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _state;
    }

    /** Request cancellation without waiting on the UI thread. */
    bool cancel()
    {
        Pid process;
        _mutex.lock();
        if (!_state.running)
        {
            _mutex.unlock();
            return false;
        }
        _cancelRequested = true;
        _state.status = "Cancelling background render…";
        process = _process;
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        return true;
    }

    /** Terminate the owned FFmpeg process and join its worker on application
     * teardown. Normal rendering and cancellation remain asynchronous. */
    void shutdown()
    {
        Pid process;
        Thread worker;
        _mutex.lock();
        _shutdown = true;
        if (_state.running)
        {
            _cancelRequested = true;
            _state.status = "Cancelling background render…";
        }
        process = _process;
        worker = _thread;
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
        if (worker !is null)
        {
            try worker.join();
            catch (Exception) {}
        }
    }

    private bool cancellationRequested()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _cancelRequested || _shutdown;
    }

    private void publish(double progress, string status)
    {
        _mutex.lock();
        if (!_cancelRequested && !_shutdown)
        {
            _state.progress = progress < 0.0 ? 0.0 : (progress > 1.0 ? 1.0 : progress);
            _state.status = status;
        }
        _mutex.unlock();
    }

    private void finishSuccess(string path)
    {
        _mutex.lock();
        _state.running = false;
        _state.done = true;
        _state.success = true;
        _state.cancelled = false;
        _state.progress = 1.0;
        _state.status = "Finished: " ~ path;
        _state.outputPath = path;
        _process = null;
        _mutex.unlock();
    }

    private void finishFailure(string message)
    {
        _mutex.lock();
        _state.running = false;
        _state.done = true;
        _state.success = false;
        _state.cancelled = false;
        _state.status = "Render failed";
        _state.error = message;
        _process = null;
        _mutex.unlock();
    }

    private void finishCancelled()
    {
        _mutex.lock();
        _state.running = false;
        _state.done = true;
        _state.success = false;
        _state.cancelled = true;
        _state.status = "Render cancelled";
        _state.error = "";
        _process = null;
        _mutex.unlock();
    }

    private void runRequest(ExportRequest request)
    {
        string workspace;
        string outputPath;
        string failure;
        bool success;
        bool cancelled;
        try
        {
            request = normalizeExportRange(request);
            const duration = request.sequenceDuration();
            if (duration <= 0.0) throw new Exception("The sequence is empty.");
            if (request.preset.width <= 0 || request.preset.height <= 0 ||
                request.preset.fps <= 0)
                throw new Exception("The render preset is invalid.");
            if (cancellationRequested())
                throw new Exception("Render cancelled.");

            const requiredExtension = request.kind == ExportKind.mp4 ? ".mp4" : ".mp3";
            outputPath = absoluteNormalized(ensureExtension(request.outputPath,
                requiredExtension));
            ensureParentDirectory(outputPath);
            workspace = createWorkspace("composition");
            publish(0.04, request.kind == ExportKind.mp4
                ? "Building the multi-track composition with " ~
                    request.videoAcceleration ~ "…"
                : "Building the mixed audio composition…");
            try
                performComposition(request, workspace, outputPath, this);
            catch (Exception hardwareError)
            {
                if (!request.hardwareVideoEncoding || request.kind != ExportKind.mp4 ||
                    cancellationRequested()) throw hardwareError;
                // A driver can disappear after startup or reject a particular
                // frame format. Retry once with libx264 instead of losing the
                // user's export or preview render.
                removePathQuietly(outputPath);
                request.videoEncoder = "libx264";
                request.videoAcceleration = "CPU fallback (libx264)";
                request.hardwareVideoEncoding = false;
                publish(0.05, "GPU encoder failed; retrying with CPU fallback…");
                performComposition(request, workspace, outputPath, this);
            }
            if (cancellationRequested())
                throw new Exception("Render cancelled.");
            publish(0.98, "Finalizing the rendered file…");
            success = true;
        }
        catch (Exception error)
        {
            cancelled = cancellationRequested();
            if (!cancelled) failure = error.msg;
        }
        finally
        {
            removePathQuietly(workspace);
            if (!success && outputPath.length > 0)
                removePathQuietly(outputPath);
        }

        if (success)
            finishSuccess(outputPath);
        else if (cancelled)
            finishCancelled();
        else
            finishFailure(failure.length > 0 ? failure : "The render did not complete.");
    }

    private void runRecompressRequest(RecompressRequest request)
    {
        string outputPath;
        string failure;
        bool success;
        bool cancelled;
        try
        {
            if (request.inputPath.length == 0)
                throw new Exception("No source MP4 was provided.");
            const inputPath = absoluteNormalized(request.inputPath);
            outputPath = absoluteNormalized(ensureExtension(request.outputPath, ".mp4"));
            if (filenameCmp(inputPath, outputPath) == 0)
                throw new Exception("Choose a different output path for the compressed copy.");
            ensureParentDirectory(outputPath);
            if (cancellationRequested())
                throw new Exception("Render cancelled.");

            const crf = max(0, min(51, request.crf));
            publish(0.04, format("Compressing MP4 copy at CRF %d…", crf));
            string[] arguments = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-nostats", "-stats_period", "0.25", "-progress", "pipe:1",
                "-i", inputPath,
                "-map", "0:v:0", "-map", "0:a?", "-sn", "-dn",
                "-c:v", "libx264", "-preset", "veryfast",
                "-crf", format("%d", crf),
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                "-movflags", "+faststart",
                outputPath
            ];
            runCancellable(arguments, "Compress MP4", 0.0);
            if (cancellationRequested())
                throw new Exception("Render cancelled.");
            publish(0.98, "Finalizing compressed MP4…");
            success = true;
        }
        catch (Exception error)
        {
            cancelled = cancellationRequested();
            if (!cancelled) failure = error.msg;
        }
        finally
        {
            if (!success && outputPath.length > 0)
                removePathQuietly(outputPath);
        }

        if (success)
            finishSuccess(outputPath);
        else if (cancelled)
            finishCancelled();
        else
            finishFailure(failure.length > 0 ? failure :
                "The MP4 recompression did not complete.");
    }

    /** Execute FFmpeg on the worker, publish real progress, and keep ownership
     * of the child process so cancellation never waits on the event thread. */
    private void runCancellable(string[] arguments, string description,
        double duration)
    {
        appLog("RUN " ~ arguments.join(" "));
        auto pipes = pipeProcess(arguments,
            Redirect.stdout | Redirect.stderrToStdout,
            cast(const string[string]) null, Config.suppressConsole);

        bool cancelNow;
        _mutex.lock();
        _process = pipes.pid;
        cancelNow = _cancelRequested || _shutdown;
        _mutex.unlock();
        if (cancelNow)
        {
            try kill(pipes.pid);
            catch (Exception) {}
        }

        string diagnostics;
        int lastPercent = -1;
        try
        {
            foreach (rawLine; pipes.stdout.byLine())
            {
                const line = rawLine.strip();
                bool progressLine;
                long elapsedMicroseconds;
                if (line.startsWith("out_time_us="))
                {
                    progressLine = true;
                    try elapsedMicroseconds = to!long(line[12 .. $]);
                    catch (Exception) elapsedMicroseconds = 0;
                }
                else if (line.startsWith("out_time_ms="))
                {
                    // FFmpeg historically labels this field "ms" while emitting
                    // microseconds. out_time_us is preferred when available.
                    progressLine = true;
                    try elapsedMicroseconds = to!long(line[12 .. $]);
                    catch (Exception) elapsedMicroseconds = 0;
                }
                else if (line.startsWith("bitrate=") ||
                    line.startsWith("total_size=") ||
                    line.startsWith("out_time=") ||
                    line.startsWith("dup_frames=") ||
                    line.startsWith("drop_frames=") ||
                    line.startsWith("speed=") ||
                    line.startsWith("progress="))
                    progressLine = true;

                if (elapsedMicroseconds > 0 && duration > 0.0)
                {
                    double ratio = cast(double) elapsedMicroseconds /
                        (duration * 1_000_000.0);
                    if (ratio < 0.0) ratio = 0.0;
                    if (ratio > 1.0) ratio = 1.0;
                    const percent = cast(int) (ratio * 100.0 + 0.5);
                    if (percent != lastPercent)
                    {
                        lastPercent = percent;
                        publish(0.04 + ratio * 0.92,
                            format("Rendering composition… %d%%", percent));
                    }
                }
                if (!progressLine && line.length > 0)
                {
                    diagnostics ~= line ~ "\n";
                    if (diagnostics.length > 64 * 1024)
                        diagnostics = diagnostics[$ - 64 * 1024 .. $].idup;
                }
            }
        }
        catch (Exception error)
        {
            if (!cancellationRequested())
                diagnostics ~= error.msg ~ "\n";
        }

        int status;
        try status = wait(pipes.pid);
        catch (Exception error)
        {
            if (!cancellationRequested())
                throw new Exception(description ~ " could not be reaped: " ~ error.msg);
        }

        _mutex.lock();
        if (_process is pipes.pid) _process = null;
        const cancelled = _cancelRequested || _shutdown;
        _mutex.unlock();
        if (cancelled) throw new Exception("Render cancelled.");
        if (status != 0)
        {
            const details = outputTail(diagnostics, 16 * 1024);
            throw new Exception(format("%s failed with exit code %d.%s%s",
                description, status, details.length > 0 ? "\n" : "", details));
        }
    }
}

/** Apply an optional export work range without changing the editor model. */
private ExportRequest normalizeExportRange(ExportRequest request)
{
    if (!request.hasRange()) return request;

    double contentEnd = 0.0;
    foreach (clip; request.video)
        if (!clip.trackDisabled && clip.end() > contentEnd) contentEnd = clip.end();
    foreach (clip; request.audio)
        if (!clip.trackDisabled && clip.end() > contentEnd) contentEnd = clip.end();

    const rangeStart = max(0.0, request.rangeStart);
    const rangeEnd = min(contentEnd, request.rangeEnd);
    if (rangeEnd <= rangeStart + 0.000_001)
        throw new Exception("The selected export range is empty.");

    request.video = clipsWithinRange(request.video, rangeStart, rangeEnd);
    request.audio = clipsWithinRange(request.audio, rangeStart, rangeEnd);
    request.rangeStart = 0.0;
    request.rangeEnd = rangeEnd - rangeStart;
    return request;
}

ExportRequest normalizedExportRequestForTesting(ExportRequest request)
{
    return normalizeExportRange(request);
}

private ExportClip[] clipsWithinRange(ExportClip[] source,
    double rangeStart, double rangeEnd)
{
    ExportClip[] result;
    result.reserve(source.length);
    foreach (ref sourceClip; source)
    {
        if (sourceClip.end() <= rangeStart + 0.000_001 ||
            sourceClip.start >= rangeEnd - 0.000_001) continue;

        ExportClip clip = cloneExportClip(sourceClip);
        const visibleStart = max(sourceClip.start, rangeStart);
        const visibleEnd = min(sourceClip.end(), rangeEnd);
        const trimLeft = visibleStart - sourceClip.start;
        const trimRight = sourceClip.end() - visibleEnd;
        clip.start = visibleStart - rangeStart;
        const sourceTrimLeft = trimLeft * sourceClip.playbackRate;
        const sourceTrimRight = trimRight * sourceClip.playbackRate;
        if (!sourceClip.reversed)
        {
            clip.inPoint += sourceTrimLeft;
            clip.outPoint -= sourceTrimRight;
        }
        else
        {
            clip.outPoint -= sourceTrimLeft;
            clip.inPoint += sourceTrimRight;
        }
        clip.fadeIn = max(0.0, sourceClip.fadeIn - trimLeft);
        clip.fadeOut = max(0.0, sourceClip.fadeOut - trimRight);
        clip.keyframes = trimmedKeyframes(sourceClip, trimLeft,
            visibleEnd - visibleStart);
        if (clip.duration() > 0.000_001) result ~= clip;
    }
    return result;
}

private KeyframeInterpolation interpolationAt(const ref ExportClip clip,
    EffectProperty property, double localTime)
{
    KeyframeInterpolation result = KeyframeInterpolation.linear;
    foreach (keyframe; clip.keyframes)
    {
        if (keyframe.property != property) continue;
        if (keyframe.time > localTime + 0.000_5) break;
        result = keyframe.interpolation;
    }
    return result;
}

private EffectKeyframe[] trimmedKeyframes(const ref ExportClip original,
    double trimLeft, double newDuration)
{
    bool[7] animated;
    foreach (keyframe; original.keyframes)
        animated[cast(size_t) keyframe.property] = true;

    EffectKeyframe[] result;
    foreach (propertyIndex; 0 .. animated.length)
    {
        if (!animated[propertyIndex]) continue;
        const property = cast(EffectProperty) propertyIndex;
        result ~= EffectKeyframe(property, 0.0,
            original.evaluatedValue(property, trimLeft),
            interpolationAt(original, property, trimLeft));
        foreach (keyframe; original.keyframes)
        {
            if (keyframe.property != property) continue;
            if (keyframe.time <= trimLeft + 0.000_5 ||
                keyframe.time >= trimLeft + newDuration - 0.000_5) continue;
            result ~= EffectKeyframe(property, keyframe.time - trimLeft,
                keyframe.value, keyframe.interpolation);
        }
        if (newDuration > 0.000_5)
            result ~= EffectKeyframe(property, newDuration,
                original.evaluatedValue(property, trimLeft + newDuration),
                interpolationAt(original, property, trimLeft + newDuration));
    }
    result.sort!((left, right) => left.property < right.property ||
        (left.property == right.property && left.time < right.time));
    return result;
}

private ExportClip cloneExportClip(const ref ExportClip source)
{
    ExportClip result;
    result.clipId = source.clipId;
    result.path = source.path.idup;
    result.generatedText = source.generatedText;
    result.titleRasterPath = source.titleRasterPath.idup;
    result.titleRasterWidth = source.titleRasterWidth;
    result.titleRasterHeight = source.titleRasterHeight;
    result.titleRasterBaseSize = source.titleRasterBaseSize;
    result.start = source.start;
    result.inPoint = source.inPoint;
    result.outPoint = source.outPoint;
    result.volume = source.volume;
    result.muted = source.muted;
    result.playbackRate = source.playbackRate;
    result.reversed = source.reversed;
    result.cropEnabled = source.cropEnabled;
    result.cropX = source.cropX;
    result.cropY = source.cropY;
    result.cropWidth = source.cropWidth;
    result.cropHeight = source.cropHeight;
    result.hasVideo = source.hasVideo;
    result.hasAudio = source.hasAudio;
    result.videoCodec = source.videoCodec.idup;
    result.sourceWidth = source.sourceWidth;
    result.sourceHeight = source.sourceHeight;
    result.trackIndex = source.trackIndex;
    result.trackMuted = source.trackMuted;
    result.trackDisabled = source.trackDisabled;
    result.scale = source.scale;
    result.positionX = source.positionX;
    result.positionY = source.positionY;
    result.opacity = source.opacity;
    result.rotation = source.rotation;
    result.fadeIn = source.fadeIn;
    result.fadeOut = source.fadeOut;
    result.blur = source.blur;
    result.shadowOpacity = source.shadowOpacity;
    result.shadowBlur = source.shadowBlur;
    result.shadowOffsetX = source.shadowOffsetX;
    result.shadowOffsetY = source.shadowOffsetY;
    result.shadowColor = source.shadowColor;
    result.strokeWidth = source.strokeWidth;
    result.strokeColor = source.strokeColor;
    result.text = source.text.idup;
    result.fontName = source.fontName.idup;
    result.textBold = source.textBold;
    result.textItalic = source.textItalic;
    result.textUnderline = source.textUnderline;
    result.textAlignment = source.textAlignment;
    result.textSize = source.textSize;
    result.textColor = source.textColor;
    result.textBox = source.textBox;
    result.textBoxColor = source.textBoxColor;
    result.keyframes = source.keyframes.dup;
    return result;
}

private TitleVisual titleVisualFromClip(const ref ExportClip clip)
{
    TitleVisual visual;
    visual.clipId = clip.clipId;
    visual.text = clip.text;
    visual.fontName = clip.fontName;
    visual.bold = clip.textBold;
    visual.italic = clip.textItalic;
    visual.underline = clip.textUnderline;
    visual.textAlignment = clip.textAlignment;
    visual.baseTextSize = clip.textSize;
    visual.textSize = clip.textSize;
    visual.textColor = clip.textColor;
    visual.box = clip.textBox;
    visual.boxColor = clip.textBoxColor;
    visual.strokeWidth = clip.strokeWidth;
    visual.strokeColor = clip.strokeColor;
    visual.shadowOpacity = clip.shadowOpacity;
    visual.shadowBlur = clip.shadowBlur;
    visual.shadowOffsetX = clip.shadowOffsetX;
    visual.shadowOffsetY = clip.shadowOffsetY;
    visual.shadowColor = clip.shadowColor;
    visual.opacity = 1.0;
    visual.scale = clip.scale;
    visual.positionX = clip.positionX;
    visual.positionY = clip.positionY;
    visual.rotation = clip.rotation;
    visual.trackIndex = clip.trackIndex;
    return visual;
}

/** Create one transparent Aurora-rendered PAM input for every generated title. */
private void prepareTitleRasters(ref ExportRequest request, string workspace)
{
    if (!request.renderTitles || request.kind != ExportKind.mp4) return;
    request.video = request.video.dup;
    foreach (index, ref clip; request.video)
    {
        if (!clip.generatedText || clip.trackDisabled) continue;
        const rasterPath = buildPath(workspace,
            format("title-%04d.pam", cast(int) index));
        const raster = renderTitlePam(titleVisualFromClip(clip), rasterPath);
        clip.titleRasterPath = raster.path;
        clip.titleRasterWidth = raster.width;
        clip.titleRasterHeight = raster.height;
        clip.titleRasterBaseSize = raster.baseTextSize;
        clip.hasVideo = true;
    }
}


private void appendVideoEncoderArguments(ref string[] arguments,
    const ExportRequest request)
{
    const encoder = request.videoEncoder.length > 0 ?
        request.videoEncoder : "libx264";
    arguments ~= ["-c:v", encoder];

    if (encoder == "h264_nvenc")
    {
        arguments ~= [
            "-preset", request.preset.previewOptimized ? "p1" : "p4",
            "-tune", request.preset.previewOptimized ? "ll" : "hq",
            "-rc", "vbr", "-cq", format("%d", request.preset.crf),
            "-b:v", "0"
        ];
    }
    else if (encoder == "h264_qsv")
    {
        arguments ~= [
            "-preset", request.preset.previewOptimized ? "veryfast" : "medium",
            "-global_quality", format("%d", request.preset.crf)
        ];
    }
    else if (encoder == "h264_amf")
    {
        arguments ~= [
            "-quality", request.preset.previewOptimized ? "speed" : "balanced",
            "-rc", "cqp",
            "-qp_i", format("%d", request.preset.crf),
            "-qp_p", format("%d", request.preset.crf)
        ];
    }
    else
    {
        arguments ~= [
            "-preset", request.preset.videoPreset,
            "-crf", format("%d", request.preset.crf),
            "-threads", request.preset.previewOptimized ? "2" : "4"
        ];
    }
}

/** Render a complete multi-track sequence in one FFmpeg filter graph. */
private void performComposition(ExportRequest request, string workspace,
    string outputPath, ExportJob job)
{
    prepareTitleRasters(request, workspace);
    const duration = request.sequenceDuration();
    InputClip[] inputs = collectInputs(request, request.kind == ExportKind.mp4, true);
    if (inputs.length == 0)
        throw new Exception("The sequence has no usable media streams.");

    string[] arguments = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-nostats", "-stats_period", "0.25", "-progress", "pipe:1",
        "-filter_threads", request.preset.previewOptimized ? "2" : "3",
        "-filter_complex_threads", request.preset.previewOptimized ? "2" : "3"
    ];
    appendInputArguments(arguments, inputs);

    // Pass the graph inline rather than via -filter_complex_script: newer
    // FFmpeg builds (including the minimal bundled release binary) removed that
    // deprecated option, so exporting would fail there. Inline -filter_complex
    // works on both the full and the minimal builds, and matches the live
    // playback/compositor paths which already use it.
    const graph = buildFilterGraph(request, inputs, duration,
        request.kind == ExportKind.mp4, true);
    arguments ~= ["-filter_complex", graph];

    if (request.kind == ExportKind.mp4)
    {
        arguments ~= [
            "-map", "[vout]", "-map", "[aout]",
            "-t", formatSeconds(duration)
        ];
        appendVideoEncoderArguments(arguments, request);
        arguments ~= [
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"
        ];
        if (request.preset.previewOptimized)
        {
            const seekGop = max(1, request.preset.fps / 2);
            arguments ~= [
                "-tune", "zerolatency",
                "-g", format("%d", seekGop),
                "-keyint_min", format("%d", seekGop),
                "-sc_threshold", "0"
            ];
        }
        arguments ~= ["-movflags", "+faststart", outputPath];
    }
    else
    {
        bool hasAudio;
        foreach (input; inputs)
            if (input.clip.hasAudio && !input.clip.trackDisabled &&
                !input.clip.trackMuted && !input.clip.muted && input.clip.volume > 0.000_001)
                hasAudio = true;
        if (!hasAudio) throw new Exception("No audible clips are available for MP3 export.");
        arguments ~= [
            "-map", "[aout]", "-vn", "-t", formatSeconds(duration),
            "-c:a", "libmp3lame", "-q:a", "2", outputPath
        ];
    }
    job.runCancellable(arguments, request.kind == ExportKind.mp4 ?
        "Compose and render MP4" : "Mix and render MP3", duration);
}

/**
 * Build a one-frame raw RGB24 compositor command.
 *
 * The caller owns process execution and cancellation. Keeping the process
 * handle outside this module lets PreviewService terminate obsolete scrub
 * requests immediately instead of waiting for an old FFmpeg invocation.
 */
string[] compositeFrameArguments(ExportRequest request, double sequenceTime)
{
    return compositeFrameArguments(request, sequenceTime,
        request.preset.width, request.preset.height);
}

/** Build video/image composition in its authoritative canvas resolution, then
 * scale only the RGB background to the visible Preview size. Titles are live
 * Aurora layers and are intentionally absent from this command. */
string[] compositeFrameArguments(ExportRequest request, double sequenceTime,
    int outputWidth, int outputHeight)
{
    ExportRequest frameRequest = frameRequestAtTime(request, sequenceTime);
    frameRequest.renderTitles = false;
    const frameDuration = 1.0 / max(1, request.preset.fps);

    InputClip[] inputs = collectInputs(frameRequest, true, false);
    string[] arguments = [
        "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
        "-threads", "1", "-filter_threads", "1",
        "-filter_complex_threads", "1"
    ];
    appendInputArguments(arguments, inputs);
    const duration = frameDuration * 2.0;
    string graph = buildFilterGraph(frameRequest, inputs, duration, true, false);
    string outputLabel = "vout";
    if (outputWidth > 0 && outputHeight > 0 &&
        (outputWidth != request.preset.width || outputHeight != request.preset.height))
    {
        graph ~= format("[vout]scale=%d:%d:flags=fast_bilinear,format=rgb24[previewout];\n",
            outputWidth, outputHeight);
        outputLabel = "previewout";
    }
    arguments ~= [
        "-filter_complex", graph,
        "-map", "[" ~ outputLabel ~ "]", "-frames:v", "1", "-an",
        "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"
    ];
    return arguments;
}


/** Build a live RGB24 timeline-composition stream. The request is trimmed to
 * the requested sequence range without creating a proxy file. VideoFrameStream
 * paces the raw frames, so edits can start playing immediately. */
string[] compositeStreamArguments(ExportRequest request, double sequenceStart,
    double sequenceEnd, int outputWidth, int outputHeight, int outputFps)
{
    request.rangeStart = sequenceStart;
    request.rangeEnd = sequenceEnd;
    request = normalizeExportRange(request);
    request.renderTitles = false;
    request.preset.fps = max(1, outputFps);
    InputClip[] inputs = collectInputs(request, true, false);
    string[] arguments = [
        "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
        "-threads", "2", "-filter_threads", "2",
        "-filter_complex_threads", "2"
    ];
    appendInputArguments(arguments, inputs);
    const duration = request.sequenceDuration();
    string graph = buildFilterGraph(request, inputs, duration, true, false);
    string outputLabel = "vout";
    if (outputWidth > 0 && outputHeight > 0 &&
        (outputWidth != request.preset.width || outputHeight != request.preset.height))
    {
        graph ~= format("[vout]scale=%d:%d:flags=fast_bilinear,format=rgb24[previewout];\n",
            outputWidth, outputHeight);
        outputLabel = "previewout";
    }
    arguments ~= [
        "-filter_complex", graph,
        "-map", "[" ~ outputLabel ~ "]", "-an", "-sn", "-dn",
        "-t", formatSeconds(duration, 6), "-pix_fmt", "rgb24",
        "-f", "rawvideo", "pipe:1"
    ];
    return arguments;
}

/** Build a live s16le PCM timeline-audio stream using the same mix graph as
 * MP4 export. The bytes are 48 kHz stereo signed 16-bit little-endian samples
 * suitable for the preview audio device. */
string[] compositeAudioArguments(ExportRequest request, double sequenceStart,
    double sequenceEnd)
{
    request.rangeStart = sequenceStart;
    request.rangeEnd = sequenceEnd;
    request = normalizeExportRange(request);
    InputClip[] inputs = collectInputs(request, false, true);
    string[] arguments = [
        "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
        "-threads", "1", "-filter_threads", "1",
        "-filter_complex_threads", "1"
    ];
    appendInputArguments(arguments, inputs);
    const duration = request.sequenceDuration();
    arguments ~= [
        "-filter_complex", buildFilterGraph(request, inputs, duration, false, true),
        "-map", "[aout]", "-vn", "-sn", "-dn",
        "-t", formatSeconds(duration, 6), "-ac", "2", "-ar", "48000",
        "-sample_fmt", "s16", "-f", "s16le", "pipe:1"
    ];
    return arguments;
}

/**
 * Render exactly one composed sequence frame through the same overlay graph
 * used by MP4 export. This compatibility helper is retained for scripts/tests;
 * interactive previews use compositeFrameArguments() and a cancellable pipe.
 */
void renderCompositeFrame(ExportRequest request, double sequenceTime,
    string outputPpmPath)
{
    ExportRequest frameRequest = frameRequestAtTime(request, sequenceTime);
    const frameDuration = 1.0 / max(1, request.preset.fps);

    string workspace = createWorkspace("composite-frame");
    scope (exit) removePathQuietly(workspace);
    prepareTitleRasters(frameRequest, workspace);
    InputClip[] inputs = collectInputs(frameRequest, true, false);
    string[] arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"];
    appendInputArguments(arguments, inputs);
    const duration = frameDuration * 2.0;
    const graph = buildFilterGraph(frameRequest, inputs, duration, true, false);
    arguments ~= [
        "-filter_complex", graph,
        "-map", "[vout]", "-frames:v", "1", "-an",
        "-f", "image2", outputPpmPath
    ];
    runChecked(arguments, "Render composed sequence frame");
}

private ExportRequest frameRequestAtTime(ExportRequest request, double sequenceTime)
{
    ExportRequest result = request;
    result.kind = ExportKind.mp4;
    result.video.length = 0;
    result.audio.length = 0;
    result.rangeStart = 0.0;
    result.rangeEnd = 0.0;
    const frameDuration = 1.0 / max(1, request.preset.fps);

    foreach (ref clip; request.video)
    {
        if (clip.trackDisabled || (!clip.hasVideo && !clip.generatedText)) continue;
        if (sequenceTime < clip.start || sequenceTime >= clip.end()) continue;
        const local = sequenceTime - clip.start;
        ExportClip active = cloneExportClip(clip);
        active.volume = clip.evaluatedValue(EffectProperty.volume, local);
        active.scale = clip.evaluatedValue(EffectProperty.scale, local);
        active.positionX = clip.evaluatedValue(EffectProperty.positionX, local);
        active.positionY = clip.evaluatedValue(EffectProperty.positionY, local);
        active.opacity = clip.evaluatedValue(EffectProperty.opacity, local) *
            fadeEnvelopeValue(clip, local);
        active.rotation = clip.evaluatedValue(EffectProperty.rotation, local);
        active.textSize = clip.evaluatedValue(EffectProperty.textSize, local);
        active.keyframes.length = 0;
        active.fadeIn = 0.0;
        active.fadeOut = 0.0;
        active.start = 0.0;
        if (active.generatedText)
        {
            active.inPoint = 0.0;
            active.outPoint = frameDuration * 2.0;
        }
        else
        {
            const sourceLocal = local * clip.playbackRate;
            if (!clip.reversed)
            {
                active.inPoint = clip.inPoint + sourceLocal;
                active.outPoint = min(clip.outPoint, active.inPoint +
                    frameDuration * clip.playbackRate * 2.0);
            }
            else
            {
                active.outPoint = clip.outPoint - sourceLocal;
                active.inPoint = max(clip.inPoint, active.outPoint -
                    frameDuration * clip.playbackRate * 2.0);
            }
            active.playbackRate = 1.0;
            active.reversed = false;
        }
        if (active.opacity > 0.000_001) result.video ~= active;
    }
    return result;
}

private double fadeEnvelopeValue(const ref ExportClip clip, double localTime)
{
    double result = 1.0;
    if (clip.fadeIn > 0.000_001)
        result *= min(1.0, max(0.0, localTime / clip.fadeIn));
    if (clip.fadeOut > 0.000_001)
        result *= min(1.0, max(0.0,
            (clip.duration() - localTime) / clip.fadeOut));
    return result;
}

private bool isStillImagePath(string path)
{
    const suffix = extension(path).toLower();
    return suffix == ".png" || suffix == ".jpg" || suffix == ".jpeg" ||
        suffix == ".webp" || suffix == ".bmp";
}

private bool isHardwareDecodeCandidatePath(string path)
{
    const suffix = extension(path).toLower();
    return suffix == ".mp4" || suffix == ".mov" || suffix == ".mkv" ||
        suffix == ".webm";
}

private InputClip[] collectInputs(const ExportRequest request, bool includeVideo,
    bool includeAudio)
{
    InputClip[] result;
    int fileInputIndex;
    foreach (clip; request.video)
    {
        if (clip.trackDisabled || clip.duration() <= 0.0) continue;
        if (clip.generatedText && (!request.renderTitles ||
            clip.titleRasterPath.length == 0)) continue;
        const needed = (includeVideo && (clip.hasVideo || clip.generatedText)) ||
            (includeAudio && clip.hasAudio);
        if (!needed) continue;
        InputClip value;
        value.clip = cloneExportClip(clip);
        value.videoTrack = true;
        value.inputIndex = fileInputIndex++;
        if (includeVideo && clip.hasVideo && !clip.generatedText &&
            isHardwareDecodeCandidatePath(clip.path))
            value.decodeInputOptions = request.videoDecodeInputOptions.dup;
        result ~= value;
    }
    if (includeAudio) foreach (clip; request.audio)
    {
        if (clip.trackDisabled || clip.duration() <= 0.0 || !clip.hasAudio) continue;
        InputClip value;
        value.clip = cloneExportClip(clip);
        value.videoTrack = false;
        value.inputIndex = fileInputIndex++;
        result ~= value;
    }
    return result;
}

private void appendInputArguments(ref string[] arguments, const InputClip[] inputs)
{
    foreach (input; inputs)
    {
        if (input.clip.generatedText)
        {
            arguments ~= [
                "-loop", "1", "-framerate", "30",
                "-t", formatSeconds(input.clip.duration()),
                "-i", input.clip.titleRasterPath
            ];
            continue;
        }
        const stillImage = isStillImagePath(input.clip.path);
        if (stillImage) arguments ~= ["-loop", "1"];
        else
        {
            string[] decodeOptions = input.decodeInputOptions.dup;
            const codec = input.clip.videoCodec.toLower();
            // Hardware decode (D3D11VA/DXVA2/CUDA) was probed against an H.264
            // sample at startup. Applying it to a stream whose stored codec is
            // different or unknown makes that decode fail and the compositor
            // output pure black frames — an AV1 .webm with an empty stored
            // codec name reproduced exactly that. Only known H.264/HEVC keep
            // the probed accelerator; everything else decodes on the CPU where
            // FFmpeg automatically selects the correct decoder.
            if (codec != "h264" && codec != "hevc" && codec != "h265")
                decodeOptions.length = 0;
            // AV1 preview decoding must stay deterministic and CPU-based:
            // dav1d keeps high-resolution AV1 preview decoding stable, and the
            // stream worker can still fall back to FFmpeg's default decoder if
            // this optional decoder is unavailable.
            if (codec == "av1" || (codec.length == 0 &&
                input.clip.sourceWidth >= 2560 && input.clip.sourceHeight >= 1440))
                decodeOptions = ["-c:v", "libdav1d"];
            if (decodeOptions.length > 0) arguments ~= decodeOptions;
        }
        arguments ~= [
            "-ss", formatSeconds(input.clip.inPoint),
            "-t", formatSeconds(max(0.0, input.clip.outPoint - input.clip.inPoint)),
            "-i", input.clip.path
        ];
    }
}

private string buildFilterGraph(const ExportRequest request, const InputClip[] inputs,
    double duration, bool includeVideo, bool includeAudio)
{
    string graph;
    if (includeVideo)
    {
        graph ~= format("color=c=black:s=%dx%d:r=%d:d=%s,format=rgba[canvas0];\n",
            request.preset.width, request.preset.height, request.preset.fps,
            formatSeconds(duration));
        string canvas = "canvas0";
        size_t overlayIndex;
        foreach (input; inputs)
        {
            const clip = input.clip;
            if (!input.videoTrack || (!clip.hasVideo && !clip.generatedText) ||
                clip.trackDisabled || clip.opacity <= 0.000_001 &&
                !hasPropertyAnimation(clip, EffectProperty.opacity)) continue;

            const video = format("v%04d", overlayIndex);
            const nextCanvas = format("canvas%04d", overlayIndex + 1);
            if (clip.generatedText)
                appendRasterTitleLayer(graph, input, request.preset, video);
            else
                appendMediaVideoLayer(graph, input, request.preset, video);

            const localTime = format("(t-%s)", formatSeconds(clip.start, 6));
            const positionX = effectExpression(clip,
                EffectProperty.positionX, localTime);
            const positionY = effectExpression(clip,
                EffectProperty.positionY, localTime);
            const offsetX = format("(%s)*%d*0.5", positionX,
                request.preset.width);
            const offsetY = format("(%s)*%d*0.5", positionY,
                request.preset.height);
            graph ~= format("[%s][%s]overlay=x='(main_w-overlay_w)/2+%s':" ~
                "y='(main_h-overlay_h)/2+%s':eof_action=pass:repeatlast=0:" ~
                "shortest=0[%s];\n", canvas, video, offsetX, offsetY,
                nextCanvas);
            canvas = nextCanvas;
            ++overlayIndex;
        }
        graph ~= format("[%s]trim=duration=%s,fps=%d,format=yuv420p[vout];\n",
            canvas, formatSeconds(duration), request.preset.fps);
    }

    if (includeAudio)
    {
        string[] audioLabels;
        size_t audioIndex;
        foreach (input; inputs)
        {
            const clip = input.clip;
            if (clip.generatedText || !clip.hasAudio || clip.trackDisabled ||
                clip.trackMuted || clip.muted || !hasAudiblePotential(clip)) continue;
            const label = format("a%04d", audioIndex++);
            const delayMs = cast(long) (max(0.0, clip.start) * 1000.0 + 0.5);
            const volume = effectExpression(clip, EffectProperty.volume, "t");
            graph ~= format("[%d:a:0]", input.inputIndex);
            if (clip.reversed) graph ~= "areverse,";
            if (fabs(clip.playbackRate - 1.0) > 0.000_001)
                graph ~= format("atempo=%s,", formatSeconds(clip.playbackRate, 6));
            graph ~= format("aresample=48000," ~
                "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo," ~
                "volume='max(0,%s)':eval=frame", volume);
            if (clip.fadeIn > 0.000_001)
                graph ~= format(",afade=t=in:st=0:d=%s",
                    formatSeconds(clip.fadeIn, 6));
            if (clip.fadeOut > 0.000_001)
                graph ~= format(",afade=t=out:st=%s:d=%s",
                    formatSeconds(max(0.0, clip.duration() - clip.fadeOut), 6),
                    formatSeconds(clip.fadeOut, 6));
            graph ~= format(",adelay=%d:all=1[%s];\n", delayMs, label);
            audioLabels ~= "[" ~ label ~ "]";
        }
        if (audioLabels.length == 0)
        {
            graph ~= format("anullsrc=r=48000:cl=stereo:d=%s[aout];\n",
                formatSeconds(duration));
        }
        else
        {
            string joined;
            foreach (label; audioLabels) joined ~= label;
            graph ~= format("%samix=inputs=%d:duration=longest:dropout_transition=0," ~
                "atrim=duration=%s,alimiter=limit=0.95[aout];\n", joined,
                audioLabels.length, formatSeconds(duration));
        }
    }
    return graph;
}

private void appendMediaVideoLayer(ref string graph, const InputClip input,
    const ExportPreset preset, string outputLabel)
{
    const clip = input.clip;
    int baseWidth;
    int baseHeight;
    fittedBaseSize(clip, preset, baseWidth, baseHeight);
    const localTime = format("(t-%s)", formatSeconds(clip.start, 6));
    const scale = effectExpression(clip, EffectProperty.scale, localTime);
    const maximumWidth = preset.width * 4;
    const maximumHeight = preset.height * 4;
    const widthExpression = format(
        "trunc(min(%d,max(2,%d*(%s)))/2)*2", maximumWidth, baseWidth, scale);
    const heightExpression = format(
        "trunc(min(%d,max(2,%d*(%s)))/2)*2", maximumHeight, baseHeight, scale);

    graph ~= format("[%d:v:0]", input.inputIndex);
    if (clip.reversed) graph ~= "reverse,";
    graph ~= format("setpts=(PTS-STARTPTS)/%s+%s/TB,",
        formatSeconds(clip.playbackRate, 6), formatSeconds(clip.start));
    if (clip.cropEnabled)
    {
        const sourceWidth = clip.sourceWidth > 0 ? clip.sourceWidth : preset.width;
        const sourceHeight = clip.sourceHeight > 0 ? clip.sourceHeight : preset.height;
        const cropX = min(0.995, max(0.0, clip.cropX));
        const cropY = min(0.995, max(0.0, clip.cropY));
        const cropWidth = max(0.005, min(1.0 - cropX, clip.cropWidth));
        const cropHeight = max(0.005, min(1.0 - cropY, clip.cropHeight));
        const cropPixelWidth = max(2, min(sourceWidth,
            cast(int) (cast(double) sourceWidth * cropWidth + 0.5)));
        const cropPixelHeight = max(2, min(sourceHeight,
            cast(int) (cast(double) sourceHeight * cropHeight + 0.5)));
        const cropPixelX = max(0, min(sourceWidth - cropPixelWidth,
            cast(int) (cast(double) sourceWidth * cropX + 0.5)));
        const cropPixelY = max(0, min(sourceHeight - cropPixelHeight,
            cast(int) (cast(double) sourceHeight * cropY + 0.5)));
        graph ~= format("crop=w=%d:h=%d:x=%d:y=%d,",
            cropPixelWidth, cropPixelHeight, cropPixelX, cropPixelY);
    }
    graph ~= format("scale=w='%s':h='%s':eval=frame:flags=bicubic,format=rgba",
        widthExpression, heightExpression);

    if (clip.strokeWidth > 0.000_001)
        graph ~= format(",drawbox=x=0:y=0:w=iw:h=ih:color=%s:t=%s",
            colorLiteral(clip.strokeColor, true),
            formatSeconds(clip.strokeWidth, 4));

    if (clip.rotation != 0.0 || hasPropertyAnimation(clip, EffectProperty.rotation))
    {
        const rotation = effectExpression(clip, EffectProperty.rotation, localTime);
        graph ~= format(",rotate=angle='(%s)*PI/180':ow=iw:oh=ih:c=none",
            rotation);
    }

    if (hasPropertyAnimation(clip, EffectProperty.opacity))
    {
        const opacity = effectExpression(clip, EffectProperty.opacity,
            format("(T-%s)", formatSeconds(clip.start, 6)));
        graph ~= format(",geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':" ~
            "a='alpha(X,Y)*clip(%s,0,1)'", opacity);
    }
    else if (clip.opacity < 0.999_999)
        graph ~= format(",colorchannelmixer=aa=%s",
            formatSeconds(max(0.0, clip.opacity), 6));

    if (clip.fadeIn > 0.000_001)
        graph ~= format(",fade=t=in:st=%s:d=%s:alpha=1",
            formatSeconds(clip.start, 6), formatSeconds(clip.fadeIn, 6));
    if (clip.fadeOut > 0.000_001)
        graph ~= format(",fade=t=out:st=%s:d=%s:alpha=1",
            formatSeconds(max(clip.start, clip.end() - clip.fadeOut), 6),
            formatSeconds(clip.fadeOut, 6));
    if (clip.blur > 0.000_001)
        graph ~= format(",gblur=sigma=%s:steps=2",
            formatSeconds(clip.blur, 5));

    if (clip.shadowOpacity <= 0.000_001)
    {
        graph ~= format("[%s];\n", outputLabel);
        return;
    }

    const baseLabel = outputLabel ~ "base";
    const paddedLabel = outputLabel ~ "padded";
    const mainLabel = outputLabel ~ "main";
    const shadowSource = outputLabel ~ "shadowsource";
    const blankSource = outputLabel ~ "blanksource";
    const shadowLabel = outputLabel ~ "shadow";
    const blankLabel = outputLabel ~ "blank";
    const shiftedLabel = outputLabel ~ "shifted";
    const margin = cast(int) (max(fabs(clip.shadowOffsetX),
        fabs(clip.shadowOffsetY)) + clip.shadowBlur * 3.0 + 6.0);
    graph ~= format("[%s];\n[%s]pad=iw+%d:ih+%d:%d:%d:color=black@0.0[%s];\n",
        baseLabel, baseLabel, margin * 2, margin * 2, margin, margin, paddedLabel);
    graph ~= format("[%s]split=3[%s][%s][%s];\n", paddedLabel,
        mainLabel, shadowSource, blankSource);
    const shadowRed = cast(int) ((clip.shadowColor >> 16) & 0xff);
    const shadowGreen = cast(int) ((clip.shadowColor >> 8) & 0xff);
    const shadowBlue = cast(int) (clip.shadowColor & 0xff);
    const shadowColorAlpha = cast(double) ((clip.shadowColor >> 24) & 0xff) / 255.0;
    const shadowAlpha = clip.shadowOpacity * shadowColorAlpha;
    graph ~= format("[%s]geq=r='%d':g='%d':b='%d':a='alpha(X,Y)*%s'",
        shadowSource, shadowRed, shadowGreen, shadowBlue,
        formatSeconds(shadowAlpha, 6));
    if (clip.shadowBlur > 0.000_001)
        graph ~= format(",gblur=sigma=%s:steps=2",
            formatSeconds(clip.shadowBlur, 5));
    graph ~= format("[%s];\n[%s]colorchannelmixer=aa=0[%s];\n",
        shadowLabel, blankSource, blankLabel);
    graph ~= format("[%s][%s]overlay=x=%s:y=%s:eof_action=pass:" ~
        "repeatlast=0:shortest=0[%s];\n", blankLabel, shadowLabel,
        formatSeconds(clip.shadowOffsetX, 4),
        formatSeconds(clip.shadowOffsetY, 4), shiftedLabel);
    graph ~= format("[%s][%s]overlay=x=0:y=0:eof_action=pass:" ~
        "repeatlast=0:shortest=0[%s];\n", shiftedLabel, mainLabel, outputLabel);
}

/** Transform an Aurora-rendered transparent title image for its timeline clip. */
private void appendRasterTitleLayer(ref string graph, const InputClip input,
    const ExportPreset preset, string outputLabel)
{
    const clip = input.clip;
    const baseSize = clip.titleRasterBaseSize > 0.000_001 ?
        clip.titleRasterBaseSize : max(8.0, clip.textSize);
    const textSize = effectExpression(clip, EffectProperty.textSize, "t");
    const scale = effectExpression(clip, EffectProperty.scale, "t");
    const factor = format("max(0.01,(%s)*((%s)/%s))", scale, textSize,
        formatSeconds(baseSize, 6));
    const opacity = effectExpression(clip, EffectProperty.opacity, "T");
    const envelope = fadeEnvelopeExpression(clip, "T");
    const alpha = format("clip((%s)*(%s),0,1)", opacity, envelope);

    graph ~= format("[%d:v:0]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':" ~
        "b='b(X,Y)':a='alpha(X,Y)*(%s)'", input.inputIndex, alpha);
    graph ~= format(",scale=w='max(1,round(iw*(%s)))':" ~
        "h='max(1,round(ih*(%s)))':eval=frame", factor, factor);
    if (clip.blur > 0.000_001)
        graph ~= format(",gblur=sigma=%s:steps=2",
            formatSeconds(clip.blur, 5));
    if (clip.rotation != 0.0 ||
        hasPropertyAnimation(clip, EffectProperty.rotation))
    {
        const rotation = effectExpression(clip, EffectProperty.rotation, "t");
        graph ~= format(",rotate=angle='(%s)*PI/180':" ~
            "ow='rotw(iw)':oh='roth(ih)':c=none", rotation);
    }
    graph ~= format(",setpts=PTS-STARTPTS+%s/TB[%s];\n",
        formatSeconds(clip.start), outputLabel);
}

private string effectExpression(const ref ExportClip clip,
    EffectProperty property, string timeExpression)
{
    EffectKeyframe[] points;
    foreach (keyframe; clip.keyframes)
        if (keyframe.property == property) points ~= keyframe;
    if (points.length == 0) return formatSeconds(clip.baseValue(property), 7);

    string result = formatSeconds(points[$ - 1].value, 7);
    for (size_t index = points.length - 1; index > 0; --index)
    {
        const left = points[index - 1];
        const right = points[index];
        const span = right.time - left.time;
        string segment;
        if (span <= 0.000_000_5)
            segment = formatSeconds(right.value, 7);
        else if (left.interpolation == KeyframeInterpolation.hold)
            segment = formatSeconds(left.value, 7);
        else
        {
            const normalized = format("clip(((%s)-%s)/%s,0,1)", timeExpression,
                formatSeconds(left.time, 7), formatSeconds(span, 7));
            const amount = left.interpolation == KeyframeInterpolation.bezier ?
                format("(%s)*(%s)*(3-2*(%s))", normalized, normalized, normalized) :
                normalized;
            segment = format("%s+(%s-%s)*(%s)",
                formatSeconds(left.value, 7), formatSeconds(right.value, 7),
                formatSeconds(left.value, 7), amount);
        }
        result = format("if(lt((%s),%s),(%s),(%s))", timeExpression,
            formatSeconds(right.time, 7), segment, result);
    }
    return format("if(lte((%s),%s),%s,(%s))", timeExpression,
        formatSeconds(points[0].time, 7), formatSeconds(points[0].value, 7), result);
}

private string fadeEnvelopeExpression(const ref ExportClip clip,
    string timeExpression)
{
    string result = "1";
    if (clip.fadeIn > 0.000_001)
        result ~= format("*min(1,max(0,(%s)/%s))", timeExpression,
            formatSeconds(clip.fadeIn, 7));
    if (clip.fadeOut > 0.000_001)
        result ~= format("*min(1,max(0,(%s-(%s))/%s))",
            formatSeconds(clip.duration(), 7), timeExpression,
            formatSeconds(clip.fadeOut, 7));
    return result;
}

private bool hasPropertyAnimation(const ref ExportClip clip,
    EffectProperty property)
{
    foreach (keyframe; clip.keyframes)
        if (keyframe.property == property) return true;
    return false;
}

private bool hasAudiblePotential(const ref ExportClip clip)
{
    if (clip.volume > 0.000_001) return true;
    foreach (keyframe; clip.keyframes)
        if (keyframe.property == EffectProperty.volume && keyframe.value > 0.000_001)
            return true;
    return false;
}

private string colorLiteral(uint argb, bool includeAlpha)
{
    const alpha = cast(double) ((argb >> 24) & 0xff) / 255.0;
    const rgb = argb & 0x00ffffff;
    return includeAlpha ? format("0x%06x@%s", rgb, formatSeconds(alpha, 5)) :
        format("0x%06x", rgb);
}

private void fittedBaseSize(const ExportClip clip, const ExportPreset preset,
    out int width, out int height)
{
    auto sourceWidth = cast(double) (clip.sourceWidth > 0 ? clip.sourceWidth : preset.width);
    auto sourceHeight = cast(double) (clip.sourceHeight > 0 ? clip.sourceHeight : preset.height);
    const fit = min(cast(double) preset.width / sourceWidth,
        cast(double) preset.height / sourceHeight);
    sourceWidth *= fit;
    sourceHeight *= fit;
    if (clip.cropEnabled)
    {
        const cropX = min(0.995, max(0.0, clip.cropX));
        const cropY = min(0.995, max(0.0, clip.cropY));
        sourceWidth *= max(0.005, min(1.0 - cropX, clip.cropWidth));
        sourceHeight *= max(0.005, min(1.0 - cropY, clip.cropHeight));
    }
    width = evenDimension(cast(int) (sourceWidth + 0.5));
    height = evenDimension(cast(int) (sourceHeight + 0.5));
    width = max(2, min(width, preset.width * 4));
    height = max(2, min(height, preset.height * 4));
}

private int evenDimension(int value)
{
    value = max(2, value);
    return value % 2 == 0 ? value : value + 1;
}

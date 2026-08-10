module auroracut.preview;

import aurora;
import auroracut.exporter : ExportRequest, compositeFrameArguments;
import auroracut.model : MediaAsset, TextAlignment;
import auroracut.titlelayer : TitleVisual, loadTitleFace, titlePaintStyle;
import auroracut.textfonts : canonicalTextFontName, textFontFamilies,
    textFontFilePath;
import auroracut.util : clampValue, formatSeconds, formatTimecode;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : ConvException, parse, to;
import std.format : format;
import std.math : PI, cos, sin, sqrt;
import std.path : extension;
import std.process : Config, Pid, ProcessPipes, Redirect, kill, pipeProcess, wait;
import std.string : toLower;
import std.utf : toUTF32;

/** RGB24 frame displayed by Aurora's preview canvas. */
struct PreviewFrame
{
    int width;
    int height;
    ubyte[] rgb;
    string title;
    string error;
    double sourceTime = 0.0;

    bool valid() const @safe pure nothrow @nogc
    {
        return width > 0 && height > 0 &&
            rgb.length >= cast(size_t) width * cast(size_t) height * 3;
    }
}

private enum PreviewRequestKind : ubyte
{
    none,
    asset,
    composition
}

private enum SelectionEdge : int
{
    none = 0,
    left = 1,
    right = 2,
    top = 4,
    bottom = 8
}

private struct PreviewRequest
{
    ulong generation;
    PreviewRequestKind kind;
    MediaAsset asset;
    ExportRequest composition;
    double time;
    int width;
    int height;
    string[] decodeInputOptions;
    bool publish = true;
}

struct PreviewServiceStats
{
    ulong requests;
    ulong processesStarted;
    ulong framesRendered;
    ulong cacheHits;
    ulong cancellations;
    ulong staleFrames;
}

private HorizontalAlign titleHorizontalAlign(TextAlignment alignment)
{
    final switch (alignment)
    {
        case TextAlignment.left: return HorizontalAlign.left;
        case TextAlignment.center: return HorizontalAlign.center;
        case TextAlignment.right: return HorizontalAlign.right;
    }
}

private bool isHardwareDecodeCandidatePath(string path)
{
    const suffix = extension(path).toLower();
    return suffix == ".mp4" || suffix == ".mov" || suffix == ".mkv" ||
        suffix == ".webm";
}

private struct AssetPreviewCacheEntry
{
    string path;
    long timeMilliseconds;
    int width;
    int height;
    ubyte[] rgb;
    ulong lastUse;
}
private struct PreviewCacheEntry
{
    ulong modelKey;
    long frameIndex;
    int width;
    int height;
    ubyte[] rgb;
    ulong lastUse;
}

/**
 * Cancellable, allocation-stable static-frame renderer.
 *
 * One persistent daemon worker consumes only the newest request. Obsolete
 * FFmpeg processes are terminated immediately, output is read directly as
 * RGB24 (no temporary PPM files), and three reusable buffers prevent repeated
 * 6–12 MiB allocations while scrubbing 1080p media.
 */
final class PreviewService
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private Pid _process;
    private PreviewRequest _pending;
    private bool _hasPending;
    private bool _rendering;
    private bool _shutdown;
    private ulong _generation;

    private ubyte[][3] _slots;
    private int _displayedSlot = -1;
    private int _readySlot = -1;
    private int _writingSlot = -1;
    private PreviewFrame _ready;
    private PreviewServiceStats _stats;
    private PreviewCacheEntry[] _compositionCache;
    private AssetPreviewCacheEntry[] _assetCache;
    private size_t _cacheBytes;
    private size_t _assetCacheBytes;
    private ulong _cacheClock;

    private enum size_t maximumCacheBytes = 48 * 1024 * 1024;
    private enum size_t maximumCacheEntries = 12;
    private enum size_t maximumAssetCacheBytes = 24 * 1024 * 1024;
    private enum size_t maximumAssetCacheEntries = 6;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread({ workerLoop(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    void request(MediaAsset asset, double sourceTime)
    {
        requestAsset(asset, sourceTime, 960, 540);
    }

    void requestAsset(MediaAsset asset, double sourceTime, int width, int height,
        string[] decodeInputOptions = null)
    {
        if (asset is null) return;
        normalizeSize(width, height);
        PreviewRequest request;
        request.kind = PreviewRequestKind.asset;
        request.asset = asset;
        request.time = sourceTime;
        request.width = width;
        request.height = height;
        if (asset.hasVideo && isHardwareDecodeCandidatePath(asset.path))
            request.decodeInputOptions = decodeInputOptions.dup;
        request.publish = true;
        enqueue(request);
    }

    /** Decode and cache a source frame without replacing Composition Preview. */
    void requestWarmAsset(MediaAsset asset, double sourceTime, int width, int height,
        string[] decodeInputOptions = null)
    {
        if (asset is null) return;
        normalizeSize(width, height);
        PreviewRequest request;
        request.kind = PreviewRequestKind.asset;
        request.asset = asset;
        request.time = sourceTime;
        request.width = width;
        request.height = height;
        if (asset.hasVideo && isHardwareDecodeCandidatePath(asset.path))
            request.decodeInputOptions = decodeInputOptions.dup;
        request.publish = false;
        enqueue(request);
    }

    void requestComposition(ExportRequest request, double sequenceTime,
        int width, int height)
    {
        normalizeSize(width, height);
        if (request.preset.width <= 0) request.preset.width = width;
        if (request.preset.height <= 0) request.preset.height = height;
        if (request.preset.fps <= 0) request.preset.fps = 30;

        PreviewRequest pending;
        pending.kind = PreviewRequestKind.composition;
        pending.composition = request;
        pending.time = sequenceTime;
        pending.width = width;
        pending.height = height;
        pending.publish = true;
        enqueue(pending);
    }

    private void enqueue(PreviewRequest request)
    {
        Pid process;
        _mutex.lock();
        if (_shutdown)
        {
            _mutex.unlock();
            return;
        }
        request.generation = ++_generation;
        _pending = request;
        _hasPending = true;
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
    }

    void cancel()
    {
        Pid process;
        _mutex.lock();
        ++_generation;
        _hasPending = false;
        _readySlot = -1;
        _ready = PreviewFrame.init;
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

    void shutdown()
    {
        Pid process;
        _mutex.lock();
        if (!_shutdown)
        {
            _shutdown = true;
            ++_generation;
            _hasPending = false;
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

    bool busy()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _rendering || _hasPending;
    }

    PreviewServiceStats stats()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _stats;
    }

    private static void normalizeSize(ref int width, ref int height)
    {
        width = clampValue(width, 160, 3840);
        height = clampValue(height, 90, 2160);
        if ((width & 1) != 0) ++width;
        if ((height & 1) != 0) ++height;
    }

    private void workerLoop()
    {
        while (true)
        {
            PreviewRequest request;
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
            _rendering = true;
            _mutex.unlock();

            renderRequest(request);

            _mutex.lock();
            _rendering = false;
            _mutex.unlock();
        }
    }

    private void renderRequest(PreviewRequest request)
    {
        if (request.kind == PreviewRequestKind.asset &&
            tryPublishCachedAsset(request)) return;
        if (request.kind == PreviewRequestKind.composition &&
            tryPublishCachedComposition(request)) return;

        string[] arguments;
        string title;
        double renderedTime;

        final switch (request.kind)
        {
            case PreviewRequestKind.asset:
                if (request.asset is null)
                {
                    if (request.publish)
                        publishError(request.generation,
                            "Preview media is unavailable.");
                    return;
                }
                renderedTime = clampValue(request.time, 0.0,
                    request.asset.duration > 0.0 ? request.asset.duration : 0.0);
                title = request.asset.name;
                if (request.asset.hasVideo)
                {
                    const filter = format(
                        "scale=%d:%d:force_original_aspect_ratio=decrease:flags=bicubic," ~
                        "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black",
                        request.width, request.height, request.width, request.height);
                    arguments = [
                        "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
                        "-threads", "1", "-filter_threads", "1"
                    ];
                    if (request.decodeInputOptions.length > 0)
                        arguments ~= request.decodeInputOptions;
                    arguments ~= [
                        "-ss", formatSeconds(renderedTime, 6), "-i", request.asset.path,
                        "-frames:v", "1", "-an", "-sn", "-dn",
                        "-vf", filter, "-pix_fmt", "rgb24",
                        "-f", "rawvideo", "pipe:1"
                    ];
                }
                else
                {
                    const filter = format(
                        "aformat=channel_layouts=mono," ~
                        "showwavespic=s=%dx%d:colors=0x4f8cff",
                        request.width, request.height);
                    arguments = [
                        "ffmpeg", "-hide_banner", "-loglevel", "fatal", "-nostdin",
                        "-threads", "1", "-filter_threads", "1",
                        "-i", request.asset.path, "-filter_complex", filter,
                        "-frames:v", "1", "-pix_fmt", "rgb24",
                        "-f", "rawvideo", "pipe:1"
                    ];
                }
                break;

            case PreviewRequestKind.composition:
                renderedTime = clampValue(request.time, 0.0,
                    request.composition.sequenceDuration() > 0.0 ?
                    request.composition.sequenceDuration() : 0.0);
                title = "Sequence composition";
                arguments = compositeFrameArguments(request.composition, renderedTime,
                    request.width, request.height);
                break;

            case PreviewRequestKind.none:
                if (request.publish)
                    publishError(request.generation,
                        "No preview request was available.");
                return;
        }

        const frameBytes = cast(size_t) request.width *
            cast(size_t) request.height * 3;
        const slot = acquireWriteSlot(request.generation, frameBytes);
        if (slot < 0) return;

        ProcessPipes pipes;
        try
        {
            pipes = pipeProcess(arguments, Redirect.stdout,
                cast(const string[string]) null, Config.suppressConsole);
        }
        catch (Exception error)
        {
            releaseWriteSlot(slot);
            if (canRetryWithoutHardwareDecode(request))
            {
                renderRequest(cpuDecodeFallbackRequest(request));
                return;
            }
            if (request.publish) publishError(request.generation, error.msg);
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
            releaseWriteSlot(slot);
            try pipes.stdout.close();
            catch (Exception) {}
            try kill(pipes.pid);
            catch (Exception) {}
            try wait(pipes.pid);
            catch (Exception) {}
            return;
        }

        size_t received;
        try
        {
            while (received < frameBytes)
            {
                auto chunk = pipes.stdout.rawRead(_slots[slot][received .. frameBytes]);
                if (chunk.length == 0) break;
                received += chunk.length;
            }
        }
        catch (Exception)
        {
            received = 0;
        }
        try pipes.stdout.close();
        catch (Exception) {}
        try wait(pipes.pid);
        catch (Exception) {}

        bool acceptedFrame;
        bool retryWithoutHardwareDecode;
        _mutex.lock();
        if (_process is pipes.pid) _process = null;
        const current = request.generation == _generation && !_shutdown;
        if (_writingSlot == slot) _writingSlot = -1;
        retryWithoutHardwareDecode = current && received != frameBytes &&
            canRetryWithoutHardwareDecode(request);
        if (!retryWithoutHardwareDecode && current && received == frameBytes)
        {
            if (request.publish)
            {
                _readySlot = slot;
                _ready = PreviewFrame.init;
                _ready.width = request.width;
                _ready.height = request.height;
                _ready.title = title;
                _ready.sourceTime = renderedTime;
            }
            ++_stats.framesRendered;
            acceptedFrame = true;
        }
        else if (!current)
            ++_stats.staleFrames;
        else if (request.publish)
        {
            _ready = PreviewFrame.init;
            _ready.error = "FFmpeg did not return a complete preview frame.";
            _readySlot = -2;
        }
        _mutex.unlock();

        if (retryWithoutHardwareDecode)
        {
            renderRequest(cpuDecodeFallbackRequest(request));
            return;
        }
        if (acceptedFrame && request.kind == PreviewRequestKind.asset &&
            request.asset !is null)
            storeAssetCache(request, _slots[slot]);
        else if (acceptedFrame && request.kind == PreviewRequestKind.composition &&
            request.composition.cacheKey != 0)
            storeCompositionCache(request, _slots[slot]);
    }

    private bool canRetryWithoutHardwareDecode(const PreviewRequest request) const
    {
        return request.decodeInputOptions.length > 0 ||
            request.composition.videoDecodeInputOptions.length > 0;
    }

    private PreviewRequest cpuDecodeFallbackRequest(PreviewRequest request) const
    {
        request.decodeInputOptions.length = 0;
        request.composition.videoDecodeInputOptions.length = 0;
        request.composition.videoDecodeAcceleration = "CPU decode";
        request.composition.hardwareVideoDecoding = false;
        return request;
    }

    private bool tryPublishCachedAsset(PreviewRequest request)
    {
        if (request.asset is null || request.asset.path.length == 0) return false;
        const timeMilliseconds = cast(long) (request.time * 1000.0 + 0.5);
        int found = -1;
        foreach (index, ref entry; _assetCache)
        {
            if (entry.path == request.asset.path &&
                entry.timeMilliseconds == timeMilliseconds &&
                entry.width == request.width && entry.height == request.height)
            {
                found = cast(int) index;
                entry.lastUse = ++_cacheClock;
                break;
            }
        }
        if (found < 0) return false;
        if (!request.publish)
        {
            ++_stats.cacheHits;
            return true;
        }

        const frameBytes = cast(size_t) request.width *
            cast(size_t) request.height * 3;
        const slot = acquireWriteSlot(request.generation, frameBytes);
        if (slot < 0) return false;
        _slots[slot][] = _assetCache[cast(size_t) found].rgb[];

        _mutex.lock();
        if (_writingSlot == slot) _writingSlot = -1;
        const current = request.generation == _generation && !_shutdown;
        if (current)
        {
            _readySlot = slot;
            _ready = PreviewFrame.init;
            _ready.width = request.width;
            _ready.height = request.height;
            _ready.title = request.asset.name ~ " (cached)";
            _ready.sourceTime = request.time;
            ++_stats.cacheHits;
            ++_stats.framesRendered;
        }
        else
            ++_stats.staleFrames;
        _mutex.unlock();
        return current;
    }

    private void storeAssetCache(PreviewRequest request, const ubyte[] pixels)
    {
        if (request.asset is null || request.asset.path.length == 0 ||
            pixels.length == 0 || pixels.length > maximumAssetCacheBytes) return;
        const timeMilliseconds = cast(long) (request.time * 1000.0 + 0.5);
        foreach (ref entry; _assetCache)
        {
            if (entry.path == request.asset.path &&
                entry.timeMilliseconds == timeMilliseconds &&
                entry.width == request.width && entry.height == request.height)
            {
                _assetCacheBytes -= entry.rgb.length;
                entry.rgb = pixels.dup;
                _assetCacheBytes += entry.rgb.length;
                entry.lastUse = ++_cacheClock;
                trimAssetCache();
                return;
            }
        }

        AssetPreviewCacheEntry entry;
        entry.path = request.asset.path.idup;
        entry.timeMilliseconds = timeMilliseconds;
        entry.width = request.width;
        entry.height = request.height;
        entry.rgb = pixels.dup;
        entry.lastUse = ++_cacheClock;
        _assetCacheBytes += entry.rgb.length;
        _assetCache ~= entry;
        trimAssetCache();
    }

    private void trimAssetCache()
    {
        while (_assetCache.length > maximumAssetCacheEntries ||
            _assetCacheBytes > maximumAssetCacheBytes)
        {
            size_t oldest;
            foreach (index; 1 .. _assetCache.length)
                if (_assetCache[index].lastUse < _assetCache[oldest].lastUse)
                    oldest = index;
            _assetCacheBytes -= _assetCache[oldest].rgb.length;
            foreach (index; oldest .. _assetCache.length - 1)
                _assetCache[index] = _assetCache[index + 1];
            _assetCache.length = _assetCache.length - 1;
        }
    }

    private bool tryPublishCachedComposition(PreviewRequest request)
    {
        const key = request.composition.cacheKey;
        if (key == 0) return false;
        const fps = request.composition.preset.fps > 0 ?
            request.composition.preset.fps : 30;
        const frameIndex = cast(long) (request.time * fps + 0.5);

        int found = -1;
        foreach (index, ref entry; _compositionCache)
        {
            if (entry.modelKey == key && entry.frameIndex == frameIndex &&
                entry.width == request.width && entry.height == request.height)
            {
                found = cast(int) index;
                entry.lastUse = ++_cacheClock;
                break;
            }
        }
        if (found < 0) return false;

        const frameBytes = cast(size_t) request.width *
            cast(size_t) request.height * 3;
        const slot = acquireWriteSlot(request.generation, frameBytes);
        if (slot < 0) return false;
        _slots[slot][] = _compositionCache[cast(size_t) found].rgb[];

        _mutex.lock();
        if (_writingSlot == slot) _writingSlot = -1;
        const current = request.generation == _generation && !_shutdown;
        if (current)
        {
            _readySlot = slot;
            _ready = PreviewFrame.init;
            _ready.width = request.width;
            _ready.height = request.height;
            _ready.title = "Sequence composition (cached)";
            _ready.sourceTime = request.time;
            ++_stats.cacheHits;
            ++_stats.framesRendered;
        }
        else
            ++_stats.staleFrames;
        _mutex.unlock();
        return current;
    }

    private void storeCompositionCache(PreviewRequest request, const ubyte[] pixels)
    {
        const key = request.composition.cacheKey;
        if (key == 0 || pixels.length == 0 || pixels.length > maximumCacheBytes)
            return;
        const fps = request.composition.preset.fps > 0 ?
            request.composition.preset.fps : 30;
        const frameIndex = cast(long) (request.time * fps + 0.5);

        foreach (ref entry; _compositionCache)
        {
            if (entry.modelKey == key && entry.frameIndex == frameIndex &&
                entry.width == request.width && entry.height == request.height)
            {
                _cacheBytes -= entry.rgb.length;
                entry.rgb = pixels.dup;
                _cacheBytes += entry.rgb.length;
                entry.lastUse = ++_cacheClock;
                trimCompositionCache();
                return;
            }
        }

        PreviewCacheEntry entry;
        entry.modelKey = key;
        entry.frameIndex = frameIndex;
        entry.width = request.width;
        entry.height = request.height;
        entry.rgb = pixels.dup;
        entry.lastUse = ++_cacheClock;
        _cacheBytes += entry.rgb.length;
        _compositionCache ~= entry;
        trimCompositionCache();
    }

    private void trimCompositionCache()
    {
        while (_compositionCache.length > maximumCacheEntries ||
            _cacheBytes > maximumCacheBytes)
        {
            size_t oldest;
            foreach (index; 1 .. _compositionCache.length)
                if (_compositionCache[index].lastUse < _compositionCache[oldest].lastUse)
                    oldest = index;
            _cacheBytes -= _compositionCache[oldest].rgb.length;
            foreach (index; oldest .. _compositionCache.length - 1)
                _compositionCache[index] = _compositionCache[index + 1];
            _compositionCache.length = _compositionCache.length - 1;
        }
    }

    private int acquireWriteSlot(ulong generation, size_t frameBytes)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (generation != _generation || _shutdown) return -1;
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
            return slot;
        }
        return -1;
    }

    private void releaseWriteSlot(int slot)
    {
        _mutex.lock();
        if (_writingSlot == slot) _writingSlot = -1;
        _mutex.unlock();
    }

    private void publishError(ulong generation, string message)
    {
        _mutex.lock();
        if (generation == _generation)
        {
            _ready = PreviewFrame.init;
            _ready.error = message;
            _readySlot = -2;
        }
        _mutex.unlock();
    }

    bool takeReady(out PreviewFrame frame)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_readySlot == -1) return false;
        if (_readySlot >= 0)
        {
            _displayedSlot = _readySlot;
            _ready.rgb = _slots[_displayedSlot];
        }
        frame = _ready;
        _ready = PreviewFrame.init;
        _readySlot = -1;
        return true;
    }
}

/**
 * The selected title itself becomes this editor while editing.
 *
 * It is deliberately a bare TextEditor rather than a TextField: there is no
 * second field surface, background, border, placeholder chrome, or duplicate
 * display label. Its glyph layout is the caret/selection layout.
 */
private final class PreviewTitleEditor : TextEditor
{
    ulong clipId;
    TitleVisual visual;
    void delegate() onCancel;

    this(ulong clipId, string text = "")
    {
        this.clipId = clipId;
        // Titles retain line breaks and use the same shaped layout for display,
        // caret movement, hit testing and export rasterization.
        super(text, true);
        layoutHints().preferredHeight = 40;
        layoutHints().minHeight = 1;
        setWordWrap(false);
        setShowBorder(false);
        setTransparentBackground(true);
        setFocusDecoration(false);
        setCanvasTextMode(true);
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape)
        {
            if (onCancel !is null) onCancel();
            return true;
        }
        return super.onKeyDown(event);
    }

    /**
     * Character-selection paint belongs only to an actively focused title.
     *
     * The layer stays alive after editing, so leaving the old logical range in
     * TextEditor would otherwise keep drawing its selection highlight over the
     * read-only composition title. Collapse it immediately on focus loss.
     */
    protected override void onFocusChanged(bool value)
    {
        super.onFocusChanged(value);
        if (!value && hasSelection()) selectNone();
    }

    void clearTextSelection()
    {
        if (hasSelection()) selectNone();
    }
}

/** Direct RGB preview surface. No external video window is ever opened. */
final class PreviewWidget : Widget
{
    private PreviewFrame _frame;
    private string _message = "Import MP4 or MP3 media to begin";
    private string _qualityLabel = "Preview";
    private dstring _messageText;
    private dstring _qualityText;
    private dstring _titleText;
    private dstring _timeText;
    private dstring _playingText;
    private string _cachedTitle;
    private long _displayedTimeTenths = long.min;
    private bool _playing;
    private bool _dragging;
    private bool _scaleDragging;
    private double _lastScaleDistance = 1.0;
    private bool _cutoutArmed;
    private bool _cutoutDragging;
    private Point _cutoutStart;
    private Point _cutoutCurrent;
    private bool _cutoutAdjustArmed;
    private bool _cutoutAdjustDragging;
    private int _cutoutAdjustEdge;
    private Point _lastDragPosition;
    private bool _selectionVisible;
    private bool _selectionIsText;
    private double _selectionCenterX;
    private double _selectionCenterY;
    private double _selectionWidth;
    private double _selectionHeight;
    private double _selectionRotation;

    // Every active title is a persistent Aurora text layer. The selected layer
    // becomes editable in place; it is never replaced by a second input widget
    // or burned into the RGB video frame.
    private bool _inlineTextEditing;
    private bool _inlineSyncing;
    private ulong _inlineClipId;
    private PreviewTitleEditor[ulong] _titleLayers;
    private TitleVisual[ulong] _titleVisuals;
    private ulong[] _titleOrder;
    private int _titleAuthoredHeight = 1080;
    private HBox _inlineToolbar;
    private PreviewTitleEditor _inlineText;
    private TextField _inlineSize;
    private Button _inlineFont;
    private string _inlineFontName = "Sans";
    private FontFace[string] _inlineFontFaces;
    private TextField _inlineColor;
    private Button _inlineBold;
    private Button _inlineItalic;
    private Button _inlineUnderline;
    private Button _inlineAlignLeft;
    private Button _inlineAlignCenter;
    private Button _inlineAlignRight;
    private bool _inlineBoldValue;
    private bool _inlineItalicValue;
    private bool _inlineUnderlineValue;
    private TextAlignment _inlineTextAlignment = TextAlignment.left;
    private double _inlineAuthoredTextSize = 48.0;
    private double _inlineOpacity = 1.0;
    private bool _inlineTextBox;
    private string _inlineTextBoxColor = "#80000000";
    private double _inlineStrokeWidth;
    private string _inlineStrokeColor = "#FFFFFFFF";
    private double _inlineShadowOpacity;
    private double _inlineShadowBlur;
    private double _inlineShadowOffsetX;
    private double _inlineShadowOffsetY;
    private string _inlineShadowColor = "#FF000000";

    void delegate(string text) onInlineTextChanged;
    void delegate(string fontName) onInlineFontChanged;
    void delegate(double size) onInlineTextSizeChanged;
    void delegate(string color) onInlineTextColorChanged;
    void delegate(bool value) onInlineBoldChanged;
    void delegate(bool value) onInlineItalicChanged;
    void delegate(bool value) onInlineUnderlineChanged;
    void delegate(TextAlignment value) onInlineTextAlignmentChanged;
    void delegate() onInlineEditEnded;

    void delegate(Point globalPosition) onContextMenuRequested;
    /** Return true when the pointer hit a movable timeline composition item. */
    bool delegate(double normalizedX, double normalizedY, int clickCount)
        onCanvasPointerDown;
    void delegate() onTransformDragStarted;
    void delegate(double normalizedDx, double normalizedDy) onTransformDragRequested;
    void delegate(double scaleFactor) onTransformScaleRequested;
    void delegate() onTransformDragEnded;
    void delegate(double normalizedX1, double normalizedY1,
        double normalizedX2, double normalizedY2) onCutoutSelectionCompleted;
    void delegate(int edge) onCutoutAdjustDragStarted;
    void delegate(int edge, double normalizedX, double normalizedY)
        onCutoutAdjustDragRequested;
    void delegate() onCutoutAdjustDragEnded;

    this()
    {
        _messageText = toUTF32(_message);
        _qualityText = toUTF32(_qualityLabel);
        _playingText = toUTF32("PLAYING");
        updateTimeText(0.0);
        // Video frames rebuild only this retained layer; the rest of the editor
        // remains cached instead of being software-rasterized every frame.
        setComposited(true);
        // onPaint begins with an opaque full-surface gradient, allowing Aurora's
        // software compositor to use row copies instead of alpha blending.
        setCompositedOpaque(true);
        layoutHints().minWidth = 320;
        layoutHints().minHeight = 200;
        layoutHints().flex = 1.0;

        _inlineToolbar = add(new HBox(3, Insets(4, 2)));
        _inlineToolbar.setId("preview-inline-text-toolbar");
        _inlineToolbar.setBackground(Color.fromHex(0x252b33));
        _inlineToolbar.setBorder(Color.fromHex(0x596473), 4);
        _inlineToolbar.setVisible(false);
        _inlineToolbar.layoutHints().excludeFromLayout = true;
        _inlineToolbar.layoutHints().allowOverflow = true;

        _inlineBold = _inlineToolbar.add(new Button("B"));
        _inlineBold.setId("preview-inline-bold");
        _inlineItalic = _inlineToolbar.add(new Button("I"));
        _inlineItalic.setId("preview-inline-italic");
        _inlineUnderline = _inlineToolbar.add(new Button("U"));
        _inlineUnderline.setId("preview-inline-underline");
        foreach (button; [_inlineBold, _inlineItalic, _inlineUnderline])
        {
            button.layoutHints().preferredWidth = 28;
            button.layoutHints().preferredHeight = 28;
            button.setFlat(true);
        }
        _inlineBold.onClick = delegate() {
            const value = !_inlineBoldValue;
            _inlineBoldValue = value;
            _inlineBold.setAccent(value);
            applyInlineFontFace();
            if (!_inlineSyncing && onInlineBoldChanged !is null)
                onInlineBoldChanged(value);
        };
        _inlineItalic.onClick = delegate() {
            const value = !_inlineItalicValue;
            _inlineItalicValue = value;
            _inlineItalic.setAccent(value);
            applyInlineFontFace();
            if (!_inlineSyncing && onInlineItalicChanged !is null)
                onInlineItalicChanged(value);
        };
        _inlineUnderline.onClick = delegate() {
            const value = !_inlineUnderlineValue;
            _inlineUnderlineValue = value;
            _inlineUnderline.setAccent(value);
            applyInlineTitleAppearance();
            if (!_inlineSyncing && onInlineUnderlineChanged !is null)
                onInlineUnderlineChanged(value);
        };

        _inlineAlignLeft = _inlineToolbar.add(new Button("L"));
        _inlineAlignLeft.setId("preview-inline-align-left");
        _inlineAlignCenter = _inlineToolbar.add(new Button("C"));
        _inlineAlignCenter.setId("preview-inline-align-center");
        _inlineAlignRight = _inlineToolbar.add(new Button("R"));
        _inlineAlignRight.setId("preview-inline-align-right");
        foreach (button; [_inlineAlignLeft, _inlineAlignCenter, _inlineAlignRight])
        {
            button.layoutHints().preferredWidth = 28;
            button.layoutHints().preferredHeight = 28;
            button.setFlat(true);
        }
        _inlineAlignLeft.onClick = delegate() {
            setInlineTextAlignment(TextAlignment.left, true);
        };
        _inlineAlignCenter.onClick = delegate() {
            setInlineTextAlignment(TextAlignment.center, true);
        };
        _inlineAlignRight.onClick = delegate() {
            setInlineTextAlignment(TextAlignment.right, true);
        };

        _inlineSize = _inlineToolbar.add(new TextField());
        _inlineSize.setId("preview-inline-text-size");
        _inlineSize.setPlaceholder("Size");
        _inlineSize.layoutHints().minHeight = 28;
        _inlineSize.layoutHints().preferredWidth = 52;
        _inlineSize.layoutHints().preferredHeight = 28;
        _inlineSize.onChanged = delegate() {
            if (_inlineSyncing || onInlineTextSizeChanged is null) return;
            try
            {
                const value = to!double(_inlineSize.textUtf8());
                if (value >= 8.0 && value <= 512.0)
                {
                    _inlineAuthoredTextSize = value;
                    applyInlineTitleAppearance();
                    onInlineTextSizeChanged(value);
                }
            }
            catch (ConvException) {}
        };

        _inlineFont = _inlineToolbar.add(new Button("Sans ▾"));
        _inlineFont.setId("preview-inline-font");
        _inlineFont.layoutHints().minHeight = 28;
        _inlineFont.layoutHints().preferredWidth = 140;
        _inlineFont.layoutHints().preferredHeight = 28;
        _inlineFont.onClick = delegate() {
            showInlineFontMenu(_inlineFont.localToGlobal(
                Point(0, _inlineFont.bounds().height + 2)));
        };

        _inlineColor = _inlineToolbar.add(new TextField());
        _inlineColor.setId("preview-inline-color");
        _inlineColor.setPlaceholder("#FFFFFF");
        _inlineColor.layoutHints().minHeight = 28;
        _inlineColor.layoutHints().preferredWidth = 82;
        _inlineColor.layoutHints().preferredHeight = 28;
        _inlineColor.onChanged = delegate() {
            applyInlineTitleAppearance();
            if (!_inlineSyncing && onInlineTextColorChanged !is null)
                onInlineTextColorChanged(_inlineColor.textUtf8());
        };

        auto done = _inlineToolbar.add(new Button("Done"));
        done.setId("preview-inline-done");
        done.layoutHints().preferredWidth = 48;
        done.layoutHints().preferredHeight = 28;
        done.onClick = delegate() { endInlineTextEditing(); };

        // Title editors are created from active timeline title layers. There is
        // deliberately no separate inline input control.
    }

    bool inlineTextEditing() const @safe pure nothrow @nogc
    {
        return _inlineTextEditing;
    }

    size_t titleLayerCountForTesting() const @safe pure nothrow @nogc
    {
        return _titleLayers.length;
    }

    TextEditor titleEditorForTesting(ulong clipId)
    {
        if (auto layer = clipId in _titleLayers) return *layer;
        return null;
    }

    private void wireTitleLayer(PreviewTitleEditor layer)
    {
        layer.onChanged = delegate() {
            if (_inlineTextEditing && _inlineText is layer &&
                !_inlineSyncing && onInlineTextChanged !is null)
                onInlineTextChanged(layer.textUtf8());
        };
        layer.onCancel = delegate() {
            if (_inlineTextEditing && _inlineText is layer)
                endInlineTextEditing();
        };
    }

    private PreviewTitleEditor titleLayer(ulong clipId)
    {
        if (auto existing = clipId in _titleLayers) return *existing;
        auto layer = new PreviewTitleEditor(clipId);
        layer.setId(format("preview-title-%d", clipId));
        layer.layoutHints().excludeFromLayout = true;
        layer.layoutHints().allowOverflow = true;
        // PreviewWidget is already one retained compositor surface. Keeping the
        // title as an ordinary child ensures its invalidation repaints that parent
        // surface instead of targeting an uncollected nested compositor cache.
        layer.setVisible(false);
        layer.setReadOnly(true);
        layer.setCaretEnabled(false);
        layer.setFocusable(false);
        layer.setEnabled(false);
        wireTitleLayer(layer);
        add(layer);
        _titleLayers[clipId] = layer;
        return layer;
    }

    private FontFace titleFontFace(const TitleVisual visual)
    {
        const path = textFontFilePath(visual.fontName, visual.bold,
            visual.italic);
        if (path.length > 0)
        {
            if (auto cached = path in _inlineFontFaces) return *cached;
            try
            {
                auto face = FontFace.load(path);
                if (face !is null)
                {
                    _inlineFontFaces[path] = face;
                    return face;
                }
            }
            catch (Exception) {}
        }
        return loadTitleFace(visual);
    }

    private void configureTitleLayer(PreviewTitleEditor layer,
        const TitleVisual visual)
    {
        const destination = displayedImageRect();
        if (destination.empty())
        {
            layer.setVisible(false);
            return;
        }

        const editing = _inlineTextEditing && visual.clipId == _inlineClipId;
        layer.visual = visual;
        if (layer.textUtf8() != visual.text && (!editing || !layer.focused()))
            layer.setText(visual.text, false);
        layer.setFontFace(titleFontFace(visual), FontRole.ui);

        const pixelFactor = _titleAuthoredHeight > 0 ?
            cast(double) destination.height / _titleAuthoredHeight : 1.0;
        layer.setPixelSizeOverride(maxInt(8, cast(int)
            (visual.textSize * visual.scale * pixelFactor + 0.5)));
        const style = titlePaintStyle(visual, pixelFactor);
        layer.setTextColor(style.foreground);
        layer.setTitleLayerOpacity(style.layerOpacity);
        layer.setTitleHorizontalAlignment(titleHorizontalAlign(
            visual.textAlignment));
        layer.setTitleEffects(style.strokeWidth, style.strokeColor,
            style.shadowOffsetX, style.shadowOffsetY, style.shadowBlur,
            style.shadowColor, style.underline, style.box, style.boxColor);
        const margin = layer.titleEffectMargin();
        layer.setPadding(margin);
        const measured = layer.contentSize();
        const width = maxInt(1, measured.width + margin * 2);
        const height = maxInt(1, measured.height + margin * 2);
        const centerX = destination.x + cast(int)
            ((visual.positionX + 1.0) * 0.5 * destination.width + 0.5);
        const centerY = destination.y + cast(int)
            ((visual.positionY + 1.0) * 0.5 * destination.height + 0.5);
        layer.setBounds(Rect(centerX - width / 2, centerY - height / 2,
            width, height));
        // A persistent title layer must never carry an old character range
        // into its normal read-only display state.
        if (!editing) layer.clearTextSelection();
        layer.setReadOnly(!editing);
        layer.setCaretEnabled(editing);
        layer.setFocusable(editing);
        layer.setEnabled(editing);
        layer.setVisible(true);
    }

    /** Replace the old burned-in preview title path with persistent live layers. */
    void setTitleLayers(TitleVisual[] visuals, int authoredWidth,
        int authoredHeight)
    {
        authoredWidth = maxInt(1, authoredWidth);
        _titleAuthoredHeight = maxInt(1, authoredHeight);
        bool[ulong] seen;
        ulong[] nextOrder;
        foreach (visual; visuals)
        {
            if (visual.clipId == 0) continue;
            seen[visual.clipId] = true;
            nextOrder ~= visual.clipId;
            _titleVisuals[visual.clipId] = visual;
            auto layer = titleLayer(visual.clipId);
            configureTitleLayer(layer, visual);
        }

        bool removedActiveEditor;
        ulong[] stale;
        foreach (clipId, layer; _titleLayers)
            if (clipId !in seen) stale ~= clipId;
        foreach (clipId; stale)
        {
            auto layer = _titleLayers[clipId];
            if (_inlineText is layer)
            {
                _inlineText = null;
                _inlineTextEditing = false;
                _inlineClipId = 0;
                _inlineToolbar.setVisible(false);
                removedActiveEditor = true;
            }
            remove(layer);
            _titleLayers.remove(clipId);
            _titleVisuals.remove(clipId);
        }
        // Reorder title children only when track order actually changes.
        if (nextOrder != _titleOrder)
        {
            foreach (index, clipId; nextOrder)
                if (auto layer = clipId in _titleLayers)
                    moveChildToIndex(*layer, index);
            moveChildToIndex(_inlineToolbar, nextOrder.length);
            _titleOrder = nextOrder.dup;
        }
        invalidate();
        if (removedActiveEditor && onInlineEditEnded !is null)
            onInlineEditEnded();
    }

    private void layoutTitleLayers()
    {
        foreach (clipId, layer; _titleLayers)
            if (auto visual = clipId in _titleVisuals)
                configureTitleLayer(layer, *visual);
        if (_inlineToolbar.visible())
        {
            layoutInlineTextEditor();
            _inlineToolbar.bringToFront();
        }
    }

    private void applyInlineFontFace()
    {
        if (_inlineText is null) return;
        const path = textFontFilePath(_inlineFontName, _inlineBoldValue,
            _inlineItalicValue);
        FontFace face;
        if (path.length > 0)
        {
            if (auto cached = path in _inlineFontFaces)
                face = *cached;
            else
            {
                // The Windows Fonts directory is a shell-backed location on
                // some systems. Loading directly avoids a second exists()
                // gate silently replacing the selected face with the UI font.
                try face = FontFace.load(path);
                catch (Exception) face = null;
                if (face !is null) _inlineFontFaces[path] = face;
            }
        }
        // A missing/custom family still uses the proportional UI collection,
        // never the old fixed monospace editor face.
        _inlineText.setFontFace(face, FontRole.ui);
    }

    private void setInlineFont(string fontName, bool notify)
    {
        _inlineFontName = canonicalTextFontName(fontName);
        _inlineFont.setText(_inlineFontName ~ " ▾");
        applyInlineFontFace();
        if (notify && !_inlineSyncing && onInlineFontChanged !is null)
            onInlineFontChanged(_inlineFontName);
    }

    private void syncInlineAlignmentButtons()
    {
        _inlineAlignLeft.setAccent(_inlineTextAlignment == TextAlignment.left);
        _inlineAlignCenter.setAccent(_inlineTextAlignment == TextAlignment.center);
        _inlineAlignRight.setAccent(_inlineTextAlignment == TextAlignment.right);
    }

    private void setInlineTextAlignment(TextAlignment value, bool notify)
    {
        if (_inlineTextAlignment == value)
        {
            syncInlineAlignmentButtons();
            return;
        }
        _inlineTextAlignment = value;
        syncInlineAlignmentButtons();
        applyInlineTitleAppearance();
        if (notify && !_inlineSyncing && onInlineTextAlignmentChanged !is null)
            onInlineTextAlignmentChanged(value);
    }

    /** Build one font command in its own call frame.
     *
     * D delegates capture foreach variables by reference. Building the
     * callbacks directly inside the loop made every row use the final family
     * (Sans), so the UI appeared to reset and every render used one face.
     * A separate factory call gives each delegate an independent captured
     * family value. */
    private ContextMenuItem inlineFontMenuItem(string requestedFont)
    {
        string capturedFont = requestedFont.idup;
        return ContextMenuItem.check(capturedFont,
            canonicalTextFontName(_inlineFontName) == capturedFont, delegate() {
                setInlineFont(capturedFont, true);
                if (_inlineText !is null) _inlineText.requestFocus();
            });
    }

    private void showInlineFontMenu(Point globalPoint)
    {
        ContextMenuItem[] items;
        foreach (fontName; textFontFamilies)
            items ~= inlineFontMenuItem(fontName);
        showContextMenu(_inlineFont, globalPoint, items);
    }

    private static Color inlineColor(string value)
    {
        string digits = value;
        if (digits.length > 0 && digits[0] == '#') digits = digits[1 .. $];
        try
        {
            if (digits.length == 8)
            {
                string encoded = digits;
                const argb = parse!uint(encoded, 16);
                return Color.fromHex(argb & 0x00ff_ffff).withAlpha(
                    cast(ubyte) ((argb >> 24) & 0xff));
            }
            if (digits.length == 6)
            {
                string encoded = digits;
                return Color.fromHex(parse!uint(encoded, 16));
            }
        }
        catch (Exception) {}
        return Color.fromHex(0xffffff);
    }

    private void applyInlineTitleAppearance()
    {
        if (_inlineText is null) return;
        TitleVisual visual = _inlineText.visual;
        visual.text = _inlineText.textUtf8();
        visual.fontName = _inlineFontName;
        visual.bold = _inlineBoldValue;
        visual.italic = _inlineItalicValue;
        visual.underline = _inlineUnderlineValue;
        visual.textAlignment = _inlineTextAlignment;
        visual.textSize = _inlineAuthoredTextSize;
        visual.textColor = inlineColor(_inlineColor.textUtf8()).argb();
        visual.opacity = _inlineOpacity;
        visual.box = _inlineTextBox;
        visual.boxColor = inlineColor(_inlineTextBoxColor).argb();
        visual.strokeWidth = _inlineStrokeWidth;
        visual.strokeColor = inlineColor(_inlineStrokeColor).argb();
        visual.shadowOpacity = _inlineShadowOpacity;
        visual.shadowBlur = _inlineShadowBlur;
        visual.shadowOffsetX = _inlineShadowOffsetX;
        visual.shadowOffsetY = _inlineShadowOffsetY;
        visual.shadowColor = inlineColor(_inlineShadowColor).argb();
        _inlineText.visual = visual;
        _titleVisuals[visual.clipId] = visual;
        configureTitleLayer(_inlineText, visual);
    }

    /** Synchronize effects into the same persistent title layer. */
    void syncInlineTextEffects(double opacity, bool textBox,
        string textBoxColor, double strokeWidth, string strokeColor,
        double shadowOpacity, double shadowBlur, double shadowOffsetX,
        double shadowOffsetY, string shadowColor,
        int authoredHeight = 1080)
    {
        _inlineOpacity = opacity;
        _inlineTextBox = textBox;
        _inlineTextBoxColor = textBoxColor;
        _inlineStrokeWidth = strokeWidth;
        _inlineStrokeColor = strokeColor;
        _inlineShadowOpacity = shadowOpacity;
        _inlineShadowBlur = shadowBlur;
        _inlineShadowOffsetX = shadowOffsetX;
        _inlineShadowOffsetY = shadowOffsetY;
        _inlineShadowColor = shadowColor;
        applyInlineTitleAppearance();
        layoutInlineTextEditor();
    }

    void beginInlineTextEditing(ulong clipId, string text, string fontName,
        double textSize, string textColor, bool bold, bool italic,
        bool underline, TextAlignment alignment, int authoredHeight = 1080)
    {
        _inlineTextEditing = true;
        _inlineClipId = clipId;
        _inlineText = titleLayer(clipId);
        _inlineText.setId("preview-inline-text");
        TitleVisual visual;
        if (auto current = clipId in _titleVisuals)
            visual = *current;
        else
        {
            visual.clipId = clipId;
            visual.text = text;
            visual.fontName = fontName;
            visual.textSize = textSize;
            visual.textColor = inlineColor(textColor).argb();
            visual.bold = bold;
            visual.italic = italic;
            visual.underline = underline;
            visual.textAlignment = alignment;
            _titleVisuals[clipId] = visual;
        }

        _inlineSyncing = true;
        if (_inlineText.textUtf8() != text) _inlineText.setText(text, false);
        _inlineAuthoredTextSize = textSize;
        _inlineSize.setText(format("%.0f", textSize), false);
        _inlineBoldValue = bold;
        _inlineItalicValue = italic;
        _inlineUnderlineValue = underline;
        _inlineTextAlignment = alignment;
        _inlineFontName = canonicalTextFontName(fontName);
        _inlineFont.setText(_inlineFontName ~ " ▾");
        _inlineColor.setText(textColor, false);
        _inlineBold.setAccent(bold);
        _inlineItalic.setAccent(italic);
        _inlineUnderline.setAccent(underline);
        syncInlineAlignmentButtons();
        _inlineSyncing = false;

        applyInlineTitleAppearance();
        _inlineText.setReadOnly(false);
        _inlineText.setCaretEnabled(true);
        _inlineText.setFocusable(true);
        _inlineText.setEnabled(true);
        _inlineText.setVisible(true);
        _inlineToolbar.setVisible(true);
        layoutInlineTextEditor();
        _inlineToolbar.bringToFront();
        _inlineText.requestFocus();
        _inlineText.selectAll();
        invalidate();
    }

    void syncInlineTextStyle(string text, string fontName, double textSize,
        string textColor, bool bold, bool italic, bool underline,
        TextAlignment alignment, int authoredHeight = 1080)
    {
        if (!_inlineTextEditing || _inlineText is null) return;
        _inlineSyncing = true;
        if (!_inlineText.focused() && _inlineText.textUtf8() != text)
            _inlineText.setText(text, false);
        if (!_inlineSize.focused())
            _inlineSize.setText(format("%.0f", textSize), false);
        _inlineAuthoredTextSize = textSize;
        if (!_inlineColor.focused()) _inlineColor.setText(textColor, false);
        _inlineBoldValue = bold;
        _inlineItalicValue = italic;
        _inlineUnderlineValue = underline;
        _inlineTextAlignment = alignment;
        _inlineFontName = canonicalTextFontName(fontName);
        _inlineFont.setText(_inlineFontName ~ " ▾");
        _inlineBold.setAccent(bold);
        _inlineItalic.setAccent(italic);
        _inlineUnderline.setAccent(underline);
        syncInlineAlignmentButtons();
        _inlineSyncing = false;
        applyInlineTitleAppearance();
        layoutInlineTextEditor();
    }

    void endInlineTextEditing(bool notify = true)
    {
        if (!_inlineTextEditing) return;
        _inlineTextEditing = false;
        _inlineToolbar.setVisible(false);
        if (_inlineText !is null)
        {
            // Clear before disabling focus. This also works when the preview is
            // not yet attached to a host and therefore emits no focus-change.
            _inlineText.clearTextSelection();
            _inlineText.setReadOnly(true);
            _inlineText.setCaretEnabled(false);
            _inlineText.setFocusable(false);
            _inlineText.setEnabled(false);
            _inlineText.setVisible(true);
            _inlineText.setId(format("preview-title-%d", _inlineText.clipId));
        }
        _inlineClipId = 0;
        invalidate();
        if (notify && onInlineEditEnded !is null) onInlineEditEnded();
    }

    private Rect selectedTextRect() const
    {
        return _inlineText is null ? Rect.init : _inlineText.bounds();
    }

    private void layoutInlineTextEditor()
    {
        if (!_inlineTextEditing || _inlineText is null) return;
        const textRect = selectedTextRect();
        if (textRect.empty()) return;
        const toolbarWidth = minInt(430, maxInt(300, bounds().width - 16));
        const toolbarHeight = 36;
        int toolbarX = textRect.x + (textRect.width - toolbarWidth) / 2;
        toolbarX = clampValue(toolbarX, 8,
            maxInt(8, bounds().width - toolbarWidth - 8));
        int toolbarY = textRect.y - toolbarHeight - 5;
        if (toolbarY < 8) toolbarY = minInt(bounds().height - toolbarHeight - 8,
            textRect.bottom() + 5);
        _inlineToolbar.setBounds(Rect(toolbarX, toolbarY,
            toolbarWidth, toolbarHeight));
        _inlineToolbar.layoutTree();
    }

    protected override void onLayout()
    {
        layoutTitleLayers();
    }

    protected override void onBoundsChanged()
    {
        layoutTitleLayers();
    }

    /** Update the video/image background metadata. */
    private void adoptFrame(PreviewFrame frame)
    {
        _frame = frame;
        const nextMessage = frame.error.length > 0 ? frame.error : "";
        if (_message != nextMessage)
        {
            _message = nextMessage;
            _messageText = toUTF32(_message);
        }
        if (_cachedTitle != frame.title)
        {
            _cachedTitle = frame.title;
            _titleText = toUTF32(frame.title);
        }
        updateTimeText(frame.sourceTime);
    }

    /** Adopt only the video/image background. Titles are independent live layers. */
    void setFrame(PreviewFrame frame)
    {
        adoptFrame(frame);
        layoutTitleLayers();
        invalidate();
    }

    private void clearInlineDisplaySurface()
    {
        if (_inlineTextEditing) endInlineTextEditing(false);
        _inlineToolbar.setVisible(false);
    }

    void setMessage(string value)
    {
        clearInlineDisplaySurface();
        if (!_frame.valid() && _message == value) return;
        _frame = PreviewFrame.init;
        _message = value;
        _messageText = toUTF32(value);
        _cachedTitle = "";
        _titleText = null;
        _displayedTimeTenths = long.min;
        foreach (layer; _titleLayers) layer.setVisible(false);
        invalidate();
    }

    void setQualityLabel(string value)
    {
        if (_qualityLabel == value) return;
        _qualityLabel = value;
        _qualityText = toUTF32(value);
        invalidate();
    }

    void setPlaybackTime(double value)
    {
        if (!_frame.valid()) return;
        if (value < 0.0) value = 0.0;
        if (value == _frame.sourceTime) return;
        _frame.sourceTime = value;
        if (updateTimeText(value)) invalidate();
    }


    /** Quantize the display-only timecode to 100 ms to avoid allocating a new
     * UTF-32 string for every decoded frame. The actual frame timestamp remains
     * full precision and is still used by transport logic and tests. */
    private bool updateTimeText(double value)
    {
        if (value < 0.0) value = 0.0;
        const bucket = cast(long) (value * 10.0 + 0.5);
        if (bucket == _displayedTimeTenths) return false;
        _displayedTimeTenths = bucket;
        _timeText = toUTF32(formatTimecode(cast(double) bucket / 10.0));
        return true;
    }

    void setPlaying(bool value)
    {
        if (_playing == value) return;
        _playing = value;
        invalidate();
    }

    bool playing() const @safe pure nothrow @nogc { return _playing; }
    bool hasFrame() const @safe pure nothrow @nogc { return _frame.valid(); }
    bool cutoutSelectionArmedForTesting() const @safe pure nothrow @nogc
    {
        return _cutoutArmed;
    }
    bool cutoutAdjustArmedForTesting() const @safe pure nothrow @nogc
    {
        return _cutoutAdjustArmed;
    }
    void beginCutoutSelection()
    {
        _cutoutArmed = true;
        _cutoutAdjustArmed = false;
        _cutoutDragging = false;
        setCursor(CursorKind.resizeDiagonalNESW);
    }
    void beginCutoutAdjustment()
    {
        _cutoutAdjustArmed = true;
        _cutoutArmed = false;
        _cutoutDragging = false;
        _cutoutAdjustDragging = false;
        setCursor(CursorKind.resizeHorizontal);
        invalidate();
    }
    void cancelCutoutSelection()
    {
        if (!_cutoutArmed && !_cutoutDragging &&
            !_cutoutAdjustArmed && !_cutoutAdjustDragging) return;
        _cutoutArmed = false;
        _cutoutDragging = false;
        _cutoutAdjustArmed = false;
        _cutoutAdjustDragging = false;
        setCursor(CursorKind.arrow);
        invalidate();
    }
    bool hasCompositionFrame() const
    {
        return _frame.valid() &&
            (_frame.title == "Sequence composition" ||
             _frame.title == "Sequence composition (cached)" ||
             (_frame.title.length >= 8 && _frame.title[0 .. 8] == "Sequence"));
    }
    int frameWidth() const @safe pure nothrow @nogc { return _frame.width; }
    int frameHeight() const @safe pure nothrow @nogc { return _frame.height; }
    double frameTime() const @safe pure nothrow @nogc { return _frame.sourceTime; }
    string frameTitleForTesting() const { return _frame.title; }
    ubyte[3] pixelForTesting(int x, int y) const
    {
        if (!_frame.valid() || x < 0 || y < 0 || x >= _frame.width || y >= _frame.height)
            return [cast(ubyte) 0, cast(ubyte) 0, cast(ubyte) 0];
        const offset = (cast(size_t) y * cast(size_t) _frame.width +
            cast(size_t) x) * 3;
        return [_frame.rgb[offset], _frame.rgb[offset + 1], _frame.rgb[offset + 2]];
    }

    void setSelectionOverlay(bool visible, double centerX = 0.0,
        double centerY = 0.0, double width = 0.0, double height = 0.0,
        double rotationDegrees = 0.0, bool isText = false)
    {
        if (_selectionVisible == visible &&
            _selectionCenterX == centerX && _selectionCenterY == centerY &&
            _selectionWidth == width && _selectionHeight == height &&
            _selectionRotation == rotationDegrees && _selectionIsText == isText)
            return;
        _selectionVisible = visible;
        _selectionCenterX = centerX;
        _selectionCenterY = centerY;
        _selectionWidth = width;
        _selectionHeight = height;
        _selectionRotation = rotationDegrees;
        _selectionIsText = isText;
        if (_inlineTextEditing && (!visible || !isText))
            endInlineTextEditing();
        else if (_inlineTextEditing)
            layoutInlineTextEditor();
        invalidate();
    }

    private Rect displayedImageRect() const
    {
        if (!_frame.valid()) return Rect.init;
        Rect destination = Rect(0, 0, bounds().width, bounds().height).inset(12);
        if (destination.empty()) return Rect.init;
        const sourceAspect = cast(double) _frame.width / cast(double) _frame.height;
        const targetAspect = destination.height > 0
            ? cast(double) destination.width / cast(double) destination.height
            : sourceAspect;
        if (targetAspect > sourceAspect)
        {
            const width = cast(int) (destination.height * sourceAspect + 0.5);
            destination.x += (destination.width - width) / 2;
            destination.width = width;
        }
        else
        {
            const height = cast(int) (destination.width / sourceAspect + 0.5);
            destination.y += (destination.height - height) / 2;
            destination.height = height;
        }
        return destination;
    }

    private bool normalizedPoint(Point point, out double x, out double y) const
    {
        const destination = displayedImageRect();
        if (destination.empty() || !destination.contains(point)) return false;
        x = cast(double) (point.x - destination.x) / destination.width * 2.0 - 1.0;
        y = cast(double) (point.y - destination.y) / destination.height * 2.0 - 1.0;
        return true;
    }

    private bool normalizedPointClamped(Point point, out double x, out double y) const
    {
        const destination = displayedImageRect();
        if (destination.empty()) return false;
        const px = clampValue(cast(double) point.x, cast(double) destination.x,
            cast(double) destination.x + destination.width);
        const py = clampValue(cast(double) point.y, cast(double) destination.y,
            cast(double) destination.y + destination.height);
        x = (px - destination.x) / destination.width * 2.0 - 1.0;
        y = (py - destination.y) / destination.height * 2.0 - 1.0;
        return true;
    }

    private bool selectionCorners(out Point[4] corners) const
    {
        const destination = displayedImageRect();
        if (!_selectionVisible || _playing || destination.width <= 0 ||
            destination.height <= 0) return false;
        const centerX = destination.x + cast(int)
            ((_selectionCenterX + 1.0) * 0.5 * destination.width);
        const centerY = destination.y + cast(int)
            ((_selectionCenterY + 1.0) * 0.5 * destination.height);
        const halfWidth = _selectionWidth * 0.25 * destination.width;
        const halfHeight = _selectionHeight * 0.25 * destination.height;
        const radians = _selectionRotation * PI / 180.0;
        const c = cos(radians);
        const sn = sin(radians);
        immutable double[4] xs = [-halfWidth, halfWidth, halfWidth, -halfWidth];
        immutable double[4] ys = [-halfHeight, -halfHeight, halfHeight, halfHeight];
        foreach (index; 0 .. 4)
        {
            corners[index] = Point(
                centerX + cast(int) (xs[index] * c - ys[index] * sn),
                centerY + cast(int) (xs[index] * sn + ys[index] * c));
        }
        return true;
    }

    private bool selectionCornerAt(Point point, out int cornerIndex) const
    {
        Point[4] corners;
        if (!selectionCorners(corners)) return false;
        long bestDistance = long.max;
        int bestIndex = -1;
        foreach (index, corner; corners)
        {
            const dx = point.x - corner.x;
            const dy = point.y - corner.y;
            const distance = cast(long) dx * dx + cast(long) dy * dy;
            if (distance < bestDistance)
            {
                bestDistance = distance;
                bestIndex = cast(int) index;
            }
        }
        if (bestIndex < 0 || bestDistance > 144) return false;
        cornerIndex = bestIndex;
        return true;
    }

    private bool selectionEdgeAt(Point point, out int edge) const
    {
        edge = SelectionEdge.none;
        const destination = displayedImageRect();
        if (!_selectionVisible || _playing || destination.width <= 0 ||
            destination.height <= 0) return false;
        const centerX = destination.x +
            ((_selectionCenterX + 1.0) * 0.5 * destination.width);
        const centerY = destination.y +
            ((_selectionCenterY + 1.0) * 0.5 * destination.height);
        const halfWidth = _selectionWidth * 0.25 * destination.width;
        const halfHeight = _selectionHeight * 0.25 * destination.height;
        if (halfWidth < 2.0 || halfHeight < 2.0) return false;
        const radians = -_selectionRotation * PI / 180.0;
        const dx = cast(double) point.x - centerX;
        const dy = cast(double) point.y - centerY;
        const localX = dx * cos(radians) - dy * sin(radians);
        const localY = dx * sin(radians) + dy * cos(radians);
        const threshold = 12.0;

        double best = threshold + 1.0;
        int bestEdge = SelectionEdge.none;
        if (localY >= -halfHeight - threshold &&
            localY <= halfHeight + threshold)
        {
            const leftDistance = localX + halfWidth;
            const leftAbsolute = leftDistance < 0.0 ? -leftDistance : leftDistance;
            if (leftAbsolute < best)
            {
                best = leftAbsolute;
                bestEdge = SelectionEdge.left;
            }
            const rightDistance = localX - halfWidth;
            const rightAbsolute = rightDistance < 0.0 ? -rightDistance : rightDistance;
            if (rightAbsolute < best)
            {
                best = rightAbsolute;
                bestEdge = SelectionEdge.right;
            }
        }
        if (localX >= -halfWidth - threshold &&
            localX <= halfWidth + threshold)
        {
            const topDistance = localY + halfHeight;
            const topAbsolute = topDistance < 0.0 ? -topDistance : topDistance;
            if (topAbsolute < best)
            {
                best = topAbsolute;
                bestEdge = SelectionEdge.top;
            }
            const bottomDistance = localY - halfHeight;
            const bottomAbsolute = bottomDistance < 0.0 ? -bottomDistance : bottomDistance;
            if (bottomAbsolute < best)
            {
                best = bottomAbsolute;
                bestEdge = SelectionEdge.bottom;
            }
        }

        if (bestEdge == SelectionEdge.none || best > threshold) return false;
        edge = bestEdge;
        return true;
    }

    private double selectionScaleDistance(Point point) const
    {
        const destination = displayedImageRect();
        if (destination.empty()) return 1.0;
        const centerX = destination.x +
            ((_selectionCenterX + 1.0) * 0.5 * destination.width);
        const centerY = destination.y +
            ((_selectionCenterY + 1.0) * 0.5 * destination.height);
        const dx = cast(double) point.x - centerX;
        const dy = cast(double) point.y - centerY;
        const distance = sqrt(dx * dx + dy * dy);
        return distance > 1.0 ? distance : 1.0;
    }

    /** Efficient decode size matched to the visible surface, capped by quality. */
    Size recommendedDecodeSize(int maximumHeight = 1080) const
    {
        maximumHeight = clampValue(maximumHeight, 180, 2160);
        int availableWidth = bounds().width > 40 ? bounds().width - 24 : 960;
        int availableHeight = bounds().height > 40 ? bounds().height - 24 : 540;
        availableHeight = availableHeight < maximumHeight ? availableHeight : maximumHeight;
        int height = availableHeight < 180 ? 180 : availableHeight;
        int width = height * 16 / 9;
        if (width > availableWidth)
        {
            width = availableWidth < 320 ? 320 : availableWidth;
            height = width * 9 / 16;
        }
        if ((width & 1) != 0) --width;
        if ((height & 1) != 0) --height;
        return Size(width < 320 ? 320 : width, height < 180 ? 180 : height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        // Neutral gray surround so the sequence frame edges stand out from the
        // video's own black padding and its aspect ratio is easy to see.
        canvas.fillVerticalGradient(full, Color.fromHex(0x3c3c3c),
            Color.fromHex(0x2a2a2a));

        const outer = full.inset(10);
        if (outer.empty()) return;
        // Gray monitor surround: the letterbox/pillarbox area around the frame
        // stays clearly lighter than the video's black padding, so the actual
        // sequence aspect and resolution borders are easy to see.
        canvas.drawRoundedRect(outer, 7, Color.fromHex(0x343434),
            palette.border.withAlpha(190), 1);

        if (!_frame.valid())
        {
            const center = Point(full.width / 2, full.height / 2 - 8);
            canvas.fillCircle(center, 30, palette.buttonBackground.withAlpha(215));
            canvas.drawLine(Point(center.x - 7, center.y - 12),
                Point(center.x - 7, center.y + 12), palette.text, 2);
            canvas.drawLine(Point(center.x - 7, center.y - 12),
                Point(center.x + 13, center.y), palette.text, 2);
            canvas.drawLine(Point(center.x + 13, center.y),
                Point(center.x - 7, center.y + 12), palette.text, 2);
            canvas.drawTextInRect(Rect(24, center.y + 44,
                    maxInt(0, full.width - 48), 52),
                _messageText, palette.textMuted, 1,
                HorizontalAlign.center, VerticalAlign.top, true);
            return;
        }

        const destination = displayedImageRect();

        // The RGB frame permanently contains video/image layers only. Active
        // titles are retained child widgets painted after this background.
        canvas.drawRgbImage(destination, _frame.width, _frame.height,
            _frame.rgb, true);
        // Hairline around the exact frame bounds so the sequence resolution
        // and aspect ratio stay visible regardless of the surround contrast.
        canvas.strokeRect(destination, Color.rgba(235, 235, 240, 130), 1);

        canvas.fillRect(Rect(destination.x, destination.y, destination.width, 28),
            Color.rgba(0, 0, 0, 125));
        canvas.drawTextInRect(Rect(destination.x + 10, destination.y,
                maxInt(0, destination.width - 160), 28),
            _titleText, Color.rgb(244, 246, 250), 1,
            HorizontalAlign.left, VerticalAlign.middle, true);
        canvas.drawTextInRect(Rect(destination.right() - 145, destination.y,
                135, 28), _qualityText, Color.rgba(230, 235, 242, 210), 1,
            HorizontalAlign.right, VerticalAlign.middle, true);

        canvas.fillRoundedRect(Rect(destination.right() - 118,
                destination.bottom() - 31, 108, 23), 4, Color.rgba(0, 0, 0, 165));
        canvas.drawTextInRect(Rect(destination.right() - 114,
                destination.bottom() - 31, 100, 23),
            _timeText, Color.rgb(245, 246, 248), 1,
            HorizontalAlign.center, VerticalAlign.middle, true);

        if (_playing)
        {
            canvas.fillRoundedRect(Rect(destination.x + 10,
                    destination.bottom() - 31, 76, 23), 4,
                Color.rgba(0, 0, 0, 165));
            canvas.drawTextInRect(Rect(destination.x + 14,
                    destination.bottom() - 31, 68, 23),
                _playingText, Color.rgb(245, 246, 248), 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
        }

        Point[4] corners;
        if (selectionCorners(corners))
        {
            const outline = _selectionIsText ? Color.fromHex(0x58a6ff) :
                Color.fromHex(0xffcc66);
            foreach (index; 0 .. 4)
                canvas.drawLine(corners[index], corners[(index + 1) % 4], outline, 2);
            foreach (corner; corners)
                canvas.fillCircle(corner, 5, outline);
            canvas.fillCircle(Point((corners[0].x + corners[2].x) / 2,
                (corners[0].y + corners[2].y) / 2), 3, outline);
            if (_cutoutAdjustArmed)
            {
                const cropHandle = Color.fromHex(0x55d47a);
                foreach (index; 0 .. 4)
                {
                    const next = corners[(index + 1) % 4];
                    canvas.fillCircle(Point((corners[index].x + next.x) / 2,
                        (corners[index].y + next.y) / 2), 5, cropHandle);
                }
            }
        }

        if (_cutoutDragging)
        {
            const left = _cutoutStart.x < _cutoutCurrent.x ?
                _cutoutStart.x : _cutoutCurrent.x;
            const top = _cutoutStart.y < _cutoutCurrent.y ?
                _cutoutStart.y : _cutoutCurrent.y;
            const right = _cutoutStart.x > _cutoutCurrent.x ?
                _cutoutStart.x : _cutoutCurrent.x;
            const bottom = _cutoutStart.y > _cutoutCurrent.y ?
                _cutoutStart.y : _cutoutCurrent.y;
            canvas.drawRoundedRect(Rect(left, top, right - left, bottom - top),
                2, Color.fromHex(0x58a6ff).withAlpha(42),
                Color.fromHex(0x58a6ff), 2);
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            if (onContextMenuRequested !is null)
                onContextMenuRequested(event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        // Events reaching the preview itself are outside the editable title
        // child. Collapse any character range immediately, even when the
        // clicked preview surface is not focusable and the host would otherwise
        // leave the editor focused.
        if (_inlineTextEditing && _inlineText !is null)
            _inlineText.clearTextSelection();
        double normalizedX;
        double normalizedY;
        if (_cutoutArmed)
        {
            if (!normalizedPointClamped(event.position, normalizedX, normalizedY))
                return true;
            _cutoutDragging = true;
            _cutoutStart = event.position;
            _cutoutCurrent = event.position;
            captureMouse();
            setCursor(CursorKind.resizeDiagonalNESW);
            invalidate();
            return true;
        }
        if (_cutoutAdjustArmed)
        {
            int edge;
            if (!selectionEdgeAt(event.position, edge)) return true;
            _cutoutAdjustDragging = true;
            _cutoutAdjustEdge = edge;
            _cutoutAdjustArmed = false;
            if (onCutoutAdjustDragStarted !is null)
                onCutoutAdjustDragStarted(edge);
            captureMouse();
            setCursor(edge == SelectionEdge.top || edge == SelectionEdge.bottom ?
                CursorKind.resizeVertical : CursorKind.resizeHorizontal);
            invalidate();
            return true;
        }
        if (!normalizedPoint(event.position, normalizedX, normalizedY)) return true;
        int cornerIndex;
        if (selectionCornerAt(event.position, cornerIndex))
        {
            _scaleDragging = true;
            _lastScaleDistance = selectionScaleDistance(event.position);
            if (onTransformDragStarted !is null) onTransformDragStarted();
            captureMouse();
            setCursor(CursorKind.resizeDiagonalNESW);
            return true;
        }
        const movable = onCanvasPointerDown !is null &&
            onCanvasPointerDown(normalizedX, normalizedY, event.clickCount);
        if (event.clickCount >= 2 || !movable) return true;
        _dragging = true;
        _lastDragPosition = event.position;
        if (onTransformDragStarted !is null) onTransformDragStarted();
        captureMouse();
        setCursor(CursorKind.move);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_cutoutDragging)
        {
            _cutoutCurrent = event.position;
            invalidate();
            return true;
        }
        if (_cutoutAdjustDragging)
        {
            double x; double y;
            if (normalizedPointClamped(event.position, x, y) &&
                onCutoutAdjustDragRequested !is null)
                onCutoutAdjustDragRequested(_cutoutAdjustEdge, x, y);
            setCursor(_cutoutAdjustEdge == SelectionEdge.top ||
                _cutoutAdjustEdge == SelectionEdge.bottom ?
                CursorKind.resizeVertical : CursorKind.resizeHorizontal);
            return true;
        }
        if (_scaleDragging)
        {
            const distance = selectionScaleDistance(event.position);
            if (distance > 1.0 && _lastScaleDistance > 1.0)
            {
                const factor = distance / _lastScaleDistance;
                _lastScaleDistance = distance;
                if (onTransformScaleRequested !is null)
                    onTransformScaleRequested(factor);
            }
            return true;
        }
        if (_cutoutAdjustArmed)
        {
            int edge;
            if (selectionEdgeAt(event.position, edge))
                setCursor(edge == SelectionEdge.top || edge == SelectionEdge.bottom ?
                    CursorKind.resizeVertical : CursorKind.resizeHorizontal);
            else
                setCursor(CursorKind.resizeHorizontal);
            return super.onMouseMove(event);
        }
        if (!_dragging) return super.onMouseMove(event);
        const dx = event.position.x - _lastDragPosition.x;
        const dy = event.position.y - _lastDragPosition.y;
        if (dx != 0 || dy != 0)
        {
            _lastDragPosition = event.position;
            if (onTransformDragRequested !is null)
            {
                const destination = displayedImageRect();
                const w = destination.width > 1 ? cast(double) destination.width : 1.0;
                const h = destination.height > 1 ? cast(double) destination.height : 1.0;
                onTransformDragRequested(cast(double) dx / w * 2.0,
                    cast(double) dy / h * 2.0);
            }
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left)
            return _dragging || _scaleDragging || _cutoutDragging ||
                _cutoutAdjustDragging;
        if (_cutoutDragging)
        {
            double x1; double y1; double x2; double y2;
            normalizedPointClamped(_cutoutStart, x1, y1);
            normalizedPointClamped(event.position, x2, y2);
            _cutoutDragging = false;
            _cutoutArmed = false;
            releaseMouse();
            setCursor(CursorKind.arrow);
            invalidate();
            if (onCutoutSelectionCompleted !is null)
                onCutoutSelectionCompleted(x1, y1, x2, y2);
            return true;
        }
        if (_cutoutAdjustDragging)
        {
            _cutoutAdjustDragging = false;
            releaseMouse();
            setCursor(CursorKind.arrow);
            if (onCutoutAdjustDragEnded !is null) onCutoutAdjustDragEnded();
            return true;
        }
        if (_scaleDragging)
        {
            _scaleDragging = false;
            releaseMouse();
            setCursor(CursorKind.arrow);
            if (onTransformDragEnded !is null) onTransformDragEnded();
            return true;
        }
        if (!_dragging) return false;
        _dragging = false;
        releaseMouse();
        setCursor(CursorKind.arrow);
        if (onTransformDragEnded !is null) onTransformDragEnded();
        return true;
    }

    protected override void onFocusChanged(bool value)
    {
        if (!value && (_dragging || _scaleDragging || _cutoutDragging ||
            _cutoutAdjustDragging))
        {
            _dragging = false;
            _scaleDragging = false;
            _cutoutDragging = false;
            _cutoutArmed = false;
            _cutoutAdjustDragging = false;
            _cutoutAdjustArmed = false;
            releaseMouse();
            setCursor(CursorKind.arrow);
            if (onTransformDragEnded !is null) onTransformDragEnded();
            if (onCutoutAdjustDragEnded !is null) onCutoutAdjustDragEnded();
            invalidate();
        }
    }
}

unittest
{
    // A title is one persistent TextEditor-derived layer before, during, and
    // after editing. No special background frame or second input widget exists.
    auto preview = new PreviewWidget();
    preview.setBounds(Rect(0, 0, 640, 360));
    PreviewFrame background;
    background.width = 640;
    background.height = 360;
    background.rgb = new ubyte[640 * 360 * 3];
    preview.setFrame(background);

    TitleVisual title;
    title.clipId = 41;
    title.text = "Editable";
    title.fontName = "Sans";
    title.textSize = 96.0;
    preview.setTitleLayers([title], 1920, 1080);
    auto before = preview.titleEditorForTesting(41);
    assert(before !is null && preview.titleLayerCountForTesting() == 1);
    assert(!before.composited(),
        "The title returned as a second compositor surface");

    preview.beginInlineTextEditing(41, title.text, title.fontName,
        title.textSize, "#FFFFFFFF", false, false, false,
        TextAlignment.left, 1080);
    auto during = preview.titleEditorForTesting(41);
    assert(during is before, "Editing replaced the live title with another widget");
    assert(preview.inlineTextEditing() && during.focusable() && !during.readOnly());
    assert(during.hasSelection(), "Editing did not create the expected initial selection");

    preview.endInlineTextEditing(false);
    auto after = preview.titleEditorForTesting(41);
    assert(after is before, "Done replaced the live title layer");
    assert(!after.focusable() && after.readOnly() && after.visible());
    assert(!after.hasSelection(),
        "A stale character selection remained painted after title editing ended");
}

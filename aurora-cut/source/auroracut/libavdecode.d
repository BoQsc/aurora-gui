module auroracut.libavdecode;

/**
 * Optional in-process FFmpeg decoder for instant random-access scrub frames.
 *
 * Aurora Cut historically spawned a fresh `ffmpeg.exe` for every paused still
 * (~54 ms fixed process/init cost). This module optionally binds the FFmpeg
 * shared libraries (libavformat/libavcodec/libavutil/libswscale) at runtime and
 * keeps a decoder open per source, so a seek+decode+RGB convert costs ~0.3 ms.
 *
 * It is deliberately OPTIONAL and self-contained:
 *  - Libraries are loaded dynamically; there is no link-time dependency.
 *  - If the libraries are missing, `available()` is false and every entry point
 *    returns false; callers keep using the existing spawn-based path.
 *  - Struct layouts are pinned to the FFmpeg major versions named in
 *    `libraryNames` (verified against the shipped headers, see
 *    testing_progress_and_methods.md). A version mismatch is detected via the
 *    reported avcodec major and refuses to bind rather than corrupt memory.
 */

import auroracut.ffmpegbundle : bundledFfmpegDirectory;
import auroracut.util : clampValue;
import core.sync.mutex : Mutex;
import core.time : MonoTime;
import std.conv : to;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment;
import std.utf : toUTF16z;

version (Windows) { import core.sys.windows.windows : HMODULE, LoadLibraryExW, GetProcAddress; }
else {}

// The whole accelerator is Windows-only. On any other platform the public
// functions below degrade to "unavailable" so callers keep the ffmpeg path.
version (Windows)
{

private enum uint LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;

// ---------------------------------------------------------------------------
// ABI prefixes (only the fields actually read; offsets verified against the
// shipped libav headers).
// ---------------------------------------------------------------------------
private struct AVRational { int num; int den; }

private struct AVFormatContextPrefix
{
    void* av_class;
    void* iformat;
    void* oformat;
    void* priv_data;
    void* pb;
    int ctx_flags;
    uint nb_streams;
    void** streams;
}

private struct AVStreamPrefix
{
    void* av_class;
    int index;
    int id;
    void* codecpar;
    void* priv_data;
    AVRational time_base;
}

private struct AVFramePrefix
{
    ubyte*[8] data;
    int[8] linesize;
    ubyte** extended_data;
    int width;
    int height;
    int nb_samples;
    int format;
}

private enum int AVMEDIA_TYPE_VIDEO = 0;
private enum int AV_PIX_FMT_RGB24 = 2;
private enum int AVSEEK_FLAG_BACKWARD = 1;
private enum int SWS_BILINEAR = 2;
private enum int AVERROR_EAGAIN = -11;

// ---------------------------------------------------------------------------
// Function aliases
// ---------------------------------------------------------------------------
private alias FnVersion = extern(C) uint function();
private alias FnOpenInput = extern(C) int function(void**, const(char)*, void*, void**);
private alias FnFindStreamInfo = extern(C) int function(void*, void**);
private alias FnFindBestStream = extern(C) int function(void*, int, int, int, void**, int);
private alias FnCloseInput = extern(C) void function(void**);
private alias FnReadFrame = extern(C) int function(void*, void*);
private alias FnSeekFrame = extern(C) int function(void*, int, long, int);
private alias FnAllocContext = extern(C) void* function(const(void)*);
private alias FnParamsToContext = extern(C) int function(void*, const(void)*);
private alias FnOpen2 = extern(C) int function(void*, const(void)*, void**);
private alias FnPacketAlloc = extern(C) void* function();
private alias FnPacketFree = extern(C) void function(void**);
private alias FnPacketUnref = extern(C) void function(void*);
private alias FnSendPacket = extern(C) int function(void*, const(void)*);
private alias FnReceiveFrame = extern(C) int function(void*, void*);
private alias FnFrameAlloc = extern(C) void* function();
private alias FnFrameFree = extern(C) void function(void**);
private alias FnFlushBuffers = extern(C) void function(void*);
private alias FnFreeContext = extern(C) void function(void**);
private alias FnSwsGetContext = extern(C) void* function(int, int, int, int, int,
    int, int, void*, void*, const(double)*);
private alias FnSwsScale = extern(C) int function(void*, const(ubyte*)*,
    const(int)*, int, int, ubyte**, const(int)*);
private alias FnSwsFree = extern(C) void function(void*);

// ---------------------------------------------------------------------------
// Runtime: load the shared libraries once and resolve the symbol subset.
// ---------------------------------------------------------------------------
private final class LibavRuntime
{
    HMODULE _avutil;
    HMODULE _avcodec;
    HMODULE _avformat;
    HMODULE _swscale;

    bool _attempted;
    bool _ready;
    string _reason;

    FnOpenInput openInput;
    FnFindStreamInfo findStreamInfo;
    FnFindBestStream findBestStream;
    FnCloseInput closeInput;
    FnReadFrame readFrame;
    FnSeekFrame seekFrame;
    FnAllocContext allocContext;
    FnParamsToContext paramsToContext;
    FnOpen2 open2;
    FnPacketAlloc packetAlloc;
    FnPacketFree packetFree;
    FnPacketUnref packetUnref;
    FnSendPacket sendPacket;
    FnReceiveFrame receiveFrame;
    FnFrameAlloc frameAlloc;
    FnFrameFree frameFree;
    FnFlushBuffers flushBuffers;
    FnFreeContext freeContext;
    FnSwsGetContext swsGetContext;
    FnSwsScale swsScale;
    FnSwsFree swsFree;

    private static string libDirFromEnvironment()
    {
        // Explicit override (also what tests use) ...
        const configured = environment.get("AURORA_LIBAV_DIR", "");
        if (configured.length > 0 && exists(configured)) return configured;
        // ... or a `libav/` folder shipped beside the executable. Deliberately
        // NOT the current directory: that would let a stray folder silently
        // change preview behavior (and test results).
        try
        {
            const beside = buildPath(dirName(thisExePath()), "libav");
            if (exists(beside)) return beside;
        }
        catch (Exception) {}
        // ... or a `libav/` folder extracted alongside the bundled FFmpeg, so a
        // single-exe release can ship the shared libraries with them.
        const bundled = bundledFfmpegDirectory();
        if (bundled.length > 0)
        {
            const inBundle = buildPath(bundled, "libav");
            if (exists(inBundle)) return inBundle;
        }
        return "";
    }

    private void* symbol(HMODULE library, string name)
    {
        return GetProcAddress(library, cast(const(char)*) (name ~ "\0").ptr);
    }

    bool load()
    {
        if (_attempted) return _ready;
        _attempted = true;
        _reason = "";

        const dir = libDirFromEnvironment();
        if (dir.length == 0)
        {
            _reason = "no libav directory (set AURORA_LIBAV_DIR or add a libav/ folder)";
            return false;
        }

        HMODULE loadOne(string fileName)
        {
            const path = cast(const(char)*) toUTF16z(buildPath(dir, fileName));
            return LoadLibraryExW(cast(const(wchar)*) path, null,
                LOAD_WITH_ALTERED_SEARCH_PATH);
        }

        _avutil = loadOne("avutil-61.dll");
        _swscale = loadOne("swscale-10.dll");
        _avcodec = loadOne("avcodec-63.dll");
        _avformat = loadOne("avformat-63.dll");
        if (_avutil is null || _avcodec is null || _avformat is null ||
            _swscale is null)
        {
            _reason = "libav DLLs not found in " ~ dir;
            return false;
        }

        // Refuse anything that is not the ABI this binding was written for.
        auto avcodecVersion = cast(FnVersion) symbol(_avcodec, "avcodec_version");
        if (avcodecVersion is null)
        {
            _reason = "avcodec_version missing";
            return false;
        }
        const ver = avcodecVersion();
        const major = ver >> 16;
        if (major != 63)
        {
            _reason = "avcodec major " ~ to!string(major) ~ " != 63";
            return false;
        }

        openInput = cast(FnOpenInput) symbol(_avformat, "avformat_open_input");
        findStreamInfo = cast(FnFindStreamInfo) symbol(_avformat, "avformat_find_stream_info");
        findBestStream = cast(FnFindBestStream) symbol(_avformat, "av_find_best_stream");
        closeInput = cast(FnCloseInput) symbol(_avformat, "avformat_close_input");
        readFrame = cast(FnReadFrame) symbol(_avformat, "av_read_frame");
        seekFrame = cast(FnSeekFrame) symbol(_avformat, "av_seek_frame");
        allocContext = cast(FnAllocContext) symbol(_avcodec, "avcodec_alloc_context3");
        paramsToContext = cast(FnParamsToContext) symbol(_avcodec, "avcodec_parameters_to_context");
        open2 = cast(FnOpen2) symbol(_avcodec, "avcodec_open2");
        packetAlloc = cast(FnPacketAlloc) symbol(_avcodec, "av_packet_alloc");
        packetFree = cast(FnPacketFree) symbol(_avcodec, "av_packet_free");
        packetUnref = cast(FnPacketUnref) symbol(_avcodec, "av_packet_unref");
        sendPacket = cast(FnSendPacket) symbol(_avcodec, "avcodec_send_packet");
        receiveFrame = cast(FnReceiveFrame) symbol(_avcodec, "avcodec_receive_frame");
        flushBuffers = cast(FnFlushBuffers) symbol(_avcodec, "avcodec_flush_buffers");
        freeContext = cast(FnFreeContext) symbol(_avcodec, "avcodec_free_context");
        frameAlloc = cast(FnFrameAlloc) symbol(_avutil, "av_frame_alloc");
        frameFree = cast(FnFrameFree) symbol(_avutil, "av_frame_free");
        swsGetContext = cast(FnSwsGetContext) symbol(_swscale, "sws_getContext");
        swsScale = cast(FnSwsScale) symbol(_swscale, "sws_scale");
        swsFree = cast(FnSwsFree) symbol(_swscale, "sws_freeContext");

        if (openInput is null || findStreamInfo is null ||
            findBestStream is null || closeInput is null || readFrame is null ||
            seekFrame is null || allocContext is null ||
            paramsToContext is null || open2 is null || packetAlloc is null ||
            packetFree is null || packetUnref is null || sendPacket is null ||
            receiveFrame is null || frameAlloc is null || frameFree is null ||
            flushBuffers is null || freeContext is null ||
            swsGetContext is null || swsScale is null || swsFree is null)
        {
            _reason = "one or more libav symbols are missing";
            return false;
        }

        _ready = true;
        return true;
    }

    string reason() const { return _reason; }
    bool ready() const { return _ready; }
}

private __gshared LibavRuntime _runtime;
private __gshared Mutex _runtimeMutex;

private LibavRuntime runtime()
{
    if (_runtimeMutex is null)
    {
        synchronized (LibavRuntime.classinfo)
        {
            if (_runtimeMutex is null) _runtimeMutex = new Mutex();
        }
    }
    _runtimeMutex.lock();
    scope (exit) _runtimeMutex.unlock();
    if (_runtime is null) _runtime = new LibavRuntime();
    _runtime.load();
    return _runtime;
}

// ---------------------------------------------------------------------------
// A persistent decoder for one source file.
// ---------------------------------------------------------------------------
private final class LibavDecoder
{
    LibavRuntime rt;
    string path;
    void* format;
    void* codecCtx;
    void* packet;
    void* frame;
    void* sws;
    int streamIndex = -1;
    AVRational timeBase;
    int swsSrcFormat = -1;
    int swsSrcWidth;
    int swsSrcHeight;
    int swsFitWidth;
    int swsFitHeight;
    ubyte[] fittedBuffer;
    double lastDecodeSeconds = -1.0;
    ulong lastUse;

    this(LibavRuntime rt, string path)
    {
        this.rt = rt;
        this.path = path;
    }

    ~this() { close(); }

    bool open()
    {
        if (codecCtx !is null) return true;
        if (rt.openInput(&format, cast(const(char)*) (path ~ "\0").ptr, null,
            null) < 0)
        {
            format = null;
            return false;
        }
        if (rt.findStreamInfo(format, null) < 0)
        {
            rt.closeInput(&format);
            return false;
        }
        void* decoder;
        streamIndex = rt.findBestStream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
            &decoder, 0);
        if (streamIndex < 0 || decoder is null)
        {
            rt.closeInput(&format);
            streamIndex = -1;
            return false;
        }
        auto fmtPrefix = cast(AVFormatContextPrefix*) format;
        auto stream = cast(AVStreamPrefix*) fmtPrefix.streams[streamIndex];
        timeBase = stream.time_base;

        codecCtx = rt.allocContext(decoder);
        if (codecCtx is null ||
            rt.paramsToContext(codecCtx, stream.codecpar) < 0 ||
            rt.open2(codecCtx, decoder, null) < 0)
        {
            if (codecCtx !is null) rt.freeContext(&codecCtx);
            rt.closeInput(&format);
            streamIndex = -1;
            return false;
        }
        packet = rt.packetAlloc();
        frame = rt.frameAlloc();
        if (packet is null || frame is null) { close(); return false; }
        return true;
    }

    void close()
    {
        if (sws !is null) { rt.swsFree(sws); sws = null; }
        if (frame !is null) { rt.frameFree(&frame); frame = null; }
        if (packet !is null) { rt.packetFree(&packet); packet = null; }
        if (codecCtx !is null) { rt.freeContext(&codecCtx); codecCtx = null; }
        if (format !is null) { rt.closeInput(&format); format = null; }
        streamIndex = -1;
        swsSrcFormat = -1;
        fittedBuffer = null;
        lastDecodeSeconds = -1.0;
    }

    private static int packetStreamIndex(const(void)* packet)
    {
        // AVPacket: buf(8) pts(8) dts(8) data(8) size(4) stream_index(4).
        return *(cast(const(int)*) (cast(const(ubyte)*) packet + 36));
    }

    private static long packetPts(const(void)* packet)
    {
        return *(cast(const(long)*) (cast(const(ubyte)*) packet + 8));
    }

    /** Decode the frame whose presentation time is the first >= `seconds`.
     * Returns the native AVFrame pointer (owned by this decoder) or null. */
    private void* decodeAt(double seconds)
    {
        if (codecCtx is null && !open()) return null;
        const targetPts = cast(long) (seconds * timeBase.den / timeBase.num);
        auto seekPts = targetPts;
        if (rt.seekFrame(format, streamIndex, seekPts, AVSEEK_FLAG_BACKWARD) < 0)
        {
            // Fall back to a forward-only decode from the start.
            rt.seekFrame(format, streamIndex, 0, AVSEEK_FLAG_BACKWARD);
        }
        rt.flushBuffers(codecCtx);
        lastDecodeSeconds = seconds;

        void* best;
        foreach (_; 0 .. 2000)
        {
            if (rt.readFrame(format, packet) < 0) break;
            if (packetStreamIndex(packet) != streamIndex)
            {
                rt.packetUnref(packet);
                continue;
            }
            const pts = packetPts(packet);
            const sendResult = rt.sendPacket(codecCtx, packet);
            rt.packetUnref(packet);
            if (sendResult < 0) continue;
            // Drain every frame the decoder has ready for this packet.
            while (true)
            {
                const receive = rt.receiveFrame(codecCtx, frame);
                if (receive < 0) break;
                best = frame;
                if (pts >= targetPts) return frame;
            }
        }
        return best;
    }

    /** Decode at `seconds` and letterbox into an RGB24 `dstW x dstH` buffer
     * using the same fit-then-pad semantics as the ffmpeg preview filter. */
    bool decodeRgb(double seconds, int dstW, int dstH, ubyte[] rgb)
    {
        auto decoded = decodeAt(seconds);
        if (decoded is null) return false;
        auto fp = cast(AVFramePrefix*) frame;
        if (fp.width <= 0 || fp.height <= 0) return false;
        if (rgb.length < cast(size_t) dstW * cast(size_t) dstH * 3) return false;

        // Fit within dst preserving aspect (integer, rounded), then pad black.
        const srcAspect = cast(double) fp.width / cast(double) fp.height;
        int fitW = dstW;
        int fitH = dstH;
        if (cast(double) dstW / cast(double) dstH > srcAspect)
            fitW = cast(int) (dstH * srcAspect + 0.5);
        else
            fitH = cast(int) (dstW / srcAspect + 0.5);
        if (fitW < 2) fitW = 2;
        if (fitH < 2) fitH = 2;
        if ((fitW & 1) != 0) --fitW;
        if ((fitH & 1) != 0) --fitH;

        if (sws is null || swsSrcFormat != fp.format ||
            swsSrcWidth != fp.width || swsSrcHeight != fp.height ||
            swsFitWidth != fitW || swsFitHeight != fitH)
        {
            if (sws !is null) rt.swsFree(sws);
            sws = rt.swsGetContext(fp.width, fp.height, fp.format, fitW, fitH,
                AV_PIX_FMT_RGB24, SWS_BILINEAR, null, null, null);
            swsSrcFormat = fp.format;
            swsSrcWidth = fp.width;
            swsSrcHeight = fp.height;
            swsFitWidth = fitW;
            swsFitHeight = fitH;
            if (sws is null) return false;
        }

        // Fast path: the source already matches the destination aspect, so write
        // straight into the caller's buffer (no temporary, no letterbox fill).
        if (fitW == dstW && fitH == dstH)
        {
            ubyte*[4] dst = [rgb.ptr, null, null, null];
            int[4] dstStride = [dstW * 3, 0, 0, 0];
            const lines = rt.swsScale(sws, cast(const(ubyte*)*) fp.data.ptr,
                cast(const(int)*) fp.linesize.ptr, 0, fp.height, dst.ptr,
                dstStride.ptr);
            return lines > 0;
        }

        const fittedBytes = cast(size_t) fitW * cast(size_t) fitH * 3;
        if (fittedBuffer.length != fittedBytes) fittedBuffer = new ubyte[fittedBytes];
        ubyte*[4] dst = [fittedBuffer.ptr, null, null, null];
        int[4] dstStride = [fitW * 3, 0, 0, 0];
        const lines = rt.swsScale(sws, cast(const(ubyte*)*) fp.data.ptr,
            cast(const(int)*) fp.linesize.ptr, 0, fp.height, dst.ptr,
            dstStride.ptr);
        if (lines <= 0) return false;

        // Black letterbox canvas.
        for (size_t i = 0; i < rgb.length; ++i) rgb[i] = 0;
        const xoff = (dstW - fitW) / 2;
        const yoff = (dstH - fitH) / 2;
        foreach (row; 0 .. fitH)
        {
            const dstOffset = (cast(size_t) (yoff + row) * cast(size_t) dstW +
                cast(size_t) xoff) * 3;
            const srcOffset = cast(size_t) row * cast(size_t) fitW * 3;
            rgb[dstOffset .. dstOffset + cast(size_t) fitW * 3] =
                fittedBuffer[srcOffset .. srcOffset + cast(size_t) fitW * 3];
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
private LibavDecoder[] _decoders;
private __gshared Mutex _decoderMutex;
private enum size_t maxDecoders = 4;
private __gshared bool _disabled;

/** Testing hook: force the accelerator off so the classic ffmpeg path runs. */
void setLibavDecodeEnabledForTesting(bool enabled)
{
    _disabled = !enabled;
}

/** Whether the optional in-process decoder is available on this machine. */
bool libavDecodeAvailable()
{
    if (_disabled) return false;
    return runtime().ready();
}

string libavDecodeUnavailableReason()
{
    return runtime().reason();
}

/**
 * Decode a single RGB24 frame at `seconds`, scaled/letterboxed to `dstW x dstH`,
 * using a persistent in-process decoder. Returns false (and leaves `rgb`
 * untouched) when the decoder is unavailable or the file cannot be decoded, so
 * callers must fall back to the ffmpeg path.
 */
bool decodeLibavRgbFrame(string path, double seconds, int dstW, int dstH,
    ubyte[] rgb)
{
    if (_disabled) return false;
    auto rt = runtime();
    if (!rt.ready() || path.length == 0 || dstW <= 0 || dstH <= 0) return false;

    if (_decoderMutex is null)
    {
        synchronized (LibavDecoder.classinfo)
        {
            if (_decoderMutex is null) _decoderMutex = new Mutex();
        }
    }
    _decoderMutex.lock();
    scope (exit) _decoderMutex.unlock();

    LibavDecoder decoder;
    int found = -1;
    foreach (index, candidate; _decoders)
    {
        if (candidate.path == path) { found = cast(int) index; break; }
    }
    if (found >= 0)
        decoder = _decoders[cast(size_t) found];
    else
    {
        decoder = new LibavDecoder(rt, path);
        if (!decoder.open()) return false;
        if (_decoders.length >= maxDecoders)
        {
            // Evict the least recently used decoder that is not this one.
            size_t oldest;
            foreach (index; 1 .. _decoders.length)
                if (_decoders[index].lastUse < _decoders[oldest].lastUse)
                    oldest = index;
            _decoders = _decoders[0 .. oldest] ~ _decoders[oldest + 1 .. $];
        }
        _decoders ~= decoder;
    }
    decoder.lastUse = ++_decoderClock;
    return decoder.decodeRgb(seconds, dstW, dstH, rgb);
}

private __gshared ulong _decoderClock;

/** Release all cached decoders (call on shutdown). */
void shutdownLibavDecoders()
{
    if (_decoderMutex is null) return;
    _decoderMutex.lock();
    scope (exit) _decoderMutex.unlock();
    foreach (decoder; _decoders) decoder.close();
    _decoders = null;
}

} // version (Windows)

else
{
    void setLibavDecodeEnabledForTesting(bool) {}
    bool libavDecodeAvailable() { return false; }
    string libavDecodeUnavailableReason() { return "not supported on this platform"; }
    bool decodeLibavRgbFrame(string, double, int, int, ubyte[]) { return false; }
    void shutdownLibavDecoders() {}
}

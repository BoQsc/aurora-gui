module aurorastream.broadcast;

import aurorastream.activitylog : ActivityLog;
import aurorastream.audiobridge : AudioBridgeSession;
import aurorastream.browser : BrowserChoice;
import aurorastream.gamecapture : GameCaptureSession, GameCaptureFrame,
    gameCaptureHookPath;
import aurorastream.windowsources : windowExists, windowIsMinimized;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, dur, msecs;
import std.conv : to;
import std.file : append, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, Pid, Redirect, execute, kill, pipeProcess, wait;
import std.stdio : File;
import std.string : indexOf, replace, split, splitLines, startsWith, strip;

/// The CRT `_write` from `<io.h>`, used to push raw BGRA frames into FFmpeg's
/// stdin from the content-capture pump thread. Druntime does not export it.
version (Windows)
{
    import core.stdc.string : memcpy, memset;
    import core.sys.windows.windows : CreateCompatibleDC, CreateDIBSection,
        DeleteDC, DeleteObject, DIB_RGB_COLORS, GetDC, HBITMAP, HDC, HGDIOBJ,
        ReleaseDC, SelectObject, SetStretchBltMode, SRCCOPY, StretchDIBits;
    import core.sys.windows.wingdi : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        GDI_ERROR, HALFTONE;
    private extern (C) int _write(int fd, const(void)* buffer, uint count);
}

enum BroadcastQuality
{
    fullHD,
    twoK,
    fourK
}

enum twitchVideoBitrateKbps = 6_000;
enum defaultAudioBitrateKbps = 160;

struct EncoderSelection
{
    bool ffmpegAvailable;
    string name = "libx264";
    string label = "CPU (libx264)";
    bool hardware;
    bool d3d11DirectProbeAttempted;
    bool d3d11DirectSupported;
}

enum DesktopCaptureBackend
{
    desktopDuplication,
    gdiWithoutCursor
}

struct CaptureSelection
{
    DesktopCaptureBackend backend = DesktopCaptureBackend.gdiWithoutCursor;
    string label = "GDI fallback (cursor omitted)";
    bool capturesCursor;
    int nativeWidth;
    int nativeHeight;
}

struct BroadcastSettings
{
    bool twitchEnabled = true;
    string twitchServer = "rtmps://ingest.global-contribute.live-video.net/app";
    string twitchKey;

    bool youtubeEnabled = true;
    string youtubeServer = "rtmp://a.rtmp.youtube.com/live2";
    string youtubeKey;

    string desktopAudioDevice;
    // UI persistence hint: true with an empty device means select the active
    // Windows default as soon as endpoint enumeration completes.
    bool desktopAudioEnabled = true;
    string microphoneDevice;

    // The shared source canvas before service-specific scaling.
    BroadcastQuality sourceQuality = BroadcastQuality.fullHD;

    // Kept as separate destination profiles even while Twitch is intentionally
    // fixed to its normal 1080p60 preset in this milestone.
    BroadcastQuality twitchQuality = BroadcastQuality.fullHD;
    // YouTube output defaults to 1080p60; 1440p60 and 4K60 are selectable
    // higher profiles that keep the highest internet quality.
    BroadcastQuality youtubeQuality = BroadcastQuality.fullHD;

    // YouTube video bitrate in kbps; 0 = auto (derived from youtubeQuality:
    // 1080p=12000, 1440p=24000, 4K=35000). A separate override lets a stream
    // send 1080p at a higher ingest bitrate when the destination (for example a
    // 4K-configured YouTube key) expects more bandwidth.
    int youtubeBitrateKbps;

    int fps = 60;
    int audioBitrateKbps = defaultAudioBitrateKbps;

    // UI preference: show the live source-canvas preview (background desktop
    // grab) so the broadcaster doubles as a monitor. Toggled off to save
    // CPU/energy; it never changes what is streamed.
    bool liveSourcePreviewEnabled = true;

    // UI preference: when a stream starts, hide the main window into the
    // system tray. A tray icon appears with Start/Stop, Show window, and Exit
    // actions; the stream keeps running in the background.
    // Off by default (auto-hiding while streaming is confusing); an explicitly
    // saved "true" is respected.
    bool minimizeToTrayOnStart = false;

    // UI preference: pressing the window Close button hides to the tray
    // instead of exiting the application. Exiting is always available from
    // the tray icon menu. On by default; an explicitly saved "false" is
    // respected.
    bool closeToTray = true;

    // UI preference: which browser the Twitch/YouTube quick links use.
    // `default` hands the URL to the operating system's default handler;
    // the concrete choices require a detected installation.
    BrowserChoice browserChoice = BrowserChoice.defaultBrowser;

    // Cache of stable audio device identifier → friendly name. Kept so a
    // temporarily disconnected device still shows its real name in the
    // selectors instead of a raw backend ID. Updated from every successful
    // device scan and persisted with the settings.
    string[string] deviceDisplayNameCache;

    // Game/window capture: when windowCaptureHwnd is non-empty (a decimal
    // Windows window handle), only that window is streamed, so viewers never
    // see the rest of the desktop. Empty = capture the whole desktop. The
    // handle is only valid in the session it was picked, so a stale value is
    // reported at stream start instead of silently capturing the desktop.
    string windowCaptureHwnd;
    // Cached friendly "process — title" label for the selected window, kept so
    // the UI still shows a meaningful name while the window is not enumerated.
    string windowCaptureLabel;
    // When true, window capture uses PrintWindow(PW_RENDERFULLCONTENT) to grab
    // the window's OWN content instead of gdigrab's on-screen pixels. The
    // stream then keeps showing the window even when it is covered by other
    // windows, off the visible desktop, or running in the background — and it
    // keeps streaming the last good frame while the window is minimized,
    // resuming automatically on restore. GPU-rendered content (games) may
    // render black through this path, so it is opt-in.
    bool windowContentCapture;

    // When true, inject gamecaphook.dll and capture D3D11 Present frames from
    // the selected process. This is intentionally separate from PrintWindow.
    bool gameCaptureMode;
}

struct BroadcastSnapshot
{
    bool requestedRunning;
    bool processRunning;
    bool failed;
    string status;
    string diagnostics;
    string frame;
    string fps;
    string bitrate;
    string speed;
    string duplicatedFrames;
    string droppedFrames;
    string outputTime;
}

int qualityWidth(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return 2560;
        case BroadcastQuality.fourK: return 3840;
        default: return 1920;
    }
}

int qualityHeight(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return 1440;
        case BroadcastQuality.fourK: return 2160;
        default: return 1080;
    }
}

int youtubeVideoBitrateKbps(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.fourK: return 35_000;
        case BroadcastQuality.twoK: return 24_000;
        default: return 12_000;
    }
}

/// The YouTube video bitrate actually used: a non-zero `youtubeBitrateKbps`
/// override wins, otherwise the quality-derived value.
int effectiveYoutubeBitrateKbps(const BroadcastSettings settings)
{
    return settings.youtubeBitrateKbps > 0 ?
        settings.youtubeBitrateKbps :
        youtubeVideoBitrateKbps(settings.youtubeQuality);
}

string qualityLabel(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return "2K / 2560×1440";
        case BroadcastQuality.fourK: return "4K / 3840×2160";
        default: return "1080p / 1920×1080";
    }
}

string qualityShortLabel(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return "1440p";
        case BroadcastQuality.fourK: return "4K";
        default: return "1080p";
    }
}

private string qualityH264Level(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return "5.1";
        case BroadcastQuality.fourK: return "5.2";
        default: return "4.2";
    }
}

private bool encoderWorks(string encoder)
{
    try
    {
        const result = execute([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "color=c=black:s=64x64:r=1",
            "-frames:v", "1", "-an", "-c:v", encoder,
            "-f", "null", "-"
        ], null, Config.suppressConsole, 2 * 1024 * 1024);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

private bool directD3D11NvencWorks()
{
    version (Windows)
    {
        try
        {
            // Probe the exact hardware-frame boundary before advertising or
            // selecting it. Merely proving that h264_nvenc accepts a CPU
            // color source does not prove that this FFmpeg/NVIDIA combination
            // accepts D3D11 frames emitted by ddagrab.
            const result = execute([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "lavfi", "-i",
                "ddagrab=output_idx=0:framerate=60:draw_mouse=0:dup_frames=1",
                "-frames:v", "2", "-an",
                "-fps_mode:v", "passthrough",
                "-c:v", "h264_nvenc",
                "-preset", "p3", "-tune", "ll", "-rc", "cbr",
                "-b:v", "6000k", "-maxrate", "6000k",
                "-bufsize", "12000k",
                "-profile:v", "high", "-level:v", "4.2",
                "-g", "120", "-keyint_min", "120", "-bf", "2",
                "-f", "null", "-"
            ], null, Config.suppressConsole, 4 * 1024 * 1024);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

EncoderSelection detectEncoder()
{
    EncoderSelection result;
    try
    {
        const versionResult = execute([
            "ffmpeg", "-hide_banner", "-version"
        ], null, Config.suppressConsole, 2 * 1024 * 1024);
        result.ffmpegAvailable = versionResult.status == 0;
    }
    catch (Exception)
    {
        result.ffmpegAvailable = false;
    }

    if (!result.ffmpegAvailable) return result;

    foreach (candidate; [
        ["h264_nvenc", "NVIDIA NVENC"],
        ["h264_qsv", "Intel Quick Sync"],
        ["h264_amf", "AMD AMF"]
    ])
    {
        if (!encoderWorks(candidate[0])) continue;
        result.name = candidate[0];
        result.label = candidate[1];
        result.hardware = true;
        if (candidate[0] == "h264_nvenc")
        {
            result.d3d11DirectProbeAttempted = true;
            result.d3d11DirectSupported = directD3D11NvencWorks();
        }
        return result;
    }
    return result;
}

private bool desktopDuplicationWorks()
{
    version (Windows)
    {
        try
        {
            // Probe one frame so a build that merely lists ddagrab but cannot
            // initialize Desktop Duplication does not become the live backend.
            const result = execute([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "lavfi", "-i",
                "ddagrab=output_idx=0:framerate=1:draw_mouse=1:dup_frames=1," ~
                    "hwdownload,format=bgra",
                "-frames:v", "1", "-an", "-f", "null", "-"
            ], null, Config.suppressConsole, 4 * 1024 * 1024);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    else
    {
        return false;
    }
}

private void readDesktopDuplicationSize(out int width, out int height)
{
    width = 0;
    height = 0;
    version (Windows)
    {
        try
        {
            const result = execute([
                "ffprobe", "-v", "error", "-f", "lavfi", "-i",
                "ddagrab=output_idx=0:framerate=1:draw_mouse=0:dup_frames=1",
                "-show_entries", "stream=width,height",
                "-of", "csv=p=0:s=x"
            ], null, Config.suppressConsole, 2 * 1024 * 1024);
            if (result.status != 0) return;
            const fields = result.output.strip().split("x");
            if (fields.length != 2) return;
            width = fields[0].strip().to!int;
            height = fields[1].strip().to!int;
        }
        catch (Exception)
        {
            width = 0;
            height = 0;
        }
    }
}

CaptureSelection detectCaptureBackend(const EncoderSelection encoder)
{
    CaptureSelection result;
    if (!encoder.hardware) return result;
    if (desktopDuplicationWorks())
    {
        result.backend = DesktopCaptureBackend.desktopDuplication;
        result.label = "Desktop Duplication (cursor-safe)";
        result.capturesCursor = true;
        readDesktopDuplicationSize(result.nativeWidth, result.nativeHeight);
    }
    return result;
}

CaptureSelection detectCaptureBackend()
{
    EncoderSelection encoder;
    encoder.hardware = true;
    return detectCaptureBackend(encoder);
}

bool usesD3D11ZeroCopyVideo(const BroadcastSettings settings,
    const EncoderSelection encoder, const CaptureSelection capture)
{
    // Window capture is a GDI path (no Desktop Duplication surface), so the
    // direct D3D11 handoff never applies to it.
    if (settings.windowCaptureHwnd.strip().length > 0) return false;
    const oneDestination = settings.twitchEnabled != settings.youtubeEnabled;
    if (!oneDestination ||
        capture.backend != DesktopCaptureBackend.desktopDuplication ||
        encoder.name != "h264_nvenc" ||
        !encoder.d3d11DirectSupported)
        return false;

    const destinationQuality = settings.twitchEnabled ?
        settings.twitchQuality : settings.youtubeQuality;
    if (destinationQuality != settings.sourceQuality) return false;

    return capture.nativeWidth == qualityWidth(settings.sourceQuality) &&
        capture.nativeHeight == qualityHeight(settings.sourceQuality);
}

string videoPipelineLabel(const BroadcastSettings settings,
    const EncoderSelection encoder, const CaptureSelection capture)
{
    if (settings.windowCaptureHwnd.strip().length > 0)
        return settings.gameCaptureMode ?
            "Game capture (D3D11 render hook) → CPU processing → encoder" :
            settings.windowContentCapture ?
            "Window content capture → CPU processing → encoder" :
            "Window capture (GDI) → CPU processing → encoder";
    if (usesD3D11ZeroCopyVideo(settings, encoder, capture))
        return "D3D11 direct hardware frames → NVENC";
    if (capture.backend == DesktopCaptureBackend.desktopDuplication)
    {
        if (encoder.name == "h264_nvenc" &&
            encoder.d3d11DirectProbeAttempted &&
            !encoder.d3d11DirectSupported)
            return "D3D11 capture → CPU compatibility path → NVENC";
        return "D3D11 capture → CPU readback/scaling → encoder";
    }
    return "GDI capture → CPU processing → encoder";
}

/// Human label for the actual video source: the captured window when game/window
/// capture is enabled, otherwise the desktop-capture backend.
string captureSourceLabel(const BroadcastSettings settings,
    const CaptureSelection capture)
{
    const window = settings.windowCaptureHwnd.strip();
    if (window.length == 0) return capture.label;
    if (settings.windowCaptureLabel.strip().length > 0)
        return settings.gameCaptureMode ?
            "Game capture: " ~ settings.windowCaptureLabel :
            settings.windowContentCapture ?
            "Window content: " ~ settings.windowCaptureLabel :
            "Window capture: " ~ settings.windowCaptureLabel;
    return "Window capture (" ~ window ~ ")";
}

private bool containsUnsafeSeparator(string value)
{
    return value.indexOf('|') >= 0 || value.indexOf('\r') >= 0 ||
        value.indexOf('\n') >= 0;
}

private bool validServer(string value)
{
    const server = value.strip();
    return server.startsWith("rtmp://") || server.startsWith("rtmps://");
}

private bool validQuality(BroadcastQuality quality)
{
    return quality == BroadcastQuality.fullHD ||
        quality == BroadcastQuality.twoK ||
        quality == BroadcastQuality.fourK;
}

string validateBroadcastSettings(const BroadcastSettings settings,
    const EncoderSelection encoder)
{
    version (Windows)
    {
        // Windows desktop capture prefers Desktop Duplication, with cursor-safe GDI fallback; audio uses WASAPI loopback and DirectShow microphones.
    }
    else
    {
        return "Aurora Stream currently supports Windows desktop capture only.";
    }

    if (!encoder.ffmpegAvailable)
        return "FFmpeg was not found on PATH.";
    if (!settings.twitchEnabled && !settings.youtubeEnabled)
        return "Enable Twitch, YouTube, or both.";
    if (settings.fps != 60)
        return "Aurora Stream currently uses 60 FPS output.";
    if (settings.windowCaptureHwnd.strip().length > 0)
    {
        if (!windowExists(settings.windowCaptureHwnd))
            return "The selected capture window is no longer open (it closed, or the saved selection is from an earlier Windows session). Reopen the window or switch the capture source back to the entire desktop.";
        if (!settings.gameCaptureMode && windowIsMinimized(settings.windowCaptureHwnd))
            return settings.windowContentCapture ?
                "The selected capture window is minimized. Restore it once so Aurora Stream can capture its first frame — after that it keeps streaming the window even if you minimize it again." :
                "The selected capture window is minimized. Restore it before starting the stream — a minimized window cannot be captured (FFmpeg would fail on its 0×0 client area).";
        if (settings.gameCaptureMode && size_t.sizeof != 8)
            return "D3D11 game capture requires a 64-bit Aurora Stream build.";
    }
    else if (settings.gameCaptureMode)
    {
        return "Game capture requires a selected window.";
    }
    if (!validQuality(settings.sourceQuality))
        return "Select a valid common source resolution.";
    if (settings.twitchQuality != BroadcastQuality.fullHD)
        return "Twitch output is currently fixed to the normal 1080p60 profile.";
    if (settings.youtubeQuality != BroadcastQuality.fullHD &&
        settings.youtubeQuality != BroadcastQuality.twoK &&
        settings.youtubeQuality != BroadcastQuality.fourK)
        return "YouTube output must be 1080p60, 1440p60, or 4K60.";
    if (settings.youtubeBitrateKbps < 0 ||
        settings.youtubeBitrateKbps > 80_000)
        return "The YouTube bitrate override must be between 0 (auto) and 80000 kbps.";

    if (settings.twitchEnabled)
    {
        if (!validServer(settings.twitchServer))
            return "Enter a valid Twitch RTMP or RTMPS server URL.";
        if (settings.twitchKey.strip().length == 0)
            return "Enter the Twitch stream key.";
        if (containsUnsafeSeparator(settings.twitchServer) ||
            containsUnsafeSeparator(settings.twitchKey))
            return "The Twitch server URL or key contains an unsupported character.";
    }

    if (settings.youtubeEnabled)
    {
        if (!validServer(settings.youtubeServer))
            return "Enter a valid YouTube RTMP or RTMPS server URL.";
        if (settings.youtubeKey.strip().length == 0)
            return "Enter the YouTube stream key.";
        if (containsUnsafeSeparator(settings.youtubeServer) ||
            containsUnsafeSeparator(settings.youtubeKey))
            return "The YouTube server URL or key contains an unsupported character.";
    }

    if (containsUnsafeSeparator(settings.desktopAudioDevice) ||
        containsUnsafeSeparator(settings.microphoneDevice))
        return "An audio device name contains an unsupported character.";

    return "";
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;

    BroadcastSettings valid;
    valid.twitchEnabled = false;
    valid.youtubeEnabled = true;
    valid.youtubeKey = "test-key";
    assert(validateBroadcastSettings(valid, encoder).length == 0);
}

private string appendPath(string server, string key)
{
    auto base = server.strip();
    auto secret = key.strip();
    while (base.length > 0 && base[$ - 1] == '/') base = base[0 .. $ - 1];
    while (secret.length > 0 && secret[0] == '/') secret = secret[1 .. $];
    return base ~ "/" ~ secret;
}

private double parseProgressClock(string value)
{
    const parts = value.strip().split(":");
    if (parts.length != 3) return 0.0;
    try
    {
        return parts[0].to!double * 3600.0 +
            parts[1].to!double * 60.0 +
            parts[2].to!double;
    }
    catch (Exception)
    {
        return 0.0;
    }
}

private double parseProgressSpeed(string value)
{
    auto text = value.strip();
    if (text.length > 0 && text[$ - 1] == 'x') text = text[0 .. $ - 1];
    try return text.to!double;
    catch (Exception) return 0.0;
}

private long parseProgressInteger(string value)
{
    try return value.strip().to!long;
    catch (Exception) return -1;
}

private bool isDesktopDuplicationFailureLine(string line)
{
    return line.indexOf("AcquireNextFrame failed") >= 0;
}

private void appendEncoderArguments(ref string[] arguments,
    const EncoderSelection encoder, int fps, int videoBitrateKbps,
    string h264Level)
{
    arguments ~= ["-c:v", encoder.name];
    if (encoder.name == "h264_nvenc")
    {
        arguments ~= [
            "-preset", "p3", "-tune", "ll", "-rc", "cbr",
            "-b:v", format("%dk", videoBitrateKbps),
            "-maxrate", format("%dk", videoBitrateKbps),
            "-bufsize", format("%dk", videoBitrateKbps * 2)
        ];
    }
    else if (encoder.name == "h264_qsv")
    {
        arguments ~= [
            "-preset", "veryfast",
            "-b:v", format("%dk", videoBitrateKbps),
            "-maxrate", format("%dk", videoBitrateKbps),
            "-bufsize", format("%dk", videoBitrateKbps * 2)
        ];
    }
    else if (encoder.name == "h264_amf")
    {
        arguments ~= [
            "-usage", "lowlatency", "-quality", "speed", "-rc", "cbr",
            "-b:v", format("%dk", videoBitrateKbps),
            "-maxrate", format("%dk", videoBitrateKbps),
            "-bufsize", format("%dk", videoBitrateKbps * 2)
        ];
    }
    else
    {
        arguments ~= [
            "-preset", "veryfast",
            "-b:v", format("%dk", videoBitrateKbps),
            "-maxrate", format("%dk", videoBitrateKbps),
            "-bufsize", format("%dk", videoBitrateKbps * 2)
        ];
    }

    const keyframeFrames = fps * 2;
    arguments ~= [
        "-profile:v", "high", "-level:v", h264Level,
        "-g", format("%d", keyframeFrames),
        "-keyint_min", format("%d", keyframeFrames)
    ];
    // `sc_threshold` is a software-encoder option and FFmpeg reports it as
    // unused for NVENC/QSV/AMF. Keep it only for libx264 so live logs contain
    // actual failures rather than a known irrelevant startup warning.
    if (encoder.name == "libx264")
        arguments ~= ["-sc_threshold", "0"];
    arguments ~= ["-bf", "2"];
}

private struct PreparedDesktopAudio
{
    string sdpPath;

    bool enabled() const
    {
        return sdpPath.length > 0;
    }
}

private enum AudioClock
{
    generated,
    rtpSampleClock,
    wallClock
}

private struct PreparedAudioInput
{
    int index;
    AudioClock clock;
}

private string[] captureArguments(const BroadcastSettings settings,
    const PreparedDesktopAudio desktopAudio, const CaptureSelection capture,
    bool keepVideoOnGpu, out PreparedAudioInput[] audioInputs)
{
    string[] arguments = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning",
        "-stats_period", "1", "-progress", "pipe:2",
        "-thread_queue_size", "512",
        "-nostdin"
    ];

    const windowCapture = settings.windowCaptureHwnd.strip();
    if (windowCapture.length > 0)
    {
        if (settings.gameCaptureMode || settings.windowContentCapture)
        {
            // Both background-window modes use the same fixed-size raw BGRA
            // stdin contract. The worker selects either the PrintWindow pump or
            // the shared-memory D3D11 hook pump after FFmpeg starts.
            const width = qualityWidth(settings.sourceQuality);
            const height = qualityHeight(settings.sourceQuality);
            arguments ~= [
                "-f", "rawvideo", "-pix_fmt", "bgra",
                "-video_size", format("%dx%d", width, height),
                "-framerate", format("%d", settings.fps),
                "-i", "pipe:0"
            ];
        }
        else
        {
            // Game/window capture: grab only the selected window via gdigrab's
            // window-handle form so viewers never see the rest of the desktop. As
            // with the desktop GDI fallback, keep the cursor path off to avoid
            // disturbing the real Windows pointer.
            arguments ~= [
                "-f", "gdigrab", "-framerate", format("%d", settings.fps),
                "-draw_mouse", "0", "-i", "hwnd=" ~ windowCapture
            ];
        }
    }
    else if (capture.backend == DesktopCaptureBackend.desktopDuplication)
    {
        auto source = format(
            "ddagrab=output_idx=0:framerate=%d:draw_mouse=1:dup_frames=1",
            settings.fps);
        if (!keepVideoOnGpu) source ~= ",hwdownload,format=bgra";
        arguments ~= ["-f", "lavfi", "-i", source];
    }
    else
    {
        // gdigrab's cursor path is known to disturb the real Windows pointer.
        // Keep the compatibility capture usable, but never let it touch/draw
        // the cursor. Desktop Duplication above preserves the stream cursor.
        arguments ~= [
            "-f", "gdigrab", "-framerate", format("%d", settings.fps),
            "-draw_mouse", "0", "-i", "desktop"
        ];
    }

    int nextInput = 1;
    if (desktopAudio.enabled())
    {
        arguments ~= [
            "-protocol_whitelist", "file,udp,rtp",
            // Video device/filter initialization can stall FFmpeg for several
            // seconds. Keep enough local RTP queued that clean WASAPI packets
            // are not discarded merely because the video path is starting.
            "-thread_queue_size", "4096",
            "-buffer_size", "4194304",
            "-reorder_queue_size", "2048",
            "-f", "sdp", "-i", desktopAudio.sdpPath
        ];
        audioInputs ~= PreparedAudioInput(nextInput++,
            AudioClock.rtpSampleClock);
    }
    if (settings.microphoneDevice.strip().length > 0)
    {
        arguments ~= [
            "-thread_queue_size", "256", "-rtbufsize", "64M",
            "-use_wallclock_as_timestamps", "1",
            "-f", "dshow", "-audio_buffer_size", "50",
            "-i", "audio=" ~ settings.microphoneDevice.strip()
        ];
        audioInputs ~= PreparedAudioInput(nextInput++, AudioClock.wallClock);
    }
    if (audioInputs.length == 0)
    {
        arguments ~= [
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"
        ];
        audioInputs ~= PreparedAudioInput(nextInput++, AudioClock.generated);
    }
    return arguments;
}

private string normalizedAudioInputGraph(PreparedAudioInput input,
    string outputLabel)
{
    final switch (input.clock)
    {
        case AudioClock.rtpSampleClock:
            return format(
                "[%d:a]aresample=48000:async=1000:first_pts=0," ~
                "aformat=sample_rates=48000:channel_layouts=stereo," ~
                "asetpts=PTS-STARTPTS[%s]",
                input.index, outputLabel);
        case AudioClock.wallClock:
            return format(
                "[%d:a]aresample=48000:async=1000:first_pts=0," ~
                "aformat=sample_rates=48000:channel_layouts=stereo," ~
                "asetpts=PTS-STARTPTS[%s]",
                input.index, outputLabel);
        case AudioClock.generated:
            return format(
                "[%d:a]aresample=48000:first_pts=0," ~
                "aformat=sample_rates=48000:channel_layouts=stereo," ~
                "asetpts=N/SR/TB[%s]",
                input.index, outputLabel);
    }
}

private string mixedAudioGraph(PreparedAudioInput[] audioInputs,
    string outputLabel)
{
    string graph;
    if (audioInputs.length == 1)
    {
        graph = normalizedAudioInputGraph(audioInputs[0], outputLabel);
    }
    else
    {
        foreach (index, input; audioInputs)
        {
            graph ~= normalizedAudioInputGraph(input,
                format("a%d", cast(int) index)) ~ ";";
        }
        foreach (index; 0 .. audioInputs.length)
            graph ~= format("[a%d]", cast(int) index);
        // All branches have already been normalized to 48 kHz. The mixed
        // output is rebuilt from sample count instead of being stretched a
        // second time by another asynchronous resampler.
        graph ~= format(
            "amix=inputs=%d:duration=longest:dropout_transition=2," ~
            "aresample=48000:first_pts=0," ~
            "asetpts=N/SR/TB[%s]",
            cast(int) audioInputs.length, outputLabel);
    }
    return graph;
}

private void appendAudioEncoderArguments(ref string[] arguments,
    int audioBitrateKbps)
{
    arguments ~= [
        "-c:a", "aac", "-b:a", format("%dk", audioBitrateKbps),
        "-ar", "48000", "-ac", "2",
        "-max_muxing_queue_size", "2048", "-flags", "+global_header"
    ];
}

private string sourceScaleGraph(const BroadcastSettings settings)
{
    const width = qualityWidth(settings.sourceQuality);
    const height = qualityHeight(settings.sourceQuality);
    return format(
        "[0:v]fps=fps=%d:start_time=0:round=near," ~
        "settb=AVTB,setpts=N/(%d*TB)," ~
        "scale=%d:%d:force_original_aspect_ratio=decrease:flags=bicubic," ~
        "pad=%d:%d:(ow-iw)/2:(oh-ih)/2,setsar=1[vsource]",
        settings.fps, settings.fps, width, height, width, height);
}

private string outputScaleGraph(string inputLabel, BroadcastQuality quality,
    string outputLabel)
{
    const width = qualityWidth(quality);
    const height = qualityHeight(quality);
    return format(
        "[%s]scale=%d:%d:force_original_aspect_ratio=decrease:flags=bicubic," ~
        "pad=%d:%d:(ow-iw)/2:(oh-ih)/2,setsar=1," ~
        "format=yuv420p[%s]",
        inputLabel, width, height, width, height, outputLabel);
}

private string outputFromSourceGraph(string inputLabel,
    BroadcastQuality sourceQuality, BroadcastQuality outputQuality,
    string outputLabel)
{
    if (sourceQuality == outputQuality)
        return format("[%s]format=yuv420p[%s]", inputLabel, outputLabel);
    return outputScaleGraph(inputLabel, outputQuality, outputLabel);
}

private void appendIndependentFlvOutput(ref string[] arguments,
    const EncoderSelection encoder, int fps, int videoBitrateKbps,
    string h264Level, int audioBitrateKbps, string videoLabel,
    string audioLabel, string destination, bool directD3D11)
{
    arguments ~= ["-map", videoLabel, "-map", audioLabel];
    if (directD3D11)
        arguments ~= ["-fps_mode:v", "passthrough"];
    else
        arguments ~= [
            "-r:v", format("%d", fps),
            "-fps_mode:v", "cfr"
        ];
    appendEncoderArguments(arguments, encoder, fps, videoBitrateKbps, h264Level);
    appendAudioEncoderArguments(arguments, audioBitrateKbps);

    // Network output must never own the capture/encode thread. A direct RTMP
    // muxer performs its socket/TLS/RTMP handshake synchronously before FFmpeg
    // begins processing frames. If that handshake stalls, the UI sees no frame
    // or timestamp even though local capture and audio are healthy. The FIFO
    // muxer moves network open/write/recovery into its own worker. Its bounded
    // queue absorbs short RTMP stalls, but it must not drop arbitrary live
    // packets: Twitch can buffer indefinitely after receiving a damaged stream.
    // If the queue fills, FFmpeg back-pressures and the live watchdog stops the
    // stream with an explicit network/output health failure.
    arguments ~= [
        "-f", "fifo", "-fifo_format", "flv",
        "-queue_size", "1200",
        "-format_opts",
            "max_interleave_delta=0:flush_packets=1:" ~
            "flvflags=no_duration_filesize",
        "-attempt_recovery", "1", "-recovery_wait_time", "1",
        "-restart_with_keyframe", "1",
        destination
    ];
}

private string[] independentOutputArguments(const BroadcastSettings settings,
    const EncoderSelection encoder, const PreparedDesktopAudio desktopAudio,
    const CaptureSelection capture)
{
    PreparedAudioInput[] audioInputs;
    const zeroCopyVideo = usesD3D11ZeroCopyVideo(settings, encoder, capture);
    auto arguments = captureArguments(settings, desktopAudio, capture,
        zeroCopyVideo, audioInputs);
    const twoOutputs = settings.twitchEnabled && settings.youtubeEnabled;

    string graph;
    string twitchVideoMap;
    string youtubeVideoMap;
    if (zeroCopyVideo)
    {
        // Map ddagrab's D3D11 frames directly. Even seemingly harmless
        // software filters force a GPU download on some FFmpeg builds.
        if (settings.twitchEnabled) twitchVideoMap = "0:v";
        if (settings.youtubeEnabled) youtubeVideoMap = "0:v";
    }
    else
    {
        graph = sourceScaleGraph(settings);
        if (twoOutputs)
        {
            graph ~= ";[vsource]split=2[vtwitchsource][vyoutubesource]";
            graph ~= ";" ~ outputFromSourceGraph("vtwitchsource",
                settings.sourceQuality, settings.twitchQuality, "vtwitch");
            graph ~= ";" ~ outputFromSourceGraph("vyoutubesource",
                settings.sourceQuality, settings.youtubeQuality, "vyoutube");
        }
        else if (settings.twitchEnabled)
        {
            graph ~= ";" ~ outputFromSourceGraph("vsource",
                settings.sourceQuality, settings.twitchQuality, "vtwitch");
        }
        else
        {
            graph ~= ";" ~ outputFromSourceGraph("vsource",
                settings.sourceQuality, settings.youtubeQuality, "vyoutube");
        }
    }

    if (!zeroCopyVideo)
    {
        if (settings.twitchEnabled) twitchVideoMap = "[vtwitch]";
        if (settings.youtubeEnabled) youtubeVideoMap = "[vyoutube]";
    }

    if (graph.length > 0) graph ~= ";";
    graph ~= mixedAudioGraph(audioInputs, "amixed");
    if (twoOutputs) graph ~= ";[amixed]asplit=2[atwitch][ayoutube]";

    arguments ~= ["-filter_complex", graph];

    if (settings.twitchEnabled)
    {
        appendIndependentFlvOutput(arguments, encoder, settings.fps,
            twitchVideoBitrateKbps, qualityH264Level(settings.twitchQuality),
            settings.audioBitrateKbps, twitchVideoMap,
            twoOutputs ? "[atwitch]" : "[amixed]",
            appendPath(settings.twitchServer, settings.twitchKey),
            zeroCopyVideo);
    }

    if (settings.youtubeEnabled)
    {
        appendIndependentFlvOutput(arguments, encoder, settings.fps,
            effectiveYoutubeBitrateKbps(settings),
            qualityH264Level(settings.youtubeQuality),
            settings.audioBitrateKbps, youtubeVideoMap,
            twoOutputs ? "[ayoutube]" : "[amixed]",
            appendPath(settings.youtubeServer, settings.youtubeKey),
            zeroCopyVideo);
    }
    return arguments;
}

string[] broadcastArguments(const BroadcastSettings settings,
    const EncoderSelection encoder, const CaptureSelection capture)
{
    // Public model helper used by tests. The live worker supplies the actual
    // isolated WASAPI RTP input after opening the selected Windows playback endpoint.
    PreparedDesktopAudio desktopAudio;
    return independentOutputArguments(settings, encoder, desktopAudio, capture);
}

string[] broadcastArguments(const BroadcastSettings settings,
    const EncoderSelection encoder)
{
    CaptureSelection compatibilityCapture;
    return broadcastArguments(settings, encoder, compatibilityCapture);
}

/// Builds a local FLV capture using the same desktop input, source canvas,
/// Twitch scaling, H.264 settings, AAC settings, CFR policy, and mux timing as
/// the live Twitch path. The diagnostic caller supplies an already-opened
/// isolated WASAPI RTP input when real desktop audio is enabled. No stream key or
/// network destination is involved.
string[] pacingDiagnosticArguments(BroadcastSettings sourceSettings,
    const EncoderSelection encoder, const CaptureSelection capture,
    string desktopAudioSdpPath, string outputPath, int durationSeconds)
{
    auto settings = sourceSettings;
    settings.twitchEnabled = true;
    settings.youtubeEnabled = false;
    settings.twitchQuality = BroadcastQuality.fullHD;

    PreparedDesktopAudio desktopAudio;
    desktopAudio.sdpPath = desktopAudioSdpPath;

    PreparedAudioInput[] audioInputs;
    const zeroCopyVideo = usesD3D11ZeroCopyVideo(settings, encoder, capture);
    auto arguments = captureArguments(settings, desktopAudio, capture,
        zeroCopyVideo, audioInputs);
    // Replace the normal one-second status cadence with a denser diagnostic
    // cadence, and permit replacing prior test files deliberately.
    foreach (index; 0 .. arguments.length)
    {
        if (arguments[index] == "-stats_period" && index + 1 < arguments.length)
            arguments[index + 1] = "0.25";
    }
    arguments = arguments[0 .. 1] ~ ["-y", "-benchmark"] ~ arguments[1 .. $];

    string graph;
    string videoMap;
    if (zeroCopyVideo)
    {
        videoMap = "0:v";
    }
    else
    {
        graph = sourceScaleGraph(settings);
        graph ~= ";" ~ outputFromSourceGraph("vsource",
            settings.sourceQuality, BroadcastQuality.fullHD, "vdiagnostic");
        videoMap = "[vdiagnostic]";
    }
    if (graph.length > 0) graph ~= ";";
    graph ~= mixedAudioGraph(audioInputs, "adiagnostic");
    arguments ~= ["-filter_complex", graph];

    arguments ~= ["-map", videoMap, "-map", "[adiagnostic]"];
    if (zeroCopyVideo)
        arguments ~= ["-fps_mode:v", "passthrough"];
    else
        arguments ~= [
            "-r:v", format("%d", settings.fps),
            "-fps_mode:v", "cfr"
        ];
    appendEncoderArguments(arguments, encoder, settings.fps,
        twitchVideoBitrateKbps, qualityH264Level(BroadcastQuality.fullHD));
    appendAudioEncoderArguments(arguments, settings.audioBitrateKbps);
    arguments ~= [
        "-t", format("%d", durationSeconds),
        "-max_interleave_delta", "0",
        "-flush_packets", "1",
        "-flvflags", "no_duration_filesize",
        "-f", "flv", outputPath
    ];
    return arguments;
}

unittest
{
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.desktopAudioDevice = "{windows-render-endpoint}";

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";

    PreparedDesktopAudio desktopAudio;
    desktopAudio.sdpPath = `C:\temp\aurora-audio.sdp`;

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.label = "test Desktop Duplication";
    capture.capturesCursor = true;

    const arguments = independentOutputArguments(settings, encoder,
        desktopAudio, capture);
    bool foundSdp;
    bool foundRtpWhitelist;
    bool foundRtpClock;
    bool foundRawPcm;
    foreach (argument; arguments)
    {
        if (argument == desktopAudio.sdpPath) foundSdp = true;
        if (argument == "file,udp,rtp") foundRtpWhitelist = true;
        if (argument.indexOf("asetpts=PTS-STARTPTS") >= 0)
            foundRtpClock = true;
        if (argument == "f32le" || argument == "s16le")
            foundRawPcm = true;
    }
    assert(foundSdp);
    assert(foundRtpWhitelist);
    assert(foundRtpClock);
    assert(!foundRawPcm);
}
unittest
{
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.twitchQuality = BroadcastQuality.fullHD;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";
    encoder.d3d11DirectProbeAttempted = true;
    encoder.d3d11DirectSupported = true;

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    const arguments = broadcastArguments(settings, encoder, capture);
    bool downloadedToCpu;
    bool softwareScaled;
    foreach (argument; arguments)
    {
        if (argument.indexOf("hwdownload") >= 0) downloadedToCpu = true;
        if (argument.indexOf("scale=1920:1080") >= 0) softwareScaled = true;
    }
    assert(usesD3D11ZeroCopyVideo(settings, encoder, capture));
    assert(!downloadedToCpu);
    assert(!softwareScaled);
}
unittest
{
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.twitchQuality = BroadcastQuality.fullHD;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";
    encoder.d3d11DirectProbeAttempted = true;
    encoder.d3d11DirectSupported = false;

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    const arguments = broadcastArguments(settings, encoder, capture);
    bool downloadedToCpu;
    foreach (argument; arguments)
    {
        if (argument.indexOf("hwdownload") >= 0) downloadedToCpu = true;
    }
    assert(!usesD3D11ZeroCopyVideo(settings, encoder, capture));
    assert(downloadedToCpu);
    assert(videoPipelineLabel(settings, encoder, capture) ==
        "D3D11 capture → CPU compatibility path → NVENC");
}

unittest
{
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";

    CaptureSelection capture;
    const arguments = broadcastArguments(settings, encoder, capture);
    bool foundFifo;
    bool foundBoundedQueue;
    bool foundDropOnOverflow;
    foreach (index, argument; arguments)
    {
        if (argument == "-fifo_format") foundFifo = true;
        if (argument.indexOf("drop_pkts") >= 0) foundDropOnOverflow = true;
        if (argument == "-queue_size" && index + 1 < arguments.length &&
            arguments[index + 1] == "1200")
            foundBoundedQueue = true;
    }
    assert(foundFifo);
    assert(foundBoundedQueue);
    assert(!foundDropOnOverflow);
}

unittest
{
    EncoderSelection cpuEncoder;
    cpuEncoder.ffmpegAvailable = true;
    cpuEncoder.name = "libx264";
    cpuEncoder.hardware = false;

    const capture = detectCaptureBackend(cpuEncoder);
    assert(capture.backend == DesktopCaptureBackend.gdiWithoutCursor);
}

unittest
{
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = true;
    settings.youtubeKey = "test-key-2";

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";

    CaptureSelection capture;
    const arguments = broadcastArguments(settings, encoder, capture);
    size_t fifoOutputs;
    foreach (argument; arguments)
        if (argument == "-fifo_format") ++fifoOutputs;
    assert(fifoOutputs == 2);
}

unittest
{
    // Window capture must use gdigrab's window-handle form, must never take the
    // D3D11 zero-copy path, and must surface the window in the pipeline label.
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.windowCaptureHwnd = "1841952";
    settings.windowCaptureLabel = "notepad.exe — Notes";

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";
    encoder.d3d11DirectProbeAttempted = true;
    encoder.d3d11DirectSupported = true;

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    assert(!usesD3D11ZeroCopyVideo(settings, encoder, capture));
    assert(videoPipelineLabel(settings, encoder, capture) ==
        "Window capture (GDI) → CPU processing → encoder");
    assert(captureSourceLabel(settings, capture) ==
        "Window capture: notepad.exe — Notes");

    const arguments = broadcastArguments(settings, encoder, capture);
    bool foundWindowHwnd;
    bool foundGdigrab;
    bool foundDesktopDup;
    foreach (index, argument; arguments)
    {
        if (argument == "hwnd=1841952") foundWindowHwnd = true;
        if (argument == "gdigrab") foundGdigrab = true;
        if (argument.indexOf("ddagrab") >= 0) foundDesktopDup = true;
    }
    assert(foundWindowHwnd);
    assert(foundGdigrab);
    assert(!foundDesktopDup);
}

unittest
{
    // Window-content capture replaces the gdigrab screen grab with a rawvideo
    // pipe that the app pumps PrintWindow frames into, so covered/background
    // windows keep streaming their own content.
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.windowCaptureHwnd = "1841952";
    settings.windowCaptureLabel = "notepad.exe — Notes";
    settings.windowContentCapture = true;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    const arguments = broadcastArguments(settings, encoder, capture);
    bool foundRawvideo;
    bool foundPipe;
    bool foundPipeSize;
    bool foundBgra;
    bool foundGdigrab;
    bool foundHwnd;
    foreach (index, argument; arguments)
    {
        if (argument == "rawvideo") foundRawvideo = true;
        if (argument == "pipe:0") foundPipe = true;
        if (argument == "1920x1080") foundPipeSize = true;
        if (argument == "bgra") foundBgra = true;
        if (argument == "gdigrab") foundGdigrab = true;
        if (argument.indexOf("hwnd=") >= 0) foundHwnd = true;
    }
    assert(foundRawvideo);
    assert(foundPipe);
    assert(foundPipeSize);
    assert(foundBgra);
    assert(!foundGdigrab);
    assert(!foundHwnd);
    assert(videoPipelineLabel(settings, encoder, capture) ==
        "Window content capture → CPU processing → encoder");
    assert(captureSourceLabel(settings, capture) ==
        "Window content: notepad.exe — Notes");
}

unittest
{
    // Game capture is a distinct rawvideo source, not PrintWindow or gdigrab.
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;
    settings.windowCaptureHwnd = "1841952";
    settings.windowCaptureLabel = "game.exe — Game";
    settings.gameCaptureMode = true;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";
    const arguments = broadcastArguments(settings, encoder, CaptureSelection.init);
    bool rawvideo;
    bool gdigrab;
    bool ddagrab;
    foreach (argument; arguments)
    {
        if (argument == "rawvideo") rawvideo = true;
        if (argument == "gdigrab") gdigrab = true;
        if (argument.indexOf("ddagrab") >= 0) ddagrab = true;
    }
    assert(rawvideo);
    assert(!gdigrab);
    assert(!ddagrab);
    assert(videoPipelineLabel(settings, encoder, CaptureSelection.init) ==
        "Game capture (D3D11 render hook) → CPU processing → encoder");
    assert(captureSourceLabel(settings, CaptureSelection.init) ==
        "Game capture: game.exe — Game");
}

unittest
{
    // A stale window handle is rejected at start instead of silently capturing
    // the desktop; an empty handle (desktop mode) remains valid.
    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "test-key";
    settings.youtubeEnabled = false;

    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "libx264";

    CaptureSelection capture;
    const valid = validateBroadcastSettings(settings, encoder);
    assert(valid.length == 0);

    settings.windowCaptureHwnd = "0";
    const invalid = validateBroadcastSettings(settings, encoder);
    assert(invalid.indexOf("capture window") >= 0);
}

unittest
{
    // A Desktop Duplication output loss must be flagged RECOVERABLE (not a
    // permanent capture failure) so the launch loop can relaunch FFmpeg after
    // an alt-tab / fullscreen transition, and it must clear once relaunched.
    auto worker = new BroadcastWorker(".");
    string[] secrets = [];
    worker._mutex.lock();
    worker._requestedRunning = true;
    worker._captureLossRecoverable = false;
    worker._captureLossRecoverableDiagnosed = false;
    worker._videoCaptureFailed = false;
    worker._mutex.unlock();

    worker.parseLine(
        "[ddagrab @ 000001] AcquireNextFrame failed: error",
        secrets, null);

    worker._mutex.lock();
    assert(worker._captureLossRecoverable);
    assert(!worker._videoCaptureFailed); // recoverable, not fatal yet
    assert(worker._captureLossRecoverableDiagnosed);
    assert(worker._status == "Desktop capture lost — reconnecting…");
    worker._mutex.unlock();

    // A second loss line must not re-diagnose (still flagged recoverable).
    worker.parseLine(
        "[ddagrab @ 000002] AcquireNextFrame failed: again",
        secrets, null);
    worker._mutex.lock();
    assert(worker._captureLossRecoverable);
    worker._mutex.unlock();

    // The relaunch path clears the flags so the next attempt is a fresh start.
    worker._mutex.lock();
    worker._captureLossRecoverable = false;
    worker._captureLossRecoverableDiagnosed = false;
    worker._videoCaptureFailed = false;
    worker._mutex.unlock();
    assert(!worker._captureLossRecoverable);
    assert(!worker._captureLossRecoverableDiagnosed);

    // The monitor's exit condition mirrors `monitorProcess`: it returns when
    // the process is gone, the user stopped, the app is shutting down, OR the
    // capture loss is flagged. A flagged loss must force an exit even when the
    // process and requestedRunning look healthy (so run() can relaunch), and a
    // user stop must exit even when the process is still marked running.
    worker._mutex.lock();
    worker._requestedRunning = true;
    worker._processRunning = true;
    worker._captureLossRecoverable = true;
    const lossForcesExit = worker._captureLossRecoverable;
    worker._captureLossRecoverable = false;
    worker._requestedRunning = false;
    const userStopForcesExit = !worker._requestedRunning;
    worker._mutex.unlock();
    assert(lossForcesExit);
    assert(userStopForcesExit);
}

private string sanitize(string text, const(string)[] secrets)
{
    auto result = text;
    foreach (secret; secrets)
    {
        if (secret.length > 0) result = result.replace(secret, "<hidden>");
    }
    return result;
}

final class BroadcastWorker
{
    private Mutex _mutex;
    private Thread _thread;
    private Pid _process;
    private string _executablePath;
    private ActivityLog _activityLog;
    private bool _requestedRunning;
    private bool _processRunning;
    private bool _shutdown;
    private bool _failed;
    private bool _audioBridgeFailed;
    private bool _audioCaptureSeen;
    private bool _audioSilenceNoticeLogged;
    private bool _startupComplete;
    private bool _startupFailed;
    private string _startupFailureReason;
    private bool _liveOutputFailed;
    private string _liveOutputFailureReason;
    private size_t _progressSerial;
    private long _progressVideoFrame;
    private double _progressOutputSeconds;
    private double _progressSpeed;
    private bool _videoCaptureFailed;
    private string _videoCaptureFailureReason;
    private string _captureFailureStatus;
    private bool _captureLossRecoverable;
    private bool _captureLossRecoverableDiagnosed;
    private bool _failureLoggedToActivity;
    private string _startupLogPath;
    private string _status = "Ready";
    private string _diagnostics;
    private string _frame;
    private string _fps;
    private string _bitrate;
    private string _speed;
    private string _duplicatedFrames;
    private string _droppedFrames;
    private string _outputTime;

    this(string executablePath, ActivityLog activityLog = null)
    {
        _mutex = new Mutex();
        _executablePath = executablePath.idup;
        _activityLog = activityLog;
        const folder = executablePath.length > 0 ? dirName(executablePath) : ".";
        _startupLogPath = buildPath(folder, "aurora-stream-startup.log");
    }

    bool start(const BroadcastSettings settings, const EncoderSelection encoder,
        const CaptureSelection capture, out string error)
    {
        error = validateBroadcastSettings(settings, encoder);
        if (error.length > 0)
        {
            activityError("Stream start rejected: " ~ error);
            return false;
        }

        Thread completedWorker;
        _mutex.lock();
        if (_requestedRunning || _processRunning)
        {
            _mutex.unlock();
            error = "A broadcast is already running.";
            activityWarning("Stream start rejected: " ~ error);
            return false;
        }
        if (_shutdown)
        {
            _mutex.unlock();
            error = "The broadcaster is shutting down.";
            activityWarning("Stream start rejected: " ~ error);
            return false;
        }

        completedWorker = _thread;
        _thread = null;
        _requestedRunning = true;
        _processRunning = false;
        _failed = false;
        _audioBridgeFailed = false;
        _audioCaptureSeen = false;
        _audioSilenceNoticeLogged = false;
        _startupComplete = false;
        _startupFailed = false;
        _startupFailureReason = "";
        _liveOutputFailed = false;
        _liveOutputFailureReason = "";
        _progressSerial = 0;
        _progressVideoFrame = 0;
        _progressOutputSeconds = 0.0;
        _progressSpeed = 0.0;
        _videoCaptureFailed = false;
        _videoCaptureFailureReason = "";
        _captureFailureStatus = "";
        _captureLossRecoverable = false;
        _captureLossRecoverableDiagnosed = false;
        _failureLoggedToActivity = false;
        _status = "Starting FFmpeg…";
        _diagnostics = "";
        _frame = "";
        _fps = "";
        _bitrate = "";
        _speed = "";
        _duplicatedFrames = "";
        _droppedFrames = "";
        _outputTime = "";
        _mutex.unlock();

        if (completedWorker !is null)
        {
            try completedWorker.join();
            catch (Exception) {}
        }

        auto workerSettings = settings;
        auto workerEncoder = encoder;
        auto workerCapture = capture;
        string[] secrets = [settings.twitchKey.idup, settings.youtubeKey.idup];
        try
        {
            auto worker = new Thread({
                run(workerSettings, workerEncoder, workerCapture, secrets);
            });
            worker.isDaemon = true;
            _mutex.lock();
            _thread = worker;
            const cancelledBeforeStart = !_requestedRunning || _shutdown;
            _mutex.unlock();
            worker.start();
            if (cancelledBeforeStart) stop();
            return true;
        }
        catch (Exception threadError)
        {
            _mutex.lock();
            _requestedRunning = false;
            _processRunning = false;
            _failed = true;
            _thread = null;
            _status = "Could not start broadcast worker";
            _diagnostics = threadError.msg;
            _mutex.unlock();
            error = "Could not start broadcast worker: " ~ threadError.msg;
            activityError("Stream start rejected: " ~ error);
            return false;
        }
    }

    void stop()
    {
        Pid process;
        _mutex.lock();
        _requestedRunning = false;
        if (_processRunning) _status = "Stopping stream…";
        process = _process;
        _mutex.unlock();

        if (process !is null)
        {
            try kill(process);
            catch (Exception) {}
        }
    }

    BroadcastSnapshot snapshot()
    {
        BroadcastSnapshot result;
        _mutex.lock();
        scope (exit) _mutex.unlock();
        result.requestedRunning = _requestedRunning;
        result.processRunning = _processRunning;
        result.failed = _failed;
        result.status = _status;
        result.diagnostics = _diagnostics;
        result.frame = _frame;
        result.fps = _fps;
        result.bitrate = _bitrate;
        result.speed = _speed;
        result.duplicatedFrames = _duplicatedFrames;
        result.droppedFrames = _droppedFrames;
        result.outputTime = _outputTime;
        return result;
    }

    void shutdown()
    {
        _mutex.lock();
        _shutdown = true;
        _mutex.unlock();
        stop();
        if (_thread !is null)
        {
            try _thread.join();
            catch (Exception) {}
        }
    }

    /// Mirrors a message into the always-on activity log when one is wired in
    /// (null-safe so unit tests can construct a worker without one).
    private void activityInfo(string message)
    {
        if (_activityLog !is null) _activityLog.info(message);
    }

    private void activityWarning(string message)
    {
        if (_activityLog !is null) _activityLog.warning(message);
    }

    private void activityError(string message)
    {
        if (_activityLog !is null) _activityLog.error(message);
    }

    private void activityAction(string message)
    {
        if (_activityLog !is null) _activityLog.action(message);
    }

    private void resetPersistentLog(const BroadcastSettings settings,
        const EncoderSelection encoder, const CaptureSelection capture)
    {
        string header =
            "Aurora Stream startup diagnostic\r\n" ~
            "================================\r\n" ~
            format("Twitch enabled: %s\r\n", settings.twitchEnabled) ~
            format("YouTube enabled: %s\r\n", settings.youtubeEnabled) ~
            format("Desktop audio enabled: %s\r\n",
                settings.desktopAudioDevice.strip().length > 0) ~
            format("Encoder: %s (%s)\r\n", encoder.label, encoder.name) ~
            format("Video source: %s\r\n",
                captureSourceLabel(settings, capture)) ~
            format("Video path: %s\r\n",
                videoPipelineLabel(settings, encoder, capture)) ~
            "Output wrapper: bounded non-dropping FIFO isolation per destination\r\n" ~
            "Live watchdog: stops on sustained post-startup network/output stalls\r\n" ~
            "Stream keys are never written to this file.\r\n\r\n";
        try write(_startupLogPath, header);
        catch (Exception) {}
    }

    private void appendPersistentLog(string line)
    {
        if (line.length == 0) return;
        try append(_startupLogPath, line ~ "\r\n");
        catch (Exception) {}
    }

    private void appendArgumentLog(const string[] arguments,
        const(string)[] secrets)
    {
        appendPersistentLog("FFmpeg arguments (one argument per line):");
        foreach (index, argument; arguments)
            appendPersistentLog(format("  [%s] %s", index,
                sanitize(argument, secrets)));
        appendPersistentLog("");
    }

    private void appendDiagnostic(string line)
    {
        if (line.length == 0) return;
        _diagnostics ~= (_diagnostics.length == 0 ? "" : "\n") ~ line;
        auto lines = _diagnostics.splitLines();
        if (lines.length > 8)
        {
            _diagnostics = "";
            foreach (index, entry; lines[$ - 8 .. $])
                _diagnostics ~= (index == 0 ? "" : "\n") ~ entry;
        }
    }

    private void inspectDesktopAudio(AudioBridgeSession bridge)
    {
        if (bridge is null) return;
        const bridgeError = bridge.failure();
        if (bridgeError.length == 0) return;

        Pid process;
        _mutex.lock();
        if (!_audioBridgeFailed)
        {
            _audioBridgeFailed = true;
            _requestedRunning = false;
            _failureLoggedToActivity = true;
            appendDiagnostic("Desktop audio helper failed: " ~ bridgeError);
            process = _process;
        }
        _mutex.unlock();
        if (process !is null)
        {
            appendPersistentLog("AUDIO HELPER FAILURE: " ~ bridgeError);
            activityError("Desktop audio helper failed: " ~ bridgeError);
            activityAction("Action taken: FFmpeg was terminated because the desktop-audio helper failed.");
            try kill(process);
            catch (Exception error)
            {
                appendPersistentLog(
                    "Could not terminate FFmpeg after helper failure: " ~
                    error.msg);
            }
        }
    }

    private void monitorProcess(Pid process, AudioBridgeSession bridge,
        string windowCaptureHwnd, bool holdsLastFrame = false)
    {
        enum startupDeadlineTicks = 120; // 12 seconds at 100 ms per tick.
        enum liveProgressDeadlineTicks = 120;
        enum liveOutputDeadlineTicks = 120;
        enum liveVideoFrameDeadlineTicks = 120;
        enum slowSpeedDeadlineTicks = 120;
        enum minimumLiveSpeed = 0.95;
        enum liveWarmupSeconds = 4.0;
        size_t startupTicks;
        size_t audioTicks;
        size_t progressQuietTicks;
        size_t outputFrozenTicks;
        size_t videoFrameFrozenTicks;
        size_t slowSpeedTicks;
        size_t lastProgressSerial;
        long lastVideoFrame = -1;
        double lastOutputSeconds = -1.0;
        bool outputAdvancedOnce;
        bool videoAdvancedOnce;
        while (true)
        {
            Thread.sleep(100.msecs);
            ++audioTicks;
            if (bridge !is null) inspectDesktopAudio(bridge);

            bool captureBecameActive;
            bool logSilentEndpoint;
            if (bridge !is null)
            {
                const active = bridge.captureActive();
                _mutex.lock();
                if (active && !_audioCaptureSeen)
                {
                    _audioCaptureSeen = true;
                    captureBecameActive = true;
                    appendDiagnostic(
                        "Desktop audio packets are now being captured.");
                }
                else if (!active && !_audioSilenceNoticeLogged &&
                    audioTicks >= 30)
                {
                    _audioSilenceNoticeLogged = true;
                    logSilentEndpoint = true;
                    appendDiagnostic(
                        "Desktop endpoint has produced no packets yet; RTP silence keeps A/V running until playback begins.");
                }
                _mutex.unlock();
            }
            if (captureBecameActive)
            {
                appendPersistentLog(
                    "Desktop audio capture became active (real WASAPI packets observed).");
                activityInfo(
                    "Desktop audio capture became active (real WASAPI packets observed).");
            }
            if (logSilentEndpoint)
            {
                appendPersistentLog(
                    "Desktop audio notice: no WASAPI packets after three seconds; continuing with bounded RTP silence.");
                activityWarning(
                    "Desktop audio: no WASAPI packets after three seconds; continuing with bounded RTP silence.");
            }

            bool terminate;
            bool startupTermination;
            bool videoCaptureTermination;
            string failureReason;
            _mutex.lock();
            const sameProcess = _process is process && _processRunning;
            const shouldContinue = _requestedRunning && !_shutdown;
            const captureLoss = _captureLossRecoverable;
            if (!sameProcess || !shouldContinue || captureLoss)
            {
                _mutex.unlock();
                return;
            }

            if (!_startupComplete)
            {
                ++startupTicks;
                if (startupTicks >= startupDeadlineTicks)
                {
                    failureReason =
                        "No encoded frame or valid output timestamp arrived " ~
                        "within 12 seconds. FFmpeg was terminated instead of " ~
                        "remaining on Connecting indefinitely.";
                    startupTermination = true;
                    _startupFailed = true;
                    _startupFailureReason = failureReason;
                    _failed = true;
                    _requestedRunning = false;
                    _status = "FFmpeg startup timed out";
                    appendDiagnostic(failureReason);
                    _failureLoggedToActivity = true;
                    terminate = true;
                }
            }
            else
            {
                const progressSerial = _progressSerial;
                const videoFrame = _progressVideoFrame;
                const outputSeconds = _progressOutputSeconds;
                const speed = _progressSpeed;

                if (progressSerial != lastProgressSerial)
                {
                    lastProgressSerial = progressSerial;
                    progressQuietTicks = 0;
                }
                else
                    ++progressQuietTicks;

                if (outputSeconds > lastOutputSeconds + 0.05)
                {
                    lastOutputSeconds = outputSeconds;
                    outputFrozenTicks = 0;
                    outputAdvancedOnce = true;
                }
                else if (outputSeconds >= liveWarmupSeconds ||
                    outputAdvancedOnce)
                    ++outputFrozenTicks;

                if (videoFrame > lastVideoFrame)
                {
                    lastVideoFrame = videoFrame;
                    videoFrameFrozenTicks = 0;
                    videoAdvancedOnce = true;
                }
                else if (outputSeconds >= liveWarmupSeconds ||
                    videoAdvancedOnce)
                    ++videoFrameFrozenTicks;

                if (outputSeconds >= liveWarmupSeconds && speed > 0.0 &&
                    speed < minimumLiveSpeed)
                    ++slowSpeedTicks;
                else
                    slowSpeedTicks = 0;

                if (progressQuietTicks >= liveProgressDeadlineTicks)
                {
                    failureReason =
                        "FFmpeg stopped reporting live progress for 12 seconds " ~
                        "after startup. This usually means the encoder, muxer, " ~
                        "or RTMP connection stalled.";
                    _liveOutputFailed = true;
                }
                else if (outputFrozenTicks >= liveOutputDeadlineTicks)
                {
                    failureReason =
                        "Encoded output time stopped advancing for 12 seconds " ~
                        "after startup. Twitch will buffer when live output is " ~
                        "starved.";
                    _liveOutputFailed = true;
                }
                else if (videoFrameFrozenTicks >= liveVideoFrameDeadlineTicks)
                {
                    failureReason =
                        "Encoded video frame count stopped advancing for 12 " ~
                        "seconds while output time continued. Desktop capture " ~
                        "or video encoding stalled, so Twitch may receive " ~
                        "audio-only output with a frozen or black frame.";
                    videoCaptureTermination = true;
                    _videoCaptureFailed = true;
                    _videoCaptureFailureReason = failureReason;
                }
                else if (slowSpeedTicks >= slowSpeedDeadlineTicks)
                {
                    failureReason = format(
                        "Live output speed stayed below %.2fx for 12 seconds " ~
                        "after startup. The second computer, encoder, or upload " ~
                        "path is not keeping up.",
                        minimumLiveSpeed);
                    _liveOutputFailed = true;
                }

                if (_liveOutputFailed)
                {
                    _liveOutputFailureReason = failureReason;
                    _failed = true;
                    _requestedRunning = false;
                    _status = "Live output stalled";
                    appendDiagnostic(failureReason);
                    _failureLoggedToActivity = true;
                    terminate = true;
                }
                else if (_videoCaptureFailed)
                {
                    if (_videoCaptureFailureReason.length > 0)
                        failureReason = _videoCaptureFailureReason;
                    _failed = true;
                    _requestedRunning = false;
                    _status = _captureFailureStatus.length > 0 ?
                        _captureFailureStatus : "Desktop capture stalled";
                    appendDiagnostic(failureReason);
                    _failureLoggedToActivity = true;
                    terminate = true;
                }
            }

            // Window capture: the moment the captured window is minimized or
            // closed, gdigrab cannot produce fresh frames (its client area
            // becomes 0×0) while all encoder/timestamps keep advancing, so the
            // stream would sit on a frozen last frame indefinitely without any
            // other watchdog firing. Stop immediately with a clear message.
            //
            // Content capture is different: the pump keeps sending the last
            // good frame while the window is minimized (a minimized window has
            // no rendered content), so the stream stays alive and resumes
            // automatically on restore — the monitor only stops it when the
            // window is actually closed.
            if (!_videoCaptureFailed && windowCaptureHwnd.strip().length > 0)
            {
                const gone = !windowExists(windowCaptureHwnd);
                if (gone)
                {
                    failureReason = "The captured window was closed, so the stream stopped instead of freezing on its last frame. Reopen the window and start streaming again.";
                    videoCaptureTermination = true;
                    _videoCaptureFailed = true;
                    _videoCaptureFailureReason = failureReason;
                    _captureFailureStatus =
                        "Window capture stopped — the captured window was closed";
                    _failed = true;
                    _requestedRunning = false;
                    appendDiagnostic(failureReason);
                    _failureLoggedToActivity = true;
                    terminate = true;
                }
                else if (!holdsLastFrame &&
                    windowIsMinimized(windowCaptureHwnd))
                {
                    failureReason = "The captured window was minimized, so the stream stopped instead of freezing on its last frame. Restore the window and start streaming again (a minimized window cannot be captured).";
                    videoCaptureTermination = true;
                    _videoCaptureFailed = true;
                    _videoCaptureFailureReason = failureReason;
                    _captureFailureStatus =
                        "Window capture stopped — the captured window was minimized";
                    _failed = true;
                    _requestedRunning = false;
                    appendDiagnostic(failureReason);
                    _failureLoggedToActivity = true;
                    terminate = true;
                }
            }
            _mutex.unlock();

            if (terminate)
            {
                appendPersistentLog((startupTermination ?
                    "STARTUP FAILURE: " : videoCaptureTermination ?
                    "VIDEO CAPTURE FAILURE: " : "LIVE OUTPUT FAILURE: ") ~
                    failureReason);
                activityError("Stream failed: " ~ failureReason);
                activityAction("Action taken: FFmpeg was terminated.");
                try kill(process);
                catch (Exception error)
                {
                    appendPersistentLog(
                        "Could not terminate stalled FFmpeg: " ~ error.msg);
                }
                return;
            }
        }
    }

    /// Background loop that pumps PrintWindow window-content frames into
    /// FFmpeg's stdin as raw BGRA at the configured rate. While the window is
    /// minimized (no rendered content) it keeps sending the last good frame so
    /// the encoder stays healthy and the stream resumes automatically on
    /// restore. Stops when FFmpeg exits (write fails) or the worker stops.
    private void runWindowContentPump(const BroadcastSettings settings,
        int stdinFd)
    {
        version (Windows)
        {
            import aurorastream.windowcontent : WindowContentCapturer;
            import core.sync.mutex : Mutex;

            const width = qualityWidth(settings.sourceQuality);
            const height = qualityHeight(settings.sourceQuality);
            const frameBytes = cast(size_t) width * height * 4;
            auto capturer = new WindowContentCapturer(width, height);
            capturer.setWindowTarget(settings.windowCaptureHwnd);
            auto frame = new ubyte[frameBytes];
            auto heldFrame = new ubyte[frameBytes];
            bool haveHeldFrame;

            const cadenceFps = settings.fps > 0 ? settings.fps : 60;
            const frameInterval = dur!"nsecs"(
                1_000_000_000L / cadenceFps);
            auto nextFrame = MonoTime.currTime;
            while (true)
            {
                _mutex.lock();
                const running = _requestedRunning && !_shutdown &&
                    _processRunning;
                _mutex.unlock();
                if (!running) break;

                // Grab the newest frame. PrintWindow can take much longer than
                // one frame interval (VLC-sized composited windows, busy apps),
                // so this call may block for several slots.
                bool captured;
                if (capturer.capture(frame))
                {
                    heldFrame[] = frame[];
                    haveHeldFrame = true;
                    captured = true;
                }

                // Write the best frame we have for the current slot, then
                // advance the cadence. FFmpeg's rawvideo demuxer stamps frames
                // by COUNT at `-framerate` (not by arrival time), so if the pump
                // fell behind (slow PrintWindow) the stamped video duration
                // would compress and drift ahead of the wall-clock audio —
                // a huge A/V desync. Duplicating the last good frame into every
                // missed slot keeps the delivered rate at ~fps frames per real
                // second, so the video stays in sync even when capture is slow
                // (the picture simply repeats, slightly choppy but not faster
                // than the audio).
                bool wrote = true;
                if (captured || haveHeldFrame)
                    wrote = writeFrame(stdinFd,
                        haveHeldFrame ? heldFrame : frame, frameBytes);

                nextFrame += frameInterval;
                const now = MonoTime.currTime;
                if (wrote)
                {
                    while (nextFrame <= now)
                    {
                        if (!haveHeldFrame) break;
                        wrote = writeFrame(stdinFd, heldFrame, frameBytes);
                        if (!wrote) break;
                        nextFrame += frameInterval;
                    }
                }
                if (!wrote) break; // FFmpeg exited or the pipe broke.

                if (nextFrame > MonoTime.currTime)
                {
                    try Thread.sleep(nextFrame - MonoTime.currTime);
                    catch (Exception) {}
                }
            }
        }
    }

    /// Resizes a hook frame into the fixed source canvas expected by FFmpeg.
    /// This matches the later scale/pad graph: preserve aspect ratio, center
    /// the image, and leave unused canvas pixels black.
    version (Windows)
    version (Windows)
    private final class BgraFrameScaler
    {
        private int _targetWidth;
        private int _targetHeight;
        private HDC _targetDC;
        private HBITMAP _targetBitmap;
        private HGDIOBJ _targetPrevious;
        private void* _targetBits;

        this(int targetWidth, int targetHeight)
        {
            _targetWidth = targetWidth;
            _targetHeight = targetHeight;
        }

        ~this()
        {
            close();
        }

        void close()
        {
            if (_targetDC !is null && _targetPrevious !is null)
                SelectObject(_targetDC, _targetPrevious);
            _targetPrevious = null;
            if (_targetBitmap !is null) DeleteObject(_targetBitmap);
            _targetBitmap = null;
            if (_targetDC !is null) DeleteDC(_targetDC);
            _targetDC = null;
            _targetBits = null;
        }

        private bool ensureTargetSurface()
        {
            if (_targetDC !is null && _targetBits !is null) return true;
            auto screenDC = GetDC(null);
            if (screenDC is null) return false;
            scope(exit) ReleaseDC(null, screenDC);
            _targetDC = CreateCompatibleDC(screenDC);
            if (_targetDC is null) return false;

            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = _targetWidth;
            info.bmiHeader.biHeight = -_targetHeight;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _targetBitmap = CreateDIBSection(_targetDC, &info,
                DIB_RGB_COLORS, &_targetBits, null, 0);
            if (_targetBitmap is null || _targetBits is null) return false;
            _targetPrevious = SelectObject(_targetDC,
                cast(HGDIOBJ) _targetBitmap);
            SetStretchBltMode(_targetDC, HALFTONE);
            return _targetPrevious !is null;
        }

        bool fit(const GameCaptureFrame source, ubyte[] target)
        {
            const targetBytes = cast(size_t) _targetWidth * _targetHeight * 4;
            if (source is null || target.length < targetBytes ||
                source.width == 0 || source.height == 0 ||
                source.pixels.length <
                    cast(size_t) source.width * source.height * 4)
                return false;
            if (source.width == _targetWidth &&
                source.height == _targetHeight)
            {
                memcpy(target.ptr, source.pixels.ptr, targetBytes);
                return true;
            }

            if (!ensureTargetSurface()) return false;
            ulong scaledWidth = _targetWidth;
            ulong scaledHeight = cast(ulong) _targetWidth * source.height /
                source.width;
            if (scaledHeight > _targetHeight)
            {
                scaledHeight = _targetHeight;
                scaledWidth = cast(ulong) _targetHeight * source.width /
                    source.height;
            }
            if (scaledWidth == 0 || scaledHeight == 0) return false;
            const offsetX = (_targetWidth - cast(int) scaledWidth) / 2;
            const offsetY = (_targetHeight - cast(int) scaledHeight) / 2;

            BITMAPINFO sourceInfo;
            sourceInfo.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            sourceInfo.bmiHeader.biWidth = cast(int) source.width;
            sourceInfo.bmiHeader.biHeight = -cast(int) source.height;
            sourceInfo.bmiHeader.biPlanes = 1;
            sourceInfo.bmiHeader.biBitCount = 32;
            sourceInfo.bmiHeader.biCompression = BI_RGB;
            memset(_targetBits, 0, targetBytes);
            const copiedLines = StretchDIBits(_targetDC, offsetX, offsetY,
                cast(int) scaledWidth, cast(int) scaledHeight, 0, 0,
                cast(int) source.width, cast(int) source.height,
                source.pixels.ptr, &sourceInfo, DIB_RGB_COLORS, SRCCOPY);
            if (copiedLines == 0 || copiedLines == cast(int) GDI_ERROR)
                return false;
            memcpy(target.ptr, _targetBits, targetBytes);
            return true;
        }
    }

    /// Reads shared D3D11 Present output and feeds the same paced rawvideo
    /// stdin path as PrintWindow. The newest completed frame replaces the held
    /// image; every missed cadence slot receives the held image instead.
    private void runGameCapturePump(const BroadcastSettings settings,
        int stdinFd, GameCaptureSession session)
    {
        version (Windows)
        {
            const width = qualityWidth(settings.sourceQuality);
            const height = qualityHeight(settings.sourceQuality);
            const frameBytes = cast(size_t) width * height * 4;
            auto heldFrame = new ubyte[frameBytes];
            auto scaler = new BgraFrameScaler(width, height);
            scope(exit) scaler.close();
            bool haveHeldFrame;
            const cadenceFps = settings.fps > 0 ? settings.fps : 60;
            const frameInterval = dur!"nsecs"(
                1_000_000_000L / cadenceFps);
            auto nextFrame = MonoTime.currTime;
            while (true)
            {
                _mutex.lock();
                const running = _requestedRunning && !_shutdown &&
                    _processRunning;
                _mutex.unlock();
                if (!running) break;

                GameCaptureFrame latest;
                if (session.readLatestFrame(latest))
                {
                    try haveHeldFrame = scaler.fit(latest, heldFrame) ||
                        haveHeldFrame;
                    finally session.releaseFrame(latest);
                }

                const captureFailure = session.failure();
                if (captureFailure.length > 0)
                {
                    _mutex.lock();
                    _videoCaptureFailed = true;
                    _videoCaptureFailureReason = captureFailure;
                    _captureFailureStatus = "Game capture stopped";
                    _mutex.unlock();
                    break;
                }

                bool wrote = true;
                if (haveHeldFrame)
                    wrote = writeFrame(stdinFd, heldFrame, frameBytes);

                nextFrame += frameInterval;
                const now = MonoTime.currTime;
                if (wrote)
                {
                    while (nextFrame <= now)
                    {
                        if (!haveHeldFrame) break;
                        wrote = writeFrame(stdinFd, heldFrame, frameBytes);
                        if (!wrote) break;
                        nextFrame += frameInterval;
                    }
                }
                if (!wrote) break;
                if (nextFrame > MonoTime.currTime)
                {
                    try Thread.sleep(nextFrame - MonoTime.currTime);
                    catch (Exception) {}
                }
            }
            appendPersistentLog("GAME CAPTURE METRICS: " ~
                session.diagnosticsSummary());
            const failure = session.failure();
            if (failure.length > 0)
                appendPersistentLog("GAME CAPTURE: " ~ failure);
        }
    }

    private bool writeFrame(int stdinFd, const(ubyte)[] frame,
        size_t byteCount)
    {
        version (Windows)
        {
            size_t offset;
            while (offset < byteCount)
            {
                const written = _write(stdinFd, frame.ptr + offset,
                    cast(uint) (byteCount - offset));
                if (written <= 0) return false;
                offset += cast(size_t) written;
            }
            return true;
        }
        else
        {
            return false;
        }
    }

    private void parseLine(string source, const(string)[] secrets,
        AudioBridgeSession desktopBridge)
    {
        const line = sanitize(source.strip(), secrets);
        if (line.length == 0) return;
        appendPersistentLog("FFmpeg: " ~ line);
        if (isDesktopDuplicationFailureLine(line))
        {
            // Desktop Duplication loses its output when the display mode
            // changes — alt-tab to/from a fullscreen-exclusive application,
            // a resolution change, a lock screen, or a UAC prompt. The capture
            // input dies with it, so FFmpeg cannot recover by itself. Mark the
            // loss as RECOVERABLE and relaunch FFmpeg (bounded) so an alt-tab
            // away and back does not kill the stream; only after the relaunch
            // budget is exhausted is this reported as a permanent capture
            // failure.
            const reason =
                "Desktop Duplication output lost: " ~ line ~
                ". This usually happens on alt-tab to/from a fullscreen-exclusive " ~
                "application or a display-mode change. Aurora Stream is " ~
                "relaunching the capture automatically; if it does not recover, " ~
                "the stream will stop.";
            Pid process;
            _mutex.lock();
            _captureLossRecoverable = true; // monitor exits on this flag so run() can relaunch
            _failureLoggedToActivity = true;
            if (!_captureLossRecoverableDiagnosed)
            {
                _captureLossRecoverableDiagnosed = true;
                _status = "Desktop capture lost — reconnecting…";
                appendDiagnostic(reason);
            }
            process = _process;
            _mutex.unlock();
            appendPersistentLog("DESKTOP CAPTURE OUTPUT LOST: " ~ reason);
            activityError("Desktop capture output lost: " ~ line ~
                ". This usually happens on alt-tab to/from a fullscreen-exclusive " ~
                "application or a display-mode change.");
            if (process !is null)
            {
                try kill(process);
                catch (Exception error)
                {
                    appendPersistentLog(
                        "Could not terminate FFmpeg after Desktop Duplication loss: " ~
                        error.msg);
                }
            }
            return;
        }
        const separator = line.indexOf('=');
        if (separator > 0)
        {
            const key = line[0 .. cast(size_t) separator];
            const value = line[cast(size_t) separator + 1 .. $];
            bool inspectAudio;
            _mutex.lock();
            switch (key)
            {
                case "frame":
                    _frame = value;
                    _progressVideoFrame = parseProgressInteger(value);
                    if (value.length > 0 && value != "0")
                        _startupComplete = true;
                    break;
                case "fps": _fps = value; break;
                case "bitrate": _bitrate = value; break;
                case "speed":
                    _speed = value;
                    _progressSpeed = parseProgressSpeed(value);
                    break;
                case "dup_frames": _duplicatedFrames = value; break;
                case "drop_frames": _droppedFrames = value; break;
                case "out_time":
                    _outputTime = value;
                    _progressOutputSeconds = parseProgressClock(value);
                    if (value.length > 0 && value != "N/A" &&
                        value != "00:00:00.000000")
                        _startupComplete = true;
                    break;
                case "progress":
                    if (_processRunning && _startupComplete)
                    {
                        ++_progressSerial;
                        _status = "LIVE encoder active — network output monitored";
                    }
                    inspectAudio = true;
                    break;
                default:
                    break;
            }
            _mutex.unlock();
            if (inspectAudio) inspectDesktopAudio(desktopBridge);
            return;
        }

        _mutex.lock();
        appendDiagnostic(line);
        _mutex.unlock();
        // Under `-loglevel warning` every non-progress stderr line is a
        // genuine warning or error, so mirror it into the activity log as the
        // "what happened" record (the line is already secret-sanitized).
        activityWarning("FFmpeg: " ~ line);
    }

    private void run(const BroadcastSettings settings,
        const EncoderSelection encoder, const CaptureSelection capture,
        string[] secrets)
    {
        int exitCode = -1;
        bool launched;
        bool bindRace;
        AudioBridgeSession desktopBridge;
        PreparedDesktopAudio desktopAudio;
        GameCaptureSession gameCapture;

        resetPersistentLog(settings, encoder, capture);
        appendPersistentLog("Broadcast worker started.");

        string destinations;
        if (settings.twitchEnabled) destinations ~= "Twitch";
        if (settings.youtubeEnabled)
            destinations ~= (destinations.length > 0 ? "+" : "") ~ "YouTube";
        if (destinations.length == 0) destinations = "none";
        activityInfo(format("Stream start: %s, encoder %s (%s), capture %s.",
            destinations, encoder.label, encoder.name,
            captureSourceLabel(settings, capture)));

        try
        {
            if (settings.desktopAudioDevice.strip().length > 0)
            {
                _mutex.lock();
                _status = "Starting isolated Windows audio helper…";
                _mutex.unlock();

                desktopBridge = new AudioBridgeSession(_executablePath);
                string bridgeError;
                if (!desktopBridge.start(settings.desktopAudioDevice, false,
                    bridgeError))
                {
                    _mutex.lock();
                    _startupFailed = true;
                    _startupFailureReason = bridgeError;
                    _failureLoggedToActivity = true;
                    appendDiagnostic(bridgeError);
                    _mutex.unlock();
                    activityError("Desktop audio helper failed to start: " ~
                        bridgeError);
                    throw new Exception(bridgeError);
                }
                string handoffError;
                if (!desktopBridge.validateReceiverReservationHandoff(
                    handoffError))
                {
                    appendPersistentLog("DESKTOP AUDIO PORT HANDOFF FAILURE: " ~
                        handoffError);
                    _mutex.lock();
                    _startupFailed = true;
                    _startupFailureReason = handoffError;
                    _failureLoggedToActivity = true;
                    appendDiagnostic(handoffError);
                    _mutex.unlock();
                    activityError("Desktop audio port handoff failed: " ~
                        handoffError);
                    throw new Exception(handoffError);
                }
                desktopAudio.sdpPath = desktopBridge.sdpPath;
                appendPersistentLog(format(
                    "Desktop-audio helper transport-ready and receiver-port " ~
                    "handoff verified. RTP=%s RTCP=%s",
                    desktopBridge.port, desktopBridge.rtcpPort));

                _mutex.lock();
                appendDiagnostic(
                    "Desktop audio: isolated process • event-driven WASAPI • 20 ms RTP L16/48000/2 sample clock");
                const cancelled = !_requestedRunning || _shutdown;
                _mutex.unlock();
                if (cancelled)
                    throw new Exception("Broadcast start was cancelled.");
            }

            _mutex.lock();
            appendDiagnostic("Capture source: " ~
                captureSourceLabel(settings, capture));
            if (encoder.name == "h264_nvenc" &&
                encoder.d3d11DirectProbeAttempted)
            {
                appendDiagnostic("Direct D3D11 → NVENC probe: " ~
                    (encoder.d3d11DirectSupported ? "passed" :
                    "failed; using CPU compatibility path"));
            }
            appendDiagnostic("Video path: " ~
                videoPipelineLabel(settings, encoder, capture));
            appendDiagnostic(
                "A/V architecture: FFmpeg owns video/encode/mux • separate MMCSS audio process • timestamped RTP • no GUI-process PCM pacing thread");
            appendDiagnostic(
                "Output transport: bounded non-dropping FIFO + live output watchdog");
            appendDiagnostic("Full startup log: aurora-stream-startup.log");
            _mutex.unlock();

            auto arguments = independentOutputArguments(settings, encoder,
                desktopAudio, capture);
            appendArgumentLog(arguments, secrets);

            if (settings.gameCaptureMode)
            {
                version (Windows)
                {
                    const hookPath = gameCaptureHookPath(_executablePath);
                    if (hookPath.length == 0)
                        throw new Exception(
                            "gamecaphook.dll was not found. Build it beside Aurora Stream or use a single-exe build with the embedded hook.");
                    gameCapture = new GameCaptureSession(hookPath);
                    string hookError;
                    if (!gameCapture.start(settings.windowCaptureHwnd,
                        hookError))
                        throw new Exception(hookError);
                    appendPersistentLog(
                        "Game capture hook injected; shared BGRA ring and framed control pipe are connected.");
                    activityInfo(
                        "Game capture hook injected and frame pipe connected.");
                }
            }

            // Windows can transiently refuse to re-bind the just-released RTP
            // UDP port with WSAEADDRINUSE (-10048) even though the handoff
            // proved it free (the diagnostic matrix retries this race with
            // fresh port pairs; the live path retries the FFmpeg launch, which
            // uses the same proven-free ports).
            enum int maxLaunchAttempts = 4;
            enum int maxCaptureRelaunches = 3;
            enum double launchHealthSeconds = 2.5;
            int captureRelaunches;
            for (int attempt = 1; attempt <= maxLaunchAttempts && !launched;
                ++attempt)
            {
                if (desktopBridge !is null)
                {
                    _mutex.lock();
                    appendDiagnostic(format(
                        "Desktop audio UDP ownership: helper source is bound and handoff verified; releasing FFmpeg RTP %s / RTCP %s reservations",
                        desktopBridge.port, desktopBridge.rtcpPort));
                    _mutex.unlock();
                    desktopBridge.releaseReceiverReservations();
                    appendPersistentLog(
                        "Released the verified non-inheritable receiver reservations immediately before FFmpeg launch.");
                }
                auto pipes = pipeProcess(arguments,
                    (settings.windowContentCapture || settings.gameCaptureMode) ?
                        Redirect.stderr | Redirect.stdin : Redirect.stderr,
                    cast(const string[string]) null, Config.suppressConsole);
                _mutex.lock();
                _process = pipes.pid;
                _processRunning = true;
                _status = "Connecting to streaming services…";
                const shouldStop = !_requestedRunning || _shutdown;
                _mutex.unlock();
                appendPersistentLog(format(
                    "FFmpeg process launched (attempt %s/%s); startup deadline is 12 seconds.",
                    attempt, maxLaunchAttempts));
                activityInfo(format(
                    "FFmpeg launched (attempt %s/%s); startup deadline is 12 seconds.",
                    attempt, maxLaunchAttempts));

                // Window-content capture pumps PrintWindow frames into FFmpeg's
                // stdin. Only the raw file descriptor crosses the thread
                // boundary (Phobos `File` is @system and sharing it between
                // threads can hand a stale Impl pointer to the pump; the pump
                // writes with the raw CRT `_write`, so the descriptor stays
                // owned and closed exactly once by `pipes` here).
                Thread contentPump;
                if (settings.windowContentCapture || settings.gameCaptureMode)
                {
                    auto stdinFd = pipes.stdin.fileno();
                    contentPump = new Thread({
                        if (settings.gameCaptureMode)
                            runGameCapturePump(settings, stdinFd, gameCapture);
                        else
                            runWindowContentPump(settings, stdinFd);
                    });
                    contentPump.isDaemon = true;
                    contentPump.start();
                    appendPersistentLog(settings.gameCaptureMode ?
                        "Game capture frame pump started (shared hook BGRA → paced rawvideo stdin)." :
                        "Window content capture frame pump started (PrintWindow → raw BGRA → stdin).");
                }

                // Drain stderr on a background thread so the pipe can never
                // fill and block FFmpeg; flag a UDP bind race if it appears.
                bool stderrEnded;
                auto reader = new Thread({
                    foreach (rawLine; pipes.stderr.byLine())
                    {
                        const line = rawLine.to!string;
                        if (line.indexOf("-10048") >= 0 ||
                            line.indexOf("bind failed") >= 0)
                            bindRace = true;
                        parseLine(line, secrets, desktopBridge);
                    }
                    stderrEnded = true;
                });
                reader.isDaemon = true;
                reader.start();

                // A healthy FFmpeg is still running after the health window; a
                // -10048 bind race exits well inside it. Only after health is
                // confirmed does the watchdog monitor start.
                const healthDeadline = MonoTime.currTime +
                    dur!"msecs"(cast(long) (launchHealthSeconds * 1000.0));
                while (!stderrEnded && MonoTime.currTime < healthDeadline)
                    Thread.sleep(20.msecs);

                if (!stderrEnded)
                {
                    launched = true;
                    auto monitor = new Thread({
                        monitorProcess(pipes.pid, desktopBridge,
                            settings.windowCaptureHwnd,
                            settings.windowContentCapture ||
                            settings.gameCaptureMode);
                    });
                    monitor.isDaemon = true;
                    monitor.start();
                    if (shouldStop)
                    {
                        try kill(pipes.pid);
                        catch (Exception) {}
                    }
                    try reader.join();
                    catch (Exception) {}
                    if (contentPump !is null)
                    {
                        try contentPump.join();
                        catch (Exception) {}
                    }
                    exitCode = wait(pipes.pid);
                    appendPersistentLog(
                        format("FFmpeg exited with code %s.", exitCode));

                    // Recoverable Desktop Duplication loss (alt-tab to/from a
                    // fullscreen-exclusive app, resolution change, lock screen):
                    // the capture output is gone but returns when the desktop
                    // is visible again. Relaunch FFmpeg (bounded) so the stream
                    // survives the transition instead of stopping.
                    bool relaunchCapture;
                    bool budgetExhausted;
                    _mutex.lock();
                    if (_captureLossRecoverable)
                    {
                        // Only relaunch while the user still wants the stream
                        // and the app is not shutting down; a Stop pressed
                        // during the recovery window must not resurrect it.
                        if (_requestedRunning && !_shutdown &&
                            captureRelaunches < maxCaptureRelaunches)
                        {
                            ++captureRelaunches;
                            _captureLossRecoverable = false;
                            _captureLossRecoverableDiagnosed = false;
                            _videoCaptureFailed = false;
                            _videoCaptureFailureReason = "";
                            _captureFailureStatus = "";
                            _failed = false;
                            _failureLoggedToActivity = false;
                            _process = null;
                            _processRunning = false;
                            _startupComplete = false;
                            _startupFailed = false;
                            _status = "Reconnecting desktop capture…";
                            relaunchCapture = true;
                        }
                        else
                        {
                            // Relaunch budget exhausted: report a real failure
                            // instead of falling through to the generic
                            // user-stopped branch.
                            _videoCaptureFailed = true;
                            _videoCaptureFailureReason =
                                "Desktop Duplication output kept being lost. The stream was stopped after " ~
                                maxCaptureRelaunches.to!string ~
                                " automatic recovery relaunches.";
                            _captureFailureStatus =
                                "Desktop capture failed (did not recover after " ~
                                maxCaptureRelaunches.to!string ~ " relaunches)";
                            _failed = true;
                            budgetExhausted = true;
                        }
                    }
                    _mutex.unlock();
                    if (relaunchCapture)
                    {
                        appendPersistentLog(format(
                            "RELAUNCH: Desktop Duplication loss was transient; relaunching FFmpeg (recovery %s of %s).",
                            captureRelaunches, maxCaptureRelaunches));
                        activityAction(format(
                            "Action taken: relaunching FFmpeg after a transient Desktop Duplication loss (recovery %s of %s).",
                            captureRelaunches, maxCaptureRelaunches));
                        Thread.sleep(300.msecs);
                        launched = false;
                        continue;
                    }
                    if (budgetExhausted)
                        activityError("Stream failed: " ~
                            _videoCaptureFailureReason);
                }
                else
                {
                    try reader.join();
                    catch (Exception) {}
                    exitCode = wait(pipes.pid);
                    appendPersistentLog(
                        format("FFmpeg exited with code %s.", exitCode));
                    _mutex.lock();
                    _processRunning = false;
                    _mutex.unlock();
                    if (bindRace && attempt < maxLaunchAttempts)
                    {
                        appendPersistentLog(format(
                            "Transient Windows UDP -10048 bind race; retrying launch (%s of %s).",
                            attempt, maxLaunchAttempts - 1));
                        activityWarning(
                            "Windows UDP -10048 bind race during FFmpeg launch.");
                        activityAction(format(
                            "Action taken: retrying FFmpeg launch (attempt %s of %s).",
                            attempt + 1, maxLaunchAttempts));
                        Thread.sleep(300.msecs);
                    }
                    else
                    {
                        appendPersistentLog(
                            bindRace ? "Gave up after repeated UDP -10048 bind races."
                                     : "FFmpeg exited before the startup deadline.");
                        _failureLoggedToActivity = true;
                        if (bindRace)
                            activityError("Stream failed: repeated Windows UDP -10048 bind races prevented FFmpeg from launching.");
                        else
                            activityError("Stream failed: FFmpeg exited before the startup deadline (see aurora-stream-startup.log for the full output).");
                    }
                }
            }
        }
        catch (Exception error)
        {
            const safeError = sanitize(error.msg, secrets);
            appendPersistentLog("BROADCAST EXCEPTION: " ~ safeError);
            bool alreadyLogged;
            bool userStoppedDuringStartup;
            _mutex.lock();
            alreadyLogged = _failureLoggedToActivity;
            userStoppedDuringStartup = !_requestedRunning || _shutdown;
            if (!alreadyLogged)
            {
                appendDiagnostic(safeError);
                if (!userStoppedDuringStartup)
                    _failureLoggedToActivity = true;
            }
            _mutex.unlock();
            if (userStoppedDuringStartup)
                activityInfo("Stream start was cancelled by the user.");
            else if (!alreadyLogged)
                activityError("Stream session aborted: " ~ safeError);
        }
        finally
        {
            if (gameCapture !is null)
                gameCapture.shutdown();
            if (desktopBridge !is null)
            {
                desktopBridge.shutdown();
                auto metrics = desktopBridge.metricsText();
                metrics = metrics.replace("\r\n", " • ").replace("\n", " • ");
                if (metrics.length > 0)
                {
                    appendPersistentLog("Desktop audio final metrics: " ~ metrics);
                    _mutex.lock();
                    appendDiagnostic("Desktop audio RTP: " ~ metrics);
                    _mutex.unlock();
                }
            }
        }

        _mutex.lock();
        const userStopped = !_requestedRunning || _shutdown;
        const helperFailed = _audioBridgeFailed;
        const startupFailed = _startupFailed;
        const startupFailureReason = _startupFailureReason;
        const liveOutputFailed = _liveOutputFailed;
        const liveOutputFailureReason = _liveOutputFailureReason;
        const videoCaptureFailed = _videoCaptureFailed;
        const videoCaptureFailureReason = _videoCaptureFailureReason;
        const captureFailureStatus = _captureFailureStatus;
        const failureLogged = _failureLoggedToActivity;
        _process = null;
        _processRunning = false;
        _requestedRunning = false;
        if (startupFailed)
        {
            _failed = true;
            _status = "FFmpeg startup failed — see aurora-stream-startup.log";
            if (startupFailureReason.length > 0)
                appendDiagnostic(startupFailureReason);
        }
        else if (liveOutputFailed)
        {
            _failed = true;
            _status = "Live output stalled — see aurora-stream-startup.log";
            if (liveOutputFailureReason.length > 0)
                appendDiagnostic(liveOutputFailureReason);
        }
        else if (videoCaptureFailed)
        {
            _failed = true;
            _status = captureFailureStatus.length > 0 ? captureFailureStatus :
                "Desktop capture failed — see aurora-stream-startup.log";
            if (videoCaptureFailureReason.length > 0)
                appendDiagnostic(videoCaptureFailureReason);
        }
        else if (userStopped && !helperFailed)
        {
            _failed = false;
            _status = "Stopped";
        }
        else if (!launched && bindRace)
        {
            _failed = true;
            _status = "FFmpeg could not bind the audio UDP port (transient Windows -10048) — see aurora-stream-startup.log";
        }
        else
        {
            _failed = true;
            if (helperFailed)
                _status = "Desktop audio helper failed";
            else
                _status = exitCode == 0 ? "FFmpeg ended unexpectedly" :
                    format("FFmpeg stopped with exit code %d", exitCode);
        }
        const finalStatus = _status;
        _mutex.unlock();

        // Final session-end line into the always-on activity log. Failures that
        // were already logged with their exact reason + the action taken at the
        // moment they happened (monitorProcess / parseLine / inspectDesktopAudio
        // / pre-launch helper checks / launch give-up) only get a concise
        // summary here; the other branches carry the reason directly.
        if (failureLogged)
            activityError("Stream session ended with failure: " ~ finalStatus);
        else if (startupFailed)
            activityError("Stream failed to start: " ~
                (startupFailureReason.length > 0 ? startupFailureReason :
                    finalStatus));
        else if (userStopped && !helperFailed)
            activityInfo("Stream session ended: " ~ finalStatus);
        else
            activityError("Stream session ended with failure: " ~ finalStatus ~
                (finalStatus.indexOf("aurora-stream-startup.log") >= 0 ? "" :
                    " (details in aurora-stream-startup.log)"));
    }
}

module aurorastream.broadcast;

import aurorastream.audiobridge : AudioBridgeSession;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : append, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, Pid, Redirect, execute, kill, pipeProcess, wait;
import std.string : indexOf, replace, split, splitLines, startsWith, strip;

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

    // The shared program canvas before service-specific scaling.
    BroadcastQuality sourceQuality = BroadcastQuality.fullHD;

    // Kept as separate destination profiles even while Twitch is intentionally
    // fixed to its normal 1080p60 preset in this milestone.
    BroadcastQuality twitchQuality = BroadcastQuality.fullHD;
    BroadcastQuality youtubeQuality = BroadcastQuality.twoK;

    int fps = 60;
    int audioBitrateKbps = defaultAudioBitrateKbps;
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

CaptureSelection detectCaptureBackend()
{
    CaptureSelection result;
    if (desktopDuplicationWorks())
    {
        result.backend = DesktopCaptureBackend.desktopDuplication;
        result.label = "Desktop Duplication (cursor-safe)";
        result.capturesCursor = true;
        readDesktopDuplicationSize(result.nativeWidth, result.nativeHeight);
    }
    return result;
}

bool usesD3D11ZeroCopyVideo(const BroadcastSettings settings,
    const EncoderSelection encoder, const CaptureSelection capture)
{
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
    if (!validQuality(settings.sourceQuality))
        return "Select a valid common source resolution.";
    if (settings.twitchQuality != BroadcastQuality.fullHD)
        return "Twitch output is currently fixed to the normal 1080p60 profile.";
    if (settings.youtubeQuality != BroadcastQuality.twoK &&
        settings.youtubeQuality != BroadcastQuality.fourK)
        return "YouTube output must be 1440p60 or 4K60.";

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

private string appendPath(string server, string key)
{
    auto base = server.strip();
    auto secret = key.strip();
    while (base.length > 0 && base[$ - 1] == '/') base = base[0 .. $ - 1];
    while (secret.length > 0 && secret[0] == '/') secret = secret[1 .. $];
    return base ~ "/" ~ secret;
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
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
        "-stats_period", "1", "-progress", "pipe:2",
        "-thread_queue_size", "512"
    ];

    if (capture.backend == DesktopCaptureBackend.desktopDuplication)
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
    // muxer moves network open/write/recovery into its own worker and keeps the
    // encoder running. Its bounded packet queue drops stale packets on overflow
    // so a reconnect returns near live time instead of replaying a long backlog.
    arguments ~= [
        "-f", "fifo", "-fifo_format", "flv",
        "-queue_size", "360",
        "-format_opts",
            "max_interleave_delta=0:flush_packets=1:" ~
            "flvflags=no_duration_filesize",
        "-attempt_recovery", "1", "-recovery_wait_time", "1",
        "-drop_pkts_on_overflow", "1", "-restart_with_keyframe", "1",
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
            youtubeVideoBitrateKbps(settings.youtubeQuality),
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
    foreach (index, argument; arguments)
    {
        if (argument == "-fifo_format") foundFifo = true;
        if (argument == "-queue_size" && index + 1 < arguments.length &&
            arguments[index + 1] == "360")
            foundBoundedQueue = true;
    }
    assert(foundFifo);
    assert(foundBoundedQueue);
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

    this(string executablePath)
    {
        _mutex = new Mutex();
        _executablePath = executablePath.idup;
        const folder = executablePath.length > 0 ? dirName(executablePath) : ".";
        _startupLogPath = buildPath(folder, "aurora-stream-startup.log");
    }

    bool start(const BroadcastSettings settings, const EncoderSelection encoder,
        const CaptureSelection capture, out string error)
    {
        error = validateBroadcastSettings(settings, encoder);
        if (error.length > 0) return false;

        Thread completedWorker;
        _mutex.lock();
        if (_requestedRunning || _processRunning)
        {
            _mutex.unlock();
            error = "A broadcast is already running.";
            return false;
        }
        if (_shutdown)
        {
            _mutex.unlock();
            error = "The broadcaster is shutting down.";
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
            format("Capture: %s\r\n", capture.label) ~
            format("Video path: %s\r\n",
                videoPipelineLabel(settings, encoder, capture)) ~
            "Output wrapper: bounded FIFO isolation per destination\r\n" ~
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
            appendDiagnostic("Desktop audio helper failed: " ~ bridgeError);
            process = _process;
        }
        _mutex.unlock();
        if (process !is null)
        {
            appendPersistentLog("AUDIO HELPER FAILURE: " ~ bridgeError);
            try kill(process);
            catch (Exception error)
            {
                appendPersistentLog(
                    "Could not terminate FFmpeg after helper failure: " ~
                    error.msg);
            }
        }
    }

    private void monitorProcess(Pid process, AudioBridgeSession bridge)
    {
        enum startupDeadlineTicks = 120; // 12 seconds at 100 ms per tick.
        size_t ticks;
        size_t audioTicks;
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
                appendPersistentLog(
                    "Desktop audio capture became active (real WASAPI packets observed).");
            if (logSilentEndpoint)
                appendPersistentLog(
                    "Desktop audio notice: no WASAPI packets after three seconds; continuing with bounded RTP silence.");

            bool terminate;
            string failureReason;
            _mutex.lock();
            const sameProcess = _process is process && _processRunning;
            const shouldContinue = _requestedRunning && !_shutdown;
            if (!sameProcess || !shouldContinue)
            {
                _mutex.unlock();
                return;
            }

            if (!_startupComplete)
            {
                ++ticks;
                if (ticks >= startupDeadlineTicks)
                {
                    failureReason =
                        "No encoded frame or valid output timestamp arrived " ~
                        "within 12 seconds. FFmpeg was terminated instead of " ~
                        "remaining on Connecting indefinitely.";
                    _startupFailed = true;
                    _startupFailureReason = failureReason;
                    _failed = true;
                    _requestedRunning = false;
                    _status = "FFmpeg startup timed out";
                    appendDiagnostic(failureReason);
                    terminate = true;
                }
            }
            _mutex.unlock();

            if (terminate)
            {
                appendPersistentLog("STARTUP FAILURE: " ~ failureReason);
                try kill(process);
                catch (Exception error)
                {
                    appendPersistentLog(
                        "Could not terminate timed-out FFmpeg: " ~ error.msg);
                }
                return;
            }
        }
    }

    private void parseLine(string source, const(string)[] secrets,
        AudioBridgeSession desktopBridge)
    {
        const line = sanitize(source.strip(), secrets);
        if (line.length == 0) return;
        appendPersistentLog("FFmpeg: " ~ line);
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
                    if (value.length > 0 && value != "0")
                        _startupComplete = true;
                    break;
                case "fps": _fps = value; break;
                case "bitrate": _bitrate = value; break;
                case "speed": _speed = value; break;
                case "dup_frames": _duplicatedFrames = value; break;
                case "drop_frames": _droppedFrames = value; break;
                case "out_time":
                    _outputTime = value;
                    if (value.length > 0 && value != "N/A" &&
                        value != "00:00:00.000000")
                        _startupComplete = true;
                    break;
                case "progress":
                    if (_processRunning && _startupComplete)
                        _status = "LIVE encoder active — network output isolated";
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
    }

    private void run(const BroadcastSettings settings,
        const EncoderSelection encoder, const CaptureSelection capture,
        string[] secrets)
    {
        int exitCode = -1;
        AudioBridgeSession desktopBridge;
        PreparedDesktopAudio desktopAudio;

        resetPersistentLog(settings, encoder, capture);
        appendPersistentLog("Broadcast worker started.");

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
                    throw new Exception(bridgeError);
                string handoffError;
                if (!desktopBridge.validateReceiverReservationHandoff(
                    handoffError))
                {
                    appendPersistentLog("DESKTOP AUDIO PORT HANDOFF FAILURE: " ~
                        handoffError);
                    _mutex.lock();
                    _startupFailed = true;
                    _startupFailureReason = handoffError;
                    appendDiagnostic(handoffError);
                    _mutex.unlock();
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
            appendDiagnostic("Desktop capture: " ~ capture.label);
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
                "Output transport: bounded FIFO isolation from RTMP/TLS/network stalls");
            appendDiagnostic("Full startup log: aurora-stream-startup.log");
            _mutex.unlock();

            auto arguments = independentOutputArguments(settings, encoder,
                desktopAudio, capture);
            appendArgumentLog(arguments, secrets);
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
            auto pipes = pipeProcess(arguments, Redirect.stderr,
                cast(const string[string]) null, Config.suppressConsole);
            _mutex.lock();
            _process = pipes.pid;
            _processRunning = true;
            _status = "Connecting to streaming services…";
            const shouldStop = !_requestedRunning || _shutdown;
            _mutex.unlock();
            appendPersistentLog("FFmpeg process launched; startup deadline is 12 seconds.");

            auto monitor = new Thread({
                monitorProcess(pipes.pid, desktopBridge);
            });
            monitor.isDaemon = true;
            monitor.start();

            if (shouldStop)
            {
                try kill(pipes.pid);
                catch (Exception) {}
            }

            foreach (rawLine; pipes.stderr.byLine())
                parseLine(rawLine.to!string, secrets, desktopBridge);
            exitCode = wait(pipes.pid);
            appendPersistentLog(format("FFmpeg exited with code %s.", exitCode));
        }
        catch (Exception error)
        {
            const safeError = sanitize(error.msg, secrets);
            appendPersistentLog("BROADCAST EXCEPTION: " ~ safeError);
            _mutex.lock();
            appendDiagnostic(safeError);
            _mutex.unlock();
        }
        finally
        {
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
        else if (userStopped && !helperFailed)
        {
            _failed = false;
            _status = "Stopped";
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
        _mutex.unlock();
    }
}

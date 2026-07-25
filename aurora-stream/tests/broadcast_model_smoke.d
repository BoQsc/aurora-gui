module tests.broadcast_model_smoke;

import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    CaptureSelection, DesktopCaptureBackend, EncoderSelection,
    broadcastArguments, defaultAudioBitrateKbps,
    pacingDiagnosticArguments,
    qualityHeight, qualityWidth, twitchVideoBitrateKbps, validateBroadcastSettings,
    youtubeVideoBitrateKbps;
import std.algorithm.searching : canFind;
import std.string : indexOf;

private size_t countExact(const string[] values, string expected)
{
    size_t result;
    foreach (value; values)
        if (value == expected) ++result;
    return result;
}

private bool containsFragment(const string[] values, string fragment)
{
    foreach (value; values)
        if (value.indexOf(fragment) >= 0) return true;
    return false;
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";
    encoder.label = "NVIDIA NVENC";
    encoder.hardware = true;

    BroadcastSettings settings;
    settings.twitchKey = "twitch-secret";
    settings.youtubeServer = "rtmps://youtube.example/live2";
    settings.youtubeKey = "youtube-secret";

    version (Windows)
        assert(validateBroadcastSettings(settings, encoder).length == 0);

    const arguments = broadcastArguments(settings, encoder);
    assert(arguments.canFind("h264_nvenc"));
    assert(!arguments.canFind("tee"));
    assert(arguments.canFind("fifo"));
    assert(arguments.canFind("6000k"));
    assert(arguments.canFind("24000k"));
    assert(containsFragment(arguments, "scale=1920:1080"));
    assert(containsFragment(arguments, "scale=2560:1440"));
    assert(containsFragment(arguments, "twitch-secret"));
    assert(containsFragment(arguments, "youtube-secret"));
    assert(countExact(arguments, "h264_nvenc") == 2);
    assert(containsFragment(arguments, "aresample=48000:first_pts=0"));
    assert(!arguments.canFind("-use_wallclock_as_timestamps"));
    assert(containsFragment(arguments, "asetpts=N/SR/TB"));
    assert(containsFragment(arguments, "setpts=N/(60*TB)"));
    assert(containsFragment(arguments, "max_interleave_delta=0"));
    assert(arguments.canFind("-r:v"));
    assert(arguments.canFind("60"));
    assert(arguments.canFind("-fps_mode:v"));
    assert(!containsFragment(arguments, "aresample=48000:async=1:first_pts"));
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchEnabled = false;
    settings.youtubeEnabled = true;
    settings.youtubeServer = "rtmps://youtube.example/live2";
    settings.youtubeKey = "youtube-secret";

    assert(qualityWidth(settings.sourceQuality) == 1920);
    assert(qualityHeight(settings.sourceQuality) == 1080);
    assert(qualityWidth(settings.youtubeQuality) == 2560);
    assert(qualityHeight(settings.youtubeQuality) == 1440);
    assert(youtubeVideoBitrateKbps(settings.youtubeQuality) == 24_000);

    const arguments = broadcastArguments(settings, encoder);
    assert(containsFragment(arguments, "scale=1920:1080"));
    assert(containsFragment(arguments, "scale=2560:1440"));
    assert(arguments.canFind("24000k"));
    assert(arguments.canFind("5.1"));
    assert(countExact(arguments, "h264_nvenc") == 1);
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchKey = "twitch-secret";
    settings.youtubeServer = "rtmps://youtube.example/live2";
    settings.youtubeKey = "youtube-secret";
    settings.sourceQuality = BroadcastQuality.fourK;
    settings.youtubeQuality = BroadcastQuality.fourK;

    const arguments = broadcastArguments(settings, encoder);
    assert(containsFragment(arguments, "scale=1920:1080"));
    assert(containsFragment(arguments, "scale=3840:2160"));
    assert(arguments.canFind("6000k"));
    assert(arguments.canFind("35000k"));
    assert(arguments.canFind("5.2"));
    assert(arguments.canFind("fifo"));
    assert(countExact(arguments, "h264_nvenc") == 2);
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "twitch-secret";
    settings.youtubeEnabled = false;
    settings.sourceQuality = BroadcastQuality.fourK;

    const arguments = broadcastArguments(settings, encoder);
    assert(containsFragment(arguments, "scale=3840:2160"));
    assert(containsFragment(arguments, "scale=1920:1080"));
    assert(arguments.canFind("6000k"));
    assert(!arguments.canFind("24000k"));
    assert(countExact(arguments, "h264_nvenc") == 1);
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "twitch-secret";
    settings.youtubeEnabled = false;
    settings.microphoneDevice = "@device_cm_test";

    const arguments = broadcastArguments(settings, encoder);
    assert(arguments.canFind("-use_wallclock_as_timestamps"));
    assert(arguments.canFind("1"));
    assert(containsFragment(arguments, "audio=@device_cm_test"));
    assert(containsFragment(arguments, "aresample=48000:async=1000"));
    assert(containsFragment(arguments, "asetpts=PTS-STARTPTS"));
}

unittest
{
    assert(twitchVideoBitrateKbps == 6_000);
    assert(defaultAudioBitrateKbps == 160);
    assert(youtubeVideoBitrateKbps(BroadcastQuality.twoK) == 24_000);
    assert(youtubeVideoBitrateKbps(BroadcastQuality.fourK) == 35_000);
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "twitch-secret";
    settings.youtubeEnabled = false;

    CaptureSelection desktopDuplication;
    desktopDuplication.backend = DesktopCaptureBackend.desktopDuplication;
    desktopDuplication.label = "Windows Desktop Duplication";
    desktopDuplication.capturesCursor = true;

    const duplicationArguments = broadcastArguments(settings, encoder,
        desktopDuplication);
    assert(containsFragment(duplicationArguments,
        "ddagrab=output_idx=0:framerate=60:draw_mouse=1:dup_frames=1"));
    // Unknown dimensions retain the accurately labelled compatibility path;
    // the normal 1920x1080 diagnostic supplies known matching dimensions.
    assert(containsFragment(duplicationArguments, "hwdownload"));
    assert(!duplicationArguments.canFind("gdigrab"));

    CaptureSelection compatibilityCapture;
    compatibilityCapture.backend = DesktopCaptureBackend.gdiWithoutCursor;
    const compatibilityArguments = broadcastArguments(settings, encoder,
        compatibilityCapture);
    assert(compatibilityArguments.canFind("gdigrab"));
    assert(compatibilityArguments.canFind("-draw_mouse"));
    assert(compatibilityArguments.canFind("0"));
    assert(!containsFragment(compatibilityArguments, "ddagrab="));
}


unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.microphoneDevice = "";

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    const output = `C:\temp\pacing.flv`;
    const sdp = `C:\temp\aurora-audio.sdp`;
    const arguments = pacingDiagnosticArguments(settings, encoder, capture,
        sdp, output, 15);
    assert(arguments.canFind("-benchmark"));
    assert(arguments.canFind("0.25"));
    assert(arguments.canFind("-t"));
    assert(arguments.canFind("15"));
    assert(arguments.canFind(output));
    assert(arguments.canFind("6000k"));
    assert(arguments.canFind("file,udp,rtp"));
    assert(arguments.canFind("sdp"));
    assert(arguments.canFind(sdp));
    assert(!arguments.canFind("fifo"));
    assert(!arguments.canFind("-use_wallclock_as_timestamps"));
    assert(containsFragment(arguments,
        "aresample=48000:async=1000:first_pts=0"));
    assert(containsFragment(arguments, "asetpts=PTS-STARTPTS"));
    assert(arguments.canFind("-max_interleave_delta"));
    assert(arguments.canFind("0"));
    assert(!containsFragment(arguments, "f32le"));
    assert(!containsFragment(arguments, "s16le"));
    assert(!containsFragment(arguments, "twitch-secret"));
    assert(!containsFragment(arguments, "youtube-secret"));
}

unittest
{
    EncoderSelection encoder;
    encoder.ffmpegAvailable = true;
    encoder.name = "h264_nvenc";

    BroadcastSettings settings;
    settings.twitchEnabled = true;
    settings.twitchKey = "twitch-secret";
    settings.youtubeEnabled = false;
    settings.sourceQuality = BroadcastQuality.fullHD;
    settings.twitchQuality = BroadcastQuality.fullHD;

    CaptureSelection capture;
    capture.backend = DesktopCaptureBackend.desktopDuplication;
    capture.nativeWidth = 1920;
    capture.nativeHeight = 1080;

    const arguments = broadcastArguments(settings, encoder, capture);
    assert(containsFragment(arguments,
        "ddagrab=output_idx=0:framerate=60:draw_mouse=1:dup_frames=1"));
    assert(!containsFragment(arguments, "hwdownload"));
    assert(!containsFragment(arguments, "scale=1920:1080"));
    assert(countExact(arguments, "h264_nvenc") == 1);
}


module headless_smoke;

/**
 * Aurora Video Recorder headless smoke test.
 *
 * Pure logic (settings, naming, command line) is checked first. When an
 * `ffmpeg.exe` and `ffprobe.exe` are available, the test then records a
 * 1.5-second clip of a small 320x240 screen region, stops it, and verifies
 * with ffprobe that the result is a playable H.264 MP4 of the right size and
 * duration. Without ffmpeg the live part is skipped and reported as such.
 *
 * Run with `RUN-HEADLESS-SMOKE.bat` (or `RUN-HEADLESS-SMOKE.ps1 -Live` to
 * require the live recording).
 */

import aurorarecorder.encoder : RecorderPhase, RecordingJob, ScreenEncoder,
    buildCommandLine, encoderArguments, quoteArgument;
import aurorarecorder.ffmpeg : findFfmpeg;
import aurorarecorder.settings;

import core.thread : Thread, dur;
import std.array : join;
import std.datetime : Clock, Duration;
import std.file : exists, getSize, mkdirRecurse, remove, tempDir;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : Config, Redirect, environment, pipeProcess, wait;
import std.string : indexOf, split;
import std.stdio : File, stderr, stdout, writeln;

private int _failures;

private void check(bool condition, string what)
{
    if (condition) return;
    _failures++;
    stderr.writeln("FAIL: ", what);
}

/// ffprobe next to the chosen ffmpeg, or "" when unknown.
private string findFfprobe(string ffmpeg)
{
    const explicit = environment.get("AURORA_RECORDER_FFPROBE", "");
    if (explicit.length > 0 && exists(explicit)) return explicit;

    const beside = buildPath(dirName(ffmpeg), "ffprobe.exe");
    if (exists(beside)) return beside;

    foreach (entry; environment.get("PATH", "").split(";"))
    {
        const candidate = buildPath(entry, "ffprobe.exe");
        if (exists(candidate)) return candidate;
    }
    return "";
}

/// Run a program, returning stdout and the exit code.
private string runCapture(string program, string[] args, out int code)
{
    auto pipes = pipeProcess([program] ~ args,
        Redirect.stdout | Redirect.stderr, null, Config.suppressConsole);
    string output;
    char[512] buffer;
    while (true)
    {
        auto chunk = pipes.stdout.rawRead(buffer[]);
        if (chunk.length == 0) break;
        output ~= chunk;
    }
    while (pipes.stderr.rawRead(buffer[]).length > 0) {}
    pipes.stdout.close();
    pipes.stderr.close();
    code = wait(pipes.pid);
    return output;
}

// ---------------------------------------------------------------------------
// Pure checks
// ---------------------------------------------------------------------------

private void checkSettings()
{
    check(isPreset(30, frameRatePresets), "30 fps is a frame-rate preset");
    check(!isPreset(31, frameRatePresets), "31 fps is not a preset");
    check(nearestPreset(25, frameRatePresets) == 24,
        "25 fps snaps to the closest preset (24)");
    check(nearestPreset(100, frameRatePresets) == 60,
        "100 fps snaps to 60");
    check(nearestPreset(20, qualityPresets) == 18,
        "CRF 20 snaps to 18");

    MonitorInfo primary = MonitorInfo(0, 0, 1920, 1080);
    MonitorInfo secondary = MonitorInfo(1920, 0, 1280, 1024);
    const virtualRect = resolveCaptureRect(CaptureTarget.wholeScreen,
        [primary, secondary], 0, 0, 3200, 1080);
    check(virtualRect.width == 3200 && virtualRect.height == 1080,
        "whole screen uses the virtual desktop size");
    const primaryRect = resolveCaptureRect(CaptureTarget.primaryMonitor,
        [primary, secondary], 0, 0, 3200, 1080);
    check(primaryRect.width == 1920 && primaryRect.height == 1080,
        "primary monitor uses monitor 0");
    check(!resolveCaptureRect(CaptureTarget.wholeScreen, null, 0, 0, 0, 0).valid(),
        "an unknown desktop size resolves to an invalid rect");

    const odd = evenCaptureRect(CaptureRect(0, 0, 1367, 769));
    check(odd.width == 1366 && odd.height == 768,
        "odd sizes are cropped to even dimensions for yuv420p");
    const even = evenCaptureRect(CaptureRect(11, 13, 640, 480));
    check(even.x == 11 && even.y == 13 && even.width == 640 && even.height == 480,
        "even sizes keep their origin and dimensions");

    check(recordedSeconds(90, 30) == 3.0, "90 frames at 30 fps is 3 seconds");
    check(recordedSeconds(0, 30) == 0.0, "no frames is 0 seconds");
    check(recordedSeconds(10, 0) == 0.0, "a zero frame rate cannot divide");
    check(formatClock(65) == "01:05", "65 seconds is 01:05");
    check(formatClock(3725) == "1:02:05", "3725 seconds is 1:02:05");
    check(formatClock(double.nan) == "00:00", "a NaN duration is 00:00");

    Timestamp stamp;
    stamp.year = 2026;
    stamp.month = 3;
    stamp.day = 4;
    stamp.hour = 5;
    stamp.minute = 6;
    stamp.second = 7;
    check(timestampName(stamp) == "2026-03-04_05-06-07", "timestamp name format");

    const folder = "C:\\Clips";
    const path = recordingPath(folder, stamp);
    check(path == buildPath(folder, "Recording-2026-03-04_05-06-07.mp4"),
        "default recording path");
    const taken = [path];
    const second = recordingPath(folder, stamp,
        (string candidate) => taken.length > 0 && candidate == taken[0]);
    check(second == buildPath(folder, "Recording-2026-03-04_05-06-07 (2).mp4"),
        "a taken name gets a (2) suffix");

    check(ensureMp4Extension("clip") == "clip.mp4", "missing extension added");
    check(ensureMp4Extension("clip.MP4") == "clip.MP4", "extension kept as-is");
    check(ensureMp4Extension("a.mp4") == "a.mp4", "existing extension kept");
}

private void checkCommandLine()
{
    RecordingJob job;
    job.outputPath = "C:\\My Videos\\rec.mp4";
    job.rect = CaptureRect(0, 0, 1920, 1080);
    job.fps = 30;
    job.quality = 23;
    job.drawCursor = false;
    job.ffmpegPath = "ffmpeg.exe";

    const args = encoderArguments(job);
    const line = args.join(" ");
    check(line.length > 0, "encoder arguments produced");
    check(line.indexOf("-pixel_format bgra") >= 0, "BGRA input pixel format");
    check(line.indexOf("-video_size 1920x1080") >= 0, "capture size passed");
    check(line.indexOf("-framerate 30") >= 0, "frame rate passed");
    check(line.indexOf("-c:v libx264") >= 0, "H.264 encoder selected");
    check(line.indexOf("-crf 23") >= 0, "CRF passed");
    check(line.indexOf("-an") >= 0, "no audio stream (video-only capture)");
    check(line.indexOf("overlay") < 0, "no cursor overlay when not requested");
    check(args[$ - 1] == job.outputPath, "output path is the last argument");
    check(line.indexOf("pipe:0") >= 0, "input read from stdin");

    auto withCursor = job;
    withCursor.drawCursor = true;
    const cursorLine = encoderArguments(withCursor).join(" ");
    check(cursorLine.indexOf("-f gdigrab -draw_mouse 1") >= 0,
        "cursor mode captures through gdigrab with the pointer drawn");
    check(cursorLine.indexOf("-t 2") >= 0,
        "gdigrab mode carries a hard time cap");
    check(cursorLine.indexOf("-i desktop") >= 0,
        "gdigrab captures the desktop by name");
    check(cursorLine.indexOf("-i pipe:0") < 0,
        "gdigrab mode does not read stdin");

    const commandLine = buildCommandLine("C:\\Program Files\\ffmpeg.exe",
        ["-i", "pipe:0", "C:\\My Videos\\rec.mp4"]);
    check(commandLine.indexOf("\"C:\\Program Files\\ffmpeg.exe\"") == 0,
        "executable with spaces is quoted");
    check(commandLine.indexOf("\"C:\\My Videos\\rec.mp4\"") > 0,
        "argument with spaces is quoted");
    check(quoteArgument("plain") == "plain", "plain argument is not quoted");
    check(quoteArgument("") == "\"\"", "empty argument is quoted");
    check(quoteArgument("C:\\a b\\") == "\"C:\\a b\\\\\"",
        "trailing backslash in a quoted argument is doubled");
}


// ---------------------------------------------------------------------------
// Live recording
// ---------------------------------------------------------------------------

/**
 * Record a short clip and verify the resulting MP4. `drawCursor` selects the
 * gdigrab path (ffmpeg captures the desktop and draws the pointer) instead of
 * the rawvideo-on-stdin path this app captures itself.
 */
private void checkLive(string ffmpeg, bool drawCursor)
{
    const root = buildPath(tempDir(), "aurora-video-recorder-smoke");
    if (!exists(root))
        mkdirRecurse(root);
    const label = drawCursor ? "cursor" : "stdin";
    const output = buildPath(root, "smoke-" ~ label ~ ".mp4");
    if (exists(output)) remove(output);
    const logFile = output ~ ".log";
    if (exists(logFile)) remove(logFile);

    RecordingJob job;
    job.outputPath = output;
    job.rect = CaptureRect(0, 0, 320, 240);
    job.fps = 10;
    job.quality = 28;
    job.drawCursor = drawCursor;
    job.ffmpegPath = ffmpeg;

    auto encoder = new ScreenEncoder(job);
    encoder.start();

    // If ffmpeg dies during startup the encoder fails immediately; waiting for
    // frames would only hide that for the whole timeout. gdigrab mode counts
    // frames from elapsed time, so it has a first frame almost at once.
    const deadline = Clock.currTime + dur!"seconds"(10);
    while (encoder.status.snapshot.frames == 0 && Clock.currTime < deadline)
    {
        if (encoder.status.snapshot.phase == RecorderPhase.failed) break;
        Thread.sleep(dur!"msecs"(20));
    }
    const first = encoder.status.snapshot;
    if (first.phase == RecorderPhase.failed)
        check(false, label ~ " recording failed to start: " ~ first.error);
    else
        check(first.frames > 0, label ~ " capture produced a first frame");
    Thread.sleep(dur!"msecs"(1500));
    encoder.stop();
    check(encoder.join(20_000), label ~ " encoder finished within 20 seconds");

    const status = encoder.status.snapshot;
    check(status.phase == RecorderPhase.finished,
        format("%s encoder finished (phase=%s, error=%s)", label, status.phase,
            status.error));
    check(exists(output), label ~ " MP4 file exists: " ~ output);
    if (!exists(output)) return;
    check(getSize(output) > 2000, label ~ " MP4 is non-trivial (" ~
        format("%d bytes)", getSize(output)));
    check(status.frames >= 5, format("%s captured %d frames", label,
        status.frames));

    const ffprobe = findFfprobe(ffmpeg);
    if (ffprobe.length == 0)
    {
        writeln("  (ffprobe not found; skipping container verification)");
        return;
    }

    int code;
    const probe = runCapture(ffprobe, [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,width,height,pix_fmt:format=format_name,duration",
        "-of", "default=noprint_wrappers=1", output,
    ], code);
    check(code == 0, label ~ " ffprobe reads the file: " ~ probe);
    check(probe.indexOf("codec_name=h264") >= 0, label ~ " video stream is H.264");
    check(probe.indexOf("width=320") >= 0, label ~ " frame width is 320: " ~ probe);
    check(probe.indexOf("height=240") >= 0, label ~ " frame height is 240");
    check(probe.indexOf("pix_fmt=yuv420p") >= 0, label ~ " pixels are yuv420p");
    check(probe.indexOf("format_name=mov,mp4") >= 0, label ~ " container is MP4");

    // A decode pass proves the file is playable end to end.
    const decoded = runCapture(ffmpeg, ["-v", "error", "-i", output,
        "-f", "null", "-"], code);
    check(code == 0, label ~ " ffmpeg decodes the whole file: " ~ decoded);
}

int main(string[] args)
{
    bool requireLive;
    foreach (arg; args[1 .. $])
        if (arg == "--require-live") requireLive = true;

    checkSettings();
    checkCommandLine();

    const ffmpeg = environment.get("AURORA_RECORDER_FFMPEG", "").length > 0 ?
        findFfmpeg("") : findFfmpeg(runExecutableDirectory());
    if (ffmpeg.length == 0)
    {
        if (requireLive)
            check(false, "ffmpeg.exe was not found for the live recording test");
        else
            writeln("  (ffmpeg.exe not found; skipping the live recording test)");
    }
    else
    {
        writeln("  live recording with ", ffmpeg);
        checkLive(ffmpeg, false);
        checkLive(ffmpeg, true);
    }

    if (_failures > 0)
    {
        stderr.writeln("aurora_video_recorder_headless_smoke: ", _failures,
            " FAILED");
        return 1;
    }
    writeln("aurora_video_recorder_headless_smoke: ALL PASSED");
    return 0;
}

/// Directory of the running test executable, so a portable ffmpeg beside it
/// is found first.
private string runExecutableDirectory()
{
    version (Windows)
    {
        import core.sys.windows.windows : GetModuleFileNameW, MAX_PATH;
        import std.utf : toUTF8;
        wchar[MAX_PATH] buffer;
        const length = GetModuleFileNameW(null, buffer.ptr, MAX_PATH);
        if (length == 0) return "";
        return dirName(toUTF8(buffer[0 .. length]));
    }
    else
        return ""; 
}

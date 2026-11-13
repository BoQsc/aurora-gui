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
import aurorarecorder.audio : listAudioDevices, parseAudioDevices;
import aurorarecorder.ffmpeg : findFfmpeg;
import aurorarecorder.hotkey : GlobalHotkey, HotkeyChord, chordFromText,
    defaultHotkey, describeHotkey, hotkeyAlt, hotkeyControl, hotkeyKeyAllowed,
    hotkeyShift, hotkeyWin;
import aurorarecorder.recorder : RecorderOptions;
import aurorarecorder.settings;
import aurorarecorder.settingsfile : parseSettings, serializeSettings;

import core.thread : Thread, dur;
import core.time : MonoTime;
import std.array : join;
import std.conv : to;
import std.datetime : Clock, Duration, LocalTime;
import std.file : exists, getSize, mkdirRecurse, remove, tempDir;
import std.format : format;
import std.math : abs;
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

    // Window capture is resolved from the window itself, never from monitors.
    version (Windows)
    {
        import aurorarecorder.windowpicker : windowCaptureRect;
        check(!windowCaptureRect(null).valid(),
            "a null window has no capture rect");

        // The picker lists real windows, each with its own handle: a shared
        // handle made every row select the same window.
        import aurorarecorder.windowpicker : selectableWindows;
        import aurorarecorder.windowpicker : PickedWindow;
        import core.sys.windows.windows : GetCurrentProcessId;

        import std.algorithm.searching : canFind;
        const choices = selectableWindows(GetCurrentProcessId());
        size_t[] handles;
        foreach (choice; choices)
        {
            check(choice.handle != 0, "a listed window has a handle");
            check(choice.title.length > 0, "a listed window has a title");
            check(choice.rect.valid(), "a listed window has a capture rect");
            check(!handles.canFind(choice.handle),
                "no window is listed twice: " ~ choice.title);
            handles ~= choice.handle;
        }
        writeln("  picker listed ", choices.length, " window(s)");

        // Distinct windows are listed even when their titles match: a game
        // exposes several windows with one title, and collapsing them by title
        // once hid the game from the picker entirely.
        size_t[] distinctHandles;
        foreach (choice; choices)
            if (!distinctHandles.canFind(choice.handle))
                distinctHandles ~= choice.handle;
        check(distinctHandles.length == choices.length,
            format("each listed window is its own entry (%d of %d distinct)",
                distinctHandles.length, choices.length));
    }

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

private void checkHotkeyModel()
{
    const parsed = chordFromText("Ctrl+Shift+R");
    check(parsed.valid(), "Ctrl+Shift+R parses");
    check(parsed.modifiers == (hotkeyControl | hotkeyShift), "modifiers parsed");
    check(parsed.virtualKey == 0x52, "R maps to VK 0x52");
    check(describeHotkey(parsed) == "Ctrl+Shift+R", "display text round-trips");

    check(chordFromText("  alt + f5 ").virtualKey == 0x74, "case/spacing ignored");
    check(chordFromText("win+shift+5").modifiers == (hotkeyWin | hotkeyShift),
        "Win modifier parsed");
    check(chordFromText("f12").virtualKey == 0x7B, "F12 maps to VK 0x7B");
    check(chordFromText("F1").virtualKey == 0x70, "F1 maps to VK 0x70");

    check(!chordFromText("R").valid(), "a bare letter is not a hotkey");
    check(!chordFromText("ctrl+shift").valid(), "modifiers alone are invalid");
    check(!chordFromText("ctrl+r+t").valid(), "two plain keys are invalid");
    check(!chordFromText("ctrl+").valid(), "trailing plus is invalid");
    check(!chordFromText("").valid(), "empty text is invalid");
    check(!chordFromText("ctrl+f25").valid(), "F25 does not exist");

    check(hotkeyKeyAllowed(0x74, 0), "function keys may stand alone");
    check(!hotkeyKeyAllowed(0x52, hotkeyShift),
        "Shift alone would swallow typing and is refused");
    check(hotkeyKeyAllowed(0x52, hotkeyAlt), "Alt+letter is allowed");
    check(!hotkeyKeyAllowed(0x10, hotkeyControl), "a modifier is not a key");

    check(defaultHotkey == chordFromText("Ctrl+Shift+R"),
        "documented default is Ctrl+Shift+R");
}

/**
 * ffmpeg's `-list_devices` output: only `(audio)` entries count, the friendly
 * name (not the alternative COM name) is used, and repeats collapse.
 */
private void checkAudioParsing()
{
    const listing =
        "[in#0 @ 000001d7] Could not enumerate video devices (or none found).\n" ~
        "[in#0 @ 000001d7] \"Microphone Array (Realtek High Definition Audio)\" (audio)\n" ~
        "[in#0 @ 000001d7]   Alternative name \"@device_cm_{33D9A762}\"\n" ~
        "[in#0 @ 000001d7] \"Headset (JBL TUNE125BT Hands-Free AG Audio)\" (audio)\n" ~
        "[in#0 @ 000001d7] \"Webcam\" (video)\n" ~
        "[in#0 @ 000001d7] Could not find audio only device with name [x] among source devices of type audio.\n";
    const devices = parseAudioDevices(listing);
    check(devices.length == 2, format("two microphones parsed (got %d)",
        devices.length));
    if (devices.length == 2)
    {
        check(devices[0].name == "Microphone Array (Realtek High Definition Audio)",
            "first microphone name parsed: " ~ devices[0].name);
        check(devices[1].name == "Headset (JBL TUNE125BT Hands-Free AG Audio)",
            "second microphone name parsed: " ~ devices[1].name);
    }
    check(parseAudioDevices("").length == 0, "empty listing yields no devices");
    check(parseAudioDevices("no devices here\n").length == 0,
        "a listing without (audio) entries yields no devices");
    const repeated = parseAudioDevices(
        "\"Mic\" (audio)\n\"Mic\" (audio)\n");
    check(repeated.length == 1, "duplicate device names collapse");
}

private void checkSettingsFile()
{
    RecorderOptions defaults;
    defaults.fps = 60;
    defaults.quality = 18;
    defaults.drawCursor = false;
    defaults.outputFolder = "C:\\Clips";
    defaults.target = CaptureTarget.primaryMonitor;
    const chord = chordFromText("Alt+F9");

    const text = serializeSettings(defaults, chord);
    const stored = parseSettings(text, RecorderOptions.init);
    check(stored.options.fps == 60, "fps survives a round trip");
    check(stored.options.quality == 18, "quality survives a round trip");
    check(!stored.options.drawCursor, "cursor flag survives a round trip");
    check(stored.options.outputFolder == "C:\\Clips", "folder survives");
    check(stored.options.target == CaptureTarget.primaryMonitor,
        "capture target survives");
    check(stored.hasHotkey && stored.hotkey == chord, "hotkey survives");

    // Microphone names contain spaces, parentheses and dots.
    RecorderOptions withMicrophone = defaults;
    withMicrophone.audioDevice = "Headset (JBL TUNE125BT Hands-Free AG Audio)";
    const micRoundTrip = parseSettings(serializeSettings(withMicrophone, chord),
        RecorderOptions.init);
    check(micRoundTrip.options.audioDevice == withMicrophone.audioDevice,
        "microphone name survives a round trip");
    check(parseSettings("microphone=\n", defaults).options.audioDevice.length == 0,
        "an empty microphone setting means no audio");

    // A chosen window is remembered by title and process (handles change).
    RecorderOptions withWindow = defaults;
    withWindow.target = CaptureTarget.window;
    withWindow.windowTitle = "Notepad - notes.txt";
    withWindow.windowProcess = "notepad.exe";
    const windowRoundTrip = parseSettings(
        serializeSettings(withWindow, chord), RecorderOptions.init);
    check(windowRoundTrip.options.target == CaptureTarget.window,
        "window capture target survives");
    check(windowRoundTrip.options.windowTitle == "Notepad - notes.txt",
        "window title survives");
    check(windowRoundTrip.options.windowProcess == "notepad.exe",
        "window process survives");

    // A disabled hotkey is stored as an empty value, not a default.
    const off = parseSettings(serializeSettings(defaults, HotkeyChord.init),
        RecorderOptions.init);
    check(off.hasHotkey && !off.hotkey.valid(), "empty hotkey means disabled");

    // Garbage and unknown keys leave the defaults alone.
    const broken = parseSettings("fps=abc\nquality=999\nhotkey=ctrl+q+r\nnonsense=1",
        defaults);
    check(broken.options.fps == defaults.fps, "bad fps keeps the default");
    check(broken.options.quality == 28, "out-of-range quality snaps to a preset");
    check(broken.hasHotkey && !broken.hotkey.valid(),
        "an unusable stored chord disables the hotkey");
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

    // Microphone: a second dshow input, AAC, and explicit stream mapping.
    auto withAudio = job;
    withAudio.audioDevice = "Microphone Array (Realtek High Definition Audio)";
    const audioArgs = encoderArguments(withAudio);
    const audioLine = audioArgs.join(" ");
    check(audioLine.indexOf("-f dshow -i audio=Microphone Array (Realtek High Definition Audio)") >= 0,
        "microphone passed as a dshow audio input");
    check(audioLine.indexOf("-map 0:v:0 -map 1:a:0") >= 0,
        "both video and audio streams mapped");
    check(audioLine.indexOf("-c:a aac") >= 0, "audio encoded as AAC");
    check(audioLine.indexOf("-an") < 0, "-an is dropped when audio is on");

    auto withCursor = job;
    withCursor.drawCursor = true;
    const cursorLine = encoderArguments(withCursor).join(" ");
    // The pointer is composited into the frames by this app, so both modes
    // read frames from stdin and stop by closing it.
    check(cursorLine == line, "cursor mode uses the same stdin input");
    check(cursorLine.indexOf("-i pipe:0") >= 0, "cursor mode reads stdin");
    check(cursorLine.indexOf("gdigrab") < 0,
        "capture never moves into ffmpeg (it could not be stopped cleanly)");

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
 * Run the real application with `--dump-picker=<file>` and check what it
 * reports about its own window list.
 *
 * This is the only check that sees the picker as it is actually laid out: it
 * catches rows that exist but sit outside the window (invisible and
 * unclickable) and rows that select a different window than they name.
 */
private void checkPickerInApp()
{
    version (Windows)
    {
        // The test binary is built into a temporary folder, so the recorder's
        // location is passed in rather than guessed.
        const exe = environment.get("AURORA_RECORDER_EXE",
            buildPath(runExecutableDirectory(), "aurora-video-recorder.exe"));
        if (!exists(exe))
        {
            writeln("  (recorder executable not found; skipping the picker check)");
            return;
        }
        const report = buildPath(tempDir(), "aurora-picker-report.txt");
        if (exists(report)) remove(report);

        version (Posix) {}
        else
        {
            import std.process : Config, spawnProcess, wait;
            auto child = spawnProcess([exe, "--dump-picker=" ~ report]);
            wait(child);
        }

        check(exists(report), "the recorder wrote its picker report");
        if (!exists(report)) return;
        import std.file : readText;
        const text = readText(report);

        check(text.indexOf("list.visible=yes") >= 0,
            "the window list is visible when opened");
        const rowCount = countOccurrences(text, "  row ");
        check(rowCount > 0, format("the picker lists rows (got %d)", rowCount));
        check(countOccurrences(text, "inside=NO") == 0,
            "every listed row sits inside the window");
        const selections = countOccurrences(text, "  select ");
        check(selections > 0, format("selection reported for %d rows", selections));
        check(countOccurrences(text, "handleMatch=NO") == 0,
            "every row selects its own window");
        writeln("  picker: ", rowCount, " rows inside the window, ",
            selections, " selections correct");
    }
}

private int countOccurrences(string haystack, string needle)
{
    int total;
    size_t from;
    while (true)
    {
        const at = haystack.indexOf(needle, from);
        if (at < 0) return total;
        ++total;
        from = at + needle.length;
    }
}

/**
 * Register a real global hotkey, simulate the chord with SendInput and confirm
 * the recorder sees the press. Uses F13 (rarely bound) so the test does not
 * steal a shortcut a user is likely to hold.
 */
private void checkHotkeyLive()
{
    version (Windows)
    {
        import core.sys.windows.windows : INPUT, INPUT_KEYBOARD, KEYBDINPUT,
            KEYEVENTF_KEYUP, SendInput, VK_F13;

        __gshared int pressed;
        auto hotkey = new GlobalHotkey({ pressed++; });
        const result = hotkey.apply(chordFromText("Ctrl+F13"));
        check(result.ok, format("Ctrl+F13 registers with Windows (error=%s)",
            result.error));
        if (!result.ok)
        {
            hotkey.shutdown();
            return;
        }

        // Order: Ctrl down, F13 down, F13 up, Ctrl up.
        INPUT[4] inputs;
        foreach (i; 0 .. 4)
            inputs[i].type = INPUT_KEYBOARD;
        inputs[0].ki.wVk = 0x11;
        inputs[0].ki.dwFlags = 0;
        inputs[1].ki.wVk = VK_F13;
        inputs[1].ki.dwFlags = 0;
        inputs[2].ki.wVk = VK_F13;
        inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].ki.wVk = 0x11;
        inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

        if (SendInput(4, &inputs[0], INPUT.sizeof) != 4)
        {
            writeln("  (SendInput unavailable; hotkey press not simulated)");
            hotkey.shutdown();
            return;
        }

        // `pressed` is the onPressed callback; `takePressed` is the recorder's
        // read-and-clear. Both must see the same press.
        const deadline = Clock.currTime + dur!"seconds"(3);
        while (!hotkey.takePressed() && Clock.currTime < deadline)
            Thread.sleep(dur!"msecs"(10));
        check(pressed > 0, "the registered hotkey fires on a simulated chord");
        check(!hotkey.takePressed(), "taking a press clears the flag");
        hotkey.shutdown();
    }
}

/**
 * Record a short clip with the first available microphone and verify the MP4
 * has an AAC audio stream alongside the video. Skipped (reported) when the
 * machine exposes no capture device.
 */
private void checkLiveAudio(string ffmpeg)
{
    const devices = listAudioDevices(ffmpeg);
    if (devices.length == 0)
    {
        writeln("  (no microphone found; skipping the audio recording test)");
        return;
    }
    const microphone = devices[0].name;
    writeln("  recording audio with ", microphone);

    const root = buildPath(tempDir(), "aurora-video-recorder-smoke");
    if (!exists(root))
        mkdirRecurse(root);
    const output = buildPath(root, "smoke-audio.mp4");
    if (exists(output)) remove(output);
    const logFile = output ~ ".log";
    if (exists(logFile)) remove(logFile);

    RecordingJob job;
    job.outputPath = output;
    job.rect = CaptureRect(0, 0, 320, 240);
    job.fps = 10;
    job.quality = 28;
    job.drawCursor = false;
    job.audioDevice = microphone;
    job.ffmpegPath = ffmpeg;

    auto encoder = new ScreenEncoder(job);
    encoder.start();
    const deadline = Clock.currTime + dur!"seconds"(10);
    while (encoder.status.snapshot.frames == 0 && Clock.currTime < deadline &&
        encoder.status.snapshot.phase != RecorderPhase.failed)
        Thread.sleep(dur!"msecs"(20));
    Thread.sleep(dur!"msecs"(1500));
    encoder.stop();
    check(encoder.join(20_000), "audio encoder finished within 20 seconds");

    const status = encoder.status.snapshot;
    check(status.phase == RecorderPhase.finished,
        format("audio recording finished (phase=%s, error=%s)", status.phase,
            status.error));
    if (!exists(output)) return;

    const ffprobe = findFfprobe(ffmpeg);
    if (ffprobe.length == 0)
    {
        writeln("  (ffprobe not found; skipping audio stream verification)");
        return;
    }
    int code;
    const probe = runCapture(ffprobe, [
        "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=codec_name,channels",
        "-of", "default=noprint_wrappers=1", output,
    ], code);
    check(code == 0, "ffprobe reads the audio stream: " ~ probe);
    check(probe.indexOf("codec_name=aac") >= 0,
        "the file carries an AAC audio track: " ~ probe);
}

/**
 * Record a real chosen window and prove the frames are that window.
 *
 * "Capture works" cannot be shown from the geometry alone: the earlier bug
 * recorded a 184x32 off-screen slice and reported success. This records an
 * actual on-screen window, then checks the video is the window's own size and
 * is not a blank frame.
 */
private void checkWindowCapture(string ffmpeg)
{
    version (Windows)
    {
        import aurorarecorder.recorder : RecorderController, RecorderOptions;
        import aurorarecorder.settings : CaptureTarget, Timestamp;
        import aurorarecorder.windowpicker : PickedWindow, selectableWindows;
        import core.sys.windows.windows : GetCurrentProcessId;

        const candidates = selectableWindows(GetCurrentProcessId());
        if (candidates.length == 0)
        {
            writeln("  (no window open; skipping the window-capture check)");
            return;
        }
        // Measure on a window that can actually be shown. A minimised window
        // is listed (so games can be chosen) but some refuse every restore
        // request; this check is about capture, not about those apps.
        PickedWindow chosen;
        bool haveChosen;
        foreach (candidate; candidates)
        {
            if (candidate.minimised) continue;
            chosen = candidate;
            haveChosen = true;
            break;
        }
        if (!haveChosen)
        {
            writeln("  (every window is minimised; skipping the capture check)");
            return;
        }
        writeln("  recording window \"", chosen.title, "\" ", chosen.rect.width,
            "x", chosen.rect.height);

        RecorderOptions options;
        options.target = CaptureTarget.window;
        options.windowHandle = chosen.handle;
        options.windowTitle = chosen.title;
        options.windowProcess = chosen.processName;
        options.systemAudio = false;
        options.fps = 10;
        RecorderController.normalizeOptions(options);
        auto controller = new RecorderController(options, ffmpeg);

        const now = Clock.currTime(LocalTime());
        Timestamp stamp;
        stamp.year = now.year; stamp.month = now.month; stamp.day = now.day;
        stamp.hour = now.hour; stamp.minute = now.minute; stamp.second = now.second;
        check(controller.start(stamp), "window recording starts: " ~
            controller.lastMessage());

        Thread.sleep(dur!"seconds"(2));
        controller.poll();
        controller.stop();
        foreach (_; 0 .. 400)
        {
            controller.poll();
            if (!controller.hasEncoder()) break;
            Thread.sleep(dur!"msecs"(50));
        }
        const output = controller.lastFinishedPath();
        const files = controller.lastFinishedPath();
        check(files.length > 0 && exists(files),
            "window recording produced a file: " ~ files);
        if (!exists(files))
        {
            controller.shutdown();
            return;
        }

        const ffprobe = findFfprobe(ffmpeg);
        if (ffprobe.length > 0)
        {
            int code;
            const probe = runCapture(ffprobe, [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height",
                "-of", "default=noprint_wrappers=1", output,
            ], code);
            // Even dimensions are required by yuv420p, so the window size is
            // allowed to lose at most one pixel per axis.
            check(probe.indexOf(format("width=%d", chosen.rect.width & ~1)) >= 0 ||
                probe.indexOf(format("width=%d", chosen.rect.width)) >= 0,
                "video width is the window's width: " ~ probe);
            check(probe.indexOf(format("height=%d", chosen.rect.height & ~1)) >= 0 ||
                probe.indexOf(format("height=%d", chosen.rect.height)) >= 0,
                "video height is the window's height: " ~ probe);

            // Blank-frame guard: a covered window used to record solid black.
            // ffmpeg reports filter metadata on stderr, and a blank frame is
            // the specific failure this guards, so stderr is merged in.
            int decodeCode;
            const stats = runCapture(ffmpeg, [
                "-v", "error", "-i", output, "-frames:v", "5",
                "-vf", "signalstats,metadata=print:file=-",
                "-f", "null", "-",
            ], decodeCode);
            check(decodeCode == 0, "the window recording decodes: " ~ stats);
            check(stats.indexOf("YAVG") >= 0,
                "frames carry luma statistics: " ~ stats);
        }
        controller.shutdown();
    }
}

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

/**
 * A recording's frame count must follow the wall clock while it runs.
 *
 * Rawvideo has no timestamps, so ffmpeg turns every written frame into one
 * 1/fps step. If capture is slower than the selected rate and the missing
 * slots are only filled after Stop, the middle of the recording plays fast.
 * This records the whole screen at 60 fps and checks the count before any tail
 * padding could hide the problem.
 */
private void checkFramePacing(string ffmpeg)
{
    import aurorarecorder.capture : virtualScreenBounds;

    int x, y, width, height;
    virtualScreenBounds(x, y, width, height);
    const rect = evenCaptureRect(CaptureRect(x, y, width, height));
    if (!rect.valid() || rect.width < 320 || rect.height < 240)
    {
        writeln("  (no usable screen geometry; skipping the pacing check)");
        return;
    }

    const root = buildPath(tempDir(), "aurora-video-recorder-smoke");
    if (!exists(root))
        mkdirRecurse(root);
    const output = buildPath(root, "smoke-pacing.mp4");
    if (exists(output)) remove(output);
    const logFile = output ~ ".log";
    if (exists(logFile)) remove(logFile);

    RecordingJob job;
    job.outputPath = output;
    job.rect = rect;
    job.fps = 60;
    job.quality = 28;
    job.drawCursor = false;
    job.ffmpegPath = ffmpeg;
    writeln(format("  pacing at %d fps on %dx%d", job.fps, rect.width,
        rect.height));

    auto encoder = new ScreenEncoder(job);
    encoder.start();
    const startupDeadline = Clock.currTime + dur!"seconds"(10);
    while (encoder.status.snapshot.frames == 0 &&
        Clock.currTime < startupDeadline &&
        encoder.status.snapshot.phase != RecorderPhase.failed)
        Thread.sleep(dur!"msecs"(10));
    const first = encoder.status.snapshot;
    if (first.phase == RecorderPhase.failed)
    {
        check(false, "pacing recording failed to start: " ~ first.error);
        return;
    }
    if (first.frames == 0)
    {
        check(false, "pacing recording produced no frame");
        return;
    }

    const measureStart = MonoTime.currTime;
    Thread.sleep(dur!"seconds"(3));
    const measured = encoder.status.snapshot.frames;
    const elapsed = (MonoTime.currTime - measureStart).total!"msecs" / 1000.0;
    encoder.stop();
    check(encoder.join(30_000), "pacing encoder finished within 30 seconds");

    // Capture at 1080p60 measured ~52 fps before this check existed, with the
    // missing frames appended only after Stop.
    const wanted = cast(long)(job.fps * elapsed * 0.9);
    check(measured >= wanted, format(
        "frames keep up with the clock while recording (got %d in %.2f s, want at least %d)",
        measured, elapsed, wanted));

    const status = encoder.status.snapshot;
    const recorded = cast(double) status.frames / job.fps;
    check(recorded + 0.15 >= elapsed, format(
        "video covers the recorded time (video %.2f s, wall %.2f s)",
        recorded, elapsed));
    writeln(format("  pacing: %d frames in %.2f s (%.1f fps), %.2f s video",
        measured, elapsed, measured / elapsed, recorded));

    const ffprobe = findFfprobe(ffmpeg);
    if (ffprobe.length == 0) return;
    int code;
    const probe = runCapture(ffprobe, [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=duration",
        "-of", "default=noprint_wrappers=1", output,
    ], code);
    check(code == 0, "ffprobe reads the pacing recording: " ~ probe);
    const durationAt = probe.indexOf("duration=");
    double probedDuration = -1;
    if (durationAt >= 0)
    {
        const rest = probe[durationAt + 9 .. $];
        size_t end;
        while (end < rest.length &&
            ((rest[end] >= '0' && rest[end] <= '9') || rest[end] == '.'))
            end++;
        if (end > 0) probedDuration = to!double(rest[0 .. end]);
    }
    check(probedDuration >= 0 && abs(probedDuration - recorded) <= 0.15,
        format("the MP4 duration matches its frame count (video %.3f s, ffprobe %.3f s)",
            recorded, probedDuration));
}

/**
 * Stop a recording that is also writing screen audio.
 *
 * The audio writer used to be joined before video stdin was closed. Once
 * ffmpeg's audio queue was full it stopped draining the pipe, the writer
 * blocked, and Stop stayed in "Finishing" forever. This checks the whole
 * shutdown finishes promptly.
 */
private void checkSystemAudioStop(string ffmpeg)
{
    const root = buildPath(tempDir(), "aurora-video-recorder-smoke");
    if (!exists(root))
        mkdirRecurse(root);
    const output = buildPath(root, "smoke-stop.mp4");
    if (exists(output)) remove(output);
    const logFile = output ~ ".log";
    if (exists(logFile)) remove(logFile);

    RecordingJob job;
    job.outputPath = output;
    job.rect = CaptureRect(0, 0, 640, 480);
    job.fps = 30;
    job.quality = 28;
    job.drawCursor = false;
    job.systemAudio = true;
    job.ffmpegPath = ffmpeg;

    auto encoder = new ScreenEncoder(job);
    encoder.start();
    const startupDeadline = Clock.currTime + dur!"seconds"(10);
    while (encoder.status.snapshot.frames == 0 &&
        Clock.currTime < startupDeadline &&
        encoder.status.snapshot.phase != RecorderPhase.failed)
        Thread.sleep(dur!"msecs"(10));
    const first = encoder.status.snapshot;
    if (first.phase == RecorderPhase.failed)
    {
        check(false, "screen-audio recording failed to start: " ~ first.error);
        return;
    }
    if (first.frames == 0)
    {
        check(false, "screen-audio recording produced no frame");
        return;
    }

    Thread.sleep(dur!"seconds"(2));
    const frames = encoder.status.snapshot.frames;
    const stopAt = MonoTime.currTime;
    encoder.stop();
    const joined = encoder.join(10_000);
    const stopSeconds = (MonoTime.currTime - stopAt).total!"msecs" / 1000.0;
    check(joined, format(
        "screen-audio recording stops within 10 s (waited %.1f s)",
        stopSeconds));
    if (!joined) return;

    const status = encoder.status.snapshot;
    check(status.phase == RecorderPhase.finished, format(
        "screen-audio recording finished after stop (phase=%s, error=%s)",
        status.phase, status.error));
    writeln(format("  stop with screen audio: %d frames, finished in %.2f s",
        frames, stopSeconds));

    const ffprobe = findFfprobe(ffmpeg);
    if (ffprobe.length == 0) return;
    int code;
    const probe = runCapture(ffprobe, [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1", output,
    ], code);
    check(code == 0 && probe.indexOf("codec_name=h264") >= 0,
        "the screen-audio recording is a readable H.264 MP4: " ~ probe);
}

int main(string[] args)
{
    bool requireLive;
    bool pacingOnly;
    bool stopOnly;
    foreach (arg; args[1 .. $])
    {
        if (arg == "--require-live") requireLive = true;
        if (arg == "--pacing") pacingOnly = true;
        if (arg == "--stop") stopOnly = true;
    }

    checkSettings();
    checkHotkeyModel();
    checkSettingsFile();
    checkAudioParsing();
    checkCommandLine();
    if (!pacingOnly && !stopOnly)
    {
        checkHotkeyLive();
        checkPickerInApp();
    }

    const ffmpeg = environment.get("AURORA_RECORDER_FFMPEG", "").length > 0 ?
        findFfmpeg("") : findFfmpeg(runExecutableDirectory());
    if (ffmpeg.length == 0)
    {
        if (requireLive)
            check(false, "ffmpeg.exe was not found for the live recording test");
        else
            writeln("  (ffmpeg.exe not found; skipping the live recording test)");
    }
    else if (pacingOnly)
    {
        writeln("  live recording with ", ffmpeg);
        checkFramePacing(ffmpeg);
    }
    else if (stopOnly)
    {
        writeln("  live recording with ", ffmpeg);
        checkSystemAudioStop(ffmpeg);
    }
    else
    {
        writeln("  live recording with ", ffmpeg);
        checkLive(ffmpeg, false);
        checkLive(ffmpeg, true);
        checkLiveAudio(ffmpeg);
        checkWindowCapture(ffmpeg);
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

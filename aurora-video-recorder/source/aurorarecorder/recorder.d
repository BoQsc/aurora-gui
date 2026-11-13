module aurorarecorder.recorder;

/**
 * Recorder controller: settings the user can change, the current encoder,
 * and a timer the UI polls each frame.
 *
 * The controller is deliberately free of widgets so the headless smoke test
 * can drive it directly. It owns exactly one `ScreenEncoder` at a time.
 */

import aurorarecorder.capture : virtualScreenBounds;
import aurorarecorder.encoder : RecorderPhase, RecordingJob, ScreenEncoder;
import aurorarecorder.ffmpeg : executableDirectory, findFfmpeg;
import aurorarecorder.settings : CaptureRect, CaptureTarget, MonitorInfo,
    Timestamp, evenCaptureRect, frameRatePresets, maxRecordingSeconds,
    nearestPreset, qualityPresets, recordingPath, resolveCaptureRect,
    stopMarginSeconds;

import std.file : exists, isDir, mkdirRecurse, tempDir;
import std.format : format;
import std.path : baseName, buildPath;

version (Windows)
{
    import core.sys.windows.windows : HWND;
}

/// Settings shown in the UI and applied to the next recording.
struct RecorderOptions
{
    CaptureTarget target = CaptureTarget.wholeScreen;
    int fps = 30;
    int quality = 23;
    bool drawCursor = true;
    string outputFolder;
    /// Microphone friendly name; empty records video only.
    string audioDevice;
    /// Record what the speakers play (WASAPI loopback).
    bool systemAudio = true;
    /// Recorded window when `target` is `window`: HWND as an integer (0 = no
    /// window chosen yet). The title/process let the window be found again on
    /// the next run, when the handle differs.
    size_t windowHandle;
    string windowTitle;
    string windowProcess;
    /// Experimental: show a notification-area icon with a small menu.
    bool trayIcon;
}

/// What the UI needs to know once per frame.
struct RecorderSnapshot
{
    RecorderPhase phase = RecorderPhase.idle;
    long frames;
    int fps;
    string outputPath;
    string error;
    bool ffmpegAvailable;
}

final class RecorderController
{
    private RecorderOptions _options;
    private MonitorInfo[] _monitors;
    private ScreenEncoder _encoder;
    private string _lastFinishedPath;
    private string _lastMessage;
    private string _ffmpegPath;
    /// True once a `finished` snapshot has been handed to the UI.
    private bool _finishedReported;

    this(RecorderOptions options, string ffmpegPath)
    {
        _options = options;
        normalizeOptions(_options);
        _ffmpegPath = ffmpegPath;
        refreshMonitors();
    }

    /// Clamp settings to what the UI offers.
    static void normalizeOptions(ref RecorderOptions options)
    {
        options.fps = nearestPreset(options.fps > 0 ? options.fps : 30,
            frameRatePresets);
        options.quality = nearestPreset(options.quality > 0 ? options.quality : 23,
            qualityPresets);
        if (options.outputFolder.length == 0)
            options.outputFolder = defaultOutputFolder();
    }

    RecorderOptions options() const { return _options; }

    void setTarget(CaptureTarget target) { _options.target = target; }
    /// Choose the window to record and switch to window capture.
    void setWindow(size_t handle, string title, string process)
    {
        _options.windowHandle = handle;
        _options.windowTitle = title;
        _options.windowProcess = process;
        if (handle != 0) _options.target = CaptureTarget.window;
    }
    void setFps(int fps) { _options.fps = nearestPreset(fps, frameRatePresets); }
    void setQuality(int quality)
    {
        _options.quality = nearestPreset(quality, qualityPresets);
    }
    void setDrawCursor(bool value) { _options.drawCursor = value; }
    /// Experimental: notification-area icon on or off.
    void setTrayIcon(bool value) { _options.trayIcon = value; }
    void setAudioDevice(string device) { _options.audioDevice = device; }
    void setSystemAudio(bool value) { _options.systemAudio = value; }
    void setOutputFolder(string folder)
    {
        if (folder.length > 0) _options.outputFolder = folder;
    }


    string ffmpegPath() const { return _ffmpegPath; }

    /// A path next to the executable is portable; a PATH lookup is not.
    bool ffmpegAvailable() const { return _ffmpegPath.length > 0; }

    /// True while an encoder owns the screen.
    bool isRecording()
    {
        return _encoder !is null && _encoder.status.snapshot.active();
    }

    /// True while a worker (or its finalizer) still exists.
    bool hasEncoder() const { return _encoder !is null; }

    /// Empty until a recording finished; the latest finished file.
    string lastFinishedPath() const { return _lastFinishedPath; }

    /// One-line result of the last start/stop, for the status label.
    string lastMessage() const { return _lastMessage; }

    /**
     * Re-read the desktop geometry. Called at start and when a display
     * change is plausible (before every recording), so a rotated or resized
     * monitor is captured with the right size.
     */
    void refreshMonitors()
    {
        int x, y, width, height;
        virtualScreenBounds(x, y, width, height);
        MonitorInfo[] found;
        if (width > 0 && height > 0)
            found ~= MonitorInfo(x, y, width, height);
        _monitors = found;
    }

    /// The rectangle the configured target would capture right now.
    CaptureRect captureRect()
    {
        version (Windows)
        {
            if (_options.target == CaptureTarget.window)
            {
                import aurorarecorder.windowpicker : windowCaptureRect;
                const rect = windowCaptureRect(
                    cast(HWND) _options.windowHandle);
                return rect.valid() ? evenCaptureRect(rect) :
                    CaptureRect.init;
            }
        }
        int vx, vy, vw, vh;
        virtualScreenBounds(vx, vy, vw, vh);
        if (_monitors.length == 0 && vw > 0 && vh > 0)
            _monitors = [MonitorInfo(vx, vy, vw, vh)];
        return evenCaptureRect(resolveCaptureRect(_options.target, _monitors,
            vx, vy, vw, vh));
    }

    /**
     * Start recording. Returns false (and sets `lastMessage`) when ffmpeg is
     * missing, a recording is already running, or the output folder cannot be
     * created.
     */
    bool start(Timestamp now)
    {
        if (isRecording())
        {
            _lastMessage = "A recording is already running.";
            return false;
        }
        if (!ffmpegAvailable())
        {
            _lastMessage = "ffmpeg.exe was not found. Install FFmpeg or set " ~
                "AURORA_RECORDER_FFMPEG.";
            return false;
        }

        ensureFolder(_options.outputFolder);
        if (!folderIsDir(_options.outputFolder))
        {
            _lastMessage = "Could not create the recording folder " ~
                _options.outputFolder ~ ". Pick another folder with Change...";
            return false;
        }
        refreshMonitors();
        // A handle only survives while its window does. When it does not, the
        // stored window is treated as gone: re-finding it by title can land on
        // a different window (two windows may share a title), which recorded
        // the wrong application. The user is asked to choose again instead.
        version (Windows)
        {
            if (_options.target == CaptureTarget.window)
            {
                import aurorarecorder.windowpicker : lastRestoreActivated,
                    restoreForCapture, windowRecordable;
                if (!windowRecordable(cast(HWND) _options.windowHandle))
                {
                    _lastMessage = "The window to record was closed. Choose " ~
                        "it again with \"Choose window...\".";
                    return false;
                }
                // A minimised target sits off-screen and would record a
                // meaningless slice. Showing it without activating keeps the
                // game's own focus behaviour intact.
                if (!restoreForCapture(cast(HWND) _options.windowHandle))
                {
                    _lastMessage = "The window to record could not be shown " ~
                        "on screen; restore it and try again.";
                    return false;
                }
                if (lastRestoreActivated())
                    _lastMessage = "Brought the window to the front to record " ~
                        "it (it only un-minimises when active).";
            }
        }
        const rect = captureRect();
        if (!rect.valid())
        {
            _lastMessage = _options.target == CaptureTarget.window ?
                "The window to record is minimised or has no visible area." :
                "Could not determine the screen size to record.";
            return false;
        }

        const path = recordingPath(_options.outputFolder, now,
            (string candidate) => exists(candidate));
        RecordingJob job;
        job.outputPath = path;
        job.rect = rect;
        job.windowHandle = _options.target == CaptureTarget.window ?
            _options.windowHandle : 0;
        job.fps = _options.fps;
        job.quality = _options.quality;
        job.drawCursor = _options.drawCursor;
        job.audioDevice = _options.audioDevice;
        // A microphone and screen sound are alternatives in this UI; the
        // loopback format is filled in by the encoder once the device opens.
        job.systemAudio = _options.systemAudio && _options.audioDevice.length == 0;
        job.maxSeconds = maxRecordingSeconds + stopMarginSeconds;
        job.ffmpegPath = _ffmpegPath;

        _lastFinishedPath = "";
        _lastMessage = "Starting at " ~ format("%dx%d", rect.width,
            rect.height) ~ format(", %d fps...", _options.fps);
        _encoder = new ScreenEncoder(job);
        _finishedReported = false;
        _encoder.start();
        return true;
    }

    /// Stop the running recording; frames already captured are written.
    void stop()
    {
        if (_encoder is null) return;
        _encoder.stop();
        _lastMessage = "Finishing the file...";
    }

    /// Poll the encoder. Call once per UI tick.
    RecorderSnapshot poll()
    {
        RecorderSnapshot snapshot;
        snapshot.fps = _options.fps;
        snapshot.ffmpegAvailable = ffmpegAvailable();
        if (_encoder is null)
        {
            snapshot.phase = RecorderPhase.idle;
            snapshot.error = _lastMessage;
            return snapshot;
        }

        const status = _encoder.status.snapshot;
        snapshot.phase = status.phase;
        snapshot.frames = status.frames;
        snapshot.outputPath = status.outputPath;
        snapshot.error = status.error;

        if (status.phase == RecorderPhase.finished)
        {
            _lastFinishedPath = status.outputPath;
            _lastMessage = "Saved " ~ baseName(status.outputPath);
            // Keep the encoder for one more poll: the UI shows the result (and
            // the "finished" taskbar icon) from this snapshot, then `poll`
            // releases it on the next tick.
            if (_finishedReported) _encoder = null;
            else _finishedReported = true;
        }
        else if (status.phase == RecorderPhase.failed)
        {
            _lastMessage = status.error;
            _encoder = null;
            snapshot.phase = RecorderPhase.failed;
        }
        else if (status.active())
        {
            _lastMessage = "";
        }
        return snapshot;
    }

    /// Wait for a running encoder to exit before the process closes.
    void shutdown()
    {
        if (_encoder is null) return;
        _encoder.stop();
        _encoder.join(10_000);
        _encoder = null;
    }

    /// Default folder: `<Videos>\Aurora Recorder`, then Temp as a fallback.
    static string defaultOutputFolder()
    {
        version (Windows)
        {
            import core.sys.windows.shlobj : CSIDL_MYVIDEO, SHGetFolderPathW;
            import core.sys.windows.windef : MAX_PATH;
            wchar[MAX_PATH] buffer;
            if (SHGetFolderPathW(null, CSIDL_MYVIDEO, null, 0, buffer.ptr) == 0)
            {
                size_t length;
                while (length < buffer.length && buffer[length] != '\0')
                    length++;
                if (length > 0)
                {
                    import std.utf : toUTF8;
                    return buildPath(toUTF8(buffer[0 .. length]),
                        "Aurora Recorder");
                }
            }
        }
        return buildPath(tempDir(), "Aurora Recorder");
    }

    private static void ensureFolder(string folder)
    {
        if (folder.length == 0 || folderIsDir(folder)) return;
        try
        {
            mkdirRecurse(folder);
            if (folderIsDir(folder)) return;
        }
        catch (Exception)
        {
            // std.file cannot create every shell folder (the per-user Videos
            // directory fails with "cannot find the file specified"), so fall
            // back to the Win32 call before giving up.
        }
        version (Windows)
        {
            import core.sys.windows.windows : CreateDirectoryW, GetFileAttributesW;
            import std.utf : toUTF16z;
            // CreateDirectoryW only makes the last component, so build each
            // parent in turn.
            foreach (i; 0 .. folder.length)
            {
                if (folder[i] != '\\' && folder[i] != '/') continue;
                if (i < 3) continue; // drive root ("C:\")
                const prefix = folder[0 .. i];
                if (GetFileAttributesW(toUTF16z(prefix)) == 0xFFFFFFFF)
                    CreateDirectoryW(toUTF16z(prefix), null);
            }
            CreateDirectoryW(toUTF16z(folder), null);
        }
    }

    /// `isDir` that never throws (a missing or locked folder is "not a dir").
    private static bool folderIsDir(string folder)
    {
        try return isDir(folder);
        catch (Exception) return false;
    }
}

/// ffmpeg next to the recorder executable, or on PATH.
string locateFfmpeg(string executablePath)
{
    return findFfmpeg(executableDirectory(executablePath));
}

module aurorarecorder.app;

/**
 * Aurora Video Recorder - quick MP4 screen recording.
 *
 * One window, one button. Pick what to record (the whole desktop or the
 * primary monitor), a frame rate, a quality and a folder, then press Record.
 * Capture runs on a background thread while ffmpeg encodes H.264 into an MP4;
 * press Stop and the file is playable immediately.
 */

import aurora;

import aurorarecorder.encoder : RecorderPhase;
import aurorarecorder.recorder : RecorderController, RecorderOptions,
    RecorderSnapshot, locateFfmpeg;
import aurorarecorder.settings : CaptureTarget, formatClock, isPreset,
    recordedSeconds, Timestamp;

import std.format : format;
import std.datetime : Clock, LocalTime;
import std.string : startsWith;

// ---------------------------------------------------------------------------
// A row of mutually exclusive buttons (the framework has no radio group).
// ---------------------------------------------------------------------------

final class ChoiceRow : HBox
{
    void delegate(int value) onChange;
    private int[] _values;
    private Button[] _buttons;
    private int _selected;

    this(int[] values, string[] labels, int selected)
    {
        super(8);
        _values = values;
        _selected = selected;
        layoutHints().preferredHeight = 36;
        foreach (i, value; values)
        {
            auto button = new Button(labels[i]);
            button.layoutHints().flex = 1.0;
            button.layoutHints().preferredWidth = 90;
            button.onClick = () { select(value); };
            add(button);
            _buttons ~= button;
        }
        restyle();
    }

    int selected() const { return _selected; }

    void select(int value)
    {
        if (!isPreset(value, _values)) return;
        const changed = value != _selected;
        _selected = value;
        restyle();
        if (changed && onChange !is null) onChange(value);
    }

    override void setEnabled(bool value)
    {
        super.setEnabled(value);
        foreach (button; _buttons) button.setEnabled(value);
    }

    private void restyle()
    {
        foreach (i, value; _values)
        {
            _buttons[i].setAccent(value == _selected);
            _buttons[i].setEnabled(enabled());
        }
    }
}

// ---------------------------------------------------------------------------
// Window content
// ---------------------------------------------------------------------------

/**
 * The recorder panel. `poll` is called from the window's native tick; it
 * rewrites text only when the phase or the displayed second changes, so an
 * idle window does not repaint.
 */
final class RecorderRoot : VBox
{
    private RecorderController _controller;
    private GuiWindow _window;

    private Label _timer;
    private Label _targetHint;
    private Label _folderLabel;
    private Label _status;
    private Button _recordButton;
    private Button _playButton;
    private ChoiceRow _monitorRow;
    private ChoiceRow _fpsRow;
    private ChoiceRow _qualityRow;
    private CheckBox _cursorBox;

    // Last values painted, so a tick without a visible change is free.
    private RecorderPhase _shownPhase = RecorderPhase.idle;
    private string _shownTimer;
    private string _shownStatus;
    private string _shownTarget;
    private bool _shownCanPlay;

    this(GuiWindow window, RecorderController controller)
    {
        super(8, Insets(16));
        _window = window;
        _controller = controller;
        const options = _controller.options();

        auto title = new Label("Aurora Video Recorder");
        title.setScale(3);
        add(title);

        auto subtitle = new Label("Record your screen to an MP4 in two clicks.");
        subtitle.setColor(theme().textMuted);
        add(subtitle);

        auto actionRow = new HBox(10);
        actionRow.layoutHints().preferredHeight = 48;
        _recordButton = new Button("Record", IconKind.clock);
        _recordButton.setTextPixelSize(20);
        _recordButton.layoutHints().flex = 1.0;
        _recordButton.layoutHints().preferredWidth = 220;
        _recordButton.setAccent(true);
        _recordButton.onClick = &onRecordPressed;
        actionRow.add(_recordButton);
        add(actionRow);

        _timer = new Label("Ready");
        _timer.setPixelSize(34);
        _timer.setAlignment(HorizontalAlign.center);
        _timer.setColor(theme().text);
        _timer.layoutHints().preferredHeight = 52;
        add(_timer);

        _status = new Label("");
        _status.setColor(theme().textMuted);
        _status.layoutHints().preferredHeight = 44;
        add(_status);

        add(new Separator());

        // Settings are added to this VBox directly: a nested VBox has no
        // intrinsic height here and collapses to zero.
        add(new Label("Capture"));
        _monitorRow = new ChoiceRow(
            [cast(int) CaptureTarget.wholeScreen,
             cast(int) CaptureTarget.primaryMonitor],
            ["All monitors", "Primary monitor"], cast(int) options.target);
        _monitorRow.onChange = (int value) {
            _controller.setTarget(cast(CaptureTarget) value);
            refreshTarget();
        };
        add(_monitorRow);

        _targetHint = new Label("");
        _targetHint.setColor(theme().textMuted);
        add(_targetHint);

        add(new Label("Frame rate"));
        _fpsRow = new ChoiceRow([15, 24, 30, 60], ["15", "24", "30 fps", "60"],
            options.fps);
        _fpsRow.onChange = (int value) { _controller.setFps(value); };
        add(_fpsRow);

        add(new Label("Quality (high is sharper and larger)"));
        _qualityRow = new ChoiceRow([18, 23, 28], ["High", "Balanced", "Small"],
            options.quality);
        _qualityRow.onChange = (int value) { _controller.setQuality(value); };
        add(_qualityRow);

        _cursorBox = new CheckBox("Draw the mouse cursor in the video",
            options.drawCursor);
        _cursorBox.onChanged = (bool value) { _controller.setDrawCursor(value); };
        add(_cursorBox);

        add(new Separator());

        auto folderRow = new HBox(10);
        folderRow.layoutHints().preferredHeight = 36;
        _folderLabel = new Label("");
        _folderLabel.setColor(theme().textMuted);
        _folderLabel.layoutHints().flex = 1.0;
        folderRow.add(_folderLabel);
        auto changeButton = new Button("Change...", IconKind.folder);
        changeButton.onClick = &onChangeFolder;
        folderRow.add(changeButton);
        add(folderRow);

        auto openRow = new HBox(10);
        openRow.layoutHints().preferredHeight = 38;
        auto openFolderButton = new Button("Open folder", IconKind.folder);
        openFolderButton.layoutHints().flex = 1.0;
        openFolderButton.onClick = () {
            openInShell(_controller.options().outputFolder);
        };
        openRow.add(openFolderButton);
        _playButton = new Button("Play last", IconKind.music);
        _playButton.layoutHints().flex = 1.0;
        _playButton.setEnabled(false);
        _playButton.onClick = () {
            if (_controller.lastFinishedPath.length > 0)
                openInShell(_controller.lastFinishedPath);
        };
        openRow.add(_playButton);
        add(openRow);

        refreshFolder();
        refreshTarget();
        refreshTheme();
        applyStatus(_controller.poll(), true);
    }

    /**
     * Apply theme colors. `theme()` only resolves once the widget is attached
     * to a window, so this runs again from the entry point after setRoot().
     */
    void refreshTheme()
    {
        _timer.setColor(_shownPhase == RecorderPhase.recording ?
            theme().accent : theme().text);
        _status.setColor(_shownPhase == RecorderPhase.failed ?
            theme().danger : theme().textMuted);
        _targetHint.setColor(theme().textMuted);
        _folderLabel.setColor(theme().textMuted);
    }

    /// Called from the window tick. Cheap when nothing is recording.
    void poll()
    {
        if (!_controller.hasEncoder())
        {
            // One final refresh after the encoder finished on its own.
            if (_controller.isRecording())
                applyStatus(_controller.poll());
            return;
        }
        applyStatus(_controller.poll());
    }

    private void applyStatus(RecorderSnapshot snapshot, bool force = false)
    {
        const active = snapshot.phase == RecorderPhase.starting ||
            snapshot.phase == RecorderPhase.recording ||
            snapshot.phase == RecorderPhase.stopping;
        const phaseChanged = force || snapshot.phase != _shownPhase;
        _shownPhase = snapshot.phase;

        if (phaseChanged)
        {
            _recordButton.setText(active ? "Stop" : "Record");
            _recordButton.setIcon(active ? IconKind.power : IconKind.clock);
            _recordButton.setAccent(!active);
            _monitorRow.setEnabled(!active);
            _fpsRow.setEnabled(!active);
            _qualityRow.setEnabled(!active);
            _cursorBox.setEnabled(!active);
            _recordButton.setEnabled(snapshot.ffmpegAvailable || active);
            _timer.setColor(snapshot.phase == RecorderPhase.recording ?
                theme().accent : theme().text);
        }

        // Timer: rewritten only when the displayed second changes.
        const timer = timerTextFor(snapshot);
        if (force || timer != _shownTimer)
        {
            _shownTimer = timer;
            _timer.setText(timer);
        }

        const status = statusTextFor(snapshot);
        if (force || status != _shownStatus)
        {
            _shownStatus = status;
            _status.setText(status);
            _status.setColor(snapshot.phase == RecorderPhase.failed ?
                theme().danger : theme().textMuted);
        }

        const canPlay = _controller.lastFinishedPath.length > 0;
        if (force || canPlay != _shownCanPlay)
        {
            _shownCanPlay = canPlay;
            _playButton.setEnabled(canPlay);
        }
    }

    private static string timerTextFor(RecorderSnapshot snapshot)
    {
        if (snapshot.phase == RecorderPhase.recording ||
            snapshot.phase == RecorderPhase.starting)
            return formatClock(recordedSeconds(snapshot.frames, snapshot.fps));
        return "Ready";
    }

    private string statusTextFor(RecorderSnapshot snapshot)
    {
        switch (snapshot.phase)
        {
            case RecorderPhase.starting:
                return "Starting ffmpeg...";
            case RecorderPhase.recording:
                return format("Recording at %d fps to %s.", snapshot.fps,
                    snapshot.outputPath);
            case RecorderPhase.stopping:
                return "Finishing the file...";
            case RecorderPhase.finished:
                return "Saved " ~ snapshot.outputPath;
            case RecorderPhase.failed:
                return snapshot.error.length > 0 ? snapshot.error :
                    "Recording failed.";
            default:
                if (!snapshot.ffmpegAvailable)
                    return "ffmpeg.exe was not found. Install FFmpeg " ~
                        "(winget install Gyan.FFmpeg) or set " ~
                        "AURORA_RECORDER_FFMPEG to the ffmpeg.exe path.";
                return _controller.lastMessage.length > 0 ?
                    _controller.lastMessage : "Ready to record.";
        }
    }

    private void refreshTarget()
    {
        const rect = _controller.captureRect();
        const text = rect.valid() ?
            format("%d x %d video, H.264 MP4", rect.width, rect.height) :
            "Screen size could not be determined.";
        if (text != _shownTarget)
        {
            _shownTarget = text;
            _targetHint.setText(text);
        }
    }

    private void refreshFolder()
    {
        _folderLabel.setText(_controller.options().outputFolder);
    }

    // ---- Actions ----

    private void onRecordPressed()
    {
        if (_controller.isRecording())
        {
            _controller.stop();
            applyStatus(_controller.poll(), true);
            return;
        }
        if (!_controller.start(currentTimestamp()))
        {
            _status.setText(_controller.lastMessage());
            _status.setColor(theme().danger);
            return;
        }
        applyStatus(_controller.poll(), true);
    }

    private void onChangeFolder()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.save;
        options.title = "Choose where recordings are saved";
        options.initialPath = _controller.options().outputFolder;
        options.acceptLabel = "Use folder";
        options.selectFolders = true;
        string path;
        if (!runFileDialogWindow(_window, options, path))
            return;
        _controller.setOutputFolder(path);
        refreshFolder();
    }
}

/// Local wall-clock time for the default file name.
Timestamp currentTimestamp()
{
    const now = Clock.currTime(LocalTime());
    Timestamp stamp;
    stamp.year = now.year;
    stamp.month = now.month;
    stamp.day = now.day;
    stamp.hour = now.hour;
    stamp.minute = now.minute;
    stamp.second = now.second;
    return stamp;
}

/// Open a file or folder with its registered application.
void openInShell(string path)
{
    version (Windows)
    {
        import core.sys.windows.shellapi : ShellExecuteW;
        import std.utf : toUTF16z;
        if (path.length == 0) return;
        ShellExecuteW(null, toUTF16z("open"), toUTF16z(path), null, null, 1);
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

private WindowOptions recorderWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora Video Recorder";
    options.width = 580;
    // Fits a 1080p work area (taskbar visible) without being resized.
    options.height = 860;
    options.resizable = false;
    options.decorated = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.enableFullscreenShortcut = false;
    return options;
}

private string folderArgument(string[] args)
{
    foreach (arg; args[1 .. $])
    {
        if (arg.startsWith("--folder="))
            return arg["--folder=".length .. $];
    }
    return "";
}

int run(string[] args, string executablePath = "")
{
    RecorderOptions options;
    options.outputFolder = folderArgument(args);
    RecorderController.normalizeOptions(options);

    auto window = new GuiWindow(recorderWindowOptions(), Theme.dark());
    auto controller = new RecorderController(options,
        locateFfmpeg(executablePath));
    auto root = new RecorderRoot(window, controller);
    window.setRoot(root);
    root.refreshTheme(); // Colors resolve once the widget is attached.
    window.applicationService = (double delta) { root.poll(); };
    window.onCloseRequested = () {
        controller.shutdown();
        return true;
    };

    const code = window.run();
    controller.shutdown();
    return code;
}

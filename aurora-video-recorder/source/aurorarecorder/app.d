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
import aurorarecorder.audio : AudioDevice, listAudioDevices;
import aurorarecorder.ffmpeg : executableDirectory;
import aurorarecorder.hotkey : GlobalHotkey, HotkeyChord, HotkeyResult,
    chordFromText, defaultHotkey, describeHotkey, hotkeyAlt, hotkeyControl,
    hotkeyErrorAlreadyRegistered, hotkeyKeyAllowed, hotkeyShift, hotkeyWin;
import aurorarecorder.recorder : RecorderController, RecorderOptions,
    RecorderSnapshot, locateFfmpeg;
import aurorarecorder.settings : CaptureTarget, formatClock, isPreset,
    recordedSeconds, Timestamp;
import aurorarecorder.settingsfile : loadSettings, saveSettings, settingsPath;

import std.datetime : Clock, LocalTime;
import std.format : format;
import std.file : exists;
import std.path : buildPath;
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
    private CheckBox _systemAudioBox;
    private Button _microphoneButton;
    private Label _microphoneHint;
    private AudioDevice[] _microphones;
    private Button _hotkeyButton;
    private Button _hotkeyClearButton;
    private Label _hotkeyHint;

    /// Global start/stop chord; null when the user turned it off.
    private GlobalHotkey _hotkey;
    private HotkeyChord _chord = defaultHotkey;
    private bool _capturingChord;
    /// Settings written on every change ("" disables persistence).
    private string _settingsFile;

    // Last values painted, so a tick without a visible change is free.
    private RecorderPhase _shownPhase = RecorderPhase.idle;
    private string _shownTimer;
    private string _shownStatus;
    private string _shownTarget;
    private bool _shownCanPlay;
    private string _shownIcon;

    this(GuiWindow window, RecorderController controller,
        GlobalHotkey hotkey, HotkeyChord chord, string settingsFile)
    {
        super(5, Insets(12));
        _window = window;
        _controller = controller;
        _hotkey = hotkey;
        _chord = chord;
        _settingsFile = settingsFile;
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
        // flex only grows the button horizontally; without a height hint it
        // stretched over the whole free column.
        _recordButton.layoutHints().preferredHeight = 48;
        _recordButton.setAccent(true);
        _recordButton.onClick = &onRecordPressed;
        actionRow.add(_recordButton);
        add(actionRow);

        _timer = new Label("Ready");
        _timer.setPixelSize(34);
        _timer.setAlignment(HorizontalAlign.center);
        _timer.setColor(theme().text);
        _timer.layoutHints().preferredHeight = 40;
        add(_timer);

        _status = new Label("");
        _status.setColor(theme().textMuted);
        _status.layoutHints().preferredHeight = 30;
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

        // Screen sound is what makes a recording of a video/video call audible.
        _systemAudioBox = new CheckBox(
            "Record the sound playing on this PC (screen audio)",
            options.systemAudio);
        _systemAudioBox.onChanged = (bool value) {
            _controller.setSystemAudio(value);
            saveCurrentSettings();
        };
        add(_systemAudioBox);

        // ---- Microphone ----
        add(new Label("Microphone"));
        auto microphoneRow = new HBox(10);
        microphoneRow.layoutHints().preferredHeight = 36;
        _microphoneButton = new Button("", IconKind.music);
        _microphoneButton.layoutHints().flex = 1.0;
        _microphoneButton.onClick = &onMicrophoneButton;
        microphoneRow.add(_microphoneButton);
        auto noMicrophoneButton = new Button("Off");
        noMicrophoneButton.onClick = () {
            _controller.setAudioDevice("");
            refreshMicrophoneText();
            saveCurrentSettings();
        };
        microphoneRow.add(noMicrophoneButton);
        add(microphoneRow);

        // The hint shares the row area of the hotkey hint below; both are
        // short enough that the panel still fits the window.
        _microphoneHint = new Label("");
        _microphoneHint.setColor(theme().textMuted);
        _microphoneHint.layoutHints().preferredHeight = 26;
        add(_microphoneHint);

        // ---- Start/stop hotkey ----
        add(new Label("Start/stop hotkey"));
        auto hotkeyRow = new HBox(10);
        hotkeyRow.layoutHints().preferredHeight = 36;
        _hotkeyButton = new Button("");
        _hotkeyButton.layoutHints().flex = 1.0;
        _hotkeyButton.layoutHints().preferredWidth = 180;
        _hotkeyButton.onClick = &onHotkeyButton;
        hotkeyRow.add(_hotkeyButton);
        _hotkeyClearButton = new Button("Off");
        _hotkeyClearButton.onClick = () {
            setChord(HotkeyChord.init);
        };
        hotkeyRow.add(_hotkeyClearButton);
        add(hotkeyRow);

        _hotkeyHint = new Label("");
        _hotkeyHint.setColor(theme().textMuted);
        _hotkeyHint.layoutHints().preferredHeight = 26;
        add(_hotkeyHint);

        refreshHotkeyText();

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
            // Select the finished recording when there is one; Explorer then
            // highlights it instead of just showing the folder contents.
            openFolderSelecting(_controller.options().outputFolder,
                _controller.lastFinishedPath);
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
        _hotkeyHint.setColor(theme().textMuted);
    }

    /// Called from the window tick. Cheap when nothing is recording.
    void poll()
    {
        // A hotkey press toggles recording exactly like the button.
        if (_hotkey !is null && _hotkey.takePressed())
            onRecordPressed();

        if (!_controller.hasEncoder())
        {
            // One final refresh after the encoder finished on its own, so the
            // result and the taskbar "finished" icon are not skipped.
            if (_shownPhase == RecorderPhase.starting ||
                _shownPhase == RecorderPhase.recording ||
                _shownPhase == RecorderPhase.stopping)
                applyStatus(_controller.poll(), true);
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
            _systemAudioBox.setEnabled(!active);
            _recordButton.setEnabled(snapshot.ffmpegAvailable || active);
            _timer.setColor(snapshot.phase == RecorderPhase.recording ?
                theme().accent : theme().text);
            // The taskbar button and title bar show idle / recording / done.
            updateTaskbarState(snapshot.phase);
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

    // ---- Start/stop hotkey ----

    /// Cycle "No microphone" -> each device -> back, and save the choice.
    private void onMicrophoneButton()
    {
        const current = _controller.options().audioDevice;
        string next;
        if (current.length == 0)
        {
            if (_microphones.length > 0) next = _microphones[0].name;
        }
        else
        {
            bool found;
            foreach (device; _microphones)
            {
                if (found)
                {
                    next = device.name;
                    break;
                }
                if (device.name == current) found = true;
            }
        }
        _controller.setAudioDevice(next);
        _microphoneHint.setText("");
        refreshMicrophoneText();
        saveCurrentSettings();
    }

    /// The chord button either starts capture ("Press a key combination") or
    /// cancels capture.
    private void onHotkeyButton()
    {
        if (_capturingChord)
        {
            setCapturing(false);
            return;
        }
        setCapturing(true);
        _hotkeyButton.setText("Press a key combination...");
        _hotkeyHint.setText("Use Ctrl, Alt or Win plus a letter or digit, " ~
            "or a function key. Esc cancels.");
        _hotkeyButton.requestFocus();
    }

    private void setCapturing(bool value)
    {
        _capturingChord = value;
        if (!value) refreshHotkeyText();
    }

    /// Keyboard hook from the panel: capture the chord while the button is
    /// waiting, otherwise leave the key for the rest of the UI.
    override bool onKeyDown(ref Event event)
    {
        if (!_capturingChord) return super.onKeyDown(event);

        if (event.key == Key.escape)
        {
            setCapturing(false);
            return true;
        }

        uint modifiers;
        if (event.control) modifiers |= hotkeyControl;
        if (event.alt) modifiers |= hotkeyAlt;
        if (event.shift) modifiers |= hotkeyShift;
        if (event.meta) modifiers |= hotkeyWin;

        const virtualKey = virtualKeyFromKey(event.key);
        if (virtualKey == 0) return true; // modifier or unhandled printable
        if (!hotkeyKeyAllowed(virtualKey, modifiers))
        {
            _hotkeyHint.setText("That combination needs Ctrl, Alt or Win " ~
                "before a letter or digit (or use a function key).");
            return true;
        }

        setCapturing(false);
        setChord(HotkeyChord(modifiers, virtualKey));
        return true;
    }

    /// Register `chord`, show it and save the setting.
    private void setChord(HotkeyChord chord)
    {
        HotkeyResult result;
        if (_hotkey !is null)
            result = _hotkey.apply(chord);
        else
            result.ok = !chord.valid();

        if (!result.ok)
        {
            _chord = chord;
            refreshHotkeyText();
            _hotkeyHint.setText(result.error == hotkeyErrorAlreadyRegistered ?
                "That combination is already used by another application." :
                "Windows refused that combination.");
            _hotkeyHint.setColor(theme().danger);
            return;
        }

        _chord = chord;
        refreshHotkeyText();
        if (chord.valid())
            _hotkeyHint.setText("Press " ~ describeHotkey(chord) ~
                " anywhere to start or stop recording.");
        else
            _hotkeyHint.setText("No global hotkey; use the Record button.");
        _hotkeyHint.setColor(theme().textMuted);
        saveCurrentSettings();
    }

    private void refreshHotkeyText()
    {
        _hotkeyButton.setText(describeHotkey(_chord));
    }

    // ---- Microphone ----

    /// Pick up the device list (once, at start-up) and show the current choice.
    void loadMicrophones(string ffmpegPath)
    {
        _microphones = listAudioDevices(ffmpegPath);
        const current = _controller.options().audioDevice;
        if (current.length > 0)
        {
            bool known;
            foreach (device; _microphones)
                if (device.name == current) known = true;
            if (!known)
            {
                // A saved device is unplugged: keep recording video only
                // rather than failing at start.
                _controller.setAudioDevice("");
                _microphoneHint.setText("The saved microphone was not found; " ~
                    "recording without sound.");
            }
        }
        refreshMicrophoneText();
    }

    private void refreshMicrophoneText()
    {
        const current = _controller.options().audioDevice;
        _microphoneButton.setText(current.length > 0 ? current :
            "No microphone");
        if (_microphoneHint.text().length == 0)
        {
            _microphoneHint.setText(_microphones.length == 0 ?
                "No microphone was found; recordings are silent." :
                "Click to switch microphone; sound is recorded with the video.");
        }
    }

    /// Swap the window/taskbar icon for the current recorder state.
    private void updateTaskbarState(RecorderPhase phase)
    {
        const name = phase == RecorderPhase.recording ||
            phase == RecorderPhase.starting ? "icon-recording.ico" :
            phase == RecorderPhase.finished ? "icon-stopped.ico" : "icon.ico";
        // Finished keeps its green "done" icon until the next recording
        // starts; only an explicit reset returns to the idle look.
        if (phase == RecorderPhase.idle && _shownIcon == "icon-stopped.ico")
            return;
        if (name == _shownIcon) return;
        const path = iconPathFor(name);
        if (path.length == 0 || !_window.setIconPath(path)) return;
        _shownIcon = name;
    }

    /// Apply the stored chord once the window is live, and report a refusal.
    void registerHotkey()
    {
        const result = _hotkey is null ? HotkeyResult(!_chord.valid(), 0) :
            _hotkey.apply(_chord);
        if (result.ok)
        {
            _hotkeyHint.setText(_chord.valid() ?
                "Press " ~ describeHotkey(_chord) ~
                    " anywhere to start or stop recording." :
                "No global hotkey; use the Record button.");
            return;
        }
        // A saved chord can be taken by another application between runs.
        _hotkeyHint.setText(result.error == hotkeyErrorAlreadyRegistered ?
            "The saved hotkey is already used by another application." :
            "The saved hotkey could not be registered.");
        _hotkeyHint.setColor(theme().danger);
    }

    private void saveCurrentSettings()
    {
        if (_settingsFile.length == 0) return;
        const options = _controller.options();
        saveSettings(_settingsFile, options, _chord);
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

/**
 * Win32 virtual-key code for a key press detected by the panel. Modifier keys
 * themselves map to 0: they are read from the event, never captured as the
 * hotkey's key.
 */
uint virtualKeyFromKey(Key key) @safe pure nothrow
{
    // letter/digit keys are contiguous in `Key` and in Win32's A..Z, 0..9.
    if (key >= Key.a && key <= Key.z)
        return 0x41 + (cast(uint) key - cast(uint) Key.a);
    if (key >= Key.digit0 && key <= Key.digit9)
        return 0x30 + (cast(uint) key - cast(uint) Key.digit0);
    if (key >= Key.f1 && key <= Key.f12)
        return 0x70 + (cast(uint) key - cast(uint) Key.f1);

    switch (key)
    {
        case Key.space: return 0x20;
        case Key.pageUp: return 0x21;
        case Key.pageDown: return 0x22;
        case Key.end: return 0x23;
        case Key.home: return 0x24;
        case Key.left: return 0x25;
        case Key.up: return 0x26;
        case Key.right: return 0x27;
        case Key.down: return 0x28;
        case Key.insert: return 0x2D;
        case Key.deleteKey: return 0x2E;
        default: return 0;
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

/**
 * Open `folder` in Explorer with `file` selected and scrolled into view.
 *
 * `explorer.exe /select,"<path>"` is the documented way to do this. Plainly
 * opening the folder only shows its contents, which is why the finished
 * recording was not highlighted before.
 */
void openFolderSelecting(string folder, string file)
{
    version (Windows)
    {
        import std.file : exists;
        import core.sys.windows.shellapi : ShellExecuteW;
        import std.utf : toUTF16z;
        // Selecting needs the file to exist. When there is no finished
        // recording yet (or it was deleted) just open the folder, so the
        // button never does nothing.
        if (file.length > 0 && exists(file))
        {
            const arguments = "/select," ~ quoteForExplorer(file);
            ShellExecuteW(null, toUTF16z("open"), toUTF16z("explorer.exe"),
                toUTF16z(arguments), toUTF16z(folder), 1);
            return;
        }
        openInShell(folder);
    }
}

/// Wrap a path for `explorer.exe /select,` so spaces and commas survive.
private string quoteForExplorer(string path)
{
    return "\"" ~ path ~ "\"";
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

private WindowOptions recorderWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora Video Recorder";
    // Shown before the first frame paints; the state icons replace it later.
    options.iconPath = iconPathFor("icon.ico");
    // The panel lays out at ~720 logical pixels wide; a narrower window would
    // clip the right-hand buttons (the click target would fall outside it).
    // The panel's rows lay out at ~720 logical pixels; a narrower window clips
    // the right-hand controls (and their click targets).
    options.width = 760;

    options.height = 856;
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

/// Folder holding the ICO assets, next to the executable.
private __gshared string g_assetFolder;

/// Full path of an icon in the asset folder; "" when it is not there.
private string iconPathFor(string name)
{
    if (g_assetFolder.length == 0) return "";
    const path = buildPath(g_assetFolder, name);
    return exists(path) ? path : "";
}

int run(string[] args, string executablePath = "")
{
    g_assetFolder = buildPath(executableDirectory(executablePath), "assets");
    // Settings live next to the executable so a portable copy keeps them.
    const settingsFile = settingsPath(executableDirectory(executablePath));

    RecorderOptions options;
    options.outputFolder = folderArgument(args);
    RecorderController.normalizeOptions(options);
    auto stored = loadSettings(settingsFile, options);
    auto settings = stored.options;
    if (options.outputFolder.length > 0)
        settings.outputFolder = options.outputFolder; // command line wins
    const chord = stored.hasHotkey ? stored.hotkey : defaultHotkey;

    auto window = new GuiWindow(recorderWindowOptions(), Theme.dark());
    auto controller = new RecorderController(settings,
        locateFfmpeg(executablePath));
    // The hotkey thread only records the press; the panel tick acts on it.
    auto hotkey = new GlobalHotkey(null);
    auto root = new RecorderRoot(window, controller, hotkey, chord,
        settingsFile);
    window.setRoot(root);
    root.refreshTheme(); // Colors resolve once the widget is attached.
    root.registerHotkey(); // After setRoot so the result can be shown.
    root.loadMicrophones(controller.ffmpegPath());
    window.applicationService = (double delta) { root.poll(); };
    window.onCloseRequested = () {
        hotkey.shutdown();
        controller.shutdown();
        return true;
    };

    const code = window.run();
    hotkey.shutdown();
    controller.shutdown();
    return code;
}

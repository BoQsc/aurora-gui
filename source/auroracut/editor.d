module auroracut.editor;

import aurora;
import auroracut.appversion : appDisplayName;
import auroracut.exporter : ExportClip, ExportJob, ExportKind, ExportPreset,
    ExportRequest, compositeAudioArguments, compositeStreamArguments;
import auroracut.filedialog : FileDialogController;
import auroracut.media : MediaImportResult, MediaImportService, ToolStatus,
    inspectToolStatus, mediaSecondaryText;
import auroracut.model : ClipKind, EditorModel, EffectProperty, KeyframeInterpolation,
    MediaAsset, TextAlignment, TimelineClip, TimelineTrack, TrackAddress,
    TrackKind, textAlignmentLabel;
import auroracut.playback : PcmAudioPlayer, PlaybackWorkerStats, VideoFrameStream;
import auroracut.preview : PreviewFrame, PreviewService,
    PreviewServiceStats, PreviewWidget;
import auroracut.project : loadProjectFile, saveProjectFile;
import auroracut.recentprojects : clearRecentProjects,
    clearUnavailableRecentProjects, loadRecentProjects, rememberRecentProject;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;
import auroracut.titlelayer : TitleVisual;
import auroracut.textfonts : canonicalTextFontName, textFontFamilies,
    textFontFilePath;
import auroracut.util : absoluteNormalized, appLog, applicationCacheDirectory, clampValue,
    formatTimecode, isSupportedMediaPath, outputTail, unnamedProjectAutosavePath;
import core.time : MonoTime;
import std.file : exists;
import std.conv : ConvException, to;
import std.format : format;
import std.math : PI, cos, fabs, log10, pow, sin;
import std.path : baseName, buildPath, dirName, filenameCmp;
import std.process : Config, spawnProcess;
import std.string : strip;

private enum JobPurpose : ubyte
{
    none,
    exportFile,
    previewTimeline
}

private enum PlaybackKind : ubyte
{
    none,
    source,
    sequence
}

private enum PlaybackPerformance : ubyte
{
    responsive,
    balanced,
    fidelity
}

private enum PendingPreviewKind : ubyte
{
    none,
    asset,
    sequence
}

private enum int mp4CompressionMinCrf = 18;
private enum int mp4CompressionMaxCrf = 32;
private enum int mp4CompressionDefaultCrf = 20;

private double gainToDb(double gain)
{
    if (gain <= 0.001) return -60.0;
    const value = 20.0 * log10(gain);
    return clampValue(value, -60.0, 12.0);
}

private double dbToGain(double db)
{
    if (db <= -59.999) return 0.0;
    return clampValue(pow(10.0, db / 20.0), 0.0, 4.0);
}

private string formatDb(double db)
{
    if (db <= -59.999) return "−∞ dB";
    return format("%+.1f dB", db);
}

private int hexDigit(char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

private bool parseArgb(string source, out uint value)
{
    auto text = strip(source);
    if (text.length > 0 && text[0] == '#') text = text[1 .. $];
    if (text.length != 6 && text.length != 8) return false;
    uint parsed;
    foreach (character; text)
    {
        const digit = hexDigit(character);
        if (digit < 0) return false;
        parsed = (parsed << 4) | cast(uint) digit;
    }
    value = text.length == 6 ? 0xff000000u | parsed : parsed;
    return true;
}

private string formatArgb(uint value)
{
    if ((value >> 24) == 0xff) return format("#%06X", value & 0x00ffffff);
    return format("#%08X", value);
}

private struct TimelineSnapshot
{
    TimelineTrack[] video;
    TimelineTrack[] audio;
    TrackAddress selectedTrack;
    int selectedIndex;
    double playhead = 0.0;
    string label;
}

private struct PendingTimelineDrop
{
    string path;
    TrackAddress track;
    double start;
}

/** Project-media list with an internal drag gesture routed to the timeline. */
private final class ProjectMediaList : ListView
{
    private bool _pressed;
    private bool _dragging;
    private int _pressIndex = -1;
    private Point _pressPosition;
    private int _pressClickCount;

    void delegate(int index, Point globalPosition) onContextMenuRequested;
    void delegate(int index, Point globalPosition) onDragStarted;
    bool delegate(int index, Point globalPosition) onDragUpdated;
    void delegate(int index, Point globalPosition, bool commit) onDragFinished;

    bool dragging() const @safe pure nothrow @nogc { return _dragging; }

    /** Re-clicking an already selected bin item still makes Project Media the
     * active source context after the user previously selected a timeline clip. */
    private void selectAndSignal(int index)
    {
        const alreadySelected = selectedIndex() == index;
        setSelectedIndex(index);
        if (alreadySelected && onSelectionChanged !is null)
            onSelectionChanged(index);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            requestFocus();
            const index = indexAt(event.position);
            if (index >= 0) selectAndSignal(index);
            if (onContextMenuRequested !is null)
                onContextMenuRequested(index, event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;

        requestFocus();
        const index = indexAt(event.position);
        if (index < 0 || index >= cast(int) items().length ||
            items()[cast(size_t) index].disabled)
            return true;
        selectAndSignal(index);
        _pressed = true;
        _dragging = false;
        _pressIndex = index;
        _pressPosition = event.position;
        _pressClickCount = event.clickCount;
        captureMouse();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_pressed) return super.onMouseMove(event);
        if (!_dragging)
        {
            const dx = event.position.x - _pressPosition.x;
            const dy = event.position.y - _pressPosition.y;
            if (dx * dx + dy * dy >= 25)
            {
                _dragging = true;
                if (onDragStarted !is null)
                    onDragStarted(_pressIndex, event.globalPosition);
            }
        }
        if (_dragging)
        {
            const accepted = onDragUpdated !is null &&
                onDragUpdated(_pressIndex, event.globalPosition);
            setCursor(accepted ? CursorKind.move : CursorKind.forbidden);
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pressed) return false;
        const wasDragging = _dragging;
        const index = _pressIndex;
        const clickCount = _pressClickCount;
        _pressed = false;
        _dragging = false;
        _pressIndex = -1;
        releaseMouse();
        setCursor(CursorKind.arrow);

        if (wasDragging)
        {
            if (onDragFinished !is null)
                onDragFinished(index, event.globalPosition, true);
        }
        else if (clickCount >= 2 && onActivated !is null)
            onActivated(index);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape && _pressed)
        {
            const index = _pressIndex;
            _pressed = false;
            const wasDragging = _dragging;
            _dragging = false;
            _pressIndex = -1;
            releaseMouse();
            setCursor(CursorKind.arrow);
            if (wasDragging && onDragFinished !is null)
                onDragFinished(index, event.globalPosition, false);
            return true;
        }
        return super.onKeyDown(event);
    }
}

/** Native Windows Explorer drops bubble here from every Project Media child. */
private final class ProjectMediaPanel : VBox
{
    void delegate(string[] paths) onMediaDropped;

    this()
    {
        super(7, Insets(9));
    }

    override bool onFilesDropped(ref Event event)
    {
        if (onMediaDropped !is null) onMediaDropped(event.paths);
        return true;
    }
}

/** Compact numeric property field.
 *
 * Click to type an exact value. Click-hold and drag horizontally to scrub the
 * value immediately. This replaces the long anonymous Inspector sliders while
 * keeping continuous-edit undo grouping and per-item keyframe behavior.
 */
final class InspectorValueField : TextField
{
    private double _minimum;
    private double _maximum;
    private double _value;
    private double _pressValue;
    private Point _pressPoint;
    private bool _pointerDown;
    private bool _scrubbing;
    private bool _editing;
    private bool _textDirty;
    private bool _programmaticText;
    private string _lastDisplay;

    void delegate() onEditStarted;
    void delegate() onEditEnded;
    void delegate(double value) onValueChanged;

    this(double minimum, double maximum, double value)
    {
        super("");
        _minimum = minimum;
        _maximum = maximum;
        layoutHints().minWidth = 62;
        layoutHints().preferredWidth = 76;
        layoutHints().minHeight = 22;
        layoutHints().preferredHeight = 22;
        setPadding(4);
        onChanged = delegate() {
            if (!_programmaticText && !_scrubbing) _textDirty = true;
        };
        onSubmitted = delegate() { commitTypedValue(); };
        _value = clampValue(value, _minimum, _maximum);
        setText(format("%.3g", _value), false);
    }

    double value() const @safe pure nothrow @nogc { return _value; }

    void setRange(double minimum, double maximum)
    {
        if (maximum < minimum) maximum = minimum;
        _minimum = minimum;
        _maximum = maximum;
        _value = clampValue(_value, _minimum, _maximum);
    }

    override void setText(string value, bool notify = false)
    {
        _programmaticText = true;
        super.setText(value, false);
        _programmaticText = false;
        _lastDisplay = value;
        _textDirty = false;
    }

    void setValue(double value, bool notify = true)
    {
        const next = clampValue(value, _minimum, _maximum);
        const changed = fabs(next - _value) >= 0.000_000_5;
        _value = next;
        if (notify && (changed || _textDirty) && onValueChanged !is null)
            onValueChanged(_value);
    }

    private void beginEdit()
    {
        if (_editing || !enabled()) return;
        _editing = true;
        if (onEditStarted !is null) onEditStarted();
    }

    private void endEdit()
    {
        if (!_editing) return;
        _editing = false;
        if (onEditEnded !is null) onEditEnded();
    }

    private bool parseTypedValue(out double result)
    {
        const source = strip(textUtf8());
        if (source.length == 0) return false;
        char[] numeric;
        numeric.reserve(source.length);
        foreach (character; source)
        {
            if ((character >= '0' && character <= '9') || character == '.' ||
                character == '-' || character == '+' || character == 'e' ||
                character == 'E')
                numeric ~= character;
        }
        if (numeric.length == 0 || numeric == "+" || numeric == "-") return false;
        try
        {
            result = to!double(numeric);
            foreach (character; source)
                if (character == '%') { result /= 100.0; break; }
            result = clampValue(result, _minimum, _maximum);
            return true;
        }
        catch (ConvException)
        {
            return false;
        }
    }

    private void commitTypedValue()
    {
        if (!_textDirty) return;
        double parsed;
        if (!parseTypedValue(parsed))
        {
            setText(_lastDisplay, false);
            return;
        }
        beginEdit();
        const previousDisplay = _lastDisplay;
        setValue(parsed, true);
        // The selected property callback normally installs its formatted unit
        // text. If the value was unchanged, restore the last canonical display.
        if (_textDirty) setText(previousDisplay, false);
        endEdit();
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left) return false;
        _pointerDown = true;
        _scrubbing = false;
        _pressPoint = event.position;
        _pressValue = _value;
        return super.onMouseDown(event);
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_pointerDown) return super.onMouseMove(event);
        const dx = event.position.x - _pressPoint.x;
        if (!_scrubbing && (dx >= 3 || dx <= -3))
        {
            _scrubbing = true;
            beginEdit();
            setCursor(CursorKind.resizeHorizontal);
        }
        if (_scrubbing)
        {
            const range = _maximum - _minimum;
            const sensitivity = range > 0.0 ? range / 500.0 : 0.01;
            const fine = event.shift() ? 0.1 : 1.0;
            setValue(_pressValue + cast(double) dx * sensitivity * fine, true);
            return true;
        }
        return super.onMouseMove(event);
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pointerDown)
            return super.onMouseUp(event);
        const wasScrubbing = _scrubbing;
        _pointerDown = false;
        _scrubbing = false;
        const handled = super.onMouseUp(event);
        setCursor(CursorKind.text);
        if (wasScrubbing) endEdit();
        return handled;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape && _textDirty)
        {
            setText(_lastDisplay, false);
            return true;
        }
        return super.onKeyDown(event);
    }

    protected override void onFocusChanged(bool focused)
    {
        super.onFocusChanged(focused);
        if (!focused)
        {
            commitTypedValue();
            endEdit();
            _pointerDown = false;
            _scrubbing = false;
            releaseMouse();
            setCursor(CursorKind.text);
        }
    }
}

/** Text field that detaches one timeline lane for an entire typing session. */
private final class InspectorTextField : TextField
{
    void delegate() onEditStarted;
    void delegate() onEditEnded;
    void delegate() onFocused;
    private bool _editing;

    this(string text = "")
    {
        super(text);
    }

    private void beginEdit()
    {
        if (_editing || !enabled()) return;
        _editing = true;
        if (onEditStarted !is null) onEditStarted();
    }

    private void endEdit()
    {
        if (!_editing) return;
        _editing = false;
        if (onEditEnded !is null) onEditEnded();
    }

    override bool onTextInput(ref Event event)
    {
        if (event.text.length > 0) beginEdit();
        return super.onTextInput(event);
    }

    override bool onKeyDown(ref Event event)
    {
        bool editingKey = event.key == Key.backspace || event.key == Key.deleteKey;
        if ((event.control() || event.meta()) &&
            (event.key == Key.v || event.key == Key.x ||
             event.key == Key.z || event.key == Key.y))
            editingKey = true;
        if (editingKey) beginEdit();
        return super.onKeyDown(event);
    }

    protected override void onFocusChanged(bool focused)
    {
        if (focused)
        {
            if (onFocused !is null) onFocused();
        }
        else
            endEdit();
    }
}

/** Button whose label may change during playback without reflowing its parent. */
private final class StableButton : Button
{
    private int _stableWidth;

    this(string text, IconKind icon, int stableWidth)
    {
        _stableWidth = stableWidth;
        super(text, icon);
        layoutHints().preferredWidth = _stableWidth;
        setComposited(true);
    }

    override void setText(string value)
    {
        super.setText(value);
        layoutHints().preferredWidth = _stableWidth;
    }
}

/** Export button with a context menu so MP3 export does not pollute the main toolbar. */
private final class ExportButton : Button
{
    void delegate(Point globalPosition) onContextRequested;

    this(string text, IconKind icon)
    {
        super(text, icon);
    }

    override bool onMouseDown(ref Event event)
    {
        if (enabled() && event.button == MouseButton.right)
        {
            requestFocus();
            if (onContextRequested !is null) onContextRequested(event.globalPosition);
            return true;
        }
        return super.onMouseDown(event);
    }
}

/** Playback slider that exposes gesture boundaries without changing Aurora's API. */
private final class PlaybackScrubber : Slider
{
    private bool _gesture;
    void delegate() onDragStarted;
    void delegate() onDragEnded;

    this(double minimum, double maximum, double value)
    {
        super(minimum, maximum, value);
    }

    override bool onMouseDown(ref Event event)
    {
        if (enabled() && event.button == MouseButton.left)
        {
            _gesture = true;
            if (onDragStarted !is null) onDragStarted();
        }
        return super.onMouseDown(event);
    }

    override bool onMouseUp(ref Event event)
    {
        const handled = super.onMouseUp(event);
        if (_gesture && event.button == MouseButton.left)
        {
            _gesture = false;
            if (onDragEnded !is null) onDragEnded();
        }
        return handled;
    }
}

final class EditorRoot : VBox
{
    private GuiWindow _window;
    private EditorModel _model;
    private ToolStatus _tools;
    private MediaImportService _importService;
    private FileDialogController _fileDialog;
    private PreviewService _previewService;
    private PcmAudioPlayer _audioPlayer;
    private VideoFrameStream _videoStream;
    private ExportJob _exportJob;

    private ProjectMediaList _mediaList;
    private Label _mediaDetails;
    private PreviewWidget _preview;
    private TimelineWidget _timeline;
    private TimelineHorizontalScrollbar _timelineScrollbar;
    private SplitPane _workspaceTimelineSplit;
    private Label _timeLabel;
    private PlaybackScrubber _scrub;
    private Label _status;
    private ProgressBar _progress;
    private Button _sourcePlayButton;
    private Button _sequencePreviewButton;
    private ExportButton _exportButton;
    private Button _revealExportButton;
    private Button _saveProjectButton;
    private Button _openProjectButton;
    private Button _recentProjectsButton;
    private Button _qualityButton;
    private Slider _mp4CompressionSlider;
    private Label _mp4CompressionLabel;
    private int _mp4CompressionCrf = mp4CompressionDefaultCrf;

    private Label _inspectorTitle;
    private Label _inspectorSource;
    private Label _inspectorTrim;
    private Label _inspectorDuration;
    private InspectorValueField _volumeValue;
    private InspectorValueField _scaleValue;
    private InspectorValueField _positionXValue;
    private InspectorValueField _positionYValue;
    private InspectorValueField _opacityValue;
    private InspectorValueField _rotationValue;
    private InspectorValueField _fadeInValue;
    private InspectorValueField _fadeOutValue;
    private InspectorValueField _textSizeValue;
    private InspectorValueField _blurValue;
    private InspectorValueField _shadowOpacityValue;
    private InspectorValueField _shadowBlurValue;
    private InspectorValueField _shadowOffsetXValue;
    private InspectorValueField _shadowOffsetYValue;
    private InspectorValueField _strokeWidthValue;
    private InspectorValueField _volume;
    private InspectorValueField _scale;
    private InspectorValueField _positionX;
    private InspectorValueField _positionY;
    private InspectorValueField _opacity;
    private InspectorValueField _rotation;
    private InspectorValueField _fadeIn;
    private InspectorValueField _fadeOut;
    private InspectorValueField _textSize;
    private InspectorValueField _blur;
    private InspectorValueField _shadowOpacity;
    private InspectorValueField _shadowBlur;
    private InspectorValueField _shadowOffsetX;
    private InspectorValueField _shadowOffsetY;
    private InspectorValueField _strokeWidth;
    private Button[EffectProperty.max + 1] _keyframeButtons;
    private VBox _inspectorSelectionSummary;
    private VBox _inspectorSourceSection;
    private VBox _inspectorAudioSection;
    private VBox _inspectorTransformSection;
    private VBox _inspectorLayerSection;
    private VBox _inspectorFadeSection;
    private VBox _inspectorTextSection;
    private Label _inspectorScope;
    private Button _resetAllPropertiesButton;
    private CheckBox _mute;
    private CheckBox _audioProxyVisible;
    private InspectorTextField _textField;
    private InspectorTextField _fontField;
    private InspectorTextField _textColorField;
    private InspectorTextField _shadowColorField;
    private InspectorTextField _strokeColorField;
    private CheckBox _textBox;
    private Button _fontPresetButton;
    private Button _textAlignLeft;
    private Button _textAlignCenter;
    private Button _textAlignRight;
    private ScrollView _inspectorScroll;
    private Button[] _clipControls;
    private bool _syncingInspector;

    private bool _inlineTextEditing;
    private bool _inlineTextChanged;
    private TrackAddress _inlineTextTrack;
    private int _inlineTextIndex = -1;
    private string _projectPath;
    private bool _projectDirty;

    private bool _hasWorkIn;
    private bool _hasWorkOut;
    private double _workIn;
    private double _workOut;

    private bool _lastSelectionIsMedia;
    private PendingPreviewKind _pendingPreviewKind;
    private double _pendingPreviewDelay = 0.0;
    private size_t _pendingAssetIndex;
    private double _pendingPreviewTime = 0.0;

    // FFprobe never runs on the event thread. These paths/counters are owned
    // by the UI and summarize one or more overlapping import/drop batches.
    private string[] _queuedImportPaths;
    private bool _importBatchActive;
    private size_t _importQueuedCount;
    private size_t _importImportedCount;
    private size_t _importDuplicateCount;
    private size_t _importIgnoredCount;
    private size_t _importFailedCount;
    private string _importLastError;
    private PendingTimelineDrop[] _pendingTimelineDrops;

    private bool _clipboardHasClip;
    private TimelineClip _clipboardClip;
    private TrackAddress _clipboardTrack;

    private PlaybackKind _playbackKind;
    private MediaAsset _playbackAsset;
    private double _playbackStart = 0.0;
    private double _playbackEnd = 0.0;
    private double _playbackPosition = 0.0;
    private bool _playbackRunning;
    private double _playbackSourceVolume = 1.0;
    private bool _playbackSourceMuted;
    // Direct sequence passthrough keeps transport positions in sequence time
    // while decoding the original media at sequenceTime + mediaOffset.
    private double _playbackMediaOffset = 0.0;
    private bool _sequencePlaybackDirect;
    private bool _sequencePlaybackLive;
    private double _liveAudioEnd = -1.0;
    private ulong _liveAudioClipId;
    private bool _playbackAudioStarted;
    private bool _playbackAwaitingAudioClock;
    private double _playbackAudioClockWait;
    private ulong _playbackModelRevision;

    private bool _canvasDragEditing;
    private bool _canvasDragChanged;
    private TimelineSnapshot _canvasDragSnapshot;
    private bool _previewTextClickValid;
    private TrackAddress _previewTextClickTrack;
    private int _previewTextClickIndex = -1;
    private MonoTime _previewTextClickStarted;

    // Playback/seek state is intentionally detached from host tick frequency.
    // The monotonic clock is authoritative, and drag events only replace one
    // pending seek instead of synchronously restarting FFmpeg for every pixel.
    private MonoTime _playbackClockStarted;
    private double _playbackClockBase = 0.0;
    private bool _playbackClockValid;
    private bool _playbackAwaitingFirstFrame;
    private bool _seekPending;
    private bool _seekGesture;
    private bool _seekResumePlayback;
    private double _seekDelay;
    private double _seekTarget;
    private double _seekStillTarget = -1.0;
    private double _transportPaintAccumulator;
    private double _lastTimeLabelPlaybackPosition = -1.0;
    private string _lastTimeText;
    private string _lastStatusText;
    private double _lastProgressValue = -1.0;
    private int _lastProgressPercent = -1;
    private string _lastProgressLabel;
    private string _lastJobStatus;
    private string _lastExportPath;
    private bool _sourceAudioRefreshPending;
    private double _sourceAudioRefreshDelay;
    private bool _sequenceRefreshPending;
    private double _sequenceRefreshDelay;
    // Timeline mutations made during active playback never tear down the
    // decoder or audio process. The current transport snapshot continues
    // uninterrupted; the edited model is adopted on pause/resume or the next
    // playback start.
    private bool _sequenceRefreshDeferred;

    // Audio-only preview clocks are repainted at 10 Hz. Video preview time is
    // carried by decoded frames, avoiding redundant full RGB redraws between
    // frame arrivals.
    private double _lastPreviewClockPaint = -1.0;

    private int _previewQualityHeight = 1080;
    // Default to the low-latency path. Render/export quality remains governed
    // independently by the 720p–2160p composition preset.
    private PlaybackPerformance _playbackPerformance = PlaybackPerformance.responsive;
    private ulong _modelRevision = 1;
    private ulong _renderedPreviewRevision;
    private ulong _previewRenderRevision;
    private int _renderedPreviewHeight;
    private int _previewRenderHeight;
    private MediaAsset _renderedPreviewAsset;

    private TimelineSnapshot[] _undo;
    private TimelineSnapshot[] _redo;

    private JobPurpose _jobPurpose;
    private bool _jobCompletionHandled = true;

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        _model = new EditorModel();
        _importService = new MediaImportService();
        _previewService = new PreviewService();
        _audioPlayer = new PcmAudioPlayer();
        _videoStream = new VideoFrameStream();
        _exportJob = new ExportJob();
        _tools = inspectToolStatus();

        buildToolbar();
        auto workspace = buildWorkspace();
        auto timelineArea = buildTimelineArea();
        _workspaceTimelineSplit = add(new SplitPane(workspace, timelineArea,
            Orientation.vertical));
        _workspaceTimelineSplit.setId("workspace-sequence-split");
        _workspaceTimelineSplit.setDividerSize(8);
        _workspaceTimelineSplit.setRatio(0.70, false);
        _workspaceTimelineSplit.layoutHints().flex = 1.0;
        buildStatusBar();

        _fileDialog = new FileDialogController(this);
        syncMediaList();
        syncInspector();
        syncTimelineRange();
        updatePlaybackButtons();
        updateQualityUi();

        if (!_tools.editingReady())
            setStatus("FFmpeg and FFprobe must be installed and available on PATH.");
        else
            setStatus("Ready • H.264: " ~ _tools.videoAcceleration);
    }

    void shutdown()
    {
        autoSaveProjectOnExit();
        if (_fileDialog !is null) _fileDialog.dismiss();
        stopPlayback(false);
        _importService.shutdown();
        _exportJob.shutdown();
        _videoStream.shutdown();
        _audioPlayer.shutdown();
        _previewService.shutdown();
    }

    // Small public inspection surface used by deterministic smoke tests.
    EditorModel modelForTesting() { return _model; }
    bool playbackRunningForTesting() const { return _playbackRunning; }
    bool playbackAwaitingFirstFrameForTesting() const { return _playbackAwaitingFirstFrame; }
    bool sequencePlaybackForTesting() const
    {
        return _playbackKind == PlaybackKind.sequence && _playbackRunning;
    }
    bool directSequencePlaybackForTesting() const
    {
        return _playbackKind == PlaybackKind.sequence &&
            _playbackRunning && _sequencePlaybackDirect;
    }
    string videoAccelerationForTesting() const
    {
        return _tools.videoAcceleration;
    }
    bool renderRunningForTesting() { return _exportJob.state().running; }
    bool importBusyForTesting() { return _importService.busy() || _queuedImportPaths.length > 0; }
    bool cancelRenderForTesting() { return _exportJob.cancel(); }
    int previewQualityHeightForTesting() const { return _previewQualityHeight; }
    void setPreviewQualityForTesting(int height) { setPreviewQuality(height); }
    int mp4CompressionCrfForTesting() const { return _mp4CompressionCrf; }
    bool hasWorkInForTesting() const { return _hasWorkIn; }
    bool hasWorkOutForTesting() const { return _hasWorkOut; }
    double workInForTesting() const { return _workIn; }
    double workOutForTesting() const { return _workOut; }
    void setWorkOutForTesting(double value) { setWorkOut(value); }
    void clearWorkRangeForTesting() { clearWorkRange(); }
    PlaybackWorkerStats videoStatsForTesting() { return _videoStream.stats(); }
    PlaybackWorkerStats audioStatsForTesting() { return _audioPlayer.stats(); }
    PreviewServiceStats previewStatsForTesting() { return _previewService.stats(); }
    bool seekPendingForTesting() const { return _seekPending; }
    bool deferredSequenceRefreshForTesting() const { return _sequenceRefreshDeferred; }
    ulong playbackRevisionForTesting() const { return _playbackModelRevision; }
    ulong modelRevisionForTesting() const { return _modelRevision; }
    void moveClipForTesting(TrackAddress source, int index,
        TrackAddress destination, double start)
    {
        moveClipRequested(source, index, destination, start);
    }
    double playbackStartForTesting() const { return _playbackStart; }
    double playbackPositionForTesting() const { return _playbackPosition; }
    double scrubMinimumForTesting() const { return _scrub.minimum(); }
    double scrubMaximumForTesting() const { return _scrub.maximum(); }
    double scrubValueForTesting() const { return _scrub.value(); }
    void saveProjectForTesting(string path) { writeProject(path); }
    string lastExportPathForTesting() const { return _lastExportPath; }
    bool revealExportEnabledForTesting() const
    {
        return _revealExportButton !is null && _revealExportButton.enabled();
    }
    double nextTimelineAudioStartForTesting(double value)
    {
        return nextTimelineAudioStart(value);
    }
    void seekForTesting(double value) { seekPlayback(value); }
    void beginSeekGestureForTesting() { beginSeekGesture(); }
    void endSeekGestureForTesting() { endSeekGesture(); }

    private void buildToolbar()
    {
        // Keep the global bar intentionally small. Playback belongs beside the
        // Preview itself; the only global action left here is export.
        auto toolbar = add(new HBox(4, Insets(6, 3)));
        toolbar.setBackground(Color.fromHex(0x20242a));
        toolbar.layoutHints().preferredHeight = 32;

        _saveProjectButton = toolbar.add(new Button("Save", IconKind.save));
        _saveProjectButton.setId("save-project");
        _saveProjectButton.layoutHints().preferredHeight = 26;
        _saveProjectButton.onClick = delegate() { saveProject(false); };

        _openProjectButton = toolbar.add(new Button("Open", IconKind.folder));
        _openProjectButton.setId("open-project");
        _openProjectButton.layoutHints().preferredHeight = 26;
        _openProjectButton.onClick = delegate() { openProjectDialog(); };

        _recentProjectsButton = toolbar.add(new Button("Recent ▾", IconKind.clock));
        _recentProjectsButton.setId("recent-projects");
        _recentProjectsButton.layoutHints().preferredHeight = 26;
        _recentProjectsButton.onClick = delegate() {
            showRecentProjectsMenu();
        };
        toolbar.add(new Spacer());

        auto compressionTitle = toolbar.add(new Label("Compress"));
        compressionTitle.setId("export-mp4-compression-title");
        compressionTitle.setScale(1);
        compressionTitle.setColor(Color.fromHex(0xb8c1cc));
        compressionTitle.layoutHints().preferredHeight = 26;

        _mp4CompressionSlider = toolbar.add(new Slider(
            mp4CompressionMinCrf, mp4CompressionMaxCrf,
            mp4CompressionDefaultCrf));
        _mp4CompressionSlider.setId("export-mp4-compression");
        _mp4CompressionSlider.layoutHints().preferredWidth = 92;
        _mp4CompressionSlider.layoutHints().minWidth = 72;
        _mp4CompressionSlider.layoutHints().preferredHeight = 26;
        _mp4CompressionSlider.onChanged = delegate(double value) {
            mp4CompressionChanged(value);
        };

        _mp4CompressionLabel = toolbar.add(new Label(""));
        _mp4CompressionLabel.setId("export-mp4-compression-value");
        _mp4CompressionLabel.setScale(1);
        _mp4CompressionLabel.setColor(Color.fromHex(0xb8c1cc));
        _mp4CompressionLabel.layoutHints().preferredHeight = 26;
        syncMp4CompressionLabel();

        _exportButton = toolbar.add(new ExportButton("Export MP4", IconKind.save));
        _exportButton.setId("export-mp4");
        _exportButton.layoutHints().preferredHeight = 26;
        _exportButton.onClick = delegate() { openExportDialog(ExportKind.mp4); };
        _exportButton.onContextRequested = delegate(Point point) {
            showExportContextMenu(point);
        };
        _revealExportButton = toolbar.add(new Button("Output", IconKind.folder));
        _revealExportButton.setId("reveal-export-output");
        _revealExportButton.layoutHints().preferredHeight = 26;
        _revealExportButton.setEnabled(false);
        _revealExportButton.onClick = delegate() { revealExportOutput(); };
    }

    private static int normalizedMp4CompressionCrf(double value)
    {
        int crf = cast(int) (value + 0.5);
        if (crf < mp4CompressionMinCrf) crf = mp4CompressionMinCrf;
        else if (crf > mp4CompressionMaxCrf) crf = mp4CompressionMaxCrf;
        return crf;
    }

    private void syncMp4CompressionLabel()
    {
        if (_mp4CompressionLabel is null) return;
        _mp4CompressionLabel.setText(format("CRF %d", _mp4CompressionCrf));
    }

    private void mp4CompressionChanged(double value)
    {
        const crf = normalizedMp4CompressionCrf(value);
        _mp4CompressionCrf = crf;
        if (_mp4CompressionSlider !is null &&
            fabs(_mp4CompressionSlider.value() - crf) > 0.000_001)
            _mp4CompressionSlider.setValue(crf, false);
        syncMp4CompressionLabel();
    }

    private void applyMp4OutputCompression(ref ExportPreset preset)
    {
        preset.crf = _mp4CompressionCrf;
    }

    private Widget buildWorkspace()
    {
        auto mediaPanel = new ProjectMediaPanel();
        mediaPanel.setId("project-media-panel");
        mediaPanel.layoutHints().minWidth = 220;
        mediaPanel.setBackground(Color.fromHex(0x1d2228));
        mediaPanel.setBorder(Color.fromHex(0x424a55), 0);
        mediaPanel.onMediaDropped = delegate(string[] paths) { importDroppedMedia(paths); };

        auto mediaTitle = mediaPanel.add(new Label("PROJECT MEDIA"));
        mediaTitle.setScale(1);
        mediaTitle.setColor(Color.fromHex(0xb8c1cc));
        mediaTitle.layoutHints().preferredHeight = 24;
        auto dropHint = mediaPanel.add(new Label(
            "Drop files here • drag media to any sequence track"));
        dropHint.setScale(1);
        dropHint.setColor(Color.fromHex(0x87919c));
        dropHint.layoutHints().preferredHeight = 30;

        _mediaList = mediaPanel.add(new ProjectMediaList());
        _mediaList.setId("project-media-list");
        _mediaList.setRowHeight(58);
        _mediaList.onSelectionChanged = delegate(int index) { mediaSelectionChanged(index); };
        _mediaList.onActivated = delegate(int index) { mediaActivated(index); };
        _mediaList.onContextMenuRequested = delegate(int index, Point point) {
            showMediaContextMenu(index, point);
        };
        _mediaList.onDragStarted = delegate(int index, Point point) {
            if (index >= 0) _timeline.beginExternalDrag(cast(size_t) index);
        };
        _mediaList.onDragUpdated = delegate bool(int index, Point point) {
            return index >= 0 && _timeline.updateExternalDrag(cast(size_t) index, point);
        };
        _mediaList.onDragFinished = delegate(int index, Point point, bool commit) {
            if (index >= 0)
                _timeline.endExternalDrag(cast(size_t) index, point, commit);
            else
                _timeline.cancelExternalDrag();
        };

        _mediaDetails = mediaPanel.add(new Label("No media imported"));
        _mediaDetails.setScale(1);
        _mediaDetails.setColor(Color.fromHex(0xaeb8c3));
        _mediaDetails.layoutHints().preferredHeight = 44;

        auto previewPanel = new VBox(6, Insets(8));
        previewPanel.layoutHints().minWidth = 360;
        previewPanel.layoutHints().minHeight = 280;
        previewPanel.setBackground(Color.fromHex(0x181c21));
        auto previewHeader = previewPanel.add(new HBox(6));
        previewHeader.layoutHints().preferredHeight = 32;
        auto previewTitle = previewHeader.add(new Label("COMPOSITION PREVIEW"));
        previewTitle.setScale(1);
        previewTitle.setColor(Color.fromHex(0xb8c1cc));
        previewHeader.add(new Spacer());
        _qualityButton = previewHeader.add(new Button("1080p"));
        _qualityButton.setId("preview-quality");
        _qualityButton.onClick = delegate() {
            const point = _qualityButton.localToGlobal(
                Point(0, _qualityButton.bounds().height + 2));
            showQualityContextMenu(point);
        };
        _timeLabel = previewHeader.add(new Label("00:00:00.000 / 00:00:00.000"));
        _timeLabel.setScale(1);
        _timeLabel.setColor(Color.fromHex(0xb8c1cc));
        _timeLabel.setComposited(true);

        _preview = previewPanel.add(new PreviewWidget());
        _preview.setId("preview");
        _preview.layoutHints().flex = 1.0;
        _preview.onContextMenuRequested = delegate(Point point) {
            showPreviewContextMenu(point);
        };
        _preview.onCanvasPointerDown = delegate bool(double normalizedX,
            double normalizedY, int clickCount) {
            return previewCanvasPointerDown(normalizedX, normalizedY, clickCount);
        };
        _preview.onTransformDragStarted = delegate() { beginCanvasTransformDrag(); };
        _preview.onTransformDragRequested = delegate(double normalizedDx, double normalizedDy) {
            nudgeSelectedClipOnCanvas(normalizedDx, normalizedDy);
        };
        _preview.onTransformDragEnded = delegate() { endCanvasTransformDrag(); };
        _preview.onInlineTextChanged = delegate(string value) {
            inlineTextChanged(value);
        };
        _preview.onInlineFontChanged = delegate(string value) {
            inlineFontChanged(value);
        };
        _preview.onInlineTextSizeChanged = delegate(double value) {
            inlineTextSizeChanged(value);
        };
        _preview.onInlineTextColorChanged = delegate(string value) {
            inlineTextColorChanged(value);
        };
        _preview.onInlineBoldChanged = delegate(bool value) {
            inlineTextStyleChanged(0, value);
        };
        _preview.onInlineItalicChanged = delegate(bool value) {
            inlineTextStyleChanged(1, value);
        };
        _preview.onInlineUnderlineChanged = delegate(bool value) {
            inlineTextStyleChanged(2, value);
        };
        _preview.onInlineTextAlignmentChanged = delegate(TextAlignment value) {
            inlineTextAlignmentChanged(value);
        };
        _preview.onInlineEditEnded = delegate() { endInlineTextEditing(); };

        auto transport = previewPanel.add(new HBox(7));
        transport.layoutHints().preferredHeight = 34;
        _sourcePlayButton = transport.add(new StableButton(
            "▶", IconKind.none, 42));
        _sourcePlayButton.setId("play-preview");
        _sourcePlayButton.onClick = delegate() { playCurrentContext(); };
        _scrub = transport.add(new PlaybackScrubber(0.0, 1.0, 0.0));
        _scrub.setId("preview-scrub");
        // Transport updates repaint only this narrow layer, never the complete
        // workspace or static timeline content.
        _scrub.setComposited(true);
        _scrub.layoutHints().flex = 1.0;
        _scrub.onDragStarted = delegate() { beginSeekGesture(); };
        _scrub.onDragEnded = delegate() { endSeekGesture(); };
        _scrub.onChanged = delegate(double value) { scrubChanged(value); };
        auto inspectorPanel = buildInspector();
        auto previewInspector = new SplitPane(previewPanel, inspectorPanel,
            Orientation.horizontal);
        previewInspector.layoutHints().minWidth = 607;
        previewInspector.layoutHints().minHeight = 280;
        previewInspector.setRatio(0.72, false);
        previewInspector.setDividerSize(7);

        auto workspace = new SplitPane(mediaPanel, previewInspector,
            Orientation.horizontal);
        workspace.setRatio(0.22, false);
        workspace.setDividerSize(7);
        workspace.layoutHints().minHeight = 280;
        workspace.layoutHints().flex = 1.0;
        return workspace;
    }

    private Widget buildInspector()
    {
        auto panel = new VBox(7, Insets(8));
        panel.setBackground(Color.fromHex(0x20252c));
        panel.layoutHints().minWidth = 286;

        auto title = panel.add(new Label("ITEM EFFECTS / KEYFRAMES"));
        title.setScale(1);
        title.setColor(Color.fromHex(0xd8dee6));
        title.layoutHints().preferredHeight = 20;

        _inspectorScope = panel.add(new Label(
            "Select one timeline item"));
        _inspectorScope.setId("inspector-scope");
        _inspectorScope.setScale(1);
        _inspectorScope.setColor(Color.fromHex(0x8f9aa6));
        _inspectorScope.layoutHints().preferredHeight = 20;

        _inspectorSelectionSummary = panel.add(new VBox(2));
        _inspectorSelectionSummary.setId("inspector-selection-summary");
        _inspectorSelectionSummary.layoutHints().preferredHeight = 26;
        _inspectorTitle = _inspectorSelectionSummary.add(new Label("No clip selected"));
        _inspectorTitle.setScale(1);
        _inspectorTitle.layoutHints().preferredHeight = 22;
        _inspectorSource = _inspectorSelectionSummary.add(
            new Label("Select one item on the sequence timeline."));
        _inspectorSource.setScale(1);
        _inspectorSource.setColor(Color.fromHex(0x919ca8));
        _inspectorSource.layoutHints().preferredHeight = 20;
        _inspectorSource.setVisible(false);
        _inspectorTrim = _inspectorSelectionSummary.add(
            new Label("In 00:00:00.000 • Out 00:00:00.000"));
        _inspectorTrim.setScale(1);
        _inspectorTrim.setColor(Color.fromHex(0x919ca8));
        _inspectorTrim.layoutHints().preferredHeight = 18;
        _inspectorTrim.setVisible(false);
        _inspectorDuration = _inspectorSelectionSummary.add(
            new Label("Start 00:00:00.000 • Duration 00:00:00.000"));
        _inspectorDuration.setScale(1);
        _inspectorDuration.setColor(Color.fromHex(0x919ca8));
        _inspectorDuration.layoutHints().preferredHeight = 18;
        _inspectorDuration.setVisible(false);

        _inspectorSourceSection = panel.add(new VBox(5));
        _inspectorSourceSection.setId("inspector-source-section");
        _inspectorSourceSection.layoutHints().preferredHeight = 90;
        _inspectorSourceSection.setVisible(false);
        _inspectorSourceSection.add(new Separator());
        auto sourceTitle = _inspectorSourceSection.add(new Label("SOURCE / TIMING"));
        sourceTitle.setScale(1);
        sourceTitle.setColor(Color.fromHex(0xb8c1cc));
        sourceTitle.layoutHints().preferredHeight = 20;

        auto trimInRow = _inspectorSourceSection.add(new HBox(4));
        trimInRow.layoutHints().preferredHeight = 26;
        addTrimButton(trimInRow, "In −1", true, -1.0);
        addTrimButton(trimInRow, "−0.1", true, -0.1);
        addTrimButton(trimInRow, "+0.1", true, 0.1);
        addTrimButton(trimInRow, "+1", true, 1.0);

        auto trimOutRow = _inspectorSourceSection.add(new HBox(4));
        trimOutRow.layoutHints().preferredHeight = 26;
        addTrimButton(trimOutRow, "Out −1", false, -1.0);
        addTrimButton(trimOutRow, "−0.1", false, -0.1);
        addTrimButton(trimOutRow, "+0.1", false, 0.1);
        addTrimButton(trimOutRow, "+1", false, 1.0);

        _inspectorAudioSection = panel.add(new VBox(5));
        _inspectorAudioSection.setId("inspector-audio-section");
        _inspectorAudioSection.layoutHints().preferredHeight = 92;
        _inspectorAudioSection.add(new Separator());
        auto audioTitle = _inspectorAudioSection.add(new Label("AUDIO • ITEM"));
        audioTitle.setScale(1);
        audioTitle.setColor(Color.fromHex(0xb8c1cc));
        audioTitle.layoutHints().preferredHeight = 20;
        _volume = addInspectorValue(_inspectorAudioSection, "Gain", _volumeValue,
            -60.0, 12.0, 0.0, "Change selected-item gain",
            delegate(double value) { volumeChanged(value); },
            EffectProperty.volume, true);
        _volume.setId("clip-volume-db");
        _mute = _inspectorAudioSection.add(new CheckBox("Mute selected item audio", false));
        _mute.setId("clip-mute");
        _mute.onChanged = delegate(bool value) { muteChanged(value); };
        _audioProxyVisible = _inspectorAudioSection.add(new CheckBox(
            "Show embedded audio on matching A track", false));
        _audioProxyVisible.setId("clip-audio-proxy");
        // This per-item display option lives in the timeline context menu.
        // Keep the backing widget for compatibility with existing sync code,
        // but remove it from the visible Inspector layout.
        _audioProxyVisible.setVisible(false);
        _audioProxyVisible.layoutHints().excludeFromLayout = true;
        _audioProxyVisible.onChanged = delegate(bool value) {
            audioProxyVisibilityChanged(value);
        };

        _inspectorTransformSection = panel.add(new VBox(5));
        _inspectorTransformSection.setId("inspector-transform-section");
        _inspectorTransformSection.layoutHints().preferredHeight = 190;
        _inspectorTransformSection.add(new Separator());
        auto transformTitle = _inspectorTransformSection.add(
            new Label("TRANSFORM • ITEM"));
        transformTitle.setScale(1);
        transformTitle.setColor(Color.fromHex(0xb8c1cc));
        transformTitle.layoutHints().preferredHeight = 20;
        auto transformHint = _inspectorTransformSection.add(
            new Label("◇ add/remove key at the playhead"));
        transformHint.setScale(1);
        transformHint.setColor(Color.fromHex(0x87919c));
        transformHint.layoutHints().preferredHeight = 18;
        _scale = addInspectorValue(_inspectorTransformSection, "Scale", _scaleValue,
            0.1, 4.0, 1.0, "Change selected-item scale",
            delegate(double value) { scaleChanged(value); },
            EffectProperty.scale, true);
        _scale.setId("clip-scale");
        _positionX = addInspectorValue(_inspectorTransformSection, "Position X",
            _positionXValue, -2.0, 2.0, 0.0, "Change selected-item X position",
            delegate(double value) { positionXChanged(value); },
            EffectProperty.positionX, true);
        _positionX.setId("clip-position-x");
        _positionY = addInspectorValue(_inspectorTransformSection, "Position Y",
            _positionYValue, -2.0, 2.0, 0.0, "Change selected-item Y position",
            delegate(double value) { positionYChanged(value); },
            EffectProperty.positionY, true);
        _positionY.setId("clip-position-y");
        _opacity = addInspectorValue(_inspectorTransformSection, "Layer opacity",
            _opacityValue, 0.0, 1.0, 1.0, "Change selected-item layer opacity",
            delegate(double value) { opacityChanged(value); },
            EffectProperty.opacity, true);
        _opacity.setId("clip-opacity");
        _rotation = addInspectorValue(_inspectorTransformSection, "Rotation",
            _rotationValue, -180.0, 180.0, 0.0, "Change selected-item rotation",
            delegate(double value) { rotationChanged(value); },
            EffectProperty.rotation, true);
        _rotation.setId("clip-rotation");

        _inspectorLayerSection = panel.add(new VBox(5));
        _inspectorLayerSection.setId("inspector-layer-section");
        _inspectorLayerSection.layoutHints().preferredHeight = 360;
        _inspectorLayerSection.add(new Separator());
        auto layerEffectsTitle = _inspectorLayerSection.add(
            new Label("STYLE EFFECTS • ITEM"));
        layerEffectsTitle.setScale(1);
        layerEffectsTitle.setColor(Color.fromHex(0xb8c1cc));
        layerEffectsTitle.layoutHints().preferredHeight = 20;
        auto styleHint = _inspectorLayerSection.add(
            new Label("Per-item styling • ◇ means animated"));
        styleHint.setScale(1);
        styleHint.setColor(Color.fromHex(0x87919c));
        styleHint.layoutHints().preferredHeight = 18;
        _blur = addInspectorValue(_inspectorLayerSection, "Blur", _blurValue,
            0.0, 40.0, 0.0, "Change selected-item blur",
            delegate(double value) { blurChanged(value); });
        _blur.setId("clip-blur");
        _strokeWidth = addInspectorValue(_inspectorLayerSection, "Stroke width",
            _strokeWidthValue, 0.0, 40.0, 0.0, "Change selected-item stroke",
            delegate(double value) { strokeWidthChanged(value); });
        _strokeWidth.setId("clip-stroke-width");
        addSmallPropertyLabel(_inspectorLayerSection, "Stroke color");
        _strokeColorField = _inspectorLayerSection.add(
            new InspectorTextField("Stroke color: #RRGGBB"));
        _strokeColorField.setId("clip-stroke-color");
        configureInspectorTextField(_strokeColorField,
            "Change selected-item stroke color");
        _strokeColorField.onChanged = delegate() { strokeColorFieldChanged(); };

        _shadowOpacity = addInspectorValue(_inspectorLayerSection, "Shadow opacity",
            _shadowOpacityValue, 0.0, 1.0, 0.0, "Change selected-item shadow opacity",
            delegate(double value) { shadowOpacityChanged(value); });
        _shadowBlur = addInspectorValue(_inspectorLayerSection, "Shadow blur",
            _shadowBlurValue, 0.0, 40.0, 12.0, "Change selected-item shadow blur",
            delegate(double value) { shadowBlurChanged(value); });
        _shadowOffsetX = addInspectorValue(_inspectorLayerSection, "Shadow X",
            _shadowOffsetXValue, -200.0, 200.0, 12.0,
            "Change selected-item shadow X",
            delegate(double value) { shadowOffsetXChanged(value); });
        _shadowOffsetY = addInspectorValue(_inspectorLayerSection, "Shadow Y",
            _shadowOffsetYValue, -200.0, 200.0, 12.0,
            "Change selected-item shadow Y",
            delegate(double value) { shadowOffsetYChanged(value); });
        addSmallPropertyLabel(_inspectorLayerSection, "Shadow color");
        _shadowColorField = _inspectorLayerSection.add(
            new InspectorTextField("Shadow color: #RRGGBB"));
        _shadowColorField.setId("clip-shadow-color");
        configureInspectorTextField(_shadowColorField,
            "Change selected-item shadow color");
        _shadowColorField.onChanged = delegate() { shadowColorFieldChanged(); };

        _inspectorFadeSection = panel.add(new VBox(5));
        _inspectorFadeSection.setId("inspector-fade-section");
        _inspectorFadeSection.layoutHints().preferredHeight = 96;
        _inspectorFadeSection.add(new Separator());
        auto fadeTitle = _inspectorFadeSection.add(
            new Label("EDGE FADES • ITEM"));
        fadeTitle.setScale(1);
        fadeTitle.setColor(Color.fromHex(0xb8c1cc));
        fadeTitle.layoutHints().preferredHeight = 20;
        _fadeIn = addInspectorValue(_inspectorFadeSection, "Fade in", _fadeInValue,
            0.0, 10.0, 0.0, "Change selected-item fade in",
            delegate(double value) { fadeInChanged(value); });
        _fadeIn.setId("clip-fade-in");
        _fadeOut = addInspectorValue(_inspectorFadeSection, "Fade out", _fadeOutValue,
            0.0, 10.0, 0.0, "Change selected-item fade out",
            delegate(double value) { fadeOutChanged(value); });
        _fadeOut.setId("clip-fade-out");

        _inspectorTextSection = panel.add(new VBox(5));
        _inspectorTextSection.setId("inspector-text-section");
        _inspectorTextSection.layoutHints().preferredHeight = 230;
        _inspectorTextSection.add(new Separator());
        auto textTitle = _inspectorTextSection.add(
            new Label("TEXT ITEM / SHAPE STYLE"));
        textTitle.setScale(1);
        textTitle.setColor(Color.fromHex(0xb8c1cc));
        textTitle.layoutHints().preferredHeight = 20;
        auto textContentLabel = addSmallPropertyLabel(_inspectorTextSection, "Text content");
        textContentLabel.setVisible(false);
        _textField = _inspectorTextSection.add(new InspectorTextField("Title"));
        _textField.setVisible(false);
        _textField.setId("clip-text");
        configureInspectorTextField(_textField, "Edit selected text item");
        _textField.onFocused = delegate() {
            if (_timeline !is null) _timeline.activateSelectionTool();
        };
        _textField.onChanged = delegate() { textFieldChanged(); };
        _textSize = addInspectorValue(_inspectorTextSection, "Text size",
            _textSizeValue, 8.0, 220.0, 96.0, "Change selected text size",
            delegate(double value) { textSizeChanged(value); },
            EffectProperty.textSize, true);
        _textSize.setId("clip-text-size");

        addSmallPropertyLabel(_inspectorTextSection, "Text alignment");
        auto alignmentRow = _inspectorTextSection.add(new HBox(5));
        alignmentRow.layoutHints().preferredHeight = 28;
        _textAlignLeft = alignmentRow.add(new Button("Left"));
        _textAlignLeft.setId("clip-text-align-left");
        _textAlignCenter = alignmentRow.add(new Button("Center"));
        _textAlignCenter.setId("clip-text-align-center");
        _textAlignRight = alignmentRow.add(new Button("Right"));
        _textAlignRight.setId("clip-text-align-right");
        foreach (button; [_textAlignLeft, _textAlignCenter, _textAlignRight])
        {
            button.layoutHints().flex = 1.0;
            button.layoutHints().preferredHeight = 28;
            button.setFlat(true);
        }
        _textAlignLeft.onClick = delegate() {
            textAlignmentChanged(TextAlignment.left);
        };
        _textAlignCenter.onClick = delegate() {
            textAlignmentChanged(TextAlignment.center);
        };
        _textAlignRight.onClick = delegate() {
            textAlignmentChanged(TextAlignment.right);
        };

        addSmallPropertyLabel(_inspectorTextSection, "Font family");
        auto fontRow = _inspectorTextSection.add(new HBox(5));
        fontRow.layoutHints().preferredHeight = 28;
        _fontField = fontRow.add(new InspectorTextField("Font family"));
        _fontField.setId("clip-font-family");
        configureInspectorTextField(_fontField, "Change selected text font");
        _fontField.layoutHints().flex = 1.0;
        _fontField.onChanged = delegate() { fontFieldChanged(); };
        _fontPresetButton = fontRow.add(new Button("Sans ▾"));
        _fontPresetButton.setId("clip-font-presets");
        _fontPresetButton.layoutHints().minWidth = 132;
        _fontPresetButton.layoutHints().preferredWidth = 132;
        _fontPresetButton.onClick = delegate() {
            showFontContextMenu(_fontPresetButton.localToGlobal(
                Point(0, _fontPresetButton.bounds().height + 2)));
        };

        addSmallPropertyLabel(_inspectorTextSection, "Text color");
        _textColorField = _inspectorTextSection.add(
            new InspectorTextField("Text color: #RRGGBB"));
        _textColorField.setId("clip-text-color");
        configureInspectorTextField(_textColorField, "Change selected text color");
        _textColorField.onChanged = delegate() { textColorFieldChanged(); };
        _textBox = _inspectorTextSection.add(new CheckBox("Background box", false));
        _textBox.setId("clip-text-box");
        _textBox.onChanged = delegate(bool value) { textBoxChanged(value); };

        _resetAllPropertiesButton = panel.add(
            new Button("Reset selected item to defaults"));
        _resetAllPropertiesButton.setId("reset-selected-item-properties");
        _resetAllPropertiesButton.onClick = delegate() { resetSelectedProperties(); };
        _clipControls ~= _resetAllPropertiesButton;

        auto inspectorHint = panel.add(new Label(
            "◆ means a key exists at this playhead. Right-click its timeline marker to remove it or change interpolation."));
        inspectorHint.setScale(1);
        inspectorHint.setColor(Color.fromHex(0x87919c));
        inspectorHint.layoutHints().preferredHeight = 38;

        _inspectorScroll = new ScrollView(panel);
        _inspectorScroll.setId("clip-inspector-scroll");
        _inspectorScroll.layoutHints().minWidth = 286;
        _inspectorScroll.layoutHints().flex = 1.0;
        return _inspectorScroll;
    }

    private void configureInspectorTextField(InspectorTextField field,
        string historyLabel)
    {
        field.onEditStarted = delegate() { beginScalarEdit(historyLabel); };
        field.onEditEnded = delegate() { _model.endContinuousEdit(); };
    }

    private InspectorValueField addInspectorValue(VBox panel, string title,
        ref InspectorValueField valueField, double minimum, double maximum,
        double initial, string historyLabel, void delegate(double value) changed,
        EffectProperty keyProperty = EffectProperty.volume, bool keyable = false)
    {
        auto header = panel.add(new HBox(5));
        header.setId("inspector-row-" ~ title);
        header.layoutHints().preferredHeight = 26;
        header.layoutHints().minHeight = 24;
        auto label = header.add(new Label(title));
        label.setId("inspector-label-" ~ title);
        label.setScale(1);
        label.setColor(Color.fromHex(0xd7dde5));
        label.layoutHints().flex = 1.0;

        valueField = header.add(new InspectorValueField(minimum, maximum, initial));
        valueField.setId("inspector-value-" ~ title);
        valueField.onEditStarted = delegate() { beginScalarEdit(historyLabel); };
        valueField.onEditEnded = delegate() { _model.endContinuousEdit(); };
        valueField.onValueChanged = changed;

        auto resetButton = header.add(new Button("Reset"));
        resetButton.layoutHints().minWidth = 60;
        resetButton.layoutHints().preferredWidth = 60;
        resetButton.layoutHints().preferredHeight = 22;
        resetButton.onClick = delegate() {
            beginScalarEdit("Reset " ~ title);
            valueField.setValue(initial, true);
            _model.endContinuousEdit();
            setStatus(title ~ " reset to its default value.");
        };
        _clipControls ~= resetButton;
        if (keyable)
        {
            auto keyButton = header.add(new Button("◇ Key"));
            keyButton.setId("inspector-key-" ~ title);
            keyButton.layoutHints().preferredWidth = 54;
            keyButton.layoutHints().preferredHeight = 24;
            keyButton.onClick = delegate() { toggleEffectKeyframe(keyProperty); };
            _keyframeButtons[cast(size_t) keyProperty] = keyButton;
        }
        return valueField;
    }

    private Label addSmallPropertyLabel(VBox panel, string text)
    {
        auto label = panel.add(new Label(text));
        label.setScale(1);
        label.setColor(Color.fromHex(0x919ca8));
        label.layoutHints().preferredHeight = 17;
        return label;
    }

    private void addTrimButton(HBox row, string text, bool trimIn, double delta)
    {
        auto button = row.add(new Button(text));
        button.layoutHints().flex = 1.0;
        button.onClick = delegate() { adjustTrim(trimIn, delta); };
        _clipControls ~= button;
    }

    private Widget buildTimelineArea()
    {
        auto area = new VBox(4, Insets(6, 5));
        area.setBackground(Color.fromHex(0x15181c));
        area.layoutHints().minHeight = 148;

        auto header = area.add(new HBox(6));
        header.layoutHints().preferredHeight = 28;
        auto title = header.add(new Label("SEQUENCE 01"));
        title.setScale(1);
        title.setColor(Color.fromHex(0xb8c1cc));
        header.add(new Spacer());
        auto snap = header.add(new Button("Snap On"));
        snap.layoutHints().minWidth = 84;
        snap.layoutHints().preferredWidth = 84;
        snap.onClick = delegate() {
            const enabled = !_timeline.snappingEnabled();
            _timeline.setSnappingEnabled(enabled);
            snap.setText(enabled ? "Snap On" : "Snap Off");
            setStatus(enabled ? "Timeline snapping enabled." :
                "Timeline snapping disabled.");
        };
        auto clearIn = header.add(new Button("In×"));
        clearIn.layoutHints().minWidth = 44;
        clearIn.layoutHints().preferredWidth = 44;
        clearIn.onClick = delegate() { clearWorkIn(); };
        auto clearOut = header.add(new Button("Out×"));
        clearOut.layoutHints().minWidth = 52;
        clearOut.layoutHints().preferredWidth = 52;
        clearOut.onClick = delegate() { clearWorkOut(); };
        auto zoomOut = header.add(new Button("−"));
        zoomOut.layoutHints().minWidth = 34;
        zoomOut.layoutHints().preferredWidth = 34;
        zoomOut.onClick = delegate() { _timeline.zoomOut(); };
        auto zoomFit = header.add(new Button("Fit"));
        zoomFit.layoutHints().minWidth = 56;
        zoomFit.layoutHints().preferredWidth = 56;
        zoomFit.onClick = delegate() { _timeline.zoomToFit(); };
        auto zoomIn = header.add(new Button("+"));
        zoomIn.layoutHints().minWidth = 34;
        zoomIn.layoutHints().preferredWidth = 34;
        zoomIn.onClick = delegate() { _timeline.zoomIn(); };

        auto hint = area.add(new Label(
            "Drag clips across time/tracks • edge-drop creates tracks • right-click for actions"));
        hint.setScale(1);
        hint.setColor(Color.fromHex(0x87919c));
        hint.layoutHints().preferredHeight = 17;

        _timeline = area.add(new TimelineWidget(_model));
        _timeline.setId("sequence-timeline");
        _timeline.layoutHints().flex = 1.0;
        _timelineScrollbar = area.add(new TimelineHorizontalScrollbar(_timeline));
        _timelineScrollbar.setId("sequence-horizontal-scrollbar");
        _timeline.onHorizontalViewportChanged = delegate() {
            if (_timelineScrollbar !is null) _timelineScrollbar.invalidate();
        };
        _timeline.onPlayheadChanged = delegate(double value) { playheadChanged(value); };
        _timeline.onScrubStarted = delegate() { beginSeekGesture(); };
        _timeline.onScrubEnded = delegate() { endSeekGesture(); };
        _timeline.onSelectionChanged = delegate(TrackAddress track, int index) {
            timelineSelectionChanged(track, index);
        };
        _timeline.onDeleteRequested = delegate() { deleteSelected(); };
        _timeline.onSplitRequested = delegate() { splitSelected(); };
        _timeline.onPreviewRequested = delegate() { previewTimeline(); };
        _timeline.onContextMenuRequested = delegate(TrackAddress track, int index,
            Point point) { showTimelineContextMenu(track, index, point); };
        _timeline.onClipActivated = delegate(TrackAddress track, int index) {
            activateTimelineClip(track, index);
        };
        _timeline.onClipMoveRequested = delegate(TrackAddress source, int index,
            TrackAddress destination, double start) {
            moveClipRequested(source, index, destination, start);
        };
        _timeline.onClipResizeRequested = delegate(TrackAddress track, int index,
            double start, double end) {
            resizeClipRequested(track, index, start, end);
        };
        _timeline.onMediaDropRequested = delegate(size_t assetIndex,
            TrackAddress destination, double start) {
            addAssetToTrack(assetIndex, destination, true, start);
        };
        _timeline.onExplorerMediaDropRequested = delegate(string[] paths,
            TrackAddress destination, double start) {
            importDroppedMediaToTimeline(paths, destination, start);
        };
        _timeline.onAddTrackRequested = delegate(TrackKind kind) { addTrack(kind); };
        _timeline.onCutToolRequested = delegate(TrackAddress track, double time) {
            cutToolRequested(track, time);
        };
        _timeline.onTextToolRequested = delegate(TrackAddress track,
            double start, double end) {
            textToolRequested(track, start, end);
        };
        _timeline.onTransitionToolRequested = delegate(TrackAddress track, int index,
            bool fadeIn, double duration) {
            setTransitionRequested(track, index, fadeIn, duration);
        };
        _timeline.onSetInRequested = delegate(double time) { setWorkIn(time); };
        _timeline.onSetOutRequested = delegate(double time) { setWorkOut(time); };
        _timeline.onClearRangeRequested = delegate() { clearWorkRange(); };
        return area;
    }

    private void buildStatusBar()
    {
        auto bar = add(new HBox(8, Insets(8, 3)));
        bar.setBackground(Color.fromHex(0x20242a));
        bar.layoutHints().preferredHeight = 34;
        _status = bar.add(new Label("Ready"));
        _status.setScale(1);
        _status.setComposited(true);
        _status.layoutHints().flex = 1.0;
        _progress = bar.add(new ProgressBar(0.0));
        _progress.setComposited(true);
        _progress.layoutHints().preferredWidth = 260;
        _progress.setShowPercent(false);
        _progress.setLabel("Idle");
    }

    private void updateProjectTitle()
    {
        string title = appDisplayName ~ " — MP4 / MP3 Editor";
        if (_projectPath.length > 0) title = appDisplayName ~ " — " ~ baseName(_projectPath);
        if (_projectDirty) title ~= " *";
        _window.setTitle(title);
    }

    private void saveProject(bool saveAs)
    {
        if (!saveAs && _projectPath.length > 0)
        {
            writeProject(_projectPath);
            return;
        }
        const suggested = _projectPath.length > 0 ? baseName(_projectPath) :
            "aurora-cut-project.auroracut";
        _fileDialog.showSave(".auroracut", suggested, delegate(string path) {
            writeProject(path);
        });
    }

    private void writeProject(string path)
    {
        try
        {
            endInlineTextEditing();
            saveProjectFile(path, _model, _timeline.playhead(), _hasWorkIn,
                _workIn, _hasWorkOut, _workOut, _previewQualityHeight);
            _projectPath = path;
            _projectDirty = false;
            rememberRecentProject(path);
            updateProjectTitle();
            setStatus("Project saved: " ~ path);
        }
        catch (Exception error)
        {
            appLog(format("Project save failed for '%s': %s", path, error.toString()));
            setStatus("Could not save project: " ~ outputTail(error.msg, 900));
        }
    }

    private void autoSaveProjectOnExit()
    {
        const path = _projectPath.length > 0 ? _projectPath :
            unnamedProjectAutosavePath();
        try
        {
            endInlineTextEditing();
            saveProjectFile(path, _model, _timeline.playhead(), _hasWorkIn,
                _workIn, _hasWorkOut, _workOut, _previewQualityHeight);
            _projectPath = path;
            _projectDirty = false;
            rememberRecentProject(path);
            updateProjectTitle();
            appLog("Project autosaved on exit: " ~ path);
        }
        catch (Exception error)
        {
            appLog(format("Project autosave failed for '%s': %s",
                path, error.toString()));
            setStatus("Could not autosave project: " ~ outputTail(error.msg, 900));
        }
    }

    private void openProjectDialog()
    {
        _fileDialog.showOpenProject(delegate(string path) { openProject(path); });
    }

    private void openProject(string path)
    {
        try
        {
            endInlineTextEditing();
            stopPlayback(false);
            auto data = loadProjectFile(path);
            _model.assets = data.assets;
            _model.restoreTimeline(data.videoTracks, data.audioTracks);
            _hasWorkIn = data.hasWorkIn;
            _hasWorkOut = data.hasWorkOut;
            _workIn = data.workIn;
            _workOut = data.workOut;
            // Older projects can contain an Out marker without an explicit In.
            // Keep the export-zone invariant visible in the timeline: Out-only
            // always means a range beginning at the sequence start.
            if (_hasWorkOut && !_hasWorkIn)
            {
                _hasWorkIn = true;
                _workIn = 0.0;
            }
            _previewQualityHeight = data.previewQualityHeight;
            if (_previewQualityHeight != 720 && _previewQualityHeight != 1080 &&
                _previewQualityHeight != 1440 && _previewQualityHeight != 2160)
                _previewQualityHeight = 1080;
            clearHistory();
            _clipboardHasClip = false;
            _timeline.modelChanged();
            _timeline.setSelection(TrackAddress(TrackKind.video, 0), -1, false);
            _timeline.setPlayhead(clampValue(data.playhead, 0.0,
                _model.sequenceDuration()), false);
            _projectPath = path;
            _projectDirty = false;
            rememberRecentProject(path);
            ++_modelRevision;
            if (_modelRevision == 0) _modelRevision = 1;
            syncMediaList();
            syncTimelineRange();
            syncTimelineWorkArea();
            syncInspector();
            updateQualityUi();
            updateProjectTitle();
            scheduleTimelineFrame();
            setStatus("Project opened: " ~ path);
        }
        catch (Exception error)
        {
            appLog(format("Project open failed for '%s': %s", path, error.toString()));
            setStatus("Could not open project: " ~ outputTail(error.msg, 900));
        }
    }

    private static string recentProjectMenuLabel(string path)
    {
        const folder = dirName(path);
        const name = baseName(path);
        if (folder.length == 0 || folder == ".") return name;
        return name ~ " — " ~ folder;
    }

    private void showRecentProjectsMenu()
    {
        ContextMenuItem[] items;
        const projects = loadRecentProjects(false);
        bool foundAvailable;
        bool foundUnavailable;

        foreach (path; projects)
        {
            if (!exists(path))
            {
                foundUnavailable = true;
                continue;
            }

            foundAvailable = true;
            const captured = path;
            const current = _projectPath.length > 0 &&
                filenameCmp(_projectPath, captured) == 0;
            items ~= ContextMenuItem.check(recentProjectMenuLabel(captured),
                current, delegate() { openProject(captured); });
        }

        if (!foundAvailable)
            items ~= ContextMenuItem.command("No recent projects", delegate() {},
                "", false);

        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Browse project…", IconKind.open,
            delegate() { openProjectDialog(); });

        if (foundAvailable || foundUnavailable)
        {
            if (foundUnavailable)
                items ~= ContextMenuItem.command("Clear unavailable projects",
                    IconKind.trash, delegate() {
                        clearUnavailableRecentProjects();
                        setStatus("Unavailable recent projects cleared.");
                    });
            items ~= ContextMenuItem.command("Clear recent projects", IconKind.trash,
                delegate() {
                    clearRecentProjects();
                    setStatus("Recent projects cleared.");
                });
        }

        showContextMenuBelow(_recentProjectsButton, items);
    }

    private void openImportDialog()
    {
        if (!_tools.ffprobe)
        {
            setStatus("FFprobe is required before media can be imported.");
            return;
        }
        _fileDialog.showOpen(delegate(string path) { importMedia(path); });
    }

    private bool importPathQueued(string path) const
    {
        foreach (queued; _queuedImportPaths)
            if (filenameCmp(queued, path) == 0) return true;
        return false;
    }

    private void beginImportBatchIfNeeded()
    {
        if (_importBatchActive) return;
        _importBatchActive = true;
        _importQueuedCount = 0;
        _importImportedCount = 0;
        _importDuplicateCount = 0;
        _importIgnoredCount = 0;
        _importFailedCount = 0;
        _importLastError = "";
    }

    private void queueMediaImports(string[] paths)
    {
        if (!_tools.ffprobe)
        {
            setStatus("FFprobe is required before media can be imported.");
            return;
        }
        if (paths.length == 0)
        {
            setStatus("No media files were selected.");
            return;
        }

        beginImportBatchIfNeeded();
        string[] accepted;
        int lastExisting = -1;
        foreach (requested; paths)
        {
            if (!isSupportedMediaPath(requested))
            {
                ++_importIgnoredCount;
                continue;
            }

            string normalized;
            try normalized = absoluteNormalized(requested);
            catch (Exception error)
            {
                ++_importFailedCount;
                _importLastError = outputTail(error.msg, 500);
                continue;
            }

            const existing = _model.assetIndexForPath(normalized);
            if (existing >= 0)
            {
                ++_importDuplicateCount;
                lastExisting = existing;
                continue;
            }
            if (importPathQueued(normalized))
            {
                ++_importDuplicateCount;
                continue;
            }
            _queuedImportPaths ~= normalized;
            accepted ~= normalized;
        }

        const queued = _importService.enqueue(accepted);
        _importQueuedCount += queued;
        if (lastExisting >= 0)
            _mediaList.setSelectedIndex(lastExisting);

        if (queued > 0)
        {
            setStatus(format("Inspecting %d media file%s in the background…",
                queued, queued == 1 ? "" : "s"));
        }
        else
            finishImportBatchIfIdle();
    }

    private void importMedia(string path)
    {
        queueMediaImports([path]);
    }

    private void importDroppedMedia(string[] paths)
    {
        queueMediaImports(paths);
    }

    private void importDroppedMediaToTimeline(string[] paths,
        TrackAddress destination, double start)
    {
        string[] toImport;
        foreach (requested; paths)
        {
            if (!isSupportedMediaPath(requested)) continue;
            string normalized;
            try normalized = absoluteNormalized(requested);
            catch (Exception) continue;
            const existing = _model.assetIndexForPath(normalized);
            if (existing >= 0)
            {
                addAssetToTrack(cast(size_t) existing, destination, true, start);
                continue;
            }
            _pendingTimelineDrops ~= PendingTimelineDrop(normalized,
                destination, start);
            toImport ~= normalized;
        }
        if (toImport.length == 0)
        {
            if (paths.length > 0)
                setStatus("Only MP4 and MP3 files can be dropped on the sequence.");
            return;
        }
        queueMediaImports(toImport);
        setStatus("Importing dropped media in the background; it will appear on the sequence automatically.");
    }

    private void placePendingTimelineDrops(string path, size_t assetIndex)
    {
        PendingTimelineDrop[] retained;
        foreach (request; _pendingTimelineDrops)
        {
            if (filenameCmp(request.path, path) == 0)
                addAssetToTrack(assetIndex, request.track, true, request.start);
            else
                retained ~= request;
        }
        _pendingTimelineDrops = retained;
    }

    private void discardPendingTimelineDrops(string path)
    {
        PendingTimelineDrop[] retained;
        foreach (request; _pendingTimelineDrops)
            if (filenameCmp(request.path, path) != 0) retained ~= request;
        _pendingTimelineDrops = retained;
    }

    private void removeQueuedImportPath(string requestedPath)
    {
        foreach (index, queued; _queuedImportPaths)
        {
            if (filenameCmp(queued, requestedPath) != 0) continue;
            _queuedImportPaths = _queuedImportPaths[0 .. index] ~
                _queuedImportPaths[index + 1 .. $];
            return;
        }
    }

    private void drainImportedMedia()
    {
        bool mediaChanged;
        int lastIndex = -1;
        MediaImportResult result;
        while (_importService.takeReady(result))
        {
            removeQueuedImportPath(result.requestedPath);
            if (result.success())
            {
                const existing = _model.assetIndexForPath(result.asset.path);
                if (existing >= 0)
                {
                    ++_importDuplicateCount;
                    lastIndex = existing;
                }
                else
                {
                    lastIndex = cast(int) _model.addAsset(result.asset);
                    ++_importImportedCount;
                    mediaChanged = true;
                    // Begin lightweight preview preparation as soon as the item
                    // appears in Project Media. The bounded source-frame cache
                    // can then serve selection and a plain V1 timeline frame
                    // without postponing work until the user presses Play.
                    if (result.asset.hasVideo && _preview !is null)
                    {
                        const warmSize = _preview.recommendedDecodeSize(
                            _previewQualityHeight);
                        _previewService.requestWarmAsset(result.asset, 0.0,
                            warmSize.width, warmSize.height);
                    }
                }
                if (lastIndex >= 0)
                    placePendingTimelineDrops(result.asset.path,
                        cast(size_t) lastIndex);
            }
            else
            {
                ++_importFailedCount;
                _importLastError = outputTail(result.error, 600);
                discardPendingTimelineDrops(result.requestedPath);
            }
        }

        if (mediaChanged)
        {
            markProjectDirty();
            syncMediaList();
        }
        if (lastIndex >= 0) _mediaList.setSelectedIndex(lastIndex);
        finishImportBatchIfIdle();
    }

    private void finishImportBatchIfIdle()
    {
        if (!_importBatchActive || _importService.busy() ||
            _queuedImportPaths.length > 0) return;

        string summary = format("Import complete: %d imported", _importImportedCount);
        if (_importDuplicateCount > 0)
            summary ~= format(", %d already present or queued", _importDuplicateCount);
        if (_importIgnoredCount > 0)
            summary ~= format(", %d unsupported ignored", _importIgnoredCount);
        if (_importFailedCount > 0)
            summary ~= format(", %d failed", _importFailedCount);
        if (_importLastError.length > 0)
            summary ~= " — " ~ _importLastError;
        setStatus(summary ~ ".");
        _importBatchActive = false;
    }

    private void syncMediaList()
    {
        ListItem[] items;
        items.reserve(_model.assets.length);
        const useCounts = _model.assetUseCounts();
        foreach (index, asset; _model.assets)
        {
            const icon = asset.hasVideo ? IconKind.image : IconKind.music;
            string secondary = mediaSecondaryText(asset);
            const uses = useCounts[index];
            if (uses > 0)
                secondary ~= format(" • %d sequence use%s", uses,
                    uses == 1 ? "" : "s");
            items ~= ListItem(asset.name, icon, secondary);
        }
        const previous = _mediaList.selectedIndex();
        _mediaList.setItems(items);
        if (previous >= 0 && previous < cast(int) items.length)
            _mediaList.setSelectedIndex(previous, false);
        if (_model.assets.length == 0)
            _mediaDetails.setText("No media imported");
        updateMediaActionButtons();
    }

    private void updateMediaActionButtons()
    {
        // Project Media uses drag-and-drop and its context menu; no visible
        // duplicate action buttons are kept in the panel.
    }

    private void mediaSelectionChanged(int index)
    {
        // Project Media selection changes details only. Composition Preview is
        // permanently locked to the current sequence and never to source media.
        _lastSelectionIsMedia = false;
        updateMediaActionButtons();
        if (_playbackKind == PlaybackKind.source) stopPlayback(false);
        if (index < 0 || index >= cast(int) _model.assets.length)
        {
            _mediaDetails.setText("No media selected");
            if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
            return;
        }
        const asset = _model.assets[cast(size_t) index];
        _mediaDetails.setText(mediaSecondaryText(asset));
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void mediaActivated(int index)
    {
        if (index < 0 || index >= cast(int) _model.assets.length) return;
        _mediaList.setSelectedIndex(index);
        _lastSelectionIsMedia = false;
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus("Drag the media to the sequence or use the Project Media context menu.");
    }

    private int selectedMediaIndex() const
    {
        const index = _mediaList.selectedIndex();
        return index >= 0 && index < cast(int) _model.assets.length ? index : -1;
    }

    private void addSelectedMediaAutomatically()
    {
        const index = selectedMediaIndex();
        if (index < 0)
        {
            setStatus("Select media in Project Media first.");
            return;
        }
        const asset = _model.assets[cast(size_t) index];
        // Video clips keep their embedded audio inside the V-track item by
        // default. A separate A-track copy is an explicit context-menu action,
        // not an automatic duplicate that forces needless audio mixing/rendering.
        addAssetToTrack(cast(size_t) index,
            TrackAddress(asset.hasVideo ? TrackKind.video : TrackKind.audio, 0),
            false, 0.0);
    }

    private void addSelectedMedia(TrackAddress track)
    {
        const index = selectedMediaIndex();
        if (index < 0)
        {
            setStatus("Select media in Project Media first.");
            return;
        }
        addAssetToTrack(cast(size_t) index, track, false, 0.0);
    }

    private void addAssetToTrack(size_t assetIndex, TrackAddress track,
        bool atSpecificTime, double requestedTime)
    {
        if (assetIndex >= _model.assets.length)
        {
            setStatus("The selected project media is unavailable.");
            return;
        }
        if (!_model.canPlace(assetIndex, track.kind))
        {
            setStatus(track.kind == TrackKind.video
                ? "The selected file has no video stream for that V track."
                : "The selected file has no audio stream for that A track.");
            return;
        }

        auto before = captureTimelineSnapshot(atSpecificTime ? "Place clip" : "Add clip");
        int index;
        if (atSpecificTime)
        {
            // The first sequence item always establishes time zero regardless
            // of where its drag thumbnail was released in an empty timeline.
            if (_model.sequenceDuration() <= 0.000_5) requestedTime = 0.0;
            index = _model.insertClip(assetIndex, track, requestedTime);
        }
        else
            index = _model.appendClip(assetIndex, track);
        if (index < 0)
        {
            setStatus("The clip could not be added to the sequence.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation(format("Added %s to %s at %s.",
            _model.assets[assetIndex].name, track.label(),
            formatTimecode(_model.clipStart(track, index))), track, index, true, true);
    }

    private void addLinkedMedia(size_t assetIndex, bool atPlayhead)
    {
        if (assetIndex >= _model.assets.length) return;
        const asset = _model.assets[assetIndex];
        if (!asset.hasVideo || !asset.hasAudio)
        {
            addAssetToTrack(assetIndex,
                TrackAddress(asset.hasVideo ? TrackKind.video : TrackKind.audio, 0),
                atPlayhead, atPlayhead ? _timeline.playhead() : 0.0);
            return;
        }

        auto before = captureTimelineSnapshot(atPlayhead ?
            "Insert linked video and audio" : "Add linked video and audio");
        const start = atPlayhead ? _timeline.playhead() :
            (_model.familyDuration(TrackKind.video) > _model.familyDuration(TrackKind.audio)
                ? _model.familyDuration(TrackKind.video)
                : _model.familyDuration(TrackKind.audio));
        const videoTrack = TrackAddress(TrackKind.video, 0);
        const audioTrack = TrackAddress(TrackKind.audio, 0);
        const videoIndex = _model.insertClip(assetIndex, videoTrack, start);
        const audioIndex = _model.insertClip(assetIndex, audioTrack, start);
        if (videoIndex < 0 || audioIndex < 0)
        {
            _model.restoreTimelineSnapshot(before.video, before.audio);
            setStatus("The linked video and audio clips could not be added.");
            return;
        }
        // A1 owns this linked source audio, preventing a duplicate mix from V1.
        _model.setMuted(videoTrack, videoIndex, true);
        commitHistory(before);
        afterTimelineMutation(format("Added %s to V1 and A1.", asset.name),
            videoTrack, videoIndex, true, true);
    }

    private TimelineSnapshot captureTimelineSnapshot(string label)
    {
        TimelineSnapshot snapshot;
        snapshot.video = _model.snapshotTracks(TrackKind.video);
        snapshot.audio = _model.snapshotTracks(TrackKind.audio);
        snapshot.selectedTrack = _timeline.selectedTrack();
        snapshot.selectedIndex = _timeline.selectedIndex();
        snapshot.playhead = _timeline.playhead();
        snapshot.label = label;
        return snapshot;
    }

    private void commitHistory(TimelineSnapshot snapshot)
    {
        if (_undo.length >= 32) _undo = _undo[$ - 31 .. $].dup;
        _undo ~= snapshot;
        _redo.length = 0;
    }

    private void clearHistory()
    {
        _undo.length = 0;
        _redo.length = 0;
    }

    private void undo()
    {
        if (_undo.length == 0)
        {
            setStatus("Nothing to undo.");
            return;
        }
        auto snapshot = _undo[$ - 1];
        _undo.length -= 1;
        _redo ~= captureTimelineSnapshot(snapshot.label);
        applyTimelineSnapshot(snapshot, "Undo: " ~ snapshot.label ~ ".");
    }

    private void redo()
    {
        if (_redo.length == 0)
        {
            setStatus("Nothing to redo.");
            return;
        }
        auto snapshot = _redo[$ - 1];
        _redo.length -= 1;
        if (_undo.length >= 32) _undo = _undo[$ - 31 .. $].dup;
        _undo ~= captureTimelineSnapshot(snapshot.label);
        applyTimelineSnapshot(snapshot, "Redo: " ~ snapshot.label ~ ".");
    }

    private void applyTimelineSnapshot(TimelineSnapshot snapshot, string statusText)
    {
        _model.restoreTimelineSnapshot(snapshot.video, snapshot.audio);
        markTimelineChanged();
        _timeline.modelChanged();
        _timeline.setSelection(snapshot.selectedTrack, snapshot.selectedIndex, false);
        _timeline.setPlayhead(snapshot.playhead, false);
        _lastSelectionIsMedia = false;
        syncMediaList();
        syncTimelineRange();
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(statusText);
    }

    private void afterTimelineMutation(string statusText, TrackAddress track,
        int index, bool seekToSelection, bool mediaUsageChanged = false)
    {
        markTimelineChanged();
        // A paused sequence player contains decoder/audio state for the old
        // topology. Discard that stale session immediately while preserving
        // the timeline playhead; the next Play builds the current split/move
        // layout once instead of requiring a retry.
        if (_playbackKind == PlaybackKind.sequence && !_playbackRunning)
        {
            _sequenceRefreshPending = false;
            _sequenceRefreshDelay = 0.0;
            stopPlayback(false);
        }
        _timeline.modelChanged();
        _timeline.setSelection(track, index, false);
        if (seekToSelection && index >= 0)
        {
            const target = _model.clipStart(track, index);
            if (_playbackKind == PlaybackKind.sequence)
            {
                // Never let a selection jump fight an actively advancing
                // transport. When paused, however, update the single shared
                // sequence position so the Preview scrubber and red playhead
                // cannot disagree after adding or placing a clip.
                if (_playbackRunning)
                    _timeline.setPlayhead(_playbackPosition, false);
                else
                {
                    _playbackPosition = target;
                    _seekPending = false;
                    _seekGesture = false;
                    _timeline.setPlayhead(target, false);
                }
            }
            else
                _timeline.setPlayhead(target, false);
        }
        _lastSelectionIsMedia = false;
        if (mediaUsageChanged) syncMediaList();
        syncTimelineRange();
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        if (_playbackKind == PlaybackKind.sequence && _playbackRunning &&
            _sequenceRefreshDeferred)
            statusText ~= " Playback continues; the edit is adopted on Pause/Resume.";
        setStatus(statusText);
    }

    private void markProjectDirty()
    {
        if (_projectDirty) return;
        _projectDirty = true;
        updateProjectTitle();
    }

    /** Edits invalidate cached composition without blocking the editor thread.
     * During sequence playback, rapid property changes are coalesced and the
     * live compositor is refreshed once after the gesture settles. The last
     * decoded frame remains visible while the replacement decoder starts. */
    private void markTimelineChanged()
    {
        markProjectDirty();
        if (_playbackKind == PlaybackKind.none)
        {
            // Keep the last valid frame visible while a replacement is prepared.
            // The pending request coalesces rapid edits and supersedes the old
            // FFmpeg job only when the next frame is actually dispatched.
        }
        else if (_playbackKind == PlaybackKind.sequence)
        {
            if (_playbackRunning)
            {
                // Never stop/restart live video or audio because a clip was
                // moved, resized, split, or otherwise edited. Replacing the
                // FFmpeg graph here caused the exact interruption reported by
                // users. Keep the active snapshot alive and adopt the current
                // model only when playback is paused/resumed or started again.
                _sequenceRefreshDeferred = true;
                _sequenceRefreshPending = false;
                _sequenceRefreshDelay = 0.0;
            }
            else
            {
                _sequenceRefreshPending = true;
                _sequenceRefreshDelay = 0.0;
            }
        }
        ++_modelRevision;
        if (_modelRevision == 0) _modelRevision = 1;
    }

    private void refreshSequenceAfterEdit()
    {
        if (_playbackKind != PlaybackKind.sequence) return;
        if (_playbackRunning)
        {
            // Active playback is intentionally immutable. Editing stays
            // instant and uninterrupted; the current revision is picked up
            // after Pause/Resume or a new Play command.
            _sequenceRefreshDeferred = true;
            return;
        }
        // A manual Play may already have rebuilt the current revision while
        // this coalesced timer was pending. Do not restart that fresh decoder.
        if (_playbackModelRevision == _modelRevision) return;
        const position = _playbackPosition;
        _timeline.setPlayhead(position, false);
        stopPlayback(false);
        _timeline.setPlayhead(position, false);
        scheduleTimelineFrame();
    }

    private bool selectedClip(out TrackAddress track, out int index,
        out TimelineClip clip, out MediaAsset asset)
    {
        track = _timeline.selectedTrack();
        index = _timeline.selectedIndex();
        if (!_model.validTrack(track)) return false;
        if (!_model.copyClip(track, index, clip)) return false;
        asset = _model.assetForClip(clip);
        return clip.isText() || asset !is null;
    }

    private void deleteSelected()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Delete clip");
        if (!_model.removeClip(track, index))
        {
            setStatus("Select a sequence clip to delete.");
            return;
        }
        commitHistory(before);
        const remaining = _model.validTrack(track) ? _model.trackValue(track).clips : null;
        const next = remaining.length == 0 ? -1 :
            (index < cast(int) remaining.length ? index : cast(int) remaining.length - 1);
        afterTimelineMutation("Clip deleted; any current playback continues.",
            track, next, false, true);
    }

    private void duplicateSelected()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Duplicate clip");
        const duplicate = _model.duplicateClip(track, index);
        if (duplicate < 0)
        {
            setStatus("Select a sequence clip to duplicate.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip duplicated.", track, duplicate, false, true);
    }

    private void splitSelected()
    {
        const track = _timeline.selectedTrack();
        auto before = captureTimelineSnapshot("Split clip");
        const rightIndex = _model.splitAt(track, _timeline.playhead());
        if (rightIndex < 0)
        {
            setStatus("Place the playhead inside a clip on the selected track before splitting.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip split at " ~ formatTimecode(_timeline.playhead()) ~ ".",
            track, rightIndex, false, true);
    }

    private void detachSelectedAudio(TrackAddress track, int index)
    {
        _timeline.setSelection(track, index, false);
        auto before = captureTimelineSnapshot("Detach embedded audio");
        TrackAddress audioTrack;
        int audioIndex;
        if (!_model.detachAudioFromVideo(track, index, audioTrack, audioIndex))
        {
            setStatus("The selected video item has no detachable embedded audio.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Embedded audio detached to " ~ audioTrack.label() ~
            "; the video item's embedded audio is muted.",
            audioTrack, audioIndex, false, true);
    }

    private void moveClipRequested(TrackAddress source, int index,
        TrackAddress destination, double start)
    {
        auto before = captureTimelineSnapshot("Move clip");
        int newIndex;
        if (!_model.moveClipToTime(source, index, destination, start, newIndex))
        {
            setStatus("That clip cannot be placed on the requested track.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation(format("Moved clip to %s at %s.", destination.label(),
            formatTimecode(_model.clipStart(destination, newIndex))),
            destination, newIndex, false);
    }

    private void resizeClipRequested(TrackAddress track, int index,
        double start, double end)
    {
        auto before = captureTimelineSnapshot("Resize clip duration");
        int newIndex;
        if (!_model.resizeClipTimeline(track, index, start, end, newIndex))
        {
            setStatus("The clip edge could not be moved farther.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation(format("Clip duration changed to %.2fs.",
            _model.trackValue(track).clips[cast(size_t) newIndex].duration()),
            track, newIndex, false);
    }

    private void copySelected()
    {
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset))
        {
            setStatus("Select a timeline item to copy.");
            return;
        }
        _clipboardClip = clip;
        _clipboardTrack = track;
        _clipboardHasClip = true;
        setStatus("Timeline item copied. Paste places it at the playhead.");
    }

    private void pasteClipboard()
    {
        if (!_clipboardHasClip)
        {
            setStatus("The timeline clipboard is empty.");
            return;
        }
        TrackAddress destination = _timeline.selectedTrack();
        if (_clipboardClip.isText())
        {
            if (destination.kind != TrackKind.video)
                destination = TrackAddress(TrackKind.video, _clipboardTrack.lane);
        }
        else if (!_model.canPlace(_clipboardClip.assetIndex, destination.kind))
            destination = _clipboardTrack;
        auto before = captureTimelineSnapshot("Paste clip");
        const index = _model.pasteClip(destination, _clipboardClip,
            _timeline.playhead());
        if (index < 0)
        {
            setStatus("The copied item cannot be pasted on that track.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Timeline item pasted at the playhead.",
            destination, index, false, true);
    }

    private void moveSelectedToTrack(TrackAddress destination)
    {
        const source = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        if (!_model.validTrack(source) || index < 0)
        {
            setStatus("Select a clip to move.");
            return;
        }
        const start = _model.clipStart(source, index);
        moveClipRequested(source, index, destination, start);
    }

    private void nudgeSelected(double delta)
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Nudge clip");
        int newIndex;
        if (!_model.nudgeClip(track, index, delta, newIndex))
        {
            setStatus("The selected clip could not be moved farther.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip moved.", track, newIndex, false);
    }

    private void cutToolRequested(TrackAddress track, double time)
    {
        auto before = captureTimelineSnapshot("Cut clip");
        const result = _model.splitAt(track, time);
        if (result < 0)
        {
            setStatus("Cut tool: click inside a clip away from its edges.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip cut.", track, result, false, true);
    }

    private void textToolRequested(TrackAddress track, double start, double end)
    {
        if (track.kind != TrackKind.video)
        {
            setStatus("Text tool works on video tracks only.");
            return;
        }
        const duration = end - start;
        if (duration < 0.25)
        {
            setStatus("Drag on a video track to define the text duration.");
            return;
        }
        auto before = captureTimelineSnapshot("Add text clip");
        const index = _model.insertTextClip(track, start, duration, "Text");
        if (index < 0)
        {
            setStatus("Unable to add a text clip at that position.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Text clip added at the dragged duration. Double-click it in Composition Preview to edit.",
            track, index, true, false);
        focusSelectedTextField();
    }

    private void syncInlineTextEffectsForClip(const TimelineClip clip,
        double localTime)
    {
        if (_preview is null) return;
        _preview.syncInlineTextEffects(
            clip.evaluatedValue(EffectProperty.opacity, localTime),
            clip.textBox, formatArgb(clip.textBoxColor),
            clip.strokeWidth, formatArgb(clip.strokeColor),
            clip.shadowOpacity, clip.shadowBlur, clip.shadowOffsetX,
            clip.shadowOffsetY, formatArgb(clip.shadowColor),
            _previewQualityHeight);
    }

    private TitleVisual previewTitleVisual(const TimelineClip clip,
        size_t lane, double sequenceTime)
    {
        const localTime = clampValue(sequenceTime - clip.start,
            0.0, clip.duration());
        double opacity = clip.evaluatedValue(EffectProperty.opacity, localTime);
        if (clip.fadeIn > 0.000_001)
            opacity *= clampValue(localTime / clip.fadeIn, 0.0, 1.0);
        if (clip.fadeOut > 0.000_001)
            opacity *= clampValue((clip.duration() - localTime) /
                clip.fadeOut, 0.0, 1.0);

        TitleVisual visual;
        visual.clipId = clip.id;
        visual.text = clip.text;
        visual.fontName = clip.fontName;
        visual.bold = clip.textBold;
        visual.italic = clip.textItalic;
        visual.underline = clip.textUnderline;
        visual.textAlignment = clip.textAlignment;
        visual.textSize = clip.evaluatedValue(EffectProperty.textSize, localTime);
        visual.textColor = clip.textColor;
        visual.box = clip.textBox;
        visual.boxColor = clip.textBoxColor;
        visual.strokeWidth = clip.strokeWidth;
        visual.strokeColor = clip.strokeColor;
        visual.shadowOpacity = clip.shadowOpacity;
        visual.shadowBlur = clip.shadowBlur;
        visual.shadowOffsetX = clip.shadowOffsetX;
        visual.shadowOffsetY = clip.shadowOffsetY;
        visual.shadowColor = clip.shadowColor;
        visual.opacity = opacity;
        visual.scale = clip.evaluatedValue(EffectProperty.scale, localTime);
        visual.positionX = clip.evaluatedValue(EffectProperty.positionX, localTime);
        visual.positionY = clip.evaluatedValue(EffectProperty.positionY, localTime);
        visual.rotation = clip.evaluatedValue(EffectProperty.rotation, localTime);
        visual.trackIndex = lane;
        return visual;
    }

    /** Synchronize all currently visible text clips as live Aurora layers. */
    private void syncPreviewTitleLayers(double sequenceTime)
    {
        if (_preview is null) return;
        TitleVisual[] titles;
        foreach (lane; 0 .. _model.trackCount(TrackKind.video))
        {
            const address = TrackAddress(TrackKind.video, lane);
            const track = _model.trackValue(address);
            if (track.disabled) continue;
            const index = _model.clipAtTime(address, sequenceTime);
            if (index < 0) continue;
            const clip = track.clips[cast(size_t) index];
            if (!clip.isText()) continue;
            titles ~= previewTitleVisual(clip, lane, sequenceTime);
        }
        const preset = ExportPreset.previewForHeight(_previewQualityHeight);
        _preview.setTitleLayers(titles, preset.width, preset.height);
    }

    private void focusSelectedTextField()
    {
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset) || !clip.isText())
        {
            setStatus("Select a text clip first, or use the Text tool in the Sequence column.");
            return;
        }
        if (_timeline !is null) _timeline.activateSelectionTool();
        if (_inlineTextEditing && _inlineTextTrack == track &&
            _inlineTextIndex == index)
        {
            const localTime = clampValue(_timeline.playhead() - clip.start,
                0.0, clip.duration());
            syncPreviewTitleLayers(_timeline.playhead());
            _preview.beginInlineTextEditing(clip.id, clip.text, clip.fontName,
                clip.evaluatedValue(EffectProperty.textSize, localTime),
                formatArgb(clip.textColor), clip.textBold, clip.textItalic,
                clip.textUnderline, clip.textAlignment, _previewQualityHeight);
            syncInlineTextEffectsForClip(clip, localTime);
            scheduleTimelineFrame();
            return;
        }

        endInlineTextEditing();
        commitHistory(captureTimelineSnapshot("Edit text in Composition Preview"));
        if (!_model.beginContinuousEdit(track)) return;
        _inlineTextEditing = true;
        _inlineTextChanged = false;
        _inlineTextTrack = track;
        _inlineTextIndex = index;
        const localTime = clampValue(_timeline.playhead() - clip.start,
            0.0, clip.duration());
        syncPreviewTitleLayers(_timeline.playhead());
        _preview.beginInlineTextEditing(clip.id, clip.text, clip.fontName,
            clip.evaluatedValue(EffectProperty.textSize, localTime),
            formatArgb(clip.textColor), clip.textBold, clip.textItalic,
            clip.textUnderline, clip.textAlignment, _previewQualityHeight);
        syncInlineTextEffectsForClip(clip, localTime);
        scheduleTimelineFrame();
        setStatus("Edit the live title directly in Composition Preview.");
    }

    private void endInlineTextEditing()
    {
        if (!_inlineTextEditing) return;
        _inlineTextEditing = false;
        _model.endContinuousEdit();
        if (_preview !is null && _preview.inlineTextEditing())
            _preview.endInlineTextEditing(false);
        if (_inlineTextChanged)
        {
            syncInspector();
            scheduleTimelineFrame();
            setStatus("Text edit applied to the selected timeline item.");
        }
        _inlineTextChanged = false;
        _inlineTextIndex = -1;
        syncPreviewTitleLayers(_timeline.playhead());
        scheduleTimelineFrame();
    }

    private bool validInlineTextTarget(out TimelineClip clip)
    {
        if (!_inlineTextEditing || !_model.validTrack(_inlineTextTrack) ||
            _inlineTextIndex < 0) return false;
        if (!_model.copyClip(_inlineTextTrack, _inlineTextIndex, clip) ||
            !clip.isText()) return false;
        return true;
    }

    private void afterInlineTextPropertyChanged(bool changed)
    {
        if (!changed) return;
        _inlineTextChanged = true;
        markTimelineChanged();
        _timeline.visualChanged();
        updatePreviewSelectionOverlay();
        syncInspector();
        syncPreviewTitleLayers(_timeline.playhead());
        // Text, font, size, and color are already painted by the live title
        // surface. Rebuilding the title-free FFmpeg background on every
        // keystroke only caused lag and flashing.
    }

    private void inlineTextChanged(string value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        afterInlineTextPropertyChanged(_model.setText(_inlineTextTrack,
            _inlineTextIndex, value));
    }

    private void inlineFontChanged(string value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        const fontName = canonicalTextFontName(value);
        const changed = _model.setFontName(_inlineTextTrack,
            _inlineTextIndex, fontName);
        if (changed)
        {
            const resolvedPath = textFontFilePath(fontName, clip.textBold,
                clip.textItalic);
            appLog("Inline text font selected: " ~ fontName ~
                (resolvedPath.length > 0 ? " -> " ~ resolvedPath :
                    " -> family lookup"));
        }
        afterInlineTextPropertyChanged(changed);
    }

    private void inlineTextSizeChanged(double value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        // Text size remains a keyable property. If it is already animated,
        // changing the inline value creates/updates the key at the playhead.
        afterInlineTextPropertyChanged(setEffectScalar(EffectProperty.textSize,
            value));
    }

    private void inlineTextColorChanged(string value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        uint color;
        if (!parseArgb(value, color)) return;
        afterInlineTextPropertyChanged(_model.setTextColor(_inlineTextTrack,
            _inlineTextIndex, color));
    }

    private void inlineTextStyleChanged(int style, bool value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        bool changed;
        switch (style)
        {
            case 0: changed = _model.setTextBold(_inlineTextTrack,
                _inlineTextIndex, value); break;
            case 1: changed = _model.setTextItalic(_inlineTextTrack,
                _inlineTextIndex, value); break;
            case 2: changed = _model.setTextUnderline(_inlineTextTrack,
                _inlineTextIndex, value); break;
            default: return;
        }
        afterInlineTextPropertyChanged(changed);
    }

    private void inlineTextAlignmentChanged(TextAlignment value)
    {
        TimelineClip clip;
        if (!validInlineTextTarget(clip)) return;
        afterInlineTextPropertyChanged(_model.setTextAlignment(_inlineTextTrack,
            _inlineTextIndex, value));
    }

    private void activateTimelineClip(TrackAddress track, int index)
    {
        if (!_model.validTrack(track)) return;
        _timeline.setSelection(track, index, false);
        _lastSelectionIsMedia = false;
        syncInspector();
        TimelineClip clip;
        if (!_model.copyClip(track, index, clip)) return;
        _timeline.setPlayhead(clampValue(_timeline.playhead(), clip.start, clip.end()), false);
        if (clip.isText()) focusSelectedTextField();
        else setStatus("Clip selected. Space plays the timeline composition.");
    }

    private bool compositionBounds(const TimelineClip clip, MediaAsset asset,
        double sequenceTime, out double centerX, out double centerY,
        out double width, out double height, out double rotation)
    {
        if (sequenceTime < clip.start || sequenceTime >= clip.end()) return false;
        const localTime = clampValue(sequenceTime - clip.start, 0.0, clip.duration());
        const scale = clip.evaluatedValue(EffectProperty.scale, localTime);
        centerX = clip.evaluatedValue(EffectProperty.positionX, localTime);
        centerY = clip.evaluatedValue(EffectProperty.positionY, localTime);
        rotation = clip.evaluatedValue(EffectProperty.rotation, localTime);
        const preset = ExportPreset.previewForHeight(_previewQualityHeight);
        if (clip.isText())
        {
            size_t lineCount = 1;
            size_t currentCharacters;
            size_t maximumCharacters;
            foreach (character; clip.text)
            {
                if (character == '\n')
                {
                    if (currentCharacters > maximumCharacters)
                        maximumCharacters = currentCharacters;
                    currentCharacters = 0;
                    ++lineCount;
                }
                else ++currentCharacters;
            }
            if (currentCharacters > maximumCharacters) maximumCharacters = currentCharacters;
            if (maximumCharacters == 0) maximumCharacters = 1;
            const textSize = clip.evaluatedValue(EffectProperty.textSize, localTime);
            const pixelWidth = cast(double) maximumCharacters * textSize * 0.60 * scale +
                clip.strokeWidth * 2.0 + 10.0;
            const pixelHeight = cast(double) lineCount * textSize * 1.28 * scale +
                clip.strokeWidth * 2.0 + 8.0;
            width = clampValue(pixelWidth / preset.width * 2.0, 0.02, 4.0);
            height = clampValue(pixelHeight / preset.height * 2.0, 0.02, 4.0);
            return true;
        }
        if (asset is null || !asset.hasVideo || asset.width <= 0 || asset.height <= 0)
            return false;
        const sourceAspect = cast(double) asset.width / asset.height;
        const canvasAspect = cast(double) preset.width / preset.height;
        double pixelWidth;
        double pixelHeight;
        if (sourceAspect >= canvasAspect)
        {
            pixelWidth = preset.width;
            pixelHeight = pixelWidth / sourceAspect;
        }
        else
        {
            pixelHeight = preset.height;
            pixelWidth = pixelHeight * sourceAspect;
        }
        width = pixelWidth / preset.width * 2.0 * scale;
        height = pixelHeight / preset.height * 2.0 * scale;
        return true;
    }

    private bool pointInsideCompositionClip(double x, double y,
        const TimelineClip clip, MediaAsset asset, double sequenceTime)
    {
        double centerX; double centerY; double width; double height; double rotation;
        if (!compositionBounds(clip, asset, sequenceTime, centerX, centerY,
            width, height, rotation)) return false;
        const radians = -rotation * PI / 180.0;
        const dx = x - centerX;
        const dy = y - centerY;
        const localX = dx * cos(radians) - dy * sin(radians);
        const localY = dx * sin(radians) + dy * cos(radians);
        return fabs(localX) <= width * 0.5 && fabs(localY) <= height * 0.5;
    }

    private bool previewCanvasPointerDown(double x, double y, int clickCount)
    {
        const sequenceTime = _timeline.playhead();
        for (size_t lane = _model.trackCount(TrackKind.video); lane > 0; --lane)
        {
            const track = TrackAddress(TrackKind.video, lane - 1);
            const timelineTrack = _model.trackValue(track);
            if (timelineTrack.disabled) continue;
            const index = _model.clipAtTime(track, sequenceTime);
            if (index < 0) continue;
            TimelineClip clip;
            if (!_model.copyClip(track, index, clip)) continue;
            auto asset = _model.assetForClip(clip);
            if (!pointInsideCompositionClip(x, y, clip, asset, sequenceTime)) continue;
            bool repeatedTextClick;
            if (clip.isText())
            {
                repeatedTextClick = _previewTextClickValid &&
                    _previewTextClickTrack == track &&
                    _previewTextClickIndex == index &&
                    (MonoTime.currTime - _previewTextClickStarted)
                        .total!"msecs" <= 500;
                _previewTextClickValid = true;
                _previewTextClickTrack = track;
                _previewTextClickIndex = index;
                _previewTextClickStarted = MonoTime.currTime;
            }
            else
            {
                _previewTextClickValid = false;
                _previewTextClickIndex = -1;
            }
            _timeline.setSelection(track, index, true);
            _lastSelectionIsMedia = false;
            syncInspector();
            if (clip.isText() && (clickCount >= 2 || repeatedTextClick))
                focusSelectedTextField();
            return true;
        }
        _previewTextClickValid = false;
        _previewTextClickIndex = -1;
        if (clickCount < 2)
        {
            _timeline.setSelection(_timeline.selectedTrack(), -1, true);
            syncInspector();
        }
        return false;
    }

    private void updatePreviewSelectionOverlay()
    {
        if (_preview is null || _timeline is null) return;
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset) || track.kind != TrackKind.video)
        {
            _preview.setSelectionOverlay(false);
            return;
        }
        double centerX; double centerY; double width; double height; double rotation;
        if (!compositionBounds(clip, asset, _timeline.playhead(), centerX, centerY,
            width, height, rotation))
        {
            _preview.setSelectionOverlay(false);
            return;
        }
        _preview.setSelectionOverlay(true, centerX, centerY, width, height,
            rotation, clip.isText());
    }

    private void beginCanvasTransformDrag()
    {
        if (_canvasDragEditing) return;
        const track = _timeline.selectedTrack();
        if (track.kind != TrackKind.video || _timeline.selectedIndex() < 0) return;
        _canvasDragSnapshot = captureTimelineSnapshot("Move composition item");
        _canvasDragChanged = false;
        _canvasDragEditing = _model.beginContinuousEdit(track);
    }

    private void endCanvasTransformDrag()
    {
        if (!_canvasDragEditing) return;
        _canvasDragEditing = false;
        _model.endContinuousEdit();
        if (!_canvasDragChanged) return;
        commitHistory(_canvasDragSnapshot);
        markTimelineChanged();
        _timeline.visualChanged();
        syncInspector();
        scheduleTimelineFrame();
        setStatus("Composition item moved.");
    }

    private void nudgeSelectedClipOnCanvas(double normalizedDx, double normalizedDy)
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        if (track.kind != TrackKind.video) return;
        TimelineClip clip;
        MediaAsset asset;
        TrackAddress ignoredTrack;
        int ignoredIndex;
        if (!selectedClip(ignoredTrack, ignoredIndex, clip, asset)) return;
        const newX = clip.positionX + normalizedDx;
        const newY = clip.positionY + normalizedDy;
        bool changed;
        changed = _model.setPositionX(track, index, newX) || changed;
        changed = _model.setPositionY(track, index, newY) || changed;
        if (!changed) return;
        if (_canvasDragEditing)
        {
            _canvasDragChanged = true;
            _positionX.setValue(clampValue(newX, -2.0, 2.0), false);
            _positionXValue.setText(format("%+.2f", clampValue(newX, -2.0, 2.0)));
            _positionY.setValue(clampValue(newY, -2.0, 2.0), false);
            _positionYValue.setText(format("%+.2f", clampValue(newY, -2.0, 2.0)));
            updatePreviewSelectionOverlay();
            return;
        }
        markTimelineChanged();
        _timeline.visualChanged();
        syncInspector();
        updatePreviewSelectionOverlay();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void setWorkIn(double value)
    {
        _hasWorkIn = true;
        _workIn = value < 0.0 ? 0.0 : value;
        if (_hasWorkOut && _workOut < _workIn) _workOut = _workIn;
        syncTimelineWorkArea();
        markProjectDirty();
        setStatus("Export range in set to " ~ formatTimecode(_workIn) ~ ".");
    }

    private void setWorkOut(double value)
    {
        const addedImplicitIn = !_hasWorkIn;
        if (addedImplicitIn)
        {
            _hasWorkIn = true;
            _workIn = 0.0;
        }
        _hasWorkOut = true;
        _workOut = value < 0.0 ? 0.0 : value;
        if (_workOut < _workIn) _workIn = _workOut;
        syncTimelineWorkArea();
        markProjectDirty();
        if (addedImplicitIn)
            setStatus("Export range set from timeline start to " ~
                formatTimecode(_workOut) ~ ".");
        else
            setStatus("Export range out set to " ~ formatTimecode(_workOut) ~ ".");
    }

    private void clearWorkRange()
    {
        _hasWorkIn = false;
        _hasWorkOut = false;
        _workIn = 0.0;
        _workOut = 0.0;
        syncTimelineWorkArea();
        markProjectDirty();
        setStatus("Export range cleared.");
    }

    private void syncTimelineWorkArea()
    {
        if (_timeline !is null) _timeline.setWorkArea(_hasWorkIn, _workIn, _hasWorkOut, _workOut);
    }

    private void addTrack(TrackKind kind)
    {
        auto before = captureTimelineSnapshot(kind == TrackKind.video ?
            "Add video track" : "Add audio track");
        const lane = _model.addTrack(kind);
        commitHistory(before);
        const address = TrackAddress(kind, lane);
        afterTimelineMutation("Added " ~ address.label() ~ ".", address, -1, false);
    }

    private void removeTrack(TrackAddress address)
    {
        auto before = captureTimelineSnapshot("Remove track");
        if (!_model.removeTrack(address, false))
        {
            setStatus("Only empty non-primary tracks can be removed.");
            return;
        }
        commitHistory(before);
        const nextLane = address.lane > 0 ? address.lane - 1 : 0;
        afterTimelineMutation("Removed " ~ address.label() ~ ".",
            TrackAddress(address.kind, nextLane), -1, false);
    }

    private void toggleTrackMuted(TrackAddress address)
    {
        if (!_model.validTrack(address)) return;
        const current = _model.trackValue(address).muted;
        auto before = captureTimelineSnapshot(current ? "Unmute track" : "Mute track");
        if (!_model.setTrackMuted(address, !current)) return;
        commitHistory(before);
        afterTimelineMutation(current ? "Track unmuted." :
            "Track muted; current playback continues.", address,
            _timeline.selectedTrack() == address ? _timeline.selectedIndex() : -1, false);
        // Only the PCM audio output is refreshed. The embedded video decoder
        // and playhead continue uninterrupted.
        queueSourceAudioRefresh();
    }

    private void toggleTrackDisabled(TrackAddress address)
    {
        if (!_model.validTrack(address)) return;
        const current = _model.trackValue(address).disabled;
        auto before = captureTimelineSnapshot(current ? "Enable track" : "Disable track");
        if (!_model.setTrackDisabled(address, !current)) return;
        commitHistory(before);
        afterTimelineMutation(current ? "Track enabled." :
            "Track disabled; current playback continues.", address,
            _timeline.selectedTrack() == address ? _timeline.selectedIndex() : -1, false);
        queueSourceAudioRefresh();
    }

    private void adjustTrim(bool trimIn, double delta)
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot(trimIn ? "Adjust trim in" : "Adjust trim out");
        const changed = trimIn ? _model.adjustTrimIn(track, index, delta) :
            _model.adjustTrimOut(track, index, delta);
        if (!changed)
        {
            setStatus("The trim limit was reached.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation(trimIn ? "Trim-in updated." : "Trim-out updated.",
            track, index, false);
    }

    private void resetSelectedTrim()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Reset clip trim");
        if (!_model.resetTrim(track, index))
        {
            setStatus("The selected clip already uses its available source range.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip trim reset.", track, index, false);
    }

    private void resetSelectedAudio()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Reset clip audio");
        if (!_model.resetAudio(track, index))
        {
            setStatus("The selected clip audio already uses default settings.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip audio reset.", track, index, false);
        queueSourceAudioRefresh();
    }

    private void resetSelectedTransform()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Reset clip transform");
        if (!_model.resetTransform(track, index))
        {
            setStatus("The selected clip transform already uses default settings.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Clip transform reset.", track, index, false);
    }

    private void resetSelectedProperties()
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Reset all clip properties");
        if (!_model.resetAllProperties(track, index))
        {
            setStatus("The selected clip already uses default effects and properties.");
            return;
        }
        commitHistory(before);
        afterTimelineMutation("All clip effects and properties reset to defaults.",
            track, index, false);
        queueSourceAudioRefresh();
    }

    private bool keyframePropertyAvailable(EffectProperty property,
        bool valid, TrackAddress track, const TimelineClip clip, MediaAsset asset) const
    {
        if (!valid) return false;
        final switch (property)
        {
            case EffectProperty.volume:
                return !clip.isText() && asset !is null && asset.hasAudio;
            case EffectProperty.scale:
            case EffectProperty.positionX:
            case EffectProperty.positionY:
            case EffectProperty.opacity:
            case EffectProperty.rotation:
                return track.kind == TrackKind.video;
            case EffectProperty.textSize:
                return clip.isText();
        }
    }

    private void syncKeyframeButtons(bool valid, TrackAddress track,
        const TimelineClip clip, MediaAsset asset)
    {
        double localTime;
        if (valid)
            localTime = clampValue(_timeline.playhead() - clip.start,
                0.0, clip.duration());
        foreach (propertyIndex; 0 .. _keyframeButtons.length)
        {
            auto button = _keyframeButtons[propertyIndex];
            if (button is null) continue;
            const property = cast(EffectProperty) propertyIndex;
            const enabled = keyframePropertyAvailable(property, valid,
                track, clip, asset);
            button.setEnabled(enabled);
            button.setText(enabled && clip.hasKeyframe(property, localTime, 0.02)
                ? "◆ Key" : "◇ Key");
        }
    }

    private void toggleEffectKeyframe(EffectProperty property)
    {
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset) ||
            !keyframePropertyAvailable(property, true, track, clip, asset))
            return;

        const localTime = clampValue(_timeline.playhead() - clip.start,
            0.0, clip.duration());
        auto before = captureTimelineSnapshot("Toggle effect keyframe");
        bool changed;
        string action;
        if (clip.hasKeyframe(property, localTime, 0.02))
        {
            changed = _model.removeKeyframe(track, index, property,
                localTime, 0.02);
            action = "Effect keyframe removed.";
        }
        else
        {
            changed = _model.setKeyframe(track, index, property,
                localTime, clip.evaluatedValue(property, localTime));
            action = "Effect keyframe added at the playhead.";
        }
        if (!changed) return;
        commitHistory(before);
        markTimelineChanged();
        _timeline.visualChanged();
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(action);
    }

    private void beginScalarEdit(string label)
    {
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset)) return;
        commitHistory(captureTimelineSnapshot(label));
        _model.beginContinuousEdit(track);
    }

    private bool setEffectScalar(EffectProperty property, double value)
    {
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (!selectedClip(track, index, clip, asset) ||
            !keyframePropertyAvailable(property, true, track, clip, asset))
            return false;
        const localTime = clampValue(_timeline.playhead() - clip.start,
            0.0, clip.duration());
        bool animated;
        foreach (keyframe; clip.keyframes)
            if (keyframe.property == property) { animated = true; break; }
        // Once a property is animated, editing it at another playhead time
        // automatically creates the corresponding marked keyframe. A property
        // with no animation still behaves as a simple constant value.
        if (animated || clip.hasKeyframe(property, localTime, 0.02))
            return _model.setKeyframe(track, index, property, localTime, value);
        final switch (property)
        {
            case EffectProperty.volume: return _model.setVolume(track, index, value);
            case EffectProperty.scale: return _model.setScale(track, index, value);
            case EffectProperty.positionX: return _model.setPositionX(track, index, value);
            case EffectProperty.positionY: return _model.setPositionY(track, index, value);
            case EffectProperty.opacity: return _model.setOpacity(track, index, value);
            case EffectProperty.rotation: return _model.setRotation(track, index, value);
            case EffectProperty.textSize: return _model.setTextSize(track, index, value);
        }
    }

    private void volumeChanged(double db)
    {
        const gain = dbToGain(db);
        if (setEffectScalar(EffectProperty.volume, gain))
        {
            markTimelineChanged();
            _volumeValue.setText(formatDb(db));
            _timeline.visualChanged();
            queueSourceAudioRefresh();
        }
    }

    private void scaleChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.scale, value), _scaleValue,
            format("%.2fx", value));
    }

    private void positionXChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.positionX, value), _positionXValue,
            format("%+.2f", value));
    }

    private void positionYChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.positionY, value), _positionYValue,
            format("%+.2f", value));
    }

    private void opacityChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.opacity, value), _opacityValue,
            format("%d%%", cast(int) (value * 100.0 + 0.5)));
    }

    private void rotationChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.rotation, value), _rotationValue,
            format("%+.0f°", value));
    }

    private void fadeInChanged(double value)
    {
        scalarTransformChanged(_model.setFadeIn(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _fadeInValue,
            format("%.2fs", value));
    }

    private void fadeOutChanged(double value)
    {
        scalarTransformChanged(_model.setFadeOut(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _fadeOutValue,
            format("%.2fs", value));
    }

    private void textSizeChanged(double value)
    {
        scalarTransformChanged(setEffectScalar(EffectProperty.textSize, value), _textSizeValue,
            format("%.0f", value));
    }

    private void textFieldChanged()
    {
        if (_syncingInspector || _textField is null) return;
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        if (_model.setText(track, index, _textField.textUtf8()))
        {
            markTimelineChanged();
            _timeline.modelChanged();
            if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
            setStatus("Text updated.");
        }
    }

    private void syncTextAlignmentButtons(TextAlignment value, bool enabled)
    {
        if (_textAlignLeft is null) return;
        _textAlignLeft.setEnabled(enabled);
        _textAlignCenter.setEnabled(enabled);
        _textAlignRight.setEnabled(enabled);
        _textAlignLeft.setAccent(enabled && value == TextAlignment.left);
        _textAlignCenter.setAccent(enabled && value == TextAlignment.center);
        _textAlignRight.setAccent(enabled && value == TextAlignment.right);
    }

    private void textAlignmentChanged(TextAlignment value)
    {
        if (_syncingInspector) return;
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot("Change text alignment");
        if (!_model.setTextAlignment(track, index, value))
        {
            syncInspector();
            return;
        }
        commitHistory(before);
        afterTimelineMutation("Text alignment set to " ~
            textAlignmentLabel(value) ~ ".", track, index, false);
    }

    private void styleScalarChanged(bool changed, InspectorValueField valueLabel, string text)
    {
        if (!changed) return;
        valueLabel.setText(text);
        markTimelineChanged();
        _timeline.visualChanged();
        updatePreviewSelectionOverlay();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void blurChanged(double value)
    {
        styleScalarChanged(_model.setBlur(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _blurValue, format("%.1f", value));
    }

    private void shadowOpacityChanged(double value)
    {
        styleScalarChanged(_model.setShadowOpacity(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _shadowOpacityValue,
            format("%d%%", cast(int) (value * 100.0 + 0.5)));
    }

    private void shadowBlurChanged(double value)
    {
        styleScalarChanged(_model.setShadowBlur(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _shadowBlurValue, format("%.1f", value));
    }

    private void shadowOffsetXChanged(double value)
    {
        styleScalarChanged(_model.setShadowOffsetX(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _shadowOffsetXValue, format("%+.0f px", value));
    }

    private void shadowOffsetYChanged(double value)
    {
        styleScalarChanged(_model.setShadowOffsetY(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _shadowOffsetYValue, format("%+.0f px", value));
    }

    private void strokeWidthChanged(double value)
    {
        styleScalarChanged(_model.setStrokeWidth(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value), _strokeWidthValue, format("%.1f px", value));
    }

    private void fontFieldChanged()
    {
        if (_syncingInspector || _fontField is null) return;
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        const fontName = canonicalTextFontName(_fontField.textUtf8());
        // The dropdown label mirrors the canonical model value immediately;
        // it is no longer a generic "Fonts" button that can look reset.
        if (_fontPresetButton !is null)
            _fontPresetButton.setText(fontName ~ " ▾");
        if (_model.setFontName(track, index, fontName))
        {
            TimelineClip clip;
            string resolvedPath;
            if (_model.copyClip(track, index, clip))
                resolvedPath = textFontFilePath(fontName, clip.textBold,
                    clip.textItalic);
            appLog("Text font selected: " ~ fontName ~
                (resolvedPath.length > 0 ? " -> " ~ resolvedPath :
                    " -> family lookup"));
            markTimelineChanged();
            updatePreviewSelectionOverlay();
            // Keep an active inline editor synchronized from the model rather
            // than letting its local button overwrite the selected family.
            if (_inlineTextEditing && track == _inlineTextTrack &&
                index == _inlineTextIndex && _model.copyClip(track, index, clip))
            {
                const localTime = clampValue(_timeline.playhead() - clip.start,
                    0.0, clip.duration());
                _preview.syncInlineTextStyle(clip.text, clip.fontName,
                    clip.evaluatedValue(EffectProperty.textSize, localTime),
                    formatArgb(clip.textColor), clip.textBold, clip.textItalic,
                    clip.textUnderline, clip.textAlignment,
                    _previewQualityHeight);
            }
            if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
            setStatus(resolvedPath.length > 0 ?
                "Text font changed to " ~ fontName ~ " using its exact font file." :
                "Text font changed to " ~ fontName ~ ".");
        }
    }

    private void updateTextColor(TextField field, bool shadow, bool stroke)
    {
        if (_syncingInspector || field is null) return;
        uint value;
        if (!parseArgb(field.textUtf8(), value)) return;
        bool changed;
        if (shadow) changed = _model.setShadowColor(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value);
        else if (stroke) changed = _model.setStrokeColor(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value);
        else changed = _model.setTextColor(_timeline.selectedTrack(),
            _timeline.selectedIndex(), value);
        if (!changed) return;
        markTimelineChanged();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void textColorFieldChanged() { updateTextColor(_textColorField, false, false); }
    private void shadowColorFieldChanged() { updateTextColor(_shadowColorField, true, false); }
    private void strokeColorFieldChanged() { updateTextColor(_strokeColorField, false, true); }

    private void textBoxChanged(bool value)
    {
        if (_syncingInspector) return;
        if (_model.setTextBox(_timeline.selectedTrack(), _timeline.selectedIndex(), value))
        {
            markTimelineChanged();
            if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        }
    }

    private void setFontPreset(string requestedFont)
    {
        if (_fontField is null) return;
        const fontName = canonicalTextFontName(requestedFont);
        _fontField.setText(fontName, false);
        if (_fontPresetButton !is null)
            _fontPresetButton.setText(fontName ~ " ▾");
        fontFieldChanged();
    }

    /** Create a menu callback outside the foreach frame. D otherwise captures
     * the reused loop variable and every font command resolves to the final
     * item in the array. */
    private ContextMenuItem inspectorFontMenuItem(string requestedFont,
        string currentFont)
    {
        string capturedFont = requestedFont.idup;
        return ContextMenuItem.check(capturedFont,
            currentFont == capturedFont,
            delegate() { setFontPreset(capturedFont); });
    }

    private void showFontContextMenu(Point point)
    {
        ContextMenuItem[] items;
        string current = "Sans";
        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        if (selectedClip(track, index, clip, asset) && clip.isText())
            current = canonicalTextFontName(clip.fontName);
        foreach (fontName; textFontFamilies)
            items ~= inspectorFontMenuItem(fontName, current);
        showContextMenu(_fontPresetButton, point, items);
    }

    private void audioProxyVisibilityChanged(bool value)
    {
        if (_syncingInspector) return;
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot(value ?
            "Show embedded audio lane" : "Hide embedded audio lane");
        if (_model.setClipAudioProxyVisible(track, index, value))
        {
            commitHistory(before);
            afterTimelineMutation(value ?
                "Embedded audio is shown on A1 for that video clip." :
                "Embedded audio display hidden.", track, index, false);
        }
    }

    private void scalarTransformChanged(bool changed, InspectorValueField valueLabel, string text)
    {
        if (!changed) return;
        valueLabel.setText(text);
        markTimelineChanged();
        _timeline.visualChanged();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void muteChanged(bool value)
    {
        const track = _timeline.selectedTrack();
        const index = _timeline.selectedIndex();
        auto before = captureTimelineSnapshot(value ? "Mute clip" : "Unmute clip");
        if (_model.setMuted(track, index, value))
        {
            commitHistory(before);
            afterTimelineMutation(value ?
                "Clip muted; current playback continues." : "Clip unmuted.",
                track, index, false);
            queueSourceAudioRefresh();
        }
    }

    private void setClipMuted(TrackAddress track, int index, bool value)
    {
        _timeline.setSelection(track, index, false);
        syncInspector();
        auto before = captureTimelineSnapshot(value ? "Mute clip" : "Unmute clip");
        if (!_model.setMuted(track, index, value)) return;
        commitHistory(before);
        afterTimelineMutation(value ?
            "Clip muted; current playback continues." : "Clip unmuted.",
            track, index, false);
        queueSourceAudioRefresh();
    }

    private void setClipGainDb(TrackAddress track, int index, double db)
    {
        _timeline.setSelection(track, index, false);
        syncInspector();
        auto before = captureTimelineSnapshot("Change clip audio gain");
        if (!_model.setVolume(track, index, dbToGain(db))) return;
        commitHistory(before);
        afterTimelineMutation("Clip audio gain set to " ~ formatDb(db) ~ ".",
            track, index, false);
        queueSourceAudioRefresh();
    }

    private void adjustClipGainDb(TrackAddress track, int index, double delta)
    {
        TimelineClip clip;
        if (!_model.copyClip(track, index, clip)) return;
        setClipGainDb(track, index,
            clampValue(gainToDb(clip.volume) + delta, -60.0, 12.0));
    }

    private void syncInspector()
    {
        _syncingInspector = true;
        scope (exit) _syncingInspector = false;

        TrackAddress track;
        int index;
        TimelineClip clip;
        MediaAsset asset;
        const valid = selectedClip(track, index, clip, asset);
        const transformEnabled = valid && track.kind == TrackKind.video;
        const textEnabled = valid && clip.isText();
        const hasAudio = valid && !clip.isText() && asset !is null && asset.hasAudio;
        const hasAudioProxy = hasAudio && track.kind == TrackKind.video;

        _inspectorScope.setText(valid
            ? format("%s • playhead %s", track.label(),
                formatTimecode(_timeline.playhead()))
            : "Select one timeline item");
        // Source trimming belongs to direct timeline edge operations, not the
        // effects/keyframe Inspector. Keep this legacy section permanently hidden.
        _inspectorSourceSection.setVisible(false);
        _inspectorAudioSection.setVisible(hasAudio);
        _inspectorTransformSection.setVisible(transformEnabled);
        _inspectorLayerSection.setVisible(transformEnabled);
        _inspectorFadeSection.setVisible(valid);
        _inspectorTextSection.setVisible(textEnabled);
        _resetAllPropertiesButton.setVisible(valid);

        foreach (button; _clipControls) button.setEnabled(valid);
        _volume.setEnabled(hasAudio);
        _mute.setEnabled(hasAudio);
        _scale.setEnabled(transformEnabled);
        _positionX.setEnabled(transformEnabled);
        _positionY.setEnabled(transformEnabled);
        _opacity.setEnabled(transformEnabled);
        _rotation.setEnabled(transformEnabled);
        _fadeIn.setEnabled(valid);
        _fadeOut.setEnabled(valid);
        _textField.setEnabled(textEnabled);
        _textSize.setEnabled(textEnabled);
        _blur.setEnabled(transformEnabled);
        _fontField.setEnabled(textEnabled);
        _fontPresetButton.setEnabled(textEnabled);
        syncTextAlignmentButtons(textEnabled ? clip.textAlignment :
            TextAlignment.left, textEnabled);
        _textColorField.setEnabled(textEnabled);
        _textBox.setEnabled(textEnabled);
        _strokeWidth.setEnabled(transformEnabled);
        _strokeColorField.setEnabled(transformEnabled);
        _shadowOpacity.setEnabled(transformEnabled);
        _shadowBlur.setEnabled(transformEnabled);
        _shadowOffsetX.setEnabled(transformEnabled);
        _shadowOffsetY.setEnabled(transformEnabled);
        _shadowColorField.setEnabled(transformEnabled);
        _audioProxyVisible.setEnabled(hasAudioProxy);

        if (!valid)
        {
            _inspectorTitle.setText("No clip selected");
            _inspectorSource.setText("Select a clip on any V or A track.");
            _inspectorTrim.setText("In 00:00:00.000 • Out 00:00:00.000");
            _inspectorDuration.setText("Duration 00:00:00.000");
            _volume.setValue(0.0, false);
            _volumeValue.setText("0.0 dB");
            _mute.setChecked(false, false);
            _scale.setValue(1.0, false);
            _scaleValue.setText("1.00x");
            _positionX.setValue(0.0, false);
            _positionXValue.setText("+0.00");
            _positionY.setValue(0.0, false);
            _positionYValue.setText("+0.00");
            _opacity.setValue(1.0, false);
            _opacityValue.setText("100%");
            _rotation.setValue(0.0, false);
            _rotationValue.setText("+0°");
            _fadeIn.setValue(0.0, false);
            _fadeInValue.setText("0.00s");
            _fadeOut.setValue(0.0, false);
            _fadeOutValue.setText("0.00s");
            _textField.setText("", false);
            _textSize.setValue(96.0, false);
            _textSizeValue.setText("96");
            _blur.setValue(0.0, false);
            _blurValue.setText("0.0");
            _fontField.setText("", false);
            _fontPresetButton.setText("Font ▾");
            syncTextAlignmentButtons(TextAlignment.left, false);
            _textColorField.setText("", false);
            _textBox.setChecked(false, false);
            _strokeWidth.setValue(0.0, false);
            _strokeWidthValue.setText("0.0 px");
            _strokeColorField.setText("", false);
            _shadowOpacity.setValue(0.0, false);
            _shadowOpacityValue.setText("0%");
            _shadowBlur.setValue(12.0, false);
            _shadowBlurValue.setText("12.0");
            _shadowOffsetX.setValue(12.0, false);
            _shadowOffsetXValue.setText("+12 px");
            _shadowOffsetY.setValue(12.0, false);
            _shadowOffsetYValue.setText("+12 px");
            _shadowColorField.setText("", false);
            _audioProxyVisible.setChecked(false, false);
            syncKeyframeButtons(false, track, clip, asset);
            updatePreviewSelectionOverlay();
            return;
        }

        _inspectorTitle.setText(format("%s • %s", track.label(),
            clip.isText() ? "Text" : asset.name));
        if (clip.isText())
            _inspectorSource.setText("Generated composition layer");
        else
            _inspectorSource.setText(mediaSecondaryText(asset));
        _inspectorTrim.setText(format("In %s • Out %s",
            formatTimecode(clip.inPoint), formatTimecode(clip.outPoint)));
        _inspectorDuration.setText(format("Start %s • Duration %s",
            formatTimecode(clip.start), formatTimecode(clip.duration())));
        const localTime = clampValue(_timeline.playhead() - clip.start,
            0.0, clip.duration());
        const evaluatedGain = clip.evaluatedValue(EffectProperty.volume, localTime);
        const clipDb = gainToDb(evaluatedGain);
        _volume.setValue(clipDb, false);
        _volumeValue.setText(formatDb(clipDb));
        _mute.setChecked(clip.muted, false);
        const evaluatedScale = clip.evaluatedValue(EffectProperty.scale, localTime);
        _scale.setValue(evaluatedScale, false);
        _scaleValue.setText(format("%.2fx", evaluatedScale));
        const evaluatedX = clip.evaluatedValue(EffectProperty.positionX, localTime);
        _positionX.setValue(evaluatedX, false);
        _positionXValue.setText(format("%+.2f", evaluatedX));
        const evaluatedY = clip.evaluatedValue(EffectProperty.positionY, localTime);
        _positionY.setValue(evaluatedY, false);
        _positionYValue.setText(format("%+.2f", evaluatedY));
        const evaluatedOpacity = clip.evaluatedValue(EffectProperty.opacity, localTime);
        _opacity.setValue(evaluatedOpacity, false);
        _opacityValue.setText(format("%d%%",
            cast(int) (evaluatedOpacity * 100.0 + 0.5)));
        const evaluatedRotation = clip.evaluatedValue(EffectProperty.rotation, localTime);
        _rotation.setValue(evaluatedRotation, false);
        _rotationValue.setText(format("%+.0f°", evaluatedRotation));
        _fadeIn.setRange(0.0, clip.duration() > clip.fadeOut ? clip.duration() - clip.fadeOut : 0.0);
        _fadeIn.setValue(clip.fadeIn, false);
        _fadeInValue.setText(format("%.2fs", clip.fadeIn));
        _fadeOut.setRange(0.0, clip.duration() > clip.fadeIn ? clip.duration() - clip.fadeIn : 0.0);
        _fadeOut.setValue(clip.fadeOut, false);
        _fadeOutValue.setText(format("%.2fs", clip.fadeOut));
        _textField.setText(textEnabled ? clip.text : "", false);
        const evaluatedTextSize = clip.evaluatedValue(EffectProperty.textSize, localTime);
        _textSize.setValue(evaluatedTextSize, false);
        _textSizeValue.setText(format("%.0f", evaluatedTextSize));
        _blur.setValue(clip.blur, false);
        _blurValue.setText(format("%.1f", clip.blur));
        _fontField.setText(textEnabled ? clip.fontName : "", false);
        _fontPresetButton.setText(textEnabled ?
            canonicalTextFontName(clip.fontName) ~ " ▾" : "Font ▾");
        syncTextAlignmentButtons(textEnabled ? clip.textAlignment :
            TextAlignment.left, textEnabled);
        _textColorField.setText(textEnabled ? formatArgb(clip.textColor) : "", false);
        _textBox.setChecked(textEnabled && clip.textBox, false);
        _strokeWidth.setValue(clip.strokeWidth, false);
        _strokeWidthValue.setText(format("%.1f px", clip.strokeWidth));
        _strokeColorField.setText(transformEnabled ? formatArgb(clip.strokeColor) : "", false);
        _shadowOpacity.setValue(clip.shadowOpacity, false);
        _shadowOpacityValue.setText(format("%d%%",
            cast(int) (clip.shadowOpacity * 100.0 + 0.5)));
        _shadowBlur.setValue(clip.shadowBlur, false);
        _shadowBlurValue.setText(format("%.1f", clip.shadowBlur));
        _shadowOffsetX.setValue(clip.shadowOffsetX, false);
        _shadowOffsetXValue.setText(format("%+.0f px", clip.shadowOffsetX));
        _shadowOffsetY.setValue(clip.shadowOffsetY, false);
        _shadowOffsetYValue.setText(format("%+.0f px", clip.shadowOffsetY));
        _shadowColorField.setText(transformEnabled ? formatArgb(clip.shadowColor) : "", false);
        _audioProxyVisible.setChecked(hasAudioProxy && clip.audioProxyVisible, false);
        syncKeyframeButtons(true, track, clip, asset);
        if (_inlineTextEditing && textEnabled && track == _inlineTextTrack &&
            index == _inlineTextIndex)
        {
            _preview.syncInlineTextStyle(clip.text, clip.fontName, evaluatedTextSize,
                formatArgb(clip.textColor), clip.textBold, clip.textItalic,
                clip.textUnderline, clip.textAlignment, _previewQualityHeight);
            syncInlineTextEffectsForClip(clip, localTime);
        }
        updatePreviewSelectionOverlay();
    }

    private void timelineSelectionChanged(TrackAddress track, int index)
    {
        if (_inlineTextEditing && (track != _inlineTextTrack ||
            index != _inlineTextIndex))
            endInlineTextEditing();
        if (index >= 0) _lastSelectionIsMedia = false;
        // A new item has a different applicable property set. Start at the top
        // instead of leaving the user inside a hidden/lower section from the
        // previously selected item.
        if (_inspectorScroll !is null) _inspectorScroll.setScrollY(0);
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
    }

    private void beginSeekGesture()
    {
        _seekGesture = true;
    }

    private void endSeekGesture()
    {
        _seekGesture = false;
        if (_seekPending) commitPendingSeek();
    }

    private void scrubChanged(double value)
    {
        if (_playbackKind != PlaybackKind.none)
        {
            seekPlayback(value);
            return;
        }
        _lastSelectionIsMedia = false;
        _timeline.setPlayhead(value);
    }

    private void playheadChanged(double value)
    {
        _lastSelectionIsMedia = false;
        _scrub.setValue(value, false);
        updateTimeLabel();
        if (_timeline.selectedIndex() >= 0) syncInspector();
        if (_playbackKind == PlaybackKind.sequence)
            seekPlayback(value);
        else if (_playbackKind == PlaybackKind.none)
            scheduleTimelineFrame();
    }

    private void syncTimelineRange()
    {
        syncTimelineWorkArea();
        const duration = _model.sequenceDuration();

        // Composition Preview and Sequence must always share the exact same
        // 00:00:00-based ruler. Starting playback from the current playhead
        // must not redefine the Preview scrubber's visual origin.
        if (_playbackKind == PlaybackKind.sequence)
        {
            const maximum = duration > 0.001 ? duration : 0.001;
            _playbackPosition = clampValue(_playbackPosition, 0.0, maximum);
            // One authoritative sequence position drives both transport views.
            // This also repairs any stale state left by a model mutation while
            // playback was paused.
            _timeline.setPlayhead(_playbackPosition, false);
            _scrub.setRange(0.0, maximum);
            _scrub.setValue(_playbackPosition, false);
        }
        else if (_playbackKind != PlaybackKind.none)
        {
            _scrub.setRange(_playbackStart,
                _playbackEnd > _playbackStart ? _playbackEnd : _playbackStart + 0.001);
            _scrub.setValue(_playbackPosition, false);
        }
        else
        {
            _scrub.setRange(0.0, duration > 0.001 ? duration : 0.001);
            _scrub.setValue(_timeline.playhead(), false);
        }
        updateTimeLabel();
    }

    private void updateTimeLabel()
    {
        if (_timeLabel is null) return;
        string next;
        if (_playbackKind != PlaybackKind.none && _playbackAsset !is null)
            next = format("%s / %s", formatTimecode(_playbackPosition),
                formatTimecode(_playbackEnd));
        else
        {
            const duration = _model.sequenceDuration();
            next = format("%s / %s", formatTimecode(_timeline.playhead()),
                formatTimecode(duration));
        }
        if (next == _lastTimeText) return;
        _lastTimeText = next;
        _timeLabel.setText(next);
    }

    private void scheduleTimelineFrame()
    {
        if (_playbackKind != PlaybackKind.none) return;
        if (_model.sequenceDuration() <= 0.0)
        {
            TitleVisual[] noTitles;
            _preview.setTitleLayers(noTitles, 1920, 1080);
            _preview.setMessage("Import MP4 or MP3 media to begin");
            _pendingPreviewKind = PendingPreviewKind.none;
            return;
        }
        const nextTime = _timeline.playhead();
        syncPreviewTitleLayers(nextTime);
        const samePendingFrame = _pendingPreviewKind == PendingPreviewKind.sequence &&
            fabs(_pendingPreviewTime - nextTime) < 0.000_5;
        _pendingPreviewKind = PendingPreviewKind.sequence;
        _pendingPreviewTime = nextTime;
        // Do not restart the debounce timer on every slider pixel or keystroke.
        // Long gestures therefore refresh repeatedly (roughly 16 fps at most),
        // while short edits still coalesce into one background composition frame.
        if (!samePendingFrame) _pendingPreviewDelay = 0.0;
    }

    private void scheduleAssetFrame(size_t assetIndex, double sourceTime)
    {
        if (assetIndex >= _model.assets.length || _playbackKind != PlaybackKind.none) return;
        _pendingAssetIndex = assetIndex;
        _pendingPreviewTime = sourceTime;
        _pendingPreviewKind = PendingPreviewKind.asset;
        _pendingPreviewDelay = 0.0;
    }

    private bool resolveCurrentSource(out MediaAsset asset, out double start,
        out double end, out double volume, out bool muted)
    {
        volume = 1.0;
        muted = false;
        const mediaIndex = selectedMediaIndex();
        if (_lastSelectionIsMedia && mediaIndex >= 0)
        {
            asset = _model.assets[cast(size_t) mediaIndex];
            start = 0.0;
            end = asset.duration;
            return true;
        }

        TrackAddress track;
        int index;
        TimelineClip clip;
        if (selectedClip(track, index, clip, asset))
        {
            start = clip.inPoint;
            end = clip.outPoint;
            volume = clip.volume;
            muted = clip.muted || _model.trackValue(track).muted;
            return true;
        }

        if (mediaIndex >= 0)
        {
            asset = _model.assets[cast(size_t) mediaIndex];
            start = 0.0;
            end = asset.duration;
            return true;
        }
        return false;
    }

    private bool samePlayback(MediaAsset asset, double start, double end,
        PlaybackKind kind) const
    {
        if (_playbackKind != kind || _playbackAsset is null || asset is null) return false;
        const sameAsset = _playbackAsset is asset || _playbackAsset.path == asset.path;
        return sameAsset && fabs(_playbackStart - start) < 0.001 &&
            fabs(_playbackEnd - end) < 0.001;
    }

    private void playCurrentSource()
    {
        MediaAsset asset;
        double start;
        double end;
        double volume;
        bool muted;
        if (!resolveCurrentSource(asset, start, end, volume, muted))
        {
            setStatus("Select Project Media or a sequence clip to play.");
            return;
        }
        if (samePlayback(asset, start, end, PlaybackKind.source))
        {
            if (_playbackRunning) pausePlayback(); else resumePlayback();
            return;
        }
        startPlayback(asset, start, end, PlaybackKind.source, volume, muted);
    }

    /** One transport action for the dedicated timeline monitor.
     *
     * Composition Preview always plays the sequence. Project Media selection
     * changes source details only and never replaces the timeline monitor.
     */
    private void playCurrentContext()
    {
        if (_playbackKind == PlaybackKind.source)
        {
            stopPlayback(false);
            previewTimeline();
            return;
        }
        if (_playbackKind == PlaybackKind.sequence)
        {
            if (_playbackRunning) pausePlayback();
            else resumePlayback();
            return;
        }
        previewTimeline();
    }

    private void playClipSource(TrackAddress track, int index)
    {
        if (!_model.validTrack(track)) return;
        const clips = _model.trackValue(track).clips;
        if (index < 0 || index >= cast(int) clips.length) return;
        _timeline.setSelection(track, index, false);
        _lastSelectionIsMedia = false;
        syncInspector();
        const clip = clips[cast(size_t) index];
        auto asset = _model.assetForClip(clip);
        if (asset is null)
        {
            setStatus("The selected clip's source media is unavailable.");
            return;
        }
        startPlayback(asset, clip.inPoint, clip.outPoint, PlaybackKind.source,
            clip.volume, clip.muted || _model.trackValue(track).muted);
    }

    private void startPlayback(MediaAsset asset, double start, double end,
        PlaybackKind kind, double volume = 1.0, bool muted = false,
        double mediaOffset = 0.0, bool directSequence = false,
        bool liveSequence = false)
    {
        // Composition Preview is a sequence monitor, never a source monitor.
        // Keep this guard even though current UI paths no longer request source
        // playback, so future context-menu changes cannot reintroduce the bug.
        if (kind == PlaybackKind.source)
        {
            scheduleTimelineFrame();
            setStatus("Composition Preview remains focused on the current sequence.");
            return;
        }
        if (asset is null || asset.duration <= 0.0) return;
        stopPlayback(false);
        _previewService.cancel();
        _pendingPreviewKind = PendingPreviewKind.none;

        _playbackAsset = asset;
        _playbackKind = kind;
        _playbackMediaOffset = mediaOffset;
        _sequencePlaybackDirect = directSequence;
        _sequencePlaybackLive = liveSequence;
        _liveAudioEnd = -1.0;
        _liveAudioClipId = 0;
        _playbackModelRevision = _modelRevision;
        const maximumPosition = asset.duration - mediaOffset;
        if (maximumPosition <= 0.0) return;

        // A sequence has one absolute time coordinate system. Previously the
        // position where Play was pressed also became the Preview scrubber's
        // minimum. A pause at 00:00:02.285 therefore drew the scrubber at its
        // far-left edge while the timeline correctly drew the red playhead at
        // 00:00:02.285. Keep the seekable sequence range anchored at zero and
        // store the requested launch point only as the current position.
        if (kind == PlaybackKind.sequence)
        {
            _playbackStart = 0.0;
            _playbackEnd = clampValue(end, 0.0, maximumPosition);
            if (_playbackEnd <= 0.001) _playbackEnd = maximumPosition;
            _playbackPosition = clampValue(start, _playbackStart, _playbackEnd);
        }
        else
        {
            _playbackStart = clampValue(start, 0.0, maximumPosition);
            _playbackEnd = clampValue(end, _playbackStart, maximumPosition);
            if (_playbackEnd <= _playbackStart + 0.001)
                _playbackEnd = maximumPosition;
            _playbackPosition = _playbackStart;
        }
        _playbackSourceVolume = volume;
        _playbackSourceMuted = muted;
        _playbackRunning = true;
        _playbackClockValid = false;
        _playbackAwaitingFirstFrame = false;
        _seekResumePlayback = false;
        clearPendingSeekState();
        _transportPaintAccumulator = 1.0;
        _lastTimeLabelPlaybackPosition = -1.0;
        _lastPreviewClockPaint = -1.0;

        // A sequence already has an authoritative composed still frame. Keep
        // that frame visible while the streaming decoder starts instead of
        // flashing an empty black Preview. Source playback may represent a
        // different file, so it still clears the old frame explicitly.
        if (kind == PlaybackKind.source ||
            (!directSequence && !liveSequence && !_preview.hasCompositionFrame()))
            _preview.setMessage(kind == PlaybackKind.sequence ?
                "Preparing composition playback…" : "Preparing source playback…");
        _preview.setPlaying(false);
        if (kind == PlaybackKind.sequence)
            syncPreviewTitleLayers(_playbackPosition);
        startPlaybackStreams();
        syncTimelineRange();
        updatePlaybackButtons();
        updateTimeLabel();
    }

    private void resetPlaybackClock()
    {
        _playbackClockBase = _playbackPosition;
        _playbackClockStarted = MonoTime.currTime;
        _playbackClockValid = true;
    }

    private double clockPlaybackPosition()
    {
        double audioPosition;
        if (_audioPlayer.clockPosition(audioPosition))
            return clampValue(audioPosition, _playbackStart, _playbackEnd);
        if (!_playbackClockValid) return _playbackPosition;
        const elapsed = MonoTime.currTime - _playbackClockStarted;
        return _playbackClockBase +
            cast(double) elapsed.total!"hnsecs" / 10_000_000.0;
    }

    private double playbackTimeForFrame(const PreviewFrame frame)
    {
        const value = _sequencePlaybackDirect ?
            frame.sourceTime - _playbackMediaOffset : frame.sourceTime;
        return clampValue(value, _playbackStart, _playbackEnd);
    }

    private string playbackPreparingStatus() const
    {
        if (_playbackKind == PlaybackKind.sequence)
        {
            if (_sequencePlaybackDirect)
                return "Preparing timeline playback from its source clip.";
            if (_sequencePlaybackLive)
                return "Preparing the live timeline composition.";
            return "Preparing rendered timeline playback.";
        }
        return "Preparing source playback.";
    }

    private string playbackRunningStatus() const
    {
        if (_playbackKind == PlaybackKind.sequence)
        {
            if (_sequencePlaybackDirect)
                return "Playing the timeline directly from its source clip.";
            if (_sequencePlaybackLive)
                return "Playing the live timeline composition.";
            return "Playing the rendered timeline composition.";
        }
        return "Playing source frames inside Aurora Preview.";
    }

    private int liveDecodeHeight() const
    {
        final switch (_playbackPerformance)
        {
            case PlaybackPerformance.responsive:
                return _previewQualityHeight < 720 ? _previewQualityHeight : 720;
            case PlaybackPerformance.balanced:
                return _previewQualityHeight < 1080 ? _previewQualityHeight : 1080;
            case PlaybackPerformance.fidelity:
                return _previewQualityHeight;
        }
    }

    private int livePlaybackFps(Size decode) const
    {
        int fps = _playbackAsset is null ? 30 :
            cast(int) (_playbackAsset.frameRate + 0.5);
        fps = clampValue(fps > 0 ? fps : 30, 12, 60);
        const long pixels = cast(long) decode.width * cast(long) decode.height;
        long pixelBudget;
        int modeCap;
        final switch (_playbackPerformance)
        {
            case PlaybackPerformance.responsive:
                pixelBudget = 50_000_000;
                modeCap = 45;
                break;
            case PlaybackPerformance.balanced:
                pixelBudget = 70_000_000;
                modeCap = 40;
                break;
            case PlaybackPerformance.fidelity:
                pixelBudget = 100_000_000;
                modeCap = 60;
                break;
        }
        if (fps > modeCap) fps = modeCap;
        if (pixels > 0)
        {
            const budgetFps = clampValue(cast(int) (pixelBudget / pixels), 12, 60);
            if (fps > budgetFps) fps = budgetFps;
        }
        return fps;
    }

    /** Earliest future sequence position containing audible media.  The mixed
     * PCM preview graph now covers those future regions in one stream; this
     * helper remains as a small regression surface for timeline audio lookup.
     */
    private double nextTimelineAudioStart(double afterTime)
    {
        double result = -1.0;
        foreach (kind; [TrackKind.video, TrackKind.audio])
        {
            foreach (lane; 0 .. _model.trackCount(kind))
            {
                const address = TrackAddress(kind, lane);
                const track = _model.trackValue(address);
                if (track.disabled || track.muted) continue;
                foreach (clip; track.clips)
                {
                    if (clip.start <= afterTime + 0.001 || clip.muted || clip.isText())
                        continue;
                    auto candidate = _model.assetForClip(clip);
                    if (candidate is null || !candidate.hasAudio) continue;
                    if (result < 0.0 || clip.start < result) result = clip.start;
                }
            }
        }
        return result;
    }

    private bool clipHasAudiblePotential(const TimelineClip clip) const
    {
        if (clip.muted || clip.isText()) return false;
        if (clip.volume > 0.000_001) return true;
        foreach (keyframe; clip.keyframes)
            if (keyframe.property == EffectProperty.volume &&
                keyframe.value > 0.000_001)
                return true;
        return false;
    }

    private bool sequenceHasAudibleAudio(double start, double end) const
    {
        foreach (kind; [TrackKind.video, TrackKind.audio])
        {
            foreach (lane; 0 .. _model.trackCount(kind))
            {
                const address = TrackAddress(kind, lane);
                const track = _model.trackValue(address);
                if (track.disabled || track.muted) continue;
                foreach (clip; track.clips)
                {
                    if (clip.end() <= start + 0.000_5 ||
                        clip.start >= end - 0.000_5 ||
                        !clipHasAudiblePotential(clip)) continue;
                    auto candidate = _model.assetForClip(clip);
                    if (candidate !is null && candidate.hasAudio) return true;
                }
            }
        }
        return false;
    }

    private bool startLiveTimelineAudio()
    {
        _audioPlayer.stop();
        _liveAudioEnd = -1.0;
        _liveAudioClipId = 0;
        if (!_tools.ffmpeg || !_sequencePlaybackLive || !_playbackRunning)
            return false;
        const sequenceTime = clampValue(_playbackPosition, _playbackStart,
            _playbackEnd);
        const remaining = _playbackEnd - sequenceTime;
        if (remaining <= 0.001 ||
            !sequenceHasAudibleAudio(sequenceTime, _playbackEnd))
            return false;
        try
        {
            auto request = buildExportRequest(ExportKind.mp4, "",
                ExportPreset.previewForHeight(liveDecodeHeight()), false);
            auto arguments = compositeAudioArguments(request, sequenceTime,
                _playbackEnd);
            return _audioPlayer.startCommand(arguments, sequenceTime, remaining);
        }
        catch (Exception error)
        {
            appLog(format("Preview audio graph failed at %.3f: %s",
                sequenceTime, error.toString()));
            return false;
        }
    }

    private bool startPlaybackAudio()
    {
        if (_playbackAudioStarted) return true;
        _playbackAudioStarted = true;
        _audioPlayer.stop();
        if (_playbackAsset is null)
        {
            _playbackAudioStarted = false;
            return false;
        }
        const remaining = _playbackEnd - _playbackPosition;
        if (remaining <= 0.001)
        {
            _playbackAudioStarted = false;
            return false;
        }
        if (_sequencePlaybackLive)
        {
            const started = startLiveTimelineAudio();
            if (!started) _playbackAudioStarted = false;
            return started;
        }

        if (_playbackAsset.hasAudio && _tools.ffmpeg && !_playbackSourceMuted &&
            _playbackSourceVolume > 0.000_001)
        {
            const mediaPosition = clampValue(_playbackPosition + _playbackMediaOffset,
                0.0, _playbackAsset.duration);
            if (!_audioPlayer.start(_playbackAsset.path, mediaPosition,
                remaining, _playbackSourceVolume))
            {
                _playbackAudioStarted = false;
                setStatus("Visual playback is ready, but audio output could not start.");
                return false;
            }
            return true;
        }
        _playbackAudioStarted = false;
        return false;
    }

    private void startPlaybackStreams()
    {
        if (_playbackAsset is null || !_playbackRunning) return;

        _videoStream.stop();
        _audioPlayer.stop();
        _playbackAudioStarted = false;
        _playbackAwaitingAudioClock = false;
        _playbackAudioClockWait = 0.0;
        _playbackClockValid = false;
        _playbackAwaitingFirstFrame = false;
        const remaining = _playbackEnd - _playbackPosition;
        if (remaining <= 0.001) return;

        const decode = _preview.recommendedDecodeSize(liveDecodeHeight());
        const fps = livePlaybackFps(decode);
        bool videoStarted;
        if (_sequencePlaybackLive)
        {
            const renderHeight = liveDecodeHeight();
            auto preset = ExportPreset.previewForHeight(renderHeight);
            auto request = buildExportRequest(ExportKind.mp4, "", preset, false);
            request.renderTitles = false;
            scalePreviewPixelEffects(request, _previewQualityHeight, renderHeight);
            auto arguments = compositeStreamArguments(request, _playbackPosition,
                _playbackEnd, decode.width, decode.height, fps);
            videoStarted = _videoStream.startCommand(arguments, _playbackPosition,
                remaining, decode.width, decode.height, fps,
                "Sequence 01 • live composition");
            if (!videoStarted)
                setStatus("The live timeline compositor could not be started.");
        }
        else
        {
            const mediaPosition = clampValue(_playbackPosition + _playbackMediaOffset,
                0.0, _playbackAsset.duration);
            if (_playbackAsset.hasVideo)
            {
                videoStarted = _videoStream.start(_playbackAsset.path, mediaPosition,
                    remaining, decode.width, decode.height, fps, _playbackAsset.name);
                if (!videoStarted)
                    setStatus("The embedded video decoder could not be started.");
            }
            else
                _previewService.requestAsset(_playbackAsset, mediaPosition,
                    decode.width, decode.height);
        }

        if ((_sequencePlaybackLive || _playbackAsset.hasVideo) && !videoStarted)
        {
            _playbackRunning = false;
            _playbackClockValid = false;
            _playbackAwaitingFirstFrame = false;
            _preview.setPlaying(false);
            updatePlaybackButtons();
            return;
        }

        if (videoStarted)
        {
            _playbackAwaitingFirstFrame = true;
            _playbackClockValid = false;
            _preview.setPlaying(false);
            setStatus(playbackPreparingStatus());
        }
        else
        {
            _playbackAwaitingFirstFrame = false;
            resetPlaybackClock();
            _preview.setPlaying(true);
            setStatus(playbackRunningStatus());
            startPlaybackAudio();
        }
        _transportPaintAccumulator = 1.0;
    }

    private void pausePlayback()
    {
        if (_playbackKind == PlaybackKind.none || !_playbackRunning) return;
        if (!_seekPending)
            _playbackPosition = clampValue(clockPlaybackPosition(),
                _playbackStart, _playbackEnd);
        _playbackRunning = false;
        _seekResumePlayback = false;
        clearPendingSeekState();
        _playbackClockValid = false;
        _playbackAwaitingFirstFrame = false;
        _playbackAudioStarted = false;
        _playbackAwaitingAudioClock = false;
        _playbackAudioClockWait = 0.0;
        _videoStream.stop();
        _audioPlayer.stop();
        _preview.setPlaying(false);
        if (_playbackKind == PlaybackKind.sequence &&
            _playbackModelRevision != _modelRevision)
        {
            // The running decoder represented the pre-edit snapshot. Pause
            // displays a frame from the current timeline model without
            // restarting playback or reusing a stale direct-source mapping.
            _sequencePlaybackDirect = false;
            _sequencePlaybackLive = true;
            _sequenceRefreshDeferred = false;
            _sequenceRefreshPending = false;
            _sequenceRefreshDelay = 0.0;
        }
        requestPlaybackStill();
        if (_playbackKind == PlaybackKind.sequence)
        {
            _timeline.setPlayhead(_playbackPosition, false);
            syncPreviewTitleLayers(_playbackPosition);
            if (_timeline.selectedIndex() >= 0) syncInspector();
        }
        _scrub.setValue(_playbackPosition, false);
        updatePlaybackButtons();
        updateTimeLabel();
        setStatus(_playbackKind == PlaybackKind.sequence
            ? "Composition preview paused." : "Source playback paused.");
    }

    private void resumePlayback()
    {
        if (_playbackKind == PlaybackKind.none || _playbackAsset is null) return;
        if (_playbackKind == PlaybackKind.sequence &&
            _playbackModelRevision != _modelRevision)
        {
            const position = _playbackPosition;
            stopPlayback(false);
            _timeline.setPlayhead(position, false);
            previewTimeline();
            return;
        }
        if (_seekPending)
        {
            _playbackPosition = _seekTarget;
            clearPendingSeekState();
        }
        if (_playbackPosition >= _playbackEnd - 0.001)
            _playbackPosition = _playbackStart;
        if (_playbackKind == PlaybackKind.sequence)
            _timeline.setPlayhead(_playbackPosition, false);
        _playbackRunning = true;
        _seekResumePlayback = false;
        _preview.setPlaying(false);
        if (_playbackKind == PlaybackKind.sequence)
            syncPreviewTitleLayers(_playbackPosition);
        startPlaybackStreams();
        syncTimelineRange();
        updatePlaybackButtons();
    }

    /**
     * Queue a seek without starting or waiting for any process. Mouse motion
     * only replaces `_seekTarget`; a single decoder restart is committed after
     * a short idle period or immediately when the gesture ends.
     */
    private void seekPlayback(double requested)
    {
        if (_playbackKind == PlaybackKind.none || _playbackAsset is null) return;
        const next = clampValue(requested, _playbackStart, _playbackEnd);
        if (!_seekPending && fabs(next - _playbackPosition) < 0.000_5) return;

        // If the pointer moved after an idle scrub still started, cancel that
        // obsolete worker generation immediately. Cancellation never waits.
        if (_seekPending && _seekStillTarget >= 0.0)
        {
            _previewService.cancel();
            _seekStillTarget = -1.0;
        }

        if (!_seekPending)
        {
            _seekResumePlayback = _playbackRunning;
            _videoStream.stop();
            _audioPlayer.stop();
            _playbackAudioStarted = false;
            _playbackAwaitingAudioClock = false;
            _playbackAudioClockWait = 0.0;
            _previewService.cancel();
            _playbackClockValid = false;
            _playbackAwaitingFirstFrame = false;
            _preview.setPlaying(false);
        }

        _seekPending = true;
        _seekTarget = next;
        _seekDelay = 0.0;
        _seekStillTarget = -1.0;
        _playbackPosition = next;
        if (_playbackKind == PlaybackKind.sequence)
        {
            _timeline.setPlayhead(next, false);
            syncPreviewTitleLayers(next);
        }
        _scrub.setValue(next, false);
        updateTimeLabel();
    }

    private void requestPlaybackStill(int maximumHeight = 0)
    {
        if (_playbackAsset is null) return;
        if (_playbackKind == PlaybackKind.sequence)
        {
            syncPreviewTitleLayers(_playbackPosition);
            const limit = maximumHeight > 0 ? maximumHeight : liveDecodeHeight();
            const decode = _preview.recommendedDecodeSize(limit);
            if (_sequencePlaybackDirect)
            {
                _previewService.requestAsset(_playbackAsset,
                    clampValue(_playbackPosition + _playbackMediaOffset,
                        0.0, _playbackAsset.duration),
                    decode.width, decode.height);
                return;
            }
            // Never seek a possibly stale/black proxy for a paused composition.
            // Render the requested sequence frame from the actual source clips
            // through the compositor graph instead. This is also what normal
            // timeline scrubbing uses, so pause and scrub always agree.
            const renderHeight = maximumHeight > 0 ?
                (maximumHeight < liveDecodeHeight() ? maximumHeight : liveDecodeHeight()) :
                liveDecodeHeight();
            auto request = buildFrameRequest(_playbackPosition,
                ExportPreset.previewForHeight(renderHeight));
            scalePreviewPixelEffects(request, _previewQualityHeight, renderHeight);
            _previewService.requestComposition(request, _playbackPosition,
                decode.width, decode.height);
            return;
        }
        if (_playbackAsset.hasVideo)
        {
            const limit = maximumHeight > 0 ? maximumHeight : liveDecodeHeight();
            const decode = _preview.recommendedDecodeSize(limit);
            _previewService.requestAsset(_playbackAsset, _playbackPosition,
                decode.width, decode.height);
        }
        else
            _preview.setPlaybackTime(_playbackPosition);
    }

    private void commitPendingSeek()
    {
        if (!_seekPending || _playbackKind == PlaybackKind.none ||
            _playbackAsset is null) return;
        _playbackPosition = clampValue(_seekTarget, _playbackStart, _playbackEnd);
        clearPendingSeekState();

        if (_playbackPosition >= _playbackEnd - 0.001)
        {
            _playbackRunning = false;
            _seekResumePlayback = false;
            _playbackClockValid = false;
            _playbackAwaitingFirstFrame = false;
            _preview.setPlaying(false);
            requestPlaybackStill();
        }
        else if (_seekResumePlayback && _playbackRunning)
        {
            _preview.setPlaying(false);
            startPlaybackStreams();
        }
        else
        {
            _playbackClockValid = false;
            _playbackAwaitingFirstFrame = false;
            _preview.setPlaying(false);
            requestPlaybackStill();
        }

        _seekResumePlayback = false;
        if (_playbackKind == PlaybackKind.sequence)
        {
            _timeline.setPlayhead(_playbackPosition, false);
            if (_timeline.selectedIndex() >= 0) syncInspector();
        }
        updatePlaybackButtons();
        updateTimeLabel();
    }

    private void clearPendingSeekState()
    {
        _seekPending = false;
        _seekGesture = false;
        _seekDelay = 0.0;
        _seekStillTarget = -1.0;
    }

    private void queueSourceAudioRefresh()
    {
        if (!_playbackRunning ||
            (_playbackKind != PlaybackKind.source && !_sequencePlaybackDirect &&
             !_sequencePlaybackLive))
            return;
        _sourceAudioRefreshPending = true;
        _sourceAudioRefreshDelay = 0.0;
    }

    private void refreshSourceAudio()
    {
        if (!_playbackRunning || _playbackAsset is null ||
            _playbackAwaitingFirstFrame) return;
        _playbackAudioStarted = false;
        double volume;
        bool muted;
        double mediaPosition = _playbackPosition + _playbackMediaOffset;

        if (_sequencePlaybackLive)
        {
            startPlaybackAudio();
            return;
        }

        if (_playbackKind == PlaybackKind.source)
        {
            MediaAsset selectedAsset;
            double start;
            double end;
            if (!resolveCurrentSource(selectedAsset, start, end, volume, muted) ||
                selectedAsset.path != _playbackAsset.path) return;
        }
        else if (_sequencePlaybackDirect)
        {
            TrackAddress directTrack;
            TimelineClip directClip;
            MediaAsset directAsset;
            if (!resolveDirectSequence(directTrack, directClip, directAsset) ||
                directAsset.path != _playbackAsset.path) return;
            volume = directClip.volume;
            muted = directClip.muted || _model.trackValue(directTrack).muted;
        }
        else
            return;

        _playbackSourceVolume = volume;
        _playbackSourceMuted = muted;
        _audioPlayer.stop();
        const remaining = _playbackEnd - _playbackPosition;
        if (remaining > 0.001 && _tools.ffmpeg && _playbackAsset.hasAudio &&
            !muted && volume > 0.000_001)
        {
            _audioPlayer.start(_playbackAsset.path,
                clampValue(mediaPosition, 0.0, _playbackAsset.duration),
                remaining, volume);
            _playbackAudioStarted = true;
        }
    }

    private void stopPlayback(bool restorePreview)
    {
        _videoStream.stop();
        _audioPlayer.stop();
        const hadPlayback = _playbackKind != PlaybackKind.none;
        _playbackKind = PlaybackKind.none;
        _playbackAsset = null;
        _playbackRunning = false;
        _playbackStart = 0.0;
        _playbackEnd = 0.0;
        _playbackPosition = 0.0;
        _playbackMediaOffset = 0.0;
        _sequencePlaybackDirect = false;
        _sequencePlaybackLive = false;
        _liveAudioEnd = -1.0;
        _liveAudioClipId = 0;
        _playbackAudioStarted = false;
        _playbackAwaitingAudioClock = false;
        _playbackAudioClockWait = 0.0;
        _playbackModelRevision = 0;
        _playbackClockValid = false;
        _playbackAwaitingFirstFrame = false;
        _seekResumePlayback = false;
        clearPendingSeekState();
        _transportPaintAccumulator = 0.0;
        _sourceAudioRefreshPending = false;
        _sourceAudioRefreshDelay = 0.0;
        _sequenceRefreshPending = false;
        _sequenceRefreshDelay = 0.0;
        _sequenceRefreshDeferred = false;
        _lastPreviewClockPaint = -1.0;
        if (_preview !is null) _preview.setPlaying(false);
        updatePlaybackButtons();
        if (_timeline !is null) syncTimelineRange();

        if (restorePreview && hadPlayback)
            scheduleTimelineFrame();
    }

    private void finishPlayback()
    {
        _playbackPosition = _playbackEnd;
        _playbackRunning = false;
        _playbackClockValid = false;
        _playbackAwaitingFirstFrame = false;
        _playbackAudioStarted = false;
        _playbackAwaitingAudioClock = false;
        _playbackAudioClockWait = 0.0;
        _seekResumePlayback = false;
        clearPendingSeekState();
        _videoStream.stop();
        _audioPlayer.stop();
        _preview.setPlaying(false);
        if (_playbackKind == PlaybackKind.sequence)
        {
            _timeline.setPlayhead(_playbackEnd, false);
            syncPreviewTitleLayers(_playbackEnd);
            _scrub.setValue(_playbackPosition, false);
            if (_timeline.selectedIndex() >= 0) syncInspector();
            setStatus("Composition preview finished.");
        }
        else
            setStatus("Source playback finished.");
        updatePlaybackButtons();
        updateTimeLabel();
    }

    private void updatePlaybackButtons()
    {
        if (_sourcePlayButton !is null)
        {
            string label = "▶";
            if (_playbackKind != PlaybackKind.none && _playbackRunning)
                label = "❚❚";
            _sourcePlayButton.setText(label);
        }
    }

    private bool renderedPreviewCurrent() const
    {
        return _renderedPreviewAsset !is null &&
            _renderedPreviewRevision == _modelRevision &&
            _renderedPreviewHeight == _previewQualityHeight &&
            exists(_renderedPreviewAsset.path);
    }

    private static bool clipNeedsVisualComposition(const TimelineClip clip)
    {
        if (clip.isText()) return true;
        if (fabs(clip.scale - 1.0) > 0.000_001 ||
            fabs(clip.positionX) > 0.000_001 ||
            fabs(clip.positionY) > 0.000_001 ||
            fabs(clip.opacity - 1.0) > 0.000_001 ||
            fabs(clip.rotation) > 0.000_001 ||
            clip.fadeIn > 0.000_001 || clip.fadeOut > 0.000_001 ||
            clip.blur > 0.000_001 || clip.shadowOpacity > 0.000_001 ||
            clip.strokeWidth > 0.000_001 || clip.reversed ||
            fabs(clip.playbackRate - 1.0) > 0.000_001)
            return true;
        foreach (keyframe; clip.keyframes)
            if (keyframe.property != EffectProperty.volume) return true;
        return false;
    }

    /** Resolve a sequence that can be decoded directly from its original MP4.
     *
     * A single untransformed video clip with no separately mixed audio does
     * not need an intermediate composition render. This is the common case
     * immediately after dragging one video to V1 and must start instantly.
     */
    private bool resolveDirectSequence(out TrackAddress address,
        out TimelineClip clip, out MediaAsset asset)
    {
        bool found;
        foreach (lane; 0 .. _model.trackCount(TrackKind.video))
        {
            const candidateAddress = TrackAddress(TrackKind.video, lane);
            const timelineTrack = _model.trackValue(candidateAddress);
            if (timelineTrack.disabled) continue;
            foreach (candidateIndex, candidate; timelineTrack.clips)
            {
                TimelineClip candidateCopy;
                if (!_model.copyClip(candidateAddress, cast(int) candidateIndex,
                    candidateCopy)) return false;
                auto candidateAsset = _model.assetForClip(candidateCopy);
                if (candidateCopy.isText()) continue;
                if (candidateAsset is null || !candidateAsset.hasVideo) return false;
                if (found) return false;
                address = candidateAddress;
                clip = candidateCopy;
                asset = candidateAsset;
                found = true;
            }
        }
        if (!found || clipNeedsVisualComposition(clip)) return false;
        if (fabs(clip.start) > 0.000_5 ||
            fabs(clip.end() - _model.sequenceDuration()) > 0.001)
            return false;

        // A separate audible A-track requires mixing and therefore a real
        // composition. Muted/disabled lanes do not block passthrough.
        foreach (lane; 0 .. _model.trackCount(TrackKind.audio))
        {
            const track = _model.trackValue(TrackAddress(TrackKind.audio, lane));
            if (track.disabled || track.muted) continue;
            foreach (audioClip; track.clips)
                if (!audioClip.muted && audioClip.volume > 0.000_001)
                    return false;
        }
        // Animated gain needs the audio filter graph even if video is plain.
        foreach (keyframe; clip.keyframes)
            if (keyframe.property == EffectProperty.volume) return false;
        return true;
    }

    /** Resolve one static sequence frame that has exactly one plain visible
     * video layer. Scrubbing then reuses the fast source-frame path instead of
     * spawning the full overlay compositor for a no-op composition. */
    private bool resolveDirectSequenceFrame(double sequenceTime,
        out MediaAsset asset, out double sourceTime)
    {
        bool found;
        foreach (lane; 0 .. _model.trackCount(TrackKind.video))
        {
            const address = TrackAddress(TrackKind.video, lane);
            const track = _model.trackValue(address);
            if (track.disabled) continue;
            const index = _model.clipAtTime(address, sequenceTime);
            if (index < 0) continue;
            const candidate = track.clips[cast(size_t) index];
            if (candidate.isText()) continue;
            auto candidateAsset = _model.assetForClip(candidate);
            if (candidateAsset is null || !candidateAsset.hasVideo ||
                clipNeedsVisualComposition(candidate))
                return false;
            if (found) return false;
            found = true;
            asset = candidateAsset;
            sourceTime = candidate.inPoint + (sequenceTime - candidate.start);
        }
        return found;
    }

    private void startDirectSequencePlayback(TrackAddress address,
        const TimelineClip clip, MediaAsset asset)
    {
        double start = clampValue(_timeline.playhead(), clip.start, clip.end());
        if (start >= clip.end() - 0.001) start = clip.start;
        const track = _model.trackValue(address);
        startPlayback(asset, start, clip.end(), PlaybackKind.sequence,
            clip.volume, clip.muted || track.muted,
            clip.inPoint - clip.start, true);
    }

    private void startLiveSequencePlayback()
    {
        const duration = _model.sequenceDuration();
        if (duration <= 0.0) return;
        auto asset = new MediaAsset("");
        asset.name = "Sequence 01";
        asset.duration = duration;
        asset.hasVideo = true;
        asset.hasAudio = true;
        const preset = ExportPreset.previewForHeight(_previewQualityHeight);
        asset.width = preset.width;
        asset.height = preset.height;
        asset.frameRate = preset.fps;
        double start = _timeline.playhead();
        if (start >= duration - 0.001) start = 0.0;
        startPlayback(asset, start, duration, PlaybackKind.sequence, 1.0, false,
            0.0, false, true);
    }

    private void previewTimeline()
    {
        endInlineTextEditing();
        // User-initiated playback supersedes any delayed edit refresh. Keeping
        // the old timer armed caused a second restart ~140 ms later and could
        // kill newly started audio after a split or seek.
        _sequenceRefreshPending = false;
        _sequenceRefreshDelay = 0.0;
        if (_playbackKind == PlaybackKind.sequence)
        {
            if (_playbackRunning)
            {
                pausePlayback();
                return;
            }
            if (_playbackModelRevision == _modelRevision)
            {
                resumePlayback();
                return;
            }
            stopPlayback(false);
        }
        if (!_tools.ffmpeg)
        {
            setStatus("Timeline preview requires FFmpeg.");
            return;
        }
        if (_model.sequenceDuration() <= 0.0)
        {
            setStatus("Add media to Sequence before playing it.");
            return;
        }

        TrackAddress directTrack;
        TimelineClip directClip;
        MediaAsset directAsset;
        if (resolveDirectSequence(directTrack, directClip, directAsset))
        {
            startDirectSequencePlayback(directTrack, directClip, directAsset);
            return;
        }

        // Normal timeline playback is streamed from the real composition graph.
        // No complete MP4 proxy is rendered before the user can press Play.
        startLiveSequencePlayback();
    }

    private void playRenderedSequence()
    {
        if (_renderedPreviewAsset is null) return;
        double start = _timeline.playhead();
        if (start >= _renderedPreviewAsset.duration - 0.001) start = 0.0;
        startPlayback(_renderedPreviewAsset, start, _renderedPreviewAsset.duration,
            PlaybackKind.sequence, 1.0, false);
    }

    private void openExportDialog(ExportKind kind)
    {
        endInlineTextEditing();
        if (!_tools.ffmpeg)
        {
            setStatus("FFmpeg is required before files can be exported.");
            return;
        }
        if (_model.sequenceDuration() <= 0.0)
        {
            setStatus("Add media to Sequence before exporting.");
            return;
        }
        if (_exportJob.state().running)
        {
            setStatus("A render is already running.");
            return;
        }

        const extension = kind == ExportKind.mp4 ? ".mp4" : ".mp3";
        const suggested = kind == ExportKind.mp4 ?
            "aurora-cut-export.mp4" : "aurora-cut-export.mp3";
        _fileDialog.showSave(extension, suggested, delegate(string path) {
            auto preset = exportPresetForHeight(_previewQualityHeight);
            if (kind == ExportKind.mp4) applyMp4OutputCompression(preset);
            auto request = buildExportRequest(kind, path, preset);
            startJob(request, JobPurpose.exportFile);
        });
    }

    private static ExportPreset exportPresetForHeight(int height)
    {
        switch (height)
        {
            case 720: return ExportPreset.hd();
            case 1440: return ExportPreset.quadHd();
            case 2160: return ExportPreset.ultraHd();
            default: return ExportPreset.fullHd();
        }
    }

    private ExportRequest buildExportRequest(ExportKind kind, string path,
        ExportPreset preset, bool applyWorkRange = true)
    {
        ExportRequest request;
        request.kind = kind;
        request.outputPath = path;
        request.preset = preset;
        request.cacheKey = _modelRevision;
        request.videoEncoder = _tools.h264Encoder;
        request.videoAcceleration = _tools.videoAcceleration;
        request.hardwareVideoEncoding = _tools.hardwareVideoEncoding;
        if (applyWorkRange && (_hasWorkIn || _hasWorkOut))
        {
            request.rangeStart = _hasWorkIn ? _workIn : 0.0;
            request.rangeEnd = _hasWorkOut ? _workOut : _model.sequenceDuration();
        }
        foreach (lane; 0 .. _model.trackCount(TrackKind.video))
        {
            const address = TrackAddress(TrackKind.video, lane);
            const track = _model.trackValue(address);
            foreach (clip; track.clips)
            {
                if (clip.isText())
                {
                    request.video ~= exportTextClip(clip, lane, track);
                    continue;
                }
                const asset = _model.assetForClip(clip);
                if (asset is null) continue;
                request.video ~= exportClip(asset, clip, lane, track);
            }
        }
        foreach (lane; 0 .. _model.trackCount(TrackKind.audio))
        {
            const address = TrackAddress(TrackKind.audio, lane);
            const track = _model.trackValue(address);
            foreach (clip; track.clips)
            {
                const asset = _model.assetForClip(clip);
                if (asset is null) continue;
                request.audio ~= exportClip(asset, clip, lane, track);
            }
        }
        return request;
    }

    private static ExportClip exportClip(const MediaAsset asset,
        const TimelineClip clip, size_t lane, const TimelineTrack track)
    {
        ExportClip result;
        result.clipId = clip.id;
        result.path = asset.path;
        result.start = clip.start;
        result.inPoint = clip.inPoint;
        result.outPoint = clip.outPoint;
        result.volume = clip.volume;
        result.muted = clip.muted;
        result.playbackRate = clip.playbackRate;
        result.reversed = clip.reversed;
        result.hasVideo = asset.hasVideo;
        result.hasAudio = asset.hasAudio;
        result.sourceWidth = asset.width;
        result.sourceHeight = asset.height;
        result.trackIndex = lane;
        result.trackMuted = track.muted;
        result.trackDisabled = track.disabled;
        result.scale = clip.scale;
        result.positionX = clip.positionX;
        result.positionY = clip.positionY;
        result.opacity = clip.opacity;
        result.rotation = clip.rotation;
        result.fadeIn = clip.fadeIn;
        result.fadeOut = clip.fadeOut;
        result.blur = clip.blur;
        result.shadowOpacity = clip.shadowOpacity;
        result.shadowBlur = clip.shadowBlur;
        result.shadowOffsetX = clip.shadowOffsetX;
        result.shadowOffsetY = clip.shadowOffsetY;
        result.shadowColor = clip.shadowColor;
        result.strokeWidth = clip.strokeWidth;
        result.strokeColor = clip.strokeColor;
        result.text = clip.text;
        result.fontName = clip.fontName;
        result.textBold = clip.textBold;
        result.textItalic = clip.textItalic;
        result.textUnderline = clip.textUnderline;
        result.textAlignment = clip.textAlignment;
        result.textSize = clip.textSize;
        result.textColor = clip.textColor;
        result.textBox = clip.textBox;
        result.textBoxColor = clip.textBoxColor;
        result.keyframes = clip.keyframes.dup;
        return result;
    }

    private static ExportClip exportTextClip(const TimelineClip clip,
        size_t lane, const TimelineTrack track)
    {
        ExportClip result;
        result.clipId = clip.id;
        result.generatedText = true;
        result.start = clip.start;
        result.inPoint = clip.inPoint;
        result.outPoint = clip.outPoint;
        result.trackIndex = lane;
        result.trackMuted = track.muted;
        result.trackDisabled = track.disabled;
        result.scale = clip.scale;
        result.positionX = clip.positionX;
        result.positionY = clip.positionY;
        result.opacity = clip.opacity;
        result.rotation = clip.rotation;
        result.fadeIn = clip.fadeIn;
        result.fadeOut = clip.fadeOut;
        result.blur = clip.blur;
        result.shadowOpacity = clip.shadowOpacity;
        result.shadowBlur = clip.shadowBlur;
        result.shadowOffsetX = clip.shadowOffsetX;
        result.shadowOffsetY = clip.shadowOffsetY;
        result.shadowColor = clip.shadowColor;
        result.strokeWidth = clip.strokeWidth;
        result.strokeColor = clip.strokeColor;
        result.text = clip.text;
        result.fontName = clip.fontName;
        result.textBold = clip.textBold;
        result.textItalic = clip.textItalic;
        result.textUnderline = clip.textUnderline;
        result.textAlignment = clip.textAlignment;
        result.textSize = clip.textSize;
        result.textColor = clip.textColor;
        result.textBox = clip.textBox;
        result.textBoxColor = clip.textBoxColor;
        result.keyframes = clip.keyframes.dup;
        return result;
    }

    private void startJob(ExportRequest request, JobPurpose purpose)
    {
        if (!_exportJob.start(request))
        {
            setStatus("A render is already running.");
            return;
        }
        _jobPurpose = purpose;
        _jobCompletionHandled = false;
        if (purpose == JobPurpose.exportFile)
        {
            _lastExportPath = "";
            if (_revealExportButton !is null) _revealExportButton.setEnabled(false);
        }
        _lastProgressValue = 0.0;
        _lastProgressPercent = -1;
        _lastProgressLabel = purpose == JobPurpose.previewTimeline ? "Preview" : "Export";
        _lastJobStatus = "";
        _progress.setValue(0.0);
        _progress.setLabel(_lastProgressLabel);
        setStatus(purpose == JobPurpose.previewTimeline
            ? format("Rendering the actual %dp multi-track composition in the background…",
                _previewQualityHeight)
            : exportStartedStatus(request));
    }

    private void cancelBackgroundRender()
    {
        if (_exportJob.cancel())
            setStatus("Cancelling the background render; editing and playback remain responsive.");
        else
            setStatus("No background render is running.");
    }

    private string exportStartedStatus(const ExportRequest request) const
    {
        if (request.hasRange())
            return "Export started in the background for " ~
                formatTimecode(request.rangeStart) ~ " to " ~
                formatTimecode(request.rangeEnd) ~ ".";
        return "Export started in the background for the full sequence.";
    }

    private void setTransitionRequested(TrackAddress track, int index,
        bool fadeIn, double duration)
    {
        auto before = captureTimelineSnapshot(fadeIn ? "Set fade in" : "Set fade out");
        const changed = fadeIn ? _model.setFadeIn(track, index, duration) :
            _model.setFadeOut(track, index, duration);
        if (changed)
        {
            commitHistory(before);
            afterTimelineMutation(format("%s set to %.2f seconds.",
                fadeIn ? "Fade in" : "Fade out", duration), track, index, false);
        }
    }

    private void setSelectedClipSpeed(TrackAddress track, int index, double rate)
    {
        auto before = captureTimelineSnapshot("Change clip speed");
        if (_model.setPlaybackRate(track, index, rate))
        {
            commitHistory(before);
            afterTimelineMutation(format("Clip speed set to %.2gx.", rate),
                track, index, false);
        }
    }

    private void addTextAtPlayheadFromPreview()
    {
        const track = TrackAddress(TrackKind.video,
            _model.trackCount(TrackKind.video));
        auto before = captureTimelineSnapshot("Add text");
        const index = _model.insertTextClip(track, _timeline.playhead(), 5.0, "Text");
        if (index >= 0)
        {
            commitHistory(before);
            afterTimelineMutation("Text item added at playhead.", track, index, false);
            focusSelectedTextField();
        }
    }

    private void clearWorkIn()
    {
        if (!_hasWorkIn) return;
        _hasWorkIn = false;
        syncTimelineWorkArea();
        setStatus("Export In point cleared.");
    }

    private void clearWorkOut()
    {
        if (!_hasWorkOut) return;
        _hasWorkOut = false;
        syncTimelineWorkArea();
        setStatus("Export Out point cleared.");
    }

    private void showQualityContextMenu(Point point)
    {
        ContextMenuItem[] items;
        addQualityItem(items, 720);
        addQualityItem(items, 1080);
        addQualityItem(items, 1440);
        addQualityItem(items, 2160);
        items ~= ContextMenuItem.separatorItem();
        addPlaybackPerformanceItems(items);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("H.264 encoding: " ~
            _tools.videoAcceleration, delegate() {}, "", false);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Render / play composition", IconKind.start,
            delegate() { previewTimeline(); });
        items ~= ContextMenuItem.command("Cancel background render", delegate() {
            cancelBackgroundRender();
        }, "", _exportJob.state().running);
        showContextMenu(_qualityButton, point, items);
    }

    private void addQualityItem(ref ContextMenuItem[] items, int height)
    {
        const selected = _previewQualityHeight == height;
        items ~= ContextMenuItem.check(format("%dp preview and MP4", height), selected,
            delegate() { setPreviewQuality(height); });
    }

    private void addPlaybackPerformanceItems(ref ContextMenuItem[] items)
    {
        items ~= ContextMenuItem.check("Playback: Responsive (720p max)",
            _playbackPerformance == PlaybackPerformance.responsive,
            delegate() { setPlaybackPerformance(PlaybackPerformance.responsive); });
        items ~= ContextMenuItem.check("Playback: Balanced (1080p max)",
            _playbackPerformance == PlaybackPerformance.balanced,
            delegate() { setPlaybackPerformance(PlaybackPerformance.balanced); });
        items ~= ContextMenuItem.check("Playback: Maximum fidelity",
            _playbackPerformance == PlaybackPerformance.fidelity,
            delegate() { setPlaybackPerformance(PlaybackPerformance.fidelity); });
    }

    private void setPlaybackPerformance(PlaybackPerformance value)
    {
        if (_playbackPerformance == value) return;
        _playbackPerformance = value;
        string label;
        final switch (value)
        {
            case PlaybackPerformance.responsive: label = "Responsive"; break;
            case PlaybackPerformance.balanced: label = "Balanced"; break;
            case PlaybackPerformance.fidelity: label = "Maximum fidelity"; break;
        }
        setStatus(label ~ " playback mode selected. Active playback continues; " ~
            "the setting applies on the next start or seek.");
    }

    private void setPreviewQuality(int height)
    {
        height = height == 720 || height == 1080 || height == 1440 || height == 2160
            ? height : 1080;
        if (_previewQualityHeight == height) return;
        _previewQualityHeight = height;
        markProjectDirty();
        updateQualityUi();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(format("Preview/export quality set to %dp. Existing playback continues.",
            height));
    }

    private void updateQualityUi()
    {
        if (_qualityButton !is null) _qualityButton.setText(format("%dp", _previewQualityHeight));
        if (_preview !is null)
            _preview.setQualityLabel(format("%dp composition", _previewQualityHeight));
    }

    private void showExportContextMenu(Point point)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Export MP4…", IconKind.save,
            delegate() { openExportDialog(ExportKind.mp4); }, "Ctrl+E");
        items ~= ContextMenuItem.command("Export MP3…", IconKind.music,
            delegate() { openExportDialog(ExportKind.mp3); }, "Ctrl+Shift+E");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Set export In at playhead", delegate() {
            setWorkIn(_timeline.playhead());
        }, "I");
        items ~= ContextMenuItem.command("Set export Out at playhead", delegate() {
            setWorkOut(_timeline.playhead());
        }, "O");
        items ~= ContextMenuItem.command("Clear export In/Out", delegate() {
            clearWorkRange();
        }, "Shift+I/O", _hasWorkIn || _hasWorkOut);
        showContextMenu(_exportButton is null ? _sequencePreviewButton : _exportButton, point, items);
    }

    private void showMediaContextMenu(int requestedIndex, Point point)
    {
        const index = requestedIndex >= 0 ? requestedIndex : selectedMediaIndex();
        const valid = index >= 0 && index < cast(int) _model.assets.length;
        const asset = valid ? _model.assets[cast(size_t) index] : null;
        const canVideo = asset !is null && asset.hasVideo;
        const canAudio = asset !is null && asset.hasAudio;
        const uses = valid ? _model.assetUseCount(cast(size_t) index) : 0;

        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Save project", IconKind.save,
            delegate() { saveProject(false); }, "Ctrl+S");
        items ~= ContextMenuItem.command("Save project as…", IconKind.save,
            delegate() { saveProject(true); }, "Ctrl+Shift+S");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Import media…", IconKind.open,
            delegate() { openImportDialog(); }, "Ctrl+I");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Add to V1", IconKind.image, delegate() {
            addAssetToTrack(cast(size_t) index, TrackAddress(TrackKind.video, 0),
                false, 0.0);
        }, "", canVideo);
        items ~= ContextMenuItem.command("Add to A1", IconKind.music, delegate() {
            addAssetToTrack(cast(size_t) index, TrackAddress(TrackKind.audio, 0),
                false, 0.0);
        }, "", canAudio);
        items ~= ContextMenuItem.command("Add video + audio", IconKind.start, delegate() {
            addLinkedMedia(cast(size_t) index, false);
        }, "", canVideo && canAudio);
        items ~= ContextMenuItem.command("Place on new video track at playhead", delegate() {
            addAssetToTrack(cast(size_t) index,
                TrackAddress(TrackKind.video, _model.trackCount(TrackKind.video)),
                true, _timeline.playhead());
        }, "", canVideo);
        items ~= ContextMenuItem.command("Place on new audio track at playhead", delegate() {
            addAssetToTrack(cast(size_t) index,
                TrackAddress(TrackKind.audio, _model.trackCount(TrackKind.audio)),
                true, _timeline.playhead());
        }, "", canAudio);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Show in File Explorer", IconKind.folder, delegate() {
            revealMedia(cast(size_t) index);
        }, "", valid);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Remove from project", IconKind.trash, delegate() {
            removeMedia(cast(size_t) index, false);
        }, "", valid && uses == 0);
        items ~= ContextMenuItem.command(format("Remove with %d sequence clip%s", uses,
            uses == 1 ? "" : "s"), IconKind.trash, delegate() {
            removeMedia(cast(size_t) index, true);
        }, "", valid && uses > 0);
        showContextMenu(_mediaList, point, items);
    }

    private static string effectPropertyLabel(EffectProperty property)
    {
        final switch (property)
        {
            case EffectProperty.volume: return "Audio gain";
            case EffectProperty.scale: return "Scale";
            case EffectProperty.positionX: return "Position X";
            case EffectProperty.positionY: return "Position Y";
            case EffectProperty.opacity: return "Layer opacity";
            case EffectProperty.rotation: return "Rotation";
            case EffectProperty.textSize: return "Text size";
        }
    }

    private static string interpolationLabel(KeyframeInterpolation interpolation)
    {
        final switch (interpolation)
        {
            case KeyframeInterpolation.linear: return "Linear";
            case KeyframeInterpolation.bezier: return "Bezier";
            case KeyframeInterpolation.hold: return "Hold";
        }
    }

    private void removeTimelineKeyframe(TrackAddress track, int index,
        EffectProperty property, double localTime)
    {
        auto before = captureTimelineSnapshot("Remove effect keyframe");
        if (!_model.removeKeyframe(track, index, property, localTime, 0.03))
        {
            setStatus("The keyframe no longer exists.");
            return;
        }
        commitHistory(before);
        markTimelineChanged();
        _timeline.visualChanged();
        _timeline.setSelection(track, index, false);
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(effectPropertyLabel(property) ~ " keyframe removed.");
    }

    private void changeTimelineKeyframeInterpolation(TrackAddress track, int index,
        EffectProperty property, double localTime,
        KeyframeInterpolation interpolation)
    {
        auto before = captureTimelineSnapshot("Change keyframe interpolation");
        if (!_model.setKeyframeInterpolation(track, index, property,
            localTime, interpolation, 0.03))
        {
            setStatus("The keyframe already uses " ~
                interpolationLabel(interpolation) ~ " interpolation.");
            return;
        }
        commitHistory(before);
        markTimelineChanged();
        _timeline.visualChanged();
        _timeline.setSelection(track, index, false);
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(effectPropertyLabel(property) ~ " keyframe changed to " ~
            interpolationLabel(interpolation) ~ ".");
    }

    private void showTimelineContextMenu(TrackAddress track, int index, Point point)
    {
        const validTrack = _model.validTrack(track);
        const clips = validTrack ? _model.trackValue(track).clips : null;
        const validClip = index >= 0 && index < cast(int) clips.length;
        const mediaIndex = selectedMediaIndex();
        const canAddSelected = mediaIndex >= 0 &&
            _model.canPlace(cast(size_t) mediaIndex, track.kind);

        ContextMenuItem[] items;
        if (validClip)
        {
            const clip = clips[cast(size_t) index];
            const asset = _model.assetForClip(clip);
            EffectProperty markerProperty;
            double markerLocalTime;
            KeyframeInterpolation markerInterpolation;
            const overKeyframe = _timeline.keyframeAtGlobalPoint(track, index, point,
                markerProperty, markerLocalTime, markerInterpolation);
            if (overKeyframe)
            {
                const capturedProperty = markerProperty;
                const capturedTime = markerLocalTime;
                const capturedInterpolation = markerInterpolation;
                items ~= ContextMenuItem.command(format("%s keyframe at %s",
                    effectPropertyLabel(capturedProperty),
                    formatTimecode(clip.start + capturedTime)), delegate() {}, "", false);
                items ~= ContextMenuItem.command("Remove keyframe", delegate() {
                    removeTimelineKeyframe(track, index, capturedProperty, capturedTime);
                });
                items ~= ContextMenuItem.check("Linear interpolation",
                    capturedInterpolation == KeyframeInterpolation.linear, delegate() {
                        changeTimelineKeyframeInterpolation(track, index,
                            capturedProperty, capturedTime, KeyframeInterpolation.linear);
                    });
                items ~= ContextMenuItem.check("Bezier interpolation",
                    capturedInterpolation == KeyframeInterpolation.bezier, delegate() {
                        changeTimelineKeyframeInterpolation(track, index,
                            capturedProperty, capturedTime, KeyframeInterpolation.bezier);
                    });
                items ~= ContextMenuItem.check("Hold interpolation",
                    capturedInterpolation == KeyframeInterpolation.hold, delegate() {
                        changeTimelineKeyframeInterpolation(track, index,
                            capturedProperty, capturedTime, KeyframeInterpolation.hold);
                    });
                items ~= ContextMenuItem.separatorItem();
            }
            const canSplit = _model.clipAtTime(track, _timeline.playhead()) == index;
            items ~= ContextMenuItem.command("Split at playhead", delegate() {
                _timeline.setSelection(track, index, false);
                splitSelected();
            }, "S", canSplit);
            items ~= ContextMenuItem.command("Copy", IconKind.file, delegate() {
                _timeline.setSelection(track, index, false);
                copySelected();
            }, "Ctrl+C");
            items ~= ContextMenuItem.command("Paste at playhead", delegate() {
                _timeline.setSelection(track, index, false);
                pasteClipboard();
            }, "Ctrl+V", _clipboardHasClip);
            items ~= ContextMenuItem.command("Duplicate", IconKind.file, delegate() {
                _timeline.setSelection(track, index, false);
                duplicateSelected();
            }, "Ctrl+D");
            items ~= ContextMenuItem.command("Nudge left 0.1s", delegate() {
                _timeline.setSelection(track, index, false);
                nudgeSelected(-0.1);
            });
            items ~= ContextMenuItem.command("Nudge right 0.1s", delegate() {
                _timeline.setSelection(track, index, false);
                nudgeSelected(0.1);
            });
            items ~= ContextMenuItem.separatorItem();

            if (asset !is null && asset.hasVideo)
            {
                foreach (lane; 0 .. _model.trackCount(TrackKind.video))
                    addMoveTrackItem(items, TrackAddress(TrackKind.video, lane), track, index);
                const target = TrackAddress(TrackKind.video,
                    _model.trackCount(TrackKind.video));
                items ~= ContextMenuItem.command("Move to new video track", delegate() {
                    _timeline.setSelection(track, index, false);
                    moveSelectedToTrack(target);
                });
            }
            if (asset !is null && asset.hasAudio)
            {
                foreach (lane; 0 .. _model.trackCount(TrackKind.audio))
                    addMoveTrackItem(items, TrackAddress(TrackKind.audio, lane), track, index);
                const target = TrackAddress(TrackKind.audio,
                    _model.trackCount(TrackKind.audio));
                items ~= ContextMenuItem.command("Move to new audio track", delegate() {
                    _timeline.setSelection(track, index, false);
                    moveSelectedToTrack(target);
                });
            }

            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.command("Reset trim", delegate() {
                _timeline.setSelection(track, index, false);
                resetSelectedTrim();
            });
            if (!clip.isText())
            {
                items ~= ContextMenuItem.check("Reverse clip", clip.reversed, delegate() {
                    auto before = captureTimelineSnapshot("Reverse clip");
                    if (_model.setReversed(track, index, !clip.reversed))
                    {
                        commitHistory(before);
                        afterTimelineMutation(!clip.reversed ? "Clip reversed." :
                            "Clip restored to forward playback.", track, index, false);
                    }
                });
                items ~= ContextMenuItem.command("Speed 0.5×", delegate() {
                    setSelectedClipSpeed(track, index, 0.5);
                });
                items ~= ContextMenuItem.command("Speed 1×", delegate() {
                    setSelectedClipSpeed(track, index, 1.0);
                });
                items ~= ContextMenuItem.command("Speed 2×", delegate() {
                    setSelectedClipSpeed(track, index, 2.0);
                });
            }
            if (!clip.isText() && asset !is null && asset.hasAudio)
            {
                items ~= ContextMenuItem.command("Audio gain −3 dB", delegate() {
                    adjustClipGainDb(track, index, -3.0);
                });
                items ~= ContextMenuItem.command("Audio gain +3 dB", delegate() {
                    adjustClipGainDb(track, index, 3.0);
                });
                items ~= ContextMenuItem.command("Set audio gain to 0 dB", delegate() {
                    setClipGainDb(track, index, 0.0);
                }, "", fabs(clip.volume - 1.0) > 0.000_5);
                items ~= ContextMenuItem.check("Mute clip audio", clip.muted, delegate() {
                    setClipMuted(track, index, !clip.muted);
                });
                items ~= ContextMenuItem.command("Reset audio effect", delegate() {
                    _timeline.setSelection(track, index, false);
                    resetSelectedAudio();
                }, "", clip.volume != 1.0 || clip.muted);
            }
            if (track.kind == TrackKind.video && asset !is null && asset.hasAudio)
            {
                items ~= ContextMenuItem.command("Detach audio to separate A track",
                    delegate() { detachSelectedAudio(track, index); });
                items ~= ContextMenuItem.check("Show embedded audio on A track",
                    clip.audioProxyVisible, delegate() {
                        _timeline.setSelection(track, index, false);
                        syncInspector();
                        auto before = captureTimelineSnapshot(clip.audioProxyVisible ?
                            "Hide embedded audio lane" : "Show embedded audio lane");
                        if (_model.setClipAudioProxyVisible(track, index, !clip.audioProxyVisible))
                        {
                            commitHistory(before);
                            afterTimelineMutation(clip.audioProxyVisible ?
                                "Embedded audio display hidden." :
                                "Embedded audio is shown on the matching A track.",
                                track, index, false);
                        }
                    });
            }
            const contextTime = _timeline.timeAtGlobalPoint(point);
            const localContextTime = contextTime - clip.start;
            if (clip.fadeIn > 0.0 && localContextTime >= 0.0 &&
                localContextTime <= clip.fadeIn + 0.05)
                items ~= ContextMenuItem.command("Remove fade in", delegate() {
                    setTransitionRequested(track, index, true, 0.0);
                });
            if (clip.fadeOut > 0.0 && localContextTime >=
                clip.duration() - clip.fadeOut - 0.05 &&
                localContextTime <= clip.duration() + 0.05)
                items ~= ContextMenuItem.command("Remove fade out", delegate() {
                    setTransitionRequested(track, index, false, 0.0);
                });
            items ~= ContextMenuItem.command("Fade in/out 0.5s", delegate() {
                _timeline.setSelection(track, index, false);
                auto before = captureTimelineSnapshot("Set clip fades");
                bool changed;
                changed = _model.setFadeIn(track, index, 0.5) || changed;
                changed = _model.setFadeOut(track, index, 0.5) || changed;
                if (changed)
                {
                    commitHistory(before);
                    afterTimelineMutation("Clip fade-in/fade-out set to 0.5s.",
                        track, index, false);
                }
            });
            items ~= ContextMenuItem.command("Clear clip fades", delegate() {
                _timeline.setSelection(track, index, false);
                auto before = captureTimelineSnapshot("Clear clip fades");
                bool changed;
                changed = _model.setFadeIn(track, index, 0.0) || changed;
                changed = _model.setFadeOut(track, index, 0.0) || changed;
                if (changed)
                {
                    commitHistory(before);
                    afterTimelineMutation("Clip fades cleared.", track, index, false);
                }
            }, "", clip.fadeIn > 0.0 || clip.fadeOut > 0.0);
            if (clip.isText())
                items ~= ContextMenuItem.command("Edit text in Preview", delegate() {
                    _timeline.setSelection(track, index, false);
                    syncInspector();
                    focusSelectedTextField();
                });
            items ~= ContextMenuItem.command("Reset transform", delegate() {
                _timeline.setSelection(track, index, false);
                resetSelectedTransform();
            }, "", track.kind == TrackKind.video);
            items ~= ContextMenuItem.command("Reset all effects / properties", delegate() {
                _timeline.setSelection(track, index, false);
                resetSelectedProperties();
            });
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.command("Delete clip", IconKind.trash, delegate() {
                _timeline.setSelection(track, index, false);
                deleteSelected();
            }, "Del");
            items ~= ContextMenuItem.separatorItem();
        }

        if (!validClip)
            items ~= ContextMenuItem.command("Paste at playhead", delegate() {
                pasteClipboard();
            }, "Ctrl+V", _clipboardHasClip);
        items ~= ContextMenuItem.command(format("Place selected media on %s",
            track.label()), track.kind == TrackKind.video ? IconKind.image : IconKind.music,
            delegate() {
                addAssetToTrack(cast(size_t) mediaIndex, track, true,
                    _timeline.playhead());
            }, "", canAddSelected);
        items ~= ContextMenuItem.command("Add video track", delegate() {
            addTrack(TrackKind.video);
        });
        items ~= ContextMenuItem.command("Add audio track", delegate() {
            addTrack(TrackKind.audio);
        });
        if (validTrack)
        {
            const timelineTrack = _model.trackValue(track);
            items ~= ContextMenuItem.check("Mute " ~ track.label(), timelineTrack.muted,
                delegate() { toggleTrackMuted(track); });
            items ~= ContextMenuItem.check(
                (track.kind == TrackKind.video ? "Hide " : "Disable ") ~ track.label(),
                timelineTrack.disabled, delegate() { toggleTrackDisabled(track); });
            items ~= ContextMenuItem.command("Remove empty " ~ track.label(), delegate() {
                removeTrack(track);
            }, "", timelineTrack.clips.length == 0 &&
                _model.trackCount(track.kind) > 1);
        }
        items ~= ContextMenuItem.command("Zoom sequence to fit", delegate() {
            _timeline.zoomToFit();
        });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Undo", delegate() { undo(); }, "Ctrl+Z",
            _undo.length > 0);
        items ~= ContextMenuItem.command("Redo", delegate() { redo(); }, "Ctrl+Y",
            _redo.length > 0);
        showContextMenu(_timeline, point, items);
    }

    private void addMoveTrackItem(ref ContextMenuItem[] items, TrackAddress target,
        TrackAddress source, int index)
    {
        const enabled = target != source;
        items ~= ContextMenuItem.command("Move to " ~ target.label(), delegate() {
            _timeline.setSelection(source, index, false);
            moveSelectedToTrack(target);
        }, "", enabled);
    }

    private void showPreviewContextMenu(Point point)
    {
        // Composition Preview is always the timeline monitor. Project Media
        // selection never changes this surface into a separate source player.
        const canPlayCurrent = _model.sequenceDuration() > 0.0 ||
            _playbackKind != PlaybackKind.none;

        ContextMenuItem[] items;
        string playLabel = "Play";
        if (_playbackKind != PlaybackKind.none)
            playLabel = _playbackRunning ? "Pause" : "Resume";
        items ~= ContextMenuItem.command(playLabel, IconKind.start,
            delegate() { playCurrentContext(); }, "Space", canPlayCurrent);
        items ~= ContextMenuItem.command("Refresh timeline frame",
            delegate() { scheduleTimelineFrame(); }, "",
            _model.sequenceDuration() > 0.0);
        items ~= ContextMenuItem.command("Add text", delegate() {
            addTextAtPlayheadFromPreview();
        });
        items ~= ContextMenuItem.command("Stop", delegate() {
            stopPlayback(true);
            setStatus("Playback stopped.");
        }, "Esc", _playbackKind != PlaybackKind.none);
        items ~= ContextMenuItem.command("Cancel background render", delegate() {
            cancelBackgroundRender();
        }, "", _exportJob.state().running);
        items ~= ContextMenuItem.separatorItem();
        addQualityItem(items, 720);
        addQualityItem(items, 1080);
        addQualityItem(items, 1440);
        addQualityItem(items, 2160);
        items ~= ContextMenuItem.separatorItem();
        addPlaybackPerformanceItems(items);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("H.264 encoding: " ~
            _tools.videoAcceleration, delegate() {}, "", false);
        showContextMenu(_preview, point, items);
    }

    private void revealMedia(size_t index)
    {
        if (index >= _model.assets.length) return;
        const path = _model.assets[index].path;
        if (revealPathInFileManager(path, "source location"))
            setStatus("Opened the source location for " ~ _model.assets[index].name ~ ".");
    }

    private void revealExportOutput()
    {
        if (_lastExportPath.length == 0)
        {
            setStatus("No completed export is available yet.");
            return;
        }
        if (!exists(_lastExportPath))
        {
            setStatus("The last export is no longer at " ~ _lastExportPath);
            if (_revealExportButton !is null) _revealExportButton.setEnabled(false);
            return;
        }
        if (revealPathInFileManager(_lastExportPath, "export output"))
            setStatus("Opened the export output folder.");
    }

    private bool revealPathInFileManager(string path, string description)
    {
        try
        {
            string[] arguments;
            version (Windows)
                arguments = ["explorer.exe", "/select,", path];
            else version (OSX)
                arguments = ["open", "-R", path];
            else
                arguments = ["xdg-open", dirName(path)];
            spawnProcess(arguments, cast(const string[string]) null,
                Config.detached | Config.suppressConsole);
            return true;
        }
        catch (Exception error)
        {
            setStatus("Could not open the " ~ description ~ ": " ~
                outputTail(error.msg, 500));
            return false;
        }
    }

    private void removeMedia(size_t index, bool removeClips)
    {
        if (index >= _model.assets.length) return;
        const name = _model.assets[index].name;
        const uses = _model.assetUseCount(index);
        if (!_model.removeAsset(index, removeClips))
        {
            setStatus(format("%s is used by %d sequence clip%s.", name, uses,
                uses == 1 ? "" : "s"));
            return;
        }

        clearHistory();
        markTimelineChanged();
        _timeline.modelChanged();
        _timeline.setSelection(TrackAddress(TrackKind.video, 0), -1, false);
        syncMediaList();
        const next = _model.assets.length == 0 ? -1 :
            cast(int) (index < _model.assets.length ? index : _model.assets.length - 1);
        _mediaList.setSelectedIndex(next);
        syncTimelineRange();
        syncInspector();
        if (_playbackKind == PlaybackKind.none) scheduleTimelineFrame();
        setStatus(removeClips && uses > 0
            ? format("Removed %s and %d sequence clip%s.", name, uses,
                uses == 1 ? "" : "s")
            : "Removed " ~ name ~ " from the project.");
    }

    /** Scale pixel-based effects when the interactive compositor runs below
     * the selected export resolution. Relative layout stays identical while
     * 1440p/2160p projects remain responsive at 720p or 1080p preview quality. */
    private void scalePreviewPixelEffects(ref ExportRequest request,
        int authoredHeight, int renderHeight)
    {
        if (authoredHeight <= 0 || renderHeight <= 0 || authoredHeight == renderHeight)
            return;
        const factor = cast(double) renderHeight / authoredHeight;
        foreach (ref clip; request.video)
        {
            clip.blur *= factor;
            clip.shadowBlur *= factor;
            clip.shadowOffsetX *= factor;
            clip.shadowOffsetY *= factor;
            clip.strokeWidth *= factor;
            clip.textSize *= factor;
            foreach (ref keyframe; clip.keyframes)
                if (keyframe.property == EffectProperty.textSize)
                    keyframe.value *= factor;
        }
        request.cacheKey ^= cast(ulong) renderHeight << 48;
    }

    /** Build only the visible video layer from each track for one scrub frame. */
    private ExportRequest buildFrameRequest(double sequenceTime, ExportPreset preset)
    {
        ExportRequest request;
        request.kind = ExportKind.mp4;
        request.preset = preset;
        // Title edits never alter the decoded video/image background.
        request.cacheKey = _modelRevision;
        request.videoEncoder = _tools.h264Encoder;
        request.videoAcceleration = _tools.videoAcceleration;
        request.hardwareVideoEncoding = _tools.hardwareVideoEncoding;
        request.renderTitles = false;
        foreach (lane; 0 .. _model.trackCount(TrackKind.video))
        {
            const address = TrackAddress(TrackKind.video, lane);
            const track = _model.trackValue(address);
            if (track.disabled) continue;
            const index = _model.clipAtTime(address, sequenceTime);
            if (index < 0) continue;
            const clip = track.clips[cast(size_t) index];
            if (clip.isText())
            {
                // Preview frames are permanently text-free. Every active title
                // is a retained Aurora layer above this video/image background.
                continue;
            }
            const asset = _model.assetForClip(clip);
            if (asset is null || !asset.hasVideo) continue;
            request.video ~= exportClip(asset, clip, lane, track);
        }
        return request;
    }

    private void dispatchPendingPreview()
    {
        const decode = _preview.recommendedDecodeSize(_previewQualityHeight);
        final switch (_pendingPreviewKind)
        {
            case PendingPreviewKind.none:
                return;
            case PendingPreviewKind.asset:
                // Source preview requests are intentionally redirected to the
                // timeline monitor. Composition Preview never locks to a media
                // item or selected clip.
                _pendingPreviewKind = PendingPreviewKind.sequence;
                dispatchPendingPreview();
                return;
            case PendingPreviewKind.sequence:
                MediaAsset directAsset;
                double directSourceTime;
                if (!_inlineTextEditing && resolveDirectSequenceFrame(
                    _pendingPreviewTime, directAsset, directSourceTime))
                {
                    _previewService.requestAsset(directAsset, directSourceTime,
                        decode.width, decode.height);
                    break;
                }
                // Only actual overlays/transforms/text use the compositor.
                // Plain V1 footage follows the faster source-frame path.
                const renderHeight = liveDecodeHeight();
                auto request = buildFrameRequest(_pendingPreviewTime,
                    ExportPreset.previewForHeight(renderHeight));
                scalePreviewPixelEffects(request, _previewQualityHeight, renderHeight);
                _previewService.requestComposition(request, _pendingPreviewTime,
                    decode.width, decode.height);
                break;
        }
        _pendingPreviewKind = PendingPreviewKind.none;
    }

    protected override void onTick(double deltaSeconds)
    {
        drainImportedMedia();
        _audioPlayer.poll();

        if (_sourceAudioRefreshPending)
        {
            _sourceAudioRefreshDelay += deltaSeconds;
            if (_sourceAudioRefreshDelay >= 0.075)
            {
                _sourceAudioRefreshPending = false;
                _sourceAudioRefreshDelay = 0.0;
                refreshSourceAudio();
            }
        }

        if (_sequenceRefreshPending)
        {
            _sequenceRefreshDelay += deltaSeconds;
            if (_sequenceRefreshDelay >= 0.14)
            {
                _sequenceRefreshPending = false;
                _sequenceRefreshDelay = 0.0;
                refreshSequenceAfterEdit();
            }
        }

        // Seek gestures never spawn/wait synchronously. While the mouse is held,
        // an occasional still frame is requested after the pointer settles. On
        // release, exactly one streaming decoder generation is started.
        if (_seekPending && _playbackKind != PlaybackKind.none)
        {
            _seekDelay += deltaSeconds;
            if (_seekGesture)
            {
                if (_seekDelay >= 0.18 &&
                    (_seekStillTarget < 0.0 ||
                     fabs(_seekTarget - _seekStillTarget) >= 0.010))
                {
                    _playbackPosition = _seekTarget;
                    // A settled drag gets a small responsive thumbnail; release
                    // commits the full live decoder exactly once.
                    requestPlaybackStill(540);
                    _seekStillTarget = _seekTarget;
                    _seekDelay = 0.0;
                }
            }
            else if (_seekDelay >= 0.055)
                commitPendingSeek();
        }

        if (_playbackRunning && !_seekPending && _playbackAsset !is null)
        {
            if (_playbackAwaitingAudioClock)
            {
                _playbackAudioClockWait += deltaSeconds;
                double audioPosition;
                if (_audioPlayer.clockPosition(audioPosition))
                {
                    _playbackPosition = clampValue(audioPosition,
                        _playbackStart, _playbackEnd);
                    _playbackAwaitingAudioClock = false;
                    _playbackAwaitingFirstFrame = false;
                    resetPlaybackClock();
                    setStatus(playbackRunningStatus());
                    _preview.setPlaying(true);
                }
                else if (_playbackAudioClockWait >= 0.85)
                {
                    _audioPlayer.stop();
                    _playbackAudioStarted = false;
                    _playbackAwaitingAudioClock = false;
                    _playbackAwaitingFirstFrame = false;
                    resetPlaybackClock();
                    setStatus("Audio output did not become ready; continuing video preview.");
                    _preview.setPlaying(true);
                }
            }

            if (!_playbackAwaitingAudioClock && !_playbackAwaitingFirstFrame)
            {
                _playbackPosition = clampValue(clockPlaybackPosition(),
                    _playbackStart, _playbackEnd);
                if (_sequencePlaybackLive && _liveAudioEnd >= 0.0)
                {
                    // End an active item a fraction early, but do not repeatedly
                    // probe a silent gap before the next item's exact start.
                    const lead = _liveAudioClipId != 0 ? 0.02 : 0.0;
                    if (_playbackPosition >= _liveAudioEnd - lead)
                        startLiveTimelineAudio();
                }
            }
            bool receivedFrame;
            PreviewFrame frame;
            if (!_playbackAwaitingAudioClock && _videoStream.takeReady(frame))
            {
                receivedFrame = true;
                bool handledFrame;
                if (_playbackAwaitingFirstFrame && frame.valid())
                {
                    _playbackPosition = playbackTimeForFrame(frame);
                    double audioPosition = _playbackPosition;
                    const audioStarted = startPlaybackAudio();
                    const audioClockReady = audioStarted &&
                        _audioPlayer.clockPosition(audioPosition);
                    if (audioStarted && !audioClockReady)
                    {
                        _playbackAwaitingAudioClock = true;
                        _playbackAudioClockWait = 0.0;
                        _preview.setFrame(frame);
                        _preview.setPlaying(false);
                        handledFrame = true;
                    }
                    else
                    {
                        if (audioClockReady)
                            _playbackPosition = clampValue(audioPosition,
                                _playbackStart, _playbackEnd);
                        _playbackAwaitingFirstFrame = false;
                        resetPlaybackClock();
                        setStatus(playbackRunningStatus());
                    }
                }
                if (!handledFrame)
                {
                    _preview.setFrame(frame);
                    _preview.setPlaying(!_playbackAwaitingFirstFrame);
                }
            }
            else if (_videoStream.finished() && _playbackAsset.hasVideo)
            {
                const error = _videoStream.error();
                if (error.length > 0)
                    setStatus("Embedded decoder ended: " ~ outputTail(error, 600));
                if (_playbackAwaitingFirstFrame)
                {
                    _playbackRunning = false;
                    _playbackClockValid = false;
                    _playbackAwaitingFirstFrame = false;
                    _preview.setPlaying(false);
                    updatePlaybackButtons();
                    updateTimeLabel();
                }
            }

            if (_playbackRunning && !_playbackAwaitingFirstFrame &&
                _playbackPosition >= _playbackEnd - 0.001)
                finishPlayback();
            else if (_playbackRunning && !_playbackAwaitingFirstFrame)
            {
                _transportPaintAccumulator += deltaSeconds;
                // The transport and timeline are visual controls, not clocks.
                // Updating them at 30 Hz keeps pointer input instant while the
                // decoder continues at the source frame rate.
                if (_transportPaintAccumulator >= 1.0 / 30.0 || receivedFrame)
                {
                    _transportPaintAccumulator = 0.0;
                    if (_playbackKind == PlaybackKind.sequence)
                    {
                        _timeline.setPlayhead(_playbackPosition, false);
                        syncPreviewTitleLayers(_playbackPosition);
                    }
                    _scrub.setValue(_playbackPosition, false);
                    if (_lastTimeLabelPlaybackPosition < 0.0 ||
                        fabs(_playbackPosition - _lastTimeLabelPlaybackPosition) >= 0.10)
                    {
                        _lastTimeLabelPlaybackPosition = _playbackPosition;
                        updateTimeLabel();
                    }
                }

                if (!_playbackAsset.hasVideo &&
                    (_lastPreviewClockPaint < 0.0 ||
                     fabs(_playbackPosition - _lastPreviewClockPaint) >= 0.10))
                {
                    _lastPreviewClockPaint = _playbackPosition;
                    _preview.setPlaybackTime(_playbackPosition);
                }
            }
        }

        if (_pendingPreviewKind != PendingPreviewKind.none &&
            _playbackKind == PlaybackKind.none)
        {
            _pendingPreviewDelay += deltaSeconds;
            if (_pendingPreviewDelay >= 0.06)
                dispatchPendingPreview();
        }

        PreviewFrame staticFrame;
        if (_previewService.takeReady(staticFrame))
        {
            if (_playbackKind == PlaybackKind.none)
                _preview.setFrame(staticFrame);
            else if (_seekPending || !_playbackRunning)
            {
                _preview.setFrame(staticFrame);
                _preview.setPlaying(false);
            }
            else if (_playbackKind == PlaybackKind.source &&
                _playbackAsset !is null && !_playbackAsset.hasVideo)
            {
                // MP3 source playback uses an internally rendered waveform;
                // PCM preview audio supplies only audio output.
                _preview.setFrame(staticFrame);
                _preview.setPlaying(_playbackRunning);
                _lastPreviewClockPaint = _playbackPosition;
                _preview.setPlaybackTime(_playbackPosition);
            }
        }

        const state = _exportJob.state();
        if (state.running)
        {
            if (_lastProgressValue < 0.0 ||
                fabs(state.progress - _lastProgressValue) >= 0.002)
            {
                _lastProgressValue = state.progress;
                _progress.setValue(state.progress);
            }
            const progressPercent = cast(int) (state.progress * 100.0 + 0.5);
            if (progressPercent != _lastProgressPercent)
            {
                _lastProgressPercent = progressPercent;
                _lastProgressLabel = format("%d%%", progressPercent);
                _progress.setLabel(_lastProgressLabel);
            }
            if (state.status != _lastJobStatus)
            {
                _lastJobStatus = state.status;
                setStatus(state.status);
            }
        }
        else if (state.done && !_jobCompletionHandled)
        {
            _jobCompletionHandled = true;
            _lastProgressValue = state.success ? 1.0 : 0.0;
            _lastProgressPercent = state.success ? 100 : 0;
            _lastProgressLabel = state.success ? "Done" : "Failed";
            _progress.setValue(_lastProgressValue);
            _progress.setLabel(_lastProgressLabel);
            const completedPurpose = _jobPurpose;
            _jobPurpose = JobPurpose.none;
            if (state.success)
            {
                if (completedPurpose == JobPurpose.previewTimeline)
                {
                    if (_previewRenderRevision != _modelRevision ||
                        _previewRenderHeight != _previewQualityHeight)
                    {
                        setStatus("Preview rendered, but the sequence or quality changed. Current playback was not interrupted.");
                    }
                    else if (!exists(state.outputPath))
                        setStatus("Preview render completed, but its proxy file is missing.");
                    else
                    {
                        // The background render already knows every property of
                        // the proxy. Avoid a synchronous FFprobe process on the
                        // UI thread at completion.
                        const preset = ExportPreset.previewForHeight(_previewRenderHeight);
                        auto asset = new MediaAsset(state.outputPath);
                        asset.name = format("Sequence 01 • %dp composition",
                            _previewRenderHeight);
                        asset.duration = _model.sequenceDuration();
                        asset.hasVideo = true;
                        asset.hasAudio = true;
                        asset.width = preset.width;
                        asset.height = preset.height;
                        asset.frameRate = preset.fps;
                        asset.audioChannels = 2;
                        asset.sampleRate = 48_000;
                        _renderedPreviewAsset = asset;
                        _renderedPreviewRevision = _previewRenderRevision;
                        _renderedPreviewHeight = _previewRenderHeight;
                        playRenderedSequence();
                    }
                }
                else
                {
                    _lastExportPath = state.outputPath;
                    if (_revealExportButton !is null)
                        _revealExportButton.setEnabled(exists(_lastExportPath));
                    setStatus("Export complete: " ~ state.outputPath);
                }
            }
            else if (state.cancelled)
                setStatus("Background render cancelled. Editing and playback were not interrupted.");
            else
                setStatus("Render failed: " ~ outputTail(state.error, 1000));
        }
    }

    private void setStatus(string text)
    {
        if (_status is null || text == _lastStatusText) return;
        _lastStatusText = text;
        _status.setText(text);
    }

    private static bool hasFocusedTextEditor(Widget widget)
    {
        if (widget is null || !widget.visible()) return false;
        auto editor = cast(TextEditor) widget;
        if (editor !is null && editor.focused()) return true;
        foreach (child; widget.children())
            if (hasFocusedTextEditor(child)) return true;
        return false;
    }

    override bool onKeyDown(ref Event event)
    {
        const command = event.control() || event.meta();
        if (command && event.key == Key.s)
        {
            saveProject(event.shift());
            return true;
        }
        if (command && event.key == Key.o)
        {
            openProjectDialog();
            return true;
        }
        if (command && event.key == Key.i)
        {
            openImportDialog();
            return true;
        }
        if (command && event.key == Key.e)
        {
            openExportDialog(event.shift() ? ExportKind.mp3 : ExportKind.mp4);
            return true;
        }
        if (command && event.key == Key.z)
        {
            if (event.shift()) redo(); else undo();
            return true;
        }
        if (command && event.key == Key.y)
        {
            redo();
            return true;
        }
        if (command && event.key == Key.c)
        {
            copySelected();
            return true;
        }
        if (command && event.key == Key.v)
        {
            pasteClipboard();
            return true;
        }
        if (command && event.key == Key.d)
        {
            duplicateSelected();
            return true;
        }
        // Printable/editor keys must remain owned by the focused text control.
        // Aurora dispatches key-down before the separate text-input event, so
        // allowing Space, P, S, V, C, R, or Delete to bubble here would run an
        // editor shortcut before the character is inserted.
        if (hasFocusedTextEditor(this)) return false;
        if (!command && !event.alt() && event.key == Key.s)
        {
            splitSelected();
            return true;
        }
        if (!command && !event.alt() && event.key == Key.p)
        {
            playCurrentContext();
            return true;
        }
        if (!command && !event.alt() && event.key == Key.space)
        {
            playCurrentContext();
            return true;
        }
        if (!command && !event.alt() && event.key == Key.escape)
        {
            stopPlayback(true);
            setStatus("Playback stopped.");
            return true;
        }
        if (!command && !event.alt() && event.key == Key.deleteKey)
        {
            deleteSelected();
            return true;
        }
        return false;
    }
}

module aurorastream.root;

import aurora;
import aurorastream.appupdate : launchUpdater, newerReleaseTag, stageLatestUpdate;
import aurorastream.appversion : appDisplayName, appFullVersion;
import aurorastream.audioendpoint : AudioEndpoint;
import aurorastream.audiodevices : AudioDeviceScanner;
import aurorastream.bitratedropdown : BitrateDropdown;
import aurorastream.browser : BrowserChoice, availableBrowserChoices,
    browserChoiceLabel, openLocalFile, openPacingDiagnostic, openUrlInBrowser;
import aurorastream.activitylog : ActivityLog;
import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    BroadcastSnapshot, BroadcastWorker, CaptureSelection, EncoderSelection,
    captureSourceLabel, detectCaptureBackend, detectEncoder,
    effectiveYoutubeBitrateKbps, videoPipelineLabel, defaultAudioBitrateKbps,
    qualityHeight, qualityShortLabel, qualityWidth, twitchVideoBitrateKbps,
    youtubeVideoBitrateKbps;
import aurorastream.clipboardfield : ClipboardTextField;
import aurorastream.desktoppreview : DesktopPreviewCapturer;
import aurorastream.devicedropdown : AudioDeviceDropdown;
import aurorastream.entry : applicationIconPath;
import aurorastream.environment : settingsReport, systemEnvironmentReport;
import aurorastream.programcanvas : LiveSourceCanvasPreview;
import aurorastream.qualitydropdown : SourceQualityDropdown;
import aurorastream.settings : loadSettings, saveSettings, settingsFilePath;
import aurorastream.trayicon : TrayIcon;
import aurorastream.wasapi : AudioDeviceNotifications;
import aurorastream.windowsources : CaptureSourceDropdown, windowExists,
    windowIsMinimized;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : dur, msecs;
import std.format : format;
import std.string : startsWith, strip;

private enum twitchSettingsUrl = "https://dashboard.twitch.tv/settings/stream";
private enum youtubeLiveControlUrl = "https://studio.youtube.com/channel/UC/livestreaming";

final class StreamRoot : VBox
{
    private GuiWindow _window;
    private ActivityLog _activityLog;
    private bool _lastMinimized;
    private bool _lastStreamActive;
    private EncoderSelection _encoder;
    private CaptureSelection _capture;
    private BroadcastWorker _worker;
    private AudioDeviceScanner _audioScanner;
    private AudioDeviceNotifications _audioNotifications;
    private string[string] _deviceNameCache;
    private string _lastAudioScanSummary;
    private bool _pendingAudioRescan;
    private bool[string] _fieldWasPopulated;
    private double _audioRescanTimer = 0.0; // D floats default to NaN; explicit 0.0
    private enum double audioRescanIntervalSeconds = 8.0;

    private SourceQualityDropdown _sourceQuality;
    private LiveSourceCanvasPreview _canvasPreview;
    private Button _settingsMenu;
    private CaptureSourceDropdown _captureSource;
    private CheckBox _windowContentCapture;
    private bool _streamingServersVisible;
    private bool _liveSourcePreviewEnabled;
    private ScrollView _settingsScroll;
    private VBox _twitchServerGroup;
    private VBox _canvasPreviewPanel;
    private VBox _statusPanel;
    private Thread _previewCaptureThread;
    private Mutex _previewCaptureMutex;
    private DesktopPreviewCapturer _previewCapturer;
    private RgbaImage _previewCaptureImage;
    private ubyte[] _previewCaptureBuffer;
    private RgbaImage _previewCaptureFrame;
    private ulong _previewCaptureLastShownRevision;
    private int _previewCaptureTargetWidth = previewCaptureWidth;
    private int _previewCaptureTargetHeight = previewCaptureHeight;
    private string _previewCaptureWindowHwnd;
    private bool _previewCaptureRunning;
    private bool _previewCaptureDesired;
    private enum int previewCaptureWidth = 480;
    private enum int previewCaptureHeight = 270;
    private enum int previewCaptureFps = 30;
    private enum double previewCaptureIdleIntervalSeconds = 0.25;
    private CheckBox _twitchEnabled;
    private ClipboardTextField _twitchServer;
    private ClipboardTextField _twitchKey;
    private Button _twitchPaste;
    private VBox _youtubeServerGroup;
    private CheckBox _youtubeEnabled;
    private ClipboardTextField _youtubeServer;
    private ClipboardTextField _youtubeKey;
    private Button _youtubePaste;
    private SourceQualityDropdown _youtubeQuality;
    private BitrateDropdown _youtubeBitrate;
    private Label _youtubeProfile;
    private AudioDeviceDropdown _desktopAudio;
    private AudioDeviceDropdown _microphone;
    private Button _refreshAudioDevices;
    private ulong _audioDeviceGeneration;
    private bool _selectDefaultDesktopAudio;
    private Label _output;
    private Label _presetSummary;
    private Button _startStop;
    private Label _videoPath;
    private Label _status;
    private Label _metrics;
    private Label _diagnostics;
    private string _lastStatus;
    private string _lastMetrics;
    private string _lastDiagnostics;
    private string _localStatus;
    private bool _localStatusError;
    private bool _settingsDirty;
    private double _settingsSaveDelay;
    private string _settingsMessage;
    private bool _settingsMessageError;
    private bool _settingsLoadFailed;
    private BrowserChoice _browserChoice;
    private Mutex _updateMutex;
    private string _updateAvailable;
    private bool _updateChecked;
    private TrayIcon _tray;
    private bool _trayHidden;
    private bool _forceExit;
    private bool _minimizeToTrayOnStart;
    private bool _closeToTray;

    this(GuiWindow window, string executablePath)
    {
        super(8, Insets(10));
        _window = window;
        _updateMutex = new Mutex();
        _activityLog = new ActivityLog(executablePath);
        _activityLog.start();
        _activityLog.info(appFullVersion ~ " starting.");
        startUpdateCheck();
        _lastMinimized = _window.isMinimized();
        _worker = new BroadcastWorker(executablePath, _activityLog);
        _audioScanner = new AudioDeviceScanner();
        _audioNotifications = new AudioDeviceNotifications();
        _encoder = detectEncoder();
        _capture = detectCaptureBackend(_encoder);

        if (_encoder.ffmpegAvailable)
        {
            _activityLog.info(format("Encoder: %s (%s).",
                _encoder.label, _encoder.name));
            if (_encoder.name == "h264_nvenc" &&
                _encoder.d3d11DirectProbeAttempted &&
                !_encoder.d3d11DirectSupported)
                _activityLog.warning(
                    "Direct D3D11 to NVENC hardware-frame path is not supported " ~
                    "on this GPU/driver; the CPU compatibility path will be used.");
        }
        else
        {
            _activityLog.error(
                "FFmpeg was not found on PATH; streaming is unavailable.");
        }
        _activityLog.info("Capture backend: " ~ _capture.label ~ ".");
        _activityLog.info("Settings file: " ~ settingsFilePath());
        foreach (reportLine; systemEnvironmentReport())
            _activityLog.info(reportLine);

        bool settingsLoaded;
        string settingsLoadMessage;
        const saved = loadSettings(settingsLoaded, settingsLoadMessage);
        _selectDefaultDesktopAudio = saved.desktopAudioEnabled &&
            saved.desktopAudioDevice.strip().length == 0;
        _liveSourcePreviewEnabled = saved.liveSourcePreviewEnabled;
        foreach (deviceId, name; saved.deviceDisplayNameCache)
            if (deviceId.length > 0 && name.length > 0)
                _deviceNameCache[deviceId] = name;
        _settingsMessage = settingsLoadMessage;
        _settingsLoadFailed = !settingsLoaded &&
            settingsLoadMessage.startsWith("Could not load");
        _settingsMessageError = _settingsLoadFailed;
        if (_settingsLoadFailed)
        {
            _activityLog.error("Settings problem: " ~ settingsLoadMessage);
            _activityLog.action(
                "Action taken: started with default settings; the unreadable " ~
                "settings file was left untouched.");
        }
        else
        {
            _activityLog.info(settingsLoadMessage);
        }
        foreach (reportLine; settingsReport(saved, _encoder, _capture))
            _activityLog.info(reportLine);
        _browserChoice = saved.browserChoice;
        _minimizeToTrayOnStart = saved.minimizeToTrayOnStart;
        _closeToTray = saved.closeToTray;

        // A saved window-capture selection that can no longer be streamed (the
        // window is closed, belongs to an earlier Windows session, or is
        // minimized right now — a minimized window has a 0×0 client area that
        // gdigrab cannot capture) must not leave the capture-source selector
        // stuck on a red, non-streamable selection. Fall back to the entire
        // desktop and say so; the fallback is persisted on the next save so it
        // does not re-appear on every launch.
        string captureFallbackMessage;
        string initialCaptureHwnd = saved.windowCaptureHwnd.strip();
        string initialCaptureLabel = saved.windowCaptureLabel.strip();
        if (initialCaptureHwnd.length > 0)
        {
            const captureWindow = initialCaptureHwnd;
            const captureLabel = initialCaptureLabel.length > 0 ?
                initialCaptureLabel : "window " ~ captureWindow;
            if (!windowExists(captureWindow))
            {
                captureFallbackMessage = "The saved capture window (" ~
                    captureLabel ~ ") is no longer open, so Aurora Stream " ~
                    "will capture the entire desktop instead.";
                initialCaptureHwnd = "";
                initialCaptureLabel = "";
            }
            else if (windowIsMinimized(captureWindow))
            {
                captureFallbackMessage = "The saved capture window (" ~
                    captureLabel ~ ") is minimized, so it cannot be captured " ~
                    "right now. Aurora Stream will capture the entire desktop " ~
                    "instead; restore the window to select it again.";
                initialCaptureHwnd = "";
                initialCaptureLabel = "";
            }
        }
        if (captureFallbackMessage.length > 0)
        {
            _settingsMessage = _settingsMessage.length > 0 ?
                _settingsMessage ~ " " ~ captureFallbackMessage :
                captureFallbackMessage;
            markSettingsDirty();
            _activityLog.warning(captureFallbackMessage);
            _activityLog.action(
                "Action taken: capture source was reset to the entire desktop.");
        }

        auto header = add(new HBox(8));
        header.layoutHints().preferredHeight = 44;
        auto title = header.add(new Label(appDisplayName));
        title.setScale(2);
        title.layoutHints().flex = 1.0;
        _settingsMenu = header.add(new Button("Settings ▼"));
        _settingsMenu.layoutHints().preferredWidth = 105;
        _settingsMenu.layoutHints().preferredHeight = 34;
        _settingsMenu.onClick = delegate() {
            _activityLog.info("Settings menu opened.");
            openSettingsMenu();
        };
        string initialSummary = "Source 1080p60";
        if (saved.twitchEnabled) initialSummary ~= " • Twitch 1080p60";
        if (saved.youtubeEnabled) initialSummary ~= " • YouTube 1080p60";
        _output = header.add(new Label(initialSummary));
        _output.setScale(1);
        _output.setColor(Color.fromHex(0x9ba7b5));

        auto body = add(new HBox(9));
        body.layoutHints().flex = 1.0;
        body.layoutHints().minHeight = 540;

        auto settingsContent = new VBox(8, Insets(9));
        settingsContent.setBackground(Color.fromHex(0x1b2026));
        settingsContent.setBorder(Color.fromHex(0x3d4651), 6);
        settingsContent.layoutHints().preferredWidth = 540;

        auto captureTitle = settingsContent.add(new Label("CAPTURE SOURCE"));
        captureTitle.setScale(1);
        captureTitle.setColor(Color.fromHex(0xc8d0da));
        _captureSource = settingsContent.add(new CaptureSourceDropdown(
            initialCaptureHwnd, initialCaptureLabel));
        _captureSource.onChanged = delegate(string value) {
            updateQualitySummary();
            markSettingsDirty();
            const label = _captureSource.selectedLabel();
            const hwnd = _captureSource.selectedHwnd();
            if (hwnd.strip().length > 0)
                _activityLog.info("Capture source changed to " ~
                    (label.strip().length > 0 ? label : "window " ~ hwnd) ~ ".");
            else
                _activityLog.info(
                    "Capture source changed to the entire desktop.");
        };
        auto captureHint = settingsContent.add(new Label(
            "Pick a single game or app window to stream only that window — viewers never see the rest of your desktop. Entire desktop captures everything."));
        captureHint.setScale(1);
        captureHint.setColor(Color.fromHex(0x8793a0));
        captureHint.layoutHints().preferredHeight = 36;
        _windowContentCapture = settingsContent.add(new CheckBox(
            "Capture window content (keeps showing the window when it is covered or minimized; black for GPU/games)", saved.windowContentCapture));
        _windowContentCapture.layoutHints().preferredHeight = 22;
        _windowContentCapture.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info(checked ?
                "Window-content capture enabled (window's own content)." :
                "Window-content capture disabled (on-screen pixels).");
        };

        settingsContent.add(new Separator());
        auto sourceTitle = settingsContent.add(new Label("COMMON SOURCE CANVAS"));
        sourceTitle.setScale(1);
        sourceTitle.setColor(Color.fromHex(0xc8d0da));
        _sourceQuality = settingsContent.add(new SourceQualityDropdown(
            saved.sourceQuality));
        _sourceQuality.onChanged = delegate(BroadcastQuality quality) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info("Common source canvas set to " ~
                qualityShortLabel(quality) ~ ".");
        };
        auto sourceHint = settingsContent.add(new Label(
            "1080p60 is the default. This shared canvas is scaled separately for every enabled destination."));
        sourceHint.setScale(1);
        sourceHint.setColor(Color.fromHex(0x8793a0));
        sourceHint.layoutHints().preferredHeight = 36;

        auto twitchHeader = settingsContent.add(new HBox(6));
        twitchHeader.layoutHints().preferredHeight = 38;
        auto twitchTitle = twitchHeader.add(new Label("TWITCH OUTPUT"));
        twitchTitle.setScale(1);
        twitchTitle.setColor(Color.fromHex(0xc8d0da));
        twitchTitle.layoutHints().flex = 1.0;
        auto twitchQuickLink = twitchHeader.add(new BrowserQuickLinkButton(
            "Open Twitch settings",
            delegate() { return _browserChoice; }));
        twitchQuickLink.setFlat(true);
        twitchQuickLink.layoutHints().preferredHeight = 30;
        twitchQuickLink.onClick = delegate() {
            openBrowserShortcut("Twitch stream settings", twitchSettingsUrl);
        };
        twitchQuickLink.onChooseBrowser = delegate(BrowserChoice choice) {
            chooseBrowser(choice);
            openBrowserIn("Twitch stream settings", twitchSettingsUrl, choice);
        };

        const twitchHasSavedKey = saved.twitchKey.strip().length > 0;
        _twitchEnabled = settingsContent.add(new CheckBox("Stream to Twitch",
            saved.twitchEnabled && twitchHasSavedKey));
        _twitchEnabled.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info(checked ?
                "Stream to Twitch enabled." : "Stream to Twitch disabled.");
        };
        auto twitchProfile = settingsContent.add(new Label(
            "1920×1080 • 60 FPS • 6000 kbps CBR • independent H.264 encoder"));
        twitchProfile.setScale(1);
        twitchProfile.setColor(Color.fromHex(0x8793a0));
        twitchProfile.layoutHints().preferredHeight = 24;
        _twitchServerGroup = addFieldGroup(settingsContent, "Twitch server",
            saved.twitchServer, "Twitch RTMP or RTMPS server URL",
            _twitchServer);
        _twitchKey = addStreamKeyField(settingsContent, "Twitch stream key",
            saved.twitchKey, "Paste the Twitch stream key", _twitchPaste);
        _twitchKey.onChanged = delegate() {
            streamKeyChanged("Twitch", _twitchKey, _twitchEnabled);
        };
        _twitchPaste.onClick = delegate() {
            pasteStreamKey("Twitch", _twitchKey);
        };
        _twitchEnabled.setEnabled(twitchHasSavedKey);

        settingsContent.add(new Separator());
        auto youtubeHeader = settingsContent.add(new HBox(6));
        youtubeHeader.layoutHints().preferredHeight = 38;
        auto youtubeTitle = youtubeHeader.add(new Label("YOUTUBE OUTPUT"));
        youtubeTitle.setScale(1);
        youtubeTitle.setColor(Color.fromHex(0xc8d0da));
        youtubeTitle.layoutHints().flex = 1.0;
        auto youtubeQuickLink = youtubeHeader.add(new BrowserQuickLinkButton(
            "Open YouTube Live",
            delegate() { return _browserChoice; }));
        youtubeQuickLink.setFlat(true);
        youtubeQuickLink.layoutHints().preferredHeight = 30;
        youtubeQuickLink.onClick = delegate() {
            openBrowserShortcut("YouTube Live Control Room", youtubeLiveControlUrl);
        };
        youtubeQuickLink.onChooseBrowser = delegate(BrowserChoice choice) {
            chooseBrowser(choice);
            openBrowserIn("YouTube Live Control Room", youtubeLiveControlUrl, choice);
        };

        const youtubeHasSavedKey = saved.youtubeKey.strip().length > 0;
        // Keep the selector row at its natural content width and center it so
        // the quality/bitrate dropdowns do not stretch across the whole panel
        // (their oversized minimum widths also forced the settings column wider
        // than its 540 px target).
        auto youtubeRowWrap = settingsContent.add(new HBox(0));
        youtubeRowWrap.layoutHints().preferredHeight = 34;
        youtubeRowWrap.layoutHints().minHeight = 34;
        youtubeRowWrap.add(new Spacer(1.0));
        auto youtubeDestinationRow = youtubeRowWrap.add(new HBox(6));
        youtubeDestinationRow.layoutHints().preferredWidth = 512;
        youtubeDestinationRow.layoutHints().preferredHeight = 34;
        _youtubeEnabled = youtubeDestinationRow.add(new CheckBox("Stream to YouTube",
            saved.youtubeEnabled && youtubeHasSavedKey));
        _youtubeEnabled.layoutHints().preferredWidth = 170;
        _youtubeEnabled.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info(checked ?
                "Stream to YouTube enabled." : "Stream to YouTube disabled.");
        };
        _youtubeQuality = youtubeDestinationRow.add(new SourceQualityDropdown(
            saved.youtubeQuality));
        _youtubeQuality.onChanged = delegate(BroadcastQuality quality) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info("YouTube output quality set to " ~
                qualityShortLabel(quality) ~ ".");
        };
        _youtubeBitrate = youtubeDestinationRow.add(new BitrateDropdown(
            saved.youtubeBitrateKbps));
        _youtubeBitrate.onChanged = delegate(int kbps) {
            updateQualitySummary();
            markSettingsDirty();
            _activityLog.info(format(
                "YouTube output bitrate set to %d kbps.", kbps));
        };
        youtubeRowWrap.add(new Spacer(1.0));
        _youtubeProfile = settingsContent.add(new Label(
            "Default: 1920×1080 • 60 FPS • 12000 kbps • independent H.264 encoder"));
        _youtubeProfile.setScale(1);
        _youtubeProfile.setColor(Color.fromHex(0x8793a0));
        _youtubeProfile.layoutHints().preferredHeight = 36;
        _youtubeServerGroup = addFieldGroup(settingsContent, "YouTube server",
            saved.youtubeServer, "YouTube RTMP or RTMPS server URL",
            _youtubeServer);
        _youtubeKey = addStreamKeyField(settingsContent, "YouTube stream key",
            saved.youtubeKey, "Paste the YouTube stream key", _youtubePaste);
        _youtubeKey.onChanged = delegate() {
            streamKeyChanged("YouTube", _youtubeKey, _youtubeEnabled);
        };
        _youtubePaste.onClick = delegate() {
            pasteStreamKey("YouTube", _youtubeKey);
        };
        _youtubeEnabled.setEnabled(youtubeHasSavedKey);

        settingsContent.add(new Separator());
        auto audioTitle = settingsContent.add(new Label("AUDIO"));
        audioTitle.setScale(1);
        audioTitle.setColor(Color.fromHex(0xc8d0da));
        _desktopAudio = addAudioDeviceDropdown(settingsContent,
            "Desktop audio (Windows WASAPI loopback)",
            saved.desktopAudioDevice,
            "No active Windows playback devices found");
        _desktopAudio.onChanged = delegate(string value) {
            _selectDefaultDesktopAudio = false;
            markSettingsDirty();
            _activityLog.info("Desktop audio device set to " ~
                deviceDisplayName(value) ~ ".");
        };
        _microphone = addAudioDeviceDropdown(settingsContent,
            "Microphone (FFmpeg DirectShow)",
            saved.microphoneDevice,
            "No DirectShow microphone devices found");
        _microphone.onChanged = delegate(string value) {
            markSettingsDirty();
            _activityLog.info("Microphone set to " ~
                deviceDisplayName(value) ~ ".");
        };

        auto deviceRow = settingsContent.add(new HBox(6));
        _refreshAudioDevices = deviceRow.add(new Button("Refresh audio devices"));
        _refreshAudioDevices.onClick = delegate() {
            _activityLog.action("Audio devices refresh requested by the user.");
            refreshAudioDevices(true);
        };
        auto audioHint = deviceRow.add(new Label(
            "Desktop lists speakers/headphones. Microphone lists recording inputs. Either can remain Disabled."));
        audioHint.setScale(1);
        audioHint.setColor(Color.fromHex(0x8793a0));
        audioHint.layoutHints().flex = 1.0;
        audioHint.layoutHints().preferredHeight = 36;

        // Restore cached device names so a selection made in a previous session
        // shows its real name even before the first scan completes.
        _desktopAudio.setNameCache(_deviceNameCache);
        _microphone.setNameCache(_deviceNameCache);

        _settingsScroll = new ScrollView(settingsContent);
        _settingsScroll.layoutHints().preferredWidth = 560;
        _settingsScroll.layoutHints().minWidth = 450;
        _settingsScroll.layoutHints().flex = 0.0;
        body.add(_settingsScroll);

        auto monitor = body.add(new VBox(8));
        monitor.layoutHints().flex = 1.0;
        monitor.layoutHints().minWidth = 420;

        _canvasPreviewPanel = monitor.add(new VBox(6, Insets(12)));
        _canvasPreviewPanel.setBackground(Color.fromHex(0x090b0e));
        _canvasPreviewPanel.setBorder(Color.fromHex(0x343d47), 6);
        _canvasPreviewPanel.layoutHints().flex = 1.0;
        _canvasPreviewPanel.layoutHints().minHeight = 300;
        _canvasPreview = _canvasPreviewPanel.add(new LiveSourceCanvasPreview());
        _canvasPreview.layoutHints().flex = 1.0;
        // Retain the preview as its own compositor layer so updating the live
        // frame repaints only the preview area instead of the whole window
        // (important for the software renderer, where full-scene redraws are
        // the dominant CPU cost).
        _canvasPreview.setComposited(true);
        _canvasPreview.setCompositedOpaque(true);
        auto previewCaption = _canvasPreviewPanel.add(new Label(
            "LIVE SOURCE CANVAS"));
        previewCaption.setAlignment(HorizontalAlign.center);
        previewCaption.setScale(1);
        previewCaption.setColor(Color.fromHex(0x8e99a6));
        previewCaption.layoutHints().preferredHeight = 24;

        _statusPanel = monitor.add(new VBox(6, Insets(10)));
        _statusPanel.setBackground(Color.fromHex(0x1b2026));
        _statusPanel.setBorder(Color.fromHex(0x3d4651), 6);
        _statusPanel.layoutHints().preferredHeight = 180;
        _videoPath = _statusPanel.add(new Label(_encoder.ffmpegAvailable
            ? "Capture: " ~ captureSourceLabel(saved, _capture) ~ " • " ~
                videoPipelineLabel(saved, _encoder, _capture) ~
                " • Encoder: " ~ _encoder.label
            : "Encoder: FFmpeg not found"));
        _videoPath.setScale(1);
        _videoPath.setColor(_encoder.ffmpegAvailable ?
            Color.fromHex(0x9fd4af) : Color.fromHex(0xe19a9a));
        _status = _statusPanel.add(new Label("Ready"));
        _status.setScale(2);
        _metrics = _statusPanel.add(new Label(
            "FPS —  •  Speed —  •  Duplicated —  •  Dropped —  •  Time —"));
        _metrics.setScale(1);
        _metrics.setColor(Color.fromHex(0x9ba7b5));
        _metrics.layoutHints().preferredHeight = 28;
        _metrics.setEllipsis(false);
        _diagnostics = _statusPanel.add(new Label(settingsLoadMessage.length > 0 ?
            settingsLoadMessage :
            "Settings, including stream keys, are saved in " ~ settingsFilePath()));
        _diagnostics.setScale(1);
        _diagnostics.setColor(Color.fromHex(0x8793a0));
        _diagnostics.layoutHints().preferredHeight = 54;
        _diagnostics.setEllipsis(false);

        auto controls = add(new HBox(8));
        controls.layoutHints().preferredHeight = 48;
        _presetSummary = controls.add(new Label(
            "Two independent outputs • H.264 High • AAC 48 kHz • 2-second keyframes"));
        _presetSummary.setScale(1);
        _presetSummary.setColor(Color.fromHex(0x8f9ba8));
        _presetSummary.layoutHints().flex = 1.0;
        _startStop = controls.add(new Button("Start streaming"));
        _startStop.setAccent(true);
        _startStop.layoutHints().preferredWidth = 180;
        _startStop.onClick = delegate() { toggleStreaming(); };

        setStreamingServersVisible(false);
        setLiveSourcePreviewVisible(_liveSourcePreviewEnabled);
        updateQualitySummary();
        refreshAudioDevices(false);
        _audioNotifications.start();

        _previewCaptureMutex = new Mutex();
        _previewCapturer = new DesktopPreviewCapturer(previewCaptureWidth,
            previewCaptureHeight);
        _previewCaptureRunning = true;
        _previewCaptureDesired = _liveSourcePreviewEnabled;
        _previewCaptureThread = new Thread({ previewCaptureLoop(); });
        _previewCaptureThread.isDaemon = true;
        _previewCaptureThread.start();
    }

    private void openBrowserShortcut(string pageName, string url)
    {
        openBrowserIn(pageName, url, _browserChoice);
    }

    /// Opens the always-on activity log file with the OS default handler so the
    /// operator can see the exact problems and actions the app recorded.
    private void openActivityLog()
    {
        const path = _activityLog !is null ?
            _activityLog.path() : "aurora-stream-activity.log";
        string error;
        if (openLocalFile(path, error))
        {
            _localStatus = "Opened the activity log (" ~ path ~ ").";
            _localStatusError = false;
            _status.setText(_localStatus);
            _status.setColor(Color.fromHex(0x9fd4af));
            _activityLog.info("Activity log opened by the user.");
            return;
        }
        _localStatus = "Could not open the activity log: " ~ error;
        _localStatusError = true;
        _status.setText(_localStatus);
        _status.setColor(Color.fromHex(0xe19a9a));
        _activityLog.error("Could not open the activity log: " ~ error);
    }

    private void openBrowserIn(string pageName, string url, BrowserChoice choice)
    {
        string error;
        if (openUrlInBrowser(url, choice, error))
        {
            _localStatus = pageName ~ " opened in " ~
                browserChoiceLabel(choice) ~ ".";
            _localStatusError = false;
            _status.setText(_localStatus);
            _status.setColor(Color.fromHex(0x9fd4af));
            _activityLog.info(pageName ~ " opened in " ~
                browserChoiceLabel(choice) ~ ".");
            return;
        }

        _localStatus = "Could not open " ~ pageName ~ ": " ~ error;
        _localStatusError = true;
        _status.setText(_localStatus);
        _status.setColor(Color.fromHex(0xe19a9a));
        _activityLog.error("Could not open " ~ pageName ~ ": " ~ error);
    }

    private void chooseBrowser(BrowserChoice choice)
    {
        if (choice == _browserChoice) return;
        _browserChoice = choice;
        markSettingsDirty();
        _activityLog.info("Browser choice set to " ~
            browserChoiceLabel(choice) ~ ".");
    }

    private VBox addFieldGroup(VBox panel, string title, string value,
        string placeholder, out ClipboardTextField field)
    {
        auto group = panel.add(new VBox(4));
        // Aurora-D's Box layout positions nested containers from their layout
        // hints rather than their measured descendants. Without an explicit
        // height this group participates in spacing but receives a zero-height
        // rectangle, so unhiding it cannot reveal either child.
        enum fieldGroupHeight = 19 + 4 + 40;
        group.layoutHints().preferredHeight = fieldGroupHeight;
        group.layoutHints().minHeight = fieldGroupHeight;
        auto label = group.add(new Label(title));
        label.setScale(1);
        label.setColor(Color.fromHex(0x9ca8b5));
        label.layoutHints().preferredHeight = 19;
        field = group.add(new ClipboardTextField(value));
        field.setPlaceholder(placeholder);
        field.onChanged = delegate() {
            markSettingsDirty();
            logFieldPopulatedChange(title, field.textUtf8());
        };
        return group;
    }

    private void openSettingsMenu()
    {
        ContextMenuItem[] items = [
            ContextMenuItem.check("Live source preview",
                _liveSourcePreviewEnabled, delegate() {
                    setLiveSourcePreviewVisible(!_liveSourcePreviewEnabled);
                    _activityLog.info("Live source preview " ~
                        (_liveSourcePreviewEnabled ? "enabled." : "disabled."));
                }),
            ContextMenuItem.check("Unhide streaming servers",
                _streamingServersVisible, delegate() {
                    setStreamingServersVisible(!_streamingServersVisible);
                    _activityLog.info("Streaming server fields " ~
                        (_streamingServersVisible ? "shown." : "hidden."));
                }),
            ContextMenuItem.check("Minimize to tray when streaming starts",
                _minimizeToTrayOnStart, delegate() {
                    _minimizeToTrayOnStart = !_minimizeToTrayOnStart;
                    markSettingsDirty();
                    _activityLog.info("Minimize-to-tray on stream start " ~
                        (_minimizeToTrayOnStart ? "enabled." : "disabled."));
                }),
            ContextMenuItem.check("Close button hides to tray instead of exiting",
                _closeToTray, delegate() {
                    _closeToTray = !_closeToTray;
                    markSettingsDirty();
                    _activityLog.info("Close-to-tray " ~
                        (_closeToTray ? "enabled." : "disabled."));
                }),
            ContextMenuItem.separatorItem(),
            ContextMenuItem.command("Run A/V pacing diagnostic", delegate() {
                const snapshot = _worker.snapshot();
                if (snapshot.requestedRunning || snapshot.processRunning)
                {
                    _localStatus = "Stop streaming before running the A/V pacing diagnostic.";
                    _localStatusError = true;
                    return;
                }
                saveSettingsNow();
                string error;
                if (!openPacingDiagnostic(error))
                {
                    _localStatus = "Could not open A/V pacing diagnostic: " ~ error;
                    _localStatusError = true;
                    _activityLog.error(
                        "Could not open A/V pacing diagnostic: " ~ error);
                    return;
                }
                _localStatus = "Opened the A/V pacing diagnostic in a separate terminal.";
                _localStatusError = false;
                _activityLog.info(
                    "A/V pacing diagnostic opened in a separate terminal.");
            }),
            ContextMenuItem.command("View activity log", delegate() {
                openActivityLog();
            })
        ];

        string updateTag;
        _updateMutex.lock();
        updateTag = _updateAvailable;
        _updateMutex.unlock();
        if (updateTag.length > 0)
            items ~= ContextMenuItem.command(
                "Update available: " ~ updateTag ~ " — install & restart",
                delegate() { startUpdate(); });

        showContextMenuBelow(_settingsMenu, items);
    }

    /// Background version check (release builds only; silently no-ops in dev).
    private void startUpdateCheck()
    {
        auto worker = new Thread(delegate() {
            const tag = newerReleaseTag();
            _updateMutex.lock();
            _updateAvailable = tag;
            _updateChecked = true;
            _updateMutex.unlock();
            if (tag.length > 0)
                _activityLog.info("Update available: " ~ tag ~
                    " (install it from the Settings menu).");
        });
        worker.isDaemon = true;
        worker.start();
    }

    /// Downloads the latest release, spawns the updater, and exits so the new
    /// version can replace this exe and relaunch.
    private void startUpdate()
    {
        _localStatus = "Downloading update…";
        _localStatusError = false;
        _activityLog.action("Update install requested by the user.");
        const staged = stageLatestUpdate();
        if (staged.length == 0)
        {
            _localStatus = "Could not download the update. Try again later.";
            _localStatusError = true;
            _activityLog.error(
                "Could not download the update; try again later.");
            return;
        }
        if (launchUpdater(staged))
        {
            _localStatus = "Restarting to install the update…";
            _localStatusError = false;
            _activityLog.action(
                "Updater launched; restarting to install the update.");
            // The updater must relaunch even when close-to-tray is enabled.
            _forceExit = true;
            if (_tray !is null) _tray.remove();
            _window.close();
        }
        else
        {
            _localStatus = "Could not start the updater.";
            _localStatusError = true;
            _activityLog.error("Could not start the update installer.");
        }
    }

    private void setStreamingServersVisible(bool visible)
    {
        _streamingServersVisible = visible;

        // Toggle both painting and layout participation. Explicitly relayout the
        // root and scroll viewport because Aurora-D 0.4.5 does not expose a
        // separate requestLayout call for a visibility change inside ScrollView.
        if (_twitchServerGroup !is null)
        {
            _twitchServerGroup.layoutHints().excludeFromLayout = !visible;
            _twitchServerGroup.setVisible(visible);
        }
        if (_youtubeServerGroup !is null)
        {
            _youtubeServerGroup.layoutHints().excludeFromLayout = !visible;
            _youtubeServerGroup.setVisible(visible);
        }

        layoutTree();
        invalidate();

        // Make the change immediately obvious even when the user had scrolled
        // lower in the settings panel before opening the toolbar menu.
        if (visible && _settingsScroll !is null && _twitchServerGroup !is null)
            _settingsScroll.ensureVisible(_twitchServerGroup.bounds());
    }

    /// Turns the live recording preview on/off. Disabling hides the panel,
    /// lets the status panel fill the monitor column, and idles the capture
    /// thread so the app stops grabbing the desktop and repainting the preview
    /// (saves CPU/energy). Persisted in the settings file.
    private void setLiveSourcePreviewVisible(bool visible)
    {
        _liveSourcePreviewEnabled = visible;
        if (_canvasPreviewPanel !is null)
        {
            _canvasPreviewPanel.layoutHints().excludeFromLayout = !visible;
            _canvasPreviewPanel.setVisible(visible);
            if (_statusPanel !is null)
                _statusPanel.layoutHints().flex = visible ? 0.0 : 1.0;
        }
        if (_previewCaptureMutex !is null)
        {
            _previewCaptureMutex.lock();
            if (!visible) _previewCaptureDesired = false;
            _previewCaptureMutex.unlock();
        }
        markSettingsDirty();
        layoutTree();
        invalidate();
    }


    private ClipboardTextField addStreamKeyField(VBox panel, string title,
        string value, string placeholder, out Button pasteButton)
    {
        auto label = panel.add(new Label(title));
        label.setScale(1);
        label.setColor(Color.fromHex(0x9ca8b5));
        label.layoutHints().preferredHeight = 19;

        auto row = panel.add(new HBox(5));
        row.layoutHints().preferredHeight = 40;
        auto field = row.add(new ClipboardTextField(value));
        field.layoutHints().flex = 1.0;
        field.setPlaceholder(placeholder);
        field.setPasswordMode(true);

        pasteButton = row.add(new Button("paste"));
        pasteButton.layoutHints().preferredWidth = 58;
        pasteButton.layoutHints().preferredHeight = 36;
        return field;
    }

    private void streamKeyChanged(string service, ClipboardTextField field,
        CheckBox destination)
    {
        const text = field.textUtf8();
        const hasKey = text.strip().length > 0;
        destination.setChecked(hasKey, false);

        const snapshot = _worker.snapshot();
        const active = snapshot.requestedRunning || snapshot.processRunning;
        destination.setEnabled(hasKey && !active);
        updateQualitySummary();
        markSettingsDirty();
        // Never log the key itself — only the populated/cleared transition.
        logFieldPopulatedChange(service ~ " stream key", text);
    }

    private void pasteStreamKey(string service, ClipboardTextField field)
    {
        field.requestFocus();
        if (field.pasteFromSystemClipboard(true) &&
            field.textUtf8().strip().length > 0)
        {
            _localStatus = service ~ " stream key pasted.";
            _localStatusError = false;
            _status.setText(_localStatus);
            _status.setColor(Color.fromHex(0x9fd4af));
            return;
        }

        if (field.textUtf8().strip().length == 0) field.clear();
        _localStatus = "The clipboard does not contain a " ~ service ~
            " stream key.";
        _localStatusError = true;
        _status.setText(_localStatus);
        _status.setColor(Color.fromHex(0xe19a9a));
        _activityLog.info("The clipboard contained no " ~ service ~
            " stream key; nothing was pasted.");
    }

    private AudioDeviceDropdown addAudioDeviceDropdown(VBox panel,
        string title, string selectedDevice, string emptyMessage)
    {
        auto label = panel.add(new Label(title));
        label.setScale(1);
        label.setColor(Color.fromHex(0x9ca8b5));
        label.layoutHints().preferredHeight = 19;
        auto dropdown = panel.add(new AudioDeviceDropdown(selectedDevice,
            emptyMessage));
        dropdown.onChanged = delegate(string value) { markSettingsDirty(); };
        return dropdown;
    }

    private void refreshAudioDevices(bool announce, bool background = false)
    {
        if (!_audioScanner.start()) return;
        if (!background && _refreshAudioDevices !is null)
        {
            _refreshAudioDevices.setText("Refreshing audio devices…");
            _refreshAudioDevices.setEnabled(false);
        }
        if (announce)
        {
            _localStatus = "Refreshing Windows playback and microphone devices…";
            _localStatusError = false;
            _status.setText(_localStatus);
            _status.useThemeColor();
        }
    }

    private void markSettingsDirty()
    {
        _settingsLoadFailed = false;
        _settingsDirty = true;
        _settingsSaveDelay = 0.45;
    }

    /// Resolves a device ID to its friendly cached name, or "Disabled" when
    /// nothing is selected. Only the display name is logged — never a raw ID.
    private string deviceDisplayName(string id)
    {
        if (id.strip().length == 0) return "Disabled";
        const name = id in _deviceNameCache;
        if (name !is null && name.length > 0) return *name;
        return id;
    }

    /// Logs when a text field transitions between empty and populated. The
    /// field CONTENT is never logged (stream keys and server URLs are
    /// sensitive); only the field's name and the transition are recorded.
    private void logFieldPopulatedChange(string name, string current)
    {
        const populated = current.strip().length > 0;
        const previous = name in _fieldWasPopulated;
        const wasPopulated = previous !is null && *previous;
        if (populated == wasPopulated) return;
        _fieldWasPopulated[name] = populated;
        _activityLog.info(name ~ (populated ? " entered." : " cleared."));
    }

    private bool saveSettingsNow()
    {
        if (_settingsLoadFailed && !_settingsDirty) return false;

        string error;
        if (saveSettings(collectSettings(), error))
        {
            _settingsDirty = false;
            _settingsSaveDelay = 0;
            _settingsMessage = "Settings saved to " ~ settingsFilePath() ~
                ". This file contains the stream keys.";
            _settingsMessageError = false;
            _activityLog.info("Settings saved to " ~ settingsFilePath() ~ ".");
            return true;
        }

        _settingsMessage = "Could not save settings: " ~ error;
        _settingsMessageError = true;
        _settingsSaveDelay = 2.0;
        _activityLog.error("Could not save settings: " ~ error);
        return false;
    }

    private BroadcastQuality selectedSourceQuality() const
    {
        return _sourceQuality.selectedQuality();
    }

    private BroadcastQuality selectedYoutubeQuality() const
    {
        return _youtubeQuality.selectedQuality();
    }

    private int selectedYoutubeBitrateKbps() const
    {
        return _youtubeBitrate.selectedKbps();
    }

    private void updateQualitySummary()
    {
        if (_output is null || _presetSummary is null ||
            _youtubeProfile is null) return;

        const sourceQuality = selectedSourceQuality();
        const youtubeQuality = selectedYoutubeQuality();
        const youtubeWidth = qualityWidth(youtubeQuality);
        const youtubeHeight = qualityHeight(youtubeQuality);
        BroadcastSettings bitrateSettings;
        bitrateSettings.youtubeQuality = youtubeQuality;
        bitrateSettings.youtubeBitrateKbps = selectedYoutubeBitrateKbps();
        const youtubeBitrate = effectiveYoutubeBitrateKbps(bitrateSettings);

        if (_videoPath !is null && _encoder.ffmpegAvailable)
        {
            BroadcastSettings pathSettings;
            pathSettings.sourceQuality = sourceQuality;
            pathSettings.twitchEnabled = _twitchEnabled.checked();
            pathSettings.youtubeEnabled = _youtubeEnabled.checked();
            pathSettings.twitchQuality = BroadcastQuality.fullHD;
            pathSettings.youtubeQuality = youtubeQuality;
            pathSettings.youtubeBitrateKbps = selectedYoutubeBitrateKbps();
            pathSettings.windowCaptureHwnd = _captureSource.selectedHwnd();
            pathSettings.windowCaptureLabel = _captureSource.selectedLabel();
            _videoPath.setText(format(
                "%s • %s • Encoder: %s",
                "Capture: " ~ captureSourceLabel(pathSettings, _capture),
                videoPipelineLabel(pathSettings, _encoder, _capture),
                _encoder.label));
        }

        string headerSummary = format("Source %s60", qualityShortLabel(sourceQuality));
        if (_twitchEnabled.checked())
            headerSummary ~= " • Twitch 1080p60";
        if (_youtubeEnabled.checked())
            headerSummary ~= format(" • YouTube %s60", qualityShortLabel(youtubeQuality));
        _output.setText(headerSummary);
        const youtubeProfileLabel = youtubeQuality == BroadcastQuality.fourK ?
            "Highest quality" :
            (youtubeQuality == BroadcastQuality.twoK ? "1440p (higher)" : "Default");
        _youtubeProfile.setText(format(
            "%s: %d×%d • 60 FPS • %d kbps • independent H.264 encoder",
            youtubeProfileLabel, youtubeWidth, youtubeHeight, youtubeBitrate));

        const twitchEnabled = _twitchEnabled.checked();
        const youtubeEnabled = _youtubeEnabled.checked();
        const twitchMediaMbps = cast(double)(twitchVideoBitrateKbps +
            defaultAudioBitrateKbps) / 1000.0;
        const youtubeMediaMbps = cast(double)(youtubeBitrate +
            defaultAudioBitrateKbps) / 1000.0;
        if (twitchEnabled && youtubeEnabled)
        {
            _presetSummary.setText(format(
                "Configured upload: Twitch 1080p60 %.2f Mbps + YouTube %s60 %.2f Mbps = %.2f Mbps total",
                twitchMediaMbps, qualityShortLabel(youtubeQuality),
                youtubeMediaMbps, twitchMediaMbps + youtubeMediaMbps));
        }
        else if (twitchEnabled)
        {
            _presetSummary.setText(format(
                "Configured Twitch upload: 1080p60 at %.2f Mbps including audio",
                twitchMediaMbps));
        }
        else if (youtubeEnabled)
        {
            _presetSummary.setText(format(
                "Configured YouTube upload: %s60 at %.2f Mbps including audio",
                qualityShortLabel(youtubeQuality), youtubeMediaMbps));
        }
        else
        {
            _presetSummary.setText("Enable Twitch, YouTube, or both.");
        }
    }

    private BroadcastSettings collectSettings()
    {
        BroadcastSettings settings;
        settings.sourceQuality = selectedSourceQuality();
        settings.twitchEnabled = _twitchEnabled.checked();
        settings.twitchServer = _twitchServer.textUtf8().strip();
        settings.twitchKey = _twitchKey.textUtf8().strip();
        settings.twitchQuality = BroadcastQuality.fullHD;
        settings.youtubeEnabled = _youtubeEnabled.checked();
        settings.youtubeServer = _youtubeServer.textUtf8().strip();
        settings.youtubeKey = _youtubeKey.textUtf8().strip();
        settings.youtubeQuality = selectedYoutubeQuality();
        settings.youtubeBitrateKbps = selectedYoutubeBitrateKbps();
        settings.desktopAudioDevice = _desktopAudio.selectedDevice().strip();
        settings.desktopAudioEnabled = _selectDefaultDesktopAudio ||
            settings.desktopAudioDevice.length > 0;
        settings.microphoneDevice = _microphone.selectedDevice().strip();
        settings.windowCaptureHwnd = _captureSource.selectedHwnd();
        settings.windowCaptureLabel = _captureSource.selectedLabel();
        settings.windowContentCapture = _windowContentCapture !is null &&
            _windowContentCapture.checked();
        settings.liveSourcePreviewEnabled = _liveSourcePreviewEnabled;
        settings.browserChoice = _browserChoice;
        settings.minimizeToTrayOnStart = _minimizeToTrayOnStart;
        settings.closeToTray = _closeToTray;
        settings.deviceDisplayNameCache.clear();
        foreach (deviceId, name; _deviceNameCache)
            settings.deviceDisplayNameCache[deviceId] = name;
        return settings;
    }

    /// Starts or stops the broadcast. Returns an error message (or an empty
    /// string on success / a requested stop). Callers that invoke this from a
    /// place without a visible window (the tray icon) surface the error as a
    /// balloon instead of an invisible status line.
    private string toggleStreaming()
    {
        const snapshot = _worker.snapshot();
        if (snapshot.requestedRunning || snapshot.processRunning)
        {
            _worker.stop();
            _activityLog.action("Stop streaming requested by the user.");
            return "";
        }

        if (_selectDefaultDesktopAudio &&
            _desktopAudio.selectedDevice().strip().length == 0)
        {
            _localStatus =
                "Wait for Windows desktop-audio detection to finish, then start streaming.";
            _localStatusError = true;
            return _localStatus;
        }

        saveSettingsNow();
        _activityLog.action("Start streaming requested by the user.");

        string error;
        if (!_worker.start(collectSettings(), _encoder, _capture, error))
        {
            _localStatus = error;
            _localStatusError = true;
            _status.setText(error);
            _status.setColor(Color.fromHex(0xe19a9a));
            return error;
        }
        _localStatus = "";
        _localStatusError = false;
        _status.useThemeColor();
        _startStop.setText("Stop streaming");
        _startStop.setDanger(true);
        if (_minimizeToTrayOnStart && !_trayHidden) hideToTray();
        return "";
    }

    private bool streamingActive()
    {
        const snapshot = _worker.snapshot();
        return snapshot.requestedRunning || snapshot.processRunning;
    }

    /// Creates the tray icon on first use and wires it to the broadcaster.
    /// Failing to create it (no shell, restricted session) leaves `_tray`
    /// null so callers fall back to a plain minimize.
    private void ensureTrayIcon()
    {
        if (_tray !is null) return;
        auto tray = new TrayIcon();
        tray.onToggleStream = &toggleStreamingFromTray;
        tray.onShowWindow = &showWindowFromTray;
        tray.onExit = &exitFromTray;
        tray.isStreaming = &streamingActive;
        tray.statusText = delegate() {
            const snapshot = _worker.snapshot();
            return snapshot.status.length > 0 ? snapshot.status : "Idle";
        };
        if (!tray.show(applicationIconPath(), "Aurora Stream — Idle"))
        {
            tray.shutdown();
            return;
        }
        _tray = tray;
    }

    /// Hides the main window and keeps the app alive in the tray. Called from
    /// Start streaming (when minimize-to-tray is enabled) and from the close
    /// button (when close-to-tray is enabled).
    private void hideToTray()
    {
        if (_trayHidden) return;
        ensureTrayIcon();
        if (_tray is null)
        {
            // The tray could not be created; fall back to a plain minimize.
            _window.minimize();
            return;
        }
        _trayHidden = true;
        _window.setVisible(false);
        _tray.setStreaming(streamingActive());
        _tray.showBalloon("Aurora Stream",
            "Aurora Stream is running in the tray. Double-click the tray icon to restore the window.",
            false);
        if (_activityLog !is null)
            _activityLog.note("Window hidden to the system tray.");
    }

    /// Restores the main window (double-click on the tray icon, or the Show
    /// entry in the tray menu).
    private void showWindowFromTray()
    {
        _trayHidden = false;
        if (_window is null) return;
        if (_window.isMinimized()) _window.restore();
        _window.setVisible(true);
        version (Windows)
        {
            import core.sys.windows.windows : HWND, SetForegroundWindow;
            const info = _window.nativeWindow().nativeSurfaceInfo();
            auto hwnd = cast(HWND) info.handleB;
            if (hwnd !is null) SetForegroundWindow(hwnd);
        }
        if (_activityLog !is null)
            _activityLog.note("Window restored from the system tray.");
    }

    /// Single-click on the tray icon: toggle Start/Stop streaming, reporting
    /// the outcome as a tray balloon because the window is not visible.
    private void toggleStreamingFromTray()
    {
        const wasActive = streamingActive();
        const error = toggleStreaming();
        const nowActive = streamingActive();
        if (_tray is null) return;
        if (error.length > 0 && !wasActive)
        {
            _tray.showBalloon("Aurora Stream",
                "Could not start streaming: " ~ error, true);
        }
        else if (!wasActive && nowActive)
        {
            _tray.setStreaming(true);
            _tray.showBalloon("Aurora Stream",
                "Streaming started. Double-click the tray icon to restore the window.",
                false);
        }
        else if (wasActive && !nowActive)
        {
            _tray.setStreaming(false);
            _tray.showBalloon("Aurora Stream", "Streaming stopped.", false);
        }
    }

    /// Tray menu Exit: quit the application entirely, even while streaming or
    /// with close-to-tray enabled.
    private void exitFromTray()
    {
        _forceExit = true;
        if (_tray !is null) _tray.remove();
        if (_window !is null) _window.close();
    }

    /// The minimize button / system-menu minimize. Once the tray icon exists,
    /// minimize keeps the app in the tray (no taskbar button) instead of
    /// minimizing to the taskbar. Returns true when the request was consumed
    /// as a tray-hide so the caller skips a plain minimize.
    bool requestMinimize()
    {
        if (_tray !is null)
        {
            hideToTray();
            return true;
        }
        return false;
    }

    /// Called by the entry point when the window close (X, Alt+F4, system
    /// menu) is requested. Returns true when the app should actually shut
    /// down; false keeps it running (hidden into the tray).
    bool closeRequested()
    {
        if (_forceExit) return true;
        // Once the tray icon exists, X never exits — it stays in the tray.
        if (_tray !is null)
        {
            hideToTray();
            return false;
        }
        if (_closeToTray)
        {
            hideToTray();
            return false;
        }
        return true;
    }

    /// Drives the LIVE SOURCE CANVAS panel: shows the latest frame from the
    /// background preview-capture thread so the panel reflects exactly what is
    /// being recorded.
    private void updateLiveSourcePreview(double deltaSeconds)
    {
        if (_canvasPreview is null) return;
        if (!_liveSourcePreviewEnabled)
        {
            _previewCaptureMutex.lock();
            _previewCaptureDesired = false;
            _previewCaptureMutex.unlock();
            return;
        }
        const minimized = _window !is null &&
            (_trayHidden || _window.isMinimized());
        _previewCaptureMutex.lock();
        _previewCaptureDesired = !minimized;
        _previewCaptureWindowHwnd = _captureSource.selectedHwnd();
        RgbaImage latest = _previewCaptureFrame;
        _previewCaptureMutex.unlock();
        // Size the capture to the preview panel so the live frame is shown at
        // (near) native resolution instead of upscaled from a small buffer.
        const previewBounds = _canvasPreview.bounds();
        if (previewBounds.width > 0 && previewBounds.height > 0)
        {
            int targetWidth = previewBounds.width;
            int targetHeight = previewBounds.width * 9 / 16;
            if (targetHeight > previewBounds.height)
            {
                targetHeight = previewBounds.height;
                targetWidth = previewBounds.height * 16 / 9;
            }
            targetWidth = clampInt(targetWidth, 320, 1280);
            targetHeight = clampInt(targetHeight, 180, 720);
            _previewCaptureMutex.lock();
            _previewCaptureTargetWidth = targetWidth;
            _previewCaptureTargetHeight = targetHeight;
            _previewCaptureMutex.unlock();
        }
        // The capture thread reuses a single RgbaImage (same texture on the
        // GPU), so a new frame is detected by its revision, not identity.
        if (latest !is null &&
            latest.revision() != _previewCaptureLastShownRevision)
        {
            _previewCaptureLastShownRevision = latest.revision();
            _canvasPreview.setLiveFrame(latest);
        }
    }

    /// Background loop that grabs the primary monitor at ~30 FPS for the live
    /// source preview, so the UI thread never blocks on GDI capture. Idles when
    /// the preview is disabled or the app is shutting down.
    private void previewCaptureLoop()
    {
        while (true)
        {
            _previewCaptureMutex.lock();
            const running = _previewCaptureRunning;
            const desired = _previewCaptureDesired;
            _previewCaptureMutex.unlock();
            if (!running) return;
            if (!desired)
            {
                try Thread.sleep(
                    dur!"msecs"(cast(long) (previewCaptureIdleIntervalSeconds * 1000)));
                catch (Exception) {}
                continue;
            }
            // Reuse the persistent GDI capture state and the same RgbaImage so
            // per-frame work is just one COLORONCOLOR StretchBlt plus a small
            // pixel shuffle; the GPU texture is never recreated. The target
            // size tracks the preview panel so the frame stays sharp.
            _previewCaptureMutex.lock();
            const targetWidth = _previewCaptureTargetWidth;
            const targetHeight = _previewCaptureTargetHeight;
            const windowHwnd = _previewCaptureWindowHwnd;
            _previewCaptureMutex.unlock();
            // Match the preview to the stream source: the selected window when
            // game/window capture is active, otherwise the primary monitor.
            _previewCapturer.setWindowTarget(windowHwnd);
            _previewCapturer.setTargetSize(targetWidth, targetHeight);
            const byteCount = cast(size_t) targetWidth * targetHeight * 4;
            if (_previewCaptureBuffer is null ||
                _previewCaptureBuffer.length < byteCount)
                _previewCaptureBuffer.length = byteCount;
            auto bytes = _previewCaptureBuffer[0 .. byteCount];
            if (_previewCapturer.capture(bytes))
            {
                if (_previewCaptureImage is null ||
                    _previewCaptureImage.width() != targetWidth ||
                    _previewCaptureImage.height() != targetHeight)
                {
                    _previewCaptureImage = new RgbaImage(targetWidth,
                        targetHeight, bytes);
                }
                else
                {
                    _previewCaptureImage.reset(targetWidth, targetHeight, bytes);
                }
                _previewCaptureMutex.lock();
                _previewCaptureFrame = _previewCaptureImage;
                _previewCaptureMutex.unlock();
            }
            try Thread.sleep(dur!"msecs"(1000 / previewCaptureFps));
            catch (Exception) {}
        }
    }

    /// Logs focus changes (alt-tab, window activation) so an unexpected stop
    /// can be correlated with a focus/minimize transition.
    protected override void onHostFocusChanged(bool focused)
    {
        _activityLog.note(focused ? "Window focus gained." : "Window focus lost (possible alt-tab).");
    }

    protected override void onTick(double deltaSeconds)
    {
        _activityLog.heartbeat();
        const minimized = _window.isMinimized();
        if (minimized != _lastMinimized)
        {
            _lastMinimized = minimized;
            _activityLog.note(minimized ? "Window minimized." : "Window restored.");
        }
        // Once the tray icon exists, a minimize from any path (taskbar click,
        // Alt+Space system menu) converts into a tray-hide so the app stays in
        // the tray instead of leaving a taskbar button.
        if (_tray !is null && !_trayHidden && _window.isMinimized())
            hideToTray();
        const streamSnapshot = _worker.snapshot();
        const streamActive = streamSnapshot.requestedRunning ||
            streamSnapshot.processRunning;
        if (streamActive != _lastStreamActive)
        {
            _lastStreamActive = streamActive;
            if (streamActive)
                _activityLog.info("Stream started.");
            else
                _activityLog.info(streamSnapshot.failed ?
                    "Stream stopped (failed: " ~ streamSnapshot.status ~ ")." :
                    "Stream stopped.");
            if (_tray !is null) _tray.setStreaming(streamActive);
        }
        _activityLog.setSnapshot(format(
            "stream=%s status=%s metrics=[%s]", streamActive ? "on" : "off",
            streamSnapshot.status,
            format("FPS %s Speed %s dup %s drop %s time %s",
                streamSnapshot.fps, streamSnapshot.speed,
                streamSnapshot.duplicatedFrames, streamSnapshot.droppedFrames,
                streamSnapshot.outputTime)));
        updateLiveSourcePreview(deltaSeconds);
        auto audioScan = _audioScanner.snapshot();

        // A Windows audio device notification (device added/removed/state
        // changed) triggers a background rescan so the lists never go stale
        // while the program runs. The scan is serialized by the scanner.
        if (_audioNotifications !is null && _audioNotifications.consumeChanged())
            _pendingAudioRescan = true;

        // A periodic safety-net rescan guarantees device changes are noticed
        // even if the Core Audio notification path is unavailable, so a
        // disconnected endpoint always shows up as Unavailable within the
        // interval.
        _audioRescanTimer += deltaSeconds;
        if (_audioRescanTimer >= audioRescanIntervalSeconds)
        {
            _audioRescanTimer = 0;
            _pendingAudioRescan = true;
        }
        if (_pendingAudioRescan && !audioScan.running)
        {
            _pendingAudioRescan = false;
            refreshAudioDevices(false, true);
        }

        if (audioScan.generation != _audioDeviceGeneration)
        {
            _audioDeviceGeneration = audioScan.generation;

            // Refresh the persistent identifier → name cache from every
            // successful scan so a temporarily disconnected device keeps its
            // real name in the selectors.
            bool cacheGrew;
            void remember(const AudioEndpoint[] devices)
            {
                foreach (device; devices)
                {
                    if (device.inputName.length == 0 ||
                        device.displayName.length == 0) continue;
                    const existing = device.inputName in _deviceNameCache;
                    if (existing is null || *existing != device.displayName)
                    {
                        _deviceNameCache[device.inputName] = device.displayName;
                        cacheGrew = true;
                    }
                }
            }
            remember(audioScan.desktopDevices);
            remember(audioScan.microphoneDevices);
            if (cacheGrew)
            {
                _desktopAudio.setNameCache(_deviceNameCache);
                _microphone.setNameCache(_deviceNameCache);
                markSettingsDirty();
            }

            _desktopAudio.setDevices(audioScan.desktopDevices);
            _microphone.setDevices(audioScan.microphoneDevices);
            if (_selectDefaultDesktopAudio &&
                _desktopAudio.selectDefaultIfEmpty())
            {
                _localStatus =
                    "Selected the Windows default playback endpoint for desktop audio.";
                _localStatusError = false;
            }

            string scanError;
            if (audioScan.desktopError.length > 0)
                scanError ~= audioScan.desktopError;
            if (audioScan.microphoneError.length > 0)
                scanError ~= (scanError.length > 0 ? "\n" : "") ~
                    audioScan.microphoneError;

            if (scanError.length > 0)
            {
                _localStatus = scanError;
                _localStatusError = true;
                _activityLog.warning(
                    "Audio device scan problem: " ~ scanError);
            }
            else
            {
                const summary = format(
                    "Found %d Windows playback endpoint%s and %d microphone%s.",
                    audioScan.desktopDevices.length,
                    audioScan.desktopDevices.length == 1 ? "" : "s",
                    audioScan.microphoneDevices.length,
                    audioScan.microphoneDevices.length == 1 ? "" : "s");
                _localStatus = summary;
                _localStatusError = false;
                // The safety-net rescan runs every few seconds even when
                // nothing changed; only log when the device inventory actually
                // changed so the activity log stays sparse.
                if (summary != _lastAudioScanSummary)
                {
                    _lastAudioScanSummary = summary;
                    _activityLog.info(summary);
                }
            }
        }

        if (_settingsDirty)
        {
            _settingsSaveDelay -= deltaSeconds;
            if (_settingsSaveDelay <= 0) saveSettingsNow();
        }

        const snapshot = _worker.snapshot();
        const active = snapshot.requestedRunning || snapshot.processRunning;
        if (active)
        {
            _localStatus = "";
            _localStatusError = false;
        }
        const status = !active && _localStatus.length > 0 ?
            _localStatus : snapshot.status;
        const metrics = format(
            "FPS %s  •  Speed %s  •  Duplicated %s  •  Dropped %s  •  Time %s",
            snapshot.fps.length > 0 ? snapshot.fps : "—",
            snapshot.speed.length > 0 ? snapshot.speed : "—",
            snapshot.duplicatedFrames.length > 0 ?
                snapshot.duplicatedFrames : "—",
            snapshot.droppedFrames.length > 0 ?
                snapshot.droppedFrames : "—",
            snapshot.outputTime.length > 0 ? snapshot.outputTime : "—");
        const diagnostics = snapshot.diagnostics.length > 0 ? snapshot.diagnostics :
            (_settingsMessage.length > 0 ? _settingsMessage :
                "Settings, including stream keys, are saved in " ~ settingsFilePath());

        if (status != _lastStatus)
        {
            _lastStatus = status;
            _status.setText(status);
            if (snapshot.failed || (!active && _localStatusError))
                _status.setColor(Color.fromHex(0xe19a9a));
            else if (snapshot.processRunning)
                _status.setColor(Color.fromHex(0x9fd4af));
            else
                _status.useThemeColor();
        }
        if (metrics != _lastMetrics)
        {
            _lastMetrics = metrics;
            _metrics.setText(metrics);
        }
        if (diagnostics != _lastDiagnostics)
        {
            _lastDiagnostics = diagnostics;
            _diagnostics.setText(diagnostics);
            if (snapshot.diagnostics.length == 0 && _settingsMessageError)
                _diagnostics.setColor(Color.fromHex(0xe19a9a));
            else
                _diagnostics.setColor(Color.fromHex(0x8793a0));
        }

        const twitchHasKey = _twitchKey.textUtf8().strip().length > 0;
        const youtubeHasKey = _youtubeKey.textUtf8().strip().length > 0;
        _twitchEnabled.setEnabled(!active && twitchHasKey);
        _youtubeEnabled.setEnabled(!active && youtubeHasKey);
        _sourceQuality.setEnabled(!active);
        _youtubeQuality.setEnabled(!active);
        _youtubeBitrate.setEnabled(!active);
        _desktopAudio.setEnabled(!active);
        _microphone.setEnabled(!active);
        _captureSource.setEnabled(!active);
        if (_windowContentCapture !is null)
        {
            const hasWindow = _captureSource.selectedHwnd().strip().length > 0;
            _windowContentCapture.setEnabled(!active && hasWindow);
        }
        _refreshAudioDevices.setEnabled(!active && !audioScan.running);
        _refreshAudioDevices.setText(audioScan.running ?
            "Refreshing audio devices…" : "Refresh audio devices");
        const expectedText = active ? "Stop streaming" : "Start streaming";
        _startStop.setText(expectedText);
        _startStop.setDanger(active);
        if (!active) _startStop.setAccent(true);
    }

    void shutdown()
    {
        _previewCaptureMutex.lock();
        _previewCaptureRunning = false;
        _previewCaptureMutex.unlock();
        if (_previewCaptureThread !is null)
        {
            try _previewCaptureThread.join();
            catch (Exception) {}
        }
        if (_tray !is null)
        {
            _tray.shutdown();
            _tray = null;
        }
        if (_audioNotifications !is null) _audioNotifications.shutdown();
        saveSettingsNow();
        _audioScanner.shutdown();
        _worker.shutdown();
        if (_activityLog !is null) _activityLog.shutdown();
    }
}

/// Quick link that opens the OS default browser on left-click and shows a
/// right-click context menu to pick a specific installed browser. The chosen
/// browser is handed to `onChooseBrowser` so the owning root can persist it.
private final class BrowserQuickLinkButton : Button
{
    private BrowserChoice delegate() _currentChoice;
    void delegate(BrowserChoice choice) onChooseBrowser;

    this(string label, BrowserChoice delegate() currentChoice)
    {
        super(label);
        _currentChoice = currentChoice;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right && enabled())
        {
            showBrowserMenu(event.globalPosition);
            return true;
        }
        return super.onMouseDown(event);
    }

    private void showBrowserMenu(Point globalPosition)
    {
        ContextMenuItem[] items = buildBrowserMenuItems(availableBrowserChoices(),
            _currentChoice(), delegate(BrowserChoice choice) {
                if (onChooseBrowser !is null)
                    onChooseBrowser(choice);
            });
        if (items.length == 0) return;
        showContextMenu(this, globalPosition, items);
    }
}

/// Builds the quick-link browser picker entries in display order, marking the
/// current choice. Extracted so the menu content is testable without a window.
private static ContextMenuItem[] buildBrowserMenuItems(
    const BrowserChoice[] available, BrowserChoice current,
    void delegate(BrowserChoice choice) choose)
{
    ContextMenuItem[] items;
    foreach (choice; available)
        items ~= browserPickerItem(choice, current, choose);
    return items;
}

/// One picker entry. The choice is a function parameter so each closure captures
/// its own copy — a delegate built directly over a foreach loop variable would
/// capture the shared loop storage and every item would fire the last choice.
private static ContextMenuItem browserPickerItem(BrowserChoice choice,
    BrowserChoice current, void delegate(BrowserChoice choice) choose)
{
    return ContextMenuItem.check(browserChoiceLabel(choice),
        current == choice, delegate() { choose(choice); });
}

unittest
{
    // Each entry must fire ITS OWN choice. A closure built over the foreach
    // loop variable captures the shared loop storage, so every item would fire
    // the last choice (regression: picking any browser opened the last one).
    BrowserChoice[] fired;
    const items = buildBrowserMenuItems(
        [BrowserChoice.defaultBrowser, BrowserChoice.chrome,
            BrowserChoice.firefox], BrowserChoice.chrome,
        delegate(BrowserChoice choice) { fired ~= choice; });
    assert(items.length == 3);
    assert(items[0].label == "Default browser");
    assert(!items[0].checked);
    assert(items[1].label == "Google Chrome");
    assert(items[1].checked);
    assert(items[2].label == "Firefox");
    assert(!items[2].checked);

    foreach (item; items)
        item.action();
    assert(fired.length == 3);
    assert(fired[0] == BrowserChoice.defaultBrowser);
    assert(fired[1] == BrowserChoice.chrome);
    assert(fired[2] == BrowserChoice.firefox);

    const all = buildBrowserMenuItems(
        [BrowserChoice.defaultBrowser, BrowserChoice.chrome,
            BrowserChoice.edge, BrowserChoice.firefox],
        BrowserChoice.defaultBrowser, delegate(BrowserChoice) {});
    assert(all.length == 4);
    assert(all[2].label == "Microsoft Edge");
    assert(all[0].checked && !all[1].checked && !all[3].checked);
}

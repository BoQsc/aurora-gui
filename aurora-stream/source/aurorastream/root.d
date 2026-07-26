module aurorastream.root;

import aurora;
import aurorastream.appversion : appDisplayName;
import aurorastream.audiodevices : AudioDeviceScanner;
import aurorastream.browser : openExternalUrl, openPacingDiagnostic;
import aurorastream.broadcast : BroadcastQuality, BroadcastSettings,
    BroadcastSnapshot, BroadcastWorker, CaptureSelection, EncoderSelection,
    detectCaptureBackend, detectEncoder, videoPipelineLabel,
    defaultAudioBitrateKbps, qualityHeight, qualityShortLabel, qualityWidth,
    twitchVideoBitrateKbps, youtubeVideoBitrateKbps;
import aurorastream.clipboardfield : ClipboardTextField;
import aurorastream.devicedropdown : AudioDeviceDropdown;
import aurorastream.qualitydropdown : SourceQualityDropdown;
import aurorastream.settings : loadSettings, saveSettings, settingsFilePath;
import std.format : format;
import std.string : startsWith, strip;

private enum twitchSettingsUrl = "https://dashboard.twitch.tv/settings/stream";
private enum youtubeLiveControlUrl = "https://studio.youtube.com/channel/UC/livestreaming";

final class StreamRoot : VBox
{
    private GuiWindow _window;
    private EncoderSelection _encoder;
    private CaptureSelection _capture;
    private BroadcastWorker _worker;
    private AudioDeviceScanner _audioScanner;

    private SourceQualityDropdown _sourceQuality;
    private Button _settingsMenu;
    private bool _streamingServersVisible;
    private ScrollView _settingsScroll;
    private VBox _twitchServerGroup;
    private CheckBox _twitchEnabled;
    private ClipboardTextField _twitchServer;
    private ClipboardTextField _twitchKey;
    private Button _twitchPaste;
    private VBox _youtubeServerGroup;
    private CheckBox _youtubeEnabled;
    private ClipboardTextField _youtubeServer;
    private ClipboardTextField _youtubeKey;
    private Button _youtubePaste;
    private CheckBox _youtubeFourK;
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

    this(GuiWindow window, string executablePath)
    {
        super(8, Insets(10));
        _window = window;
        _worker = new BroadcastWorker(executablePath);
        _audioScanner = new AudioDeviceScanner();
        _encoder = detectEncoder();
        _capture = detectCaptureBackend();

        bool settingsLoaded;
        string settingsLoadMessage;
        const saved = loadSettings(settingsLoaded, settingsLoadMessage);
        _selectDefaultDesktopAudio = saved.desktopAudioEnabled &&
            saved.desktopAudioDevice.strip().length == 0;
        _settingsMessage = settingsLoadMessage;
        _settingsLoadFailed = !settingsLoaded &&
            settingsLoadMessage.startsWith("Could not load");
        _settingsMessageError = _settingsLoadFailed;

        auto header = add(new HBox(8));
        header.layoutHints().preferredHeight = 44;
        auto title = header.add(new Label(appDisplayName));
        title.setScale(2);
        title.layoutHints().flex = 1.0;
        _settingsMenu = header.add(new Button("Settings ▼"));
        _settingsMenu.layoutHints().preferredWidth = 105;
        _settingsMenu.layoutHints().preferredHeight = 34;
        _settingsMenu.onClick = delegate() { openSettingsMenu(); };
        _output = header.add(new Label(
            "Source 1080p60 • Twitch 1080p60 • YouTube 1440p60"));
        _output.setScale(1);
        _output.setColor(Color.fromHex(0x9ba7b5));

        auto body = add(new HBox(9));
        body.layoutHints().flex = 1.0;
        body.layoutHints().minHeight = 540;

        auto settingsContent = new VBox(8, Insets(9));
        settingsContent.setBackground(Color.fromHex(0x1b2026));
        settingsContent.setBorder(Color.fromHex(0x3d4651), 6);
        settingsContent.layoutHints().preferredWidth = 540;

        auto sourceTitle = settingsContent.add(new Label("COMMON SOURCE CANVAS"));
        sourceTitle.setScale(1);
        sourceTitle.setColor(Color.fromHex(0xc8d0da));
        _sourceQuality = settingsContent.add(new SourceQualityDropdown(
            saved.sourceQuality));
        _sourceQuality.onChanged = delegate(BroadcastQuality quality) {
            updateQualitySummary();
            markSettingsDirty();
        };
        auto sourceHint = settingsContent.add(new Label(
            "1080p60 is the default. This shared canvas is scaled separately for every enabled destination."));
        sourceHint.setScale(1);
        sourceHint.setColor(Color.fromHex(0x8793a0));
        sourceHint.layoutHints().preferredHeight = 36;

        settingsContent.add(new Separator());
        auto twitchHeader = settingsContent.add(new HBox(6));
        twitchHeader.layoutHints().preferredHeight = 38;
        auto twitchTitle = twitchHeader.add(new Label("TWITCH OUTPUT"));
        twitchTitle.setScale(1);
        twitchTitle.setColor(Color.fromHex(0xc8d0da));
        twitchTitle.layoutHints().flex = 1.0;
        auto twitchQuickLink = twitchHeader.add(new Button("Open Twitch settings"));
        twitchQuickLink.setFlat(true);
        twitchQuickLink.layoutHints().preferredHeight = 30;
        twitchQuickLink.onClick = delegate() {
            openBrowserShortcut("Twitch stream settings", twitchSettingsUrl);
        };

        const twitchHasSavedKey = saved.twitchKey.strip().length > 0;
        _twitchEnabled = settingsContent.add(new CheckBox("Stream to Twitch",
            saved.twitchEnabled && twitchHasSavedKey));
        _twitchEnabled.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
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
            streamKeyChanged(_twitchKey, _twitchEnabled);
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
        auto youtubeQuickLink = youtubeHeader.add(new Button("Open YouTube Live"));
        youtubeQuickLink.setFlat(true);
        youtubeQuickLink.layoutHints().preferredHeight = 30;
        youtubeQuickLink.onClick = delegate() {
            openBrowserShortcut("YouTube Live Control Room", youtubeLiveControlUrl);
        };

        const youtubeHasSavedKey = saved.youtubeKey.strip().length > 0;
        auto youtubeDestinationRow = settingsContent.add(new HBox(6));
        youtubeDestinationRow.layoutHints().preferredHeight = 34;
        _youtubeEnabled = youtubeDestinationRow.add(new CheckBox("Stream to YouTube",
            saved.youtubeEnabled && youtubeHasSavedKey));
        _youtubeEnabled.layoutHints().preferredWidth = 170;
        _youtubeEnabled.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
        };
        _youtubeFourK = youtubeDestinationRow.add(new CheckBox(
            "4K / 2160p60 highest-quality output",
            saved.youtubeQuality == BroadcastQuality.fourK));
        _youtubeFourK.layoutHints().preferredWidth = 310;
        _youtubeFourK.layoutHints().flex = 1.0;
        _youtubeFourK.onChanged = delegate(bool checked) {
            updateQualitySummary();
            markSettingsDirty();
        };
        _youtubeProfile = settingsContent.add(new Label(
            "Default: 2560×1440 • 60 FPS • 24000 kbps • independent H.264 encoder"));
        _youtubeProfile.setScale(1);
        _youtubeProfile.setColor(Color.fromHex(0x8793a0));
        _youtubeProfile.layoutHints().preferredHeight = 36;
        _youtubeServerGroup = addFieldGroup(settingsContent, "YouTube server",
            saved.youtubeServer, "YouTube RTMP or RTMPS server URL",
            _youtubeServer);
        _youtubeKey = addStreamKeyField(settingsContent, "YouTube stream key",
            saved.youtubeKey, "Paste the YouTube stream key", _youtubePaste);
        _youtubeKey.onChanged = delegate() {
            streamKeyChanged(_youtubeKey, _youtubeEnabled);
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
        };
        _microphone = addAudioDeviceDropdown(settingsContent,
            "Microphone (FFmpeg DirectShow)",
            saved.microphoneDevice,
            "No DirectShow microphone devices found");

        auto deviceRow = settingsContent.add(new HBox(6));
        _refreshAudioDevices = deviceRow.add(new Button("Refresh audio devices"));
        _refreshAudioDevices.onClick = delegate() { refreshAudioDevices(true); };
        auto audioHint = deviceRow.add(new Label(
            "Desktop lists speakers/headphones. Microphone lists recording inputs. Either can remain Disabled."));
        audioHint.setScale(1);
        audioHint.setColor(Color.fromHex(0x8793a0));
        audioHint.layoutHints().flex = 1.0;
        audioHint.layoutHints().preferredHeight = 36;

        _settingsScroll = new ScrollView(settingsContent);
        _settingsScroll.layoutHints().preferredWidth = 560;
        _settingsScroll.layoutHints().minWidth = 450;
        _settingsScroll.layoutHints().flex = 0.0;
        body.add(_settingsScroll);

        auto monitor = body.add(new VBox(8));
        monitor.layoutHints().flex = 1.0;
        monitor.layoutHints().minWidth = 420;

        auto preview = monitor.add(new VBox(6, Insets(18)));
        preview.setBackground(Color.fromHex(0x090b0e));
        preview.setBorder(Color.fromHex(0x343d47), 6);
        preview.layoutHints().flex = 1.0;
        preview.layoutHints().minHeight = 300;
        preview.add(new Spacer());
        auto previewTitle = preview.add(new Label("LIVE SOURCE CANVAS"));
        previewTitle.setAlignment(HorizontalAlign.center);
        previewTitle.setScale(2);
        auto previewDetail = preview.add(new Label(
            "One common 1080p, 1440p, or 4K source canvas.\nTwitch and YouTube are then scaled and encoded independently."));
        previewDetail.setAlignment(HorizontalAlign.center);
        previewDetail.setScale(1);
        previewDetail.setColor(Color.fromHex(0x8e99a6));
        previewDetail.layoutHints().preferredHeight = 54;
        preview.add(new Spacer());

        auto statusPanel = monitor.add(new VBox(6, Insets(10)));
        statusPanel.setBackground(Color.fromHex(0x1b2026));
        statusPanel.setBorder(Color.fromHex(0x3d4651), 6);
        statusPanel.layoutHints().preferredHeight = 180;
        _videoPath = statusPanel.add(new Label(_encoder.ffmpegAvailable
            ? "Capture: " ~ _capture.label ~ " • " ~
                videoPipelineLabel(saved, _encoder, _capture) ~
                " • Encoder: " ~ _encoder.label
            : "Encoder: FFmpeg not found"));
        _videoPath.setScale(1);
        _videoPath.setColor(_encoder.ffmpegAvailable ?
            Color.fromHex(0x9fd4af) : Color.fromHex(0xe19a9a));
        _status = statusPanel.add(new Label("Ready"));
        _status.setScale(2);
        _metrics = statusPanel.add(new Label(
            "FPS —  •  Speed —  •  Duplicated —  •  Dropped —  •  Time —"));
        _metrics.setScale(1);
        _metrics.setColor(Color.fromHex(0x9ba7b5));
        _metrics.layoutHints().preferredHeight = 28;
        _metrics.setEllipsis(false);
        _diagnostics = statusPanel.add(new Label(settingsLoadMessage.length > 0 ?
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
        updateQualitySummary();
        refreshAudioDevices(false);
    }

    private void openBrowserShortcut(string pageName, string url)
    {
        string error;
        if (openExternalUrl(url, error))
        {
            _localStatus = pageName ~ " opened in the default browser.";
            _localStatusError = false;
            _status.setText(_localStatus);
            _status.setColor(Color.fromHex(0x9fd4af));
            return;
        }

        _localStatus = "Could not open " ~ pageName ~ ": " ~ error;
        _localStatusError = true;
        _status.setText(_localStatus);
        _status.setColor(Color.fromHex(0xe19a9a));
    }

    private VBox addFieldGroup(VBox panel, string title, string value,
        string placeholder, out ClipboardTextField field)
    {
        auto group = panel.add(new VBox(4));
        auto label = group.add(new Label(title));
        label.setScale(1);
        label.setColor(Color.fromHex(0x9ca8b5));
        label.layoutHints().preferredHeight = 19;
        field = group.add(new ClipboardTextField(value));
        field.setPlaceholder(placeholder);
        field.onChanged = delegate() { markSettingsDirty(); };
        return group;
    }

    private void openSettingsMenu()
    {
        ContextMenuItem[] items = [
            ContextMenuItem.check("Unhide streaming servers",
                _streamingServersVisible, delegate() {
                    setStreamingServersVisible(!_streamingServersVisible);
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
                    return;
                }
                _localStatus = "Opened the A/V pacing diagnostic in a separate terminal.";
                _localStatusError = false;
            })
        ];

        // Context menus use a bottom-left anchor. Supplying the button bottom
        // plus the complete menu height places the menu immediately below it.
        enum menuHeight = 6 + 22 + 6 + 22;
        showContextMenu(_settingsMenu, _settingsMenu.localToGlobal(
            Point(0, _settingsMenu.bounds().height + menuHeight + 2)), items);
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

    private void streamKeyChanged(ClipboardTextField field,
        CheckBox destination)
    {
        const hasKey = field.textUtf8().strip().length > 0;
        destination.setChecked(hasKey, false);

        const snapshot = _worker.snapshot();
        const active = snapshot.requestedRunning || snapshot.processRunning;
        destination.setEnabled(hasKey && !active);
        updateQualitySummary();
        markSettingsDirty();
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

    private void refreshAudioDevices(bool announce)
    {
        if (!_audioScanner.start()) return;
        if (_refreshAudioDevices !is null)
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
            return true;
        }

        _settingsMessage = "Could not save settings: " ~ error;
        _settingsMessageError = true;
        _settingsSaveDelay = 2.0;
        return false;
    }

    private BroadcastQuality selectedSourceQuality() const
    {
        return _sourceQuality.selectedQuality();
    }

    private BroadcastQuality selectedYoutubeQuality() const
    {
        return _youtubeFourK.checked() ?
            BroadcastQuality.fourK : BroadcastQuality.twoK;
    }

    private void updateQualitySummary()
    {
        if (_output is null || _presetSummary is null ||
            _youtubeProfile is null) return;

        const sourceQuality = selectedSourceQuality();
        const youtubeQuality = selectedYoutubeQuality();
        const youtubeWidth = qualityWidth(youtubeQuality);
        const youtubeHeight = qualityHeight(youtubeQuality);
        const youtubeBitrate = youtubeVideoBitrateKbps(youtubeQuality);

        if (_videoPath !is null && _encoder.ffmpegAvailable)
        {
            BroadcastSettings pathSettings;
            pathSettings.sourceQuality = sourceQuality;
            pathSettings.twitchEnabled = _twitchEnabled.checked();
            pathSettings.youtubeEnabled = _youtubeEnabled.checked();
            pathSettings.twitchQuality = BroadcastQuality.fullHD;
            pathSettings.youtubeQuality = youtubeQuality;
            _videoPath.setText("Capture: " ~ _capture.label ~ " • " ~
                videoPipelineLabel(pathSettings, _encoder, _capture) ~
                " • Encoder: " ~ _encoder.label);
        }

        _output.setText(format(
            "Source %s60 • Twitch 1080p60 • YouTube %s60",
            qualityShortLabel(sourceQuality), qualityShortLabel(youtubeQuality)));
        _youtubeProfile.setText(format(
            "%s: %d×%d • 60 FPS • %d kbps • independent H.264 encoder",
            youtubeQuality == BroadcastQuality.fourK ? "Highest quality" : "Default",
            youtubeWidth, youtubeHeight, youtubeBitrate));

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
        settings.desktopAudioDevice = _desktopAudio.selectedDevice().strip();
        settings.desktopAudioEnabled = _selectDefaultDesktopAudio ||
            settings.desktopAudioDevice.length > 0;
        settings.microphoneDevice = _microphone.selectedDevice().strip();
        return settings;
    }

    private void toggleStreaming()
    {
        const snapshot = _worker.snapshot();
        if (snapshot.requestedRunning || snapshot.processRunning)
        {
            _worker.stop();
            return;
        }

        if (_selectDefaultDesktopAudio &&
            _desktopAudio.selectedDevice().strip().length == 0)
        {
            _localStatus =
                "Wait for Windows desktop-audio detection to finish, then start streaming.";
            _localStatusError = true;
            return;
        }

        saveSettingsNow();

        string error;
        if (!_worker.start(collectSettings(), _encoder, _capture, error))
        {
            _localStatus = error;
            _localStatusError = true;
            _status.setText(error);
            _status.setColor(Color.fromHex(0xe19a9a));
            return;
        }
        _localStatus = "";
        _localStatusError = false;
        _status.useThemeColor();
        _startStop.setText("Stop streaming");
        _startStop.setDanger(true);
    }

    protected override void onTick(double deltaSeconds)
    {
        auto audioScan = _audioScanner.snapshot();
        if (audioScan.generation != _audioDeviceGeneration)
        {
            _audioDeviceGeneration = audioScan.generation;
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
            }
            else
            {
                _localStatus = format(
                    "Found %d Windows playback endpoint%s and %d microphone%s.",
                    audioScan.desktopDevices.length,
                    audioScan.desktopDevices.length == 1 ? "" : "s",
                    audioScan.microphoneDevices.length,
                    audioScan.microphoneDevices.length == 1 ? "" : "s");
                _localStatusError = false;
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
        _youtubeFourK.setEnabled(!active);
        _desktopAudio.setEnabled(!active);
        _microphone.setEnabled(!active);
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
        saveSettingsNow();
        _audioScanner.shutdown();
        _worker.shutdown();
    }
}

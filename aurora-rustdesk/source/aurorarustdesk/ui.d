module aurorarustdesk.ui;

import aurora;
import aurora.canvas : Canvas;
import aurora.event : Event, Key, MouseButton;
import aurora.image : RgbaImage;
import aurorarustdesk.identity : DeviceIdentity, generatePassword,
    loadStoredPassword, saveStoredPassword;
import aurorarustdesk.input : keyPressPacket, mouseButtonPacket,
    mouseMovePacket, mouseWheelPacket;
import aurorarustdesk.peers : SavedPeer, loadSavedPeers, rememberPeer;
import aurorarustdesk.session : RustDeskController, RustDeskHost;
import aurorarustdesk.settings : AccessPermission, RustDeskSettings,
    loadSettings, saveSettings;
import aurorarustdesk.windowsintegration : autostartEnabled, setAutostart;
import std.algorithm.comparison : max, min;
import std.conv : to;
import std.file : thisExePath;
import std.string : startsWith, strip;

version (Windows)
{
    pragma(lib, "user32");
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock,
        GMEM_MOVEABLE, OpenClipboard, SetClipboardData;
    import std.utf : toUTF16;
}

version (Windows)
private bool copyTextToClipboard(string value)
{
    if (!OpenClipboard(null)) return false;
    scope (exit) CloseClipboard();
    if (!EmptyClipboard()) return false;

    auto encoded = toUTF16(value);
    const bytes = (encoded.length + 1) * wchar.sizeof;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory is null) return false;
    auto text = cast(wchar*) GlobalLock(memory);
    if (text is null)
    {
        GlobalFree(memory);
        return false;
    }
    foreach (index, ch; encoded) text[index] = ch;
    text[encoded.length] = 0;
    GlobalUnlock(memory);

    if (SetClipboardData(CF_UNICODETEXT, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }
    return true;
}

private final class RemoteCanvas : Widget
{
    private RustDeskController _connector;
    private RgbaImage _image;
    private uint _revision;
    private Rect _imageRect;

    this(RustDeskController connector)
    {
        _connector = connector;
        layoutHints().minHeight = 220;
        layoutHints().flex = 1.0;
        setFocusable(true);
    }

    void pollFrame()
    {
        int width;
        int height;
        ubyte[] rgba;
        if (!_connector.frameSnapshot(_revision, width, height, rgba)) return;
        if (_image is null || _image.width != width || _image.height != height)
            _image = new RgbaImage(width, height, rgba);
        else
            _image.reset(width, height, rgba);
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
            Color.fromHex(0x080a0d));
        if (_image is null)
        {
            canvas.drawTextInRect(Rect(18, 18, max(0, bounds().width - 36),
                max(0, bounds().height - 36)),
                "The remote desktop appears here after the encrypted connection is ready."d,
                theme().textMuted, 1, HorizontalAlign.center,
                VerticalAlign.middle, true);
            _imageRect = Rect.init;
            return;
        }
        int width = bounds().width;
        int height = cast(int)(cast(long) width * _image.height / _image.width);
        if (height > bounds().height)
        {
            height = bounds().height;
            width = cast(int)(cast(long) height * _image.width / _image.height);
        }
        _imageRect = Rect((bounds().width - width) / 2,
            (bounds().height - height) / 2, width, height);
        canvas.drawImage(_imageRect, _image, true);
        canvas.drawRoundedRect(_imageRect, 1, Color(0, 0, 0, 0),
            theme().border, 1);
    }

    private bool sendPosition(Point position)
    {
        if (_imageRect.width <= 0 || _imageRect.height <= 0) return false;
        if (position.x < _imageRect.x || position.y < _imageRect.y ||
            position.x >= _imageRect.right || position.y >= _imageRect.bottom)
            return false;
        const localX = position.x - _imageRect.x;
        const localY = position.y - _imageRect.y;
        const normalizedX = cast(ushort) min(65_535,
            cast(long) localX * 65_535 / max(1, _imageRect.width - 1));
        const normalizedY = cast(ushort) min(65_535,
            cast(long) localY * 65_535 / max(1, _imageRect.height - 1));
        _connector.sendInput(mouseMovePacket(normalizedX, normalizedY));
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        return sendPosition(event.position);
    }

    override bool onMouseDown(ref Event event)
    {
        if (!sendPosition(event.position)) return false;
        requestFocus();
        _connector.sendInput(mouseButtonPacket(event.button, true));
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (!sendPosition(event.position)) return false;
        _connector.sendInput(mouseButtonPacket(event.button, false));
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        const delta = cast(short) min(short.max, max(short.min, event.wheelY));
        _connector.sendInput(mouseWheelPacket(delta));
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.unknown) return false;
        _connector.sendInput(keyPressPacket(event.key, event.modifiers));
        return true;
    }

    override bool onFilesDropped(ref Event event)
    {
        if (event.paths.length == 0) return false;
        _connector.sendPaths(event.paths);
        return true;
    }
}

final class RustDeskRoot : VBox
{
    private DeviceIdentity _identity;
    private RustDeskHost _host;
    private RustDeskController _connector;
    private VBox _home;
    private VBox _session;
    private VBox _advanced;
    private VBox _welcome;
    private HBox _columns;
    private Label _notice;
    private Label _shareId;
    private TextField _sharePassword;
    private Label _hostStatus;
    private TextField _connectId;
    private TextField _connectPassword;
    private Label _connectStatus;
    private CheckBox _allowConnections;
    private Button _newPasswordButton;
    private Button _connectButton;
    private Button _cancelButton;
    private Button _disconnectButton;
    private Button _savedPeerButton;
    private Label _transferStatus;
    private Label _streamStatusLabel;
    private RemoteCanvas _remoteCanvas;
    private TextField _serverHostField;
    private TextField _serverPortField;
    private CheckBox _useRelay;
    private TextField _directPortField;
    private CheckBox _permanentPassword;
    private CheckBox _minimizeToTray;
    private CheckBox _permissionInput;
    private CheckBox _permissionFiles;
    private CheckBox _permissionClipboard;
    private Button _settingsButton;
    private string _password;
    private RustDeskSettings _settings;
    private bool _advancedVisible;
    private GuiWindow _window;
    private bool _hideAtStartup;
    private bool _startupVisibilityApplied;
    private string _serverOverrideHost;
    private ushort _serverOverridePort;
    private bool _rememberedCurrentConnection;
    private double _pollSeconds = 0.0;

    this(DeviceIdentity identity, GuiWindow window = null,
        bool hideAtStartup = false, string serverOverrideHost = "",
        ushort serverOverridePort = 0)
    {
        super(12, Insets(22));
        _identity = identity;
        _window = window;
        _hideAtStartup = hideAtStartup;
        _serverOverrideHost = serverOverrideHost;
        _serverOverridePort = serverOverridePort;
        _settings = loadSettings();
        _host = new RustDeskHost;
        _connector = new RustDeskController;
        buildUi();
        startHosting();
    }

    private void buildUi()
    {
        const palette = Theme.dark();
        auto heading = add(new HBox(12));
        heading.layoutHints().preferredHeight = 42;
        auto title = heading.add(new Label("Aurora RustDesk"));
        title.setScale(3);
        title.layoutHints().flex = 1.0;
        auto device = heading.add(new Label("ID " ~ _identity.numericId));
        device.setScale(1);

        _home = add(new VBox(14));
        _home.layoutHints().flex = 1.0;

        _welcome = _home.add(new VBox(5));
        _welcome.layoutHints().preferredHeight = 60;
        auto welcomeTitle = _welcome.add(new Label("Remote desktop by numeric ID"));
        welcomeTitle.setScale(3);
        auto welcomeText = _welcome.add(new Label(
            "Share the ID and one-time password to let someone help you, or enter a remote ID and password to control another computer."));
        welcomeText.setScale(1);
        welcomeText.setEllipsis(false);

        _columns = _home.add(new HBox(16));
        _columns.layoutHints().preferredHeight = 360;

        auto share = new VBox(10, Insets(20));
        share.layoutHints().flex = 1.0;
        share.layoutHints().minWidth = 360;
        share.setBackground(palette.panelBackground);
        share.setBorder(palette.border, 1);
        auto shareTitle = share.add(new Label("Share this computer"));
        shareTitle.setScale(2);
        auto shareHint = share.add(new Label(
            "Give the other person your ID and password."));
        shareHint.setScale(1);
        shareHint.setEllipsis(false);
        share.add(new Label("YOUR ID"));
        _shareId = share.add(new Label(_identity.numericId));
        _shareId.setScale(4);
        share.add(new Label("PASSWORD"));
        auto passwordRow = share.add(new HBox(8));
        passwordRow.layoutHints().preferredHeight = 44;
        _sharePassword = passwordRow.add(new TextField());
        _sharePassword.setReadOnly(true);
        _sharePassword.layoutHints().flex = 1.0;
        _newPasswordButton = passwordRow.add(new Button("New password"));
        _newPasswordButton.onClick = delegate() { rotatePassword(); };
        _allowConnections = share.add(new CheckBox(
            "Allow connections while Aurora RustDesk is open", true));
        _allowConnections.onChanged = delegate(bool enabled)
        {
            if (enabled) startHosting();
            else stopHosting();
        };
        _hostStatus = share.add(new Label("Preparing…"));
        _hostStatus.setScale(1);
        _hostStatus.setEllipsis(false);
        _columns.add(share);

        auto control = new VBox(10, Insets(20));
        control.layoutHints().flex = 1.0;
        control.layoutHints().minWidth = 360;
        control.setBackground(palette.panelBackground);
        control.setBorder(palette.border, 1);
        auto controlTitle = control.add(new Label("Control another computer"));
        controlTitle.setScale(2);
        auto controlHint = control.add(new Label(
            "Enter the remote ID and the password shown on that computer."));
        controlHint.setScale(1);
        controlHint.setEllipsis(false);
        control.add(new Label("REMOTE ID"));
        _connectId = control.add(new TextField());
        _connectId.layoutHints().preferredHeight = 44;
        control.add(new Label("PASSWORD"));
        _connectPassword = control.add(new TextField());
        _connectPassword.layoutHints().preferredHeight = 44;
        auto actions = control.add(new HBox(8));
        actions.layoutHints().preferredHeight = 40;
        _connectButton = actions.add(new Button("Connect"));
        _connectButton.onClick = delegate() { connect(); };
        _cancelButton = actions.add(new Button("Cancel"));
        _cancelButton.setEnabled(false);
        _cancelButton.onClick = delegate() { disconnect(); };
        _savedPeerButton = actions.add(new Button("Recent IDs"));
        auto savedPeers = loadSavedPeers();
        _savedPeerButton.setEnabled(savedPeers.length > 0);
        _savedPeerButton.onClick = delegate()
        {
            auto peers = loadSavedPeers();
            if (peers.length == 0) return;
            _connectId.setText(peers[0].id);
            _connectStatus.setText("Recent ID " ~ peers[0].id ~ " is ready.");
        };
        actions.add(new Spacer());
        _connectStatus = control.add(new Label(
            "Enter a remote ID when you are ready."));
        _connectStatus.setScale(1);
        _connectStatus.setEllipsis(false);
        _columns.add(control);

        _notice = _home.add(new Label(
            "The ID server only introduces computers. Your password proves the session and is never sent to it."));
        _notice.setScale(1);
        _notice.setEllipsis(false);
        auto settingsRow = _home.add(new HBox(8));
        settingsRow.layoutHints().preferredHeight = 38;
        _settingsButton = settingsRow.add(new Button("Settings"));
        settingsRow.add(new Spacer());
        _settingsButton.onClick = delegate()
        {
            _advancedVisible = !_advancedVisible;
            _advanced.setVisible(_advancedVisible);
            _welcome.setVisible(!_advancedVisible);
            _columns.setVisible(!_advancedVisible);
            _notice.setVisible(!_advancedVisible);
            _settingsButton.setText(_advancedVisible ? "Back" : "Settings");
        };
        _advanced = _home.add(new VBox(8, Insets(14)));
        _advanced.layoutHints().flex = 1.0;
        _advanced.setBackground(palette.panelElevated);
        _advanced.setBorder(palette.border, 1);
        _advanced.setVisible(false);
        auto serverHint = _advanced.add(new Label(
            "Enter the ID (rendezvous) server both computers use. Leave the relay option on when neither computer accepts incoming Internet connections."));
        serverHint.setScale(1);
        serverHint.setEllipsis(false);
        auto serverRow = _advanced.add(new HBox(8));
        serverRow.layoutHints().preferredHeight = 40;
        serverRow.add(new Label("ID server address"));
        _serverHostField = serverRow.add(new TextField(_settings.serverHost));
        _serverHostField.layoutHints().flex = 1.0;
        _serverHostField.setPlaceholder("id.example.com");
        serverRow.add(new Label("Port"));
        _serverPortField = serverRow.add(new TextField(
            to!string(_settings.serverPort != 0 ? _settings.serverPort : 21_116)));
        _serverPortField.layoutHints().preferredWidth = 92;
        auto applyServer = serverRow.add(new Button("Apply"));
        applyServer.onClick = delegate() { restartHosting(); };
        auto transportRow = _advanced.add(new HBox(14));
        transportRow.layoutHints().preferredHeight = 40;
        _useRelay = transportRow.add(new CheckBox("Use relay",
            _settings.useRelay));
        _useRelay.onChanged = delegate(bool) { restartHosting(); };
        transportRow.add(new Label("Direct port"));
        _directPortField = transportRow.add(new TextField(
            to!string(_settings.directPort != 0 ? _settings.directPort : 21_118)));
        _directPortField.layoutHints().preferredWidth = 92;
        transportRow.add(new Spacer());
        auto windowsOptions = _advanced.add(new HBox(18));
        windowsOptions.layoutHints().preferredHeight = 36;
        auto startWithWindows = windowsOptions.add(new CheckBox(
            "Start with Windows", autostartEnabled()));
        startWithWindows.onChanged = delegate(bool enabled)
        {
            try setAutostart(enabled, thisExePath());
            catch (Exception error)
            {
                startWithWindows.setChecked(!enabled, false);
                _hostStatus.setText("Autostart could not be changed: " ~ error.msg);
            }
        };
        _minimizeToTray = windowsOptions.add(new CheckBox(
            "Keep running in notification area", _settings.keepRunningInTray));
        _minimizeToTray.onChanged = delegate(bool) { persistSettings(); };
        windowsOptions.add(new Spacer());
        auto passwordOptions = _advanced.add(new HBox(14));
        passwordOptions.layoutHints().preferredHeight = 36;
        _permanentPassword = passwordOptions.add(new CheckBox(
            "Permanent password", _settings.permanentPassword));
        _permanentPassword.onChanged = delegate(bool) { restartHosting(); };
        passwordOptions.add(new Spacer());
        auto permissionsRow = _advanced.add(new HBox(14));
        permissionsRow.layoutHints().preferredHeight = 36;
        permissionsRow.add(new Label("Allow"));
        _permissionInput = permissionsRow.add(new CheckBox("Control",
            (_settings.permissions & AccessPermission.input) != 0));
        _permissionInput.onChanged = delegate(bool) { restartHosting(); };
        _permissionFiles = permissionsRow.add(new CheckBox("Files",
            (_settings.permissions & AccessPermission.files) != 0));
        _permissionFiles.onChanged = delegate(bool) { restartHosting(); };
        _permissionClipboard = permissionsRow.add(new CheckBox("Clipboard",
            (_settings.permissions & AccessPermission.clipboard) != 0));
        _permissionClipboard.onChanged = delegate(bool) { restartHosting(); };
        permissionsRow.add(new Spacer());

        _session = add(new VBox(10));
        _session.layoutHints().flex = 1.0;
        _session.setVisible(false);
        auto sessionHeading = _session.add(new HBox(10));
        sessionHeading.layoutHints().preferredHeight = 42;
        auto sessionTitle = sessionHeading.add(new Label("Remote computer"));
        sessionTitle.setScale(2);
        sessionTitle.layoutHints().flex = 1.0;
        _disconnectButton = sessionHeading.add(new Button("End session"));
        _disconnectButton.onClick = delegate() { disconnect(); };
        auto sessionHint = _session.add(new Label(
            "Click inside the remote screen to control it. Drag files or folders onto the screen to send them."));
        sessionHint.setScale(1);
        auto sessionTools = _session.add(new HBox(8));
        sessionTools.layoutHints().preferredHeight = 40;
        auto sendFileButton = sessionTools.add(new Button("Send file"));
        sendFileButton.onClick = delegate() { chooseFile(false); };
        auto sendClipboardButton = sessionTools.add(new Button("Send clipboard"));
        sendClipboardButton.onClick = delegate() { _connector.sendClipboard(); };
        auto getClipboardButton = sessionTools.add(new Button("Get clipboard"));
        getClipboardButton.onClick = delegate() { _connector.requestClipboard(); };
        sessionTools.add(new Spacer());
        _transferStatus = _session.add(new Label("No file transfer"));
        _transferStatus.setScale(1);
        _streamStatusLabel = _session.add(new Label("Waiting for stream quality…"));
        _streamStatusLabel.setScale(1);
        _remoteCanvas = _session.add(new RemoteCanvas(_connector));
    }

    private void chooseFile(bool sendFromHost)
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Send a file";
        options.acceptLabel = "Send";
        showFileDialog(this, options, delegate(string path)
        {
            if (sendFromHost) _host.sendPaths([path]);
            else _connector.sendPaths([path]);
        });
    }

    private uint currentPermissions()
    {
        uint permissions = AccessPermission.view;
        if (_permissionInput is null || _permissionInput.checked())
            permissions |= AccessPermission.input;
        if (_permissionFiles is null || _permissionFiles.checked())
            permissions |= AccessPermission.files;
        if (_permissionClipboard is null || _permissionClipboard.checked())
            permissions |= AccessPermission.clipboard;
        return permissions;
    }

    private string serverHost() const
    {
        if (_serverOverrideHost.length > 0) return _serverOverrideHost;
        return _settings.serverHost;
    }

    private ushort serverPort() const
    {
        if (_serverOverridePort != 0) return _serverOverridePort;
        return _settings.serverPort;
    }

    private void startHosting()
    {
        const permissions = currentPermissions();
        persistSettings(permissions);
        if (_permanentPassword !is null && _permanentPassword.checked())
        {
            const stored = loadStoredPassword();
            _password = stored.length > 0 ? stored : generatePassword();
            if (stored.length == 0)
                try saveStoredPassword(_password); catch (Exception) {}
        }
        else if (_password.length == 0)
            _password = generatePassword();
        _sharePassword.setReadOnly(false);
        _sharePassword.setText(_password);
        _sharePassword.setReadOnly(true);
        ushort directPort;
        try directPort = to!ushort(strip(_directPortField.textUtf8()));
        catch (Exception) directPort = _settings.directPort;
        const hostName = serverHost();
        if (hostName.length == 0)
        {
            _hostStatus.setText(
                "Add an ID server address in Settings to share this computer.");
            return;
        }
        try
        {
            _host.startRendezvous(_identity, hostName, serverPort(), directPort,
                _password, _useRelay !is null && _useRelay.checked(), permissions);
            bool connected;
            _hostStatus.setText(_host.status(connected));
        }
        catch (Exception error)
        {
            _hostStatus.setText("Could not start sharing: " ~ error.msg);
        }
    }

    private void restartHosting()
    {
        if (!_allowConnections.checked())
            _allowConnections.setChecked(true, false);
        startHosting();
    }

    private void rotatePassword()
    {
        _password = generatePassword();
        if (_permanentPassword !is null && _permanentPassword.checked())
            try saveStoredPassword(_password); catch (Exception) {}
        _sharePassword.setReadOnly(false);
        _sharePassword.setText(_password);
        _sharePassword.setReadOnly(true);
        if (_allowConnections.checked()) startHosting();
    }

    private void persistSettings(uint permissions = uint.max)
    {
        if (_serverOverrideHost.length > 0) return;
        if (_serverHostField is null || _serverPortField is null) return;
        _settings.serverHost = strip(_serverHostField.textUtf8());
        try _settings.serverPort = to!ushort(strip(_serverPortField.textUtf8()));
        catch (Exception) {}
        _settings.useRelay = _useRelay.checked();
        try _settings.directPort = to!ushort(strip(_directPortField.textUtf8()));
        catch (Exception) {}
        _settings.permanentPassword = _permanentPassword.checked();
        if (permissions != uint.max) _settings.permissions = permissions;
        _settings.keepRunningInTray = _minimizeToTray.checked();
        try saveSettings(_settings);
        catch (Exception) {}
    }

    private void stopHosting()
    {
        _host.stop();
        _hostStatus.setText("Sharing is turned off.");
    }

    private void connect()
    {
        const id = strip(_connectId.textUtf8());
        const password = _connectPassword.textUtf8();
        if (id.length == 0)
        {
            _connectStatus.setText("Enter the remote ID first.");
            return;
        }
        if (password.length == 0)
        {
            _connectStatus.setText("Enter the password shown on the remote computer.");
            return;
        }
        _connector.connect(serverHost(), serverPort(), id, password);
        _rememberedCurrentConnection = false;
        _connectStatus.setText("Connecting…");
        _connectButton.setEnabled(false);
        _cancelButton.setEnabled(true);
    }

    private void disconnect()
    {
        _connector.disconnect();
        _home.setVisible(true);
        _session.setVisible(false);
        _connectButton.setEnabled(true);
        _cancelButton.setEnabled(false);
        _disconnectButton.setEnabled(false);
    }

    protected override void onTick(double deltaSeconds)
    {
        if (!_startupVisibilityApplied)
        {
            _startupVisibilityApplied = true;
            if (_hideAtStartup && _window !is null) _window.setVisible(false);
        }
        if (_window !is null && _minimizeToTray !is null &&
            _minimizeToTray.checked() && _window.isMinimized())
            _window.setVisible(false);
        if (deltaSeconds == deltaSeconds && deltaSeconds > 0)
            _pollSeconds += deltaSeconds;
        if (_pollSeconds < 0.1) return;
        _pollSeconds = 0.0;
        bool hostConnected;
        const hostStatus = _host.status(hostConnected);
        if (hostConnected)
            _hostStatus.setText("Connected. Turn off Allow connections to end access.");
        else if (hostStatus.startsWith("Waiting") ||
            hostStatus.startsWith("Could not") ||
            hostStatus.startsWith("Add "))
            _hostStatus.setText(hostStatus);
        else if (hostStatus == "Remote computer disconnected")
            _hostStatus.setText("Connection ended. Waiting for a new controller.");
        const controllerStatus = _connector.status(_controllerConnected);
        if (controllerStatus.startsWith("ID not found"))
            _connectStatus.setText(controllerStatus);
        else if (controllerStatus.startsWith("Connection failed:"))
            _connectStatus.setText(
                "Could not connect. Check the ID, password, and that the other computer is online.");
        else if (controllerStatus.startsWith("Add an ID server"))
            _connectStatus.setText(controllerStatus);
        else if (!_controllerConnected && controllerStatus == "Remote computer disconnected")
            _connectStatus.setText("The remote computer ended the session.");
        _remoteCanvas.pollFrame();
        const controllerTransfer = _connector.transferStatus();
        if (controllerTransfer != "Idle")
            _transferStatus.setText(controllerTransfer);
        const streamQuality = _connector.streamStatus();
        if (streamQuality != "Idle")
            _streamStatusLabel.setText("Stream: " ~ streamQuality);
        if (_controllerConnected)
        {
            if (!_rememberedCurrentConnection)
            {
                try
                {
                    rememberPeer(strip(_connectId.textUtf8()));
                    _savedPeerButton.setEnabled(loadSavedPeers().length > 0);
                }
                catch (Exception) {}
                _rememberedCurrentConnection = true;
            }
            _home.setVisible(false);
            _session.setVisible(true);
            _connectButton.setEnabled(false);
            _cancelButton.setEnabled(false);
            _disconnectButton.setEnabled(true);
        }
        else if (controllerStatus.startsWith("Connection failed:") ||
            controllerStatus.startsWith("ID not found") ||
            controllerStatus == "Remote computer disconnected" ||
            controllerStatus == "Idle")
        {
            _connectButton.setEnabled(true);
            _cancelButton.setEnabled(false);
            _disconnectButton.setEnabled(false);
        }
        invalidate();
    }

    private bool _controllerConnected;

    void shutdown()
    {
        _connector.disconnect();
        _host.stop();
    }

    bool keepRunningInTray() const
    {
        return _minimizeToTray !is null && _minimizeToTray.checked();
    }

    version (unittest)
    {
        private Rect testingGlobalBounds(Widget widget)
        {
            const origin = widget.globalOrigin();
            const local = widget.bounds();
            return Rect(origin.x, origin.y, local.width, local.height);
        }

        string testingShareId() { return to!string(_shareId.text()); }
        string testingPassword() { return _password; }
        dstring testingHostStatus() { return _hostStatus.text(); }
        dstring testingConnectStatus() { return _connectStatus.text(); }
        string testingEnteredId() { return _connectId.textUtf8(); }
        Rect testingIdFieldBounds() { return testingGlobalBounds(_connectId); }
        Rect testingPasswordFieldBounds() { return testingGlobalBounds(_connectPassword); }
        Rect testingConnectButtonBounds() { return testingGlobalBounds(_connectButton); }
        Rect testingSettingsButtonBounds() { return testingGlobalBounds(_settingsButton); }
        Rect testingDisconnectButtonBounds() { return testingGlobalBounds(_disconnectButton); }
        Rect testingNewPasswordButtonBounds() { return testingGlobalBounds(_newPasswordButton); }
        bool testingHomeVisible() const { return _home.visible(); }
        bool testingSessionVisible() const { return _session.visible(); }
        bool testingSettingsVisible() const { return _advanced.visible(); }
        bool testingConnectEnabled() const { return _connectButton.enabled(); }
        bool testingRemoteFrameReady() const { return _remoteCanvas._image !is null; }
        bool testingPrimaryActionsLaidOut() const
        {
            return _newPasswordButton.bounds().height > 0 &&
                _connectButton.bounds().height > 0 &&
                _settingsButton.bounds().height > 0;
        }
        void testingReplaceEnteredId(string value) { _connectId.setText(value); }
        void testingReplacePassword(string value) { _connectPassword.setText(value); }
    }
}

WindowOptions rustDeskWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora RustDesk";
    options.width = 1040;
    options.height = 740;
    options.resizable = true;
    options.decorated = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    return options;
}

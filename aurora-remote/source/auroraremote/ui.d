module auroraremote.ui;

import aurora;
import aurora.canvas : Canvas;
import aurora.event : Event, Key, MouseButton;
import aurora.image : RgbaImage;
import auroraremote.capsule : deviceIdText;
import auroraremote.capsule : AccessPermission;
import auroraremote.crypto : sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity, loadOrCreatePersistentAccessToken,
    rotatePersistentAccessToken;
import auroraremote.input : keyPressPacket, mouseButtonPacket,
    mouseMovePacket, mouseWheelPacket;
import auroraremote.peers : SavedPeer, loadSavedPeers, rememberPeer;
import auroraremote.settings : RemoteSettings, loadSettings, saveSettings;
import auroraremote.windowsintegration : autostartEnabled, setAutostart;
import std.algorithm.comparison : max, min;
import std.conv : to;
import std.file : thisExePath;
import std.socket : Socket;
import std.string : startsWith, strip;

private string linkMarker(string link)
{
    enum hex = "0123456789ABCDEF";
    const digest = sha256(cast(const(ubyte)[]) link);
    auto result = new char[9];
    foreach (index; 0 .. 4)
    {
        result[index * 2] = hex[digest[index] >> 4];
        result[index * 2 + 1] = hex[digest[index] & 15];
    }
    result[8] = 0;
    return result[0 .. 8].idup;
}

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
    private DirectConnector _connector;
    private RgbaImage _image;
    private uint _revision;
    private Rect _imageRect;

    this(DirectConnector connector)
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
                "The remote desktop will appear here after the encrypted connection is ready."d,
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
        const delta = cast(short) min(short.max,
            max(short.min, event.wheelY));
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

final class RemoteRoot : VBox
{
    private DeviceIdentity _identity;
    private DirectHost _host;
    private DirectConnector _connector;
    private VBox _home;
    private VBox _session;
    private VBox _advanced;
    private VBox _welcome;
    private HBox _columns;
    private Label _linkNotice;
    private TextField _hostField;
    private TextField _portField;
    private TextField _shareCode;
    private TextField _connectCode;
    private Label _hostStatus;
    private Label _connectStatus;
    private Label _incomingNotice;
    private CheckBox _allowConnections;
    private CheckBox _useRelay;
    private TextField _relayHostField;
    private TextField _relayPortField;
    private Button _copyButton;
    private Button _newLinkButton;
    private Button _connectButton;
    private Button _cancelButton;
    private Button _disconnectButton;
    private Button _hostSendButton;
    private Button _hostClipboardButton;
    private Label _transferStatus;
    private Label _streamStatusLabel;
    private RemoteCanvas _remoteCanvas;
    private string _connectionLink;
    private string _initialHost;
    private ushort _initialPort;
    private bool _advancedVisible;
    private GuiWindow _window;
    private CheckBox _minimizeToTray;
    private CheckBox _unattendedAccess;
    private CheckBox _permissionInput;
    private CheckBox _permissionFiles;
    private CheckBox _permissionClipboard;
    private bool _hideAtStartup;
    private bool _startupVisibilityApplied;
    private CheckBox _rememberPeer;
    private Button _savedPeerButton;
    private Button _settingsButton;
    private SavedPeer[] _savedPeers;
    private bool _rememberedCurrentConnection;
    private RemoteSettings _settings;
    private bool _persistConfiguration;
    private double _pollSeconds = 0.0;

    this(DeviceIdentity identity, string initialHost = "",
        ushort initialPort = 47_831, GuiWindow window = null,
        bool hideAtStartup = false)
    {
        super(12, Insets(22));
        _identity = identity;
        _persistConfiguration = initialHost.length == 0;
        _settings = loadSettings();
        if (initialHost.length > 0)
        {
            _settings = RemoteSettings();
            _settings.directHost = initialHost;
            _settings.directPort = initialPort;
        }
        _initialHost = initialHost;
        _initialPort = initialPort;
        _window = window;
        _hideAtStartup = hideAtStartup;
        _host = new DirectHost;
        _connector = new DirectConnector;
        buildUi();
        startHosting();
    }

    private void buildUi()
    {
        // Widgets are assembled before they are attached to the window, so use
        // the application's palette directly instead of the unattached widget's
        // fallback theme.
        const palette = Theme.dark();
        auto heading = add(new HBox(12));
        heading.layoutHints().preferredHeight = 42;
        auto title = heading.add(new Label("Aurora Remote"));
        title.setScale(3);
        title.layoutHints().flex = 1.0;
        auto device = heading.add(new Label("Device " ~
            deviceIdText(_identity.id[])));
        device.setScale(1);

        _home = add(new VBox(14));
        _home.layoutHints().flex = 1.0;

        _welcome = _home.add(new VBox(5));
        _welcome.layoutHints().preferredHeight = 64;
        auto welcomeTitle = _welcome.add(new Label("Choose what you want to do"));
        welcomeTitle.setScale(3);
        auto welcomeText = _welcome.add(new Label(
            "Send your connection link when you want help, or paste someone else's link to control their computer."));
        welcomeText.setScale(1);
        welcomeText.setEllipsis(false);

        _incomingNotice = _home.add(new Label(""));
        _incomingNotice.setScale(1);
        _incomingNotice.setVisible(false);

        _columns = _home.add(new HBox(16));
        _columns.layoutHints().preferredHeight = 380;

        auto share = new VBox(12, Insets(20));
        share.layoutHints().flex = 1.0;
        share.layoutHints().minWidth = 360;
        share.setBackground(palette.panelBackground);
        share.setBorder(palette.border, 1);
        auto shareTitle = share.add(new Label("Let someone control this computer"));
        shareTitle.setScale(2);
        auto shareHint = share.add(new Label(
            "Copy the private link and send it to the person helping you."));
        shareHint.setScale(1);
        shareHint.setEllipsis(false);
        _shareCode = share.add(new TextField());
        _shareCode.setReadOnly(true);
        _shareCode.layoutHints().preferredHeight = 46;
        auto shareActions = share.add(new HBox(8));
        shareActions.layoutHints().preferredHeight = 40;
        _copyButton = shareActions.add(new Button("Copy connection link"));
        _copyButton.onClick = delegate() { copyConnectionLink(); };
        _newLinkButton = shareActions.add(new Button("Create a new link"));
        _newLinkButton.onClick = delegate() { createNewConnectionLink(); };
        shareActions.add(new Spacer());
        auto hostTools = share.add(new HBox(8));
        hostTools.layoutHints().preferredHeight = 40;
        _hostSendButton = hostTools.add(new Button("Send file"));
        _hostSendButton.setEnabled(false);
        _hostSendButton.onClick = delegate() { chooseFile(true); };
        _hostClipboardButton = hostTools.add(new Button("Send clipboard"));
        _hostClipboardButton.setEnabled(false);
        _hostClipboardButton.onClick = delegate() { _host.sendClipboard(); };
        hostTools.add(new Spacer());
        _allowConnections = share.add(new CheckBox(
            "Allow connections while Aurora Remote is open", true));
        _allowConnections.onChanged = delegate(bool enabled)
        {
            if (enabled) startHosting();
            else stopHosting();
        };
        _hostStatus = share.add(new Label("Preparing your connection link…"));
        _hostStatus.setScale(1);
        _hostStatus.setEllipsis(false);
        _columns.add(share);

        auto control = new VBox(12, Insets(20));
        control.layoutHints().flex = 1.0;
        control.layoutHints().minWidth = 360;
        control.setBackground(palette.panelBackground);
        control.setBorder(palette.border, 1);
        auto controlTitle = control.add(new Label("Control another computer"));
        controlTitle.setScale(2);
        auto controlHint = control.add(new Label(
            "Paste the private link sent by the other person."));
        controlHint.setScale(1);
        controlHint.setEllipsis(false);
        control.add(new Label("PASTE CONNECTION LINK"));
        _connectCode = control.add(new TextField());
        _connectCode.layoutHints().preferredHeight = 46;
        auto actions = control.add(new HBox(8));
        actions.layoutHints().preferredHeight = 40;
        _connectButton = actions.add(new Button("Connect"));
        _connectButton.onClick = delegate() { connect(); };
        _cancelButton = actions.add(new Button("Cancel"));
        _cancelButton.setEnabled(false);
        _cancelButton.onClick = delegate() { disconnect(); };
        _savedPeerButton = actions.add(new Button("Use saved computer"));
        _savedPeers = loadSavedPeers();
        _savedPeerButton.setEnabled(_savedPeers.length > 0);
        _savedPeerButton.onClick = delegate()
        {
            _savedPeers = loadSavedPeers();
            if (_savedPeers.length == 0) return;
            _connectCode.setText(_savedPeers[0].link);
            _connectStatus.setText("Saved computer " ~
                _savedPeers[0].device ~ " is ready to connect.");
        };
        actions.add(new Spacer());
        _rememberPeer = control.add(new CheckBox(
            "Remember this computer after connecting", true));
        _connectStatus = control.add(new Label(
            "Paste a link when you are ready."));
        _connectStatus.setScale(1);
        _connectStatus.setEllipsis(false);
        _columns.add(control);

        _linkNotice = _home.add(new Label(
            "Connection links contain the address, transport, expiry, and encryption secret needed by the other computer."));
        _linkNotice.setScale(1);
        _linkNotice.setEllipsis(false);
        auto settingsRow = _home.add(new HBox(8));
        settingsRow.layoutHints().preferredHeight = 38;
        _settingsButton = settingsRow.add(new Button("Connection settings"));
        settingsRow.add(new Spacer());
        _settingsButton.onClick = delegate()
        {
            _advancedVisible = !_advancedVisible;
            _advanced.setVisible(_advancedVisible);
            _welcome.setVisible(!_advancedVisible);
            _columns.setVisible(!_advancedVisible);
            _linkNotice.setVisible(!_advancedVisible);
            _settingsButton.setText(_advancedVisible ?
                "Back to connection" : "Connection settings");
        };
        _advanced = _home.add(new VBox(8, Insets(14)));
        _advanced.layoutHints().flex = 1.0;
        _advanced.setBackground(palette.panelElevated);
        _advanced.setBorder(palette.border, 1);
        _advanced.setVisible(false);
        auto directHint = _advanced.add(new Label(
            "Use a direct connection on a LAN or forwarded port. Use a relay when neither computer accepts incoming Internet connections."));
        directHint.setScale(1);
        directHint.setEllipsis(false);
        auto endpoint = _advanced.add(new HBox(8));
        endpoint.layoutHints().preferredHeight = 40;
        endpoint.add(new Label("Address other computer can reach"));
        _hostField = endpoint.add(new TextField());
        _hostField.layoutHints().flex = 1.0;
        string hostName = _initialHost.length > 0 ? _initialHost :
            _settings.directHost;
        if (hostName.length == 0)
        {
            hostName = "127.0.0.1";
            try hostName = Socket.hostName; catch (Exception) {}
        }
        _hostField.setText(hostName);
        endpoint.add(new Label("Port"));
        const initialPort = _initialHost.length > 0 ? _initialPort :
            (_settings.directPort != 0 ? _settings.directPort : _initialPort);
        _portField = endpoint.add(new TextField(to!string(initialPort)));
        _portField.layoutHints().preferredWidth = 92;
        auto applyEndpoint = endpoint.add(new Button("Apply"));
        applyEndpoint.onClick = delegate() { renewConnectionLink(); };
        auto relayEndpoint = _advanced.add(new HBox(8));
        relayEndpoint.layoutHints().preferredHeight = 40;
        _useRelay = relayEndpoint.add(new CheckBox("Use relay", _settings.useRelay));
        _useRelay.onChanged = delegate(bool) { renewConnectionLink(); };
        relayEndpoint.add(new Label("Relay address"));
        _relayHostField = relayEndpoint.add(new TextField(_settings.relayHost));
        _relayHostField.layoutHints().flex = 1.0;
        _relayHostField.setPlaceholder("relay.example.com");
        relayEndpoint.add(new Label("Port"));
        _relayPortField = relayEndpoint.add(new TextField(
            to!string(_settings.relayPort != 0 ? _settings.relayPort : 47_832)));
        _relayPortField.layoutHints().preferredWidth = 92;
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
        auto unattendedRow = _advanced.add(new HBox(10));
        unattendedRow.layoutHints().preferredHeight = 36;
        _unattendedAccess = unattendedRow.add(new CheckBox(
            "Permanent unattended key", _settings.unattended));
        _unattendedAccess.onChanged = delegate(bool) { renewConnectionLink(); };
        unattendedRow.add(new Spacer());
        auto rotateKey = unattendedRow.add(new Button("Rotate key"));
        rotateKey.onClick = delegate()
        {
            rotatePersistentAccessToken();
            if (!_unattendedAccess.checked())
                _unattendedAccess.setChecked(true, false);
            startHosting();
        };
        auto permissionsRow = _advanced.add(new HBox(10));
        permissionsRow.layoutHints().preferredHeight = 36;
        permissionsRow.add(new Label("Permissions for this key"));
        _permissionInput = permissionsRow.add(new CheckBox("Allow control",
            (_settings.permissions & AccessPermission.input) != 0));
        _permissionInput.onChanged = delegate(bool) { renewConnectionLink(); };
        _permissionFiles = permissionsRow.add(new CheckBox("Allow files",
            (_settings.permissions & AccessPermission.files) != 0));
        _permissionFiles.onChanged = delegate(bool) { renewConnectionLink(); };
        _permissionClipboard = permissionsRow.add(new CheckBox(
            "Allow clipboard",
            (_settings.permissions & AccessPermission.clipboard) != 0));
        _permissionClipboard.onChanged = delegate(bool) { renewConnectionLink(); };
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

    private void startHosting(bool userCreatedNewLink = false)
    {
        const persistent = _unattendedAccess !is null &&
            _unattendedAccess.checked();
        uint permissions = AccessPermission.view;
        if (_permissionInput is null || _permissionInput.checked())
            permissions |= AccessPermission.input;
        if (_permissionFiles is null || _permissionFiles.checked())
            permissions |= AccessPermission.files;
        if (_permissionClipboard is null || _permissionClipboard.checked())
            permissions |= AccessPermission.clipboard;
        persistSettings(permissions);
        ubyte[32] persistentToken;
        if (persistent)
        {
            try persistentToken = loadOrCreatePersistentAccessToken();
            catch (Exception error)
            {
                _hostStatus.setText("Could not load unattended key: " ~ error.msg);
                return;
            }
        }
        if (_useRelay !is null && _useRelay.checked())
        {
            ushort relayPort;
            try relayPort = to!ushort(strip(_relayPortField.textUtf8()));
            catch (Exception)
            {
                _hostStatus.setText("Enter a valid relay port from 1 to 65535.");
                return;
            }
            const relayHost = strip(_relayHostField.textUtf8());
            if (relayHost.length == 0 || relayPort == 0)
            {
                _hostStatus.setText("Enter the public relay address and port.");
                return;
            }
            try
            {
                _connectionLink = _host.startRelay(_identity, relayHost,
                    relayPort, persistent, persistentToken[], permissions);
                const marker = linkMarker(_connectionLink);
                _shareCode.setReadOnly(false);
                _shareCode.setText((persistent ?
                    "Permanent relay key " : "Relay link ") ~ marker ~
                    (persistent ? "" : " — expires in 10 min"));
                _shareCode.setReadOnly(true);
                _copyButton.setEnabled(true);
                _newLinkButton.setEnabled(true);
                _hostStatus.setText(userCreatedNewLink ?
                    "New link " ~ marker ~
                        " created. The previous link is revoked." :
                    "Ready through relay. The relay cannot decrypt this session.");
            }
            catch (Exception error)
            {
                _copyButton.setEnabled(false);
                _hostStatus.setText("Could not start the relayed session: " ~
                    error.msg);
            }
            return;
        }
        ushort port;
        try port = to!ushort(strip(_portField.textUtf8()));
        catch (Exception)
        {
            _hostStatus.setText("Enter a valid port from 1 to 65535.");
            return;
        }
        const host = strip(_hostField.textUtf8());
        if (host.length == 0)
        {
            _hostStatus.setText("Enter an address to advertise.");
            return;
        }
        try
        {
            const code = _host.start(_identity, host, port, persistent,
                persistentToken[], permissions);
            _connectionLink = code;
            const marker = linkMarker(_connectionLink);
            _shareCode.setReadOnly(false);
            _shareCode.setText((persistent ?
                "Permanent key " : "Link ") ~ marker ~
                (persistent ? "" : " — expires in 10 min"));
            _shareCode.setReadOnly(true);
            _copyButton.setEnabled(true);
            _newLinkButton.setEnabled(true);
            _hostStatus.setText(userCreatedNewLink ?
                "New link " ~ marker ~
                    " created. The previous link is revoked." :
                (persistent ?
                    "Unattended access is active. Rotate the key to revoke saved copies." :
                    "Ready. Only someone with this link can connect."));
        }
        catch (Exception error)
        {
            _copyButton.setEnabled(false);
            _hostStatus.setText(
                "This computer is not available yet. Open connection settings and check the address or port. " ~
                error.msg);
        }
    }

    private void persistSettings(uint permissions = uint.max)
    {
        if (!_persistConfiguration) return;
        if (_hostField is null || _portField is null ||
            _relayHostField is null || _relayPortField is null) return;
        _settings.directHost = strip(_hostField.textUtf8());
        try _settings.directPort = to!ushort(strip(_portField.textUtf8()));
        catch (Exception) {}
        _settings.useRelay = _useRelay.checked();
        _settings.relayHost = strip(_relayHostField.textUtf8());
        try _settings.relayPort = to!ushort(strip(_relayPortField.textUtf8()));
        catch (Exception) {}
        _settings.unattended = _unattendedAccess.checked();
        if (permissions != uint.max) _settings.permissions = permissions;
        _settings.keepRunningInTray = _minimizeToTray.checked();
        try saveSettings(_settings);
        catch (Exception) {}
    }

    private void stopHosting()
    {
        _host.stop();
        _connectionLink = null;
        _shareCode.setReadOnly(false);
        _shareCode.setText("");
        _shareCode.setReadOnly(true);
        _copyButton.setEnabled(false);
        _hostStatus.setText("Connections are turned off.");
    }

    private void renewConnectionLink()
    {
        if (!_allowConnections.checked())
            _allowConnections.setChecked(true, false);
        startHosting();
    }

    private void createNewConnectionLink()
    {
        if (_unattendedAccess !is null && _unattendedAccess.checked())
        {
            try rotatePersistentAccessToken();
            catch (Exception error)
            {
                _hostStatus.setText("Could not replace the permanent key: " ~
                    error.msg);
                return;
            }
        }
        if (!_allowConnections.checked())
            _allowConnections.setChecked(true, false);
        startHosting(true);
    }

    private void copyConnectionLink()
    {
        if (_connectionLink.length == 0) return;
        version (Windows)
        {
            if (copyTextToClipboard(_connectionLink))
                _hostStatus.setText(
                    "Copied. Send the link to the person you want to connect.");
            else
                _hostStatus.setText("Windows could not access the clipboard. Try again.");
        }
        else
            _hostStatus.setText("Clipboard copy is available in the Windows build.");
    }

    private void connect()
    {
        const code = strip(_connectCode.textUtf8());
        if (code.length == 0)
        {
            _connectStatus.setText("Paste the other computer's connection link first.");
            return;
        }
        _connector.connect(code);
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
        bool controllerConnected;
        const hostStatus = _host.status(hostConnected);
        if (hostConnected)
        {
            _incomingNotice.setText(
                "This computer is currently being viewed and controlled.");
            _incomingNotice.setVisible(true);
            _hostStatus.setText("Connected. Turn off Allow connections to end access.");
            _hostSendButton.setEnabled(true);
            _hostClipboardButton.setEnabled(true);
        }
        else
        {
            _incomingNotice.setVisible(false);
            _hostSendButton.setEnabled(false);
            _hostClipboardButton.setEnabled(false);
            if (hostStatus.startsWith("Direct host stopped:") ||
                hostStatus == "Remote computer disconnected")
                _hostStatus.setText("Connection ended. Create a new link for another session.");
        }
        const connectorStatus = _connector.status(controllerConnected);
        if (connectorStatus.startsWith("Connection failed:"))
            _connectStatus.setText("Could not connect. Check that the other computer is online and the link has not expired.");
        else if (connectorStatus.startsWith("Connection code rejected:"))
            _connectStatus.setText("That connection link is invalid or has expired. Ask for a new link.");
        else if (!controllerConnected && connectorStatus == "Remote computer disconnected")
            _connectStatus.setText("The remote computer ended the session.");
        _remoteCanvas.pollFrame();
        const controllerTransfer = _connector.transferStatus();
        if (controllerTransfer != "Idle")
            _transferStatus.setText(controllerTransfer);
        const streamQuality = _connector.streamStatus();
        if (streamQuality != "Idle")
            _streamStatusLabel.setText("Stream: " ~ streamQuality);
        const hostTransfer = _host.transferStatus();
        if (hostConnected && hostTransfer != "Idle")
            _hostStatus.setText(hostTransfer);
        if (controllerConnected)
        {
            if (!_rememberedCurrentConnection && _rememberPeer.checked())
            {
                try
                {
                    rememberPeer(strip(_connectCode.textUtf8()));
                    _savedPeers = loadSavedPeers();
                    _savedPeerButton.setEnabled(_savedPeers.length > 0);
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
        else if (connectorStatus.startsWith("Connection failed:") ||
            connectorStatus.startsWith("Connection code rejected:") ||
            connectorStatus == "Remote computer disconnected" ||
            connectorStatus == "Idle")
        {
            _connectButton.setEnabled(true);
            _cancelButton.setEnabled(false);
            _disconnectButton.setEnabled(false);
        }
        invalidate();
    }

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

        string testingConnectionLink() const { return _connectionLink; }
        string testingShareText() { return _shareCode.textUtf8(); }
        dstring testingHostStatus() { return _hostStatus.text(); }
        string testingEnteredLink() { return _connectCode.textUtf8(); }
        dstring testingConnectStatus() { return _connectStatus.text(); }
        Rect testingConnectFieldBounds() { return testingGlobalBounds(_connectCode); }
        Rect testingConnectButtonBounds() { return testingGlobalBounds(_connectButton); }
        Rect testingNewLinkButtonBounds() { return testingGlobalBounds(_newLinkButton); }
        Rect testingSettingsButtonBounds() { return testingGlobalBounds(_settingsButton); }
        Rect testingDisconnectButtonBounds() { return testingGlobalBounds(_disconnectButton); }
        bool testingHomeVisible() const { return _home.visible(); }
        bool testingSessionVisible() const { return _session.visible(); }
        bool testingSettingsVisible() const { return _advanced.visible(); }
        bool testingConnectEnabled() const { return _connectButton.enabled(); }
        bool testingRemoteFrameReady() const { return _remoteCanvas._image !is null; }
        bool testingPrimaryActionsLaidOut() const
        {
            return _copyButton.bounds().height > 0 &&
                _newLinkButton.bounds().height > 0 &&
                _connectButton.bounds().height > 0;
        }
        void testingReplaceEnteredLink(string value)
        {
            _connectCode.setText(value);
        }
    }
}

WindowOptions remoteWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora Remote";
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

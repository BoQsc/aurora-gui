module aurorarustdesk.session;

import aurorarustdesk.clipboard : readClipboardText, writeClipboardText;
import aurorarustdesk.desktop : DesktopCapturer;
import aurorarustdesk.framecodec : DeltaFrameDecoder, DeltaFrameEncoder;
import aurorarustdesk.identity : DeviceIdentity, passwordToken;
import aurorarustdesk.input : applyRemoteInput;
import aurorarustdesk.protocol : ControlMessage, ProtocolChannel,
    SecureConnection, acceptClient, establishClient;
import aurorarustdesk.quality : AdaptiveQuality;
import aurorarustdesk.relay : RelayRole, joinRelay;
import aurorarustdesk.rendezvous : RendezvousPeer, RendezvousRegistration,
    lookupPeer, registerHost;
import aurorarustdesk.settings : AccessPermission;
import aurorarustdesk.transfer : FileReceiver, defaultReceiveFolder,
    sendTransferPaths = sendPaths;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : lastIndexOf;

alias RemoteInputHandler = void delegate(const(ubyte)[] packet);
alias ClipboardReader = string delegate();
alias ClipboardWriter = void delegate(string value);

private void tuneInteractiveSocket(Socket socket)
{
    try socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
    catch (Exception) {}
    try socket.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, true);
    catch (Exception) {}
}

private string localHostName()
{
    try return Socket.hostName;
    catch (Exception) return "127.0.0.1";
}

private final class SharedStatus
{
    Mutex mutex;
    string text = "Idle";
    bool connected;

    this() { mutex = new Mutex; }

    void set(string value, bool isConnected = false)
    {
        synchronized (mutex)
        {
            text = value;
            connected = isConnected;
        }
    }

    string snapshot(out bool isConnected)
    {
        synchronized (mutex)
        {
            isConnected = connected;
            return text;
        }
    }
}

private final class SharedFrame
{
    Mutex mutex;
    int width;
    int height;
    uint revision;
    ubyte[] rgba;

    this() { mutex = new Mutex; }

    void publish(int frameWidth, int frameHeight, const(ubyte)[] pixels)
    {
        synchronized (mutex)
        {
            width = frameWidth;
            height = frameHeight;
            rgba = pixels.dup;
            ++revision;
            if (revision == 0) revision = 1;
        }
    }

    bool snapshot(ref uint knownRevision, out int frameWidth,
        out int frameHeight, out ubyte[] pixels)
    {
        synchronized (mutex)
        {
            if (revision == 0 || revision == knownRevision) return false;
            knownRevision = revision;
            frameWidth = width;
            frameHeight = height;
            pixels = rgba.dup;
            return true;
        }
    }
}

// The host side of a session: it advertises a numeric ID through the
// rendezvous server (or a direct endpoint when no server is set) and serves the
// first controller that proves possession of the current password.
final class RustDeskHost
{
    private Mutex _lifecycle;
    private SharedStatus _status;
    private Socket _listener;
    private Socket _client;
    private RendezvousRegistration _registration;
    private SecureConnection _secure;
    private Thread _worker;
    private string _numericId;
    private string _endpoint;
    private ubyte[] _passwordToken;
    private const(ubyte)[] _context;
    private uint _permissions = AccessPermission.all;
    private RemoteInputHandler _inputHandler;
    private FileReceiver _fileReceiver;
    private SharedStatus _transferStatus;
    private SharedStatus _streamStatus;
    private ClipboardReader _clipboardReader;
    private ClipboardWriter _clipboardWriter;

    this(RemoteInputHandler inputHandler = null, string receiveFolder = "",
        ClipboardReader clipboardReader = null,
        ClipboardWriter clipboardWriter = null)
    {
        _lifecycle = new Mutex;
        _status = new SharedStatus;
        _transferStatus = new SharedStatus;
        _streamStatus = new SharedStatus;
        _inputHandler = inputHandler;
        _fileReceiver = new FileReceiver(receiveFolder.length > 0 ?
            receiveFolder : defaultReceiveFolder());
        _clipboardReader = clipboardReader;
        _clipboardWriter = clipboardWriter;
    }

    // Direct endpoint mode, used on a LAN or loopback when no ID server is set.
    string startDirect(DeviceIdentity identity, ushort directPort,
        string password, uint permissions = AccessPermission.all)
    {
        stop();
        prepare(identity, password, permissions);
        _listener = new TcpSocket(AddressFamily.INET);
        _listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        _listener.bind(new InternetAddress("0.0.0.0", directPort));
        _listener.listen(4);
        const boundPort = (cast(InternetAddress) _listener.localAddress).port;
        _endpoint = identity.numericId ~ "@" ~ localHostName() ~ ":" ~
            to!string(boundPort);
        _status.set("Waiting for a direct connection on port " ~
            to!string(boundPort));
        _worker = new Thread(&runDirectHost);
        _worker.isDaemon = true;
        _worker.start();
        return _endpoint;
    }

    // ID-server mode: register the numeric ID, then wait for a controller.
    void startRendezvous(DeviceIdentity identity, string serverHost,
        ushort serverPort, ushort directPort, string password, bool wantRelay,
        uint permissions = AccessPermission.all)
    {
        stop();
        prepare(identity, password, permissions);
        if (serverHost.length == 0)
        {
            _status.set("Add an ID server address in Settings to share this computer.");
            return;
        }
        if (wantRelay)
        {
            try
            {
                _registration = registerHost(serverHost, serverPort,
                    identity.numericId, 0, true);
            }
            catch (Exception error)
            {
                _status.set("Could not reach the ID server: " ~ error.msg);
                return;
            }
            _endpoint = identity.numericId;
            _status.set("Waiting through the relay (ID " ~ identity.numericId ~ ")");
            const relayPort = _registration.relayPort;
            const relayKey = _registration.relayKey;
            _worker = new Thread({ runRelayHost(serverHost, relayPort,
                relayKey[]); });
            _worker.isDaemon = true;
            _worker.start();
            return;
        }
        _listener = new TcpSocket(AddressFamily.INET);
        _listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        _listener.bind(new InternetAddress("0.0.0.0", directPort));
        _listener.listen(4);
        const boundPort = (cast(InternetAddress) _listener.localAddress).port;
        try
        {
            _registration = registerHost(serverHost, serverPort,
                identity.numericId, boundPort, false);
        }
        catch (Exception error)
        {
            try _listener.close(); catch (Exception) {}
            _listener = null;
            _status.set("Could not reach the ID server: " ~ error.msg);
            return;
        }
        _endpoint = identity.numericId ~ "@" ~ localHostName() ~ ":" ~
            to!string(boundPort);
        _status.set("Waiting for a controller (ID " ~ identity.numericId ~ ")");
        _worker = new Thread(&runDirectHost);
        _worker.isDaemon = true;
        _worker.start();
    }

    private void prepare(DeviceIdentity identity, string password,
        uint permissions)
    {
        _numericId = identity.numericId;
        _passwordToken = passwordToken(password);
        _context = cast(const(ubyte)[]) identity.numericId;
        _permissions = permissions;
    }

    private void runDirectHost()
    {
        try
        {
            while (true)
            {
                Socket listener;
                synchronized (_lifecycle) listener = _listener;
                if (listener is null) break;
                Socket client;
                try client = listener.accept();
                catch (Exception) break;
                tuneInteractiveSocket(client);
                synchronized (_lifecycle) _client = client;
                serve(client, "Direct encrypted connection established");
                _status.set("Remote computer disconnected");
            }
        }
        catch (Exception error)
        {
            _status.set("Host stopped: " ~ error.msg);
        }
        closeSession();
    }

    private void runRelayHost(string serverHost, ushort relayPort,
        const(ubyte)[] relayKey)
    {
        try
        {
            auto socket = new TcpSocket(AddressFamily.INET);
            tuneInteractiveSocket(socket);
            synchronized (_lifecycle) _client = socket;
            socket.connect(new InternetAddress(serverHost, relayPort));
            joinRelay(socket, RelayRole.host, relayKey);
            serve(socket, "End-to-end encrypted relay connection established");
            _status.set("Remote computer disconnected");
        }
        catch (Exception error)
        {
            _status.set("Relay host stopped: " ~ error.msg);
        }
        closeSession();
    }

    private void serve(Socket client, string connectedStatus)
    {
        Thread captureWorker;
        try
        {
            auto session = acceptClient(client, _passwordToken, _context);
            synchronized (_lifecycle) _secure = session;
            _status.set(connectedStatus, true);
            const readiness = session.receive();
            if (readiness.channel != ProtocolChannel.control ||
                readiness.kind != ControlMessage.ping)
                throw new Exception("Controller skipped the readiness handshake.");
            session.send(ProtocolChannel.control, ControlMessage.pong,
                readiness.payload);
            if ((_permissions & AccessPermission.view) != 0)
            {
                captureWorker = new Thread({ streamDesktop(session); });
                captureWorker.isDaemon = true;
                captureWorker.start();
            }
            while (true)
            {
                const message = session.receive();
                if (message.channel == ProtocolChannel.input)
                {
                    if ((_permissions & AccessPermission.input) == 0) continue;
                    if (_inputHandler !is null) _inputHandler(message.payload);
                    else applyRemoteInput(message.payload);
                    continue;
                }
                if (message.channel == ProtocolChannel.file)
                {
                    if ((_permissions & AccessPermission.files) == 0) continue;
                    _fileReceiver.process(message.kind, message.payload);
                    _transferStatus.set(_fileReceiver.status());
                    continue;
                }
                if (message.channel == ProtocolChannel.clipboard)
                {
                    if ((_permissions & AccessPermission.clipboard) == 0) continue;
                    const text = cast(string) message.payload.idup;
                    if (_clipboardWriter !is null) _clipboardWriter(text);
                    else writeClipboardText(text);
                    _transferStatus.set("Received remote clipboard text");
                    continue;
                }
                if (message.channel != ProtocolChannel.control) continue;
                if (message.kind == ControlMessage.ping)
                    session.send(ProtocolChannel.control, ControlMessage.pong,
                        message.payload);
                else if (message.kind == ControlMessage.disconnect) break;
                else if (message.kind == ControlMessage.clipboardRequest)
                {
                    if ((_permissions & AccessPermission.clipboard) == 0) continue;
                    const text = _clipboardReader !is null ?
                        _clipboardReader() : readClipboardText();
                    if (text.length <= 1024 * 1024)
                        session.send(ProtocolChannel.clipboard, 1,
                            cast(const(ubyte)[]) text);
                }
            }
        }
        catch (Exception) {}
        closeSession();
        if (captureWorker !is null)
        {
            try captureWorker.join();
            catch (Exception) {}
        }
    }

    private void streamDesktop(SecureConnection session)
    {
        try
        {
            auto quality = new AdaptiveQuality;
            auto profile = quality.profile();
            auto capturer = new DesktopCapturer(profile.width, profile.height);
            auto encoder = new DeltaFrameEncoder;
            ubyte[] previous;
            _streamStatus.set(profile.label);
            session.send(ProtocolChannel.telemetry, 1,
                cast(const(ubyte)[]) profile.label);
            while (true)
            {
                const rgba = capturer.capture();
                if (rgba.length > 0 && rgba != previous)
                {
                    const packet = encoder.encode(rgba, capturer.width,
                        capturer.height);
                    auto watch = StopWatch(AutoStart.yes);
                    session.send(ProtocolChannel.video, 1, packet);
                    const sendMs = watch.peek.total!"msecs";
                    previous = rgba.dup;
                    if (quality.observe(sendMs, packet.length))
                    {
                        profile = quality.profile();
                        capturer = new DesktopCapturer(profile.width,
                            profile.height);
                        encoder = new DeltaFrameEncoder;
                        previous = null;
                        _streamStatus.set(profile.label ~
                            " — adapting to connection");
                        session.send(ProtocolChannel.telemetry, 1,
                            cast(const(ubyte)[]) profile.label);
                    }
                }
                Thread.sleep(profile.intervalMs.msecs);
            }
        }
        catch (Exception error)
        {
            _status.set("Desktop stream stopped: " ~ error.msg);
            session.close();
        }
    }

    string status(out bool connected) { return _status.snapshot(connected); }
    string endpoint() const { return _endpoint; }
    string numericId() const { return _numericId; }

    void sendPaths(const(string)[] paths)
    {
        auto session = _secure;
        if (session is null || paths.length == 0) return;
        auto copied = paths.dup;
        auto worker = new Thread({
            try sendTransferPaths(session, copied,
                delegate(string value) { _transferStatus.set(value); });
            catch (Exception error)
                _transferStatus.set("Transfer failed: " ~ error.msg);
        });
        worker.isDaemon = true;
        worker.start();
    }

    string transferStatus()
    {
        bool ignored;
        return _transferStatus.snapshot(ignored);
    }

    string streamStatus()
    {
        bool ignored;
        return _streamStatus.snapshot(ignored);
    }

    void sendClipboard()
    {
        auto session = _secure;
        if (session is null) return;
        try
        {
            const text = _clipboardReader !is null ?
                _clipboardReader() : readClipboardText();
            if (text.length > 1024 * 1024)
                throw new Exception("Clipboard text exceeds 1 MiB.");
            session.send(ProtocolChannel.clipboard, 1,
                cast(const(ubyte)[]) text);
            _transferStatus.set("Clipboard text sent");
        }
        catch (Exception error)
            _transferStatus.set("Clipboard failed: " ~ error.msg);
    }

    void stop()
    {
        closeSession();
        Socket listener;
        Socket registration;
        synchronized (_lifecycle)
        {
            listener = _listener;
            _listener = null;
            registration = _registration.socket;
            _registration = RendezvousRegistration.init;
        }
        if (listener !is null)
            try listener.close(); catch (Exception) {}
        if (registration !is null)
            try registration.close(); catch (Exception) {}
        auto worker = _worker;
        _worker = null;
        if (worker !is null)
            try worker.join(); catch (Exception) {}
        _status.set("Idle");
        _endpoint = "";
    }

    private void closeSession()
    {
        SecureConnection secure;
        Socket client;
        synchronized (_lifecycle)
        {
            secure = _secure;
            _secure = null;
            client = _client;
            _client = null;
        }
        if (secure !is null) secure.close();
        else if (client !is null)
            try client.close(); catch (Exception) {}
    }
}

// The controller side: resolve the target ID through the rendezvous server (or
// dial a direct endpoint), prove the password, and render the remote desktop.
final class RustDeskController
{
    private Mutex _lifecycle;
    private SharedStatus _status;
    private Thread _worker;
    private Socket _socket;
    private SecureConnection _secure;
    private SharedFrame _frame;
    private FileReceiver _fileReceiver;
    private SharedStatus _transferStatus;
    private SharedStatus _streamStatus;
    private ClipboardReader _clipboardReader;
    private ClipboardWriter _clipboardWriter;

    this(string receiveFolder = "", ClipboardReader clipboardReader = null,
        ClipboardWriter clipboardWriter = null)
    {
        _lifecycle = new Mutex;
        _status = new SharedStatus;
        _frame = new SharedFrame;
        _transferStatus = new SharedStatus;
        _streamStatus = new SharedStatus;
        _fileReceiver = new FileReceiver(receiveFolder.length > 0 ?
            receiveFolder : defaultReceiveFolder());
        _clipboardReader = clipboardReader;
        _clipboardWriter = clipboardWriter;
    }

    void connect(string serverHost, ushort serverPort, string id,
        string password)
    {
        disconnect();
        if (serverHost.length == 0)
        {
            _status.set("Add an ID server address in Settings first.");
            return;
        }
        _status.set("Looking up computer " ~ id ~ "…");
        _worker = new Thread({ runRendezvous(serverHost, serverPort, id,
            password); });
        _worker.isDaemon = true;
        _worker.start();
    }

    void connectDirect(string endpoint, string password)
    {
        disconnect();
        const separator = lastIndexOf(endpoint, ":");
        if (separator <= 0)
        {
            _status.set("Enter an endpoint such as 192.168.0.10:21118.");
            return;
        }
        string host = endpoint[0 .. separator];
        ushort port;
        try port = to!ushort(endpoint[separator + 1 .. $]);
        catch (Exception)
        {
            _status.set("Enter an endpoint such as 192.168.0.10:21118.");
            return;
        }
        if (port == 0)
        {
            _status.set("Enter an endpoint such as 192.168.0.10:21118.");
            return;
        }
        _status.set("Connecting directly to " ~ endpoint ~ "…");
        _worker = new Thread({ runDirect(host, port, password); });
        _worker.isDaemon = true;
        _worker.start();
    }

    private void runRendezvous(string serverHost, ushort serverPort, string id,
        string password)
    {
        try
        {
            RendezvousPeer peer;
            if (!lookupPeer(serverHost, serverPort, id, peer))
            {
                _status.set("ID not found. Check the number and that the " ~
                    "other computer is online on this ID server.");
                return;
            }
            Socket socket;
            if (peer.relay)
            {
                socket = new TcpSocket(AddressFamily.INET);
                tuneInteractiveSocket(socket);
                socket.connect(new InternetAddress(serverHost, peer.relayPort));
                joinRelay(socket, RelayRole.controller, peer.relayKey[]);
            }
            else
            {
                socket = new TcpSocket(AddressFamily.INET);
                tuneInteractiveSocket(socket);
                socket.connect(new InternetAddress(peer.address, peer.directPort));
            }
            synchronized (_lifecycle) _socket = socket;
            _status.set("Authenticating with " ~ id ~ "…");
            auto session = establishClient(socket, passwordToken(password),
                cast(const(ubyte)[]) id);
            runSession(session, peer.relay);
        }
        catch (Exception error)
        {
            _status.set("Connection failed: " ~ error.msg);
            cleanup();
        }
    }

    private void runDirect(string host, ushort port, string password)
    {
        try
        {
            auto socket = new TcpSocket(AddressFamily.INET);
            tuneInteractiveSocket(socket);
            socket.connect(new InternetAddress(host, port));
            synchronized (_lifecycle) _socket = socket;
            _status.set("Authenticating with " ~ host ~ "…");
            auto session = establishClient(socket, passwordToken(password));
            runSession(session, false);
        }
        catch (Exception error)
        {
            _status.set("Connection failed: " ~ error.msg);
            cleanup();
        }
    }

    private void runSession(SecureConnection session, bool relayed)
    {
        _secure = session;
        const ping = cast(const(ubyte)[]) "aurora-rustdesk-ready";
        session.send(ProtocolChannel.control, ControlMessage.ping, ping);
        const reply = session.receive();
        if (reply.channel != ProtocolChannel.control ||
            reply.kind != ControlMessage.pong || reply.payload != ping)
            throw new Exception("Host returned an invalid readiness reply.");
        _status.set(relayed ?
            "End-to-end encrypted relay connection established" :
            "Direct encrypted connection established", true);
        auto decoder = new DeltaFrameDecoder;
        while (true)
        {
            const message = session.receive();
            if (message.channel == ProtocolChannel.video && message.kind == 1)
            {
                const frame = decoder.decode(message.payload);
                _frame.publish(frame.width, frame.height, frame.rgba);
            }
            else if (message.channel == ProtocolChannel.file)
            {
                _fileReceiver.process(message.kind, message.payload);
                _transferStatus.set(_fileReceiver.status());
            }
            else if (message.channel == ProtocolChannel.clipboard)
            {
                const text = cast(string) message.payload.idup;
                if (_clipboardWriter !is null) _clipboardWriter(text);
                else writeClipboardText(text);
                _transferStatus.set("Received remote clipboard text");
            }
            else if (message.channel == ProtocolChannel.telemetry &&
                message.kind == 1)
                _streamStatus.set(cast(string) message.payload.idup);
            else if (message.channel == ProtocolChannel.control &&
                message.kind == ControlMessage.disconnect)
                break;
        }
        _status.set("Remote computer disconnected");
        cleanup();
    }

    string status(out bool connected) { return _status.snapshot(connected); }

    bool frameSnapshot(ref uint revision, out int width, out int height,
        out ubyte[] rgba)
    {
        return _frame.snapshot(revision, width, height, rgba);
    }

    void sendInput(const(ubyte)[] packet)
    {
        auto session = _secure;
        if (session is null || packet.length == 0) return;
        try session.send(ProtocolChannel.input, 1, packet);
        catch (Exception error) _status.set("Input send failed: " ~ error.msg);
    }

    void sendPaths(const(string)[] paths)
    {
        auto session = _secure;
        if (session is null || paths.length == 0) return;
        auto copied = paths.dup;
        auto worker = new Thread({
            try sendTransferPaths(session, copied,
                delegate(string value) { _transferStatus.set(value); });
            catch (Exception error)
                _transferStatus.set("Transfer failed: " ~ error.msg);
        });
        worker.isDaemon = true;
        worker.start();
    }

    string transferStatus()
    {
        bool ignored;
        return _transferStatus.snapshot(ignored);
    }

    string streamStatus()
    {
        bool ignored;
        return _streamStatus.snapshot(ignored);
    }

    void sendClipboard()
    {
        auto session = _secure;
        if (session is null) return;
        try
        {
            const text = _clipboardReader !is null ?
                _clipboardReader() : readClipboardText();
            if (text.length > 1024 * 1024)
                throw new Exception("Clipboard text exceeds 1 MiB.");
            session.send(ProtocolChannel.clipboard, 1,
                cast(const(ubyte)[]) text);
            _transferStatus.set("Clipboard text sent");
        }
        catch (Exception error)
            _transferStatus.set("Clipboard failed: " ~ error.msg);
    }

    void requestClipboard()
    {
        auto session = _secure;
        if (session is null) return;
        try session.send(ProtocolChannel.control,
            ControlMessage.clipboardRequest);
        catch (Exception error)
            _transferStatus.set("Clipboard failed: " ~ error.msg);
    }

    void disconnect()
    {
        if (_secure !is null)
        {
            try _secure.send(ProtocolChannel.control,
                ControlMessage.disconnect); catch (Exception) {}
        }
        cleanup();
        auto worker = _worker;
        _worker = null;
        if (worker !is null)
            try worker.join(); catch (Exception) {}
        _status.set("Idle");
    }

    private void cleanup()
    {
        SecureConnection secure;
        Socket socket;
        synchronized (_lifecycle)
        {
            secure = _secure;
            _secure = null;
            socket = _socket;
            _socket = null;
        }
        if (secure !is null) secure.close();
        else if (socket !is null)
            try socket.close(); catch (Exception) {}
    }
}

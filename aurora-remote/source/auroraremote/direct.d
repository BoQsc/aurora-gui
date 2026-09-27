module auroraremote.direct;

import auroraremote.capsule : AccessPermission, ConnectionCapsule,
    ConnectionTransport, decodeConnectionCapsule, encodeConnectionCapsule,
    newConnectionCapsule, newPersistentConnectionCapsule;
import auroraremote.clipboard : readClipboardText, writeClipboardText;
import auroraremote.desktop : DesktopCapturer;
import auroraremote.framecodec : DeltaFrameDecoder, DeltaFrameEncoder;
import auroraremote.identity : DeviceIdentity;
import auroraremote.input : applyRemoteInput;
import auroraremote.protocol : ControlMessage, ProtocolChannel,
    SecureConnection, acceptClient, establishClient;
import auroraremote.quality : AdaptiveQuality;
import auroraremote.relay : RelayRole, joinRelay;
import auroraremote.transfer : FileReceiver, defaultReceiveFolder,
    sendTransferPaths = sendPaths;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.socket : AddressFamily, InternetAddress, Socket,
    SocketOption, SocketOptionLevel, TcpSocket;

private void tuneInteractiveSocket(Socket socket)
{
    // Remote input and small frame deltas must not wait for Nagle's batching.
    // Keepalive also lets a dead WAN path fail instead of leaving the UI in a
    // permanently connected-looking state.
    try socket.setOption(SocketOptionLevel.TCP,
        SocketOption.TCP_NODELAY, true);
    catch (Exception) {}
    try socket.setOption(SocketOptionLevel.SOCKET,
        SocketOption.KEEPALIVE, true);
    catch (Exception) {}
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

alias RemoteInputHandler = void delegate(const(ubyte)[] packet);
alias ClipboardReader = string delegate();
alias ClipboardWriter = void delegate(string value);

final class DirectHost
{
    private Mutex _lifecycle;
    private SharedStatus _status;
    private Socket _listener;
    private Socket _client;
    private SecureConnection _secure;
    private Thread _worker;
    private ConnectionCapsule _capsule;
    private string _code;
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

    string start(DeviceIdentity identity, string advertisedHost, ushort port,
        bool persistent = false, const(ubyte)[] persistentToken = null,
        uint permissions = AccessPermission.all)
    {
        stop();
        _listener = new TcpSocket(AddressFamily.INET);
        _listener.setOption(SocketOptionLevel.SOCKET,
            SocketOption.REUSEADDR, true);
        _listener.bind(new InternetAddress("0.0.0.0", port));
        _listener.listen(4);
        const boundPort = (cast(InternetAddress) _listener.localAddress).port;
        _capsule = persistent ? newPersistentConnectionCapsule(advertisedHost,
            boundPort, identity.id[], persistentToken,
            ConnectionTransport.direct, permissions) :
            newConnectionCapsule(advertisedHost, boundPort, identity.id[],
                10 * 60, ConnectionTransport.direct, permissions);
        _code = encodeConnectionCapsule(_capsule);
        _status.set("Waiting for an authenticated direct connection on port " ~
            to!string(boundPort));
        _worker = new Thread(&runDirect);
        _worker.isDaemon = true;
        _worker.start();
        return _code;
    }

    string startRelay(DeviceIdentity identity, string relayHost, ushort relayPort,
        bool persistent = false, const(ubyte)[] persistentToken = null,
        uint permissions = AccessPermission.all)
    {
        stop();
        auto socket = new TcpSocket(AddressFamily.INET);
        tuneInteractiveSocket(socket);
        synchronized (_lifecycle) _client = socket;
        _capsule = persistent ? newPersistentConnectionCapsule(relayHost,
            relayPort, identity.id[], persistentToken,
            ConnectionTransport.relay, permissions) :
            newConnectionCapsule(relayHost, relayPort, identity.id[],
                10 * 60, ConnectionTransport.relay, permissions);
        _code = encodeConnectionCapsule(_capsule);
        _status.set("Waiting through encrypted relay " ~ relayHost ~ ":" ~
            to!string(relayPort));
        _worker = new Thread({ runRelay(socket); });
        _worker.isDaemon = true;
        _worker.start();
        return _code;
    }

    private void runDirect()
    {
        Thread captureWorker;
        try
        {
            auto listener = _listener;
            auto client = listener.accept();
            tuneInteractiveSocket(client);
            _client = client;
            _status.set("Authenticating direct connection…");
            serve(client, "Direct encrypted connection established",
                captureWorker);
            _status.set("Remote computer disconnected");
        }
        catch (Exception error)
        {
            _status.set("Direct host stopped: " ~ error.msg);
        }
        cleanupSockets();
        if (captureWorker !is null)
        {
            try captureWorker.join();
            catch (Exception) {}
        }
    }

    private void runRelay(Socket socket)
    {
        Thread captureWorker;
        try
        {
            socket.connect(new InternetAddress(_capsule.host, _capsule.port));
            joinRelay(socket, _capsule, RelayRole.host);
            _status.set("Authenticating relayed connection…");
            serve(socket, "End-to-end encrypted relay connection established",
                captureWorker);
            _status.set("Remote computer disconnected");
        }
        catch (Exception error)
        {
            _status.set("Relay host stopped: " ~ error.msg);
        }
        cleanupSockets();
        if (captureWorker !is null)
        {
            try captureWorker.join();
            catch (Exception) {}
        }
    }

    private void serve(Socket client, string connectedStatus,
        ref Thread captureWorker)
    {
        auto session = acceptClient(client, _capsule);
        _secure = session;
        _status.set(connectedStatus, true);
        const readiness = session.receive();
        if (readiness.channel != ProtocolChannel.control ||
            readiness.kind != ControlMessage.ping)
            throw new Exception("Controller skipped the readiness handshake.");
        session.send(ProtocolChannel.control, ControlMessage.pong,
            readiness.payload);
        if ((_capsule.permissions & AccessPermission.view) != 0)
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
                if ((_capsule.permissions & AccessPermission.input) == 0)
                    continue;
                if (_inputHandler !is null)
                    _inputHandler(message.payload);
                else
                    applyRemoteInput(message.payload);
                continue;
            }
            if (message.channel == ProtocolChannel.file)
            {
                if ((_capsule.permissions & AccessPermission.files) == 0)
                    continue;
                _fileReceiver.process(message.kind, message.payload);
                _transferStatus.set(_fileReceiver.status());
                continue;
            }
            if (message.channel == ProtocolChannel.clipboard)
            {
                if ((_capsule.permissions & AccessPermission.clipboard) == 0)
                    continue;
                const text = cast(string) message.payload.idup;
                if (_clipboardWriter !is null) _clipboardWriter(text);
                else writeClipboardText(text);
                _transferStatus.set("Received remote clipboard text");
                continue;
            }
            if (message.channel != ProtocolChannel.control) continue;
            if (message.kind == ControlMessage.ping)
                session.send(ProtocolChannel.control,
                    ControlMessage.pong, message.payload);
            else if (message.kind == ControlMessage.disconnect)
                break;
            else if (message.kind == ControlMessage.clipboardRequest)
            {
                if ((_capsule.permissions & AccessPermission.clipboard) == 0)
                    continue;
                const text = _clipboardReader !is null ?
                    _clipboardReader() : readClipboardText();
                if (text.length <= 1024 * 1024)
                    session.send(ProtocolChannel.clipboard, 1,
                        cast(const(ubyte)[]) text);
            }
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
    string code() const { return _code; }

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
        cleanupSockets();
        auto worker = _worker;
        _worker = null;
        if (worker !is null)
        {
            try worker.join();
            catch (Exception) {}
        }
        _status.set("Idle");
        _code = "";
    }

    private void cleanupSockets()
    {
        SecureConnection secure;
        Socket client;
        Socket listener;
        synchronized (_lifecycle)
        {
            secure = _secure;
            _secure = null;
            client = _client;
            _client = null;
            listener = _listener;
            _listener = null;
        }
        if (secure !is null)
            secure.close();
        else if (client !is null)
        {
            try client.close(); catch (Exception) {}
        }
        if (listener !is null)
        {
            try listener.close(); catch (Exception) {}
        }
    }
}

final class DirectConnector
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
    private uint _permissions;

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

    void connect(string code)
    {
        disconnect();
        ConnectionCapsule capsule;
        try capsule = decodeConnectionCapsule(code);
        catch (Exception error)
        {
            _status.set("Connection code rejected: " ~ error.msg);
            return;
        }
        _permissions = capsule.permissions;
        _status.set((capsule.transport == ConnectionTransport.relay ?
            "Connecting through relay " : "Connecting directly to ") ~
            capsule.host ~ ":" ~ to!string(capsule.port) ~ "…");
        auto socket = new TcpSocket(AddressFamily.INET);
        tuneInteractiveSocket(socket);
        synchronized (_lifecycle) _socket = socket;
        _worker = new Thread({ run(capsule, socket); });
        _worker.isDaemon = true;
        _worker.start();
    }

    private void run(ConnectionCapsule capsule, Socket socket)
    {
        try
        {
            socket.connect(new InternetAddress(capsule.host, capsule.port));
            if (capsule.transport == ConnectionTransport.relay)
                joinRelay(socket, capsule, RelayRole.controller);
            _status.set("Authenticating host…");
            auto session = establishClient(socket, capsule);
            _secure = session;
            const ping = cast(const(ubyte)[]) "aurora-direct-ready";
            session.send(ProtocolChannel.control, ControlMessage.ping, ping);
            const reply = session.receive();
            if (reply.channel != ProtocolChannel.control ||
                reply.kind != ControlMessage.pong || reply.payload != ping)
                throw new Exception("Host returned an invalid readiness reply.");
            _status.set(capsule.transport == ConnectionTransport.relay ?
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
        catch (Exception error)
        {
            _status.set("Connection failed: " ~ error.msg);
            cleanup();
        }
    }

    string status(out bool connected) { return _status.snapshot(connected); }

    bool frameSnapshot(ref uint revision, out int width, out int height,
        out ubyte[] rgba)
    {
        return _frame.snapshot(revision, width, height, rgba);
    }

    void sendInput(const(ubyte)[] packet)
    {
        if ((_permissions & AccessPermission.input) == 0) return;
        auto session = _secure;
        if (session is null || packet.length == 0) return;
        try session.send(ProtocolChannel.input, 1, packet);
        catch (Exception error) _status.set("Input send failed: " ~ error.msg);
    }

    void sendPaths(const(string)[] paths)
    {
        if ((_permissions & AccessPermission.files) == 0) return;
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
        if ((_permissions & AccessPermission.clipboard) == 0) return;
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
        if ((_permissions & AccessPermission.clipboard) == 0) return;
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
        {
            try worker.join();
            catch (Exception) {}
        }
        _status.set("Idle");
        _permissions = 0;
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
        if (secure !is null)
            secure.close();
        else if (socket !is null)
        {
            try socket.close(); catch (Exception) {}
        }
    }
}

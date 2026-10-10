module aurorarustdesk.rendezvous;

import aurorarustdesk.crypto : randomBytes;
import aurorarustdesk.relay : RelayServer;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.exception : enforce;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
    SocketOptionLevel, SocketShutdown, TcpSocket;

// The rendezvous ("ID") server keeps a live map of numeric ID -> reachable
// address. It only brokers introductions: it never sees the password or the
// session key, and it forwards no desktop, input, or file bytes itself. That is
// the one structural difference from the link-based Aurora Remote model: the
// peer is dialed by ID, discovered through this server, and the relay (when
// used) stays content-blind.
enum RendezvousKind : ubyte
{
    register = 1,
    lookup = 2,
    registered = 128,
    found = 129,
    notFound = 130,
    error = 131
}

private struct Frame
{
    RendezvousKind kind;
    ubyte[] payload;
}

private void sendFrame(Socket socket, RendezvousKind kind,
    const(ubyte)[] payload)
{
    enforce(payload.length <= ushort.max, "Rendezvous payload is too large.");
    auto header = new ubyte[3];
    header[0] = cast(ubyte) kind;
    header[1] = cast(ubyte)(payload.length >> 8);
    header[2] = cast(ubyte) payload.length;
    socket.send(header);
    if (payload.length > 0) socket.send(payload);
}

private Frame receiveFrame(Socket socket)
{
    auto header = new ubyte[3];
    size_t offset;
    while (offset < header.length)
    {
        const received = socket.receive(header[offset .. $]);
        enforce(received > 0, "Rendezvous connection closed.");
        offset += received;
    }
    const length = (cast(size_t) header[1] << 8) | header[2];
    auto payload = new ubyte[length];
    offset = 0;
    while (offset < length)
    {
        const received = socket.receive(payload[offset .. $]);
        enforce(received > 0, "Rendezvous connection closed mid-record.");
        offset += received;
    }
    return Frame(cast(RendezvousKind) header[0], payload);
}

private void putU16(ref ubyte[] output, ushort value)
{
    output ~= cast(ubyte)(value >> 8);
    output ~= cast(ubyte) value;
}

private ushort readU16(const(ubyte)[] input, size_t offset)
{
    return cast(ushort)((cast(ushort) input[offset] << 8) | input[offset + 1]);
}

bool validNumericId(string id)
{
    if (id.length != 9) return false;
    foreach (ch; id)
        if (ch < '0' || ch > '9') return false;
    return true;
}

Socket connectServer(string host, ushort port)
{
    auto socket = new TcpSocket(AddressFamily.INET);
    socket.connect(new InternetAddress(host, port));
    return socket;
}

private void closeQuietly(Socket socket)
{
    if (socket is null) return;
    try socket.shutdown(SocketShutdown.BOTH); catch (Exception) {}
    try socket.close(); catch (Exception) {}
}

struct RendezvousRegistration
{
    Socket socket;
    ushort relayPort;
    ubyte[16] relayKey;
}

// Register this host's ID with the server and keep the control socket open so
// the ID stays resolvable while the host runs.
RendezvousRegistration registerHost(string host, ushort port, string id,
    ushort directPort, bool wantRelay)
{
    enforce(validNumericId(id), "Numeric ID must be nine digits.");
    auto socket = connectServer(host, port);
    ubyte[16] relayKey;
    if (wantRelay) relayKey[] = randomBytes(relayKey.length)[];
    ubyte[] payload;
    payload ~= cast(const(ubyte)[]) id;
    putU16(payload, directPort);
    payload ~= cast(ubyte)(wantRelay ? 1 : 0);
    payload ~= relayKey[];
    sendFrame(socket, RendezvousKind.register, payload);
    const reply = receiveFrame(socket);
    enforce(reply.kind == RendezvousKind.registered,
        "The ID server rejected the registration.");
    RendezvousRegistration result;
    result.socket = socket;
    result.relayPort = reply.payload.length >= 2 ? readU16(reply.payload, 0) : 0;
    result.relayKey = relayKey;
    return result;
}

struct RendezvousPeer
{
    string address;
    ushort directPort;
    bool relay;
    ubyte[16] relayKey;
    ushort relayPort;
}

// Resolve a remote ID to a reachable endpoint. Returns false when the ID is not
// currently registered.
bool lookupPeer(string host, ushort port, string id, out RendezvousPeer peer)
{
    auto socket = connectServer(host, port);
    scope (exit) closeQuietly(socket);
    sendFrame(socket, RendezvousKind.lookup, cast(const(ubyte)[]) id);
    const reply = receiveFrame(socket);
    if (reply.kind != RendezvousKind.found) return false;
    size_t offset;
    const addressLength = reply.payload[offset++];
    peer.address = cast(string) reply.payload[offset .. offset + addressLength]
        .idup;
    offset += addressLength;
    peer.directPort = readU16(reply.payload, offset);
    offset += 2;
    peer.relay = reply.payload[offset++] != 0;
    peer.relayKey[] = reply.payload[offset .. offset + 16];
    offset += 16;
    peer.relayPort = readU16(reply.payload, offset);
    return true;
}

private struct RegisteredHost
{
    Socket socket;
    string address;
    ushort directPort;
    bool wantRelay;
    ubyte[16] relayKey;
}

final class RendezvousServer
{
    private Mutex _mutex;
    private Socket _listener;
    private Thread _acceptWorker;
    private RelayServer _relay;
    private RegisteredHost[string] _hosts;
    private ushort _idPort;
    private ushort _relayPort;
    private bool _running;

    this() { _mutex = new Mutex; }

    ushort start(ushort idPort, ushort relayPort = 0)
    {
        stop();
        _relay = new RelayServer;
        _relayPort = _relay.start(relayPort);
        auto listener = new TcpSocket(AddressFamily.INET);
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("0.0.0.0", idPort));
        listener.listen(64);
        _idPort = (cast(InternetAddress) listener.localAddress).port;
        synchronized (_mutex)
        {
            _listener = listener;
            _running = true;
        }
        _acceptWorker = new Thread({ acceptLoop(listener); });
        _acceptWorker.isDaemon = true;
        _acceptWorker.start();
        return _idPort;
    }

    ushort idPort() const { return _idPort; }
    ushort relayPort() const { return _relayPort; }

    private void acceptLoop(Socket listener)
    {
        while (true)
        {
            Socket socket;
            try socket = listener.accept();
            catch (Exception) break;
            bool running;
            synchronized (_mutex) running = _running;
            if (!running)
            {
                try socket.close(); catch (Exception) {}
                break;
            }
            startHandler(socket);
        }
    }

    private void startHandler(Socket socket)
    {
        auto worker = new Thread({ handle(socket); });
        worker.isDaemon = true;
        worker.start();
    }

    private string observedAddress(Socket socket)
    {
        try return socket.remoteAddress.toAddrString();
        catch (Exception) return "";
    }

    private void handle(Socket socket)
    {
        try
        {
            const frame = receiveFrame(socket);
            if (frame.kind == RendezvousKind.register)
            {
                size_t offset;
                const id = cast(string) frame.payload[0 .. 9].idup;
                offset = 9;
                const directPort = readU16(frame.payload, offset);
                offset += 2;
                const wantRelay = frame.payload[offset++] != 0;
                ubyte[16] relayKey;
                relayKey[] = frame.payload[offset .. offset + 16];
                auto entry = RegisteredHost(socket, observedAddress(socket),
                    directPort, wantRelay, relayKey);
                synchronized (_mutex) _hosts[id] = entry;
                ubyte[] reply;
                putU16(reply, wantRelay ? _relayPort : 0);
                sendFrame(socket, RendezvousKind.registered, reply);
                // Hold the socket open; a disconnect means the host is offline.
                while (true)
                {
                    auto probe = new ubyte[1];
                    const received = socket.receive(probe[]);
                    if (received <= 0) break;
                }
            }
            else if (frame.kind == RendezvousKind.lookup)
            {
                const id = cast(string) frame.payload.idup;
                RegisteredHost host;
                bool found;
                synchronized (_mutex)
                {
                    auto entry = id in _hosts;
                    if (entry !is null)
                    {
                        host = *entry;
                        found = true;
                    }
                }
                if (!found)
                {
                    sendFrame(socket, RendezvousKind.notFound, null);
                    return;
                }
                ubyte[] reply;
                const address = cast(const(ubyte)[]) host.address;
                reply ~= cast(ubyte) address.length;
                reply ~= address;
                putU16(reply, host.directPort);
                reply ~= cast(ubyte)(host.wantRelay ? 1 : 0);
                reply ~= host.relayKey[];
                putU16(reply, _relayPort);
                sendFrame(socket, RendezvousKind.found, reply);
            }
            else sendFrame(socket, RendezvousKind.error, null);
        }
        catch (Exception)
        {
        }
        try socket.shutdown(SocketShutdown.BOTH); catch (Exception) {}
        try socket.close(); catch (Exception) {}
        // Do not drop a still-live registration whose socket just happened to
        // be the one this handler finished with: remove only on close.
        removeIfSame(socket);
    }

    private void removeIfSame(Socket socket)
    {
        string[] stale;
        synchronized (_mutex)
        {
            foreach (id, ref entry; _hosts)
                if (entry.socket is socket) stale ~= id;
            foreach (id; stale) _hosts.remove(id);
        }
    }

    void stop()
    {
        Socket listener;
        Socket[] openSockets;
        synchronized (_mutex)
        {
            _running = false;
            listener = _listener;
            _listener = null;
            foreach (entry; _hosts.byValue()) openSockets ~= entry.socket;
            _hosts = null;
        }
        if (listener !is null)
        {
            try
            {
                auto wake = new TcpSocket(AddressFamily.INET);
                wake.connect(new InternetAddress("127.0.0.1", _idPort));
                wake.close();
            }
            catch (Exception) {}
            try listener.close(); catch (Exception) {}
        }
        foreach (socket; openSockets)
        {
            try socket.shutdown(SocketShutdown.BOTH); catch (Exception) {}
            try socket.close(); catch (Exception) {}
        }
        auto worker = _acceptWorker;
        _acceptWorker = null;
        if (worker !is null) try worker.join(); catch (Exception) {}
        if (_relay !is null) _relay.stop();
        _relay = null;
        _idPort = 0;
    }
}

module auroraremote.relay;

import auroraremote.capsule : ConnectionCapsule, ConnectionTransport;
import auroraremote.crypto : sha256;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.exception : enforce;
import std.socket : AddressFamily, InternetAddress, Socket, SocketShutdown,
    SocketOption, SocketOptionLevel, TcpSocket;

enum RelayRole : ubyte
{
    host = 1,
    controller = 2
}

private enum relayMagic = cast(const(ubyte)[]) "ARR1";

private void tuneRelaySocket(Socket socket)
{
    try socket.setOption(SocketOptionLevel.TCP,
        SocketOption.TCP_NODELAY, true);
    catch (Exception) {}
    try socket.setOption(SocketOptionLevel.SOCKET,
        SocketOption.KEEPALIVE, true);
    catch (Exception) {}
}

private void sendAll(Socket socket, const(ubyte)[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        const sent = socket.send(bytes[offset .. $]);
        enforce(sent > 0, "Relay closed while sending.");
        offset += sent;
    }
}

private ubyte[] receiveExact(Socket socket, size_t length)
{
    auto result = new ubyte[length];
    size_t offset;
    while (offset < length)
    {
        const received = socket.receive(result[offset .. $]);
        enforce(received > 0, "Relay closed while receiving.");
        offset += received;
    }
    return result;
}

private ubyte[16] sessionId(const ConnectionCapsule capsule)
{
    const digest = sha256(capsule.token[]);
    ubyte[16] result;
    result[] = digest[0 .. result.length];
    return result;
}

private string sessionKey(const(ubyte)[] bytes)
{
    enum alphabet = "0123456789abcdef";
    char[] result = new char[bytes.length * 2];
    foreach (index, value; bytes)
    {
        result[index * 2] = alphabet[value >> 4];
        result[index * 2 + 1] = alphabet[value & 15];
    }
    return result.idup;
}

void joinRelay(Socket socket, const ConnectionCapsule capsule, RelayRole role)
{
    enforce(capsule.transport == ConnectionTransport.relay,
        "Connection invitation is not configured for a relay.");
    auto preface = new ubyte[relayMagic.length + 1 + 16];
    preface[0 .. relayMagic.length] = relayMagic[];
    preface[relayMagic.length] = cast(ubyte) role;
    const id = sessionId(capsule);
    preface[relayMagic.length + 1 .. $] = id[];
    sendAll(socket, preface);
    const ready = receiveExact(socket, 1);
    enforce(ready[0] == 1, "Relay rejected the session.");
}

Socket connectThroughRelay(const ConnectionCapsule capsule, RelayRole role)
{
    auto socket = new TcpSocket(AddressFamily.INET);
    tuneRelaySocket(socket);
    socket.connect(new InternetAddress(capsule.host, capsule.port));
    joinRelay(socket, capsule, role);
    return socket;
}

private struct WaitingPair
{
    Socket host;
    Socket controller;
}

final class RelayServer
{
    private Mutex _mutex;
    private Socket _listener;
    private Thread _acceptWorker;
    private WaitingPair[string] _waiting;
    private ushort _port;
    private bool _running;

    this() { _mutex = new Mutex; }

    ushort start(ushort port)
    {
        stop();
        auto listener = new TcpSocket(AddressFamily.INET);
        listener.bind(new InternetAddress("0.0.0.0", port));
        listener.listen(64);
        _port = (cast(InternetAddress) listener.localAddress).port;
        synchronized (_mutex)
        {
            _listener = listener;
            _running = true;
        }
        _acceptWorker = new Thread({ acceptLoop(listener); });
        _acceptWorker.isDaemon = true;
        _acceptWorker.start();
        return _port;
    }

    ushort port() const { return _port; }

    private void acceptLoop(Socket listener)
    {
        while (true)
        {
            Socket socket;
            try socket = listener.accept();
            catch (Exception) break;
            tuneRelaySocket(socket);
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
        // Keep each accepted socket in its own closure. Capturing the accept
        // loop's reused local lets a later accept replace an earlier handler's
        // socket before that handler starts.
        auto worker = new Thread({ handle(socket); });
            worker.isDaemon = true;
            worker.start();
    }

    private void handle(Socket socket)
    {
        try
        {
            const preface = receiveExact(socket, relayMagic.length + 1 + 16);
            enforce(preface[0 .. relayMagic.length] == relayMagic,
                "Invalid relay preface.");
            const role = cast(RelayRole) preface[relayMagic.length];
            enforce(role == RelayRole.host || role == RelayRole.controller,
                "Invalid relay role.");
            const key = sessionKey(preface[relayMagic.length + 1 .. $]);
            Socket peer;
            synchronized (_mutex)
            {
                auto pair = key in _waiting;
                if (pair is null)
                {
                    WaitingPair fresh;
                    if (role == RelayRole.host) fresh.host = socket;
                    else fresh.controller = socket;
                    _waiting[key] = fresh;
                    return;
                }
                if (role == RelayRole.host)
                {
                    enforce(pair.host is null, "Duplicate relay host.");
                    pair.host = socket;
                }
                else
                {
                    enforce(pair.controller is null, "Duplicate relay controller.");
                    pair.controller = socket;
                }
                if (pair.host !is null && pair.controller !is null)
                {
                    peer = role == RelayRole.host ? pair.controller : pair.host;
                    _waiting.remove(key);
                }
                else return;
            }
            sendAll(socket, [cast(ubyte) 1]);
            sendAll(peer, [cast(ubyte) 1]);
            bridge(socket, peer);
        }
        catch (Exception)
        {
            try socket.close(); catch (Exception) {}
        }
    }

    private void bridge(Socket first, Socket second)
    {
        auto reverseWorker = new Thread({ pipe(second, first); });
        reverseWorker.isDaemon = true;
        reverseWorker.start();
        pipe(first, second);
        try first.shutdown(SocketShutdown.BOTH); catch (Exception) {}
        try second.shutdown(SocketShutdown.BOTH); catch (Exception) {}
        try reverseWorker.join(); catch (Exception) {}
        try first.close(); catch (Exception) {}
        try second.close(); catch (Exception) {}
    }

    private void pipe(Socket source, Socket destination)
    {
        ubyte[64 * 1024] buffer;
        try
        {
            while (true)
            {
                const count = source.receive(buffer[]);
                if (count <= 0) break;
                sendAll(destination, buffer[0 .. count]);
            }
        }
        catch (Exception) {}
    }

    void stop()
    {
        Socket listener;
        Socket[] waitingSockets;
        synchronized (_mutex)
        {
            _running = false;
            listener = _listener;
            _listener = null;
            foreach (pair; _waiting.byValue())
            {
                if (pair.host !is null) waitingSockets ~= pair.host;
                if (pair.controller !is null) waitingSockets ~= pair.controller;
            }
            _waiting = null;
        }
        if (listener !is null)
        {
            // Closing a listening Winsock socket from another thread does not
            // reliably wake a blocking accept on every Windows version. Make
            // one local connection after clearing _running, then close it.
            try
            {
                auto wake = new TcpSocket(AddressFamily.INET);
                wake.connect(new InternetAddress("127.0.0.1", _port));
                wake.close();
            }
            catch (Exception) {}
            try listener.close(); catch (Exception) {}
        }
        foreach (socket; waitingSockets)
            try socket.close(); catch (Exception) {}
        auto worker = _acceptWorker;
        _acceptWorker = null;
        if (worker !is null)
            try worker.join(); catch (Exception) {}
        _port = 0;
    }
}

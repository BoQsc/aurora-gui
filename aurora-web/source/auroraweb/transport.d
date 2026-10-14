module auroraweb.transport;

/**
 * Cross-platform byte transport for Aurora Web.
 *
 * This is the bottom of the browser's network stack. It is built entirely on
 * Phobos `std.socket` — Winsock on Windows, BSD sockets on Linux/macOS — so
 * there is no `version`-specific socket code and no third-party dependency. The
 * HTTP layer (`auroraweb.httpclient`) and the TLS layer (`auroraweb.tls`) both
 * speak to the network through the `ByteTransport` interface, which is what lets
 * a TLS session wrap a TCP connection transparently.
 *
 * Sockets are non-blocking and every read/write waits with `Socket.select` under
 * a deadline, so a dead or slow peer can never hang a caller forever.
 */

import std.socket;
import core.time : Duration, dur;
import std.conv : to;

/**
 * A duplex byte stream. Implemented by `TcpTransport` (raw TCP) and by the TLS
 * record layer, which wraps another `ByteTransport`.
 */
interface ByteTransport
{
    /**
     * Read up to `buf.length` bytes into `buf`.
     * Returns the number of bytes read (0 means the peer closed the connection
     * cleanly). Throws `TransportException` on timeout or a socket error.
     */
    ptrdiff_t readSome(ubyte[] buf);

    /// Write every byte of `data`, looping until done. Throws `TransportException`
    /// on timeout or a socket error.
    void writeAll(const(ubyte)[] data);

    /// Close the transport. Idempotent.
    void close();
}

/// Raised for timeouts and socket-level failures.
class TransportException : Exception
{
    this(string msg) { super(msg); }
}

/// A raw TCP connection.
final class TcpTransport : ByteTransport
{
    private Socket _sock;
    private Duration _timeout;
    private bool _closed;

    private this(Socket sock, Duration timeout)
    {
        _sock = sock;
        _timeout = timeout;
    }

    /// Wrap an already-connected socket (used by tests and by future server
    /// code). Switches it to non-blocking mode.
    static TcpTransport fromConnected(Socket sock, Duration timeout = dur!"seconds"(30))
    {
        sock.blocking = false;
        return new TcpTransport(sock, timeout);
    }

    /**
     * Resolve `host`, connect to `port`, and return a live transport. Tries
     * every address the resolver returns (IPv4 and IPv6) until one connects.
     * Throws `TransportException` if none succeed or the deadline passes.
     */
    static TcpTransport connect(string host, ushort port,
        Duration timeout = dur!"seconds"(30))
    {
        Address[] addresses;
        try
            addresses = getAddress(host, port);
        catch (SocketException e)
            throw new TransportException("DNS lookup failed for '" ~ host ~ "': " ~ e.msg);
        if (addresses.length == 0)
            throw new TransportException("no addresses for '" ~ host ~ "'");

        Exception last;
        foreach (addr; addresses)
        {
            Socket sock;
            try
            {
                sock = new Socket(addr.addressFamily, SocketType.STREAM);
                sock.blocking = false;
                // Phobos returns normally for a non-blocking connect that is
                // still in progress (WSAEWOULDBLOCK / EINPROGRESS).
                sock.connect(addr);
                if (!waitWritable(sock, timeout))
                {
                    sock.close();
                    continue;
                }
                int err = 0;
                try sock.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, err);
                catch (SocketException) { err = -1; }
                if (err != 0)
                {
                    sock.close();
                    last = new TransportException("connect to " ~ host ~ ":" ~
                        to!string(port) ~ " failed (socket error " ~ to!string(err) ~ ")");
                    continue;
                }
                return new TcpTransport(sock, timeout);
            }
            catch (Exception e)
            {
                if (sock !is null) sock.close();
                last = e;
            }
        }
        throw last !is null ? last :
            new TransportException("could not connect to " ~ host);
    }

    override ptrdiff_t readSome(ubyte[] buf)
    {
        if (_closed || buf.length == 0) return 0;
        while (true)
        {
            auto n = _sock.receive(buf);
            if (n > 0) return n;
            if (n == 0) return 0;                 // clean EOF
            if (!wouldHaveBlocked())
                throw new TransportException("socket receive failed");
            if (!wait(_sock, false, _timeout))
                throw new TransportException("read timed out after " ~ to!string(_timeout));
        }
    }

    override void writeAll(const(ubyte)[] data)
    {
        size_t off = 0;
        while (off < data.length)
        {
            auto n = _sock.send(data[off .. $]);
            if (n > 0) { off += cast(size_t) n; continue; }
            if (n == 0) throw new TransportException("socket send returned 0");
            if (!wouldHaveBlocked())
                throw new TransportException("socket send failed");
            if (!wait(_sock, true, _timeout))
                throw new TransportException("write timed out after " ~ to!string(_timeout));
        }
    }

    override void close()
    {
        if (_closed) return;
        _closed = true;
        try _sock.shutdown(SocketShutdown.BOTH);
        catch (SocketException) {}
        try _sock.close();
        catch (SocketException) {}
    }

    ~this()
    {
        close();
    }

    private static bool wait(Socket sock, bool writable, Duration timeout)
    {
        auto set = new SocketSet();
        set.add(sock);
        int n = writable
            ? Socket.select(null, set, null, timeout)
            : Socket.select(set, null, null, timeout);
        return n > 0;
    }

    private static bool waitWritable(Socket sock, Duration timeout)
    {
        auto ws = new SocketSet();
        ws.add(sock);
        auto es = new SocketSet();
        es.add(sock);
        int n = Socket.select(null, ws, es, timeout);
        return n > 0;
    }
}

version (unittest)
{
    import core.thread : Thread;
    // Loopback tests over a connected socket pair (no DNS, no listener thread).
    unittest
    {
        auto pair_ = socketPair();
        auto a = TcpTransport.fromConnected(pair_[0], dur!"seconds"(2));
        auto b = TcpTransport.fromConnected(pair_[1], dur!"seconds"(2));

        a.writeAll(cast(ubyte[]) "hello");
        ubyte[16] buf;
        auto n = b.readSome(buf);
        assert(n == 5, "expected 5 bytes, got " ~ to!string(n));
        assert(cast(string) buf[0 .. 5] == "hello", "payload mismatch");

        b.writeAll(cast(ubyte[]) "world");
        n = a.readSome(buf);
        assert(n == 5 && cast(string) buf[0 .. 5] == "world", "reverse payload");

        // A large write exercises the write loop across partial sends.
        ubyte[] big = new ubyte[](200_000);
        foreach (i; 0 .. big.length) big[i] = cast(ubyte) (i & 0xff);
        auto writer = new Thread({ a.writeAll(big); });
        writer.start();
        ubyte[] got;
        ubyte[64 * 1024] chunk;
        while (got.length < big.length)
        {
            auto r = b.readSome(chunk);
            if (r <= 0) break;
            got ~= chunk[0 .. cast(size_t) r];
        }
        writer.join();
        assert(got.length == big.length, "large transfer length " ~ to!string(got.length));
        assert(got == big, "large transfer content mismatch");

        // Clean EOF: closing one side makes the other read 0.
        a.close();
        n = b.readSome(buf);
        assert(n == 0, "expected EOF (0), got " ~ to!string(n));
        b.close();
    }

    unittest
    {
        // A read with a short deadline and no data must raise, not hang.
        auto pair_ = socketPair();
        auto a = TcpTransport.fromConnected(pair_[0], dur!"msecs"(80));
        auto b = TcpTransport.fromConnected(pair_[1], dur!"msecs"(80));
        scope (exit) { a.close(); b.close(); }
        ubyte[16] buf;
        bool threw = false;
        try b.readSome(buf);
        catch (TransportException) threw = true;
        assert(threw, "read with no data should time out");
    }
}

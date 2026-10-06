module auroraopencode.httptransport;

import core.sys.windows.windows : DWORD, DWORD_PTR, GetLastError;
import core.sys.windows.winhttp;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time : MonoTime;
import core.thread : Thread, thread_attachThis, thread_detachThis;
import core.memory : GC;
import std.conv : to;
import std.utf : toUTF16z;
import auroraopencode.workerbudget : providerWorkerBudget;

pragma(lib, "winhttp.lib");

private enum DWORD enableHttpProtocol = 133;
private enum DWORD http2Protocol = 1;
private enum DWORD protocolUsed = 134;

private class Connection
{
    HINTERNET handle;
    size_t users;
    ulong touched;
}

/// Connections belong to the process, requests to individual clients. Closing
/// one chat never closes another chat's connection. Idle handles are bounded;
/// active leases remain alive until the final request callback has arrived.
private class ConnectionPool
{
    Mutex mutex;
    HINTERNET directSession, proxySession;
    Connection[string] connections;
    ulong clock, created;

    this() { mutex = new Mutex(); }

    Connection acquire(string host, ushort port, bool secure, bool direct)
    {
        const key = (direct ? "direct|" : "proxy|") ~ (secure ? "https|" : "http|") ~
            host ~ ":" ~ to!string(port);
        HINTERNET session;
        synchronized (mutex) session = direct ? directSession : proxySession;
        if (session is null)
        {
            auto candidate = WinHttpOpen("Aurora OpenCode"w.ptr,
                direct ? WINHTTP_ACCESS_TYPE_NO_PROXY : WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                null, null, WINHTTP_FLAG_ASYNC);
            if (candidate is null) throw new Exception("Could not open WinHTTP (" ~ to!string(GetLastError()) ~ ").");
            WinHttpSetTimeouts(candidate, 30_000, 30_000, 60_000, 120_000);
            DWORD connections = cast(DWORD) providerWorkerBudget().capacity;
            WinHttpSetOption(candidate, WINHTTP_OPTION_MAX_CONNS_PER_SERVER, &connections, connections.sizeof);
            WinHttpSetOption(candidate, WINHTTP_OPTION_MAX_CONNS_PER_1_0_SERVER, &connections, connections.sizeof);
            DWORD protocols = http2Protocol;
            // Older Windows versions may reject this option; HTTP/1.1 remains
            // valid. Negotiation, rather than this setting, determines usage.
            WinHttpSetOption(candidate, enableHttpProtocol, &protocols, protocols.sizeof);
            synchronized (mutex)
            {
                session = direct ? directSession : proxySession;
                if (session is null)
                {
                    session = candidate;
                    if (direct) directSession = candidate; else proxySession = candidate;
                    candidate = null;
                }
            }
            if (candidate !is null) WinHttpCloseHandle(candidate);
        }
        synchronized (mutex)
        {
            if (auto existing = key in connections)
            {
                ++(*existing).users;
                (*existing).touched = ++clock;
                return *existing;
            }
            if (connections.length >= 32)
            {
                string oldest;
                ulong time = ulong.max;
                foreach (name, entry; connections)
                    if (!entry.users && entry.touched < time) { oldest = name; time = entry.touched; }
                if (oldest.length)
                {
                    WinHttpCloseHandle(connections[oldest].handle);
                    connections.remove(oldest);
                }
            }
            auto entry = new Connection();
            entry.handle = WinHttpConnect(session, toUTF16z(host), port, 0);
            if (entry.handle is null) throw new Exception("Could not create the WinHTTP connection.");
            entry.users = 1;
            entry.touched = ++clock;
            connections[key] = entry;
            ++created;
            return entry;
        }
    }

    void release(Connection entry)
    {
        synchronized (mutex)
        {
            assert(entry.users);
            --entry.users;
            while (connections.length > 32)
            {
                string oldest;
                ulong time = ulong.max;
                foreach (name, candidate; connections)
                    if (!candidate.users && candidate.touched < time) { oldest = name; time = candidate.touched; }
                if (!oldest.length) break;
                WinHttpCloseHandle(connections[oldest].handle);
                connections.remove(oldest);
            }
        }
    }
}

private __gshared ConnectionPool pool;
shared static this() { pool = new ConnectionPool(); }

struct TransportPoolStats { size_t handles, activeLeases; ulong created; }
TransportPoolStats transportPoolStats()
{
    synchronized (pool.mutex)
    {
        TransportPoolStats result;
        result.handles = pool.connections.length;
        result.created = pool.created;
        foreach (entry; pool.connections) result.activeLeases += entry.users;
        return result;
    }
}

/// WinHTTP performs network operations asynchronously. The bounded provider
/// worker waits only for notifications; Stop closes this request alone. The
/// callback context and read buffers outlive HANDLE_CLOSING, including errors.
class AsyncHttpRequest
{
    private Mutex mutex;
    private Condition changed;
    private Connection connection;
    private HINTERNET handle;
    private bool cancelled, closed, rooted;
    private DWORD completed, error, count;
    private string body;
    private long connectedTicks = -1, sentTicks = -1;
    private uint negotiatedProtocol;

    this(string host, ushort port, string path, bool secure, bool direct)
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
        connection = pool.acquire(host, port, secure, direct);
        handle = WinHttpOpenRequest(connection.handle, "POST"w.ptr, toUTF16z(path),
            null, null, null, secure ? WINHTTP_FLAG_SECURE : 0);
        if (handle is null)
        {
            pool.release(connection);
            connection = null;
            throw new Exception("Could not open the WinHTTP request.");
        }
        // Sessions share sockets, never provider cookies. Endpoint redirects
        // are reported to the caller instead of forwarding its bearer header.
        DWORD disabled = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS;
        WinHttpSetOption(handle, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, disabled.sizeof);
        DWORD_PTR context = cast(DWORD_PTR) cast(void*) this;
        if (!WinHttpSetOption(handle, WINHTTP_OPTION_CONTEXT_VALUE, &context, context.sizeof))
        {
            WinHttpCloseHandle(handle);
            pool.release(connection);
            connection = null;
            throw new Exception("Could not set the WinHTTP request context.");
        }
        GC.addRoot(cast(void*) this);
        rooted = true;
        if (WinHttpSetStatusCallback(handle, &statusCallback,
            WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES |
            WINHTTP_CALLBACK_FLAG_CONNECT_TO_SERVER | WINHTTP_CALLBACK_FLAG_SEND_REQUEST, 0) ==
            WINHTTP_INVALID_STATUS_CALLBACK)
        {
            GC.removeRoot(cast(void*) this);
            rooted = false;
            WinHttpCloseHandle(handle);
            pool.release(connection);
            connection = null;
            throw new Exception("Could not install the WinHTTP callback.");
        }
    }

    private static extern(Windows) int statusCallback(HINTERNET request, DWORD_PTR context,
        DWORD status, void* info, DWORD length)
    {
        if (!context) return 0;
        const attach = Thread.getThis() is null;
        if (attach) thread_attachThis();
        scope(exit) if (attach) thread_detachThis();
        auto owner = cast(AsyncHttpRequest) cast(void*) context;
        bool unroot;
        synchronized (owner.mutex)
        {
            switch (status)
            {
                case WINHTTP_CALLBACK_STATUS_CONNECTED_TO_SERVER:
                    owner.connectedTicks = MonoTime.currTime.ticks; break;
                case WINHTTP_CALLBACK_STATUS_REQUEST_SENT:
                    owner.sentTicks = MonoTime.currTime.ticks; break;
                case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
                    owner.error = (cast(WINHTTP_ASYNC_RESULT*) info).dwError; break;
                case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
                    owner.count = length;
                    owner.completed = status; break;
                case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
                    owner.count = *cast(DWORD*) info;
                    owner.completed = status; break;
                case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
                case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
                    owner.completed = status; break;
                case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
                    owner.closed = true;
                    unroot = owner.rooted;
                    owner.rooted = false; break;
                default: break;
            }
            owner.changed.notifyAll();
        }
        if (unroot) GC.removeRoot(cast(void*) owner);
        return 0;
    }

    private void ensureOpen()
    {
        if (cancelled || handle is null) throw new Exception("Chat request cancelled.");
        if (error) throw new Exception("WinHTTP error " ~ to!string(error) ~ ".");
    }

    private void awaitCompletion(DWORD status)
    {
        // Caller owns mutex. No application lock is held by a callback.
        while (!cancelled && !error && completed != status) changed.wait();
        ensureOpen();
    }

    uint send(string headers, string payload)
    {
        synchronized (mutex)
        {
            ensureOpen();
            body = payload; // WinHTTP may reference the upload until send completes.
            completed = 0;
            if (!WinHttpSendRequest(handle, toUTF16z(headers), cast(DWORD) -1,
                cast(void*) body.ptr, cast(DWORD) body.length, cast(DWORD) body.length,
                cast(DWORD_PTR) cast(void*) this))
                throw new Exception("WinHTTP send failed (" ~ to!string(GetLastError()) ~ ").");
            awaitCompletion(WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE);
            completed = 0;
            if (!WinHttpReceiveResponse(handle, null))
                throw new Exception("WinHTTP response failed (" ~ to!string(GetLastError()) ~ ").");
            awaitCompletion(WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE);
            DWORD status, size = status.sizeof;
            if (!WinHttpQueryHeaders(handle, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                null, &status, &size, null)) throw new Exception("Could not read the HTTP status.");
            size = negotiatedProtocol.sizeof;
            WinHttpQueryOption(handle, protocolUsed, &negotiatedProtocol, &size);
            return status;
        }
    }

    size_t read(ubyte[] buffer)
    {
        synchronized (mutex)
        {
            ensureOpen();
            completed = 0;
            if (!WinHttpQueryDataAvailable(handle, null))
                throw new Exception("WinHTTP availability failed (" ~ to!string(GetLastError()) ~ ").");
            awaitCompletion(WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE);
            if (!count) return 0;
            const available = count < buffer.length ? count : cast(DWORD) buffer.length;
            completed = 0;
            if (!WinHttpReadData(handle, buffer.ptr, available, null))
                throw new Exception("WinHTTP read failed (" ~ to!string(GetLastError()) ~ ").");
            awaitCompletion(WINHTTP_CALLBACK_STATUS_READ_COMPLETE);
            return count;
        }
    }

    string readError()
    {
        string result;
        ubyte[8192] buffer;
        while (result.length < 64 * 1024)
        {
            const n = read(buffer);
            if (!n) break;
            result ~= cast(string) buffer[0 .. n];
        }
        return result;
    }

    struct Timing { long connected, sent; uint protocol; }
    Timing timing() { synchronized (mutex) return Timing(connectedTicks, sentTicks, negotiatedProtocol); }

    void cancel()
    {
        HINTERNET request;
        synchronized (mutex)
        {
            cancelled = true;
            request = handle;
            handle = null;
            changed.notifyAll();
        }
        if (request !is null) WinHttpCloseHandle(request);
    }

    void finish()
    {
        cancel();
        synchronized (mutex) while (!closed) changed.wait();
        if (connection !is null)
        {
            pool.release(connection);
            connection = null;
        }
    }
}

/**
 * ISO download manager.
 *
 * Downloads an ISO over HTTP(S) using the Windows WinHTTP stack (a system
 * component, so the executable stays self-contained). Supports progress
 * reporting, cancellation, and resume of a partial download through HTTP
 * range requests.
 */
module auroraiso.download;

import std.conv : to;
import std.string : indexOf, split, strip;

/// Immutable view of a download's state, safe to read from the UI thread.
struct DownloadSnapshot
{
    bool active;
    bool finished;
    bool failed;
    bool cancelled;
    string error;
    ulong received;
    ulong total;
    string destination;

    double fraction() const pure nothrow @nogc @safe
    {
        if (total == 0)
            return 0.0;
        const value = cast(double) received / cast(double) total;
        return value > 1.0 ? 1.0 : value;
    }
}

/// A parsed HTTP(S) URL sufficient for WinHTTP.
struct ParsedUrl
{
    bool secure;
    string host;
    ushort port;
    string target; // path plus query, starting with '/'
}

/// Parse "https://host:port/path?query" into its WinHTTP components.
ParsedUrl parseUrl(string url)
{
    if (url.length == 0)
        throw new Exception("Empty URL");
    ParsedUrl parsed;
    string rest = url;
    const schemeEnd = rest.indexOf("://");
    if (schemeEnd < 0)
        throw new Exception("URL is missing a scheme: " ~ url);
    const scheme = rest[0 .. schemeEnd];
    if (scheme.length == 0)
        throw new Exception("URL is missing a scheme: " ~ url);
    parsed.secure = equalsIgnoreCase(scheme, "https");
    if (!parsed.secure && !equalsIgnoreCase(scheme, "http"))
        throw new Exception("Unsupported URL scheme \"" ~ scheme ~ "\"");
    rest = rest[schemeEnd + 3 .. $];

    const slash = rest.indexOf('/');
    string authority = slash < 0 ? rest : rest[0 .. slash];
    parsed.target = slash < 0 ? "/" : rest[slash .. $];
    if (parsed.target.length == 0)
        parsed.target = "/";

    const colon = authority.indexOf(':');
    if (colon >= 0)
    {
        parsed.host = authority[0 .. colon];
        auto portText = authority[colon + 1 .. $];
        parsed.port = portText.length == 0 ? cast(ushort)(parsed.secure ? 443 : 80) :
            cast(ushort) portText.to!uint;
    }
    else
    {
        parsed.host = authority;
        parsed.port = parsed.secure ? 443 : 80;
    }
    if (parsed.host.length == 0)
        throw new Exception("URL is missing a host: " ~ url);
    return parsed;
}

private bool equalsIgnoreCase(string a, string b)
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = cast(char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = cast(char)(cb + 32);
        if (ca != cb)
            return false;
    }
    return true;
}

version (Windows)
{
    private import core.thread : Thread;
    private import std.file : exists, getSize, remove, rename;
    private import std.stdio : File, StdioException;
    private import std.utf : toUTF16z;

    private enum uint winHttpAccessAutoProxy = 4;
    private enum uint winHttpFlagSecure = 0x00800000;
    private enum uint winHttpQueryStatusCode = 19;
    private enum uint winHttpQueryContentLength = 5;
    private enum uint winHttpQueryFlagNumber = 0x20000000;
    private enum uint winHttpQueryAcceptRanges = 42;
    private enum uint winHttpQueryFlagCustom = 0;
    private enum uint infWaitTimeoutMs = 60000;
    private enum uint infWaitError = 0xFFFFFFFF;

    private alias DWORD_PTR = size_t;

    private extern(Windows) nothrow @nogc
    {
        alias void* HINTERNET;
        alias int BOOL;
        alias uint DWORD;
        alias ushort WORD;
        alias wchar WCHAR;
        alias const(WCHAR)* LPCWSTR;
        alias WCHAR* LPWSTR;
        alias void* LPVOID;

        HINTERNET WinHttpOpen(LPCWSTR agent, DWORD accessType, LPCWSTR proxy,
            LPCWSTR proxyBypass, DWORD flags);
        HINTERNET WinHttpConnect(HINTERNET session, LPCWSTR server, WORD port,
            DWORD reserved);
        HINTERNET WinHttpOpenRequest(HINTERNET connect, LPCWSTR verb,
            LPCWSTR objectName, LPCWSTR httpVersion, LPCWSTR referrer,
            LPCWSTR* acceptTypes, DWORD flags);
        BOOL WinHttpSendRequest(HINTERNET request, LPCWSTR headers,
            DWORD headersLength, LPVOID optional, DWORD optionalLength,
            DWORD totalLength, DWORD_PTR context);
        BOOL WinHttpReceiveResponse(HINTERNET request, LPVOID reserved);
        BOOL WinHttpQueryHeaders(HINTERNET request, DWORD infoLevel, LPCWSTR name,
            LPVOID buffer, DWORD* bufferLength, DWORD* index);
        BOOL WinHttpReadData(HINTERNET request, LPVOID buffer, DWORD toRead,
            DWORD* read);
        BOOL WinHttpSetTimeouts(HINTERNET handle, int resolve, int connect,
            int send, int receive);
        BOOL WinHttpCloseHandle(HINTERNET handle);
    }

    private string winErrorText(DWORD code)
    {
        return "WinHTTP error " ~ code.to!string;
    }

    /**
     * Background ISO downloader. Create one per download, call `start`, poll
     * `snapshot`, and optionally `cancel`.
     */
    final class IsoDownloader
    {
        private Thread _thread;
        private shared bool _cancelRequested;
        private bool _running;
        private bool _finished;
        private bool _failed;
        private bool _cancelled;
        private string _error;
        private ulong _received;
        private ulong _total;
        private string _url;
        private string _destination;
        private bool _resume;

        /// Begin downloading `url` to `destination`. A ".part" file is used
        /// while in progress and renamed on success when `resume` is set.
        void start(string url, string destination, bool resume = true)
        {
            if (_running)
                throw new Exception("A download is already in progress");
            _url = url;
            _destination = destination;
            _resume = resume;
            _running = true;
            _finished = false;
            _failed = false;
            _cancelled = false;
            _error = "";
            _received = 0;
            _total = 0;
            _cancelRequested = false;
            _thread = new Thread(&worker).start();
        }

        /// Request cancellation; the worker stops at the next read boundary.
        void cancel()
        {
            _cancelRequested = true;
        }

        /// True while the worker thread is running.
        bool running() @trusted
        {
            return _running;
        }

        /// Take a consistent snapshot of the download state.
        DownloadSnapshot snapshot() @trusted
        {
            DownloadSnapshot value;
            value.active = _running;
            value.finished = _finished;
            value.failed = _failed;
            value.cancelled = _cancelled;
            value.error = _error;
            value.received = _received;
            value.total = _total;
            value.destination = _destination;
            return value;
        }

        private void worker()
        {
            try
            {
                runDownload();
                _finished = !_cancelled && !_failed;
            }
            catch (Exception error)
            {
                _failed = true;
                _error = error.msg;
            }
            _running = false;
        }

        private void runDownload()
        {
            const parsed = parseUrl(_url);
            const partPath = _destination ~ ".part";
            ulong resumeFrom = 0;
            if (_resume && exists(partPath))
                resumeFrom = getSize(partPath);

            auto session = WinHttpOpen("Aurora ISO/1.0".toUTF16z,
                winHttpAccessAutoProxy, null, null, 0);
            if (session is null)
                throw new Exception(winErrorText(0));
            scope(exit) WinHttpCloseHandle(session);
            WinHttpSetTimeouts(session, infWaitTimeoutMs, infWaitTimeoutMs,
                infWaitTimeoutMs, infWaitTimeoutMs);

            auto connect = WinHttpConnect(session, parsed.host.toUTF16z, parsed.port, 0);
            if (connect is null)
                throw new Exception("Cannot connect to " ~ parsed.host);
            scope(exit) WinHttpCloseHandle(connect);

            const flags = parsed.secure ? winHttpFlagSecure : 0;
            auto request = WinHttpOpenRequest(connect, "GET".toUTF16z,
                parsed.target.toUTF16z, null, null, null, flags);
            if (request is null)
                throw new Exception("Cannot create request for " ~ parsed.target);
            scope(exit) WinHttpCloseHandle(request);

            const rangeText = resumeFrom > 0
                ? "Range: bytes=" ~ resumeFrom.to!string ~ "-\r\n" : "";
            auto headerZ = rangeText.length > 0 ? rangeText.toUTF16z : null;

            if (!WinHttpSendRequest(request, headerZ,
                cast(DWORD)(rangeText.length * 2), null, 0, 0, 0))
                throw new Exception(winErrorText(0));

            if (!WinHttpReceiveResponse(request, null))
                throw new Exception(winErrorText(0));

            DWORD status = 0;
            DWORD statusSize = DWORD.sizeof;
            WinHttpQueryHeaders(request,
                winHttpQueryStatusCode | winHttpQueryFlagNumber, null,
                &status, &statusSize, null);

            DWORD contentLength = 0;
            DWORD lengthSize = DWORD.sizeof;
            WinHttpQueryHeaders(request,
                winHttpQueryContentLength | winHttpQueryFlagNumber, null,
                &contentLength, &lengthSize, null);

            bool append = false;
            if (status == 206 && resumeFrom > 0)
            {
                _received = resumeFrom;
                _total = resumeFrom + contentLength;
                append = true;
            }
            else
            {
                _received = 0;
                _total = contentLength;
                append = false;
            }

            auto file = File(partPath, append ? "ab" : "wb");
            auto buffer = new ubyte[1 << 16];
            while (true)
            {
                if (_cancelRequested)
                {
                    _cancelled = true;
                    break;
                }
                DWORD read = 0;
                if (!WinHttpReadData(request, buffer.ptr,
                    cast(DWORD) buffer.length, &read))
                    throw new Exception(winErrorText(0));
                if (read == 0)
                    break;
                file.rawWrite(buffer[0 .. read]);
                _received += read;
            }
            file.close();

            if (!_cancelled)
            {
                if (exists(_destination))
                    remove(_destination);
                rename(partPath, _destination);
            }
        }
    }
}
else
{
    /// Non-Windows placeholder so the project still builds elsewhere.
    final class IsoDownloader
    {
        private bool _running;
        private string _error;

        void start(string url, string destination, bool resume = true)
        {
            _running = true;
            _error = "Downloads are only implemented on Windows";
        }

        void cancel() {}

        bool running() const { return _running; }

        DownloadSnapshot snapshot() const
        {
            DownloadSnapshot value;
            value.failed = true;
            value.error = _error;
            return value;
        }
    }
}

unittest
{
    auto parsed = parseUrl("https://releases.ubuntu.com/24.04/ubuntu.iso");
    assert(parsed.secure);
    assert(parsed.host == "releases.ubuntu.com");
    assert(parsed.port == 443);
    assert(parsed.target == "/24.04/ubuntu.iso");

    auto plain = parseUrl("http://example.com:8080/a/b?c=1");
    assert(!plain.secure);
    assert(plain.host == "example.com");
    assert(plain.port == 8080);
    assert(plain.target == "/a/b?c=1");

    auto noPath = parseUrl("http://host");
    assert(noPath.target == "/" && noPath.port == 80);
}

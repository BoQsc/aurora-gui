module auroraweb.net;

version (Windows) pragma(lib, "wininet");

/**
 * Networking layer for Aurora Web.
 *
 * Provides URL parsing and a synchronous HTTP/HTTPS client built on the Win32
 * WinINet API (`wininet.dll`). This is the low-level transport used by
 * `WebPage.navigate`, `WebPage.fetchText`/`fetchBytes` and the `fetch` global
 * exposed to page scripts.
 *
 * All public functions here are defensive: they return an `HttpResponse` with
 * `error` set (or a `Url` with `ok == false`) instead of throwing across an FFI
 * boundary. Only genuinely exceptional conditions (out of memory, programming
 * errors) throw.
 */

import core.sys.windows.windows : DWORD, PVOID, LPCWSTR, MAKELANGID,
    LANG_NEUTRAL, SUBLANG_DEFAULT, FORMAT_MESSAGE_FROM_SYSTEM,
    FORMAT_MESSAGE_IGNORE_INSERTS, FormatMessageW, GetLastError;

import core.sys.windows.wininet : HINTERNET, InternetOpenW, InternetConnectW,
    HttpOpenRequestW, HttpSendRequestW, InternetReadFile, InternetCloseHandle,
    InternetSetOptionW, HttpQueryInfoW, INTERNET_OPEN_TYPE_PRECONFIG,
    INTERNET_SERVICE_HTTP, INTERNET_FLAG_SECURE, INTERNET_FLAG_NO_AUTO_REDIRECT,
    INTERNET_FLAG_NO_CACHE_WRITE, INTERNET_FLAG_RELOAD, INTERNET_FLAG_KEEP_CONNECTION,
    SECURITY_FLAG_IGNORE_UNKNOWN_CA, SECURITY_FLAG_IGNORE_CERT_CN_INVALID,
    SECURITY_FLAG_IGNORE_CERT_DATE_INVALID, INTERNET_OPTION_SECURITY_FLAGS,
    INTERNET_OPTION_CONNECT_TIMEOUT, INTERNET_OPTION_SEND_TIMEOUT,
    INTERNET_OPTION_RECEIVE_TIMEOUT, INTERNET_OPTION_DATA_SEND_TIMEOUT,
    INTERNET_OPTION_DATA_RECEIVE_TIMEOUT, HTTP_QUERY_STATUS_CODE,
    HTTP_QUERY_RAW_HEADERS_CRLF, HTTP_QUERY_CONTENT_TYPE,
    HTTP_QUERY_FLAG_NUMBER, INTERNET_DEFAULT_HTTP_PORT, INTERNET_DEFAULT_HTTPS_PORT;

import std.array : split;
import std.conv : to;
import std.string : indexOf, lastIndexOf, toLower, strip;

/// A parsed URL.
struct Url
{
    string scheme;
    string host;
    ushort port;
    string path;
    string query;
    string fragment;
    bool ok;              /// `false` if `parse` failed.

    /// Parse a URL string. Returns a `Url` with `ok == false` for invalid
    /// input. `ok == true` on success. Default ports are applied (`80` for
    /// http, `443` for https) when the URL omits one.
    static Url parse(string raw)
    {
    Url u;
    if (raw.length == 0) return u;

    string s = strip(raw);
    if (s.length == 0) return u;

    // Scheme: `scheme://...`
    auto schemeIdx = indexOf(s, "://");
    if (schemeIdx <= 0) return u;
    u.scheme = toLower(s[0 .. schemeIdx]);
    if (u.scheme != "http" && u.scheme != "https") return u;
    s = s[schemeIdx + 3 .. $];

    // Fragment: `#frag`
    auto fragIdx = indexOf(s, "#");
    if (fragIdx >= 0)
    {
        u.fragment = s[fragIdx + 1 .. $];
        s = s[0 .. fragIdx];
    }

    // Query: `?q=1`
    auto queryIdx = indexOf(s, "?");
    if (queryIdx >= 0)
    {
        u.query = s[queryIdx + 1 .. $];
        s = s[0 .. queryIdx];
    }

    // Host[:port]
    size_t slash = 0;
    while (slash < s.length && s[slash] != '/') slash++;
    auto authority = s[0 .. slash];
    if (authority.length == 0) return u;
    u.path = slash < s.length ? s[slash .. $] : "/";
    if (u.path.length == 0 || u.path[0] != '/') return u;

    // Port
    auto colon = indexOf(authority, ":");
    if (colon >= 0)
    {
        u.host = toLower(authority[0 .. colon]);
        auto portStr = authority[colon + 1 .. $];
        if (portStr.length == 0) return u;
        foreach (ch; portStr)
            if (ch < '0' || ch > '9') return u;
        auto p = to!ushort(portStr);
        if (p == 0) return u;
        u.port = p;
    }
    else
    {
        u.host = toLower(authority);
        u.port = u.scheme == "https" ? 443 : 80;
    }
    if (u.host.length == 0) return u;

    u.ok = true;
    return u;
    }
}

/// An HTTP response, mirroring the Fetch API shape.
struct HttpResponse
{
    int status;              /// HTTP status code (200 for success). 0 if failed.
    string[string] headers;  /// Lower-cased header name -> value.
    ubyte[] body;            /// Raw response body bytes.
    string finalUrl;         /// Final URL after redirects.
    string error;            /// Non-empty on transport failure.
}

/// Synchronous HTTP client on WinINet. Fetches a URL with the given method,
/// body and extra headers. Redirects (3xx with a Location header) are followed
/// manually up to 10 hops, relative and absolute. Never throws for ordinary
/// network failures; it returns an `HttpResponse` with `error` set instead.
HttpResponse httpFetch(string url, string method = "GET", ubyte[] body = null,
    string[string] extraHeaders = null)
{
    HttpResponse res;
    res.finalUrl = url;

    auto parsed = Url.parse(url);
    if (!parsed.ok)
    {
        res.error = "invalid URL: " ~ url;
        return res;
    }
    if (method.length == 0) method = "GET";

    auto hInternet = InternetOpenW(wide("Aurora Browser").ptr,
        INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
    if (hInternet is null)
    {
        res.error = win32ErrorMessage(GetLastError(), "InternetOpenW failed");
        return res;
    }
    scope (exit) InternetCloseHandle(hInternet);

    // Bounded timeouts so a dead host cannot hang the browser forever.
    uint timeout = 30000;
    InternetSetOptionW(hInternet, INTERNET_OPTION_CONNECT_TIMEOUT, &timeout,
        timeout.sizeof);
    InternetSetOptionW(hInternet, INTERNET_OPTION_SEND_TIMEOUT, &timeout,
        timeout.sizeof);
    InternetSetOptionW(hInternet, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeout,
        timeout.sizeof);
    InternetSetOptionW(hInternet, INTERNET_OPTION_DATA_SEND_TIMEOUT, &timeout,
        timeout.sizeof);
    InternetSetOptionW(hInternet, INTERNET_OPTION_DATA_RECEIVE_TIMEOUT, &timeout,
        timeout.sizeof);

    string currentUrl = url;
    for (int hop = 0; hop <= 10; hop++)
    {
        auto u = Url.parse(currentUrl);
        if (!u.ok)
        {
            res.error = "invalid redirect URL: " ~ currentUrl;
            return res;
        }

        auto hConnect = InternetConnectW(hInternet, wide(u.host).ptr, u.port,
            null, null, INTERNET_SERVICE_HTTP, 0, 0);
        if (hConnect is null)
        {
            res.error = win32ErrorMessage(GetLastError(),
                "InternetConnectW failed for " ~ currentUrl);
            return res;
        }
        scope (exit) InternetCloseHandle(hConnect);

        uint flags = INTERNET_FLAG_NO_AUTO_REDIRECT
            | INTERNET_FLAG_NO_CACHE_WRITE
            | INTERNET_FLAG_RELOAD
            | INTERNET_FLAG_KEEP_CONNECTION;
        if (u.scheme == "https") flags |= INTERNET_FLAG_SECURE;

        auto target = u.path;
        if (u.query.length) target ~= "?" ~ u.query;

        auto hRequest = HttpOpenRequestW(hConnect, wide(method).ptr, wide(target).ptr,
            null, null, null, flags, 0);
        if (hRequest is null)
        {
            res.error = win32ErrorMessage(GetLastError(),
                "HttpOpenRequestW failed for " ~ currentUrl);
            return res;
        }
        scope (exit) InternetCloseHandle(hRequest);

        // Ignore common self-signed/expired certificate problems for a
        // developer-oriented engine.
        if (u.scheme == "https")
        {
            uint secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA
                | SECURITY_FLAG_IGNORE_CERT_CN_INVALID
                | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
            InternetSetOptionW(hRequest, INTERNET_OPTION_SECURITY_FLAGS,
                &secFlags, secFlags.sizeof);
        }

        // Build the extra header string (CRLF-terminated).
        string headers = "User-Agent: Mozilla/5.0 (Aurora Browser)\r\n"
            ~ "Accept: text/html,application/xhtml+xml\r\n";
        foreach (k, v; extraHeaders)
            headers ~= k ~ ": " ~ v ~ "\r\n";

        auto bodyPtr = body.length ? body.ptr : null;
        auto bodyLen = cast(DWORD) body.length;
        auto headersWide = wide(headers);
        // dwHeadersLength is in TCHARs (wchar count), not bytes.
        auto sent = HttpSendRequestW(hRequest, headersWide.ptr,
            cast(DWORD) headersWide.length, bodyPtr, bodyLen);
        if (!sent)
        {
            res.error = win32ErrorMessage(GetLastError(),
                "HttpSendRequestW failed for " ~ currentUrl);
            return res;
        }

        // Status code (numeric flag required for DWORD-valued queries).
        DWORD statusCode = 0;
        DWORD statusLen = statusCode.sizeof;
        HttpQueryInfoW(hRequest, HTTP_QUERY_FLAG_NUMBER | HTTP_QUERY_STATUS_CODE,
            &statusCode, &statusLen, null);
        res.status = cast(int) statusCode;

        // Headers.
        auto rawHeaders = queryHeader(hRequest, HTTP_QUERY_RAW_HEADERS_CRLF);
        parseRawHeaders(rawHeaders, res.headers);
        auto ct = queryHeader(hRequest, HTTP_QUERY_CONTENT_TYPE);
        if (ct.length) res.headers["content-type"] = toLower(ct);

        // Redirect: follow the Location header, relative or absolute.
        auto location = "location" in res.headers;
        if (statusCode >= 300 && statusCode < 400 && location !is null &&
            (*location).length)
        {
            if (hop == 10)
            {
                res.error = "too many redirects (limit 10)";
                return res;
            }
            auto next = resolveLocation(currentUrl, *location);
            if (next.length == 0)
            {
                res.error = "failed to resolve redirect Location from " ~ currentUrl;
                return res;
            }
            currentUrl = next;
            res.finalUrl = currentUrl;
            continue;
        }

        // Read the body.
        res.body = readAll(hRequest);
        res.finalUrl = currentUrl;
        return res;
    }

    res.error = "too many redirects (limit 10)";
    return res;
}

/// Resolve a possibly-relative Location header against the current URL.
private string resolveLocation(string baseUrl, string location)
{
    auto loc = strip(location);
    if (loc.length == 0) return "";
    auto base = Url.parse(baseUrl);
    if (!base.ok) return "";
    if (indexOf(loc, "://") >= 0) return loc;

    auto q = indexOf(loc, "?");
    auto locPath = q >= 0 ? loc[0 .. q] : loc;
    auto locQuery = q >= 0 ? loc[q + 1 .. $] : "";

    auto u = base;
    if (locPath.length && locPath[0] == '/')
    {
        u.path = locPath;
    }
    else
    {
        auto dirEnd = lastIndexOf(base.path, "/");
        auto dir = dirEnd >= 0 ? base.path[0 .. dirEnd + 1] : "/";
        u.path = dir ~ locPath;
    }
    u.query = locQuery;
    u.fragment = "";
    return rebuildUrl(u);
}

private string rebuildUrl(Url u)
{
    string result = u.scheme ~ "://" ~ u.host;
    auto defaultPort = u.scheme == "https" ? 443 : 80;
    if (u.port != defaultPort) result ~= ":" ~ to!string(u.port);
    result ~= u.path;
    if (u.query.length) result ~= "?" ~ u.query;
    if (u.fragment.length) result ~= "#" ~ u.fragment;
    return result;
}

/// Read a WinINet query value into a D string (repeated calls to grow the
/// buffer handle ERROR_INSUFFICIENT_BUFFER).
private string queryHeader(HINTERNET hRequest, DWORD query)
{
    import core.sys.windows.winerror : ERROR_INSUFFICIENT_BUFFER;
    DWORD len = 0;
    auto ok = HttpQueryInfoW(hRequest, query, null, &len, null);
    if (ok && len == 0) return "";
    if (!ok && GetLastError() != ERROR_INSUFFICIENT_BUFFER) return "";
    if (len == 0) return "";

    auto nChars = (len / wchar.sizeof) + 2;
    auto buf = new wchar[](nChars);
    DWORD bufLen = cast(DWORD)(buf.length * wchar.sizeof);
    if (!HttpQueryInfoW(hRequest, query, buf.ptr, &bufLen, null))
        return "";
    // bufLen is the number of bytes written.
    auto chars = bufLen / wchar.sizeof;
    if (chars == 0) return "";
    // Trim the trailing NUL the API writes.
    size_t end = chars;
    if (end > 0 && buf[end - 1] == 0) end--;
    return to!string(buf[0 .. end]);
}

/// Parse a CRLF-delimited raw header blob into a lower-cased name->value map.
private void parseRawHeaders(string raw, ref string[string] headers)
{
    foreach (line; raw.split("\r\n"))
    {
        if (line.length == 0) continue;
        auto colon = indexOf(line, ":");
        if (colon <= 0) continue;
        auto name = toLower(line[0 .. colon]).strip();
        auto value = line[colon + 1 .. $].strip();
        if (name.length == 0) continue;
        headers[name] = value;
    }
}

/// Read the full request body with InternetReadFile.
private ubyte[] readAll(HINTERNET hRequest)
{
    ubyte[] body;
    ubyte[8192] chunk;
    while (true)
    {
        DWORD read = 0;
        auto ok = InternetReadFile(hRequest, chunk.ptr, chunk.length, &read);
        if (!ok) break;
        if (read == 0) break;
        body ~= chunk[0 .. read];
        if (read < chunk.length) break;
    }
    return body;
}

private wchar[] wide(string s)
{
    return to!wstring(s).dup;
}

/// Format a Win32 error code (from GetLastError) into a readable message.
private string win32ErrorMessage(DWORD code, string what)
{
    string text = what ~ " (error " ~ to!string(code) ~ ")";
    if (code == 0) return text;

    wchar[1024] buf;
    auto n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        code,
        MAKELANGID(cast(uint) LANG_NEUTRAL, cast(uint) SUBLANG_DEFAULT),
        buf.ptr,
        buf.length,
        null);
    if (n > 0)
    {
        size_t end = n;
        while (end > 0 && (buf[end - 1] == 0 || buf[end - 1] == '\r' ||
            buf[end - 1] == '\n'))
            end--;
        return text ~ ": " ~ to!string(buf[0 .. end]);
    }
    return text;
}

unittest
{
    // https://example.com:8443/a/b?q=1#frag
    auto u1 = Url.parse("https://example.com:8443/a/b?q=1#frag");
    assert(u1.ok, "https url should parse");
    assert(u1.scheme == "https", "scheme");
    assert(u1.host == "example.com", "host");
    assert(u1.port == 8443, "port");
    assert(u1.path == "/a/b", "path");
    assert(u1.query == "q=1", "query");
    assert(u1.fragment == "frag", "fragment");

    // http://x.com with default port 80.
    auto u2 = Url.parse("http://x.com");
    assert(u2.ok, "http url should parse");
    assert(u2.scheme == "http", "scheme http");
    assert(u2.host == "x.com", "host x.com");
    assert(u2.port == 80, "default http port");
    assert(u2.path == "/", "root path");

    // https default port 443.
    auto u3 = Url.parse("https://x.com");
    assert(u3.ok, "https url should parse");
    assert(u3.port == 443, "default https port");

    // Garbage is rejected.
    auto u4 = Url.parse("not a url");
    assert(!u4.ok, "garbage should fail");

    auto u5 = Url.parse("");
    assert(!u5.ok, "empty should fail");
}

unittest
{
    // Relative redirect resolution, offline.
    auto next1 = resolveLocation("http://a.com/x/y.html", "/z");
    assert(next1 == "http://a.com/z", "absolute-path redirect: " ~ next1);

    auto next2 = resolveLocation("http://a.com/x/y.html", "z.html");
    assert(next2 == "http://a.com/x/z.html", "relative redirect: " ~ next2);

    auto next3 = resolveLocation("http://a.com:8080/x/y.html", "https://b.com/z");
    assert(next3 == "https://b.com/z", "absolute redirect: " ~ next3);

    auto next4 = resolveLocation("http://a.com/x/y.html", "../z.html");
    assert(next4 == "http://a.com/x/../z.html", "parent redirect: " ~ next4);
}

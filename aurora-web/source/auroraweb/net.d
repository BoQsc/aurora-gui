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
    FORMAT_MESSAGE_IGNORE_INSERTS, FormatMessageW, GetLastError, BOOL, TRUE;

import core.sys.windows.wininet : HINTERNET, InternetOpenW, InternetConnectW,
    HttpOpenRequestW, HttpSendRequestW, InternetReadFile, InternetCloseHandle,
    InternetSetOptionW, HttpQueryInfoW, INTERNET_OPEN_TYPE_PRECONFIG,
    INTERNET_SERVICE_HTTP, INTERNET_FLAG_SECURE, INTERNET_FLAG_NO_AUTO_REDIRECT,
    INTERNET_FLAG_NO_CACHE_WRITE, INTERNET_FLAG_RELOAD, INTERNET_FLAG_KEEP_CONNECTION,
    INTERNET_FLAG_NO_UI, SECURITY_FLAG_IGNORE_UNKNOWN_CA,
    SECURITY_FLAG_IGNORE_CERT_CN_INVALID, SECURITY_FLAG_IGNORE_CERT_DATE_INVALID,
    INTERNET_OPTION_SECURITY_FLAGS, INTERNET_OPTION_HTTP_DECODING,
    INTERNET_OPTION_CONNECT_TIMEOUT, INTERNET_OPTION_SEND_TIMEOUT,
    INTERNET_OPTION_RECEIVE_TIMEOUT, INTERNET_OPTION_DATA_SEND_TIMEOUT,
    INTERNET_OPTION_DATA_RECEIVE_TIMEOUT, HTTP_QUERY_STATUS_CODE,
    HTTP_QUERY_RAW_HEADERS_CRLF, HTTP_QUERY_CONTENT_TYPE,
    HTTP_QUERY_FLAG_NUMBER, INTERNET_DEFAULT_HTTP_PORT, INTERNET_DEFAULT_HTTPS_PORT;

import std.array : split, join;
import std.conv : to;
import std.string : indexOf, lastIndexOf, toLower, strip;
import std.zlib : uncompress;

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
    string statusText;       /// Status text, e.g. `"404 Not Found"`.
    string[string] headers;  /// Lower-cased header name -> value.
    ubyte[] body;            /// Raw response body bytes (decompressed if the
                             /// server sent gzip/deflate `Content-Encoding`).
    string finalUrl;         /// Final URL after redirects.
    string error;            /// Non-empty on transport failure.

    /// `true` when the request reached the server and the status is in the
    /// 2xx success range. Always `false` on transport errors (`status == 0`).
    bool ok() const
    {
        return status >= 200 && status <= 299;
    }
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
            | INTERNET_FLAG_KEEP_CONNECTION
            | INTERNET_FLAG_NO_UI;
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

        // Ask WinINet to transparently decode gzip/deflate Content-Encoding.
        // If the option is unsupported we fall back to manual inflate below.
        int decoding = 1;
        InternetSetOptionW(hRequest, INTERNET_OPTION_HTTP_DECODING, &decoding,
            decoding.sizeof);

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
            ~ "Accept: text/html,application/xhtml+xml\r\n"
            ~ "Accept-Encoding: gzip, deflate\r\n";
        foreach (k, v; extraHeaders)
            headers ~= k ~ ": " ~ v ~ "\r\n";
        auto cookieLine = cookieHeader(currentUrl);
        if (cookieLine.length) headers ~= cookieLine ~ "\r\n";

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

        // Status text, e.g. "200 OK" or "404 Not Found", from the status line.
        res.statusText = statusTextFromRaw(rawHeaders, res.status);

        // Store any Set-Cookie headers in the jar.
        captureCookies(currentUrl, rawHeaders);

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
        // If WinINet did not decode a compressed body for us, decode it now.
        if (res.body.length)
        {
            auto enc = "content-encoding" in res.headers;
            if (enc !is null && (*enc).length)
            {
                auto decoded = decodeBody(res.body, toLower(*enc));
                if (decoded.length) res.body = decoded;
            }
        }
        res.finalUrl = currentUrl;
        return res;
    }

    res.error = "too many redirects (limit 10)";
    return res;
}

/// A single cookie stored in the module-level cookie jar.
struct Cookie
{
    string name;
    string value;
    string domain;  /// Lower-cased, without a leading dot.
    string path;    /// Defaults to "/" when the Set-Cookie omits it.
    bool secure;    /// Only sent over HTTPS.
}

/// Module-level cookie jar shared by all `httpFetch` calls.
Cookie[] cookieJar;

/// Check whether `body` starts with the gzip magic bytes `1f 8b`.
bool looksLikeGzip(ubyte[] body)
{
    return body.length >= 2 && body[0] == 0x1f && body[1] == 0x8b;
}

/// Inflate a raw DEFLATE stream (`Content-Encoding: deflate` as sent by some
/// servers without a zlib wrapper). Returns empty on failure.
ubyte[] inflateRawDeflate(ubyte[] data)
{
    if (data.length == 0) return null;
    try
    {
        // A windowBits of -15 selects raw deflate (no zlib/gzip header).
        return cast(ubyte[]) uncompress(data, 0, -15);
    }
    catch (Exception)
    {
        return null;
    }
}

/// Decompress a body according to a `Content-Encoding` value (already
/// lower-cased). Handles `gzip` and `deflate`; returns `data` unchanged for
/// any other (or unknown) encoding. Never throws.
ubyte[] decodeBody(ubyte[] data, string encoding)
{
    if (data.length == 0) return data;
    auto enc = strip(encoding);
    if (enc == "gzip")
    {
        // A gzip stream is a deflate stream with a wrapper; inflating it with
        // auto-detection (windowBits + 32) handles the wrapper transparently.
        if (!looksLikeGzip(data)) return data;
        try
        {
            auto inflated = cast(ubyte[]) uncompress(data, 0, 15 + 32);
            if (inflated.length) return inflated;
            return data;
        }
        catch (Exception)
        {
            return data;
        }
    }
    if (enc == "deflate")
    {
        // Some servers send a zlib-wrapped stream, others send raw deflate.
        // Try the zlib wrapper first, then raw deflate.
        try
        {
            auto inflated = cast(ubyte[]) uncompress(data, 0, 15);
            if (inflated.length) return inflated;
        }
        catch (Exception)
        {
        }
        auto raw = inflateRawDeflate(data);
        if (raw.length) return raw;
        return data;
    }
    return data;
}

/// Parse the `Set-Cookie` header(s) from a raw response header blob and add
/// them to the cookie jar. `url` is the URL the response came from.
private void captureCookies(string url, string rawHeaders)
{
    auto u = Url.parse(url);
    if (!u.ok) return;
    foreach (line; rawHeaders.split("\r\n"))
    {
        auto colon = indexOf(line, ":");
        if (colon <= 0) continue;
        auto name = toLower(line[0 .. colon]).strip();
        if (name != "set-cookie") continue;
        auto value = line[colon + 1 .. $].strip();
        auto cookie = parseSetCookie(value, u.host, u.path);
        if (cookie.name.length == 0) continue;
        // Same-name cookies with the same domain/path replace older entries.
        foreach (i, c; cookieJar)
        {
            if (c.name == cookie.name && c.domain == cookie.domain &&
                c.path == cookie.path)
            {
                cookieJar[i] = cookie;
                cookie = Cookie.init; // signal "already replaced"
                break;
            }
        }
        if (cookie.name.length) cookieJar ~= cookie;
    }
}

/// Parse a single `Set-Cookie` header value into a `Cookie`. `defaultDomain`
/// and `defaultPath` come from the URL that sent the cookie. No expiry/
/// Max-Age handling: cookies are kept for the life of the process.
Cookie parseSetCookie(string header, string defaultDomain, string defaultPath)
{
    Cookie c;
    auto parts = header.split(";");
    if (parts.length == 0) return c;

    auto pair = strip(parts[0]);
    auto eq = indexOf(pair, "=");
    if (eq <= 0) return c;
    c.name = strip(pair[0 .. eq]);
    c.value = strip(pair[eq + 1 .. $]);

    c.domain = toLower(strip(defaultDomain));
    c.path = "/";
    if (defaultPath.length && defaultPath[0] == '/')
    {
        // RFC 6265 default path: the directory of the request path.
        auto slash = lastIndexOf(defaultPath, "/");
        c.path = slash > 0 ? defaultPath[0 .. slash] : "/";
    }

    foreach (i; 1 .. parts.length)
    {
        auto attr = strip(parts[i]);
        auto ae = indexOf(attr, "=");
        auto an = ae >= 0 ? toLower(strip(attr[0 .. ae])) : toLower(strip(attr));
        auto av = ae >= 0 ? strip(attr[ae + 1 .. $]) : "";
        if (an == "domain")
        {
            auto d = toLower(strip(av));
            if (d.length && d[0] == '.') d = d[1 .. $];
            if (d.length) c.domain = d;
        }
        else if (an == "path")
        {
            auto p = strip(av);
            if (p.length == 0) p = "/";
            if (p[0] != '/') p = "/" ~ p;
            c.path = p;
        }
        else if (an == "secure")
        {
            c.secure = true;
        }
        // HttpOnly, Expires, Max-Age, SameSite are intentionally ignored.
    }
    return c;
}

/// Build a `Cookie: name=value; name2=value2` header line for `url`, or "" if
/// no stored cookie matches. Domain matches when the request host equals the
/// cookie domain or is a subdomain of it; the path must be a prefix of the
/// request path; Secure cookies are only sent over HTTPS.
string cookieHeader(string url)
{
    if (cookieJar.length == 0) return "";
    auto u = Url.parse(url);
    if (!u.ok) return "";

    string[] pieces;
    foreach (c; cookieJar)
    {
        if (!cookieMatches(c, u.host, u.path, u.scheme == "https"))
            continue;
        pieces ~= c.name ~ "=" ~ c.value;
    }
    if (pieces.length == 0) return "";
    return "Cookie: " ~ pieces.join("; ");
}

private bool cookieMatches(const Cookie c, string host, string path, bool https)
{
    if (https == false && c.secure) return false;
    // Domain match: exact or subdomain (suffix match on a label boundary).
    auto h = toLower(host);
    if (h != c.domain)
    {
        if (h.length <= c.domain.length) return false;
        auto suffix = h[h.length - c.domain.length .. $];
        if (suffix != c.domain) return false;
        auto dot = h[h.length - c.domain.length - 1];
        if (dot != '.') return false;
    }
    // Path match: cookie path must be a prefix of the request path.
    if (path.length < c.path.length) return false;
    if (path[0 .. c.path.length] != c.path) return false;
    return true;
}

/// Extract the status text (e.g. "404 Not Found") from the first HTTP status
/// line in a raw header blob. Falls back to a numeric-only string.
private string statusTextFromRaw(string rawHeaders, int status)
{
    auto line = rawHeaders.split("\r\n")[0];
    auto sp1 = indexOf(line, " ");
    if (sp1 < 0) return to!string(status);
    auto sp2 = indexOf(line, " ", sp1 + 1);
    if (sp2 < 0) return to!string(status);
    auto text = strip(line[sp2 + 1 .. $]);
    if (text.length == 0) return to!string(status);
    return text;
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

/// `HttpResponse.ok` / `statusText` handling.
unittest
{
    HttpResponse okRes;
    okRes.status = 200;
    assert(okRes.ok, "200 should be ok");
    assert(okRes.statusText.length == 0, "statusText defaults empty");

    HttpResponse notFound;
    notFound.status = 404;
    assert(!notFound.ok, "404 should not be ok");

    HttpResponse serverErr;
    serverErr.status = 500;
    assert(!serverErr.ok, "500 should not be ok");

    HttpResponse failed;
    failed.status = 0;
    assert(!failed.ok, "transport failure should not be ok");
}

/// `looksLikeGzip` magic detection.
unittest
{
    assert(!looksLikeGzip(null), "empty is not gzip");
    assert(!looksLikeGzip(cast(ubyte[]) "hello"), "text is not gzip");
    assert(!looksLikeGzip([0x1f]), "single byte is not gzip");
    assert(looksLikeGzip([0x1f, 0x8b]), "gzip magic detected");
    assert(looksLikeGzip([0x1f, 0x8b, 0x08, 0x00]), "gzip header detected");
}

/// gzip and deflate decompression round-trips through std.zlib.
unittest
{
    import std.zlib : compress;
    auto original = cast(ubyte[]) "The quick brown fox jumps over the lazy dog.";

    // zlib-wrapped deflate (what most servers call `Content-Encoding: deflate`).
    auto zlibWrapped = compress(original);
    auto deflated = decodeBody(zlibWrapped, "deflate");
    assert(deflated == original, "deflate round-trip failed");

    // Raw deflate without the zlib wrapper.
    auto rawStream = stripZlibWrapper(zlibWrapped);
    auto rawInflated = decodeBody(rawStream, "deflate");
    assert(rawInflated == original, "raw deflate round-trip failed");

    // Gzip: wrap the deflate stream in a gzip header/trailer manually.
    auto gz = gzipStream(rawStream, original);
    assert(looksLikeGzip(gz), "gzipStream must start with the gzip magic");
    auto gunzipped = decodeBody(gz, "gzip");
    assert(gunzipped == original, "gzip round-trip failed");

    // Unsupported encodings are passed through untouched.
    auto passthrough = decodeBody(original, "identity");
    assert(passthrough == original, "identity should pass through");
    auto br = decodeBody(original, "br");
    assert(br == original, "unknown encoding should pass through");
}

/// Strip the 2-byte zlib header and trailing 4-byte Adler-32 from a
/// zlib-wrapped stream to produce a raw DEFLATE stream.
private ubyte[] stripZlibWrapper(ubyte[] zlibStream)
{
    if (zlibStream.length < 7) return zlibStream;
    return zlibStream[2 .. $ - 4];
}

/// Wrap a raw deflate stream in a minimal gzip container (RFC 1952). The
/// CRC-32 and ISIZE trailer fields are computed from the original plaintext.
private ubyte[] gzipStream(ubyte[] rawDeflate, ubyte[] plaintext)
{
    import std.zlib : crc32;
    ubyte[] result;
    result ~= 0x1f; result ~= 0x8b; result ~= 0x08; result ~= 0x00;   // magic, CM=8, FLG=0
    result ~= 0x00; result ~= 0x00; result ~= 0x00; result ~= 0x00;   // MTIME = 0
    result ~= 0x00; result ~= 0xff;                                   // XFL, OS
    result ~= rawDeflate;
    auto crc = crc32(0, plaintext);
    result ~= [cast(ubyte) (crc & 0xff), cast(ubyte) ((crc >> 8) & 0xff),
        cast(ubyte) ((crc >> 16) & 0xff), cast(ubyte) ((crc >> 24) & 0xff)];
    auto isize = cast(uint) plaintext.length;
    result ~= [cast(ubyte) (isize & 0xff), cast(ubyte) ((isize >> 8) & 0xff),
        cast(ubyte) ((isize >> 16) & 0xff), cast(ubyte) ((isize >> 24) & 0xff)];
    return result;
}

/// Set-Cookie parsing, cookie jar matching, and cookie header generation.
unittest
{
    // Parsing a plain Set-Cookie.
    auto c1 = parseSetCookie("session=abc123; Path=/; Domain=example.com",
        "example.com", "/x/y");
    assert(c1.name == "session", "cookie name");
    assert(c1.value == "abc123", "cookie value");
    assert(c1.domain == "example.com", "cookie domain");
    assert(c1.path == "/", "cookie path");
    assert(!c1.secure, "cookie not secure");

    // Secure + HttpOnly + leading-dot domain + path defaulting.
    auto c2 = parseSetCookie("sid=xyz; Secure; HttpOnly; Domain=.example.org",
        "example.org", "/a/b");
    assert(c2.secure, "Secure flag parsed");
    assert(c2.domain == "example.org", "leading dot stripped");
    assert(c2.path == "/a", "default path is the request directory");

    // Path attribute and non-attribute garbage are handled.
    auto c3 = parseSetCookie("k=v; Path=/shop; SameSite=Lax", "shop.example.net",
        "/other");
    assert(c3.path == "/shop", "explicit path parsed");

    // Missing name is rejected.
    auto bad = parseSetCookie("=novalue", "x.com", "/");
    assert(bad.name.length == 0, "nameless cookie rejected");

    // Cookie header generation and matching against the jar.
    auto savedJar = cookieJar;
    scope (exit) cookieJar = savedJar;
    cookieJar.length = 0;

    cookieJar ~= Cookie("session", "abc", "example.com", "/", false);
    cookieJar ~= Cookie("sid", "xyz", "example.com", "/private", true);
    cookieJar ~= Cookie("other", "zzz", "other.com", "/", false);

    // Matching domain + path on plain HTTP: session only (sid is secure).
    auto h1 = cookieHeader("http://www.example.com/dir/page.html");
    assert(h1.length, "expected at least one cookie");
    assert(indexOf(h1, "session=abc") >= 0, "session cookie included");
    assert(indexOf(h1, "sid=xyz") < 0, "secure cookie excluded over http");

    // HTTPS + matching path: both example.com cookies apply.
    auto h2 = cookieHeader("https://www.example.com/private/file.html");
    assert(indexOf(h2, "session=abc") >= 0, "session cookie over https");
    assert(indexOf(h2, "sid=xyz") >= 0, "secure cookie included over https");

    // Non-matching domain: no cookies.
    auto h3 = cookieHeader("http://www.other.org/");
    assert(h3.length == 0, "unrelated domain must not receive cookies");

    // captureCookies populates the jar from a raw header blob.
    cookieJar.length = 0;
    captureCookies("http://example.com/", "HTTP/1.1 200 OK\r\n"
        ~ "Set-Cookie: theme=dark; Path=/\r\n"
        ~ "Content-Type: text/html\r\n");
    assert(cookieJar.length == 1, "one cookie captured");
    assert(cookieJar[0].name == "theme", "captured cookie name");
    assert(cookieJar[0].value == "dark", "captured cookie value");
    assert(cookieJar[0].domain == "example.com", "captured cookie domain");
    assert(cookieHeader("http://example.com/") == "Cookie: theme=dark",
        "captured cookie is sent back");
}


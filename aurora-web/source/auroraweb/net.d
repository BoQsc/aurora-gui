module auroraweb.net;

/**
 * Networking layer for Aurora Web.
 *
 * URL parsing plus a real HTTP/1.1 client written from scratch on the
 * cross-platform byte transport (`auroraweb.transport`, which is plain
 * `std.socket`). There is no WinINet, no libcurl and no `version(Windows)`
 * transport code: the request/response protocol, redirects, chunked transfer,
 * content-length framing, cookies and gzip/deflate decoding are all implemented
 * here and behave the same on Windows, Linux and macOS.
 *
 * All public functions are defensive: they return an `HttpResponse` with
 * `error` set (or a `Url` with `ok == false`) instead of throwing across an FFI
 * boundary. Only genuinely exceptional conditions throw.
 */

import core.time : Duration, dur;
import std.array : split, join;
import std.conv : to;
import std.string : indexOf, lastIndexOf, toLower, strip;
import std.zlib : uncompress;

import auroraweb.transport : ByteTransport, TcpTransport, TransportException;
import auroraweb.tls : TlsTransport;

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
    /// input. Default ports are applied (`80` for http, `443` for https) when
    /// the URL omits one.
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

/// A buffered reader over a `ByteTransport`. The HTTP parser pulls status
/// lines, header lines and bodies through this.
private final class HttpStream
{
    private ByteTransport _t;
    private ubyte[] _buf;
    private size_t _pos;
    private bool _eof;

    this(ByteTransport t) { _t = t; }

    private bool fill()
    {
        if (_eof) return false;
        ubyte[16384] tmp;
        auto n = _t.readSome(tmp);
        if (n <= 0) { _eof = true; return false; }
        _buf ~= tmp[0 .. cast(size_t) n];
        return true;
    }

    /// Read one CRLF-terminated line, returned without the CRLF. Returns null at
    /// EOF with no bytes pending; a final unterminated chunk is returned as-is.
    string readLine()
    {
        while (true)
        {
            for (size_t i = _pos; i + 1 < _buf.length; i++)
            {
                if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A)
                {
                    auto line = cast(string) _buf[_pos .. i].dup;
                    _pos = i + 2;
                    return line;
                }
            }
            if (!fill())
            {
                if (_pos < _buf.length)
                {
                    auto line = cast(string) _buf[_pos .. $].dup;
                    _pos = _buf.length;
                    return line;
                }
                return null;
            }
        }
    }

    /// Read exactly `n` bytes (fewer only if the peer closed early).
    ubyte[] readExact(size_t n)
    {
        while (_buf.length - _pos < n && fill()) {}
        auto avail = _buf.length - _pos;
        auto take = avail < n ? avail : n;
        auto bytes = _buf[_pos .. _pos + take].dup;
        _pos += take;
        return bytes;
    }

    /// Read everything until EOF.
    ubyte[] readToEof()
    {
        while (fill()) {}
        auto bytes = _buf[_pos .. $].dup;
        _pos = _buf.length;
        return bytes;
    }
}

/// Synchronous HTTP/1.1 client. Fetches `url` with `method`, an optional body
/// and extra headers. Redirects are followed up to 10 hops (relative and
/// absolute). Never throws for ordinary network failures; returns an
/// `HttpResponse` with `error` set instead.
HttpResponse httpFetch(string url, string method = "GET", ubyte[] body = null,
    string[string] extraHeaders = null)
{
    HttpResponse res;
    res.finalUrl = url;
    if (method.length == 0) method = "GET";

    string currentUrl = url;
    for (int hop = 0; hop <= 10; hop++)
    {
        auto u = Url.parse(currentUrl);
        if (!u.ok)
        {
            res.error = "invalid URL: " ~ currentUrl;
            return res;
        }

        ByteTransport conn;
        try
        {
            auto tcp = TcpTransport.connect(u.host, u.port);
            conn = u.scheme == "https"
                ? cast(ByteTransport) TlsTransport.connect(u.host, tcp)
                : cast(ByteTransport) tcp;
        }
        catch (Exception e)
        {
            res.error = e.msg;
            return res;
        }
        scope (exit) conn.close();

        string target = u.path.length ? u.path : "/";
        if (u.query.length) target ~= "?" ~ u.query;

        string hostHeader = u.host;
        auto defaultPort = u.scheme == "https" ? 443 : 80;
        if (u.port != defaultPort) hostHeader ~= ":" ~ to!string(u.port);

        string req = method ~ " " ~ target ~ " HTTP/1.1\r\n"
            ~ "Host: " ~ hostHeader ~ "\r\n"
            ~ "User-Agent: Mozilla/5.0 (Aurora Browser)\r\n"
            ~ "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
            ~ "Accept-Encoding: gzip, deflate\r\n"
            ~ "Connection: close\r\n";
        foreach (k, v; extraHeaders)
            req ~= k ~ ": " ~ v ~ "\r\n";
        auto cookieLine = cookieHeader(currentUrl);
        if (cookieLine.length) req ~= cookieLine ~ "\r\n";
        if (body.length) req ~= "Content-Length: " ~ to!string(body.length) ~ "\r\n";
        req ~= "\r\n";

        try
        {
            conn.writeAll(cast(const(ubyte)[]) req);
            if (body.length) conn.writeAll(cast(const(ubyte)[]) body);
        }
        catch (TransportException e)
        {
            res.error = e.msg;
            return res;
        }

        auto stream = new HttpStream(conn);

        // Status line, skipping any 1xx informational responses.
        int status;
        string statusLine;
        while (true)
        {
            statusLine = stream.readLine();
            if (statusLine is null || statusLine.length == 0)
            {
                res.error = "empty response from " ~ currentUrl;
                return res;
            }
            status = parseStatusCode(statusLine);
            if (status < 100 || status >= 200) break;
            string l;
            while ((l = stream.readLine()) !is null && l.length) {}
        }
        res.status = status;
        res.statusText = statusTextOf(statusLine);

        // Headers.
        string[string] headers;
        string[] setCookies;
        string line;
        while ((line = stream.readLine()) !is null && line.length)
        {
            auto colon = indexOf(line, ":");
            if (colon <= 0) continue;
            auto name = toLower(line[0 .. colon]).strip();
            auto value = line[colon + 1 .. $].strip();
            if (name == "set-cookie") setCookies ~= value;
            headers[name] = value;
        }
        res.headers = headers;
        foreach (sc; setCookies) storeSetCookie(sc, currentUrl);

        // Redirect.
        auto location = "location" in headers;
        if (status >= 300 && status < 400 && location !is null && (*location).length)
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
            // 303, and 301/302 answering a POST, become a bodyless GET.
            if (status == 303 || ((status == 301 || status == 302) && method == "POST"))
            {
                method = "GET";
                body = null;
            }
            continue;
        }

        // Body framing: chunked, content-length, or read-to-close.
        ubyte[] raw;
        auto te = "transfer-encoding" in headers;
        auto cl = "content-length" in headers;
        if (te !is null && indexOf(toLower(*te), "chunked") >= 0)
            raw = decodeChunked(stream.readToEof());
        else if (cl !is null)
            raw = stream.readExact(cast(size_t) parseLong((*cl).strip()));
        else
            raw = stream.readToEof();

        auto enc = "content-encoding" in headers;
        if (enc !is null && (*enc).length)
        {
            auto decoded = decodeBody(raw, toLower(*enc));
            if (decoded.length) raw = decoded;
        }

        res.body = raw;
        res.finalUrl = currentUrl;
        return res;
    }

    res.error = "too many redirects (limit 10)";
    return res;
}

/// Parse the numeric status code from `HTTP/1.1 200 OK`.
int parseStatusCode(string statusLine)
{
    auto sp = indexOf(statusLine, " ");
    if (sp < 0) return 0;
    int code = 0;
    foreach (ch; statusLine[sp + 1 .. $])
    {
        if (ch < '0' || ch > '9') break;
        code = code * 10 + (ch - '0');
    }
    return code;
}

/// Extract the reason phrase from `HTTP/1.1 200 OK` ("OK"); "" if absent.
string statusTextOf(string statusLine)
{
    auto sp1 = indexOf(statusLine, " ");
    if (sp1 < 0) return "";
    auto sp2 = indexOf(statusLine, " ", sp1 + 1);
    if (sp2 < 0) return "";
    return strip(statusLine[sp2 + 1 .. $]);
}

private long parseLong(string s)
{
    long v = 0;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9') break;
        v = v * 10 + (ch - '0');
    }
    return v;
}

/// Decode a `Transfer-Encoding: chunked` body. Returns the de-chunked bytes;
/// malformed input yields whatever was decoded before the error.
ubyte[] decodeChunked(const(ubyte)[] data)
{
    ubyte[] outBytes;
    size_t i = 0;
    while (i < data.length)
    {
        // Size line: hex digits, optional ";ext", terminated by CRLF.
        size_t lineEnd = i;
        while (lineEnd + 1 < data.length &&
            !(data[lineEnd] == 0x0D && data[lineEnd + 1] == 0x0A))
            lineEnd++;
        if (lineEnd + 1 >= data.length) break;
        string sizeLine = cast(string) data[i .. lineEnd];
        auto semi = indexOf(sizeLine, ";");
        if (semi >= 0) sizeLine = sizeLine[0 .. semi];
        long size = hexToLong(strip(sizeLine));
        i = lineEnd + 2;
        if (size <= 0) break;
        auto n = cast(size_t) size;
        if (i + n > data.length) { outBytes ~= data[i .. $]; return outBytes; }
        outBytes ~= data[i .. i + n];
        i += n;
        if (i + 1 < data.length && data[i] == 0x0D && data[i + 1] == 0x0A) i += 2;
    }
    return outBytes;
}

/// Parse a hexadecimal string into a long (0 on invalid digits).
long hexToLong(string s)
{
    long v = 0;
    foreach (ch; s)
    {
        int d;
        if (ch >= '0' && ch <= '9') d = ch - '0';
        else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
        else break;
        v = v * 16 + d;
    }
    return v;
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

/// Store one `Set-Cookie` value (from `url`) into the jar, replacing an
/// existing cookie with the same name/domain/path.
private void storeSetCookie(string setCookieValue, string url)
{
    auto u = Url.parse(url);
    if (!u.ok) return;
    auto cookie = parseSetCookie(setCookieValue, u.host, u.path);
    if (cookie.name.length == 0) return;
    foreach (i, c; cookieJar)
    {
        if (c.name == cookie.name && c.domain == cookie.domain &&
            c.path == cookie.path)
        {
            cookieJar[i] = cookie;
            return;
        }
    }
    cookieJar ~= cookie;
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

/// Resolve a possibly-relative Location header against the current URL.
string resolveUrl(string baseUrl, string reference)
{
    return resolveLocation(baseUrl, reference);
}

private string resolveLocation(string baseUrl, string location)
{
    auto loc = strip(location);
    if (loc.length == 0) return "";
    auto base = Url.parse(baseUrl);
    if (!base.ok) return "";
    if (indexOf(loc, "://") >= 0) return loc;

    // Protocol-relative reference (`//cdn.example/i.png`): a host-qualified URL
    // that inherits the base scheme. Treating it as a path produced
    // `https://currenthost//cdn.example/i.png`, so every such image 404'd —
    // a very common source of silently missing images.
    if (loc.length >= 2 && loc[0] == '/' && loc[1] == '/')
        return base.scheme ~ ":" ~ loc;

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

/// Status-line parsing and chunked decoding.
unittest
{
    assert(parseStatusCode("HTTP/1.1 200 OK") == 200, "status 200");
    assert(parseStatusCode("HTTP/1.1 404 Not Found") == 404, "status 404");
    assert(statusTextOf("HTTP/1.1 404 Not Found") == "Not Found", "reason phrase");

    // "Wiki" (4) + "pedia" (5) + " in\r\n\r\nchunks." (14) then 0-chunk.
    auto body = decodeChunked(cast(ubyte[]) "4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n");
    assert(cast(string) body == "Wikipedia in\r\n\r\nchunks.", "chunked decode: " ~ cast(string) body);
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

    // storeSetCookie populates the jar from a Set-Cookie value.
    cookieJar.length = 0;
    storeSetCookie("theme=dark; Path=/", "http://example.com/");
    assert(cookieJar.length == 1, "one cookie captured");
    assert(cookieJar[0].name == "theme", "captured cookie name");
    assert(cookieJar[0].value == "dark", "captured cookie value");
    assert(cookieJar[0].domain == "example.com", "captured cookie domain");
    assert(cookieHeader("http://example.com/") == "Cookie: theme=dark",
        "captured cookie is sent back");
}

version (unittest)
{
    // A minimal single-shot HTTP/1.1 server: accepts one connection, consumes
    // the request, sends `response`, and closes. Used by the loopback tests.
    private ushort serveOne(ref Thread[] keep, ubyte[] response)
    {
        import std.socket : Socket, InternetAddress, AddressFamily, SocketType,
            SocketOptionLevel, SocketOption;
        auto listener = new Socket(AddressFamily.INET, SocketType.STREAM);
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(4);
        auto port = (cast(InternetAddress) listener.localAddress).port;
        auto t = new Thread({
            auto conn = listener.accept();
            ubyte[8192] req;
            conn.receive(req);           // consume the request (we don't parse it)
            conn.send(response);
            conn.close();
            listener.close();
        });
        t.start();
        keep ~= t;
        return port;
    }

    unittest
    {
        import std.socket : Socket, InternetAddress, AddressFamily, SocketType;
        import std.zlib : compress;

        Thread[] keep;
        scope (exit) foreach (t; keep) t.join();

        // 1) Content-Length framing + headers.
        auto p1 = serveOne(keep, cast(ubyte[])
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello");
        auto r1 = httpFetch("http://127.0.0.1:" ~ to!string(p1) ~ "/x");
        assert(r1.status == 200, "status " ~ to!string(r1.status) ~ " err=" ~ r1.error);
        assert(cast(string) r1.body == "hello", "body: " ~ cast(string) r1.body);
        assert(r1.headers["content-type"] == "text/html", "content-type header");

        // 2) Chunked transfer-encoding.
        auto p2 = serveOne(keep, cast(ubyte[])
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n");
        auto r2 = httpFetch("http://127.0.0.1:" ~ to!string(p2) ~ "/");
        assert(cast(string) r2.body == "Wikipedia", "chunked body: " ~ cast(string) r2.body);

        // 3) gzip Content-Encoding is transparently decoded.
        auto plain = cast(ubyte[]) "compressed payload";
        auto gz = gzipStream(compress(plain)[2 .. $ - 4], plain);
        ubyte[] gzResp;
        gzResp ~= cast(ubyte[]) ("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: "
            ~ to!string(gz.length) ~ "\r\n\r\n");
        gzResp ~= gz;
        auto p3 = serveOne(keep, gzResp);
        auto r4 = httpFetch("http://127.0.0.1:" ~ to!string(p3) ~ "/");
        assert(r4.body == plain, "gzip body should decode");

        // 4) Redirect (302) to a second loopback server, relative to absolute.
        auto pB = serveOne(keep, cast(ubyte[])
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal");
        string redir = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:"
            ~ to!string(pB) ~ "/final\r\nContent-Length: 0\r\n\r\n";
        auto pA = serveOne(keep, cast(ubyte[]) redir);
        auto r5 = httpFetch("http://127.0.0.1:" ~ to!string(pA) ~ "/start");
        assert(r5.status == 200, "redirect final status " ~ to!string(r5.status) ~ " err=" ~ r5.error);
        assert(cast(string) r5.body == "final", "redirect body: " ~ cast(string) r5.body);
        assert(r5.finalUrl == "http://127.0.0.1:" ~ to!string(pB) ~ "/final",
            "finalUrl: " ~ r5.finalUrl);
    }
}

version (unittest)
{
    import core.thread : Thread;
}

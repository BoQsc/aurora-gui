module opencodelite.http;

import core.atomic : atomicLoad, atomicStore;
import core.sys.windows.winhttp;
import core.sys.windows.windows : DWORD, ERROR_HANDLE_EOF, GetLastError;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.utf : toUTF16z;

/// Thread-safe cancellation shared by the UI thread and the stream worker.
final class Cancellation
{
    private shared bool _requested;

    void cancel() @safe nothrow
    {
        atomicStore(_requested, true);
    }

    bool requested() @safe nothrow const
    {
        return atomicLoad(_requested);
    }
}

struct SseResult
{
    uint status;
    int events;
    bool canceled;
    string error;
}

alias SseEvent = void delegate(string data);

private struct ParsedUrl
{
    bool secure;
    string host;
    ushort port;
    string path;
}

private ParsedUrl parseUrl(string url)
{
    const schemeEnd = url.indexOf("://");
    if (schemeEnd < 0)
        throw new Exception("URL is missing a scheme: " ~ url);
    const scheme = url[0 .. schemeEnd].toLower;
    const rest = url[schemeEnd + 3 .. $];
    const slash = rest.indexOf('/');
    const authority = slash < 0 ? rest : rest[0 .. slash];
    if (authority.length == 0 || authority.indexOf('@') >= 0)
        throw new Exception("unsupported URL authority: " ~ url);

    ParsedUrl parsed;
    parsed.secure = scheme == "https";
    if (scheme != "http" && scheme != "https")
        throw new Exception("unsupported URL scheme: " ~ scheme);

    const colon = authority.lastIndexOf(':');
    if (colon >= 0)
    {
        parsed.host = authority[0 .. colon];
        parsed.port = to!ushort(authority[colon + 1 .. $]);
    }
    else
    {
        parsed.host = authority;
        parsed.port = parsed.secure ? 443 : 80;
    }
    parsed.path = slash < 0 ? "/" : rest[slash .. $];
    if (parsed.host.length == 0)
        throw new Exception("URL is missing a host: " ~ url);
    return parsed;
}

private string winError(string operation)
{
    return operation ~ " failed (Win32 error " ~ to!string(GetLastError) ~ ")";
}

/// Perform one blocking SSE POST. Cancellation is checked between events.
SseResult streamSse(string url, string headers, string body,
    SseEvent onEvent, Cancellation cancellation = null)
{
    SseResult result;
    if (cancellation is null)
        cancellation = new Cancellation();
    ParsedUrl target;
    try
        target = parseUrl(url);
    catch (Exception error)
    {
        result.error = error.msg;
        return result;
    }

    HINTERNET session;
    HINTERNET connect;
    HINTERNET request;
    scope (exit)
    {
        if (request !is null) WinHttpCloseHandle(request);
        if (connect !is null) WinHttpCloseHandle(connect);
        if (session !is null) WinHttpCloseHandle(session);
    }

    const agent = toUTF16z("AuroraOpenCodeLiteV2/0.1");
    session = WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (session is null)
    {
        result.error = winError("WinHttpOpen");
        return result;
    }
    WinHttpSetTimeouts(session, 5000, 5000, 5000, 30000);

    const host = toUTF16z(target.host);
    connect = WinHttpConnect(session, host, target.port, 0);
    if (connect is null)
    {
        result.error = winError("WinHttpConnect");
        return result;
    }

    const path = toUTF16z(target.path);
    request = WinHttpOpenRequest(connect, toUTF16z("POST"), path,
        null, null, null, target.secure ? WINHTTP_FLAG_SECURE : 0);
    if (request is null)
    {
        result.error = winError("WinHttpOpenRequest");
        return result;
    }

    const headerText = toUTF16z(headers);
    if (!WinHttpSendRequest(request, headerText, cast(DWORD) -1,
            body.length == 0 ? null : cast(void*) body.ptr,
            cast(DWORD) body.length, cast(DWORD) body.length, 0))
    {
        result.error = winError("WinHttpSendRequest");
        return result;
    }
    if (!WinHttpReceiveResponse(request, null))
    {
        result.error = winError("WinHttpReceiveResponse");
        return result;
    }

    DWORD status;
    DWORD statusSize = DWORD.sizeof;
    if (!WinHttpQueryHeaders(request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            null, &status, &statusSize, null))
    {
        result.error = winError("WinHttpQueryHeaders");
        return result;
    }
    result.status = status;
    if (status < 200 || status >= 300)
    {
        string detail;
        for (size_t total; total < 4096;)
        {
            ubyte[1024] buffer;
            DWORD read;
            if (!WinHttpReadData(request, buffer.ptr,
                    cast(DWORD) buffer.length, &read) || read == 0)
                break;
            detail ~= cast(string) buffer[0 .. read];
            total += read;
        }
        detail = detail.strip;
        if (detail.length > 600)
            detail = detail[0 .. 600];
        result.error = "HTTP status " ~ to!string(status)
            ~ (detail.length > 0 ? ": " ~ detail : "");
        return result;
    }

    string pending;
    bool done;
    while (!done && !cancellation.requested)
    {
        ubyte[4096] buffer;
        DWORD read;
        if (!WinHttpReadData(request, buffer.ptr, cast(DWORD) buffer.length,
                &read))
        {
            if (GetLastError == ERROR_HANDLE_EOF)
                break;
            result.error = winError("WinHttpReadData");
            break;
        }
        if (read == 0)
            break;
        pending ~= cast(string) buffer[0 .. read];

        size_t lineStart;
        while (true)
        {
            const lineEnd = pending.indexOf('\n', lineStart);
            if (lineEnd < 0)
                break;
            auto line = pending[lineStart .. lineEnd];
            if (line.length != 0 && line[$ - 1] == '\r')
                line = line[0 .. $ - 1];
            lineStart = lineEnd + 1;
            if (!line.startsWith("data:"))
                continue;
            const data = line[5 .. $].strip;
            if (data == "[DONE]")
            {
                done = true;
                break;
            }
            if (data.length == 0)
                continue;
            ++result.events;
            if (onEvent !is null)
                onEvent(data);
            if (cancellation.requested)
            {
                result.canceled = true;
                done = true;
                break;
            }
        }
        if (lineStart != 0)
            pending = pending[lineStart .. $];
    }
    if (cancellation.requested)
        result.canceled = true;
    return result;
}

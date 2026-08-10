module auroraopencode.opencode_client;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.sys.windows.windows : DWORD, BOOL, FALSE, TRUE, GetLastError;
import core.sys.windows.wininet : ERROR_INTERNET_OPERATION_CANCELLED,
    HTTP_QUERY_STATUS_CODE, HttpOpenRequestW, HttpQueryInfoW, HttpSendRequestW,
    HINTERNET, INTERNET_DEFAULT_HTTPS_PORT, INTERNET_FLAG_NO_CACHE_WRITE,
    INTERNET_FLAG_PRAGMA_NOCACHE, INTERNET_FLAG_RELOAD, INTERNET_FLAG_SECURE,
    INTERNET_OPEN_TYPE_PRECONFIG, INTERNET_OPTION_CONNECT_TIMEOUT,
    INTERNET_OPTION_RECEIVE_TIMEOUT, INTERNET_OPTION_SEND_TIMEOUT,
    INTERNET_SERVICE_HTTP, InternetCloseHandle, InternetConnectW, InternetOpenW,
    InternetOpenUrlW, InternetReadFile, InternetSetOptionW;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf;
import std.utf : toUTF16z;

/** Kinds of events the client delivers to the UI thread. */
enum OpenCodeEventKind
{
    chatBegin,   // assistant reply started (text = "")
    delta,       // streaming fragment (text = fragment, reasoning = kind)
    done,        // assistant reply finished (text = full content)
    error,       // request failed (text = message)
    models,      // model list refreshed (modelIds = ids)
}

struct OpenCodeEvent
{
    OpenCodeEventKind kind;
    string text;
    bool reasoning;
    string[] modelIds;
    bool cancelled;
}

private struct HttpTarget
{
    string host;
    ushort port;
    string path;
}

private enum DWORD defaultConnectTimeoutMs = 30_000;
private enum DWORD defaultSendTimeoutMs = 60_000;
private enum DWORD defaultReceiveTimeoutMs = 120_000;

/** Parse an OpenAI-compatible base URL into host/port/path. */
private HttpTarget parseHttpTarget(string baseUrl, string suffix)
{
    string url = baseUrl.stripTrailingSlashes();
    string scheme = "https";
    if (startsWithAscii(url, "https://")) url = url[8 .. $];
    else if (startsWithAscii(url, "http://"))
    {
        url = url[7 .. $];
        scheme = "http";
    }

    const slash = url.indexOf('/');
    const hostPort = slash < 0 ? url : url[0 .. cast(size_t) slash];
    const pathPart = slash < 0 ? "" : url[cast(size_t) slash .. $];

    string host = hostPort;
    ushort port = scheme == "https" ? 443 : 80;
    const colon = hostPort.indexOf(':');
    if (colon >= 0 && hostPort.lastIndexOf(':') == colon)
    {
        host = hostPort[0 .. cast(size_t) colon];
        const portText = hostPort[cast(size_t) colon + 1 .. $];
        if (portText.length > 0)
        {
            try port = to!ushort(portText);
            catch (Exception) {}
        }
    }

    string path = pathPart.length == 0 ? "" : pathPart;
    if (path.length > 0 && path[$ - 1] == '/') path = path[0 .. $ - 1];
    return HttpTarget(host, port, path ~ suffix);
}

private bool startsWithAscii(string value, string prefix)
{
    return value.length >= prefix.length && value[0 .. prefix.length] == prefix;
}

private string stripTrailingSlashes(string value)
{
    while (value.length > 0 && value[$ - 1] == '/')
        value = value[0 .. $ - 1];
    return value;
}

private string wininetErrorText(DWORD code)
{
    return "WinINet error " ~ to!string(code);
}

/**
 * Minimal OpenAI-compatible chat client over WinINet.
 *
 * Requests run on worker threads. Every event is pushed onto a mutex-guarded
 * queue that the UI drains each tick, so streaming text never blocks the GUI
 * thread. Cancellation closes the live request handle, which unblocks the
 * streaming read with ERROR_INTERNET_OPERATION_CANCELLED.
 */
final class OpenCodeClient
{
    private Mutex _mutex;
    private OpenCodeEvent[] _pending;
    private Thread _worker;
    private bool _chatBusy;
    private bool _modelsBusy;
    private bool _cancel;
    private HINTERNET _chatHandle;
    private HINTERNET _modelsHandle;
    private HINTERNET _session;
    private bool _sessionClosed;
    private string _baseUrl;
    private string _apiKey;
    private string _streamReasoning;
    private string _streamContent;

    this(string baseUrl, string apiKey)
    {
        _mutex = new Mutex();
        _baseUrl = baseUrl;
        _apiKey = apiKey;
    }

    string baseUrl() const @safe pure nothrow @nogc { return _baseUrl; }
    string apiKey() const @safe pure nothrow @nogc { return _apiKey; }

    void setCredentials(string baseUrl, string apiKey)
    {
        _baseUrl = baseUrl;
        _apiKey = apiKey;
    }

    bool busy()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _chatBusy;
    }

    bool modelsBusy()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _modelsBusy;
    }

    /** Start a streaming chat completion. Roles/contents are parallel arrays. */
    void startChat(const(string)[] roles, const(string)[] contents,
        string model, bool thinking)
    {
        _mutex.lock();
        if (_chatBusy)
        {
            _mutex.unlock();
            return;
        }
        _chatBusy = true;
        _cancel = false;
        _chatHandle = null;
        _mutex.unlock();

        string[] roleCopy;
        string[] contentCopy;
        foreach (index; 0 .. roles.length)
        {
            roleCopy ~= roles[index].dup;
            contentCopy ~= contents[index].dup;
        }

        _worker = new Thread({
            runChatRequest(roleCopy, contentCopy, model, thinking);
        });
        _worker.isDaemon = true;
        _worker.start();
    }

    void cancel()
    {
        _mutex.lock();
        _cancel = true;
        auto handle = _chatHandle;
        _chatHandle = null;
        _mutex.unlock();
        if (handle !is null)
        {
            try InternetCloseHandle(handle);
            catch (Exception) {}
        }
    }

    void fetchModels()
    {
        _mutex.lock();
        if (_modelsBusy)
        {
            _mutex.unlock();
            return;
        }
        _modelsBusy = true;
        _modelsHandle = null;
        _mutex.unlock();

        _worker = new Thread({ runModelsRequest(); });
        _worker.isDaemon = true;
        _worker.start();
    }

    /** Release the shared session. Call once on shutdown. */
    void closeSession()
    {
        _mutex.lock();
        _sessionClosed = true;
        auto session = _session;
        _session = null;
        _mutex.unlock();
        if (session !is null)
        {
            try InternetCloseHandle(session);
            catch (Exception) {}
        }
    }

    /** Move all pending events into `output` and clear the queue. */
    void drain(ref OpenCodeEvent[] output)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        output.length = 0;
        output ~= _pending;
        _pending.length = 0;
    }

    private void pushEvent(OpenCodeEvent event)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        _pending ~= event;
    }

    private void finishWorker(bool chat)
    {
        _mutex.lock();
        if (chat)
        {
            _chatBusy = false;
            _chatHandle = null;
        }
        else
        {
            _modelsBusy = false;
            _modelsHandle = null;
        }
        _mutex.unlock();
    }

    private HINTERNET openSession()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_session is null && !_sessionClosed)
        {
            auto session = InternetOpenW(toUTF16z("Aurora OpenCode"),
                INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
            if (session !is null)
            {
                DWORD connectTimeout = defaultConnectTimeoutMs;
                InternetSetOptionW(session, INTERNET_OPTION_CONNECT_TIMEOUT,
                    &connectTimeout, cast(DWORD) connectTimeout.sizeof);
                DWORD sendTimeout = defaultSendTimeoutMs;
                InternetSetOptionW(session, INTERNET_OPTION_SEND_TIMEOUT,
                    &sendTimeout, cast(DWORD) sendTimeout.sizeof);
                DWORD receiveTimeout = defaultReceiveTimeoutMs;
                InternetSetOptionW(session, INTERNET_OPTION_RECEIVE_TIMEOUT,
                    &receiveTimeout, cast(DWORD) receiveTimeout.sizeof);
                _session = session;
            }
        }
        if (_session is null)
            throw new Exception(_sessionClosed
                ? "The network client is closed."
                : "Could not open an internet session.");
        return _session;
    }

    private HINTERNET registerRequest(HINTERNET handle, bool chat)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_cancel && chat)
        {
            _chatHandle = null;
            return null;
        }
        if (chat) _chatHandle = handle;
        else _modelsHandle = handle;
        return handle;
    }

    private void unregisterRequest(HINTERNET handle, bool chat)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (chat && _chatHandle is handle) _chatHandle = null;
        else if (!chat && _modelsHandle is handle) _modelsHandle = null;
    }

    private void runChatRequest(string[] roles, string[] contents,
        string model, bool thinking)
    {
        scope (exit) finishWorker(true);

        bool cancelled;

        try
        {
            const target = parseHttpTarget(_baseUrl, "/chat/completions");
            const body = buildChatBody(roles, contents, model, thinking);
            _streamReasoning = "";
            _streamContent = "";

            auto session = openSession();

            auto connection = InternetConnectW(session, toUTF16z(target.host),
                target.port, null, null, INTERNET_SERVICE_HTTP, 0, 0);
            if (connection is null)
                throw new Exception("Could not connect to " ~ target.host);
            scope (exit) InternetCloseHandle(connection);

            const flags = INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD |
                INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_PRAGMA_NOCACHE;
            auto request = HttpOpenRequestW(connection, "POST"w.ptr,
                toUTF16z(target.path), null, null, null, flags, 0);
            if (request is null)
                throw new Exception("Could not create the chat request.");
            if (registerRequest(request, true) is null)
            {
                InternetCloseHandle(request);
                throw new Exception("Chat request cancelled.");
            }
            scope (exit)
            {
                unregisterRequest(request, true);
                InternetCloseHandle(request);
            }

            const headers = "Authorization: Bearer " ~ _apiKey ~
                "\r\nContent-Type: application/json\r\n" ~
                "Accept: text/event-stream\r\n";
            auto bodyBytes = cast(ubyte[]) body.dup;
            if (!HttpSendRequestW(request, toUTF16z(headers), -1,
                bodyBytes.ptr, cast(DWORD) bodyBytes.length))
                throw new Exception("Chat request failed (" ~
                    wininetErrorText(GetLastError()) ~ ").");

            DWORD statusCode;
            DWORD statusLength = cast(DWORD) statusCode.sizeof;
            if (HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE, &statusCode,
                &statusLength, null) && statusCode != 200)
            {
                const detail = readAllAsUtf8(request);
                throw new Exception("Upstream returned HTTP " ~
                    to!string(statusCode) ~
                    (detail.length > 0 ? ": " ~ truncateForError(detail) : ""));
            }

            pushEvent(OpenCodeEvent(OpenCodeEventKind.chatBegin));

            ubyte[8192] buffer;
            string lineBuffer;
            while (!_cancel)
            {
                DWORD readBytes;
                if (!InternetReadFile(request, buffer.ptr,
                    cast(DWORD) buffer.length, &readBytes))
                {
                    const errorCode = GetLastError();
                    if (_cancel || errorCode == ERROR_INTERNET_OPERATION_CANCELLED)
                    {
                        cancelled = true;
                        break;
                    }
                    throw new Exception("Stream read failed (" ~
                        wininetErrorText(errorCode) ~ ").");
                }
                if (readBytes == 0) break;

                lineBuffer ~= cast(string) buffer[0 .. cast(size_t) readBytes];
                lineBuffer = dispatchSseLines(lineBuffer);

                if (_cancel)
                {
                    cancelled = true;
                    break;
                }
            }

            if (cancelled)
                pushEvent(OpenCodeEvent(OpenCodeEventKind.done,
                    _streamContent, false, null, true));
            else
                pushEvent(OpenCodeEvent(OpenCodeEventKind.done,
                    _streamContent, false, null, false));
        }
        catch (Exception error)
        {
            _mutex.lock();
            const cancelNow = _cancel;
            _mutex.unlock();
            if (cancelNow)
                pushEvent(OpenCodeEvent(OpenCodeEventKind.done,
                    _streamContent, false, null, true));
            else
                pushEvent(OpenCodeEvent(OpenCodeEventKind.error, error.msg));
        }
    }

    private void runModelsRequest()
    {
        scope (exit) finishWorker(false);

        try
        {
            const target = parseHttpTarget(_baseUrl, "/models");
            auto session = openSession();

            const headers = "Authorization: Bearer " ~ _apiKey ~ "\r\n";
            const flags = INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD |
                INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_PRAGMA_NOCACHE;
            auto request = InternetOpenUrlW(session, toUTF16z(targetUrl(target)),
                toUTF16z(headers), -1, flags, 0);
            if (request is null)
                throw new Exception("Could not open the models URL.");
            if (registerRequest(request, false) is null)
            {
                InternetCloseHandle(request);
                return;
            }
            scope (exit)
            {
                unregisterRequest(request, false);
                InternetCloseHandle(request);
            }

            const body = readAllAsUtf8(request);
            string[] ids;
            auto value = parseJSON(body);
            if (value.type == JSONType.object)
            {
                auto data = "data" in value.object;
                if (data !is null && data.type == JSONType.array)
                {
                    foreach (entry; data.array)
                    {
                        if (entry.type != JSONType.object) continue;
                        auto id = "id" in entry.object;
                        if (id !is null && id.type == JSONType.string &&
                            id.str.length > 0)
                            ids ~= id.str.dup;
                    }
                }
            }
            if (ids.length == 0)
                throw new Exception("The models endpoint returned no models.");
            pushEvent(OpenCodeEvent(OpenCodeEventKind.models, "", false, ids));
        }
        catch (Exception error)
        {
            pushEvent(OpenCodeEvent(OpenCodeEventKind.error, error.msg));
        }
    }

    private static string targetUrl(const HttpTarget target)
    {
        const scheme = target.port == 80 ? "http" : "https";
        return scheme ~ "://" ~ target.host ~ (target.port == 80 ||
            target.port == 443 ? "" : ":" ~ to!string(target.port)) ~
            target.path;
    }

    private static string buildChatBody(const(string)[] roles,
        const(string)[] contents, string model, bool thinking)
    {
        JSONValue root;
        root["model"] = model;
        JSONValue messages = JSONValue(string[].init);
        foreach (index; 0 .. roles.length)
        {
            JSONValue message;
            message["role"] = roles[index];
            message["content"] = contents[index];
            messages.array ~= message;
        }
        root["messages"] = messages;
        root["stream"] = true;
        if (!thinking)
            root["thinking"] = false;
        return root.toString();
    }

    private static string readAllAsUtf8(HINTERNET request)
    {
        string result;
        ubyte[8192] buffer;
        while (true)
        {
            DWORD readBytes;
            if (!InternetReadFile(request, buffer.ptr,
                cast(DWORD) buffer.length, &readBytes))
                break;
            if (readBytes == 0) break;
            result ~= cast(string) buffer[0 .. cast(size_t) readBytes];
        }
        return result;
    }

    private static string truncateForError(string value)
    {
        if (value.length <= 800) return value;
        return value[0 .. 800] ~ "…";
    }

    private string dispatchSseLines(string buffer)
    {
        size_t start;
        while (true)
        {
            const newline = indexOf(buffer, '\n', start);
            if (newline < 0) break;
            const line = buffer[start .. cast(size_t) newline];
            start = cast(size_t) newline + 1;
            processSseLine(line);
        }
        return start >= buffer.length ? "" : buffer[start .. $];
    }

    private void processSseLine(string line)
    {
        if (line.length > 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (!startsWithAscii(line, "data:")) return;
        const payload = line[5 .. $];
        if (payload.length == 0) return;
        if (payload == "[DONE]") return;

        JSONValue value;
        try value = parseJSON(payload);
        catch (Exception) return;
        if (value.type != JSONType.object) return;

        auto choices = "choices" in value.object;
        if (choices is null || choices.type != JSONType.array ||
            choices.array.length == 0) return;
        const choice = choices.array[0];
        if (choice.type != JSONType.object) return;
        auto delta = "delta" in choice.object;
        if (delta is null || delta.type != JSONType.object) return;

        string fragment;
        bool reasoningFragment;
        if (auto found = "reasoning_content" in delta.object)
        {
            if (found.type == JSONType.string && found.str.length > 0)
            {
                fragment = found.str;
                reasoningFragment = true;
            }
        }
        if (fragment.length == 0)
        {
            if (auto found = "content" in delta.object)
            {
                if (found.type == JSONType.string && found.str.length > 0)
                    fragment = found.str;
            }
        }

        if (fragment.length == 0) return;
        if (reasoningFragment) _streamReasoning ~= fragment;
        else _streamContent ~= fragment;
        pushEvent(OpenCodeEvent(OpenCodeEventKind.delta, fragment,
            reasoningFragment));
    }
}

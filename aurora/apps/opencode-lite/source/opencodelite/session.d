module opencodelite.session;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import opencodelite.http : Cancellation, SseResult, streamSse;
import opencodelite.settings : LiteSettings;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip, stripRight;

enum SessionEventKind
{
    delta,
    done,
    failed,
}

struct SessionEvent
{
    SessionEventKind kind;
    string text;
}

struct ChatMessage
{
    string role;
    string content;
}

/// One in-memory conversation with one in-flight streaming request.
final class ChatSession
{
    private LiteSettings _settings;
    private ChatMessage[] _messages;
    private Mutex _mutex;
    private SessionEvent[] _events;
    private Cancellation _cancellation;
    private Thread _worker;
    private bool _busy;

    this(LiteSettings settings)
    {
        _settings = settings;
        _mutex = new Mutex();
    }

    LiteSettings settings() const
    {
        return _settings;
    }

    void updateSettings(LiteSettings settings)
    {
        synchronized (_mutex)
            _settings = settings;
    }

    ChatMessage[] messages()
    {
        synchronized (_mutex)
            return _messages.dup;
    }

    bool busy()
    {
        synchronized (_mutex)
            return _busy;
    }

    SessionEvent[] drain()
    {
        synchronized (_mutex)
        {
            auto copy = _events.dup;
            _events = null;
            return copy;
        }
    }

    void cancel()
    {
        Cancellation cancellation;
        synchronized (_mutex)
            cancellation = _cancellation;
        if (cancellation !is null)
            cancellation.cancel();
    }

    void send(string prompt)
    {
        prompt = prompt.strip;
        if (prompt.length == 0)
            return;
        synchronized (_mutex)
        {
            if (_busy)
                return;
            _messages ~= ChatMessage("user", prompt);
            _busy = true;
            _cancellation = new Cancellation();
        }
        _worker = new Thread(&runStream);
        _worker.isDaemon = true;
        _worker.start();
    }

    private void emit(SessionEventKind kind, string text)
    {
        synchronized (_mutex)
            _events ~= SessionEvent(kind, text);
    }

    private static string deltaText(string payload)
    {
        try
        {
            const document = parseJSON(payload);
            if (document.type != JSONType.object)
                return "";
            auto choices = "choices" in document.object;
            if (choices is null || choices.type != JSONType.array
                || choices.array.length == 0)
                return "";
            const choice = choices.array[0];
            if (choice.type != JSONType.object)
                return "";
            auto delta = "delta" in choice.object;
            if (delta is null || delta.type != JSONType.object)
                return "";
            auto content = "content" in delta.object;
            if (content is null || content.type != JSONType.string)
                return "";
            return content.str;
        }
        catch (Exception)
        {
            return "";
        }
    }

    private void runStream()
    {
        ChatMessage[] history;
        LiteSettings settings;
        Cancellation cancellation;
        synchronized (_mutex)
        {
            history = _messages.dup;
            settings = _settings;
            cancellation = _cancellation;
        }

        JSONValue[] messages;
        foreach (message; history)
        {
            JSONValue item;
            item["role"] = message.role;
            item["content"] = message.content;
            messages ~= item;
        }
        JSONValue payload;
        payload["model"] = settings.model;
        payload["stream"] = true;
        payload["messages"] = messages;

        string headers = "Content-Type: application/json\r\n"
            ~ "Accept: text/event-stream\r\n";
        if (settings.apiKey.length != 0)
            headers ~= "Authorization: Bearer " ~ settings.apiKey ~ "\r\n";
        const url = settings.baseUrl.stripRight("/") ~ "/chat/completions";

        string assistant;
        const result = streamSse(url, headers, payload.toString(),
            (string data) {
                const delta = deltaText(data);
                if (delta.length == 0)
                    return;
                assistant ~= delta;
                emit(SessionEventKind.delta, delta);
            }, cancellation);

        synchronized (_mutex)
        {
            if (assistant.length != 0)
                _messages ~= ChatMessage("assistant", assistant);
            _busy = false;
            _cancellation = null;
        }

        if (result.canceled)
            emit(SessionEventKind.done, "Stopped");
        else if (result.error.length != 0)
            emit(SessionEventKind.failed, result.error);
        else
            emit(SessionEventKind.done, "Complete");
    }
}

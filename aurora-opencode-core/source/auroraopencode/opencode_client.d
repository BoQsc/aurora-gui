module auroraopencode.opencode_client;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import core.sys.windows.windows : DWORD, BOOL, FALSE, TRUE, GetLastError;
import core.sys.windows.wininet : ERROR_INTERNET_OPERATION_CANCELLED,
    HTTP_QUERY_FLAG_NUMBER, HTTP_QUERY_STATUS_CODE, HttpOpenRequestW,
    HttpQueryInfoW, HttpSendRequestW, HINTERNET, INTERNET_DEFAULT_HTTPS_PORT,
    INTERNET_FLAG_NO_CACHE_WRITE, INTERNET_FLAG_PRAGMA_NOCACHE,
    INTERNET_FLAG_RELOAD, INTERNET_FLAG_SECURE, INTERNET_OPEN_TYPE_PRECONFIG,
    INTERNET_OPTION_CONNECT_TIMEOUT, INTERNET_OPTION_RECEIVE_TIMEOUT,
    INTERNET_OPTION_SEND_TIMEOUT, INTERNET_SERVICE_HTTP, InternetCloseHandle,
    InternetConnectW, InternetOpenW, InternetOpenUrlW, InternetReadFile,
    InternetSetOptionW;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.utf : toUTF16z;
import auroraopencode.core : ChatImageAttachment, ChatRequestMessage,
    OpenCodeToolCall, OpenCodeToolDef, isLoopbackApiBaseUrl,
    isOpenCodeApiBaseUrl, isVisionModel;
import auroraopencode.logging : logError, logInfo;

/** Kinds of events the client delivers to the UI thread. */
enum OpenCodeEventKind
{
    chatBegin,   // assistant reply started (text = "")
    delta,       // streaming fragment (text = fragment, reasoning = kind)
    usage,       // live usage update while streaming (token fields populated)
    toolCallDelta, // assistant is generating tool arguments (toolCalls = partial)
    toolCalls,   // assistant finished requesting tools (text = content, toolCalls set)
    toolResult,  // a tool execution finished (text = output, toolName/toolCallId set)
    done,        // assistant reply finished (text = full content)
    error,       // request failed (text = message)
    models,      // model list refreshed (modelIds = ids)
    modelsError, // model discovery failed; must not fail an active chat
}

struct OpenCodeEvent
{
    OpenCodeEventKind kind;
    string text;
    bool reasoning;
    string[] modelIds;
    bool cancelled;
    int promptTokens;
    int completionTokens;
    int totalTokens;
    OpenCodeToolCall[] toolCalls;
    string toolName;
    string toolCallId;
    bool toolFailed;
    int diffAdditions;
    int diffDeletions;
    string diffText;
    long elapsedMs; // tool wall-clock duration in ms, carried to the UI
    // Opaque UI-supplied identity for routing late events. Zero is reserved for
    // standalone parser tests and callers that do not need request isolation.
    ulong requestId;
    // Provider terminal reason (`stop`, `length`, `max_tokens`, ...). Kept
    // separate from cancellation so the UI can offer a safe continuation.
    string finishReason;
}

private struct HttpTarget
{
    string host;
    ushort port;
    string path;
    bool secure;
}

private enum DWORD defaultConnectTimeoutMs = 30_000;
/// Attempts for a momentary upstream blip (5xx). Bounded, so a request the
/// server refuses every single time still fails instead of hanging the turn.
private enum uint maxTransientChatAttempts = 3;
/// Interval between replays of a 429. The gateway says "the upstream model
/// provider is temporarily unavailable, please try again in a moment", so the
/// retries are steady rather than a growing backoff: a fixed three seconds is
/// frequent enough to pick the answer up moments after the provider returns,
/// and an exponential cap would leave the reply waiting up to its ceiling
/// longer than necessary.
private enum int rateLimitRetryIntervalMs = 3_000;

private bool isTransientChatStatus(DWORD status)
{
    // 429 is the gateway's "provider temporarily unavailable / slow down"
    // signal (not just a hard quota refusal), so the turn is replayed instead
    // of failing outright.
    return status == 429 || status == 500 || status == 502 ||
        status == 503 || status == 504;
}

/// Exposes the deliberately narrow retry policy without requiring a live HTTP
/// server in unit tests. Transient upstream conditions (provider busy or a
/// momentary 5xx) are replayed; client errors are never replayed automatically.
public bool transientChatStatusForTesting(uint status)
{
    return isTransientChatStatus(cast(DWORD) status);
}

/// Test-only: the retry decision for `nextAttempt` (1-based) after `status`.
public bool transientRetryAllowedForTesting(uint status, uint nextAttempt)
{
    return mayRetryTransientStatus(cast(DWORD) status, nextAttempt);
}

/// Test-only: the pause taken before attempt `attempt` of a retry sequence.
public int transientRetryBackoffMsForTesting(uint status, uint attempt)
{
    return transientRetryBackoffMs(cast(DWORD) status, attempt);
}

/**
 * Whether another attempt may follow a transient failure.
 *
 * A 5xx is usually a momentary blip, so it keeps the short bounded budget. A
 * 429 says the upstream model provider itself is unavailable ("try again in a
 * moment"); those clear on their own, so the turn is replayed until the
 * provider answers rather than failing and making the user re-send by hand.
 * The wait stays safe because it is interruptible: Stop, and closing the
 * session, both end the retry loop immediately.
 */
private bool mayRetryTransientStatus(DWORD status, uint nextAttempt)
{
    if (!isTransientChatStatus(status)) return false;
    if (status == 429) return true;
    return nextAttempt < maxTransientChatAttempts;
}

/**
 * True when a 429 states a usage limit and a reset time, i.e. the caller is out
 * of quota rather than catching the provider at a bad moment.
 *
 * The OpenCode Go gateway answers that way: "5-hour usage limit reached.
 * Resets in 3hr 52min. To continue using this model now, enable usage from your
 * available balance: ...". That will not clear on its next three-second poll,
 * and retrying it forever hides both the reason and the reset time, so the
 * turn fails immediately and shows the provider's own sentence.
 */
private bool isPersistentRateLimit(string detail)
{
    return containsAsciiIgnoreCase(detail, "usage limit") ||
        containsAsciiIgnoreCase(detail, "limit reached") ||
        containsAsciiIgnoreCase(detail, "resets in") ||
        containsAsciiIgnoreCase(detail, "reset in") ||
        containsAsciiIgnoreCase(detail, "quota") ||
        containsAsciiIgnoreCase(detail, "available balance");
}

/// Test-only: exposes the quota-wall decision.
public bool persistentRateLimitForTesting(string detail)
{
    return isPersistentRateLimit(detail);
}

/// How long an automatic re-send may be postponed. Bounds a misread duration
/// ("reset in 9000 days") to something a running app can still honour.
private enum long maxAutoResendDelayMs = 86_400_000;

/**
 * How long to wait before sending a failed turn again on its own, in
 * milliseconds. Negative means "do not": the failure needs the user's
 * decision, and replaying it would only hide the reason the provider gave.
 *
 * `attempt` counts the automatic re-sends already made for this turn, so a
 * provider that stays unreachable is polled at a widening interval instead of
 * being hammered.
 *
 * A failed turn used to wait for the user to press Retry even when the
 * provider had already said exactly when it would accept work again.
 */
public long autoResendDelayMs(string failureText, uint attempt)
{
    // A stated reset time is the provider answering "when", so use it as given.
    const resetMs = quotaResetDelayMs(failureText);
    if (resetMs > 0)
        return resetMs > maxAutoResendDelayMs ? maxAutoResendDelayMs : resetMs;
    // A quota wall with no time, or a request the server rejected on its own
    // terms (a bad key, a malformed body), fails identically when replayed.
    if (isPersistentRateLimit(failureText)) return -1;
    if (containsAsciiIgnoreCase(failureText, "HTTP 400") ||
        containsAsciiIgnoreCase(failureText, "HTTP 401") ||
        containsAsciiIgnoreCase(failureText, "HTTP 403") ||
        containsAsciiIgnoreCase(failureText, "HTTP 404") ||
        containsAsciiIgnoreCase(failureText, "HTTP 422"))
        return -1;
    // Anything else is a transport or provider blip (a stream that died, a
    // gateway that refused, a socket error): wait, then send the same turn
    // again, backing off to half a minute.
    const delay = 3_000 + 3_000 * cast(long) attempt;
    return delay > 30_000 ? 30_000 : delay;
}

/**
 * Milliseconds until the moment a "... resets in 3hr 52min" notice names, or 0
 * when the failure text states no reset time.
 *
 * The provider's own sentence is the only reliable "when" available, so it is
 * read rather than guessed. The duration is scanned as number/unit pairs and
 * stops at the first pair without a unit, so the prose that follows
 * ("To continue using this model now, ...") cannot be misread as more time.
 */
public long quotaResetDelayMs(string failureText)
{
    const lower = failureText.toLower();
    const marker = lower.indexOf("reset");
    if (marker < 0) return 0;
    auto rest = lower[cast(size_t) marker + 5 .. $];
    // The notice reads "resets in <duration>" (or "reset in ...").
    const inIndex = rest.indexOf("in ");
    if (inIndex < 0 || inIndex > 3) return 0;
    rest = rest[cast(size_t) inIndex + 3 .. $];

    long total;
    size_t index;
    int fields;
    while (index < rest.length && fields < 4)
    {
        while (index < rest.length &&
            (rest[index] == ' ' || rest[index] == ',')) ++index;
        if (index >= rest.length || rest[index] < '0' || rest[index] > '9')
            break;
        long value;
        while (index < rest.length && rest[index] >= '0' && rest[index] <= '9')
        {
            value = value * 10 + (rest[index] - '0');
            ++index;
        }
        while (index < rest.length && rest[index] == ' ') ++index;
        size_t unitLength;
        const unitMs = resetUnitMs(rest[index .. $], unitLength);
        if (unitMs == 0) break;
        index += unitLength;
        total += value * unitMs;
        ++fields;
    }
    return total;
}

/// Duration of the unit keyword at the start of `text`, and its length. Longest
/// keyword first, so "min" is not read as "m" followed by prose.
private long resetUnitMs(string text, out size_t length)
{
    static immutable string[] words = ["days", "day", "hours", "hour", "hrs",
        "hr", "minutes", "minute", "mins", "min", "seconds", "second", "secs",
        "sec", "h", "m", "s"];
    static immutable long[] durations = [86_400_000, 86_400_000, 3_600_000,
        3_600_000, 3_600_000, 3_600_000, 60_000, 60_000, 60_000, 60_000,
        1_000, 1_000, 1_000, 1_000, 3_600_000, 60_000, 1_000];
    foreach (index, word; words)
        if (startsWithAscii(text, word))
        {
            length = word.length;
            return durations[index];
        }
    length = 0;
    return 0;
}

/// Pause before replaying a transient failure. A 5xx keeps the original short
/// interval; a 429 waits `rateLimitRetryIntervalMs` so the provider is polled
/// at a steady rate until it answers.
private int transientRetryBackoffMs(DWORD status, uint attempt)
{
    if (status != 429) return cast(int) attempt * 250;
    return rateLimitRetryIntervalMs;
}

/// Thinking-mode providers (DeepSeek-class routes behind the OpenCode Go
/// gateway) reject a request whose assistant messages omit `reasoning_content`:
/// "The `reasoning_content` in the thinking mode must be passed back to the
/// API". That is a request-shape problem Aurora can repair, not a fatal upstream
/// failure, so the client re-sends the payload with the reasoning replayed
/// instead of blocking the answer.
private bool isReasoningReplayRejection(string detail)
{
    return containsAsciiIgnoreCase(detail, "reasoning_content") &&
        (containsAsciiIgnoreCase(detail, "thinking") ||
            containsAsciiIgnoreCase(detail, "passed back"));
}

/// Test-only: exposes the reasoning-replay recovery decision.
public bool recoverableReasoningErrorForTesting(string detail)
{
    return isReasoningReplayRejection(detail);
}

/// Test-only: exposes the gateway-wrapper stripping applied to failures.
public string condenseUpstreamDetailForTesting(string detail)
{
    return condenseUpstreamDetail(detail);
}

/// Case-insensitive ASCII substring search. Provider payloads can be tens of
/// kilobytes, so this scans in place instead of lowering a whole copy.
private bool containsAsciiIgnoreCase(string haystack, string needle)
{
    if (needle.length == 0) return true;
    if (haystack.length < needle.length) return false;
    foreach (index; 0 .. haystack.length - needle.length + 1)
    {
        bool match = true;
        foreach (offset; 0 .. needle.length)
        {
            if (asciiLower(haystack[index + offset]) !=
                asciiLower(needle[offset]))
            {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

private char asciiLower(char value)
{
    return value >= 'A' && value <= 'Z' ? cast(char)(value + 32) : value;
}

/// The OpenCode Go route wraps provider failures in several layers ("Error from
/// provider (X): Upstream request failed: [code] text"). Showing every layer
/// turned one actionable sentence into a wall of gateway plumbing, so keep the
/// provider's own message.
private static string condenseUpstreamDetail(string detail)
{
    string text = detail.strip;
    if (startsWithAscii(text, "Error from provider ("))
    {
        const close = text.indexOf("):");
        if (close >= 0) text = text[cast(size_t) close + 2 .. $].strip;
    }
    if (startsWithAscii(text, "Upstream request failed:"))
    {
        const colon = text.indexOf(':');
        text = text[cast(size_t) colon + 1 .. $].strip;
    }
    if (text.length > 1 && text[0] == '[')
    {
        const close = text.indexOf("] ");
        if (close > 0) text = text[cast(size_t) close + 2 .. $].strip;
    }
    return text;
}

/// Plain-language failure shown only when the provider keeps refusing the
/// conversation's thinking state even after Aurora replayed it and dropped
/// hosted reasoning. The raw gateway text names internal fields and reads like
/// a bug in the user's own prompt, so it stays in the log.
private immutable string reasoningReplayFailureText =
    "The provider refused this conversation in thinking mode: it requires the " ~
    "assistant's earlier thinking to be sent back, and it still refused after " ~
    "Aurora replayed it. Turn Thinking off for this chat (or start a new chat) " ~
    "and send again.";

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
    return HttpTarget(host, port, path ~ suffix, scheme == "https");
}

private DWORD requestFlags(const ref HttpTarget target)
{
    DWORD flags = INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE |
        INTERNET_FLAG_PRAGMA_NOCACHE;
    if (target.secure) flags |= INTERNET_FLAG_SECURE;
    return flags;
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

/// CommandCode's API (and the legacy opencode-api mirror) sit behind
/// Cloudflare and block non-browser clients (HTTP 1010), so requests to those
/// hosts identify as a desktop browser.
private immutable string clientBrowserUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ~
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// The OpenCode Go gateway explicitly asks clients to identify with their own
/// product user agent rather than a generic SDK/browser string, and monitors
/// traffic for abuse. Verified live: this UA is accepted (no Cloudflare 1010),
/// unlike on the CommandCode host.
private immutable string clientOpenCodeUserAgent = "aurora-opencode/0.66.9";

/// The user agent to send to `baseUrl`'s host.
private string userAgentFor(string baseUrl)
{
    return isOpenCodeApiBaseUrl(baseUrl)
        ? clientOpenCodeUserAgent : clientBrowserUserAgent;
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
    private bool _chatBusy;
    // True while the worker is paused between replays of a transient upstream
    // failure. A 429 is replayed until the provider answers, which can take a
    // minute or more, so the UI reads this to say the provider is busy instead
    // of leaving a retrying request looking frozen.
    private bool _transientRetrying;
    private bool _modelsBusy;
    private bool _cancel;
    private HINTERNET _chatHandle;
    private HINTERNET _modelsHandle;
    private HINTERNET _session;
    private bool _sessionClosed;
    private string _baseUrl;
    private string _apiKey;
    // Stable per-conversation id for the OpenCode Go `x-opencode-session`
    // routing header. The UI updates it when the active conversation changes;
    // the constructor value covers requests made before any session exists.
    private string _opencodeSession;
    private string _streamReasoning;
    private string _streamContent;
    private ulong _streamRequestId;
    private OpenCodeToolCall[] _streamToolCalls;
    // How many of `_streamToolCalls` already had a name announced to the UI, so
    // a progress event fires once per new tool call (not on every argument
    // fragment, which would flood the UI thread while a file body streams).
    private size_t _streamToolNamesPushed;
    // While a tool's arguments stream, the UI wants periodic progress so the
    // live `+N -M` counters grow as the file body arrives. Emitting one event
    // per fragment would flood the UI thread, so progress is throttled to at
    // most once per `_toolProgressIntervalMs` and only when the arguments
    // actually changed.
    private int _toolProgressIntervalMs = 120;
    private MonoTime _lastToolProgressTime;
    private size_t _streamToolArgBytes;
    private bool _streamWantedTools;
    private string _streamFinishReason;
    private int _lastPromptTokens;
    private int _lastCompletionTokens;
    private int _lastTotalTokens;
    private bool _streamActive;
    private int _lastPushedPrompt;
    private int _lastPushedCompletion;
    private int _lastPushedTotal;

    this(string baseUrl, string apiKey)
    {
        _mutex = new Mutex();
        _baseUrl = baseUrl;
        _apiKey = apiKey;
        _opencodeSession = "aurora-session-" ~
            to!string(MonoTime.currTime.ticks);
    }

    string baseUrl() const @safe pure nothrow @nogc { return _baseUrl; }
    string apiKey() const @safe pure nothrow @nogc { return _apiKey; }

    void setCredentials(string baseUrl, string apiKey)
    {
        _baseUrl = baseUrl;
        _apiKey = apiKey;
    }

    /// Set the stable conversation id sent as `x-opencode-session` to the
    /// OpenCode gateway. Ignored when empty, so a caller without a session
    /// keeps the constructor's per-run id.
    void setOpenCodeSession(string value)
    {
        if (value.length > 0) _opencodeSession = value;
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

    /// True while the chat request is waiting out a transient upstream failure
    /// (HTTP 429 or a 5xx) before replaying it. Polled by the UI.
    bool retryingTransient()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _transientRetrying;
    }

    private void setTransientRetry()
    {
        _mutex.lock();
        _transientRetrying = true;
        _mutex.unlock();
    }

    private void clearTransientRetry()
    {
        _mutex.lock();
        _transientRetrying = false;
        _mutex.unlock();
    }

    /** Start a streaming chat completion. Roles/contents are parallel arrays. */
    void startChat(const(string)[] roles, const(string)[] contents,
        string model, bool thinking)
    {
        ChatRequestMessage[] messages;
        foreach (index; 0 .. roles.length)
        {
            ChatRequestMessage message;
            message.role = roles[index];
            message.content = contents[index];
            messages ~= message;
        }
        startChatMessages(messages, null, model, thinking);
    }

    /** Start a streaming chat completion with tool definitions. */
    void startChatMessages(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, string model, bool thinking,
        ulong requestId = 0)
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

        ChatRequestMessage[] messageCopy;
        foreach (message; messages)
        {
            ChatRequestMessage copy;
            copy.role = message.role.dup;
            copy.content = message.content.dup;
            copy.reasoningContent = message.reasoningContent.dup;
            copy.toolCallId = message.toolCallId.dup;
            foreach (image; message.images)
            {
                ChatImageAttachment imageCopy;
                imageCopy.mimeType = image.mimeType.dup;
                imageCopy.base64Data = image.base64Data.dup;
                imageCopy.name = image.name.dup;
                copy.images ~= imageCopy;
            }
            foreach (call; message.toolCalls)
            {
                OpenCodeToolCall callCopy;
                callCopy.id = call.id.dup;
                callCopy.name = call.name.dup;
                callCopy.arguments = call.arguments.dup;
                copy.toolCalls ~= callCopy;
            }
            messageCopy ~= copy;
        }

        OpenCodeToolDef[] toolCopy;
        foreach (tool; tools)
        {
            OpenCodeToolDef copy;
            copy.name = tool.name.dup;
            copy.description = tool.description.dup;
            copy.parametersJson = tool.parametersJson.dup;
            toolCopy ~= copy;
        }

        auto worker = new Thread({
            runChatRequest(messageCopy, toolCopy, model, thinking, requestId);
        });
        worker.isDaemon = true;
        worker.start();
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

        auto worker = new Thread({ runModelsRequest(); });
        worker.isDaemon = true;
        worker.start();
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

    /**
     * Move all pending events into `output` and recycle the caller's previous
     * buffer for producers. This is a constant-time swap under the mutex: the
     * streaming worker never waits while the UI copies a potentially large
     * burst of events, and steady-state ticks allocate no event arrays.
     */
    void drain(ref OpenCodeEvent[] output)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        auto reusable = output;
        output = _pending;
        _pending = reusable;
        _pending.length = 0;
    }

    /**
     * Push an event from the application thread (e.g. a completed tool
     * result) into the same queue the UI drains each tick, so the tool loop
     * and the streaming client share one event channel.
     */
    void pushLocalEvent(OpenCodeEvent event)
    {
        pushEvent(event);
    }

    /// True when the client is being cancelled or closed, so in-flight request
    /// failures are expected shutdown artifacts rather than reportable errors.
    bool shuttingDown()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return _cancel || _sessionClosed;
    }

    private void pushEvent(OpenCodeEvent event)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();

        // These are snapshots, not an ordered history. When the UI is slower
        // than a provider's fragment rate, retaining obsolete snapshots only
        // causes redundant transcript rebuilds and badge layout work.
        if (_pending.length > 0 &&
            (event.kind == OpenCodeEventKind.toolCallDelta ||
             event.kind == OpenCodeEventKind.usage) &&
            _pending[$ - 1].kind == event.kind)
        {
            _pending[$ - 1] = event;
            return;
        }
        _pending ~= event;
    }

    /// Tag every event produced by the current streaming request. Tool-result
    /// events are tagged by their executor because they outlive this worker.
    private void pushStreamEvent(OpenCodeEvent event)
    {
        event.requestId = _streamRequestId;
        pushEvent(event);
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

    private void runChatRequest(ChatRequestMessage[] messages,
        OpenCodeToolDef[] tools, string model, bool thinking, ulong requestId)
    {
        scope (exit)
        {
            finishWorker(true);
            _streamActive = false;
        }

        bool cancelled;

        try
        {
            const target = parseHttpTarget(_baseUrl, "/chat/completions");
            // Request-shape recovery state. A thinking-mode provider can reject
            // the payload because the assistant's reasoning was not replayed
            // (first recovery) and, if it still refuses, because hosted
            // reasoning cannot continue on this history (second recovery).
            bool replayReasoning;
            bool droppedReasoning;
            string body = buildChatBody(messages, tools, model, thinking,
                _baseUrl);
            _streamReasoning = "";
            _streamContent = "";
            _streamRequestId = requestId;
            _streamToolCalls.length = 0;
            _streamToolNamesPushed = 0;
            _streamToolArgBytes = 0;
            _lastToolProgressTime = MonoTime.currTime;
            _streamWantedTools = false;
            _streamFinishReason = "";
            _lastPromptTokens = 0;
            _lastCompletionTokens = 0;
            _lastTotalTokens = 0;

            string headers = "User-Agent: " ~ userAgentFor(_baseUrl) ~ "\r\n";
            if (_apiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ _apiKey ~ "\r\n";
            if (isOpenCodeApiBaseUrl(_baseUrl))
                headers ~= "x-opencode-session: " ~ _opencodeSession ~ "\r\n";
            headers ~= "Content-Type: application/json\r\n" ~
                "Accept: text/event-stream\r\n";
            // Log the request shape once per turn. Without it, a request that
            // carries inline images is indistinguishable from a text-only one
            // in the log, and "the model did not answer about the image" cannot
            // be separated from "the image never left the app".
            logRequestShape(messages, model, _baseUrl);
            auto session = openSession();
            uint attempt;
            // Deliberately no attempt ceiling: a 429 is replayed until the
            // provider answers (see mayRetryTransientStatus). The only way out
            // other than success or a fatal error is the backoff's shutdown
            // poll, so Stop and a closing window both end the wait immediately.
            while (true)
            {
                if (replayReasoning || droppedReasoning)
                    body = buildChatBody(messages, tools, model,
                        droppedReasoning ? false : thinking, _baseUrl,
                        replayReasoning);
                auto bodyBytes = cast(ubyte[]) body.dup;
                HINTERNET connection;
                HINTERNET request;
                bool retry;
                DWORD retryStatus;
                string retryNote;
                string retryReason;
                try
                {
                    connection = InternetConnectW(session,
                        toUTF16z(target.host), target.port, null, null,
                        INTERNET_SERVICE_HTTP, 0, 0);
                    if (connection is null)
                        throw new Exception("Could not connect to " ~ target.host);

                    const flags = requestFlags(target);
                    request = HttpOpenRequestW(connection, "POST"w.ptr,
                        toUTF16z(target.path), null, null, null, flags, 0);
                    if (request is null)
                        throw new Exception("Could not create the chat request.");
                    if (registerRequest(request, true) is null)
                        throw new Exception("Chat request cancelled.");

                    if (!HttpSendRequestW(request, toUTF16z(headers), -1,
                        bodyBytes.ptr, cast(DWORD) bodyBytes.length))
                        throw new Exception("Chat request failed (" ~
                            wininetErrorText(GetLastError()) ~ ").");

                    DWORD statusCode;
                    DWORD statusLength = cast(DWORD) statusCode.sizeof;
                    if (HttpQueryInfoW(request,
                            HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                            &statusCode, &statusLength, null) &&
                        statusCode != 200)
                    {
                        const detail = readAllAsUtf8(request);
                        const reasoningRejected =
                            isReasoningReplayRejection(detail);
                        // A 429 that names a usage limit with a reset time is a
                        // quota wall, not a momentary outage. Replaying it would
                        // hide the one line the user needs ("Resets in 3hr
                        // 52min"), so it fails at once with the provider's own
                        // words instead of retrying every few seconds for hours.
                        const quotaWall = statusCode == 429 &&
                            isPersistentRateLimit(detail);
                        if (!quotaWall &&
                            mayRetryTransientStatus(statusCode, attempt + 1))
                        {
                            retry = true;
                            retryStatus = statusCode;
                            retryReason = condenseUpstreamDetail(
                                formatHttpErrorDetail(detail));
                        }
                        else if (reasoningRejected && !droppedReasoning &&
                            attempt + 1 < maxTransientChatAttempts)
                        {
                            // Repair the request instead of failing the turn:
                            // echo the assistant reasoning, then (if the
                            // provider still objects) continue without hosted
                            // reasoning rather than blocking the answer.
                            if (!replayReasoning)
                            {
                                replayReasoning = true;
                                retryNote = "replaying the assistant reasoning";
                            }
                            else
                            {
                                droppedReasoning = true;
                                retryNote =
                                    "continuing without hosted reasoning";
                            }
                            retry = true;
                            retryStatus = statusCode;
                        }
                        else if (reasoningRejected)
                        {
                            logError("chat request failed: HTTP " ~
                                to!string(statusCode) ~ " " ~
                                condenseUpstreamDetail(
                                    formatHttpErrorDetail(detail)) ~ " [" ~
                                _baseUrl ~ "]");
                            throw new Exception(reasoningReplayFailureText);
                        }
                        else
                            throw new Exception("Upstream returned HTTP " ~
                                to!string(statusCode) ~
                                (detail.length > 0 ? ": " ~
                                    condenseUpstreamDetail(
                                        formatHttpErrorDetail(detail)) : "") ~
                                (isTransientChatStatus(statusCode) && attempt > 0
                                    ? " (after " ~ to!string(attempt + 1) ~
                                        " attempts)" : ""));
                    }

                    if (!retry)
                    {
                        pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.chatBegin));
                        _streamActive = true;

                        ubyte[8192] buffer;
                        string lineBuffer;
                        while (!_cancel)
                        {
                            DWORD readBytes;
                            if (!InternetReadFile(request, buffer.ptr,
                                cast(DWORD) buffer.length, &readBytes))
                            {
                                const errorCode = GetLastError();
                                if (_cancel ||
                                    errorCode == ERROR_INTERNET_OPERATION_CANCELLED)
                                {
                                    cancelled = true;
                                    break;
                                }
                                throw new Exception("Stream read failed (" ~
                                    wininetErrorText(errorCode) ~ ").");
                            }
                            if (readBytes == 0) break;

                            lineBuffer ~= cast(string)
                                buffer[0 .. cast(size_t) readBytes];
                            lineBuffer = dispatchSseLines(lineBuffer);

                            if (_cancel)
                            {
                                cancelled = true;
                                break;
                            }
                        }
                        // SSE normally terminates every data line with `\n`,
                        // but compatible local/proxy servers sometimes close
                        // immediately after their last JSON event. Do not drop
                        // that final (occasionally one-character) content chunk.
                        if (!_cancel && lineBuffer.length > 0)
                            processSseLine(lineBuffer);
                    }
                }
                finally
                {
                    if (request !is null)
                    {
                        unregisterRequest(request, true);
                        InternetCloseHandle(request);
                    }
                    if (connection !is null)
                        InternetCloseHandle(connection);
                }

                if (!retry) break;
                ++attempt;
                const backoffMs = transientRetryBackoffMs(retryStatus, attempt);
                logInfo("chat upstream returned HTTP " ~
                    to!string(retryStatus) ~
                    (retryNote.length > 0 ? " (" ~ retryNote ~ ")" : "") ~
                    (retryReason.length > 0 ? " (" ~ retryReason ~ ")" : "") ~
                    "; backing off " ~ to!string(backoffMs) ~
                    " ms, retrying (attempt " ~ to!string(attempt + 1) ~ ") [" ~
                    _baseUrl ~ "]");
                // Publish the wait so the UI can show the retry and its age
                // rather than a request that looks frozen.
                setTransientRetry();
                // Poll shutdown so Stop stays immediate, and closing the window
                // never waits on this loop.
                foreach (_; 0 .. backoffMs / 50)
                {
                    Thread.sleep(50.msecs);
                    if (shuttingDown())
                    {
                        cancelled = true;
                        break;
                    }
                }
                clearTransientRetry();
                if (cancelled) break;
            }

            if (cancelled)
                pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.done,
                    _streamContent, false, null, true, _lastPromptTokens,
                    _lastCompletionTokens, _lastTotalTokens));
            else
                pushStreamEnd();
        }
        catch (Exception error)
        {
            if (!shuttingDown())
                logError("chat request failed: " ~ error.msg ~ " [" ~
                    _baseUrl ~ "]");
            _mutex.lock();
            const cancelNow = _cancel;
            _mutex.unlock();
            if (cancelNow)
                pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.done,
                    _streamContent, false, null, true, _lastPromptTokens,
                    _lastCompletionTokens, _lastTotalTokens));
            else
                pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.error, error.msg));
        }
    }

    /// Emit the terminal event for a stream that was not cancelled: a
    /// toolCalls event when the model requested tools, otherwise done.
    private void pushStreamEnd()
    {
        OpenCodeEvent event;
        if (_streamWantedTools)
            event = OpenCodeEvent(OpenCodeEventKind.toolCalls,
                _streamContent, false, null, false, _lastPromptTokens,
                _lastCompletionTokens, _lastTotalTokens,
                _streamToolCalls.dup);
        else
            event = OpenCodeEvent(OpenCodeEventKind.done,
                _streamContent, false, null, false, _lastPromptTokens,
                _lastCompletionTokens, _lastTotalTokens);
        event.finishReason = _streamFinishReason;
        pushStreamEvent(event);
    }

    // -- test hooks --------------------------------------------------------

    /// Test-only: run the SSE line parser on a captured payload. No network.
    public void feedSseForTesting(string payload)
    {
        dispatchSseLines(payload);
    }

    /// Test-only: simulate a server closing after a final SSE event without a
    /// trailing newline, exercising the network reader's EOF flush.
    public void feedSseEofForTesting(string payload)
    {
        auto remainder = dispatchSseLines(payload);
        if (remainder.length > 0) processSseLine(remainder);
    }

    /// Test-only: emit the terminal event for the parsed stream (done or
    /// toolCalls depending on what the payload requested), then drain.
    public OpenCodeEvent[] finishStreamForTesting()
    {
        pushStreamEnd();
        OpenCodeEvent[] events;
        drain(events);
        return events;
    }

    /// Test-only: reset the per-stream accumulation state between fixtures.
    public void resetStreamStateForTesting()
    {
        _streamReasoning = "";
        _streamContent = "";
        _streamToolCalls.length = 0;
        _streamToolNamesPushed = 0;
        _streamToolArgBytes = 0;
        _lastToolProgressTime = MonoTime.currTime;
        _streamWantedTools = false;
        _streamFinishReason = "";
        _lastPromptTokens = 0;
        _lastCompletionTokens = 0;
        _lastTotalTokens = 0;
    }

    /// Test-only: how many ms must pass between throttled tool-progress
    /// events. 0 makes every argument change emit one, so a test can observe
    /// the live counters without waiting on a clock.
    public void setToolProgressIntervalMsForTesting(int value)
    {
        _toolProgressIntervalMs = value;
    }

    /// Test-only: build the request JSON body without sending anything.
    public string buildBodyForTesting(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, string model, bool thinking,
        bool forceReasoningReplay = false)
    {
        return buildChatBody(messages, tools, model, thinking, _baseUrl,
            forceReasoningReplay);
    }

    /// Pure helper exposed for the multimodal request-shape regression.
    public static JSONValue chatMessageJsonForTesting(
        const ref ChatRequestMessage message)
    {
        return chatMessageToJson(message);
    }


    /// Test-only: verify URL transport selection without opening a connection.
    public bool secureTransportForTesting(string baseUrl)
    {
        return parseHttpTarget(baseUrl, "/models").secure;
    }

    private void runModelsRequest()
    {
        scope (exit) finishWorker(false);

        try
        {
            const target = parseHttpTarget(_baseUrl, "/models");
            auto session = openSession();

            auto connection = InternetConnectW(session, toUTF16z(target.host),
                target.port, null, null, INTERNET_SERVICE_HTTP, 0, 0);
            if (connection is null)
                throw new Exception("Could not connect to " ~ target.host);
            scope (exit) InternetCloseHandle(connection);

            const flags = requestFlags(target);
            auto request = HttpOpenRequestW(connection, "GET"w.ptr,
                toUTF16z(target.path), null, null, null, flags, 0);
            if (request is null)
                throw new Exception("Could not create the models request.");
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

            string headers = "User-Agent: " ~ userAgentFor(_baseUrl) ~ "\r\n";
            if (_apiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ _apiKey ~ "\r\n";
            if (isOpenCodeApiBaseUrl(_baseUrl))
                headers ~= "x-opencode-session: " ~ _opencodeSession ~ "\r\n";
            if (!HttpSendRequestW(request, toUTF16z(headers), -1, null, 0))
                throw new Exception("Could not open the models URL (" ~
                    wininetErrorText(GetLastError()) ~ ").");

            DWORD statusCode;
            DWORD statusLength = cast(DWORD) statusCode.sizeof;
            if (HttpQueryInfoW(request,
                    HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                    &statusCode, &statusLength, null) && statusCode != 200)
            {
                const detail = readAllAsUtf8(request);
                throw new Exception("Models endpoint returned HTTP " ~
                    to!string(statusCode) ~
                    (detail.length > 0 ? ": " ~
                        formatHttpErrorDetail(detail) : ""));
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
            if (!shuttingDown())
                logError("models request failed: " ~ error.msg ~ " [" ~
                    _baseUrl ~ "]");
            pushEvent(OpenCodeEvent(OpenCodeEventKind.modelsError, error.msg));
        }
    }

    private static JSONValue chatMessageToJson(
        const ref ChatRequestMessage message, bool forceReasoningReplay = false)
    {
        JSONValue json;
        json["role"] = message.role;
        // A user turn with inline images uses the OpenAI-compatible parts
        // array. Text-only messages keep the plain string form, which is what
        // every non-vision route and the local llama.cpp templates expect.
        if (message.images.length > 0)
            json["content"] = chatContentParts(message);
        else
            json["content"] = message.content;
        // DeepSeek/CommandCode-style reasoning models require the assistant's
        // reasoning_content to be echoed on the following tool round. Include
        // an empty value for legacy persisted tool calls: presence is required
        // even when an older Aurora build failed to save the returned text.
        // `forceReasoningReplay` extends that to every assistant message; it is
        // the recovery for a provider that rejected an earlier attempt with
        // exactly this complaint.
        if (message.role == "assistant" &&
            (forceReasoningReplay || message.reasoningContent.length > 0 ||
                message.toolCalls.length > 0))
            json["reasoning_content"] = message.reasoningContent;
        if (message.role == "tool" && message.toolCallId.length > 0)
            json["tool_call_id"] = message.toolCallId;
        if (message.toolCalls.length > 0)
        {
            JSONValue calls = JSONValue(string[].init);
            foreach (call; message.toolCalls)
            {
                JSONValue callJson;
                callJson["id"] = call.id;
                callJson["type"] = "function";
                JSONValue funcDef;
                funcDef["name"] = call.name;
                funcDef["arguments"] = call.arguments;
                callJson["function"] = funcDef;
                calls.array ~= callJson;
            }
            json["tool_calls"] = calls;
        }
        return json;
    }

    /// The multimodal `content` array: the text (when present) first, then one
    /// `image_url` part per image as a base64 data URL.
    private static JSONValue chatContentParts(
        const ref ChatRequestMessage message)
    {
        JSONValue parts = JSONValue(string[].init);
        if (message.content.length > 0)
        {
            JSONValue text;
            text["type"] = "text";
            text["text"] = message.content;
            parts.array ~= text;
        }
        foreach (image; message.images)
        {
            if (image.base64Data.length == 0) continue;
            JSONValue part;
            part["type"] = "image_url";
            JSONValue url;
            url["url"] = chatImageDataUrl(image);
            part["image_url"] = url;
            parts.array ~= part;
        }
        return parts;
    }

    /// `data:<mime>;base64,<payload>`, defaulting the mime type so a caller
    /// that only captured bytes still produces a valid URL.
    public static string chatImageDataUrl(const ref ChatImageAttachment image)
    {
        const mime = image.mimeType.length > 0
            ? image.mimeType : "image/png";
        return "data:" ~ mime ~ ";base64," ~ image.base64Data;
    }

    /// llama.cpp chat templates (including Qwen 3/3.5 templates) commonly
    /// require the system/developer instruction to be the first message and
    /// allow only one such block. Aurora can add later system checkpoints when
    /// compacting a long tool history, so fold every instruction block into a
    /// single leading system message before serialization. Removing them from
    /// their old positions also preserves assistant tool_calls -> tool result
    /// adjacency for strict OpenAI-compatible validators.
    private static ChatRequestMessage[] normalizeSystemMessages(
        const(ChatRequestMessage)[] messages)
    {
        ChatRequestMessage combined;
        combined.role = "system";
        ChatRequestMessage[] ordinary;
        foreach (message; messages)
        {
            if (message.role == "system" || message.role == "developer")
            {
                if (message.content.length == 0) continue;
                if (combined.content.length > 0) combined.content ~= "\n\n";
                combined.content ~= message.content;
            }
            else
            {
                ChatRequestMessage copy;
                copy.role = message.role;
                copy.content = message.content;
                copy.reasoningContent = message.reasoningContent;
                copy.toolCallId = message.toolCallId;
                copy.toolCalls = message.toolCalls.dup;
                // The fold rebuilds every non-system message, so inline images
                // must be copied here too: dropping them silently turned a
                // vision turn into a text turn with no error anywhere.
                copy.images = message.images.dup;
                ordinary ~= copy;
            }
        }
        if (combined.content.length == 0) return ordinary;
        return [combined] ~ ordinary;
    }

    private static string buildChatBody(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, string model, bool thinking,
        string baseUrl, bool forceReasoningReplay = false)
    {
        JSONValue root;
        root["model"] = model;
        JSONValue messageList = JSONValue(string[].init);
        foreach (message; normalizeSystemMessages(messages))
            messageList.array ~= chatMessageToJson(message, forceReasoningReplay);
        root["messages"] = messageList;
        if (tools.length > 0)
        {
            JSONValue toolList = JSONValue(string[].init);
            foreach (tool; tools)
            {
                JSONValue toolJson;
                toolJson["type"] = "function";
                JSONValue funcDef;
                funcDef["name"] = tool.name;
                funcDef["description"] = tool.description;
                try funcDef["parameters"] = parseJSON(tool.parametersJson);
                catch (Exception) funcDef["parameters"] = JSONValue.emptyObject;
                toolJson["function"] = funcDef;
                toolList.array ~= toolJson;
            }
            root["tools"] = toolList;
            // Match Codex's request contract: let the model return independent
            // tool calls in one response instead of paying for a fresh model
            // round-trip for every read/search. The Pro runtime still decides
            // which calls are actually safe to execute concurrently.
            root["parallel_tool_calls"] = true;
        }
        root["stream"] = true;
        // Most OpenAI-compatible servers omit usage from streamed chunks unless
        // explicitly asked. This lets the UI replace its live estimate with the
        // provider tokenizer's authoritative counts.
        JSONValue streamOptions;
        streamOptions["include_usage"] = true;
        root["stream_options"] = streamOptions;
        // `low` still enables reasoning on hosted DeepSeek/OpenCode routes.
        // That made an unchecked Thinking box misleading and could make the
        // next request fail when a provider demanded its hidden
        // `reasoning_content` back. Local llama-server accepts `none`; hosted
        // gateways such as CommandCode may reject it, so omit the option there
        // when thinking is disabled and let the provider's non-reasoning
        // default apply.
        if (thinking)
            root["reasoning_effort"] = "high";
        else if (isLoopbackApiBaseUrl(baseUrl))
            root["reasoning_effort"] = "none";
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

    /// One INFO line per request describing what the model will actually
    /// receive: model, message count, inline image count and total base64
    /// bytes. This is the evidence that separates "the image reached the
    /// provider" from "the image was dropped before the request was built".
    private static void logRequestShape(const(ChatRequestMessage)[] messages,
        string model, string baseUrl)
    {
        auto normalized = normalizeSystemMessages(messages);
        size_t images;
        size_t imageBytes;
        size_t requestBytes;
        foreach (message; normalized)
        {
            requestBytes += message.content.length + message.role.length + 16;
            foreach (image; message.images)
            {
                if (image.base64Data.length == 0) continue;
                ++images;
                imageBytes += image.base64Data.length;
            }
        }
        // Base64 inflates by roughly a third, so the payload the socket sees is
        // the text bytes plus the inflated image bytes.
        const wireBytes = requestBytes + imageBytes + (imageBytes / 2);
        logInfo("chat request: model=" ~ (model.length > 0 ? model : "?") ~
            " messages=" ~ to!string(normalized.length) ~
            " images=" ~ to!string(images) ~
            " imageBase64Bytes=" ~ to!string(imageBytes) ~
            " approxWireBytes=" ~ to!string(wireBytes) ~
            (isVisionModel(model) ? " vision=yes" : " vision=no") ~
            " [" ~ baseUrl ~ "]");
    }

    private static string truncateForError(string value)
    {
        if (value.length <= 800) return value;
        return value[0 .. 800] ~ "…";
    }

    /// OpenAI-compatible servers wrap failures as {"error":{"message":...}}.
    /// Decode that envelope before handing it to the Markdown UI: displaying
    /// raw JSON made `\n` render as a literal `n` and backslashes/underscores
    /// look corrupted even though the server response itself was valid JSON.
    private static string formatHttpErrorDetail(string detail)
    {
        try
        {
            auto root = parseJSON(detail);
            if (root.type == JSONType.object)
            {
                if (auto error = "error" in root.object)
                {
                    if (error.type == JSONType.object)
                        if (auto message = "message" in error.object)
                            if (message.type == JSONType.string)
                                return truncateForError(message.str);
                    if (error.type == JSONType.string)
                        return truncateForError(error.str);
                }
                if (auto message = "message" in root.object)
                    if (message.type == JSONType.string)
                        return truncateForError(message.str);
            }
        }
        catch (Exception) {}
        return truncateForError(detail);
    }

    unittest
    {
        // Snapshot events collapse, ordered deltas do not, and request identity
        // survives the zero-copy drain. This exercises the hot queue without a
        // provider or network connection.
        auto client = new OpenCodeClient("http://127.0.0.1:8080/v1", "");
        OpenCodeEvent usage;
        usage.kind = OpenCodeEventKind.usage;
        usage.totalTokens = 10;
        usage.requestId = 7;
        client.pushLocalEvent(usage);
        usage.totalTokens = 20;
        client.pushLocalEvent(usage);

        OpenCodeEvent first;
        first.kind = OpenCodeEventKind.delta;
        first.text = "a";
        first.requestId = 7;
        client.pushLocalEvent(first);
        OpenCodeEvent second = first;
        second.text = "b";
        client.pushLocalEvent(second);

        OpenCodeEvent[] events;
        client.drain(events);
        assert(events.length == 3);
        assert(events[0].totalTokens == 20 && events[0].requestId == 7);
        assert(events[1].text == "a" && events[2].text == "b");

        // A second cycle reuses the previous output allocation as the producer's
        // next queue rather than copying its contents under the mutex.
        client.pushLocalEvent(first);
        client.drain(events);
        assert(events.length == 1 && events[0].text == "a");

        ChatRequestMessage message;
        message.role = "user";
        message.content = "hello";
        const body = parseJSON(client.buildBodyForTesting([message], null,
            "tiny-model", false));
        const options = "stream_options" in body.object;
        assert(options !is null && options.type == JSONType.object);
        const includeUsage = "include_usage" in options.object;
        assert(includeUsage !is null && includeUsage.type == JSONType.true_);
        client.closeSession();
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
            choices.array.length == 0)
        {
            // Some providers deliver the usage summary in a chunk with empty
            // choices just before [DONE].
            captureUsage(value);
            return;
        }
        const choice = choices.array[0];
        if (choice.type != JSONType.object) return;
        auto delta = "delta" in choice.object;
        if (delta is null || delta.type != JSONType.object) return;
        captureUsage(value);

        // Some providers signal tool-call completion through the chunk's
        // finish_reason before [DONE]; others only through the delta shape.
        if (auto found = "finish_reason" in choice.object)
            if (found.type == JSONType.string)
            {
                _streamFinishReason = found.str;
                if (found.str == "tool_calls") _streamWantedTools = true;
            }

        if (auto found = "tool_calls" in delta.object)
        {
            if (found.type == JSONType.array)
            {
                foreach (entry; found.array)
                {
                    if (entry.type != JSONType.object) continue;
                    int index = 0;
                    if (auto field = "index" in entry.object)
                        if (field.type == JSONType.integer)
                            index = cast(int) field.integer;
                    while (_streamToolCalls.length <= cast(size_t) index)
                        _streamToolCalls ~= OpenCodeToolCall.init;
                    if (auto field = "id" in entry.object)
                        if (field.type == JSONType.string &&
                            field.str.length > 0)
                            _streamToolCalls[cast(size_t) index].id =
                                field.str;
                    auto funcEntry = "function" in entry.object;
                    if (funcEntry !is null && funcEntry.type == JSONType.object)
                    {
                        if (auto name = "name" in funcEntry.object)
                            if (name.type == JSONType.string &&
                                name.str.length > 0)
                                _streamToolCalls[cast(size_t) index].name =
                                    name.str;
                        if (auto args = "arguments" in funcEntry.object)
                            if (args.type == JSONType.string &&
                                args.str.length > 0)
                                _streamToolCalls[cast(size_t) index].arguments ~=
                                    args.str;
                    }
                }
                _streamWantedTools = true;
                // Announce each tool as soon as its name is known so the UI can
                // show "Writing foo.html ..." while the arguments (the whole file
                // body) are still streaming. Without this the reply looks
                // stalled between the assistant's text and the tool starting.
                // While the arguments keep growing, push throttled updates too so
                // the live `+N -M` counters advance with the streamed file body.
                size_t named;
                size_t argBytes;
                foreach (call; _streamToolCalls)
                {
                    if (call.name.length > 0) ++named;
                    argBytes += call.arguments.length;
                }
                const newName = named > _streamToolNamesPushed;
                const argsChanged = argBytes != _streamToolArgBytes;
                const due = (MonoTime.currTime -
                    _lastToolProgressTime).total!"msecs" >= _toolProgressIntervalMs;
                if (named > 0 && (newName || (argsChanged && due)))
                {
                    _streamToolNamesPushed = named;
                    _streamToolArgBytes = argBytes;
                    _lastToolProgressTime = MonoTime.currTime;
                    pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.toolCallDelta,
                        "", false, null, false, 0, 0, 0,
                        _streamToolCalls.dup));
                }
            }
        }

        // A single chunk can carry BOTH the chain of thought and the start of
        // the answer: gateways that stream the final reasoning record attach
        // the answer's first token to it. Treating reasoning and content as one
        // mutually exclusive `fragment` silently dropped that `content`, so the
        // reply's first letter or word vanished ("I've made…" arrived as
        // "'ve made…"). Extract the two channels independently and emit each.
        string reasoningFragment;
        if (auto found = "reasoning_content" in delta.object)
        {
            if (found.type == JSONType.string && found.str.length > 0)
                reasoningFragment = found.str;
        }
        if (reasoningFragment.length == 0)
        {
            // CommandCode/DeepSeek-style gateways stream the chain of thought
            // as `reasoning` (a plain string), usually next to a parallel
            // `reasoning_details` array. Recognizing only `reasoning_content`
            // silently dropped every reasoning chunk, so the app showed
            // nothing (not even the cold-start countdown resetting) for the
            // whole reasoning phase — often a minute or more on coding tasks.
            if (auto found = "reasoning" in delta.object)
            {
                if (found.type == JSONType.string && found.str.length > 0)
                    reasoningFragment = found.str;
            }
        }
        if (reasoningFragment.length == 0)
        {
            if (auto details = "reasoning_details" in delta.object)
            {
                if (details.type == JSONType.array)
                {
                    foreach (entry; details.array)
                    {
                        if (entry.type != JSONType.object) continue;
                        if (auto text = "text" in entry.object)
                            if (text.type == JSONType.string)
                                reasoningFragment ~= text.str;
                    }
                }
            }
        }

        string contentFragment;
        if (auto found = "content" in delta.object)
        {
            if (found.type == JSONType.string && found.str.length > 0)
                contentFragment = found.str;
        }

        if (reasoningFragment.length == 0 && contentFragment.length == 0) return;
        if (reasoningFragment.length > 0)
        {
            _streamReasoning ~= reasoningFragment;
            pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.delta,
                reasoningFragment, true));
        }
        if (contentFragment.length > 0)
        {
            _streamContent ~= contentFragment;
            pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.delta,
                contentFragment, false));
        }
    }

    private void captureUsage(const JSONValue value)
    {
        if (value.type != JSONType.object) return;
        auto usage = "usage" in value.object;
        if (usage is null || usage.type != JSONType.object) return;
        if (auto field = "prompt_tokens" in usage.object)
            if (field.type == JSONType.integer)
                _lastPromptTokens = cast(int) field.integer;
        if (auto field = "completion_tokens" in usage.object)
            if (field.type == JSONType.integer)
                _lastCompletionTokens = cast(int) field.integer;
        if (auto field = "total_tokens" in usage.object)
            if (field.type == JSONType.integer)
                _lastTotalTokens = cast(int) field.integer;
        // Mirror the real opencode: surface exact provider usage live so the
        // UI can meter context before the stream ends when the provider sends
        // usage in intermediate chunks (many only send it in the final one).
        if (_streamActive &&
            (_lastPromptTokens != _lastPushedPrompt ||
                _lastCompletionTokens != _lastPushedCompletion ||
                _lastTotalTokens != _lastPushedTotal))
        {
            _lastPushedPrompt = _lastPromptTokens;
            _lastPushedCompletion = _lastCompletionTokens;
            _lastPushedTotal = _lastTotalTokens;
            pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.usage, "", false, null,
                false, _lastPromptTokens, _lastCompletionTokens,
                _lastTotalTokens));
        }
    }
}

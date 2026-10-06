module auroraopencode.opencode_client;

import auroraopencode.provideradapter : buildChatBody, chatMessageToJson, normalizeSystemMessages,
    WireProjectionCache, providerImageDataUrl = chatImageDataUrl;
import auroraopencode.workerbudget : WorkerBudget, providerWorkerBudget;
import auroraopencode.httptransport : AsyncHttpRequest;
import auroraopencode.latency : RequestLatency, LatencyStage;
import std.process : environment;
import auroraopencode.retrypolicy : ProviderRetryPolicy, configuredProviderRetryPolicy;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import core.sys.windows.windows : DWORD, DWORD_PTR, BOOL, FALSE, TRUE, GetLastError;
import core.sys.windows.wininet : ERROR_INTERNET_OPERATION_CANCELLED,
    HTTP_QUERY_FLAG_NUMBER, HTTP_QUERY_STATUS_CODE, HttpOpenRequestW,
    HttpQueryInfoW, HttpSendRequestW, HINTERNET, INTERNET_DEFAULT_HTTPS_PORT,
    INTERNET_FLAG_NO_CACHE_WRITE, INTERNET_FLAG_PRAGMA_NOCACHE,
    INTERNET_FLAG_RELOAD, INTERNET_FLAG_SECURE, INTERNET_OPEN_TYPE_PRECONFIG,
    INTERNET_OPTION_CONNECT_TIMEOUT, INTERNET_OPTION_RECEIVE_TIMEOUT,
    INTERNET_OPTION_SEND_TIMEOUT, INTERNET_SERVICE_HTTP, InternetCloseHandle,
    InternetConnectW, InternetOpenW, InternetOpenUrlW, InternetReadFile,
    InternetQueryDataAvailable,
    InternetSetOptionW, InternetSetStatusCallback, INTERNET_STATUS_REQUEST_SENT;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.utf : toUTF16z;
import auroraopencode.core : ChatImageAttachment, ChatRequestMessage,
    OpenCodeToolCall, OpenCodeToolDef, defaultReasoningEffortForModel,
    isLoopbackApiBaseUrl, isOpenCodeApiBaseUrl, isVisionModel;
import auroraopencode.logging : logError, logInfo;

public import auroraopencode.events;
import auroraopencode.providerstream : ProviderStreamDecoder;
import auroraopencode.provideraudit : ProviderAudit;

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
    // terms (a bad key, an unknown route), fails identically when replayed.
    // A 400 is deliberately NOT in this set: gateways route those to model
    // provisioning/model-not-ready conditions that answer a bare body such as
    // {"model":"..."} and clear on their own, so a random 400 used to kill the
    // turn outright. It is replayed on the same bounded schedule as any other
    // blip, and the provider's own sentence stays in the failed reply either
    // way, so nothing is hidden.
    if (isPersistentRateLimit(failureText)) return -1;
    if (containsAsciiIgnoreCase(failureText, "HTTP 401") ||
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
    private ProviderRetryPolicy _retryPolicy;
    private WorkerBudget _workerBudget;
    private Condition _queueSpace;
    private Thread _consumerThread;
    private OpenCodeEvent[] _pending;
    private size_t _pendingBytes;
    private enum size_t queueByteBudget = 8 * 1024 * 1024;
    private enum size_t queueEventBudget = 1024;
    private bool _chatBusy;
    // True while the worker is paused between replays of a transient upstream
    // failure. A 429 is replayed within the configured outage budget, which can take a
    // minute or more, so the UI reads this to say the provider is busy instead
    // of leaving a retrying request looking frozen.
    private bool _transientRetrying;
    private bool _modelsBusy;
    private bool _modelsRefreshQueued;
    private bool _cancel;
    private HINTERNET _chatHandle;
    private AsyncHttpRequest _httpRequest;
    private RequestLatency _latency;
    private void delegate() _eventWake;
    private HINTERNET _modelsHandle;
    private HINTERNET _session;
    private HINTERNET _retiredSession;
    private bool _sessionClosed;
    private string _baseUrl;
    private string _apiKey;
    // Stable per-conversation id for the OpenCode Go `x-opencode-session`
    // routing header. The UI updates it when the active conversation changes;
    // the constructor value covers requests made before any session exists.
    private string _opencodeSession;
    private ProviderStreamDecoder _decoder;
    private ulong _streamRequestId;
    // How many of `_decoder._streamToolCalls` already had a name announced to the UI, so
    // a progress event fires once per new tool call (not on every argument
    // fragment, which would flood the UI thread while a file body streams).
    // While a tool's arguments stream, the UI wants periodic progress so the
    // live `+N -M` counters grow as the file body arrives. Emitting one event
    // per fragment would flood the UI thread, so progress is throttled to at
    // most once per `_decoder._toolProgressIntervalMs` and only when the arguments
    // actually changed.
    private bool _deferStreamEnd;
    private bool _hasStreamEnd;
    private OpenCodeEvent _streamEnd;
    // True once the prompt-cache split for the current request has been logged,
    // so the wait log carries the cache verdict exactly once per request.
    private bool _waitCacheLogged;
    // Exact count returned by llama.cpp's tokenizer-only endpoint before the
    // matching completion is sent. The final streamed usage is still parsed
    // independently and can expose a server regression if the two diverge.

    // "Waiting for the model…" latency breakdown. The UI shows one opaque wait
    // between Send and the first token; that wait is really several stages with
    // very different causes, so each is timed and reported (see WaitBreakdown).
    // All are milliseconds since the request began, or -1 when not reached.
    private long _waitConnectMs = -1;    // actual WinHTTP callback, WinINet handle creation
    private long _waitSentMs = -1;       // until the request body (incl. images)
                                         // is fully uploaded
    private long _waitHeadersMs = -1;    // until the upstream status line arrives
    private long _waitFirstByteMs = -1;  // until the first SSE byte of the answer
    private long _waitFirstTokenMs = -1; // until the first content/reasoning token
    private long _lastRequestBytes;
    private long _lastRequestImages;
    // Request start time, kept as a field so the SSE parser (a different method)
    // can attribute the first token to the wait that preceded it.
    private MonoTime _waitStart;

    this(string baseUrl, string apiKey,
        ProviderRetryPolicy retryPolicy = configuredProviderRetryPolicy(),
        WorkerBudget workerBudget = null)
    {
        _workerBudget = workerBudget !is null ? workerBudget : providerWorkerBudget();
        _decoder = new ProviderStreamDecoder();
        _decoder.emit = &pushStreamEvent;
        _decoder.onFirstToken = &recordFirstStreamToken;
        _decoder.onUsage = &logPromptCache;
        _decoder.formatError = &formatHttpErrorDetail;
        _decoder.onTokenizerMismatch = delegate(int preflight, int streamed) {
            logError("local tokenizer count mismatch: preflight=" ~ to!string(preflight) ~
                ", streamed=" ~ to!string(streamed) ~ " [" ~ _baseUrl ~ "]");
        };
        _mutex = new Mutex();
        _latency = new RequestLatency(0);
        _retryPolicy = retryPolicy;
        _queueSpace = new Condition(_mutex);
        _consumerThread = Thread.getThis();
        _baseUrl = baseUrl;
        _apiKey = apiKey;
        _opencodeSession = "aurora-session-" ~
            to!string(MonoTime.currTime.ticks);
    }

    string baseUrl() const @safe pure nothrow @nogc { return _baseUrl; }
    string apiKey() const @safe pure nothrow @nogc { return _apiKey; }

    void setEventWake(void delegate() wake)
    {
        synchronized (_mutex) _eventWake = wake;
    }

    RequestLatency latency() { synchronized (_mutex) return _latency; }

    void setCredentials(string baseUrl, string apiKey)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        _baseUrl = baseUrl;
        _apiKey = apiKey;
    }

    /// Set the stable conversation id sent as `x-opencode-session` to the
    /// OpenCode gateway. Ignored when empty, so a caller without a session
    /// keeps the constructor's per-run id.
    void setOpenCodeSession(string value)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
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

    /// Stage-by-stage breakdown of the model wait, in milliseconds from the
    /// request start. Each field is -1 until that stage is reached, so a caller
    /// can tell "still uploading" from "uploaded, waiting on the provider".
    /// `firstToken` is the figure the UI's "Waiting for the model…" row shows.
    struct WaitBreakdown
    {
        long connect;     // connection handle created; not a TCP measurement
        long sent;        // request start -> whole body uploaded
        long headers;     // request start -> upstream response status line
        long firstByte;   // request start -> first SSE byte of the answer
        long firstToken;  // request start -> first content/reasoning token
        long requestBytes;
        long requestImages;
        bool valid;       // false before any chat request has run
    }

    /// Snapshot the current wait breakdown. Safe to poll from the UI thread.
    WaitBreakdown waitBreakdown()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        return WaitBreakdown(_waitConnectMs, _waitSentMs, _waitHeadersMs,
            _waitFirstByteMs, _waitFirstTokenMs, _lastRequestBytes,
            _lastRequestImages, _lastRequestBytes > 0 || _waitSentMs >= 0);
    }

    private static extern(Windows) void chatRequestStatus(HINTERNET handle,
        DWORD_PTR context, DWORD status, void* information, DWORD length)
    {
        if (context == 0 || status != INTERNET_STATUS_REQUEST_SENT) return;
        auto client = cast(OpenCodeClient) cast(void*) context;
        client._mutex.lock();
        // HttpSendRequest returns only after response headers arrive. The
        // request-sent notification is the actual end of the upload.
        if (client._chatHandle is handle)
        {
            client._waitSentMs = elapsedMsSince(client._waitStart);
            client._latency.mark(LatencyStage.uploaded);
        }
        client._mutex.unlock();
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
    ChatStartResult startChatMessages(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, string model, bool thinking,
        ulong requestId = 0, string reasoningEffort = "",
        int thinkingBudgetTokens = 0, bool llamaCppServer = false,
        long preparationStartedTicks = 0)
    {
        _mutex.lock();
        if (_chatBusy || _sessionClosed)
        {
            const result = _sessionClosed ? ChatStartResult.closed : ChatStartResult.busy;
            _mutex.unlock();
            return result;
        }
        if (!_workerBudget.acquire())
        {
            _mutex.unlock();
            return ChatStartResult.capacity;
        }
        _chatBusy = true;
        _cancel = false;
        _chatHandle = null;
        const requestBaseUrl = _baseUrl;
        const requestApiKey = _apiKey;
        const requestSession = _opencodeSession;
        _latency = new RequestLatency(requestId, preparationStartedTicks);
        _latency.mark(LatencyStage.accepted);
        const exactPreflight = environment.get("AURORA_TOKEN_PREFLIGHT", "0") == "1";
        const useWinHttp = environment.get("AURORA_HTTP_TRANSPORT", "winhttp") != "wininet";
        _mutex.unlock();

        try
        {
        ChatRequestMessage[] messageCopy;
        foreach (message; messages)
        {
            ChatRequestMessage copy;
            // Strings are immutable in D. Share their payloads while detaching
            // the mutable structs/arrays; copying the whole history and base64
            // images here blocked the UI before the worker could even start.
            copy.role = message.role;
            copy.content = message.content;
            copy.reasoningContent = message.reasoningContent;
            copy.toolCallId = message.toolCallId;
            foreach (image; message.images)
            {
                ChatImageAttachment imageCopy;
                imageCopy.mimeType = image.mimeType;
                imageCopy.base64Data = image.base64Data;
                imageCopy.name = image.name;
                copy.images ~= imageCopy;
            }
            foreach (call; message.toolCalls)
            {
                OpenCodeToolCall callCopy;
                callCopy.id = call.id;
                callCopy.name = call.name;
                callCopy.arguments = call.arguments;
                copy.toolCalls ~= callCopy;
            }
            messageCopy ~= copy;
        }

        OpenCodeToolDef[] toolCopy;
        foreach (tool; tools)
        {
            OpenCodeToolDef copy;
            copy.name = tool.name;
            copy.description = tool.description;
            copy.parametersJson = tool.parametersJson;
            toolCopy ~= copy;
        }

        auto worker = new Thread({
            scope (exit) _workerBudget.release();
            runChatRequest(messageCopy, toolCopy, model, thinking, requestId,
                reasoningEffort, thinkingBudgetTokens, llamaCppServer,
                requestBaseUrl, requestApiKey, requestSession, exactPreflight, useWinHttp);
        });
        worker.isDaemon = true;
        worker.start();
        return ChatStartResult.accepted;
        }
        catch (Exception error)
        {
            synchronized (_mutex) _chatBusy = false;
            _workerBudget.release();
            return ChatStartResult.failed;
        }
    }

    void cancel()
    {
        _mutex.lock();
        _cancel = true;
        _queueSpace.notifyAll();
        auto handle = _chatHandle;
        auto http = _httpRequest;
        _chatHandle = null;
        _mutex.unlock();
        if (http !is null) http.cancel();
        if (handle !is null)
        {
            try InternetCloseHandle(handle);
            catch (Exception) {}
        }
    }

    void fetchModels()
    {
        _mutex.lock();
        if (_modelsBusy || _sessionClosed)
        {
            if (!_sessionClosed) _modelsRefreshQueued = true;
            _mutex.unlock();
            return;
        }
        if (!_workerBudget.acquire())
        {
            _mutex.unlock();
            pushEvent(OpenCodeEvent(OpenCodeEventKind.modelsError,
                "Provider workers are at capacity; model refresh can be retried."));
            return;
        }
        _modelsBusy = true;
        _modelsHandle = null;
        const requestBaseUrl = _baseUrl;
        const requestApiKey = _apiKey;
        const requestSession = _opencodeSession;
        _mutex.unlock();

        try
        {
            auto worker = new Thread({
                scope (exit) _workerBudget.release();
                runModelsRequest(requestBaseUrl, requestApiKey, requestSession);
            });
            worker.isDaemon = true;
            worker.start();
        }
        catch (Exception error)
        {
            synchronized (_mutex) _modelsBusy = false;
            _workerBudget.release();
            pushEvent(OpenCodeEvent(OpenCodeEventKind.modelsError,
                "Model refresh could not start: " ~ error.msg));
        }
    }

    /** Release the shared session. Call once on shutdown. */
    void closeSession()
    {
        _mutex.lock();
        _sessionClosed = true;
        _cancel = true;
        _pending = null;
        _pendingBytes = 0;
        _queueSpace.notifyAll();
        auto session = _session;
        auto chatHandle = _chatHandle;
        auto http = _httpRequest;
        auto modelsHandle = _modelsHandle;
        _session = null;
        _chatHandle = null;
        _modelsHandle = null;
        // Workers still own connection handles below this session. Closing the
        // parent now invalidates them before their cleanup can release them.
        if (session !is null && (_chatBusy || _modelsBusy))
        {
            _retiredSession = session;
            session = null;
        }
        _mutex.unlock();
        if (http !is null) http.cancel();
        if (chatHandle !is null) InternetCloseHandle(chatHandle);
        if (modelsHandle !is null) InternetCloseHandle(modelsHandle);
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
    void drain(ref OpenCodeEvent[] output, size_t maxEvents = size_t.max,
        size_t maxBytes = size_t.max)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (maxEvents == size_t.max && maxBytes == size_t.max)
        {
        auto reusable = output;
        output = _pending;
        _pending = reusable;
        _pending.length = 0;
        _pendingBytes = 0;
        }
        else
        {
            output.length = 0;
            size_t taken, bytes;
            while (taken < _pending.length && output.length < maxEvents)
            {
                auto event = _pending[taken];
                const cost = eventBytes(event);
                if (bytes >= maxBytes) break;
                if (event.kind == OpenCodeEventKind.delta &&
                    event.text.length > maxBytes - bytes)
                {
                    size_t cut = maxBytes - bytes;
                    while (cut && (cast(ubyte) event.text[cut] & 0xc0) == 0x80) --cut;
                    // A positive budget smaller than one UTF-8 code point
                    // still makes progress by admitting that indivisible unit.
                    if (!cut)
                    {
                        if (output.length) break;
                        cut = 1;
                        while (cut < event.text.length &&
                            (cast(ubyte) event.text[cut] & 0xc0) == 0x80) ++cut;
                    }
                    event.text = event.text[0 .. cut];
                    output ~= event;
                    if (cut == _pending[taken].text.length)
                    {
                        _pendingBytes -= cost;
                        ++taken;
                    }
                    else
                    {
                        _pending[taken].text = _pending[taken].text[cut .. $];
                        _pendingBytes -= cut;
                    }
                    break;
                }
                if (output.length && cost > maxBytes - bytes) break;
                output ~= event;
                bytes += cost;
                _pendingBytes -= cost;
                ++taken;
            }
            _pending = _pending[taken .. $];
        }
        _queueSpace.notifyAll();
    }

    size_t queuedBytes()
    {
        synchronized (_mutex) return _pendingBytes;
    }

    private static size_t eventBytes(const ref OpenCodeEvent event)
    {
        size_t bytes = OpenCodeEvent.sizeof + event.text.length + event.diffText.length;
        foreach (call; event.toolCalls)
            bytes += OpenCodeToolCall.sizeof + call.id.length + call.name.length + call.arguments.length;
        foreach (attachment; event.images) bytes += attachment.base64Data.length;
        foreach (model; event.modelIds) bytes += model.length;
        return bytes;
    }

    bool hasPendingEvents()
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();

        return _pending.length > 0;
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
        void delegate() wake;
        _mutex.lock();
        scope (exit)
        {
            _mutex.unlock();
            if (wake !is null) wake();
        }

        const cost = eventBytes(event);
        // Backpressure belongs on producers. Control events generated on the
        // consumer thread use a reserve instead of waiting on their own drain.
        // One indivisible event may exceed the byte budget; subsequent events
        // wait until it is consumed. Cancellation always wakes blocked workers.
        while (!_cancel && !_sessionClosed && _pending.length &&
            (_pending.length >= queueEventBudget || _pendingBytes + cost > queueByteBudget) &&
            Thread.getThis() !is _consumerThread)
            _queueSpace.wait();
        if (_sessionClosed || (_cancel && Thread.getThis() !is _consumerThread)) return;

        // Adjacent fragments of the same stream channel merge into one queued
        // event. The UI concatenates same-channel deltas anyway, so this is
        // byte-identical output with far fewer queue entries when a provider
        // emits many tiny chunks faster than the UI ticks. Ordering across
        // reasoning/content/tools/usage is preserved because only a directly
        // preceding event of the same kind and channel is merged.
        if (event.kind == OpenCodeEventKind.delta && _pending.length > 0 &&
            _pending[$ - 1].kind == OpenCodeEventKind.delta &&
            _pending[$ - 1].requestId == event.requestId &&
            _pending[$ - 1].reasoning == event.reasoning)
        {
            _pending[$ - 1].text ~= event.text;
            _pendingBytes += event.text.length;
            return;
        }
        // These are snapshots, not an ordered history. When the UI is slower
        // than a provider's fragment rate, retaining obsolete snapshots only
        // causes redundant transcript rebuilds and badge layout work.
        if (_pending.length > 0 &&
            (event.kind == OpenCodeEventKind.toolCallDelta ||
             event.kind == OpenCodeEventKind.usage) &&
            _pending[$ - 1].kind == event.kind &&
            _pending[$ - 1].requestId == event.requestId)
        {
            _pendingBytes -= eventBytes(_pending[$ - 1]);
            _pending[$ - 1] = event;
            _pendingBytes += cost;
            return;
        }
        if (!_pending.length) wake = _eventWake;
        _pending ~= event;
        _pendingBytes += cost;
    }

    /// Tag every event produced by the current streaming request. Tool-result
    /// events are tagged by their executor because they outlive this worker.
    private void pushStreamEvent(OpenCodeEvent event)
    {
        event.requestId = _streamRequestId;
        if (_deferStreamEnd && (event.kind == OpenCodeEventKind.done ||
            event.kind == OpenCodeEventKind.error || event.kind == OpenCodeEventKind.toolCalls))
        {
            _streamEnd = event;
            _hasStreamEnd = true;
            return;
        }
        pushEvent(event);
    }

    private void finishWorker(bool chat)
    {
        HINTERNET retired;
        bool refreshModels;
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
            refreshModels = _modelsRefreshQueued && !_sessionClosed;
            _modelsRefreshQueued = false;
        }
        if (_sessionClosed && !_chatBusy && !_modelsBusy)
        {
            retired = _retiredSession;
            _retiredSession = null;
        }
        _mutex.unlock();
        if (retired !is null) InternetCloseHandle(retired);
        if (refreshModels) fetchModels();
    }

    private HINTERNET openSession()
    {
        // Fast path: a session already exists or the client is closed. This is
        // the only part that needs the lock; it is a couple of field reads.
        _mutex.lock();
        auto existing = _session;
        const closed = _sessionClosed;
        _mutex.unlock();
        if (existing !is null) return existing;
        if (closed) throw new Exception("The network client is closed.");

        // Build the WinINet session WITHOUT holding `_mutex`. InternetOpenW and
        // InternetSetOptionW initialize WinINet and resolve the proxy (which a
        // WPAD lookup can stall for seconds). The GUI thread takes this same
        // lock many times per frame (busy()/shuttingDown()), so holding it
        // across these calls froze the UI whenever a request opened its first
        // session. Opening outside the lock keeps the UI responsive; the store
        // below is the only synchronized step.
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
        }

        // Publish the freshly opened session, or discard it if another worker
        // won the race or the client was closed while we were opening.
        bool discard;
        _mutex.lock();
        if (_sessionClosed)
        {
            discard = session !is null;
        }
        else if (_session is null)
        {
            _session = session;
        }
        else
        {
            discard = session !is null;
        }
        existing = _session;
        const closedNow = _sessionClosed;
        _mutex.unlock();

        if (discard)
        {
            try InternetCloseHandle(session);
            catch (Exception) {}
        }
        if (existing is null)
            throw new Exception(closedNow
                ? "The network client is closed."
                : "Could not open an internet session.");
        return existing;
    }

    private HINTERNET registerRequest(HINTERNET handle, bool chat)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_sessionClosed || (_cancel && chat))
        {
            _chatHandle = null;
            return null;
        }
        if (chat) _chatHandle = handle;
        else _modelsHandle = handle;
        return handle;
    }

    private bool unregisterRequest(HINTERNET handle, bool chat)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (chat && _chatHandle is handle)
        {
            _chatHandle = null;
            return true;
        }
        if (!chat && _modelsHandle is handle)
        {
            _modelsHandle = null;
            return true;
        }
        // Cancellation/shutdown already took ownership and closed the handle.
        return false;
    }

    private void runChatRequest(ChatRequestMessage[] messages,
        OpenCodeToolDef[] tools, string model, bool thinking, ulong requestId,
        string reasoningEffort, int thinkingBudgetTokens, bool llamaCppServer,
        string requestBaseUrl, string requestApiKey, string requestSession,
        bool exactPreflight, bool useWinHttp)
    {
        _streamRequestId = requestId;
        _deferStreamEnd = true;
        _hasStreamEnd = false;
        scope (exit)
        {
            const hasEnd = _hasStreamEnd;
            auto end = _streamEnd;
            _streamEnd = OpenCodeEvent.init;
            _hasStreamEnd = false;
            _deferStreamEnd = false;
            _decoder._streamActive = false;
            _latency.mark(LatencyStage.settled);
            _latency.report("settled");
            finishWorker(true);
            // A terminal event is permission for the UI to send the next tool
            // round/follow-up. Release this worker before publishing it, or a
            // fast continuation can be silently rejected by the busy guard.
            if (hasEnd) pushEvent(end);
        }

        bool cancelled;

        try
        {
            const target = parseHttpTarget(requestBaseUrl, "/chat/completions");
            // Request-shape recovery state. A thinking-mode provider can reject
            // the payload because the assistant's reasoning was not replayed
            // (first recovery) and, if it still refuses, because hosted
            // reasoning cannot continue on this history (second recovery).
            bool replayReasoning;
            bool droppedReasoning;
            string body = buildChatBody(messages, tools, model, thinking,
                requestBaseUrl, false, reasoningEffort, thinkingBudgetTokens,
                llamaCppServer, wireProjectionCache());
            _latency.mark(LatencyStage.serialized);
            _latency.wire(body.length, useWinHttp ? "winhttp" : "wininet");
            logPayloadComponents(messages, tools, body.length, requestId);
            _decoder._streamReasoning = "";
            _decoder._streamContent = "";
            _streamRequestId = requestId;
            _decoder._streamToolCalls.length = 0;
            _decoder._streamToolNamesPushed = 0;
            _decoder._streamToolArgBytes = 0;
            _decoder._lastToolProgressTime = MonoTime.currTime;
            _decoder._streamWantedTools = false;
            _decoder._streamFinishReason = "";
            _decoder._streamDone = false;
            _decoder._streamError = "";
            _decoder.outputIssue = "";
            _decoder.nextGuardBytes = 512;
            _decoder.guardToolNames = null;
            foreach (tool; tools) _decoder.guardToolNames ~= tool.name;
            _decoder.audit = new ProviderAudit(requestId, model, requestApiKey);
            _decoder._lastPromptTokens = 0;
            _decoder._lastCompletionTokens = 0;
            _decoder._lastTotalTokens = 0;
            _decoder._lastCachedPromptTokens = 0;
            _decoder._lastUncachedPromptTokens = 0;
            _decoder._preflightPromptTokens = 0;
            _decoder._lastPushedPrompt = -1;
            _decoder._lastPushedCompletion = -1;
            _decoder._lastPushedTotal = -1;
            _decoder._lastPushedCachedPrompt = -1;
            _decoder._lastPushedUncachedPrompt = -1;
            // Fresh wait breakdown for this request, plus the request size, so
            // the log can separate "big body / slow upload" from "fast upload,
            // slow provider".
            const waitStart = MonoTime.currTime;
            _mutex.lock();
            _waitStart = waitStart;
            _waitCacheLogged = false;
            _waitConnectMs = _waitSentMs = _waitHeadersMs = -1;
            _waitFirstByteMs = _waitFirstTokenMs = -1;
            _lastRequestBytes = _lastRequestImages = 0;
            _mutex.unlock();

            string headers = "User-Agent: " ~ userAgentFor(requestBaseUrl) ~ "\r\n";
            if (requestApiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ requestApiKey ~ "\r\n";
            if (isOpenCodeApiBaseUrl(requestBaseUrl))
                headers ~= "x-opencode-session: " ~ requestSession ~ "\r\n";
            headers ~= "Content-Type: application/json\r\n" ~
                "Accept: text/event-stream\r\n";
            // Log the request shape once per turn. Without it, a request that
            // carries inline images is indistinguishable from a text-only one
            // in the log, and "the model did not answer about the image" cannot
            // be separated from "the image never left the app".
            logRequestShape(messages, model, requestBaseUrl, llamaCppServer);
            HINTERNET session;
            if (!useWinHttp || (llamaCppServer && exactPreflight)) session = openSession();
            // Ask the same local server that will run inference to apply the
            // loaded model's tokenizer and chat template to the exact request
            // body. This is model-aware for Qwen, DeepSeek, or any other GGUF;
            // counting raw message strings locally would miss tool/template
            // tokens. Failure is non-fatal so older llama.cpp builds keep
            // working and their final streamed usage can still provide the
            // authoritative count.
            if (llamaCppServer && exactPreflight)
            {
                _decoder._preflightPromptTokens = countChatInputTokens(session, body,
                    requestBaseUrl, requestApiKey);
                if (_decoder._preflightPromptTokens > 0)
                {
                    _decoder._lastPromptTokens = _decoder._preflightPromptTokens;
                    _decoder._lastTotalTokens = _decoder._preflightPromptTokens;
                    OpenCodeEvent usage;
                    usage.kind = OpenCodeEventKind.usage;
                    usage.promptTokens = _decoder._preflightPromptTokens;
                    usage.totalTokens = _decoder._preflightPromptTokens;
                    pushStreamEvent(usage);
                }
                if (shuttingDown())
                {
                    cancelled = true;
                    pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.done,
                        "", false, null, true, _decoder._lastPromptTokens, 0,
                        _decoder._lastTotalTokens));
                    return;
                }
            }
            uint attempt;
            // Provider outage recovery has a separate finite time budget.
            // Useful streaming and tool work are not subject to this budget.
            while (true)
            {
                if (replayReasoning || droppedReasoning)
                    body = buildChatBody(messages, tools, model,
                        droppedReasoning ? false : thinking, requestBaseUrl,
                        replayReasoning, reasoningEffort,
                        droppedReasoning ? 0 : thinkingBudgetTokens,
                        llamaCppServer, wireProjectionCache());
                // Both transports retain this immutable body through send.
                _decoder.audit.record("request", body);
                // A second full copy is especially costly for inline images.
                auto bodyBytes = cast(const(ubyte)[]) body;
                synchronized (_mutex)
                {
                    _lastRequestBytes = cast(long) bodyBytes.length;
                    _lastRequestImages = countInlineImages(messages);
                }
                HINTERNET connection;
                HINTERNET request;
                AsyncHttpRequest http;
                bool requestRegistered;
                bool retry;
                DWORD retryStatus;
                string retryNote;
                string retryReason;
                const attemptStarted = MonoTime.currTime;
                scope (exit) if (http !is null)
                {
                    const timing = http.timing();
                    long elapsed(long ticks) { return ticks < 0 ? -1 :
                        cast(long) (cast(double) (ticks - attemptStarted.ticks) * 1_000_000 / MonoTime.ticksPerSecond); }
                    logInfo("transport attempt: id=" ~ to!string(requestId) ~
                        " attempt=" ~ to!string(attempt + 1) ~
                        " sendCompletedUs=" ~ to!string(elapsed(timing.sent)) ~
                        " headersAvailableUs=" ~ to!string(elapsed(timing.headers)) ~
                        " protocol=" ~ to!string(timing.protocol) ~
                        " bytes=" ~ to!string(body.length));
                }
                try
                {
                    DWORD statusCode;
                    if (useWinHttp)
                    {
                        http = new AsyncHttpRequest(target.host, target.port, target.path,
                            target.secure, isLoopbackApiBaseUrl(requestBaseUrl));
                        bool stop;
                        synchronized (_mutex)
                        {
                            stop = _cancel || _sessionClosed;
                            _httpRequest = http;
                        }
                        if (stop) http.cancel();
                        statusCode = http.send(headers, body);
                        const timing = http.timing();
                        if (timing.connected >= 0) _latency.mark(LatencyStage.connected, timing.connected);
                        if (timing.sent >= 0) _latency.mark(LatencyStage.uploaded, timing.sent);
                        if (timing.headers >= 0) _latency.mark(LatencyStage.headers, timing.headers);
                        _latency.wire(body.length, "winhttp", timing.protocol);
                        synchronized (_mutex)
                        {
                            _waitConnectMs = timing.connected >= 0
                                ? cast(long) (cast(double) (timing.connected - waitStart.ticks) * 1000 / MonoTime.ticksPerSecond) : -1;
                            _waitSentMs = timing.sent >= 0
                                ? cast(long) (cast(double) (timing.sent - waitStart.ticks) * 1000 / MonoTime.ticksPerSecond) : -1;
                        }
                    }
                    else
                    {
                    connection = InternetConnectW(session,
                        toUTF16z(target.host), target.port, null, null,
                        INTERNET_SERVICE_HTTP, 0, 0);
                    if (connection is null)
                        throw new Exception("Could not connect to " ~ target.host);
                    synchronized (_mutex) _waitConnectMs = elapsedMsSince(waitStart);

                    const flags = requestFlags(target);
                    request = HttpOpenRequestW(connection, "POST"w.ptr,
                        toUTF16z(target.path), null, null, null, flags,
                        cast(DWORD_PTR) cast(void*) this);
                    if (request is null)
                        throw new Exception("Could not create the chat request.");
                    if (registerRequest(request, true) is null)
                        throw new Exception("Chat request cancelled.");
                    requestRegistered = true;

                    InternetSetStatusCallback(request, &chatRequestStatus);
                    _mutex.lock();
                    _waitSentMs = _waitHeadersMs = -1;
                    _mutex.unlock();

                    // This call includes both upload and response-header wait.
                    // The status callback records the upload boundary separately.
                    if (!HttpSendRequestW(request, toUTF16z(headers), -1,
                        cast(void*) bodyBytes.ptr, cast(DWORD) bodyBytes.length))
                        throw new Exception("Chat request failed (" ~
                            wininetErrorText(GetLastError()) ~ ").");
                    DWORD statusLength = cast(DWORD) statusCode.sizeof;
                    if (!HttpQueryInfoW(request,
                            HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                            &statusCode, &statusLength, null))
                        throw new Exception("Could not read the HTTP status.");
                    }
                    synchronized (_mutex) _waitHeadersMs = elapsedMsSince(waitStart);
                    _latency.mark(LatencyStage.headers);
                    if (statusCode != 200)
                    {
                        const detail = http !is null ? http.readError() : readAllAsUtf8(request);
                        const reasoningRejected =
                            isReasoningReplayRejection(detail);
                        // A 429 that names a usage limit with a reset time is a
                        // quota wall, not a momentary outage. Replaying it would
                        // hide the one line the user needs ("Resets in 3hr
                        // 52min"), so it fails at once with the provider's own
                        // words instead of retrying every few seconds for hours.
                        const quotaWall = statusCode == 429 &&
                            isPersistentRateLimit(detail);
                        const recovery = _retryPolicy.decide(statusCode,
                            attempt + 1, MonoTime.currTime - waitStart, quotaWall);
                        if (recovery.retry)
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
                        // The first read that returns bytes is the first time the
                        // provider has answered at all; from here on the wait is
                        // decoding tokens, not the provider.
                        pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.chatBegin));
                        _decoder._streamActive = true;

                        ubyte[8192] buffer;
                        string lineBuffer;
                        while (!shuttingDown() && !_decoder._streamDone &&
                            _decoder._streamError.length == 0)
                        {
                            DWORD readBytes;
                            if (http !is null)
                                readBytes = cast(DWORD) http.read(buffer);
                            else
                            {
                            // A full-size synchronous read can wait to fill the
                            // buffer. Read only bytes already available so short
                            // token chunks and [DONE] reach the UI immediately.
                            DWORD availableBytes;
                            bool readSucceeded = InternetQueryDataAvailable(
                                request, &availableBytes, 0, 0) != FALSE;
                            if (readSucceeded && availableBytes > 0)
                                readSucceeded = InternetReadFile(request, buffer.ptr,
                                    availableBytes < buffer.length ? availableBytes :
                                        cast(DWORD) buffer.length, &readBytes) != FALSE;
                            if (!readSucceeded)
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
                            }
                            if (readBytes == 0) break;

                            synchronized (_mutex)
                                if (_waitFirstByteMs < 0) _waitFirstByteMs = elapsedMsSince(waitStart);
                            _latency.mark(LatencyStage.firstByte);
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
                        if (shuttingDown()) cancelled = true;
                        if (!cancelled && lineBuffer.length > 0)
                            processSseLine(lineBuffer);
                    }
                }
                finally
                {
                    if (http !is null)
                    {
                        http.finish();
                        synchronized (_mutex) if (_httpRequest is http) _httpRequest = null;
                    }
                    if (request !is null)
                    {
                        if (!requestRegistered || unregisterRequest(request, true))
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
                    _decoder._streamContent, false, null, true, _decoder._lastPromptTokens,
                    _decoder._lastCompletionTokens, _decoder._lastTotalTokens));
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
                    _decoder._streamContent, false, null, true, _decoder._lastPromptTokens,
                    _decoder._lastCompletionTokens, _decoder._lastTotalTokens));
            else
                pushStreamEvent(OpenCodeEvent(OpenCodeEventKind.error, error.msg));
        }
    }

    /// Emit the terminal event for a stream that was not cancelled: a
    /// toolCalls event when the model requested tools, otherwise done.
    private void pushStreamEnd() { _decoder.finish(); }

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
        _waitStart = MonoTime.currTime;
        _waitFirstTokenMs = -1;
        _waitCacheLogged = false;
        _decoder._streamActive = true;
        _decoder._streamReasoning = "";
        _decoder._streamContent = "";
        _decoder._streamToolCalls.length = 0;
        _decoder._streamToolNamesPushed = 0;
        _decoder._streamToolArgBytes = 0;
        _decoder._lastToolProgressTime = MonoTime.currTime;
        _decoder._streamWantedTools = false;
        _decoder._streamFinishReason = "";
        _decoder._streamDone = false;
        _decoder._streamError = "";
        _decoder.outputIssue = "";
        _decoder.nextGuardBytes = 512;
        _decoder.guardToolNames = null;
        _decoder.audit = null;
        _decoder._lastPromptTokens = 0;
        _decoder._lastCompletionTokens = 0;
        _decoder._lastTotalTokens = 0;
        _decoder._lastCachedPromptTokens = 0;
        _decoder._lastUncachedPromptTokens = 0;
        _decoder._lastPushedPrompt = -1;
        _decoder._lastPushedCompletion = -1;
        _decoder._lastPushedTotal = -1;
        _decoder._lastPushedCachedPrompt = -1;
        _decoder._lastPushedUncachedPrompt = -1;
    }

    /// Test-only: how many ms must pass between throttled tool-progress
    /// events. 0 makes every argument change emit one, so a test can observe
    /// the live counters without waiting on a clock.
    public void setToolProgressIntervalMsForTesting(int value)
    {
        _decoder._toolProgressIntervalMs = value;
    }

    /// Test-only: build the request JSON body without sending anything.
    public string buildBodyForTesting(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, string model, bool thinking,
        bool forceReasoningReplay = false, string reasoningEffort = "",
        int thinkingBudgetTokens = 0, bool llamaCppServer = false)
    {
        return buildChatBody(messages, tools, model, thinking, _baseUrl,
            forceReasoningReplay, reasoningEffort, thinkingBudgetTokens,
            llamaCppServer);
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

    private void runModelsRequest(string requestBaseUrl, string requestApiKey,
        string requestSession)
    {
        scope (exit) finishWorker(false);

        try
        {
            const target = parseHttpTarget(requestBaseUrl, "/models");
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
                if (unregisterRequest(request, false)) InternetCloseHandle(request);
            }

            string headers = "User-Agent: " ~ userAgentFor(requestBaseUrl) ~ "\r\n";
            if (requestApiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ requestApiKey ~ "\r\n";
            if (isOpenCodeApiBaseUrl(requestBaseUrl))
                headers ~= "x-opencode-session: " ~ requestSession ~ "\r\n";
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
            int[string] contextLimits;
            bool llamaCppServer;
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
                        if (id is null || id.type != JSONType.string ||
                            id.str.length == 0) continue;
                        ids ~= id.str.dup;
                        if (isLlamaCppModelEntry(entry))
                        {
                            llamaCppServer = true;
                        }
                        const contextLimit = modelContextLimit(entry);
                        if (contextLimit > 0)
                            contextLimits[id.str] = contextLimit;
                    }
                }
            }
            if (ids.length == 0)
                throw new Exception("The models endpoint returned no models.");
            // llama.cpp's model metadata describes training capacity. /props
            // reports the active n_ctx and also detects remote servers whose
            // model catalog does not identify them as llama.cpp.
            if (ids.length == 1)
            {
                const runtimeLimit = llamaRuntimeContextLimit(session, target,
                    requestBaseUrl, requestApiKey);
                if (runtimeLimit > 0)
                {
                    contextLimits[ids[0]] = runtimeLimit;
                    llamaCppServer = true;
                }
            }
            OpenCodeEvent event;
            event.kind = OpenCodeEventKind.models;
            event.text = requestBaseUrl;
            event.modelIds = ids;
            event.modelContextLimits = contextLimits;
            event.llamaCppServer = llamaCppServer;
            pushEvent(event);
        }
        catch (Exception error)
        {
            if (!shuttingDown())
                logError("models request failed: " ~ error.msg ~ " [" ~
                    _baseUrl ~ "]");
            pushEvent(OpenCodeEvent(OpenCodeEventKind.modelsError, error.msg));
        }
    }

    private int llamaRuntimeContextLimit(HINTERNET session,
        const ref HttpTarget modelsTarget, string requestBaseUrl,
        string requestApiKey)
    {
        try
        {
            auto connection = InternetConnectW(session,
                toUTF16z(modelsTarget.host), modelsTarget.port, null, null,
                INTERNET_SERVICE_HTTP, 0, 0);
            if (connection is null) return 0;
            scope (exit) InternetCloseHandle(connection);
            const propsTarget = HttpTarget(modelsTarget.host,
                modelsTarget.port, "/props", modelsTarget.secure);
            auto request = HttpOpenRequestW(connection, "GET"w.ptr,
                "/props"w.ptr, null, null, null,
                requestFlags(propsTarget), 0);
            if (request is null) return 0;
            scope (exit) InternetCloseHandle(request);
            string headers = "User-Agent: " ~ userAgentFor(requestBaseUrl) ~ "\r\n";
            if (requestApiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ requestApiKey ~ "\r\n";
            if (!HttpSendRequestW(request, toUTF16z(headers), -1,
                    null, 0)) return 0;
            DWORD statusCode;
            DWORD statusLength = cast(DWORD) statusCode.sizeof;
            if (!HttpQueryInfoW(request,
                    HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                    &statusCode, &statusLength, null) || statusCode != 200)
                return 0;
            return runtimeContextLimit(readAllAsUtf8(request));
        }
        catch (Exception)
        {
            return 0;
        }
    }

    private static int positiveContext(const ref JSONValue value)
    {
        return value.type == JSONType.integer && value.integer > 0 &&
            value.integer <= int.max ? cast(int) value.integer : 0;
    }

    private static int modelContextLimit(const ref JSONValue entry)
    {
        if (entry.type != JSONType.object) return 0;
        int result;
        foreach (key; ["context_length", "context_window"])
            if (auto field = key in entry.object)
            {
                const value = positiveContext(*field);
                if (value > 0) result = value;
            }
        if (auto limit = "limit" in entry.object)
            if (limit.type == JSONType.object)
                if (auto context = "context" in limit.object)
                {
                    const value = positiveContext(*context);
                    if (value > 0) result = value;
                }
        return result;
    }

    private static bool isLlamaCppModelEntry(const ref JSONValue entry)
    {
        if (entry.type != JSONType.object) return false;
        if (auto owner = "owned_by" in entry.object)
            if (owner.type == JSONType.string &&
                (owner.str.toLower() == "llamacpp" ||
                 owner.str.toLower() == "llama.cpp"))
                return true;
        if (auto meta = "meta" in entry.object)
            if (meta.type == JSONType.object &&
                "n_ctx_train" in meta.object) return true;
        return false;
    }

    private static int runtimeContextLimit(string body)
    {
        const value = parseJSON(body);
        if (value.type != JSONType.object) return 0;
        auto settings = "default_generation_settings" in value.object;
        if (settings is null || settings.type != JSONType.object) return 0;
        auto context = "n_ctx" in settings.object;
        return context is null ? 0 : positiveContext(*context);
    }

    public static int modelContextLimitForTesting(string json)
    {
        const value = parseJSON(json);
        return modelContextLimit(value);
    }

    public static int runtimeContextLimitForTesting(string json)
    {
        return runtimeContextLimit(json);
    }

    public static bool isLlamaCppModelEntryForTesting(string json)
    {
        const value = parseJSON(json);
        return isLlamaCppModelEntry(value);
    }

    public static string chatImageDataUrl(const ref ChatImageAttachment image)
    {
        return providerImageDataUrl(image);
    }

    /**
     * Count a complete OpenAI chat request with llama.cpp's loaded tokenizer.
     *
     * `/v1/chat/completions/input_tokens` accepts the same body as the real
     * completion endpoint, so tool schemas, special tokens, reasoning history,
     * multimodal placeholders, and the model's current Jinja template are all
     * included. The endpoint performs no generation and does not consume the
     * model's KV prefix cache.
     */
    private int countChatInputTokens(HINTERNET session, string body,
        string requestBaseUrl, string requestApiKey)
    {
        HINTERNET connection;
        HINTERNET request;
        bool requestRegistered;
        try
        {
            const target = parseHttpTarget(requestBaseUrl,
                "/chat/completions/input_tokens");
            connection = InternetConnectW(session, toUTF16z(target.host),
                target.port, null, null, INTERNET_SERVICE_HTTP, 0, 0);
            if (connection is null) return 0;
            request = HttpOpenRequestW(connection, "POST"w.ptr,
                toUTF16z(target.path), null, null, null,
                requestFlags(target), 0);
            if (request is null || registerRequest(request, true) is null)
                return 0;
            requestRegistered = true;

            string headers = "User-Agent: " ~ userAgentFor(requestBaseUrl) ~ "\r\n";
            if (requestApiKey.length > 0)
                headers ~= "Authorization: Bearer " ~ requestApiKey ~ "\r\n";
            headers ~= "Content-Type: application/json\r\n" ~
                "Accept: application/json\r\n";
            auto bytes = cast(ubyte[]) body.dup;
            if (!HttpSendRequestW(request, toUTF16z(headers), -1,
                    bytes.ptr, cast(DWORD) bytes.length))
                return 0;

            DWORD statusCode;
            DWORD statusLength = cast(DWORD) statusCode.sizeof;
            if (!HttpQueryInfoW(request,
                    HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                    &statusCode, &statusLength, null) || statusCode != 200)
            {
                // Drain the response so the shared WinINet session remains
                // reusable, but do not fail a valid chat on an older server.
                readAllAsUtf8(request);
                logInfo("local input-token endpoint unavailable; final usage " ~
                    "will be used [" ~ _baseUrl ~ "]");
                return 0;
            }
            return parseInputTokenCount(readAllAsUtf8(request));
        }
        catch (Exception error)
        {
            if (!shuttingDown())
                logInfo("local input-token count unavailable: " ~ error.msg ~
                    " [" ~ _baseUrl ~ "]");
            return 0;
        }
        finally
        {
            if (request !is null)
            {
                if (!requestRegistered || unregisterRequest(request, true))
                    InternetCloseHandle(request);
            }
            if (connection !is null) InternetCloseHandle(connection);
        }
    }

    private static int parseInputTokenCount(string body)
    {
        try
        {
            const value = parseJSON(body);
            if (value.type != JSONType.object) return 0;
            auto count = "input_tokens" in value.object;
            if (count is null || count.type != JSONType.integer ||
                count.integer <= 0 || count.integer > int.max)
                return 0;
            return cast(int) count.integer;
        }
        catch (Exception)
        {
            return 0;
        }
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
        string model, string baseUrl, bool llamaCppServer)
    {
        const(ChatRequestMessage)[] normalized = llamaCppServer
            ? normalizeSystemMessages(messages, true) : messages;
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

    private WireProjectionCache _wireProjection;
    private WireProjectionCache wireProjectionCache()
    {
        if (_wireProjection is null) _wireProjection = new WireProjectionCache();
        return _wireProjection;
    }

    private static void logPayloadComponents(const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools, size_t bytes, ulong requestId)
    {
        size_t text, reasoning, toolOutput, images, schemas, arguments;
        foreach (message; messages)
        {
            if (message.role == "tool") toolOutput += message.content.length;
            else text += message.content.length;
            reasoning += message.reasoningContent.length;
            foreach (image; message.images) images += image.base64Data.length;
            foreach (call; message.toolCalls) arguments += call.arguments.length;
        }
        foreach (tool; tools) schemas += tool.parametersJson.length + tool.description.length;
        logInfo("request payload: id=" ~ to!string(requestId) ~ " wireBytes=" ~ to!string(bytes) ~
            " textBytes=" ~ to!string(text) ~ " reasoningBytes=" ~ to!string(reasoning) ~
            " toolOutputBytes=" ~ to!string(toolOutput) ~ " imageBase64Bytes=" ~ to!string(images) ~
            " toolSchemaBytes=" ~ to!string(schemas) ~ " argumentBytes=" ~ to!string(arguments));
    }

    /// Milliseconds elapsed since `start`, rounded down. Used for the wait
    /// breakdown only; not a timer.
    private static long elapsedMsSince(MonoTime start)
    {
        const ms = (MonoTime.currTime - start).total!"msecs";
        return cast(long) ms;
    }

    /// Count inline images across the request, matching logRequestShape, so the
    /// wait log can say whether the delay carried image bytes.
    private static long countInlineImages(const(ChatRequestMessage)[] messages)
    {
        long images;
        foreach (message; messages)
            foreach (image; message.images)
                if (image.base64Data.length > 0) ++images;
        return images;
    }

    /// One INFO line per answered request, in milliseconds from request start:
    /// connect / uploaded body / response headers / first SSE byte / first token.
    /// This is the evidence that attributes the "Waiting for the model…" delay
    /// to the connection, the upload, or the provider's own prefill.
    private void logWaitBreakdown()
    {
        logInfo("model wait: connect=" ~ to!string(_waitConnectMs) ~
            "ms sent=" ~ to!string(_waitSentMs) ~
            "ms headers=" ~ to!string(_waitHeadersMs) ~
            "ms firstByte=" ~ to!string(_waitFirstByteMs) ~
            "ms firstToken=" ~ to!string(_waitFirstTokenMs) ~
            "ms requestBytes=" ~ to!string(_lastRequestBytes) ~
            " images=" ~ to!string(_lastRequestImages) ~
            " [" ~ _baseUrl ~ "]");
    }

    private void recordFirstStreamToken()
    {
        synchronized (_mutex)
        {
            if (_waitFirstTokenMs >= 0) return;
            _waitFirstTokenMs = elapsedMsSince(_waitStart);
        }
        _latency.mark(LatencyStage.firstToken);
        logWaitBreakdown();
        logPromptCache();
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
        // Snapshots collapse and adjacent same-channel deltas merge without
        // changing text order; request identity survives the zero-copy drain.
        // This exercises the hot queue without a
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
        assert(events.length == 2);
        assert(events[0].totalTokens == 20 && events[0].requestId == 7);
        assert(events[1].text == "ab" && events[1].requestId == 7);

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

    private string dispatchSseLines(string buffer) { return _decoder.feed(buffer); }
    private void processSseLine(string line) { _decoder.feedLine(line); }

    private void logPromptCache()
    {
        // Correlation line: the wait breakdown says how long the first token
        // took; this says how much of that prompt the provider served from its
        // cache. High firstToken + low cache hits = prefill was paid in full.
        if (!_waitCacheLogged && _decoder._streamActive && _waitFirstTokenMs >= 0 &&
            (_decoder._lastCachedPromptTokens > 0 || _decoder._lastUncachedPromptTokens > 0))
        {
            _waitCacheLogged = true;
            const total = _decoder._lastCachedPromptTokens + _decoder._lastUncachedPromptTokens;
            const ratio = total > 0
                ? (_decoder._lastCachedPromptTokens * 100 / total) : 0;
            logInfo("prompt cache: cached=" ~
                to!string(_decoder._lastCachedPromptTokens) ~ " uncached=" ~
                to!string(_decoder._lastUncachedPromptTokens) ~ " (" ~
                to!string(ratio) ~ "% hit) firstToken=" ~
                to!string(_waitFirstTokenMs) ~ "ms [" ~ _baseUrl ~ "]");
        }
    }

    /// Test-only parser for llama.cpp's token-count response.
    public static int inputTokenCountForTesting(string body)
    {
        return parseInputTokenCount(body);
    }
}

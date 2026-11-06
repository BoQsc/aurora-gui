/**
 * The language-model half of the concision optimizer.
 *
 * Aurora Write shows the instant table pass first and then, once the writer
 * pauses, asks an OpenAI-compatible chat endpoint for better rewrites of the
 * same span plus a real definition. The request runs on its own thread so
 * typing never waits for the network; the UI polls `RefinementJob.done`.
 *
 * Transport is WinINet in synchronous mode on a worker thread: one short request
 * per pause, no streaming, no retries that could pile up behind typing.
 */
module aurorawrite.llmclient;

import aurorawrite.concision : ConciseChoice, maxChoiceWords, maxChoices, wordCount;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, strip;
import std.utf : toUTF32;

version (Windows)
{
    import core.sys.windows.windows : DWORD, GetLastError;
    import core.sys.windows.wininet;
    import std.utf : toUTF16z;
}

/// One refinement request: the span, its sentence, and the instant drafts.
struct RefinementRequest
{
    string baseUrl;
    string apiKey;
    string model;
    bool thinking;
    string sentence;
    string target;
    string instantDefinition;
    ConciseChoice[] instantChoices;
}

/// What the model returned, already validated into the card's shape.
struct RefinementResult
{
    bool ok;
    string error;
    string definition;
    ConciseChoice[] choices;
    long elapsedMs;
    /// First part of the provider's answer, kept for diagnostics.
    string raw;

    string statusLine() const @safe pure nothrow @nogc
    {
        if (!ok) return error.length ? error : "model unavailable";
        return "Model";
    }
}

/// True when this build can reach a provider.
bool refinementSupported() @safe pure nothrow @nogc
{
    version (Windows) return true;
    else return false;
}

private enum int connectTimeoutMs = 8_000;
private enum int sendTimeoutMs = 20_000;
private enum int receiveTimeoutMs = 90_000;

private immutable string systemPrompt =
    "You shorten English without losing meaning. Reply with JSON only. " ~
    "For the target word or phrase from the sentence you receive, return one " ~
    "plain definition of it as used there (one sentence, at most 16 words) " ~
    "and up to 8 shorter replacements. Each replacement is 1-3 words, keeps " ~
    "the sentence's meaning and is at most as long as the target; give each a " ~
    "one-sentence gloss of at most 12 words. Prefer everyday words. Never " ~
    "explain outside the JSON.";

/// Build the chat-completions body for one refinement.
string buildRefinementBody(const ref RefinementRequest request)
{
    string drafts;
    foreach (index, choice; request.instantChoices)
    {
        if (index >= 3) break;
        if (choice.text.length == 0) continue;
        if (drafts.length) drafts ~= " | ";
        drafts ~= choice.text;
    }

    auto user = "Sentence: \"" ~ request.sentence ~ "\"\n" ~
        "Target: \"" ~ request.target ~ "\"\n";
    if (request.instantDefinition.length)
        user ~= "Definition draft: \"" ~ request.instantDefinition ~ "\"\n";
    if (drafts.length) user ~= "Shorter drafts: \"" ~ drafts ~ "\"\n";
    user ~= "JSON: {\"definition\":\"...\",\"choices\":[{\"text\":\"...\"," ~
        "\"gloss\":\"...\"}]}";

    JSONValue root;
    root["model"] = request.model;
    JSONValue systemMessage;
    systemMessage["role"] = "system";
    systemMessage["content"] = systemPrompt;
    JSONValue userMessage;
    userMessage["role"] = "user";
    userMessage["content"] = user;
    JSONValue[] messages;
    messages ~= systemMessage;
    messages ~= userMessage;
    root["messages"] = messages;
    root["stream"] = false;
    root["temperature"] = 0.2;
    // A high-thinking route spends this budget on its reasoning first. 500 was
    // enough for the quiet pass but cut thinking answers off mid-JSON, so the
    // deliberate pass gets real headroom.
    root["max_tokens"] = request.thinking ? 2_048 : 500;

    // Reasoning controls are gateway vocabulary, not a standard: send the
    // explicit-off form only where a rejection is known to be impossible, and
    // omit it elsewhere so the provider's default applies.
    if (request.thinking)
        root["reasoning_effort"] = "high";
    else
    {
        const endpoint = request.baseUrl.strip.stripRight("/").toLowerAscii;
        if (endpoint == "https://api.commandcode.ai/provider/v1")
            root["reasoning_effort"] = "off";
        else if (endpoint.startsWithAscii("http://127.0.0.1") ||
            endpoint.startsWithAscii("http://localhost"))
            root["reasoning_effort"] = "none";
    }
    return root.toString();
}

private string toLowerAscii(string value) @safe pure nothrow
{
    char[] buffer = value.dup;
    foreach (ref char c; buffer)
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return buffer.idup;
}

private bool startsWithAscii(string value, string prefix) @safe pure nothrow
{
    return value.length >= prefix.length && value[0 .. prefix.length] == prefix;
}

private string stripRight(string value, string ch) @safe pure nothrow
{
    auto finish = value.length;
    while (finish > 0 && value[finish - 1] == ch[0]) --finish;
    return value[0 .. finish];
}

version (Windows)
{
    private struct HttpTarget
    {
        string host;
        ushort port;
        string path;
        bool secure;
    }

    /// Split an OpenAI-compatible base URL into a WinINet target.
    private HttpTarget parseTarget(string baseUrl, string suffix)
    {
        auto url = stripRight(baseUrl.strip, "/");
        auto scheme = "https";
        if (startsWithAscii(url, "https://")) url = url[8 .. $];
        else if (startsWithAscii(url, "http://"))
        {
            url = url[7 .. $];
            scheme = "http";
        }
        const slash = url.indexOf('/');
        auto hostPort = slash < 0 ? url : url[0 .. cast(size_t) slash];
        auto pathPart = slash < 0 ? "" : url[cast(size_t) slash .. $];
        auto host = hostPort;
        auto port = cast(ushort) (scheme == "https" ? 443 : 80);
        const colon = hostPort.indexOf(':');
        if (colon >= 0 && hostPort.lastIndexOf(':') == colon)
        {
            host = hostPort[0 .. cast(size_t) colon];
            try port = to!ushort(hostPort[cast(size_t) colon + 1 .. $]);
            catch (Exception) {}
        }
        return HttpTarget(host, port, stripRight(pathPart, "/") ~ suffix,
            scheme == "https");
    }

    private void setOption(HINTERNET handle, DWORD option, DWORD value)
    {
        DWORD payload = value;
        InternetSetOptionW(handle, option, &payload, payload.sizeof);
    }

    private string readAll(HINTERNET request)
    {
        string body;
        ubyte[8192] buffer;
        while (true)
        {
            DWORD read;
            if (!InternetReadFile(request, buffer.ptr,
                    cast(DWORD) buffer.length, &read) || read == 0)
                break;
            body ~= cast(string) buffer[0 .. cast(size_t) read];
            if (body.length > 256 * 1024) break;
        }
        return body;
    }

    private string postJson(const ref RefinementRequest request, string body,
        out DWORD status)
    {
        status = 0;
        const target = parseTarget(request.baseUrl, "/chat/completions");
        auto session = InternetOpenW("AuroraWrite/1.0"w.ptr,
            INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
        if (session is null) throw new Exception("WinINet session unavailable.");
        scope (exit) InternetCloseHandle(session);
        setOption(session, INTERNET_OPTION_CONNECT_TIMEOUT, connectTimeoutMs);
        setOption(session, INTERNET_OPTION_SEND_TIMEOUT, sendTimeoutMs);
        setOption(session, INTERNET_OPTION_RECEIVE_TIMEOUT, receiveTimeoutMs);

        auto connection = InternetConnectW(session, toUTF16z(target.host),
            target.port, null, null, INTERNET_SERVICE_HTTP, 0, 0);
        if (connection is null) throw new Exception("Could not reach the endpoint.");
        scope (exit) InternetCloseHandle(connection);

        DWORD flags = INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE |
            INTERNET_FLAG_PRAGMA_NOCACHE;
        if (target.secure) flags |= INTERNET_FLAG_SECURE;
        auto handle = HttpOpenRequestW(connection, "POST"w.ptr,
            toUTF16z(target.path), null, null, null, flags, 0);
        if (handle is null) throw new Exception("Could not open the request.");
        scope (exit) InternetCloseHandle(handle);

        auto headers = "Content-Type: application/json\r\n" ~
            "Accept: application/json\r\n";
        if (request.apiKey.length)
            headers ~= "Authorization: Bearer " ~ request.apiKey ~ "\r\n";

        auto bytes = cast(ubyte[]) body.dup;
        if (!HttpSendRequestW(handle, toUTF16z(headers), -1, bytes.ptr,
                cast(DWORD) bytes.length))
            throw new Exception("Request failed (" ~ to!string(GetLastError()) ~ ").");

        DWORD length = cast(DWORD) status.sizeof;
        if (!HttpQueryInfoW(handle, HTTP_QUERY_STATUS_CODE |
                HTTP_QUERY_FLAG_NUMBER, &status, &length, null))
            throw new Exception("No HTTP status returned.");
        return readAll(handle);
    }
}

/// Pull the answer text out of a chat-completions response.
private string completionText(const JSONValue response)
{
    if (response.type != JSONType.object) return "";
    auto choices = "choices" in response.object;
    if (choices is null || choices.type != JSONType.array || choices.array.length == 0)
        return "";
    auto message = "message" in choices.array[0].object;
    if (message is null || message.type != JSONType.object) return "";
    // Thinking routes sometimes leave `content` empty and put the answer in a
    // reasoning field; read every text field the OpenAI family uses.
    foreach (key; ["content", "reasoning_content", "reasoning", "text"])
    {
        auto found = key in message.object;
        if (found is null || found.type != JSONType.string) continue;
        if (found.str.strip.length > 0) return found.str;
    }
    return "";
}

/// Every balanced `{...}` slice in `text`, in order (strings and escapes aware).
private string[] jsonObjectsIn(string text) @safe pure
{
    string[] objects;
    size_t index = 0;
    while (index < text.length)
    {
        if (text[index] != '{')
        {
            ++index;
            continue;
        }
        const start = index;
        int depth;
        bool inString;
        bool escaped;
        while (index < text.length)
        {
            const c = text[index];
            if (inString)
            {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
            }
            else if (c == '"') inString = true;
            else if (c == '{') ++depth;
            else if (c == '}')
            {
                --depth;
                if (depth == 0)
                {
                    objects ~= text[start .. index + 1];
                    break;
                }
            }
            ++index;
        }
        ++index;
    }
    return objects;
}

/// Validate a model answer into the card's shape.
RefinementResult parseRefinement(string answer, string target)
{
    RefinementResult result;
    result.raw = answer.length > 400 ? answer[0 .. 400] : answer;
    const candidates = jsonObjectsIn(answer);
    if (candidates.length == 0)
    {
        result.error = "Model reply was not JSON.";
        return result;
    }
    // Reasoning routes can wrap the object in commentary, so use the first
    // balanced object that actually parses into this product's shape.
    foreach (body; candidates)
    {
        JSONValue value;
        try value = parseJSON(body);
        catch (Exception) continue;
        if (value.type != JSONType.object) continue;
        auto definitionField = "definition" in value.object;
        auto choicesField = "choices" in value.object;
        if (definitionField is null && choicesField is null) continue;
        if (auto definition = "definition" in value.object)
            if (definition.type == JSONType.string)
                result.definition = definition.str.strip;
        if (auto choices = "choices" in value.object)
        {
            if (choices.type == JSONType.array)
            {
                foreach (ref entry; choices.array)
                {
                    if (entry.type != JSONType.object) continue;
                    auto text = "text" in entry.object;
                    if (text is null || text.type != JSONType.string) continue;
                    const candidate = text.str.strip;
                    if (candidate.length == 0) continue;
                    if (candidate.toLowerAscii == target.strip.toLowerAscii) continue;
                    if (wordCount(candidate) > maxChoiceWords) continue;
                    string gloss;
                    if (auto found = "gloss" in entry.object)
                        if (found.type == JSONType.string) gloss = found.str.strip;
                    result.choices ~= ConciseChoice(candidate, gloss,
                        wordCount(candidate), true);
                    if (result.choices.length >= maxChoices) break;
                }
            }
        }
        if (result.choices.length > 0 || result.definition.length > 0) break;
    }
    if (result.choices.length == 0 && result.definition.length == 0)
    {
        result.error = "Model reply could not be read.";
        return result;
    }
    result.ok = true;
    return result;
}

/// Blocking refinement; call it on a worker thread only.
RefinementResult refine(const ref RefinementRequest request)
{
    RefinementResult result;
    auto watch = StopWatch(AutoStart.yes);
    scope (exit) result.elapsedMs = watch.peek.total!"msecs";
    if (!request.baseUrl.length || !request.model.length)
    {
        result.error = "No provider configured.";
        return result;
    }
    const body = buildRefinementBody(request);
    version (Windows)
    {
        DWORD status;
        string response;
        try response = postJson(request, body, status);
        catch (Exception error)
        {
            result.error = error.msg;
            return result;
        }
        if (status != 200)
        {
            const detail = response.length > 160 ? response[0 .. 160] : response;
            result.error = "Provider returned HTTP " ~ to!string(status) ~
                (detail.length ? ": " ~ detail.strip : "");
            return result;
        }
        try
        {
            auto parsed = parseRefinement(completionText(parseJSON(response)),
                request.target);
            // Measured here, before the scope(exit) below runs: assigning from
            // `result` would copy the unset value and always report 0 ms.
            parsed.elapsedMs = watch.peek.total!"msecs";
            return parsed;
        }
        catch (Exception)
        {
            result.error = "Provider reply was not valid JSON.";
            return result;
        }
    }
    else
    {
        result.error = "This build has no HTTP transport.";
        return result;
    }
}

/**
 * One background refinement with a single-owner result slot.
 *
 * The UI keeps the job object, polls `done()` from its tick, and reads the
 * result once. A newer keystroke simply abandons the finished job, so stale
 * answers can never overwrite suggestions for text that has since changed.
 */
final class RefinementJob
{
    private Mutex _mutex;
    private Condition _changed;
    private bool _done;
    private bool _consumed;
    private RefinementResult _result;
    private Thread _thread;

    this()
    {
        _mutex = new Mutex();
        _changed = new Condition(_mutex);
    }

    void start(RefinementRequest request)
    {
        auto worker = new Thread(delegate()
        {
            RefinementResult completed;
            try completed = refine(request);
            catch (Exception error)
            {
                completed.error = error.msg;
            }
            synchronized (_mutex)
            {
                _result = completed;
                _done = true;
                _changed.notifyAll();
            }
        });
        worker.isDaemon = true;
        _thread = worker;
        worker.start();
    }

    bool done()
    {
        synchronized (_mutex) return _done && !_consumed;
    }

    /// Read the finished result once; later calls return an empty result.
    RefinementResult take()
    {
        synchronized (_mutex)
        {
            if (!_done || _consumed) return RefinementResult.init;
            _consumed = true;
            return _result;
        }
    }

    /// Block until the worker finished; used by the headless probe only.
    void join()
    {
        if (_thread !is null) _thread.join();
    }
}

unittest
{
    // The instant drafts steer the model, and thinking adds the effort knob.
    RefinementRequest request;
    request.baseUrl = "https://api.commandcode.ai/provider/v1";
    request.model = "deepseek/deepseek-v4.1-flash";
    request.target = "utilize";
    request.sentence = "We utilize the tool daily.";
    request.instantDefinition = "To put something to practical use.";
    request.instantChoices = [ConciseChoice("use", "Plain verb.", 1, false)];
    request.thinking = true;
    const thinkingBody = parseJSON(buildRefinementBody(request));
    assert(thinkingBody["reasoning_effort"].str == "high");
    assert(thinkingBody["max_tokens"].integer == 2_048);
    assert(thinkingBody["stream"].boolean == false);
    assert(thinkingBody["messages"].array.length == 2);
    assert(thinkingBody["messages"].array[1]["content"].str.indexOf("utilize") > 0);

    request.thinking = false;
    const quietBody = parseJSON(buildRefinementBody(request));
    assert(quietBody["reasoning_effort"].str == "off");
    assert(quietBody["max_tokens"].integer == 500);
}

unittest
{
    // A fenced answer still parses, duplicates of the target drop out, and the
    // shortlist is capped.
    const answer = "```json\n{\"definition\":\"To put something to use.\"," ~
        "\"choices\":[{\"text\":\"utilize\",\"gloss\":\"itself\"}," ~
        "{\"text\":\"use\",\"gloss\":\"Plain verb for the act.\"}," ~
        "{\"text\":\"apply\",\"gloss\":\"Put it to its purpose.\"}]}\n```";
    const result = parseRefinement(answer, "utilize");
    assert(result.ok);
    assert(result.definition == "To put something to use.");
    assert(result.choices.length == 2);
    assert(result.choices[0].text == "use");
    assert(result.choices[0].refined);
    assert(result.choices[1].text == "apply");
}

unittest
{
    const missing = parseRefinement("I cannot help with that.", "utilize");
    assert(!missing.ok);
    assert(missing.error.length > 0);
    assert(missing.raw == "I cannot help with that.");

    const empty = parseRefinement("{\"choices\":[]}", "utilize");
    assert(!empty.ok);
}

unittest
{
    // A thinking route may narrate before the object, and earlier prose can
    // contain braces. The first balanced object that fits the shape wins.
    const narrated = "Thinking: the reader wants {short} words.\n" ~
        "{\"definition\":\"To put something to use.\"," ~
        "\"choices\":[{\"text\":\"use\",\"gloss\":\"Plain verb.\"}]}";
    const parsed = parseRefinement(narrated, "utilize");
    assert(parsed.ok, parsed.error);
    assert(parsed.definition == "To put something to use.");
    assert(parsed.choices.length == 1);

    // A brace inside the JSON string must not be treated as structure.
    const braces = "{\"definition\":\"A {tight} claim.\"," ~
        "\"choices\":[{\"text\":\"show\",\"gloss\":\"Set it out.\"}]}";
    const withBraces = parseRefinement(braces, "demonstrate");
    assert(withBraces.ok);
    assert(withBraces.definition == "A {tight} claim.");
    assert(withBraces.choices[0].text == "show");

    // A well-formed object that is not this shape is skipped, not accepted.
    const unrelated = "{\"error\":\"rate limited\"}{\"definition\":\"x\"," ~
        "\"choices\":[{\"text\":\"ease\",\"gloss\":\"Make it simpler.\"}]}";
    const second = parseRefinement(unrelated, "facilitate");
    assert(second.ok);
    assert(second.choices[0].text == "ease");
}

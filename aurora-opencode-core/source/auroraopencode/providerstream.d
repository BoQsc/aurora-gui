module auroraopencode.providerstream;

import auroraopencode.events;
import auroraopencode.core : OpenCodeToolCall;
import core.time : MonoTime;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : indexOf;

/// One stream decoder owns provider accumulation and usage interpretation.
/// It knows no HTTP handles, mutexes, widgets, files, or task continuation rules.
/// Callback effects are supplied by transport or a captured-stream replay.
public final class ProviderStreamDecoder
{
    void delegate(OpenCodeEvent) emit;
    void delegate() onFirstToken;
    void delegate() onUsage;
    void delegate(int, int) onTokenizerMismatch;
    string function(string) formatError;
    string _streamReasoning;
    string _streamContent;
    OpenCodeToolCall[] _streamToolCalls;
    size_t _streamToolNamesPushed;
    int _toolProgressIntervalMs = 120;
    MonoTime _lastToolProgressTime;
    size_t _streamToolArgBytes;
    bool _streamWantedTools;
    string _streamFinishReason;
    bool _streamDone;
    string _streamError;
    int _lastPromptTokens;
    int _lastCompletionTokens;
    int _lastTotalTokens;
    int _lastCachedPromptTokens;
    int _lastUncachedPromptTokens;
    int _preflightPromptTokens;
    bool _streamActive;
    int _lastPushedPrompt;
    int _lastPushedCompletion;
    int _lastPushedTotal;
    int _lastPushedCachedPrompt;
    int _lastPushedUncachedPrompt;

    string feed(string buffer)
    {
        size_t start;
        while (true)
        {
            const newline = indexOf(buffer, '\n', start);
            if (newline < 0) break;
            const line = buffer[start .. cast(size_t) newline];
            start = cast(size_t) newline + 1;
            feedLine(line);
        }
        return start >= buffer.length ? "" : buffer[start .. $];
    }

    /// Allocation-free test for the `[DONE]` sentinel, tolerating surrounding
    /// ASCII spaces/tabs (some gateways send `data: [DONE]`). `strip()` copied
    /// the payload on every non-empty chunk; this runs on the hottest path.
    private static bool isDonePayload(string payload)
    {
        size_t start;
        while (start < payload.length &&
            (payload[start] == ' ' || payload[start] == '\t')) ++start;
        size_t end = payload.length;
        while (end > start &&
            (payload[end - 1] == ' ' || payload[end - 1] == '\t')) --end;
        const done = "[DONE]";
        if (end - start != done.length) return false;
        foreach (i; 0 .. done.length)
            if (payload[start + i] != done[i]) return false;
        return true;
    }

    void feedLine(string line)
    {
        if (_streamDone || _streamError.length > 0) return;
        if (line.length > 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (line.length < 5 || line[0 .. 5] != "data:") return;
        const payload = line[5 .. $];
        if (payload.length == 0) return;
        if (isDonePayload(payload))
        {
            _streamDone = true;
            return;
        }

        JSONValue value;
        try value = parseJSON(payload);
        catch (Exception)
        {
            _streamError = "The provider sent an invalid streaming response. " ~
                "Your partial reply has been preserved; try again.";
            return;
        }
        if (value.type != JSONType.object) return;

        if (auto error = "error" in value.object)
        {
            if (error.type != JSONType.null_)
            {
                _streamError = "Provider error: " ~ (formatError !is null ? formatError(payload) : payload);
                return;
            }
        }
        captureUsage(value);

        auto choices = "choices" in value.object;
        if (choices is null || choices.type != JSONType.array ||
            choices.array.length == 0)
        {
            // Some providers deliver the usage summary in a chunk with empty
            // choices just before [DONE].
            return;
        }
        const choice = choices.array[0];
        if (choice.type != JSONType.object) return;

        // Some providers signal tool-call completion through the chunk's
        // finish_reason before [DONE]; others only through the delta shape.
        if (auto found = "finish_reason" in choice.object)
            if (found.type == JSONType.string)
            {
                _streamFinishReason = found.str;
                if (found.str == "tool_calls") _streamWantedTools = true;
            }

        auto delta = "delta" in choice.object;
        if (delta is null || delta.type != JSONType.object) return;

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
                        {
                            if (field.integer < 0 || field.integer >= 128)
                            {
                                _streamError = "The provider sent an invalid tool-call index.";
                                return;
                            }
                            index = cast(int) field.integer;
                        }
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
                if (_streamToolCalls.length > 0)
                    if (onFirstToken !is null) onFirstToken();
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
                    emit(OpenCodeEvent(OpenCodeEventKind.toolCallDelta,
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
        // The first token of any kind ends the opaque "Waiting for the model…"
        // phase; record it once and log the full breakdown so the wait can be
        // attributed (upload vs provider) instead of guessed at.
        if (onFirstToken !is null) onFirstToken();
        if (reasoningFragment.length > 0)
        {
            _streamReasoning ~= reasoningFragment;
            emit(OpenCodeEvent(OpenCodeEventKind.delta,
                reasoningFragment, true));
        }
        if (contentFragment.length > 0)
        {
            _streamContent ~= contentFragment;
            emit(OpenCodeEvent(OpenCodeEventKind.delta,
                contentFragment, false));
        }
    }

    private void captureUsage(const JSONValue value)
    {
        if (value.type != JSONType.object) return;
        auto usage = "usage" in value.object;
        // Responses-style streams nest the final usage object under response;
        // Anthropic-compatible gateways use input_tokens/output_tokens.
        if ((usage is null || usage.type != JSONType.object))
        {
            if (auto response = "response" in value.object)
                if (response.type == JSONType.object)
                    usage = "usage" in response.object;
        }
        if (usage is null || usage.type != JSONType.object) return;
        auto prompt = "prompt_tokens" in usage.object;
        const promptIsAnthropicInput = prompt is null;
        if (prompt is null) prompt = "input_tokens" in usage.object;
        if (prompt !is null && prompt.type == JSONType.integer)
            _lastPromptTokens = cast(int) prompt.integer;
        if (_preflightPromptTokens > 0 && _lastPromptTokens > 0 &&
            _preflightPromptTokens != _lastPromptTokens)
        {
            if (onTokenizerMismatch !is null)
                onTokenizerMismatch(_preflightPromptTokens, _lastPromptTokens);
            // Log once even when a provider repeats usage in several chunks.
            _preflightPromptTokens = 0;
        }
        auto completion = "completion_tokens" in usage.object;
        if (completion is null) completion = "output_tokens" in usage.object;
        if (completion !is null && completion.type == JSONType.integer)
            _lastCompletionTokens = cast(int) completion.integer;
        if (auto field = "total_tokens" in usage.object)
            if (field.type == JSONType.integer)
                _lastTotalTokens = cast(int) field.integer;

        // DeepSeek's disk cache exposes direct hit/miss counters.
        if (auto field = "prompt_cache_hit_tokens" in usage.object)
            if (field.type == JSONType.integer)
            {
                _lastCachedPromptTokens = cast(int) field.integer;
            }
        if (auto field = "prompt_cache_miss_tokens" in usage.object)
            if (field.type == JSONType.integer)
            {
                _lastUncachedPromptTokens = cast(int) field.integer;
            }

        // OpenAI nests cached input under prompt_tokens_details. Derive the
        // uncached portion from the authoritative prompt total.
        if (auto details = "prompt_tokens_details" in usage.object)
            if (details.type == JSONType.object)
                if (auto field = "cached_tokens" in details.object)
                    if (field.type == JSONType.integer)
                    {
                        _lastCachedPromptTokens = cast(int) field.integer;
                        _lastUncachedPromptTokens = _lastPromptTokens >
                            _lastCachedPromptTokens
                            ? _lastPromptTokens - _lastCachedPromptTokens : 0;
                    }

        // Anthropic usage separates ordinary input, cache reads, and cache
        // creation. Count cache creation as uncached work and include all three
        // in prompt occupancy; `input_tokens` alone otherwise under-reports it.
        int cacheRead;
        int cacheCreation;
        bool sawAnthropicCache;
        if (auto field = "cache_read_input_tokens" in usage.object)
            if (field.type == JSONType.integer)
            {
                cacheRead = cast(int) field.integer;
                sawAnthropicCache = true;
            }
        if (auto field = "cache_creation_input_tokens" in usage.object)
            if (field.type == JSONType.integer)
            {
                cacheCreation = cast(int) field.integer;
                sawAnthropicCache = true;
            }
        if (sawAnthropicCache)
        {
            _lastCachedPromptTokens = cacheRead;
            _lastUncachedPromptTokens = _lastPromptTokens + cacheCreation;
            if (promptIsAnthropicInput)
                _lastPromptTokens += cacheRead + cacheCreation;
        }
        if (_lastTotalTokens <= 0 &&
            (_lastPromptTokens > 0 || _lastCompletionTokens > 0))
            _lastTotalTokens = _lastPromptTokens + _lastCompletionTokens;
        // Mirror the real opencode: surface exact provider usage live so the
        // UI can meter context before the stream ends when the provider sends
        // usage in intermediate chunks (many only send it in the final one).
        if (_streamActive &&
            (_lastPromptTokens != _lastPushedPrompt ||
                _lastCompletionTokens != _lastPushedCompletion ||
                _lastTotalTokens != _lastPushedTotal ||
                _lastCachedPromptTokens != _lastPushedCachedPrompt ||
                _lastUncachedPromptTokens != _lastPushedUncachedPrompt))
        {
            _lastPushedPrompt = _lastPromptTokens;
            _lastPushedCompletion = _lastCompletionTokens;
            _lastPushedTotal = _lastTotalTokens;
            _lastPushedCachedPrompt = _lastCachedPromptTokens;
            _lastPushedUncachedPrompt = _lastUncachedPromptTokens;
            auto event = OpenCodeEvent(OpenCodeEventKind.usage, "", false, null,
                false, _lastPromptTokens, _lastCompletionTokens,
                _lastTotalTokens);
            event.cachedPromptTokens = _lastCachedPromptTokens;
            event.uncachedPromptTokens = _lastUncachedPromptTokens;
            emit(event);
        }

        if (onUsage !is null) onUsage();
    }

    void finish()
    {
        if (_streamError.length > 0 ||
            (!_streamDone && _streamFinishReason.length == 0))
        {
            emit(OpenCodeEvent(OpenCodeEventKind.error,
                _streamError.length > 0 ? _streamError :
                    "The connection closed before the reply finished. " ~
                    "Your partial reply has been preserved; try again."));
            return;
        }
        // Never execute tool arguments cut off by the output limit.
        if (_streamWantedTools && (_streamFinishReason == "length" ||
            _streamFinishReason == "max_tokens"))
        {
            emit(OpenCodeEvent(OpenCodeEventKind.error,
                "The model reached its output limit while preparing tools. " ~
                "No incomplete tool calls were executed. Try a smaller request."));
            return;
        }
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
        emit(event);
    }

}

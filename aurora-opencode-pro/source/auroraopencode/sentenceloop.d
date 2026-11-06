module auroraopencode.sentenceloop;

/**
 * Experimental: the streaming computer loop, one sentence per action.
 *
 * The prototype this replaces (the "reactive paragraph" presentation plus the
 * non-streaming nested `subagent` round) made the loop read as one paragraph
 * while every step still paid a whole request/response before anything was
 * visible. This module supplies the parts of the streaming loop that are pure
 * logic, so the behaviour can be tested without a provider, a desktop or a
 * window:
 *
 *   1. `takeSentences` cuts the assistant's streamed text at sentence ends, so
 *      a sentence can be shown (and the loop's pace measured) while the reply
 *      is still decoding.
 *   2. `actionArgumentsReady` decides when a streamed tool call is final
 *      enough to run.
 *   3. `sentenceLoopPrompt` is the loop's discipline: the frame comes first,
 *      then one short sentence about it, then exactly one action.
 *   4. `SentencePace` measures the cycle the user cares about - how long from
 *      one sentence to the next - instead of a wall-clock guess.
 *
 * Nothing here performs input, HTTP or rendering: `computeruse.d` owns the
 * desktop and the provider request, and the tool row shows the sentences.
 */

import std.conv : to;
import std.process : environment;
import std.string : indexOf, strip;

/// Longest sentence fragment kept before the loop flushes anyway. A model that
/// emits no terminator would otherwise hold back every sentence of the reply.
enum size_t maxSentenceChars = 320;

/// Cut complete sentences out of `buffer`, returning them and leaving only the
/// unfinished tail in `buffer`. `flush` releases the tail as well (used when the
/// stream ends, so a final sentence without a period is still shown).
///
/// A boundary is a terminator (`.` `!` `?`) followed by whitespace or the end of
/// what has arrived, or a newline. Trailing quotes/brackets belong to the
/// sentence they close. Decimal points inside numbers ("3.5 s") are followed by
/// a digit, so they do not split.
string[] takeSentences(ref string buffer, bool flush = false)
{
    string[] result;
    void emit(size_t from, size_t to)
    {
        if (to <= from) return;
        const piece = strip(buffer[from .. to]);
        if (piece.length) result ~= piece;
    }
    size_t start;
    size_t index;
    while (index < buffer.length)
    {
        const ch = buffer[index];
        if (ch == '\n')
        {
            emit(start, index);
            start = ++index;
            continue;
        }
        if (ch != '.' && ch != '!' && ch != '?')
        {
            ++index;
            continue;
        }
        const afterTerminator = index + 1;
        size_t end = afterTerminator;
        while (end < buffer.length && (buffer[end] == '"' || buffer[end] == '\'' ||
            buffer[end] == ')' || buffer[end] == ']'))
            ++end;
        const closed = end >= buffer.length
            ? flush
            : (buffer[end] == ' ' || buffer[end] == '\t' || buffer[end] == '\n');
        if (closed)
        {
            emit(start, end);
            start = end;
        }
        index = end;
    }
    buffer = buffer[start .. $];
    // No terminator for a long stretch: release whole chunks so a run-on reply
    // still reads as sentences instead of arriving in one block at the end.
    while (buffer.length > maxSentenceChars)
    {
        auto cut = maxSentenceChars;
        while (cut > 0 && (cast(ubyte) buffer[cut] & 0xC0) == 0x80) --cut;
        if (cut == 0) break;
        emit(0, cut);
        buffer = buffer[cut .. $];
    }
    if (flush && buffer.length)
    {
        auto piece = strip(buffer);
        if (piece.length) result ~= piece;
        buffer = "";
    }
    return result;
}

/// When a streamed tool call may run. Argument fragments arrive cumulatively, so
/// a partial `{"action":"click"}` can parse before its coordinates exist:
/// parsing alone is not enough. The call is run only once the provider has also
/// signalled that the message is finished, which is the first moment the
/// arguments cannot still grow.
bool actionArgumentsReady(string arguments, bool messageFinished)
{
    if (!messageFinished) return false;
    const trimmed = strip(arguments);
    if (trimmed.length < 2 || trimmed[0] != '{' || trimmed[$ - 1] != '}') return false;
    import std.json : JSONType, parseJSON;
    try return parseJSON(trimmed).type == JSONType.object;
    catch (Exception) return false;
}

/// The cycle the operator feels: from one sentence to the next. `lastCycleMs`
/// is the previous round's cost (its first sentence to this round's first
/// sentence); `firstSentenceMs` is this round's provider latency.
struct SentencePace
{
    int rounds;
    int sentences;
    long lastCycleMs;
    long totalCycleMs;
    long firstSentenceMs;
}

/// Human text for the live row and the loop's result. Only measured values are
/// printed; a missing measurement prints nothing rather than a placeholder.
string sentencePaceText(const ref SentencePace pace)
{
    if (pace.rounds <= 0) return "";
    auto text = "round " ~ to!string(pace.rounds) ~ " · " ~
        to!string(pace.sentences) ~ " sentence" ~ (pace.sentences == 1 ? "" : "s");
    if (pace.firstSentenceMs > 0)
        text ~= " · first sentence " ~ millisecondsText(pace.firstSentenceMs);
    if (pace.lastCycleMs > 0)
        text ~= " · " ~ millisecondsText(pace.lastCycleMs) ~ " per sentence";
    return text;
}

string millisecondsText(long ms)
{
    if (ms < 1000) return to!string(ms) ~ " ms";
    const tenths = (ms + 50) / 100;
    return to!string(tenths / 10) ~ "." ~ to!string(tenths % 10) ~ " s";
}

/// Loop discipline folded into the loop's own system prompt. The point is that a
/// sentence is not narration: it reports the attached frame, and the action
/// follows from it. Replaces the reactive-paragraph main-chat module.
string sentenceLoopPrompt()
{
    return "Work in sentence-sized cycles. Every user message attaches the " ~
        "current screen first; read that frame before writing anything. " ~
        "Then reply with ONE short sentence that states only what that frame " ~
        "shows or which control you will use, and send exactly one action " ~
        "call for it. Do not describe a plan, do not restate the task, and do " ~
        "not claim an outcome you have not seen in a frame. A sentence " ~
        "without an action, or an action without a sentence, is a mistake; " ~
        "when the task is finished, reply with one sentence and no action.";
}

private __gshared bool _enabled;

/// Called by the app on load and whenever the Settings switch changes.
public void setSentenceLoopSetting(bool value)
{
    _enabled = value;
}

/// Whether the streaming loop presentation is on. The persisted switch is the
/// one that also arms the `computer` tool; the environment override lets a
/// scripted run pin it without touching settings. The old reactive-paragraph
/// variable is still honoured so an existing launcher keeps working.
public bool experimentalSentenceLoopEnabled()
{
    const raw = strip(environment.get("AURORA_STREAMING_LOOP", ""));
    const legacy = strip(environment.get("AURORA_REACTIVE_PARAGRAPH", ""));
    const value = raw.length > 0 ? raw : legacy;
    if (value.length > 0) return value == "1" || value == "true" || value == "on";
    return _enabled;
}

/// A round continues the paragraph above it exactly when the message before it
/// is a tool result: that seam is what makes a screenshot/act loop read as one
/// live narration instead of a stack of separate replies.
public bool sentenceLoopContinues(string previousRole, string role)
{
    return role == "assistant" && previousRole == "tool";
}

unittest
{
    // A sentence is released as soon as its terminator arrives, not at the end.
    string buffer = "The dialog is open. I will click Continue";
    auto first = takeSentences(buffer);
    assert(first.length == 1, first.to!string);
    assert(first[0] == "The dialog is open.", first[0]);
    assert(buffer == " I will click Continue", buffer);

    // The tail stays buffered while the stream is still open.
    assert(takeSentences(buffer).length == 0);
    assert(buffer == " I will click Continue", buffer);
    // At the end of the stream the unterminated sentence is still shown.
    auto tail = takeSentences(buffer, true);
    assert(tail.length == 1 && tail[0] == "I will click Continue", tail.to!string);
    assert(buffer.length == 0);

    // Decimals do not split; quotes stay with their sentence.
    buffer = "Took 3.5 s. It says \"Ready.\" Next";
    auto pieces = takeSentences(buffer, true);
    assert(pieces.length == 3, pieces.to!string);
    assert(pieces[0] == "Took 3.5 s.", pieces[0]);
    assert(pieces[1] == "It says \"Ready.\"", pieces[1]);
    assert(pieces[2] == "Next", pieces[2]);
    assert(buffer.length == 0, buffer);

    // Newlines end a sentence even without punctuation.
    buffer = "Loading\nMenu visible. Clicking";
    pieces = takeSentences(buffer);
    assert(pieces.length == 2, pieces.to!string);
    assert(pieces[0] == "Loading", pieces[0]);
    assert(pieces[1] == "Menu visible.", pieces[1]);
    assert(buffer == " Clicking", buffer);

    // A run-on paragraph is still released in readable chunks.
    buffer.length = 0;
    foreach (i; 0 .. maxSentenceChars * 2) buffer ~= 'x';
    auto chunks = takeSentences(buffer);
    assert(chunks.length == 1 && chunks[0].length == maxSentenceChars, chunks.to!string);
    assert(buffer.length == maxSentenceChars, to!string(buffer.length));

    // Parsing alone is not readiness: the stream must be finished too.
    assert(!actionArgumentsReady(`{"action":"click"}`, false));
    assert(actionArgumentsReady(`{"action":"click","x":1,"y":2}`, true));
    assert(!actionArgumentsReady(`{"action":"click","x":1,"y":`, true));
    assert(!actionArgumentsReady(``, true));
    assert(!actionArgumentsReady(`not json`, true));

    // Pace prints only measured values.
    SentencePace pace;
    assert(sentencePaceText(pace).length == 0);
    pace.rounds = 3;
    pace.sentences = 4;
    pace.firstSentenceMs = 640;
    pace.lastCycleMs = 2100;
    const text = sentencePaceText(pace);
    assert(text == "round 3 · 4 sentences · first sentence 640 ms · 2.1 s per sentence", text);

    // The prompt states the cycle order the loop enforces.
    const prompt = sentenceLoopPrompt();
    assert(prompt.indexOf("ONE short sentence") >= 0);
    assert(prompt.indexOf("exactly one action") >= 0);

    // The shared switch drives the loop presentation, and a round that answers
    // a tool result continues the block above it.
    setSentenceLoopSetting(true);
    assert(experimentalSentenceLoopEnabled());
    setSentenceLoopSetting(false);
    assert(!experimentalSentenceLoopEnabled());
    assert(sentenceLoopContinues("tool", "assistant"));
    assert(!sentenceLoopContinues("assistant", "assistant"));
    assert(!sentenceLoopContinues("user", "assistant"));
}

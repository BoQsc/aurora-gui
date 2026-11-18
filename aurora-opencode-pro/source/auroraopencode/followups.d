module auroraopencode.followups;

// ===========================================================================
// Suggested follow-ups: 2 clickable next messages shown at the end of a
// settled conversation. Unlike the composer suggestion (one line inserted with
// Tab), these are deliberately different directions the user could take, so
// the list reads as options rather than a single guess.
//
// The instruction and the reply cleaning are pure and GUI-free so they can be
// unit-tested directly; the request itself lives in appui.d next to the
// composer-suggestion request.
// ===========================================================================

import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, splitLines, strip, toLower;

/// The instruction sent alongside a short conversation excerpt.
public string followUpInstruction()
{
    return "You suggest follow-up messages for the user in a chat with a coding " ~
        "assistant. Read the excerpt in the next message and reply with a JSON " ~
        "array of exactly 2 strings. Each string is a message the user could " ~
        "send next: at most 14 words, in the user's own voice, referring to " ~
        "the work actually in progress. Use varied sentence forms: at least " ~
        "one must be an imperative instruction that starts with a verb (such " ~
        "as \"Add a keyboard shortcut\" or \"Move the setting\"); at most one " ~
        "may be a question. Do not make both questions. Make the two " ~
        "genuinely different in direction. Do not suggest verifying, testing, " ~
        "checking, confirming, or re-running the work; those are predictable " ~
        "and rarely what the user wants next. Prefer directions such as " ~
        "extending the result, exploring an alternative, improving a related " ~
        "part, or naming a design trade-off or remaining risk. Do not repeat " ~
        "the same request with different wording. No labels and no " ~
        "explanation; output only the JSON array.";
}

/// Drop leading list markers (bullets, numbers, blockquote marks) from a line.
private string stripListMarker(string value)
{
    auto text = value.strip;
    size_t digits;
    while (digits < text.length && text[digits] >= '0' && text[digits] <= '9')
        ++digits;
    if (digits > 0 && digits < text.length &&
        (text[digits] == '.' || text[digits] == ')'))
        text = text[digits + 1 .. $].strip;
    while (text.length > 0)
    {
        if (text[0] == '-' || text[0] == '*' || text[0] == '>' ||
            text[0] == '+' || text[0] == 0x2022)
        {
            text = text[1 .. $].strip;
            continue;
        }
        break;
    }
    return text;
}

/// Drop wrapping quotes/backticks so the chip shows the message itself.
private string undecorate(string value)
{
    auto text = value.strip;
    while (text.length >= 2 &&
        ((text[0] == '"' && text[$ - 1] == '"') ||
         (text[0] == '\'' && text[$ - 1] == '\'') ||
         (text[0] == '`' && text[$ - 1] == '`')))
        text = text[1 .. $ - 1].strip;
    return text;
}

/// Drop an explicit label such as "Follow-up: open the file".
private string withoutLabel(string value)
{
    const colon = value.indexOf(':');
    if (colon <= 0 || colon >= 24) return value;
    const label = value[0 .. colon].strip.toLower;
    if (label != "follow-up" && label != "follow up" && label != "followup" &&
        label != "suggestion" && label != "next" && label != "user")
        return value;
    return undecorate(value[colon + 1 .. $]);
}

/// Whether `text` starts with `phrase` ending at a word boundary.
private bool startsWithPhrase(string text, string phrase)
{
    if (text.length < phrase.length || text[0 .. phrase.length] != phrase)
        return false;
    if (text.length == phrase.length) return true;
    const next = text[phrase.length];
    return next == ' ' || next == ':' || next == ',' || next == '\n';
}

/// Whether a candidate is a direct request to verify, test, check, confirm or
/// re-run the work that just finished. The model falls back to these often;
/// they are predictable and rarely what the user wants next, so they are
/// dropped rather than offered.
private bool isDirectVerification(string value)
{
    auto text = value.strip.toLower;
    static immutable string[] prefixes = [
        "verify", "verifying", "validate", "validating", "check", "checking",
        "test", "testing", "confirm", "confirming", "ensure", "ensuring",
        "prove", "proving", "rerun", "re-run", "double-check", "double check",
        "run the tests", "run tests", "run the test", "run a test",
        "run the build", "run a build", "make sure", "see if", "try running",
    ];
    foreach (prefix; prefixes)
        if (startsWithPhrase(text, prefix)) return true;
    return false;
}

/// Whether a candidate is phrased as a question rather than an instruction.
/// The trailing question mark is the reliable signal; the wh-word/auxiliary
/// check covers a reply that forgot it. `do`/`have` are deliberately absent so
/// imperatives such as "Do a pass" or "Have a look" are not misread.
private bool isQuestionFollowUp(string value)
{
    auto text = value.strip;
    if (text.length == 0) return false;
    if (text[$ - 1] == '?') return true;
    auto lower = text.toLower;
    static immutable string[] openers = [
        "what", "why", "how", "when", "where", "which", "who", "whom",
        "whose", "can", "could", "should", "would", "will", "shall", "may",
        "might", "is", "are", "was", "were", "does", "did", "has", "had", "am",
    ];
    foreach (opener; openers)
        if (startsWithPhrase(lower, opener)) return true;
    return false;
}

/// Accept a model reply as up to `maxItems` distinct follow-up messages.
/// Handles the requested JSON array of strings (or objects with a text-like
/// field), and falls back to one item per line. Fenced code, labels, duplicate
/// wording (ignoring case), direct verification directions, a second question
/// and blank entries are dropped; an unusable reply yields an empty list so
/// nothing is shown.
public string[] cleanFollowUps(string raw, size_t maxItems = 2,
    size_t maxChars = 120)
{
    if (raw.strip.length == 0 || maxItems == 0) return null;

    string[] result;
    bool[string] seen;
    void consider(string value)
    {
        if (result.length >= maxItems) return;
        auto text = undecorate(stripListMarker(value));
        text = withoutLabel(text);
        text = undecorate(text);
        if (text.length == 0) return;
        if (isDirectVerification(text)) return;
        // The model sometimes wraps the array in prose; a line ending in a
        // colon is an introduction, not a message.
        if (text[$ - 1] == ':' && text.length < 90) return;
        if (text.length > maxChars) text = text[0 .. maxChars].strip;
        if (text.length == 0) return;
        const key = text.toLower;
        if (key in seen) return;
        // Two question-shaped chips read as an interview, not as options. Keep
        // the first question and let a later instruction fill the second slot.
        if (maxItems == 2 && result.length == 1 &&
            isQuestionFollowUp(result[0]) && isQuestionFollowUp(text))
            return;
        seen[key] = true;
        result ~= text;
    }

    const open = raw.indexOf('[');
    const close = raw.lastIndexOf(']');
    if (open >= 0 && close > open)
    {
        JSONValue value;
        try value = parseJSON(raw[open .. close + 1]);
        catch (Exception) value = JSONValue.init;
        if (value.type == JSONType.array)
        {
            foreach (item; value.array)
            {
                if (item.type == JSONType.string)
                {
                    consider(item.str);
                    continue;
                }
                if (item.type != JSONType.object) continue;
                foreach (field; ["text", "prompt", "message", "followUp",
                    "follow_up"])
                    if (auto found = field in item.object)
                        if (found.type == JSONType.string)
                        {
                            consider(found.str);
                            break;
                        }
            }
            if (result.length > 0) return result;
        }
    }

    foreach (line; splitLines(raw))
    {
        auto text = line.strip;
        if (text.length == 0) continue;
        // Check fences before decoration stripping: a bare closing fence would
        // otherwise become a stray item.
        bool fence = text[0] == '`';
        foreach (ch; text) if (ch != '`' && !(ch == ' ' || ch == '\t'))
        {
            fence = false;
            break;
        }
        if (fence || (text.length >= 3 && text[0 .. 3] == "```")) continue;
        // JSON that failed to parse is not a message the user can send.
        if (text[0] == '{' || text[0] == '[') continue;
        consider(text);
    }
    return result;
}

unittest
{
    // A mixed pair is fine, but two questions collapse to one. A later
    // imperative still fills the second slot.
    auto mixed = cleanFollowUps(
        `["How should the stop path handle retries?", "Add a keyboard shortcut"]`);
    assert(mixed.length == 2, mixed.length.to!string);
    auto questions = cleanFollowUps(
        `["How should the stop path handle retries?", "What about mobile?"]`);
    assert(questions.length == 1, questions.length.to!string);
    auto backfilled = cleanFollowUps(
        `["Why is the button hidden?", "Where should it live?", ` ~
        `"Add a tooltip"]`);
    assert(backfilled.length == 2, backfilled.length.to!string);
    assert(backfilled[0] == "Why is the button hidden?");
    assert(backfilled[1] == "Add a tooltip");

    // Direct verification directions are dropped instead of offered.
    auto filtered = cleanFollowUps(
        `["Run the tests", "Verify the build", "Check the logs", ` ~
        `"Add a regression test", "Explain the trade-off"]`);
    assert(filtered.length == 2);
    assert(filtered[0] == "Add a regression test", filtered[0]);
    assert(filtered[1] == "Explain the trade-off", filtered[1]);

    // The requested JSON array of strings is capped at two items.
    auto two = cleanFollowUps(
        `["Add a keyboard shortcut", "Try a different layout", ` ~
        `"Explain the trade-off"]`);
    assert(two.length == 2);
    assert(two[0] == "Add a keyboard shortcut");
    assert(two[1] == "Try a different layout");

    // Objects with a text-like field also parse, and duplicates are dropped.
    auto objects = cleanFollowUps(
        `[{"text":"Open the file"},{"prompt":"Add a shortcut"},` ~
        `{"text":"open the file"}]`);
    assert(objects.length == 2, objects.length.to!string);
    assert(objects[1] == "Add a shortcut");

    // A fenced or prose-wrapped array is still parsed.
    auto fenced = cleanFollowUps(
        "Here are some directions:\n```json\n" ~
        `["Fix the build", "Add a regression test", "Check the docs", ` ~
        `"Review the diff"]` ~ "\n```");
    assert(fenced.length == 2);
    assert(fenced[0] == "Fix the build");
    assert(fenced[1] == "Add a regression test");

    // A plain line list is the fallback: bullets, numbering and labels go.
    auto lines = cleanFollowUps(
        "1. Run the tests\n- Follow-up: open the composer\n" ~
        "* Explain the change\n\"Ship it\"");
    assert(lines.length == 2, lines.length.to!string);
    assert(lines[0] == "open the composer");
    assert(lines[1] == "Explain the change");

    // The list is capped, and each item is trimmed to the display budget.
    auto capped = cleanFollowUps(
        `["a","b","c","d","e"]`);
    assert(capped.length == 2);
    string padded = "y";
    foreach (i; 0 .. 300) padded ~= "y";
    auto trimmed = cleanFollowUps(`["` ~ padded ~ `"]`, 4, 80);
    assert(trimmed.length == 1 && trimmed[0].length == 80);

    // Blank or unusable replies produce nothing.
    assert(cleanFollowUps("   ").length == 0);
    assert(cleanFollowUps("```json\n{}\n```").length == 0);

    // The instruction asks for two genuinely different directions.
    const instruction = followUpInstruction();
    assert(instruction.indexOf("exactly 2") > 0);
    assert(instruction.indexOf("genuinely different") > 0);
    assert(instruction.indexOf("at least one must be an imperative") > 0);
    assert(instruction.indexOf("Do not make both questions") > 0);
    assert(instruction.indexOf("Do not suggest verifying") > 0);
    assert(instruction.indexOf("verify or finish") < 0);
    assert(instruction.indexOf("JSON") > 0);
}

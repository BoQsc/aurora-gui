module auroraopencode.followups;

// ===========================================================================
// Suggested follow-ups: 3-4 clickable next messages shown at the end of a
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
        "array of exactly 4 strings. Each string is a message the user could " ~
        "send next: at most 14 words, in the user's own voice, as a direct " ~
        "instruction or question referring to the work actually in progress. " ~
        "Make the four genuinely different in direction: for example verify or " ~
        "finish the current work, explore an alternative or an edge case, extend " ~
        "the result to a closely related improvement, and ask about a design " ~
        "trade-off or remaining risk. Do not repeat the same request with " ~
        "different wording. No labels and no explanation; output only the JSON " ~
        "array.";
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

/// Accept a model reply as up to `maxItems` distinct follow-up messages.
/// Handles the requested JSON array of strings (or objects with a text-like
/// field), and falls back to one item per line. Fenced code, labels, duplicate
/// wording (ignoring case) and blank entries are dropped; an unusable reply
/// yields an empty list so nothing is shown.
public string[] cleanFollowUps(string raw, size_t maxItems = 4,
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
        // The model sometimes wraps the array in prose; a line ending in a
        // colon is an introduction, not a message.
        if (text[$ - 1] == ':' && text.length < 90) return;
        if (text.length > maxChars) text = text[0 .. maxChars].strip;
        if (text.length == 0) return;
        const key = text.toLower;
        if (key in seen) return;
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
    // The requested JSON array of strings is used as-is.
    auto four = cleanFollowUps(
        `["Run the test suite", "Try a different layout", "Check the logs", ` ~
        `"Explain the trade-off"]`);
    assert(four.length == 4);
    assert(four[0] == "Run the test suite");
    assert(four[3] == "Explain the trade-off");

    // Objects with a text-like field also parse, and duplicates are dropped.
    auto objects = cleanFollowUps(
        `[{"text":"Open the file"},{"prompt":"Run the tests"},` ~
        `{"text":"open the file"}]`);
    assert(objects.length == 2, objects.length.to!string);
    assert(objects[1] == "Run the tests");

    // A fenced or prose-wrapped array is still parsed.
    auto fenced = cleanFollowUps(
        "Here are four directions:\n```json\n" ~
        `["Fix the build", "Add a regression test", "Check the docs", ` ~
        `"Review the diff"]` ~ "\n```");
    assert(fenced.length == 4);
    assert(fenced[0] == "Fix the build");

    // A plain line list is the fallback: bullets, numbering and labels go.
    auto lines = cleanFollowUps(
        "1. Run the tests\n- Follow-up: open the composer\n" ~
        "* Explain the change\n\"Ship it\"");
    assert(lines.length == 4, lines.length.to!string);
    assert(lines[0] == "Run the tests");
    assert(lines[1] == "open the composer");
    assert(lines[3] == "Ship it");

    // The list is capped, and each item is trimmed to the display budget.
    auto capped = cleanFollowUps(
        `["a","b","c","d","e"]`);
    assert(capped.length == 4);
    string padded = "y";
    foreach (i; 0 .. 300) padded ~= "y";
    auto trimmed = cleanFollowUps(`["` ~ padded ~ `"]`, 4, 80);
    assert(trimmed.length == 1 && trimmed[0].length == 80);

    // Blank or unusable replies produce nothing.
    assert(cleanFollowUps("   ").length == 0);
    assert(cleanFollowUps("```json\n{}\n```").length == 0);

    // The instruction asks for four genuinely different directions.
    const instruction = followUpInstruction();
    assert(instruction.indexOf("exactly 4") > 0);
    assert(instruction.indexOf("genuinely different") > 0);
    assert(instruction.indexOf("JSON") > 0);
}

module auroraopencode.composersuggestion;

// ===========================================================================
// Composer suggestion: one dimmed line inside an empty message box guessing
// what the user might send next, accepted with Tab. The instruction and the
// reply cleaning are pure and GUI-free so they can be unit-tested directly;
// the request itself lives in appui.d next to the quick-title rewrite.
// ===========================================================================

import std.string : indexOf, splitLines, strip, toLower;

/// The instruction sent alongside a short conversation excerpt.
public string composerSuggestionInstruction()
{
    return "You suggest what the user might send next in a chat with a coding " ~
        "assistant. Read the excerpt in the next message and reply with exactly " ~
        "one message the user could plausibly send next: at most 12 words, in " ~
        "the user's own voice, as a direct instruction or question, referring to " ~
        "the work actually in progress. No quotes, no label, no explanation.";
}

/// Trim list bullets, blockquote markers and wrapping quotes from one line.
private string undecorate(string value)
{
    auto text = value.strip;
    while (text.length > 0)
    {
        if (text[0] == '-' || text[0] == '*' || text[0] == '>')
        {
            text = text[1 .. $].strip;
            continue;
        }
        break;
    }
    while (text.length >= 2 &&
        ((text[0] == '"' && text[$ - 1] == '"') ||
         (text[0] == '\'' && text[$ - 1] == '\'') ||
         (text[0] == '`' && text[$ - 1] == '`')))
        text = text[1 .. $ - 1].strip;
    return text;
}

/// Drop an explicit label such as "Suggestion: open the file".
private string withoutLabel(string value)
{
    const colon = value.indexOf(':');
    if (colon <= 0 || colon >= 24) return value;
    const label = value[0 .. colon].strip.toLower;
    if (label != "suggestion" && label != "next message" && label != "user" &&
        label != "user message")
        return value;
    return undecorate(value[colon + 1 .. $]);
}

/// Accept the model's reply as one composer suggestion line. Fenced code,
/// labels and anything after the first usable line are dropped; an empty or
/// unusable reply yields "" so nothing is shown.
public string cleanComposerSuggestion(string raw, size_t maxChars = 160)
{
    if (raw.strip.length == 0) return "";
    foreach (line; splitLines(raw))
    {
        auto text = line.strip;
        if (text.length == 0) continue;
        // Check fences before decoration stripping: a bare closing fence would
        // otherwise be reduced to one stray backtick and offered as a message.
        bool fence = text[0] == '`';
        foreach (ch; text) if (ch != '`' && !(ch == ' ' || ch == '\t'))
        {
            fence = false;
            break;
        }
        if (fence) continue;
        if (text.length >= 3 && text[0 .. 3] == "```") continue;
        text = withoutLabel(undecorate(text));
        if (text.length == 0) continue;
        // The model ignored the instruction and answered with JSON.
        if (text[0] == '{' || text[0] == '[') continue;
        if (text.length > maxChars) text = text[0 .. maxChars];
        text = undecorate(text);
        if (text.length == 0) continue;
        return text;
    }
    return "";
}

unittest
{
    // A quoted single-line reply becomes the bare message.
    assert(cleanComposerSuggestion("\"Run the tests and fix the failures.\"") ==
        "Run the tests and fix the failures.");

    // An explicit label is removed and only the first usable line survives.
    assert(cleanComposerSuggestion(
        "Suggestion: Open the composer file\n\nThis would help.") ==
        "Open the composer file");

    // Bullets and backticks are presentation, not part of the message.
    assert(cleanComposerSuggestion("- `Update the changelog`") ==
        "Update the changelog");

    // Fenced/JSON replies and blank replies produce nothing.
    assert(cleanComposerSuggestion("```json\n{\"next\":\"x\"}\n```") == "");
    assert(cleanComposerSuggestion("{\"next\": \"x\"}") == "");
    assert(cleanComposerSuggestion("   ") == "");

    // The cap keeps the line short enough for one input row.
    string padded = "y";
    foreach (i; 0 .. 300) padded ~= "y";
    assert(cleanComposerSuggestion(padded).length == 160);

    // The instruction asks for one short message in the user's voice.
    const instruction = composerSuggestionInstruction();
    assert(instruction.length > 0);
    assert(instruction.indexOf("one message") > 0);
}
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

/// Whether Tab in an empty composer may ask for a suggestion. A request that is
/// already running owns the key (pressing Tab again just consumes it), while an
/// idle composer needs the feature on and some conversation to read.
public bool composerSuggestionCanRequest(bool enabled, bool generating,
    bool busy, bool hasContext)
{
    if (generating) return true;
    return enabled && !busy && hasContext;
}

/// Whether the tiny "suggest" button beside Send may be clicked right now: the
/// feature is on, the box is empty so a guess has somewhere to appear, no turn
/// is running, and no guess is already being generated. `hasContext` is the
/// cheap "some conversation can be read" test; the exact excerpt is built only
/// when the button is actually clicked.
public bool composerSuggestionTriggerReady(bool enabled, bool generating,
    bool busy, bool hasContext, bool composerEmpty)
{
    if (!composerEmpty || generating) return false;
    return composerSuggestionCanRequest(enabled, generating, busy, hasContext);
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

    // Tab may generate only in an idle composer that has something to read.
    assert(composerSuggestionCanRequest(true, false, false, true));
    assert(!composerSuggestionCanRequest(false, false, false, true));
    assert(!composerSuggestionCanRequest(true, false, false, false));
    assert(!composerSuggestionCanRequest(true, false, true, true));
    // A running request always keeps the key so Tab is not typed as whitespace.
    assert(composerSuggestionCanRequest(true, true, true, false));

    // The tiny click target asks only in an empty composer, and never while a
    // guess is already in flight (the box shows the pulse instead).
    assert(composerSuggestionTriggerReady(true, false, false, true, true));
    assert(!composerSuggestionTriggerReady(false, false, false, true, true));
    assert(!composerSuggestionTriggerReady(true, false, false, false, true));
    assert(!composerSuggestionTriggerReady(true, false, true, true, true));
    assert(!composerSuggestionTriggerReady(true, true, false, true, true));
    assert(!composerSuggestionTriggerReady(true, false, false, true, false));
}
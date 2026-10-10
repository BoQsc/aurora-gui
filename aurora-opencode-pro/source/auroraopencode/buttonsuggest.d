module auroraopencode.buttonsuggest;

// ===========================================================================
// Starter-button suggestions for the empty ("What can I help you with?") state.
//
// The text-mining here is pure and GUI-free so it can be unit-tested directly.
// The app mines folder/file paths from recent conversations and renders them as
// vertically listed options in a dialog; when a model key is configured it also
// hands the same recent-conversation digest to the agent, which refines the
// list. This module owns the mining, the prompt sent to the agent, and parsing
// of whatever it answers.
// ===========================================================================

import auroraopencode.core : ChatSession;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, split, splitLines, strip;

/// One proposed starter button: the pill label, the text a click inserts, and
/// a short line describing where it points.
public struct ButtonSuggestion
{
    string label;
    string prompt;
    string detail;
}

/// Characters that never sit inside a path but commonly surround one in prose
/// or markdown. Splitting on these keeps a path whole when it is written
/// plainly or wrapped in quotes, backticks or brackets.
private bool isPathSeparator(char ch)
{
    switch (ch)
    {
        case ' ': case '\t': case '\n': case '\r':
        case '"': case '\'': case '`':
        case '(': case ')': case '[': case ']':
        case '<': case '>': case ',':
        case '*': case '{': case '}':
            return true;
        default:
            return false;
    }
}

private string trimTrailingPunctuation(string token)
{
    while (token.length > 0)
    {
        const c = token[$ - 1];
        if (c == '.' || c == ',' || c == ';' || c == ':')
        {
            token = token[0 .. $ - 1];
            continue;
        }
        break;
    }
    return token;
}

private string stripSurroundingQuotes(string token)
{
    while (token.length >= 2 &&
        ((token[0] == '"' && token[$ - 1] == '"') ||
         (token[0] == '\'' && token[$ - 1] == '\'') ||
         (token[0] == '`' && token[$ - 1] == '`')))
        token = token[1 .. $ - 1].strip;
    return token;
}

/// Whether a token reads as a filesystem path worth offering as a button: a
/// Windows drive path, a UNC share, a home-relative `~/...` path, or a POSIX
/// absolute path with at least two segments. Bare words are rejected so the
/// list is not polluted with ordinary prose.
private bool looksLikePath(string token)
{
    if (token.length < 3) return false;
    // Windows drive: C:\... or C:/...
    if (token[1] == ':' &&
        ((token[0] >= 'A' && token[0] <= 'Z') ||
         (token[0] >= 'a' && token[0] <= 'z')) &&
        (token[2] == '\\' || token[2] == '/'))
        return true;
    // UNC share: \\server\share.
    if (token.length >= 4 && token[0] == '\\' && token[1] == '\\')
        return true;
    // Home-relative: ~/...
    if (token.length >= 3 && token[0] == '~' && token[1] == '/')
        return true;
    // POSIX absolute with a second segment.
    if (token[0] == '/' && token[1] != '/' && token[1 .. $].canFind('/'))
        return true;
    return false;
}

/// Extract every distinct path-like token from free text, in first-seen order.
public string[] extractCandidatePaths(string text)
{
    string[] found;
    bool[string] seen;
    void consider(string raw)
    {
        if (raw.length == 0) return;
        auto token = trimTrailingPunctuation(stripSurroundingQuotes(raw));
        if (!looksLikePath(token)) return;
        if (token in seen) return;
        seen[token] = true;
        found ~= token;
    }

    size_t start;
    foreach (i, ch; text)
    {
        if (!isPathSeparator(ch)) continue;
        if (i > start) consider(text[start .. i]);
        start = i + 1;
    }
    if (start < text.length) consider(text[start .. $]);
    return found;
}

/// The short pill label for a path: its final segment (folder or file name).
private string pathLabel(string path)
{
    auto value = path;
    while (value.length > 1 && (value[$ - 1] == '/' || value[$ - 1] == '\\'))
        value = value[0 .. $ - 1];
    size_t cut;
    foreach (i, ch; value)
        if (ch == '/' || ch == '\\') cut = i + 1;
    auto label = cut < value.length ? value[cut .. $] : value;
    return label.length > 0 ? label : value;
}

/// Turn a mined path into a clickable starter button: the label is the last
/// segment and a click inserts the full path (with a trailing space to keep
/// typing), so the agent starts work from exactly that location.
public ButtonSuggestion pathToSuggestion(string path)
{
    ButtonSuggestion suggestion;
    suggestion.label = pathLabel(path);
    suggestion.prompt = path ~ " ";
    suggestion.detail = path;
    return suggestion;
}

/// Mine up to `maxPaths` distinct folder/file paths across recent
/// conversations, newest first, skipping the conversation the empty state
/// already belongs to. Every non-internal message is read - user and assistant
/// prose, reasoning, assistant tool-call arguments and tool-result content and
/// arguments - so a path mentioned anywhere in a prior turn is found.
public string[] recentConversationPaths(const(ChatSession)[] sessions,
    string excludeId, size_t maxPaths)
{
    // Bounded so a very long history cannot stall the UI thread: only the most
    // recent conversations and messages are read, and only the small,
    // path-bearing fields (prose and tool arguments). Tool output and reasoning
    // can be enormous, so they are skipped entirely.
    enum maxSessions = 12;
    enum maxMessagesPerSession = 40;
    enum maxTextChars = 2000;
    string[] paths;
    bool[string] seen;
    size_t sessionsRead;
    foreach_reverse (i; 0 .. sessions.length)
    {
        const ref session = sessions[i];
        if (session.id == excludeId) continue;
        if (++sessionsRead > maxSessions) break;
        size_t messagesRead;
        foreach_reverse (j; 0 .. session.messages.length)
        {
            const ref message = session.messages[j];
            if (message.internal) continue;
            if (++messagesRead > maxMessagesPerSession) break;
            string[] texts;
            if ((message.role == "user" || message.role == "assistant") &&
                message.content.length > 0)
                texts ~= clippedText(message.content, maxTextChars);
            if (message.toolArgs.length > 0)
                texts ~= clippedText(message.toolArgs, maxTextChars);
            foreach (call; message.toolCalls)
                if (call.arguments.length > 0)
                    texts ~= clippedText(call.arguments, maxTextChars);
            foreach (text; texts)
                foreach (candidate; extractCandidatePaths(text))
                {
                    if (candidate in seen) continue;
                    seen[candidate] = true;
                    paths ~= candidate;
                    if (paths.length >= maxPaths) return paths;
                }
        }
    }
    return paths;
}

private string clippedText(string text, size_t limit)
{
    return text.length > limit ? text[0 .. limit] : text;
}

/// Turn a list of candidate paths into distinct buttons, in first-seen order,
/// capped at `maxSuggestions` and with a clearer "folder" detail for a path
/// that ends in a separator or that a project registered as a folder.
public ButtonSuggestion[] suggestionsForPaths(const(string)[] paths,
    size_t maxSuggestions)
{
    ButtonSuggestion[] result;
    bool[string] seen;
    foreach (path; paths)
    {
        if (path.length == 0) continue;
        if (path in seen) continue;
        seen[path] = true;
        result ~= pathToSuggestion(path);
        if (result.length >= maxSuggestions) break;
    }
    return result;
}

/// Convenience: mine recent conversations and map the paths to buttons.
public ButtonSuggestion[] suggestButtonsFromRecentConversations(
    const(ChatSession)[] sessions, string excludeId, size_t maxSuggestions)
{
    return suggestionsForPaths(
        recentConversationPaths(sessions, excludeId, maxSuggestions * 4),
        maxSuggestions);
}

/// A compact, role-labelled digest of recent conversations for the agent: the
/// newest messages first, with each conversation capped so the request stays
/// small. Returns empty when there is nothing to read.
public string conversationDigest(const(ChatSession)[] sessions,
    string excludeId, size_t maxChars)
{
    auto buffer = appender!string();
    foreach_reverse (i; 0 .. sessions.length)
    {
        const ref session = sessions[i];
        if (session.id == excludeId) continue;
        if (session.messages.length == 0) continue;
        if (buffer.data.length >= maxChars) break;
        buffer.put("Conversation: ");
        buffer.put(session.title.length > 0 ? session.title : session.id);
        buffer.put("\n");
        size_t lines;
        foreach_reverse (j; 0 .. session.messages.length)
        {
            const ref message = session.messages[j];
            if (message.internal) continue;
            if (message.role != "user" && message.role != "assistant") continue;
            auto text = message.content.strip;
            if (text.length == 0) continue;
            if (text.length > 400) text = text[0 .. 400];
            buffer.put(message.role);
            buffer.put(": ");
            buffer.put(text);
            buffer.put("\n");
            if (++lines >= 6) break;
        }
    }
    auto data = buffer.data;
    return data.length > maxChars ? data[0 .. maxChars] : data;
}

/// The instruction that turns the digest into a small JSON array of buttons.
public string suggestionInstruction()
{
    return "You help a desktop coding assistant propose quick-start buttons. " ~
        "Read the recent conversations in the next message and reply with a " ~
        "JSON array of at most 6 objects, each with string fields " ~
        "\"label\" (at most four words), \"prompt\" (text to prefill the " ~
        "composer), and \"detail\" (one short line). Prefer buttons that point " ~
        "at specific folders or files mentioned in the conversations: set " ~
        "\"prompt\" to that path (optionally followed by a short task) so a " ~
        "click starts work in that location, and \"label\" to the folder or " ~
        "file name. Output only the JSON array, no prose.";
}

/// Parse the agent's reply into buttons. Accepts the requested JSON array and
/// falls back to one button per line in the form "label | prompt | detail", so
/// a model that ignores the format still yields something usable.
public ButtonSuggestion[] parseSuggestionResponse(string output)
{
    const text = output.strip;
    if (text.length == 0) return null;

    // The model often wraps the array in prose or a ```json fence; parse the
    // bracketed span rather than requiring the whole reply to be JSON.
    const open = text.indexOf('[');
    const close = text.lastIndexOf(']');
    if (open >= 0 && close > open)
    {
        JSONValue value;
        try value = parseJSON(text[open .. close + 1]);
        catch (Exception) value = JSONValue.init;
        if (value.type == JSONType.array)
        {
            ButtonSuggestion[] fromJson;
            foreach (item; value.array)
            {
                if (item.type != JSONType.object) continue;
                ButtonSuggestion suggestion;
                if (auto label = "label" in item.object)
                    if (label.type == JSONType.string)
                        suggestion.label = label.str.strip;
                if (auto prompt = "prompt" in item.object)
                    if (prompt.type == JSONType.string)
                        suggestion.prompt = prompt.str;
                if (auto detail = "detail" in item.object)
                    if (detail.type == JSONType.string)
                        suggestion.detail = detail.str.strip;
                if (suggestion.prompt.length == 0) suggestion.prompt = suggestion.label;
                if (suggestion.label.length == 0 && suggestion.prompt.length == 0)
                    continue;
                fromJson ~= suggestion;
            }
            if (fromJson.length > 0) return fromJson;
        }
    }

    ButtonSuggestion[] parsed;
    foreach (line; splitLines(text))
    {
        const trimmed = line.strip;
        if (trimmed.length == 0) continue;
        const parts = split(trimmed, "|");
        ButtonSuggestion suggestion;
        suggestion.label = parts.length > 0 ? parts[0].strip : "";
        suggestion.prompt = parts.length > 1 ? parts[1].strip : suggestion.label;
        suggestion.detail = parts.length > 2 ? parts[2].strip : "";
        if (suggestion.label.length == 0 && suggestion.prompt.length == 0)
            continue;
        parsed ~= suggestion;
    }
    return parsed;
}

unittest
{
    // Windows, POSIX and home paths are recognized; bare words are not.
    auto paths = extractCandidatePaths(
        "Open C:\\Users\\me\\src\\app and /home/me/src/app, then `~/notes/todo.md`.");
    assert(paths.canFind("C:\\Users\\me\\src\\app"), "drive path not extracted");
    assert(paths.canFind("/home/me/src/app"), "POSIX path not extracted");
    assert(paths.canFind("~/notes/todo.md"), "home path not extracted");
    assert(!paths.canFind("app"), "bare word must not be a path");

    // Trailing sentence punctuation is trimmed.
    auto punctuation = extractCandidatePaths("See C:\\repo\\main.d, and stop.");
    assert(punctuation.length == 1 && punctuation[0] == "C:\\repo\\main.d",
        "trailing punctuation not trimmed");

    // A path list maps to deduplicated buttons, preserving order.
    auto options = suggestionsForPaths(
        ["C:\\work\\repo", "C:\\work\\repo", "/home/me/src/app"], 8);
    assert(options.length == 2, "suggestionsForPaths should deduplicate");
    assert(options[0].label == "repo");

    // A path becomes a button whose label is its last segment.
    auto suggestion = pathToSuggestion("C:\\work\\aurora-opencode-pro");
    assert(suggestion.label == "aurora-opencode-pro", suggestion.label);
    assert(suggestion.prompt == "C:\\work\\aurora-opencode-pro ");

    // The requested JSON reply parses; a plain line list also parses.
    auto json = parseSuggestionResponse(
        `[{"label":"repo","prompt":"C:\\repo ","detail":"open repo"}]`);
    assert(json.length == 1 && json[0].label == "repo" &&
        json[0].prompt == "C:\\repo ", json[0].label);

    // A code-fenced or prose-wrapped array is still parsed.
    auto fenced = parseSuggestionResponse(
        "Here you go:\n```json\n[{\"label\":\"docs\",\"prompt\":\"C:\\\\docs \"}]\n```");
    assert(fenced.length == 1 && fenced[0].label == "docs" &&
        fenced[0].prompt == "C:\\docs ", fenced[0].prompt);

    auto lines = parseSuggestionResponse(
        "Open the docs | C:\\docs\\index.md | read the docs");
    assert(lines.length == 1 && lines[0].label == "Open the docs" &&
        lines[0].prompt == "C:\\docs\\index.md", lines[0].label);

    assert(parseSuggestionResponse("   ").length == 0);
}

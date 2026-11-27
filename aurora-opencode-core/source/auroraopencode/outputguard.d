module auroraopencode.outputguard;

import std.string : split, strip, startsWith, indexOf;
import std.array : join, appender;
import std.algorithm : splitter;

public enum outputFailurePrefix = "Agent output stalled: ";
public enum outputRecoveryMarker = "Agent output recovery:";

// Only inspect prose. Documentation, quoted transcripts and fenced code must
// remain text, even when they contain valid-looking tool syntax.
private string prose(string text)
{
    auto result = appender!string();
    string fence;
    foreach (line; text.splitter('\n'))
    {
        const trimmed = line.strip();
        if (trimmed.startsWith("```") || trimmed.startsWith("~~~"))
        {
            const marker = trimmed[0 .. 3];
            if (fence.length == 0) fence = marker;
            else if (marker == fence) fence = "";
            continue;
        }
        if (fence.length == 0 && !trimmed.startsWith(">"))
        {
            result.put(trimmed);
            result.put('\n');
        }
    }
    return result.data;
}

/// DeepSeek can leak its DSML special tokens into reply text as a tag prefix
/// (`<` U+FF5C `DSML` U+FF5C ` invoke name=...>`). The marker hides an
/// otherwise plain text-form call, so strip it before matching the shapes
/// below. Only text right after `<` or `</` is inspected, so ordinary prose
/// keeps its characters.
private string withoutDsmlTags(string text)
{
    enum marker = "\uFF5CDSML\uFF5C";
    auto result = appender!string();
    size_t index;
    while (index < text.length)
    {
        if (text[index] != '<')
        {
            result.put(text[index]);
            ++index;
            continue;
        }
        result.put('<');
        ++index;
        if (index < text.length && text[index] == '/')
        {
            result.put('/');
            ++index;
        }
        bool marked;
        while (index + marker.length <= text.length &&
            text[index .. index + marker.length] == marker)
        {
            index += marker.length;
            marked = true;
        }
        if (marked)
            while (index < text.length &&
                (text[index] == ' ' || text[index] == '\t')) ++index;
    }
    return result.data;
}

/// Detect output failure, never infer executable calls from ordinary text.
public string agentOutputIssue(string text, const(string)[] toolNames,
    bool terminal = false, bool structuredCalls = false)
{
    // Preserve fence state across the whole answer, including later output.
    const plain = prose(withoutDsmlTags(text));
    int[string] paragraphs;
    foreach (paragraph; plain.splitter("\n\n"))
    {
        const normalized = paragraph.split().join(" ");
        if (normalized.length >= 80 && ++paragraphs[normalized] >= 4)
            return "repeated_prose";
    }
    if (toolNames.length == 0) return "";
    // Count invocation markers in one pass. Previously every available tool
    // allocated a fresh line array and rescanned the entire growing response.
    int[string] startsByName;
    foreach (line; plain.splitter('\n'))
    {
        const trimmed = line.strip();
        enum prefix = "<invoke name=\"";
        // Providers also put the calls wrapper and invocation on ONE line.
        // Only accept a protocol-shaped line, never an inline quoted example.
        string invocation = trimmed;
        if (invocation.startsWith("<calls>")) invocation = invocation[7 .. $].strip();
        while (invocation.startsWith(prefix))
        {
            const end = invocation.indexOf('"', prefix.length);
            if (end < 0) break;
            ++startsByName[invocation[prefix.length .. cast(size_t) end]];
            const next = invocation.indexOf(prefix, cast(size_t) end + 1);
            if (next < 0) break;
            invocation = invocation[cast(size_t) next .. $];
        }
    }
    // A truncated invocation is unusable too; waiting for its closing tag let
    // output-limit fragments settle as successful answers.
    const completeInvocation = terminal && !structuredCalls;
    foreach (name; toolNames)
    {
        const found = name in startsByName;
        const starts = found is null ? 0 : *found;
        if (starts >= 3) return "text_tool_calls";
        if (completeInvocation && starts > 0)
            return "text_tool_calls";
    }
    return "";
}

public string outputIssueDescription(string issue)
{
    if (issue == "text_tool_calls")
        return "the provider printed tool calls as text; those calls were not executed.";
    if (issue == "repeated_tool_call")
        return "the provider kept requesting an exhausted tool call without changed files or new instructions.";
    if (issue == "goal_audit_stalled")
        return "the provider kept answering without advancing the active goal or taking an action.";
    if (issue == "task_audit_stalled")
        return "the provider kept answering without advancing the unfinished work or taking an action.";
    if (issue == "replayed_prose" || issue == "repeated_prose")
        return "the provider repeated the same prose without taking an action.";
    return "the provider produced no usable action.";
}

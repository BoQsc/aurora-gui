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

/// Detect output failure, never infer executable calls from ordinary text.
public string agentOutputIssue(string text, const(string)[] toolNames,
    bool terminal = false, bool structuredCalls = false)
{
    // Preserve fence state across the whole answer, including later output.
    const plain = prose(text);
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
        if (!trimmed.startsWith(prefix)) continue;
        const end = trimmed.indexOf("\">", prefix.length);
        if (end >= 0) ++startsByName[trimmed[prefix.length .. cast(size_t) end]];
    }
    const completeInvocation = terminal && !structuredCalls &&
        plain.indexOf("<parameter name=") >= 0 && plain.indexOf("</invoke>") >= 0;
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
    return "the provider repeated the same prose without taking an action.";
}

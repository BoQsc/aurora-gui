module auroraopencode.answercontract;

import std.string : toLower, indexOf, strip;
import std.regex : matchFirst;
import std.json : parseJSON;
import auroraopencode.requestintent : RequestIntent, requestIntent;

bool jsonOnlyRequest(string request)
{
    const lower = request.toLower();
    const requested = cast(bool) matchFirst(lower,
        `(?:^|[.!?:;\n]\s*|\bthen\s+|\band\s+)(?:please\s+)?(?:return|respond|reply|output)\s+(?:(?:only|exactly|just|one|a|an|single|valid|in|with|as)\s+)*json\b`);
    return requested && lower.indexOf("followed by") < 0 && lower.indexOf("and explain") < 0 &&
        lower.indexOf("with an explanation") < 0 && lower.indexOf("and an explanation") < 0;
}

/// Remove presentation wrappers only when there is exactly one complete JSON
/// object/array. Never guess a value, repair invalid syntax or choose between
/// multiple candidate answers. Callers retain the original provider text.
string normalizedJsonAnswer(string request, string output)
{
    if (!jsonOnlyRequest(request)) return output;
    const trimmed = output.strip();
    try { parseJSON(trimmed); return trimmed; } catch (Exception) {}
    string candidate;
    size_t i;
    while (i < output.length)
    {
        if (output[i] != '{' && output[i] != '[') { ++i; continue; }
        const begin = i;
        char[] stack;
        bool quoted, escaped, invalid;
        for (; i < output.length; ++i)
        {
            const ch = output[i];
            if (quoted)
            {
                if (escaped) escaped = false;
                else if (ch == '\\') escaped = true;
                else if (ch == '"') quoted = false;
                continue;
            }
            if (ch == '"') { quoted = true; continue; }
            if (ch == '{' || ch == '[') stack ~= ch;
            else if (ch == '}' || ch == ']')
            {
                if (!stack.length || (ch == '}' ? stack[$-1] != '{' : stack[$-1] != '['))
                { invalid = true; break; }
                stack.length--;
                if (!stack.length) { ++i; break; }
            }
        }
        if (invalid || stack.length) return output;
        try { parseJSON(output[begin .. i]); } catch (Exception) { return output; }
        if (candidate.length) return output;
        candidate = output[begin .. i];
    }
    return candidate.length ? candidate : output;
}

/// A short, stable reminder placed after history, outside lossy checkpoints.
/// The user's request itself remains the authority; never infer a new task here.
string answerContract(string request, string verbosity)
{
    auto result = "# Current answer contract\n" ~
        "Answer the latest request in its requested scope and format. Newer user corrections override earlier assumptions. " ~
        "State the supported result briefly; don't add speculative defects, future redesigns or unrelated improvements.\n";
    if (jsonOnlyRequest(request))
        result ~= "The user requests JSON output. Return the requested JSON value alone, with no Markdown fence, preface, explanation or trailing prose.\n";
    else if (requestIntent(request) == RequestIntent.diagnosis)
        result ~= "This request asks for a cause: investigate it from evidence and resolve it when the cause is within reach. " ~
            "Do not stop at an explanation; state the cause and the fix that was applied, or name the concrete blocker.\n";
    else if (verbosity.indexOf("Target 40 words") >= 0)
        result ~= "Use at most three short bullets or sentences unless the user explicitly needs a detailed treatment. " ~
            "A request for tradeoffs does not require an exhaustive catalogue. Omit hypothetical future requirements.\n";
    return result;
}

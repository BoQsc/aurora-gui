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
string answerContract(string request, string verbosity, bool executionGrounding = true)
{
    auto result = "# Current answer contract\n" ~
        "Answer the latest request in its requested scope and format. Newer user corrections override earlier assumptions. " ~
        "State the supported result briefly; don't add speculative defects, future redesigns or unrelated improvements.\n";
    if (jsonOnlyRequest(request))
        result ~= "The user requests JSON output. Return the requested JSON value alone, with no Markdown fence, preface, explanation or trailing prose.\n";
    else if (requestIntent(request) == RequestIntent.diagnosis)
        result ~= "This request asks for a cause: investigate it from evidence and resolve it when the cause is within reach. " ~
            "Do not stop at an explanation; state the cause and the fix that was applied, or name the concrete blocker.\n";
    else if (requestIntent(request) == RequestIntent.implementation ||
        requestIntent(request) == RequestIntent.changeRequest)
        result ~= "This is authorized implementation work: carry it through to the requested result. When the deliverable is a running " ~
            "program or visible UI, launch it and exercise the user's actual path; a compile or synthetic check is not proof of " ~
            "visible behavior. Do not hand back a build for the user to run. " ~
            "Use existing acceptance checks early to guide the work. Add requested tests and focused regression coverage for gaps; " ~
            "do not duplicate an entire supplied checker merely to increase test volume. Run every required check, preserving its requirements. " ~
            "Reuse a passing result only while its relevant inputs and execution context are unchanged.\n";
    else if (verbosity.indexOf("Target 40 words") >= 0)
        result ~= "Use at most three short bullets or sentences unless the user explicitly needs a detailed treatment. " ~
            "A request for tradeoffs does not require an exhaustive catalogue. Omit hypothetical future requirements.\n";
    import auroraopencode.numericalgrounding : numericalCodeRequest, numericalGroundingInstruction;
    if (executionGrounding && numericalCodeRequest(request)) result ~= numericalGroundingInstruction ~ "\n";
    if (requestIntent(request) == RequestIntent.analysis &&
        (request.indexOf("https://") >= 0 || request.indexOf("http://") >= 0))
        result ~= "Fetch the named sources directly and cite URLs that actually supplied the evidence. " ~
            "Reuse successful retrievals while the facts and freshness requirements are unchanged; retry temporary failures. " ~
            "webfetch follows redirects automatically. A requested URL that supplied the redirected content is a valid citation. " ~
            "Inspect redirect headers or re-fetch a successful body for a concrete diagnostic, missing evidence or freshness need, not merely to reconfirm it.\n";
    return result;
}

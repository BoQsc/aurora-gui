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
        "Answer the latest user request, preserving its scope and format. Earlier assistant claims are not evidence. " ~
        "Before acting, name the user-visible outcome and the evidence that will prove it; do not " ~
        "substitute a benchmark, model comparison or tool success for the requested outcome. " ~
        "When the user says the work is off-target, that correction is authoritative: state the exact " ~
        "delta and replace the rejected plan; do not defend or repeat it. " ~
        "State the supported conclusion first; include only the reasons, checks or caveats needed to use it. " ~
        "Do not add speculative defects, future redesigns or unrelated improvements. " ~
        "For claims about existing code, distinguish the source, actual execution and the desired behavior. " ~
        "A calculator verifies only its input expression, not the program you inferred it from. " ~
        "Derive expected results from the user's original rules, not from current code or self-authored tests. " ~
        "For requirement changes, identify the exact semantic delta and preserve unaffected behavior. " ~
        "Generated assertions are hypotheses, not the specification. Independently calculate expected values with explicit input operands and original rules before deciding which side of a mismatch is wrong. " ~
        "Correct a faulty generated assertion when that derivation justifies it; preserve user-owned tests unless their change is authorized. Never change expectations merely to obtain a green check. " ~
        "Track units through rates and limits: an output-amount limit cannot be applied to input quantities before conversion. " ~
        "Check a nonzero limiting case, not only zero/default cases. " ~
        "When a numerical or branch claim determines the diagnosis, call the actual implementation with a minimal safe probe. " ~
        "If execution is unavailable or unsafe, give a clearly labelled static inference and its uncertainty. " ~
        "Use enough internal reasoning to check each claim; keep the visible answer appropriately brief.\n";
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

module auroraopencode.answercontract;

import std.string : toLower, indexOf;
import std.regex : matchFirst;

/// A short, stable reminder placed after history, outside lossy checkpoints.
/// The user's request itself remains the authority; never infer a new task here.
string answerContract(string request, string verbosity)
{
    auto result = "# Current answer contract\n" ~
        "Answer the latest user request, preserving its scope and format. Earlier assistant claims are not evidence. " ~
        "State the supported conclusion first; include only the reasons, checks or caveats needed to use it. " ~
        "Do not add speculative defects, future redesigns or unrelated improvements. " ~
        "For claims about existing code, distinguish the source, actual execution and the desired behavior. " ~
        "A calculator verifies only its input expression, not the program you inferred it from. " ~
        "When a numerical or branch claim determines the diagnosis, call the actual implementation with a minimal safe probe. " ~
        "If execution is unavailable or unsafe, give a clearly labelled static inference and its uncertainty. " ~
        "Use enough internal reasoning to check each claim; keep the visible answer appropriately brief.\n";
    const lower = request.toLower();
    const jsonOutput = cast(bool) matchFirst(lower,
        `(?:^|[.!?\n]\s*|\bthen\s+|\band\s+)(?:please\s+)?(?:return|respond|reply|output)\s+(?:(?:only|exactly|just|one|a|an|single|valid|in|with|as)\s+)*json\b`);
    const mixedOutput = lower.indexOf("followed by") >= 0 || lower.indexOf("and explain") >= 0 ||
        lower.indexOf("with an explanation") >= 0 || lower.indexOf("and an explanation") >= 0;
    if (jsonOutput && !mixedOutput)
        result ~= "The user requests JSON output. Return the requested JSON value alone, with no Markdown fence, preface, explanation or trailing prose.\n";
    else if (verbosity.indexOf("Target 40 words") >= 0)
        result ~= "Use at most three short bullets or sentences unless the user explicitly needs a detailed treatment. " ~
            "A request for tradeoffs does not require an exhaustive catalogue. Omit hypothetical future requirements.\n";
    return result;
}

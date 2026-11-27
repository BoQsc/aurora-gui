module auroraopencode.agentloop;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.outputguard : outputRecoveryMarker;
import auroraopencode.outputrecovery : outputRecoveryCount;
import auroraopencode.taskcontext : taskExcerpt;
import auroraopencode.contextpolicy : latestActualUserRequest;
import std.conv : to;
import std.string : startsWith, toLower, indexOf, replace;

/// Only an actual provider rejection can tighten a request budget. This is
/// distinct from the user's selected context target and never deletes history.
int providerContextLimit(string failure)
{
    import std.regex : matchFirst;
    const match = matchFirst(failure.toLower(),
        `(?:available context size\s*\(|maximum context length(?: is| of|:)?\s*|context (?:window|limit)(?: is| of|:)?\s*)([0-9][0-9,]*)`);
    if (!match.length) return 0;
    try return to!int(match[1].replace(",", ""));
    catch (Exception) return 0;
}

int rejectedContextBudget(string failure, int current)
{
    const lower = failure.toLower();
    const available = providerContextLimit(failure);
    if (!available && lower.indexOf("context_length_exceeded") < 0 &&
        lower.indexOf("prompt is too long") < 0 && lower.indexOf("too many tokens") < 0 &&
        lower.indexOf("context window exceeded") < 0) return 0;
    int bound = current;
    if (available > 0 && (bound <= 0 || available < bound)) bound = available;
    if (bound <= 0) return 0;
    const reduced = cast(int)(cast(long) bound * 3 / 4);
    return reduced < 1024 && bound >= 1024 ? 1024 : reduced > 0 ? reduced : bound;
}

/// Both execution owners apply this value decision. Retries are scheduled,
/// cancellable operations, never recursive calls or a terminal attempt budget.
struct AgentRecovery
{
    string guidance;
    int delayMs;
    int attempt;
}

AgentRecovery recoverAgent(const ref ChatSession session, string cause, int attempts = -1)
{
    AgentRecovery result;
    const count = attempts < 0 ? outputRecoveryCount(session) : attempts;
    result.attempt = count == int.max ? int.max : count + 1;
    // Quick repairs first, then a bounded cadence during a persistent outage.
    // Productive work never waits, and no number of failed repairs ends work.
    result.delayMs = count < 2 ? 0 : count < 7 ? 500 << (count - 2) : 30_000;
    result.guidance = outputRecoveryMarker ~ " attempt=" ~ to!string(result.attempt) ~
        " cause=" ~ cause ~ "\n" ~
        "Resume the authorized task from saved successful results. The previous response did not advance it. " ~
        "Use only the supplied structured tool channel; printed XML/DSML is text and executes nothing. " ~
        "Do not repeat the last answer, request permission for routine choices, or ask the user to retry. ";
    switch (count % 4)
    {
        case 0:
            result.guidance ~= "Take one concrete action on the next open outcome. Repair the actual tool name and JSON arguments using its supplied schema. ";
            break;
        case 1:
            result.guidance ~= "Change approach: inspect the specific failed dependency or result with a different available tool, then act on that observation. ";
            break;
        case 2:
            result.guidance ~= "Reduce the next step to one small, verifiable action. Do independent work while unavailable dependencies recover. ";
            break;
        default:
            result.guidance ~= "Reconcile current external state before retrying a mutation whose outcome is unknown. Reuse successful actions and checks; do not replay their side effects. ";
            break;
    }
    result.guidance ~= "If the outcome is already achieved, report it using the existing evidence" ~
        (session.goalStatus == "active" ? " and call goal_complete" : "") ~
        ". Planning records the work; updating a checklist is not a prerequisite to taking action.\n" ~
        "Current request: " ~ taskExcerpt(latestActualUserRequest(session), 1200);
    return result;
}

/// Detect repeated *observations*, not just repeated prose. Polling an existing
/// process is legitimate; repeating a read/search without new facts needs a
/// changed approach, not suppression of the requested tool.
string stagnantToolGuidance(const ref ChatSession session)
{
    string[string] observations;
    int[string] repeats;
    int inspected;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.internal && message.content.startsWith(outputRecoveryMarker))) break;
        if (message.role != "tool") continue;
        if (++inspected > 48) break;
        if (message.workspaceChanged || (!message.failed && message.verificationCheck.length)) break;
        if (message.toolName != "read" && message.toolName != "grep" &&
            message.toolName != "glob" && message.toolName != "list" &&
            message.toolName != "read_plan" && message.toolName != "update_plan" &&
            message.toolName != "update_subplan") continue;
        const key = message.toolName ~ "\n" ~ message.toolArgs;
        auto prior = key in observations;
        if (prior is null) { observations[key] = message.content; repeats[key] = 1; }
        else if (*prior == message.content && ++repeats[key] >= 3)
            return recoverAgent(session, "unchanged_tool_results").guidance;
    }
    return "";
}

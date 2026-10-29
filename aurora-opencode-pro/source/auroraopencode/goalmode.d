module auroraopencode.goalmode;

import auroraopencode.core : ChatSession, GoalHistoryEntry, activeMessagePath;
import std.array : appender, join, split;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, startsWith, strip, toLower;
import std.utf : toUTF32, toUTF8;

/// Claude Code caps a goal condition at 4,000 characters. Keep the same bound
/// so a goal stays a one-line completion condition instead of becoming a
/// second transcript.
public enum size_t maxGoalLength = 4000;

/// A safety bound for autonomous continuations. The normal stop condition is
/// the model's evidence-backed `goal_complete` call or the user pressing Stop.
public enum int maxGoalTurns = 64;

/// Detect a goal turn that cannot progress without the user. Repeating the
/// same request for human action used to start another automatic goal turn
/// until the safety limit; this lets the UI pause immediately instead.
public bool goalNeedsHumanInput(const ref ChatSession session)
{
    if (session.goal.length == 0 || session.goalStatus != "active")
        return false;
    string last;
    string previous;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal) break;
        if (message.role != "assistant" || message.internal || message.failed ||
            message.toolCalls.length > 0) continue;
        if (!last.length) last = message.content;
        else if (!previous.length) previous = message.content;
    }
    if (!last.length) return false;
    const text = last.toLower().split().join(" ");
    foreach (phrase; humanHelpPhrases)
        if (text.indexOf(phrase) >= 0) return true;
    // A repeated appeal is also a stop signal even if its wording is not in
    // the phrase table. Neutral repeated progress prose does not qualify.
    if (!previous.length) return false;
    return text == previous.toLower().split().join(" ") &&
        (text.indexOf("you") >= 0 || text.indexOf("need") >= 0);
}

private static immutable string[] humanHelpPhrases = [
    "i need you to", "i need your", "you need to provide",
    "you need to send", "you need to share", "you need to run",
    "you need to install", "you need to open", "you need to approve",
    "you need to confirm", "you need to sign in", "you need to log in",
    "you will need to", "you'll need to", "you must ",
    "waiting for you", "waiting for your", "requires your",
    "requires human", "human intervention", "manual intervention",
    "manual step", "please provide", "please send", "please share",
    "please confirm", "please approve", "please grant",
    "let me know once", "let me know when", "once you have",
    "once you provide", "after you ", "until you ",
    "i can't proceed until", "i cannot proceed until",
    "i can't continue until", "i cannot continue until",
    "blocked until you"
];

/// Bound the goal by characters without splitting a UTF-8 sequence.
public string clampGoalText(string text)
{
    const units = toUTF32(text);
    return units.length <= maxGoalLength ? text : toUTF8(units[0 .. maxGoalLength]);
}

/// Record the current goal text whenever it is created or changed. Re-setting
/// the same live goal only refreshes its outcome; a previously completed or
/// cleared goal with the same text is a new history entry.
public void recordGoalSet(ref ChatSession session, long at)
{
    if (!session.goal.length) return;
    auto history = session.goalHistory;
    if (history.length)
    {
        auto last = history[$ - 1];
        if (last.text == session.goal &&
            (last.outcome == "active" || last.outcome == "paused" ||
             last.outcome.length == 0))
        {
            last.outcome = session.goalStatus.length
                ? session.goalStatus : "active";
            last.closedAt = 0;
            history[$ - 1] = last;
            session.goalHistory = history;
            return;
        }
        if (last.outcome == "active" || last.outcome == "paused" ||
            last.outcome.length == 0)
        {
            last.outcome = "replaced";
            last.closedAt = at;
            history[$ - 1] = last;
        }
    }
    history ~= GoalHistoryEntry(session.goal, session.goalStatus.length
        ? session.goalStatus : "active", at, 0);
    session.goalHistory = history;
}

/// Update the outcome of the latest goal record, seeding it when restoring a
/// conversation saved before goal history existed.
public void recordGoalOutcome(ref ChatSession session, string outcome, long at)
{
    if (!session.goal.length) return;
    auto history = session.goalHistory;
    if (!history.length || history[$ - 1].text != session.goal)
    {
        recordGoalSet(session, session.goalStartedAt > 0
            ? session.goalStartedAt : at);
        history = session.goalHistory;
    }
    if (!history.length) return;
    auto last = history[$ - 1];
    last.outcome = outcome;
    const terminal = outcome == "completed" || outcome == "cleared" ||
        outcome == "replaced";
    if (terminal)
    {
        if (last.closedAt == 0) last.closedAt = at;
    }
    else
        last.closedAt = 0;
    history[$ - 1] = last;
    session.goalHistory = history;
}

/// Backfill history for a goal restored from an older build.
public void syncGoalHistory(ref ChatSession session, long at)
{
    if (!session.goal.length) return;
    if (!session.goalHistory.length ||
        session.goalHistory[$ - 1].text != session.goal)
    {
        recordGoalSet(session, session.goalStartedAt > 0
            ? session.goalStartedAt : at);
        return;
    }
    recordGoalOutcome(session, session.goalStatus.length
        ? session.goalStatus : "active", at);
}

public enum GoalCommandKind
{
    none,
    show,
    set,
    pause,
    resume,
    clear,
}

public struct GoalCommand
{
    GoalCommandKind kind;
    string text;
}

/// Parse `/goal` and its Codex-compatible control variants. A command must be
/// the whole composer text; ordinary prose that merely mentions a goal remains
/// a normal message.
public GoalCommand parseGoalCommand(string input)
{
    const text = input.strip();
    if (!(text == "/goal" || text.startsWith("/goal "))) return GoalCommand.init;
    const argument = text.length > 5 ? text[5 .. $].strip() : "";
    if (argument.length == 0) return GoalCommand(GoalCommandKind.show);
    switch (argument.toLower())
    {
        case "status":
            return GoalCommand(GoalCommandKind.show);
        case "pause":
        case "stop":
        case "off":
            return GoalCommand(GoalCommandKind.pause);
        case "resume":
        case "start":
        case "unpause":
            return GoalCommand(GoalCommandKind.resume);
        case "clear":
        case "cancel":
        case "none":
        case "reset":
            return GoalCommand(GoalCommandKind.clear);
        default:
            return GoalCommand(GoalCommandKind.set, argument);
    }
}

public bool goalActive(const ref ChatSession session)
{
    return session.goal.length > 0 && session.goalStatus == "active";
}

/// The goal block is dynamic request context, deliberately outside the cached
/// system prompt. Paused and completed goals stay visible to the model for
/// continuity but never drive an automatic turn.
public string goalPromptBlock(const ref ChatSession session)
{
    if (session.goal.length == 0) return "";
    const status = session.goalStatus.length ? session.goalStatus : "active";
    auto output = appender!string();
    output.put("\n\n# Persistent goal\n");
    output.put("Status: " ~ status ~ "\n");
    output.put("Goal: " ~ session.goal ~ "\n");
    switch (status)
    {
        case "active":
            output.put("Keep working toward this goal across turns. After each turn " ~
                "audit the actual result and continue with useful tool work until the " ~
                "completion condition is demonstrably true. Do not ask permission for " ~
                "routine execution or verification. When every outcome is complete and " ~
                "checks pass, call `goal_complete` with a short summary and concrete " ~
                "evidence (successful tool-call IDs or check receipts). Never call it " ~
                "for prose, an attempted action, or unfinished work.\n");
            break;
        case "paused":
            output.put("The user paused this goal. Preserve its state and do not start " ~
                "another turn for it until the user resumes it.\n");
            break;
        case "completed":
            output.put("This goal was completed. Do not resume it unless the user edits " ~
                "or starts it again.\n");
            break;
        default:
            output.put("This goal is not active. Do not continue it automatically.\n");
            break;
    }
    return output.data;
}

/// Text appended as a hidden user turn when an active goal needs another turn.
public string goalContinuationInstruction(const ref ChatSession session)
{
    return "Persistent goal continuation: " ~ session.goal ~ "\n" ~
        "Continue from the recorded work and current evidence. Do work rather than " ~
        "restating the goal. If the goal is now demonstrably complete, call " ~
        "`goal_complete` with a concise summary and concrete evidence; otherwise keep " ~
        "advancing the unfinished outcomes. The user can pause this goal at any time.";
}

/// Validate a model's `goal_complete` request. Completion is refused while the
/// user's goal is paused/completed, while verification is outstanding, or while
/// the durable checklist still has unfinished outcomes.
public string goalCompletionError(const ref ChatSession session, string arguments)
{
    if (session.goal.length == 0) return "There is no persistent goal to complete.";
    if (session.goalStatus != "active")
        return "The persistent goal is " ~
            (session.goalStatus.length ? session.goalStatus : "not active") ~
            "; it cannot be completed from this turn.";
    JSONValue value;
    try value = parseJSON(arguments);
    catch (Exception) return "goal_complete requires valid JSON. Continue the goal with tools.";
    if (value.type != JSONType.object) return "goal_complete requires a JSON object.";
    string field(string key)
    {
        if (auto found = key in value.object)
            if (found.type == JSONType.string) return found.str.strip();
        return "";
    }
    if (!field("summary").length)
        return "goal_complete requires a concise summary of the verified result.";
    auto evidence = "evidence" in value.object;
    if (evidence is null || evidence.type != JSONType.array || !evidence.array.length)
        return "goal_complete requires concrete evidence: successful tool-call IDs or check receipts.";
    size_t usable;
    foreach (entry; evidence.array)
        if (entry.type == JSONType.string && entry.str.strip().length) ++usable;
    if (!usable) return "goal_complete evidence must contain non-empty tool-call IDs or check receipts.";
    if (session.verificationStatus == "required" || session.verificationStatus == "failed")
        return "Verification is still outstanding. Run the required check, then call goal_complete.";
    foreach (step; session.taskSteps)
        if (step.status != "completed")
            return "The checklist still has unfinished outcomes. Finish them or update the plan, then call goal_complete.";
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed")
                return "A nested plan still has unfinished steps. Finish them before completing the goal.";
    foreach (item; session.contract.workItems)
        if (item.required && item.step.status != "completed")
            return "Required work remains open. Finish it before completing the goal.";
    return "";
}
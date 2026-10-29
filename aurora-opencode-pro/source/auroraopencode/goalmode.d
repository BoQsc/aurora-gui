module auroraopencode.goalmode;

import auroraopencode.core : ChatSession;
import std.array : appender;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : startsWith, strip, toLower;
import std.utf : toUTF32, toUTF8;

/// Claude Code caps a goal condition at 4,000 characters. Keep the same bound
/// so a goal stays a one-line completion condition instead of becoming a
/// second transcript.
public enum size_t maxGoalLength = 4000;

/// A safety bound for autonomous continuations. The normal stop condition is
/// the model's evidence-backed `goal_complete` call or the user pressing Stop.
public enum int maxGoalTurns = 64;

/// Bound the goal by characters without splitting a UTF-8 sequence.
public string clampGoalText(string text)
{
    const units = toUTF32(text);
    return units.length <= maxGoalLength ? text : toUTF8(units[0 .. maxGoalLength]);
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
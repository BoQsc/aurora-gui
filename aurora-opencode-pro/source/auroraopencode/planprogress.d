module auroraopencode.planprogress;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.turnpolicy : hasIncompleteTaskSteps;
import auroraopencode.worktracking : workTracksPhase;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf;

enum planProgressMarker = "Plan progress checkpoint: ";
enum planProgressWindow = 10;

struct PlanProgress
{
    int results, inspections, phase, nudgedAt, nudgedPhase;
    bool recorded, nudged;
}

/// Derive upkeep from the selected durable branch, including prior reminders.
/// Reopening a chat or replaying its actor cannot reset the reminder budget.
PlanProgress planProgress(const ref ChatSession session)
{
    PlanProgress result;
    foreach (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal)
        { result = PlanProgress.init; continue; }
        if (message.role == "user" && message.internal && message.content.startsWith(planProgressMarker))
        {
            const text = message.content[planProgressMarker.length .. $];
            const end = text.indexOf('\n');
            try
            {
                const note = parseJSON(end < 0 ? text : text[0 .. end]);
                if (note.type == JSONType.object && "results" in note.object && "phase" in note.object &&
                    note["results"].type == JSONType.integer && note["phase"].type == JSONType.integer)
                {
                    result.nudged = true;
                    result.nudgedAt = cast(int) note["results"].integer;
                    result.nudgedPhase = cast(int) note["phase"].integer;
                }
            }
            catch (Exception) {}
        }
        if (message.role != "tool") continue;
        if (!message.failed && message.toolName == "update_plan")
        {
            result = PlanProgress.init;
            result.recorded = true;
            continue;
        }
        // Child-plan and control activity must not keep an obsolete parent
        // checklist looking fresh. Failed calls are not a phase transition.
        if (message.toolName == "update_subplan" || message.toolName == "read_plan" ||
            message.toolName == "process" || message.toolName == "tool_status") continue;
        ++result.results;
        if (message.failed) continue;
        if (message.toolName == "read" || message.toolName == "grep" || message.toolName == "glob")
            ++result.inspections;
        if (message.toolName == "verify" || message.verificationCheck.length) result.phase = 2;
        else if (result.phase < 1 && (message.toolName == "edit" || message.toolName == "write" ||
            message.toolName == "apply_patch" || message.toolName == "remove" ||
            message.toolName == "move" || message.toolName == "rename")) result.phase = 1;
    }
    if (session.taskStatus == "verifying") result.phase = 2;
    return result;
}

bool planPositionMissing(const ref ChatSession session, int phase)
{
    if (workTracksPhase(session, phase)) return false;
    foreach (step; session.taskSteps)
        if (step.status == "in_progress")
        {
            // "other" is an unclassified outcome, not evidence that work is
            // still research. E.g. "Assemble the handoff" legitimately edits.
            // Its normal upkeep window still applies.
            if (!step.kind.length || step.kind == "other") return false;
            return (phase >= 1 && step.kind != "edit" && step.kind != "verify") ||
                (phase >= 2 && step.kind != "verify");
        }
    return true;
}

bool planNeedsRefresh(const ref ChatSession session)
{
    if (!session.taskSteps.length || !hasIncompleteTaskSteps(session) ||
        session.taskStatus == "waiting_input") return false;
    const progress = planProgress(session);
    return progress.results >= planProgressWindow || planPositionMissing(session, progress.phase);
}

/// Advisory only: never cancel useful tools, manufacture completion, or add a
/// provider request. The owner appends this only after every result is paired.
string planProgressGuidance(const ref ChatSession session)
{
    if (session.taskStatus == "waiting_input") return "";
    const progress = planProgress(session);
    const unfinished = hasIncompleteTaskSteps(session);
    const stale = session.taskSteps.length && unfinished &&
        (progress.results >= planProgressWindow || planPositionMissing(session, progress.phase));
    const missing = !session.taskSteps.length && !progress.recorded &&
        (progress.inspections >= 3 || progress.results >= planProgressWindow);
    if (!stale && !missing) return "";
    const phaseChanged = stale && planPositionMissing(session, progress.phase) &&
        progress.phase > progress.nudgedPhase;
    if (progress.nudged && !phaseChanged && progress.results - progress.nudgedAt < planProgressWindow)
        return "";
    JSONValue checkpoint;
    checkpoint["results"] = progress.results;
    checkpoint["phase"] = progress.phase;
    return planProgressMarker ~ checkpoint.toString() ~ "\n" ~
        (phaseChanged
            ? "Work has moved into editing or verification. "
            : missing ? "This investigation has grown beyond a quick lookup. " : "Plan upkeep: " ~ to!string(progress.results) ~ " tool results since the last parent-plan update. ") ~
        "Reconcile update_plan in your next tool batch: mark only proven outcomes completed, name the current " ~
        "unfinished outcome, and explain changed requirements or approach. Preserve unfinished outcomes and original acceptance. " ~
        "Combine the update with independent useful tools when appropriate. Planning does not block tools or require permission. " ~
        "Do not repeat successful work to obtain new receipts or invent extra steps.";
}

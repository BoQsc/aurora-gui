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
            const phase = result.phase;
            result = PlanProgress.init;
            result.phase = phase;
            result.nudgedPhase = phase;
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
        else if (message.toolName == "edit" || message.toolName == "write" ||
            message.toolName == "apply_patch" || message.toolName == "remove" ||
            message.toolName == "move" || message.toolName == "rename") result.phase = 1;
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

private bool planTracksPhase(const ref ChatSession session, int phase)
{
    if (workTracksPhase(session, phase)) return true;
    foreach (step; session.taskSteps) if (step.status == "in_progress")
        return phase == 2 ? step.kind == "verify" :
            phase == 1 && (step.kind == "edit" || step.kind == "verify");
    return false;
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
        (progress.results >= planProgressWindow || planPositionMissing(session, progress.phase) ||
            (progress.phase > 0 && progress.phase != progress.nudgedPhase && !planTracksPhase(session, progress.phase)));
    const missing = !session.taskSteps.length && !progress.recorded &&
        (progress.inspections >= 3 || progress.results >= planProgressWindow);
    if (!stale && !missing) return "";
    // Even an unclassified outcome needs reconciliation when actual work
    // changes phase; do not assert that its label is wrong.
    const phaseChanged = stale && progress.phase > 0 && progress.phase != progress.nudgedPhase && !planTracksPhase(session, progress.phase);
    if (progress.nudged && !phaseChanged)
        return "";
    JSONValue checkpoint;
    checkpoint["results"] = progress.results;
    checkpoint["phase"] = progress.phase;
    if (phaseChanged)
        return planProgressMarker ~ checkpoint.toString() ~ "\n" ~
            "Work now includes editing or verification. Use update_plan in your next tool batch to reconcile completed " ~
            "and active outcomes with the actual work. Retain genuinely unfinished outcomes; do not fabricate completion. " ~
            "Deliver the current request: hypothetical follow-on work does not require new contracts, inventories or integration frameworks.";
    return planProgressMarker ~ checkpoint.toString() ~ "\n" ~
        (missing ? "This investigation has grown beyond a quick lookup. " : "Plan upkeep: " ~ to!string(progress.results) ~ " tool results since the last parent-plan update. ") ~
        "If the work has moved on, use update_plan to update completed and active outcomes together. If the current outcome is still " ~
        "underway, continue it without inventing new steps or repeating checks. Keep the plan brief and scoped.";

}

/// One focused reconciliation after a phase reminder was ignored. Deriving the
/// attempt from durable assistant turns bounds it across reloads, without
/// rejecting tool batches or requiring a plan for ordinary small requests.
bool planReconciliationDue(const ref ChatSession session)
{
    if (!hasIncompleteTaskSteps(session) || session.taskStatus == "waiting_input") return false;
    bool armed;
    int replies;
    foreach (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && message.toolName == "update_plan" && !message.failed))
        { armed = false; replies = 0; }
        if (message.internal && message.content.startsWith(planProgressMarker))
        {
            const text = message.content[planProgressMarker.length .. $];
            const end = text.indexOf('\n');
            try
            {
                const note = parseJSON(end < 0 ? text : text[0 .. end]);
                armed = note["phase"].integer > 0 && message.content.indexOf("Work now includes") >= 0;
                replies = 0;
            }
            catch (Exception) { armed = false; }
        }
        else if (armed && message.role == "assistant") ++replies;
    }
    return armed && replies == 1;
}

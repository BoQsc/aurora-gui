module auroraopencode.planprogress;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.turnpolicy : hasIncompleteTaskSteps;
import auroraopencode.worktracking : workTracksPhase;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf;

enum planProgressMarker = "Plan review reminder: ";
enum initialPlanSuggestion = "For multi-step work, prefer a short, provisional plan in the first response. " ~
    "Keep it brief and adapt it when progress or new discoveries change the work. Simple tasks do not need a plan.";
enum planProgressWindow = 5;
// An unplanned run is worth a suggestion as soon as it stops looking like a
// quick lookup, not only after a full upkeep window. Repeated suggestions use
// the normal window so an ignored first reminder cannot become chatter.
enum planCreationWindow = 3;

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
            message.toolName == "process" || message.toolName == "tool_status" ||
            message.toolName == "request_input" || message.toolName == "task_blocker" ||
            message.toolName == "goal_complete" || message.toolName == "retire_images" ||
            message.toolName == "assign" || message.toolName == "finish") continue;
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

bool planNeedsRefresh(const ref ChatSession session)
{
    if (!session.taskSteps.length || !hasIncompleteTaskSteps(session) ||
        session.taskStatus == "waiting_input") return false;
    const progress = planProgress(session);
    // The visible checklist is stale as soon as work moves past the phase its
    // in-progress outcome describes, not only when a tool-result window ends.
    return progress.results >= planProgressWindow ||
        (progress.phase > 0 && planPositionMissing(session, progress.phase));
}

/// Advisory only: never cancel useful tools, manufacture completion, or add a
/// provider request. The owner appends this only after every result is paired.
string planProgressGuidance(const ref ChatSession session)
{
    import auroraopencode.contextpolicy : latestActualUserRequest;
    import auroraopencode.requestintent : answerOnlyRequest;
    import auroraopencode.taskflow : taskInvestigation;
    if (session.taskStatus == "waiting_input" || session.taskStatus == "completed" ||
        taskInvestigation(session) || answerOnlyRequest(latestActualUserRequest(session)) ||
        (session.verificationStatus == "passed" && !hasIncompleteTaskSteps(session))) return "";
    const progress = planProgress(session);
    const hasPlan = session.taskSteps.length > 0;
    import auroraopencode.requestintent : requestIntent, RequestIntent;
    const intent = requestIntent(latestActualUserRequest(session));
    if (!hasPlan && (intent == RequestIntent.analysis || intent == RequestIntent.clarification ||
        intent == RequestIntent.conversation)) return "";
    // A first suggestion for unplanned work arrives early; later suggestions
    // keep the normal cadence.
    const window = !progress.nudged && !hasPlan ? planCreationWindow : planProgressWindow;
    // A phase transition is the moment an existing plan most needs an update:
    // editing or verification started while the in-progress outcome still
    // describes the previous phase. Recheck the plan now instead of waiting for
    // the next tool-result window.
    const phaseShift = hasPlan && hasIncompleteTaskSteps(session) &&
        progress.phase > progress.nudgedPhase && planPositionMissing(session, progress.phase);
    if (!phaseShift && progress.results - progress.nudgedAt < window) return "";
    JSONValue checkpoint;
    checkpoint["results"] = progress.results;
    checkpoint["phase"] = progress.phase;
    const opening = !hasPlan
        ? "This work has several steps now; consider recording a short plan. "
        : phaseShift
        ? (progress.phase >= 2
            ? "Verification has started while the in-progress outcome still describes earlier work. "
            : "Editing has started while the in-progress outcome still describes investigation. ")
        : "Check whether the plan still matches the work and new discoveries. ";
    return planProgressMarker ~ checkpoint.toString() ~ "\n" ~
        opening ~
        "If useful, use update_plan to reflect completed work, the current step and changed direction, and explain any unfinished outcome you drop. " ~
        "If the plan still fits, continue working. This reminder does not require a plan update or extra checks.";
}

/// Kept for older integrations; advisory reviews never escalate into a gate.
bool planReconciliationDue(const ref ChatSession session) { return false; }

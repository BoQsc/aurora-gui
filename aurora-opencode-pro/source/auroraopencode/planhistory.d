module auroraopencode.planhistory;

// Append-only history of conversation plans. The live plan lives in
// `ChatSession.taskSteps` / `nestedPlans`; this module keeps immutable
// snapshots of earlier revisions so the plan metadata is still available after
// the task has moved on, a goal replaced the plan, or a branch switch restored
// an older one.
//
// The history is persisted with the session (see core.writeTaskContract) and
// is deliberately bounded: one task can rewrite its plan dozens of times, and
// an unbounded list would grow every conversation snapshot without limit.

import auroraopencode.core : ChatSession, NestedPlan, PlanHistoryEntry,
    TaskStep;
import std.datetime : Clock;
import std.json : JSONType, JSONValue;
import std.string : strip;

/// Newest revisions kept per conversation. Older snapshots are dropped first,
/// so the most recent evolution is always available.
public enum size_t maxPlanHistoryEntries = 200;

private bool sameSteps(const(TaskStep)[] a, const(TaskStep)[] b)
{
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i].text != b[i].text || a[i].status != b[i].status ||
            a[i].id != b[i].id || a[i].kind != b[i].kind ||
            a[i].done != b[i].done || a[i].blocker != b[i].blocker ||
            a[i].evidence != b[i].evidence)
            return false;
    return true;
}

private bool sameNestedPlans(const(NestedPlan)[] a, const(NestedPlan)[] b)
{
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i].parentStep != b[i].parentStep ||
            !sameSteps(a[i].steps, b[i].steps))
            return false;
    return true;
}

/// The model's stated reason for a plan change, when it supplied one.
private string explanationFrom(JSONValue root)
{
    if (root.type != JSONType.object) return "";
    foreach (key; ["explanation", "reason"])
        if (auto field = key in root.object)
            if (field.type == JSONType.string)
            {
                const text = field.str.strip();
                if (text.length) return text;
            }
    return "";
}

/// Record the current plan as a new revision. A call that would repeat the
/// previous snapshot is ignored, so unchanged status polls do not grow the
/// history.
public void recordPlanHistory(ref ChatSession session, string source,
    JSONValue root = JSONValue.init)
{
    recordPlanHistory(session, source, explanationFrom(root),
        Clock.currTime.toUnixTime());
}

/// A caller-supplied explanation, with the revision time taken now. Used where
/// the app, not the model, knows why the plan changed (a replaced goal).
public void recordPlanHistory(ref ChatSession session, string source,
    string explanation)
{
    recordPlanHistory(session, source, explanation,
        Clock.currTime.toUnixTime());
}

/// Same as above with the revision time supplied by the caller.
public void recordPlanHistory(ref ChatSession session, string source,
    JSONValue root, long at)
{
    recordPlanHistory(session, source, explanationFrom(root), at);
}

public void recordPlanHistory(ref ChatSession session, string source,
    string explanation, long at)
{
    if (!session.taskSteps.length && !session.nestedPlans.length &&
        !session.objective.length)
        return;
    if (session.planHistory.length)
    {
        const last = session.planHistory[$ - 1];
        if (last.objective == session.objective &&
            last.status == session.taskStatus &&
            sameSteps(last.steps, session.taskSteps) &&
            sameNestedPlans(last.nestedPlans, session.nestedPlans))
            return;
    }

    PlanHistoryEntry entry;
    entry.at = at;
    entry.source = source;
    entry.explanation = explanation;
    entry.objective = session.objective;
    entry.status = session.taskStatus;
    entry.steps = session.taskSteps.dup;
    entry.nestedPlans = session.nestedPlans.dup;
    foreach (i, plan; session.nestedPlans)
        entry.nestedPlans[i].steps = plan.steps.dup;
    session.planHistory ~= entry;
    if (session.planHistory.length > maxPlanHistoryEntries)
        session.planHistory =
            session.planHistory[$ - maxPlanHistoryEntries .. $].dup;
}

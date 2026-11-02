module auroraopencode.taskmutation;

import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.worktracking;
import auroraopencode.planhistory : recordPlanHistory;
import std.json : JSONValue, JSONType, parseJSON;
import std.algorithm : canFind;
import std.string : strip, startsWith;
import std.conv : to;

void applyTaskPlan(ref ChatSession session, string arguments)
{
    JSONValue root;
    try root = parseJSON(arguments);
    catch (Exception) return;
    if (root.type != JSONType.object) return;
    auto plan = "plan" in root.object;
    if (plan !is null && plan.type != JSONType.array) return;
    // The model rewrites the durable objective here so the plan card shows
    // the task's actual goal instead of a copy of the user's message, which
    // is also the chat title. An omitted field keeps the current objective.
    if (auto field = "objective" in root.object)
        if (!taskInvestigation(session) && field.type == JSONType.string)
        {
            const value = field.str.strip();
            if (value.length > 0) session.objective = value;
        }
    const replacement = "replace_entire_plan" in root.object && root["replace_entire_plan"].type == JSONType.true_;
    auto steps = plan !is null ? normalizedPlan(session, *plan, session.taskSteps, !replacement, incrementalPlan(root)) : session.taskSteps.dup;
    foreach (key; ["constraints", "decisions"])
        if (auto field = key in root.object)
            if (field.type == JSONType.array)
            {
                string[] values;
                foreach (item; field.array) if (item.type == JSONType.string) values ~= item.str;
                if (key == "constraints") session.contract.constraints = values;
                else
                {
                    foreach (decision; session.contract.decisions)
                        if (decision.startsWith("Plan change: ") && !values.canFind(decision)) values ~= decision;
                    session.contract.decisions = values;
                }
            }
    session.nestedPlans = replacement ? null : retainNestedWork(session.taskSteps, steps, session.nestedPlans);
    rememberPlanRevision(session, root, session.taskSteps, steps);
    session.contract.workItems = normalizedWorkItems(session, root, steps);
    session.contract.work = workContextForPlan(session, steps, root);
    session.taskSteps = steps;
    initializeLegacyTask(session);
    bool complete = steps.length > 0;
    foreach (step; steps)
        if (step.status != "completed") complete = false;
    if (complete && !requiredWorkRemaining(session))
        session.taskStatus = (session.verificationStatus == "required" || session.verificationStatus == "failed")
            ? "verifying" : "completed";
    else if (session.taskStatus != "reviewing")
        session.taskStatus = "active";
    recordPlanHistory(session, "update_plan", root);
}

string nestedPlanError(const ref ChatSession session,
    string arguments, bool enabled)
{
    if (!enabled)
        return "Error: experimental nested plans are disabled in Settings.";
    JSONValue root;
    try root = parseJSON(arguments);
    catch (Exception) return "Error: invalid subplan arguments.";
    if (root.type != JSONType.object)
        return "Error: invalid subplan arguments.";
    auto parent = "parent_step" in root.object;
    if (parent is null || parent.type != JSONType.integer ||
        parent.integer < 1 || parent.integer > session.taskSteps.length)
        return "Error: parent_step must name an existing top-level " ~
            "plan step (1 through " ~
            to!string(session.taskSteps.length) ~ ").";
    const(TaskStep)[] previous;
    foreach (nested; session.nestedPlans)
        if (nested.parentStep == parent.integer) previous = nested.steps;
    return planUpdateError(session, arguments, previous);
}

void applyTaskSubplan(ref ChatSession session, string arguments)
{
    auto root = parseJSON(arguments);
    const parent = cast(size_t) root["parent_step"].integer;
    TaskStep[] previous;
    foreach (nested; session.nestedPlans) if (nested.parentStep == parent) previous = nested.steps;
    const replacement = "replace_entire_plan" in root.object && root["replace_entire_plan"].type == JSONType.true_;
    auto steps = normalizedPlan(session, root["plan"], previous, !replacement, incrementalPlan(root));
    foreach (ref nested; session.nestedPlans)
        if (nested.parentStep == parent)
        {
            rememberPlanRevision(session, root, nested.steps, steps);
            nested.steps = steps;
            recordPlanHistory(session, "subplan", root);
            return;
        }
    NestedPlan nested;
    nested.parentStep = parent;
    nested.steps = steps;
    session.nestedPlans ~= nested;
    recordPlanHistory(session, "subplan", root);
}



/// A short plan for one phase must not silently erase a large unfinished
/// parent plan. Explicit user-directed replacement remains available.
string planReplacementError(const ref ChatSession session,
    string arguments)
{
    const error = planUpdateError(session, arguments, session.taskSteps);
    if (error.length) return error;
    const root = parseJSON(arguments);
    const replacement = "replace_entire_plan" in root.object && root["replace_entire_plan"].type == JSONType.true_;
    const(TaskStep)[] steps = "plan" in root.object ? normalizedPlan(session, root["plan"], session.taskSteps, !replacement, incrementalPlan(root)) : session.taskSteps;
    foreach (nested; session.nestedPlans)
        if (nested.parentStep <= session.taskSteps.length)
            foreach (step; steps)
                if ((step.id == session.taskSteps[nested.parentStep - 1].id ||
                    step.text == session.taskSteps[nested.parentStep - 1].text) && step.status == "completed")
                    foreach (child; nested.steps)
                        if (child.status != "completed") return "Error: finish the outstanding substeps before completing their parent.";
    return "";
}


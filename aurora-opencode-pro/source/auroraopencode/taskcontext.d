module auroraopencode.taskcontext;

import auroraopencode.core;
import auroraopencode.taskflow : workContextForPlan, taskEvidenceIndex, taskMessagePath;
import std.algorithm : min, max;
import std.array : appender;
import std.conv : to;
import std.string : startsWith;

string taskExcerpt(string value, size_t bytes)
{
    if (value.length <= bytes) return value;
    if (bytes < 4) return "";
    size_t cut = bytes - 3;
    while (cut && (cast(ubyte)value[cut] & 0xC0) == 0x80) --cut;
    return value[0 .. cut] ~ "...";
}

/// A bounded projection, never a mutation of the durable task or its history.
string taskContext(const ref ChatSession session, string request, bool nested, size_t budget = 12_000)
{
    auto output = appender!string();
    void line(string label, string value, size_t limit)
    {
        if (!value.length || output.data.length + label.length + 5 >= budget) return;
        const available = budget - output.data.length - label.length - 1;
        output.put(label ~ taskExcerpt(value, min(limit, available)) ~ "\n");
    }
    line("Task: ", session.contract.id ~ " · intent: " ~ session.contract.intent ~ " · current request: " ~ session.contract.currentIntent, 256);
    const goalLimit = min(cast(size_t) 1200, budget / 8);
    line("Objective: ", session.objective, goalLimit);
    if (session.contract.requestedOutcome != session.objective) line("Requested outcome: ", session.contract.requestedOutcome, goalLimit);
    if (request != session.objective) line("Current request: ", request, goalLimit);
    const work = workContextForPlan(session, session.taskSteps);
    line("Current step: ", work.stepId, 128);
    line("Current action ID: ", work.workItemId, 128);
    line("Working on: ", work.action, 400);
    line("Next action: ", work.nextAction, 320);
    line("Detour: ", work.detourReason, 320);
    line("Done when: ", work.doneWhen, 320);
    line("Return to: ", work.returnTo, 320);
    line("Status: ", session.taskStatus, 64);
    line("Turn: ", session.turnStatus, 64);
    line("Verification: ", session.verificationStatus, 64);
    const constraintLimit = max(cast(size_t) 64, min(cast(size_t) 800, budget / 4 / max(cast(size_t) 1, session.contract.constraints.length)));
    foreach (constraint; session.contract.constraints) line("Constraint: ", constraint, constraintLimit);
    size_t unfinished;
    foreach (step; session.taskSteps) if (step.status != "completed") ++unfinished;
    const perStep = max(cast(size_t) 64, min(cast(size_t) 900,
        (budget > output.data.length ? budget - output.data.length : 0) * 2 / 3 / max(cast(size_t) 1, unfinished)));
    line("", "Checklist (original row numbers; completed outcomes retained automatically):", 128);
    foreach (i, step; session.taskSteps)
        if (step.status != "completed")
            line(to!string(i + 1) ~ ". [" ~ step.status ~ "] " ~ step.id ~ ": ",
                taskExcerpt(step.text, perStep / 2) ~ "; done: " ~ taskExcerpt(step.done, perStep / 2), perStep);
    string completed;
    foreach (step; session.taskSteps)
        if (step.status == "completed") completed ~= (completed.length ? ", " : "") ~ step.id;
    line("Completed outcomes retained: ", completed, 1200);
    if (nested)
        foreach (plan; session.nestedPlans)
            foreach (step; plan.steps)
                if (step.status != "completed")
                    line("Substep " ~ to!string(plan.parentStep) ~ " [" ~ step.status ~ "] " ~ step.id ~ ": ",
                        step.text ~ "; done: " ~ step.done, 320);
    const evidence = taskEvidenceIndex(session);
    size_t receipts;
    foreach_reverse (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        if (auto proof = message.id in evidence)
            if ((*proof).startsWith("verify-current|") && receipts++ < 6)
                line("Accepted check: ", (message.toolCallId.length ? message.toolCallId : message.id) ~ " = " ~ message.verificationCheck, 200);
    }
    if (session.contract.workItems.length)
    {
        size_t closedWork, openWork, followups;
        const workBudget = min(cast(size_t) 3000, budget / 4);
        const workStart = output.data.length;
        foreach (status; ["in_progress", "pending"])
            foreach (item; session.contract.workItems)
                if (item.required && item.step.status == status && output.data.length - workStart < workBudget)
                    line("Required action " ~ item.step.id ~ " [" ~ item.step.status ~ "] under " ~
                        (item.parentId.length ? item.parentId : "objective") ~ ": ",
                        item.step.text ~ "; done: " ~ item.step.done ~ "; " ~ item.origin ~ ": " ~ item.reason, 360);
        foreach (item; session.contract.workItems)
        {
            if (item.step.status == "completed") ++closedWork;
            else if (item.required) ++openWork;
            else ++followups;
        }
        line("Work summary: ", to!string(openWork) ~ " required unfinished; " ~ to!string(closedWork) ~
            " completed; " ~ to!string(followups) ~ " optional follow-ups. read_plan provides full details.", 160);
        size_t shown;
        foreach_reverse (item; session.contract.workItems)
            if (!item.required && item.step.status != "completed" && shown++ < 3)
                line("Optional follow-up " ~ item.step.id ~ ": ", item.step.text ~ "; why outside scope: " ~ item.reason, 240);
    }
    // Established decisions precede the recent audit trail; full text remains saved.
    foreach_reverse (decision; session.contract.decisions)
        if (!decision.startsWith("Plan change: ")) line("Decision: ", decision, 320);
    size_t changes;
    foreach_reverse (decision; session.contract.decisions)
        if (decision.startsWith("Plan change: ") && changes++ < 4) line("Decision: ", decision, 240);
    line("Blocker: ", session.contract.blocker, 320);
    line("", "Full task records and earlier plan-change reasons remain saved; this is the bounded working context.", 128);
    return output.data;
}

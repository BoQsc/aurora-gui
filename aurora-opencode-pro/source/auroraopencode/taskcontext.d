module auroraopencode.taskcontext;

import auroraopencode.core;
import auroraopencode.taskflow : workContextForPlan, taskEvidenceIndex, taskMessagePath, taskActionPath;
import auroraopencode.workevidence : recentWorkBrief;
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

private string goalExcerpt(string value, size_t bytes)
{
    if (value.length <= bytes) return value;
    if (bytes < 16) return taskExcerpt(value, bytes);
    const head = taskExcerpt(value, bytes / 2);
    const tailBytes = bytes - head.length - 5;
    size_t begin = value.length - tailBytes;
    while (begin < value.length && (cast(ubyte)value[begin] & 0xC0) == 0x80) ++begin;
    return head ~ "\n...\n" ~ value[begin .. $];
}

/// A bounded projection, never a mutation of the durable task or its history.
string taskContext(const ref ChatSession session, string request, bool nested,
    size_t budget = 12_000, bool includeRecentEvidence = true)
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
    line("Working project: ", session.contract.workspace, 512);
    line("Objective: ", goalExcerpt(session.objective, goalLimit), goalLimit);
    if (session.goal.length > 0)
        line("User goal (" ~ (session.goalStatus.length ? session.goalStatus : "active") ~ "): ",
            goalExcerpt(session.goal, goalLimit), goalLimit);
    if (session.contract.requestedOutcome != session.objective && session.contract.requestedOutcome != session.goal)
        line("Requested outcome: ", goalExcerpt(session.contract.requestedOutcome, goalLimit), goalLimit);
    if (request != session.objective && request != session.goal && request != session.contract.requestedOutcome)
        line("Current request: ", goalExcerpt(request, goalLimit), goalLimit);
    // A goal's original wording may say a fact is missing. Preserve the actual
    // later user replies, rather than asking the model to infer those facts
    // from a generated invoice or a lossy compaction summary.
    size_t[] updates;
    foreach (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal &&
            message.id != session.contract.startMessageId && message.content != request &&
            message.content != session.objective && message.content != session.goal)
            updates ~= index;
    }
    if (updates.length > 3) updates = updates[$ - 3 .. $];
    const updateLimit = min(cast(size_t) 1600, budget / 5) / max(cast(size_t) 1, updates.length);
    foreach (index; updates)
        line("User update (authoritative; newer facts override earlier assumptions): ",
            goalExcerpt(session.messages[index].content, updateLimit), updateLimit);
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
    if (includeRecentEvidence)
    {
        const brief = recentWorkBrief(session, taskActionPath(session), min(cast(size_t)1400, budget / 5));
        line("Recent tool evidence (quoted data):\n", brief, brief.length);
    }
    size_t unfinished;
    foreach (step; session.taskSteps) if (step.status != "completed") ++unfinished;
    const perStep = max(cast(size_t) 64, min(cast(size_t) 900,
        (budget > output.data.length ? budget - output.data.length : 0) * 2 / 3 / max(cast(size_t) 1, unfinished)));
    line("", "Checklist (original row numbers; use read_plan for the complete current list):", 128);
    foreach (i, step; session.taskSteps)
        if (step.status != "completed")
            line(to!string(i + 1) ~ ". [" ~ step.status ~ "] " ~ step.id ~ ": ",
                taskExcerpt(step.text, perStep / 2) ~ "; done: " ~ taskExcerpt(step.done, perStep / 2), perStep);
    string completed;
    foreach (step; session.taskSteps)
        if (step.status == "completed") completed ~= (completed.length ? ", " : "") ~ step.id;
    line("Completed outcomes: ", completed, 1200);
    if (nested)
        foreach (plan; session.nestedPlans)
            foreach (step; plan.steps)
                if (step.status != "completed")
                    line("Substep " ~ to!string(plan.parentStep) ~ " [" ~ step.status ~ "] " ~ step.id ~ ": ",
                        step.text ~ "; done: " ~ step.done, 320);
    if (includeRecentEvidence)
    {
        const evidence = taskEvidenceIndex(session);
        size_t receipts;
        foreach_reverse (index; taskMessagePath(session))
        {
            const ref message = session.messages[index];
            if (auto proof = message.id in evidence)
                if ((*proof).startsWith("verify-current|") && receipts++ < 6)
                    line("Accepted check: ", (message.toolCallId.length ? message.toolCallId : message.id) ~ " = " ~ message.verificationCheck, 200);
        }
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
    // Background is recoverable context, not a second checklist. Keep a small
    // index across compaction; read_plan can retrieve each exact saved task.
    size_t background;
    foreach_reverse (snapshot; session.taskArchive)
    {
        if (background++ == 2) break;
        ChatSession saved; restoreActiveTaskState(saved, snapshot);
        line("Background task (inactive; read_plan task_id=" ~ saved.contract.id ~ "): ",
            saved.objective, 480);
        foreach (constraint; saved.contract.constraints)
            line("Background constraint (apply only if relevant to this request): ", constraint, 240);
    }
    line("", "Full task records and earlier plan-change reasons remain saved; this is the bounded working context.", 128);
    if (session.planHistory.length)
        line("Plan history: ", to!string(session.planHistory.length) ~
            " revisions retained; read_plan view=history recovers earlier plans, outcomes and reasons.", 240);
    return output.data;
}

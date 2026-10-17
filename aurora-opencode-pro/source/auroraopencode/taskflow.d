module auroraopencode.taskflow;

import auroraopencode.core;
import auroraopencode.requestintent;
import auroraopencode.planmode : experimentalStrictPlanEnabled;
import auroraopencode.verification : verificationCheck;
import std.algorithm : canFind;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip, startsWith, toLower;
import std.regex : matchFirst;

string latestTaskRequest(const ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
        if (session.messages[index].role == "user" && !session.messages[index].internal)
            return session.messages[index].content;
    return "";
}

size_t[] taskMessagePath(const ref ChatSession session)
{
    auto path = activeMessagePath(session);
    if (session.contract.startMessageId.length)
        foreach (i, index; path)
            if (session.messages[index].id == session.contract.startMessageId) return path[i .. $];
    // Legacy conversations have no scope anchor. Never include unrelated old
    // requests when deriving new requirements.
    foreach_reverse (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal) return path[i .. $];
    return path;
}

void acceptTaskRequest(ref ChatSession session, string text, string messageId)
{
    const intent = requestIntent(text);
    const name = requestIntentName(intent);
    if (intent == RequestIntent.conversation)
    {
        if (session.taskStatus == "waiting_input")
        {
            session.taskStatus = "active";
            session.contract.blocker = "";
        }
        session.contract.currentIntent = session.contract.intent.length ? session.contract.intent : name;
        return;
    }
    if (intent == RequestIntent.clarification)
    {
        session.contract.currentIntent = name;
        return;
    }
    if (intent == RequestIntent.continuation && session.taskStatus == "completed")
        foreach_reverse (snapshot; session.taskArchive)
            try
            {
                auto state = parseJSON(snapshot);
                if (state["taskStatus"].str == "completed") continue;
                const previousCurrent = activeTaskStateJson(session);
                session.objective = state["objective"].str;
                session.taskStatus = state["taskStatus"].str;
                session.verificationStatus = state["verificationStatus"].str;
                auto archive = session.taskArchive;
                archive ~= previousCurrent;
                readTaskContract(session, state);
                session.taskArchive = archive;
                break;
            }
            catch (Exception) {}
    if (intent == RequestIntent.continuation &&
        (session.taskStatus == "completed" || !session.objective.length))
    {
        session.contract.currentIntent = "conversation";
        return;
    }
    const fresh = session.objective.length == 0 || session.taskStatus == "completed" || explicitlyNewTask(text);
    if (fresh)
    {
        if (session.objective.length)
        {
            session.taskArchive ~= activeTaskStateJson(session);
        }
        session.objective = text;
        session.contract = TaskContract();
        session.taskSteps = null; session.nestedPlans = null;
        session.verificationStatus = "not_required";
    }
    if (!session.contract.id.length)
    {
        string anchor = messageId;
        RequestIntent originalIntent = intent;
        if (!fresh)
        {
            originalIntent = requestIntent(session.objective);
            foreach_reverse (index; activeMessagePath(session))
            {
                const ref message = session.messages[index];
                if (message.id != messageId && message.role == "user" && !message.internal &&
                    requestIntent(message.content) == originalIntent)
                { anchor = message.id; break; }
            }
        }
        session.contract.id = anchor;
        session.contract.startMessageId = anchor;
        session.contract.requestedOutcome = session.objective;
        session.contract.intent = originalIntent == RequestIntent.continuation ? "implementation" : requestIntentName(originalIntent);
    }
    if (intent == RequestIntent.implementation && session.contract.intent == "analysis")
        session.contract.intent = "implementation";
    session.contract.currentIntent = name;
    session.contract.blocker = "";
    session.taskStatus = "active";
}

bool taskInvestigation(const ref ChatSession session)
{
    return session.contract.currentIntent == "analysis" && session.contract.intent != "analysis";
}

void remapTaskContract(ref ChatSession session, string[string] ids)
{
    if (auto mapped = session.contract.startMessageId in ids) session.contract.startMessageId = *mapped;
    if (auto mapped = session.contract.id in ids) session.contract.id = *mapped;
    foreach (ref step; session.taskSteps)
        foreach (ref evidence; step.evidence) if (auto mapped = evidence in ids) evidence = *mapped;
    foreach (ref plan; session.nestedPlans)
        foreach (ref step; plan.steps)
            foreach (ref evidence; step.evidence) if (auto mapped = evidence in ids) evidence = *mapped;
    foreach (ref snapshot; session.taskArchive)
        try
        {
            auto state = parseJSON(snapshot);
            ChatSession archived; readTaskContract(archived, state);
            remapTaskContract(archived, ids);
            writeTaskContract(state, archived);
            state.object.remove("taskArchive");
            snapshot = state.toString();
        }
        catch (Exception) {}
    foreach (ref message; session.messages)
        if (message.taskStateJson.length)
        {
            ChatSession state;
            restoreActiveTaskState(state, message.taskStateJson);
            remapTaskContract(state, ids);
            auto root = parseJSON(message.taskStateJson);
            writeTaskContract(root, state);
            root.object.remove("taskArchive");
            message.taskStateJson = root.toString();
        }
}

enum executionDiagnosisMarker = "Execution diagnosis checkpoint: ";

/// Count an unchanged evidence window while tools keep running. Distinct
/// successful findings/effects reset it; plan edits and query variations do not.
int stalledExecutionTools(const ref ChatSession session)
{
    bool[string] seen;
    int stalled;
    auto path = taskMessagePath(session);
    size_t begin;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal) begin = i + 1;
    foreach (index; path[begin .. $])
    {
        const message = session.messages[index];
        if (message.role != "tool" || ["update_plan", "update_subplan", "process", "tool_status",
                "task_blocker", "request_input", "retire_images"].canFind(message.toolName)) continue;
        const text = message.content.strip().toLower();
        const noFinding = !text.length || text.startsWith("no matches") || text.startsWith("no results") ||
            text.startsWith("no files") || text.startsWith("0 matches");
        const detail = message.toolName == "run" ? message.toolArgs : message.content ~ message.toolDiff;
        const key = sha256Of(message.toolName ~ "\n" ~ detail).toHexString().idup;
        if (!message.failed && !noFinding && evidenceKind(message).length && !(key in seen))
        { seen[key] = true; stalled = 0; }
        else ++stalled;
    }
    return stalled;
}

/// Recovery recurs every evidence window, without a terminal tool-count limit.
bool executionRecoveryDue(const ref ChatSession session)
{
    if (stalledExecutionTools(session) < 16) return false;
    int tools;
    foreach_reverse (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.internal && message.content.startsWith(executionDiagnosisMarker))) break;
        if (message.role == "tool") ++tools;
    }
    return tools >= 16;
}

void restoreBranchTask(ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
        if (session.messages[index].taskStateJson.length && !session.messages[index].authorId.length)
        {
            restoreActiveTaskState(session, session.messages[index].taskStateJson);
            return;
        }
    if (!session.contract.id.length) return; // Legacy state has no branch receipts.
    auto archive = session.taskArchive;
    session.contract = TaskContract(); session.taskSteps = null; session.nestedPlans = null;
    session.objective = ""; session.taskStatus = "idle"; session.verificationStatus = "not_required";
    foreach_reverse (index; activeMessagePath(session))
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        {
            acceptTaskRequest(session, session.messages[index].content, session.messages[index].id);
            break;
        }
    session.taskArchive = archive;
}

string evidenceKind(const ref ChatMessage message)
{
    if (message.internal && message.taskStateJson.length)
        try
        {
            const state = parseJSON(message.taskStateJson);
            if (auto proof = "taskActionEvidence" in state.object)
                if (proof.type == JSONType.true_ && state["taskStatus"].str == "completed")
                    return state["taskContract"]["intent"].str == "analysis" ? "research" : "action";
        }
        catch (Exception) {}
    if (message.role != "tool" || message.failed) return "";
    if (["read", "grep", "glob", "checksum", "view_image", "webfetch", "websearch"].canFind(message.toolName)) return "research";
    if (message.toolName == "dshell") return message.toolArgs.canFind("\"list\"") || message.toolArgs.canFind("\"info\"") ? "research" : "";
    if (["write", "edit", "apply_patch", "copy", "move", "rename", "remove", "download", "create_folder"].canFind(message.toolName)) return "edit";
    if (message.toolName == "verify") return "verify";
    if (message.toolName == "run")
    {
        try
        {
            const value = parseJSON(message.toolArgs);
            string[] args;
            if (auto f = "args" in value.object)
                if (f.type == JSONType.array)
                    foreach (arg; f.array) if (arg.type == JSONType.string) args ~= arg.str;
            if (auto f = "program" in value.object)
                if (f.type == JSONType.string && verificationCheck(f.str, args).length) return "verify";
        }
        catch (Exception) {}
        return "action";
    }
    if (["open", "sync", "rebuild", "computer"].canFind(message.toolName)) return "action";
    return "";
}

bool evidenceMatches(const ref ChatSession session, const ref TaskStep step, string id)
{
    auto index = taskEvidenceIndex(session);
    auto proof = id in index;
    return proof !is null && compatibleEvidence(step, *proof, session.verificationStatus == "passed");
}

string[string] taskEvidenceIndex(const ref ChatSession session)
{
    string[string] result;
    foreach (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        const kind = evidenceKind(message);
        if (!kind.length) continue;
        const proof = kind == "verify" ? kind ~ "|" ~ message.verificationCheck : kind;
        result[message.id] = proof;
        if (message.toolCallId.length) result[message.toolCallId] = proof;
    }
    return result;
}

bool compatibleEvidence(string kind, string proof, bool verified)
{
    if (!proof.length) return false;
    if (kind == "verify") return proof.startsWith("verify|") && verified;
    if (kind == "edit") return proof == "edit" || proof == "action";
    if (kind == "research") return proof == "research" || proof.startsWith("verify|");
    return true;
}

bool compatibleEvidence(const ref TaskStep step, string proof, bool verified)
{
    if (!compatibleEvidence(step.kind, proof, verified)) return false;
    if (step.kind == "verify" && matchFirst(step.done.toLower(), `\b(tests?|assertions?|pytest|unittest)\b`))
        return proof.canFind("tests") || proof.canFind("pytest") || proof.canFind("unittest") ||
            proof.canFind(" test");
    return true;
}

bool supportedStep(const ref ChatSession session, const ref TaskStep step, const ref string[string] index)
{
    if (step.status != "completed") return false;
    foreach (id; step.evidence)
        if (auto proof = id in index)
            if (compatibleEvidence(step, *proof, session.verificationStatus == "passed")) return true;
    return false;
}

bool supportedStep(const ref ChatSession session, const ref TaskStep step)
{
    auto index = taskEvidenceIndex(session);
    return supportedStep(session, step, index);
}

bool taskHasActionEvidence(const ref ChatSession session, bool includeResearch = false)
{
    const current = latestTaskRequest(session);
    const intent = requestIntent(current);
    const changedArtifact = artifactChangeRequested(current) ||
        ((!current.length || intent == RequestIntent.continuation || intent == RequestIntent.conversation) &&
            artifactChangeRequested(session.contract.requestedOutcome));
    auto path = taskMessagePath(session);
    size_t begin;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal) begin = i + 1;
    foreach (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        const kind = evidenceKind(message);
        if (kind == "edit" || (message.workspaceChanged && !message.failed)) return true;
        if (!changedArtifact && ["action", "verify"].canFind(kind)) return true;
        if (includeResearch && kind == "research") return true;
    }
    return false;
}

bool taskRequiresPlan(const ref ChatSession session)
{
    // Work size may suggest a plan, but only the explicitly enabled strict
    // mode can require one. Completed work must not trigger planning rounds.
    if (!experimentalStrictPlanEnabled()) return false;
    bool[string] changedPaths;
    int actions;
    foreach (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        const kind = evidenceKind(message);
        if (kind != "edit" && kind != "action") continue;
        ++actions;
        if (kind == "edit")
            try
            {
                auto args = parseJSON(message.toolArgs);
                if (auto path = "filePath" in args.object)
                    if (path.type == JSONType.string) changedPaths[path.str] = true;
            }
            catch (Exception) {}
    }
    return changedPaths.length > 1 || actions >= 6;
}

TaskStep[] normalizedPlan(const ref ChatSession session, JSONValue value, const(TaskStep)[] previous,
    bool retainCompleted = true)
{
    auto steps = taskStepsFromJson(value);
    if (retainCompleted)
        foreach_reverse (oldIndex, old; previous)
            if (old.status == "completed")
            {
                bool found;
                foreach (step; steps)
                    if ((old.id.length && step.id == old.id) || step.text == old.text) found = true;
                if (found) continue;
                size_t insertAt = steps.length;
                bool anchored;
                foreach (later; previous[oldIndex + 1 .. $])
                {
                    foreach (i, step; steps)
                        if ((later.id.length && step.id == later.id) || step.text == later.text)
                        { insertAt = i; anchored = true; break; }
                    if (anchored) break;
                }
                auto retained = TaskStep(old.text, old.status, old.id, old.kind, old.done, old.evidence.dup, old.blocker);
                steps = steps[0 .. insertAt] ~ retained ~ steps[insertAt .. $];
            }
    auto index = taskEvidenceIndex(session);
    auto path = taskMessagePath(session);
    foreach (ref step; steps)
    {
        foreach (old; previous)
            if ((step.id.length && old.id == step.id) || (!step.id.length && old.text == step.text))
            {
                if (!step.id.length) step.id = old.id;
                if (!step.kind.length) step.kind = old.kind;
                if (!step.done.length) step.done = old.done;
                if (!step.evidence.length) step.evidence = old.evidence.dup;
                break;
            }
        if (!step.id.length) step.id = "step-" ~ sha256Of(session.contract.id ~ "\n" ~ step.text).toHexString()[0 .. 16].idup;
        if (!step.kind.length)
        {
            const text = step.text.toLower();
            if (text.startsWith("verify") || text.startsWith("test") || text.startsWith("check")) step.kind = "verify";
            else if (requestIntent(step.text) == RequestIntent.implementation) step.kind = "edit";
            else if (requestIntent(step.text) == RequestIntent.analysis) step.kind = "research";
            else step.kind = "other";
        }
        if (!step.done.length) step.done = step.text;
        if (step.status == "completed" && !step.evidence.length)
            foreach_reverse (slot; path)
            {
                const ref message = session.messages[slot];
                const id = message.toolCallId.length ? message.toolCallId : message.id;
                if (auto proof = id in index)
                    if (compatibleEvidence(step, *proof, session.verificationStatus == "passed"))
                    { step.evidence = [id]; break; }
            }
    }
    return steps;
}

TaskWorkContext workContextForPlan(const ref ChatSession session, const(TaskStep)[] steps, JSONValue root = JSONValue.init)
{
    TaskWorkContext result;
    size_t current = steps.length;
    foreach (i, step; steps) if (step.status == "in_progress") { current = i; break; }
    if (current == steps.length)
        foreach (i, step; steps) if (step.status != "completed") { current = i; break; }
    if (current == steps.length) return result;
    if (session.contract.work.stepId == steps[current].id) result = session.contract.work;
    result.stepId = steps[current].id;
    if (!result.action.length) result.action = steps[current].text;
    size_t next = steps.length;
    foreach (i, step; steps[current + 1 .. $])
        if (step.status != "completed") { next = current + 1 + i; break; }
    if (next == steps.length)
        foreach (i, step; steps[0 .. current])
            if (step.status != "completed") { next = i; break; }
    const nextId = next < steps.length ? steps[next].id : "";
    if (result.nextStepId != nextId || !result.nextAction.length)
        result.nextAction = next < steps.length ? steps[next].text : "";
    result.nextStepId = nextId;
    if (root.type != JSONType.object) return result;
    if (auto context = "work_context" in root.object)
    {
        if (context.type == JSONType.null_)
        { ChatSession empty; return workContextForPlan(empty, steps); }
        if (context.type != JSONType.object) return result;
        const originalAction = result.action;
        foreach (i, key; ["action", "next_action", "detour_reason", "done_when", "return_to"])
            if (auto field = key in context.object)
                if (field.type == JSONType.string)
                {
                    const text = field.str.strip();
                    switch (i)
                    {
                        case 0: result.action = text; break;
                        case 1: result.nextAction = text; break;
                        case 2:
                            if (result.detourReason != text) { result.doneWhen = ""; result.returnTo = ""; }
                            result.detourReason = text; break;
                        case 3: result.doneWhen = text; break;
                        case 4: result.returnTo = text; break;
                        default: break;
                    }
                }
        if (result.detourReason.length && !result.returnTo.length) result.returnTo = originalAction;
        if (!result.detourReason.length) { result.doneWhen = ""; result.returnTo = ""; }
        if (!result.action.length) result.action = steps[current].text;
    }
    return result;
}

NestedPlan[] retainNestedWork(const(TaskStep)[] previous, const(TaskStep)[] steps, const(NestedPlan)[] plans)
{
    NestedPlan[] result;
    foreach (plan; plans)
        if (plan.parentStep >= 1 && plan.parentStep <= previous.length)
        {
            const parent = previous[plan.parentStep - 1];
            foreach (i, step; steps)
                if ((parent.id.length && step.id == parent.id) || (!parent.id.length && step.text == parent.text))
                {
                    TaskStep[] children;
                    foreach (child; plan.steps)
                        children ~= TaskStep(child.text, child.status, child.id, child.kind, child.done, child.evidence.dup, child.blocker);
                    result ~= NestedPlan(i + 1, children, plan.expanded);
                    break;
                }
        }
    return result;
}

string planUpdateError(const ref ChatSession session, string arguments, const(TaskStep)[] previous)
{
    JSONValue root;
    try root = parseJSON(arguments);
    catch (Exception) return "Error: invalid plan JSON.";
    if (root.type != JSONType.object || !("plan" in root.object)) return "Error: plan is required.";
    auto evidenceIndex = taskEvidenceIndex(session);
    bool replacement;
    if (auto f = "replace_entire_plan" in root.object) replacement = f.type == JSONType.true_;
    if (replacement)
    {
        const request = latestTaskRequest(session).toLower();
        if (!explicitlyNewTask(request) && !explicitPlanReplacementRequested(request))
            return "Error: replacing unfinished outcomes requires an explicit user scope change. Preserve their IDs and statuses.";
    }
    auto steps = normalizedPlan(session, root["plan"], previous, !replacement);
    if (auto context = "work_context" in root.object)
    {
        if (context.type != JSONType.object && context.type != JSONType.null_)
            return "Error: work_context must be an object, or null to clear a detour.";
        if (context.type == JSONType.object)
        {
            foreach (key; ["step_id", "action", "next_action", "detour_reason", "done_when", "return_to"])
                if (auto field = key in context.object)
                    if (field.type != JSONType.string) return "Error: work_context." ~ key ~ " must be a string.";
            const work = workContextForPlan(session, steps, root);
            if (auto id = "step_id" in context.object)
                if (id.str.length && id.str != work.stepId)
                    return "Error: work_context belongs to the active step " ~ work.stepId ~ ". Omit step_id to bind it automatically.";
            if (work.detourReason.length && (!work.doneWhen.length || !work.returnTo.length))
                return "Error: record done_when and return_to for the detour, preserving its parent outcome.";
        }
    }
    foreach (old; previous)
        if (old.status != "completed" && !replacement)
        {
            bool retained;
            foreach (step; steps) if (step.id == old.id || step.text == old.text) retained = true;
            if (!retained) return "Error: unfinished outcome omitted: " ~ old.text ~ ". Preserve it or use a subplan.";
        }
    bool[string] ids;
    foreach (step; steps)
    {
        if (step.id in ids) return "Error: duplicate plan step ID: " ~ step.id;
        ids[step.id] = true;
        bool unchangedCompleted;
        foreach (old; previous)
            if (old.status == "completed" && step == old) unchangedCompleted = true;
        foreach (id; step.evidence)
        {
            auto proof = id in evidenceIndex;
            if (proof is null || !compatibleEvidence(step, *proof, unchangedCompleted || session.verificationStatus == "passed"))
                return "Error: evidence is missing, failed, stale or incompatible: " ~ id;
        }
        if (step.status == "completed" && !unchangedCompleted && !supportedStep(session, step, evidenceIndex))
            return "Error: completion needs successful evidence for '" ~ step.text ~ "'. Cite tool-call IDs; run the relevant check for verification outcomes.";
    }
    return "";
}

string explorationGuidance(const ref ChatSession session)
{
    const intent = requestIntent(latestTaskRequest(session));
    if (intent == RequestIntent.analysis || intent == RequestIntent.clarification)
        return "Exploration checkpoint: synthesize the supported findings for the current request. " ~
            "Before another lookup, name the remaining unknown. Reuse recorded evidence, batch independent reads, " ~
            "and stop when the requested analysis is supported. Analysis alone does not authorize edits.";
    return "Exploration checkpoint: act when the target and intended behavior are supported. " ~
        "Before another lookup, name the remaining unknown. Batch independent reads and related edits. " ~
        "Record a short outcome plan if this has become substantial work. Verify proportionally; " ~
        "after repeated failure, change the hypothesis or reduce the failing case.";
}

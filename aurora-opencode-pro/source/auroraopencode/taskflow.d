module auroraopencode.taskflow;

import auroraopencode.core;
import auroraopencode.requestintent;
import auroraopencode.planmode : experimentalStrictPlanEnabled;
import auroraopencode.verification : verificationCheck;
import auroraopencode.workevidence : observedResultKey;
import std.algorithm : canFind, min;
import std.array : appender;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip, startsWith, toLower;
import std.regex : matchFirst;

bool taskInstruction(const ref ChatSession session, const ref ChatMessage message)
{
    return message.role == "user" && (!message.internal ||
        (session.parentSessionId.length && session.subagentId.length && message.authorId == session.subagentId));
}

string latestTaskRequest(const ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
        if (taskInstruction(session, session.messages[index]))
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

/// Resume and question turns retain the task's work. A corrective action asks
/// for new evidence, including assignments delivered inside a nested chat.
size_t[] taskActionPath(const ref ChatSession session)
{
    auto path = taskMessagePath(session);
    size_t begin;
    foreach (i, index; path)
    {
        const ref message = session.messages[index];
        if (!taskInstruction(session, message)) continue;
        const intent = requestIntent(message.content);
        if (intent == RequestIntent.implementation ||
            (intent == RequestIntent.analysis && session.contract.intent == "analysis")) begin = i + 1;
    }
    return path[begin .. $];
}

bool initializeLegacyTask(ref ChatSession session)
{
    if (session.contract.id.length || !session.objective.length || !session.messages.length) return false;
    const path = activeMessagePath(session);
    size_t boundary = path.length;
    bool snapshot;
    foreach (i, index; path)
        if (session.messages[index].taskStateJson.length)
            try
            {
                const state = parseJSON(session.messages[index].taskStateJson);
                if (state["objective"].str == session.objective) { boundary = i; snapshot = true; break; }
            }
            catch (Exception) {}
    string anchor;
    const originalIntent = requestIntent(session.objective);
    if (snapshot)
    {
        foreach (index; path[0 .. boundary])
            if (session.messages[index].role == "user" && !session.messages[index].internal)
                anchor = session.messages[index].id;
    }
    else
    {
        foreach_reverse (index; path)
            if (session.messages[index].role == "user" && !session.messages[index].internal &&
                session.messages[index].content.strip() == session.objective.strip())
            { anchor = session.messages[index].id; break; }
        if (!anchor.length && originalIntent != RequestIntent.conversation && originalIntent != RequestIntent.continuation && originalIntent != RequestIntent.clarification)
            foreach_reverse (index; path)
                if (session.messages[index].role == "user" && !session.messages[index].internal &&
                    requestIntent(session.messages[index].content) == originalIntent)
                { anchor = session.messages[index].id; break; }
    }
    if (!anchor.length)
        foreach (index; path)
            if (session.messages[index].role == "user" && !session.messages[index].internal)
            { anchor = session.messages[index].id; break; }
    if (!anchor.length) return false;
    session.contract.id = anchor; session.contract.startMessageId = anchor;
    if (!session.contract.requestedOutcome.length) session.contract.requestedOutcome = session.objective;
    auto intent = requestIntent(session.objective);
    if (intent == RequestIntent.conversation || intent == RequestIntent.continuation)
        intent = session.taskSteps.length ? RequestIntent.implementation : intent;
    session.contract.intent = requestIntentName(intent);
    if (!session.contract.currentIntent.length || session.contract.currentIntent == "conversation")
        session.contract.currentIntent = session.contract.intent;
    return true;
}

void acceptTaskRequest(ref ChatSession session, string text, string messageId)
{
    initializeLegacyTask(session);
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
    foreach (ref item; session.contract.workItems)
        foreach (ref evidence; item.step.evidence) if (auto mapped = evidence in ids) evidence = *mapped;
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
        if (!message.failed && (message.workspaceChanged || message.toolDiff.length)) seen = null;
        const key = observedResultKey(message);
        if (key.length && evidenceKind(message).length && !(key in seen))
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
            initializeLegacyTask(session);
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
    if (message.failed) return "";
    if (message.internal && message.taskStateJson.length)
        try
        {
            const state = parseJSON(message.taskStateJson);
            if (auto proof = "taskActionEvidence" in state.object)
                if (proof.type == JSONType.true_ && state["taskStatus"].str == "completed" &&
                    !["required", "failed"].canFind(state["verificationStatus"].str))
                    return state["taskContract"]["intent"].str == "analysis" ? "research" : "action";
        }
        catch (Exception) {}
    if (message.role != "tool") return "";
    if (["calculate", "read", "grep", "glob", "checksum", "view_image", "webfetch", "websearch"].canFind(message.toolName)) return "research";
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
    return proof !is null && compatibleEvidence(step, *proof, false);
}

string[string] taskEvidenceIndex(const ref ChatSession session, bool currentChecks = true)
{
    string[string] result;
    bool current = true;
    import auroraopencode.recipeevidence : RecipeEvidenceCache;
    RecipeEvidenceCache recipes;
    foreach_reverse (index; taskMessagePath(session))
    {
        const ref message = session.messages[index];
        if (currentChecks) recipes.observe(message);
        const recipe = currentChecks ? recipes.key(message) : "";
        if (!recipe.length && session.verificationScope.length && message.verificationScope == session.verificationScope &&
            !message.verificationCheck.length) current = false;
        const kind = evidenceKind(message);
        if (!kind.length) continue;
        const fresh = currentChecks && (recipe.length ? recipes.current(message, session.verificationScope) :
            current && session.verificationScope.length && message.verificationScope == session.verificationScope);
        const proof = kind == "verify" ? (fresh ? "verify-current|" : "verify|") ~ message.verificationCheck : kind;
        result[message.id] = proof;
        if (message.toolCallId.length && !(message.toolCallId in result)) result[message.toolCallId] = proof;
    }
    return result;
}

bool compatibleEvidence(string kind, string proof, bool allowHistorical)
{
    if (!proof.length) return false;
    if (kind == "verify") return (proof.startsWith("verify-current|") && proof.length > 15) ||
        (allowHistorical && proof.startsWith("verify|") && proof.length > 7);
    if (kind == "edit") return proof == "edit" || proof == "action";
    if (kind == "research") return proof == "research" || proof.startsWith("verify|") || proof.startsWith("verify-current|");
    return true;
}

bool compatibleEvidence(const ref TaskStep step, string proof, bool allowHistorical)
{
    if (!compatibleEvidence(step.kind, proof, allowHistorical)) return false;
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
            if (compatibleEvidence(step, *proof, true)) return true;
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
        ((!current.length || intent == RequestIntent.continuation || intent == RequestIntent.conversation || intent == RequestIntent.clarification) &&
            artifactChangeRequested(session.contract.requestedOutcome));
    foreach (index; taskActionPath(session))
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

private bool samePlanStep(const ref TaskStep a, const ref TaskStep b)
{
    return a.id.length && b.id.length ? a.id == b.id : a.text == b.text;
}

private struct PlanRevision
{
    bool added, reordered, changedAcceptance, interrupted, outOfOrder;
    string[] reopened;
    bool needsReason() const
    { return added || reordered || changedAcceptance || interrupted || outOfOrder || reopened.length > 0; }
}

private PlanRevision inspectPlanRevision(const(TaskStep)[] previous, const(TaskStep)[] steps)
{
    PlanRevision result;
    if (!previous.length) return result;
    size_t last;
    bool matched;
    string priorActive, active;
    foreach (old; previous) if (old.status == "in_progress") priorActive = old.id;
    size_t firstUnfinished = steps.length, activeIndex = steps.length;
    foreach (i, step; steps)
    {
        if (step.status != "completed" && firstUnfinished == steps.length) firstUnfinished = i;
        if (step.status == "in_progress") { active = step.id; activeIndex = i; }
        bool found;
        foreach (j, old; previous)
            if (samePlanStep(old, step))
            {
                found = true;
                if (matched && j < last) result.reordered = true;
                matched = true; last = j;
                if ((old.done.length && old.done != step.done) || (old.kind.length && old.kind != step.kind))
                    result.changedAcceptance = true;
                if (old.status == "completed" && step.status != "completed") result.reopened ~= step.id;
                if (old.status == "in_progress" && step.status == "pending") result.interrupted = true;
                break;
            }
        if (!found) result.added = true;
    }
    result.outOfOrder = active.length && active != priorActive && activeIndex > firstUnfinished;
    return result;
}

void rememberPlanRevision(ref ChatSession session, JSONValue root, const(TaskStep)[] previous, const(TaskStep)[] steps)
{
    if (!inspectPlanRevision(previous, steps).needsReason()) return;
    if (auto reason = "explanation" in root.object)
        if (reason.type == JSONType.string && reason.str.strip().length)
        {
            const decision = "Plan change: " ~ reason.str.strip();
            if (!session.contract.decisions.canFind(decision)) session.contract.decisions ~= decision;
        }
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
                    if (samePlanStep(old, step)) found = true;
                if (found) continue;
                size_t insertAt = steps.length;
                bool anchored;
                foreach (later; previous[oldIndex + 1 .. $])
                {
                    foreach (i, step; steps)
                        if (samePlanStep(later, step))
                        { insertAt = i; anchored = true; break; }
                    if (anchored) break;
                }
                auto retained = TaskStep(old.text, old.status, old.id, old.kind, old.done, old.evidence.dup, old.blocker);
                steps = steps[0 .. insertAt] ~ retained ~ steps[insertAt .. $];
            }
    string[string] index;
    size_t[] path;
    bool indexed;
    foreach (ref step; steps)
    {
        foreach (old; previous)
            if ((step.id.length && old.id == step.id) || (!step.id.length && old.text == step.text))
            {
                if (!step.id.length) step.id = old.id;
                if (!step.kind.length) step.kind = old.kind;
                if (!step.done.length) step.done = old.done;
                if (old.status == "completed" && step.status != "completed") step.evidence = null;
                else if (!step.evidence.length) step.evidence = old.evidence.dup;
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
        {
            if (!indexed) { index = taskEvidenceIndex(session); path = taskMessagePath(session); indexed = true; }
            foreach_reverse (slot; path)
            {
                const ref message = session.messages[slot];
                const id = message.toolCallId.length ? message.toolCallId : message.id;
                if (auto proof = id in index)
                    if (compatibleEvidence(step, *proof, false))
                    { step.evidence = [id]; break; }
            }
        }
    }
    if (retainCompleted && previous.length)
    {
        TaskStep[] existing, added;
        foreach (step; steps)
        {
            bool known;
            foreach (old; previous) if (samePlanStep(old, step)) { known = true; break; }
            if (known) existing ~= step;
            else added ~= step;
        }
        steps = existing ~ added;
    }
    return steps;
}

string planUpdateText(const ref ChatSession session, string arguments)
{
    const root = parseJSON(arguments);
    const replacement = "replace_entire_plan" in root.object && root["replace_entire_plan"].type == JSONType.true_;
    const(TaskStep)[] steps = "plan" in root.object ? normalizedPlan(session, root["plan"], session.taskSteps, !replacement) : session.taskSteps;
    auto output = appender!string();
    output.put("Plan updated");
    if (auto reason = "explanation" in root.object)
        if (reason.type == JSONType.string && reason.str.length) output.put(" (" ~ reason.str ~ ")");
    output.put(":");
    if ("plan" in root.object) foreach (i, step; steps)
    {
        const marker = step.status == "completed" ? "[x]" : step.status == "in_progress" ? "[>]" : "[ ]";
        output.put("\n" ~ to!string(i + 1) ~ ". " ~ marker ~ " " ~ step.text);
        if (step.done.length) output.put(" (done: " ~ step.done ~ ")");
    }
    if (!("plan" in root.object)) output.put(" checklist retained.");
    if ("work_items" in root.object)
    {
        import auroraopencode.worktracking : normalizedWorkItems;
        foreach (item; normalizedWorkItems(session, root, steps))
            foreach (row; root["work_items"].array)
                if (("id" in row.object && row["id"].str == item.step.id) ||
                    (!("id" in row.object) && "step" in row.object && row["step"].str == item.step.text))
                {
                    output.put("\nWork " ~ item.step.id ~ " [" ~ item.step.status ~ "] " ~ item.step.text ~
                        (item.required ? " (required)" : " (follow-up)"));
                    break;
                }
    }
    return output.data;
}

TaskWorkContext workContextForPlan(const ref ChatSession session, const(TaskStep)[] steps, JSONValue root = JSONValue.init)
{
    TaskWorkContext result;
    size_t current = steps.length;
    foreach (i, step; steps) if (step.status == "in_progress") { current = i; break; }
    if (current == steps.length)
        foreach (i, step; steps) if (step.status != "completed") { current = i; break; }
    if (current == steps.length && steps.length) return result;
    if (!steps.length)
    {
        result = session.contract.work;
        result.stepId = ""; result.nextStepId = "";
        if (!result.action.length) result.action = session.objective;
    }
    if (current < steps.length && session.contract.work.stepId == steps[current].id) result = session.contract.work;
    if (current < steps.length)
    {
        result.stepId = steps[current].id;
        if (!result.action.length) result.action = steps[current].text;
    }
    size_t next = steps.length;
    foreach (i, step; steps[min(current + 1, steps.length) .. $])
        if (step.status != "completed") { next = current + 1 + i; break; }
    if (next == steps.length)
        foreach (i, step; steps[0 .. current])
            if (step.status != "completed") { next = i; break; }
    const nextId = next < steps.length ? steps[next].id : "";
    if (result.nextStepId != nextId || !result.nextAction.length)
        result.nextAction = next < steps.length ? steps[next].text : "";
    result.nextStepId = nextId;
    string activeItem;
    foreach (item; session.contract.workItems)
        if (item.parentId == result.stepId && item.step.status == "in_progress" && item.required)
        {
            activeItem = item.step.id;
            if (result.workItemId != activeItem)
            {
                result.action = item.step.text;
                result.nextAction = next < steps.length ? steps[next].text : "";
                foreach (remaining; session.contract.workItems)
                    if (remaining.parentId == result.stepId && remaining.required && remaining.step.status == "pending")
                    { result.nextAction = remaining.step.text; break; }
            }
            break;
        }
    if (!activeItem.length && result.workItemId.length)
    {
        result.action = current < steps.length ? steps[current].text : session.objective;
        result.nextAction = next < steps.length ? steps[next].text : "";
        foreach (remaining; session.contract.workItems)
            if (remaining.parentId == result.stepId && remaining.required && remaining.step.status == "pending")
            { result.nextAction = remaining.step.text; break; }
    }
    result.workItemId = activeItem;
    if (root.type != JSONType.object) return result;
    if (auto context = "work_context" in root.object)
    {
        if (context.type == JSONType.null_)
        { ChatSession empty; result = workContextForPlan(empty, steps); }
        else if (context.type == JSONType.object)
        {
            const originalAction = session.contract.work.action.length ? session.contract.work.action : result.action;
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
            if (result.detourReason.length && !result.doneWhen.length) result.doneWhen = current < steps.length ? steps[current].done : session.objective;
            if (!result.detourReason.length) { result.doneWhen = ""; result.returnTo = ""; }
            if (!result.action.length) result.action = current < steps.length ? steps[current].text : session.objective;
        }
    }
    // Moving to independent work can be legitimate. Keep the paused outcome's
    // return point even when the model supplied only the explanation.
    bool explicitReturn;
    if (auto context = "work_context" in root.object)
        if (context.type == JSONType.object)
            if (auto field = "return_to" in context.object)
                explicitReturn = field.type == JSONType.string && field.str.strip().length > 0;
    foreach (old; session.taskSteps)
            if (old.status == "in_progress" && old.id != result.stepId)
                foreach (step; steps)
                    if (samePlanStep(old, step) && step.status == "pending")
                        if (auto reason = "explanation" in root.object)
                            if (reason.type == JSONType.string && reason.str.strip().length)
                            {
                                if (!result.detourReason.length) result.detourReason = reason.str.strip();
                                if (!result.doneWhen.length) result.doneWhen = steps[current].done;
                                if (!explicitReturn)
                                    result.returnTo = session.contract.work.stepId == old.id && session.contract.work.action.length
                                        ? session.contract.work.action : old.text;
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
    if (root.type != JSONType.object) return "Error: update_plan requires an object.";
    bool update;
    foreach (key; ["plan", "work_items", "work_context", "objective", "constraints", "decisions"]) if (key in root.object) update = true;
    if (!update) return "Error: provide plan, work_items, work_context or task metadata.";
    if (auto plan = "plan" in root.object)
        if (plan.type != JSONType.array || !plan.array.length) return "Error: plan must be a non-empty array.";
    string[string] evidenceIndex;
    bool indexed;
    bool replacement;
    if (auto f = "replace_entire_plan" in root.object) replacement = f.type == JSONType.true_;
    if (replacement)
    {
        const request = latestTaskRequest(session).toLower();
        if (!explicitlyNewTask(request) && !explicitPlanReplacementRequested(request))
            return "Error: replacing unfinished outcomes requires an explicit user scope change. Preserve their IDs and statuses.";
    }
    const(TaskStep)[] steps = "plan" in root.object ? normalizedPlan(session, root["plan"], previous, !replacement) : previous;
    string reason;
    if (auto field = "explanation" in root.object)
    {
        if (field.type != JSONType.string) return "Error: explanation must be a string.";
        reason = field.str.strip();
    }
    string[] reopened;
    if (auto field = "reopen_steps" in root.object)
    {
        if (field.type != JSONType.array) return "Error: reopen_steps must contain stable outcome IDs.";
        foreach (entry; field.array)
        {
            if (entry.type != JSONType.string || !entry.str.strip().length)
                return "Error: reopen_steps must contain stable outcome IDs.";
            reopened ~= entry.str;
        }
    }
    const revision = inspectPlanRevision(previous, steps);
    if (!replacement)
    {
        if (revision.needsReason() && !reason.length)
            return "Error: explain additions, reordering, changed acceptance, or a paused/skipped outcome in explanation. Tie the change to the user's goal or a concrete finding; preserve unfinished work.";
        foreach (id; revision.reopened)
            if (!reopened.canFind(id))
                return "Error: completed outcome '" ~ id ~ "' cannot silently become unfinished. List its ID in reopen_steps and explain the new defect or changed requirement.";
        foreach (id; reopened)
            if (!revision.reopened.canFind(id)) return "Error: reopen_steps names an outcome that is not being reopened: " ~ id;
    }
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
            foreach (step; steps) if (samePlanStep(old, step)) retained = true;
            if (!retained) return "Error: unfinished outcome omitted: " ~ old.text ~ ". Preserve it or use a subplan.";
        }
    if (!("plan" in root.object))
    {
        import auroraopencode.worktracking : workItemsError;
        return workItemsError(session, root, steps);
    }
    bool[string] ids;
    bool[string] texts;
    int active;
    foreach (step; steps)
    {
        if (step.id in ids) return "Error: duplicate plan step ID: " ~ step.id;
        ids[step.id] = true;
        const text = step.text.strip().toLower();
        if (text in texts) return "Error: duplicate plan outcome: " ~ step.text ~ ". Reuse its existing stable ID.";
        texts[text] = true;
        if (step.status == "in_progress" && ++active > 1) return "Error: at most one plan outcome may be in_progress.";
        bool unchangedCompleted;
        foreach (old; previous)
        {
            if (samePlanStep(old, step) && old.status == "completed" && step.status == "completed" &&
                ((old.done.length && old.done != step.done) || (old.kind.length && old.kind != step.kind)))
                return "Error: completed acceptance cannot silently change. Reopen the outcome with a reason, or add a justified follow-up outcome.";
            if (old.status == "completed" && step.status == "completed" && samePlanStep(old, step) &&
                old.kind == step.kind && old.done == step.done && old.evidence == step.evidence)
                unchangedCompleted = true;
        }
        if (unchangedCompleted || step.status != "completed") continue;
        if (!indexed) { evidenceIndex = taskEvidenceIndex(session); indexed = true; }
        foreach (id; step.evidence)
        {
            auto proof = id in evidenceIndex;
            if (proof is null || !compatibleEvidence(step, *proof, unchangedCompleted))
                return "Error: evidence is missing, failed, stale or incompatible: " ~ id;
        }
        if (step.status == "completed" && !unchangedCompleted && !supportedStep(session, step, evidenceIndex))
            return "Error: completion needs successful evidence for '" ~ step.text ~ "'. Cite tool-call IDs; run the relevant check for verification outcomes.";
    }
    import auroraopencode.worktracking : workItemsError;
    return workItemsError(session, root, steps);
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

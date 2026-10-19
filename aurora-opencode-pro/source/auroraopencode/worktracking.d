module auroraopencode.worktracking;

import auroraopencode.core;
import auroraopencode.taskflow : taskEvidenceIndex, compatibleEvidence,
    inferredPlanKind, reconciledPlanKind, planCompletionError;
import std.algorithm : canFind;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip;

TaskWorkItem[] normalizedWorkItems(const ref ChatSession session, JSONValue root, const(TaskStep)[] parents)
{
    TaskWorkItem[] items;
    foreach (item; session.contract.workItems)
        items ~= TaskWorkItem(TaskStep(item.step.text, item.step.status, item.step.id, item.step.kind,
            item.step.done, item.step.evidence.dup, item.step.blocker), item.parentId, item.origin, item.reason, item.required);
    auto updates = "work_items" in root.object;
    if (updates is null || updates.type != JSONType.array) return items;
    string[string] evidence;
    bool indexed;
    foreach (row; updates.array)
    {
        if (row.type != JSONType.object) continue;
        string field(string key)
        {
            if (auto f = key in row.object) if (f.type == JSONType.string) return f.str.strip();
            return "";
        }
        auto id = field("id");
        string parentId = field("parent_id");
        if (!("parent_id" in row.object))
            foreach (parent; parents) if (parent.status == "in_progress") { parentId = parent.id; break; }
        size_t at = items.length;
        foreach (i, item; items)
            if ((id.length && item.step.id == id) || (!id.length && item.step.text == field("step") &&
                item.parentId == parentId)) { at = i; break; }
        TaskWorkItem item;
        if (at < items.length) item = items[at];
        else
        {
            item.step.status = "pending"; item.step.kind = "other";
            foreach (parent; parents) if (parent.status == "in_progress") { item.parentId = parent.id; break; }
        }
        foreach (key; ["step", "status", "kind", "done", "parent_id", "origin", "reason"])
            if (key in row.object)
            {
                const text = field(key);
                switch (key)
                {
                    case "step": item.step.text = text; break;
                    case "status": item.step.status = text; break;
                    case "kind": item.step.kind = text; break;
                    case "done": item.step.done = text; break;
                    case "parent_id": item.parentId = text; break;
                    case "origin": item.origin = text; break;
                    case "reason": item.reason = text; break;
                    default: break;
                }
            }
        if (auto required = "required" in row.object) item.required = required.type != JSONType.false_;
        if (!("kind" in row.object))
            item.step.kind = at == items.length ? inferredPlanKind(item.step.text) : reconciledPlanKind(items[at].step);
        if (!item.step.done.length) item.step.done = item.step.text;
        if (!id.length) id = at < items.length ? items[at].step.id : "work-" ~
            sha256Of(session.contract.id ~ "\n" ~ item.parentId ~ "\n" ~ item.step.text).toHexString()[0 .. 16].idup;
        item.step.id = id;
        if (auto proof = "evidence" in row.object)
        {
            item.step.evidence = null;
            if (proof.type == JSONType.array)
                foreach (entry; proof.array) if (entry.type == JSONType.string) item.step.evidence ~= entry.str;
        }
        const alreadyCompleted = at < items.length && items[at].step.status == "completed";
        if (alreadyCompleted && item.step.status != "completed") item.step.evidence = null;
        if (item.step.status == "completed" && !alreadyCompleted && !item.step.evidence.length)
        {
            if (!indexed) { evidence = taskEvidenceIndex(session); indexed = true; }
            foreach_reverse (index; activeMessagePath(session))
            {
                const ref message = session.messages[index];
                const proofId = message.toolCallId.length ? message.toolCallId : message.id;
                if (auto proof = proofId in evidence)
                    if (compatibleEvidence(item.step, *proof, false)) { item.step.evidence = [proofId]; break; }
            }
        }
        if (at < items.length) items[at] = item;
        else items ~= item;
    }
    return items;
}

bool requiredWorkRemaining(const ref ChatSession session)
{
    foreach (item; session.contract.workItems)
        if (item.required && item.step.status != "completed") return true;
    return false;
}

bool workTracksPhase(const ref ChatSession session, int phase)
{
    foreach (item; session.contract.workItems)
        if (item.step.id == session.contract.work.workItemId && item.parentId == session.contract.work.stepId &&
            item.step.status == "in_progress")
            return phase >= 2 ? item.step.kind == "verify" :
                phase == 1 && (item.step.kind == "edit" || item.step.kind == "verify");
    return false;
}

string workItemsError(const ref ChatSession session, JSONValue root, const(TaskStep)[] parents)
{
    if (auto updates = "work_items" in root.object)
    {
        if (updates.type != JSONType.array) return "Error: work_items must be an array of incremental work records.";
        bool[string] seen;
        foreach (row; updates.array)
        {
            if (row.type != JSONType.object) return "Error: each work item must be an object.";
            foreach (key; ["id", "step", "status", "kind", "done", "parent_id", "origin", "reason"])
                if (auto value = key in row.object)
                    if (value.type != JSONType.string) return "Error: work_items." ~ key ~ " must be a string.";
            if (auto value = "required" in row.object)
                if (value.type != JSONType.true_ && value.type != JSONType.false_) return "Error: work_items.required must be boolean.";
            if (auto value = "evidence" in row.object)
            {
                if (value.type != JSONType.array) return "Error: work_items.evidence must contain tool-call IDs.";
                foreach (id; value.array) if (id.type != JSONType.string || !id.str.length) return "Error: invalid work item evidence ID.";
            }
            const key = "id" in row.object ? row["id"].str : "step" in row.object ? row["step"].str : "";
            if (!key.length) return "Error: identify an existing work item by id, or provide step text for a new item.";
            if (key in seen) return "Error: update each work item once per call.";
            seen[key] = true;
        }
    }
    auto items = normalizedWorkItems(session, root, parents);
    if (!items.length) return "";
    string[string] evidence;
    bool indexed;
    foreach (item; items)
    {
        if (!item.step.text.length || !["pending", "in_progress", "completed", "deferred"].canFind(item.step.status))
            return "Error: work items need step text and a valid status.";
        if (!["research", "edit", "verify", "answer", "other"].canFind(item.step.kind)) return "Error: invalid work item kind.";
        if (!["planned", "discovery", "recovery"].canFind(item.origin)) return "Error: invalid work item origin.";
        if ((item.origin != "planned" || !item.required) && !item.reason.length)
            return "Error: record why discovered/recovery work matters, or why a follow-up is outside current scope.";
        if (item.required && item.step.status == "deferred") return "Error: required work remains pending until resolved; only optional follow-ups can be deferred.";
        if (item.parentId.length)
        {
            bool found;
            foreach (parent; parents) if (parent.id == item.parentId)
            {
                found = true;
                if (parent.status == "completed" && item.required && item.step.status != "completed")
                    return "Error: finish required work '" ~ item.step.text ~ "' before completing its parent outcome.";
            }
            if (!found) return "Error: work item parent_id must name a retained outcome, or be empty for the objective.";
        }
        bool unchangedCompleted;
        foreach (old; session.contract.workItems) if (old.step.id == item.step.id)
        {
            unchangedCompleted = old.step.status == "completed" && item.step.status == "completed" &&
                old.step.kind == item.step.kind && old.step.done == item.step.done && old.step.evidence == item.step.evidence;
            if (old.required != item.required || old.parentId != item.parentId ||
                (old.step.status == "completed" && (item.step.status != "completed" || old.step.done != item.step.done || old.step.kind != item.step.kind)))
                if (!("explanation" in root.object) || root["explanation"].type != JSONType.string || !root["explanation"].str.strip().length)
                    return "Error: explain reclassification, reparenting or reopening of recorded work; preserve the objective.";
            if (old.step.status == "completed" && item.step.status == "completed" && (old.step.done != item.step.done || old.step.kind != item.step.kind))
                return "Error: reopen a work item before changing its completed acceptance.";
        }
        if (item.step.status == "completed" && !unchangedCompleted)
        {
            if (!indexed) { evidence = taskEvidenceIndex(session); indexed = true; }
            const completionError = planCompletionError(session, item.step, evidence);
            if (completionError.length) return completionError;
        }
    }
    return "";
}


string readPlanText(const ref ChatSession session, string arguments)
{
    import auroraopencode.taskcontext : taskContext;
    JSONValue args;
    try args = parseJSON(arguments);
    catch (Exception) return "Error: invalid read_plan JSON.";
    if (args.type != JSONType.object) return "Error: read_plan requires an object.";
    string field(string key)
    {
        if (auto value = key in args.object) if (value.type == JSONType.string) return value.str;
        return "";
    }
    const view = field("view");
    if (!view.length || view == "summary") return taskContext(session, "", true);
    if (view != "details") return "Error: view must be summary or details.";
    size_t offset, limit = 12;
    if (auto value = "offset" in args.object)
    {
        if (value.type != JSONType.integer || value.integer < 0) return "Error: offset must be nonnegative.";
        offset = cast(size_t) value.integer;
    }
    if (auto value = "limit" in args.object)
    {
        if (value.type != JSONType.integer || value.integer < 1 || value.integer > 50) return "Error: limit must be 1..50.";
        limit = cast(size_t) value.integer;
    }
    const completed = "include_completed" in args.object && args["include_completed"].type == JSONType.true_;
    auto rows = JSONValue(string[].init);
    const outcomes = field("collection") == "outcomes";
    if (outcomes)
    {
        foreach (step; session.taskSteps)
            if (completed || step.status != "completed") rows.array ~= taskStepsToJson([step])[0];
    }
    else
        foreach (item; session.contract.workItems)
            if ((completed || item.step.status != "completed") &&
                (!("parent_id" in args.object) || item.parentId == field("parent_id")))
                rows.array ~= taskWorkItemsToJson([item])[0];
    JSONValue result;
    result["objective"] = session.objective;
    result["requestedOutcome"] = session.contract.requestedOutcome;
    result["collection"] = outcomes ? "outcomes" : "actions";
    result["total"] = cast(long) rows.array.length;
    JSONValue[] page;
    if (offset < rows.array.length)
    {
        const end = offset + (limit < rows.array.length - offset ? limit : rows.array.length - offset);
        page = rows.array[offset .. end];
        if (end < rows.array.length) result["nextOffset"] = cast(long) end;
    }
    result["items"] = page;
    return result.toPrettyString();
}

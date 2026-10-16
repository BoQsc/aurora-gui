module auroraopencode.taskcontinuation;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.requestintent : answerOnlyRequest;
import auroraopencode.taskflow : supportedStep, taskHasActionEvidence, taskEvidenceIndex, taskRequiresPlan;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf, strip;

enum taskContinuationMarker = "Continuation: unfinished authorized work\n";
enum taskStallLimit = 3;

enum TaskContinuationAction { settle, continueWork, replan, needsAttention }

struct TaskContinuation
{
    TaskContinuationAction action;
    int tools;
    int completed;
    bool verified;
    int stalled;
    int replans;
    string[] evidence;

    string guidance() const
    {
        JSONValue state;
        state["tools"] = tools;
        state["completed"] = completed;
        state["verified"] = verified;
        state["stalled"] = action == TaskContinuationAction.replan ? 0 : stalled;
        state["replans"] = replans + (action == TaskContinuationAction.replan ? 1 : 0);
        state["evidence"] = JSONValue(evidence);
        if (action == TaskContinuationAction.replan)
            return taskContinuationMarker ~ state.toString() ~ "\n" ~
                "The last attempts produced no completed outcome or accepted verification. " ~
                "Change the diagnostic approach now. Record the exact remaining defect, " ~
                "expected behavior, strongest contradictory evidence and rejected hypotheses. " ~
                "Reduce it to a failing case or inspect a different subsystem before editing. " ~
                "Use an independent reference for rendering. New query strings, repeated " ~
                "builds and plan rewrites are not proof of improvement. Continue the user's " ~
                "authorized work without asking permission; use task_blocker only for an " ~
                "actual missing input or external dependency.";
        return taskContinuationMarker ~ state.toString() ~ "\n" ~
            "The user's authorized task still has unfinished work or verification. " ~
            "Continue the remaining outcomes with the available tools now. " ~
            "Keep update_plan accurate and verify completed changes. Do not repeat " ~
            "successful checks without a new reason, merely summarize the remaining " ~
            "work, or ask permission to continue work already requested. A successful " ~
            "check of a partial change does not complete the task. If required input " ~
            "or an external dependency actually prevents further work, call " ~
            "task_blocker with the specific reason and required question, then " ~
            "explain it to the user. Otherwise finish the remaining work.";
    }
}

bool unfinishedTask(const ref ChatSession session)
{
    auto evidenceIndex = taskEvidenceIndex(session);
    foreach (step; session.taskSteps)
        if (step.status != "completed" ||
            (session.contract.id.length && !supportedStep(session, step, evidenceIndex))) return true;
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed" ||
                (session.contract.id.length && !supportedStep(session, step, evidenceIndex))) return true;
    if (session.contract.id.length && session.taskSteps.length == 0 &&
        (session.contract.currentIntent == "implementation" || session.contract.currentIntent == "continuation") &&
        (!taskHasActionEvidence(session) || taskRequiresPlan(session))) return true;
    return session.verificationStatus == "required" ||
        session.verificationStatus == "failed";
}

/// Derive the retry budget from the selected, durable branch. Prose, failed
/// calls, novel searches and plan rewrites cannot reset it. Completed outcomes
/// and accepted verification can. A stalled run changes diagnosis before it
/// needs attention; productive work has no fixed turn cap.
TaskContinuation taskContinuation(const ref ChatSession session, bool toolsEnabled)
{
    TaskContinuation result;
    if (!toolsEnabled || session.taskStatus == "blocked" ||
        session.queuedFollowUps.length || !unfinishedTask(session)) return result;
    auto path = activeMessagePath(session);
    size_t begin;
    string request;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        {
            begin = i + 1;
            request = session.messages[index].content;
        }
    if (!request.length && session.parentSessionId.length) request = session.contract.requestedOutcome;
    if (!request.length || answerOnlyRequest(request)) return result;

    JSONValue previous;
    bool[string] evidence;
    foreach (index; path[begin .. $])
    {
        const message = session.messages[index];
        if (message.role == "user" && message.internal &&
            message.content.startsWith(taskContinuationMarker))
        {
            const text = message.content[taskContinuationMarker.length .. $];
            const end = text.indexOf('\n');
            try
            {
                auto snapshot = parseJSON(end < 0 ? text : text[0 .. end]);
                if (snapshot.type == JSONType.object &&
                    "tools" in snapshot.object && "completed" in snapshot.object &&
                    "verified" in snapshot.object && "stalled" in snapshot.object &&
                    snapshot["tools"].type == JSONType.integer &&
                    snapshot["completed"].type == JSONType.integer &&
                    (snapshot["verified"].type == JSONType.true_ ||
                     snapshot["verified"].type == JSONType.false_) &&
                    snapshot["stalled"].type == JSONType.integer)
                    previous = snapshot;
            }
            catch (Exception) {}
        }
        if (message.role != "tool" || message.failed ||
            message.toolName == "update_plan" || message.toolName == "update_subplan" ||
            message.toolName == "task_blocker" || message.toolName == "process" ||
            message.toolName == "assign" || message.toolName == "ask_user" ||
            message.toolName == "finish") continue;
        if (message.toolName == "dshell" &&
            (message.toolArgs.indexOf("\"sleep\"") >= 0 ||
             message.toolArgs.indexOf("\"wait\"") >= 0)) continue;
        // Command timing/output alone is not new progress for an identical run.
        const detail = message.toolName == "run" ? "" : message.content ~ message.toolDiff;
        const key = sha256Of(message.toolName ~ "\n" ~ message.toolArgs ~ "\n" ~ detail).toHexString().idup;
        evidence[key] = true;
    }
    result.tools = cast(int) evidence.length;
    bool[string] completedEvidence;
    auto evidenceIndex = taskEvidenceIndex(session);
    foreach (step; session.taskSteps)
        if (supportedStep(session, step, evidenceIndex))
        {
            ++result.completed;
            foreach (id; step.evidence) completedEvidence[id] = true;
        }
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (supportedStep(session, step, evidenceIndex))
            {
                ++result.completed;
                foreach (id; step.evidence) completedEvidence[id] = true;
            }
    foreach (id; completedEvidence.keys) result.evidence ~= id;
    result.verified = session.verificationStatus == "passed";
    if (previous.type == JSONType.object)
    {
        bool newEvidence;
        if (auto prior = "evidence" in previous.object)
            if (prior.type == JSONType.array)
                foreach (id; result.evidence)
                {
                    bool known;
                    foreach (entry; prior.array)
                        if (entry.type == JSONType.string && entry.str == id) known = true;
                    if (!known) newEvidence = true;
                }
        const progressed = newEvidence || (result.verified && !previous["verified"].boolean);
        result.stalled = progressed ? 0 : cast(int) previous["stalled"].integer + 1;
        if (!progressed)
            if (auto value = "replans" in previous.object)
                if (value.type == JSONType.integer) result.replans = cast(int) value.integer;
    }
    result.action = result.stalled >= taskStallLimit
        ? (result.replans == 0 ? TaskContinuationAction.replan : TaskContinuationAction.needsAttention)
        : TaskContinuationAction.continueWork;
    return result;
}

string taskBlockerError(string arguments)
{
    try
    {
        const value = parseJSON(arguments);
        if (value.type != JSONType.object) return "task_blocker requires an object.";
        string field(string key)
        {
            if (auto found = key in value.object)
                if (found.type == JSONType.string) return found.str.strip();
            return "";
        }
        const kind = field("kind");
        if (kind != "input" && kind != "external")
            return "task_blocker kind must be input or external.";
        if (!field("reason").length) return "task_blocker requires the specific missing input or dependency in reason.";
        if (kind == "input" && !field("question").length)
            return "task_blocker requires a question when input is missing.";
        return "";
    }
    catch (Exception) { return "task_blocker requires valid JSON."; }
}

module auroraopencode.taskcontinuation;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.requestintent : answerOnlyRequest;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf, strip;

enum taskContinuationMarker = "Continuation: unfinished authorized work\n";
enum taskStallLimit = 3;

enum TaskContinuationAction { settle, continueWork, needsAttention }

struct TaskContinuation
{
    TaskContinuationAction action;
    int tools;
    int completed;
    bool verified;
    int stalled;

    string guidance() const
    {
        JSONValue state;
        state["tools"] = tools;
        state["completed"] = completed;
        state["verified"] = verified;
        state["stalled"] = stalled;
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
    foreach (step; session.taskSteps)
        if (step.status != "completed") return true;
    return session.verificationStatus == "required" ||
        session.verificationStatus == "failed";
}

/// Derive the retry budget from the selected, durable branch. Prose, failed
/// calls and plan rewrites cannot reset it. New evidence/work, completed steps
/// and passing verification can, so productive work has no fixed turn cap.
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
    foreach (step; session.taskSteps)
        if (step.status == "completed") ++result.completed;
    result.verified = session.verificationStatus == "passed";
    if (previous.type == JSONType.object)
    {
        const progressed = result.tools > previous["tools"].integer ||
            result.completed > previous["completed"].integer ||
            (result.verified && !previous["verified"].boolean);
        result.stalled = progressed ? 0 : cast(int) previous["stalled"].integer + 1;
    }
    result.action = result.stalled >= taskStallLimit
        ? TaskContinuationAction.needsAttention : TaskContinuationAction.continueWork;
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

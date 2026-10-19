module auroraopencode.completionhandoff;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.taskflow : taskInstruction, supportedStep, taskEvidenceIndex;
import auroraopencode.taskcontext : taskExcerpt;
import std.algorithm : canFind;
import std.array : join;
import std.json : JSONType, parseJSON;
import std.regex : matchFirst;
import std.string : strip, startsWith, toLower, splitLines, replace;

enum completionHandoffMarker = "Completion handoff requested:\n";
enum completionHandoffInstruction = "Summarize recorded work with Result:, Checks:, Remaining:. " ~
    "Name delivered outcomes, actual checks (or unrun checks), and unresolved work. " ~
    "Use three brief lines; every response style retains them. " ~
    "Use only existing evidence: no tools, new work or permission questions. " ~
    "Do not claim unchecked or unfinished work completed.";

/// Scope the checkpoint to this instruction and selected branch, including
/// assignments in child chats. A new human request never inherits a repair.
private size_t[] turnPath(const ref ChatSession session)
{
    auto path = activeMessagePath(session);
    foreach_reverse (i, index; path)
        if (taskInstruction(session, session.messages[index])) return path[i + 1 .. $];
    return path;
}

bool completionHandoffPending(const ref ChatSession session)
{
    foreach (index; turnPath(session))
        if (session.messages[index].internal &&
            session.messages[index].content.startsWith(completionHandoffMarker)) return true;
    return false;
}

/// Accept plain or Markdown labels and multiline bodies, including localized
/// content. Quoted examples and code fences cannot satisfy a real handoff.
bool hasCompletionHandoff(string text)
{
    bool[3] body;
    int section = -1;
    string fence;
    foreach (raw; text.splitLines())
    {
        auto line = raw.strip();
        if (line.startsWith("```") || line.startsWith("~~~"))
        {
            if (!fence.length) fence = line[0 .. 3];
            else if (line.startsWith(fence)) fence = "";
            continue;
        }
        if (fence.length || line.startsWith(">")) continue;
        line = line.replace("**", "");
        while (line.length && "#*- ".canFind(line[0])) line = line[1 .. $];
        const lower = line.toLower();
        foreach (i, name; ["result", "checks", "remaining"])
            if (lower == name || lower.startsWith(name ~ ":"))
            {
                section = cast(int) i;
                line = line.length > name.length ? line[name.length + 1 .. $].strip() : "";
                break;
            }
        if (section >= 0 && line.strip().length) body[section] = true;
    }
    return body[0] && body[1] && body[2];
}

private bool customReplyRequested(string request)
{
    return cast(bool) matchFirst(request.toLower(),
        `\b(?:no (?:closing )?(?:summary|recap)|without (?:a )?(?:closing )?(?:summary|recap)|(?:do not|don't|dont) (?:summari[sz]e|recap)|(?:json|csv|xml|yaml) only|(?:reply|respond|answer|output|return)(?:\s+(?:with|using|in|as|a|an|valid|single))*\s+(?:json|csv|xml|yaml|html)\b|(?:reply|respond|answer|output|return)(?:\s+(?:with|using|in))?\s+(?:only|exactly|just)\b|(?:then|finally)\s+(?:reply|respond|answer)\s+(?:with\s+)?\S+\s*[.!]?\s*$)`);
}

bool completionHandoffNeeded(const ref ChatSession session, string finishReason = "")
{
    string request;
    foreach_reverse (index; activeMessagePath(session))
        if (taskInstruction(session, session.messages[index]))
        { request = session.messages[index].content; break; }
    if (customReplyRequested(request)) return false;
    size_t actions;
    bool changed, checked, planned;
    string answer, reason;
    foreach (index; turnPath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "tool")
        {
            if (message.toolName == "update_plan" && !message.failed) planned = true;
            if (["update_plan", "read_plan", "update_subplan", "process", "tool_status",
                    "request_input", "task_blocker", "retire_images", "assign", "finish", "ask_user"].canFind(message.toolName)) continue;
            ++actions;
            changed |= !message.failed && message.workspaceChanged;
            checked |= message.verificationCheck.length > 0;
        }
        if (message.role == "assistant" && !message.internal && !message.failed && !message.toolCalls.length)
        { answer = message.content; reason = message.finishReason; }
    }
    if (actions < 4 && !(changed && checked) && !(planned && actions && session.taskSteps.length > 1)) return false;
    return finishReason == "length" || reason == "length" || !hasCompletionHandoff(answer);
}

/// Bounded, conservative fallback if the provider also omits the requested
/// summary. It describes receipts, never promotes them into unsupported claims.
string recordedCompletionHandoff(const ref ChatSession session)
{
    string[] delivered, changes, checks, remaining;
    auto evidence = taskEvidenceIndex(session);
    void add(ref string[] values, string value)
    {
        value = taskExcerpt(value.replace("\n", " ").replace("\r", " "), 240);
        if (value.length && !values.canFind(value) && values.length < 8) values ~= value;
    }
    foreach (step; session.taskSteps)
        if (step.status == "completed" && supportedStep(session, step, evidence)) add(delivered, step.text);
        else add(remaining, step.text);
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed" || !supportedStep(session, step, evidence)) add(remaining, step.text);
    foreach (item; session.contract.workItems)
        if (item.required && (item.step.status != "completed" || !supportedStep(session, item.step, evidence)))
            add(remaining, item.step.text);
    foreach (index; turnPath(session))
    {
        const ref message = session.messages[index];
        if (message.role != "tool" || message.failed) continue;
        if (auto proof = message.id in evidence)
            if ((*proof).startsWith("verify-current|")) add(checks, message.verificationCheck);
        if (message.workspaceChanged)
        {
            string target;
            try
            {
                const args = parseJSON(message.toolArgs);
                if (args.type == JSONType.object)
                    foreach (key; ["filePath", "path"])
                        if (auto value = key in args.object)
                            if (value.type == JSONType.string) { target = value.str; break; }
            }
            catch (Exception) {}
            add(changes, message.toolName ~ (target.length ? " " ~ target : " (recorded workspace change)"));
        }
    }
    if (session.verificationStatus == "required" || session.verificationStatus == "failed")
        add(remaining, session.verificationStatus == "failed" ? "Required verification failed" : "Required verification is outstanding");
    add(remaining, session.contract.blocker);
    const result = delivered.length ? delivered.join("; ") : changes.length ? changes.join("; ") :
        "Tool work is recorded above; the agent did not return a complete outcome explanation";
    return "Aurora work summary (from recorded evidence):\n\nResult: " ~ result ~
        ".\nChecks: " ~ (checks.length ? checks.join("; ") : "No current successful verification receipt recorded") ~
        ".\nRemaining: " ~ (remaining.length ? remaining.join("; ") : "No further required work recorded") ~ ".";
}

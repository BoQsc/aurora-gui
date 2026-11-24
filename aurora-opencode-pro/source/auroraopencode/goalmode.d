module auroraopencode.goalmode;

import auroraopencode.core : ChatSession, GoalHistoryEntry, activeMessagePath;
import auroraopencode.requestintent : answerOnlyRequest, requestIntent,
    RequestIntent;
import std.array : appender, join, split;
import std.json : JSONType, JSONValue, parseJSON;
import std.regex : matchAll, matchFirst, regex;
import std.string : indexOf, replace, splitLines, startsWith, strip, toLower;
import std.utf : toUTF32, toUTF8;

/// Claude Code caps a goal condition at 4,000 characters. Keep the same bound
/// so a goal stays a one-line completion condition instead of becoming a
/// second transcript.
public enum size_t maxGoalLength = 4000;

/// Goal continuation shares the task's validated input boundary. Prose can
/// quote instructions, describe future setup, or ask an unnecessary question;
/// none of those is evidence that authorized work requires user input.
public bool goalNeedsHumanInput(const ref ChatSession session)
{
    import auroraopencode.taskcontinuation : taskAwaitingInput;
    return session.goal.length > 0 && session.goalStatus == "active" &&
        taskAwaitingInput(session);
}

/// Automatic first-message goals are an opt-in convenience. Ordinary tasks
/// retain their own plan and continuation; /goal creates an explicit persistent objective.
public bool automaticGoalRequest(string text)
{
    return text.strip().length > 0;
}

/// A goal is proved by its reply only when it asks a question or records a
/// note. A goal phrased as an outcome ("Let's ensure 60 fps", "Perfectly
/// placed elements") is conversation-shaped prose, not an answer: treating it
/// as answer-only let goal_complete accept a bare summary with no evidence and
/// close the goal before any work, while the turn policy still treated the
/// same goal as action work.
public bool goalIsAnswerOnly(string goal)
{
    const intent = requestIntent(goal);
    if (answerOnlyRequest(goal) || intent == RequestIntent.analysis ||
        intent == RequestIntent.diagnosis) return true;
    const text = goal.strip.toLower;
    foreach (prefix; ["remember ", "note ", "keep in mind ", "bear in mind ",
            "keep this ", "acknowledge ", "reply with ", "just say ", "just reply ",
            "say exactly "])
        if (text.startsWith(prefix)) return true;
    return false;
}

/// The reply the user asked for is already delivered on the active branch, so an
/// answer-shaped goal is finished rather than interrupted. A tool-call turn or a
/// failed reply is not a delivered answer.
public bool goalAnswerDelivered(const ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "assistant")
            return !message.failed && !message.toolCalls.length &&
                message.content.strip.length > 0;
        if (message.role == "tool") return false;
        if (message.role == "user" && !message.internal) return false;
    }
    return false;
}

/// Goals whose completion is the reply itself must not acquire automatic work
/// turns. The continuation and completion rules must use the same set: a goal
/// that is not answer-only keeps working until goal_complete proves the result.
public bool goalIsAnswerTurn(string goal)
{
    return goalIsAnswerOnly(goal);
}

/// Bound the goal by characters without splitting a UTF-8 sequence.
public string clampGoalText(string text)
{
    const units = toUTF32(text);
    return units.length <= maxGoalLength ? text : toUTF8(units[0 .. maxGoalLength]);
}

/// Record the current goal text whenever it is created or changed. Re-setting
/// the same live goal only refreshes its outcome; a previously completed or
/// cleared goal with the same text is a new history entry.
public void recordGoalSet(ref ChatSession session, long at)
{
    if (!session.goal.length) return;
    auto history = session.goalHistory;
    if (history.length)
    {
        auto last = history[$ - 1];
        if (last.text == session.goal &&
            (last.outcome == "active" || last.outcome == "paused" ||
             last.outcome.length == 0))
        {
            last.outcome = session.goalStatus.length
                ? session.goalStatus : "active";
            last.closedAt = 0;
            history[$ - 1] = last;
            session.goalHistory = history;
            return;
        }
        if (last.outcome == "active" || last.outcome == "paused" ||
            last.outcome.length == 0)
        {
            last.outcome = "replaced";
            last.closedAt = at;
            history[$ - 1] = last;
        }
    }
    history ~= GoalHistoryEntry(session.goal, session.goalStatus.length
        ? session.goalStatus : "active", at, 0);
    session.goalHistory = history;
}

/// Update the outcome of the latest goal record, seeding it when restoring a
/// conversation saved before goal history existed.
public void recordGoalOutcome(ref ChatSession session, string outcome, long at)
{
    if (!session.goal.length) return;
    auto history = session.goalHistory;
    if (!history.length || history[$ - 1].text != session.goal)
    {
        recordGoalSet(session, session.goalStartedAt > 0
            ? session.goalStartedAt : at);
        history = session.goalHistory;
    }
    if (!history.length) return;
    auto last = history[$ - 1];
    last.outcome = outcome;
    const terminal = outcome == "completed" || outcome == "cleared" ||
        outcome == "replaced";
    if (terminal)
    {
        if (last.closedAt == 0) last.closedAt = at;
    }
    else
        last.closedAt = 0;
    history[$ - 1] = last;
    session.goalHistory = history;
}

/// Backfill history for a goal restored from an older build.
public void syncGoalHistory(ref ChatSession session, long at)
{
    if (!session.goal.length) return;
    if (!session.goalHistory.length ||
        session.goalHistory[$ - 1].text != session.goal)
    {
        recordGoalSet(session, session.goalStartedAt > 0
            ? session.goalStartedAt : at);
        return;
    }
    recordGoalOutcome(session, session.goalStatus.length
        ? session.goalStatus : "active", at);
}

public enum GoalCommandKind
{
    none,
    show,
    set,
    pause,
    resume,
    clear,
}

public struct GoalCommand
{
    GoalCommandKind kind;
    string text;
}

/// Parse `/goal` and its Codex-compatible control variants. A command must be
/// the whole composer text; ordinary prose that merely mentions a goal remains
/// a normal message.
public GoalCommand parseGoalCommand(string input)
{
    const text = input.strip();
    if (!(text == "/goal" || text.startsWith("/goal "))) return GoalCommand.init;
    const argument = text.length > 5 ? text[5 .. $].strip() : "";
    if (argument.length == 0) return GoalCommand(GoalCommandKind.show);
    switch (argument.toLower())
    {
        case "status":
            return GoalCommand(GoalCommandKind.show);
        case "pause":
        case "stop":
        case "off":
            return GoalCommand(GoalCommandKind.pause);
        case "resume":
        case "start":
        case "unpause":
            return GoalCommand(GoalCommandKind.resume);
        case "clear":
        case "cancel":
        case "none":
        case "reset":
            return GoalCommand(GoalCommandKind.clear);
        default:
            return GoalCommand(GoalCommandKind.set, argument);
    }
}

public bool goalActive(const ref ChatSession session)
{
    return session.goal.length > 0 && session.goalStatus == "active";
}

/// Every durable outcome a goal still owns. A goal is never finished while a
/// recorded plan step, nested plan, work item or required check is open. A
/// deferred item is open work, not completion: the goal contract does not allow
/// parking work for a later turn.
public bool goalOutstandingWork(const ref ChatSession session)
{
    foreach (step; session.taskSteps)
        if (step.status != "completed") return true;
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed") return true;
    foreach (item; session.contract.workItems)
        if (item.step.status != "completed") return true;
    return session.verificationStatus == "required" ||
        session.verificationStatus == "failed";
}

/// The goal block is dynamic request context, deliberately outside the cached
/// system prompt. Paused and completed goals stay visible to the model for
/// continuity but never drive an automatic turn.
public string goalPromptBlock(const ref ChatSession session)
{
    if (session.goal.length == 0) return "";
    const status = session.goalStatus.length ? session.goalStatus : "active";
    auto output = appender!string();
    output.put("\n\n# Persistent goal\n");
    output.put("Status: " ~ status ~ "\n");
    output.put("Goal: " ~ session.goal ~ "\n");
    output.put("Later user-supplied facts and corrections supersede outdated assumptions in the original goal wording. " ~
        "Use those supplied values; do not ask the user to confirm an already supplied fact.\n");
    switch (status)
    {
        case "active":
            output.put("This goal is a standing work contract, not a chat topic. It is complete only when the " ~
                "requested outcome exists and every recorded outcome, plan step, work item and required check is finished. " ~
                "Never mark it complete while anything remains, is deferred, postponed or left for later. " ~
                "The goal is not complete until all of it is complete. " ~
                "Work through every plan: finish planned outcomes, close discovered work, and resolve blockers with the available tools. " ~
                "No part of this work may be put on hold while the goal is active: after each result, continue with the next real action. " ~
                "Do not stop to hand the goal back, replace action with a summary, or wait for the app to prompt you again. " ~
                "Testing is ordinary authorized work. Verifying a change never requires the user to bring a window to the " ~
                "foreground, focus it, click it or be present: use the app's programmatic checks, a detached or background run, " ~
                "or the available computer-use tools. Never stop or ask for that. " ~
                "Decide routine implementation, testing, tool, file and design choices yourself. " ~
                "If a genuinely user-owned fact is missing, finish the independent work, continue with the best supported " ~
                "default, record the assumption once with request_input, and keep the goal running. " ~
                "Call goal_complete with a concise summary and accepted toolCallId evidence only when everything is done; " ~
                "an answer-only goal needs no receipt. Its validator refuses pending, deferred or unverified items. " ~
                "Never call goal_complete to record a failure, a blocker or a failed audit. " ~
                "Don't add hypothetical future work or repeat passing checks for completion bookkeeping.\n");
            break;
        case "paused":
            // The user paused this goal; the app never pauses it on the model's
            // behalf. This state is not evidence that the user stopped the
            // current request. Telling the model
            // "the user paused this goal" made it refuse the next request
            // ("the goal is paused, so I'm not running another test or
            // changing the build") while the task state still recorded an
            // active deliverable. The pause withholds self-started goal turns
            // only; the user's current message still owns this turn.
            output.put("The goal's automatic continuation is paused; its recorded work waits for " ~
                "the user to press Start. The pause stops self-started goal turns only. " ~
                "It is not a stop of the user's current message: answer it, investigate with " ~
                "the available tools, and finish every outcome it asks for. Never use the paused " ~
                "goal, its checklist or its required verification as a reason to refuse, defer " ~
                "or narrow that work. Do not carry the paused goal's remaining work into a later " ~
                "turn by calling it deferred: finish it now or state the exact unresolved outcome.\n");
            break;
        case "completed":
            output.put("This goal was completed. Do not resume it unless the user edits " ~
                "or starts it again.\n");
            break;
        default:
            output.put("This goal is not active. Do not continue it automatically.\n");
            break;
    }
    return output.data;
}

/// Text appended as a hidden user turn when an active goal needs another turn.
public string goalContinuationInstruction(const ref ChatSession session)
{
    const answerGoal = goalIsAnswerOnly(session.goal);
    return "Persistent goal continuation: " ~ session.goal ~ "\n" ~
        "The goal stays active until the requested outcome is complete or the user pauses it. " ~
        "Continue from the recorded work and current evidence. Do work rather than " ~
        "restating the goal. Finish every recorded outcome, plan step and required check; " ~
        "nothing may be deferred, postponed or left for later, and no part of the work may be put on hold. " ~
        "If the plan only covers a local symptom, widen it to the " ~
        "general cause and the whole objective before the next action; generalize the " ~
        "fix and its checks rather than patching one instance. Reconcile update_plan with the remaining work before " ~
        "continuing, explaining any changed path. Testing never requires the user to bring a window " ~
        "to the foreground, focus it, click it or be present; use programmatic checks, a detached or " ~
        "background run, or the available computer-use tools. Do not stop for a test, a window, " ~
        "a routine tool, file or design choice. If the goal is now demonstrably complete, call " ~
        "`goal_complete` with a concise summary" ~
        (answerGoal
            ? "; no tool receipt is required for this answer goal. Otherwise keep "
            : " and concrete evidence; otherwise keep ") ~
        "advancing the unfinished outcomes. Do not close the goal as a failure: an audit that " ~
        "finds the outcome unmet, blocked or not achieved means more work, not completion. Do not stop " ~
        "the goal for a question: decide routine implementation, testing and design choices yourself. " ~
        "If a genuinely user-owned fact is missing, record it once with request_input and continue with " ~
        "the best supported default; the app keeps the goal running until it is complete. " ~
        "Do not repeat completed work just to avoid this boundary. " ~
        "The user can pause this goal at any time.";
}

/// Text appended after a goal continuation that replied with prose only. The
/// app never pauses the goal on the agent's behalf; it spends the next turn on a
/// concrete action or an explicit completion instead. There is no stop after a
/// fixed number of attempts: the work is never parked while the goal is active.
public enum goalAuditRecoveryInstruction = " The previous goal continuation " ~
    "replied with prose only and took no action. Do not restate the goal, the " ~
    "summary, or the remaining work. Take one concrete action with the " ~
    "available tools and report what actually changed. If the goal is " ~
    "demonstrably complete, call `goal_complete` with a concise summary and " ~
    "accepted evidence: that tool is offered in this request, so never answer " ~
    "that it is unavailable and never ask the user to pause or stop the goal. " ~
    "Do not stop for a question: decide routine choices yourself and continue " ~
    "with the best supported default. Testing never requires the user to bring a " ~
    "window to the foreground. The app keeps this goal active until it is " ~
    "validated complete or the user pauses it.";

/// Directive for a goal that keeps replying without a useful action. The app
/// never pauses or completes the user's goal on the model's behalf, so the
/// strategy changes and the goal keeps running. `round` is the number of
/// recovery turns already spent on this stall.
public string goalStallInstruction(const ref ChatSession session, int round)
{
    if (round < 2) return goalAuditRecoveryInstruction;
    if (round < 4)
        return " Progress audit: this goal turn again produced no useful action. " ~
            "Restating or summarizing the work is not progress, and the app will not " ~
            "pause or complete the goal for you. Either call `goal_complete` with " ~
            "validated evidence for the whole goal, or make one concrete tool call that " ~
            "advances the smallest open outcome. If the current route is blocked, change " ~
            "route: a different tool, file, command or smaller verifiable step. Reduce the " ~
            "next step until it can be finished and verified now. Never answer that " ~
            "completion is impossible and never ask the user to pause the goal. Testing " ~
            "never requires the user to bring a window to the foreground.";
    return " Progress audit after repeated turns without an action: act now on the " ~
        "smallest unfinished outcome. Use the tools this request offers, including " ~
        "`goal_complete` when the whole goal is genuinely finished; its validator names " ~
        "the exact remaining item when it is not. If a tool is failing, read its error and " ~
        "use a different one. Nothing may be deferred or left for a later turn, and the " ~
        "goal stays active until it validates complete or the user pauses it.";
}

/// Added to ordinary execution recovery while an active goal still owns
/// unresolved outcomes. The shared attempt budget bounds provider retries, not
/// the user's goal: the decision keeps requesting work instead of settling.
public string goalExecutionEscalation(const ref ChatSession session, int attempts)
{
    if (attempts < 2) return "";
    return " Persistent goal recovery: the same unresolved outcome has now failed " ~
        "repeated completion attempts. Do not end this turn with a summary and do not " ~
        "defer any part of the work. Change the approach, take the smallest concrete " ~
        "action that advances the open outcome, and verify it on the actual execution " ~
        "path. Testing never requires the user to bring a window to the foreground. " ~
        "The goal stays active until every outcome is finished and validated.";
}

/// Added when the agent asked for input inside an active goal. The request
/// stays in the transcript as recorded context, but a goal chat never settles
/// into "waiting for information": the next turn acts on the best evidence.
public enum goalInputContinuesInstruction = " The previous goal turn requested user input. " ~
    "This goal does not stop for a question: keep the request in context, do not repeat it, " ~
    "and take the next concrete action with the available tools. Decide routine " ~
    "implementation, testing and design questions yourself from the local evidence. " ~
    "If the missing fact is genuinely user-owned, proceed with the best supported default, " ~
    "state that assumption in the result, and keep advancing the unfinished outcomes. " ~
    "Call `goal_complete` only once the requested outcome and its checks are complete.";

/// Retained for reading and retiring control history from older builds.
public enum goalCompletionAuditMarker = "Persistent goal completion audit:\n";

/// Labels a completion answer uses to declare work it has not finished. Only an
/// explicit label counts: discussing a limitation of the code is not a claim
/// that the goal still has an unaddressed outcome.
private enum unfinishedWorkLabels = [
    "remaining work", "remaining limitations", "remaining issues",
    "known limitations", "known issues", "outstanding work", "unfinished work",
    "deferred", "deferred work", "deferred items", "deferred tasks",
    "postponed", "postponed work", "future work", "pending work",
    "open items", "known gaps", "unresolved work", "unfinished items",
    "next steps", "follow-ups", "follow ups", "followup", "followups",
    "follow-up", "follow up", "limitations", "limitation",
    "remaining", "outstanding", "unfinished", "not done", "todo", "to-do",
];

private bool statesNoOutstandingWork(string body)
{
    auto text = body.strip.toLower;
    while (text.length && ",.;:!-".indexOf(text[$ - 1]) >= 0)
        text = text[0 .. $ - 1].strip;
    if (!text.length) return true;
    foreach (negative; ["none", "nothing", "n/a", "na", "not applicable",
            "no further work", "no remaining work", "no known issues",
            "no known limitations", "no outstanding work", "no limitations",
            "no follow-up", "no follow-ups", "no open work",
            "none deferred", "nothing deferred", "no deferred work",
            "no pending work", "no open items", "no known gaps",
            "all done", "all complete", "all addressed",
            "complete", "completed", "done", "resolved", "none recorded",
            "none remaining"])
        if (text == negative) return true;
    foreach (negative; ["none ", "none;", "none,", "nothing ",
            "no further ", "no remaining ", "no known ", "not applicable"])
        if (text.startsWith(negative)) return true;
    return false;
}

/// The completion summary or final answer can describe work as still
/// outstanding. Completing then records a goal the agent itself says is not
/// finished, so this returns that declaration for a refusal.
private string declaredUnfinishedWork(string text)
{
    string label, body, fence;
    bool found;
    string declared;
    foreach (raw; text.splitLines())
    {
        auto line = raw.strip;
        if (line.startsWith("```") || line.startsWith("~~~"))
        {
            if (!fence.length) fence = line[0 .. 3];
            else if (line.startsWith(fence)) fence = "";
            continue;
        }
        if (fence.length || line.startsWith(">")) continue;
        line = line.replace("**", "");
        while (line.length && "#*-_+ ".indexOf(line[0]) >= 0)
            line = line[1 .. $].strip;
        size_t digits;
        while (digits < line.length && line[digits] >= '0' && line[digits] <= '9') ++digits;
        if (digits && digits + 1 < line.length &&
            (line[digits] == '.' || line[digits] == ')') && line[digits + 1] == ' ')
            line = line[digits + 2 .. $].strip;
        const lower = line.toLower;
        string matched;
        foreach (name; unfinishedWorkLabels)
            if (lower == name || lower.startsWith(name ~ ":"))
            {
                matched = name;
                break;
            }
        if (matched.length)
        {
            if (label.length && !statesNoOutstandingWork(body))
            {
                declared = label ~ ": " ~ body.strip;
                found = true;
                break;
            }
            label = matched;
            body = lower.length > matched.length ? line[matched.length + 1 .. $] : "";
            continue;
        }
        if (label.length && line.length)
            body ~= (body.length ? " " : "") ~ line;
    }
    if (!found && label.length && !statesNoOutstandingWork(body))
        declared = label ~ ": " ~ body.strip;
    if (!declared.length) return "";
    import auroraopencode.taskcontext : taskExcerpt;
    return taskExcerpt(declared.replace("\n", " ").replace("\r", " "), 180);
}

/// Completion prose that still reports work as deferred, postponed or not yet
/// implemented. A goal may not close while its own final answer says part of it
/// waits for later.
private bool declaresDeferredWork(string text)
{
    const plain = text.toLower.replace("*", "").replace("_", " ").splitLines.join(" ");
    enum pattern =
        `\b(?:is|are|remains?|stays?|left|kept|still) (?:currently |still )?(?:deferred|postponed|shelved|on hold)\b|` ~
        `\b(?:deferred|postponed|shelved) (?:to|until|for) (?:a |the )?(?:later|next|future|follow-up|follow up)\b|` ~
        `\b(?:left|kept|put|held) (?:for|to|until) later\b|` ~
        `\bnot (?:yet )?(?:implemented|done|addressed|verified)\b|` ~
        `\b(?:future work|pending work|deferred work|unresolved work)\b`;
    foreach (found; matchAll(plain, regex(pattern)))
    {
        // "Nothing was deferred to a later turn" is a completion statement, not
        // a declaration of remaining work.
        const start = found.pre.length;
        const before = start > 40 ? plain[start - 40 .. start] : plain[0 .. start];
        if (matchFirst(before, regex(`\b(?:not|never|no|nothing|without|none)\b`)).length)
            continue;
        return true;
    }
    return false;
}

/// A completion summary that reports the requested outcome as unmet is not a
/// completion. `goal_complete` is the only way to stop automatic continuation,
/// so accepting "closed as a critical failure" let an unfinished goal end
/// without the user's cooperation. Match only wording that asserts the current
/// result, not a description of a defect that was fixed.
private bool declaresUnmetGoal(string summary)
{
    const text = summary.toLower.replace("*", "").replace("_", " ").splitLines.join(" ");
    enum pattern =
        `\bgoal (?:is|was|remains|remained|has been|is still) (?:unmet|incomplete|not (?:met|achieved|complete|completed|satisfied|fulfilled))\b|` ~
        `\b(?:is|was|remains|remained|found|recorded as|closed as) (?:still )?(?:unmet|incomplete)\b|` ~
        `\b(?:is|are|was|were|has|have) (?:still )?not (?:been )?(?:achieved|met|satisfied|fulfilled|completed?)\b|` ~
        `\b(?:does not|did not|doesn't|didn't) meet\b|` ~
        `\b(?:fails?|failed) (?:the )?acceptance\b|\bacceptance (?:still )?(?:fails?|failed)\b|` ~
        `\b(?:recorded as|closed as|remains|remained|result is|result remains) (?:a |the )?(?:total |critical )?failure\b|` ~
        `\bnot an? (?:[\w.-]+ ){0,3}success\b`;
    return matchFirst(text, regex(pattern)).length > 0;
}

/// The final prose answer at the end of the current no-action interval. Once a
/// tool has produced a result, the plan and its receipts decide completion;
/// stale prose from before that work must not veto it.
private string currentAnswerProse(const ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "tool") break;
        if (message.role == "assistant" && message.failed) break;
        if (message.role == "user" && !message.internal) break;
        if (message.role == "assistant" && !message.internal &&
            !message.toolCalls.length && message.content.strip.length)
            return message.content;
    }
    return "";
}

/// Validate a model's `goal_complete` request. Completion is refused while the
/// user's goal is paused/completed, while verification is outstanding, or while
/// the durable checklist still has unfinished outcomes.
/// Evidence that only records inspection or planning does not prove an outcome
/// goal. A goal phrased as a result ("ensure", "bring", "perfectly placed")
/// needs a change, an action or a passing check; otherwise the model can close
/// it after reading a file and the goal bar reports completion before any work.
private bool goalWorkProven(const ref ChatSession session, const string[] ids)
{
    import auroraopencode.taskflow : taskEvidenceIndex;
    const index = taskEvidenceIndex(session);
    foreach (id; ids)
    {
        auto proof = id in index;
        if (proof is null) continue;
        const kind = *proof;
        if (kind == "edit" || kind == "action" ||
            kind.startsWith("verify|") || kind.startsWith("verify-current|"))
            return true;
    }
    return false;
}

public string goalCompletionError(const ref ChatSession session, string arguments)
{
    if (session.goal.length == 0) return "There is no persistent goal to complete.";
    if (session.goalStatus != "active")
        return "The persistent goal is " ~
            (session.goalStatus.length ? session.goalStatus : "not active") ~
            "; it cannot be completed from this turn.";
    JSONValue value;
    try value = parseJSON(arguments);
    catch (Exception) return "goal_complete requires valid JSON. Continue the goal with tools.";
    if (value.type != JSONType.object) return "goal_complete requires a JSON object.";
    string field(string key)
    {
        if (auto found = key in value.object)
            if (found.type == JSONType.string) return found.str.strip();
        return "";
    }
    if (!field("summary").length)
        return "goal_complete requires a concise summary of the verified result.";
    const answerGoal = goalIsAnswerOnly(session.goal);
    // A summary that reports the requested outcome as unmet cannot complete
    // the goal, whatever receipts or checklist state the turn has. Automatic
    // continuation stops only through goal_complete, so accepting this wording
    // ended an unfinished goal without the user's cooperation.
    if (!answerGoal && declaresUnmetGoal(field("summary")))
        return "goal_complete cannot close a goal whose summary reports the requested outcome as unmet or failed. " ~
            "The persistent goal remains active. Do work on the unfinished outcome with the available tools; " ~
            "an audit that finds the goal unmet is a result to act on, not completion. " ~
            "Call goal_complete only once the requested outcome is achieved and its checks pass. " ~
            "If an essential user-owned fact prevents completion, call request_input with that fact and blocked_steps.";
    // Report remaining work before asking the model to repair receipt IDs.
    // Otherwise an already-finished archive sent the agent through thirteen
    // history lookups only to discover it still needed an accepted check.
    if (session.verificationStatus == "required" || session.verificationStatus == "failed")
        return "Verification is still outstanding. Call verify with inline inputs naming the actual deliverables " ~
            "and steps running the relevant check. A custom run may succeed without an accepted receipt. " ~
            "Use the accepted toolCallId in goal_complete. No saved recipe, extra framework or history search is required.";
    // An answer-only goal is proved by the answer itself. Action goals still
    // need real receipts so prose cannot stand in for completed work.
    if (!answerGoal)
    {
        auto evidence = "evidence" in value.object;
        if (evidence is null || evidence.type != JSONType.array || !evidence.array.length)
            return "goal_complete requires concrete evidence: successful tool-call IDs or check receipts.";
        import auroraopencode.taskflow : taskEvidenceIndex;
        const recorded = taskEvidenceIndex(session, false);
        size_t usable;
        string[] cited;
        foreach (entry; evidence.array)
        {
            if (entry.type != JSONType.string || !entry.str.strip().length)
                return "goal_complete evidence must contain successful recorded tool-call IDs.";
            const id = entry.str.strip();
            if ((id in recorded) is null)
                return "goal_complete evidence '" ~ id ~ "' is not a successful recorded result on the active task. " ~
                    "Use the toolCallId from the actual result; do not invent a receipt.";
            ++usable;
            cited ~= id;
        }
        if (!usable) return "goal_complete evidence must contain non-empty tool-call IDs or check receipts.";
        if (!goalWorkProven(session, cited))
            return "goal_complete evidence only records inspection or planning, not the goal's deliverable. " ~
                "This goal asks for an outcome, so make the change, take the action or run the check it requires " ~
                "and cite that result. A summary of intended work does not complete it.";
    }
    else if (auto evidence = "evidence" in value.object)
        if (evidence.type != JSONType.array)
            return "goal_complete evidence must be an array of tool-call IDs.";
    foreach (step; session.taskSteps)
        if (step.status != "completed")
            return "The checklist still has unfinished outcomes. Finish them or update the plan, then call goal_complete.";
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed")
                return "A nested plan still has unfinished steps. Finish them before completing the goal.";
    foreach (item; session.contract.workItems)
        if (item.step.status != "completed")
        {
            import auroraopencode.taskcontext : taskExcerpt;
            const label = taskExcerpt(item.step.text, 120);
            if (item.step.status == "deferred")
                return "A work item is deferred (" ~ label ~ "). A deferred item is unfinished work: " ~
                    "complete it and record its evidence before calling goal_complete. " ~
                    "The persistent goal never completes with deferred work.";
            return "Work remains open (" ~ label ~ "). Finish it before completing the goal.";
        }
    if (!answerGoal)
    {
        if (declaresDeferredWork(field("summary") ~ "\n" ~ currentAnswerProse(session)))
            return "goal_complete cannot complete a goal whose summary or answer leaves work " ~
                "deferred, postponed or not yet implemented. Finish that work with tools and " ~
                "verify it, then call goal_complete again. The persistent goal never completes " ~
                "with deferred work.";
        string declared = declaredUnfinishedWork(field("summary"));
        if (!declared.length)
            declared = declaredUnfinishedWork(currentAnswerProse(session));
        if (declared.length)
            return "goal_complete still names unresolved work (" ~ declared ~ "). " ~
                "Finish it with tools or record it as an outcome with update_plan and " ~
                "complete it with evidence, then call goal_complete again.";
    }
    return "";
}

module auroraopencode.taskcontinuation;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.taskcontext : taskExcerpt;
import auroraopencode.requestintent : RequestIntent, actionApprovalRequest, answerOnlyRequest,
    permissionQuestionReply, requestIntent;
import auroraopencode.taskflow : supportedStep, taskHasActionEvidence, taskEvidenceIndex, taskRequiresPlan, taskInvestigation, missingVerificationInput;
import auroraopencode.workevidence : observedResultKey;
import auroraopencode.planmode : experimentalStrictPlanEnabled;
import auroraopencode.inputcontract : inputRequestStep;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf, strip, toLower, split, join;
import std.regex : matchFirst;

enum taskContinuationMarker = "Continuation: unfinished authorized work\n";
enum taskStallLimit = 3;

enum TaskContinuationAction { settle, continueWork, replan }

struct TaskContinuation
{
    TaskContinuationAction action;
    int tools;
    int effects;
    int completed;
    bool verified;
    int stalled;
    int replans;
    int verificationAttempts;
    string[] evidence;
    bool verificationRequired;
    string remaining;

    string guidance() const
    {
        JSONValue state;
        state["tools"] = tools;
        state["effects"] = effects;
        state["completed"] = completed;
        state["verified"] = verified;
        state["stalled"] = action == TaskContinuationAction.replan ? 0 : stalled;
        state["replans"] = replans + (action == TaskContinuationAction.replan ? 1 : 0);
        state["verificationAttempts"] = verificationAttempts;
        state["evidence"] = JSONValue(evidence);
        if (action == TaskContinuationAction.replan)
            return taskContinuationMarker ~ state.toString() ~ "\n" ~
                "No planned step advanced. Change the diagnosis: compare expected behavior with the " ~
                "recorded failure, reject the unsupported hypothesis, and test a smaller case or different source. " ~
                "Record the revised plan with update_plan, explaining what changed and preserving completed outcomes. " ~
                "Do useful tool work now; do not answer or ask permission. " ~
                remaining ~ verificationGuidance();
        return taskContinuationMarker ~ state.toString() ~ "\n" ~
            "Follow the plan: finish the specific unfinished planned outcomes below with tools. Use existing successful evidence; " ~
            "do not repeat passing checks without a new reason or ask permission to continue. " ~
            "Answer only when the planned outcomes and required checks are complete. " ~
            remaining ~ verificationGuidance();
    }

    private string verificationGuidance() const
    {
        return verificationRequired
            ? "Verify the current requested behavior using the relevant execution path and acceptance checks. " ~
              "Reuse checks that are still current. Changed or deleted tracked inputs are a new reason to run the relevant check once."
            : "Use request_input only for an essential unavailable user fact, after finishing independent work.";
    }
}

bool unfinishedTask(const ref ChatSession session, bool strictPlan = experimentalStrictPlanEnabled())
{
    auto evidenceIndex = taskEvidenceIndex(session, false);
    foreach (step; session.taskSteps)
        if (step.status != "completed" ||
            (session.contract.id.length && !supportedStep(session, step, evidenceIndex))) return true;
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed" ||
                (session.contract.id.length && !supportedStep(session, step, evidenceIndex))) return true;
    foreach (item; session.contract.workItems)
        if (item.required && (item.step.status != "completed" ||
            (session.contract.id.length && !supportedStep(session, item.step, evidenceIndex)))) return true;
    const workIntent = session.contract.currentIntent == "implementation" ||
        session.contract.currentIntent == "continuation" ||
        (session.contract.currentIntent == "diagnosis" &&
            session.contract.intent == "implementation");
    if (session.contract.id.length && session.taskSteps.length == 0 && workIntent &&
        (!taskHasActionEvidence(session) || taskRequiresPlan(session, strictPlan))) return true;
    return session.verificationStatus == "required" ||
        session.verificationStatus == "failed";
}

/// True when every outcome is complete and the only outstanding requirement is
/// a verification receipt. Repeated receipt churn triggers a new diagnosis.
private bool verificationOnly(const ref ChatSession session)
{
    auto evidenceIndex = taskEvidenceIndex(session, false);
    const requireEvidence = session.contract.id.length > 0;
    foreach (step; session.taskSteps)
        if (step.status != "completed" ||
            (requireEvidence && !supportedStep(session, step, evidenceIndex)))
            return false;
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps)
            if (step.status != "completed" ||
                (requireEvidence && !supportedStep(session, step, evidenceIndex)))
                return false;
    foreach (item; session.contract.workItems)
        if (item.required && (item.step.status != "completed" ||
            (requireEvidence && !supportedStep(session, item.step, evidenceIndex))))
            return false;
    return session.verificationStatus == "required" ||
        session.verificationStatus == "failed";
}

/// Derive recovery checkpoints from the selected, durable branch. Prose, failed
/// calls, novel searches and plan rewrites cannot reset it. Completed outcomes
/// and accepted verification can. Stalls change diagnosis; they never exhaust
/// the authorization to complete the task.
TaskContinuation taskContinuation(const ref ChatSession session, bool toolsEnabled,
    bool strictPlan = experimentalStrictPlanEnabled())
{
    TaskContinuation result;
    // A queued follow-up never ends authorized work early: the turn keeps
    // following unfinished plan steps and the queue opens only once the agent
    // has actually stopped (see the turn settlement dispatch sites).
    if (!toolsEnabled || taskAwaitingInput(session) || taskInvestigation(session) ||
        (session.contract.currentIntent == "analysis" && verificationOnly(session)) ||
        !unfinishedTask(session, strictPlan)) return result;
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
    if (!request.length || answerOnlyRequest(request) ||
        (requestIntent(request) == RequestIntent.conversation &&
         session.contract.currentIntent != "continuation" &&
         !actionApprovalRequest(request))) return result;

    JSONValue previous;
    int previousVerificationAttempts;
    bool[string] evidence, effects;
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
                if (snapshot.type == JSONType.object)
                    if (auto value = "verificationAttempts" in snapshot.object)
                        if (value.type == JSONType.integer)
                            previousVerificationAttempts = cast(int) value.integer;
            }
            catch (Exception) {}
        }
        if (message.role != "tool" || message.failed ||
            message.toolName == "update_plan" || message.toolName == "update_subplan" ||
            message.toolName == "goal_complete" ||
            message.toolName == "task_blocker" || message.toolName == "request_input" || message.toolName == "process" ||
            message.toolName == "assign" || message.toolName == "ask_user" ||
            message.toolName == "finish") continue;
        if (message.toolName == "dshell" &&
            (message.toolArgs.indexOf("\"sleep\"") >= 0 ||
             message.toolArgs.indexOf("\"wait\"") >= 0)) continue;
        const key = observedResultKey(message);
        if (key.length)
        {
            evidence[key] = true;
            import auroraopencode.toolprogresspolicy : isSubstantiveMutation;
            if (message.verificationCheck.length || isSubstantiveMutation(message.toolName,
                message.failed, message.diffAdditions, message.diffDeletions, message.toolDiff)) effects[key] = true;
        }
    }
    result.tools = cast(int) evidence.length;
    result.effects = cast(int) effects.length;
    bool[string] completedEvidence;
    auto evidenceIndex = taskEvidenceIndex(session, false);
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
    foreach (item; session.contract.workItems)
        if (item.required && supportedStep(session, item.step, evidenceIndex))
        {
            ++result.completed;
            foreach (id; item.step.evidence) completedEvidence[id] = true;
        }
    foreach (id; completedEvidence.keys) result.evidence ~= id;
    result.verified = session.verificationStatus == "passed";
    result.verificationRequired = session.verificationStatus == "required" || session.verificationStatus == "failed";
    const onlyVerification = verificationOnly(session);
    if (onlyVerification && result.verificationRequired && !result.verified)
        result.verificationAttempts = previousVerificationAttempts + 1;
    if (!session.taskSteps.length && taskRequiresPlan(session, strictPlan))
        result.remaining ~= "This task now requires an outcome checklist. Record the already requested outcomes " ~
            "with update_plan and cite successful tool-call IDs for completed work; do not invent extra work. ";
    const diagnosisContract = session.contract.intent == "diagnosis";
    if (result.verificationRequired)
    {
        const missing = missingVerificationInput(session);
        if (missing.length) result.remaining ~= "A tracked input to the last passing check is missing: " ~
            taskExcerpt(missing, 1000) ~ ". Restore the required deliverable/checker input and retain it through one final relevant check. ";
    }
    if (!taskHasActionEvidence(session, diagnosisContract) && session.contract.intent != "analysis")
        result.remaining ~= "Actual requested action evidence is missing. Perform it, or use a tracked behavioral check with no_change_needed when the requested outcome already holds. Compilation alone does not establish this. ";
    size_t omitted;
    void remaining(string label, string text, string done)
    {
        if (result.remaining.length < 1600)
            result.remaining ~= label ~ taskExcerpt(text, 320) ~ ". Acceptance: " ~ taskExcerpt(done, 320) ~ ". ";
        else ++omitted;
    }
    foreach (step; session.taskSteps)
        if (step.status != "completed" || !supportedStep(session, step, evidenceIndex))
            remaining("Remaining outcome: ", step.text, step.done);
    foreach (item; session.contract.workItems)
        if (item.required && (item.step.status != "completed" || !supportedStep(session, item.step, evidenceIndex)))
            remaining("Required action: ", item.step.text, item.step.done);
    if (omitted) result.remaining ~= "More required work remains saved; use read_plan details to recover its exact acceptance. ";
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
        int previousEffects;
        if (auto value = "effects" in previous.object)
            if (value.type == JSONType.integer) previousEffects = cast(int) value.integer;
        const progressed = result.effects > previousEffects || newEvidence || result.completed > previous["completed"].integer ||
            (result.verified && !previous["verified"].boolean);
        result.stalled = progressed ? 0 : cast(int) previous["stalled"].integer + 1;
        if (!progressed)
            if (auto value = "replans" in previous.object)
                if (value.type == JSONType.integer) result.replans = cast(int) value.integer;
    }
    result.action = result.stalled >= taskStallLimit
        ? TaskContinuationAction.replan
        : TaskContinuationAction.continueWork;
    return result;
}

string taskBlockerError(string arguments)
{
    try
    {
        const value = parseJSON(arguments);
        if (value.type != JSONType.object) return "request_input requires an object.";
        string field(string key)
        {
            if (auto found = key in value.object)
                if (found.type == JSONType.string) return found.str.strip();
            return "";
        }
        if (field("kind") == "external")
            return "Recover internally: inspect the dependency, try alternatives or wait for its result while completing independent work. External errors do not pause the task.";
        if (!field("reason").length || !field("question").length || !field("required_fact").length)
            return "request_input requires reason, question and the essential user-owned required_fact. Routine tool, testing and planning choices are yours to resolve.";
        const question = field("question").toLower().split().join(" ");
        foreach (phrase; ["may i ", "may we ", "can i ", "can we ", "should i ", "should we ",
                "shall i ", "shall we ", "would you like", "do you want", "permission", "say continue"])
            if (question.startsWith(phrase))
                return "Continue the authorized work. Do not ask permission for routine execution or verification.";
        const need = field("required_fact").toLower().split().join(" ");
        const context = (field("reason") ~ " " ~ need ~ " " ~ field("question")).toLower().split().join(" ");
        // Committing and publishing a completed delivery is authorized work,
        // not an essential missing fact. A dirty worktree is a delivery
        // constraint to handle or report, so do not let a permission question
        // leave the goal active but idle behind waiting_input.
        if (matchFirst(question, `\b(?:may|should|shall|can|could) (?:i|we) (?:also )?(?:commit|push|publish|merge|release|ship|deliver)\b`) ||
            matchFirst(need, `\bwhether\b.*\b(?:may|can|should|could)\b.*\b(?:commit|push|publish|merge|release|ship|deliver)\b`))
            return "Recover internally: committing and publishing this task's completed delivery is authorized work, not missing user information. Commit or publish only the work this task changed; if that is not possible, report the local-only limitation instead of pausing for permission. Do not commit unrelated work without authorization.";
        if (matchFirst(need, `\b(permission|approval|consent|whether i|whether we|may i|can i|allowed to|close .*window|close .*process)\b`) ||
            matchFirst(question, `\b(do you want me to|will you .*yourself|(?:may|should) i (?:close|stop|kill|run|test|continue)|permission to|say continue)\b`))
            return "Recover internally: this asks for permission for a routine workaround, not missing user information. Preserve the running application; build and test a unique output instead of closing its window.";
        if (matchFirst(context, `\b(?:which|what) (?:implementation |testing |test |verification |build |code |file |command |tool |library |language |design )?(?:approach|option|method|way|file|test|command|tool|library|language|design)\b`) ||
            matchFirst(need, `\b(?:preferred|routine|implementation|testing|test|verification|build|code) (?:approach|option|method|choice|file|test|command|tool|library|language|design)\b`))
            return "Choose a reasonable default and continue. Implementation, file, test, tool and verification choices are routine execution decisions, not missing user information.";
        if (matchFirst(context, `\b(locked|mapped image|file in use|sharing violation|link step|release link|permission denied|linker|running executable)\b`) &&
            matchFirst(context, `\b(build|compile|executable|window|process|output|\.exe)\b`))
            return "Recover internally: a locked build output is a technical obstacle. Use verify, which isolates locked compiler outputs, or choose a separate artifact path. Keep the user's application running and finish the task.";
        const checked = "checked" in value.object;
        if (checked is null || checked.type != JSONType.array || !checked.array.length)
            return "Inspect available sources and alternatives first; record them in checked.";
        foreach (entry; checked.array)
            if (entry.type != JSONType.string || !entry.str.strip().length)
                return "checked must contain the concrete sources or alternatives inspected.";
        const independent = "independent_work_complete" in value.object;
        if (independent is null || independent.type != JSONType.true_)
            return "Complete every independent outcome before requesting user input.";
        return "";
    }
    catch (Exception) { return "request_input requires valid JSON. Continue the task with available tools."; }
}


string taskInputError(const ref ChatSession session, string arguments)
{
    const error = taskBlockerError(arguments);
    if (error.length) return error;
    const value = parseJSON(arguments);
    string[] remaining;
    foreach (step; session.taskSteps) if (step.status != "completed" && !inputRequestStep(step)) remaining ~= step.id.length ? step.id : step.text;
    foreach (item; session.contract.workItems) if (item.required && item.step.status != "completed" && !inputRequestStep(item.step)) remaining ~= item.step.id;
    foreach (plan; session.nestedPlans) foreach (step; plan.steps) if (step.status != "completed" && !inputRequestStep(step)) remaining ~= step.id.length ? step.id : step.text;
    if (remaining.length > 1)
    {
        string[] blocked;
        if (auto ids = "blocked_steps" in value.object)
            if (ids.type == JSONType.array)
                foreach (id; ids.array) if (id.type == JSONType.string) blocked ~= id.str;
        import std.algorithm : canFind;
        foreach (id; remaining)
            if (!blocked.canFind(id)) return "Complete independent work first. Name only remaining outcome/action IDs that actually depend on the missing fact in blocked_steps; independent_work_complete alone cannot pause unfinished outcomes.";
    }
    return "";
}

bool taskAwaitingInput(const ref ChatSession session)
{
    if (session.taskStatus != "waiting_input") return false;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal)
        {
            if (answerOnlyRequest(message.content)) continue;
            return false;
        }
        if (message.role == "tool" && !message.failed &&
            (message.toolName == "request_input" || message.toolName == "task_blocker" || message.toolName == "ask_user"))
            return taskInputError(session, message.toolArgs).length == 0;
    }
    return false;
}



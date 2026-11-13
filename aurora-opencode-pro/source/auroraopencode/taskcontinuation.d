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
        return remaining;
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

/// Compatibility entry point. Execution decisions now use the shared outcome
/// ledger rather than parsing a succession of plan and audit checkpoints.
TaskContinuation taskContinuation(const ref ChatSession session, bool toolsEnabled,
    bool strictPlan = experimentalStrictPlanEnabled())
{
    import auroraopencode.executioncontrol : executionState, executionShouldContinue;
    TaskContinuation result;
    const state = executionState(session, strictPlan);
    if (!executionShouldContinue(session, toolsEnabled, state)) return result;
    result.action = state.attempts ? TaskContinuationAction.replan : TaskContinuationAction.continueWork;
    result.completed = state.completed;
    result.tools = state.tools;
    result.effects = state.effects;
    result.verified = state.verified;
    result.verificationRequired = state.verificationRequired;
    result.stalled = state.attempts;
    result.remaining = state.guidance();
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



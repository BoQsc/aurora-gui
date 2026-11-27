module auroraopencode.executioncontrol;

import auroraopencode.core : ChatMessage, ChatSession, activeMessagePath;
import auroraopencode.taskflow : executionDiagnosisMarker, taskEvidenceIndex, supportedStep,
    taskHasActionEvidence, missingVerificationInput;
import auroraopencode.taskcontext : taskExcerpt;
import auroraopencode.planmode : planModeBlockedTool, planModeProposalPending;
import auroraopencode.tools : diagnosticRefusalPrefix;
import std.algorithm : canFind, remove, sort;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : startsWith, indexOf, strip, toLower;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

enum executionRecoveryMarker = "Execution recovery: ";

/// Operations that legitimately keep a turn running. A busy turn with none of
/// these is a nonserious stall, not a slow provider: it must fail visibly
/// instead of waiting forever for an operation that no longer exists.
enum TurnOperation : uint
{
    none = 0,
    stopping = 1 << 0,
    provider = 1 << 1,
    compaction = 1 << 2,
    toolResult = 1 << 3,
    toolCall = 1 << 4,
    continuation = 1 << 5,
    storageEffect = 1 << 6,
    queuedEvent = 1 << 7,
    childAgent = 1 << 8,
    pausedContinuation = 1 << 9,
}

uint turnOwnedOperations(bool stopping, bool providerBusy, bool compacting,
    int pendingToolResults, size_t pendingToolCalls, bool continuationPending,
    bool storageEffectPending, bool queuedEvents, bool childPending,
    bool continuationPaused)
{
    uint result;
    if (stopping) result |= cast(uint) TurnOperation.stopping;
    if (providerBusy) result |= cast(uint) TurnOperation.provider;
    if (compacting) result |= cast(uint) TurnOperation.compaction;
    if (pendingToolResults > 0) result |= cast(uint) TurnOperation.toolResult;
    if (pendingToolCalls > 0) result |= cast(uint) TurnOperation.toolCall;
    if (continuationPending) result |= cast(uint) TurnOperation.continuation;
    if (storageEffectPending) result |= cast(uint) TurnOperation.storageEffect;
    if (queuedEvents) result |= cast(uint) TurnOperation.queuedEvent;
    if (childPending) result |= cast(uint) TurnOperation.childAgent;
    if (continuationPaused) result |= cast(uint) TurnOperation.pausedContinuation;
    return result;
}

bool turnOwnsOperation(uint operations) { return operations != 0; }

string turnOperationLabel(uint operations)
{
    if (operations == 0) return "none";
    string[] names;
    static immutable uint[] bits = [
        cast(uint) TurnOperation.stopping,
        cast(uint) TurnOperation.provider,
        cast(uint) TurnOperation.compaction,
        cast(uint) TurnOperation.toolResult,
        cast(uint) TurnOperation.toolCall,
        cast(uint) TurnOperation.continuation,
        cast(uint) TurnOperation.storageEffect,
        cast(uint) TurnOperation.queuedEvent,
        cast(uint) TurnOperation.childAgent,
        cast(uint) TurnOperation.pausedContinuation];
    static immutable string[] labels = [
        "stopping", "provider", "compaction", "tool-result", "tool-call",
        "continuation", "storage-effect", "queued-event", "child-agent",
        "paused-continuation"];
    foreach (i, operation; bits)
        if (operations & operation) names ~= labels[i];
    import std.array : join;
    return names.join(",");
}

/// A filesystem host fault is infrastructure, not evidence that the requested
/// outcome is wrong. The tool already replays a host that never delivered a
/// result, so a remaining timeout must not spend the completion-recovery budget
/// or turn a delivered answer into a substantive failure.
public bool transientToolFailure(const ref ChatMessage message)
{
    if (message.role != "tool" || !message.failed) return false;
    foreach (prefix; ["Error: filesystem tool timed out after ",
            "Error: filesystem tool host failed:",
            "Error: filesystem tool host exited with code ",
            "Error: filesystem tool hosts are at capacity"])
        if (message.content.startsWith(prefix)) return true;
    return false;
}

/// The read-only gate's refusal is the gate working, not an execution failure.
private bool diagnosticBlockedTool(const ref ChatMessage message)
{
    return message.role == "tool" && message.failed &&
        message.content.startsWith(diagnosticRefusalPrefix);
}

/// One outcome ledger for desktop and headless execution. Tool volume, novel
/// searches, edits and rewritten answers are deliberately not completion facts.
struct ExecutionState
{
    string fingerprint, remaining, failure;
    int completed, attempts, tools, effects;
    bool verificationRequired, verified, actionMissing, transientFailure;

    string guidance() const
    {
        JSONValue state;
        state["fingerprint"] = fingerprint;
        state["attempts"] = attempts + 1;
        const action = attempts ?
            "The previous completion attempt did not resolve an outcome. Reproduce the reported failure, test a different hypothesis, and resolve the specific gap below. " :
            "The requested work has an unresolved outcome. Complete the specific gap below. ";
        return executionRecoveryMarker ~ state.toString() ~ "\n" ~ action ~
            (failure.length ? "Observed obstacle: " ~ failure ~ "\n" : "") ~ remaining ~
            " Reuse current passing checks. A plan update is needed only when the actual work changes.";
    }
}

private struct FailedCheck
{
    string call, category;
    string[] commands;
    bool adHoc;
}

/// A successful checker whose inputs changed supplies no current proof. It is
/// not a failed behavior that must be rerun with the identical command forever:
/// current verification owns that obligation. Retain actual failed steps even
/// if a malformed report also claims its evidence was invalidated.
private bool invalidatedCheck(const ref ChatMessage message)
{
    if (!message.failed) return false;
    try
    {
        const report = parseJSON(message.content);
        if (report.type != JSONType.object) return false;
        const error = "error" in report.object;
        if (error is null || error.type != JSONType.string ||
            !["Source inputs or recipe changed during verification; results are stale.",
                "Reference changed during verification; results are stale."].canFind(error.str)) return false;
        const steps = "steps" in report.object;
        if (steps is null || steps.type != JSONType.array || !steps.array.length) return false;
        foreach (step; steps.array)
        {
            if (step.type != JSONType.object) return false;
            const passed = "passed" in step.object;
            if (passed is null || passed.type != JSONType.true_) return false;
        }
        return true;
    }
    catch (Exception) { return false; }
}

/// One behavioral obligation, whatever surface reported it. A checked `run`
/// labels a test command "python tests" while the `verify` tool labels the same
/// work "verify:tests"; comparing the raw labels meant a failure recorded by one
/// surface could never be cleared by a passing check from the other, so the task
/// kept demanding a rerun that had already happened.
public string checkCategory(string check)
{
    const lower = check.toLower;
    if (lower.canFind("interaction")) return "interaction";
    if (lower.canFind("render")) return "render";
    if (lower.canFind("test")) return "tests";
    if (lower.canFind("compile") || lower.canFind("build") || lower == "cargo check") return "compile";
    return lower;
}

/// The commands a check actually ran, normalized across the `run` and `verify`
/// surfaces. A failed recipe reports its failing step separately, while a later
/// successful rerun lists every step, so failures are matched by containment
/// rather than by whole-payload equality.
public string[] checkCommands(const ref ChatMessage message)
{
    string[] commands;
    void command(JSONValue value)
    {
        if (value.type != JSONType.object || !("program" in value.object)) return;
        string text;
        if (auto program = "program" in value.object) text ~= program.str;
        if (auto arguments = "args" in value.object)
        {
            auto args = *arguments;
            // Python's interpreter-only -B changes cache writes, not the test
            // being run. A retry that disables bytecode must resolve the same
            // failed checker; flags after the script/module remain significant.
            if (["python", "python.exe", "python3", "python3.exe"].canFind(text.toLower()) && args.type == JSONType.array)
            {
                JSONValue[] normalized;
                bool interpreter = true;
                foreach (argument; args.array)
                {
                    if (argument.type == JSONType.string)
                    {
                        if (interpreter && argument.str == "-B") continue;
                        if (!argument.str.startsWith("-") || argument.str == "-m" ||
                            argument.str == "-c" || argument.str == "--") interpreter = false;
                    }
                    normalized ~= argument;
                }
                args = JSONValue(normalized);
            }
            text ~= "\n" ~ args.toString();
        }
        if (text.length) commands ~= text;
    }
    void steps(JSONValue root, string key)
    {
        if (auto value = key in root.object)
            if (value.type == JSONType.object) command(*value);
        if (auto value = key in root.object)
            if (value.type == JSONType.array)
                foreach (step; value.array)
                    if (step.type == JSONType.object)
                        if (auto nested = "command" in step.object) command(*nested);
    }
    bool loaded;
    try
    {
        const report = parseJSON(message.content);
        if (report.type == JSONType.object)
        {
            loaded = true;
            if (message.failed) steps(report, "failedStep");
            if (!commands.length) steps(report, "steps");
        }
    }
    catch (Exception) {}
    if (!commands.length)
        try
        {
            const arguments = parseJSON(message.toolArgs);
            if (arguments.type == JSONType.object)
            {
                loaded = true;
                if (message.failed) steps(arguments, "failedStep");
                if (!commands.length) steps(arguments, "steps");
                if (!commands.length) command(arguments);
            }
        }
        catch (Exception) {}
    commands.sort();
    return loaded ? commands : null;
}

private bool reranCheck(string required, const(string)[] commands, bool revisionAllowed)
{
    import auroraopencode.checkrevision : retainsInlineCheckCoverage;
    foreach (command; commands)
        if (command == required || (revisionAllowed && retainsInlineCheckCoverage(required, command))) return true;
    return false;
}

ExecutionState executionState(const ref ChatSession session, bool strictPlan = false)
{
    ExecutionState state;
    auto proofs = taskEvidenceIndex(session, false);
    string facts;
    bool[string] completedProofs;
    bool[string] claimedProofs;
    void outcome(string id, string text, string done, bool complete, const(string)[] evidence)
    {
        if (complete)
        {
            // One receipt completes one outcome. A new outcome that only
            // reuses evidence an earlier outcome already claimed is not
            // progress: counting it changed the recovery fingerprint and reset
            // the stagnation budget, so repeating a plan entry with borrowed
            // evidence escaped recovery forever. Ignore the duplicate instead
            // of certifying it or adding it as remaining work.
            bool novelEvidence;
            foreach (proof; evidence)
                if ((proof in proofs) && !(proof in claimedProofs))
                    novelEvidence = true;
            if (evidence.length && !novelEvidence) return;
            ++state.completed;
            foreach (proof; evidence)
                if (proof in proofs)
                {
                    claimedProofs[proof] = true;
                    completedProofs[proof] = true;
                }
        }
        else if (state.remaining.length < 1800)
            state.remaining ~= "Outcome: " ~ taskExcerpt(text, 240) ~
                (done.length ? ". Acceptance: " ~ taskExcerpt(done, 240) : "") ~ "\n";
    }
    // A stale advisory checklist cannot reopen delivered, verified work.
    // Required actions and current verification remain separate obligations.
    const reconcilePlan = !strictPlan && session.verificationStatus == "passed" && taskHasActionEvidence(session);
    if (!reconcilePlan)
    {
        foreach (step; session.taskSteps)
            outcome(step.id, step.text, step.done, supportedStep(session, step, proofs), step.evidence);
        foreach (plan; session.nestedPlans) foreach (step; plan.steps)
            outcome(step.id, step.text, step.done, supportedStep(session, step, proofs), step.evidence);
    }
    foreach (item; session.contract.workItems) if (item.required)
        outcome(item.step.id, item.step.text, item.step.done, supportedStep(session, item.step, proofs), item.step.evidence);
    import auroraopencode.taskflow : taskRequiresPlan;
    if (strictPlan && taskRequiresPlan(session, true) && !session.taskSteps.length)
        state.remaining ~= "Strict planning was explicitly enabled: record the requested outcomes before completing.\n";
    state.verified = session.verificationStatus == "passed";
    state.verificationRequired = session.verificationStatus == "required" || session.verificationStatus == "failed";
    state.actionMissing = session.contract.id.length &&
        session.contract.intent != "analysis" && !taskHasActionEvidence(session);
    if (state.actionMissing) state.remaining ~= "Perform the requested action; source inspection or compilation alone does not establish the requested behavior.\n";
    if (state.verificationRequired && missingVerificationInput(session).length)
        state.remaining ~= "Restore the missing tracked verification input: " ~ missingVerificationInput(session) ~ "\n";
    if (state.verificationRequired)
        state.remaining ~= "Verify the reported behavior on the current deliverable and actual execution path. Direct handler calls do not prove physical input; compilation does not prove behavior.\n";
    import std.algorithm : sort;
    auto completedKeys = completedProofs.keys;
    completedKeys.sort();
    foreach (key; completedKeys) facts ~= key ~ "\n";
    // Plan progress is substantive even when the completed outcome carries no
    // tool-call evidence. Without this, a six-step plan that completes two
    // outcomes still produced the same fingerprint, so the recovery budget
    // expired and failed work that was actually advancing.
    facts ~= "completed:" ~ to!string(state.completed) ~ "\n";
    facts ~= "remaining:" ~ state.remaining ~ "\n";
    facts ~= state.verified ? "verified\n" : "unchecked\n";
    facts ~= state.actionMissing ? "no-action\n" : "action\n";
    state.fingerprint = sha256Of(facts).toHexString().idup;
    auto path = activeMessagePath(session);
    size_t begin;
    string actualRequest;
    foreach (i, index; path)
        if (session.messages[index].role == "user" && !session.messages[index].internal)
        { begin = i + 1; actualRequest = session.messages[index].content; }
    FailedCheck[] failedChecks;
    string failureTool;
    foreach (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role == "tool")
        {
            ++state.tools;
            if (message.workspaceChanged) ++state.effects;
            if (!message.failed && message.workspaceChanged) state.attempts = 0;
            // A Plan-mode refusal is the user's gate working, not a failed
            // attempt to recover; do not feed it back as an observed obstacle.
            if (message.failed && !planModeBlockedTool(message) &&
                !diagnosticBlockedTool(message))
            {
                state.failure = taskExcerpt(message.content, 800);
                state.transientFailure = transientToolFailure(message);
                failureTool = message.toolName;
            }
            // Successful checks resolve prior checker failures. Reads and plan
            // edits cannot clear an actual failed execution.
            else if (message.verificationCheck.length)
            {
                state.failure = "";
                failureTool = "";
            }
            // A later success of the same tool is the retry landing: the
            // operation that failed now works, so the recorded obstacle no
            // longer describes the current state. Without this, one malformed
            // command (for example a broken `python -c` one-liner) stayed in
            // the ledger after the next execution succeeded, two recovery
            // rounds expired, and an already delivered answer was marked
            // failed. A success of a different tool cannot erase the failure.
            else if (!message.failed && failureTool.length && message.toolName == failureTool)
            {
                state.failure = "";
                state.transientFailure = false;
                state.attempts = 0;
                failureTool = "";
            }
            // An accepted check is real progress. A fingerprint can recur after
            // verification flips back (a later check fails, then passes), so
            // attempts from an earlier streak must not make the next answer
            // terminal. Only substantive evidence resets the budget; reads and
            // plan edits still cannot erase an unresolved outcome.
            if (!message.failed && message.verificationCheck.length)
            {
                state.failure = "";
                state.transientFailure = false;
                state.attempts = 0;
            }
            if (message.verificationScope.length && (message.verificationCheck.indexOf("test") >= 0 || message.verificationCheck.indexOf("interaction") >= 0 || message.verificationCheck.indexOf("render") >= 0))
            {
                auto commands = checkCommands(message);
                import auroraopencode.checkreconciliation : revisableAdHocCheck;
                if (message.failed && !invalidatedCheck(message))
                    failedChecks ~= FailedCheck(message.toolCallId.length ? message.toolCallId : message.id,
                        message.verificationCheck, commands, revisableAdHocCheck(message, actualRequest));
                else if (!message.failed)
                    foreach_reverse (i, failed; failedChecks)
                    {
                        if (checkCategory(failed.category) != checkCategory(message.verificationCheck)) continue;
                        import auroraopencode.checkreconciliation : recordedCheckRevision;
                        const corrected = recordedCheckRevision(message, failed.call);
                        bool rerun = true;
                        foreach (required; failed.commands)
                            if (!reranCheck(required, commands, failed.adHoc)) { rerun = false; break; }
                        if (rerun || corrected) failedChecks = failedChecks.remove(i);
                    }
            }
        }
        // A read-only review supplies new information; the main model gets a
        // fresh recovery budget instead of inheriting the attempts that prompted
        // the review.
        if (message.internal && message.content.startsWith(executionDiagnosisMarker))
        {
            state.attempts = 0;
            continue;
        }
        if (!message.internal || !message.content.startsWith(executionRecoveryMarker)) continue;
        try
        {
            auto text = message.content[executionRecoveryMarker.length .. $];
            const end = text.indexOf('\n');
            auto value = parseJSON(end < 0 ? text : text[0 .. end]);
            if (value.type == JSONType.object && "fingerprint" in value.object && "attempts" in value.object &&
                value["fingerprint"].type == JSONType.string && value["attempts"].type == JSONType.integer &&
                value["fingerprint"].str == state.fingerprint)
                state.attempts = cast(int)value["attempts"].integer;
        }
        catch (Exception) {}
    }
    foreach (failed; failedChecks)
    {
        JSONValue revision;
        revision["failed_call_id"] = failed.call;
        revision["reason"] = "Explain the original requirement, the checker mistake and how the corrected tests cover it.";
        state.remaining ~= "Behavioral check " ~ failed.call ~ " failed and has not passed on a subsequent run. Resolve and rerun that check; an unrelated passing check cannot replace it. " ~
            "If this was your ad hoc inline check with an incorrect expectation or comparison, run the corrected behavioral checks through verify on all original inputs and supply " ~
            "check_revisions:" ~ JSONValue([revision]).toString() ~ ". " ~
            "This records an auditable correction; do not change user-owned tests or repeat a final answer while this check remains unresolved.\n";
    }
    return state;
}

/// Technical recovery is driven by repeated failures of one tool, not by how
/// many successful lookups the model performed. One notice per failure window.
string executionToolRecovery(const ref ChatSession session)
{
    import auroraopencode.agentloop : stagnantToolGuidance;
    const stagnant = stagnantToolGuidance(session);
    if (stagnant.length) return stagnant;
    int[string] failures;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.internal && message.content.startsWith("Execution obstacle: "))) break;
        if (message.role != "tool") continue;
        if (planModeBlockedTool(message) || diagnosticBlockedTool(message)) continue;
        if (message.verificationCheck.length && !message.failed) break;
        if (message.failed && ++failures[message.toolName] >= 3)
            return "Execution obstacle: " ~ taskExcerpt(message.content, 900) ~
                "\nRepeated execution failed. Resolve this concrete obstacle before repeating that operation. " ~
                "For a checkout mismatch, use the requested project's checkout; for a search timeout, select files or a smaller source directory. Do not just increase the deadline.";
    }
    return "";
}

/// Desktop restrictions survive plan replacement and compaction because the
/// authority is the preserved human history, never model-written plan text.
bool desktopRestricted(const ref ChatSession session)
{
    import std.string : toLower, strip;
    bool restricted;
    foreach (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role != "user" || message.internal) continue;
        auto text = message.content.toLower().strip();
        if (text.startsWith("please ")) text = text[7 .. $];
        foreach (phrase; ["stop using computer use", "stop interfering with my computer", "do not disturb me",
                "no more clicking", "do not use computer use", "do not use the desktop"])
            if (text.indexOf(phrase) >= 0) restricted = true;
        foreach (phrase; ["resume computer use", "you can use computer use again", "resume desktop input"])
            if (text.startsWith(phrase)) restricted = false;
    }
    return restricted;
}

/// Once every recorded outcome and the current behavioral check are complete,
/// the next request is the final answer. Do not expose tools for another audit.
bool executionReadyToAnswer(const ref ChatSession session)
{
    import auroraopencode.goalmode : goalActive;
    if (goalActive(session) || session.queuedGuidance.length || session.verificationStatus != "passed" ||
        session.contract.currentIntent == "analysis" || session.contract.intent == "analysis") return false;
    import auroraopencode.planmode : experimentalStrictPlanEnabled;
    const state = executionState(session, experimentalStrictPlanEnabled());
    return !state.remaining.length && !state.actionMissing;
}

bool executionShouldContinue(const ref ChatSession session, bool toolsEnabled, const ref ExecutionState state)
{
    import auroraopencode.taskcontinuation : taskAwaitingInput;
    import auroraopencode.taskflow : taskInvestigation;
    import auroraopencode.contextpolicy : latestActualUserRequest;
    import auroraopencode.requestintent : answerOnlyRequest, requestIntent, RequestIntent, actionApprovalRequest;
    if (!toolsEnabled || planModeProposalPending(session) ||
        taskAwaitingInput(session) || taskInvestigation(session) ||
        (session.contract.currentIntent == "analysis" && session.contract.intent == "analysis")) return false;
    const request = latestActualUserRequest(session);
    if (answerOnlyRequest(request) ||
        (requestIntent(request) == RequestIntent.conversation && session.contract.currentIntent != "continuation" &&
         !actionApprovalRequest(request))) return false;
    return state.remaining.length > 0;
}

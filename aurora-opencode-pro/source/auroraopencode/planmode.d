module auroraopencode.planmode;

// experimental: planmode (tracked, stricter plan upkeep).
// Removable drop-in: delete this file and the "experimental: planmode" markers
// in appui.d, plus the experimentalStrictPlan field in core.d and the Settings
// checkbox, and the feature is gone. Mirrors websearch/orchestrator.
//
// Off by default. Opt in with the Settings checkbox or AURORA_STRICT_PLAN=1.
//
// Design: this raises checklist reliability WITHOUT imposing a step template.
// It never forces a research/investigation step and never fixes step order;
// the invariants say "derive steps from this task".

import std.algorithm.searching : canFind;
import std.process : environment;
import std.string : startsWith, strip, toLower;

import auroraopencode.core : ChatMessage, ChatSession, activeMessagePath;
import auroraopencode.nativetooldefs : nativeOperationReadOnly;

/// Only these values enable the mode, so an unset variable (the common case)
/// leaves it off.
private enum enableValues = ["1", "on", "true", "yes", "y", "enabled", "enable"];

/// Whether tracked plan mode is active. Read on every call so tests (and a
/// relaunch with a different environment) see the current value.
public bool experimentalStrictPlanEnabled()
{
    if (strictPlanEnabledBySetting) return true;
    const raw = strip(toLower(environment.get("AURORA_STRICT_PLAN", "")));
    if (raw.length == 0) return false;
    return enableValues.canFind(raw);
}

/// Set by the host app from the persisted Settings checkbox. `__gshared` is
/// required: the app writes it on the UI thread while the prompt builder reads
/// it.
public __gshared bool strictPlanEnabledBySetting = false;

/// Apply the Settings choice. Called on load and whenever the checkbox changes,
/// so the next prompt build reflects the new value.
public void setStrictPlanSetting(bool value)
{
    strictPlanEnabledBySetting = value;
}

// ---------------------------------------------------------------------------
// experimental: plan mode - user-triggered propose-before-editing
//
// Removable drop-in: delete this region, the `experimentalPlanMode` fields in
// core.d, the Plan controls in appui.d and the gate imports in tools.d and
// conversationactor.d, and the feature is gone. The user arms it per
// conversation with the composer's Plan toggle; this switch only controls
// whether that toggle exists. ON by default.
// ---------------------------------------------------------------------------

/// Set by the host app from the persisted Settings checkbox. Defaults to on.
public __gshared bool planModeEnabledBySetting = true;

/// Whether the user-triggered Plan control exists. Read on every call so the
/// prompt builder and the gate always agree with the current Settings value.
public bool experimentalPlanModeEnabled()
{
    return planModeEnabledBySetting;
}

/// Apply the Settings choice.
public void setPlanModeSetting(bool value)
{
    planModeEnabledBySetting = value;
}

/// Tools that cannot change the workspace or run a program. Everything else is
/// refused while the conversation is in plan mode, so a prompt-ignoring model
/// cannot bypass the gate.
private enum planModeTools = ["read", "grep", "glob", "read_plan",
    "read_history", "webfetch", "websearch", "calculate", "environment",
    "tool_status", "process", "request_input", "task_blocker", "update_plan",
    "update_subplan", "retire_images", "dshell"];

/// True when a call must be refused because the conversation is in plan mode.
public bool planBlocksTool(string name, string arguments)
{
    if (name.length == 0) return false;
    if (planModeTools.canFind(name)) return false;
    // data/archive mutate only for their write actions; their read-only actions
    // stay available so the model can inspect JSON or list an archive.
    return !nativeOperationReadOnly(name, arguments);
}

/// Guidance appended only while the user has armed Plan mode. It states the
/// gate and the expected shape of the proposal; it never invents a step
/// template.
public string planModePromptBlock()
{
    return "\n# Plan mode\n" ~
        "The user turned Plan mode on. Investigate read-only and propose; do " ~
        "not change anything yet. Editing, writing, patching, removing, " ~
        "moving, renaming, running commands, verifying, syncing and " ~
        "rebuilding are refused until the user approves the plan.\n" ~
        "Record the intended work with update_plan: each step names the files " ~
        "or symbols it touches and a done criterion the user can check, plus " ~
        "the acceptance rule taken from the request. Treat the steps as a " ~
        "provisional hypothesis the user can adjust. Then stop and summarize " ~
        "the proposal in one or two sentences. Nothing has been changed yet, " ~
        "so never claim work is done.\n" ~
        "If the request is only a question, answer it directly and skip the " ~
        "plan. If a fact only the user can supply is missing, use " ~
        "request_input instead of guessing.\n";
}

/// The refusal text a blocked call returns. Explicit so the model stops
/// instead of retrying the same mutation.
public string planModeRefusal(string name)
{
    return "Plan mode is on: nothing is changed yet, so `" ~ name ~
        "` was not run. Record the intended steps with update_plan and stop; " ~
        "the user will approve or adjust the plan.";
}

/// The refusal is a proposal checkpoint, not a failed attempt to retry. Kept as
/// a prefix so callers can classify a blocked call without knowing the tool.
private enum planModeRefusalPrefix =
    "Plan mode is on: nothing is changed yet, so `";

/// True when this tool result is the Plan-mode gate refusing a mutation.
public bool planModeBlockedTool(const ref ChatMessage message)
{
    return message.role == "tool" && message.failed &&
        message.content.startsWith(planModeRefusalPrefix);
}

/// True when the agent has proposed a plan under Plan mode and stopped to
/// summarize. A mutation refusal is one trigger; a plan recorded in this turn
/// is the other, because the Plan-mode prompt tells the agent to record steps
/// and stop for approval. Treating either as retryable execution failure made
/// the agent repeat the blocked call, edit before approval, or flood the
/// conversation with recovery rounds.
public bool planModeProposalPending(const ref ChatSession session)
{
    if (!session.planMode || !experimentalPlanModeEnabled()) return false;
    bool proposed;
    foreach (step; session.taskSteps)
        if (step.status != "completed") { proposed = true; break; }
    if (!proposed)
        foreach (plan; session.nestedPlans)
        {
            foreach (step; plan.steps)
                if (step.status != "completed") { proposed = true; break; }
            if (proposed) break;
        }
    if (!proposed) return false;
    bool blocked, recordedPlan, sawAssistant, assistantUsedTools;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal) break;
        if (planModeBlockedTool(message)) blocked = true;
        if (message.role == "tool" && !message.failed && message.toolName == "update_plan")
            recordedPlan = true;
        if (!sawAssistant && message.role == "assistant" && !message.internal)
        {
            sawAssistant = true;
            assistantUsedTools = message.toolCalls.length > 0;
        }
    }
    return (blocked || recordedPlan) && sawAssistant && !assistantUsedTools;
}

/// The system-prompt block appended only while tracked plan mode is on. It
/// states invariants, never a fixed step template: it must not force a
/// research/investigation step, and it must not impose step order.
public string trackedPlanPromptBlock()
{
    if (!experimentalStrictPlanEnabled()) return "";
    return "\n# Tracked plan mode\n" ~
        "Record a plan with update_plan for every request; one step is enough " ~
        "for a small request, and a direct answer gets an answer step. Derive " ~
        "the steps from THIS task - " ~
        "never a fixed template, and never assume a research or investigation " ~
        "step is required. The first step is the smallest action that reduces " ~
        "the most uncertainty (a read, a search, a quick edit, or a question " ~
        "to the user). Each step is a concrete outcome with a stable ID and " ~
        "`done` naming how completion is proven. Cite successful tool-call IDs " ~
        "as evidence before marking outcomes completed. The plan is a live " ~
        "state, not a fixed script: add discovered work and reorder freely, " ~
        "and revise it whenever evidence changes the path. Keep at most one " ~
        "step in_progress. Explain a dropped unfinished outcome, a changed " ~
        "acceptance, or a reopened completed outcome; ordinary additions and " ~
        "reordering need no ceremony. Revisions and their explanations are " ~
        "retained as plan history. Reconcile the plan before the final " ~
        "answer: mark finished steps completed, prune obsolete steps, and " ~
        "never mark unfinished work completed to satisfy the checklist.\n";
}

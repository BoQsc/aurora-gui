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
import std.string : strip, toLower;

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
        "the acceptance rule taken from the request. Then stop and summarize " ~
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
        "as evidence before marking outcomes completed. Keep at most one step " ~
        "in_progress, and revise the plan whenever evidence changes the path. " ~
        "Revisions and their explanations are retained as plan history. " ~
        "Reconcile the plan before the final answer: mark " ~
        "finished steps completed, rewrite obsolete or mixed steps, and never " ~
        "mark unfinished work completed.\n";
}

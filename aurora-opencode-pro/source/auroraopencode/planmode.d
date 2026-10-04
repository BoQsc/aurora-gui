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

/// The system-prompt block appended only while tracked plan mode is on. It
/// states invariants, never a fixed step template: it must not force a
/// research/investigation step, and it must not impose step order.
public string trackedPlanPromptBlock()
{
    if (!experimentalStrictPlanEnabled()) return "";
    return "\n# Tracked plan mode\n" ~
        "Before substantial work, record a plan with update_plan; skip " ~
        "planning for a one-step request. Derive the steps from THIS task - " ~
        "never a fixed template, and never assume a research or investigation " ~
        "step is required. The first step is the smallest action that reduces " ~
        "the most uncertainty (a read, a search, a quick edit, or a question " ~
        "to the user). Each step is a concrete outcome; when useful add " ~
        "`done` naming how completion is proven. Keep at most one step " ~
        "in_progress, and reconcile the plan before the final answer: mark " ~
        "finished steps completed, rewrite obsolete or mixed steps, and never " ~
        "mark unfinished work completed.\n";
}

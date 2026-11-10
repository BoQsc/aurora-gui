// Experimental plan-mode contracts: the user-triggered gate, its guidance and
// its durable per-conversation flag. Standalone runner (main), mirroring the
// other tests/ programs.
module plan_mode_contracts;

import auroraopencode.conversationcodec : decodeSessionMetadata;
import auroraopencode.conversationencode : sessionMetaToJson;
import auroraopencode.core : ChatSession, OpenCodeToolCall, Settings;
import auroraopencode.planmode : experimentalPlanModeEnabled,
    planBlocksTool, planModePromptBlock, planModeRefusal, setPlanModeSetting;
import auroraopencode.tools : ChangeContext, ToolExecution, executeTool;

import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse, tempDir;
import std.json : JSONValue;
import std.path : buildPath;
import std.string : indexOf, startsWith;

int main()
{
    // The experimental switch ships ON: the composer control exists unless the
    // user turns it off in Settings.
    Settings defaults;
    assert(defaults.experimentalPlanMode, "plan mode must default to on");
    assert(experimentalPlanModeEnabled(), "the setting must be applied by default");

    // The allowlist is what the gate refuses on: mutations and programs stop,
    // read-only inspection and plan upkeep keep working.
    assert(planBlocksTool("write", `{}`));
    assert(planBlocksTool("edit", `{}`));
    assert(planBlocksTool("apply_patch", `{}`));
    assert(planBlocksTool("remove", `{}`));
    assert(planBlocksTool("move", `{}`));
    assert(planBlocksTool("rename", `{}`));
    assert(planBlocksTool("create_folder", `{}`));
    assert(planBlocksTool("run", `{}`));
    assert(planBlocksTool("bash", `{}`));
    assert(planBlocksTool("verify", `{}`));
    assert(planBlocksTool("sync", `{}`));
    assert(planBlocksTool("rebuild", `{}`));
    assert(!planBlocksTool("read", `{}`));
    assert(!planBlocksTool("grep", `{}`));
    assert(!planBlocksTool("glob", `{}`));
    assert(!planBlocksTool("read_plan", `{}`));
    assert(!planBlocksTool("read_history", `{}`));
    assert(!planBlocksTool("update_plan", `{}`));
    assert(!planBlocksTool("request_input", `{}`));
    assert(!planBlocksTool("environment", `{}`));
    // data/archive are read-only only for their query/list/validate actions.
    assert(!planBlocksTool("data", `{"action":"query"}`));
    assert(planBlocksTool("data", `{"action":"set"}`));
    assert(!planBlocksTool("archive", `{"action":"list"}`));
    assert(planBlocksTool("archive", `{"action":"create"}`));

    // Guidance states the gate and the proposal shape, and the refusal tells
    // the model to stop rather than retry.
    assert(planModePromptBlock().indexOf("Plan mode") >= 0);
    assert(planModePromptBlock().indexOf("update_plan") >= 0);
    assert(planModeRefusal("write").indexOf("was not run") >= 0);

    // The flag round-trips with the conversation, so a reload cannot silently
    // re-open the gate or pretend the user approved.
    ChatSession armed;
    armed.id = "plan-mode-contract";
    armed.planMode = true;
    const encoded = sessionMetaToJson(armed);
    assert(encoded.object["planMode"].boolean);
    ChatSession restored;
    restored.id = armed.id;
    decodeSessionMetadata(encoded, restored);
    assert(restored.planMode);
    ChatSession plain; plain.id = "plain";
    decodeSessionMetadata(JSONValue.emptyObject, plain);
    assert(!plain.planMode);

    // The real gate: a write is refused while armed and performs the write
    // once the conversation is not armed.
    const root = buildPath(tempDir(), "aurora-plan-mode-" ~
        to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    static void cleanup(string path)
    {
        try rmdirRecurse(path);
        catch (Exception) {}
    }
    scope (exit) cleanup(root);
    const target = buildPath(root, "gated.txt");
    const args = `{"filePath":"gated.txt","content":"plan mode ran this"}`;

    ChangeContext armedContext;
    armedContext.conversationId = "plan-mode-contract";
    armedContext.planMode = true;
    ToolExecution blocked = executeTool(
        OpenCodeToolCall("call_blocked", "write", args), root, null, armedContext);
    assert(blocked.failed, "a write must fail while plan mode is armed");
    assert(blocked.output.indexOf("Plan mode") >= 0, blocked.output);
    assert(!exists(target), "plan mode must not touch the workspace");

    // A second attempt is refused the same way: the gate is state, not a
    // one-shot prompt hint.
    ToolExecution again = executeTool(
        OpenCodeToolCall("call_blocked_2", "write", args), root, null, armedContext);
    assert(again.failed);
    assert(!exists(target));

    // Reads stay available for the investigation phase.
    ToolExecution read = executeTool(
        OpenCodeToolCall("call_read", "read", `{"filePath":"missing.txt"}`), root,
        null, armedContext);
    assert(!read.output.startsWith("Plan mode is on"), read.output);

    ChangeContext openContext;
    openContext.conversationId = "plan-mode-contract";
    ToolExecution wrote = executeTool(
        OpenCodeToolCall("call_write", "write", args), root, null, openContext);
    assert(!wrote.failed, wrote.output);
    assert(exists(target));
    assert(readText(target) == "plan mode ran this");

    // Turning the experimental switch off removes the control and the gate.
    setPlanModeSetting(false);
    assert(!experimentalPlanModeEnabled());
    setPlanModeSetting(true);

    return 0;
}

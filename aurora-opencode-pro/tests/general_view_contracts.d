module general_view_contracts;

// The agent must survey the whole problem before narrowing to a local step,
// and it must generalize a fix instead of patching only the reported instance.
// These are the prompt/tool contracts that keep a long objective from turning
// into a sequence of one-off local patches.

import auroraopencode.core : ChatSession;
import auroraopencode.goalmode : goalContinuationInstruction;
import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt,
    responsePlanReviewPrompt;
import auroraopencode.tools : builtinToolDefinitions, nativeOnlyToolDefinitions;
import std.string : indexOf;
import std.stdio : writeln;

private void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

int main()
{
    SystemPromptContext ctx;
    ctx.platformName = "win32";
    const prompt = renderSystemPrompt(ctx);

    require(prompt.indexOf("Survey the relevant system before narrowing") >= 0,
        "the core prompt does not ask for a system survey before narrowing");
    require(prompt.indexOf("take the general view before local work") >= 0,
        "the planning prompt has no general-view phase");
    require(prompt.indexOf("map the relevant system end-to-end") >= 0,
        "the general view does not cover the whole system");
    require(prompt.indexOf("fix the class of failure at its shared cause") >= 0,
        "the prompt does not ask for a generalized fix");
    require(prompt.indexOf("check sibling call sites") >= 0,
        "the prompt does not ask for related call sites");
    require(prompt.indexOf("A question deserves the same system view") >= 0,
        "questions are not covered by the general-view rule");
    require(prompt.indexOf("take the general view before local work") <
        prompt.indexOf("Keep one outcome active"),
        "the general view must be established before narrowing to one outcome");

    ChatSession session;
    session.goal = "Complete the whole volumetric terrain objective";
    session.goalStatus = "active";
    const continuation = goalContinuationInstruction(session);
    require(continuation.indexOf("widen it to the general cause") >= 0,
        "goal continuation can still narrow to a local symptom");
    require(continuation.indexOf("generalize the fix and its checks") >= 0,
        "goal continuation does not ask for a generalized fix");
    require(responsePlanReviewPrompt().indexOf(
        "Keep the whole objective and general approach in view") >= 0,
        "the recurring plan review can still narrow to one symptom");

    bool sawPlan = false;
    foreach (def; builtinToolDefinitions() ~ nativeOnlyToolDefinitions())
        if (def.name == "update_plan")
        {
            sawPlan = true;
            require(def.description.indexOf("record the general approach and whole scope") >= 0,
                "update_plan does not ask for the general approach before local steps");
            require(def.description.indexOf("plan the class of fix") >= 0,
                "update_plan does not ask for a generalizable fix");
        }
    require(sawPlan, "update_plan tool definition is missing");

    writeln("PASS general-view survey and generalized-fix contracts are present");
    return 0;
}
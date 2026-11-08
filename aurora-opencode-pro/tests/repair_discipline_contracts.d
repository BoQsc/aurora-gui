module repair_discipline_contracts;

// Contract for the repair-discipline prompt section: the qualities that keep a
// user-facing failure from being "fixed" by a plausible story are present, and
// the section sits with the working rules rather than after the tool policy.

import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt;
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

    require(prompt.indexOf("# Diagnosis and repair discipline") >= 0,
        "the repair-discipline section is missing");
    require(prompt.indexOf("Reproduce before you change what runs.") >= 0,
        "the reproduce-first gate is missing");
    require(prompt.indexOf("A cause needs discriminating evidence.") >= 0,
        "the cause-evidence gate is missing");
    require(prompt.indexOf("Never change the user's launch surface as a repair") >= 0,
        "the launch-surface rule is missing");
    require(prompt.indexOf("\"Fixed\" means the user's path works.") >= 0,
        "the fixed-means-user-path rule is missing");
    require(prompt.indexOf("A headless, offscreen, helper or self-written check is a check, never a fix") >= 0,
        "the headless-is-not-a-fix rule is missing");
    require(prompt.indexOf("Your tests are not the user's evidence.") >= 0,
        "the own-tests rule is missing");
    require(prompt.indexOf("retire the old claim in the same reply") >= 0,
        "the contradicted-claim rule is missing");
    require(prompt.indexOf("\"Still broken\" means stop editing.") >= 0,
        "the still-broken rule is missing");
    require(prompt.indexOf("Report the delta, not the intention") >= 0,
        "the delta-report rule is missing");

    // Working contract order: after the execution loop, before the batching
    // and editing rules, so it reads as part of doing the work.
    const loop = prompt.indexOf("# Execution loop");
    const section = prompt.indexOf("# Diagnosis and repair discipline");
    require(loop >= 0 && loop < section,
        "the repair discipline must follow the execution loop");
    require(section < prompt.indexOf("# Independent tool calls"),
        "the repair discipline must precede the batching rules");
    require(section < prompt.indexOf("# Editing and safety"),
        "the repair discipline must precede the editing rules");

    writeln("PASS repair discipline gates are present and ordered with the working rules");
    return 0;
}

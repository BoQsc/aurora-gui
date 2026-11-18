module problem_framing_contracts;

import auroraopencode.answercontract : answerContract;
import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt;
import std.string : indexOf;
import std.stdio : writeln;

void main()
{
    SystemPromptContext ctx; ctx.nativeOnly = true; ctx.platformName = "win32";
    const prompt = renderSystemPrompt(ctx);
    assert(prompt.length < 7800, "Global workflow policy grew into repeated task lectures");
    assert(prompt.indexOf("Future use is context") >= 0);
    assert(prompt.indexOf("take the general view before local work") >= 0,
        "The general-view survey phase is missing from the workflow policy");
    assert(prompt.indexOf("Only an explicit explanation-only request") < 0);
    assert(prompt.indexOf("Company of Heroes") < 0);
    const contract = answerContract("Make the agent sharper", "");
    assert(contract.length < 600, "Per-response footer duplicated global policy");
    assert(contract.indexOf("corrections") >= 0);
    assert(contract.indexOf("Do not hand back a build for the user to run") >= 0,
        "Implementation work can still be handed back for the user to launch");
    assert(answerContract("Why does the provider stall?", "").indexOf("Do not hand back a build") < 0,
        "Diagnosis footer duplicated the implementation delivery rule");
    writeln("MEASURE system_prompt_bytes=",prompt.length," answer_footer_bytes=",contract.length);
    writeln("PASS scoped workflow without framing deferrals or repeated global policy");
}

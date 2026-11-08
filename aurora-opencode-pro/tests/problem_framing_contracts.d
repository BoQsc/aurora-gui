module problem_framing_contracts;

// Contract for the problem-framing prompt section: the requested outcome owns
// the work, a benchmark or model comparison is a proxy unless it measures that
// outcome, and an off-target correction retires the rejected plan.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets -of=build/problem_framing_contracts.exe \
//       aurora-opencode-pro/tests/problem_framing_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/problem_framing_contracts.exe

import auroraopencode.answercontract : answerContract;
import auroraopencode.systemprompt : SystemPromptContext, renderSystemPrompt;
import std.string : indexOf;
import std.stdio : writeln;

private void require(bool condition, string message)
{
    if (condition) return;
    writeln("FAIL: ", message);
    assert(condition, message);
}

int main()
{
    SystemPromptContext ctx;
    ctx.platformName = "win32";
    const prompt = renderSystemPrompt(ctx);
    const section = prompt.indexOf("# Problem framing");
    require(section >= 0, "problem-framing section is missing");
    require(prompt.indexOf("user-visible outcome") >= 0,
        "the outcome-first rule is missing");
    require(prompt.indexOf("proxy") >= 0,
        "the proxy-rejection rule is missing");
    require(prompt.indexOf("correction is authoritative") >= 0,
        "the authoritative-correction rule is missing");
    const plan = prompt.indexOf("# Plan");
    const operating = prompt.indexOf("# Operating contract");
    require(plan >= 0 && plan < section && section < operating,
        "problem framing must follow Plan and precede the operating contract");

    const contract = answerContract(
        "Make the agent sharper and more intelligent.", "");
    require(contract.indexOf("user-visible outcome") >= 0,
        "the answer contract lost the outcome-first rule");
    require(contract.indexOf("off-target") >= 0,
        "the answer contract lost the correction rule");
    writeln("PASS problem framing requires the outcome, rejects proxy work, and obeys corrections");
    return 0;
}
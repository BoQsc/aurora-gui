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

import auroraopencode.answercontract : answerContract, framedOutcomeText,
    openEndedFramingRequest;
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
    require(openEndedFramingRequest(
        "Its program source is at C:/work/app try to find a way to maximize " ~
        "sharpness and intelligence of agent to solve the right problems"),
        "the original ambiguous improvement request must be framed first");
    require(openEndedFramingRequest("Make the agent faster"),
        "a vague improvement request must be framed first");
    require(!openEndedFramingRequest("Fix the parser in source/parser.d"),
        "a concrete file task must not trigger the framing gate");
    require(!openEndedFramingRequest("Improve performance by 20% in bench.py"),
        "a measured target must not trigger the framing gate");
    require(!openEndedFramingRequest("Review this change"),
        "a review request without an improvement claim must not be gated");
    require(!framedOutcomeText(
        "I'll inspect the agent's prompt, planning, and verification surfaces in " ~
        "the source, then give concrete levers with file/line evidence."),
        "an action announcement must not count as outcome framing");
    require(framedOutcomeText(
        "The outcome is a measurably sharper first reply; I will measure the " ~
        "first-turn outcome statement on the trap task."),
        "an explicit outcome statement must satisfy framing");
    require(framedOutcomeText("Which surface should I change?"),
        "a focused question must satisfy framing");
    writeln("PASS problem framing requires the outcome, rejects proxy work, and obeys corrections");
    return 0;
}
module auroraopencode_pro_computer_policy_probe;

// Delivery check for the computer-use necessity policy: the prompt and the
// `computer` schema must both say the desktop is a last resort, so a model
// prefers code/file/run verification when it can prove the same fact.

import auroraopencode.computeruse : setComputerUseSetting;
import auroraopencode.tools : builtinToolDefinitions, toolSteeringPrompt;
import std.stdio : writeln;
import std.string : indexOf;

private void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

int main()
{
    setComputerUseSetting(true);
    const prompt = toolSteeringPrompt(true);
    require(prompt.indexOf(
        "Computer use is enabled, but it is a last resort") >= 0,
        "steering prompt must make computer use a last resort");
    require(prompt.indexOf(
        "use the `computer` tool only when the outcome genuinely requires the desktop") >= 0,
        "steering prompt must limit computer use to genuinely desktop-only outcomes");
    require(prompt.indexOf("`run` (a minimal probe or test)") >= 0,
        "steering prompt must name the programmatic alternative");
    require(prompt.indexOf(
        "do not reach for `computer` just to try something out") >= 0,
        "steering prompt must reject exploratory desktop use");
    require(prompt.indexOf(
        "State the desktop-only reason before the first `computer` call") >= 0,
        "steering prompt must require a stated desktop-only reason");
    require(prompt.indexOf("last resort") < prompt.indexOf(
        "drive the desktop with the"), "the necessity rule must precede the how-to");

    string description;
    foreach (tool; builtinToolDefinitions())
        if (tool.name == "computer") description = tool.description;
    require(description.length > 0, "enabled computer use must expose the tool");
    require(description.indexOf("Last resort:") >= 0,
        "the computer tool description must state the necessity rule");
    require(description.indexOf("running a probe or test") >= 0,
        "the computer tool description must prefer a code check");
    writeln("PASS computer use is a last resort in the prompt and the tool schema");
    return 0;
}

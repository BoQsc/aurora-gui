module auroraopencode_pro_computer_policy_probe;

// Delivery check for the computer-use policy: when enabled, the prompt and the
// `computer` schema must both say the desktop is a last resort. When disabled,
// the prompt must forbid custom Python scripts and other programs that control
// the computer, so the hidden tool cannot be replaced by a home-made workaround.

import auroraopencode.computeruse : setComputerUseSetting;
import auroraopencode.tools : builtinToolDefinitions, toolSteeringPrompt;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

private void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

int main()
{
    const previous = environment.get("AURORA_COMPUTER_USE", null);
    environment.remove("AURORA_COMPUTER_USE");
    scope (exit)
    {
        setComputerUseSetting(false);
        if (previous is null) environment.remove("AURORA_COMPUTER_USE");
        else environment["AURORA_COMPUTER_USE"] = previous;
    }

    // Disabled: no custom script may take the hidden tool's place.
    setComputerUseSetting(false);
    const disabled = toolSteeringPrompt(true);
    require(disabled.indexOf("Computer use is disabled in Settings") >= 0,
        "disabled computer use must be stated in the steering prompt");
    require(disabled.indexOf("Do not create or run custom Python scripts") >= 0,
        "disabled computer use must forbid custom Python desktop-control scripts");
    require(disabled.indexOf(
        "other programs that control the computer") >= 0,
        "the prohibition must cover non-Python desktop-control programs");
    require(disabled.indexOf("unless the user enables") >= 0,
        "the prohibition must be conditional on the computer-use option");
    require(disabled.indexOf("ask the user to enable it") >= 0,
        "the prompt must route a genuine desktop need to the setting");

    // Enabled: the tool and its last-resort rule are the sanctioned route, and
    // the disabled-state prohibition is gone.
    setComputerUseSetting(true);
    const prompt = toolSteeringPrompt(true);
    require(prompt.indexOf("Computer use is disabled in Settings") < 0,
        "enabled computer use must not be described as disabled");
    require(prompt.indexOf(
        "Do not create or run custom Python scripts") < 0,
        "the script prohibition must not apply while computer use is enabled");
    require(prompt.indexOf("Use computer tools when pixels") >= 0,
        "enabled computer use must advertise the computer tools");

    string description;
    foreach (tool; builtinToolDefinitions())
        if (tool.name == "computer") description = tool.description;
    require(description.length > 0, "enabled computer use must expose the tool");
    require(description.indexOf("Last resort:") >= 0,
        "the computer tool description must state the necessity rule");
    require(description.indexOf("running a probe or test") >= 0,
        "the computer tool description must prefer a code check");
    writeln("PASS computer use gates custom desktop-control scripts and remains a last resort");
    return 0;
}

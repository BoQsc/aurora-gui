module computeruse_schema_test;

// Headless contract check: no window is created, so it can verify the
// model-facing tool schema and guidance without disturbing the desktop.

import auroraopencode.computeruse : experimentalComputerUseTools,
    setComputerUseSetting;
import std.algorithm : canFind;
import std.json : JSONType, parseJSON;
import std.stdio : writeln;

int main()
{
    setComputerUseSetting(true);
    scope (exit) setComputerUseSetting(false);
    auto tools = experimentalComputerUseTools();
    assert(tools.length == 1, "the computer tool is not registered");
    auto schema = parseJSON(tools[0].parametersJson);
    assert(schema.type == JSONType.object, "tool parameters are not a JSON object");
    auto properties = schema["properties"];
    assert(properties.type == JSONType.object, "the schema has no properties");
    foreach (name; ["window", "app", "full_screen", "list_windows", "region"])
        assert(name in properties.object, name ~ " parameter is missing");

    const appHelp = properties["app"]["description"].str;
    assert(appHelp.length > 0 && appHelp.canFind("filter"),
        "app must be described as a filter");
    const listHelp = properties["list_windows"]["description"].str;
    assert(listHelp.canFind("app"), "the list parameter must mention app filtering");
    const windowHelp = properties["window"]["description"].str;
    assert(windowHelp.canFind("list_windows"),
        "the window parameter must point at the candidate list");

    // The choice is the agent's: the guidance presents the window as a
    // suggestion and names full_screen as an equal option.
    const guidance = tools[0].description;
    assert(guidance.canFind("suggests"),
        "the guidance no longer presents the window as a suggestion");
    assert(guidance.canFind("list_windows") && guidance.canFind("app"),
        "the guidance does not explain the list and its app filter");
    assert(guidance.canFind("full_screen"),
        "the guidance does not offer the whole desktop");
    writeln("PASS: computer tool schema and guidance expose window/app filtering, " ~
        "the window list, and the whole-desktop choice");
    return 0;
}

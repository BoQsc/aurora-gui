module plan_agent_ui_contracts;

// The plan leads the agent contract, and the experimental automatic-follow-up
// divider is gone from both the transcript and Settings.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.tools : builtinToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath, absolutePath;
import std.string : indexOf;
import std.stdio : writeln;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children()) if (auto found = find(child, id)) return found;
    return null;
}

int main()
{
    foreach (tool; builtinToolDefinitions())
        if (tool.name == "update_plan")
            assert(tool.description.indexOf("Follow the steps in order") >= 0,
                "update_plan does not require following the planned steps");

    const state = absolutePath(buildPath(tempDir(), "aurora-plan-ui-" ~ to!string(MonoTime.currTime.ticks)));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:1/v1"; settings.apiKey = "fixture";
    settings.workspace = state; settings.toolsEnabled = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.width = 1100; options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) { root.shutdownClient(); window.close(); }
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 20) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }

    const prompt = root.systemPromptViewerTextForTesting();
    root.dismissPopupForTesting();
    assert(prompt.indexOf("# Plan") >= 0, "Plan section missing from the live prompt viewer");
    assert(prompt.indexOf("# Plan") < prompt.indexOf("# Operating contract"),
        "Plan section does not lead the working sections");
    assert(prompt.indexOf("never by follow-up rounds") >= 0,
        "The no-follow-up planning rule is missing");
    assert(prompt.indexOf("Never end with a question, an offer") >= 0,
        "The closing-offer prohibition is missing");

    assert(root.providerSelectorPresentForTesting(), "Settings did not open");
    assert(find(root, "oc-provider") !is null, "Settings probe control is not visible");
    assert(find(root, "oc-followupdivider") is null,
        "The removed follow-up option is still in Settings");
    root.dismissPopupForTesting();
    writeln("PASS live prompt leads with the Plan contract; Settings no longer offers the follow-up divider");
    return 0;
}

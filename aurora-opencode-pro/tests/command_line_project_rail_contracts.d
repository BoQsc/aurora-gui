module command_line_project_rail_contracts;

// Focused headless contract for the command-line project's place in the
// projects rail: the "Command Line Conversations" project (created by a
// cmd/console session) must always render as the rail's last row, directly
// above the "New project" button, no matter when it was created or where a
// later action put it. Runs offline against a private state directory and
// drives the real widgets offscreen.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets -of=build/command_line_project_rail_contracts.exe \
//       aurora-opencode-pro/tests/command_line_project_rail_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/command_line_project_rail_contracts.exe

import aurora;
import auroraopencode.appui : OpenCodeRoot, commandLineConversationsProjectName;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.time : MonoTime, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;

private void writeState(string stateDir)
{
    JSONValue settings;
    settings["apiKey"] = "";
    settings["baseUrl"] = "http://Probe.Local/v1/";
    settings["model"] = "probe-model";
    write(buildPath(stateDir, "settings.json"), settings.toString());

    JSONValue root;
    root["sessions"] = JSONValue(string[].init);
    root["current"] = -1;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

private string[] projectNamesFromDisk(string stateDir)
{
    auto doc = parseJSON(readText(buildPath(stateDir, "projects.json")));
    string[] names;
    foreach (item; doc["projects"].array)
        names ~= item["name"].str;
    return names;
}

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-command-line-project-rail");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeState(stateDir);

    WindowOptions options;
    options.title = "Aurora command-line project rail contracts";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    scope (exit)
    {
        root.shutdownClient();
        window.close();
    }

    // Wait out the deferred history load so startConversationInProject runs.
    const deadline = MonoTime.currTime + seconds(30);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        driver.paint();
    }

    // A console session files its chats under the command-line project.
    root.startConversationInProject(commandLineConversationsProjectName,
        buildPath(stateDir, "console"));
    root.tickTree(0.02);
    driver.paint();

    auto names = root.projectNamesForTesting();
    assert(names.length == 2, "expected sandbox + command-line project");
    assert(names[$ - 1] == commandLineConversationsProjectName,
        "the command-line project should be the rail's last row: " ~
        names.to!string);
    writeln("Command-line project created last: ", names);

    // A later project must slot in above the command-line project, which stays
    // pinned as the last row (directly above the New project button).
    root.addProjectForTesting("Alpha", buildPath(stateDir, "alpha"));
    root.tickTree(0.02);
    driver.paint();
    names = root.projectNamesForTesting();
    assert(names[$ - 1] == commandLineConversationsProjectName,
        "adding a project pushed the command-line project off the bottom: " ~
        names.to!string);
    assert(names.length == 3 && names[1] == "Alpha",
        "the new project should sit above the pinned command-line project: " ~
        names.to!string);
    writeln("New project slotted above the pinned command-line project: ",
        names);

    // Dragging the command-line row elsewhere must not un-pin it.
    root.reorderProjectForTesting(2, 0);
    root.tickTree(0.02);
    driver.paint();
    names = root.projectNamesForTesting();
    assert(names[$ - 1] == commandLineConversationsProjectName,
        "a rail drag moved the command-line project off the bottom: " ~
        names.to!string);
    writeln("Drag left the command-line project pinned last: ", names);

    // The command-line project must render as its own row directly above the
    // New project button, not merely last inside the scrollable list: the list
    // is top-anchored in a tall rail, so a last list row leaves a wide empty
    // band above the button and the project reads as missing from the bottom.
    auto rail = cast(ListView) findById(root, "oc-projects");
    auto pinned = cast(ListView) findById(root, "oc-command-line-project");
    auto newProject = findById(root, "oc-new-project");
    assert(rail !is null, "the projects rail must exist");
    assert(pinned !is null,
        "the command-line project needs its own row above the button");
    assert(newProject !is null, "the New project button must exist");
    assert(pinned.visible(), "the pinned command-line row must be visible");
    assert(pinned.items().length == 1,
        "the pinned row holds exactly the command-line project");
    assert(to!string(pinned.items()[0].text) ==
        commandLineConversationsProjectName,
        "the pinned row must be the command-line project, was: " ~
        to!string(pinned.items()[0].text));
    foreach (item; rail.items())
        assert(to!string(item.text) != commandLineConversationsProjectName,
            "the command-line project must not also sit in the scrollable list");
    const gap = newProject.bounds().y - pinned.bounds().bottom();
    assert(gap >= 0 && gap <= 12,
        "the pinned row must sit directly above the New project button, gap was " ~
        gap.to!string);
    writeln("Pinned row sits ", gap, " px above the New project button");

    // Selecting the pinned row activates the command-line project and clears the
    // scrollable list's selection, so only one rail row ever looks active.
    root.selectProjectForTesting(1);
    root.tickTree(0.02);
    driver.paint();
    pinned.setSelectedIndex(0);
    root.tickTree(0.02);
    driver.paint();
    assert(root.activeProjectNameForTesting() ==
        commandLineConversationsProjectName,
        "selecting the pinned row must activate the command-line project, was: " ~
        root.activeProjectNameForTesting());
    assert(rail.selectedIndex() == -1,
        "the scrollable list must not keep a selection beside the pinned row");
    assert(pinned.selectedIndex() == 0,
        "the pinned row must show the selection");
    writeln("Pinned row selection activates the command-line project");

    // The rail is often collapsed to icon width, and that presentation must keep
    // the pinned row hugging the button too, so flip it and check again.
    const wasCollapsed = root.projectsRailCollapsedForTesting();
    root.toggleProjectsRailForTesting();
    root.tickTree(0.02);
    driver.paint();
    assert(root.projectsRailCollapsedForTesting() != wasCollapsed,
        "toggling the rail must flip its presentation");
    assert(pinned.visible(),
        "the pinned row must stay visible when the rail is collapsed");
    assert(pinned.items().length == 1 && to!string(pinned.items()[0].text) ==
        commandLineConversationsProjectName,
        "the pinned row must keep the command-line project in both presentations");
    const flippedGap = newProject.bounds().y - pinned.bounds().bottom();
    assert(flippedGap >= 0 && flippedGap <= 12,
        "the pinned row must sit directly above the New project button in the " ~
        "other rail presentation too, gap was " ~ flippedGap.to!string);
    writeln("Toggled rail (wasCollapsed=", wasCollapsed, ") keeps the pinned row ",
        flippedGap, " px above the New project button");

    // The pinned order must persist to projects.json.
    root.flushRepositoryForTesting();
    const onDisk = projectNamesFromDisk(stateDir);
    assert(onDisk.length > 0 && onDisk[$ - 1] == commandLineConversationsProjectName,
        "the pinned command-line project was not persisted to projects.json: " ~
        onDisk.to!string);
    writeln("Pinned order persisted to projects.json: ", onDisk);

    writeln("command_line_project_rail_contracts: PASS");
    return 0;
}

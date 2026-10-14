module reorder_projects_probe;

// Focused headless probe for dragging a project row in the rail to rearrange
// the project order. Runs offline against a private state directory and drives
// the real mouse path (UiTestDriver), then checks the new order persists to
// projects.json.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;

import std.algorithm : equal;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, readText, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;

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

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

private bool paintProjection(OpenCodeRoot root, UiTestDriver driver)
{
    root.projectTranscriptForTesting();
    return driver.paint();
}

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

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-reorder-projects-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeState(stateDir);

    WindowOptions options;
    options.title = "Aurora reorder-projects probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(paintProjection(root, driver), "Initial paint failed");
    root.tickTree(0.02);

    // Two extra projects beside the always-present sandbox (rail index 0).
    root.addProjectForTesting("Alpha", buildPath(stateDir, "alpha"));
    root.addProjectForTesting("Beta", buildPath(stateDir, "beta"));
    root.tickTree(0.02);
    assert(paintProjection(root, driver), "Rail repaint failed");

    auto names = root.projectNamesForTesting();
    assert(names.length == 3, "rail should hold three projects");
    const sandboxName = names[0];
    assert(names[1] == "Alpha" && names[2] == "Beta",
        "unexpected initial project order");
    writeln("Initial order: ", names);

    auto projects = requireWidget!ListView(root, "oc-projects");
    const rh = projects.rowHeight();
    assert(rh > 0, "rail has no row height");

    // Drag the sandbox row (0) down past the last row to insert it at the end
    // (slot 3). The point sits in the lower half of the third row so the drop
    // slot is "after it".
    const from = projects.localToGlobal(Point(20, 0 * rh + rh / 2));
    const to = projects.localToGlobal(Point(20, 2 * rh + rh / 2 + 5));
    driver.drag(from, to);
    root.tickTree(0.02);
    assert(paintProjection(root, driver), "Post-drop repaint failed");

    auto reordered = root.projectNamesForTesting();
    assert(reordered.equal(["Alpha", "Beta", sandboxName]),
        "dragging the first project to the bottom did not reorder the rail: "
        ~ reordered.to!string);
    // The project dragged stays the active one (identity, not index).
    assert(root.activeProjectNameForTesting() == sandboxName,
        "the dragged project should remain active");
    writeln("Drag reordered the rail: ", reordered);

    // The new order must survive a save of projects.json.
    root.flushRepositoryForTesting();
    const onDisk = projectNamesFromDisk(stateDir);
    assert(onDisk.equal(reordered),
        "the reordered rail was not persisted to projects.json: "
        ~ onDisk.to!string);
    writeln("Reordered rail persisted to projects.json");

    // Moving a project down one slot (insertion slot 2) swaps the first two.
    root.reorderProjectForTesting(0, 2);
    root.tickTree(0.02);
    assert(root.projectNamesForTesting().equal(["Beta", "Alpha", sandboxName]),
        "moving a project down one slot did not swap the pair");

    // Dropping into the row's own slot is a no-op.
    root.reorderProjectForTesting(0, 1);
    assert(root.projectNamesForTesting().equal(["Beta", "Alpha", sandboxName]),
        "a drop inside the row's own slot must not reorder");
    writeln("Direct reorder + no-op verified");

    writeln("PASS: drag to rearrange projects works");
    return 0;
}

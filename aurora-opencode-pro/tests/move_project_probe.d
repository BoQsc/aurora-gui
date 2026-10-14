module move_project_probe;

// Focused headless probe for the "Move to project" conversation action and for
// dragging a conversation onto a project tile: both must retarget the
// conversation's project id. Runs offline against a private state directory.

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;

import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
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
    JSONValue sessions = JSONValue(string[].init);
    JSONValue session;
    session["id"] = "t-move-source";
    session["title"] = "Move source";
    session["model"] = "probe-model";
    session["thinking"] = false;
    JSONValue messages = JSONValue(string[].init);
    JSONValue message;
    message["role"] = "user";
    message["content"] = "hello";
    message["id"] = "mm-1";
    messages.array ~= message;
    session["messages"] = messages;
    session["activeLeaf"] = "mm-1";
    sessions.array ~= session;
    root["sessions"] = sessions;
    root["current"] = 0;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-move-project-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    writeState(stateDir);

    WindowOptions options;
    options.title = "Aurora move-project probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(paintProjection(root, driver), "Initial paint failed");
    root.tickTree(0.02);

    // The conversation menu must offer the move action.
    bool sawMove;
    foreach (label; root.sessionContextMenuLabelsForTesting(0))
        if (label == "Move to project") sawMove = true;
    assert(sawMove, "the conversation menu never offered 'Move to project'");
    writeln("Menu offers 'Move to project'");

    // Create a second project. addProjectForTesting activates it, so switch
    // back to the sandbox (index 0) to make the source conversation visible.
    root.addProjectForTesting("Target Project", buildPath(stateDir, "target"));
    root.tickTree(0.02);
    assert(root.projectCountForTesting() == 2, "rail should hold two projects");
    root.selectProjectForTesting(0);
    root.tickTree(0.02);
    assert(paintProjection(root, driver), "Sandbox repaint failed");
    assert(root.visibleSessionCountForTesting() == 1,
        "the sandbox conversation should be visible");

    auto sessions = requireWidget!SessionListView(root, "oc-sessions");
    auto projects = requireWidget!ListView(root, "oc-projects");
    const rowH = sessions.rowHeight();
    const railRowH = projects.rowHeight();

    const row = 0;
    const sessionIndex = root.visibleSessionIndexAtRowForTesting(row);
    assert(sessionIndex >= 0, "no conversation row to drag");
    // The restored conversation belongs to the sandbox project.
    const startedProject = root.sessionProjectForTesting(sessionIndex);
    assert(startedProject.length > 0,
        "the restored conversation has no project id");

    // Drag the conversation onto the 'Target Project' tile (rail index 1).
    const from = sessions.localToGlobal(Point(20, row * rowH + rowH / 2));
    const to = projects.localToGlobal(Point(20, 1 * railRowH + railRowH / 2));
    driver.moveTo(from);
    driver.mouseDown();
    driver.moveTo(to);
    root.tickTree(0.02);
    assert(root.sessionDragGhostForTesting().length > 0,
        "dragging over the rail should keep a ghost");
    const ghostAction = root.sessionDragGhostActionForTesting();
    assert(ghostAction.length >= 4 && ghostAction[0 .. 4] == "Move",
        "the drag ghost should announce the move, got '" ~ ghostAction ~ "'");
    writeln("Drag ghost announces: ", ghostAction);
    driver.mouseUp();
    root.tickTree(0.02);
    assert(paintProjection(root, driver), "Post-drop repaint failed");

    // The conversation must have left the sandbox and belong to the target.
    assert(root.sessionProjectForTesting(sessionIndex) != startedProject &&
        root.sessionProjectForTesting(sessionIndex).length > 0,
        "the drop did not retarget the conversation's project");
    assert(root.visibleSessionCountForTesting() == 0,
        "the moved conversation should leave the sandbox list");
    root.selectProjectForTesting(1);
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == 1,
        "the moved conversation should appear under the target project");
    writeln("Drag onto a project moves the conversation");

    // Move it back with the context-menu item (the cascading submenu child).
    const sandboxName = root.projectNamesForTesting()[0];
    assert(root.invokeSessionContextMenuItemForTesting(0, sandboxName),
        "'Move to project' did not offer the sandbox ('" ~ sandboxName ~ "')");
    root.tickTree(0.02);
    assert(root.sessionProjectForTesting(sessionIndex) == startedProject,
        "the context-menu move did not return the conversation to the sandbox");
    assert(root.visibleSessionCountForTesting() == 0,
        "the conversation should leave the target project's list");
    writeln("Context-menu 'Move to project' moves the conversation");

    // Persistence: a move must survive a save + reload.
    const targetName = root.projectNamesForTesting()[1];
    const movedId = root.sessionIdForTesting(sessionIndex);
    root.selectProjectForTesting(0);
    root.tickTree(0.02);
    assert(root.invokeSessionContextMenuItemForTesting(0, targetName),
        "'Move to project' did not offer '" ~ targetName ~ "'");
    root.tickTree(0.02);
    const movedProject = root.sessionProjectForTesting(sessionIndex);
    assert(movedProject.length > 0 && movedProject != startedProject,
        "the menu move did not retarget the conversation");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    root.tickTree(0.02);
    int reloaded = -1;
    foreach (i; 0 .. root.sessionCountForTesting())
        if (root.sessionIdForTesting(cast(int) i) == movedId)
        {
            reloaded = cast(int) i;
            break;
        }
    assert(reloaded >= 0, "the conversation vanished after a reload");
    assert(root.sessionProjectForTesting(reloaded) == movedProject,
        "the move did not survive a save + reload");
    writeln("Move persists across a save + reload");

    writeln("PASS: move to project works");
    return 0;
}

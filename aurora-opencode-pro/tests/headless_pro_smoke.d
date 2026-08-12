module auroraopencode_pro_headless_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.utf : toUTF32;

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

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private JSONValue makeSession(string title, string messageBody)
{
    JSONValue session;
    session["title"] = title;
    session["model"] = "deepseek-v4-flash";
    session["thinking"] = false;
    JSONValue messages = JSONValue(string[].init);
    JSONValue user;
    user["role"] = "user";
    user["content"] = "Hello";
    user["time"] = "09:00";
    messages.array ~= user;
    JSONValue assistant;
    assistant["role"] = "assistant";
    assistant["content"] = messageBody;
    assistant["time"] = "09:01";
    messages.array ~= assistant;
    session["messages"] = messages;
    return session;
}

private void writeStartupState(string stateDir)
{
    JSONValue root;
    JSONValue sessions = JSONValue(string[].init);
    sessions.array ~= makeSession("alpha one",
        "A [link](https://opencode.ai) and a code block:\n```d\nvoid main() {}\n```");
    sessions.array ~= makeSession("beta two", "Plain reply two.");
    sessions.array ~= makeSession("gamma three", "Plain reply three.");
    root["sessions"] = sessions;
    root["current"] = 1;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-pro-smoke-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    writeStartupState(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode Pro headless";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "Initial pro paint failed");
    root.tickTree(0.02);
    assert(driver.paint(), "Second pro paint failed");

    auto sessions = requireWidget!SessionListView(root, "oc-sessions");
    auto filter = requireWidget!TextField(root, "oc-filter");
    assert(root.sessionCountForTesting() == 3, "Expected 3 restored sessions");
    assert(sessions.items().length == 3, "Session list should show 3 rows");
    writeln("Restored sessions: ", sessions.items().length);

    // Filter narrows the list and remaps the selected row.
    filter.setText("beta");
    root.tickTree(0.02);
    assert(sessions.items().length == 1, "Filter did not narrow the list");
    assert(sessions.selectedIndex() == 0, "Filtered current row not selected");
    writeln("Filtered rows: ", sessions.items().length);
    filter.setText("");
    root.tickTree(0.02);
    assert(sessions.items().length == 3, "Clearing the filter did not restore rows");

    // Rename via the sidebar context menu.
    sessions.onContextMenuRequested(1, Point(10, 10));
    root.tickTree(0.02);
    auto menu = cast(ContextMenu) currentTransientPopup(root);
    assert(menu !is null, "Session context menu did not open");
    bool renamed;
    foreach (item; menu.items())
    {
        if (item.label == toUTF32("Rename…"))
        {
            item.action();
            renamed = true;
            break;
        }
    }
    assert(renamed, "Rename item missing from the context menu");
    root.tickTree(0.02);
    assert(driver.paint(), "Rename dialog did not paint after opening");
    auto renameField = requireWidget!TextField(root, "oc-rename-field");
    renameField.setText("Renamed chat");
    root.tickTree(0.02);
    assert(driver.paint(), "Rename field edit did not paint");
    auto renameSave = requireWidget!Button(root, "oc-rename-save");
    driver.click(globalCenter(renameSave));
    root.tickTree(0.02);
    assert(driver.paint(), "Rename dialog did not paint after save");
    assert(root.sessionTitleForTesting(1) == "Renamed chat",
        "Rename did not update the session title");
    writeln("Renamed session title: ", root.sessionTitleForTesting(1));

    // Delete a session via the list's Delete-key hook.
    sessions.onDeleteRequested(0);
    root.tickTree(0.02);
    assert(driver.paint(), "Delete did not repaint");
    assert(root.sessionCountForTesting() == 2, "Delete did not remove a session");
    assert(sessions.items().length == 2, "Session list did not shrink after delete");
    writeln("Sessions after delete: ", root.sessionCountForTesting());

    // Markdown bubbles (code blocks + links) paint and stay interactive.
    root.addConversationForTesting(
        ["assistant"],
        ["```d\nimport std.stdio;\nvoid main() { writeln(\"hi\"); }\n```"]);
    assert(driver.paint(), "Code bubble did not paint");
    writeln("Pro markdown bubble painted");

    root.shutdownClient();
    window.close();
    rmdirRecurse(stateDir);
    writeln("Aurora OpenCode Pro headless smoke test passed.");
    return 0;
}

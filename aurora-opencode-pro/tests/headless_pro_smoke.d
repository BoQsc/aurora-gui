module auroraopencode_pro_headless_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.time : msecs, seconds;
import core.thread : Thread;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
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
    session["model"] = "deepseek/deepseek-v4.1-flash";
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

    // Context meter starts empty: the restored replies have no API usage yet.
    auto usageBadge = requireWidget!Widget(root, "oc-usage");
    assert(root.contextUsageTextForTesting() == "ctx",
        "Context badge should read ctx until usage is reported");
    writeln("Context badge initially: ", root.contextUsageTextForTesting());

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
    dismissTransientPopups(root);
    root.tickTree(0.02);

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

    // Thinking blocks: collapsed to a slim "Thinking" header by default (like
    // the original opencode app), expand/collapse on click, and the animation
    // clock advances while live.
    root.addConversationForTestingWithReasoning(
        ["assistant"], ["The answer."], ["Let me reason about this first."]);
    assert(root.lastThinkingCollapsedForTesting(),
        "Thinking block should start collapsed");
    root.toggleLastThinkingForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded thinking did not repaint");
    assert(!root.lastThinkingCollapsedForTesting(),
        "Thinking block did not expand on toggle");
    root.toggleLastThinkingForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapsed thinking did not repaint");
    assert(root.lastThinkingCollapsedForTesting(),
        "Thinking block did not collapse again");
    writeln("Thinking blocks collapse by default and expand on click");

    // Chat quality: only the latest assistant reply carries the action pill
    // (Regenerate / Retry); user messages and older bubbles stay clean. Edit &
    // resend is available from the right-click context menu instead.
    root.addConversationForTesting(["user"], ["A new user message."]);
    assert(root.lastBubbleActionForTesting() == "",
        "User message should not carry an action pill");
    root.addConversationForTesting(["assistant"], ["A normal reply."]);
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Latest assistant reply did not get the Regenerate pill");
    // Older bubbles (including the user message) have no visible pill.
    const count = root.messageCountForTesting();
    assert(root.bubbleActionForTesting(cast(int) count - 2) == "",
        "Older user bubble should not carry an action pill");
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an assistant reply");
    // After dropping the reply, the user message is the last bubble and has no
    // pill; the Regenerate action is back on the context menu.
    assert(root.lastBubbleActionForTesting() == "",
        "After regenerate the last bubble should have no pill");
    const countAfterRegenerate = root.messageCountForTesting();

    // Edit & resend the newest user message via the right-click context menu.
    root.openMessageContextMenuForTesting(countAfterRegenerate - 1);
    root.tickTree(0.02);
    assert(driver.paint(), "Message context menu did not paint");
    auto messageMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(messageMenu !is null, "Message context menu did not open");
    bool edited;
    foreach (item; messageMenu.items())
    {
        if (item.label == toUTF32("Edit & resend"))
        {
            item.action();
            edited = true;
            break;
        }
    }
    assert(edited, "Edit & resend missing from the message context menu");
    root.tickTree(0.02);
    assert(driver.paint(), "Edit & resend did not repaint");
    dismissContextMenus(root);
    root.tickTree(0.02);
    assert(root.messageCountForTesting() == countAfterRegenerate - 1,
        "Edit & resend did not truncate at the user message");
    assert(root.inputTextForTesting() == "A new user message.",
        "Edit & resend did not prefill the input");
    writeln("Edit & resend prefilled input: ", root.inputTextForTesting());

    // Regression: the context menu on an older user message targets THAT
    // message, not the last one (D foreach closure capture bug).
    root.addConversationForTesting(
        ["user", "assistant", "user"],
        ["edit me zero", "reply one", "edit me two"]);
    const menuCount = root.messageCountForTesting();
    root.openMessageContextMenuForTesting(cast(int) menuCount - 3);
    root.tickTree(0.02);
    auto olderMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(olderMenu !is null, "Older message context menu did not open");
    bool olderEdited;
    foreach (item; olderMenu.items())
    {
        if (item.label == toUTF32("Edit & resend"))
        {
            item.action();
            olderEdited = true;
            break;
        }
    }
    assert(olderEdited, "Older message Edit & resend missing");
    root.tickTree(0.02);
    dismissContextMenus(root);
    root.tickTree(0.02);
    assert(root.inputTextForTesting() == "edit me zero",
        "Older message Edit & resend targeted the wrong message");
    assert(root.messageCountForTesting() == cast(int) menuCount - 3,
        "Older message Edit & resend did not truncate at its own message");
    writeln("Context menu targets its own message (no foreach capture bug)");

    // Regenerate still works after an edit.
    root.addConversationForTesting(
        ["assistant"], ["A reply that will be regenerated."]);
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an edit");
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Pill did not refresh after the final regenerate");
    writeln("Chat-quality pill stays on the latest assistant reply");

    // Context usage meter: the toolbar badge shows the exact API usage as a
    // percentage of the model's context window, and hovering opens a tooltip
    // with the full breakdown (mirrors the real opencode indicator). The
    // limit comes from the CommandCode model catalog: deepseek/deepseek-v4.1-flash
    // has a 1,000,000-token context window.
    root.addConversationForTesting(["assistant"], ["A reply that used tokens."]);
    root.recordContextUsageForTesting(240000, 10000, 250000);
    assert(driver.paint(), "Context badge did not paint after usage");
    assert(root.contextUsageTextForTesting() == "25%",
        "Badge should show 250000/1000000 = 25%");
    writeln("Context badge after usage: ", root.contextUsageTextForTesting());

    assert(!root.isContextTooltipOpenForTesting(),
        "Tooltip must be closed before hovering the badge");
    driver.moveTo(globalCenter(usageBadge));
    root.tickTree(0.02);
    assert(driver.paint(), "Tooltip did not paint after hover");
    assert(root.isContextTooltipOpenForTesting(),
        "Hovering the badge did not open the context tooltip");
    const tooltip = root.contextTooltipTextForTesting();
    assert(tooltip.length > 0, "Context tooltip text is empty");
    assert(tooltip.indexOf("Context usage") >= 0, "Tooltip lacks the title");
    assert(tooltip.indexOf("deepseek/deepseek-v4.1-flash") >= 0,
        "Tooltip lacks the model");
    assert(tooltip.indexOf("1,000,000") >= 0, "Tooltip lacks the context limit");
    assert(tooltip.indexOf("250,000") >= 0, "Tooltip lacks the used tokens");
    assert(tooltip.indexOf("25%") >= 0, "Tooltip lacks the usage percent");
    assert(tooltip.indexOf("240,000") >= 0, "Tooltip lacks the prompt tokens");
    writeln("Context tooltip shows the usage breakdown on hover");

    // Moving away from the badge dismisses the tooltip.
    driver.moveTo(Point(4, 700));
    root.tickTree(0.02);
    assert(driver.paint(), "Tooltip did not repaint after leaving");
    assert(!root.isContextTooltipOpenForTesting(),
        "Leaving the badge did not dismiss the context tooltip");

    // The meter follows the active session: a session without recorded usage
    // resets the badge, and switching back restores the persisted count.
    sessions.onSelectionChanged(1);
    root.tickTree(0.02);
    assert(root.contextUsageTextForTesting() == "ctx",
        "Badge should reset for a session without usage");
    sessions.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.contextUsageTextForTesting() == "25%",
        "Badge should restore the persisted usage for the session");
    writeln("Context meter follows the active session");

    // --- Projects -------------------------------------------------------
    // The sandbox is the default project (first in the rail) and owns the
    // restored chats. Creating, switching, persisting, and removing projects
    // must all keep each project's conversation list separate.
    auto projects = requireWidget!ListView(root, "oc-projects");
    const sandboxVisible = root.visibleSessionCountForTesting();
    assert(root.projectCountForTesting() == 1,
        "Expected only the sandbox project");
    assert(root.projectNamesForTesting()[0] == "Sandbox",
        "Sandbox must be the first project");
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Sandbox must be active by default");
    assert(root.activeProjectPathForTesting().indexOf("sandbox") >= 0,
        "Sandbox folder should live under the state directory: " ~
        root.activeProjectPathForTesting());
    assert(projects.items().length == 1, "Rail should show one project tile");
    writeln("Sandbox is the default project: ",
        root.activeProjectPathForTesting());

    // The merged custom titlebar owns the top band and the project rail starts
    // collapsed to icon width; the toggle expands it and the state persists.
    assert(root.hasCustomTitleBarForTesting(),
        "The merged custom titlebar should own the top band");
    assert(root.projectsRailCollapsedForTesting(),
        "Project rail should start collapsed");
    assert(root.projectsRailWidthForTesting() <= 48,
        "Collapsed rail should be icon width, got " ~
        to!string(root.projectsRailWidthForTesting()));
    root.toggleProjectsRailForTesting();
    root.tickTree(0.02);
    assert(!root.projectsRailCollapsedForTesting(),
        "Toggling should expand the rail");
    assert(root.projectsRailWidthForTesting() > 48,
        "Expanded rail should be wider than icon width");
    auto railJson = parseJSON(readText(buildPath(stateDir, "projects.json")));
    assert(railJson["projectsCollapsed"].type == JSONType.false_,
        "Expanded rail state was not persisted");
    root.toggleProjectsRailForTesting();
    root.tickTree(0.02);
    assert(root.projectsRailCollapsedForTesting(),
        "Toggling again should collapse the rail");
    assert(driver.paint(), "Rail toggle did not repaint");
    writeln("Project rail collapses to icon width and persists its state");

    // Create a project through the real dialog.
    root.openNewProjectDialogForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "New project dialog did not paint");
    auto projectName = requireWidget!TextField(root, "oc-project-name");
    auto projectPath = requireWidget!TextField(root, "oc-project-path-input");
    const projectDir = buildPath(stateDir, "proj-one");
    projectName.setText("proj-one");
    projectPath.setText(projectDir);
    root.tickTree(0.02);
    driver.click(globalCenter(requireWidget!Button(root, "oc-project-create")));
    root.tickTree(0.02);
    assert(driver.paint(), "New project dialog did not paint after create");
    assert(root.projectCountForTesting() == 2,
        "The dialog did not create the project");
    assert(projects.items().length == 2, "Rail did not gain a tile");
    assert(root.activeProjectNameForTesting() == "proj-one",
        "The new project should become active");
    assert(root.visibleSessionCountForTesting() == 0,
        "A new project starts with no conversations");
    assert(exists(projectDir), "Project folder was not created");
    writeln("Created project: ", root.activeProjectNameForTesting());

    // New chats belong to the active project.
    root.newChatForTesting();
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == 1,
        "New chat is missing from the project list");
    const projectChat = cast(int) root.sessionCountForTesting() - 1;
    assert(root.sessionProjectForTesting(projectChat) ==
        root.activeProjectIdForTesting(),
        "New chat was not tagged with the active project");

    // Switching tiles swaps in that project's own conversation list.
    projects.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Tile 0 must select the sandbox");
    assert(root.visibleSessionCountForTesting() == sandboxVisible,
        "Sandbox did not restore its own conversations");
    projects.onSelectionChanged(1);
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == 1,
        "Switching back did not show the project's chat");
    writeln("Project switching filters the conversation list");

    assert(exists(buildPath(stateDir, "projects.json")),
        "projects.json was not written");

    // The sessions/chat divider is a draggable SplitPane and its width is
    // persisted so the layout survives a restart.
    auto split = requireWidget!SplitPane(root, "oc-split");
    const ratioBefore = root.sessionsRatioForTesting();
    assert(split.ratio() == ratioBefore, "Split ratio accessor mismatch");
    assert(ratioBefore > 0.1 && ratioBefore < 0.5,
        "Unexpected default split ratio: " ~ to!string(ratioBefore));
    root.dragSessionsDividerForTesting(120);
    root.tickTree(0.02);
    assert(root.sessionsRatioForTesting() > ratioBefore,
        "Dragging did not widen the conversation list");
    auto projectsJson = parseJSON(readText(buildPath(stateDir, "projects.json")));
    assert(projectsJson["sessionsRatio"].floating > ratioBefore,
        "Split ratio was not persisted");
    assert(driver.paint(), "Split drag did not repaint");
    writeln("Sessions column is draggable and its width persists");

    // Removing a project moves its chats to the sandbox.
    root.removeProjectForTesting(1);
    root.tickTree(0.02);
    assert(root.projectCountForTesting() == 1, "Project was not removed");
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Removing the active project should fall back to the sandbox");
    projects.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == sandboxVisible + 1,
        "The removed project's chats were not reassigned to the sandbox");
    writeln("Removing a project reassigns its chats to the sandbox");

    // Native tools are the main mode; Legacy tools live in Settings with a
    // hover tooltip, not in the toolbar.
    auto legacyCheck = root.legacyToolsCheckboxForTesting();
    assert(legacyCheck !is null, "Settings dialog missing the Legacy tools checkbox");
    assert(!legacyCheck.checked(), "Legacy tools should be off by default");
    const legacyTip = root.legacyToolsTooltipForTesting();
    assert(legacyTip.indexOf("bash") >= 0,
        "Legacy tools tooltip should explain the shell tool: " ~ legacyTip);
    writeln("Legacy tools checkbox + tooltip present in Settings");

    // Tool loop: with tools enabled and a workspace, an injected tool call is
    // executed locally and the result lands as a `tool` role message.
    auto workspaceDir = buildPath(stateDir, "workspace");
    mkdirRecurse(workspaceDir);
    write(buildPath(workspaceDir, "notes.txt"), "hello tool world\n");
    root.enableToolsForTesting(workspaceDir);
    root.pauseToolContinuationForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["What is in notes.txt?"]);
    // The client creates an assistant message (chatBegin) before delivering
    // toolCalls, so mirror that shape here.
    root.addConversationForTesting(["assistant"], [""]);
    OpenCodeToolCall readCall;
    readCall.id = "call_test_1";
    readCall.name = "read";
    readCall.arguments = `{"filePath":"notes.txt"}`;
    OpenCodeToolCall grepCall;
    grepCall.id = "call_test_2";
    grepCall.name = "grep";
    grepCall.arguments = `{"pattern":"tool"}`;
    root.injectToolCallsForTesting([readCall, grepCall]);
    // The tool worker runs on a background thread; tick the tree so onTick
    // drains the results, up to a short deadline.
    const deadline = Clock.currTime + 5.seconds;
    while (root.toolMessageCountForTesting() < 2 && Clock.currTime < deadline)
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    assert(root.toolMessageCountForTesting() == 2,
        "Tool results did not arrive as tool role messages");
    assert(root.toolResultForTesting(0).indexOf("hello tool world") >= 0,
        "read tool did not return the file contents: " ~
        root.toolResultForTesting(0));
    assert(root.toolResultForTesting(1).indexOf("notes.txt") >= 0,
        "grep tool did not find the matching file");
    assert(driver.paint(), "Tool bubble did not paint");
    writeln("Tool loop executed read + grep and landed two tool messages");
    assert(root.messageCountForTesting() >= 3,
        "Tool loop did not append the tool messages to the session");
    writeln("Tool loop preserved the session history");

    // The tool-call wrapper (the assistant message that requested tools) is
    // not a reply: it must not render as a visible empty bubble, and must not
    // carry an action pill or token usage even if usage streamed first.
    foreach (index; 0 .. root.messageCountForTesting())
    {
        if (root.messageRoleForTesting(index) != "assistant") continue;
        assert(root.bubbleActionForTesting(index) == "",
            "Tool-call wrapper must not carry an action pill");
        assert(!root.bubbleHasUsageForTesting(index),
            "Tool-call wrapper must not show token usage");
        assert(root.bubbleHiddenForTesting(index),
            "Empty tool-call wrapper must not render as a visible bubble");
    }
    writeln("Tool-call wrapper is hidden, no pill, no token usage");

    // Doom-loop recovery: repeating the same tool call with identical input
    // must break the loop and inject a recovery message asking for an answer,
    // instead of running tools forever until the round cap.
    root.addConversationForTesting(["assistant"], [""]);
    const userCountBefore = root.userMessageCountForTesting();
    OpenCodeToolCall loopCall;
    loopCall.id = "call_loop";
    loopCall.name = "dshell";
    loopCall.arguments = `{"command":"list"}`;
    root.injectToolCallsForTesting([loopCall]);
    root.injectToolCallsForTesting([loopCall]);
    assert(root.toolRepeatCountForTesting() == 2,
        "Repeat count did not accumulate: " ~
        to!string(root.toolRepeatCountForTesting()));
    root.injectToolCallsForTesting([loopCall]);
    root.tickTree(0.02);
    // The third identical call triggers recovery: a recovery user message is
    // injected and the loop stops running tools.
    assert(root.userMessageCountForTesting() == userCountBefore + 1,
        "Doom-loop recovery did not inject a recovery message");
    assert(root.toolRepeatCountForTesting() == 0,
        "Doom-loop recovery did not reset the repeat counter");
    writeln("Doom-loop recovery breaks repeated identical tool calls");

    // Tool outputs start collapsed (a compact header) and expand on click.
    assert(root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble should start collapsed");
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded tool bubble did not repaint");
    assert(!root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble did not expand on toggle");
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapsed tool bubble did not repaint");
    assert(root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble did not collapse again");
    writeln("Tool outputs collapse by default and expand on click");

    // Regression: expanding/collapsing a tool output must NOT snap the scroll
    // to the bottom. Scroll up, expand, and confirm the offset is preserved.
    const beforeScroll = root.scrollYForTesting();
    if (beforeScroll > 0)
    {
        root.scrollToForTesting(maxInt(0, beforeScroll / 2));
        root.tickTree(0.02);
        assert(driver.paint(), "Scroll-up did not repaint");
    }
    const midScroll = root.scrollYForTesting();
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expand did not repaint after scroll-up");
    const afterExpandScroll = root.scrollYForTesting();
    // Allow a tiny clamp drift (the max may shrink), but never a jump to the
    // bottom when the expanded bubble is above the fold.
    assert(afterExpandScroll <= midScroll + 4,
        "Expanding a tool output snapped the scroll down: " ~
        to!string(midScroll) ~ " -> " ~ to!string(afterExpandScroll));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapse did not repaint after scroll-up");
    writeln("Tool collapse/expand preserves the scroll position");

    const shotDir = buildPath(tempDir(), "aurora-opencode-collapse-shots");
    if (!exists(shotDir)) mkdirRecurse(shotDir);
    window.saveScreenshot(buildPath(shotDir, "tool-collapsed.ppm"));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded tool bubble did not repaint");
    window.saveScreenshot(buildPath(shotDir, "tool-expanded.ppm"));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    writeln("Collapse screenshots: ", shotDir);

    root.shutdownClient();
    window.close();
    try rmdirRecurse(stateDir);
    catch (Exception) {}
    writeln("Aurora OpenCode Pro headless smoke test passed.");
    return 0;
}

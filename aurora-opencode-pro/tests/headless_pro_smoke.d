module auroraopencode_pro_headless_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.time : msecs, seconds;
import core.thread : Thread;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
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

    // Chat quality: every message bubble carries its action pill.
    root.addConversationForTesting(["user"], ["A new user message."]);
    assert(root.lastBubbleActionForTesting() == "Edit & resend",
        "User message did not get the Edit & resend pill");
    root.addConversationForTesting(["assistant"], ["A normal reply."]);
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Assistant reply did not get the Regenerate pill");
    // Both the user bubble and the assistant reply keep their pills.
    const count = root.messageCountForTesting();
    assert(root.bubbleActionForTesting(cast(int) count - 2) == "Edit & resend",
        "User bubble lost its Edit & resend pill");
    assert(root.bubbleActionForTesting(cast(int) count - 1) == "Regenerate",
        "Assistant bubble lost its Regenerate pill");
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an assistant reply");
    assert(root.lastBubbleActionForTesting() == "Edit & resend",
        "Pill did not return to Edit & resend after regenerate");
    const countAfterRegenerate = root.messageCountForTesting();

    // Edit & resend the newest user message.
    root.editAndResendForTesting(countAfterRegenerate - 1);
    root.tickTree(0.02);
    assert(driver.paint(), "Edit & resend did not repaint");
    assert(root.messageCountForTesting() == countAfterRegenerate - 1,
        "Edit & resend did not truncate at the user message");
    assert(root.inputTextForTesting() == "A new user message.",
        "Edit & resend did not prefill the input");
    writeln("Edit & resend prefilled input: ", root.inputTextForTesting());

    // Regression: invoking a bubble's action pill must target THAT bubble's
    // message, not the last one (D foreach closures capture the reused loop
    // slot, which silently bound every pill to the final message).
    root.addConversationForTesting(
        ["user", "assistant", "user"],
        ["edit me zero", "reply one", "edit me two"]);
    const pillsCount = root.messageCountForTesting();
    assert(root.bubbleActionForTesting(cast(int) pillsCount - 3) ==
        "Edit & resend", "Bubble 0 should carry Edit & resend");
    // Clicking bubble 0's pill truncates at message 0 and prefills its text.
    assert(root.invokeBubbleActionForTesting(cast(int) pillsCount - 3),
        "Bubble 0 action pill did not fire");
    root.tickTree(0.02);
    assert(driver.paint(), "Bubble 0 action did not repaint");
    assert(root.inputTextForTesting() == "edit me zero",
        "Bubble 0 pill did not prefill its own message (foreach capture bug)");
    assert(root.messageCountForTesting() == cast(int) pillsCount - 3,
        "Bubble 0 pill did not truncate at its own message");
    writeln("Pill targets its own message (no foreach capture bug)");

    // Regenerate still works after an edit.
    root.addConversationForTesting(
        ["assistant"], ["A reply that will be regenerated."]);
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an edit");
    assert(root.messageCountForTesting() == countAfterRegenerate - 1,
        "Regenerate did not remove the assistant reply");
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Pill did not refresh after the final regenerate");
    writeln("Chat-quality pills stay consistent on every message");

    // Context usage meter: the toolbar badge shows the exact API usage as a
    // percentage of the model's context window, and hovering opens a tooltip
    // with the full breakdown (mirrors the real opencode indicator). The
    // limit comes from the official opencode model catalog: deepseek-v4-flash
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
    assert(tooltip.indexOf("deepseek-v4-flash") >= 0, "Tooltip lacks the model");
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

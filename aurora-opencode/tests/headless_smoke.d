module auroraopencode_headless_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.conv : to;
import std.utf : toUTF8;

private Widget findById(Widget root, string requestedId)
{
    if (root is null) return null;
    if (root.id() == requestedId) return root;
    foreach (child; root.children())
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

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-smoke-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode headless";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "Initial opencode paint failed");
    root.tickTree(0.02);

    auto keyBadge = requireWidget!Label(root, "oc-key");
    auto sessions = requireWidget!ListView(root, "oc-sessions");
    auto messages = requireWidget!VBox(root, "oc-messages");
    auto input = requireWidget!TextArea(root, "oc-input");
    auto sendButton = requireWidget!Button(root, "oc-send");
    auto modelButton = requireWidget!Button(root, "oc-model");
    auto newChatButton = requireWidget!Button(root, "oc-new");

    writeln("Key badge: ", keyBadge.text());
    writeln("Model button: ", modelButton.text());
    writeln("Initial message count: ", messages.children().length);
    assert(sessions.items().length == 0, "Expected an empty session list at startup");

    // New chat
    driver.click(globalCenter(newChatButton));
    root.tickTree(0.02);
    assert(driver.paint(), "New chat did not paint");
    assert(sessions.items().length == 1, "New chat did not create a session");

    // Type and send
    input.requestFocus();
    root.tickTree(0.02);
    driver.text("Say exactly: AURORA-OPENCODE-GUI-OK");
    root.tickTree(0.02);
    const typedText = input.textUtf8();
    writeln("Typed text: ", typedText);
    assert(typedText.length > 0, "Text input did not reach the chat field");
    driver.pressKey(Key.enter);
    root.tickTree(0.02);
    assert(driver.paint(), "Send did not paint");
    const bubblesAfterSend = messages.children().length;
    writeln("Bubbles after send: ", bubblesAfterSend);
    assert(bubblesAfterSend >= 1, "No user bubble after send");
    assert(input.textUtf8().length == 0, "Input not cleared after send");
    assert(sendButton.text() == "Stop" || sendButton.text() == "Send",
        "Unexpected send button label");

    // Wait for the streaming reply.
    const deadline = MonoTime.currTime + seconds(150);
    bool finished;
    while (MonoTime.currTime < deadline)
    {
        root.tickTree(0.03);
        Thread.sleep(30.msecs);
        if (toUTF8(sendButton.text()) == "Send")
        {
            finished = true;
            break;
        }
    }
    assert(finished, "Assistant reply did not finish within 150 s");

    const finalBubbles = messages.children().length;
    writeln("Final bubble count: ", finalBubbles);
    assert(finalBubbles >= 2, "Assistant bubble missing after reply");

    // Layout (and therefore bounds) is applied during paint.
    assert(driver.paint(), "Final paint failed");
    root.tickTree(0.02);

    // Bubbles must be laid out with real size, otherwise text is invisible.
    foreach (child; messages.children())
    {
        assert(child.bounds().height > 0,
            "A message bubble has zero height and is not visible");
        assert(child.bounds().width > 0,
            "A message bubble has zero width and is not visible");
    }
    writeln("All bubbles have non-zero layout size");

    const lastContent = root.lastAssistantContentForTesting();
    writeln("Last assistant content length: ", lastContent.length);
    assert(lastContent.length > 0, "Assistant reply was empty");

    // Model picker popup opens with models.
    driver.click(globalCenter(modelButton));
    root.tickTree(0.02);
    assert(driver.paint(), "Model picker did not paint");
    auto popup = currentTransientPopup(root);
    assert(popup !is null, "Model picker popup did not open");
    writeln("Model picker popup opened");
    // Dismiss it.
    popup.dismiss();
    root.tickTree(0.02);

    // Scrollbar: a long conversation overflows the chat area; auto-follow pins
    // the view to the bottom, and dragging the scrollbar must let the user
    // scroll up without being snapped back down.
    {
        string[] roles;
        string[] contents;
        foreach (index; 0 .. 40)
        {
            roles ~= index % 2 == 0 ? "user" : "assistant";
            contents ~= "Message number " ~ to!string(index);
        }
        root.addConversationForTesting(roles, contents);
        assert(driver.paint(), "Long conversation did not paint");
        auto scrollWidget = requireWidget!ScrollView(root, "oc-scroll");
        assert(scrollWidget.maxScroll() > 0,
            "Long conversation did not overflow the chat area");
        assert(scrollWidget.scrollY() == scrollWidget.maxScroll(),
            "Auto-follow did not pin the view to the bottom");
        writeln("Auto-follow at bottom: ", scrollWidget.scrollY(), "/",
            scrollWidget.maxScroll());

        // Drag the scrollbar thumb from near the bottom to near the top.
        const origin = scrollWidget.localToGlobal(Point(0, 0));
        const scrollbarX = origin.x + scrollWidget.bounds().width - 12;
        const from = Point(scrollbarX, origin.y + scrollWidget.bounds().height - 12);
        const to = Point(scrollbarX, origin.y + 12);
        driver.drag(from, to, 8);
        root.tickTree(0.02);
        assert(driver.paint(), "Scrollbar drag did not repaint");
        writeln("Scroll after drag: ", scrollWidget.scrollY(), "/",
            scrollWidget.maxScroll());
        assert(scrollWidget.scrollY() < scrollWidget.maxScroll() - 20,
            "Scrollbar drag could not scroll away from the bottom");

        // The next layout pass must not snap back to the bottom.
        assert(driver.paint(), "Post-drag layout paint failed");
        assert(scrollWidget.scrollY() < scrollWidget.maxScroll() - 20,
            "Auto-follow snapped the scrollbar back after the user scrolled up");
        writeln("Scroll position persisted after layout");
    }

    // Sessions persisted.
    const sessionsPath = buildPath(stateDir, "sessions.json");
    assert(exists(sessionsPath), "sessions.json was not written");
    const settingsPath = buildPath(stateDir, "settings.json");
    assert(exists(settingsPath), "settings.json was not written");
    writeln("State persisted to ", stateDir);
    writeln("Session count: ", root.sessionCountForTesting());

    // Persistence round-trip: a fresh root reloads the session.
    auto window2 = new GuiWindow(options, opencodeTheme());
    auto root2 = new OpenCodeRoot(window2);
    window2.setRoot(root2);
    root2.tickTree(0.02);
    assert(root2.sessionCountForTesting() == 1,
        "Restored session count mismatch");
    assert(root2.lastAssistantContentForTesting().length > 0,
        "Restored assistant content missing");
    window2.close();

    writeln("Aurora OpenCode headless smoke test passed.");
    return 0;
}

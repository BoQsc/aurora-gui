module thinking_mode_switch_contracts;

// Regression: the composer Thinking selector must show the mode that is
// actually in effect for the open conversation, and switching conversations
// must not rewrite the saved app-wide mode.
//
// A per-route Off has to win over a conversation's older `true` flag. Otherwise
// the selector printed "Thinking: Low" (thinkingEffortLabel's fallback for the
// route's "off" record) while the request sent the model's default effort, and
// the label changed on every switch between that chat and one whose flag was
// already false.
//
// This drives the real widgets: a right click on the composer selector, the
// dropdown rows, the New chat button and the sidebar rows, then reads the text
// the selector actually renders.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets \
//       -of=build/thinking_mode_switch_contracts.exe \
//       aurora-opencode-pro/tests/thinking_mode_switch_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/thinking_mode_switch_contracts.exe

import aurora;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : Settings, saveSettings, loadSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.time : MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
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

int main()
{
    const stateDir = buildPath(tempDir, "aurora-opencode-thinking-switch");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    // Point the app's settings at a throwaway directory.
    setOpencodeStateDirectoryForTesting(stateDir);

    Settings seeded;
    seeded.model = "deepseek-v4.1-flash";
    seeded.thinking = true;
    saveSettings(seeded);

    WindowOptions options;
    options.title = "thinking mode switch contracts";
    options.width = 1100;
    options.height = 800;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    scope (exit)
    {
        root.shutdownClient();
        window.close();
    }
    const deadline = MonoTime.currTime + seconds(30);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
        root.tickTree(0.02);
    assert(!root.startupPendingForTesting(), "startup restore did not finish");

    void settle()
    {
        root.tickTree(0.02);
        driver.paint();
    }

    Point globalCenter(Widget widget)
    {
        const origin = widget.localToGlobal(Point(0, 0));
        return Point(origin.x + widget.bounds().width / 2,
            origin.y + widget.bounds().height / 2);
    }

    ContextMenu openThinkingMenu()
    {
        auto control = requireWidget!Widget(root, "oc-thinking");
        driver.click(globalCenter(control), MouseButton.right);
        settle();
        auto menu = cast(ContextMenu) currentTransientPopup(root);
        assert(menu !is null, "a right click on Thinking did not open its menu");
        return menu;
    }

    settle();

    // Click New chat, then choose High through the real dropdown.
    driver.click(globalCenter(requireWidget!Widget(root, "oc-new")));
    settle();
    const chatA = root.currentSessionForTesting();
    assert(chatA >= 0, "the New chat button did not create chat A");
    auto menu = openThinkingMenu();
    assert(menu.items().length >= 5, "Thinking menu lost its mode rows");
    menu.items()[4].action(); // High
    settle();
    assert(root.thinkingControlTextForTesting() == "Thinking: High",
        "selector did not render the clicked High mode: " ~
        root.thinkingControlTextForTesting());
    assert(root.thinkingMenuModeForTesting() == "high",
        "dropdown did not mark High as chosen: " ~
        root.thinkingMenuModeForTesting());
    assert(root.requestReasoningForTesting() == "on:high",
        "request did not carry High: " ~ root.requestReasoningForTesting());

    // New chat again, then click Off. The new chat inherits the mode in effect,
    // and the label must follow the click at once instead of waiting for the
    // next conversation switch.
    driver.click(globalCenter(requireWidget!Widget(root, "oc-new")));
    settle();
    const chatB = root.currentSessionForTesting();
    assert(chatB >= 0 && chatB != chatA, "the New chat button did not create chat B");
    assert(root.thinkingControlTextForTesting() == "Thinking: High",
        "a new chat did not render the mode in effect: " ~
        root.thinkingControlTextForTesting());
    menu = openThinkingMenu();
    assert(menu.items()[4].checked, "the dropdown did not mark the inherited High mode");
    menu.items()[1].action(); // Off
    settle();
    assert(root.thinkingControlTextForTesting() == "Thinking: Off",
        "selector did not render Off after clicking it: " ~
        root.thinkingControlTextForTesting());
    assert(root.requestReasoningForTesting() == "off",
        "request still carried reasoning after clicking Off: " ~
        root.requestReasoningForTesting());

    // Click back to chat A through the sidebar. Its own flag is still `true`,
    // but the explicit per-route Off is what is actually sent. The label used
    // to fall back to "Thinking: Low" here (and the dropdown marked no row at
    // all), which is the change seen when switching conversations.
    auto sessions = requireWidget!SessionListView(root, "oc-sessions");
    int rowForSession(int sessionIndex)
    {
        foreach (row; 0 .. cast(int) sessions.items().length)
            if (root.visibleSessionIndexAtRowForTesting(row) == sessionIndex)
                return row;
        return -1;
    }
    bool sawA;
    const rowA = rowForSession(chatA);
    assert(rowA >= 0, "the sidebar did not list chat A");
    driver.click(sessions.rowCenterForTesting(rowA));
    settle();
    if (root.currentSessionForTesting() == chatA)
    {
        sawA = true;
        assert(root.activeSessionThinkingForTesting(),
            "fixture lost chat A's own Thinking flag");
        assert(root.thinkingControlTextForTesting() == "Thinking: Off",
            "route Off did not win over the chat's stale flag: " ~
            root.thinkingControlTextForTesting());
        assert(root.thinkingMenuModeForTesting() == "off",
            "dropdown did not mark Off for the route: " ~
            root.thinkingMenuModeForTesting());
        assert(root.requestReasoningForTesting() == "off",
            "request did not follow the route Off: " ~
            root.requestReasoningForTesting());
        menu = openThinkingMenu();
        assert(menu.items()[1].checked && !menu.items()[4].checked,
            "the dropdown did not check Off for the stale-flag chat");
        dismissContextMenus(root);
        settle();
    }
    assert(sawA, "clicking the sidebar did not open chat A");

    // Opening a conversation must not rewrite the saved app-wide mode. Before
    // the fix, selecting chat A copied its `true` flag into Settings, and the
    // next debounced settings write persisted it.
    assert(!root.settingsThinkingForTesting(),
        "opening a conversation rewrote the in-memory Thinking switch");
    root.flushSettingsForTesting();
    auto saved = loadSettings();
    assert(!saved.thinking,
        "opening a conversation rewrote the saved Thinking switch");
    assert(!saved.reasoningControls.length ||
        saved.reasoningControls[0].effort == "off",
        "opening a conversation changed the saved route record");

    // Click through to chat B: the two conversations now show the same mode,
    // so switching does not change the selector.
    sessions = requireWidget!SessionListView(root, "oc-sessions");
    const rowB = rowForSession(chatB);
    assert(rowB >= 0, "the sidebar did not list chat B");
    bool sawB;
    driver.click(sessions.rowCenterForTesting(rowB));
    settle();
    if (root.currentSessionForTesting() == chatB)
    {
        sawB = true;
        assert(root.thinkingControlTextForTesting() == "Thinking: Off",
            "switching back to chat B changed the displayed mode: " ~
            root.thinkingControlTextForTesting());
        assert(root.requestReasoningForTesting() == "off",
            "chat B stopped following the chosen Off: " ~
            root.requestReasoningForTesting());
    }
    assert(sawB, "clicking the sidebar did not open chat B");

    writeln("PASS thinking mode stays Off across a conversation switch and " ~
        "matches the saved choice");
    writeln("PASS a per-route Off wins over a chat's stale Thinking flag");
    writeln("thinking_mode_switch_contracts: PASS");
    return 0;
}

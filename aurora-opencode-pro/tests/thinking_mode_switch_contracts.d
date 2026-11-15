module thinking_mode_switch_contracts;

// Regression: Thinking mode belongs to the conversation it was set in. Each
// chat keeps its own Off/Low/Medium/High, the composer shows that chat's mode
// after a switch, and the outgoing request carries the same mode.
//
// The old model stored only a per-chat boolean and resolved the level from a
// global endpoint/model record, so choosing Off or High in one chat changed
// what every other chat on that model displayed.
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
import auroraopencode.conversationcodec : decodeSessionMetadata;
import auroraopencode.conversationencode : sessionMetaToJson;
import auroraopencode.core : ChatSession, Settings, saveSettings, loadSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.time : MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.json : parseJSON;
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

    // Click New chat, then choose High through the real dropdown. This mode
    // belongs to chat A only.
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
    assert(root.sessionThinkingModeForTesting(chatA) == "high",
        "chat A did not store its own High mode");

    // New chat again, then click Off. The new chat inherits the mode in effect,
    // and its Off must not touch chat A.
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
    assert(root.sessionThinkingModeForTesting(chatB) == "off",
        "chat B did not store its own Off mode");
    assert(root.sessionThinkingModeForTesting(chatA) == "high",
        "choosing Off in chat B changed chat A's mode");

    // Click back to chat A through the sidebar. Each chat shows the mode that
    // was set for it: A stayed High while B is Off. This is the case that
    // changed on every switch before the mode was stored per conversation.
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
            "fixture lost chat A's own Thinking state");
        assert(root.thinkingControlTextForTesting() == "Thinking: High",
            "chat A lost the mode set for it: " ~
            root.thinkingControlTextForTesting());
        assert(root.thinkingMenuModeForTesting() == "high",
            "dropdown did not mark chat A's High mode: " ~
            root.thinkingMenuModeForTesting());
        assert(root.requestReasoningForTesting() == "on:high",
            "request did not carry chat A's High mode: " ~
            root.requestReasoningForTesting());
        menu = openThinkingMenu();
        assert(menu.items()[4].checked && !menu.items()[1].checked,
            "the dropdown did not check High for chat A");
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

    // Change chat A to Medium, then visit chat B and come back. B must remain
    // Off and A must show the Medium that was set for it.
    menu = openThinkingMenu();
    menu.items()[3].action(); // Medium
    settle();
    assert(root.sessionThinkingModeForTesting(chatA) == "medium",
        "chat A did not store the newly chosen Medium mode");
    assert(root.sessionThinkingModeForTesting(chatB) == "off",
        "changing chat A changed chat B's mode");

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

    const rowA2 = rowForSession(chatA);
    assert(rowA2 >= 0, "the sidebar did not list chat A after the switch");
    driver.click(sessions.rowCenterForTesting(rowA2));
    settle();
    assert(root.currentSessionForTesting() == chatA,
        "clicking the sidebar did not reopen chat A");
    assert(root.thinkingControlTextForTesting() == "Thinking: Medium",
        "chat A did not show the Medium mode set for it: " ~
        root.thinkingControlTextForTesting());
    assert(root.requestReasoningForTesting() == "on:medium",
        "request did not carry chat A's Medium mode: " ~
        root.requestReasoningForTesting());

    // Persistence boundary: each chat's stored metadata carries its own mode,
    // and decoding that metadata restores it.
    ChatSession storedA;
    decodeSessionMetadata(parseJSON(root.sessionMetadataJsonForTesting(chatA)),
        storedA);
    assert(storedA.thinkingMode == "medium",
        "chat A's stored metadata lost Medium: " ~ storedA.thinkingMode);
    ChatSession storedB;
    decodeSessionMetadata(parseJSON(root.sessionMetadataJsonForTesting(chatB)),
        storedB);
    assert(storedB.thinkingMode == "off",
        "chat B's stored metadata lost Off: " ~ storedB.thinkingMode);

    writeln("PASS each conversation keeps its own Thinking mode across switches");
    writeln("thinking_mode_switch_contracts: PASS");
    return 0;
}

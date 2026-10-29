module goal_ui_smoke;

// Headless UI smoke for the persistent goal bar above the composer. It drives
// the real widgets through the normal event path and intentionally avoids
// starting a network turn: editing is exercised while the goal is paused, and
// Stop is exercised on an active but idle goal.

import aurora;
import aurora.widgets.contextmenu : ContextMenu;
import aurora.widgets.popup : currentTransientPopup;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeContentMaxWidth, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, toLower;
import std.utf : toUTF8;

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

int main()
{
    const state = buildPath(tempDir(), "aurora-goal-ui-smoke");
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);

    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    foreach (_; 0 .. 100)
    {
        root.tickTree(0.02);
        if (!root.startupPendingForTesting()) break;
    }
    root.newChatForTesting();
    root.tickTree(0.02);
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "initial goal-bar paint failed");
    assert(driver.paint(), "second goal-bar layout failed");

    auto bar = requireWidget!Widget(root, "oc-goal");
    auto composer = requireWidget!Widget(root, "oc-composer");
    auto text = requireWidget!Label(root, "oc-goal-text");
    assert(bar.visible() && bar.bounds().width > 0 && bar.bounds().height > 0,
        "goal bar has no laid-out bounds");
    assert(bar.bounds().width <= opencodeContentMaxWidth,
        "goal bar exceeded the centered content width");
    const barOrigin = bar.localToGlobal(Point(0, 0));
    const composerOrigin = composer.localToGlobal(Point(0, 0));
    assert(barOrigin.y + bar.bounds().height <= composerOrigin.y,
        "goal bar must sit above the chat input");
    assert(toUTF8(text.text()).indexOf("Set a persistent goal") >= 0,
        "empty goal bar lacks its prompt");
    auto emptyEdit = requireWidget!Button(root, "oc-goal-edit");
    assert(emptyEdit.visible() && toUTF8(emptyEdit.text()) == "Set goal",
        "empty goal bar should offer Set goal");
    const emptyEditOrigin = emptyEdit.localToGlobal(Point(0, 0));
    assert(emptyEdit.bounds().width > 52,
        "Set goal button width did not expand for its label: " ~
        to!string(emptyEdit.bounds().width));
    assert(emptyEditOrigin.x + emptyEdit.bounds().width <=
        barOrigin.x + bar.bounds().width - 16,
        "Set goal button does not leave a right margin in the goal row");
    driver.click(globalCenter(emptyEdit));
    root.tickTree(0.02);
    assert(driver.paint(), "empty goal editor paint failed");
    auto createField = requireWidget!TextField(root, "oc-goal-field");
    assert(createField.visible(), "Set goal did not open the goal field");
    driver.click(globalCenter(requireWidget!Button(root, "oc-goal-cancel")));
    root.tickTree(0.02);
    assert(driver.paint(), "cancelled goal editor paint failed");
    assert(!createField.visible() && toUTF8(text.text()).indexOf(
        "Set a persistent goal") >= 0,
        "Cancel did not restore the empty goal prompt");
    writeln("PASS goal row is visible above the chat input");

    root.setGoalForTesting("keep the build green", "paused");
    root.tickTree(0.02);
    assert(driver.paint(), "saved-goal paint failed");
    assert(toUTF8(text.text()) == "keep the build green",
        "goal text did not update");
    auto prefix = requireWidget!Label(root, "oc-goal-prefix");
    const prefixOrigin = prefix.localToGlobal(Point(0, 0));
    assert(prefixOrigin.x >= barOrigin.x + 16,
        "goal content does not leave a left margin in the goal row");
    assert(toUTF8(prefix.text()).toLower().indexOf("paused") >= 0,
        "paused status is not visible");
    auto edit = requireWidget!Button(root, "oc-goal-edit");
    assert(edit.visible() && toUTF8(edit.text()) == "Edit",
        "Edit control missing for a saved goal");
    auto toggle = requireWidget!Button(root, "oc-goal-toggle");
    assert(toggle.visible() && toUTF8(toggle.text()) == "Start",
        "paused goal should offer Start");
    auto clear = requireWidget!Button(root, "oc-goal-clear");
    assert(clear.visible(), "Clear control missing for a saved goal");
    auto history = requireWidget!Button(root, "oc-goal-history");
    assert(history.visible() && toUTF8(history.text()) == "History",
        "saved goal should expose its history");
    driver.click(globalCenter(history));
    root.tickTree(0.02);
    assert(driver.paint(), "goal history menu paint failed");
    auto menu = cast(ContextMenu) currentTransientPopup(root);
    assert(menu !is null && menu.items().length >= 3,
        "History did not open a goal-history menu");
    assert(toUTF8(menu.items()[2].label).indexOf("keep the build green") >= 0,
        "goal-history menu omitted the saved goal");
    menu.dismiss();
    root.tickTree(0.02);
    assert(driver.paint(), "dismissed goal history paint failed");
    driver.moveTo(globalCenter(text));
    foreach (_; 0 .. 20) root.tickTree(0.05);
    assert(driver.paint(), "goal tooltip paint failed");
    assert(root.buttonTooltipTextForTesting("oc-goal-text") ==
        "keep the build green",
        "hovering the goal text did not show its full text");
    driver.moveTo(Point(4, 700));
    root.tickTree(0.02);
    assert(root.buttonTooltipTextForTesting("oc-goal-text").length == 0,
        "goal tooltip stayed open after the pointer left");
    writeln("PASS saved goal shows text, Edit, Start and Clear");

    driver.click(globalCenter(edit));
    root.tickTree(0.02);
    assert(driver.paint(), "goal editor paint failed");
    auto field = requireWidget!TextField(root, "oc-goal-field");
    assert(field.visible(), "Edit did not open the inline goal field");
    field.setText("keep the build green and tests passing");
    driver.click(globalCenter(requireWidget!Button(root, "oc-goal-save")));
    root.tickTree(0.02);
    assert(driver.paint(), "saved goal edit paint failed");
    assert(root.goalForTesting() == "keep the build green and tests passing",
        "edited goal text was not saved");
    assert(root.goalStatusForTesting() == "paused",
        "editing a paused goal must not resume it");
    assert(!field.visible(), "goal editor stayed open after Save");
    writeln("PASS Edit/Save updates the goal without resuming a paused run");

    root.persistForTesting();
    root.reloadSessionsForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "reloaded-goal paint failed");
    assert(root.goalForTesting() == "keep the build green and tests passing",
        "goal text did not survive save + reload");
    assert(root.goalStatusForTesting() == "paused",
        "goal status did not survive save + reload");
    assert(toUTF8(text.text()) == "keep the build green and tests passing",
        "reloaded goal is not shown in the bar");
    writeln("PASS goal text and paused state survive save + reload");

    root.setGoalForTesting("keep the build green and tests passing", "active");
    root.tickTree(0.02);
    assert(driver.paint(), "active-goal paint failed");
    toggle = requireWidget!Button(root, "oc-goal-toggle");
    assert(toUTF8(toggle.text()) == "Stop", "active goal should offer Stop");
    driver.click(globalCenter(toggle));
    root.tickTree(0.02);
    assert(driver.paint(), "paused-goal paint failed");
    assert(root.goalStatusForTesting() == "paused",
        "Stop did not pause the idle goal");
    assert(toUTF8(requireWidget!Button(root, "oc-goal-toggle").text()) == "Start",
        "Stop did not switch the control to Start");
    writeln("PASS Stop/Start control pauses an active goal");

    driver.click(globalCenter(requireWidget!Button(root, "oc-goal-clear")));
    root.tickTree(0.02);
    assert(driver.paint(), "cleared-goal paint failed");
    assert(root.goalForTesting().length == 0 &&
        root.goalStatusForTesting().length == 0,
        "Clear did not remove the goal");
    assert(toUTF8(text.text()).indexOf("Set a persistent goal") >= 0,
        "cleared goal bar did not return to its prompt");
    writeln("PASS Clear removes the goal and restores the prompt");

    auto historyTexts = root.goalHistoryTextsForTesting();
    auto historyOutcomes = root.goalHistoryOutcomesForTesting();
    assert(historyTexts.length == 2 &&
        historyTexts[0] == "keep the build green" &&
        historyTexts[1] == "keep the build green and tests passing",
        "goal history did not retain every set goal");
    assert(historyOutcomes[0] == "replaced" && historyOutcomes[1] == "cleared",
        "goal history outcomes were not recorded");
    const originalSession = root.currentSessionForTesting();
    root.setGoalForTesting("third saved goal", "paused");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "reloaded-goal-history paint failed");
    assert(root.goalHistoryTextsForTesting().length == 3 &&
        root.goalHistoryTextsForTesting()[2] == "third saved goal",
        "goal history did not survive save + reload");
    assert(toUTF8(requireWidget!Button(root, "oc-goal-history").text()) == "History",
        "restored goal history is not reachable from the goal row");
    root.newChatForTesting();
    assert(root.goalHistoryTextsForTesting().length == 0,
        "goal history leaked into another conversation");
    root.selectSessionForTesting(originalSession);
    assert(root.goalHistoryTextsForTesting().length == 3,
        "original conversation lost its goal history");
    writeln("PASS goal history is retained per conversation across reload");

    const longGoal = "Tooltip verification: this deliberately long goal " ~
        "must be shown without dropping any part of its final marker.";
    root.setGoalForTesting(longGoal, "paused");
    root.tickTree(0.02);
    assert(driver.paint(), "long-goal paint failed");
    driver.moveTo(globalCenter(text));
    foreach (_; 0 .. 20) root.tickTree(0.05);
    assert(driver.paint(), "long-goal tooltip paint failed");
    assert(root.buttonTooltipTextForTesting("oc-goal-text") == longGoal,
        "goal tooltip did not contain the complete goal text");
    driver.moveTo(Point(4, 700));
    root.tickTree(0.02);
    writeln("PASS goal tooltip shows the complete goal text");

    root.setAutoGoalFromFirstMessageForTesting(true);
    auto autoGoalCheck = root.autoGoalCheckboxForTesting();
    assert(autoGoalCheck !is null && autoGoalCheck.checked(),
        "Settings does not expose the enabled first-message goal option");
    driver.pressKey(Key.escape);
    root.tickTree(0.02);
    assert(driver.paint(), "first-message goal settings paint failed");
    root.newChatForTesting();
    assert(root.adoptFirstMessageGoalForTesting("Ship the first-message goal"),
        "first message did not become the goal");
    assert(root.goalForTesting() == "Ship the first-message goal",
        "adopted goal text was not saved");
    assert(!root.adoptFirstMessageGoalForTesting("A later message"),
        "a later message replaced the first-message goal");
    assert(root.goalForTesting() == "Ship the first-message goal",
        "later message changed the adopted goal");
    root.setAutoGoalFromFirstMessageForTesting(false);
    root.newChatForTesting();
    assert(!root.adoptFirstMessageGoalForTesting("Disabled first message"),
        "first-message goal was adopted while the setting was off");
    root.setAutoGoalFromFirstMessageForTesting(true);
    writeln("PASS first-message goal adoption follows its setting");

    root.shutdownClient();
    window.close();
    writeln("goal UI smoke passed");
    return 0;
}
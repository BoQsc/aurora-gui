module background_process_ui_smoke;

// Headless smoke for the toolbar background-process control. A command the agent
// leaves running must stay accounted for while the chat stays usable: the pill
// sits left of Export, hovering it peeks at the floating card, clicking it pins
// the card, and every row stops or clears its command with one click. It also
// proves the shutdown hook terminates a still-running command instead of leaving
// it behind the closed window.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : SupervisedProcessInfo, clearFinishedSupervisedProcesses,
    executeTool, installDeveloperToolSource, killAllSupervisedProcesses,
    listSupervisedProcesses, restoreDeveloperToolSource;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, startsWith;
import std.utf : toUTF8;
import core.thread : Thread;
import core.time : msecs;

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
    auto widget = findById(root, requestedId);
    assert(widget !is null, "Missing widget for id: " ~ requestedId);
    auto typed = cast(T) widget;
    assert(typed !is null, "Wrong widget type for id: " ~ requestedId);
    return typed;
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private SupervisedProcessInfo processById(string id)
{
    foreach (process; listSupervisedProcesses())
        if (process.id == id) return process;
    return SupervisedProcessInfo.init;
}

private bool processExists(string id)
{
    foreach (process; listSupervisedProcesses())
        if (process.id == id) return true;
    return false;
}

private string startBackground(string workspace, string json)
{
    OpenCodeToolCall call;
    call.id = "call_background";
    call.name = "run";
    call.arguments = json;
    const result = executeTool(call, workspace);
    assert(!result.failed, "background run failed: " ~ result.output);
    const marker = result.output.indexOf("processId: ");
    assert(marker >= 0, "background run returned no process id: " ~ result.output);
    auto body = result.output[cast(size_t) marker + 11 .. $];
    const end = body.indexOf('\n');
    const id = end >= 0 ? body[0 .. cast(size_t) end] : body;
    assert(id.length > 0, "background run returned an empty process id");
    return id;
}

/// A command that stays alive long enough to be seen and stopped. No workdir is
/// passed: the tool defaults to the workspace, which keeps the payload free of
/// Windows path escaping.
private string longRunJson()
{
    version (Windows)
        return `{"program":"cmd.exe","args":["/d","/c","ping -n 120 127.0.0.1 >nul"],"background":true}`;
    else
        return `{"program":"/bin/sh","args":["-c","sleep 120"],"background":true}`;
}

private void waitForTermination(string id, string context)
{
    foreach (_; 0 .. 200)
    {
        const process = processById(id);
        if (process.id.length > 0 && !process.running)
        {
            assert(process.state() == "killed",
                "background command ended as " ~ process.state() ~
                " instead of killed (" ~ context ~ ")");
            return;
        }
        Thread.sleep(msecs(25));
    }
    const process = processById(id);
    assert(false, "background command was never terminated (" ~ context ~
        "): state=" ~ process.state() ~ " running=" ~
        (process.running ? "yes" : "no") ~ " killRequested=" ~
        (process.killRequested ? "yes" : "no"));
}

/// Tick and paint until `condition` holds, or fail with `context`.
private void waitUntil(OpenCodeRoot root, UiTestDriver driver,
    bool delegate() condition, string context)
{
    foreach (_; 0 .. 60)
    {
        root.tickTree(0.1);
        driver.paint();
        if (condition()) return;
    }
    assert(false, "timed out waiting for " ~ context);
}

int main()
{
    const state = buildPath(tempDir(), "aurora-background-process-ui-smoke");
    mkdirRecurse(state);
    // Give the fixture workspace its own checkout identity. Without a `.git`
    // marker the lease identity walks up to the drive root, which collides with
    // any other Aurora process mutating an unrelated path on the same drive.
    mkdirRecurse(buildPath(state, ".git"));
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":true}`);

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
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "initial paint failed");
    assert(driver.paint(), "second paint failed");
    // The control, not the source workflow, is under test. Pinning the developer
    // source to none keeps these `run` calls on the fixture's own checkout lease
    // instead of the live Aurora checkout the launching app already holds.
    const previousSource = installDeveloperToolSource("");
    scope (exit) restoreDeveloperToolSource(previousSource);

    auto pill = requireWidget!Widget(root, "oc-processes");
    auto checkpointButton = requireWidget!Widget(root, "oc-checkpoint");
    auto composer = requireWidget!Widget(root, "oc-composer");
    const pillOrigin = pill.localToGlobal(Point(0, 0));
    const checkpointOrigin = checkpointButton.localToGlobal(Point(0, 0));
    const composerOrigin = composer.localToGlobal(Point(0, 0));
    assert(pill.visible() && pill.bounds().width > 0 && pill.bounds().height > 0,
        "the background pill has no laid-out bounds");
    assert(pillOrigin.y + pill.bounds().height <= composerOrigin.y,
        "the background pill must sit in the top toolbar, not in the chat column");
    assert(pillOrigin.x + pill.bounds().width <= checkpointOrigin.x,
        "the background pill must sit left of Checkpoint");
    assert(findById(root, "oc-processes-panel") is null,
        "the floating card is present before the pill is used");
    writeln("PASS background pill sits in the top toolbar left of Checkpoint");

    const background = startBackground(state, longRunJson());
    assert(processById(background).running,
        "a background command did not register as running");
    driver.moveTo(Point(4, 690));
    waitUntil(root, driver, delegate() { return true; }, "initial ticks");
    assert(findById(root, "oc-processes-panel") is null,
        "the card opened without hovering the pill");

    // Hover peeks at the card.
    assert(root.hitTest(globalCenter(pill)).id() == "oc-processes",
        "the pill is not the widget under its own centre");
    driver.moveTo(globalCenter(pill));
    waitUntil(root, driver,
        delegate() { return findById(root, "oc-processes-panel") !is null; },
        "the hover peek to open");
    auto panel = requireWidget!Widget(root, "oc-processes-panel");
    const panelOrigin = panel.localToGlobal(Point(0, 0));
    assert(panel.visible() && panel.bounds().width > 200,
        "the floating card has no usable bounds");
    assert(panel.bounds().width < root.bounds().width - 100,
        "the floating card should stay a small panel, not span the window: " ~
        to!string(panel.bounds().width));
    const pillBottom = pillOrigin.y + pill.bounds().height;
    assert(panelOrigin.y <= pillBottom && panelOrigin.y >= pillBottom - 2,
        "the floating card should sit flush under the pill so the peek has no " ~
        "gap to cross: cardY=" ~ to!string(panelOrigin.y) ~
        " pillBottom=" ~ to!string(pillBottom));
    assert(panelOrigin.x < pillOrigin.x + pill.bounds().width,
        "the floating card should be right-aligned to the pill");
    auto firstStop = requireWidget!Button(root, "oc-process-stop-0");
    assert(firstStop.visible() && toUTF8(firstStop.text()) == "Stop",
        "the listed row does not offer a one-click Stop");
    writeln("PASS hovering the pill peeks at the floating card");

    // The card is flush under the pill, so walking down into it keeps the peek
    // open: hiding immediately must not fight the natural pointer path.
    driver.moveTo(Point(globalCenter(pill).x, panelOrigin.y + 6));
    root.tickTree(0.016);
    assert(driver.paint(), "card-hover paint failed");
    assert(findById(root, "oc-processes-panel") !is null,
        "moving the pointer from the pill into the card hid it");
    writeln("PASS stepping from the pill into the card keeps the peek");

    // Leaving hides the peek at once: this is a pill with a popover, not a
    // hover tooltip that lingers over the conversation.
    driver.moveTo(Point(4, 690));
    root.tickTree(0.016);
    assert(driver.paint(), "dismissed-card paint failed");
    assert(findById(root, "oc-processes-panel") is null,
        "the hover peek lingered after the pointer left the pill");
    writeln("PASS the card hides on the first frame after the pointer leaves");

    // Clicking the pill pins the card open.
    driver.moveTo(globalCenter(pill));
    waitUntil(root, driver,
        delegate() { return findById(root, "oc-processes-panel") !is null; },
        "the hover peek to reopen");
    driver.click(globalCenter(pill));
    driver.moveTo(Point(4, 690));
    foreach (_; 0 .. 20) root.tickTree(0.1);
    assert(driver.paint(), "pinned-card paint failed");
    assert(findById(root, "oc-processes-panel") !is null,
        "the card did not stay open after the pill was clicked");
    assert(toUTF8(requireWidget!Button(root, "oc-process-pin").text()) == "Unpin",
        "a pinned card should offer Unpin");
    writeln("PASS clicking the pill pins the card");

    // One click on the row stops the command.
    driver.click(globalCenter(requireWidget!Button(root, "oc-process-stop-0")));
    const requested = processById(background);
    assert(requested.killRequested || !requested.running,
        "the row Stop did not request termination (state=" ~ requested.state() ~
        ")");
    waitForTermination(background, "row Stop");
    foreach (_; 0 .. 40)
    {
        root.tickTree(0.1);
        driver.paint();
        auto row = cast(Button) findById(root, "oc-process-stop-0");
        if (row !is null && toUTF8(row.text()) == "Clear") break;
    }
    auto finishedRow = cast(Button) findById(root, "oc-process-stop-0");
    const panelStillOpen = findById(root, "oc-processes-panel") !is null;
    const pinButton = cast(Button) findById(root, "oc-process-pin");
    assert(finishedRow !is null && toUTF8(finishedRow.text()) == "Clear",
        "the finished row did not offer Clear: row=" ~
        (finishedRow is null ? "missing" :
            (finishedRow.visible() ? "visible" : "hidden") ~ " text='" ~
            toUTF8(finishedRow.text()) ~ "'") ~
        " panelOpen=" ~ (panelStillOpen ? "yes" : "no") ~
        " pin='" ~ (pinButton is null ? "missing" : toUTF8(pinButton.text())) ~
        "' record=" ~ processById(background).state() ~
        " cardRows=" ~ to!string(root.backgroundProcessRowsForTesting()));
    writeln("PASS one click terminates the running command");

    // Clearing the finished record empties the card, which stays pinned.
    driver.click(globalCenter(requireWidget!Button(root, "oc-process-stop-0")));
    waitUntil(root, driver,
        delegate() { return !processExists(background); },
        "the finished record to be cleared");
    assert(findById(root, "oc-processes-panel") !is null,
        "clearing a record must not close a pinned card");
    writeln("PASS clearing the record removes it from the card");

    // The card's own pin control releases it.
    driver.click(globalCenter(requireWidget!Button(root, "oc-process-pin")));
    driver.moveTo(Point(4, 690));
    waitUntil(root, driver,
        delegate() { return findById(root, "oc-processes-panel") is null; },
        "Unpin to withdraw the card");
    writeln("PASS Unpin withdraws the pinned card");

    // Stop all covers several running commands.
    const first = startBackground(state, longRunJson());
    const second = startBackground(state, longRunJson());
    driver.moveTo(globalCenter(pill));
    waitUntil(root, driver,
        delegate() { return findById(root, "oc-processes-panel") !is null; },
        "the peek to open for two commands");
    auto stopAll = requireWidget!Button(root, "oc-process-stop-all");
    assert(stopAll.visible() && toUTF8(stopAll.text()).startsWith("Stop all"),
        "Stop all is missing while commands run");
    assert(requireWidget!Button(root, "oc-process-stop-1").visible(),
        "both running commands should have their own row");
    driver.click(globalCenter(stopAll));
    waitForTermination(first, "Stop all");
    waitForTermination(second, "Stop all");
    waitUntil(root, driver,
        delegate() { return requireWidget!Button(root, "oc-process-clear").visible(); },
        "Clear finished to appear");
    driver.click(globalCenter(requireWidget!Button(root, "oc-process-clear")));
    waitUntil(root, driver,
        delegate() { return listSupervisedProcesses().length == 0; },
        "Clear finished to drop both records");
    writeln("PASS Stop all terminates every running command");

    // Shutdown path: a command still running when the app closes is terminated
    // by the hook rather than becoming an orphan with nothing accounting for it.
    const abandoned = startBackground(state, longRunJson());
    assert(processById(abandoned).running);
    root.shutdownClient();
    const after = processById(abandoned);
    assert(after.id.length > 0 && !after.running && after.state() == "killed",
        "shutdown left a supervised background command running");
    clearFinishedSupervisedProcesses();
    assert(killAllSupervisedProcesses() == 0,
        "shutdown kill reported commands when none were running");
    writeln("PASS shutdown terminates a still-running background command");

    window.close();
    writeln("background process UI smoke passed");
    return 0;
}

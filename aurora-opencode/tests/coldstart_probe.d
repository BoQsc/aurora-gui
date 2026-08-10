module auroraopencode_coldstart_probe;

import aurora;
import auroraopencode.appui : OpenCodeRoot, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
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

int main()
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-coldstart-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode cold-start probe";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);

    auto input = cast(TextArea) findById(root, "oc-input");
    auto status = cast(Label) findById(root, "oc-status");
    if (input is null || status is null)
    {
        writeln("Missing oc-input or oc-status widget");
        return 1;
    }

    input.requestFocus();
    root.tickTree(0.02);
    driver.text(toUTF32("Reply with the single word OK."));
    root.tickTree(0.02);
    driver.pressKey(Key.enter);
    root.tickTree(0.02);

    const deadline = MonoTime.currTime + seconds(30);
    bool sawColdStart;
    while (MonoTime.currTime < deadline)
    {
        root.tickTree(0.03);
        Thread.sleep(30.msecs);
        driver.paint();
        const statusText = status.text();
        if (statusText.length > 0)
            writeln("status: ", statusText);
        if (statusText.length > 0 && indexOf(statusText, "Cold-starting"d) >= 0)
            sawColdStart = true;
        auto sendButton = cast(Button) findById(root, "oc-send");
        if (sendButton !is null && sendButton.text() == "Send")
            break;
    }

    writeln("Saw cold-start status: ", sawColdStart);
    root.shutdownClient();
    window.close();
    return sawColdStart ? 0 : 2;
}

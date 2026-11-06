module tool_row_render_probe;

// Renders the DEPLOYED app's recorded loop output in the real transcript widgets
// and saves the frame, so the per-sentence lines of the computer loop can be
// inspected as pixels rather than trusted as text.
//
// Input: the state directory a real `aurora-opencode-pro.exe --screenshot-chat`
// run produced (copied here, never modified). It is opened through the same
// OpenCodeRoot the desktop window uses, the action group is expanded (the row is
// collapsed by default), and the result is painted to a PPM/PNG image.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : copy, dirEntries, exists, mkdirRecurse, SpanMode, tempDir;
import std.path : baseName, buildPath, dirName;
import std.stdio : writeln;
import std.string : endsWith;

int main()
{
    const source = buildPath(tempDir(), "aurora-loop-ui-shot", "appdata",
        "Aurora OpenCode");
    if (!exists(source))
    {
        writeln("SKIP: no recorded loop state at ", source);
        return 2;
    }
    const state = buildPath(tempDir(), "aurora-loop-row-"
        ~ simpleStamp());
    mkdirRecurse(state);
    foreach (name; ["settings.json", "threads.index.json"])
        if (exists(buildPath(source, name)))
            copy(buildPath(source, name), buildPath(state, name));
    mkdirRecurse(buildPath(state, "threads"));
    foreach (entry; dirEntries(buildPath(source, "threads"), SpanMode.shallow))
        if (entry.isFile && entry.name.endsWith(".json"))
            copy(entry.name, buildPath(state, "threads", baseName(entry.name)));
    setOpencodeStateDirectoryForTesting(state);

    WindowOptions options;
    options.title = "Aurora loop row render";
    options.width = 1200;
    options.height = 900;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 20.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting(), "the UI never finished loading history");
    if (root.totalMessageCountForTesting() == 0)
        root.selectSessionForTesting(0);
    assert(root.totalMessageCountForTesting() > 0,
        "the recorded loop conversation did not load");

    const headers = root.toolGroupHeaderTextsForTesting();
    writeln("action groups: ", headers);
    const expanded = root.expandToolGroupsForTesting();
    writeln("expanded groups: ", expanded);
    assert(expanded > 0, "no action group to expand");

    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "painting the transcript failed");

    const shot = buildPath(tempDir(), "aurora-loop-ui-shot", "loop-row.ppm");
    window.saveScreenshot(shot);
    writeln("screenshot: ", shot);
    writeln("PASS rendered the recorded loop transcript with its action group expanded");
    return 0;
}

private string simpleStamp()
{
    import std.conv : to;
    return to!string(MonoTime.currTime.ticks % 1_000_000_000);
}

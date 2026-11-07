module system_prompt_viewer_probe;

// Renders the app's own "System prompt" viewer - the read-only dialog that shows
// the exact system message sent with the next request - against a workspace that
// ships an AGENTS.md, and saves the frame so the section can be inspected as
// pixels. This is the GUI surface of the project-instructions feature; the prompt
// itself never reaches the transcript, so the viewer is where a user sees it.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : exists, mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.algorithm : canFind;

private string sentinel = "PROJECT-RULE-SENTINEL use native-resolution frames only.";

int main()
{
    const root = buildPath(tempDir(), "aurora-prompt-viewer");
    const state = buildPath(root, "state");
    const workspace = buildPath(root, "project");
    mkdirRecurse(state);
    mkdirRecurse(workspace);
    write(buildPath(workspace, "AGENTS.md"), sentinel ~ "\n");
    setOpencodeStateDirectoryForTesting(state);

    WindowOptions options;
    options.title = "Aurora system prompt viewer";
    options.width = 1100;
    options.height = 900;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto app = new OpenCodeRoot(window);
    window.setRoot(app);
    scope (exit) app.shutdownClient();

    app.enableToolsForTesting(workspace);
    const ready = MonoTime.currTime + 20.seconds;
    while (app.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }

    // The dialog the "System prompt" button opens, with the same builder the next
    // request uses.
    const shown = app.systemPromptViewerTextForTesting();
    const hasHeader = shown.canFind("# Project instructions");
    const hasFile = shown.canFind("## AGENTS.md");
    const hasSentinel = shown.canFind(sentinel);
    const hasPrecedence = shown.canFind("cannot grant permissions");
    writeln("viewer bytes: ", shown.length);
    writeln("header: ", hasHeader, " | file heading: ", hasFile,
        " | sentinel: ", hasSentinel, " | precedence: ", hasPrecedence);

    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "painting the viewer dialog failed");
    const shot = buildPath(tempDir(), "aurora-prompt-viewer.ppm");
    window.saveScreenshot(shot);
    writeln("screenshot: ", shot);

    assert(hasHeader && hasFile && hasSentinel && hasPrecedence,
        "the viewer does not show the project instructions");
    writeln("PASS the app's system-prompt viewer shows the project instructions");
    return 0;
}

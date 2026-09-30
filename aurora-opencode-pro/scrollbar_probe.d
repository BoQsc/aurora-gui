module scrollbar_probe;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.array : appender;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

void main()
{
    setOpencodeStateDirectoryForTesting(buildPath(tempDir, "aurora-scroll-probe"));

    WindowOptions options;
    options.title = "scrollbar probe";
    options.width = 1100;
    options.height = 720;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);
    driver.paint();

    auto body = appender!string();
    foreach (i; 0 .. 12)
        body.put("Filler line " ~ to!string(i) ~
            " padding the transcript so it overflows the viewport.\n");
    foreach (i; 0 .. 8)
    {
        root.addConversationForTesting(["user"], ["Question " ~ to!string(i)]);
        root.addConversationForTesting(["assistant"], [body.data]);
    }
    root.tickTree(0.02);
    driver.paint();
    root.scrollToForTesting(int.max);
    root.tickTree(0.02);
    driver.paint();

    mkdirRecurse("build");
    window.saveScreenshot("build\\scroll-probe.ppm");
    writeln("saved build\\scroll-probe.ppm");
}

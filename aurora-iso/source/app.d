module app;

import aurora;
import auroraiso.appui : IsoRoot;
import auroraiso.theme : auroraIsoTheme;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : stderr;

private WindowOptions makeOptions()
{
    WindowOptions options;
    options.title = "Aurora ISO";
    options.width = 1280;
    options.height = 900;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.automatic;
    return options;
}

private int runScreenshot(string isoPath, string outputPath)
{
    auto window = new GuiWindow(makeOptions(), auroraIsoTheme());
    auto root = new IsoRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1280, 900));
    driver.paint();
    root.tickTree(0.02);

    if (isoPath.length > 0)
        root.loadIso(isoPath);

    const deadline = MonoTime.currTime + seconds(30);
    while (MonoTime.currTime < deadline && root.imageForTesting() !is null)
    {
        root.tickTree(0.02);
        driver.paint();
        break;
    }
    root.tickTree(0.02);
    driver.paint();
    window.saveScreenshot(outputPath);
    if (isoPath.length > 0 && root.imageForTesting() is null)
        stderr.writeln("screenshot warning: image did not load: ",
            root.statusTextForTesting());
    window.close();
    return 0;
}

int main(string[] args)
{
    if (args.length >= 4 && args[1] == "--screenshot")
        return runScreenshot(args[2], args[3]);

    string openPath;
    foreach (arg; args[1 .. $])
        if (arg.length > 0 && arg[0] != '-')
            openPath = arg;

    auto window = new GuiWindow(makeOptions(), auroraIsoTheme());
    auto root = new IsoRoot(window);
    window.setRoot(root);
    if (openPath.length > 0)
        root.loadIso(openPath);
    return window.run();
}

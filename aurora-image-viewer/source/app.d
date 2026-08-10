module app;

import aurora;
import auroraimageviewer.appui : ViewerRoot, imageViewerTheme;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import std.stdio : writeln;

private int runScreenshot(string imagePath, string outputPath)
{
    WindowOptions options;
    options.title = "Aurora Image Viewer";
    options.width = 1280;
    options.height = 800;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, imageViewerTheme());
    auto root = new ViewerRoot(window, imagePath);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);

    const deadline = MonoTime.currTime + seconds(60);
    while (MonoTime.currTime < deadline && !root.imageLoadedForTesting())
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
        driver.paint();
    }
    driver.paint();
    if (!root.imageLoadedForTesting())
        writeln("screenshot warning: image did not load: ",
            root.statusTextForTesting());
    window.saveScreenshot(outputPath);
    window.close();
    return 0;
}

int main(string[] args)
{
    if (args.length >= 4 && args[1] == "--screenshot")
        return runScreenshot(args[2], args[3]);

    string openPath;
    foreach (arg; args[1 .. $])
    {
        if (arg.length > 0 && arg[0] != '-')
            openPath = arg;
    }

    WindowOptions options;
    options.title = "Aurora Image Viewer";
    options.width = 1280;
    options.height = 800;
    options.darkTitleBar = true;
    auto window = new GuiWindow(options, imageViewerTheme());
    window.setRoot(new ViewerRoot(window, openPath));
    return window.run();
}

module app;

import aurora;
import auroranotepad.appui : NotepadRoot, notepadTheme;
import auroranotepad.iconpath : notepadIconPath;
import std.stdio : writeln;

private int runScreenshot(string outputPath)
{
    WindowOptions options;
    options.title = "Aurora Notepad";
    options.width = 1080;
    options.height = 680;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    options.iconPath = notepadIconPath();
    auto window = new GuiWindow(options, notepadTheme());
    auto root = new NotepadRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    window.saveScreenshot(outputPath);
    window.close();
    return 0;
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2]);

    WindowOptions options;
    options.title = "Aurora Notepad";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = false;
    options.lowLatency = true;
    options.vsync = true;
    options.iconPath = notepadIconPath();
    // Keep the native pointer during titlebar drags; Aurora's synchronized
    // drawn cursor is meant for dragging retained compositor layers.
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, notepadTheme());
    window.setRoot(new NotepadRoot(window));
    return window.run();
}

module app;

import aurora;
import auroradesigner.appui : DesignerRoot, darkDesignerTheme;
import auroradesigner.model : NodeKind;
import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.stdio : writeln;

private int runScreenshot(string outputPath)
{
    const directory = dirName(outputPath);
    if (directory.length != 0 && directory != "." && !exists(directory))
        mkdirRecurse(directory);

    WindowOptions options;
    options.title = "Aurora Designer";
    options.width = 1280;
    options.height = 800;
    options.decorated = false;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, darkDesignerTheme());
    auto root = new DesignerRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    // Build a small nested design so the screenshot shows hierarchy depth.
    root.selectNodeForTesting(root.document().root);
    const panel = root.addNodeForTesting(NodeKind.panel);
    root.designDocument().nodes[panel].x = 20;
    root.designDocument().nodes[panel].y = 20;
    root.designDocument().nodes[panel].width = 280;
    root.designDocument().nodes[panel].height = 150;
    root.selectNodeForTesting(panel);
    const button = root.addNodeForTesting(NodeKind.button);
    root.designDocument().nodes[button].x = 70;
    root.designDocument().nodes[button].y = 40;
    const label = root.addNodeForTesting(NodeKind.label);
    root.designDocument().nodes[label].x = 70;
    root.designDocument().nodes[label].y = 95;
    root.selectNodeForTesting(label);
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
    options.title = "Aurora Designer";
    options.width = 1280;
    options.height = 800;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, darkDesignerTheme());
    window.setRoot(new DesignerRoot(window));
    return window.run();
}

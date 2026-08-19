module app;

import aurora;
import auroradesigner.appui : DesignerRoot, darkDesignerTheme;
import auroradesigner.model : NodeKind;
import std.stdio : writeln;

private int runScreenshot(string outputPath)
{
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
    // Add a few representative widgets so the screenshot shows a design.
    root.selectNodeForTesting(root.document().root);
    root.addNodeForTesting(NodeKind.button);
    root.addNodeForTesting(NodeKind.label);
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

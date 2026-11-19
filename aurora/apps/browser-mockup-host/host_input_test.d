module host_input_test;

import aurora : GuiWindow, Point, Size, UiTestDriver;
import aurorahost.scene : NodeRegistry, createWindow, loadScene;
import std.file : thisExePath;
import std.path : buildPath, dirName;
import std.stdio : writeln;

void main(string[] args)
{
    const scenePath = args.length > 1 ? args[1] :
        buildPath(dirName(thisExePath()), "scene.json");
    auto scene = loadScene(scenePath);
    auto registry = new NodeRegistry();
    string actionSeen;
    registry.onAction = delegate(string node, string action)
    {
        if (node == "bookmark-design")
            actionSeen = action;
    };

    auto window = createWindow(scene, registry);
    scope (exit) window.close();
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1100, 760));
    driver.paint();

    auto button = registry.widget("bookmark-design");
    if (button is null)
        throw new Exception("bookmark-design widget is missing");
    const origin = button.globalOrigin();
    const bounds = button.bounds();
    driver.click(Point(origin.x + bounds.width / 2,
        origin.y + bounds.height / 2));
    driver.paint();
    if (actionSeen != "bookmark.design")
        throw new Exception("native widget click did not dispatch bookmark.design");

    // Exercise the flex canvas bounds after a logical resize without a native
    // visible window.
    driver.resize(Size(1400, 900));
    driver.paint();
    auto page = registry.widget("page");
    if (page is null)
        throw new Exception("page canvas is missing");
    const pageBounds = page.bounds();
    if (pageBounds.width < 1200 || pageBounds.height < 650)
        throw new Exception("page canvas did not grow after resize");
    writeln("PASS native headless widget click action=", actionSeen,
        " page=", pageBounds.width, "x", pageBounds.height);
}

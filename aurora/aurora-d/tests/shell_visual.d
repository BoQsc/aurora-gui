module tests.shell_visual;

import aurora;
import std.file : mkdirRecurse;
import std.stdio : writeln;

private final class PreviewRoot : Widget
{
    DesktopSurface desktop;
    Taskbar taskbar;

    this()
    {
        desktop = add(new DesktopSurface());
        taskbar = add(new Taskbar());
        desktop.addIcon("Notepad", IconKind.notepad);
        desktop.addIcon("Files", IconKind.folder);
        desktop.addIcon("Computer", IconKind.computer);
        desktop.addIcon("Trash", IconKind.trash);
        taskbar.addCommand("Notepad", IconKind.notepad, delegate() {});
        taskbar.addCommand("Files", IconKind.folder, delegate() {});
        taskbar.addCommand("Terminal", IconKind.terminal, delegate() {});
    }

    protected override void onLayout()
    {
        const barHeight = 52;
        desktop.setBounds(Rect(0, 0, bounds().width,
            maxInt(0, bounds().height - barHeight)));
        taskbar.setBounds(Rect(0, maxInt(0, bounds().height - barHeight),
            bounds().width, barHeight));
    }
}

int main()
{
    WindowOptions options;
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new PreviewRoot();
    window.setRoot(root);

    auto menu = new StartMenu(root.taskbar);
    menu.addApplication("Notepad", IconKind.notepad, delegate() {},
        "Create and edit text documents");
    menu.addApplication("File Explorer", IconKind.folder, delegate() {},
        "Browse files and folders");
    menu.addApplication("System Settings", IconKind.settings, delegate() {},
        "Display and desktop preferences");
    menu.addApplication("Terminal", IconKind.terminal, delegate() {},
        "Aurora command shell");
    menu.addSystemCommand("Full screen (F11)", IconKind.maximize, delegate() {});
    menu.addSystemCommand("Taskbar settings", IconKind.settings, delegate() {});
    menu.addSystemCommand("Shut down", IconKind.close, delegate() {}, true);
    assert(menu.show(root.taskbar, root.taskbar.startButtonGlobalBounds()));
    assert(menu.layoutValid());
    root.taskbar.setStartMenuOpen(true);

    mkdirRecurse("build");
    window.saveScreenshot("build/aurora-start-menu.ppm");
    writeln("Rendered validated Start menu preview to build/aurora-start-menu.ppm");

    menu.dismiss();
    root.taskbar.setStartMenuOpen(false);
    auto driver = new UiTestDriver(window);
    const sourceLocal = root.taskbar.entryBounds(0);
    const targetLocal = root.taskbar.entryBounds(2);
    const source = root.taskbar.localToGlobal(
        Point(sourceLocal.x + 18, sourceLocal.y + 12));
    const target = root.taskbar.localToGlobal(
        Point(targetLocal.x + 18, targetLocal.y - 10));
    driver.moveTo(source);
    driver.mouseDown();
    driver.moveTo(target);
    assert(root.taskbar.reordering());
    assert(root.taskbar.dragAnchorGlobalPosition() == PointF(target));
    window.saveScreenshot("build/aurora-task-drag.ppm");
    writeln("Rendered pointer-locked task drag preview to build/aurora-task-drag.ppm");
    driver.mouseUp();
    return 0;
}

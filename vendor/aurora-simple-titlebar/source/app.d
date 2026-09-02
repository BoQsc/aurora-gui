module app;

import aurora;
import aurorasimpletitlebar.titlebar;

final class SimpleTitleBarDemoRoot : VBox
{
    private GuiWindow _window;
    private SimpleTitleBar _titleBar;
    private Label _status;
    private Rect _restoredBounds;
    private bool _maximized;

    this(GuiWindow window)
    {
        super(0);
        _window = window;

        _titleBar = add(new SimpleTitleBar());
        _titleBar.setTitle("Untitled - Aurora Simple Titlebar");
        _titleBar.setIcon(IconKind.notepad);
        _titleBar.onMinimize = delegate() { _window.minimize(); };
        _titleBar.onMaximizeToggle = &toggleMaximize;
        _titleBar.onClose = delegate() { _window.close(); };
        _titleBar.onSystemMenu = delegate(Point) {
            if (_status !is null) _status.setText("System menu requested");
        };
        _titleBar.onDragStarted = delegate(PointF) {
            if (_status !is null) _status.setText("Owner-driven drag started");
        };

        auto content = add(new Panel(Color.fromHex(0xf4f6f8)));
        content.layoutHints().flex = 1.0;
        auto heading = content.add(new Label("Aurora Simple Titlebar"));
        heading.setScale(2);
        heading.setColor(Color.fromHex(0x20242a));
        auto detail = content.add(new Label(
            "A Windows 10-inspired caption rendered by Aurora Canvas.\n" ~
            "Hover the caption buttons, double-click the title, or drag the bar."));
        detail.setColor(Color.fromHex(0x66707a));

        _status = add(new Label("Ready - custom painted, platform-neutral titlebar"));
        _status.setColor(Color.fromHex(0x66707a));
        _status.layoutHints().preferredHeight = 32;
    }

    private void toggleMaximize()
    {
        if (!_maximized)
        {
            Rect current;
            if (_window.windowBounds(current))
                _restoredBounds = current;
            Rect workArea;
            if (_window.queryWorkArea(Point(current.x, current.y), workArea) &&
                !workArea.empty)
                _window.setWindowBounds(workArea);
            _maximized = true;
        }
        else if (!_restoredBounds.empty)
        {
            _window.setWindowBounds(_restoredBounds);
            _maximized = false;
        }
        _titleBar.setMaximized(_maximized);
        _status.setText(_maximized ? "Maximized" : "Restored");
    }
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2]);

    WindowOptions opts;
    opts.title = "Aurora Simple Titlebar";
    opts.width = 960;
    opts.height = 600;
    opts.resizable = true;
    opts.lowLatency = true;
    opts.vsync = true;
    opts.decorated = false;
    opts.darkTitleBar = false;

    auto theme = Theme.light();
    theme.windowBackground = Color.fromHex(0xf4f6f8);
    auto window = new GuiWindow(opts, theme);
    window.setRoot(new SimpleTitleBarDemoRoot(window));
    return window.run();
}

private int runScreenshot(string outputPath)
{
    WindowOptions opts;
    opts.title = "Aurora Simple Titlebar";
    opts.width = 960;
    opts.height = 600;
    opts.resizable = true;
    opts.decorated = false;
    opts.renderer = RendererPreference.software;

    auto theme = Theme.light();
    theme.windowBackground = Color.fromHex(0xf4f6f8);
    auto window = new GuiWindow(opts, theme);
    window.setRoot(new SimpleTitleBarDemoRoot(window));
    auto driver = new UiTestDriver(window);
    driver.resize(Size(opts.width, opts.height));
    driver.paint();
    window.saveScreenshot(outputPath);
    window.close();
    return 0;
}

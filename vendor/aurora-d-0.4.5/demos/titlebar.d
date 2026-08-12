module demos.titlebar;

import aurora;
import std.conv : to;
import std.stdio : writeln;

/**
 * Aurora TitleBar demo.
 *
 * A frameless window whose entire top strip is a completely customized
 * `TitleBar` widget: draggable through the native OS move loop, with custom
 * caption buttons, a right-click system menu, and a custom content widget
 * hosted inside the bar.
 */
final class TitleBarDemoRoot : Widget
{
    private TitleBar _titleBar;
    private Label _message;
    private int _eventCount;
    private bool _maximized;
    private GuiWindow _window;

    this(GuiWindow window)
    {
        _window = window;
        _titleBar = add(new TitleBar());
        _titleBar.setTitle("Aurora Custom TitleBar");
        _titleBar.setIcon(IconKind.computer);
        _titleBar.setSystemMoveOnDrag(true);
        _titleBar.setBarHeight(44);
        _titleBar.setCornerRadius(8);
        _titleBar.setBackground(Color.fromHex(0x232a33));
        _titleBar.setInactiveBackground(Color.fromHex(0x1b2129));
        _titleBar.setBorderColor(Color.fromHex(0x10141a));
        setAccentColors();

        auto searchField = new TextField("Search clips, tracks, effects…");
        searchField.setTransparentBackground(true);
        searchField.setTextColor(Color.fromHex(0xf2f6fa));
        _titleBar.setContent(searchField);

        _message = add(new Label("Drag the bar, double-click, right-click, or press the caption buttons."));
        _message.setAlignment(HorizontalAlign.center, VerticalAlign.middle);
        _message.setColor(Color.fromHex(0xd8e2ec));
        _message.setScale(2);

        _titleBar.onMinimize = delegate() { announce("Minimize requested (native minimize not exposed)"); };
        _titleBar.onMaximizeToggle = delegate()
        {
            _maximized = !_maximized;
            _titleBar.setMaximized(_maximized);
            _window.toggleFullscreen();
            announce(_maximized ? "Maximized" : "Restored");
        };
        _titleBar.onDoubleClick = delegate() { announce("Double-clicked the title"); };
        _titleBar.onClose = delegate() { _window.close(); };
        _titleBar.onSystemMenu = &showSystemMenu;
    }

    private void setAccentColors()
    {
        _titleBar.setTextColor(Color.fromHex(0xf2f6fa));
        _titleBar.setMutedTextColor(Color.fromHex(0x9fb0c0));
        _titleBar.setButtonHoverColor(Color.fromHex(0x3b4757));
        _titleBar.setButtonPressedColor(Color.fromHex(0x222a33));
        _titleBar.setCloseHoverColor(Color.fromHex(0xe5484d));
        _titleBar.setClosePressedColor(Color.fromHex(0xbf3438));
    }

    private void showSystemMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Restore", IconKind.open,
            delegate()
            {
                if (_maximized) toggleMaximize();
            }, "", _maximized);
        items ~= ContextMenuItem.command(_maximized ? "Restore down" : "Maximize",
            IconKind.maximize, delegate() { toggleMaximize(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close", IconKind.close,
            delegate() { _window.close(); }, "Alt+F4");
        showContextMenu(this, globalPosition, items);
    }

    private void toggleMaximize()
    {
        _maximized = !_maximized;
        _titleBar.setMaximized(_maximized);
        _window.toggleFullscreen();
        announce(_maximized ? "Maximized" : "Restored");
    }

    private void announce(string text)
    {
        ++_eventCount;
        _message.setText(text ~ "  •  event " ~ to!string(_eventCount));
        writeln("Aurora titlebar: ", text);
    }

    protected override void onLayout()
    {
        _titleBar.setBounds(Rect(0, 0, bounds().width, _titleBar.barHeight()));
        _message.setBounds(Rect(0, _titleBar.barHeight(), bounds().width,
            maxInt(0, bounds().height - _titleBar.barHeight())));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillVerticalGradient(Rect(0, 0, bounds().width, bounds().height),
            Color.fromHex(0x22334a), Color.fromHex(0x141b24));
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Custom TitleBar Demo";
    options.width = 1080;
    options.height = 640;
    options.x = 60;
    options.y = 60;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new TitleBarDemoRoot(window));
    return window.run();
}

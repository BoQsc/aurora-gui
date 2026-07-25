module demos.taskbar;

import aurora;
import std.stdio : writeln;

final class TaskbarDemoRoot : Widget
{
    private Label _message;
    private Taskbar _taskbar;
    private int _launchCount;

    this()
    {
        _message = add(new Label("Click, drag, or right-click a task button."));
        _message.setAlignment(HorizontalAlign.center, VerticalAlign.middle);
        _message.setColor(Color.rgb(245, 248, 252));
        _message.setScale(2);

        _taskbar = add(new Taskbar());
        _taskbar.onStart = delegate() { announce("Start menu requested"); };
        _taskbar.onShowDesktop = delegate() { announce("Show Desktop toggled"); };
        _taskbar.onTaskbarSettings = delegate() { announce("Taskbar settings requested"); };
        _taskbar.onDateTimeSettings = delegate() { announce("Date and time settings requested"); };
        _taskbar.onToggleFullscreen = delegate() { announce("Full screen requested"); };
        _taskbar.onEntryMoved = delegate(int from, int to)
        {
            announce("Task moved from " ~ toString(from + 1) ~ " to " ~ toString(to + 1));
        };
        _taskbar.addCommand("Notepad", IconKind.notepad,
            delegate() { announce("Notepad launched"); });
        _taskbar.addCommand("Files", IconKind.folder,
            delegate() { announce("File Explorer launched"); });
        _taskbar.addCommand("Terminal", IconKind.terminal,
            delegate() { announce("Terminal launched"); });
        _taskbar.addCommand("Settings", IconKind.settings,
            delegate() { announce("Settings launched"); });
        _taskbar.addCommand("Close", IconKind.close,
            delegate() { closeHostWindow(); });
    }

    private void announce(string text)
    {
        ++_launchCount;
        _message.setText(text ~ "  •  event " ~ toString(_launchCount));
        writeln("Aurora taskbar: ", text);
    }

    private static string toString(int value)
    {
        import std.conv : to;
        return to!string(value);
    }

    protected override void onLayout()
    {
        const barHeight = 52;
        _message.setBounds(Rect(0, 0, bounds().width, maxInt(0, bounds().height - barHeight)));
        _taskbar.setBounds(Rect(0, maxInt(0, bounds().height - barHeight), bounds().width, barHeight));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillVerticalGradient(Rect(0, 0, bounds().width, bounds().height),
            Color.fromHex(0x304864), Color.fromHex(0x1a2636));
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Taskbar Demo";
    options.width = 1080;
    options.height = 112;
    options.x = 40;
    options.y = 40;
    options.resizable = false;
    options.decorated = false;
    options.alwaysOnTop = true;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new TaskbarDemoRoot());
    return window.run();
}

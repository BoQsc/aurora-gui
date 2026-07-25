module demos.notepad;

import aurora;
import std.file : exists, readText, write;
import std.format : format;
import std.path : baseName;

final class NotepadRoot : VBox
{
    private GuiWindow _window;
    private TextField _path;
    private TextArea _editor;
    private Label _status;
    private Button _wrapButton;
    private Button _themeButton;
    private bool _dirty;
    private bool _dark;
    private bool _wrap;

    this(GuiWindow window, string initialPath = "")
    {
        super(7, Insets(8));
        _window = window;

        auto toolbar = add(new HBox(6));
        toolbar.layoutHints().preferredHeight = 42;

        auto newButton = toolbar.add(new Button("New", IconKind.newDocument));
        newButton.onClick = delegate() { newDocument(); };
        auto openButton = toolbar.add(new Button("Open", IconKind.open));
        openButton.onClick = delegate() { openDocument(); };
        auto saveButton = toolbar.add(new Button("Save", IconKind.save));
        saveButton.setAccent(true);
        saveButton.onClick = delegate() { saveDocument(); };

        toolbar.add(new Separator(Orientation.vertical));
        _path = toolbar.add(new TextField(initialPath));
        _path.setPlaceholder("Path to a UTF-8 text file");
        _path.layoutHints().flex = 1.0;
        _path.layoutHints().preferredWidth = 320;
        _path.onSubmitted = delegate() { openDocument(); };

        _wrapButton = toolbar.add(new Button("Wrap"));
        _wrapButton.onClick = delegate() { toggleWrap(); };
        _themeButton = toolbar.add(new Button("Dark", IconKind.settings));
        _themeButton.onClick = delegate() { toggleTheme(); };

        _editor = add(new TextArea());
        _editor.setPlaceholder("Start typing…");
        _editor.layoutHints().flex = 1.0;
        _editor.onChanged = delegate()
        {
            _dirty = true;
            updateStatus();
        };
        _editor.onCursorMoved = delegate() { updateStatus(); };

        _status = add(new Label("Ready"));
        _status.layoutHints().preferredHeight = 28;
        _status.setScale(1);

        if (initialPath.length > 0)
            loadPath(initialPath);
        else
            updateStatus();
    }

    private void newDocument()
    {
        _editor.setText("", false);
        _path.setText("", false);
        _dirty = false;
        _status.setText("New document");
        updateTitle();
        _editor.requestFocus();
    }

    private void openDocument()
    {
        const path = _path.textUtf8();
        if (path.length == 0)
        {
            _status.setText("Enter a path, then press Open or Enter.");
            _path.requestFocus();
            return;
        }
        loadPath(path);
    }

    private void loadPath(string path)
    {
        try
        {
            if (!exists(path))
            {
                _status.setText("File does not exist: " ~ path);
                return;
            }
            const text = readText(path);
            _editor.setText(text, false);
            _editor.setCursorIndex(0);
            _path.setText(path, false);
            _dirty = false;
            _status.setText("Opened " ~ path);
            updateStatus();
            _editor.requestFocus();
        }
        catch (Exception error)
        {
            _status.setText("Open failed: " ~ error.msg);
        }
    }

    private void saveDocument()
    {
        const path = _path.textUtf8();
        if (path.length == 0)
        {
            _status.setText("Enter a destination path first.");
            _path.requestFocus();
            return;
        }
        try
        {
            write(path, _editor.textUtf8());
            _dirty = false;
            _status.setText("Saved " ~ path);
            updateStatus();
        }
        catch (Exception error)
        {
            _status.setText("Save failed: " ~ error.msg);
        }
    }

    private void toggleWrap()
    {
        _wrap = !_wrap;
        _editor.setWordWrap(_wrap);
        _wrapButton.setText(_wrap ? "No wrap" : "Wrap");
        updateStatus();
    }

    private void toggleTheme()
    {
        _dark = !_dark;
        _window.setTheme(_dark ? Theme.dark() : Theme.light());
        _themeButton.setText(_dark ? "Light" : "Dark");
    }

    private void updateStatus()
    {
        _status.setText(format("Line %d, column %d   |   %d characters%s",
            _editor.cursorLine() + 1,
            _editor.cursorColumn() + 1,
            _editor.textView().length,
            (_wrap ? "   |   Wrap" : "") ~
            (_dirty ? "   |   Modified" : "")));
        updateTitle();
    }

    private void updateTitle()
    {
        auto path = _path.textUtf8();
        const name = path.length == 0 ? "Untitled" : baseName(path);
        _window.setTitle((_dirty ? "*" : "") ~ name ~ " — Aurora Notepad");
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.s)
        {
            saveDocument();
            return true;
        }
        if (shortcut && event.key == Key.o)
        {
            _path.requestFocus();
            return true;
        }
        if (shortcut && event.key == Key.n)
        {
            newDocument();
            return true;
        }
        if (event.key == Key.f6)
        {
            toggleTheme();
            return true;
        }
        return false;
    }
}

int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Notepad";
    options.width = 980;
    options.height = 680;
    auto window = new GuiWindow(options, Theme.light());
    const initialPath = args.length > 1 ? args[1] : "";
    window.setRoot(new NotepadRoot(window, initialPath));
    return window.run();
}

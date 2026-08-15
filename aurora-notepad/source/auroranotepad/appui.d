module auroranotepad.appui;

import aurora;
import auroranotepad.iconpath : loadNotepadTitleImage, notepadImagePath,
    notepadTitleImagePath;
import auroranotepad.menubar : MenuBar;
import auroranotepad.titlebar : NotepadTitleBar;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, readText, write;
import std.format : format;
import std.path : baseName;

/** Windows-10-style light theme. */
Theme notepadTheme()
{
    auto theme = Theme.light();
    theme.windowBackground = Color.fromHex(0xffffff);
    theme.panelBackground = Color.fromHex(0xf5f5f5);
    theme.panelElevated = Color.fromHex(0xffffff);
    theme.text = Color.fromHex(0x1a1a1a);
    theme.textMuted = Color.fromHex(0x6a6a6a);
    theme.border = Color.fromHex(0xd6d6d6);
    theme.accent = Color.fromHex(0x0078d4);
    theme.accentHover = Color.fromHex(0x0067b8);
    theme.accentPressed = Color.fromHex(0x005a9e);
    theme.selection = Color.fromHex(0xcce8ff);
    theme.selectionText = Color.fromHex(0x1a1a1a);
    theme.fieldBackground = Color.fromHex(0xffffff);
    theme.buttonBackground = Color.fromHex(0xf0f0f0);
    theme.buttonHover = Color.fromHex(0xe5e5e5);
    theme.buttonPressed = Color.fromHex(0xd4d4d4);
    theme.disabled = Color.fromHex(0xb0b0b0);
    theme.danger = Color.fromHex(0xe81123);
    theme.cornerRadius = 3;
    theme.controlHeight = 32;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

/** Windows-10-style dark theme. */
Theme darkNotepadTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x202020);
    theme.panelBackground = Color.fromHex(0x2b2b2b);
    theme.panelElevated = Color.fromHex(0x2f2f2f);
    theme.text = Color.fromHex(0xffffff);
    theme.textMuted = Color.fromHex(0xa0a0a0);
    theme.border = Color.fromHex(0x3f3f3f);
    theme.accent = Color.fromHex(0x0078d4);
    theme.accentHover = Color.fromHex(0x2b88d8);
    theme.accentPressed = Color.fromHex(0x0067b8);
    theme.selection = Color.fromHex(0x1e6fbf);
    theme.selectionText = Color.fromHex(0xffffff);
    theme.fieldBackground = Color.fromHex(0x1e1e1e);
    theme.buttonBackground = Color.fromHex(0x333333);
    theme.buttonHover = Color.fromHex(0x3c3c3c);
    theme.buttonPressed = Color.fromHex(0x4a4a4a);
    theme.disabled = Color.fromHex(0x6e6e6e);
    theme.danger = Color.fromHex(0xe81123);
    theme.cornerRadius = 3;
    theme.controlHeight = 32;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

/** The status band color for each theme. */
private Color statusBand(bool dark)
{
    return Color.fromHex(dark ? 0x2b2b2b : 0xf0f0f0);
}

/**
 * One-pixel theme border painted over every edge so the frameless window looks
 * like a real Windows-10 window even where DWM's own resize frame is absent.
 * Created disabled so it never intercepts pointer input (the host's hit test
 * skips disabled widgets, exactly like the snap-preview overlay).
 */
final class WindowBorder : Widget
{
    this()
    {
        setEnabled(false);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.strokeRect(Rect(0, 0, bounds().width, bounds().height),
            theme().border, 1);
    }
}

/**
 * The Aurora Notepad root: a Windows-10-Notepad clone.
 *
 * A slim titlebar over the classic File/Edit/Format/View/Help menu bar, a
 * borderless Consolas editor, and an optional gray status band with a 1 px
 * top hairline. `_statusBorder` is added after `_statusBand` so its one-pixel
 * line paints over the band's top edge.
 */
final class NotepadRoot : Widget
{
    private GuiWindow _window;
    private NotepadTitleBar _titleBar;
    private MenuBar _menuBar;
    private Panel _statusBand;
    private Separator _statusBorder;
    private WindowBorder _windowBorder;
    private TitleBarSnapPreview _snapPreview;
    private TextArea _editor;
    private Label _status;
    private string _currentPath;
    private bool _dirty;
    private bool _dark;
    private bool _wrap;
    private bool _statusVisible = true;

    this(GuiWindow window)
    {
        _window = window;

        _titleBar = add(new NotepadTitleBar(window));
        _titleBar.onSnapPreview = &updateSnapPreview;
        // Show the application's own PNG icon in the custom titlebar.
        try
        {
            const derivativePath = notepadTitleImagePath();
            const imagePath = derivativePath.length > 0 ? derivativePath :
                notepadImagePath();
            if (imagePath.length > 0)
                _titleBar.setIconImage(loadNotepadTitleImage(imagePath));
        }
        catch (Exception)
        {
            // Keep the procedural notepad glyph when the PNG is unavailable.
        }

        // Classic Windows-10 Notepad menu bar.
        _menuBar = add(new MenuBar());
        buildFileMenu();
        buildEditMenu();
        buildFormatMenu();
        buildViewMenu();
        buildHelpMenu();

        // Borderless editor, Windows-10 Notepad text size (Consolas 11 pt).
        _editor = add(new TextArea());
        _editor.setPlaceholder("Start typing…");
        _editor.setWordWrap(false);
        _editor.setShowBorder(false);
        _editor.setFocusDecoration(false);
        _editor.setPixelSizeOverride(14);
        _editor.onChanged = delegate()
        {
            _dirty = true;
            updateStatus();
        };
        _editor.onCursorMoved = delegate() { updateStatus(); };

        // Gray status band with the status text and a 1 px top hairline.
        _statusBand = add(new Panel(statusBand(false)));
        _status = _statusBand.add(new Label("Ready"));
        _status.setScale(1);
        _statusBorder = add(new Separator(Orientation.horizontal));

        // Snap-preview overlay: added last so it paints above all content. The
        // overlay is created disabled, so it never intercepts pointer input.
        _snapPreview = add(new TitleBarSnapPreview());
        // The 1 px window border paints on top of everything (last child).
        _windowBorder = add(new WindowBorder());

        updateStatus();
    }

    NotepadTitleBar titleBar() @safe pure nothrow @nogc { return _titleBar; }
    MenuBar menuBar() @safe pure nothrow @nogc { return _menuBar; }
    TextArea editor() @safe pure nothrow @nogc { return _editor; }
    TitleBarSnapPreview snapPreview() @safe pure nothrow @nogc
    {
        return _snapPreview;
    }

    // --- Menu construction. ---

    private void buildFileMenu()
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("New", IconKind.newDocument,
            delegate() { newDocument(); }, "Ctrl+N");
        items ~= ContextMenuItem.command("Open…", IconKind.open,
            delegate() { openDocument(); }, "Ctrl+O");
        items ~= ContextMenuItem.command("Save", IconKind.save,
            delegate() { saveDocument(); }, "Ctrl+S");
        items ~= ContextMenuItem.command("Save As…", IconKind.save,
            delegate() { showSaveDialog(); }, "Ctrl+Shift+S");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Exit", IconKind.close,
            delegate() { _window.close(); });
        _menuBar.addItem("File", items);
    }

    private void buildEditMenu()
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Undo",
            delegate() { _editor.undo(); }, "Ctrl+Z");
        items ~= ContextMenuItem.command("Redo",
            delegate() { _editor.redo(); }, "Ctrl+Y");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Cut",
            delegate() { _editor.cutToClipboard(); }, "Ctrl+X");
        items ~= ContextMenuItem.command("Copy",
            delegate() { _editor.copyToClipboard(); }, "Ctrl+C");
        items ~= ContextMenuItem.command("Paste",
            delegate() { _editor.pasteFromClipboard(); }, "Ctrl+V");
        items ~= ContextMenuItem.command("Delete",
            delegate() { _editor.deleteSelectionCommand(); }, "Del");
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Select All",
            delegate() { _editor.selectAll(); }, "Ctrl+A");
        items ~= ContextMenuItem.command("Time/Date",
            delegate() { insertTimeDate(); }, "F5");
        _menuBar.addItem("Edit", items);
    }

    private void buildFormatMenu()
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.check("Word Wrap", _wrap,
            delegate() { toggleWrap(); });
        _menuBar.addItem("Format", items);
    }

    private void buildViewMenu()
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.check("Status Bar", _statusVisible,
            delegate() { toggleStatusBar(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.check("Dark Theme", _dark,
            delegate() { toggleTheme(); });
        _menuBar.addItem("View", items);
    }

    private void buildHelpMenu()
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("About Aurora Notepad",
            delegate() { showAbout(); });
        _menuBar.addItem("Help", items);
    }

    // --- Actions. ---

    /** Show/hide the translucent preview while a drag crosses a snap zone. */
    private void updateSnapPreview(TitleBarSnapTarget target, Rect bounds)
    {
        if (target == TitleBarSnapTarget.none)
        {
            _snapPreview.hide();
            return;
        }
        Rect origin;
        _window.windowBounds(origin);
        _snapPreview.show(Rect(bounds.x - origin.x, bounds.y - origin.y,
            bounds.width, bounds.height));
    }

    private void newDocument()
    {
        _editor.setText("", false);
        _currentPath = "";
        _dirty = false;
        updateStatus();
        _editor.requestFocus();
    }

    private void openDocument()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Open Text File";
        options.initialPath = _currentPath;
        options.acceptLabel = "Open";
        string path;
        if (runFileDialogWindow(_window, options, path, dialogTheme()))
            loadPath(path);
        else
            _editor.requestFocus();
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
            _currentPath = path;
            _dirty = false;
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
        if (_currentPath.length == 0)
        {
            showSaveDialog();
            return;
        }
        saveToPath(_currentPath);
    }

    private void showSaveDialog()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.save;
        options.title = "Save Text File";
        options.initialPath = _currentPath.length > 0 ? _currentPath :
            "Untitled.txt";
        options.defaultFileName = "Untitled.txt";
        options.acceptLabel = "Save";
        string path;
        if (runFileDialogWindow(_window, options, path, dialogTheme()))
            saveToPath(path);
        else
            _editor.requestFocus();
    }

    private void saveToPath(string path)
    {
        try
        {
            write(path, _editor.textUtf8());
            _currentPath = path;
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
        updateStatus();
    }

    private void toggleTheme()
    {
        _dark = !_dark;
        _window.setTheme(_dark ? darkNotepadTheme() : notepadTheme());
        _titleBar.setDarkMode(_dark);
        _statusBand.setBackground(statusBand(_dark));
        _window.setFrameDark(_dark);
    }

    private void toggleStatusBar()
    {
        _statusVisible = !_statusVisible;
        invalidate();
    }

    private void insertTimeDate()
    {
        auto now = Clock.currTime().toLocalTime();
        const hour12 = ((cast(int) now.hour + 11) % 12) + 1;
        const ampm = now.hour < 12 ? "AM" : "PM";
        const text = format("%d:%02d %s %d/%d/%d", hour12, now.minute, ampm,
            cast(int) now.month, now.day, now.year);
        _editor.insertTextAtCursor(to!dstring(text));
    }

    private void showAbout()
    {
        _status.setText("Aurora Notepad 0.1.0 — a Windows-10-style Notepad "
            ~ "built on Aurora-D.");
    }

    private Theme dialogTheme()
    {
        return _dark ? darkNotepadTheme() : notepadTheme();
    }

    private void updateStatus()
    {
        _status.setText(format("Line %d, column %d   |   %d characters%s",
            _editor.cursorLine() + 1,
            _editor.cursorColumn() + 1,
            _editor.textView().length,
            (_wrap ? "   |   Wrap" : "") ~
            (_dirty ? "   |   Modified" : "")));
        const name = _currentPath.length == 0 ? "Untitled" : baseName(_currentPath);
        _titleBar.setDocumentTitle(name, _dirty);
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.s && event.shift())
        {
            showSaveDialog();
            return true;
        }
        if (shortcut && event.key == Key.s)
        {
            saveDocument();
            return true;
        }
        if (shortcut && event.key == Key.o)
        {
            openDocument();
            return true;
        }
        if (shortcut && event.key == Key.n)
        {
            newDocument();
            return true;
        }
        return false;
    }

    protected override void onLayout()
    {
        const barHeight = _titleBar.barHeight();
        const menuBarHeight = 30;
        const statusHeight = _statusVisible ? 28 : 0;
        const statusTop = maxInt(0, bounds().height - statusHeight);
        const editorTop = barHeight + menuBarHeight;
        _titleBar.setBounds(Rect(0, 0, bounds().width, barHeight));
        _menuBar.setBounds(Rect(0, barHeight, bounds().width, menuBarHeight));
        _editor.setBounds(Rect(0, editorTop, bounds().width,
            maxInt(0, statusTop - editorTop)));
        _statusBand.setBounds(Rect(0, statusTop, bounds().width, statusHeight));
        _status.setBounds(Rect(8, 0, maxInt(0, bounds().width - 16),
            statusHeight));
        _statusBorder.setBounds(Rect(0, statusTop, bounds().width, 1));
        _snapPreview.setBounds(Rect(0, 0, bounds().width, bounds().height));
        _windowBorder.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

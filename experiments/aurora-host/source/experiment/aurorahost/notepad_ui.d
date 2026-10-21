module experiment.aurorahost.notepad_ui;

import experiment.aurorahost.component : ComponentContext;
import experiment.aurorahost.host_editor : HostTextEditor;
import aurora;
import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.utf : toUTF32;

private enum CaptionTarget : ubyte
{
    none,
    minimize,
    maximize,
    close
}

/**
 * A bespoke Windows 10 Notepad surface.
 *
 * The caption, menu bar, status bar, icons, and hit regions are painted here
 * with Aurora's canvas. Only the document editor is a retained child widget,
 * because caret movement, selection, clipboard, undo, and scrolling are
 * behavior that should not be reimplemented as pixels.
 */
final class NotepadView : Widget
{
    private GuiWindow _window;
    private HostTextEditor _editor;
    private dstring _title;
    private dstring[] _menuLabels;
    private int[] _menuWidths;
    private string _statusText = "Ln 1, Col 1";
    private void delegate(string action) _dispatchAction;

    private bool _wordWrap = true;
    private bool _showStatus = true;
    private bool _maximized;
    private Rect _restoreBounds;

    private CaptionTarget _hotCaption;
    private CaptionTarget _pressedCaption;
    private int _hotMenu = -1;
    private int _pressedMenu = -1;

    private enum int titleHeight = 32;
    private enum int menuHeight = 24;
    private enum int statusHeight = 22;
    private enum int captionWidth = 46;

    this(GuiWindow window, string title, string text,
        void delegate(string action) dispatchAction)
    {
        _window = window;
        _title = toUTF32(title);
        _dispatchAction = dispatchAction;
        foreach (label; ["File", "Edit", "Format", "View", "Help"])
            _menuLabels ~= toUTF32(label);
        _menuWidths = [44, 44, 58, 48, 48];

        _editor = new HostTextEditor(text);
        _editor.setShowBorder(false);
        _editor.setWordWrap(true);
        _editor.setPadding(5);
        _editor.setFontPixelSize(15);
        _editor.onChanged = delegate() { updateStatus(); };
        _editor.onCursorMoved = delegate() { updateStatus(); };
        add(_editor);

        setFocusable(false);
        setCursor(CursorKind.arrow);
    }

    private int menuY() const
    {
        return titleHeight + menuHeight;
    }

    private Rect menuRect(int index)
    {
        int x = 2;
        foreach (i; 0 .. index)
            x += _menuWidths[i];
        return Rect(x, titleHeight, _menuWidths[index], menuHeight);
    }

    private Rect captionRect(CaptionTarget target) const
    {
        const width = bounds().width;
        const int index = target == CaptionTarget.close ? 0 :
            target == CaptionTarget.maximize ? 1 : 2;
        return Rect(width - (index + 1) * captionWidth, 0,
            captionWidth, titleHeight);
    }

    private CaptionTarget captionAt(Point point)
    {
        foreach (target; [CaptionTarget.minimize, CaptionTarget.maximize,
            CaptionTarget.close])
        {
            if (captionRect(target).contains(point))
                return target;
        }
        return CaptionTarget.none;
    }

    private int menuAt(Point point)
    {
        if (point.y < titleHeight || point.y >= titleHeight + menuHeight)
            return -1;
        foreach (index; 0 .. _menuWidths.length)
            if (menuRect(cast(int) index).contains(point))
                return cast(int) index;
        return -1;
    }

    protected override void onLayout()
    {
        const bottom = _showStatus ? statusHeight : 0;
        _editor.setBounds(Rect(0, menuY(), bounds().width,
            maxInt(1, bounds().height - menuY() - bottom)));
        _editor.layoutTree();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        const palette = theme();
        const text = Color.rgb(0x1a, 0x1a, 0x1a);
        const muted = Color.rgb(0x60, 0x60, 0x60);
        const border = Color.rgb(0xd0, 0xd0, 0xd0);

        canvas.fillRect(Rect(0, 0, width, height), Color.rgb(255, 255, 255));

        // Windows 10 caption: white chrome, left-aligned title, system glyphs.
        canvas.fillRect(Rect(0, 0, width, titleHeight),
            Color.rgb(0xf3, 0xf3, 0xf3));
        canvas.fillRect(Rect(0, titleHeight - 1, width, 1), border);

        const icon = Rect(8, 8, 16, 16);
        canvas.fillRoundedRect(icon, 2, Color.rgb(0x2a, 0x6f, 0xcc));
        canvas.fillRect(Rect(icon.x + 3, icon.y + 4, 10, 1),
            Color.rgb(255, 255, 255));
        canvas.fillRect(Rect(icon.x + 3, icon.y + 8, 10, 1),
            Color.rgb(255, 255, 255));
        canvas.fillRect(Rect(icon.x + 3, icon.y + 12, 7, 1),
            Color.rgb(255, 255, 255));

        canvas.drawTextInRect(Rect(32, 0, width - 180, titleHeight),
            _title, text, 1, HorizontalAlign.left, VerticalAlign.middle, true);

        foreach (target; [CaptionTarget.minimize, CaptionTarget.maximize,
            CaptionTarget.close])
        {
            const rect = captionRect(target);
            const hot = target == _hotCaption;
            const pressed = target == _pressedCaption;
            if (hot || pressed)
                canvas.fillRect(rect,
                    target == CaptionTarget.close ?
                    Color.rgb(0xe8, 0x11, 0x23) :
                    Color.rgb(0xe5, 0xe5, 0xe5));
            const glyph = hot && target == CaptionTarget.close ?
                Color.rgb(255, 255, 255) : text;
            const cx = rect.x + rect.width / 2;
            const cy = rect.y + rect.height / 2;
            if (target == CaptionTarget.minimize)
                canvas.fillRect(Rect(cx - 6, cy - 1, 12, 2), glyph);
            else if (target == CaptionTarget.maximize)
                canvas.strokeRect(Rect(cx - 5, cy - 5, 10, 10), glyph, 1);
            else
            {
                canvas.drawLine(Point(cx - 5, cy - 5),
                    Point(cx + 5, cy + 5), glyph, 1);
                canvas.drawLine(Point(cx + 5, cy - 5),
                    Point(cx - 5, cy + 5), glyph, 1);
            }
        }

        // Compact owner-drawn menu bar.
        canvas.fillRect(Rect(0, titleHeight, width, menuHeight),
            Color.rgb(0xff, 0xff, 0xff));
        canvas.fillRect(Rect(0, menuY() - 1, width, 1), border);
        foreach (index; 0 .. _menuLabels.length)
        {
            const rect = menuRect(cast(int) index);
            if (index == _hotMenu || index == _pressedMenu)
                canvas.fillRect(rect, Color.rgb(0xe5, 0xf1, 0xfb));
            canvas.drawTextInRect(Rect(rect.x + 7, rect.y,
                rect.width - 8, rect.height), _menuLabels[index],
                text, 1, HorizontalAlign.left, VerticalAlign.middle, true);
        }

        if (_showStatus)
        {
            const y = height - statusHeight;
            canvas.fillRect(Rect(0, y, width, statusHeight),
                Color.rgb(0xf0, 0xf0, 0xf0));
            canvas.fillRect(Rect(0, y, width, 1), border);
            canvas.drawTextInRect(Rect(8, y, width - 80, statusHeight),
                toUTF32(_statusText), muted, 1,
                HorizontalAlign.left, VerticalAlign.middle, true);
            canvas.drawTextInRect(Rect(width - 56, y, 48, statusHeight),
                "100%"d, muted, 1,
                HorizontalAlign.right, VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const nextCaption = captionAt(event.position);
        const nextMenu = menuAt(event.position);
        if (nextCaption != _hotCaption || nextMenu != _hotMenu)
        {
            _hotCaption = nextCaption;
            _hotMenu = nextMenu;
            setCursor(nextCaption != CaptionTarget.none ? CursorKind.hand :
                nextMenu >= 0 ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        return nextCaption != CaptionTarget.none || nextMenu >= 0;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.position.y < titleHeight)
        {
            const target = captionAt(event.position);
            if (target != CaptionTarget.none)
            {
                _pressedCaption = target;
                invalidate();
                return true;
            }
            beginSystemMove();
            return true;
        }
        const index = menuAt(event.position);
        if (index >= 0)
        {
            _pressedMenu = index;
            invalidate();
            const rect = menuRect(index);
            const origin = globalOrigin();
            showContextMenu(this,
                Point(origin.x + rect.x, origin.y + menuY() + 1),
                menuItems(index));
            return true;
        }
        return false;
    }

    override bool onMouseUp(ref Event event)
    {
        if (_pressedCaption != CaptionTarget.none)
        {
            const target = _pressedCaption;
            _pressedCaption = CaptionTarget.none;
            invalidate();
            if (captionRect(target).contains(event.position))
                activateCaption(target);
            return true;
        }
        if (_pressedMenu >= 0)
        {
            _pressedMenu = -1;
            invalidate();
            return true;
        }
        return false;
    }

    private void activateCaption(CaptionTarget target)
    {
        if (target == CaptionTarget.close)
            _window.close();
        else if (target == CaptionTarget.minimize)
            _window.minimize();
        else if (target == CaptionTarget.maximize)
            toggleMaximize();
    }

    private void toggleMaximize()
    {
        Rect current;
        if (_maximized)
        {
            if (!_restoreBounds.empty)
                _window.setWindowBounds(_restoreBounds);
            _maximized = false;
        }
        else
        {
            if (_window.windowBounds(current))
                _restoreBounds = current;
            Rect work;
            if (_window.queryWorkArea(Point(current.x, current.y), work) &&
                !work.empty)
            {
                _window.setWindowBounds(work);
                _maximized = true;
            }
        }
        invalidate();
    }

    private void updateStatus()
    {
        _statusText = format("Ln %d, Col %d",
            _editor.cursorLine() + 1, _editor.cursorColumn() + 1);
        invalidate();
    }

    private void dispatch(string action)
    {
        switch (action)
        {
            case "file.exit":
                _window.close();
                break;
            case "edit.undo":
                _editor.undo();
                break;
            case "edit.copy":
                _editor.copyToClipboard();
                break;
            case "edit.paste":
                _editor.pasteFromClipboard();
                break;
            case "edit.selectAll":
                _editor.selectAll();
                break;
            case "format.wordWrap":
                _wordWrap = !_wordWrap;
                _editor.setWordWrap(_wordWrap);
                break;
            case "view.statusBar":
                _showStatus = !_showStatus;
                onLayout();
                break;
            default:
                break;
        }
        invalidate();
        if (_dispatchAction !is null)
            _dispatchAction(action);
    }

    private ContextMenuItem[] menuItems(int index)
    {
        switch (index)
        {
            case 0:
                return [
                    ContextMenuItem.command("New", delegate()
                        { dispatch("file.new"); }, "Ctrl+N"),
                    ContextMenuItem.command("Open...", delegate()
                        { dispatch("file.open"); }, "Ctrl+O"),
                    ContextMenuItem.command("Save", delegate()
                        { dispatch("file.save"); }, "Ctrl+S"),
                    ContextMenuItem.command("Save As...", delegate()
                        { dispatch("file.saveAs"); }, "Ctrl+Shift+S"),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("Page Setup...", delegate()
                        { dispatch("file.pageSetup"); }),
                    ContextMenuItem.command("Print...", delegate()
                        { dispatch("file.print"); }, "Ctrl+P"),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("Exit", delegate()
                        { dispatch("file.exit"); })
                ];
            case 1:
                return [
                    ContextMenuItem.command("Undo", delegate()
                        { dispatch("edit.undo"); }, "Ctrl+Z"),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("Cut", delegate()
                        { dispatch("edit.cut"); }, "Ctrl+X"),
                    ContextMenuItem.command("Copy", delegate()
                        { dispatch("edit.copy"); }, "Ctrl+C"),
                    ContextMenuItem.command("Paste", delegate()
                        { dispatch("edit.paste"); }, "Ctrl+V"),
                    ContextMenuItem.command("Delete", delegate()
                        { dispatch("edit.delete"); }, "Del"),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("Find...", delegate()
                        { dispatch("edit.find"); }, "Ctrl+F"),
                    ContextMenuItem.command("Find Next", delegate()
                        { dispatch("edit.findNext"); }, "F3"),
                    ContextMenuItem.command("Replace...", delegate()
                        { dispatch("edit.replace"); }, "Ctrl+H"),
                    ContextMenuItem.command("Go To...", delegate()
                        { dispatch("edit.goto"); }, "Ctrl+G"),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("Select All", delegate()
                        { dispatch("edit.selectAll"); }, "Ctrl+A"),
                    ContextMenuItem.command("Time/Date", delegate()
                        { dispatch("edit.timeDate"); }, "F5")
                ];
            case 2:
                return [
                    ContextMenuItem.check("Word Wrap", _wordWrap, delegate()
                        { dispatch("format.wordWrap"); }),
                    ContextMenuItem.command("Font...", delegate()
                        { dispatch("format.font"); })
                ];
            case 3:
                return [
                    ContextMenuItem.check("Status Bar", _showStatus, delegate()
                        { dispatch("view.statusBar"); })
                ];
            case 4:
                return [
                    ContextMenuItem.command("View Help", delegate()
                        { dispatch("help.view"); }),
                    ContextMenuItem.separatorItem(),
                    ContextMenuItem.command("About Notepad", delegate()
                        { dispatch("help.about"); })
                ];
            default:
                return [];
        }
    }
}

Widget createNotepad(ComponentContext context, JSONValue props)
{
    if (context.window is null)
        throw new Exception("notepad.win10 requires a window");
    string title = "Untitled - Notepad";
    string text = "";
    if (props.type == JSONType.object)
    {
        if (auto value = "title" in props.object)
            if ((*value).type == JSONType.string)
                title = (*value).str;
        if (auto value = "text" in props.object)
            if ((*value).type == JSONType.string)
                text = (*value).str;
    }
    return new NotepadView(context.window, title, text,
        context.dispatchAction);
}

module experiment.aurorahost.notepad_ui;

import experiment.aurorahost.caption : CaptionInteractionLayer;
import experiment.aurorahost.component : ComponentContext;
import experiment.aurorahost.host_editor : HostTextEditor;
import aurora;
import aurora.image : RgbaImage;
import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
import aurora.widgets.titlebar : TitleBarControl;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : sqrt;
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
    private RgbaImage _icon;
    private RgbaImage _closeGlyph;
    private int _closeGlyphPhysical;
    private CaptionInteractionLayer _caption;

    private int _hotMenu = -1;
    private int _pressedMenu = -1;

    private enum int titleHeight = 32;
    private enum int menuHeight = 24;
    private enum int statusHeight = 22;
    private enum int captionWidth = 46;

    this(GuiWindow window, string title, string text, RgbaImage icon,
        void delegate(string action) dispatchAction)
    {
        _window = window;
        _title = toUTF32(title);
        _icon = icon;
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

        _caption = new CaptionInteractionLayer(window, titleHeight);
        _caption.onVisualChanged = delegate() { invalidate(); };
        add(_caption);

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
        _caption.setBounds(Rect(0, 0, bounds().width, titleHeight));
        _caption.layoutTree();
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
        if (_icon !is null)
            canvas.drawImage(icon, _icon);
        else
        {
            canvas.fillRoundedRect(icon, 2, Color.rgb(0x2a, 0x6f, 0xcc));
            canvas.fillRect(Rect(icon.x + 3, icon.y + 4, 10, 1),
                Color.rgb(255, 255, 255));
            canvas.fillRect(Rect(icon.x + 3, icon.y + 8, 10, 1),
                Color.rgb(255, 255, 255));
            canvas.fillRect(Rect(icon.x + 3, icon.y + 12, 7, 1),
                Color.rgb(255, 255, 255));
        }

        canvas.drawTextInRect(Rect(32, 0, width - 180, titleHeight),
            _title, text, 1, HorizontalAlign.left, VerticalAlign.middle, true);

        foreach (target; [CaptionTarget.minimize, CaptionTarget.maximize,
            CaptionTarget.close])
        {
            const rect = captionRect(target);
            const hot = target == captionTarget(_caption.hotControl());
            const pressed = target == captionTarget(_caption.pressedControl());
            if (hot || pressed)
                canvas.fillRect(rect,
                    target == CaptionTarget.close ?
                    Color.rgb(0xe8, 0x11, 0x23) :
                    Color.rgb(0xe5, 0xe5, 0xe5));
            Color glyph = hot && target == CaptionTarget.close ?
                Color.rgb(255, 255, 255) : text;
            const cx = rect.x + rect.width / 2;
            const cy = rect.y + rect.height / 2;
            if (target == CaptionTarget.minimize)
                canvas.fillRect(Rect(cx - 5, cy, 10, 1), glyph);
            else if (target == CaptionTarget.maximize)
                canvas.strokeRect(Rect(cx - 5, cy - 5, 10, 10), glyph, 1);
            else
            {
                auto glyphRect = Rect(cx - 5, cy - 5, 10, 10);
                auto image = closeGlyph();
                canvas.drawImage(glyphRect, image, image.bounds(), glyph, false);
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
        const nextMenu = menuAt(event.position);
        if (nextMenu != _hotMenu)
        {
            _hotMenu = nextMenu;
            setCursor(nextMenu >= 0 ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        return nextMenu >= 0;
    }

    override bool onMouseDown(ref Event event)
    {
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
        if (_pressedMenu >= 0)
        {
            _pressedMenu = -1;
            invalidate();
            return true;
        }
        return false;
    }

    private static CaptionTarget captionTarget(TitleBarControl control)
    {
        switch (control)
        {
            case TitleBarControl.minimize: return CaptionTarget.minimize;
            case TitleBarControl.maximize: return CaptionTarget.maximize;
            case TitleBarControl.close: return CaptionTarget.close;
            default: return CaptionTarget.none;
        }
    }

    private void updateStatus()
    {
        _statusText = format("Ln %d, Col %d",
            _editor.cursorLine() + 1, _editor.cursorColumn() + 1);
        invalidate();
    }

    private RgbaImage closeGlyph()
    {
        const physical = _window.displayScale().logicalToPhysical(
            Size(10, 10)).width;
        if (_closeGlyph is null || _closeGlyphPhysical != physical)
        {
            _closeGlyph = renderCloseGlyph(physical);
            _closeGlyphPhysical = physical;
        }
        return _closeGlyph;
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

private double distanceToSegment(double px, double py, double ax, double ay,
    double bx, double by)
{
    const dx = bx - ax;
    const dy = by - ay;
    const lengthSquared = dx * dx + dy * dy;
    double t = lengthSquared == 0 ? 0 :
        ((px - ax) * dx + (py - ay) * dy) / lengthSquared;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    const qx = ax + t * dx - px;
    const qy = ay + t * dy - py;
    return sqrt(qx * qx + qy * qy);
}

/**
 * Rasterize the caption close mark at physical resolution. The two crossing
 * strokes are supersampled so the mark stays sharp at 125% and 150% DPI
 * instead of becoming a jagged logical-pixel diagonal.
 */
private RgbaImage renderCloseGlyph(int size)
{
    const samples = 4;
    const inset = size * 0.1;
    const start = inset;
    const end = size - inset;
    // Match the 1-logical-pixel stroke used by the minimize and maximize
    // marks after conversion to the current physical raster size.
    const halfWidth = size * 0.04;
    auto pixels = new ubyte[size * size * 4];
    foreach (y; 0 .. size)
    {
        foreach (x; 0 .. size)
        {
            uint covered;
            foreach (sy; 0 .. samples)
            {
                foreach (sx; 0 .. samples)
                {
                    const px = x + (sx + 0.5) / samples;
                    const py = y + (sy + 0.5) / samples;
                    if (distanceToSegment(px, py, start, start, end, end) <=
                            halfWidth ||
                        distanceToSegment(px, py, end, start, start, end) <=
                            halfWidth)
                        ++covered;
                }
            }
            const offset = (y * size + x) * 4;
            pixels[offset] = 255;
            pixels[offset + 1] = 255;
            pixels[offset + 2] = 255;
            pixels[offset + 3] = cast(ubyte)
                (covered * 255 / (samples * samples));
        }
    }
    return new RgbaImage(size, size, pixels);
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
    return new NotepadView(context.window, title, text, context.icon,
        context.dispatchAction);
}

module experiment.aurorahost.host_ui;

import experiment.aurorahost.host_editor : HostTextArea;
import aurora;
import std.algorithm : max;
import std.string : toLower;
import std.utf : toUTF32, toUTF8;

/** Rendering role for a host chrome button. */
enum ChromeStyle
{
    standard,
    menu,
    toolbar,
    flat,
    status
}

ChromeStyle parseChromeStyle(string name, ChromeStyle fallback = ChromeStyle.standard)
{
    switch (name.toLower)
    {
        case "": return fallback;
        case "standard": return ChromeStyle.standard;
        case "menu": return ChromeStyle.menu;
        case "toolbar": return ChromeStyle.toolbar;
        case "flat": return ChromeStyle.flat;
        case "status": return ChromeStyle.status;
        default: return fallback;
    }
}

/**
 * Paint toolbar glyphs without translucent fills.
 *
 * Aurora's stock icon set uses alpha fills, which the retained canvas draws
 * opaque.  Chrome buttons therefore use a small set of solid, background-aware
 * glyphs so page and floppy faces stay legible on light chrome.
 */
private void drawChromeIcon(ref Canvas canvas, IconKind icon, Rect rect,
    Color foreground, Color accent, Color surface)
{
    const scale = max(1, rect.width / 18);
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    switch (icon)
    {
        case IconKind.newDocument:
            auto page = Rect(cx - 7 * scale, cy - 9 * scale,
                14 * scale, 18 * scale);
            canvas.drawRoundedRect(page, 2 * scale, surface, foreground, scale);
            canvas.drawLine(Point(page.right() - 5 * scale, page.y),
                Point(page.right(), page.y + 5 * scale), foreground, scale);
            canvas.drawLine(Point(page.right() - 5 * scale, page.y),
                Point(page.right() - 5 * scale, page.y + 5 * scale),
                foreground, scale);
            canvas.drawLine(Point(cx, cy - 2 * scale),
                Point(cx, cy + 5 * scale), accent, scale * 2);
            canvas.drawLine(Point(cx - 4 * scale, cy + 1 * scale),
                Point(cx + 4 * scale, cy + 1 * scale), accent, scale * 2);
            break;
        case IconKind.folder:
            canvas.fillRect(Rect(cx - 8 * scale, cy - 7 * scale,
                7 * scale, 4 * scale), accent);
            canvas.drawRoundedRect(Rect(cx - 8 * scale, cy - 4 * scale,
                16 * scale, 10 * scale), 2 * scale, accent, foreground, scale);
            break;
        case IconKind.save:
            auto body = Rect(cx - 7 * scale, cy - 8 * scale,
                14 * scale, 16 * scale);
            canvas.drawRoundedRect(body, 2 * scale, surface, foreground, scale);
            canvas.fillRect(Rect(cx - 2 * scale, cy - 8 * scale,
                5 * scale, 5 * scale), accent);
            canvas.drawLine(Point(cx - 4 * scale, cy + 3 * scale),
                Point(cx + 4 * scale, cy + 3 * scale), accent, scale);
            canvas.drawLine(Point(cx - 4 * scale, cy + 5 * scale),
                Point(cx + 4 * scale, cy + 5 * scale), foreground, scale);
            break;
        case IconKind.search:
            const radius = 6 * scale;
            canvas.fillCircle(Point(cx - scale, cy - scale), radius,
                foreground);
            canvas.fillCircle(Point(cx - scale, cy - scale), radius - 2 * scale,
                surface);
            canvas.drawLine(Point(cx + 3 * scale, cy + 3 * scale),
                Point(cx + 7 * scale, cy + 7 * scale), foreground,
                scale * 2);
            break;
        case IconKind.close:
            canvas.drawLine(Point(cx - 5 * scale, cy - 5 * scale),
                Point(cx + 5 * scale, cy + 5 * scale), foreground, scale);
            canvas.drawLine(Point(cx + 5 * scale, cy - 5 * scale),
                Point(cx - 5 * scale, cy + 5 * scale), foreground, scale);
            break;
        default:
            drawIcon(canvas, icon, rect, foreground, accent);
            break;
    }
}

/** Map a portable scene icon name to Aurora's glyph set. */
IconKind iconForName(string name)
{
    switch (name.toLower)
    {
        case "": return IconKind.none;
        case "new":
        case "document":
        case "newdocument":
        case "file": return IconKind.newDocument;
        case "open":
        case "folder": return IconKind.folder;
        case "save":
        case "floppy": return IconKind.save;
        case "search":
        case "find": return IconKind.search;
        case "settings": return IconKind.settings;
        case "close": return IconKind.close;
        case "terminal": return IconKind.terminal;
        case "computer": return IconKind.computer;
        case "home": return IconKind.home;
        case "refresh": return IconKind.refresh;
        case "up": return IconKind.up;
        case "image": return IconKind.image;
        case "music": return IconKind.music;
        case "drive": return IconKind.drive;
        case "trash": return IconKind.trash;
        case "start": return IconKind.start;
        case "clock": return IconKind.clock;
        case "user": return IconKind.user;
        case "power": return IconKind.power;
        case "wifi": return IconKind.wifi;
        case "volume": return IconKind.volume;
        case "volumemuted": return IconKind.volumeMuted;
        case "battery": return IconKind.battery;
        case "batterycharging": return IconKind.batteryCharging;
        case "chevronright":
        case "right": return IconKind.chevronRight;
        case "chevronleft":
        case "left": return IconKind.none;
        case "chevronup":
        case "uparrow": return IconKind.chevronUp;
        case "chevrondown":
        case "downarrow": return IconKind.chevronDown;
        default: return IconKind.none;
    }
}

/**
 * Compact delayed hover hint. It is a non-interactive root overlay so it can
 * extend beyond its anchor without participating in scene layout.
 */
final class HostTooltip : HBox
{
    private Label _label;

    this(string text = "")
    {
        super(0, Insets(8, 5));
        layoutHints().excludeFromLayout = true;
        setComposited(true);
        setEnabled(false);
        _label = new Label();
        _label.setPixelSize(12);
        _label.setEllipsis(false);
        add(_label);
        const palette = theme();
        setBackground(palette.panelElevated);
        setBorder(palette.border, 3);
        setText(text);
    }

    string text() const
    {
        return toUTF8(_label.text);
    }

    void setText(string text)
    {
        _label.setText(text);
        const measured = measure();
        setBounds(Rect(0, 0, measured.width, measured.height));
        layoutTree();
        invalidate();
    }
}

/**
 * A compact host-styled button used for menu bars and toolbars.
 *
 * Aurora supplies focus, keyboard activation, hit testing and hover state.
 * The host owns only portable drawing, so applications can build desktop-style
 * chrome without adding widget classes to the core toolkit.
 */
class ChromeButton : Button
{
    private ChromeStyle _chromeStyle;
    private IconKind _chromeIcon;
    private bool _active;
    private int _pixelSize;
    private Color _textColor;
    private bool _hasTextColor;

    this(string text = "", IconKind icon = IconKind.none,
        ChromeStyle style = ChromeStyle.standard)
    {
        super(text, icon);
        _chromeStyle = style;
        _chromeIcon = icon;
        setFocusable(true);
    }

    void setChromeStyle(ChromeStyle style)
    {
        _chromeStyle = style;
        invalidate();
    }

    void setChromeIcon(IconKind icon)
    {
        _chromeIcon = icon;
        invalidate();
    }

    void setActive(bool value)
    {
        if (_active == value) return;
        _active = value;
        invalidate();
    }

    void setPixelSize(int value)
    {
        _pixelSize = value > 0 ? value : 0;
        setTextPixelSize(_pixelSize);
        invalidate();
    }

    void setTextColor(Color value)
    {
        _textColor = value;
        _hasTextColor = true;
        invalidate();
    }

    private int textPixelSize()
    {
        const palette = theme();
        return _pixelSize > 0 ? _pixelSize : fontPixelSize(palette.fontScale);
    }

    private TextLayout textLayout()
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = textPixelSize();
        options.wrap = false;
        return fontSystem().textEngine.layoutCached(toUTF32(text()), options);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const body = Rect(0, 0, width, height);
        const radius = _chromeStyle == ChromeStyle.menu ||
            _chromeStyle == ChromeStyle.toolbar ? 3 : palette.cornerRadius;
        Color background = Color.rgba(0, 0, 0, 0);
        bool paintBackground;

        switch (_chromeStyle)
        {
            case ChromeStyle.menu:
                if (_active || pressed())
                {
                    background = palette.buttonPressed;
                    paintBackground = true;
                }
                else if (hovered())
                {
                    background = palette.buttonHover;
                    paintBackground = true;
                }
                break;
            case ChromeStyle.toolbar:
                if (pressed())
                {
                    background = palette.buttonPressed;
                    paintBackground = true;
                }
                else if (_active)
                {
                    background = palette.selection;
                    paintBackground = true;
                }
                else if (hovered())
                {
                    background = palette.buttonHover;
                    paintBackground = true;
                }
                break;
            case ChromeStyle.flat:
            case ChromeStyle.status:
                if (hovered())
                {
                    background = palette.buttonHover;
                    paintBackground = true;
                }
                break;
            case ChromeStyle.standard:
                background = pressed() ? palette.buttonPressed :
                    (hovered() ? palette.buttonHover : palette.buttonBackground);
                paintBackground = true;
                break;
            default:
                break;
        }

        if (paintBackground)
        {
            if (_chromeStyle == ChromeStyle.standard)
                canvas.drawRoundedRect(body, radius, background,
                    palette.border, palette.borderWidth);
            else
                canvas.fillRoundedRect(body, radius, background);
        }

        const textColor = !enabled() ? palette.disabled :
            (_hasTextColor ? _textColor : palette.text);
        auto layout = textLayout();
        const measured = layout.measuredSize();
        const iconSize = 17;
        const iconWidth = _chromeIcon == IconKind.none ? 0 : iconSize;
        const gap = _chromeIcon == IconKind.none ? 0 : 6;
        const horizontalPadding =
            _chromeStyle == ChromeStyle.toolbar ? 7 : 9;
        const contentWidth = iconWidth + gap + measured.width;
        int x = _chromeStyle == ChromeStyle.status ? horizontalPadding :
            max(0, (width - contentWidth) / 2);
        const y = max(0, (height - measured.height) / 2);

        if (_chromeIcon != IconKind.none)
        {
            const iconY = max(0, (height - iconSize) / 2);
            drawChromeIcon(canvas, _chromeIcon,
                Rect(x, iconY, iconSize, iconSize), textColor,
                palette.accent, palette.fieldBackground);
            x += iconSize + gap;
        }
        if (text().length > 0)
            canvas.drawLayout(Point(x, y), layout, textColor);

        if (_active && _chromeStyle == ChromeStyle.toolbar)
            canvas.drawLine(Point(3, height - 2),
                Point(width - 4, height - 2), palette.accent, 2);
    }
}

/** Menu-bar button whose popup items can be replaced by the application. */
class HostMenuButton : ChromeButton
{
    private ContextMenuItem[] _items;

    void delegate() onEmpty;

    this(string text = "")
    {
        super(text, IconKind.none, ChromeStyle.menu);
    }

    void setItems(ContextMenuItem[] items)
    {
        _items = items.dup;
    }

    size_t itemCount() const @safe pure nothrow @nogc
    {
        return _items.length;
    }

    void open()
    {
        if (_items.length > 0)
            showContextMenuBelow(this, _items);
        else if (onEmpty !is null)
            onEmpty();
    }
}

/** One application-owned tab shown by the host TabStrip. */
struct TabItem
{
    string label;
    string action;
    bool active;
    bool dirty;
}

/**
 * Compact desktop tab strip. The host owns tab geometry, hover, active
 * rendering and click routing; applications own the tab list and active index.
 */
class TabStrip : Widget
{
    private TabItem[] _items;
    private int _hover = -1;
    private int _pressed = -1;

    void delegate(string action) onAction;

    this(TabItem[] items = [])
    {
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = 30;
        setItems(items);
    }

    const(TabItem)[] items() const @safe pure nothrow @nogc
    {
        return _items;
    }

    void setItems(TabItem[] items)
    {
        _items = items.dup;
        if (_hover >= _items.length) _hover = -1;
        if (_pressed >= _items.length) _pressed = -1;
        invalidate();
    }

    private TextLayout labelLayout(string label)
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = 12;
        options.wrap = false;
        return fontSystem().textEngine.layoutCached(toUTF32(label), options);
    }

    private int[] tabWidths()
    {
        int[] widths;
        if (_items.length == 0) return widths;
        const available = max(0, bounds().width);
        int total;
        foreach (item; _items)
        {
            auto layout = textLayoutForMeasure(item.label);
            const measured = layout.measuredSize();
            int width = max(86, measured.width + 30);
            width = max(86, width);
            if (width > 210) width = 210;
            widths ~= width;
            total += width;
        }
        if (total > available && available > 0)
        {
            const floor = max(42, available / cast(int) _items.length);
            foreach (ref width; widths)
                if (width > floor) width = floor;
        }
        return widths;
    }

    private TextLayout textLayoutForMeasure(string label)
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = 12;
        options.wrap = false;
        return fontSystem().textEngine.layoutCached(toUTF32(label), options);
    }

    Rect itemRect(int index)
    {
        if (index < 0 || index >= _items.length) return Rect.init;
        auto widths = tabWidths();
        int x;
        foreach (i; 0 .. index)
            x += widths[i];
        return Rect(x, 0, widths[index], bounds().height);
    }

    int itemAt(Point point)
    {
        auto widths = tabWidths();
        int x;
        foreach (index, width; widths)
        {
            if (point.x >= x && point.x < x + width &&
                point.y >= 0 && point.y < bounds().height)
                return cast(int) index;
            x += width;
        }
        return -1;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        canvas.fillRect(Rect(0, 0, width, height), palette.windowBackground);
        auto widths = tabWidths();
        int x;
        foreach (index, item; _items)
        {
            const tabWidth = widths[index];
            const rect = Rect(x, 0, tabWidth, height);
            Color background = item.active ? palette.fieldBackground :
                (cast(int) index == _hover ? palette.buttonHover :
                    palette.buttonBackground);
            canvas.fillRect(rect, background);
            canvas.drawLine(Point(x, 0), Point(x, height - 1),
                palette.border, 1);
            if (item.active)
            {
                canvas.fillRect(Rect(x, 0, tabWidth, 2), palette.accent);
                canvas.drawLine(Point(x, height - 1),
                    Point(x + tabWidth - 1, height - 1),
                    palette.fieldBackground, 1);
            }
            else
                canvas.drawLine(Point(x, height - 1),
                    Point(x + tabWidth - 1, height - 1),
                    palette.border, 1);

            auto layout = labelLayout(item.label);
            const measured = layout.measuredSize();
            const textY = max(0, (height - measured.height) / 2);
            const textColor = item.active ? palette.text : palette.textMuted;
            const maxTextWidth = max(0, tabWidth - 22);
            canvas.clipped(Rect(x + 11, 0, maxTextWidth, height))
                .drawLayout(Point(x + 11, textY), layout, textColor);
            if (item.dirty)
            {
                const dotX = x + tabWidth - 13;
                canvas.fillRect(Rect(dotX, height / 2 - 2, 4, 4),
                    palette.accent);
            }
            x += tabWidth;
        }
        canvas.drawLine(Point(0, height - 1), Point(width, height - 1),
            palette.border, 1);
    }

    override bool onMouseMove(ref Event event)
    {
        const index = itemAt(event.position);
        if (index != _hover)
        {
            _hover = index;
            invalidate();
        }
        return index >= 0;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        _pressed = itemAt(event.position);
        if (_pressed >= 0)
        {
            requestFocus();
            invalidate();
            return true;
        }
        return false;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        const index = itemAt(event.position);
        const pressed = _pressed;
        _pressed = -1;
        invalidate();
        if (pressed < 0 || index != pressed) return false;
        if (onAction !is null)
            onAction(_items[index].action);
        return true;
    }
}

/** TextArea with a generic, app-owned right-click command menu. */
class ContextTextArea : TextArea
{
    private ContextMenuItem[] _items;

    this(string text, ContextMenuItem[] items)
    {
        super(text);
        _items = items.dup;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right && _items.length > 0)
        {
            requestFocus();
            showContextMenuKeepPopups(this,
                localToGlobal(event.position), _items);
            return true;
        }
        return super.onMouseDown(event);
    }
}

/** Host-rendered text area with a generic, app-owned context menu. */
class ContextHostTextArea : HostTextArea
{
    private ContextMenuItem[] _items;

    this(string text, ContextMenuItem[] items)
    {
        super(text);
        _items = items.dup;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right && _items.length > 0)
        {
            requestFocus();
            showContextMenuKeepPopups(this,
                localToGlobal(event.position), _items);
            return true;
        }
        return super.onMouseDown(event);
    }
}

/** TextField with a generic, app-owned right-click command menu. */
class ContextTextField : TextField
{
    private ContextMenuItem[] _items;

    this(string text, ContextMenuItem[] items)
    {
        super(text);
        _items = items.dup;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right && _items.length > 0)
        {
            requestFocus();
            showContextMenuKeepPopups(this,
                localToGlobal(event.position), _items);
            return true;
        }
        return super.onMouseDown(event);
    }
}

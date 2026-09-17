module auroradesktop.taskpreview;

import aurora;
import aurora.widgets.desktop : FloatingWindow;
import aurora.widgets.popup : TransientPopup, dismissTransientPopups, popupRoot;
import aurora.image : RgbaImage;
import aurora.surface : Surface;
import aurora.canvas : Canvas;
import std.utf : toUTF32;

/**
 * A small Windows-11-style thumbnail preview shown above a hovered taskbar
 * entry. It renders the target window's content into a scaled image, draws a
 * title bar with the window title, and an X (close) button in the top-right
 * corner. It is a TransientPopup so it dismisses on click-away / Escape.
 *
 * The preview is deliberately compact (~224x168) so a hovered task shows just
 * a peek, exactly like the Windows taskbar widget preview.
 */
final class TaskPreview : TransientPopup
{
    private dstring _title;
    // One tile per previewed window. A single-window task has one tile; a
    // grouped app shows one tile per window in a row.
    private RgbaImage[] _thumbnails;
    private ulong[] _hwnds;          // per-tile external hwnd (0 = in-shell)
    private dstring[] _tileTitles;   // per-tile caption
    private Rect _panelRect;
    private Rect _titleRect;
    private Rect[] _tileRects;
    private Rect[] _tileCaptionRects;
    private Rect _closeRect;
    private Rect _anchorGlobal;
    private int _margin = 8;
    private int _gap = 6;
    private int _titleHeight = 30;
    private int _tileWidth = 200;
    private int _panelHeight = 168;
    private int _captionHeight = 18;
    private bool _opening;
    private bool _closeHover;
    private int _hotTile = -1;
    private bool _pointerInside;
    // Fade-in on show. `_opacity` scales every painted colour's alpha.
    private double _opacity = 1.0;
    private bool _fadeActive;
    private enum double fadeInSeconds = 0.15;

    /// Invoked when the X (close) button is clicked.
    void delegate() onCloseRequested;
    /// Invoked when the preview body is clicked (click-to-focus the task).
    void delegate() onActivate;
    /// Invoked when a specific grouped window's tile is clicked.
    void delegate(ulong hwnd) onActivateHwnd;

    this(FloatingWindow window, Widget content, string title, IconKind icon)
    {
        super();
        setCursor(CursorKind.arrow);
        _title = toUTF32(title);
        auto image = renderThumbnail(content, window.size());
        if (image !is null) _thumbnails ~= image;
    }

    /// Build a preview from an already-captured image (external OS window).
    this(string title, RgbaImage thumbnail)
    {
        super();
        setCursor(CursorKind.arrow);
        _title = toUTF32(title);
        if (thumbnail !is null) _thumbnails ~= thumbnail;
    }

    /// Build a grouped preview: one tile per external window of the same app.
    this(string title, RgbaImage[] thumbnails, ulong[] hwnds,
        string[] captions)
    {
        super();
        setCursor(CursorKind.arrow);
        _title = toUTF32(title);
        _thumbnails = thumbnails;
        _hwnds = hwnds;
        foreach (caption; captions) _tileTitles ~= toUTF32(caption);
    }

    Rect panelRect() const @safe pure nothrow @nogc
    {
        return _panelRect;
    }

    bool show(Widget owner, Rect globalAnchor)
    {
        auto root = popupRoot(owner);
        if (root is null) return false;
        if (open()) dismiss();
        dismissTransientPopups(root);
        prepareToOpen(owner);
        _opening = true;
        _anchorGlobal = globalAnchor;
        root.add(this);
        setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
        root.bringChildToFront(this);
        recalculateLayout();
        requestFocus();
        _opening = false;
        // Fade in from transparent.
        _opacity = 0.0;
        _fadeActive = true;
        invalidate();
        return true;
    }

    bool open()
    {
        return parent() !is null && !dismissed();
    }

    /// Current fade opacity (0..1); exposed for tests.
    double opacity() const @safe pure nothrow @nogc { return _opacity; }

    override void dismiss()
    {
        if (dismissed() || _opening) return;
        super.dismiss();
    }

    protected override void onTick(double deltaSeconds)
    {
        if (!_fadeActive) return;
        _opacity += deltaSeconds / fadeInSeconds;
        if (_opacity >= 1.0)
        {
            _opacity = 1.0;
            _fadeActive = false;
        }
        invalidate();
    }

    /// Scale a colour's alpha by the current fade opacity.
    private Color fade(Color value) const @safe pure nothrow @nogc
    {
        return value.withAlpha(cast(ubyte) (value.a * _opacity + 0.5));
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    /**
     * The popup overlay spans the whole root for click-away, but it must only
     * receive hover/clicks over its actual panel. Returning null elsewhere lets
     * the taskbar beneath keep its hover, so the preview does not flicker and
     * the pointer can travel from a task button onto the preview.
     */
    override Widget hitTest(Point globalPoint)
    {
        if (!visible() || !enabled() || _panelRect.empty()) return null;
        const local = globalToLocal(globalPoint);
        return _panelRect.contains(local) ? this : null;
    }

    /// True while the pointer is over the preview panel (see `hitTest`).
    bool pointerInside() const @safe pure nothrow @nogc
    {
        return _pointerInside;
    }

    protected override void onMouseEnter()
    {
        _pointerInside = true;
    }

    protected override void onMouseLeave()
    {
        _pointerInside = false;
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        dismiss();
        return false;
    }

    private void recalculateLayout()
    {
        const tileCount = maxInt(1, cast(int) _thumbnails.length);
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            _titleRect = Rect.init;
            _tileRects = null;
            _tileCaptionRects = null;
            _closeRect = Rect.init;
            return;
        }
        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);

        const padding = 10;
        // Fit every tile in a row; shrink the tiles when the screen cannot hold
        // the nominal width (Windows grows the flyout, then scrolls; here we
        // shrink so grouped windows always stay reachable).
        int tileWidth = _tileWidth;
        const maxContent = availableWidth - padding * 2 - _gap * (tileCount - 1);
        if (maxContent < tileWidth * tileCount)
            tileWidth = maxInt(72, maxContent / tileCount);
        const desiredWidth = padding * 2 + tileWidth * tileCount +
            _gap * (tileCount - 1);
        const width = minInt(desiredWidth, availableWidth);
        const height = minInt(_panelHeight, availableHeight);

        const rootOrigin = globalOrigin();
        const anchor = Rect(_anchorGlobal.x - rootOrigin.x,
            _anchorGlobal.y - rootOrigin.y, _anchorGlobal.width,
            _anchorGlobal.height);
        // Center horizontally over the entry; sit just above it.
        int x = anchor.x + anchor.width / 2 - width / 2;
        int y = anchor.y - height - _gap;
        if (y < _margin) y = anchor.bottom() + _gap;
        x = clampInt(x, _margin, maxInt(_margin, bounds().width - width - _margin));
        y = clampInt(y, _margin, maxInt(_margin, bounds().height - height - _margin));
        _panelRect = Rect(x, y, width, height);

        _titleRect = Rect(_panelRect.x + padding, _panelRect.y + padding,
            _panelRect.width - padding * 2, _titleHeight);
        const closeSize = 16;
        _closeRect = Rect(_titleRect.right() - closeSize - 4,
            _titleRect.y + (_titleRect.height - closeSize) / 2,
            closeSize, closeSize);

        const contentY = _titleRect.bottom() + 6;
        const contentHeight = maxInt(1, _panelRect.bottom() - padding - contentY);
        const usable = maxInt(1, _panelRect.width - padding * 2 -
            _gap * (tileCount - 1));
        const actualTile = maxInt(1, usable / tileCount);
        // A single-window preview gets the full content height (its title is
        // already in the popup header); a group reserves a caption row per tile.
        const captionH = tileCount > 1 ? _captionHeight : 0;
        _tileRects.length = tileCount;
        _tileCaptionRects.length = tileCount;
        foreach (i; 0 .. tileCount)
        {
            const tx = _panelRect.x + padding + i * (actualTile + _gap);
            _tileCaptionRects[i] = Rect(tx, contentY, actualTile, captionH);
            _tileRects[i] = Rect(tx, contentY + captionH, actualTile,
                maxInt(1, contentHeight - captionH));
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_panelRect.empty()) return;
        const palette = theme();
        canvas.fillRoundedRect(_panelRect.translated(3, 4), 8,
            fade(Color.rgba(0, 0, 0, 135)));
        canvas.drawRoundedRect(_panelRect, 8, fade(palette.panelElevated),
            fade(palette.border.withAlpha(230)), 1);

        // Title bar.
        canvas.drawTextInRect(_titleRect, _title, fade(palette.text), 2,
            HorizontalAlign.left, VerticalAlign.middle, true);

        // X (close) button in the top-right corner.
        if (_closeHover)
            canvas.fillRoundedRect(_closeRect.inset(-2), 4,
                fade(palette.buttonHover));
        drawIcon(canvas, IconKind.close, _closeRect.inset(3),
            fade(_closeHover ? Color.rgb(255, 255, 255) : palette.textMuted),
            fade(palette.accent));

        // Thumbnail tiles (one for a single window, a row for a grouped app).
        foreach (i; 0 .. _tileRects.length)
        {
            const tile = _tileRects[i];
            if (i == _hotTile)
                canvas.drawRoundedRect(tile.inset(-2), 6, Color.rgba(0, 0, 0, 0),
                    fade(palette.accent.withAlpha(210)), 2);
            RgbaImage image = i < _thumbnails.length ? _thumbnails[i] : null;
            if (image !is null && !tile.empty())
            {
                canvas.drawRoundedRect(tile, 4, fade(palette.panelBackground),
                    fade(palette.border.withAlpha(120)), 1);
                // Fit the image into the tile preserving aspect.
                const scale = minDouble(
                    cast(double) tile.width / image.width(),
                    cast(double) tile.height / image.height());
                const dw = maxInt(1, cast(int) (image.width() * scale));
                const dh = maxInt(1, cast(int) (image.height() * scale));
                const img = Rect(tile.x + (tile.width - dw) / 2,
                    tile.y + (tile.height - dh) / 2, dw, dh);
                canvas.drawImage(img, image, image.bounds(),
                    fade(Color.rgb(255, 255, 255)));
            }
            else
            {
                canvas.drawTextInRect(tile, "No preview"d,
                    fade(palette.textMuted), 1, HorizontalAlign.center,
                    VerticalAlign.middle, true);
            }
            if (i < _tileCaptionRects.length && i < _tileTitles.length &&
                _tileTitles[i].length > 0)
                canvas.drawTextInRect(_tileCaptionRects[i], _tileTitles[i],
                    fade(i == _hotTile ? palette.text :
                        palette.text.withAlpha(210)), 1, HorizontalAlign.center,
                    VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const closeHover = _closeRect.contains(event.position);
        int hot = -1;
        foreach (i; 0 .. _tileRects.length)
            if (_tileRects[i].contains(event.position))
            {
                hot = cast(int) i;
                break;
            }
        if (closeHover != _closeHover || hot != _hotTile)
        {
            _closeHover = closeHover;
            _hotTile = hot;
            invalidate();
        }
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return true;
        if (!_panelRect.contains(event.position))
        {
            dismiss();
            return true;
        }
        if (event.button == MouseButton.right) return true;
        if (_closeRect.contains(event.position))
        {
            if (onCloseRequested !is null) onCloseRequested();
            dismiss();
            return true;
        }
        foreach (i; 0 .. _tileRects.length)
        {
            if (!_tileRects[i].contains(event.position)) continue;
            if (i < _hwnds.length && _hwnds[i] != 0 && onActivateHwnd !is null)
                onActivateHwnd(_hwnds[i]);
            else if (onActivate !is null)
                onActivate();
            dismiss();
            return true;
        }
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape)
        {
            dismiss();
            return true;
        }
        return false;
    }

    // --- thumbnail rasterization ---------------------------------------
    // Rasterize a window's widget subtree into a small image. The window's
    // content is painted via paintTreeSkippingComposited into a CPU Surface,
    // then downsampled to straight-alpha RGBA for the renderer's drawImage.
    private static RgbaImage renderThumbnail(Widget content, Size windowSize)
    {
        if (content is null) return null;
        const srcW = maxInt(1, windowSize.width);
        const srcH = maxInt(1, windowSize.height);
        // Limited target so a huge window cannot blow memory.
        const targetSide = 360;
        const ratio = minDouble(1.0,
            cast(double) targetSide / maxInt(1, maxInt(srcW, srcH)));
        const outW = maxInt(1, cast(int) (srcW * ratio));
        const outH = maxInt(1, cast(int) (srcH * ratio));

        auto surface = new Surface(srcW, srcH);
        surface.clear(Color.rgb(24, 24, 28));
        auto canvas = Canvas(surface);
        // Temporarily place content at origin and force it visible so a
        // minimized window still paints its content into the preview. Use
        // plain paintTree (composited children just paint into this canvas).
        const savedBounds = content.bounds();
        const savedVisible = content.visible();
        content.setVisible(true);
        content.setBounds(Rect(0, 0, srcW, srcH));
        content.layoutTree();
        content.paintTree(canvas);
        content.setBounds(savedBounds);
        content.setVisible(savedVisible);

        // Downsample (nearest) into the output size and build straight RGBA.
        ubyte[] rgba;
        rgba.length = cast(size_t) outW * cast(size_t) outH * 4;
        foreach (y; 0 .. outH)
        {
            const srcY = cast(int) (y / ratio);
            foreach (x; 0 .. outW)
            {
                const srcX = cast(int) (x / ratio);
                const argb = surface.pixel(srcX, srcY);
                const a = cast(ubyte) ((argb >> 24) & 0xff);
                const r = cast(ubyte) ((argb >> 16) & 0xff);
                const g = cast(ubyte) ((argb >> 8) & 0xff);
                const b = cast(ubyte) (argb & 0xff);
                const t = cast(size_t) (cast(size_t) y * outW + x) * 4;
                // Surface stores premultiplied alpha; recover straight alpha.
                if (a > 0 && a < 255)
                {
                    rgba[t + 0] = cast(ubyte) minInt(255, (r * 255 + a / 2) / a);
                    rgba[t + 1] = cast(ubyte) minInt(255, (g * 255 + a / 2) / a);
                    rgba[t + 2] = cast(ubyte) minInt(255, (b * 255 + a / 2) / a);
                }
                else
                {
                    rgba[t + 0] = r;
                    rgba[t + 1] = g;
                    rgba[t + 2] = b;
                }
                rgba[t + 3] = a;
            }
        }
        return new RgbaImage(outW, outH, rgba);
    }

    private static double minDouble(double a, double b)
    {
        return a < b ? a : b;
    }
}

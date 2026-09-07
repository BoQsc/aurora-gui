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
    private RgbaImage _thumbnail;
    private Rect _panelRect;
    private Rect _titleRect;
    private Rect _imageRect;
    private Rect _closeRect;
    private Rect _anchorGlobal;
    private int _margin = 8;
    private int _gap = 6;
    private int _titleHeight = 30;
    private int _panelWidth = 224;
    private int _panelHeight = 168;
    private bool _opening;
    private bool _closeHover;

    /// Invoked when the X (close) button is clicked.
    void delegate() onCloseRequested;
    /// Invoked when the preview body is clicked (click-to-focus the task).
    void delegate() onActivate;

    this(FloatingWindow window, Widget content, string title, IconKind icon)
    {
        super();
        setCursor(CursorKind.arrow);
        _title = toUTF32(title);
        _thumbnail = renderThumbnail(content, window.size());
    }

    /// Build a preview from an already-captured image (external OS window).
    this(string title, RgbaImage thumbnail)
    {
        super();
        setCursor(CursorKind.arrow);
        _title = toUTF32(title);
        _thumbnail = thumbnail;
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
        invalidate();
        return true;
    }

    bool open()
    {
        return parent() !is null && !dismissed();
    }

    override void dismiss()
    {
        if (dismissed() || _opening) return;
        super.dismiss();
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        dismiss();
        return false;
    }

    private void recalculateLayout()
    {
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            _titleRect = Rect.init;
            _imageRect = Rect.init;
            _closeRect = Rect.init;
            return;
        }
        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);
        const width = minInt(_panelWidth, availableWidth);
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

        const padding = 10;
        _titleRect = Rect(_panelRect.x + padding, _panelRect.y + padding,
            _panelRect.width - padding * 2, _titleHeight);
        _imageRect = Rect(_panelRect.x + padding, _titleRect.bottom() + 6,
            _panelRect.width - padding * 2,
            _panelRect.bottom() - _titleRect.bottom() - padding - 6);
        const closeSize = 16;
        _closeRect = Rect(_titleRect.right() - closeSize - 4,
            _titleRect.y + (_titleRect.height - closeSize) / 2,
            closeSize, closeSize);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_panelRect.empty()) return;
        const palette = theme();
        canvas.fillRoundedRect(_panelRect.translated(3, 4), 8,
            Color.rgba(0, 0, 0, 135));
        canvas.drawRoundedRect(_panelRect, 8, palette.panelElevated,
            palette.border.withAlpha(230), 1);

        // Title bar.
        canvas.drawTextInRect(_titleRect, _title, palette.text, 2,
            HorizontalAlign.left, VerticalAlign.middle, true);

        // X (close) button in the top-right corner.
        if (_closeHover)
            canvas.fillRoundedRect(_closeRect.inset(-2), 4,
                palette.buttonHover);
        drawIcon(canvas, IconKind.close, _closeRect.inset(3),
            _closeHover ? Color.rgb(255, 255, 255) : palette.textMuted,
            palette.accent);

        // Thumbnail image.
        if (_thumbnail !is null && !_imageRect.empty())
        {
            canvas.drawRoundedRect(_imageRect, 4, palette.panelBackground,
                palette.border.withAlpha(120), 1);
            // Fit the image into the image rect preserving aspect.
            const scale = minDouble(
                cast(double) _imageRect.width / _thumbnail.width(),
                cast(double) _imageRect.height / _thumbnail.height());
            const dw = maxInt(1, cast(int) (_thumbnail.width() * scale));
            const dh = maxInt(1, cast(int) (_thumbnail.height() * scale));
            const img = Rect(_imageRect.x + (_imageRect.width - dw) / 2,
                _imageRect.y + (_imageRect.height - dh) / 2, dw, dh);
            canvas.drawImage(img, _thumbnail);
        }
        else
        {
            canvas.drawTextInRect(_imageRect, "No preview"d, palette.textMuted,
                1, HorizontalAlign.center, VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const hover = _closeRect.contains(event.position);
        if (hover != _closeHover)
        {
            _closeHover = hover;
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
        if (_imageRect.contains(event.position))
        {
            if (onActivate !is null) onActivate();
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

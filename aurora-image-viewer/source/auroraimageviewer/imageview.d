module auroraimageviewer.imageview;

import aurora;
import auroraimageviewer.scaler : MipImage;
import core.time : MonoTime;
import std.algorithm : max, min;
import std.math : abs, pow;
import std.utf : toUTF32;

/**
 * Image canvas with custom mipmapped rendering, drag panning, and cursor
 * centered wheel zoom.
 *
 * The widget renders the visible region itself into a reusable RGB24 buffer
 * sized to its bounds and submits that buffer 1:1, so interaction cost is a
 * small bilinear pass over a pre-filtered mip level instead of a full-res
 * resample. It is an opaque retained compositor layer so panning and zooming
 * never force the surrounding UI to repaint.
 */
final class ImageView : Widget
{
    private static immutable Color checkerA = Color.fromHex(0x3b4046);
    private static immutable Color checkerB = Color.fromHex(0x2b3036);
    private static immutable Color letterbox = Color.fromHex(0x141619);
    private static immutable double minimumZoom = 0.02;
    private static immutable double maximumZoom = 64.0;

    private MipImage _image;
    private double _zoom = 1.0;
    private double _offsetX;
    private double _offsetY;
    private bool _panning;
    private Point _lastPointer;
    private ubyte[] _rgb;
    private dstring _hintText;
    private dstring _errorText;
    private long _lastRenderMicros;

    void delegate() onViewChanged;
    void delegate() onOpenRequested;
    void delegate() onReloadRequested;
    void delegate(string path) onFileDropped;

    this()
    {
        setComposited(true);
        setCompositedOpaque(true);
        setFocusable(true);
        layoutHints().minWidth = 320;
        layoutHints().minHeight = 200;
        layoutHints().flex = 1.0;
        _hintText = toUTF32("Drop an image here or press Ctrl+O");
    }

    bool hasImage() const @safe pure nothrow @nogc { return _image !is null; }
    const(MipImage) image() const @safe pure nothrow @nogc { return _image; }
    double zoom() const @safe pure nothrow @nogc { return _zoom; }
    double offsetX() const @safe pure nothrow @nogc { return _offsetX; }
    double offsetY() const @safe pure nothrow @nogc { return _offsetY; }
    int imageWidth() const @safe pure nothrow @nogc
    {
        return _image is null ? 0 : _image.width();
    }
    int imageHeight() const @safe pure nothrow @nogc
    {
        return _image is null ? 0 : _image.height();
    }

    long lastRenderMilliseconds() const @safe pure nothrow @nogc
    {
        return _lastRenderMicros / 1000;
    }

    void setImage(MipImage image)
    {
        _image = image;
        _errorText.length = 0;
        if (_image is null)
        {
            _zoom = 1.0;
            _offsetX = 0.0;
            _offsetY = 0.0;
        }
        else
            fitToWindow();
        invalidate();
        if (onViewChanged !is null) onViewChanged();
    }

    void setError(string message)
    {
        _image = null;
        _errorText = toUTF32(message);
        invalidate();
    }

    void fitToWindow()
    {
        if (_image is null) return;
        const viewWidth = maxInt(1, bounds().width);
        const viewHeight = maxInt(1, bounds().height);
        const scaleX = cast(double) viewWidth / cast(double) _image.width();
        const scaleY = cast(double) viewHeight / cast(double) _image.height();
        _zoom = max(minimumZoom, min(scaleX, scaleY));
        centerImage();
        invalidate();
        if (onViewChanged !is null) onViewChanged();
    }

    void actualSize()
    {
        if (_image is null) return;
        _zoom = 1.0;
        centerImage();
        invalidate();
        if (onViewChanged !is null) onViewChanged();
    }

    void zoomIn()
    {
        zoomAt(_zoom * 1.5, cast(double) bounds().width / 2.0,
            cast(double) bounds().height / 2.0);
    }

    void zoomOut()
    {
        zoomAt(_zoom / 1.5, cast(double) bounds().width / 2.0,
            cast(double) bounds().height / 2.0);
    }

    void panBy(double sourceDx, double sourceDy)
    {
        if (_image is null) return;
        _offsetX += sourceDx;
        _offsetY += sourceDy;
        clampOffsets();
        invalidate();
        if (onViewChanged !is null) onViewChanged();
    }

    private void centerImage()
    {
        const viewWidth = maxInt(1, bounds().width);
        const viewHeight = maxInt(1, bounds().height);
        _offsetX = (cast(double) _image.width() - viewWidth / _zoom) * 0.5;
        _offsetY = (cast(double) _image.height() - viewHeight / _zoom) * 0.5;
        clampOffsets();
    }

    private void zoomAt(double newZoom, double cursorX, double cursorY)
    {
        if (_image is null) return;
        newZoom = clampDouble(newZoom, minimumZoom, maximumZoom);
        const sourceX = _offsetX + cursorX / _zoom;
        const sourceY = _offsetY + cursorY / _zoom;
        _zoom = newZoom;
        _offsetX = sourceX - cursorX / _zoom;
        _offsetY = sourceY - cursorY / _zoom;
        clampOffsets();
        invalidate();
        if (onViewChanged !is null) onViewChanged();
    }

    private void clampOffsets()
    {
        if (_image is null) return;
        const viewWidth = maxInt(1, bounds().width);
        const viewHeight = maxInt(1, bounds().height);
        const visibleWidth = viewWidth / _zoom;
        const visibleHeight = viewHeight / _zoom;
        _offsetX = clampDouble(_offsetX,
            min(0.0, cast(double) _image.width() - visibleWidth),
            max(0.0, cast(double) _image.width() - visibleWidth));
        _offsetY = clampDouble(_offsetY,
            min(0.0, cast(double) _image.height() - visibleHeight),
            max(0.0, cast(double) _image.height() - visibleHeight));
    }

    protected override void onBoundsChanged()
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const required = cast(size_t) width * cast(size_t) height * 3;
        if (_rgb.length != required) _rgb.length = required;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const required = cast(size_t) width * cast(size_t) height * 3;
        if (_rgb.length != required) _rgb.length = required;

        if (_image is null)
        {
            canvas.fillRect(Rect(0, 0, width, height), letterbox);
            if (_errorText.length > 0)
                canvas.drawTextInRect(Rect(24, 0, maxInt(0, width - 48), height),
                    _errorText, Color.fromHex(0xff9b9b), 2,
                    HorizontalAlign.center, VerticalAlign.middle, true);
            else
                canvas.drawTextInRect(Rect(24, 0, maxInt(0, width - 48), height),
                    _hintText, Color.fromHex(0x8a929c), 2,
                    HorizontalAlign.center, VerticalAlign.middle, true);
            return;
        }

        const start = MonoTime.currTime;
        _image.render(_rgb, width, height, _zoom, _offsetX, _offsetY,
            letterbox, checkerA, checkerB);
        _lastRenderMicros = (MonoTime.currTime - start).total!"usecs";
        canvas.drawRgbImage(Rect(0, 0, width, height), width, height, _rgb, true);
    }

    protected override void onFocusChanged(bool focused)
    {
        super.onFocusChanged(focused);
        if (!focused && _panning)
        {
            _panning = false;
            releaseMouse();
            setCursor(CursorKind.arrow);
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.left)
        {
            requestFocus();
            if (_image !is null)
            {
                if (event.clickCount >= 2)
                {
                    toggleFitOrActual();
                    return true;
                }
                _panning = true;
                _lastPointer = event.position;
                captureMouse();
                setCursor(CursorKind.move);
                return true;
            }
            return false;
        }
        if (event.button == MouseButton.right)
        {
            requestFocus();
            showViewContextMenu(event.position);
            return true;
        }
        return false;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_panning) return false;
        const dx = cast(double) (event.position.x - _lastPointer.x);
        const dy = cast(double) (event.position.y - _lastPointer.y);
        _lastPointer = event.position;
        _offsetX -= dx / _zoom;
        _offsetY -= dy / _zoom;
        clampOffsets();
        invalidate();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_panning) return false;
        _panning = false;
        releaseMouse();
        setCursor(CursorKind.arrow);
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (_image is null) return false;
        const steps = clampDouble(cast(double) event.wheelY, -20.0, 20.0);
        if (steps == 0.0) return false;
        const factor = pow(1.15, steps);
        zoomAt(_zoom * factor, cast(double) event.position.x,
            cast(double) event.position.y);
        return true;
    }

    override bool onFilesDropped(ref Event event)
    {
        foreach (path; event.paths)
        {
            if (path.length == 0) continue;
            if (onFileDropped !is null) onFileDropped(path);
            return true;
        }
        return false;
    }

    override bool onKeyDown(ref Event event)
    {
        if (_image is null && !(event.control() && event.key == Key.o))
            return false;
        if (event.control() && event.key == Key.o)
        {
            if (onOpenRequested !is null) onOpenRequested();
            return true;
        }
        if (event.control() && event.key == Key.digit0)
        {
            fitToWindow();
            return true;
        }
        if (event.key == Key.f)
        {
            fitToWindow();
            return true;
        }
        if (event.key == Key.digit0 || event.key == Key.digit1)
        {
            actualSize();
            return true;
        }
        if (event.key == Key.equal)
        {
            zoomIn();
            return true;
        }
        if (event.key == Key.minus)
        {
            zoomOut();
            return true;
        }
        const pan = 96.0 / _zoom;
        if (event.key == Key.left) { panBy(-pan, 0.0); return true; }
        if (event.key == Key.right) { panBy(pan, 0.0); return true; }
        if (event.key == Key.up) { panBy(0.0, -pan); return true; }
        if (event.key == Key.down) { panBy(0.0, pan); return true; }
        return false;
    }

    private void toggleFitOrActual()
    {
        if (_image is null) return;
        const viewWidth = maxInt(1, bounds().width);
        const viewHeight = maxInt(1, bounds().height);
        const fitZoom = min(cast(double) viewWidth / cast(double) _image.width(),
            cast(double) viewHeight / cast(double) _image.height());
        if ((_zoom - fitZoom).abs < 0.001 && _zoom > minimumZoom + 0.001)
            actualSize();
        else
            fitToWindow();
    }

    private void showViewContextMenu(Point position)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Open…", IconKind.open,
            delegate() {
                if (onOpenRequested !is null) onOpenRequested();
            }, "Ctrl+O");
        items ~= ContextMenuItem.command("Reload", IconKind.refresh,
            delegate() {
                if (onReloadRequested !is null) onReloadRequested();
            });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Fit to window", IconKind.image,
            delegate() { fitToWindow(); }, "F");
        items ~= ContextMenuItem.command("Actual size", IconKind.image,
            delegate() { actualSize(); }, "1");
        items ~= ContextMenuItem.command("Zoom in", IconKind.search,
            delegate() { zoomIn(); }, "+");
        items ~= ContextMenuItem.command("Zoom out", IconKind.search,
            delegate() { zoomOut(); }, "-");
        showContextMenu(this, localToGlobal(position), items);
    }
}

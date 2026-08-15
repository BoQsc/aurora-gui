module aurora.platform.headless;

import aurora.platform.base : NativeWindow, NativeWindowSink, WindowOptions;
import aurora.types : CursorKind, DisplayScale, Point, PointF, Rect, Size;

final class PlatformWindow : NativeWindow
{
    private Size _size;
    private bool _closed;
    private bool _invalidated = true;
    private bool _fullscreen;
    private bool _pointerVisible = true;
    private PointF _pointerPosition;
    private PointF _screenPointerPosition;
    private bool _screenPointerSet;
    private Rect _workArea;
    private bool _workAreaSet;
    private Rect _lastWindowBounds;
    private bool _boundsSet;

    this(WindowOptions options, NativeWindowSink sink)
    {
        super(options, sink);
        _size = Size(options.width, options.height);
        _fullscreen = options.startFullscreen;
        // Model a real window's outer bounds so tests that read windowBounds
        // (restore-on-drag, maximize bookkeeping) behave like the live platform.
        _lastWindowBounds = Rect(0, 0, options.width, options.height);
        _boundsSet = true;
    }

    /** Inject a screen-space pointer sample for `queryPointerScreenPosition`. */
    void setTestScreenPointerPosition(PointF value)
    {
        _screenPointerPosition = value;
        _screenPointerSet = true;
    }

    /** Inject a work area returned by `queryWorkArea`. */
    void setTestWorkArea(Rect value)
    {
        _workArea = value;
        _workAreaSet = true;
    }

    /** The most recent bounds passed to `setWindowBounds`, if any. */
    bool lastWindowBounds(out Rect bounds)
    {
        bounds = _lastWindowBounds;
        return _boundsSet;
    }

    override void show()
    {
        import aurora.event : Event, EventType;
        Event event;
        event.type = EventType.resized;
        event.size = _size;
        event.framebufferSize = _size;
        event.displayScale = DisplayScale.init;
        sink.onNativeEvent(event);
    }

    override int run()
    {
        if (!_closed && _invalidated)
        {
            _invalidated = !sink.onNativePaint();
        }
        sink.onNativeShutdown();
        return 0;
    }

    override void invalidate()
    {
        _invalidated = true;
    }

    override void present(const(uint)[] pixels, int width, int height)
    {
        _size = Size(width, height);
    }

    override void setTitle(string title) {}
    override void setCursor(CursorKind cursor) {}

    override bool setPointerVisible(bool visible)
    {
        _pointerVisible = visible;
        return true;
    }

    override bool queryPointerPosition(out PointF position)
    {
        position = _pointerPosition;
        return true;
    }

    override bool queryPointerScreenPosition(out PointF position)
    {
        position = _screenPointerPosition;
        return _screenPointerSet;
    }

    override bool setWindowBounds(Rect logicalBounds)
    {
        _lastWindowBounds = logicalBounds;
        _boundsSet = true;
        return true;
    }

    override bool windowBounds(out Rect bounds)
    {
        bounds = _lastWindowBounds;
        return _boundsSet;
    }

    override bool queryWorkArea(Point screenPoint, out Rect workArea)
    {
        workArea = _workAreaSet ? _workArea : Rect.init;
        return _workAreaSet;
    }

    void setTestPointerPosition(PointF value)
    {
        _pointerPosition = value;
    }

    bool pointerVisible() const @safe pure nothrow @nogc
    {
        return _pointerVisible;
    }

    override void setFullscreen(bool value)
    {
        if (_fullscreen == value) return;
        _fullscreen = value;
        options.startFullscreen = value;
        _invalidated = true;
    }

    override bool fullscreen() const
    {
        return _fullscreen;
    }

    override void close()
    {
        _closed = true;
    }

    override Size clientSize() const
    {
        return _size;
    }
}

module aurora.platform.headless;

import aurora.platform.base : NativeWindow, NativeWindowSink, WindowOptions;
import aurora.types : CursorKind, DisplayScale, PointF, Size;

final class PlatformWindow : NativeWindow
{
    private Size _size;
    private bool _closed;
    private bool _invalidated = true;
    private bool _fullscreen;
    private bool _pointerVisible = true;
    private PointF _pointerPosition;

    this(WindowOptions options, NativeWindowSink sink)
    {
        super(options, sink);
        _size = Size(options.width, options.height);
        _fullscreen = options.startFullscreen;
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

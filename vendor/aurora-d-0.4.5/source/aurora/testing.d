module aurora.testing;

import aurora.dragdrop : DragAction, DragActions, DragPayload,
    preferredDragAction;
import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
import aurora.types : DisplayScale, Point, PointF, Size, maxInt;
import aurora.window : GuiWindow;

/**
 * Deterministic input driver for headless and CI tests.
 *
 * Events travel through GuiWindow's real dispatch path: popup pre-dispatch,
 * hit testing, focus, capture, bubbling, and click counting are all exercised.
 * Tests should prefer this over calling individual widget handlers directly.
 */
final class UiTestDriver
{
    private GuiWindow _window;
    private Point _pointer;
    private long _timestampMs = 1_000;

    this(GuiWindow window)
    {
        assert(window !is null);
        _window = window;
    }

    GuiWindow window() @safe pure nothrow @nogc { return _window; }
    Point pointerPosition() const @safe pure nothrow @nogc { return _pointer; }

    void resize(Size logicalSize, DisplayScale scale = DisplayScale.init)
    {
        Event event;
        event.type = EventType.resized;
        event.size = logicalSize;
        event.displayScale = scale;
        event.framebufferSize = scale.logicalToPhysical(logicalSize);
        event.timestampMs = nextTimestamp();
        _window.onNativeEvent(event);
    }

    void moveTo(Point position)
    {
        _pointer = position;
        auto event = pointerEvent(EventType.mouseMove, MouseButton.none);
        _window.onNativeEvent(event);
    }

    void mouseDown(MouseButton button = MouseButton.left)
    {
        auto event = pointerEvent(EventType.mouseDown, button);
        _window.onNativeEvent(event);
    }

    void mouseUp(MouseButton button = MouseButton.left)
    {
        auto event = pointerEvent(EventType.mouseUp, button);
        _window.onNativeEvent(event);
    }

    void click(Point position, MouseButton button = MouseButton.left)
    {
        moveTo(position);
        mouseDown(button);
        mouseUp(button);
    }

    void rightClick(Point position)
    {
        click(position, MouseButton.right);
    }

    void doubleClick(Point position, MouseButton button = MouseButton.left)
    {
        click(position, button);
        // Keep the second press inside the host's 500 ms double-click window.
        click(position, button);
    }

    void drag(Point from, Point to, int steps = 8,
        MouseButton button = MouseButton.left)
    {
        steps = maxInt(1, steps);
        moveTo(from);
        mouseDown(button);
        foreach (step; 1 .. steps + 1)
        {
            const x = from.x + (to.x - from.x) * step / steps;
            const y = from.y + (to.y - from.y) * step / steps;
            moveTo(Point(x, y));
        }
        mouseUp(button);
    }

    void wheel(Point position, int vertical, int horizontal = 0)
    {
        _pointer = position;
        auto event = pointerEvent(EventType.mouseWheel, MouseButton.none);
        event.wheelY = vertical;
        event.wheelX = horizontal;
        _window.onNativeEvent(event);
    }

    /** Route a file drop through the host hit-test and normal event bubbling path. */
    void dropFiles(Point position, string[] paths)
    {
        _pointer = position;
        auto event = pointerEvent(EventType.filesDropped, MouseButton.none);
        event.paths = paths.dup;
        _window.onNativeEvent(event);
    }

    DragAction dragEnter(Point position, DragPayload payload,
        DragActions allowedActions)
    {
        return dragEvent(EventType.dragEntered, position, payload,
            allowedActions);
    }

    DragAction dragMove(Point position, DragPayload payload,
        DragActions allowedActions)
    {
        return dragEvent(EventType.dragMoved, position, payload,
            allowedActions);
    }

    DragAction drop(Point position, DragPayload payload,
        DragActions allowedActions)
    {
        return dragEvent(EventType.dropped, position, payload, allowedActions);
    }

    void dragLeave(Point position, DragPayload payload = DragPayload.init)
    {
        dragEvent(EventType.dragLeft, position, payload, 0);
    }

    void keyDown(Key key, uint modifiers = cast(uint) KeyModifier.none,
        bool repeat = false)
    {
        Event event;
        event.type = EventType.keyDown;
        event.key = key;
        event.modifiers = modifiers;
        event.repeat = repeat;
        event.globalPosition = _pointer;
        event.preciseGlobalPosition = PointF(_pointer);
        event.hasPrecisePosition = true;
        event.timestampMs = nextTimestamp();
        _window.onNativeEvent(event);
    }

    void keyUp(Key key, uint modifiers = cast(uint) KeyModifier.none)
    {
        Event event;
        event.type = EventType.keyUp;
        event.key = key;
        event.modifiers = modifiers;
        event.globalPosition = _pointer;
        event.preciseGlobalPosition = PointF(_pointer);
        event.hasPrecisePosition = true;
        event.timestampMs = nextTimestamp();
        _window.onNativeEvent(event);
    }

    void pressKey(Key key, uint modifiers = cast(uint) KeyModifier.none)
    {
        keyDown(key, modifiers);
        keyUp(key, modifiers);
    }

    void text(const(dchar)[] value)
    {
        Event event;
        event.type = EventType.textInput;
        event.text = value.dup;
        event.globalPosition = _pointer;
        event.preciseGlobalPosition = PointF(_pointer);
        event.hasPrecisePosition = true;
        event.timestampMs = nextTimestamp();
        _window.onNativeEvent(event);
    }

    void setHostFocus(bool focused)
    {
        Event event;
        event.type = focused ? EventType.focusGained : EventType.focusLost;
        event.globalPosition = _pointer;
        event.timestampMs = nextTimestamp();
        _window.onNativeEvent(event);
    }

    bool paint()
    {
        return _window.onNativePaint();
    }

    version (AuroraHeadless)
    {
        import aurora.platform.select : PlatformWindow;
        import aurora.types : Rect;

        private PlatformWindow nativePlatformWindow()
        {
            return cast(PlatformWindow) _window.nativeWindow();
        }

        /** Inject a monitor work area for the headless platform window. */
        void setTestWorkArea(Rect value)
        {
            auto native = nativePlatformWindow();
            if (native !is null) native.setTestWorkArea(value);
        }

        /** Inject the screen-space pointer sample used by drag-snap detection. */
        void setTestScreenPointerPosition(PointF value)
        {
            auto native = nativePlatformWindow();
            if (native !is null) native.setTestScreenPointerPosition(value);
        }

        /** The most recent bounds the window was asked to snap to, if any. */
        bool lastWindowBounds(out Rect bounds)
        {
            auto native = nativePlatformWindow();
            return native !is null && native.lastWindowBounds(bounds);
        }
    }

    private Event pointerEvent(EventType type, MouseButton button)
    {
        Event event;
        event.type = type;
        event.position = _pointer;
        event.globalPosition = _pointer;
        event.precisePosition = PointF(_pointer);
        event.preciseGlobalPosition = PointF(_pointer);
        event.hasPrecisePosition = true;
        event.button = button;
        event.timestampMs = nextTimestamp();
        return event;
    }

    private DragAction dragEvent(EventType type, Point position,
        DragPayload payload, DragActions allowedActions)
    {
        _pointer = position;
        auto event = pointerEvent(type, MouseButton.none);
        event.dragPayload = payload.duplicate();
        event.paths = event.dragPayload.paths;
        event.allowedDragActions = allowedActions;
        event.suggestedDragAction = preferredDragAction(allowedActions,
            DragAction.copy);
        _window.onNativeEvent(event);
        return event.dragAction;
    }

    private long nextTimestamp() @safe nothrow @nogc
    {
        _timestampMs += 16;
        return _timestampMs;
    }
}

unittest
{
    import aurora.platform.base : RendererPreference, WindowOptions;
    import aurora.widget : Widget;
    import aurora.types : Rect;

    version (AuroraHeadless)
    {
        final class TestRoot : Widget {}
        WindowOptions options;
        options.width = 320;
        options.height = 200;
        options.renderer = RendererPreference.software;
        auto window = new GuiWindow(options);
        auto root = new TestRoot();
        window.setRoot(root);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(320, 200));
        assert(root.bounds() == Rect(0, 0, 320, 200));
    }
}

module tests.latency;

import aurora;
import aurora.platform.headless : PlatformWindow;
import std.stdio : writeln;

private final class LatencyRoot : Widget
{
    DesktopSurface desktop;
    FloatingWindow floating;

    this()
    {
        desktop = add(new DesktopSurface());
        auto content = new VBox(4, Insets(8));
        content.add(new Label("Late-latched window"));
        floating = desktop.addWindow(new FloatingWindow("Latency",
            IconKind.computer, content));
        floating.setBounds(Rect(40, 45, 260, 170));
    }

    protected override void onLayout()
    {
        desktop.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

private Event pointerEvent(EventType type, PointF position,
    MouseButton button = MouseButton.none)
{
    Event event;
    event.type = type;
    event.button = button;
    event.precisePosition = position;
    event.preciseGlobalPosition = position;
    event.position = position.rounded();
    event.globalPosition = event.position;
    event.hasPrecisePosition = true;
    event.timestampMs = 1;
    return event;
}

int main()
{
    WindowOptions options;
    options.width = 640;
    options.height = 420;
    options.renderer = RendererPreference.software;
    options.lowLatency = true;
    options.synchronizedDragPointer = true;

    auto window = new GuiWindow(options, Theme.dark());
    auto native = cast(PlatformWindow) window.nativeWindow();
    assert(native !is null);
    auto root = new LatencyRoot();
    window.setRoot(root);
    assert(window.onNativePaint());

    const downPosition = PointF(60.25, 55.5);
    native.setTestPointerPosition(downPosition);
    auto down = pointerEvent(EventType.mouseDown, downPosition, MouseButton.left);
    window.onNativeEvent(down);
    assert(!native.pointerVisible());

    // Warm the persistent cursor layer. A continuous drag intentionally leaves
    // another render opportunity pending, hence onNativePaint returns false.
    assert(!window.onNativePaint());
    window.resetCompositorStats();
    window.resetRendererStats();

    // No WM_MOUSEMOVE is delivered here. The renderer must query and latch the
    // newest pointer after it has a presentation slot, update the floating
    // layer at subpixel precision, and draw the synchronized cursor in the same
    // frame without rebuilding content.
    const newest = PointF(60.75, 56.0);
    native.setTestPointerPosition(newest);
    assert(!window.onNativePaint());
    assert(root.floating.precisePosition() == PointF(40.5, 45.5));

    const compositor = window.compositorStats();
    const renderer = window.rendererStats();
    assert(compositor.lateLatchSamples == 1);
    assert(compositor.lateLatchUpdates == 1);
    assert(compositor.baseBuilds == 0);
    assert(compositor.layerBuilds == 0);
    assert(compositor.layerOrderBuilds == 0);
    assert(renderer.cachedSurfaceBuilds == 0);
    assert(renderer.layerDraws == 2); // floating window + synchronized pointer

    auto up = pointerEvent(EventType.mouseUp, newest, MouseButton.left);
    window.onNativeEvent(up);
    assert(native.pointerVisible());
    assert(window.onNativePaint());

    writeln("Aurora latency regression: precise late latch, continuous frames, "
        ~ "and frame-synchronized drag pointer passed.");
    return 0;
}

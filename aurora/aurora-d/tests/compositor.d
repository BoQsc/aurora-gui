module tests.compositor;

import aurora;
import std.stdio : writeln;

private final class CountingContent : Widget
{
    ulong layoutCalls;
    ulong paintCalls;

    protected override void onLayout()
    {
        ++layoutCalls;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        ++paintCalls;
        canvas.fillVerticalGradient(Rect(0, 0, bounds().width, bounds().height),
            Color.fromHex(0xf5f7fa), Color.fromHex(0xdfe7ef));
        canvas.fillRoundedRect(Rect(18, 18, 150, 44), 7,
            Color.fromHex(0x2e6ea6));
        canvas.drawText(Point(30, 30), "Retained content"d,
            Color.rgb(255, 255, 255), 2);
    }
}

private final class CompositorRoot : Widget
{
    DesktopSurface desktop;
    FloatingWindow floating;
    CountingContent content;

    this()
    {
        desktop = add(new DesktopSurface());
        content = new CountingContent();
        floating = desktop.addWindow(new FloatingWindow("Compositor",
            IconKind.computer, content));
        floating.setBounds(Rect(40, 45, 260, 170));
    }

    protected override void onLayout()
    {
        desktop.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

int main()
{
    WindowOptions options;
    options.width = 640;
    options.height = 420;
    options.renderer = RendererPreference.software;
    options.lowLatency = true;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new CompositorRoot();
    window.setRoot(root);

    assert(window.onNativePaint());
    auto initial = window.surface().pixels().dup;
    auto firstStats = window.compositorStats();
    assert(firstStats.baseBuilds == 1);
    assert(firstStats.layerBuilds == 1);

    const layoutsBeforeDrag = root.content.layoutCalls;
    const paintsBeforeDrag = root.content.paintCalls;
    window.resetCompositorStats();
    window.resetRendererStats();

    // Exercise a sustained drag-sized stream, including partially off-screen
    // positions. Each frame must reuse the same base and layer content.
    enum moveCount = 96;
    bool exercisedOffscreen;
    foreach (index; 0 .. moveCount)
    {
        int x;
        int y;
        if (index + 1 == moveCount)
        {
            x = 220;
            y = 135;
        }
        else
        {
            x = -110 + cast(int) ((index * 17) % 520);
            y = 24 + cast(int) ((index * 11) % 210);
        }
        if (x < 0) exercisedOffscreen = true;
        root.floating.setPosition(Point(x, y));
        assert(window.onNativePaint());
    }

    auto moved = window.surface().pixels().dup;
    auto dragStats = window.compositorStats();
    auto rendererDragStats = window.rendererStats();
    assert(exercisedOffscreen);
    assert(dragStats.frames == moveCount);
    assert(dragStats.baseBuilds == 0);
    assert(dragStats.layerBuilds == 0);
    assert(dragStats.layerOrderBuilds == 0);
    assert(dragStats.transformOnlyFrames == moveCount);
    assert(root.content.layoutCalls == layoutsBeforeDrag);
    assert(root.content.paintCalls == paintsBeforeDrag);
    assert(rendererDragStats.frames == moveCount);
    assert(rendererDragStats.cachedSurfaceBuilds == 0);
    assert(rendererDragStats.layerDraws == moveCount);
    assert(initial != moved);

    // The old title-bar location should expose wallpaper; the new location
    // should contain the cached floating-window surface.
    const oldPixel = initial[cast(size_t) 60 * 640 + 55];
    const oldAfterMove = moved[cast(size_t) 60 * 640 + 55];
    const newBeforeMove = initial[cast(size_t) 150 * 640 + 235];
    const newPixel = moved[cast(size_t) 150 * 640 + 235];
    assert(oldPixel != oldAfterMove);
    assert(newBeforeMove != newPixel);

    // A content change rebuilds only the affected Aurora layer.
    window.resetCompositorStats();
    window.resetRendererStats();
    root.content.invalidate();
    assert(window.onNativePaint());
    auto contentStats = window.compositorStats();
    auto contentRendererStats = window.rendererStats();
    assert(contentStats.baseBuilds == 0);
    assert(contentStats.layerBuilds == 1);
    assert(contentStats.transformOnlyFrames == 0);
    assert(root.content.layoutCalls == layoutsBeforeDrag + 1);
    assert(root.content.paintCalls == paintsBeforeDrag + 1);
    assert(contentRendererStats.cachedSurfaceBuilds == 1);

    // Minimize/restore changes only composition order/visibility. Retained
    // window content stays valid and requires no repaint on restore.
    window.resetCompositorStats();
    window.resetRendererStats();
    root.floating.setVisible(false);
    assert(window.onNativePaint());
    auto hiddenStats = window.compositorStats();
    assert(hiddenStats.baseBuilds == 0);
    assert(hiddenStats.layerBuilds == 0);
    assert(hiddenStats.layerOrderBuilds == 1);
    assert(window.rendererStats().cachedSurfaceBuilds == 0);

    window.resetCompositorStats();
    window.resetRendererStats();
    root.floating.setVisible(true);
    assert(window.onNativePaint());
    auto restoredStats = window.compositorStats();
    assert(restoredStats.baseBuilds == 0);
    assert(restoredStats.layerBuilds == 0);
    assert(restoredStats.layerOrderBuilds == 1);
    assert(window.rendererStats().cachedSurfaceBuilds == 0);

    writeln("Aurora retained compositor: ", moveCount,
        " presented moves; 0 layouts; 0 paints; 0 content rebuilds during drag.");
    return 0;
}

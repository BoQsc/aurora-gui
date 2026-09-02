module tests.renderer_smoke;

import aurora.color : Color;
import aurora.render.drawlist : DrawList;
import aurora.render.scene : RenderLayer, RenderScene;
import aurora.render.software : SoftwareRenderer;
import aurora.surface : Surface;
import aurora.types : Rect, Size;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio : writeln;

private ubyte red(uint argb) { return cast(ubyte) ((argb >> 16) & 0xff); }
private ubyte green(uint argb) { return cast(ubyte) ((argb >> 8) & 0xff); }
private ubyte blue(uint argb) { return cast(ubyte) (argb & 0xff); }

int main()
{
    // Exact-size RGB24 conversion.
    ubyte[] source = [
        255, 0, 0,      0, 255, 0,
        0, 0, 255,      255, 255, 255
    ];
    auto exactList = new DrawList();
    exactList.reset(Size(2, 2), Color.rgb(0, 0, 0));
    exactList.addRgbImage(Rect(0, 0, 2, 2), 2, 2, source,
        Rect(0, 0, 2, 2), true);
    auto exact = new Surface(2, 2);
    SoftwareRenderer.renderInto(exactList, exact);
    assert(exact.pixel(0, 0) == 0xffff0000);
    assert(exact.pixel(1, 0) == 0xff00ff00);
    assert(exact.pixel(0, 1) == 0xff0000ff);
    assert(exact.pixel(1, 1) == 0xffffffff);

    // Fixed-point bilinear scaling and ordered vector batches.
    auto scaledList = new DrawList();
    scaledList.reset(Size(6, 6), Color.rgb(0, 0, 0));
    scaledList.addRgbImage(Rect(0, 0, 6, 6), 2, 2, source,
        Rect(0, 0, 6, 6), true);
    scaledList.addSolidRect(Rect(0, 0, 1, 1), Color.rgb(9, 18, 27),
        Rect(0, 0, 6, 6));
    auto scaled = new Surface(6, 6);
    SoftwareRenderer.renderInto(scaledList, scaled);
    assert(scaled.pixel(0, 0) == Color.rgb(9, 18, 27).argb(),
        "Vector commands were not composited after the retained RGB image");
    const center = scaled.pixel(3, 3);
    assert(red(center) > 80 && green(center) > 80 && blue(center) > 80,
        "Bilinear RGB scaling did not blend all four source colors");

    // Exercise the exact-size 1080p playback path and report its local cost.
    enum width = 1920;
    enum height = 1080;
    auto frame = new ubyte[cast(size_t) width * height * 3];
    foreach (offset; 0 .. frame.length / 3)
    {
        frame[offset * 3] = cast(ubyte) (offset & 0xff);
        frame[offset * 3 + 1] = cast(ubyte) ((offset >> 3) & 0xff);
        frame[offset * 3 + 2] = cast(ubyte) ((offset >> 7) & 0xff);
    }
    auto fullHdList = new DrawList();
    fullHdList.reset(Size(width, height), Color.rgb(0, 0, 0));
    fullHdList.addRgbImage(Rect(0, 0, width, height), width, height, frame,
        Rect(0, 0, width, height), true);
    auto fullHd = new Surface(width, height);
    auto watch = StopWatch(AutoStart.yes);
    SoftwareRenderer.renderInto(fullHdList, fullHd);
    watch.stop();
    assert(fullHd.pixel(0, 0) == 0xff000000);
    const lastOffset = cast(size_t) width * height - 1;
    const expectedLast = 0xff000000u |
        (cast(uint) frame[lastOffset * 3] << 16) |
        (cast(uint) frame[lastOffset * 3 + 1] << 8) |
        cast(uint) frame[lastOffset * 3 + 2];
    assert(fullHd.pixel(width - 1, height - 1) == expectedLast);

    // Transform-only retained-layer movement must update only the old/new
    // rectangles. This is the path used by the sequence playhead and is the
    // central guard against full-window redraws while scrubbing.
    auto base = new DrawList();
    base.reset(Size(100, 100), Color.rgb(0, 0, 180));

    auto redLayerList = new DrawList();
    redLayerList.reset(Size(10, 10), Color.rgba(0, 0, 0, 0));
    redLayerList.addSolidRect(Rect(0, 0, 10, 10), Color.rgb(220, 0, 0),
        Rect(0, 0, 10, 10));

    auto greenLayerList = new DrawList();
    greenLayerList.reset(Size(10, 10), Color.rgba(0, 0, 0, 0));
    greenLayerList.addSolidRect(Rect(0, 0, 10, 10), Color.rgba(0, 220, 0, 128),
        Rect(0, 0, 10, 10));

    auto scene = new RenderScene();
    scene.reset(base, 1, Size(100, 100));
    RenderLayer moving;
    moving.id = 10;
    moving.revision = 1;
    moving.drawList = redLayerList;
    moving.deviceBounds = Rect(10, 10, 10, 10);
    moving.visible = true;
    moving.opaque = true;
    scene.addLayer(moving);
    RenderLayer overlay;
    overlay.id = 11;
    overlay.revision = 1;
    overlay.drawList = greenLayerList;
    overlay.deviceBounds = Rect(22, 22, 10, 10);
    overlay.visible = true;
    scene.addLayer(overlay);

    auto retained = new SoftwareRenderer(Size(100, 100));
    assert(retained.renderScene(scene));
    assert(red(retained.softwareSurface().pixel(11, 11)) > 200);

    retained.resetStats();
    scene.reset(base, 1, Size(100, 100));
    moving.deviceBounds = Rect(20, 20, 10, 10);
    scene.addLayer(moving);
    scene.addLayer(overlay);
    assert(retained.renderScene(scene));
    const movedStats = retained.stats();
    assert(movedStats.fullSceneRedraws == 0 &&
        movedStats.partialSceneRedraws == 1,
        "Moving a retained layer forced a full-window redraw");
    assert(movedStats.cachedSurfaceBuilds == 0,
        "Moving a retained layer rebuilt its unchanged pixels");
    assert(movedStats.dirtyPixels < 1_000,
        "Playhead-sized movement dirtied an implausibly large region");
    assert(blue(retained.softwareSurface().pixel(11, 11)) > 150,
        "The old transformed-layer rectangle was not restored from the base");
    assert(red(retained.softwareSurface().pixel(20, 20)) > 200,
        "The retained layer was not drawn at its new transform");
    const overlap = retained.softwareSurface().pixel(23, 23);
    assert(red(overlap) > 70 && green(overlap) > 70 && blue(overlap) < 30,
        "Unchanged overlapping layers were not replayed over a dirty region");

    writeln("Aurora retained RGB renderer smoke test passed (1080p blit: ",
        watch.peek.total!"msecs", " ms; moved-layer dirty pixels: ",
        movedStats.dirtyPixels, ").");
    return 0;
}

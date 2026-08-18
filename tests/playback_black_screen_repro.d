module tests.playback_black_screen_repro;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.preview : PreviewWidget;
import auroracut.recentprojects : clearRecentProjects,
    setRecentProjectsFilePathForTesting;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, remove, tempDir, write;
import std.math : fabs;
import std.path : baseName, buildPath;
import std.stdio : writeln;
import std.string : toLower;

private Widget findById(Widget root, string requestedId)
{
    if (root is null) return null;
    if (root.id() == requestedId) return root;
    foreach (child; root.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing widget for id: " ~ requestedId);
    return widget;
}

private void writeBmp(string path, const Surface surface)
{
    const w = surface.width();
    const h = surface.height();
    const pixels = surface.pixels();
    ubyte[] data;
    data.reserve(w * h * 3 + 54);
    // 24-bit BMP header, bottom-up rows.
    const fileSize = 54 + w * h * 3;
    data ~= "BM";
    data ~= [cast(ubyte) (fileSize & 0xff), cast(ubyte) ((fileSize >> 8) & 0xff),
        cast(ubyte) ((fileSize >> 16) & 0xff), cast(ubyte) ((fileSize >> 24) & 0xff)];
    data ~= [0, 0, 0, 0];
    data ~= [54, 0, 0, 0];
    data ~= [40, 0, 0, 0];
    data ~= [cast(ubyte) (w & 0xff), cast(ubyte) ((w >> 8) & 0xff),
        cast(ubyte) ((w >> 16) & 0xff), cast(ubyte) ((w >> 24) & 0xff)];
    data ~= [cast(ubyte) (h & 0xff), cast(ubyte) ((h >> 8) & 0xff),
        cast(ubyte) ((h >> 16) & 0xff), cast(ubyte) ((h >> 24) & 0xff)];
    data ~= [1, 0];
    data ~= [24, 0];
    data ~= [0, 0, 0, 0];
    data ~= [0, 0, 0, 0];
    data ~= [0, 0, 0, 0];
    data ~= [0, 0, 0, 0];
    data ~= [0, 0, 0, 0];
    data ~= [0, 0, 0, 0];
    foreach (int y; 0 .. h)
    {
        const row = h - 1 - y;
        foreach (int x; 0 .. w)
        {
            const argb = pixels[cast(size_t) row * cast(size_t) w + cast(size_t) x];
            const r = (argb >> 16) & 0xff;
            const g = (argb >> 8) & 0xff;
            const b = argb & 0xff;
            data ~= [cast(ubyte) b, cast(ubyte) g, cast(ubyte) r];
        }
    }
    write(path, data);
    writeln("[repro] saved ", path);
}

/// Average + dark fraction over the region of the window surface that the
/// Preview widget occupies (scaled to physical pixels).
private void sampleWindowRegion(GuiWindow window, Widget preview, string label)
{
    auto snapshot = window.surface();
    const scale = window.displayScale();
    const origin = preview.localToGlobal(Point(0, 0));
    const topLeft = scale.logicalToPhysical(Point(origin.x + 10, origin.y + 10));
    const bottomRight = scale.logicalToPhysical(Point(
        origin.x + preview.bounds().width - 10,
        origin.y + preview.bounds().height - 10));
    const pitch = snapshot.width();
    const w = snapshot.width();
    const h = snapshot.height();
    const pixels = snapshot.pixels();
    double totalR = 0.0;
    double totalG = 0.0;
    double totalB = 0.0;
    long samples;
    long nearBlack; // all channels < 16
    long nearGray;  // all channels in 35..70 and channels close together
    for (int y = topLeft.y; y < bottomRight.y; y += 4)
    {
        for (int x = topLeft.x; x < bottomRight.x; x += 4)
        {
            if (y < 0 || y >= h || x < 0 || x >= w) continue;
            const argb = pixels[cast(size_t) y * pitch + cast(size_t) x];
            const r = (argb >> 16) & 0xff;
            const g = (argb >> 8) & 0xff;
            const b = argb & 0xff;
            totalR += r;
            totalG += g;
            totalB += b;
            ++samples;
            if (r < 16 && g < 16 && b < 16) ++nearBlack;
            else if (r >= 35 && r <= 70 && g >= 35 && g <= 70 && b >= 35 && b <= 70)
                ++nearGray;
        }
    }
    if (samples == 0)
    {
        writeln("[repro] ", label, ": window region EMPTY");
        return;
    }
    const avgR = totalR / samples;
    const avgG = totalG / samples;
    const avgB = totalB / samples;
    writeln("[repro] ", label, ": window avgRGB=(", cast(int) avgR, ",",
        cast(int) avgG, ",", cast(int) avgB, ") brightness=",
        cast(int) ((avgR + avgG + avgB) / 3.0),
        " nearBlack=", nearBlack * 100 / samples, "%",
        " nearGray=", nearGray * 100 / samples, "%");
}

private void sampleRawPreview(PreviewWidget preview, string label)
{
    if (!preview.hasFrame())
    {
        writeln("[repro] ", label, ": RAW NO FRAME");
        return;
    }
    const w = preview.frameWidth();
    const h = preview.frameHeight();
    double totalR = 0.0;
    double totalG = 0.0;
    double totalB = 0.0;
    long samples;
    foreach (y; 0 .. 8)
    {
        const py = cast(int) (cast(double) y * cast(double) h / 8.0 + 0.5);
        foreach (x; 0 .. 8)
        {
            const px = cast(int) (cast(double) x * cast(double) w / 8.0 + 0.5);
            const pixel = preview.pixelForTesting(px, py);
            totalR += pixel[0];
            totalG += pixel[1];
            totalB += pixel[2];
            ++samples;
        }
    }
    const avgR = totalR / samples;
    const avgG = totalG / samples;
    const avgB = totalB / samples;
    writeln("[repro] ", label, ": RAW size=", w, "x", h, " avgRGB=(",
        cast(int) avgR, ",", cast(int) avgG, ",", cast(int) avgB,
        ") brightness=", cast(int) ((avgR + avgG + avgB) / 3.0));
}

private bool waitForPlaybackReady(EditorRoot editor, PreviewWidget preview)
{
    foreach (_; 0 .. 900)
    {
        editor.tickTree(0.02);
        if (!editor.playbackAwaitingFirstFrameForTesting() &&
            preview.playing() && preview.hasFrame())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    if (arguments.length < 3)
    {
        writeln("Usage: playback-black-screen-repro <project.auroracut> <software|vulkan>");
        return 1;
    }
    const projectPath = arguments[1];
    if (!exists(projectPath))
    {
        writeln("Project does not exist: ", projectPath);
        return 1;
    }
    const rendererName = arguments[2].toLower();

    WindowOptions options;
    options.title = "Aurora Cut black-screen repro (" ~ rendererName ~ ")";
    options.width = 1440;
    options.height = 960;
    if (rendererName == "vulkan")
        options.renderer = RendererPreference.vulkan;
    else
        options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    const recentPath = buildPath(tempDir(),
        "aurora-cut-black-screen-repro-recent.json");
    if (exists(recentPath)) remove(recentPath);
    setRecentProjectsFilePathForTesting(recentPath);
    clearRecentProjects();
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial editor paint failed");

    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto playSource = requireWidget!Button(editor, "play-preview");

    writeln("[repro] opening project: ", projectPath);
    editor.openProjectForTesting(projectPath);
    foreach (_; 0 .. 60) editor.tickTree(0.02);
    assert(driver.paint());
    const playhead = timeline.playhead();
    writeln("[repro] project loaded; playhead=", playhead, " comp=",
        editor.compositionWidthForTesting(), "x",
        editor.compositionHeightForTesting(), " quality=",
        editor.previewQualityHeightForTesting());

    // Scrub a few frames so a still is displayed first (like a real user).
    foreach (pos; [playhead - 1.0, playhead - 0.5, playhead])
    {
        if (pos < 0.0) continue;
        timeline.setPlayhead(pos, true);
        editor.tickTree(0.02);
        Thread.sleep(150.msecs);
        editor.tickTree(0.05);
    }
    assert(driver.paint());
    sampleRawPreview(preview, "pre-play raw");
    sampleWindowRegion(window, preview, "pre-play window");
    writeBmp(buildPath(tempDir(), "black-screen-pre-play-" ~ rendererName ~ ".bmp"),
        window.surface());

    // Now press Play from the playhead.
    driver.click(globalCenter2(playSource));
    writeln("[repro] play pressed; awaitingFirstFrame=",
        editor.playbackAwaitingFirstFrameForTesting());
    const ready = waitForPlaybackReady(editor, preview);
    writeln("[repro] playback ready=", ready, " running=",
        editor.playbackRunningForTesting(), " status=",
        editor.statusTextForTesting(), " playing=", preview.playing());
    assert(driver.paint());
    sampleRawPreview(preview, "t+0 ready raw");
    sampleWindowRegion(window, preview, "t+0 ready window");
    writeBmp(buildPath(tempDir(), "black-screen-play-" ~ rendererName ~ ".bmp"),
        window.surface());

    for (int index; index < 20; ++index)
    {
        Thread.sleep(250.msecs);
        editor.tickTree(0.05);
        assert(driver.paint());
        const label = "t+" ~ to!string((index + 1) * 250) ~ "ms";
        sampleRawPreview(preview, label ~ " raw");
        sampleWindowRegion(window, preview, label ~ " window");
        if (!editor.playbackRunningForTesting())
        {
            writeln("[repro] playback STOPPED pos=",
                editor.playbackPositionForTesting(), " status=",
                editor.statusTextForTesting());
            break;
        }
    }
    writeBmp(buildPath(tempDir(), "black-screen-play-late-" ~ rendererName ~ ".bmp"),
        window.surface());
    writeln("[repro] final pos=", editor.playbackPositionForTesting(),
        " running=", editor.playbackRunningForTesting(),
        " videoRequests=", editor.videoStatsForTesting().requests);
    writeln("[repro] DONE");
    return 0;
}

private Point globalCenter2(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

module tests.live_portrait_playback_repro;

import aurora;
import auroracut.editor : EditorRoot, InspectorValueField;
import auroracut.model : ClipKind, EditorModel, EffectProperty, TimelineClip,
    TextAlignment, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.recentprojects : clearRecentProjects,
    setRecentProjectsFilePathForTesting;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, remove, tempDir;
import std.math : fabs;
import std.path : baseName, buildPath;
import std.stdio : writeln;

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
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

private bool waitForMediaCount(EditorRoot editor, ListView mediaList,
    size_t expected, int iterations = 1_200)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (mediaList.items().length == expected && !editor.importBusyForTesting())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private Point mediaRowPoint(ListView list, int index)
{
    const origin = list.localToGlobal(Point(0, 0));
    return Point(origin.x + 70,
        origin.y + index * list.rowHeight() - list.scrollOffset() + list.rowHeight() / 2);
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
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

private void samplePreview(PreviewWidget preview, string label)
{
    if (!preview.hasFrame())
    {
        writeln("[repro] ", label, ": NO FRAME width=", preview.frameWidth(),
            " height=", preview.frameHeight());
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
    if (samples == 0)
    {
        writeln("[repro] ", label, ": EMPTY FRAME");
        return;
    }
    const avgR = totalR / samples;
    const avgG = totalG / samples;
    const avgB = totalB / samples;
    writeln("[repro] ", label, ": width=", w, " height=", h,
        " avgRGB=(", cast(int) avgR, ",", cast(int) avgG, ",", cast(int) avgB,
        ") brightness=", cast(int) ((avgR + avgG + avgB) / 3.0));
}

int main(string[] arguments)
{
    if (arguments.length < 2)
    {
        writeln("Usage: live-portrait-playback-repro <proxy-or-video.mp4>");
        return 1;
    }
    const mediaPath = arguments[1];
    if (!exists(mediaPath))
    {
        writeln("Media does not exist: ", mediaPath);
        return 1;
    }

    WindowOptions options;
    options.title = "Aurora Cut playback repro";
    options.width = 1280;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    const recentPath = buildPath(tempDir(), "aurora-cut-playback-repro-recent.json");
    if (exists(recentPath)) remove(recentPath);
    setRecentProjectsFilePathForTesting(recentPath);
    clearRecentProjects();
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial editor paint failed");

    auto mediaPanel = requireWidget!Widget(editor, "project-media-panel");
    auto mediaList = requireWidget!ListView(editor, "project-media-list");
    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playSource = requireWidget!Button(editor, "play-preview");

    writeln("[repro] dropping media: ", mediaPath);
    driver.dropFiles(globalCenter(mediaPanel), [mediaPath]);
    assert(waitForMediaCount(editor, mediaList, 1),
        "Media import did not produce an asset");
    writeln("[repro] media imported");

    const v1 = TrackAddress(TrackKind.video, 0);
    editor.modelForTesting().ensureTrack(TrackKind.video, 2);

    driver.drag(mediaRowPoint(mediaList, 0), timeline.pointForTrackTime(v1, 0.05), 16);
    assert(editor.modelForTesting().trackValue(v1).clips.length == 1,
        "Media drag did not create a V1 clip");
    const sourceAsset = editor.modelForTesting().assets[0];
    writeln("[repro] V1 clip added; media size=", sourceAsset.width, "x",
        sourceAsset.height, " duration=", sourceAsset.duration,
        " hasVideo=", sourceAsset.hasVideo);

    // Portrait sequence like the user's shorts project.
    editor.setCompositionResolutionForTesting(720, 960);
    editor.setPreviewQualityForTesting(720);
    timeline.modelChanged();

    // A transform on V1 forces live composition playback (the same overlay
    // graph path the user's shorts project uses for text/crops/effects).
    assert(editor.modelForTesting().setScale(v1, 0, 0.9),
        "Could not set V1 scale for live-composition repro");

    // A text overlay on V2 like the user's shorts overlays.
    const v2 = TrackAddress(TrackKind.video, 1);
    assert(editor.modelForTesting().insertTextClip(v2, 2.0, 6.0,
        "Reading posts") >= 0,
        "Could not insert a text overlay for live-composition repro");
    timeline.modelChanged();

    // Flush so the model revision is picked up.
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    assert(driver.paint());

    writeln("[repro] composition=", editor.compositionWidthForTesting(), "x",
        editor.compositionHeightForTesting());

    timeline.setPlayhead(3.0, true);
    editor.tickTree(0.02);
    driver.click(globalCenter(playSource));
    assert(editor.playbackRunningForTesting() &&
        editor.sequencePlaybackForTesting(),
        "Live sequence playback did not start");
    assert(waitForPlaybackReady(editor, preview),
        "Live playback never left first-frame preroll");
    samplePreview(preview, "t+0 ready");
    writeln("[repro] playing=", preview.playing(), " pos=",
        editor.playbackPositionForTesting(), " status=",
        editor.statusTextForTesting());

    double lastPosition = editor.playbackPositionForTesting();
    for (int index; index < 40; ++index)
    {
        Thread.sleep(250.msecs);
        editor.tickTree(0.05);
        samplePreview(preview, "t+" ~ to!string((index + 1) * 250) ~ "ms");
        if (!editor.playbackRunningForTesting())
        {
            writeln("[repro] playback STOPPED at pos=",
                editor.playbackPositionForTesting(), " status=",
                editor.statusTextForTesting());
            break;
        }
        lastPosition = editor.playbackPositionForTesting();
    }
    writeln("[repro] final pos=", lastPosition, " running=",
        editor.playbackRunningForTesting());
    writeln("[repro] video stats: requests=",
        editor.videoStatsForTesting().requests,
        " processes=", editor.videoStatsForTesting().processesStarted);
    writeln("[repro] DONE");
    return 0;
}

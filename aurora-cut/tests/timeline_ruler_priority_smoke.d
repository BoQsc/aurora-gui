module tests.timeline_ruler_priority_smoke;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.model : TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

private Widget byId(Widget root, string id)
{
    if (root is null) return null;
    if (root.id() == id) return root;
    foreach (child; root.children())
    {
        auto found = byId(child, id);
        if (found !is null) return found;
    }
    return null;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: timeline-ruler-priority-smoke <base-av.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut timeline ruler priority smoke test";
    options.width = 1440;
    options.height = 960;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial editor paint failed");

    auto timeline = cast(TimelineWidget) byId(editor, "sequence-timeline");
    assert(timeline !is null, "Timeline widget is missing");
    const origin = timeline.localToGlobal(Point(0, 0));

    // Several tracks give the timeline a vertical scrollbar.
    foreach (_; 0 .. 10) editor.modelForTesting().addTrack(TrackKind.video);
    const top = TrackAddress(TrackKind.video,
        editor.modelForTesting().trackCount(TrackKind.video) - 1);
    assert(driver.paint(), "Paint after adding tracks failed");

    // Put a clip on the topmost row so its body can be scrolled under the ruler.
    driver.dropFiles(timeline.pointForTrackTime(top, 0.05), [arguments[1]]);
    bool placed;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.modelForTesting().trackValue(top).clips.length == 1 &&
            !editor.importBusyForTesting())
        {
            placed = true;
            break;
        }
        Thread.sleep(20.msecs);
    }
    assert(placed, "Dropping the fixture did not create a clip");
    assert(driver.paint(), "Paint after the drop failed");

    const clip = editor.modelForTesting().trackValue(top).clips[0];

    // Scroll the row up so the clip body sits underneath the ruler band.
    timeline.restoreView(110.0, 0.0, 40, false, false);
    assert(driver.paint(), "Paint after scrolling failed");
    const rowUnder = timeline.trackRectForTesting(top);
    assert(rowUnder.y < 0 && rowUnder.bottom() > 0,
        "Test setup did not scroll the clip underneath the ruler");

    // Hovering the ruler over the clip's right-edge band must keep the ruler's
    // own cursor: content beneath the ruler must not win interaction.
    const edge = timeline.pointForTrackTime(top, clip.end() - 0.02);
    const rulerEdge = Point(edge.x, origin.y + 10);
    driver.moveTo(rulerEdge);
    assert(driver.paint(), "Paint while hovering the ruler failed");
    assert(timeline.cursor() == CursorKind.arrow,
        "A clip underneath the ruler stole the resize cursor");
    assert(timeline.hoveredToolForTesting() == -1,
        "The ruler hover was misread as a tool hover");

    // The same edge below the ruler must still advertise its resize cursor, so
    // the guard is specific to the ruler band.
    timeline.restoreView(110.0, 0.0, 0, false, false);
    assert(driver.paint(), "Paint after scrolling back failed");
    const body = timeline.pointForTrackTime(top, clip.end() - 0.02);
    driver.moveTo(body);
    assert(driver.paint(), "Paint while hovering the clip edge failed");
    assert(timeline.cursor() == CursorKind.resizeHorizontal,
        "A clip edge below the ruler no longer offers the resize cursor");

    writeln("[timeline-ruler-priority-smoke] ALL PASSED");
    return 0;
}

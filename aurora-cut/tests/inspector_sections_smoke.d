module tests.inspector_sections_smoke;

import aurora;
import auroracut.editor : EditorRoot, InspectorValueField;
import auroracut.model : EffectProperty, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : to;
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

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private Rect globalBounds(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Rect(origin.x, origin.y, widget.bounds().width, widget.bounds().height);
}

private int countBrightPixels(Surface surface, Rect globalRect, int scale)
{
    int count;
    foreach (py; globalRect.y .. globalRect.bottom())
        foreach (px; globalRect.x .. globalRect.right())
        {
            const c = surface.pixel(px * scale, py * scale);
            const r = (c >> 16) & 0xff;
            const g = (c >> 8) & 0xff;
            const b = c & 0xff;
            if ((r + g + b) / 3 > 110) count++;
        }
    return count;
}

/** Horizontal extent of bright (glyph) pixels inside a widget, in logical px. */
private int brightSpanX(Surface surface, Rect globalRect, int scale)
{
    int minimum = int.max;
    int maximum = int.min;
    foreach (py; globalRect.y .. globalRect.bottom())
        foreach (px; globalRect.x .. globalRect.right())
        {
            const c = surface.pixel(px * scale, py * scale);
            const r = (c >> 16) & 0xff;
            const g = (c >> 8) & 0xff;
            const b = c & 0xff;
            if ((r + g + b) / 3 > 110)
            {
                minimum = px < minimum ? px : minimum;
                maximum = px > maximum ? px : maximum;
            }
        }
    return maximum < minimum ? 0 : maximum - minimum + 1;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: inspector-sections-smoke <base-av.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut inspector sections smoke test";
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

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    const v1 = TrackAddress(TrackKind.video, 0);

    // Place the A/V fixture directly on V1 so the Inspector exposes Transform,
    // Style, Audio, Edge Fades and (for text items) Text groups.
    driver.dropFiles(timeline.pointForTrackTime(v1, 0.05), [arguments[1]]);
    bool placed;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.modelForTesting().trackValue(v1).clips.length == 1 &&
            !editor.importBusyForTesting())
        {
            placed = true;
            break;
        }
        Thread.sleep(20.msecs);
    }
    assert(placed, "Dropping the fixture on V1 did not create a clip");

    timeline.setSelection(v1, 0);
    assert(driver.paint(), "Paint after selection failed");
    window.saveScreenshot("build/headless-smoke/inspector-sections.ppm");

    // Every group must exist as a widget, and the legacy hidden source section
    // must stay addressable for older tests.
    requireWidget!Widget(editor, "inspector-source-section");
    auto transformSection = requireWidget!Widget(editor, "inspector-transform-section");
    auto audioSection = requireWidget!Widget(editor, "inspector-audio-section");
    auto layerSection = requireWidget!Widget(editor, "inspector-layer-section");
    auto fadeSection = requireWidget!Widget(editor, "inspector-fade-section");
    assert(transformSection.visible() && audioSection.visible() &&
        layerSection.visible() && fadeSection.visible(),
        "A required Inspector group was not visible for a video clip");

    // Compact rows: diamond key toggle + value field + reset glyph, no text
    // buttons. The value field is still a scrubbable InspectorValueField.
    auto scale = requireWidget!InspectorValueField(editor, "clip-scale");
    auto scaleKey = requireWidget!Button(editor, "inspector-key-Scale");
    auto scaleReset = requireWidget!Button(editor, "inspector-reset-Scale");
    assert(scale.visible(), "Scale value field is not visible");
    assert(scaleKey.visible() && scaleKey.text() == "◇"d,
        "Keyframe toggle is not a compact diamond glyph");
    assert(scaleReset.visible() && scaleReset.text() == "↺"d,
        "Per-row reset is not a compact glyph");

    // Regression: the glyph must actually be painted, not clipped into an
    // invisible sliver by Button's 8px text padding. Count bright glyph pixels
    // inside each button; the dark panel background is far below the threshold.
    const pixelScale = maxInt(1, window.surface().width / options.width);
    const keySpan = brightSpanX(window.surface(), globalBounds(scaleKey), pixelScale);
    const resetSpan = brightSpanX(window.surface(), globalBounds(scaleReset), pixelScale);
    assert(countBrightPixels(window.surface(), globalBounds(scaleKey), pixelScale) > 3 &&
        keySpan > 8,
        "Keyframe diamond glyph was clipped instead of painted (span " ~
        keySpan.to!string ~ "px)");
    assert(countBrightPixels(window.surface(), globalBounds(scaleReset), pixelScale) > 3 &&
        resetSpan > 8,
        "Reset glyph was clipped instead of painted (span " ~
        resetSpan.to!string ~ "px)");

    // Gains from the audio group keep their labels and legacy ids.
    auto gainLabel = requireWidget!Label(editor, "inspector-label-Gain");
    auto gainKey = requireWidget!Button(editor, "inspector-key-Gain");
    assert(gainLabel.visible() && gainLabel.bounds().height >= 20,
        "Inspector property names collapsed to zero height");
    assert(gainKey.visible() && gainKey.text() == "◇"d,
        "Per-item keyframe control is not a compact diamond glyph");

    // Text-item controls remain present and addressable.
    requireWidget!Widget(editor, "clip-mute");
    requireWidget!Widget(editor, "clip-text-align-right");
    requireWidget!Widget(editor, "clip-text");
    requireWidget!Widget(editor, "clip-add-transitions");

    // Style effects start collapsed so the Inspector stays short.
    auto styleBody = requireWidget!Widget(editor, "inspector-body-STYLE EFFECTS");
    assert(!styleBody.visible() && styleBody.layoutHints().excludeFromLayout,
        "Style Effects should start collapsed");

    // Transform starts expanded and is at the top of the scroll viewport, so
    // its header button is a reliable target for the collapse/expand toggle.
    auto transformHeader = requireWidget!Button(editor, "inspector-header-TRANSFORM");
    auto transformBody = requireWidget!Widget(editor, "inspector-body-TRANSFORM");
    assert(transformBody.visible(), "Transform should start expanded");
    assert(!transformHeader.text().canFind("key"d),
        "Unanimated Transform header should not claim keyframes");

    driver.click(globalCenter(transformHeader));
    assert(driver.paint(), "Paint after collapsing Transform failed");
    assert(!transformBody.visible() && transformBody.layoutHints().excludeFromLayout,
        "Header click did not collapse the Transform body");
    driver.click(globalCenter(transformHeader));
    assert(driver.paint(), "Paint after expanding Transform failed");
    assert(transformBody.visible() && !transformBody.layoutHints().excludeFromLayout,
        "Second header click did not expand the Transform body");

    assert(editor.modelForTesting().setKeyframe(v1, 0,
        EffectProperty.scale, 0.0, 2.0),
        "Could not add a Scale keyframe to the fixture clip");
    timeline.setSelection(v1, 0);
    assert(driver.paint(), "Paint after keying failed");
    assert(transformHeader.text().canFind("1 key"d),
        "Transform header did not report its keyframe count");

    writeln("[inspector-sections-smoke] ALL PASSED");
    return 0;
}

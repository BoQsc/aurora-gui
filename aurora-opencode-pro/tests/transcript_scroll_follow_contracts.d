module transcript_scroll_follow_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.array : appender;
import std.conv : to;
import std.datetime : Clock;
import std.file : mkdirRecurse, read, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : split;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children())
        if (auto found = find(child, id)) return found;
    return null;
}

/// On-screen position of a transcript row: its column-relative bounds shifted
/// by the viewport offset. A measurement correction that only re-anchors the
/// view leaves this unchanged.
private int screenY(OpenCodeRoot root, ScrollView view, int row)
{
    return root.bubbleBoundsForTesting(row).y - view.scrollY();
}

/// A saved software-rendered frame, so the fixture can prove the reader sees a
/// stable picture and not only stable widget state.
private struct Frame
{
    int width;
    int height;
    size_t pixels;
    ubyte[] bytes;
}

private Frame loadFrame(string path)
{
    auto bytes = cast(ubyte[]) read(path);
    size_t headerEnd;
    int newlines;
    foreach (i; 0 .. bytes.length)
        if (bytes[i] == '\n' && ++newlines == 3)
        {
            headerEnd = i + 1;
            break;
        }
    assert(headerEnd > 0, "not a PPM screenshot: " ~ path);
    const tokens = (cast(string) bytes[0 .. headerEnd]).split();
    assert(tokens.length == 4 && tokens[0] == "P6", "unsupported PPM: " ~ path);
    return Frame(to!int(tokens[1]), to!int(tokens[2]), headerEnd, bytes);
}

/// Pixel equality of one region between two frames, so a scrollbar or text
/// shift inside the viewport is caught even when widget state looks right.
private bool sameRegion(Frame first, Frame second, Rect region, out string why)
{
    why = "";
    if (first.width != second.width || first.height != second.height)
    {
        why = "frame size changed";
        return false;
    }
    const left = maxInt(0, region.x);
    const top = maxInt(0, region.y);
    const right = minInt(first.width, region.right());
    const bottom = minInt(first.height, region.bottom());
    if (right - left < 8 || bottom - top < 8)
    {
        why = "region too small to compare: " ~ to!string(region);
        return false;
    }
    foreach (y; top .. bottom)
    {
        const start = first.pixels +
            (cast(size_t) y * first.width + cast(size_t) left) * 3;
        const length = cast(size_t) (right - left) * 3;
        if (first.bytes[start .. start + length] !=
            second.bytes[start .. start + length])
        {
            why = "pixels differ in row " ~ to!string(y) ~ " of " ~
                to!string(region);
            return false;
        }
    }
    return true;
}

int main()
{
    const state = buildPath(tempDir(), "aurora-transcript-scroll-" ~
        to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    root.setExperimentalChatRedesignForTesting(true);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    root.pauseToolContinuationForTesting();
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 20) { root.tickTree(0.02); driver.paint(); }

    auto view = cast(ScrollView) find(root, "oc-scroll");
    assert(view !is null, "the transcript scroll view is missing");
    auto bar = view.verticalScrollbar();

    // A virtualized transcript (more rows than the materialization threshold)
    // whose row heights differ sharply from the deferred 64 px estimate, so
    // scrolling up keeps discovering rows that were never measured.
    root.newChatForTesting();
    string[] roles, bodies;
    auto longBody = appender!string();
    foreach (i; 0 .. 14)
        longBody.put("Wrapped filler line " ~ to!string(i) ~
            " that pads the transcript so it overflows the viewport.\n");
    foreach (i; 0 .. 45)
    {
        roles ~= "user";
        bodies ~= "Question " ~ to!string(i);
        roles ~= "assistant";
        bodies ~= (i % 3 == 0) ? longBody.data : "Short reply " ~ to!string(i);
    }
    root.addConversationForTesting(roles, bodies);
    root.tickTree(0.02);
    assert(driver.paint(), "the transcript fixture did not paint");
    const rows = root.messageColumnVisualCountForTesting();
    assert(rows >= 80, "the fixture must exercise the virtualized transcript path, got " ~
        to!string(rows) ~ " rows");

    // Start pinned to the newest message.
    root.scrollToForTesting(int.max);
    root.tickTree(0.02);
    assert(driver.paint(), "the transcript bottom did not paint");
    assert(view.maxScroll() > 0, "the fixture transcript is not scrollable");
    assert(root.followForTesting() && view.scrollY() == view.maxScroll(),
        "a scrolled-to-bottom transcript is not pinned to its newest content");
    const newest = rows - 1;
    assert(root.bubbleBoundsForTesting(newest).bottom() <=
        view.scrollY() + view.bounds().height,
        "the newest message is clipped at the bottom");
    // The viewport rectangle in window pixels, captured from the real frame.
    const windowSize = window.logicalClientSize();
    window.saveScreenshot("build/scroll-bottom.ppm");
    auto bottomFrame = loadFrame("build/scroll-bottom.ppm");
    const scaleX = cast(double) bottomFrame.width / windowSize.width;
    const scaleY = cast(double) bottomFrame.height / windowSize.height;
    const origin = view.globalOrigin();
    const viewportRegion = Rect(
        cast(int) (origin.x * scaleX), cast(int) (origin.y * scaleY),
        cast(int) (view.bounds().width * scaleX),
        cast(int) (view.bounds().height * scaleY));
    assert(viewportRegion.width >= view.bounds().width / 2,
        "the transcript viewport is not inside the captured frame");

    // The reader scrolls up. The layout that follows measures rows above the
    // viewport for the first time; it must settle their corrections in that one
    // layout instead of leaving the scrollbar to move again on later frames.
    root.scrollTranscriptUpForTesting(300);
    assert(!root.followForTesting(), "scrolling up did not hand auto-follow over");
    const readerOffset = view.scrollY();
    int visibleRow = -1;
    foreach (i; 0 .. rows)
    {
        const rect = root.bubbleBoundsForTesting(i);
        if (rect.height <= 0) continue;
        if (rect.y < view.scrollY() || rect.y >= view.scrollY() + view.bounds().height)
            continue;
        visibleRow = cast(int) i;
        break;
    }
    assert(visibleRow >= 0, "the scrolled-up transcript has no visible row to anchor");
    const visibleScreenY = screenY(root, view, visibleRow);

    root.tickTree(0.02);
    assert(driver.paint(), "the scrolled-up transcript did not paint");
    window.saveScreenshot("build/scroll-up-settled.ppm");
    const settledOffset = view.scrollY();
    const settledThumb = bar.thumbRect();
    assert(root.followPillShownForTesting(),
        "scrolling up did not offer the jump-to-latest pill");
    assert(screenY(root, view, visibleRow) == visibleScreenY,
        "measuring the rows above the viewport moved the visible text");
    assert(settledOffset <= readerOffset && settledOffset >= readerOffset - 64,
        "the height correction scrolled the reader from " ~
        to!string(readerOffset) ~ " to " ~ to!string(settledOffset));

    foreach (_; 0 .. 4)
    {
        root.tickTree(0.02);
        assert(driver.paint(), "a settled scrolled-up frame did not paint");
        assert(view.scrollY() == settledOffset,
            "the scrollbar kept moving after the reader stopped scrolling: " ~
            to!string(settledOffset) ~ " -> " ~ to!string(view.scrollY()));
        assert(bar.thumbRect() == settledThumb,
            "the scrollbar thumb kept moving after the reader stopped scrolling");
        assert(root.followPillShownForTesting(),
            "the jump-to-latest pill disappeared while the reader was scrolled up");
    }
    window.saveScreenshot("build/scroll-up-later.ppm");
    string regionWhy;
    // Guard the pixel comparison itself: scrolling up must visibly change the
    // frame, otherwise the equality checks below could pass without seeing the
    // transcript at all.
    assert(!sameRegion(bottomFrame, loadFrame("build/scroll-up-settled.ppm"),
        viewportRegion, regionWhy),
        "the fixture's scroll-up frame is identical to the bottom frame");
    assert(sameRegion(loadFrame("build/scroll-up-settled.ppm"),
        loadFrame("build/scroll-up-later.ppm"), viewportRegion, regionWhy),
        "the transcript or scrollbar kept moving after the reader stopped " ~
        "scrolling: " ~ regionWhy);
    writeln("Scrolling up settles the scrollbar in the frame that measures it");

    // Jump to latest: one frame must land on the newest content and stay there.
    root.clickFollowPillForTesting();
    assert(root.followForTesting(), "jump to latest did not re-engage auto-follow");
    assert(driver.paint(), "the jump-to-latest frame did not paint");
    window.saveScreenshot("build/scroll-jumped.ppm");
    assert(view.scrollY() == view.maxScroll(),
        "jump to latest stopped " ~
        to!string(view.maxScroll() - view.scrollY()) ~
        " px short of the newest content");
    assert(root.bubbleBoundsForTesting(newest).bottom() <=
        view.scrollY() + view.bounds().height,
        "jump to latest left the newest message clipped");
    foreach (_; 0 .. 4)
    {
        root.tickTree(0.02);
        assert(driver.paint(), "a pinned frame after jump to latest did not paint");
        assert(root.followForTesting(), "jump to latest lost auto-follow again");
        assert(view.scrollY() == view.maxScroll(),
            "the viewport drifted away from the newest content after jump to latest");
        assert(!root.followPillShownForTesting(),
            "the jump-to-latest pill came back while the view was pinned");
    }
    assert(sameRegion(bottomFrame, loadFrame("build/scroll-jumped.ppm"),
        viewportRegion, regionWhy),
        "jump to latest did not restore the newest content view: " ~ regionWhy);
    writeln("Jump to latest lands on the newest content in one frame");

    root.shutdownClient();
    return 0;
}

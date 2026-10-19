module pageperf;

/**
 * Stage timing for the page-open and render path.
 *
 * `pageshot` answers "what does the frame look like"; this answers "what did
 * opening it cost". Live mode drives the same real load path the app does - a
 * `BrowserRoot` with a page view, pumped one pass at a time - and times the
 * stages a page open is made of: the network (the engine's own opt-in fetch
 * trace, which attributes every request the page makes), servicing the
 * navigation and stylesheets, layout, and painting. It then separates the two
 * costs a browser pays once a page is up: the engine painting the page itself,
 * and the host repainting the whole window (page plus chrome) after an
 * invalidation.
 *
 * Fixture mode takes the network and the host out of the picture entirely and
 * times one layout and one paint of a local file, so a primitive (a gradient, a
 * scaled image, a wall of text) can be measured on its own.
 *
 * usage: pageperf <url> <width> <height> [maxPasses] [paints]
 *        pageperf --fixture <file.html> <width> <height> [paints]
 *        pageperf --windowmem <width> <height>
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, BrowserTitleBar, browserTheme, WebPageView;
import auroraweb : WebPage;
import auroraweb.dom : Element;
import auroraweb.net : loadTraceEnabled;
import auroraweb : resourceCacheBytes, resourceCacheSize;
import auroraweb.shaping : shapeCacheSize, shapeHitCount, shapeShapingCount;
import aurora.image : RgbaImage;

import std.conv : to;
import std.file : readText;
import std.stdio : stderr, stdout, writeln;
import core.thread : Thread;
import core.time : msecs;
import core.memory : GC;
import std.datetime.stopwatch : AutoStart, StopWatch;

/// The process's managed heap in MiB: what the engine is holding versus what the
/// collector has reclaimed but not yet returned. A browser's resident footprint
/// is dominated by this, so a load's cost has to be read in memory as well as in
/// time.
string heap()
{
    import std.format : format;
    auto stats = GC.stats;
    return format("heap %.1f MiB used / %.1f MiB free; %s", stats.usedSize / 1048576.0,
        stats.freeSize / 1048576.0, resident());
}

/// The heap after a full collection: what the process actually keeps, rather
/// than what the collector has allocated and not yet returned.
string collected()
{
    GC.collect();
    return heap();
}

version (Windows)
{
    private struct ProcessMemoryCounters
    {
        uint cb;
        uint pageFaultCount;
        size_t peakWorkingSetSize;
        size_t workingSetSize;
        size_t quotaPeakPagedPoolUsage;
        size_t quotaPagedPoolUsage;
        size_t quotaPeakNonPagedPoolUsage;
        size_t quotaNonPagedPoolUsage;
        size_t pagefileUsage;
        size_t peakPagefileUsage;
        size_t privateUsage;
    }

    private extern (Windows) int K32GetProcessMemoryInfo(void* process,
        ProcessMemoryCounters* counters, uint cb);
    private extern (Windows) void* GetCurrentProcess();
}

/// The process's resident set, in MiB, with its peak since start. The managed
/// heap number above says what the collector is holding; this says what the
/// operating system actually has to keep in RAM, which is what a task manager
/// shows and what a load's real footprint is judged by. The two diverge when a
/// load churns through many short-lived frames: the pools stay large while the
/// live set does not.
string resident()
{
    version (Windows)
    {
        import std.format : format;
        ProcessMemoryCounters counters;
        counters.cb = ProcessMemoryCounters.sizeof;
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0)
            return "(resident unknown)";
        return format("resident %.1f MiB (peak %.1f MiB)",
            counters.workingSetSize / 1048576.0,
            counters.peakWorkingSetSize / 1048576.0);
    }
    else
    {
        return "(resident not measured)";
    }
}

/// The vendor's glyph atlas: keyed by `FontFace.identity` and grow-only, so it
/// is the place a page that keeps handing the engine a different face instance
/// would accumulate glyph bitmaps - the same key the shaping cache uses.
string atlasInfo()
{
    import aurora.text.atlas : FontSystem;
    import std.format : format;
    auto fonts = FontSystem.sharedInstance();
    if (fonts is null) return "(no font system)";
    auto atlas = fonts.atlas;
    if (atlas is null) return "(no atlas)";
    return format("atlas %dx%d = %.1f MiB", atlas.width(), atlas.height(),
        atlas.pixels().length / 1048576.0);
}

/// Depth-first search for the page view inside the widget tree.
WebPageView findView(Widget widget)
{
    if (widget is null) return null;
    auto view = cast(WebPageView) widget;
    if (view !is null) return view;
    foreach (child; widget.children)
    {
        auto found = findView(child);
        if (found !is null) return found;
    }
    return null;
}

/// Elements in the document, so a cost can be read per node as well as in total.
int countNodes(Element e)
{
    if (e is null) return 0;
    int n = 1;
    foreach (child; e.elements) n += countNodes(child);
    return n;
}

/// One line per image the tree holds: which box carries it and how large it is,
/// which names whatever a paint-time cache attached to the document.
void reportImageLines(Element e, ref string[] lines, int limit)
{
    if (e is null) return;
    void note(Object art, string what)
    {
        auto im = cast(RgbaImage) art;
        if (im is null || lines.length >= limit) return;
        string cls;
        if (auto p = "class" in e.attrs) cls = *p;
        if (cls.length > 28) cls = cls[0 .. 28];
        lines ~= e.tag ~ (cls.length ? "." ~ cls : "") ~ " " ~ what ~ " " ~
            to!string(im.width()) ~ "x" ~ to!string(im.height());
    }
    note(e.image, "img");
    note(e.backgroundImage, "bg");
    if (e.pseudoBefore !is null)
    {
        note(e.pseudoBefore.image, "::before img");
        note(e.pseudoBefore.backgroundImage, "::before bg");
    }
    if (e.pseudoAfter !is null)
    {
        note(e.pseudoAfter.image, "::after img");
        note(e.pseudoAfter.backgroundImage, "::after bg");
    }
    foreach (child; e.elements) reportImageLines(child, lines, limit);
}

/// Bytes held by decoded images and background art in the tree: a browser's
/// retained memory is mostly decoded pixels, so a page's footprint is either
/// here or somewhere that is not an image.
void reportImageBytes(Element e, ref long bytes, ref int count, ref int bigW,
    ref int bigH, ref string bigWhat)
{
    if (e is null) return;
    void account(Object art, string what)
    {
        auto im = cast(RgbaImage) art;
        if (im is null) return;
        const long b = cast(long) im.width() * im.height() * 4;
        bytes += b;
        ++count;
        if (cast(long) im.width() * im.height() > cast(long) bigW * bigH)
        {
            bigW = im.width();
            bigH = im.height();
            bigWhat = what;
        }
    }
    account(e.image, e.tag);
    account(e.backgroundImage, e.tag ~ " background");
    account(e.pseudoBefore is null ? null : e.pseudoBefore.image, "::before");
    account(e.pseudoBefore is null ? null : e.pseudoBefore.backgroundImage,
        "::before background");
    account(e.pseudoAfter is null ? null : e.pseudoAfter.image, "::after");
    account(e.pseudoAfter is null ? null : e.pseudoAfter.backgroundImage,
        "::after background");
    foreach (child; e.elements)
        reportImageBytes(child, bytes, count, bigW, bigH, bigWhat);
}

/// Count boxes that carry a mask and how many of them hold a cached composited
/// layer, so a cache that is never hit can be told from one that is, and the
/// first masked box is described (its children and text decide eligibility).
void reportMaskCache(Element e, ref int masked, ref int cached, ref long pixels,
    ref string[] lines)
{
    if (e is null) return;
    void describe(Element b, string kind)
    {
        if (b is null) return;
        if (!(b.style.maskImage.length && b.style.maskImage != "none")) return;
        ++masked;
        string line = kind ~ " " ~ b.tag ~ " " ~ b.box.width.to!string ~ "x" ~
            b.box.height.to!string ~ " elements=" ~ b.elements.length.to!string ~
            " textNodes=" ~ b.textNodes.length.to!string ~
            " sticky=" ~ (b.style.isSticky ? "yes" : "no");
        if (b.maskedLayer !is null)
        {
            ++cached;
            pixels += cast(long) b.maskedLayerW * b.maskedLayerH;
            line ~= " CACHED gen=" ~ b.maskedLayerGen.to!string;
        }
        else
            line ~= " not cached";
        if (lines.length < 8) lines ~= line;
    }
    describe(e, "box");
    describe(e.pseudoBefore, "::before");
    describe(e.pseudoAfter, "::after");
    foreach (child; e.elements) reportMaskCache(child, masked, cached, pixels, lines);
}

/// Milliseconds since the watch started, and restart it.
double lap(ref StopWatch sw)
{
    const ms = sw.peek.total!"nsecs" / 1.0e6;
    sw.reset();
    return ms;
}

/// Time `paints` full paints of the page alone - no browser chrome, no window
/// compositing - so the engine's own render cost is readable on its own.
///
/// Each frame is timed separately as well as in total: an average hides the
/// shape that decides whether painting feels instant. A document whose first
/// frame is expensive and whose later frames are cheap is resolving its
/// gradients and masks once; every frame at the first frame's cost means the
/// per-frame work is being redone, which is what a scroll or a repaint pays.
double timePagePaint(WebPage page, int paints)
{
    auto surface = new Surface(page.width(), page.height());
    surface.clear(Color.rgb(255, 255, 255));
    page.paint(surface);            // warm any per-frame setup out of the average
    auto sw = StopWatch(AutoStart.yes);
    double fastest = double.max;
    double slowest = 0;
    foreach (i; 0 .. paints)
    {
        auto frame = StopWatch(AutoStart.yes);
        page.paint(surface);
        const ms = frame.peek.total!"nsecs" / 1.0e6;
        if (ms < fastest) fastest = ms;
        if (ms > slowest) slowest = ms;
        if (paints <= 8) writeln("  frame ", i + 1, ": ", ms, " ms");
    }
    writeln("  frame range: ", fastest, " .. ", slowest, " ms");
    return sw.peek.total!"nsecs" / 1.0e6;
}

/// Paint `frames` frames and report the live heap after each frame collects.
/// The shaping counters name a paint that re-shapes runs it already shaped: a
/// rising cache size with a rising shaping count is a key that changes per frame.
void paintAndReport(WebPage page, Surface surface, int frames)
{
    foreach (i; 0 .. frames)
    {
        page.paint(surface);
        const before = heap();
        GC.collect();
        writeln("  paint ", i + 1, ": ", before, " then collected: ", heap(),
            "  shape cache ", shapeCacheSize(), ", shapings ", shapeShapingCount(),
            ", hits ", shapeHitCount(), "  ", atlasInfo());
    }
}

/// `mask-image` off for every box, pseudo-elements included.
void disableMasks(Element e)
{
    if (e is null) return;
    e.style.maskImage = "none";
    if (e.pseudoBefore !is null) e.pseudoBefore.style.maskImage = "none";
    if (e.pseudoAfter !is null) e.pseudoAfter.style.maskImage = "none";
    foreach (child; e.elements) disableMasks(child);
}

/// `filter` and `opacity` off for every box, pseudo-elements included.
void disableFiltersAndOpacity(Element e)
{
    if (e is null) return;
    e.style.filter = "none";
    e.style.opacity = 1.0;
    if (e.pseudoBefore !is null)
    {
        e.pseudoBefore.style.filter = "none";
        e.pseudoBefore.style.opacity = 1.0;
    }
    if (e.pseudoAfter !is null)
    {
        e.pseudoAfter.style.filter = "none";
        e.pseudoAfter.style.opacity = 1.0;
    }
    foreach (child; e.elements) disableFiltersAndOpacity(child);
}

/// Page-load mode: the engine alone - no window, no host, no chrome. Whatever a
/// load retains here belongs to the engine, so measuring the same page with the
/// window separates the engine's share from the host's.
void runPageLoadCase(string url, int w, int h, int maxPasses, int hostStage = 0,
    string label = "")
{
    loadTraceEnabled = true;
    writeln("before load: ", heap());
    auto page = new WebPage(w, h);
    writeln("after an empty page: ", heap());
    // The host does two things the engine alone does not, every frame while the
    // document is still loading: it paints the page into a canvas, and it ticks
    // the page's event loop (timers, rAF). Bit 0 of `hostStage` adds the paint,
    // bit 1 the tick, so a load that retains under the window can be split
    // between them without a window in the picture. (The earlier text-retainer
    // bisect used the same idea: one switch per candidate stage.)
    auto hostSurface = new Surface(w, h);
    hostSurface.clear(Color.rgb(255, 255, 255));
    double clockMs = 0;
    writeln("host stages: paint=", (hostStage & 1) != 0, ", tick=",
        (hostStage & 2) != 0, ", host=", (hostStage & 3) != 0);

    auto sw = StopWatch(AutoStart.yes);
    page.navigate(url);
    double serviceMs = 0;
    double layoutMs = 0;
    int passes = 0;
    int layoutsRun = 0;
    int lastGen = -1;
    while (passes < maxPasses)
    {
        if (!page.layoutPending()) break;
        ++passes;
        auto stage = StopWatch(AutoStart.yes);
        page.serviceNavigation();
        page.serviceStylesheets();
        serviceMs += lap(stage);
        page.layout();
        layoutMs += lap(stage);
        const gen = page.layoutGeneration();
        const bool newLayout = gen != lastGen;
        if (gen != lastGen)
        {
            lastGen = gen;
            ++layoutsRun;
        }
        if (hostStage & 1)
        {
            page.paint(hostSurface);
            page.notePaint();
        }
        if (hostStage & 2)
        {
            page.serviceEventLoop(clockMs);
            if (page.animationFramePending())
                page.serviceAnimationFrame(clockMs);
            clockMs += 16.0;
        }
        // One line per pass floods a 200-pass load; the interesting passes are
        // the ones that ended a layout generation, plus a periodic sample.
        if (newLayout || passes % 20 == 0)
            writeln("pass ", passes, " (", layoutsRun, " layout(s)): ", heap());
        Thread.sleep(1.msecs);
    }
    const loadMs = sw.peek.total!"nsecs" / 1.0e6;
    writeln("load: ", loadMs, " ms, ", passes, " pass(es), ", layoutsRun,
        " layout(s), ", countNodes(page.root()), " elements, viewport=",
        page.width(), "x", page.height());
    writeln("  service: ", serviceMs, " ms; layout: ", layoutMs, " ms");
    writeln("  after load: ", heap());
    GC.collect();
    writeln("  ", label, "after a collection: ", heap());
    // Separate the two things a settled footprint can be: objects the collector
    // still finds reachable, and free pool space it is holding rather than
    // returning. `minimize` returns the free pages, so the drop between these
    // two lines is memory the load only appeared to need.
    GC.minimize();
    writeln("  after returning free pools: ", heap());
    GC.collect();
    writeln("  after collecting again: ", heap());
    writeln("  glyph atlas: ", atlasInfo());
    long bytes;
    int count, bigW, bigH;
    string bigWhat;
    reportImageBytes(page.root(), bytes, count, bigW, bigH, bigWhat);
    writeln("  decoded pixels: ", count, " image(s), ", bytes / 1048576.0, " MiB");
    writeln("  resource cache: ", resourceCacheSize(), " resource(s), ",
        resourceCacheBytes() / 1048576.0, " MiB");
    // Attribution: is the retained heap reachable from this document and page,
    // or only from a process-wide engine/vendor cache? This frame cannot answer
    // that - `page` is one of its locals, so the collector still finds the whole
    // document through the frame (and through the register shadow space a
    // conservative scan reads) and every drop looks like a few MiB. `main`
    // measures the drop after this frame is gone: see `reportDropAndHog`.
    return;
    // Paint the page alone, frame by frame: memory the engine's own paint path
    // retains shows up here, with no window and no chrome in the picture. Each
    // switch below removes one paint stage, so whichever switch stops the growth
    // names the stage that is holding the memory.
    auto surface = new Surface(page.width(), page.height());
    surface.clear(Color.rgb(255, 255, 255));
    page.paint(surface);
    writeln("  after a first paint: ", heap());
    writeln("  --- baseline, every paint stage on ---");
    paintAndReport(page, surface, 4);
    disableMasks(page.root());
    writeln("  --- mask-image off ---");
    paintAndReport(page, surface, 4);
    disableFiltersAndOpacity(page.root());
    writeln("  --- mask-image, filter and opacity off ---");
    paintAndReport(page, surface, 4);
    reportImageBytes(page.root(), bytes, count, bigW, bigH, bigWhat);
    writeln("  images held now: ", count, " image(s), ", bytes / 1048576.0,
        " MiB; biggest ", bigW, "x", bigH,
        bigWhat.length ? " (" ~ bigWhat ~ ")" : "");
    int masked, cached;
    long px;
    string[] lines;
    reportMaskCache(page.root(), masked, cached, px, lines);
    writeln("  masks: ", masked, " masked box(es), ", cached, " cached (", px,
        " px)");
    writeln("  resources held: ", resourceCacheSize(), " resource(s), ",
        resourceCacheBytes() / 1048576.0, " MiB");

    // The window does not paint the page into a Surface: the host's widget
    // canvas is backed by a retained DrawList. Painting the same settled
    // document through both backings separates a retainer the engine keeps in
    // its draw-list path from one the host's scene keeps around the frame.
    import aurora.render.drawlist : DrawList;
    writeln("  --- page painted into a host DrawList ---");
    auto list = new DrawList();
    foreach (i; 0 .. 4)
    {
        list.reset(Size(page.width(), page.height()), Color.rgba(0, 0, 0, 0));
        auto dl = Canvas(list, page.width(), page.height());
        page.paint(dl, 0, 0);
        const before = heap();
        GC.collect();
        writeln("  drawlist paint ", i + 1, ": ", before,
            " then collected: ", heap(), "  ", list.vertices.length,
            " vertices, ", list.rgbaImages.length, " rgba image(s)");
    }
    writeln("  settled: ", resident());
    // Is the retained heap reachable from the document at all? Detaching it
    // separates a retainer the page's own tree holds from one an engine or
    // vendor cache keeps after the tree is gone.
    try
    {
        bytes = 0;
        count = 0;
        bigW = 0;
        bigH = 0;
        bigWhat = null;
        reportImageBytes(page.root(), bytes, count, bigW, bigH, bigWhat);
        writeln("  images reachable from the document: ", count, " image(s), ",
            bytes / 1048576.0, " MiB, biggest ", bigW, "x", bigH, " (", bigWhat, ")");
        page.setHtml("");
        page.layout();
        GC.collect();
        writeln("  after detaching the document: ", heap());
        GC.collect();
        writeln("  after collecting twice: ", heap());
    }
    catch (Throwable) writeln("  detach probe failed");
    // Hold the process open so the real resident size can be read from outside:
    // a heap number that has stopped moving can still be pool accounting, and
    // the resident set is what a user's task manager reports.
    writeln("holding for 6 s so the resident size can be read");
    Thread.sleep(6000.msecs);
}

/// `mask-image`, background gradients and images off for every box.
void disableBackdrops(Element e, bool masks, bool gradients, bool images)
{
    if (e is null) return;
    if (masks) e.style.maskImage = "none";
    if (gradients)
    {
        e.style.backgroundGradient = "none";
        e.style.backgroundGradients = null;
    }
    if (images && e.style.backgroundImage != "none" && e.style.backgroundImage.length)
        e.style.backgroundImage = "none";
    if (e.pseudoBefore !is null)
        disableBackdrops(e.pseudoBefore, masks, gradients, images);
    if (e.pseudoAfter !is null)
        disableBackdrops(e.pseudoAfter, masks, gradients, images);
    foreach (child; e.elements) disableBackdrops(child, masks, gradients, images);
}

/// Stage mode: which paint stage costs the frame time. Each stage switches one
/// more feature off and repaints the same document, so the drop between two
/// stages is that feature's own cost - unlike stripping CSS from the file, which
/// changes the layout the other stages run on.
void runPaintStagesCase(string path, int w, int h, int frames)
{
    auto page = new WebPage(w, h);
    page.setHtml(readText(path));
    page.executeScripts();
    page.layout();
    int settle = 0;
    while (page.layoutPending() && settle < 8)
    {
        page.layout();
        ++settle;
    }
    auto surface = new Surface(page.width(), page.height());
    surface.clear(Color.rgb(255, 255, 255));
    writeln("stages ", path, "  ", page.width(), "x", page.height(), ", ",
        countNodes(page.root()), " elements, ", frames, " frame(s) per stage");
    void stage(string name)
    {
        import auroraweb.paint : paintProfile, resetPaintProfile;
        page.paint(surface);
        auto sw = StopWatch(AutoStart.yes);
        double fastest = double.max;
        double gradMs = 0, buildMs = 0, blitMs = 0, filterMs = 0, filterBlitMs = 0;
        long gradN, buildN, blitN, filterN, filterBlitN;
        foreach (i; 0 .. frames)
        {
            resetPaintProfile();
            auto frame = StopWatch(AutoStart.yes);
            page.paint(surface);
            const ms = frame.peek.total!"nsecs" / 1.0e6;
            if (ms < fastest) fastest = ms;
            gradMs += paintProfile.gradientMs;
            gradN += paintProfile.gradientRasters;
            buildMs += paintProfile.maskedBuildMs;
            buildN += paintProfile.maskedBuilds;
            blitMs += paintProfile.maskedBlitMs;
            blitN += paintProfile.maskedBlits;
            filterMs += paintProfile.filterMs;
            filterN += paintProfile.filterLayers;
            filterBlitMs += paintProfile.filterBlitMs;
            filterBlitN += paintProfile.filterBlits;
        }
        writeln("  ", name, ": ", sw.peek.total!"nsecs" / 1.0e6 / frames,
            " ms/frame (fastest ", fastest, " ms)");
        writeln("    gradient rasters ", gradN / frames, "/frame (",
            gradMs / frames, " ms), masked builds ", buildN / frames, "/frame (",
            buildMs / frames, " ms), masked blits ", blitN / frames, "/frame (",
            blitMs / frames, " ms), filtered layers ", filterN / frames, "/frame (",
            filterMs / frames, " ms)");
        writeln("    filtered blits ", filterBlitN / frames, "/frame (",
            filterBlitMs / frames, " ms)");
    }
    stage("everything on");
    disableBackdrops(page.root(), true, false, false);
    stage("masks off");
    disableBackdrops(page.root(), false, true, false);
    stage("masks and background gradients off");
    disableBackdrops(page.root(), false, false, true);
    stage("masks, gradients and background images off");
}

/// Fixture mode: one local file, no network, no host. Reports the cost of a
/// first layout (parse + style + geometry), of a re-layout, and of one paint.
void runFixtureCase(string path, int w, int h, int paints)
{
    auto page = new WebPage(w, h);
    auto sw = StopWatch(AutoStart.yes);
    page.setHtml(readText(path));
    const parseMs = lap(sw);
    page.executeScripts();
    const scriptMs = lap(sw);
    page.layout();
    const layoutMs = lap(sw);
    const firstMs = lap(sw);
    const nodes = countNodes(page.root());
    // Let the work a document defers land the way the host's frame loop does -
    // a `data:` image, an inline SVG - so the paint below measures the finished
    // document and not a half-loaded one.
    int settlePasses = 0;
    while (page.layoutPending() && settlePasses < 8)
    {
        page.layout();
        ++settlePasses;
    }
    const settleMs = lap(sw);
    // A second layout with the document marked dirty: the geometry pass alone,
    // without parsing or the cascade.
    page.markLayoutDirty();
    page.layout();
    const relayoutMs = lap(sw);
    const paintMs = timePagePaint(page, paints);
    writeln("fixture ", path, "  ", page.width(), "x", page.height(), ", ",
        nodes, " elements");
    writeln("  parse+style+layout: ", firstMs, " ms (parse ", parseMs,
        ", scripts ", scriptMs, ", first layout ", layoutMs, ")");
    writeln("  settle: ", settlePasses, " further pass(es) in ", settleMs, " ms");
    writeln("  re-layout: ", relayoutMs, " ms");
    writeln("  paint: ", paints, " frame(s) in ", paintMs, " ms => ",
        paints ? paintMs / paints : 0.0, " ms/frame");
    // Steady-state paint memory on one document: a stage that retains per frame
    // shows up as a rising live heap here, with the page's own content as the
    // only variable between runs.
    auto steady = new Surface(page.width(), page.height());
    steady.clear(Color.rgb(255, 255, 255));
    page.paint(steady);
    paintAndReport(page, steady, 4);
}

/// Zero a region of this thread's stack below the calling frame.
///
/// The collector is conservative, so a stale copy of a dead object left in an
/// abandoned frame's slot - or in the Win64 register shadow space above the
/// stack pointer - keeps that object's whole graph alive and hides the release
/// the measurement is trying to read. Filling the region drops those copies.
/// Measured on this probe: without it, a dropped 173 MiB page and 768 MB of
/// nulled scratch arrays both stayed "used" after a collection, because the
/// frames that had held them were still being scanned.
private void clearStaleStack()
{
    ubyte[512 * 1024] pad = void;
    foreach (ref b; pad)
        b = 1;
}

/// What closing the page released.
///
/// Called by `main` after `runPageLoadCase` has returned, because the page and
/// its document die with that frame. Read inside the loading frame, the page is
/// one of its locals and survives the collection.
void reportDrop()
{
    clearStaleStack();
    GC.collect();
    writeln("  after dropping the page: ", heap());
    stdout.flush();
    GC.minimize();
    writeln("  after returning pools: ", heap(), "; resident ", resident());
    stdout.flush();
}

/// Occupy 768 MB, then leave: is the retained space really occupied, or is the
/// collector only counting pages it could reuse? Occupied space makes the pool
/// grow again; reusable space does not. The caller measures after this frame is
/// gone (see `reportHogFreed`).
void reportHogAllocated()
{
    auto hog = new ubyte[][](96);
    foreach (i; 0 .. hog.length)
    {
        hog[i] = new ubyte[8 * 1024 * 1024];
        hog[i][0] = cast(ubyte) i;
    }
    writeln("  after allocating 768 MB: ", heap());
    stdout.flush();
}

/// What the 768 MB cost once its frame is gone.
void reportHogFreed()
{
    clearStaleStack();
    GC.collect();
    writeln("  after freeing those buffers: ", heap());
    stdout.flush();
}

/// The whole teardown story: drop, then the occupancy test.
void reportDropAndHog()
{
    reportDrop();
    reportHogAllocated();
    reportHogFreed();
}

/// Window-baseline mode: what the app holds the instant its window exists and
/// no page has been opened - the number a user reads in Task Manager right
/// after launch. Splits that number into garbage the collector has not returned
/// and state the window really keeps, then builds a second window to tell a
/// per-window cost apart from a one-time process cost.
void runWindowBaselineCase(int w, int h)
{
    writeln("start: ", heap());
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = w;
    options.height = h;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    // Each step is collected before the next begins, so a step's own retained
    // cost is visible instead of being mixed into the following step's.
    writeln("process, collected: ", collected());
    auto theme = browserTheme();
    writeln("theme: ", collected());
    // The interpreter's own fixed cost: every page pays it once, before it has
    // parsed anything, so it has to be measured before any document exists.
    {
        import auroraweb.js : JsRuntime;
        auto runtime = new JsRuntime();
        writeln("js runtime: ", collected());
    }
    auto window = new GuiWindow(options, theme);
    writeln("window: ", collected());
    // A page of its own, before any browser chrome: the engine's document plus
    // its JavaScript realm, which the shell is expected to hold once per tab.
    auto barePage = new WebPage(w, h);
    writeln("bare page: ", collected());
    // The chrome is built piece by piece here so the shell's fixed cost can be
    // attributed: a titlebar, the two full-window overlays, and a page view.
    auto titleBar = new BrowserTitleBar(window);
    writeln("titlebar: ", collected());
    auto snapPreview = new TitleBarSnapPreview();
    writeln("snap preview: ", collected());
    auto bareView = new WebPageView(barePage);
    writeln("page view: ", collected());
    // What a page view's document costs, split into its two halves: the
    // document the engine parses and lays out, and the JavaScript realm it
    // creates for it.
    auto docPage = new WebPage(w, h);
    docPage.setHtml("<html><body><p>hello</p></body></html>");
    writeln("setHtml: ", collected());
    docPage.executeScripts();
    writeln("executeScripts: ", collected());
    // Per-tab cost after the engine has warmed up, which is what the user pays
    // for every further tab rather than on the first one.
    auto viewB = new WebPageView(new WebPage(w, h));
    writeln("second page view: ", collected());
    auto viewC = new WebPageView(new WebPage(w, h));
    writeln("third page view: ", collected());
    auto root = new BrowserRoot(window);
    writeln("browser root: ", collected());
    window.setRoot(root);
    // Drive the host's own loop for a moment: the shell's idle trim runs from
    // its tick, so this is what tells a trim that never fires apart from one
    // that fires and releases nothing.
    foreach (i; 0 .. 1200) root.tickTree(0.016);
    writeln("after settled ticks: ", heap());
    auto driver = new UiTestDriver(window);
    driver.resize(Size(w, h));
    writeln("resize: ", collected());
    auto view = findView(root);
    if (view !is null)
    {
        view.invalidate();
        driver.paint();
        writeln("first frame: ", collected());
    }
    auto second = new GuiWindow(options, browserTheme());
    auto root2 = new BrowserRoot(second);
    second.setRoot(root2);
    auto driver2 = new UiTestDriver(second);
    driver2.resize(Size(w, h));
    writeln("second window: ", collected());
}

void main(string[] args)
{
    if (args.length < 4)
    {
        stderr.writeln("usage: pageperf <url> <width> <height> [maxPasses] [paints]");
        stderr.writeln("       pageperf --fixture <file.html> <width> <height> [paints]");
        stderr.writeln("       pageperf --fixtures <width> <height> <paints> <file.html>...");
        stderr.writeln("       pageperf --windowmem <width> <height>");
        return;
    }
    if (args[1] == "--pageload")
    {
        if (args.length < 5)
        {
            stderr.writeln("usage: pageperf --pageload <url> <width> <height> [maxPasses]");
            return;
        }
        // What a user's next navigation does: open the same page again, in the
        // same process, three times. Each page is dropped when its loading
        // frame returns; if anything still holds it, its document reappears as
        // growth on the next line - and four loads show whether that growth
        // accumulates or is a single retained pool. The collector is
        // conservative, so the abandoned frame's slots are cleared first, and
        // the free pools are returned so the next load cannot simply reuse the
        // space the previous one grew.
        const passes = args.length >= 6 ? to!int(args[5]) : 200;
        string[] labels = ["", "second ", "third ", "fourth "];
        foreach (idx, label; labels)
        {
            if (idx)
            {
                clearStaleStack();
                GC.collect();
                GC.minimize();
                writeln("  after reclaiming page ", idx, ": ", heap());
                stdout.flush();
            }
            runPageLoadCase(args[2], to!int(args[3]), to!int(args[4]), passes, 0, label);
        }
        reportDropAndHog();
        return;
    }
    if (args[1] == "--pageload-host")
    {
        if (args.length < 6)
        {
            stderr.writeln("usage: pageperf --pageload-host <url> <width> <height> <stage> [maxPasses]");
            stderr.writeln("       stage: 1 = paint the page each pass, 2 = tick its event loop, 3 = both");
            return;
        }
        runPageLoadCase(args[2], to!int(args[3]), to!int(args[4]),
            args.length >= 7 ? to!int(args[6]) : 200, to!int(args[5]));
        reportDropAndHog();
        return;
    }
/// Pseudo-box census: every generated box, with the box it occupies and the art
/// it paints. A page whose `::before` rule leaked onto every descendant shows up
/// here as many boxes sharing one viewport-sized rectangle.
void runPseudoCensusCase(string path, int w, int h)
{
    auto page = new WebPage(w, h);
    page.setHtml(readText(path));
    page.executeScripts();
    page.layout();
    int settle = 0;
    while (page.layoutPending() && settle < 8)
    {
        page.layout();
        ++settle;
    }
    int maskCount, gradientCount, imageCount, fullViewport;
    long area;
    void visit(Element e)
    {
        if (e is null) return;
        foreach (pseudo; [e.pseudoBefore, e.pseudoAfter])
        {
            if (pseudo is null) continue;
            const hasMask = pseudo.style.maskImage != "none";
            const hasGradient = pseudo.style.backgroundGradient != "none" &&
                pseudo.style.backgroundGradient.length;
            const hasImage = pseudo.backgroundImage !is null;
            if (!hasMask && !hasGradient && !hasImage) continue;
            if (hasMask) ++maskCount;
            if (hasGradient) ++gradientCount;
            if (hasImage) ++imageCount;
            area += cast(long) pseudo.box.width * pseudo.box.height;
            const full = pseudo.box.x == 0 && pseudo.box.y == 0 &&
                pseudo.box.width >= w && pseudo.box.height >= h / 2;
            if (full) ++fullViewport;
            writeln("  ", e.tag, " ", pseudo.box.x, ",", pseudo.box.y, " ",
                pseudo.box.width, "x", pseudo.box.height,
                hasMask ? " mask" : "", hasGradient ? " gradient" : "",
                hasImage ? " image" : "",
                pseudo.style.backgroundRepeat == "no-repeat" ? " no-repeat" : "",
                pseudo.style.opacity < 1.0 ? " opacity" : "");
        }
        foreach (child; e.elements) visit(child);
    }
    visit(page.root());
    writeln("pseudo boxes: ", maskCount, " masked, ", gradientCount,
        " gradient, ", imageCount, " image, ", fullViewport,
        " viewport-sized; total painted area ", area / 1048576.0, " Mpx");
}

    if (args[1] == "--pseudoboxes")
    {
        if (args.length < 5)
        {
            stderr.writeln("usage: pageperf --pseudoboxes <file.html> <width> <height>");
            return;
        }
        runPseudoCensusCase(args[2], to!int(args[3]), to!int(args[4]));
        return;
    }
    if (args[1] == "--paintstages")
    {
        if (args.length < 5)
        {
            stderr.writeln("usage: pageperf --paintstages <file.html> <width> <height> [frames]");
            return;
        }
        runPaintStagesCase(args[2], to!int(args[3]), to!int(args[4]),
            args.length >= 6 ? to!int(args[5]) : 4);
        return;
    }
    if (args[1] == "--windowmem")
    {
        if (args.length < 4)
        {
            stderr.writeln("usage: pageperf --windowmem <width> <height>");
            return;
        }
        runWindowBaselineCase(to!int(args[2]), to!int(args[3]));
        return;
    }
    if (args[1] == "--fixture")
    {
        if (args.length < 5)
        {
            stderr.writeln("usage: pageperf --fixture <file.html> <width> <height> [paints]");
            return;
        }
        runFixtureCase(args[2], to!int(args[3]), to!int(args[4]),
            args.length >= 6 ? to!int(args[5]) : 10);
        return;
    }
    if (args[1] == "--fixtures")
    {
        // One case at a time inside one process: no CPU contention between
        // cases, so their numbers can be compared.
        if (args.length < 6)
        {
            stderr.writeln("usage: pageperf --fixtures <width> <height> <paints> <file.html>...");
            return;
        }
        const cw = to!int(args[2]);
        const ch = to!int(args[3]);
        const cp = to!int(args[4]);
        foreach (path; args[5 .. $]) runFixtureCase(path, cw, ch, cp);
        return;
    }

    const url = args[1];
    const w = to!int(args[2]);
    const h = to!int(args[3]);
    const maxPasses = args.length >= 5 ? to!int(args[4]) : 200;
    const paints = args.length >= 6 ? to!int(args[5]) : 10;

    // The engine traces every resource the page loads: the document, its
    // stylesheets, scripts, images and fonts, each with its own wall time and
    // its offset from the run's first request.
    loadTraceEnabled = true;
    writeln("before load: ", heap());

    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = w;
    options.height = h;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(w, h));
    writeln("window ready: ", heap());

    auto total = StopWatch(AutoStart.yes);
    auto stage = StopWatch(AutoStart.no);
    double serviceMs = 0;   // navigation response + stylesheets applied
    double layoutMs = 0;    // layout() calls that did work
    double paintMs = 0;     // frames rasterised while loading
    int passes = 0;
    int layoutsRun = 0;
    int lastGen = -1;

    stage.start();
    if (url.length) root.openUrlAtStartup(url);

    while (passes < maxPasses)
    {
        auto view = findView(root);
        if (view is null || view.page() is null)
        {
            Thread.sleep(1.msecs);
            if (lap(stage) > 120000.0) break;
            continue;
        }
        auto page = view.page();
        if (!page.layoutPending()) break;
        ++passes;

        page.serviceNavigation();
        page.serviceStylesheets();
        serviceMs += lap(stage);

        page.layout();
        layoutMs += lap(stage);
        const gen = page.layoutGeneration();
        if (gen != lastGen)
        {
            lastGen = gen;
            ++layoutsRun;
        }

        // Split every loading pass into its two halves: whatever the load
        // retains belongs to one of them.
        const afterLayout = heap();
        view.invalidate();
        driver.paint();
        paintMs += lap(stage);
        writeln("pass ", passes, " (", layoutsRun, " layout(s)): after layout ",
            afterLayout, ", after paint ", heap());
        // Where the loading passes are spending their memory: document art
        // (baked gradients, images) and the mask layer cache are the two caches
        // the layout pass rebuilds, so report both every pass.
        {
            long bytes;
            int count, bigW, bigH;
            string bigWhat;
            reportImageBytes(page.root(), bytes, count, bigW, bigH, bigWhat);
            int masked, cached;
            long px;
            string[] lines;
            reportMaskCache(page.root(), masked, cached, px, lines);
            writeln("    art: ", count, " image(s), ", bytes / 1048576.0,
                " MiB; masks: ", masked, " box(es), ", cached, " cached (", px,
                " px)");
        }

        Thread.sleep(1.msecs);
    }
    const openMs = total.peek.total!"nsecs" / 1.0e6;
    stage.stop();

    auto view = findView(root);
    if (view is null || view.page() is null)
    {
        writeln("no page view after ", openMs, " ms");
        return;
    }
    auto page = view.page();
    const nodes = countNodes(page.root());
    writeln("open: ", openMs, " ms total, ", passes, " pass(es), ",
        layoutsRun, " layout(s), ", nodes, " elements, ",
        "viewport=", page.width(), "x", page.height());
    writeln("  service (navigation + stylesheets): ", serviceMs, " ms");
    writeln("  layout: ", layoutMs, " ms over ", layoutsRun, " layout(s)");
    writeln("  window paint while loading: ", paintMs, " ms over ", passes, " frame(s)");
    writeln("  after load: ", heap());
    // How much of what the load is holding is garbage the collector has not had
    // a reason to reclaim, and how much is live? A browser's resident footprint
    // is dominated by the first.
    GC.collect();
    writeln("  after a collection: ", heap());
    // Whether the settled browser would still report outstanding work: the
    // host's idle-trim waits for that flag to clear, so a page that never clears
    // it would silently keep the collector's free pools.
    writeln("  settled state: layoutPending=", page.layoutPending(),
        " pendingTasks=", page.hasPendingTasks());
    // Control: hide the page view. Its document stays loaded and laid out; only
    // the host stops compositing it into the window. A settle that collapses
    // here was held by that compositing, not by the document.
    view.setVisible(false);
    driver.paint();
    GC.collect();
    writeln("  with the page view hidden: ", heap());
    view.setVisible(true);
    driver.paint();
    GC.collect();
    writeln("  shown again: ", heap());
    {
        long bytes;
        int count, bigW, bigH;
        string bigWhat;
        reportImageBytes(page.root(), bytes, count, bigW, bigH, bigWhat);
        writeln("  decoded pixels: ", count, " image(s), ", bytes / 1048576.0,
            " MiB; biggest ", bigW, "x", bigH,
            bigWhat.length ? " (" ~ bigWhat ~ ")" : "");
        writeln("  resource cache: ", resourceCacheSize(), " resource(s), ",
            resourceCacheBytes() / 1048576.0, " MiB");
        writeln("  shaping: cache ", shapeCacheSize(), ", shapings ",
            shapeShapingCount(), ", hits ", shapeHitCount());
    }
    {
        int masked, cached;
        long px;
        string[] lines;
        reportMaskCache(page.root(), masked, cached, px, lines);
        writeln("  masks: ", masked, " masked box(es), ", cached, " cached (",
            px, " px)");
        foreach (line; lines) writeln("    ", line);
    }
    if (page.layoutPending()) writeln("  STILL PENDING after ", maxPasses, " passes");

    // After settle, two different steady costs. The engine's paint of the page
    // alone, then the host repainting the window - page and chrome - after an
    // invalidation, which is what a scroll or an animation frame pays.
    const pageMs = timePagePaint(page, paints);
    auto windowSw = StopWatch(AutoStart.yes);
    foreach (i; 0 .. paints)
    {
        view.invalidate();
        driver.paint();
        // Live heap after every window frame: the host path retaining per frame
        // shows up as a rise here that the engine's own paint does not have.
        if (i < 8)
        {
            const before = heap();
            GC.collect();
            writeln("  window frame ", i + 1, ": ", before,
                " then collected: ", heap());
        }
    }
    const windowRepaintMs = windowSw.peek.total!"nsecs" / 1.0e6;
    writeln("  page paint: ", paints, " frame(s) in ", pageMs, " ms => ",
        paints ? pageMs / paints : 0.0, " ms/frame");
    writeln("  window repaint: ", paints, " invalidated frame(s) in ",
        windowRepaintMs, " ms => ", paints ? windowRepaintMs / paints : 0.0,
        " ms/frame");
    writeln("  after repaints: ", heap());
    GC.collect();
    writeln("  after a collection: ", heap());
    // Control: the same window frames with the page view's document detached, so
    // whatever still rises here belongs to the host's chrome and scene rather
    // than to the page.
    writeln("  --- window frames with an empty page view ---");
    auto detached = view.page();
    view.setPage(null);
    foreach (i; 0 .. 4)
    {
        view.invalidate();
        driver.paint();
        const before = heap();
        GC.collect();
        writeln("  chrome frame ", i + 1, ": ", before,
            " then collected: ", heap());
    }
    view.setPage(detached);
    GC.minimize();
    writeln("  after returning memory: ", heap());
    // Hold the process open briefly so an outside observer can read its resident
    // size at this point (tasklist), which is what the user actually sees.
    writeln("  holding for 6 s so the resident size can be read");
    Thread.sleep(6000.msecs);
    {
        int masked, cached;
        long px;
        string[] lines;
        reportMaskCache(page.root(), masked, cached, px, lines);
        writeln("  masks after repainting: ", masked, " masked box(es), ",
            cached, " cached (", px, " px)");
        foreach (line; lines) writeln("    ", line);
    }
}

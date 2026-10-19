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
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, browserTheme, WebPageView;
import auroraweb : WebPage;
import auroraweb.dom : Element;
import auroraweb.net : loadTraceEnabled;

import std.conv : to;
import std.file : readText;
import std.stdio : stderr, writeln;
import core.thread : Thread;
import core.time : msecs;
import std.datetime.stopwatch : AutoStart, StopWatch;

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

/// Milliseconds since the watch started, and restart it.
double lap(ref StopWatch sw)
{
    const ms = sw.peek.total!"nsecs" / 1.0e6;
    sw.reset();
    return ms;
}

/// Time `paints` full paints of the page alone - no browser chrome, no window
/// compositing - so the engine's own render cost is readable on its own.
double timePagePaint(WebPage page, int paints)
{
    auto surface = new Surface(page.width(), page.height());
    surface.clear(Color.rgb(255, 255, 255));
    page.paint(surface);            // warm any per-frame setup out of the average
    auto sw = StopWatch(AutoStart.yes);
    foreach (i; 0 .. paints) page.paint(surface);
    return sw.peek.total!"nsecs" / 1.0e6;
}

/// Fixture mode: one local file, no network, no host. Reports the cost of a
/// first layout (parse + style + geometry), of a re-layout, and of one paint.
void runFixtureCase(string path, int w, int h, int paints)
{
    auto page = new WebPage(w, h);
    auto sw = StopWatch(AutoStart.yes);
    page.setHtml(readText(path));
    page.executeScripts();
    page.layout();
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
    writeln("  parse+style+layout: ", firstMs, " ms");
    writeln("  settle: ", settlePasses, " further pass(es) in ", settleMs, " ms");
    writeln("  re-layout: ", relayoutMs, " ms");
    writeln("  paint: ", paints, " frame(s) in ", paintMs, " ms => ",
        paints ? paintMs / paints : 0.0, " ms/frame");
}

void main(string[] args)
{
    if (args.length < 4)
    {
        stderr.writeln("usage: pageperf <url> <width> <height> [maxPasses] [paints]");
        stderr.writeln("       pageperf --fixture <file.html> <width> <height> [paints]");
        stderr.writeln("       pageperf --fixtures <width> <height> <paints> <file.html>...");
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

        view.invalidate();
        driver.paint();
        paintMs += lap(stage);

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
    }
    const windowRepaintMs = windowSw.peek.total!"nsecs" / 1.0e6;
    writeln("  page paint: ", paints, " frame(s) in ", pageMs, " ms => ",
        paints ? pageMs / paints : 0.0, " ms/frame");
    writeln("  window repaint: ", paints, " invalidated frame(s) in ",
        windowRepaintMs, " ms => ", paints ? windowRepaintMs / paints : 0.0,
        " ms/frame");
}

module app;

/**
 * Aurora Browser — a desktop web browser shell built on Aurora-D.
 *
 * The window chrome and page rendering live in `aurorabrowser.appui`
 * (`BrowserRoot`); this module is the slim entry point. The window is
 * frameless: `BrowserRoot` carries the `BrowserTitleBar` (an Aurora
 * `FramelessWindowTitleBar`) plus a snap-preview overlay and 1 px window
 * border, matching the current Aurora window-shell pattern.
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, browserTheme;
import core.thread : Thread;
import core.time : msecs;

private int runScreenshot(string path, string startUrl)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    // A network document is fetched off the window now, so the host's own
    // passes are what apply it: tick and paint until it is in, or the capture
    // would be the frame before the load. A local or built-in page is already
    // in hand, so it keeps the single paint it had.
    for (int guard = 0; root.loadPendingForTesting() && guard < 400; ++guard)
    {
        root.tickTree(0.02);
        driver.paint();
        Thread.sleep(5.msecs);
    }
    driver.paint();
    window.saveScreenshot(path);
    window.close();
    return 0;
}

/**
 * Print what the running browser holds, split into collector memory (live and
 * committed-free) and the rest of what the process touches, then exit.
 *
 * The window is built exactly as the interactive browser builds it, because the
 * renderer and window path are precisely where a probe and the shipped app
 * disagree: a headless probe reports ~170 MiB while the app's Task Manager shows
 * ~350 MiB for the same page.
 */
private int runMemReport(string startUrl, int seconds)
{
    import std.datetime.stopwatch : AutoStart, StopWatch;
    import std.stdio : writeln;
    import core.memory : GC;

    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = false;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    auto clock = StopWatch(AutoStart.yes);
    while (clock.peek.total!"seconds" < seconds)
    {
        root.tickTree(0.016);
        driver.paint();
        Thread.sleep(16.msecs);
    }
    GC.collect();
    auto stats = GC.stats;
    writeln("gc used ", stats.usedSize / 1048576.0, " MiB, free ",
        stats.freeSize / 1048576.0, " MiB");
    writeln("resident ", workingSetMiB(), " MiB (peak ", peakWorkingSetMiB(),
        " MiB)");
    // What the collector can actually hand back in this state: the idle trim
    // calls `minimize` every 120 ticks, so the gap between these two lines is
    // pool the trim never manages to release while the browser keeps painting.
    GC.minimize();
    auto after = GC.stats;
    writeln("after minimize: gc used ", after.usedSize / 1048576.0, " MiB, free ",
        after.freeSize / 1048576.0, " MiB, resident ", workingSetMiB(), " MiB");
    window.close();
    return 0;
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

/// This process's resident set in MiB, the number a task manager shows.
private double workingSetMiB()
{
    version (Windows)
    {
        ProcessMemoryCounters counters;
        counters.cb = ProcessMemoryCounters.sizeof;
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0)
            return -1;
        return counters.workingSetSize / 1048576.0;
    }
    else
        return -1;
}

private double peakWorkingSetMiB()
{
    version (Windows)
    {
        ProcessMemoryCounters counters;
        counters.cb = ProcessMemoryCounters.sizeof;
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0)
            return -1;
        return counters.peakWorkingSetSize / 1048576.0;
    }
    else
        return -1;
}

/// Extract `--url <target>` from the command line ("" when absent).
private string urlArg(string[] args)
{
    for (int i = 1; i < args.length - 1; ++i)
    {
        if (args[i] == "--url" && args[i + 1].length > 0)
            return args[i + 1];
    }
    return "";
}

/// Extract `--screenshot <path>` from the command line ("" when absent).
private string screenshotArg(string[] args)
{
    for (int i = 1; i < args.length - 1; ++i)
    {
        if (args[i] == "--screenshot" && args[i + 1].length > 0)
            return args[i + 1];
    }
    return "";
}

/// Seconds requested by `--memreport[=<seconds>]`, or 0 when absent. The
/// duration is what tells a footprint that is merely large apart from one that
/// keeps growing while the browser sits idle.
private int memReportArg(string[] args)
{
    import std.algorithm : startsWith;
    foreach (arg; args[1 .. $])
    {
        if (arg == "--memreport") return 6;
        if (arg.startsWith("--memreport="))
        {
            import std.conv : to;
            return to!int(arg["--memreport=".length .. $]);
        }
    }
    return 0;
}

/// Open a browser window. When `startUrl` is non-empty it is opened in the
/// first tab instead of the home page.
private int runBrowser(string startUrl)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = false;
    options.lowLatency = true;
    options.vsync = true;
    // Keep the native pointer during titlebar drags; Aurora's synchronized
    // drawn cursor is meant for dragging retained compositor layers.
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    return window.run();
}

int main(string[] args)
{
    const screenshot = screenshotArg(args);
    if (screenshot.length > 0)
        return runScreenshot(screenshot, urlArg(args));
    const memSeconds = memReportArg(args);
    if (memSeconds > 0)
        return runMemReport(urlArg(args), memSeconds);
    return runBrowser(urlArg(args));
}

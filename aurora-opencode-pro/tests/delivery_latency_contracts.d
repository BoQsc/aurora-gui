module delivery_latency_contracts;

import aurora;
import aurora.platform.base : NativeWindowSink;
import aurora.platform.win32 : PlatformWindow;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import auroraopencode.latency : LatencyStage, LatencySnapshot;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : sort;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

// Exercise the native pacing wait itself, independently of layout/provider work.
class WakeProbe : NativeWindowSink
{
    PlatformWindow window;
    Mutex mutex;
    long sent;
    long[] delays;
    size_t ticks;
    MonoTime started;
    bool timedOut;

    this() { mutex = new Mutex(); started = MonoTime.currTime; }
    override void onNativeEvent(ref Event event) {}
    override bool onNativeClientControlAt(Point point) { return false; }
    override void onNativeScrollTarget(PointF point) {}
    override bool onNativePaint() { return true; }
    override void onNativeTick(double delta)
    {
        ++ticks;
        if (MonoTime.currTime - started > 10.seconds)
        { timedOut = true; window.close(); }
    }
    override void onNativeService()
    {
        synchronized (mutex)
        {
            if (!sent) return;
            delays ~= cast(long) ((MonoTime.currTime.ticks - sent) *
                1_000_000.0 / MonoTime.ticksPerSecond);
            sent = 0;
            if (delays.length == 40) window.close();
        }
    }
    override bool onNativeContinuousPointerFrames() { return false; }
    override bool onNativeCloseRequested() { return true; }
    override void onNativeShutdown() {}
}

void measureWake()
{
    auto probe = new WakeProbe();
    WindowOptions options;
    options.width = 160; options.height = 100;
    options.startNoActivate = true;
    probe.window = new PlatformWindow(options, probe);
    auto wake = probe.window.serviceWake();
    auto producer = new Thread(delegate()
    {
        foreach (i; 0 .. 40)
        {
            Thread.sleep((23 + i % 11).msecs);
            synchronized (probe.mutex) probe.sent = MonoTime.currTime.ticks;
            wake();
            while (true)
            {
                synchronized (probe.mutex) if (!probe.sent) break;
                if (MonoTime.currTime - probe.started > 11.seconds) return;
                Thread.sleep(1.msecs);
            }
        }
    });
    probe.window.show();
    producer.start();
    probe.window.run();
    producer.join();
    // A producer can still hold a wake delegate after native shutdown.
    wake();
    assert(!probe.timedOut && probe.delays.length == 40);
    const elapsedMs = (MonoTime.currTime - probe.started).total!"msecs";
    assert(probe.ticks < elapsedMs / 8 + 80, "Native pacing became an idle spin");
    sort(probe.delays);
    assert(probe.delays[20] < 8_000, "Worker notifications are still waiting behind a frame sleep");
    writeln("MEASURE native_wake samples=40 p50_us=", probe.delays[20],
        " p95_us=", probe.delays[38], " ticks=", probe.ticks, " elapsed_ms=", elapsedMs);
}

int main()
{
    measureWake();
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run with test_latency_transport.py --delivery");
    const directory = absolutePath("delivery-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(buildPath(directory, "workspace"));
    mkdirRecurse(buildPath(directory, "state"));
    setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "local-fixture";
    settings.model = "delivery"; settings.workspace = buildPath(directory, "workspace");
    settings.toolsEnabled = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    options.startNoActivate = true;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    const deadline = MonoTime.currTime + 20.seconds;
    size_t submitted, settled, painted;
    bool firstPaintBeforeSettlement;
    MonoTime composerStarted;
    long composerUs;
    LatencySnapshot[] samples;
    auto originalService = window.applicationService;
    auto originalPaint = window.afterPaintSubmitted;
    window.applicationService = delegate(double delta)
    {
        originalService(delta);
        if (MonoTime.currTime > deadline) { window.close(); return; }
        if (root.startupPendingForTesting()) return;
        if (submitted && !root.turnBusyForTesting())
        {
            assert(root.lastAssistantContentForTesting() == "firstlast");
            assert(firstPaintBeforeSettlement, "First text was buffered until the stream completed");
            settled = submitted;
        }
        if (settled == 6) { window.close(); return; }
        if (submitted == settled)
        {
            firstPaintBeforeSettlement = false;
            root.newChatForTesting();
            root.setInputForTesting("Reply briefly.");
            composerStarted = MonoTime.currTime;
            root.sendForTesting();
            composerUs = (MonoTime.currTime - composerStarted).total!"usecs";
            ++submitted;
        }
    };
    window.afterPaintSubmitted = delegate()
    {
        originalPaint();
        const trace = root.latencyPaintForTesting();
        if (submitted > painted && trace.microseconds[LatencyStage.paintSubmitted] >= 0 &&
            root.lastAssistantContentForTesting() == "first")
        {
            assert(root.turnBusyForTesting());
            firstPaintBeforeSettlement = true;
            painted = submitted;
            samples ~= trace;
            writeln("MEASURE delivery sample=", submitted,
                " composer_us=", composerUs,
                " submit_to_paint_us=", (MonoTime.currTime - composerStarted).total!"usecs",
                " serialized_us=", trace.microseconds[LatencyStage.serialized],
                " uploaded_us=", trace.microseconds[LatencyStage.uploaded],
                " headers_us=", trace.microseconds[LatencyStage.headers],
                " first_token_us=", trace.microseconds[LatencyStage.firstToken],
                " applied_us=", trace.microseconds[LatencyStage.applied],
                " paint_us=", trace.microseconds[LatencyStage.paintSubmitted]);
        }
    };
    window.run();
    assert(settled == 6 && samples.length == 6, "Delivery benchmark did not finish");
    long[] clientDelays;
    foreach (trace; samples)
    {
        assert(trace.microseconds[LatencyStage.firstToken] >= 0);
        assert(trace.microseconds[LatencyStage.applied] >= trace.microseconds[LatencyStage.firstToken]);
        assert(trace.microseconds[LatencyStage.paintSubmitted] >= trace.microseconds[LatencyStage.applied]);
        clientDelays ~= trace.microseconds[LatencyStage.paintSubmitted] -
            trace.microseconds[LatencyStage.firstToken];
    }
    sort(clientDelays);
    writeln("MEASURE token_to_paint samples=6 median_us=", clientDelays[3],
        " max_us=", clientDelays[$ - 1]);
    writeln("PASS actual native wake, bounded idle pacing and streamed HTTP -> GUI paint before completion");
    return 0;
}

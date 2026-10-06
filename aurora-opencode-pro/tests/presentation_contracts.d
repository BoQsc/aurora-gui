module presentation_contracts;

import aurora;
import auroraopencode.transcriptpresenter;
import core.time : MonoTime;
import std.algorithm : sort;
import std.stdio : writeln;

private final class Counters { int created, measured; }
private final class Row : Widget
{
    Counters counters;
    int ordinal;
    this(Counters counters, int ordinal)
    { this.counters = counters; this.ordinal = ordinal; ++counters.created; }
    protected override Size onMeasure(Size available)
    { ++counters.measured; return Size(available.width, 40 + ordinal % 5 * 10); }
}
private final class Factory
{
    Counters counters;
    int ordinal;
    this(Counters counters, int ordinal) { this.counters = counters; this.ordinal = ordinal; }
    Widget create() { return new Row(counters, ordinal); }
}

int main()
{
    WindowOptions options;
    options.width = 800;
    options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options);
    auto presenter = new TranscriptPresenter(6);
    auto view = new ScrollView(presenter);
    window.setRoot(view);
    auto counters = new Counters();
    foreach (i; 0 .. 10_000)
    {
        auto factory = new Factory(counters, i);
        presenter.add(new DeferredTranscriptRow(&factory.create));
    }
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 3) assert(driver.paint());
    assert(counters.created < 100 && counters.measured < 200,
        "First frame materialized rows outside its viewport");
    foreach (offset; [150_000, 300_000, 450_000, 0])
    {
        view.setScrollY(offset);
        foreach (_; 0 .. 3) assert(driver.paint());
        int materialized;
        foreach (row; presenter.children())
            if ((cast(DeferredTranscriptRow) row).materialized() !is null) ++materialized;
        assert(materialized < 100, "Scrolled history retained offscreen text widgets");
    }
    assert(counters.created < 500, "Scrolling constructed the full 10,000-row history");
    long[] samples;
    foreach (_; 0 .. 100)
    {
        const started = MonoTime.currTime;
        assert(driver.paint());
        samples ~= (MonoTime.currTime - started).total!"usecs";
    }
    samples.sort();
    writeln("PASS 10,000-row viewport construction, variable-height scrolling, eviction; created=",
        counters.created, " cached_paint_median_us=", samples[50], " p95_us=", samples[95]);
    view.setScrollY(view.maxScroll());
    foreach (_; 0 .. 3) assert(driver.paint());
    assert((cast(DeferredTranscriptRow) presenter.children()[$ - 1]).materialized() !is null,
        "Final transcript row was not materialized at the bottom");
    window.close();
    return 0;
}

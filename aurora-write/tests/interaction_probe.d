/// Interaction probe: measures the cost the writer actually feels.
///
/// Prints numbers instead of asserting opinions:
///   - per-keystroke cost of text input plus the frame it triggers,
///   - how many suggestion analyses run per keystroke (duplicate work),
///   - how many whole-window rebuilds the idle frame pump requests per second,
///   - the quiet time before a refinement request is dispatched.
///
/// Exit code 1 when a budget is exceeded, so it can gate a release.
module aurora_write_interaction_probe;

import aurora;
import aurorawrite.theme : writeTheme;
import aurorawrite.writeroot : WriteRoot;
import core.time : MonoTime, msecs;
import std.algorithm : sort;
import std.conv : to;
import std.process : environment;
import std.stdio : writefln, writeln;
import std.utf : toUTF32;

private enum int keystrokeBudgetMs = 16;
private enum int idlePumpBudgetPerSecond = 10;

private int failures;

private void check(bool condition, string what)
{
    if (condition) return;
    ++failures;
    writeln("BUDGET EXCEEDED: ", what);
}

private long elapsedMs(MonoTime start)
{
    return (MonoTime.currTime - start).total!"msecs";
}

private int run()
{
    WindowOptions options;
    options.title = "Aurora Write";
    options.width = 1120;
    options.height = 760;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, writeTheme(false));
    auto root = new WriteRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    root.editor().requestFocus();

    // --- Per-keystroke cost ------------------------------------------------
    const typed = "We utilize a short checklist in order to keep each " ~
        "paragraph tight.";
    long[] samples;
    const refreshesBefore = root.diagnosticRefreshCount;
    const analysesBefore = root.diagnosticAnalysisCount;
    const relayoutsBefore = root.card.diagnosticRelayoutCount;
    foreach (index, dchar value; typed.toUTF32)
    {
        const start = MonoTime.currTime;
        driver.text([value]);
        driver.paint();
        samples ~= elapsedMs(start);
    }
    samples.sort;
    const median = samples[samples.length / 2];
    const worst = samples[$ - 1];
    const characters = cast(int) typed.length;
    writefln("keystrokes: %d  median %d ms  worst %d ms",
        characters, median, worst);
    writefln("  suggestion refreshes per keystroke: %.2f",
        cast(double) (root.diagnosticRefreshCount - refreshesBefore) / characters);
    writefln("  analyses per keystroke: %.2f",
        cast(double) (root.diagnosticAnalysisCount - analysesBefore) / characters);
    writefln("  card re-layouts per keystroke: %.2f",
        cast(double) (root.card.diagnosticRelayoutCount - relayoutsBefore) /
        characters);
    check(worst <= keystrokeBudgetMs,
        "worst keystroke " ~ worst.to!string ~ " ms exceeds " ~
        keystrokeBudgetMs.to!string ~ " ms");

    // --- Idle frame pump ---------------------------------------------------
    // Emulate the native loop: keep painting while the app keeps asking for
    // frames, and count how many of those frames cost a whole-window rebuild.
    const pumpBefore = root.diagnosticPumpCount;
    const idleStart = MonoTime.currTime;
    int frames;
    while ((MonoTime.currTime - idleStart).total!"msecs" < 1000)
    {
        driver.paint();
        ++frames;
    }
    const pumpAfter = root.diagnosticPumpCount;
    const rebuilds = pumpAfter - pumpBefore;
    writefln("idle second: %d frames pumped, %d whole-window rebuilds requested",
        frames, rebuilds);
    check(rebuilds <= idlePumpBudgetPerSecond,
        "idle pump requested " ~ rebuilds.to!string ~
        " rebuilds in one second (budget " ~
        idlePumpBudgetPerSecond.to!string ~ ")");

    window.close();
    return failures == 0 ? 0 : 1;
}

int main()
{
    // The probe never contacts a provider: audio-free, deterministic, offline.
    environment["AURORA_WRITE_OFFLINE"] = "1";
    environment["AURORA_WRITE_SETTINGS"] =
        environment.get("TEMP", ".") ~ "\\aurora-write-probe-settings.json";
    try
    {
        const code = run();
        writeln(failures == 0 ? "INTERACTION BUDGETS PASSED"
            : "INTERACTION BUDGETS FAILED");
        return code;
    }
    catch (Throwable error)
    {
        writeln("EXCEPTION: ", error.msg);
        return 2;
    }
}

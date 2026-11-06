/// Interaction probe: measures the cost the writer actually feels.
///
/// Frames are driven the way the native loop drives them: `onNativeTick` with a
/// real delta, then paint. (`UiTestDriver.paint()` alone never ticks widgets,
/// which is why an earlier test could pass without ever refining anything.)
///
/// Reports:
///   - per-keystroke input handling and frame cost,
///   - suggestion analyses and card re-layouts per keystroke,
///   - how long after the last keystroke the refinement request is dispatched,
///   - whole-window rebuilds requested per second while a refinement is pending
///     (a silent local endpoint keeps the request open for as long as we watch).
///
/// Exit code 1 when a budget is exceeded, so it can gate a release.
module aurora_write_interaction_probe;

import aurora;
import aurorawrite.theme : writeTheme;
import aurorawrite.writeroot : WriteRoot;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : sort;
import std.conv : to;
import std.file : remove, write;
import std.path : buildPath;
import std.process : environment;
import std.socket : AddressFamily, InternetAddress, SocketOption, SocketOptionLevel,
    TcpSocket;
import std.stdio : stderr;
import std.utf : toUTF32;

private enum int keystrokeBudgetMs = 16;
private enum int frameBudgetMs = 16;
/// One-off cost of the first card in a fresh process (glyph/atlas/heap warm-up).
private enum int firstCardBudgetMs = 45;
private enum int idlePumpBudgetPerSecond = 12;
private enum int dispatchBudgetMs = 120;

private int failures;
private MonoTime lastFrame;

private void check(bool condition, string what)
{
    if (condition) return;
    ++failures;
    stderr.writeln("BUDGET EXCEEDED: ", what);
}

private void report(string message)
{
    stderr.writeln(message);
    try
    {
        import std.file : append;
        append("build/probe-log.txt", message ~ "\n");
    }
    catch (Exception) {}
}

private long elapsedMs(MonoTime start)
{
    return (MonoTime.currTime - start).total!"msecs";
}

/// One production frame: tick with the elapsed delta, then paint.
private bool frame(GuiWindow window, UiTestDriver driver)
{
    const now = MonoTime.currTime;
    double delta = 1.0 / 60.0;
    if (lastFrame.ticks != 0)
    {
        delta = cast(double) (now - lastFrame).total!"nsecs" / 1_000_000_000.0;
        if (!(delta > 0.0) || delta > 0.25) delta = 1.0 / 60.0;
    }
    lastFrame = now;
    window.onNativeTick(delta);
    return driver.paint();
}

/// Hold every accepted connection open and never answer, so the app stays in
/// the pending state a slow provider puts it in.
private void acceptForever(TcpSocket listener)
{
    try
    {
        while (true)
        {
            auto connection = listener.accept();
            if (connection is null) break;
        }
    }
    catch (Exception) {}
}

/// Open a silent local endpoint. The socket is captured by the acceptor's
/// closure: a module-level socket would be thread-local storage, so the worker
/// thread would see a null copy (a hard fault, not an exception).
private ushort startSilentEndpoint()
{
    auto listener = new TcpSocket(AddressFamily.INET);
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(8);
    const port = (cast(InternetAddress) listener.localAddress).port;
    auto acceptor = new Thread(delegate() { acceptForever(listener); });
    acceptor.isDaemon = true;
    acceptor.start();
    return port;
}

private GuiWindow openWindow(WindowOptions options, out WriteRoot root,
    out UiTestDriver driver)
{
    auto window = new GuiWindow(options, writeTheme(false));
    root = new WriteRoot(window);
    window.setRoot(root);
    driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    lastFrame = MonoTime.init;
    frame(window, driver);
    root.editor().requestFocus();
    return window;
}

private int run()
{
    WindowOptions options;
    options.title = "Aurora Write";
    options.width = 1120;
    options.height = 760;
    options.renderer = RendererPreference.software;

    // --- Per-keystroke cost ------------------------------------------------
    environment["AURORA_WRITE_OFFLINE"] = "1";
    environment["AURORA_WRITE_SETTINGS"] = buildPath(
        environment.get("TEMP", "."), "aurora-write-probe-settings.json");
    WriteRoot root;
    UiTestDriver driver;
    auto window = openWindow(options, root, driver);

    const typed = "We utilize a short checklist in order to keep each " ~
        "paragraph tight.";
    long[] inputSamples, frameSamples;
    long worstFrame;
    int worstIndex = -1;
    const refreshesBefore = root.diagnosticRefreshCount;
    const analysesBefore = root.diagnosticAnalysisCount;
    const relayoutsBefore = root.card.diagnosticRelayoutCount;
    int keyIndex;
    foreach (dchar value; typed.toUTF32)
    {
        auto start = MonoTime.currTime;
        driver.text([value]);
        inputSamples ~= elapsedMs(start);
        start = MonoTime.currTime;
        frame(window, driver);
        const frameMs = elapsedMs(start);
        frameSamples ~= frameMs;
        if (frameMs > worstFrame) { worstFrame = frameMs; worstIndex = keyIndex; }
        ++keyIndex;
    }
    inputSamples.sort;
    frameSamples.sort;
    const characters = cast(int) typed.length;
    report("keystrokes: " ~ characters.to!string);
    report("  input handling: median " ~
        inputSamples[inputSamples.length / 2].to!string ~ " ms  worst " ~
        inputSamples[$ - 1].to!string ~ " ms");
    report("  frame:          median " ~
        frameSamples[frameSamples.length / 2].to!string ~ " ms  worst " ~
        frameSamples[$ - 1].to!string ~ " ms at keystroke " ~
        worstIndex.to!string);
    const refreshesPerKey = cast(double) (root.diagnosticRefreshCount -
        refreshesBefore) / characters;
    const analysesPerKey = cast(double) (root.diagnosticAnalysisCount -
        analysesBefore) / characters;
    const relayoutsPerKey = cast(double) (root.card.diagnosticRelayoutCount -
        relayoutsBefore) / characters;
    report("  suggestion refreshes per keystroke: " ~ refreshesPerKey.to!string);
    report("  analyses per keystroke: " ~ analysesPerKey.to!string);
    report("  card re-layouts per keystroke: " ~ relayoutsPerKey.to!string);
    check(inputSamples[$ - 1] <= keystrokeBudgetMs,
        "worst input handling " ~ inputSamples[$ - 1].to!string ~ " ms");
    check(analysesPerKey <= 1.05,
        "suggestion analysis runs " ~ analysesPerKey.to!string ~ "x per keystroke");
    check(relayoutsPerKey <= 1.01,
        "card re-lays out " ~ relayoutsPerKey.to!string ~ "x per keystroke");
    // --- Warm passes: same text, then different words ----------------------
    // Distinguishes a one-off process warm-up from a per-card-open cost.
    root.editor().setText("", false);
    root.editor().setCursorIndex(0);
    frame(window, driver);
    const firstWorst = frameSamples[$ - 1];
    const warmWorst = measureTyping(root, driver, window, typed);
    report("warm pass frame: worst " ~ warmWorst.to!string ~ " ms");
    const otherWorst = measureTyping(root, driver, window,
        "We demonstrate the end result and it is very unique here.");
    report("different words frame: worst " ~ otherWorst.to!string ~ " ms");
    check(warmWorst <= frameBudgetMs,
        "warm pass worst frame " ~ warmWorst.to!string ~ " ms");
    check(otherWorst <= frameBudgetMs,
        "new-word worst frame " ~ otherWorst.to!string ~ " ms");
    check(firstWorst <= firstCardBudgetMs,
        "first card " ~ firstWorst.to!string ~ " ms exceeds the one-off budget");
    window.close();

    // --- Pending state: dispatch latency and pump rate ---------------------
    const port = startSilentEndpoint();
    const liveSettings = buildPath(environment.get("TEMP", "."),
        "aurora-write-probe-live.json");
    write(liveSettings, "{\"baseUrl\":\"http://127.0.0.1:" ~ port.to!string ~
        "/v1\",\"model\":\"probe\",\"apiKey\":\"\",\"thinking\":false," ~
        "\"optimizer\":true,\"offline\":false}");
    environment["AURORA_WRITE_OFFLINE"] = "";
    environment["AURORA_WRITE_SETTINGS"] = liveSettings;
    WriteRoot liveRoot;
    UiTestDriver liveDriver;
    auto liveWindow = openWindow(options, liveRoot, liveDriver);
    check(liveRoot.settings().configured() && !liveRoot.settings().offline,
        "probe settings name a provider and are online");

    // Type a finished word plus the space that ends it, then measure how long
    // the app waits before asking the provider.
    const typeStart = MonoTime.currTime;
    foreach (dchar value; "We utilize ".toUTF32)
    {
        liveDriver.text([value]);
        frame(liveWindow, liveDriver);
    }

    long dispatchedAt = -1;
    const waitStart = MonoTime.currTime;
    while (elapsedMs(waitStart) < 3000)
    {
        frame(liveWindow, liveDriver);
        if (liveRoot.statusRightText().length > 0 &&
            liveRoot.statusRightText().indexOfAscii("refining") >= 0)
        {
            dispatchedAt = elapsedMs(typeStart);
            break;
        }
        Thread.sleep(2.msecs);
    }
    report("dispatch after the last keystroke: " ~ dispatchedAt.to!string ~ " ms");
    report("  B state: text='" ~ liveRoot.editor().textUtf8() ~
        "' target='" ~ liveRoot.analysis().target ~ "' cardOpen=" ~
        liveRoot.cardOpen().to!string ~ " refreshes=" ~
        liveRoot.diagnosticRefreshCount.to!string ~ " analyses=" ~
        liveRoot.diagnosticAnalysisCount.to!string ~ " pump=" ~
        liveRoot.diagnosticPumpCount.to!string ~ " status='" ~
        liveRoot.statusRightText() ~ "' focused=" ~
        liveRoot.editor().focused().to!string);
    check(dispatchedAt >= 0 && dispatchedAt <= dispatchBudgetMs,
        "dispatch took " ~ dispatchedAt.to!string ~ " ms (budget " ~
        dispatchBudgetMs.to!string ~ " ms)");

    // The request is pending now. Measure one second of 60 Hz frames and count
    // how many of them request a whole-window rebuild.
    const pumpBefore = liveRoot.diagnosticPumpCount;
    int frames;
    const idleStart = MonoTime.currTime;
    while (elapsedMs(idleStart) < 1000)
    {
        if (frame(liveWindow, liveDriver)) ++frames;
        Thread.sleep(16.msecs);
    }
    const rebuilds = liveRoot.diagnosticPumpCount - pumpBefore;
    report("pending second: " ~ frames.to!string ~ " frames, " ~
        rebuilds.to!string ~ " whole-window rebuilds requested");
    check(rebuilds <= idlePumpBudgetPerSecond,
        "pending pump requested " ~ rebuilds.to!string ~
        " rebuilds in one second (budget " ~
        idlePumpBudgetPerSecond.to!string ~ ")");
    liveWindow.close();
    return failures == 0 ? 0 : 1;
}

/// Type `text` into `root` one character at a time; return the worst frame.
private long measureTyping(WriteRoot root, UiTestDriver driver, GuiWindow window,
    string text)
{
    root.editor().setText("", false);
    root.editor().setCursorIndex(0);
    frame(window, driver);
    long worst;
    foreach (dchar value; text.toUTF32)
    {
        driver.text([value]);
        const start = MonoTime.currTime;
        frame(window, driver);
        const frameMs = elapsedMs(start);
        if (frameMs > worst) worst = frameMs;
    }
    return worst;
}

/// `std.string.indexOf` without pulling in the name.
private ptrdiff_t indexOfAscii(string haystack, string needle) @safe pure nothrow
{
    if (needle.length == 0 || haystack.length < needle.length) return -1;
    for (size_t index = 0; index + needle.length <= haystack.length; ++index)
        if (haystack[index .. index + needle.length] == needle)
            return cast(ptrdiff_t) index;
    return -1;
}

int main()
{
    try remove("build/probe-log.txt");
    catch (Exception) {}
    try
    {
        const code = run();
        report(failures == 0 ? "INTERACTION BUDGETS PASSED"
            : "INTERACTION BUDGETS FAILED");
        return code;
    }
    catch (Throwable error)
    {
        stderr.writeln("EXCEPTION: ", error.msg);
        return 2;
    }
}

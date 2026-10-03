module app;

import aurora;
import auroraiso.appui : IsoRoot;
import auroraiso.iso;
import auroraiso.logging;
import auroraiso.osutil : executablePath, shellExecuteRunAs;
import auroraiso.theme : auroraIsoTheme;
import auroraiso.usb : isProcessElevated, logVolumeProbe, runLockProbe,
    runRawWriteProbe, formatRemainingSpace, writeImageToFile,
    writeIsoLayoutToPhysicalDrive;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import std.stdio : stderr;

private WindowOptions makeOptions()
{
    WindowOptions options;
    options.title = "Aurora ISO";
    options.width = 980;
    options.height = 720;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.automatic;
    return options;
}

/// Where the log lives: `--log <path>`, else beside the executable, else temp.
private string logFilePath(string[] args)
{
    foreach (index, arg; args)
        if (arg == "--log" && index + 1 < args.length)
            return args[index + 1];
    auto beside = executablePath();
    if (beside.length > 0)
        return buildPath(dirName(beside), "aurora-iso.log");
    return buildPath(tempDir(), "aurora-iso.log");
}

/// Headless end-to-end check of the ISO engine and the write streamer.
private int runSelfTest()
{
    logInfo("self-test: start");
    const root = buildPath(tempDir(), "aurora-iso-selftest");
    if (exists(root))
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "in/sub"));
    write(buildPath(root, "in/hello.txt"), "hello world\n");
    auto payload = new ubyte[5000];
    foreach (i; 0 .. payload.length)
        payload[i] = cast(ubyte)((i * 7) & 0xFF);
    write(buildPath(root, "in/sub/data.bin"), payload);

    const isoPath = buildPath(root, "self.iso");
    IsoWriterOptions options;
    options.volumeId = "SELFTEST";
    auto result = createIsoFromDirectory(buildPath(root, "in"), isoPath, options);
    logInfo("self-test: create ok=" ~ result.ok.to!string ~
        " bytes=" ~ result.bytesWritten.to!string);
    if (!result.ok)
    {
        logError("self-test: create failed: " ~ result.error);
        return 1;
    }

    auto image = new IsoImage(isoPath);
    auto nodes = image.rootNodes();
    auto hello = image.readFile("/hello.txt");
    auto data = image.readFile("/sub/data.bin");
    const helloOk = (cast(string) hello) == "hello world\n";
    const dataOk = data == payload;
    logInfo("self-test: rootNodes=" ~ nodes.length.to!string ~
        " helloOk=" ~ helloOk.to!string ~ " dataOk=" ~ dataOk.to!string);

    mkdirRecurse(buildPath(root, "out"));
    auto stats = extractAll(image, buildPath(root, "out"));
    logInfo("self-test: extractedFiles=" ~ stats.files.to!string);

    const target = buildPath(root, "roundtrip.img");
    auto written = writeImageToFile(isoPath, target);
    auto original = cast(ubyte[]) read(isoPath);
    auto copied = cast(ubyte[]) read(target);
    const roundTripOk = original == copied;
    logInfo("self-test: wrote=" ~ written.to!string ~
        " roundTripOk=" ~ roundTripOk.to!string);

    const ok = nodes.length == 2 && helloOk && dataOk &&
        stats.files == 2 && roundTripOk;
    logInfo(ok ? "self-test: PASSED" : "self-test: FAILED");
    image.close();
    return ok ? 0 : 1;
}

private int runScreenshot(string isoPath, string outputPath)
{
    logInfo("screenshot: start " ~ isoPath);
    auto window = new GuiWindow(makeOptions(), auroraIsoTheme());
    auto root = new IsoRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(980, 720));
    driver.paint();
    root.tickTree(0.02);

    if (isoPath.length > 0)
        root.loadIso(isoPath);

    root.tickTree(0.02);
    driver.paint();
    window.saveScreenshot(outputPath);
    if (isoPath.length > 0 && root.imageForTesting() is null)
        logWarn("screenshot: image did not load: " ~ root.statusTextForTesting());
    window.close();
    logInfo("screenshot: done " ~ outputPath);
    return 0;
}

int main(string[] args)
{
    // Log first so every run leaves a trace we can inspect afterwards.
    logInit(logFilePath(args));
    logInfo("main: start args=" ~ args.length.to!string);
    logInfo("main: elevated=" ~ isProcessElevated().to!string);

    if (args.length >= 2 && args[1] == "--selftest")
        return runSelfTest();

    if (args.length >= 2 && args[1] == "--probe")
    {
        logVolumeProbe();
        return 0;
    }

    if (args.length >= 3 && args[1] == "--lock-probe")
    {
        runLockProbe(args[2].to!uint);
        return 0;
    }

    if (args.length >= 3 && args[1] == "--raw-write-probe")
    {
        runRawWriteProbe(args[2].to!uint);
        return 0;
    }

    if (args.length >= 3 && args[1] == "--format-remaining")
    {
        formatRemainingSpace(args[2].to!uint);
        return 0;
    }

    // Experimental from-scratch layout: GPT + FAT32 (ISO contents) + exFAT data
    // partition. Opt-in only; the default install path is still the raw write.
    if (args.length >= 4 && args[1] == "--layout-install")
    {
        auto written = writeIsoLayoutToPhysicalDrive(args[2], args[3].to!uint);
        logInfo("layout-install: wrote " ~ written.to!string ~ " bytes");
        return 0;
    }

    if (args.length >= 4 && args[1] == "--screenshot")
        return runScreenshot(args[2], args[3]);

    // Auto-promote on launch: relaunch elevated (one UAC prompt) so raw USB
    // writing works without the user starting the app as administrator. The
    // "--elevated" marker prevents an elevation loop.
    const bool elevatedRun = args.length > 1 && args[1] == "--elevated";
    if (!elevatedRun && !isProcessElevated())
    {
        string parameters = "--elevated";
        foreach (arg; args[1 .. $])
            parameters ~= " \"" ~ arg ~ "\"";
        const result = shellExecuteRunAs(parameters);
        logInfo("main: elevation request result=" ~ result.to!string);
        if (result > 32)
            return 0; // the elevated copy is taking over
        logWarn("main: continuing unelevated");
    }

    // Elevated relaunch: complete an install that the user already confirmed.
    size_t autoIndex = size_t.max;
    foreach (index, arg; args)
        if (arg == "--auto-install")
            autoIndex = index;
    if (autoIndex != size_t.max && autoIndex + 2 < args.length)
    {
        logInfo("main: auto-install distro=" ~ args[autoIndex + 1] ~
            " disk=" ~ args[autoIndex + 2]);
        auto window = new GuiWindow(makeOptions(), auroraIsoTheme());
        auto root = new IsoRoot(window);
        window.setRoot(root);
        bool makeDataPartition = true;
        if (args.length > autoIndex + 3)
            makeDataPartition = args[autoIndex + 3] != "0";
        bool useFromScratchLayout = false;
        if (args.length > autoIndex + 4)
            useFromScratchLayout = args[autoIndex + 4] != "0";
        root.autoInstall(args[autoIndex + 1].to!int, args[autoIndex + 2].to!uint,
            makeDataPartition, useFromScratchLayout);
        return window.run();
    }

    string openPath;
    foreach (arg; args[1 .. $])
        if (arg.length > 0 && arg[0] != '-')
            openPath = arg;

    auto window = new GuiWindow(makeOptions(), auroraIsoTheme());
    auto root = new IsoRoot(window);
    window.setRoot(root);
    if (openPath.length > 0)
        root.loadIso(openPath);
    return window.run();
}

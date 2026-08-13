module app;

import aurora;
import aurorastream.appversion : appDisplayName, appFullVersion;
import aurorastream.audiobridge : AudioBridgeSession, runAudioBridgeHelper;
import aurorastream.ffmpegbundle : enableBundledFfmpeg;
import aurorastream.pacingdiagnostic : runStreamPacingDiagnostic;
import aurorastream.wasapi : enumerateWasapiRenderEndpoints;
import aurorastream.root : StreamRoot;
import core.thread : Thread;
import core.time : msecs;
import std.file : append, exists, thisExePath;
import std.json : JSONValue;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;

version (Windows)
{
    import core.sys.windows.windows : MB_ICONERROR, MB_OK, MessageBoxW;
    import std.utf : toUTF16z;
}

private void recordStartupFailure(string details)
{
    try append("aurora-stream-startup.log", details ~ "\r\n");
    catch (Exception) {}

    version (Windows)
    {
        try MessageBoxW(null, toUTF16z(details),
            toUTF16z("Aurora Stream startup error"), MB_OK | MB_ICONERROR);
        catch (Throwable) {}
    }
}

private string applicationIconPath()
{
    const local = buildPath("assets", "aurora-stream.ico");
    if (exists(local)) return local;

    try
    {
        const besideExecutable = buildPath(dirName(thisExePath()), "assets",
            "aurora-stream.ico");
        if (exists(besideExecutable)) return besideExecutable;
    }
    catch (Exception)
    {
    }

    return local;
}

private string commandOption(const string[] arguments, string option)
{
    foreach (index; 0 .. arguments.length)
    {
        if (arguments[index] == option && index + 1 < arguments.length)
            return arguments[index + 1];
    }
    return "";
}

private int runAudioBridgeSessionTest(string executablePath,
    const string[] arguments)
{
    bool synthetic;
    foreach (argument; arguments)
        if (argument == "--synthetic") synthetic = true;
    const endpointId = commandOption(arguments, "--endpoint");

    auto bridge = new AudioBridgeSession(executablePath);
    string error;
    if (!bridge.start(endpointId, synthetic, error))
    {
        writeln("status=error");
        writeln("error=", error);
        return 2;
    }

    string handoffError;
    if (!bridge.validateReceiverReservationHandoff(handoffError))
    {
        writeln("status=error");
        writeln("error=", handoffError);
        bridge.shutdown();
        return 2;
    }

    writeln("status=ready");
    writeln("receiver_handoff=verified");
    writeln("rtp_destination_port=", bridge.port);
    writeln("rtcp_destination_port=", bridge.rtcpPort);
    Thread.sleep(3_000.msecs);
    const failure = bridge.failure();
    bridge.shutdown();
    const metrics = bridge.metricsText();
    if (metrics.length > 0) writeln(metrics);
    if (failure.length > 0)
    {
        writeln("status=error");
        writeln("error=", failure);
        return 2;
    }
    writeln("status=complete");
    return 0;
}

private int printAudioEndpointsJson()
{
    string error;
    const endpoints = enumerateWasapiRenderEndpoints(error);
    JSONValue[] encoded;
    foreach (endpoint; endpoints)
    {
        JSONValue item = JSONValue.emptyObject;
        item["label"] = endpoint.label;
        item["id"] = endpoint.inputName;
        item["default"] = endpoint.alternativeName == "default";
        encoded ~= item;
    }

    JSONValue root = JSONValue.emptyObject;
    root["error"] = error;
    root["endpoints"] = encoded;
    writeln(root.toString());
    return endpoints.length > 0 ? 0 : 2;
}

private int runApplication(string executablePath)
{
    WindowOptions options;
    options.title = appDisplayName ~ " — Twitch + YouTube Broadcaster";
    options.iconPath = applicationIconPath();
    options.width = 1280;
    options.height = 780;
    options.resizable = true;
    options.lowLatency = true;
    // Aurora Stream never needs the framework's drag-time host-cursor hiding.
    // Keep the real Windows pointer owned by Windows throughout stream startup.
    options.synchronizedDragPointer = false;
    options.vsync = true;
    options.renderer = RendererPreference.automatic;

    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x121519);
    theme.panelBackground = Color.fromHex(0x1b2026);
    theme.panelElevated = Color.fromHex(0x252c34);
    theme.fieldBackground = Color.fromHex(0x0e1115);
    theme.buttonBackground = Color.fromHex(0x2b333d);
    theme.buttonHover = Color.fromHex(0x37424e);
    theme.buttonPressed = Color.fromHex(0x20262d);
    theme.border = Color.fromHex(0x414b57);
    theme.accent = Color.fromHex(0x5a8ef0);
    theme.selection = Color.fromHex(0x385f9c);
    theme.cornerRadius = 5;
    theme.controlHeight = 36;
    theme.spacing = 7;

    auto window = new GuiWindow(options, theme);
    auto root = new StreamRoot(window, executablePath);
    window.setRoot(root);
    window.onCloseRequested = delegate() {
        root.shutdown();
        return true;
    };
    return window.run();
}

int main(string[] arguments)
{
    // A single-exe build embeds ffmpeg.exe/ffprobe.exe; extract them (first
    // run) and put them first on PATH so every "ffmpeg"/"ffprobe" invocation
    // in this process uses the bundled copies.
    enableBundledFfmpeg();

    // The app links as the Windows GUI subsystem (no console), so a diagnostic
    // command must allocate one for its stdout output.
    if (arguments.length > 1 && isDiagnosticCommand(arguments[1]))
        attachDiagnosticConsole();

    if (arguments.length > 1 &&
        (arguments[1] == "--version" || arguments[1] == "-v"))
    {
        writeln(appFullVersion);
        return 0;
    }
    if (arguments.length > 1 && arguments[1] == "--list-audio-endpoints-json")
        return printAudioEndpointsJson();
    if (arguments.length > 1 && arguments[1] == "--audio-bridge-session-test")
        return runAudioBridgeSessionTest(arguments[0], arguments);
    if (arguments.length > 1 && arguments[1] == "--audio-rtp-helper")
        return runAudioBridgeHelper(arguments);
    if (arguments.length > 1 && arguments[1] == "--pacing-test")
        return runStreamPacingDiagnostic(arguments[0]);

    try return runApplication(arguments[0]);
    catch (Throwable error)
    {
        string details;
        try details = "Aurora Stream could not start.\r\n\r\n" ~ error.toString();
        catch (Throwable) details = "Aurora Stream could not start: " ~ error.msg;
        recordStartupFailure(details);
        return 1;
    }
}

private bool isDiagnosticCommand(string command)
{
    // `--audio-rtp-helper` is deliberately NOT a console-allocating diagnostic
    // command: the broadcaster spawns it with Config.suppressConsole, it
    // communicates only through status/metrics files and UDP, and it never
    // writes to stdout, so allocating a console would pop up a stray command
    // prompt on every Start streaming.
    return command == "--version" || command == "-v" ||
        command == "--list-audio-endpoints-json" ||
        command == "--audio-bridge-session-test" ||
        command == "--pacing-test";
}

private void attachDiagnosticConsole()
{
    version (Windows)
    {
        import core.sys.windows.windows : AllocConsole;
        import core.stdc.stdio : fflush, freopen, stderr, stdin, stdout;
        if (!AllocConsole()) return;
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
        freopen("CONIN$", "r", stdin);
    }
}

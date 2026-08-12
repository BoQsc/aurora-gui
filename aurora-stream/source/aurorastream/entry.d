module aurorastream.entry;

import aurorastream.audiobridge : AudioBridgeSession;
import aurorastream.wasapi : enumerateWasapiRenderEndpoints;
import core.thread : Thread;
import core.time : msecs;
import std.file : append, exists, thisExePath;
import std.json : JSONValue;
import std.path : buildPath, dirName;
import std.stdio : writeln;

version (Windows)
{
    import core.sys.windows.windows : MB_ICONERROR, MB_OK, MessageBoxW;
    import std.utf : toUTF16z;
}

void recordStartupFailure(string details)
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

string applicationIconPath()
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

string commandOption(const string[] arguments, string option)
{
    foreach (index; 0 .. arguments.length)
    {
        if (arguments[index] == option && index + 1 < arguments.length)
            return arguments[index + 1];
    }
    return "";
}

int runAudioBridgeSessionTest(string executablePath, const string[] arguments)
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

int printAudioEndpointsJson()
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

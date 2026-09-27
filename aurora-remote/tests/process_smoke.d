module tests.process_smoke;

import auroraremote.crypto : randomBytes, sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity;
import auroraremote.input : mouseMovePacket;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.exception : enforce;
import std.file : write;
import std.process : environment, spawnProcess, wait;
import std.stdio : writeln;

private int runController(string link)
{
    auto connector = new DirectConnector;
    scope (exit) connector.disconnect();
    connector.connect(link);
    bool connected;
    string status;
    foreach (_; 0 .. 200)
    {
        status = connector.status(connected);
        if (connected) break;
        Thread.sleep(25.msecs);
    }
    enforce(connected, "Controller process did not connect: " ~ status);

    uint revision;
    int width;
    int height;
    ubyte[] rgba;
    foreach (_; 0 .. 240)
    {
        if (connector.frameSnapshot(revision, width, height, rgba)) break;
        Thread.sleep(25.msecs);
    }
    enforce(width >= 640 && height >= 360 &&
        rgba.length == cast(size_t) width * height * 4,
        "Controller process did not receive a complete desktop frame.");
    bool variedPixels;
    const firstRed = rgba[0];
    const firstGreen = rgba[1];
    const firstBlue = rgba[2];
    foreach (offset; 4 .. rgba.length / 4)
    {
        const pixel = offset * 4;
        if (rgba[pixel] != firstRed || rgba[pixel + 1] != firstGreen ||
            rgba[pixel + 2] != firstBlue)
        {
            variedPixels = true;
            break;
        }
    }
    enforce(variedPixels,
        "Controller received a uniform frame instead of desktop pixels.");
    const dumpPath = environment.get("AURORA_FRAME_DUMP", "");
    if (dumpPath.length > 0)
    {
        write(dumpPath, rgba);
        write(dumpPath ~ ".size", width.to!string ~ "x" ~
            height.to!string);
    }
    connector.sendInput(mouseMovePacket(1_234, 56_789));
    Thread.sleep(100.msecs);
    return 0;
}

int main(string[] arguments)
{
    if (arguments.length == 3 && arguments[1] == "--controller")
        return runController(arguments[2]);

    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];

    auto inputMutex = new Mutex;
    bool receivedInput;
    auto host = new DirectHost(delegate(const(ubyte)[] packet)
    {
        synchronized (inputMutex)
            receivedInput = packet == mouseMovePacket(1_234, 56_789);
    });
    scope (exit) host.stop();
    const link = host.start(identity, "127.0.0.1", 0);
    auto process = spawnProcess([arguments[0], "--controller", link]);
    enforce(wait(process) == 0, "Controller process failed.");

    foreach (_; 0 .. 40)
    {
        synchronized (inputMutex)
            if (receivedInput) break;
        Thread.sleep(25.msecs);
    }
    synchronized (inputMutex)
        enforce(receivedInput,
            "Host process did not receive the controller's input packet.");
    writeln("Aurora Remote process smoke passed: separate host/controller processes exchanged video and input");
    return 0;
}

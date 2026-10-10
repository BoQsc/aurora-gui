module tests.process_smoke;

import aurorarustdesk.crypto : randomBytes;
import aurorarustdesk.identity : DeviceIdentity, deviceFingerprint,
    generatePassword, numericIdFromSecret;
import aurorarustdesk.input : mouseMovePacket;
import aurorarustdesk.rendezvous : RendezvousServer;
import aurorarustdesk.session : RustDeskController, RustDeskHost;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.exception : enforce;
import std.process : spawnProcess, wait;
import std.stdio : writeln;

private int runController(string host, string port, string id, string password)
{
    auto connector = new RustDeskController;
    scope (exit) connector.disconnect();
    connector.connect(host, to!ushort(port), id, password);
    bool connected;
    string status;
    foreach (_; 0 .. 300)
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
    foreach (_; 0 .. 300)
    {
        if (connector.frameSnapshot(revision, width, height, rgba)) break;
        Thread.sleep(25.msecs);
    }
    enforce(width >= 640 && height >= 360 &&
        rgba.length == cast(size_t) width * height * 4,
        "Controller process received no complete desktop frame.");
    connector.sendInput(mouseMovePacket(1_234, 56_789));
    Thread.sleep(150.msecs);
    return 0;
}

int main(string[] arguments)
{
    if (arguments.length == 6 && arguments[1] == "--controller")
        return runController(arguments[2], arguments[3], arguments[4],
            arguments[5]);

    const secret = randomBytes(32);
    DeviceIdentity identity;
    identity.secret[] = secret[];
    identity.id = deviceFingerprint(secret);
    identity.numericId = numericIdFromSecret(secret);
    const password = generatePassword();

    auto server = new RendezvousServer;
    const idPort = server.start(0, 0);
    scope (exit) server.stop();

    auto inputMutex = new Mutex;
    bool receivedInput;
    auto host = new RustDeskHost(delegate(const(ubyte)[] packet)
    {
        synchronized (inputMutex)
            receivedInput = packet == mouseMovePacket(1_234, 56_789);
    });
    scope (exit) host.stop();
    host.startRendezvous(identity, "127.0.0.1", idPort, 0, password, false);

    auto child = spawnProcess([arguments[0], "--controller", "127.0.0.1",
        to!string(idPort), identity.numericId, password]);
    enforce(wait(child) == 0, "Controller process failed.");

    foreach (_; 0 .. 60)
    {
        synchronized (inputMutex) if (receivedInput) break;
        Thread.sleep(25.msecs);
    }
    synchronized (inputMutex)
        enforce(receivedInput,
            "Host process did not receive the controller's input packet.");
    writeln("Aurora RustDesk process smoke passed: separate host/controller processes exchanged video and input over the ID server");
    return 0;
}

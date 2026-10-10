module tests.session_smoke;

import aurorarustdesk.crypto : randomBytes;
import aurorarustdesk.identity : DeviceIdentity, deviceFingerprint,
    generatePassword, numericIdFromSecret;
import aurorarustdesk.input : mouseMovePacket;
import aurorarustdesk.rendezvous : RendezvousServer;
import aurorarustdesk.session : RustDeskController, RustDeskHost;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.exception : enforce;
import std.stdio : stderr, writeln;
import std.string : startsWith;

private void mark(string value)
{
    stderr.writeln(value);
    stderr.flush();
}

private DeviceIdentity makeIdentity()
{
    const secret = randomBytes(32);
    DeviceIdentity identity;
    identity.secret[] = secret[];
    identity.id = deviceFingerprint(secret);
    identity.numericId = numericIdFromSecret(secret);
    return identity;
}

int main()
{
    mark("stage: begin");
    auto server = new RendezvousServer;
    const idPort = server.start(0, 0);
    scope (exit) server.stop();
    mark("stage: server");

    const identity = makeIdentity();
    const password = generatePassword();

    auto inputMutex = new Mutex;
    ubyte[] receivedInput;
    auto host = new RustDeskHost(delegate(const(ubyte)[] packet)
    {
        synchronized (inputMutex) receivedInput = packet.dup;
    });
    auto connector = new RustDeskController;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }

    host.startRendezvous(identity, "127.0.0.1", idPort, 0, password, false);
    mark("stage: host started");
    connector.connect("127.0.0.1", idPort, identity.numericId, password);
    mark("stage: connect called");
    bool connected;
    string status;
    foreach (_; 0 .. 240)
    {
        status = connector.status(connected);
        if (connected) break;
        Thread.sleep(25.msecs);
    }
    enforce(connected, "Rendezvous session did not connect: " ~ status);
    mark("stage: connected");

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
        "Rendezvous session delivered no complete desktop frame.");
    mark("stage: frame");

    const expectedInput = mouseMovePacket(12_345, 54_321);
    connector.sendInput(expectedInput);
    bool arrived;
    foreach (_; 0 .. 80)
    {
        synchronized (inputMutex) arrived = receivedInput == expectedInput;
        if (arrived) break;
        Thread.sleep(25.msecs);
    }
    enforce(arrived, "Remote input did not reach the host.");
    mark("stage: input");

    connector.disconnect();
    connector.connect("127.0.0.1", idPort, identity.numericId,
        "definitely-wrong");
    bool badConnected;
    string badStatus;
    foreach (_; 0 .. 200)
    {
        badStatus = connector.status(badConnected);
        if (!badConnected && badStatus.startsWith("Connection failed:")) break;
        Thread.sleep(25.msecs);
    }
    enforce(!badConnected && badStatus.startsWith("Connection failed:"),
        "A wrong password was not rejected: " ~ badStatus);
    mark("stage: wrong-password rejected");

    writeln("Aurora RustDesk session smoke passed: resolve ID, handshake, frame, input, reject wrong password");
    return 0;
}

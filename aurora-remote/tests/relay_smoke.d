module tests.relay_smoke;

import auroraremote.crypto : randomBytes, sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity;
import auroraremote.input : mouseMovePacket;
import auroraremote.relay : RelayServer;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.exception : enforce;
import std.stdio : writeln;

int main()
{
    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];

    auto relay = new RelayServer;
    const relayPort = relay.start(0);
    scope (exit) relay.stop();

    auto inputMutex = new Mutex;
    bool receivedInput;
    const expectedInput = mouseMovePacket(22_222, 44_444);
    auto host = new DirectHost(delegate(const(ubyte)[] packet)
    {
        synchronized (inputMutex) receivedInput = packet == expectedInput;
    });
    auto connector = new DirectConnector;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }

    const link = host.startRelay(identity, "127.0.0.1", relayPort);
    connector.connect(link);
    bool connected;
    string status;
    foreach (_; 0 .. 240)
    {
        status = connector.status(connected);
        if (connected) break;
        Thread.sleep(25.msecs);
    }
    enforce(connected, "Relayed connection did not establish: " ~ status);

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
        "Relayed connection delivered no complete desktop frame.");
    connector.sendInput(expectedInput);
    foreach (_; 0 .. 80)
    {
        synchronized (inputMutex) if (receivedInput) break;
        Thread.sleep(25.msecs);
    }
    synchronized (inputMutex)
        enforce(receivedInput, "Relayed input did not reach the host.");
    connector.disconnect();
    host.stop();
    relay.stop();
    writeln("Aurora Remote relay smoke passed: paired, authenticated, video and input exchanged");
    return 0;
}

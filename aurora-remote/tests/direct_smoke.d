module tests.direct_smoke;

import auroraremote.crypto : randomBytes, sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity;
import auroraremote.input : mouseMovePacket;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.exception : enforce;
import std.stdio : stderr, writeln;

private void waitForConnection(DirectConnector connector)
{
    bool connected;
    string status;
    foreach (_; 0 .. 200)
    {
        status = connector.status(connected);
        if (connected) return;
        Thread.sleep(25.msecs);
    }
    enforce(false, "Loopback connection did not establish: " ~ status);
}

private void waitForFrame(DirectConnector connector, ref uint revision)
{
    int width;
    int height;
    ubyte[] rgba;
    foreach (_; 0 .. 240)
    {
        if (connector.frameSnapshot(revision, width, height, rgba))
        {
            enforce(width >= 640 && height >= 360 &&
                rgba.length == cast(size_t) width * height * 4,
                "Desktop frame has unexpected dimensions.");
            return;
        }
        Thread.sleep(25.msecs);
    }
    enforce(false, "Encrypted loopback delivered no desktop frame.");
}

int main()
{
    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];

    auto inputMutex = new Mutex;
    ubyte[] receivedInput;
    auto host = new DirectHost(delegate(const(ubyte)[] packet)
    {
        synchronized (inputMutex) receivedInput = packet.dup;
    });
    auto connector = new DirectConnector;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }

    const cancelledCode = host.start(identity, "127.0.0.1", 0);
    connector.connect(cancelledCode);
    connector.disconnect();
    bool cancelledConnected;
    enforce(connector.status(cancelledConnected) == "Idle" &&
        !cancelledConnected,
        "Immediate cancellation did not leave the connector idle.");

    uint revision;
    foreach (attempt; 0 .. 2)
    {
        stderr.writeln("direct smoke attempt ", attempt + 1, ": start");
        const code = host.start(identity, "127.0.0.1", 0);
        stderr.writeln("direct smoke attempt ", attempt + 1, ": connect");
        connector.connect(code);
        waitForConnection(connector);
        stderr.writeln("direct smoke attempt ", attempt + 1, ": frame");
        waitForFrame(connector, revision);
        const expectedInput = mouseMovePacket(12_345, 54_321);
        synchronized (inputMutex) receivedInput = null;
        connector.sendInput(expectedInput);
        bool inputArrived;
        foreach (_; 0 .. 80)
        {
            synchronized (inputMutex)
                inputArrived = receivedInput == expectedInput;
            if (inputArrived) break;
            Thread.sleep(25.msecs);
        }
        enforce(inputArrived,
            "Encrypted remote-input packet did not reach the host.");
        stderr.writeln("direct smoke attempt ", attempt + 1, ": disconnect");
        connector.disconnect();
        stderr.writeln("direct smoke attempt ", attempt + 1, ": done");
    }
    writeln("Aurora Remote direct smoke passed: connect, frame, disconnect, reconnect, frame");
    return 0;
}

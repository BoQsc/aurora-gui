module tests.unattended_smoke;

import auroraremote.capsule : AccessPermission, decodeConnectionCapsule;
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

private void waitConnected(DirectConnector connector)
{
    bool connected;
    string status;
    foreach (_; 0 .. 240)
    {
        status = connector.status(connected);
        if (connected) return;
        Thread.sleep(25.msecs);
    }
    enforce(false, "Persistent connection failed: " ~ status);
}

int main()
{
    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];
    const token = randomBytes(32);
    auto relay = new RelayServer;
    const relayPort = relay.start(0);
    scope (exit) relay.stop();

    auto inputMutex = new Mutex;
    bool inputReceived;
    auto host = new DirectHost(delegate(const(ubyte)[])
    {
        synchronized (inputMutex) inputReceived = true;
    });
    auto connector = new DirectConnector;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }

    const permissions = cast(uint) AccessPermission.view;
    const savedLink = host.startRelay(identity, "127.0.0.1", relayPort,
        true, token, permissions);
    const capsule = decodeConnectionCapsule(savedLink);
    enforce(capsule.persistent && !capsule.expired(),
        "Persistent key decoded as expiring.");
    connector.connect(savedLink);
    waitConnected(connector);
    connector.sendInput(mouseMovePacket(1, 2));
    Thread.sleep(100.msecs);
    synchronized (inputMutex)
        enforce(!inputReceived, "View-only key delivered remote input.");

    connector.disconnect();
    host.stop();
    const restartedLink = host.startRelay(identity, "127.0.0.1", relayPort,
        true, token, permissions);
    enforce(restartedLink == savedLink,
        "Persistent key changed across host restart.");
    connector.connect(savedLink);
    waitConnected(connector);
    writeln("Aurora Remote unattended smoke passed: stable restart key and view-only permission enforcement");
    return 0;
}

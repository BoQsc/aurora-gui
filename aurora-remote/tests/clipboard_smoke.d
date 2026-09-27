module tests.clipboard_smoke;

import auroraremote.crypto : randomBytes, sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity;
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

    auto mutex = new Mutex;
    string hostReceived;
    string controllerReceived;
    auto host = new DirectHost(null, "",
        delegate string() { return "clipboard from host"; },
        delegate void(string value)
        {
            synchronized (mutex) hostReceived = value;
        });
    auto connector = new DirectConnector("",
        delegate string() { return "clipboard from controller"; },
        delegate void(string value)
        {
            synchronized (mutex) controllerReceived = value;
        });
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }
    connector.connect(host.start(identity, "127.0.0.1", 0));
    bool connected;
    foreach (_; 0 .. 200)
    {
        connector.status(connected);
        if (connected) break;
        Thread.sleep(25.msecs);
    }
    enforce(connected, "Clipboard test did not connect.");

    connector.sendClipboard();
    connector.requestClipboard();
    foreach (_; 0 .. 120)
    {
        bool complete;
        synchronized (mutex)
            complete = hostReceived == "clipboard from controller" &&
                controllerReceived == "clipboard from host";
        if (complete) break;
        Thread.sleep(25.msecs);
    }
    synchronized (mutex)
    {
        enforce(hostReceived == "clipboard from controller",
            "Controller clipboard did not reach host.");
        enforce(controllerReceived == "clipboard from host",
            "Host clipboard did not reach controller.");
    }
    writeln("Aurora Remote clipboard smoke passed: explicit send and request in both directions");
    return 0;
}

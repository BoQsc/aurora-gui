module tests.transfer_smoke;

import auroraremote.crypto : randomBytes, sha256;
import auroraremote.direct : DirectConnector, DirectHost;
import auroraremote.identity : DeviceIdentity;
import core.thread : Thread;
import core.time : msecs;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.uuid : randomUUID;

int main()
{
    const workspace = buildPath(tempDir(),
        "aurora-remote-transfer-" ~ randomUUID().toString());
    const source = buildPath(workspace, "source-folder");
    const nested = buildPath(source, "nested");
    const received = buildPath(workspace, "received");
    mkdirRecurse(nested);
    mkdirRecurse(received);
    scope (exit) if (exists(workspace)) rmdirRecurse(workspace);

    ubyte[] large = new ubyte[700_000];
    foreach (index, ref value; large) value = cast(ubyte)(index * 31);
    write(buildPath(nested, "payload.bin"), large);
    write(buildPath(source, "empty.txt"), cast(const(ubyte)[]) []);

    DeviceIdentity identity;
    identity.secret[] = randomBytes(identity.secret.length);
    const digest = sha256(identity.secret[]);
    identity.id[] = digest[0 .. identity.id.length];

    auto host = new DirectHost(null, received);
    auto connector = new DirectConnector;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }
    const link = host.start(identity, "127.0.0.1", 0);
    connector.connect(link);
    bool connected;
    foreach (_; 0 .. 200)
    {
        connector.status(connected);
        if (connected) break;
        Thread.sleep(25.msecs);
    }
    enforce(connected, "File-transfer test did not connect.");
    connector.sendPaths([source]);

    const receivedLarge = buildPath(received, "source-folder", "nested",
        "payload.bin");
    const receivedEmpty = buildPath(received, "source-folder", "empty.txt");
    foreach (_; 0 .. 400)
    {
        if (exists(receivedLarge) && exists(receivedEmpty) &&
            read(receivedLarge) == large)
            break;
        Thread.sleep(25.msecs);
    }
    enforce(exists(receivedLarge) && read(receivedLarge) == large,
        "Chunked folder payload did not arrive intact.");
    enforce(exists(receivedEmpty) && read(receivedEmpty).length == 0,
        "Empty file did not arrive intact.");
    writeln("Aurora Remote transfer smoke passed: nested folder, 700 KB chunked file, empty file");
    return 0;
}

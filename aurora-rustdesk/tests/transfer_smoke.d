module tests.transfer_smoke;

import aurorarustdesk.crypto : randomBytes;
import aurorarustdesk.identity : DeviceIdentity, deviceFingerprint,
    generatePassword, numericIdFromSecret;
import aurorarustdesk.rendezvous : RendezvousServer;
import aurorarustdesk.session : RustDeskController, RustDeskHost;
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
        "aurora-rustdesk-transfer-" ~ randomUUID().toString());
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

    const secret = randomBytes(32);
    DeviceIdentity identity;
    identity.secret[] = secret[];
    identity.id = deviceFingerprint(secret);
    identity.numericId = numericIdFromSecret(secret);
    const password = generatePassword();

    auto server = new RendezvousServer;
    const idPort = server.start(0, 0);
    scope (exit) server.stop();

    auto host = new RustDeskHost(null, received);
    auto connector = new RustDeskController;
    scope (exit)
    {
        connector.disconnect();
        host.stop();
    }
    host.startRendezvous(identity, "127.0.0.1", idPort, 0, password, false);
    connector.connect("127.0.0.1", idPort, identity.numericId, password);
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
    writeln("Aurora RustDesk transfer smoke passed: nested folder, 700 KB chunked file, empty file");
    return 0;
}

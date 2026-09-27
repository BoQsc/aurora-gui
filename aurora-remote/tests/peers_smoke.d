module tests.peers_smoke;

import auroraremote.capsule : encodeConnectionCapsule,
    newPersistentConnectionCapsule;
import auroraremote.crypto : randomBytes;
import auroraremote.peers : loadSavedPeers, rememberPeer;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.uuid : randomUUID;

int main()
{
    const previous = environment.get("LOCALAPPDATA", "");
    const workspace = buildPath(tempDir(),
        "aurora-remote-peers-" ~ randomUUID().toString());
    mkdirRecurse(workspace);
    environment["LOCALAPPDATA"] = workspace;
    scope (exit)
    {
        if (previous.length > 0) environment["LOCALAPPDATA"] = previous;
        else environment.remove("LOCALAPPDATA");
        if (exists(workspace)) rmdirRecurse(workspace);
    }

    ubyte[16] firstDevice;
    firstDevice[] = randomBytes(firstDevice.length);
    const first = encodeConnectionCapsule(newPersistentConnectionCapsule(
        "relay.example.test", 47_832, firstDevice[], randomBytes(32)));
    rememberPeer(first);
    rememberPeer(first);
    auto peers = loadSavedPeers();
    assert(peers.length == 1 && peers[0].link == first);

    ubyte[16] secondDevice;
    secondDevice[] = randomBytes(secondDevice.length);
    const second = encodeConnectionCapsule(newPersistentConnectionCapsule(
        "relay.example.test", 47_832, secondDevice[], randomBytes(32)));
    rememberPeer(second);
    peers = loadSavedPeers();
    assert(peers.length == 2 && peers[0].link == second);
    writeln("Aurora Remote saved-peer smoke passed: DPAPI storage, deduplication, recency");
    return 0;
}

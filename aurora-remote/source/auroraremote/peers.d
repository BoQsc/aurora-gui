module auroraremote.peers;

import auroraremote.capsule : decodeConnectionCapsule, deviceIdText;
import auroraremote.identity : identityFolder, protectForCurrentUser,
    unprotectForCurrentUser;
import std.base64 : Base64;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.string : join, split, strip;

struct SavedPeer
{
    string device;
    long lastUsedUnix;
    string link;
}

private string savedPeersPath()
{
    return buildPath(identityFolder(), "saved-peers.dat");
}

SavedPeer[] loadSavedPeers()
{
    const path = savedPeersPath();
    if (!exists(path)) return null;
    ubyte[] plain;
    try plain = unprotectForCurrentUser(Base64.decode(strip(readText(path))));
    catch (Exception) return null;
    SavedPeer[] result;
    foreach (line; (cast(string) plain).split('\n'))
    {
        if (line.length == 0) continue;
        const fields = line.split('\t');
        if (fields.length != 3) continue;
        try result ~= SavedPeer(fields[0], to!long(fields[1]), fields[2]);
        catch (Exception) continue;
    }
    return result;
}

void rememberPeer(string link)
{
    const capsule = decodeConnectionCapsule(link);
    const device = deviceIdText(capsule.deviceId[]);
    auto peers = loadSavedPeers();
    SavedPeer[] updated;
    updated ~= SavedPeer(device, Clock.currTime.toUnixTime(), link);
    foreach (peer; peers)
        if (peer.device != device && updated.length < 20) updated ~= peer;
    string[] lines;
    foreach (peer; updated)
        lines ~= peer.device ~ "\t" ~ to!string(peer.lastUsedUnix) ~ "\t" ~
            peer.link;
    mkdirRecurse(identityFolder());
    const plain = cast(const(ubyte)[]) (lines.join("\n") ~ "\n");
    write(savedPeersPath(), Base64.encode(protectForCurrentUser(plain)) ~ "\n");
}

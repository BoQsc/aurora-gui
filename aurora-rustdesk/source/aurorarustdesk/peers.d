module aurorarustdesk.peers;

import aurorarustdesk.identity : identityFolder, protectForCurrentUser,
    unprotectForCurrentUser;
import std.base64 : Base64;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.string : join, split, strip;

struct SavedPeer
{
    string id;
    string name;
    long lastUsedUnix;
}

private string savedPeersPath()
{
    return buildPath(identityFolder(), "recent-ids.dat");
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
        try result ~= SavedPeer(fields[0], fields[1], to!long(fields[2]));
        catch (Exception) continue;
    }
    return result;
}

void rememberPeer(string id, string name = "")
{
    if (id.length == 0) return;
    auto peers = loadSavedPeers();
    SavedPeer[] updated;
    updated ~= SavedPeer(id, name, Clock.currTime.toUnixTime());
    foreach (peer; peers)
        if (peer.id != id && updated.length < 20)
            updated ~= SavedPeer(peer.id, peer.name, peer.lastUsedUnix);
    string[] lines;
    foreach (peer; updated)
        lines ~= peer.id ~ "\t" ~ peer.name ~ "\t" ~ to!string(peer.lastUsedUnix);
    mkdirRecurse(identityFolder());
    const plain = cast(const(ubyte)[]) (lines.join("\n") ~ "\n");
    write(savedPeersPath(), Base64.encode(protectForCurrentUser(plain)) ~ "\n");
}

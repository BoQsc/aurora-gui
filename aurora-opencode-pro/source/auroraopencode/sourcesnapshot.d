module auroraopencode.sourcesnapshot;

import core.time : MonoTime, msecs;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : exists, isFile, isSymlink, getSize, read, timeLastModified;
import std.path : buildNormalizedPath, dirName;
import std.regex : matchAll, matchFirst;
import std.string : splitLines, startsWith, toLower, replace;
import std.conv : to;

enum sourceSnapshotPrefix = "Source snapshot SHA256: ";
enum sourceSnapshotMaxBytes = 1024 * 1024;

string sourceContentHash(string source) { return sha256Of(source).toHexString().idup; }

private string snapshotText(string path, MonoTime deadline, out bool valid)
{
    try
    {
        if (MonoTime.currTime >= deadline || !exists(path) || !isFile(path) || isSymlink(path)) return "";
        const size = getSize(path); const modified = timeLastModified(path);
        if (size > sourceSnapshotMaxBytes) return "";
        auto bytes = cast(string)read(path);
        if (MonoTime.currTime >= deadline || bytes.length != size || getSize(path) != size || timeLastModified(path) != modified) return "";
        valid = true;
        return bytes;
    }
    catch (Exception) { return ""; }
}

string sourceSnapshotHash(string output)
{
    string hash;
    foreach (m; matchAll(output, `(?m)^Source snapshot SHA256: ([0-9A-F]{64})\r?$`)) hash = m[1];
    return hash;
}

/// Optional native byte identity, not behavioral verification. Compare every
/// returned line to the same byte snapshot before attaching its whole-file hash.
/// Failure/size/time pressure simply omits the cache metadata; tools still work.
string sourceReadStamp(string path, string output)
{
    try
    {
    bool valid;
    const source = snapshotText(path, MonoTime.currTime + 50.msecs, valid);
    if (!valid || !source.length) return "";
    const lines = source.splitLines();
    bool observed;
    foreach (line; output.splitLines())
    {
        const m = matchFirst(line, `^([0-9]+): (.*)$`);
        if (!m.length) continue;
        size_t number;
        try { number = to!size_t(m[1]); } catch (Exception) { return ""; }
        if (!number || number > lines.length || m[2] != lines[number - 1]) return "";
        observed = true;
    }
    return observed ? "\n" ~ sourceSnapshotPrefix ~ sourceContentHash(source) ~ "\n" : "";
    }
    catch (Exception) { return ""; }
}

/// Validate a known source resource after unrelated/unknown workspace effects.
/// Never certify another checkout or follow a symlink. Whole workspace/check
/// verification remains conservative and independent of this source-only cache.
bool sourceSnapshotCurrent(string path, string hash, string workspace, MonoTime deadline)
{
    if (!hash.length || !workspace.length) return false;
    auto root = buildNormalizedPath(workspace).replace("\\", "/");
    auto target = buildNormalizedPath(path).replace("\\", "/");
    version (Windows) { root = root.toLower(); target = target.toLower(); }
    while (root.length && root[$-1] == '/') root = root[0..$-1];
    if (!target.startsWith(root ~ "/")) return false;
    try
    {
        auto parent = path;
        while (parent.length)
        {
            if (MonoTime.currTime >= deadline || isSymlink(parent)) return false;
            auto normalized = buildNormalizedPath(parent).replace("\\", "/");
            version (Windows) normalized = normalized.toLower();
            if (normalized == root) break;
            const next = dirName(parent); if (next == parent) return false; parent = next;
        }
        bool valid;
        const source = snapshotText(path, deadline, valid);
        return valid && sourceContentHash(source) == hash;
    }
    catch (Exception) { return false; }
}

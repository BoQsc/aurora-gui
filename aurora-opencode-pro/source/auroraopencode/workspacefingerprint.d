module auroraopencode.workspacefingerprint;

import core.time : Duration, MonoTime, msecs;
import std.algorithm : sort;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256;
import std.file : dirEntries, exists, getSize, isDir, isSymlink, SpanMode, timeLastModified;
import std.path : buildNormalizedPath;
import std.stdio : File;

enum workspaceSnapshotMaxBytes = 16UL * 1024 * 1024;
enum workspaceSnapshotMaxFiles = 512;
enum workspaceSnapshotMaxDirectories = 128;

/// An empty result means unknown, never unchanged. Include every file and empty
/// directory, without ignore rules or symlink traversal. The soft deadline is
/// checked between OS operations; one OS call may exceed it.
string workspaceFingerprint(string root, bool delegate() cancelled = null,
    Duration budget = 200.msecs)
{
    const deadline = MonoTime.currTime + budget;
    bool interrupted() { return MonoTime.currTime >= deadline || (cancelled !is null && cancelled()); }
    try
    {
        root = buildNormalizedPath(root);
        if (interrupted() || !exists(root) || !isDir(root) || isSymlink(root)) return "";
        string[] files, directories;
        ulong bytes;
        bool discover(string directory, size_t depth)
        {
            if (interrupted() || depth > 32 || directories.length >= workspaceSnapshotMaxDirectories) return false;
            directories ~= directory;
            foreach(entry; dirEntries(directory, SpanMode.shallow))
            {
                if (interrupted() || entry.isSymlink) return false;
                if (entry.isDir)
                {
                    if (!discover(entry.name, depth + 1)) return false;
                }
                else if (entry.isFile)
                {
                    if (files.length >= workspaceSnapshotMaxFiles || entry.size > workspaceSnapshotMaxBytes - bytes) return false;
                    bytes += entry.size; files ~= entry.name;
                }
                else return false;
            }
            return true;
        }
        if (!discover(root, 0)) return "";
        directories.sort(); files.sort();
        SHA256 digest;
        void put(string value) { digest.put(cast(const(ubyte)[]) value); digest.put(cast(const(ubyte)[]) "\0"); }
        foreach(directory; directories) { if (interrupted()) return ""; put("directory"); put(directory[root.length .. $]); }
        auto buffer = new ubyte[64 * 1024];
        ulong readBytes;
        foreach(path; files)
        {
            if (interrupted()) return "";
            const size = getSize(path); const modified = timeLastModified(path);
            if (size > workspaceSnapshotMaxBytes - readBytes) return "";
            put("file"); put(path[root.length .. $]); put(to!string(size));
            auto file = File(path, "rb"); scope(exit) file.close();
            ulong consumed;
            while (!file.eof())
            {
                if (interrupted()) return "";
                const chunk = file.rawRead(buffer);
                if (chunk.length > workspaceSnapshotMaxBytes - readBytes) return "";
                consumed += chunk.length; readBytes += chunk.length; digest.put(chunk);
            }
            if (consumed != size || getSize(path) != size || timeLastModified(path) != modified) return "";
            put("");
        }
        if (interrupted()) return "";
        return digest.finish().toHexString().idup;
    }
    catch(Exception) { return ""; }
}

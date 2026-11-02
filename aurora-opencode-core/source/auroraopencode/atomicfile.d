module auroraopencode.atomicfile;

import std.file : write, readText, exists, remove, rename;
import std.path : absolutePath, buildNormalizedPath;
import std.string : toLower;
import core.sync.mutex : Mutex;

private __gshared Mutex mutex;
private __gshared ulong[string] protectedBackups;
private __gshared ulong sequence;
shared static this() { mutex = new Mutex(); }
private string identity(string path)
{
    auto result = buildNormalizedPath(absolutePath(path));
    version (Windows) result = result.toLower();
    return result;
}
/// A loader recovered from this backup. Until a replacement primary installs,
/// backing up its corrupt predecessor would destroy the remaining good copy.
public void preserveBackupOnNextWrite(string path)
{ synchronized (mutex) protectedBackups[identity(path)] = ++sequence; }

/// A single storage owner replaces the primary atomically and retains its
/// previous whole value. A failed backup never removes the live primary.
public void writeFileAtomically(string path, string contents)
{
    const temporary = path ~ ".tmp";
    const key = identity(path); ulong protection;
    synchronized (mutex) if (auto saved = key in protectedBackups) protection = *saved;
    write(temporary, contents);
    if (!protection && exists(path))
        try
        {
            const backup = path ~ ".bak";
            if (exists(backup)) remove(backup);
            write(backup, readText(path));
        }
        catch (Exception) {}
    rename(temporary, path);
    synchronized (mutex) if (auto saved = key in protectedBackups)
        if (*saved == protection) protectedBackups.remove(key);
}

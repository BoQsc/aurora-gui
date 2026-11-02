module auroraopencode.attachmentstore;

import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : exists, mkdirRecurse, readText, rename, remove, isFile, isSymlink, getSize, FileException;
import std.json : JSONValue, JSONType;
import std.path : buildPath, buildNormalizedPath, absolutePath;
import std.stdio : File;
import std.string : toLower;
import std.conv : to;
import std.datetime : Clock;
import std.process : thisProcessID;
import core.sync.mutex : Mutex;
import auroraopencode.logging : logError;

private void installAttachment(string temporary, string target)
{
    version (Windows)
    {
        import core.sys.windows.windows : MoveFileW, GetLastError;
        import std.utf : toUTF16z;
        if (!MoveFileW(toUTF16z(temporary), toUTF16z(target)))
            throw new FileException(target, GetLastError());
    }
    else version (Posix)
    {
        import core.sys.posix.unistd : link;
        import core.stdc.errno : errno;
        import std.string : toStringz;
        if (link(toStringz(temporary), toStringz(target)) != 0)
            throw new FileException(target, cast(uint) errno);
    }
    else rename(temporary, target);
}

private string readAttachment(string path)
{
    version (Windows)
    {
        import core.sys.windows.windows : CreateFileW, GetLastError, CloseHandle,
            GetFileSizeEx, ReadFile, INVALID_HANDLE_VALUE, GENERIC_READ,
            FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, FILE_FLAG_SEQUENTIAL_SCAN, LARGE_INTEGER, DWORD;
        import std.utf : toUTF16z, validate;
        auto handle = CreateFileW(toUTF16z(path), GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, null);
        if (handle == INVALID_HANDLE_VALUE) throw new FileException(path, GetLastError());
        scope (exit) CloseHandle(handle);
        LARGE_INTEGER length;
        if (!GetFileSizeEx(handle, &length)) throw new FileException(path, GetLastError());
        if (length.QuadPart < 0 || cast(ulong) length.QuadPart > size_t.max)
            throw new FileException(path, "Attachment exceeds the addressable size");
        auto data = new ubyte[cast(size_t) length.QuadPart];
        size_t offset;
        while (offset < data.length)
        {
            const chunk = data.length - offset > 1024 * 1024 ? 1024 * 1024 : data.length - offset;
            DWORD count;
            if (!ReadFile(handle, data.ptr + offset, cast(DWORD) chunk, &count, null))
                throw new FileException(path, GetLastError());
            if (!count) throw new FileException(path, "Attachment changed while reading");
            offset += count;
        }
        auto text = cast(string) data; validate(text); return text;
    }
    else return readText(path);
}

private final class LiveAttachments
{
    bool[string] pins;
    bool saturated;
}
private __gshared Mutex attachmentMutex;
private __gshared LiveAttachments[string] liveDirectories;
private __gshared ulong temporarySequence;
shared static this() { attachmentMutex = new Mutex(); }

private LiveAttachments liveAttachments(string directory)
{
    auto key = buildNormalizedPath(absolutePath(directory));
    version (Windows) key = key.toLower();
    auto found = key in liveDirectories;
    if (found !is null) return *found;
    auto live = new LiveAttachments();
    liveDirectories[key] = live;
    return live;
}

public bool validAttachmentDigest(string digest)
{
    if (digest.length != 64) return false;
    foreach (ch; digest)
        if (!((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F'))) return false;
    return true;
}

private void removeTemporary(string path)
{
    try { if (exists(path)) remove(path); }
    catch (Exception) {}
}

/// Scoped to one restore operation. Immutable pixels shared by many messages
/// are read and checked once, without a process-wide image cache.
public final class AttachmentHydrationCache
{
    private struct Entry { string data, error; }
    private Entry[string] entries;
    private size_t retained;
    public enum size_t byteBudget = 16 * 1024 * 1024;
    public enum size_t entryBudget = 256;

    private Entry load(AttachmentStore store, string digest)
    {
        const key = store.directory ~ "/" ~ digest;
        if (auto entry = key in entries) return *entry;
        Entry entry;
        try entry.data = store.get(digest);
        catch (Exception error)
        {
            entry.error = error.msg;
            logError("Attachment unavailable: " ~ digest ~ ": " ~ error.msg);
        }
        const bytes = key.length + entry.data.length + entry.error.length + 128;
        if (entries.length < entryBudget && bytes <= byteBudget - retained)
        { entries[key] = entry; retained += bytes; }
        return entry;
    }

    public size_t retainedBytes() const { return retained; }
}

/// Content-addressed immutable attachment data. References are committed only
/// after their blob exists. Legacy inline image records remain readable.
public struct AttachmentStore
{
    string directory;

    /// Reads and writes pin references for this process lifetime. Collection
    /// can then run beside a journal append without deleting a reused blob
    /// between externalization and durable reference admission. A later launch
    /// can collect newly orphaned pins. On saturation, collection stops safely.
    private void pin(string digest)
    {
        if (!validAttachmentDigest(digest)) return;
        synchronized (attachmentMutex)
        {
            auto live = liveAttachments(directory);
            if (live.saturated || digest in live.pins) return;
            if (live.pins.length >= 65_536) { live.saturated = true; return; }
            live.pins[digest] = true;
        }
    }

    bool collectionAllowed()
    { synchronized (attachmentMutex) return !liveAttachments(directory).saturated; }

    /// Only the maintenance worker calls this, after a complete durable mark.
    /// Keep the pin check and unlink atomic relative to new reads/writes.
    bool removeUnpinned(string digest)
    {
        if (!validAttachmentDigest(digest)) return false;
        synchronized (attachmentMutex)
        {
            auto live = liveAttachments(directory);
            if (live.saturated || digest in live.pins) return false;
            const path = buildPath(directory, digest ~ ".b64");
            if (!exists(path) || isSymlink(path) || !isFile(path)) return false;
            remove(path);
            return true;
        }
    }

    string put(string data)
    {
        const digest = sha256Of(data).toHexString().idup;
        pin(digest);
        const target = buildPath(directory, digest ~ ".b64");
        if (exists(target))
        {
            if (get(digest) != data) throw new Exception("Attachment content mismatch");
            return digest;
        }
        mkdirRecurse(directory);
        string temporary;
        synchronized (attachmentMutex)
            temporary = buildPath(directory, ".tmp-" ~ to!string(thisProcessID) ~ "-" ~
                to!string(Clock.currTime.stdTime) ~ "-" ~ to!string(++temporarySequence));
        scope (exit) removeTemporary(temporary);
        auto file = File(temporary, "wb");
        file.write(data);
        file.flush();
        file.close();
        // Immutable content must never replace a winner from another writer.
        // Replacement also conflicts with readers holding the destination.
        try installAttachment(temporary, target);
        catch (Exception error)
        {
            if (!exists(target)) throw error;
            // Another writer may have won the same content-addressed target.
            // Never silently accept an unrelated or damaged existing payload.
            if (get(digest) != data) throw new Exception("Attachment content mismatch");
        }
        return digest;
    }

    string get(string digest)
    {
        if (!validAttachmentDigest(digest)) throw new Exception("Invalid attachment reference");
        pin(digest);
        const data = readAttachment(buildPath(directory, digest ~ ".b64"));
        if (sha256Of(data).toHexString() != digest)
            throw new Exception("Attachment checksum mismatch");
        return data;
    }

    ulong byteLength(string digest)
    {
        if (!validAttachmentDigest(digest)) throw new Exception("Invalid attachment reference");
        pin(digest);
        return getSize(buildPath(directory, digest ~ ".b64"));
    }

    void externalize(ref JSONValue value)
    {
        if (value.type == JSONType.array)
            foreach (ref child; value.array) externalize(child);
        else if (value.type == JSONType.object)
        {
            foreach (key; ["blob", "originalBlob"])
                if (auto blob = key in value.object)
                    if (blob.type == JSONType.string && "mimeType" in value.object) pin(blob.str);
            if (auto data = "base64Data" in value.object)
                if (data.type == JSONType.string && "mimeType" in value.object)
                {
                    if (data.str.length) value["blob"] = put(data.str);
                    value.object.remove("base64Data");
                }
            foreach (ref child; value.object) externalize(child);
        }
    }

    void hydrate(ref JSONValue value, AttachmentHydrationCache cache = null)
    {
        if (cache is null) cache = new AttachmentHydrationCache();
        if (value.type == JSONType.array)
            foreach (ref child; value.array) hydrate(child, cache);
        else if (value.type == JSONType.object)
        {
            if (auto original = "originalBlob" in value.object)
                if (original.type == JSONType.string && "mimeType" in value.object) pin(original.str);
            if (auto blob = "blob" in value.object)
                if (blob.type == JSONType.string && "mimeType" in value.object)
                {
                    const entry = cache.load(this, blob.str);
                    value["base64Data"] = entry.data;
                    if (entry.error.length)
                    {
                        // A damaged image must not discard the surrounding
                        // message or the remainder of a conversation journal.
                        value["attachmentError"] = entry.error;
                    }
                }
            foreach (ref child; value.object) hydrate(child, cache);
        }
    }
}

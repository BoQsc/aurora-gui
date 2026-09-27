module auroraremote.transfer;

import auroraremote.crypto : randomBytes;
import auroraremote.protocol : ProtocolChannel, SecureConnection;
import core.sync.mutex : Mutex;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, getSize, isDir,
    mkdirRecurse;
import std.path : baseName, buildPath, dirName, relativePath;
import std.process : environment;
import std.stdio : File;
import std.string : replace, split;

enum FileMessage : ubyte
{
    entry = 1,
    chunk = 2,
    complete = 3
}

string defaultReceiveFolder()
{
    auto home = environment.get("USERPROFILE", "");
    if (home.length == 0) home = environment.get("LOCALAPPDATA", ".");
    return buildPath(home, "Downloads", "Aurora Remote");
}

private enum chunkSize = 256 * 1024;

private void appendU16(ref ubyte[] output, ushort value)
{
    output ~= cast(ubyte)(value >> 8);
    output ~= cast(ubyte) value;
}

private void appendU64(ref ubyte[] output, ulong value)
{
    foreach_reverse (shift; 0 .. 8)
        output ~= cast(ubyte)(value >> (shift * 8));
}

private ushort readU16(const(ubyte)[] input, ref size_t offset)
{
    if (offset + 2 > input.length) throw new Exception("Truncated file record.");
    const value = cast(ushort)((cast(ushort) input[offset] << 8) |
        input[offset + 1]);
    offset += 2;
    return value;
}

private ulong readU64(const(ubyte)[] input, ref size_t offset)
{
    if (offset + 8 > input.length) throw new Exception("Truncated file record.");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | input[offset++];
    return value;
}

private ulong newTransferId()
{
    const bytes = randomBytes(8);
    size_t offset;
    return readU64(bytes, offset);
}

private string safeRelativePath(string value)
{
    value = value.replace('\\', '/');
    if (value.length == 0 || value[0] == '/' || value.canFind(':'))
        throw new Exception("Remote file path is not relative.");
    string[] accepted;
    foreach (part; value.split('/'))
    {
        if (part.length == 0 || part == ".") continue;
        if (part == "..")
            throw new Exception("Remote file path attempts to leave the receive folder.");
        accepted ~= part;
    }
    if (accepted.length == 0) throw new Exception("Remote file path is empty.");
    string result = accepted[0];
    foreach (part; accepted[1 .. $]) result = buildPath(result, part);
    return result;
}

private ubyte[] entryPacket(ulong id, bool directory, ulong size,
    string relativeName)
{
    const nameBytes = cast(const(ubyte)[]) relativeName;
    if (nameBytes.length == 0 || nameBytes.length > ushort.max)
        throw new Exception("Transferred path is too long.");
    ubyte[] result;
    appendU64(result, id);
    result ~= cast(ubyte)(directory ? 1 : 0);
    appendU64(result, size);
    appendU16(result, cast(ushort) nameBytes.length);
    result ~= nameBytes;
    return result;
}

private ubyte[] dataPacket(ulong id, const(ubyte)[] bytes)
{
    ubyte[] result;
    appendU64(result, id);
    result ~= bytes;
    return result;
}

private ubyte[] completePacket(ulong id)
{
    ubyte[] result;
    appendU64(result, id);
    return result;
}

private void sendOneFile(SecureConnection session, string source,
    string relativeName, void delegate(string) update)
{
    const id = newTransferId();
    const size = cast(ulong) getSize(source);
    session.send(ProtocolChannel.file, FileMessage.entry,
        entryPacket(id, false, size, relativeName));
    auto file = File(source, "rb");
    ubyte[] buffer = new ubyte[chunkSize];
    ulong sent;
    while (sent < size)
    {
        const wanted = cast(size_t) ((size - sent) < buffer.length ?
            size - sent : buffer.length);
        auto bytes = file.rawRead(buffer[0 .. wanted]);
        if (bytes.length == 0) throw new Exception("File changed while reading.");
        session.send(ProtocolChannel.file, FileMessage.chunk,
            dataPacket(id, bytes));
        sent += bytes.length;
        if (update !is null)
            update("Sending " ~ relativeName ~ " — " ~
                to!string(sent) ~ " / " ~ to!string(size) ~ " bytes");
    }
    session.send(ProtocolChannel.file, FileMessage.complete,
        completePacket(id));
}

void sendPaths(SecureConnection session, const(string)[] paths,
    void delegate(string) update = null)
{
    foreach (path; paths)
    {
        if (!exists(path)) throw new Exception("Path no longer exists: " ~ path);
        if (!isDir(path))
        {
            sendOneFile(session, path, baseName(path), update);
            continue;
        }
        const parent = dirName(path);
        const rootName = baseName(path);
        const rootId = newTransferId();
        session.send(ProtocolChannel.file, FileMessage.entry,
            entryPacket(rootId, true, 0, rootName));
        session.send(ProtocolChannel.file, FileMessage.complete,
            completePacket(rootId));
        foreach (entry; dirEntries(path, SpanMode.depth, false))
        {
            const relative = buildPath(rootName,
                relativePath(entry.name, path));
            if (entry.isDir)
            {
                const id = newTransferId();
                session.send(ProtocolChannel.file, FileMessage.entry,
                    entryPacket(id, true, 0, relative));
                session.send(ProtocolChannel.file, FileMessage.complete,
                    completePacket(id));
            }
            else sendOneFile(session, entry.name, relative, update);
        }
    }
    if (update !is null) update("Transfer complete");
}

private final class IncomingFile
{
    File file;
    string path;
    ulong expected;
    ulong received;
}

final class FileReceiver
{
    private Mutex _mutex;
    private string _root;
    private IncomingFile[ulong] _active;
    private string _status = "No file transfer";

    this(string root)
    {
        _mutex = new Mutex;
        _root = root;
        mkdirRecurse(_root);
    }

    string status()
    {
        synchronized (_mutex) return _status;
    }
    string root() const { return _root; }

    void process(ubyte kind, const(ubyte)[] payload)
    {
        size_t offset;
        const id = readU64(payload, offset);
        if (kind == FileMessage.entry)
        {
            if (offset + 1 > payload.length)
                throw new Exception("Truncated file entry.");
            const directory = payload[offset++] != 0;
            const size = readU64(payload, offset);
            const nameLength = readU16(payload, offset);
            if (offset + nameLength != payload.length)
                throw new Exception("Invalid file entry path length.");
            const relative = safeRelativePath(
                cast(string) payload[offset .. $].idup);
            const destination = buildPath(_root, relative);
            if (directory)
            {
                mkdirRecurse(destination);
                synchronized (_mutex) _status = "Receiving folder " ~ relative;
                return;
            }
            mkdirRecurse(dirName(destination));
            if (exists(destination))
                throw new Exception("Refusing to overwrite existing received file: " ~
                    relative);
            auto incoming = new IncomingFile;
            incoming.path = destination;
            incoming.expected = size;
            incoming.file = File(destination, "wb");
            _active[id] = incoming;
            synchronized (_mutex) _status = "Receiving " ~ relative;
            return;
        }
        auto incoming = id in _active;
        if (incoming is null)
        {
            if (kind == FileMessage.complete) return; // directory completion
            throw new Exception("File chunk has no matching entry.");
        }
        if (kind == FileMessage.chunk)
        {
            const bytes = payload[offset .. $];
            if (incoming.received + bytes.length > incoming.expected)
                throw new Exception("Received file exceeds its declared size.");
            incoming.file.rawWrite(bytes);
            incoming.received += bytes.length;
            synchronized (_mutex)
                _status = "Receiving " ~ baseName(incoming.path) ~ " — " ~
                    to!string(incoming.received) ~ " / " ~
                    to!string(incoming.expected) ~ " bytes";
            return;
        }
        if (kind == FileMessage.complete)
        {
            incoming.file.close();
            if (incoming.received != incoming.expected)
                throw new Exception("Received file ended before its declared size.");
            synchronized (_mutex) _status = "Received " ~ incoming.path;
            _active.remove(id);
            return;
        }
        throw new Exception("Unknown file-transfer message.");
    }
}

unittest
{
    assert(safeRelativePath("folder/file.txt") ==
        buildPath("folder", "file.txt"));
    foreach (unsafePath; ["../secret.txt", "folder/../../secret.txt",
        "C:\\Windows\\file.txt", "/absolute/file.txt"])
    {
        bool rejected;
        try safeRelativePath(unsafePath);
        catch (Exception) rejected = true;
        assert(rejected);
    }
}

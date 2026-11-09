module auroraopencode.archives;

import auroraopencode.nativeio;
import std.algorithm : canFind, sort;
import std.array : array;
import std.conv : to;
import std.exception : enforce, collectException;
import std.file : dirEntries, exists, getSize, isDir, isFile, isSymlink,
    mkdirRecurse, read, remove, rename, rmdirRecurse, SpanMode;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName, extension, relativePath;
import std.stdio : File;
import std.string : endsWith, indexOf, lastIndexOf, join, replace, split, startsWith, strip, toLower;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

// std.zip uses a memory-backed ZIP32 representation. Bound its allocation
// explicitly; TAR uses streaming I/O and supports larger source files.
enum ulong zipMemoryLimit = 512UL * 1024 * 1024;
enum ulong archiveExpandedLimit = 8UL * 1024 * 1024 * 1024;
enum size_t archiveEntryLimit = 100_000;

struct ArchiveItem
{
    string name;
    ulong size;
    bool directory;
    ulong offset; // TAR data position
}

string archiveRelativePath(string name)
{
    name = name.replace('\\', '/');
    enforce(name.length && !name.startsWith("/") && name.indexOf(':') < 0 &&
        name.indexOf('\0') < 0, "Invalid archive path: " ~ name);
    string[] parts;
    foreach (part; name.split('/'))
    {
        if (part == "" || part == ".") continue;
        enforce(part != "..", "Archive path escapes destination: " ~ name);
        version (Windows)
        {
            enforce(part[$ - 1] != '.' && part[$ - 1] != ' ' &&
                part.indexOf('<') < 0 && part.indexOf('>') < 0 &&
                part.indexOf('"') < 0 && part.indexOf('|') < 0 &&
                part.indexOf('?') < 0 && part.indexOf('*') < 0,
                "Unsupported Windows archive path: " ~ name);
            auto stem = part.split('.')[0].toLower();
            enforce(!["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"].canFind(stem),
                "Reserved Windows archive path: " ~ name);
        }
        parts ~= part;
    }
    enforce(parts.length > 0, "Empty archive path.");
    return parts.join('/');
}

private string archiveKind(string path)
{
    const kind = extension(path).toLower();
    enforce(kind == ".zip" || kind == ".tar", "Supported archive formats: .zip and uncompressed .tar.");
    return kind;
}

private ZipArchive openZip(string path)
{
    enforce(getSize(path) <= zipMemoryLimit, "ZIP exceeds the 512 MiB memory-backed ZIP32 limit; use streaming TAR for larger inputs.");
    auto bytes = cast(ubyte[])read(path, zipMemoryLimit + 1);
    enforce(bytes.length <= zipMemoryLimit, "ZIP grew beyond its memory limit during reading.");
    return new ZipArchive(bytes);
}

// std.zip's expand() does not check CRC and retains every expanded member.
// Stream through the zlib already linked by Phobos, bounding memory and
// validating both declared size and CRC without accumulating expanded files.
private void streamZipMember(ArchiveMember member, void delegate(const(ubyte)[]) consume,
    NativeCancel cancelled)
{
    import std.zlib : crc32;
    import etc.c.zlib : z_stream, inflateInit2, inflate, inflateEnd,
        Z_NO_FLUSH, Z_OK, Z_STREAM_END;
    enforce((member.flags & 1) == 0, "Encrypted ZIP entries are unsupported.");
    ulong expanded;
    uint crc;
    void emit(const(ubyte)[] bytes)
    {
        enforce(bytes.length <= member.expandedSize - expanded, "ZIP expanded size exceeds its declared size.");
        expanded += bytes.length;
        crc = crc32(crc, bytes);
        if (consume !is null) consume(bytes);
    }
    if (member.compressionMethod == CompressionMethod.none)
    {
        auto data = member.compressedData;
        while (data.length)
        {
            checkNativeCancellation(cancelled);
            const amount = data.length < 65536 ? data.length : 65536;
            emit(data[0 .. amount]); data = data[amount .. $];
        }
    }
    else
    {
        enforce(member.compressionMethod == CompressionMethod.deflate, "Unsupported ZIP compression method.");
        z_stream stream;
        enforce(inflateInit2(&stream, -15) == Z_OK, "Could not initialize ZIP decompression.");
        scope(exit) inflateEnd(&stream);
        stream.next_in = cast(ubyte*)member.compressedData.ptr;
        stream.avail_in = to!uint(member.compressedData.length);
        ubyte[] buffer = new ubyte[65536];
        while (true)
        {
            checkNativeCancellation(cancelled);
            stream.next_out = buffer.ptr; stream.avail_out = cast(uint)buffer.length;
            const before = stream.avail_in;
            const status = inflate(&stream, Z_NO_FLUSH);
            emit(buffer[0 .. buffer.length - stream.avail_out]);
            if (status == Z_STREAM_END)
            {
                enforce(stream.avail_in == 0, "ZIP entry contains trailing compressed data.");
                break;
            }
            enforce(status == Z_OK && (before != stream.avail_in || stream.avail_out != buffer.length),
                "Invalid or truncated ZIP deflate stream.");
        }
    }
    enforce(expanded == member.expandedSize, "ZIP expanded size mismatch.");
    enforce(crc == member.crc32, "ZIP CRC-32 mismatch.");
}

private ulong octal(const(ubyte)[] bytes)
{
    ulong value;
    foreach (ch; bytes)
    {
        if (ch == 0 || ch == ' ') continue;
        enforce(ch >= '0' && ch <= '7', "Unsupported/invalid TAR numeric field.");
        enforce(value <= ulong.max >> 3, "TAR numeric overflow.");
        value = (value << 3) + ch - '0';
    }
    return value;
}

private string tarText(const(ubyte)[] bytes)
{
    size_t end;
    while (end < bytes.length && bytes[end]) ++end;
    return cast(string) bytes[0 .. end].dup;
}

private ArchiveItem[] tarItems(string path, NativeCancel cancelled)
{
    auto input = File(path, "rb");
    ArchiveItem[] result;
    const length = getSize(path);
    ulong total;
    while (input.tell() + 512 <= length)
    {
        checkNativeCancellation(cancelled);
        ubyte[512] header;
        enforce(input.rawRead(header[]).length == 512, "Truncated TAR header.");
        bool empty = true;
        foreach (b; header) if (b) { empty = false; break; }
        if (empty)
        {
            enforce(input.rawRead(header[]).length == 512, "TAR is missing its second end block.");
            foreach (b; header) enforce(b == 0, "Invalid TAR end marker.");
            return result;
        }
        ulong checksum;
        foreach (i, b; header) checksum += i >= 148 && i < 156 ? ' ' : b;
        enforce(checksum == octal(header[148 .. 156]), "TAR header checksum mismatch.");
        const type = header[156];
        enforce(type == 0 || type == '0' || type == '5', "Unsupported TAR entry type (links/extensions are not extracted).");
        auto name = tarText(header[0 .. 100]);
        if (tarText(header[257 .. 263]).startsWith("ustar"))
        {
            const prefix = tarText(header[345 .. 500]);
            if (prefix.length) name = prefix ~ "/" ~ name;
        }
        const size = octal(header[124 .. 136]);
        const offset = input.tell();
        enforce(size <= archiveExpandedLimit - total && size <= length - offset,
            "TAR entry exceeds available data or expanded-size limit.");
        total += size;
        enforce(type != '5' || size == 0, "TAR directory has a non-zero payload.");
        if (!(type == '5' && (name == "." || name == "./")))
            result ~= ArchiveItem(archiveRelativePath(name), size, type == '5', offset);
        enforce(result.length <= archiveEntryLimit, "Archive has too many entries.");
        const padded = (size + 511) / 512 * 512;
        enforce(padded <= length - offset, "Truncated TAR padding.");
        input.seek(offset + padded);
    }
    enforce(false, "TAR has no end marker.");
    return result;
}

ArchiveItem[] archiveItems(string path, NativeCancel cancelled = null)
{
    if (archiveKind(path) == ".tar")
    {
        auto items = tarItems(path, cancelled);
        validateArchivePaths(items);
        return items;
    }
    auto zip = openZip(path);
    ArchiveItem[] result;
    ulong total;
    foreach (name, member; zip.directory)
    {
        checkNativeCancellation(cancelled);
        enforce((member.fileAttributes & 0xF000) != 0xA000, "Archive links are unsupported.");
        enforce(member.expandedSize <= archiveExpandedLimit - total, "Archive exceeds expanded-size limit.");
        total += member.expandedSize;
        result ~= ArchiveItem(archiveRelativePath(name), member.expandedSize, name.endsWith("/") || name.endsWith("\\"));
        enforce(result.length <= archiveEntryLimit, "Archive has too many entries.");
    }
    result.sort!((a, b) => a.name < b.name);
    validateArchivePaths(result);
    return result;
}

private void validateArchivePaths(ArchiveItem[] items)
{
    bool[string] destinations;
    foreach (item; items)
    {
        auto key = item.name;
        version (Windows) key = key.toLower();
        enforce(key !in destinations, "Duplicate archive destination: " ~ item.name);
        enforce(!item.directory || item.size == 0, "Archive directory has a non-zero payload.");
        destinations[key] = item.directory;
    }
    foreach (item; items)
    {
        auto parts = item.name.split('/');
        while (parts.length > 1)
        {
            parts = parts[0 .. $ - 1];
            auto parent = parts.join('/');
            version (Windows) parent = parent.toLower();
            auto entry = parent in destinations;
            enforce(entry is null || *entry, "Archive file is also a parent directory: " ~ parent);
        }
    }
}

private void copyArchiveBytes(ref File input, ref File output, ulong length, NativeCancel cancelled)
{
    ubyte[] buffer = new ubyte[1024 * 1024];
    while (length)
    {
        checkNativeCancellation(cancelled);
        const amount = cast(size_t)(length < buffer.length ? length : buffer.length);
        const bytes = input.rawRead(buffer[0 .. amount]);
        enforce(bytes.length == amount, "Source changed or archive was truncated during copying.");
        output.rawWrite(bytes);
        length -= amount;
    }
}

// Shared by source snapshots, developer provisioning, and the assistant. The
// caller controls destination staging; all member paths are checked up front.
ArchiveItem[] extractArchive(string path, string destination, bool stripFirst = false,
    NativeCancel cancelled = null, NativeProgress progress = null, bool overwrite = false)
{
    auto items = archiveItems(path, cancelled);
    string[string] outputs;
    foreach (ref item; items)
    {
        if (stripFirst)
        {
            const slash = item.name.indexOf('/');
            item.name = slash < 0 ? "" : item.name[cast(size_t)slash + 1 .. $];
        }
        if (!item.name.length) continue;
        const target = buildPath(destination, item.name);
        rejectNativeLinks(target);
        auto key = item.name;
        version (Windows) key = key.toLower();
        enforce(key !in outputs, "Duplicate archive destination: " ~ item.name);
        outputs[key] = item.name;
        enforce(!exists(target) || (item.directory && isDir(target)) ||
            (overwrite && !item.directory && isFile(target)), "Archive destination already exists: " ~ target);
    }
    mkdirRecurse(destination);
    ZipArchive zip;
    File tar;
    if (archiveKind(path) == ".zip") zip = openZip(path);
    else tar = File(path, "rb");
    // std.zip's original names can differ from normalized destination names.
    ArchiveMember[string] members;
    if (zip !is null)
        foreach (name, member; zip.directory)
        {
            auto normalized = archiveRelativePath(name);
            if (stripFirst)
            {
                const slash = normalized.indexOf('/');
                normalized = slash < 0 ? "" : normalized[cast(size_t)slash + 1 .. $];
            }
            members[normalized] = member;
        }
    foreach (item; items)
    {
        checkNativeCancellation(cancelled);
        if (!item.name.length) continue;
        const target = buildPath(destination, item.name);
        if (item.directory) mkdirRecurse(target);
        else
        {
            mkdirRecurse(dirName(target));
            const temporary = nativeTemporaryPath(target);
            scope(exit) if (exists(temporary)) collectException(remove(temporary));
            auto output = File(temporary, "wb");
            if (zip !is null)
            {
                streamZipMember(members[item.name], (const(ubyte)[] bytes) { output.rawWrite(bytes); }, cancelled);
            }
            else
            {
                tar.seek(item.offset);
                copyArchiveBytes(tar, output, item.size, cancelled);
            }
            output.close();
            checkNativeCancellation(cancelled);
            enforce(overwrite || !exists(target), "Extraction target appeared during the operation: " ~ target);
            rename(temporary, target);
        }
        if (progress !is null) progress("Extracted " ~ item.name);
    }
    return items;
}

private void putOctal(ref ubyte[512] header, size_t start, size_t length, ulong value)
{
    header[start .. start + length] = '0';
    header[start + length - 1] = 0;
    auto index = start + length - 1;
    do
    {
        enforce(index > start, "TAR numeric field exceeds ustar capacity.");
        header[--index] = cast(ubyte)('0' + (value & 7));
        value >>= 3;
    } while (value);
}

JSONValue archiveOperation(string arguments, string workspace, NativeCancel cancelled = null,
    NativeProgress progress = null)
{
    auto args = parseJSON(arguments);
    enforce(args.type == JSONType.object, "archive requires an object.");
    const action = nativeString(args, "action");
    const path = nativePath(nativeString(args, "path"), workspace);
    const kind = archiveKind(path);
    JSONValue result;
    result["path"] = path;
    result["action"] = action;
    if (action == "create")
    {
        rejectNativeLinks(path);
        enforce(!exists(path), "Archive already exists; choose a new output path.");
        const root = nativePath(nativeString(args, "root", "."), workspace);
        rejectNativeLinks(root);
        auto selected = "paths" in args.object;
        enforce(selected !is null && selected.type == JSONType.array && selected.array.length, "create requires non-empty paths relative to root.");
        string[string] sources;
        ulong total;
        void add(string source)
        {
            checkNativeCancellation(cancelled);
            enforce(!isSymlink(source), "Archive creation does not follow symbolic links: " ~ source);
            const name = archiveRelativePath(relativePath(source, root).replace('\\', '/'));
            enforce(source != path, "Archive cannot include itself.");
            if (name in sources) return;
            const length = isDir(source) ? 0UL : getSize(source);
            enforce(length <= archiveExpandedLimit - total, "Archive input exceeds 8 GiB limit.");
            total += length;
            sources[name] = source;
            enforce(sources.length <= archiveEntryLimit, "Too many archive inputs.");
        }
        foreach (entry; selected.array)
        {
            enforce(entry.type == JSONType.string, "paths entries must be strings.");
            const source = nativePath(entry.str, root);
            rejectNativeLinks(source);
            enforce(exists(source), "Archive input missing: " ~ source);
            // relativePath validation prevents sources outside root.
            if (source != root) add(source);
            if (isDir(source))
            {
                void visit(string directory)
                {
                    foreach (child; dirEntries(directory, SpanMode.shallow))
                    {
                        add(child.name);
                        if (child.isDir) visit(child.name);
                    }
                }
                visit(source);
            }
        }
        if (kind == ".zip") enforce(total <= zipMemoryLimit, "ZIP input exceeds 512 MiB memory limit; use .tar.");
        auto names = sources.keys.sort.array;
        mkdirRecurse(dirName(path));
        const temporary = nativeTemporaryPath(path);
        scope(exit) if (exists(temporary)) collectException(remove(temporary));
        if (kind == ".zip")
        {
            auto zip = new ZipArchive();
            ulong actualBytes;
            foreach (name; names)
            {
                checkNativeCancellation(cancelled);
                const directory = isDir(sources[name]);
                auto member = new ArchiveMember();
                member.name = name ~ (directory ? "/" : "");
                member.compressionMethod = directory ? CompressionMethod.none : CompressionMethod.deflate;
                auto bytes = directory ? null : cast(ubyte[])read(sources[name], zipMemoryLimit + 1);
                enforce(bytes.length <= zipMemoryLimit - actualBytes, "ZIP input grew beyond the memory limit; use .tar.");
                actualBytes += bytes.length;
                member.expandedData = bytes;
                zip.addMember(member);
                if (progress !is null) progress("Packed " ~ name);
            }
            import std.file : write;
            auto built = zip.build();
            enforce(built.length <= zipMemoryLimit, "Built ZIP exceeds 512 MiB memory limit; use .tar.");
            write(temporary, built);
        }
        else
        {
            auto output = File(temporary, "wb");
            ubyte[512] zero;
            foreach (name; names)
            {
                checkNativeCancellation(cancelled);
                ubyte[512] header;
                auto shortName = name;
                string prefix;
                if (name.length > 100)
                {
                    auto slash = name.length > 155 ? name[0 .. 156].lastIndexOf('/') : name.lastIndexOf('/');
                    enforce(slash > 0 && name.length - slash - 1 <= 100, "Path exceeds ustar name capacity: " ~ name);
                    prefix = name[0 .. cast(size_t)slash];
                    shortName = name[cast(size_t)slash + 1 .. $];
                }
                const directory = isDir(sources[name]);
                const size = directory ? 0UL : getSize(sources[name]);
                header[0 .. shortName.length] = cast(const(ubyte)[])shortName;
                header[345 .. 345 + prefix.length] = cast(const(ubyte)[])prefix;
                putOctal(header, 100, 8, directory ? 493 : 420);
                putOctal(header, 108, 8, 0); putOctal(header, 116, 8, 0);
                putOctal(header, 124, 12, size); putOctal(header, 136, 12, 0);
                header[148 .. 156] = ' ';
                header[156] = directory ? '5' : '0';
                header[257 .. 263] = cast(const(ubyte)[])"ustar\0";
                header[263 .. 265] = cast(const(ubyte)[])"00";
                ulong sum; foreach (b; header) sum += b;
                putOctal(header, 148, 7, sum); header[155] = ' ';
                output.rawWrite(header[]);
                if (!directory)
                {
                    auto input = File(sources[name], "rb");
                    copyArchiveBytes(input, output, size, cancelled);
                    const padding = cast(size_t)((512 - size % 512) % 512);
                    output.rawWrite(zero[0 .. padding]);
                }
                if (progress !is null) progress("Packed " ~ name);
            }
            output.rawWrite(zero[]); output.rawWrite(zero[]); output.close();
        }
        checkNativeCancellation(cancelled);
        rename(temporary, path);
        result["entries"] = cast(long)names.length;
        result["inputBytes"] = total;
        result["archiveBytes"] = getSize(path);
        return result;
    }
    enforce(action == "list" || action == "extract" || action == "validate", "action must be create, list, extract or validate.");
    auto items = archiveItems(path, cancelled);
    if (action == "extract")
    {
        const destination = nativePath(nativeString(args, "destination"), workspace);
        rejectNativeLinks(destination);
        enforce(!exists(destination), "Extraction destination must be new; existing files are never overwritten.");
        mkdirRecurse(dirName(destination));
        const staging = nativeTemporaryPath(destination);
        scope(exit) if (exists(staging)) collectException(rmdirRecurse(staging));
        extractArchive(path, staging, false, cancelled, progress);
        checkNativeCancellation(cancelled);
        rename(staging, destination);
        result["destination"] = destination;
    }
    else if (action == "validate" && kind == ".zip")
    {
        auto zip = openZip(path);
        foreach (name, member; zip.directory)
        {
            checkNativeCancellation(cancelled);
            streamZipMember(member, null, cancelled);
            if (progress !is null) progress("Validated " ~ name);
        }
    }
    const offset = nativeInteger(args, "offset", 0);
    const limit = nativeInteger(args, "limit", 100);
    enforce(offset >= 0 && limit >= 1 && limit <= 200, "offset must be non-negative; limit must be 1..200.");
    result["entries"] = cast(long)items.length;
    ulong bytes;
    foreach (item; items) bytes += item.size;
    result["expandedBytes"] = bytes;
    if (action == "validate") result["valid"] = true;
    if (action != "list") return result;
    result["items"] = JSONValue.emptyArray;
    foreach (i, item; items)
    {
        if (i < offset || i - offset >= limit) continue;
        JSONValue row;
        row["name"] = item.name; row["bytes"] = item.size; row["directory"] = item.directory;
        result["items"].array ~= row;
    }
    result["nextOffset"] = offset + result["items"].array.length < items.length ?
        JSONValue(offset + result["items"].array.length) : JSONValue(null);
    enforce(result.toString().length <= 24_000, "Archive listing exceeds 24 KiB; request a smaller limit.");
    return result;
}

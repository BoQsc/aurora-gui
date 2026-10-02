/**
 * Independent ISO 9660 (ECMA-119) reader.
 *
 * Supports the Primary Volume Descriptor, optional Joliet (UCS-2) supplementary
 * descriptors, Rock Ridge (NM/SL/PX/CE) name and symlink extensions, multi-
 * extent files, and an El Torito boot-record summary. No external tools or
 * libraries are used: the module reads and parses the raw image itself.
 */
module auroraiso.iso.reader;

import auroraiso.iso.endian : hasRange, readBe32, readLe32, readBoth32, readBoth16;
import auroraiso.iso.structures;
import std.algorithm : min;
import std.array : Appender, appender;
import std.conv : to;
import std.stdio : File, StdioException;
import std.string : indexOf, lastIndexOf, split, strip, toLower;
import std.utf : toUTF8;

/// A single entry (file or directory) found in an ISO image.
struct IsoNode
{
    string name;         // display name (Rock Ridge / Joliet / plain)
    string path;         // absolute image path, e.g. "/boot/grub.cfg"
    bool isDirectory;
    uint extent;         // logical block address of the data
    uint size;           // data length in bytes
    bool isSymlink;
    string linkTarget;

    bool isFile() const pure nothrow @nogc @safe { return !isDirectory; }
}

/// Raised for malformed or unreadable images.
class IsoFormatException : Exception
{
    this(string message)
    {
        super(message);
    }
}

/// Parse options controlling which names a reader prefers.
struct IsoReadOptions
{
    /// Prefer the Joliet tree when a supplementary descriptor is present.
    bool preferJoliet = true;
    /// Prefer Rock Ridge names when present.
    bool useRockRidge = true;
}

/**
 * A random-access ISO 9660 image. Open once, list directories, and read files.
 * The underlying file handle stays open until `close()` (or the GC collects the
 * object); all reads are seek-based so large images are never slurped whole.
 */
final class IsoImage
{
    private File _file;
    private string _path;
    private string _volumeId;
    private string _systemId;
    private string _applicationId;
    private bool _hasJoliet;
    private bool _hasRockRidge;
    private bool _useJoliet;
    private bool _useRockRidge;
    private IsoReadOptions _options;
    private uint _blockSize = isoBlockSize;
    private uint _volumeSpace;
    private IsoDirectoryRecord _root;
    private IsoDirectoryRecord _rootJoliet;
    private ElToritoInfo _elTorito;
    private bool _closed;

    this(string path, IsoReadOptions options = IsoReadOptions.init)
    {
        _path = path;
        _options = options;
        _useJoliet = options.preferJoliet;
        _useRockRidge = options.useRockRidge;
        try
            _file = File(path, "rb");
        catch (StdioException error)
            throw new IsoFormatException("Cannot open \"" ~ path ~ "\": " ~ error.msg);
        parseDescriptors();
    }

    ~this()
    {
        close();
    }

    /// Absolute path of the image on disk.
    string path() const @safe pure nothrow @nogc { return _path; }

    /// Volume identifier from the primary descriptor (leading/trailing spaces trimmed).
    string volumeId() const @safe pure nothrow @nogc { return _volumeId; }

    /// System identifier string (usually empty).
    string systemId() const @safe pure nothrow @nogc { return _systemId; }

    /// Application identifier string (usually empty).
    string applicationId() const @safe pure nothrow @nogc { return _applicationId; }

    /// True when the image carries a Joliet supplementary descriptor.
    bool hasJoliet() const @safe pure nothrow @nogc { return _hasJoliet; }

    /// True when the active tree exposes Rock Ridge extensions.
    bool hasRockRidge() const @safe pure nothrow @nogc { return _hasRockRidge; }

    /// True when the active name source is Joliet.
    bool usingJoliet() const @safe pure nothrow @nogc { return _useJoliet && _hasJoliet; }

    /// True when an El Torito boot record is present.
    bool isBootable() const @safe pure nothrow @nogc { return _elTorito.present && _elTorito.bootable; }

    /// El Torito summary (platform, bootable flag, load address).
    ElToritoInfo elTorito() const @safe pure nothrow @nogc { return _elTorito; }

    /// Total image size in 2048-byte logical blocks.
    uint volumeSpaceSectors() const @safe pure nothrow @nogc { return _volumeSpace; }

    /// Total image size in bytes.
    ulong volumeSizeBytes() const @safe pure nothrow @nogc
    {
        return cast(ulong) _volumeSpace * _blockSize;
    }

    /// Logical block size (always 2048 for ECMA-119; reported from the image).
    uint blockSize() const @safe pure nothrow @nogc { return _blockSize; }

    /// Release the underlying file handle. Safe to call more than once.
    void close() @trusted
    {
        if (_closed) return;
        _closed = true;
        _file.close();
    }

    // ----- Public navigation -------------------------------------------------

    /// List the root directory.
    IsoNode[] rootNodes()
    {
        return readDirectory(_root, "");
    }

    /// List a directory by absolute image path ("/" or "/EFI/BOOT").
    IsoNode[] list(string directoryPath)
    {
        IsoDirectoryRecord directory;
        if (!locateDirectory(directoryPath, directory))
            throw new IsoFormatException("Directory not found: " ~ directoryPath);
        return readDirectory(directory, normalizeDir(directoryPath));
    }

    /// Find an entry by absolute image path, or a default-constructed node when missing.
    bool find(string imagePath, out IsoNode node)
    {
        const normalized = normalizePath(imagePath);
        if (normalized == "/")
        {
            node = IsoNode("", "/", true, _root.extent, _root.dataLength, false, "");
            return true;
        }
        const slash = normalized.lastIndexOf('/');
        const parent = slash <= 0 ? "/" : normalized[0 .. slash];
        const leaf = normalized[slash + 1 .. $];
        foreach (candidate; list(parent))
        {
            if (equalsIgnoreCase(candidate.name, leaf))
            {
                node = candidate;
                return true;
            }
        }
        return false;
    }

    /// Read a whole file into memory. Throws when the path is not a regular file.
    ubyte[] readFile(string imagePath, bool delegate() cancel = null)
    {
        IsoNode node;
        if (!find(imagePath, node))
            throw new IsoFormatException("File not found: " ~ imagePath);
        if (node.isDirectory)
            throw new IsoFormatException("Not a file: " ~ imagePath);
        return readFileData(node, cancel);
    }

    /// Recursively list every node under a directory (directories excluded by default).
    IsoNode[] walk(string directoryPath = "/", bool includeDirectories = false,
        bool delegate() cancel = null)
    {
        IsoNode[] output;
        bool cancelled;
        walkInto(normalizeDir(directoryPath), includeDirectories, output, cancel, cancelled);
        return output;
    }

    // ----- Internals ---------------------------------------------------------

    private void parseDescriptors()
    {
        bool foundPrimary;
        uint lba = isoFirstDescriptorLba;
        for (uint count = 0; count < 64; ++count, ++lba)
        {
            auto sector = readAt(cast(ulong) lba * _blockSize, _blockSize);
            if (sector.length < _blockSize)
                break;
            if (sector[0] == vdTerminator)
                break;
            if (sector[1] != 'C' || sector[2] != 'D' || sector[3] != '0' ||
                sector[4] != '0' || sector[5] != '1')
                continue;

            switch (sector[0])
            {
                case vdPrimary:
                    if (!foundPrimary)
                    {
                        foundPrimary = true;
                        _blockSize = readBoth16(sector, 128);
                        if (_blockSize == 0)
                            _blockSize = isoBlockSize;
                        _volumeSpace = readBoth32(sector, 80);
                        _volumeId = decodeAscii(sector[40 .. 72]);
                        _systemId = decodeAscii(sector[8 .. 40]);
                        _applicationId = decodeAscii(sector[574 .. 702]);
                        auto root = parseDirectoryRecord(sector, 156);
                        if (root.valid)
                            _root = root;
                    }
                    break;
                case vdSupplementary:
                    if (isJolietDescriptor(sector))
                    {
                        _hasJoliet = true;
                        auto root = parseDirectoryRecord(sector, 156);
                        if (root.valid)
                            _rootJoliet = root;
                    }
                    break;
                case vdBootRecord:
                    if (isElToritoRecord(sector))
                        parseElTorito(sector);
                    break;
                default:
                    break;
            }
        }

        if (!foundPrimary || !_root.valid)
            throw new IsoFormatException("Not an ISO 9660 image: " ~ _path);

        // Prefer Joliet when requested and present.
        if (_useJoliet && _hasJoliet && _rootJoliet.valid)
            _root = _rootJoliet;

        // Detect Rock Ridge on the active root record.
        if (_useRockRidge)
        {
            string ignoredName;
            bool ignoredSymlink;
            string ignoredTarget;
            scanRockRidge(_root.systemUse, ignoredName, ignoredSymlink, ignoredTarget, 0);
            if (_hasRockRidge && _useJoliet && _hasJoliet)
                _hasRockRidge = false; // Rock Ridge is meaningless over Joliet.
        }
    }

    private static bool isJolietDescriptor(const(ubyte)[] sector) pure nothrow @nogc @safe
    {
        // Joliet escape sequences start at byte 88: "%/@", "%/C", or "%/E".
        return sector.length > 90 && sector[88] == '%' && sector[89] == '/';
    }

    private void parseElTorito(const(ubyte)[] sector)
    {
        ElToritoInfo info;
        info.present = true;
        info.bootCatalogLba = readLe32(sector, 71);

        auto catalog = readAt(cast(ulong) info.bootCatalogLba * _blockSize, _blockSize);
        if (catalog.length >= 64)
        {
            // Validation entry: byte 0 = 1, byte 1 = platform, bytes 30-31 = 0xAA55.
            if (catalog[0] == 1)
                info.platform = elToritoPlatformName(catalog[1]);
            // Initial/default entry at offset 32.
            const bootable = catalog[32];
            info.bootable = bootable == 0x88;
            info.mediaType = catalog[33];
            info.loadSegment = cast(uint)(catalog[34] | (catalog[35] << 8));
            info.systemType = catalog[36];
            info.sectorCount = cast(ushort)(catalog[38] | (catalog[39] << 8));
            info.loadLba = readLe32(catalog, 40);
        }
        _elTorito = info;
    }

    /// Read directory data and produce nodes. `basePath` has no trailing slash.
    private IsoNode[] readDirectory(const IsoDirectoryRecord directory, string basePath)
    {
        IsoNode[] output;
        if (directory.dataLength == 0)
            return output;

        auto data = readAt(cast(ulong) directory.extent * _blockSize, directory.dataLength);
        size_t offset = 0;
        while (offset < data.length)
        {
            const remainingInSector = _blockSize - (offset % _blockSize);
            auto record = parseDirectoryRecord(data, offset);
            if (!record.valid || record.recordLength == 0 ||
                record.recordLength > remainingInSector)
            {
                offset += remainingInSector;
                continue;
            }

            if (!record.isSelf() && !record.isParent())
            {
                auto node = buildNode(record, basePath);
                if (node.name.length > 0)
                    output ~= node;
            }
            offset += record.recordLength;
        }
        return output;
    }

    private IsoNode buildNode(const ref IsoDirectoryRecord record, string basePath)
    {
        string name;
        bool symlink;
        string target;
        if (_useRockRidge)
            scanRockRidge(record.systemUse, name, symlink, target, 0);

        if (name.length == 0)
            name = decodeIdentifier(record);

        IsoNode node;
        node.name = name;
        node.isDirectory = record.isDirectory();
        node.extent = record.extent;
        node.size = record.dataLength;
        node.isSymlink = symlink;
        node.linkTarget = target;
        node.path = basePath.length == 0 ? "/" ~ name : basePath ~ "/" ~ name;
        return node;
    }

    /// Concatenate any multi-extent chain into a single byte buffer.
    private ubyte[] readFileData(IsoNode node, bool delegate() cancel)
    {
        auto output = appender!(ubyte[])();
        uint extent = node.extent;
        uint remaining = node.size;
        uint guard = 0;
        while (remaining > 0 && guard++ < 4096)
        {
            if (cancel !is null && cancel())
                break;
            const chunk = cast(uint) min(cast(ulong) remaining,
                cast(ulong) 64 * 1024 * 1024);
            auto block = readAt(cast(ulong) extent * _blockSize, chunk);
            if (block.length == 0)
                break;
            output.put(block);
            remaining -= cast(uint) block.length;
            if (block.length < chunk)
                break;
            extent += cast(uint) (chunk / _blockSize);
            if (chunk % _blockSize != 0)
                extent += 1;
        }
        return output.data;
    }

    private void walkInto(string directoryPath, bool includeDirectories,
        ref IsoNode[] output, bool delegate() cancel, ref bool cancelled)
    {
        if (cancelled)
            return;
        if (cancel !is null && cancel())
        {
            cancelled = true;
            return;
        }
        IsoNode[] children;
        try
            children = list(directoryPath);
        catch (IsoFormatException)
            return;
        foreach (child; children)
        {
            if (cancelled)
                return;
            if (child.isDirectory)
            {
                if (includeDirectories)
                    output ~= child;
                walkInto(child.path, includeDirectories, output, cancel, cancelled);
            }
            else
            {
                output ~= child;
            }
        }
    }

    private bool locateDirectory(string directoryPath, out IsoDirectoryRecord result)
    {
        if (normalizePath(directoryPath) == "/")
        {
            result = _root;
            return true;
        }

        auto parts = splitPath(directoryPath);
        IsoDirectoryRecord current = _root;
        foreach (part; parts)
        {
            if (part == ".")
                continue;
            if (part == "..")
            {
                current = _root;
                continue;
            }
            bool found;
            auto data = readAt(cast(ulong) current.extent * _blockSize, current.dataLength);
            size_t offset = 0;
            while (offset < data.length)
            {
                const remainingInSector = _blockSize - (offset % _blockSize);
                auto record = parseDirectoryRecord(data, offset);
                if (!record.valid || record.recordLength == 0 ||
                    record.recordLength > remainingInSector)
                {
                    offset += remainingInSector;
                    continue;
                }
                if (!record.isSelf() && !record.isParent() && record.isDirectory())
                {
                    auto node = buildNode(record, "");
                    if (equalsIgnoreCase(node.name, part))
                    {
                        current = record;
                        found = true;
                        break;
                    }
                }
                offset += record.recordLength;
            }
            if (!found)
                return false;
        }
        result = current;
        return true;
    }

    private static string[] splitPath(string directoryPath)
    {
        import std.array : array;
        import std.algorithm : filter;
        auto normalized = normalizePath(directoryPath);
        auto parts = normalized.split('/').filter!(a => a.length > 0).array;
        return parts;
    }

    private static string normalizePath(string imagePath)
    {
        auto trimmed = imagePath.strip;
        if (trimmed.length == 0)
            return "/";
        string result = trimmed;
        import std.string : replace;
        result = result.replace('\\', '/');
        if (result[0] != '/')
            result = "/" ~ result;
        // Collapse trailing slash except for the root.
        while (result.length > 1 && result[$ - 1] == '/')
            result = result[0 .. $ - 1];
        return result;
    }

    private static string normalizeDir(string directoryPath)
    {
        auto normalized = normalizePath(directoryPath);
        return normalized == "/" ? "" : normalized;
    }

    // ----- Name decoding -----------------------------------------------------

    private string decodeIdentifier(const ref IsoDirectoryRecord record)
    {
        if (usingJoliet() && !record.isDirectory())
            return stripVersion(decodeJoliet(record.identifier));
        if (usingJoliet() && record.isDirectory())
            return decodeJoliet(record.identifier);

        auto raw = record.identifier;
        auto text = decodeAscii(raw);
        if (!record.isDirectory())
            text = stripVersion(text);
        return text;
    }

    private static string stripVersion(string value)
    {
        const semicolon = value.lastIndexOf(';');
        if (semicolon < 0)
            return value;
        const versionText = value[semicolon + 1 .. $];
        if (versionText.length == 0)
            return value;
        foreach (ch; versionText)
            if (ch < '0' || ch > '9')
                return value;
        return value[0 .. semicolon];
    }

    private static string decodeAscii(const(ubyte)[] raw)
    {
        auto output = appender!(char[])();
        foreach (value; raw)
        {
            if (value == 0)
                break;
            output.put(cast(char) value);
        }
        return output.data.strip.to!string;
    }

    private static string decodeJoliet(const(ubyte)[] raw)
    {
        dchar[] buffer;
        size_t index = 0;
        while (index + 1 < raw.length)
        {
            const unit = cast(uint)(raw[index] << 8) | raw[index + 1];
            index += 2;
            if (unit == 0)
                break;
            if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < raw.length)
            {
                const low = cast(uint)(raw[index] << 8) | raw[index + 1];
                if (low >= 0xDC00 && low <= 0xDFFF)
                {
                    index += 2;
                    buffer ~= cast(dchar)(0x10000 + ((unit - 0xD800) << 10) +
                        (low - 0xDC00));
                    continue;
                }
            }
            buffer ~= cast(dchar) unit;
        }
        return toUTF8(buffer);
    }

    // ----- Rock Ridge --------------------------------------------------------

    private void scanRockRidge(const(ubyte)[] systemUse, ref string name,
        ref bool symlink, ref string target, int depth)
    {
        if (systemUse.length == 0 || depth > 16)
            return;
        auto nameBuilder = appender!string();
        auto targetBuilder = appender!string();
        size_t offset = 0;
        while (offset + 4 <= systemUse.length)
        {
            const signature = systemUse[offset .. offset + 2];
            const length = systemUse[offset + 2];
            if (length < 4 || offset + length > systemUse.length)
                break;
            auto data = systemUse[offset + 4 .. offset + length];

            if (signature[0] == 'R' && signature[1] == 'R')
            {
                _hasRockRidge = true;
            }
            else if (signature[0] == 'N' && signature[1] == 'M' && data.length >= 1)
            {
                _hasRockRidge = true;
                const flags = data[0];
                if ((flags & 0x08) != 0)
                    nameBuilder.put(""); // root marker
                else if ((flags & 0x02) != 0)
                    nameBuilder.put(".");
                else if ((flags & 0x04) != 0)
                    nameBuilder.put("..");
                else if (data.length > 1)
                    nameBuilder.put(cast(string) data[1 .. $].dup);
            }
            else if (signature[0] == 'P' && signature[1] == 'X' && data.length >= 4)
            {
                _hasRockRidge = true;
                const mode = readLe32(data, 0);
                if ((mode & 0xF000) == 0xA000)
                    symlink = true;
            }
            else if (signature[0] == 'S' && signature[1] == 'L' && data.length >= 1)
            {
                _hasRockRidge = true;
                symlink = true;
                parseSymlinkComponents(data[1 .. $], targetBuilder);
            }
            else if (signature[0] == 'C' && signature[1] == 'E' && data.length >= 24)
            {
                const block = readBoth32(data, 0);
                const dataOffset = readBoth32(data, 8);
                const dataLength = readBoth32(data, 16);
                auto continuation = readAt(cast(ulong) block * _blockSize + dataOffset,
                    dataLength);
                string nestedName;
                bool nestedSymlink;
                string nestedTarget;
                scanRockRidge(continuation, nestedName, nestedSymlink, nestedTarget,
                    depth + 1);
                if (nestedName.length > 0)
                    nameBuilder.put(nestedName);
                if (nestedSymlink)
                    symlink = true;
                if (nestedTarget.length > 0)
                    targetBuilder.put(nestedTarget);
            }
            offset += length;
        }

        if (nameBuilder.data.length > 0)
            name = nameBuilder.data;
        if (targetBuilder.data.length > 0)
            target = targetBuilder.data;
    }

    private static void parseSymlinkComponents(const(ubyte)[] data, ref Appender!string output)
    {
        size_t offset = 0;
        while (offset + 2 <= data.length)
        {
            const flags = data[offset];
            const length = data[offset + 1];
            offset += 2;
            if (offset + length > data.length)
                break;
            auto component = data[offset .. offset + length];
            offset += length;
            if ((flags & 0x01) != 0) // continue from previous component
            {
                output.put(cast(string) component.dup);
                continue;
            }
            if (output.data.length > 0)
                output.put("/");
            if ((flags & 0x08) != 0)
                output.put("/");
            else if ((flags & 0x10) != 0)
                output.put("..");
            else if ((flags & 0x20) != 0)
                output.put("~");
            else
                output.put(cast(string) component.dup);
        }
    }

    // ----- Raw I/O -----------------------------------------------------------

    private ubyte[] readAt(ulong offset, size_t length) @trusted
    {
        if (length == 0)
            return [];
        auto buffer = new ubyte[length];
        try
        {
            _file.seek(offset);
            auto read = _file.rawRead(buffer);
            if (read.length < length)
                buffer.length = read.length;
        }
        catch (StdioException error)
        {
            throw new IsoFormatException("Read error at offset " ~ offset.to!string ~
                ": " ~ error.msg);
        }
        return buffer;
    }

    private static bool equalsIgnoreCase(string a, string b)
    {
        if (a.length != b.length)
            return false;
        foreach (i; 0 .. a.length)
        {
            char ca = a[i];
            char cb = b[i];
            if (ca >= 'A' && ca <= 'Z') ca = cast(char)(ca + 32);
            if (cb >= 'A' && cb <= 'Z') cb = cast(char)(cb + 32);
            if (ca != cb)
                return false;
        }
        return true;
    }
}

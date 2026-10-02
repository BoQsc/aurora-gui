/**
 * Independent ISO 9660 (ECMA-119) image writer.
 *
 * Builds a standards-compliant image from a directory tree, with:
 *   - a Primary Volume Descriptor (plain ISO names),
 *   - an optional Joliet supplementary descriptor for long/Unicode names,
 *   - optional Rock Ridge "NM" entries recording the original file names.
 *
 * File data is shared between the primary and Joliet trees, while each tree
 * gets its own directory extents and path tables, exactly as the standard
 * requires. No external tools are used.
 */
module auroraiso.iso.writer;

import auroraiso.iso.endian;
import auroraiso.iso.structures;
import std.algorithm : min, sort;
import std.array : appender, Appender;
import std.conv : to;
import std.datetime : Clock;
import std.file : DirEntry, SpanMode, dirEntries;
import std.path : baseName;
import std.stdio : File;
import std.string : lastIndexOf, toLower, toUpper;

/// Options controlling image creation.
struct IsoWriterOptions
{
    string volumeId = "AURORA_ISO";
    string applicationId = "AURORA-ISO WRITER";
    bool joliet = true;
    bool rockRidge = true;
}

/// Outcome of an image creation run.
struct IsoWriteResult
{
    bool ok;
    string error;
    ulong bytesWritten;
    uint totalSectors;
    uint fileCount;
    uint directoryCount;
}

private final class WNode
{
    string name;
    bool isDirectory;
    string sourcePath;
    ulong size;
    WNode[] children;

    string isoName;
    string jolietName;

    WNode parent;
    uint dirNumber;
    uint parentNumber;

    uint primaryExtent;
    uint jolietExtent;
    uint primaryDataLength;
    uint jolietDataLength;

    uint dataExtent; // files only
}

/// Create an ISO 9660 image at `outputPath` from the tree rooted at `sourceDir`.
IsoWriteResult createIsoFromDirectory(string sourceDir, string outputPath,
    IsoWriterOptions options = IsoWriterOptions.init,
    scope void delegate(double fraction) onProgress = null,
    scope bool delegate() cancel = null)
{
    IsoWriteResult result;
    try
    {
        auto root = scanDirectory(sourceDir, "");
        assignNames(root);
        auto directories = orderDirectories(root);
        auto files = collectFiles(directories);

        // Compute directory data sizes using placeholder extents.
        foreach (dir; directories)
        {
            dir.primaryDataLength = cast(uint) packRecords(buildRecords(dir, false, false, options.rockRidge)).length;
            if (options.joliet)
                dir.jolietDataLength = cast(uint) packRecords(buildRecords(dir, true, false, options.rockRidge)).length;
        }

        auto primaryPathTable = buildPathTable(directories, false, false, root);
        auto primaryPathTableM = buildPathTable(directories, false, true, root);
        ubyte[] jolietPathTableL;
        ubyte[] jolietPathTableM;
        if (options.joliet)
        {
            jolietPathTableL = buildPathTable(directories, true, false, root);
            jolietPathTableM = buildPathTable(directories, true, true, root);
        }

        const descriptorCount = options.joliet ? 3u : 2u; // PVD (+SVD) + terminator
        uint lba = isoFirstDescriptorLba + descriptorCount;

        const primaryPtL = lba;
        lba += sectorsFor(primaryPathTable.length);
        const primaryPtM = lba;
        lba += sectorsFor(primaryPathTableM.length);
        uint jolietPtL;
        uint jolietPtM;
        if (options.joliet)
        {
            jolietPtL = lba;
            lba += sectorsFor(jolietPathTableL.length);
            jolietPtM = lba;
            lba += sectorsFor(jolietPathTableM.length);
        }

        foreach (dir; directories)
        {
            dir.primaryExtent = lba;
            lba += sectorsFor(dir.primaryDataLength);
        }
        if (options.joliet)
        {
            foreach (dir; directories)
            {
                dir.jolietExtent = lba;
                lba += sectorsFor(dir.jolietDataLength);
            }
        }
        foreach (file; files)
        {
            file.dataExtent = lba;
            lba += sectorsFor(cast(uint) file.size);
        }

        const volumeSpace = lba;
        const volumeId = sanitizeVolumeId(options.volumeId);

        auto rootRecordPrimary = buildRecord([0x00], root.primaryExtent,
            root.primaryDataLength, fileFlagDirectory, null);
        rootRecordPrimary.length = 34;
        auto rootRecordJoliet = buildRecord([0x00], root.jolietExtent,
            root.jolietDataLength, fileFlagDirectory, null);
        rootRecordJoliet.length = 34;

        auto pvd = buildDescriptor(false, volumeId, options.applicationId,
            volumeSpace, isoBlockSize, cast(uint) primaryPathTable.length,
            primaryPtL, primaryPtM, rootRecordPrimary);
        ubyte[] svd;
        if (options.joliet)
            svd = buildDescriptor(true, volumeId, options.applicationId,
                volumeSpace, isoBlockSize, cast(uint) jolietPathTableL.length,
                jolietPtL, jolietPtM, rootRecordJoliet);

        auto terminator = new ubyte[isoBlockSize];
        terminator[0] = vdTerminator;
        terminator[1 .. 6] = cast(ubyte[]) "CD001";
        terminator[6] = 1;

        auto output = File(outputPath, "wb");

        // System area: 16 empty sectors.
        output.rawWrite(new ubyte[isoFirstDescriptorLba * isoBlockSize]);
        output.rawWrite(pvd);
        if (options.joliet)
            output.rawWrite(svd);
        output.rawWrite(terminator);

        writePadded(output, primaryPathTable);
        writePadded(output, primaryPathTableM);
        if (options.joliet)
        {
            writePadded(output, jolietPathTableL);
            writePadded(output, jolietPathTableM);
        }

        foreach (dir; directories)
        {
            if (cancel !is null && cancel())
                throw new Exception("cancelled");
            writePadded(output, packRecords(buildRecords(dir, false, true, options.rockRidge)));
        }
        if (options.joliet)
        {
            foreach (dir; directories)
            {
                if (cancel !is null && cancel())
                    throw new Exception("cancelled");
                writePadded(output, packRecords(buildRecords(dir, true, true, options.rockRidge)));
            }
        }
        uint fileIndex = 0;
        foreach (file; files)
        {
            if (cancel !is null && cancel())
                throw new Exception("cancelled");
            writeFileData(output, file);
            ++fileIndex;
            if (onProgress !is null)
                onProgress(files.length == 0 ? 1.0 :
                    cast(double) fileIndex / cast(double) files.length);
        }
        output.close();

        result.ok = true;
        result.totalSectors = volumeSpace;
        result.fileCount = cast(uint) files.length;
        result.directoryCount = cast(uint) directories.length - 1;
        result.bytesWritten = cast(ulong) lba * isoBlockSize;
        if (onProgress !is null)
            onProgress(1.0);
    }
    catch (Exception error)
    {
        result.ok = false;
        result.error = error.msg;
    }
    return result;
}

// ----- Tree scanning ---------------------------------------------------------

private WNode scanDirectory(string directoryPath, string name)
{
    auto node = new WNode();
    node.name = name;
    node.isDirectory = true;

    DirEntry[] entries;
    foreach (entry; dirEntries(directoryPath, SpanMode.shallow))
    {
        if (entry.isSymlink)
            continue;
        entries ~= entry;
    }
    sort!((a, b) => a.name < b.name)(entries);

    foreach (entry; entries)
    {
        if (entry.isDir)
            node.children ~= scanDirectory(entry.name, baseName(entry.name));
        else if (entry.isFile)
        {
            auto file = new WNode();
            file.name = baseName(entry.name);
            file.isDirectory = false;
            file.sourcePath = entry.name;
            file.size = entry.size;
            node.children ~= file;
        }
    }
    return node;
}

private void assignNames(WNode directory)
{
    bool[string] used;
    foreach (child; directory.children)
    {
        child.isoName = uniqueIsoName(child.name, child.isDirectory, used);
        child.jolietName = sanitizeJolietName(child.name);
    }
    foreach (child; directory.children)
        if (child.isDirectory)
            assignNames(child);
}

private WNode[] orderDirectories(WNode root)
{
    WNode[] order;
    root.dirNumber = 1;
    root.parentNumber = 1;
    order ~= root;
    size_t index = 0;
    uint next = 1;
    while (index < order.length)
    {
        auto directory = order[index];
        ++index;
        foreach (child; directory.children)
        {
            if (child.isDirectory)
            {
                ++next;
                child.dirNumber = next;
                child.parentNumber = directory.dirNumber;
                child.parent = directory;
                order ~= child;
            }
        }
    }
    return order;
}

private WNode[] collectFiles(WNode[] directories)
{
    WNode[] files;
    foreach (directory; directories)
        foreach (child; directory.children)
            if (!child.isDirectory)
                files ~= child;
    return files;
}

// ----- Name handling ---------------------------------------------------------

private string sanitizeIsoName(string name, bool isDirectory)
{
    auto builder = appender!string();
    foreach (ch; name)
    {
        char c = ch;
        if (c >= 'a' && c <= 'z')
            c = cast(char)(c - 32);
        bool allowed = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
        if (c == '.' && !isDirectory)
            allowed = true;
        if (!allowed)
            c = '_';
        builder.put(c);
    }
    auto result = builder.data;
    if (result.length == 0)
        result = isDirectory ? "_DIR" : "_FILE";
    if (result.length > 30)
        result = result[0 .. 30];
    return result;
}

private string uniqueIsoName(string name, bool isDirectory, ref bool[string] used)
{
    auto base = sanitizeIsoName(name, isDirectory);
    auto candidate = base;
    int counter = 1;
    while ((candidate.toLower in used) !is null)
    {
        auto suffix = "_" ~ counter.to!string;
        candidate = applyIsoSuffix(base, suffix, isDirectory);
        ++counter;
    }
    used[candidate.toLower] = true;
    return candidate;
}

/// Insert a disambiguation suffix before the extension so names stay readable.
private string applyIsoSuffix(string base, string suffix, bool isDirectory)
{
    if (!isDirectory)
    {
        const dot = base.lastIndexOf('.');
        if (dot > 0)
        {
            auto stem = base[0 .. dot];
            auto extension = base[dot .. $];
            auto room = 30 - cast(int)(suffix.length + extension.length);
            if (room < 1)
                room = 1;
            if (cast(int) stem.length > room)
                stem = stem[0 .. room];
            return stem ~ suffix ~ extension;
        }
    }
    const room = 30 - cast(int) suffix.length;
    auto trimmed = cast(int) base.length > room ? base[0 .. room] : base;
    return trimmed ~ suffix;
}

private string sanitizeJolietName(string name)
{
    auto builder = appender!string();
    foreach (ch; name)
    {
        char c = ch;
        if (c == ';' || c == '/' || c == '\\')
            c = '_';
        builder.put(c);
    }
    auto result = builder.data;
    if (result.length == 0)
        result = "_";
    if (result.length > 64)
        result = result[0 .. 64];
    return result;
}

private string sanitizeVolumeId(string value)
{
    auto builder = appender!string();
    foreach (ch; value.toUpper)
    {
        char c = ch;
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            c = '_';
        builder.put(c);
    }
    auto result = builder.data;
    if (result.length == 0)
        result = "AURORA_ISO";
    if (result.length > 32)
        result = result[0 .. 32];
    return result;
}

private ubyte[] ucs2(string value)
{
    auto builder = appender!(ubyte[])();
    foreach (dchar c; value)
    {
        if (c < 0x10000)
        {
            builder.put(cast(ubyte)(c >> 8));
            builder.put(cast(ubyte)(c & 0xFF));
        }
        else
        {
            const v = c - 0x10000;
            const hi = 0xD800 + (v >> 10);
            const lo = 0xDC00 + (v & 0x3FF);
            builder.put(cast(ubyte)(hi >> 8));
            builder.put(cast(ubyte)(hi & 0xFF));
            builder.put(cast(ubyte)(lo >> 8));
            builder.put(cast(ubyte)(lo & 0xFF));
        }
    }
    return builder.data;
}

private ubyte[] asciiBytes(string value)
{
    auto builder = appender!(ubyte[])();
    foreach (ch; value)
        builder.put(cast(ubyte) ch);
    return builder.data;
}

// ----- Record building -------------------------------------------------------

private ubyte[] buildRecord(const(ubyte)[] identifier, uint extent, uint dataLength,
    ubyte flags, const(ubyte)[] systemUse)
{
    const idLength = cast(uint) identifier.length;
    const suLength = systemUse is null ? 0u : cast(uint) systemUse.length;
    uint length = 33 + idLength + (idLength & 1) + suLength;
    if ((length & 1) != 0)
        ++length;
    if (length > 255)
        throw new Exception("ISO 9660 directory record exceeds 255 bytes");

    auto record = new ubyte[length];
    record[0] = cast(ubyte) length;
    record[1] = 0;
    writeBoth32(record, 2, extent);
    writeBoth32(record, 10, dataLength);
    const now = Clock.currTime();
    record[18] = cast(ubyte)(now.year - 1900);
    record[19] = cast(ubyte) now.month;
    record[20] = cast(ubyte) now.day;
    record[21] = cast(ubyte) now.hour;
    record[22] = cast(ubyte) now.minute;
    record[23] = cast(ubyte) now.second;
    record[24] = 0;
    record[25] = flags;
    record[26] = 0;
    record[27] = 0;
    writeBoth16(record, 28, 1);
    record[32] = cast(ubyte) idLength;
    foreach (i; 0 .. idLength)
        record[33 + i] = identifier[i];
    if (suLength > 0)
    {
        const suStart = 33 + idLength + (idLength & 1);
        foreach (i; 0 .. suLength)
            record[suStart + i] = systemUse[i];
    }
    return record;
}

private ubyte[] rockRidgeName(string name)
{
    auto builder = appender!(ubyte[])();
    size_t start = 0;
    do
    {
        const room = 250u;
        auto take = cast(size_t) min(cast(size_t) room, name.length - start);
        const more = start + take < name.length;
        builder.put('N');
        builder.put('M');
        builder.put(cast(ubyte)(5 + take));
        builder.put(cast(ubyte) 1);
        builder.put(more ? cast(ubyte) 0x01 : cast(ubyte) 0x00);
        foreach (i; 0 .. take)
            builder.put(cast(ubyte) name[start + i]);
        start += take;
        if (!more)
            break;
    }
    while (true);
    return builder.data;
}

private ubyte[][] buildRecords(WNode directory, bool joliet, bool realExtents,
    bool rockRidge)
{
    ubyte[][] records;
    const selfExtent = realExtents
        ? (joliet ? directory.jolietExtent : directory.primaryExtent) : 0;
    const selfLength = realExtents
        ? (joliet ? directory.jolietDataLength : directory.primaryDataLength) : 0;
    const parent = directory.parent;
    const parentExtent = parent is null ? selfExtent : (realExtents
        ? (joliet ? parent.jolietExtent : parent.primaryExtent) : 0);
    const parentLength = parent is null ? selfLength : (realExtents
        ? (joliet ? parent.jolietDataLength : parent.primaryDataLength) : 0);

    records ~= buildRecord([0x00], selfExtent, selfLength, fileFlagDirectory, null);
    records ~= buildRecord([0x01], parentExtent, parentLength, fileFlagDirectory, null);

    foreach (child; directory.children)
    {
        if (child.isDirectory)
        {
            const extent = realExtents
                ? (joliet ? child.jolietExtent : child.primaryExtent) : 0;
            const dataLength = realExtents
                ? (joliet ? child.jolietDataLength : child.primaryDataLength) : 0;
            auto identifier = joliet ? ucs2(child.jolietName) : asciiBytes(child.isoName);
            ubyte[] systemUse = (rockRidge && !joliet && child.name != child.isoName)
                ? rockRidgeName(child.name) : null;
            records ~= buildRecord(identifier, extent, dataLength, fileFlagDirectory,
                systemUse);
        }
        else
        {
            const extent = realExtents ? child.dataExtent : 0;
            const dataLength = cast(uint) child.size;
            auto identifier = joliet ? ucs2(child.jolietName) :
                asciiBytes(child.isoName ~ ";1");
            ubyte[] systemUse = (rockRidge && !joliet && child.name != child.isoName)
                ? rockRidgeName(child.name) : null;
            records ~= buildRecord(identifier, extent, dataLength, 0, systemUse);
        }
    }
    return records;
}

private ubyte[] packRecords(ubyte[][] records)
{
    auto builder = appender!(ubyte[])();
    size_t offsetInSector = 0;
    foreach (record; records)
    {
        if (record.length == 0)
            continue;
        const remaining = isoBlockSize - offsetInSector;
        if (record.length > remaining)
        {
            builder.put(new ubyte[remaining]);
            offsetInSector = 0;
        }
        builder.put(record);
        offsetInSector += record.length;
        if (offsetInSector == isoBlockSize)
            offsetInSector = 0;
    }
    if (offsetInSector != 0)
        builder.put(new ubyte[isoBlockSize - offsetInSector]);
    if (builder.data.length == 0)
        builder.put(new ubyte[isoBlockSize]);
    return builder.data;
}

private ubyte[] buildPathTable(WNode[] directories, bool joliet, bool bigEndian,
    WNode root)
{
    auto builder = appender!(ubyte[])();
    foreach (directory; directories)
    {
        ubyte[] nameBytes;
        if (directory is root)
            nameBytes = [cast(ubyte) 0x00];
        else
            nameBytes = joliet ? ucs2(directory.jolietName) : asciiBytes(directory.isoName);
        const extent = joliet ? directory.jolietExtent : directory.primaryExtent;

        auto record = appender!(ubyte[])();
        record.put(cast(ubyte) nameBytes.length);
        record.put(cast(ubyte) 0);
        auto extentBytes = new ubyte[4];
        if (bigEndian)
            writeBe32(extentBytes, 0, extent);
        else
            writeLe32(extentBytes, 0, extent);
        record.put(extentBytes);
        auto parentBytes = new ubyte[2];
        if (bigEndian)
            writeBe16(parentBytes, 0, cast(ushort) directory.parentNumber);
        else
            writeLe16(parentBytes, 0, cast(ushort) directory.parentNumber);
        record.put(parentBytes);
        record.put(nameBytes);
        if ((record.data.length & 1) != 0)
            record.put(cast(ubyte) 0);
        builder.put(record.data);
    }
    return builder.data;
}

private ubyte[] buildDescriptor(bool supplementary, string volumeId,
    string applicationId, uint volumeSpace, uint blockSize, uint pathTableSize,
    uint pathTableL, uint pathTableM, const(ubyte)[] rootRecord)
{
    auto sector = new ubyte[isoBlockSize];
    sector[0] = supplementary ? vdSupplementary : vdPrimary;
    sector[1] = 'C';
    sector[2] = 'D';
    sector[3] = '0';
    sector[4] = '0';
    sector[5] = '1';
    sector[6] = 1;

    fillSpaces(sector, 8, 32);   // system identifier
    fillSpaces(sector, 40, 32);  // volume identifier
    writeAsciiField(sector, 40, 32, volumeId);

    if (supplementary)
    {
        sector[88] = '%';
        sector[89] = '/';
        sector[90] = 'E'; // Joliet level 3
    }

    writeBoth16(sector, 120, 1);                 // volume set size
    writeBoth16(sector, 124, 1);                 // volume sequence number
    writeBoth16(sector, 128, cast(ushort) blockSize);
    writeBoth32(sector, 80, volumeSpace);        // volume space size (in blocks)
    writeBoth32(sector, 132, pathTableSize);
    writeLe32(sector, 140, pathTableL);
    writeLe32(sector, 144, 0);
    writeBe32(sector, 148, pathTableM);
    writeBe32(sector, 152, 0);

    foreach (i; 0 .. rootRecord.length)
        sector[156 + i] = rootRecord[i];

    fillSpaces(sector, 190, 128); // volume set identifier
    fillSpaces(sector, 318, 128); // publisher identifier
    fillSpaces(sector, 446, 128); // data preparer identifier
    fillSpaces(sector, 574, 128); // application identifier
    writeAsciiField(sector, 574, 128, applicationId);
    fillSpaces(sector, 702, 37);  // copyright file identifier
    fillSpaces(sector, 739, 37);  // abstract file identifier
    fillSpaces(sector, 776, 37);  // bibliographic file identifier

    writeVolumeDate(sector, 813);
    writeVolumeDate(sector, 830);
    fillZeroDate(sector, 847);
    fillZeroDate(sector, 864);
    sector[881] = 1; // file structure version
    return sector;
}

private void fillSpaces(ubyte[] buffer, size_t offset, size_t length)
{
    foreach (i; 0 .. length)
        buffer[offset + i] = ' ';
}

private void writeAsciiField(ubyte[] buffer, size_t offset, size_t length, string value)
{
    fillSpaces(buffer, offset, length);
    const count = value.length < length ? value.length : length;
    foreach (i; 0 .. count)
        buffer[offset + i] = cast(ubyte) value[i];
}

private void writeVolumeDate(ubyte[] buffer, size_t offset)
{
    const now = Clock.currTime();
    putNumber(buffer, offset, 4, now.year);
    putNumber(buffer, offset + 4, 2, now.month);
    putNumber(buffer, offset + 6, 2, now.day);
    putNumber(buffer, offset + 8, 2, now.hour);
    putNumber(buffer, offset + 10, 2, now.minute);
    putNumber(buffer, offset + 12, 2, now.second);
    putNumber(buffer, offset + 14, 2, 0);
    buffer[offset + 16] = 0;
}

private void fillZeroDate(ubyte[] buffer, size_t offset)
{
    putNumber(buffer, offset, 4, 0);
    putNumber(buffer, offset + 4, 2, 0);
    putNumber(buffer, offset + 6, 2, 0);
    putNumber(buffer, offset + 8, 2, 0);
    putNumber(buffer, offset + 10, 2, 0);
    putNumber(buffer, offset + 12, 2, 0);
    putNumber(buffer, offset + 14, 2, 0);
    buffer[offset + 16] = 0;
}

private void putNumber(ubyte[] buffer, size_t offset, int width, long value)
{
    foreach (i; 0 .. width)
    {
        const divisor = cast(long) pow10(width - 1 - i);
        const digit = divisor == 0 ? 0 : (value / divisor) % 10;
        buffer[offset + i] = cast(ubyte)('0' + digit);
    }
}

private long pow10(int power)
{
    long result = 1;
    foreach (i; 0 .. power)
        result *= 10;
    return result;
}

// ----- Output helpers --------------------------------------------------------

private uint sectorsFor(size_t bytes)
{
    return cast(uint)((bytes + isoBlockSize - 1) / isoBlockSize);
}

private void writePadded(File output, const(ubyte)[] data)
{
    if (data.length == 0)
        return;
    output.rawWrite(data);
    const padding = (isoBlockSize - (data.length % isoBlockSize)) % isoBlockSize;
    if (padding > 0)
        output.rawWrite(new ubyte[padding]);
}

private void writeFileData(File output, WNode file)
{
    auto input = File(file.sourcePath, "rb");
    auto buffer = new ubyte[1 << 20];
    ulong remaining = file.size;
    while (remaining > 0)
    {
        auto want = cast(size_t) min(cast(ulong) buffer.length, remaining);
        auto got = input.rawRead(buffer[0 .. want]);
        if (got.length == 0)
            break;
        output.rawWrite(got);
        remaining -= got.length;
    }
    const padding = (isoBlockSize - (file.size % isoBlockSize)) % isoBlockSize;
    if (padding > 0)
        output.rawWrite(new ubyte[cast(size_t) padding]);
}

unittest
{
    assert(sanitizeIsoName("hello world.txt", false) == "HELLO_WORLD.TXT");
    assert(sanitizeIsoName("readme", true) == "README");
    assert(sanitizeIsoName("a/b", false) == "A_B");
    assert(sanitizeVolumeId("my volume!") == "MY_VOLUME_");
    assert(ucs2("A").length == 2);

    bool[string] used;
    assert(uniqueIsoName("file.txt", false, used) == "FILE.TXT");
    assert(uniqueIsoName("FILE.TXT", false, used) == "FILE_1.TXT");
}

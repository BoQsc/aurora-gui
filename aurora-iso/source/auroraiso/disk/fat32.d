/**
 * FAT32 formatter and file writer, written from scratch.
 *
 * FAT32 is the common denominator Windows and Linux both mount natively, and
 * UEFI firmware boots from it. This module can format a volume and populate it
 * with files and directories (including long file names) without any native
 * formatting API. A matching reader is included so the writer can be validated
 * from the on-disk bytes alone.
 */
module auroraiso.disk.fat32;

import auroraiso.disk.bytes;
import auroraiso.disk.device;
import std.algorithm : min;
import std.array : appender, split;
import std.ascii : isAlpha, isDigit, toLower, toUpper;
import std.conv : to;
import std.utf : toUTF16, toUTF8;

/// FAT32 volume geometry, derived from the volume size.
struct Fat32Geometry
{
    uint bytesPerSector;
    uint sectorsPerCluster;
    uint reservedSectors;
    uint numFats;
    uint fatSizeSectors;
    uint rootCluster;
    ulong totalSectors;

    ulong fatStartSector() const { return reservedSectors; }
    ulong dataStartSector() const
    {
        return reservedSectors + cast(ulong) numFats * fatSizeSectors;
    }
    uint clusterCount() const
    {
        return cast(uint) ((totalSectors - dataStartSector()) / sectorsPerCluster);
    }
    ulong volumeBytes() const { return totalSectors * bytesPerSector; }
}

/// Absolute byte offset of a cluster inside the volume.
ulong fat32ClusterOffset(const Fat32Geometry g, uint cluster)
{
    return (g.dataStartSector() +
        cast(ulong) (cluster - 2) * g.sectorsPerCluster) * g.bytesPerSector;
}

/// Pick a cluster size and FAT length that yields a valid FAT32 volume.
Fat32Geometry computeFat32Geometry(ulong totalSectors, uint bytesPerSector = 512,
    uint sectorsPerCluster = 0)
{
    if (sectorsPerCluster == 0)
    {
        const ulong bytes = totalSectors * bytesPerSector;
        if (bytes <= 260UL * 1024 * 1024)
            sectorsPerCluster = 1;
        else if (bytes <= 8UL * 1024 * 1024 * 1024)
            sectorsPerCluster = 8;
        else
            sectorsPerCluster = 64;
    }

    const uint reserved = 32;
    const uint numFats = 2;
    uint fatSize = 1;
    uint clusterCount = 0;
    // Grow the FAT until it is large enough; this converges (unlike an
    // equality check, which can oscillate between two sizes).
    foreach (_; 0 .. 64)
    {
        const ulong dataSectors = totalSectors - (reserved + cast(ulong) numFats * fatSize);
        clusterCount = cast(uint) (dataSectors / sectorsPerCluster);
        const ulong needed = (cast(ulong) clusterCount + 2) * 4;
        const uint newFatSize = cast(uint) ((needed + bytesPerSector - 1) / bytesPerSector);
        if (newFatSize <= fatSize)
            break;
        fatSize = newFatSize;
    }
    // Recompute the cluster count for the final FAT size.
    clusterCount = cast(uint) ((totalSectors - (reserved +
        cast(ulong) numFats * fatSize)) / sectorsPerCluster);

    if (clusterCount < 65525 && sectorsPerCluster > 1)
        return computeFat32Geometry(totalSectors, bytesPerSector, 1);
    if (clusterCount < 65525)
        throw new Exception("volume too small for FAT32");

    Fat32Geometry g;
    g.bytesPerSector = bytesPerSector;
    g.sectorsPerCluster = sectorsPerCluster;
    g.reservedSectors = reserved;
    g.numFats = numFats;
    g.fatSizeSectors = fatSize;
    g.rootCluster = 2;
    g.totalSectors = totalSectors;
    return g;
}

/// Format an empty FAT32 volume on `vol` and return its geometry.
Fat32Geometry formatFat32(BlockDevice vol, string label = "AURORA",
    uint sectorsPerCluster = 0, uint volumeSerial = 0x1A2B3C4D)
{
    const uint bps = vol.sectorSize() != 0 ? vol.sectorSize() : 512;
    const ulong totalSectors = vol.size() / bps;
    auto g = computeFat32Geometry(totalSectors, bps, sectorsPerCluster);

    auto boot = new ubyte[bps];
    boot[0] = 0xEB;
    boot[1] = 0x58;
    boot[2] = 0x90;
    putAscii(boot, 3, "AURORA  ");
    putU16(boot, 11, cast(ushort) g.bytesPerSector);
    boot[13] = cast(ubyte) g.sectorsPerCluster;
    putU16(boot, 14, cast(ushort) g.reservedSectors);
    boot[16] = cast(ubyte) g.numFats;
    putU16(boot, 17, 0);
    putU16(boot, 19, 0);
    boot[21] = 0xF8;
    putU16(boot, 22, 0);
    putU16(boot, 24, 32);
    putU16(boot, 26, 64);
    putU32(boot, 28, 0);
    putU32(boot, 32, g.totalSectors > 0xFFFFFFFF ? 0xFFFFFFFF : cast(uint) g.totalSectors);
    putU32(boot, 36, g.fatSizeSectors);
    putU16(boot, 40, 0);
    putU16(boot, 42, 0);
    putU32(boot, 44, g.rootCluster);
    putU16(boot, 48, 1);
    putU16(boot, 50, 6);
    boot[64] = 0x80;
    boot[66] = 0x29;
    putU32(boot, 67, volumeSerial);
    auto labelBytes = fitLabelBytes(label);
    putBytes(boot, 71, labelBytes[]);
    putAscii(boot, 82, "FAT32   ");
    boot[bps - 2] = 0x55;
    boot[bps - 1] = 0xAA;
    vol.write(0, boot);

    auto fsinfo = new ubyte[bps];
    putU32(fsinfo, 0, 0x41615252);
    putU32(fsinfo, 484, 0x61417272);
    putU32(fsinfo, 488, 0xFFFFFFFF);
    putU32(fsinfo, 492, 0xFFFFFFFF);
    fsinfo[bps - 2] = 0x55;
    fsinfo[bps - 1] = 0xAA;
    vol.write(cast(ulong) bps * 1, fsinfo);
    vol.write(cast(ulong) bps * 6, boot);
    vol.write(cast(ulong) bps * 7, fsinfo);

    const ulong fatBytes = cast(ulong) g.fatSizeSectors * bps;
    auto zero = new ubyte[bps];
    foreach (f; 0 .. g.numFats)
    {
        const ulong fatOffset = (g.reservedSectors + cast(ulong) f * g.fatSizeSectors) * bps;
        ulong done = 0;
        while (done < fatBytes)
        {
            auto chunk = min(cast(ulong) bps, fatBytes - done);
            vol.write(fatOffset + done, zero[0 .. cast(size_t) chunk]);
            done += chunk;
        }
        auto first = new ubyte[12];
        putU32(first, 0, 0x0FFFFFF8);
        putU32(first, 4, 0x0FFFFFFF);
        putU32(first, 8, 0x0FFFFFFF);
        vol.write(fatOffset, first);
    }

    auto rootZero = new ubyte[cast(size_t) g.sectorsPerCluster * bps];
    vol.write(fat32ClusterOffset(g, g.rootCluster), rootZero);

    auto writer = new Fat32Writer(vol, g);
    if (label.length > 0)
        writer.addVolumeLabel(label);

    vol.flush();
    return g;
}

/// Writer that populates a freshly formatted FAT32 volume.
final class Fat32Writer
{
    private BlockDevice vol;
    private Fat32Geometry g;
    private uint nextFree = 3;
    private uint shortCounter;

    this(BlockDevice vol, Fat32Geometry g)
    {
        this.vol = vol;
        this.g = g;
    }

    private ulong clusterOffset(uint cluster) const
    {
        return fat32ClusterOffset(g, cluster);
    }

    private size_t clusterBytes() const
    {
        return cast(size_t) g.sectorsPerCluster * g.bytesPerSector;
    }

    private uint readFat(uint cluster)
    {
        ubyte[4] raw;
        vol.read(g.fatStartSector() * g.bytesPerSector + cast(ulong) cluster * 4, raw[]);
        return getU32(raw[], 0) & 0x0FFFFFFF;
    }

    private void writeFat(uint cluster, uint value)
    {
        ubyte[4] raw;
        putU32(raw[], 0, value & 0x0FFFFFFF);
        foreach (f; 0 .. g.numFats)
            vol.write((g.reservedSectors + cast(ulong) f * g.fatSizeSectors) *
                g.bytesPerSector + cast(ulong) cluster * 4, raw[]);
    }

    private uint allocCluster()
    {
        const count = g.clusterCount();
        for (uint c = nextFree; c < count + 2; ++c)
        {
            if (readFat(c) == 0)
            {
                nextFree = c + 1;
                writeFat(c, 0x0FFFFFFF);
                auto zeros = new ubyte[clusterBytes()];
                vol.write(clusterOffset(c), zeros);
                return c;
            }
        }
        throw new Exception("FAT32: out of free clusters");
    }

    private uint[] chain(uint start)
    {
        uint[] result;
        uint c = start;
        size_t guard;
        while (c >= 2 && c < 0x0FFFFFF8 && guard < 1_000_000)
        {
            result ~= c;
            c = readFat(c);
            ++guard;
        }
        if (c >= 2 && c < 0x0FFFFFF8)
            throw new Exception("FAT32: cluster chain loop");
        return result;
    }

    private ubyte[] readChain(uint start)
    {
        auto clusters = chain(start);
        auto buffer = new ubyte[clusters.length * clusterBytes()];
        foreach (i, c; clusters)
            vol.read(clusterOffset(c), buffer[i * clusterBytes() .. (i + 1) * clusterBytes()]);
        return buffer;
    }

    private void appendEntries(uint dirCluster, ubyte[] entries)
    {
        auto clusters = chain(dirCluster);
        foreach (c; clusters)
        {
            auto data = new ubyte[clusterBytes()];
            vol.read(clusterOffset(c), data);
            for (size_t off = 0; off + 32 <= data.length; off += 32)
            {
                if ((data[off] == 0x00 || data[off] == 0xE5) &&
                    off + entries.length <= data.length)
                {
                    data[off .. off + entries.length] = entries[];
                    vol.write(clusterOffset(c), data);
                    return;
                }
            }
        }
        auto last = clusters[$ - 1];
        auto newCluster = allocCluster();
        writeFat(last, newCluster);
        auto data = new ubyte[clusterBytes()];
        data[0 .. entries.length] = entries[];
        vol.write(clusterOffset(newCluster), data);
    }

    private struct Found
    {
        bool ok;
        bool isDir;
        uint cluster;
        ulong size;
    }

    private Found findEntry(uint dirCluster, string name)
    {
        auto data = readChain(dirCluster);
        string lfn;
        foreach (slot; 0 .. data.length / 32)
        {
            auto e = data[slot * 32 .. slot * 32 + 32];
            if (e[0] == 0x00)
                break;
            if (e[0] == 0xE5)
            {
                lfn = "";
                continue;
            }
            auto attr = e[11];
            if (attr == 0x0F)
            {
                lfn = lfnPart(e) ~ lfn;
                continue;
            }
            if ((attr & 0x08) && !(attr & 0x10))
            {
                lfn = "";
                continue;
            }
            auto full = lfn.length > 0 ? lfn : sfnToString(e);
            if (equalsIgnoreCase(full, name))
            {
                Found f;
                f.ok = true;
                f.isDir = (attr & 0x10) != 0;
                f.cluster = (cast(uint) getU16(e, 20) << 16) | getU16(e, 26);
                f.size = getU32(e, 28);
                return f;
            }
            lfn = "";
        }
        return Found.init;
    }

    private uint resolveDir(string[] parts, bool create)
    {
        uint current = g.rootCluster;
        foreach (part; parts)
        {
            if (part.length == 0)
                continue;
            auto f = findEntry(current, part);
            if (f.ok && f.isDir)
            {
                current = f.cluster;
                continue;
            }
            if (f.ok && !f.isDir)
                throw new Exception("FAT32: path component is a file: " ~ part);
            if (!create)
                throw new Exception("FAT32: directory not found: " ~ part);
            current = createDirectory(current, part);
        }
        return current;
    }

    private uint createDirectory(uint parentCluster, string name)
    {
        auto cluster = allocCluster();
        auto dot = makeDotEntry(".", cluster);
        auto dotdot = makeDotEntry("..", parentCluster);
        auto data = new ubyte[clusterBytes()];
        data[0 .. 32] = dot[];
        data[32 .. 64] = dotdot[];
        vol.write(clusterOffset(cluster), data);
        appendEntries(parentCluster, buildEntries(name, 0x10, cluster, 0));
        return cluster;
    }

    /// Create a directory (and any missing parents).
    void mkdir(string path)
    {
        resolveDir(splitPath(path), true);
    }

    /// Write a file at `path`, creating parent directories as needed.
    void writeFile(string path, const(ubyte)[] data)
    {
        auto parts = splitPath(path);
        if (parts.length == 0)
            throw new Exception("FAT32: empty file path");
        auto name = parts[$ - 1];
        auto dirCluster = resolveDir(parts[0 .. $ - 1], true);
        auto firstCluster = writeData(data);
        appendEntries(dirCluster, buildEntries(name, 0x20, firstCluster, data.length));
    }

    private uint writeData(const(ubyte)[] data)
    {
        if (data.length == 0)
            return 0;
        const cb = clusterBytes();
        const needed = (data.length + cb - 1) / cb;
        auto clusters = new uint[needed];
        foreach (i; 0 .. needed)
            clusters[i] = allocCluster();
        foreach (i; 0 .. needed)
        {
            if (i + 1 < needed)
                writeFat(clusters[i], clusters[i + 1]);
            auto chunk = min(cb, data.length - i * cb);
            vol.write(clusterOffset(clusters[i]), data[i * cb .. i * cb + chunk]);
        }
        return clusters[0];
    }

    /// Add the volume-label directory entry (attribute 0x08) to the root.
    void addVolumeLabel(string label)
    {
        auto entry = new ubyte[32];
        auto name = fitLabelBytes(label);
        entry[0 .. 11] = name[];
        entry[11] = 0x08;
        appendEntries(g.rootCluster, entry);
    }

    private ubyte[] buildEntries(string name, ubyte attr, uint cluster, ulong size)
    {
        auto sn = makeShortName(name, shortCounter);
        auto result = appender!(ubyte[])();
        if (sn.needsLfn)
            result.put(buildLfn(name, sn.bytes[]));
        auto primary = new ubyte[32];
        primary[0 .. 11] = sn.bytes[];
        primary[11] = attr;
        putU16(primary, 14, 0x6000);
        putU16(primary, 16, 0x5C21);
        putU16(primary, 18, 0x5C21);
        putU16(primary, 20, cast(ushort) (cluster >> 16));
        putU16(primary, 22, 0x6000);
        putU16(primary, 24, 0x5C21);
        putU16(primary, 26, cast(ushort) (cluster & 0xFFFF));
        putU32(primary, 28, cast(uint) size);
        result.put(primary[]);
        return result.data;
    }

    private ubyte[] buildLfn(string name, const(ubyte)[] sfn)
    {
        auto wide = toUTF16(name);
        size_t charCount = wide.length;
        size_t groups = (charCount + 12) / 13;
        if (groups == 0)
            groups = 1;
        auto chars = new ushort[groups * 13];
        foreach (i; 0 .. chars.length)
            chars[i] = 0xFFFF;
        foreach (i; 0 .. charCount)
            chars[i] = cast(ushort) wide[i];
        if (charCount < chars.length)
            chars[charCount] = 0x0000;
        auto checksum = lfnChecksum(sfn);
        auto entries = new ubyte[groups * 32];
        foreach (seq; 0 .. groups)
        {
            auto groupIndex = groups - 1 - seq;
            auto e = entries[seq * 32 .. seq * 32 + 32];
            e[0] = cast(ubyte) (groupIndex + 1);
            if (groupIndex == groups - 1)
                e[0] |= 0x40;
            e[11] = 0x0F;
            e[12] = 0;
            e[13] = checksum;
            auto b = groupIndex * 13;
            putU16(e, 1, chars[b + 0]);
            putU16(e, 3, chars[b + 1]);
            putU16(e, 5, chars[b + 2]);
            putU16(e, 7, chars[b + 3]);
            putU16(e, 9, chars[b + 4]);
            putU16(e, 14, chars[b + 5]);
            putU16(e, 16, chars[b + 6]);
            putU16(e, 18, chars[b + 7]);
            putU16(e, 20, chars[b + 8]);
            putU16(e, 22, chars[b + 9]);
            putU16(e, 24, chars[b + 10]);
            putU16(e, 28, chars[b + 11]);
            putU16(e, 30, chars[b + 12]);
        }
        return entries;
    }
}

/// Reader used by the tests (and diagnostics) to validate a FAT32 volume.
final class Fat32Reader
{
    private BlockDevice vol;
    private Fat32Geometry g;

    this(BlockDevice vol)
    {
        this.vol = vol;
        this.g = readFat32Geometry(vol);
    }

    Fat32Geometry geometry() const { return g; }

    private ulong clusterOffset(uint cluster) const
    {
        return fat32ClusterOffset(g, cluster);
    }

    private size_t clusterBytes() const
    {
        return cast(size_t) g.sectorsPerCluster * g.bytesPerSector;
    }

    private uint readFat(uint cluster)
    {
        ubyte[4] raw;
        vol.read(g.fatStartSector() * g.bytesPerSector + cast(ulong) cluster * 4, raw[]);
        return getU32(raw[], 0) & 0x0FFFFFFF;
    }

    private ubyte[] readChain(uint start, ulong limit = ulong.max)
    {
        auto buffer = appender!(ubyte[])();
        uint c = start;
        size_t guard;
        while (c >= 2 && c < 0x0FFFFFF8 && guard < 1_000_000)
        {
            auto data = new ubyte[clusterBytes()];
            vol.read(clusterOffset(c), data);
            buffer.put(data);
            c = readFat(c);
            ++guard;
        }
        auto result = buffer.data;
        if (limit < result.length)
            result = result[0 .. cast(size_t) limit];
        return result;
    }

    /// Names (long names where present) of the entries in a directory.
    string[] listNames(uint dirCluster)
    {
        auto data = readChain(dirCluster);
        string[] names;
        string lfn;
        foreach (slot; 0 .. data.length / 32)
        {
            auto e = data[slot * 32 .. slot * 32 + 32];
            if (e[0] == 0x00)
                break;
            if (e[0] == 0xE5)
            {
                lfn = "";
                continue;
            }
            auto attr = e[11];
            if (attr == 0x0F)
            {
                lfn = lfnPart(e) ~ lfn;
                continue;
            }
            if ((attr & 0x08) && !(attr & 0x10))
            {
                lfn = "";
                continue;
            }
            names ~= (lfn.length > 0 ? lfn : sfnToString(e));
            lfn = "";
        }
        return names;
    }

    string[] listRootNames()
    {
        return listNames(g.rootCluster);
    }

    private bool find(uint dirCluster, string name, out bool isDir,
        out uint cluster, out ulong size)
    {
        auto data = readChain(dirCluster);
        string lfn;
        foreach (slot; 0 .. data.length / 32)
        {
            auto e = data[slot * 32 .. slot * 32 + 32];
            if (e[0] == 0x00)
                break;
            if (e[0] == 0xE5)
            {
                lfn = "";
                continue;
            }
            auto attr = e[11];
            if (attr == 0x0F)
            {
                lfn = lfnPart(e) ~ lfn;
                continue;
            }
            if ((attr & 0x08) && !(attr & 0x10))
            {
                lfn = "";
                continue;
            }
            auto full = lfn.length > 0 ? lfn : sfnToString(e);
            if (equalsIgnoreCase(full, name))
            {
                isDir = (attr & 0x10) != 0;
                cluster = (cast(uint) getU16(e, 20) << 16) | getU16(e, 26);
                size = getU32(e, 28);
                return true;
            }
            lfn = "";
        }
        return false;
    }

    /// Read a file by "/dir/name" path (leading slashes optional).
    ubyte[] readFile(string path)
    {
        auto parts = splitPath(path);
        if (parts.length == 0)
            throw new Exception("FAT32: empty path");
        uint current = g.rootCluster;
        foreach (i, part; parts)
        {
            bool isDir;
            uint cluster;
            ulong size;
            if (!find(current, part, isDir, cluster, size))
                throw new Exception("FAT32: not found: " ~ part);
            if (i + 1 < parts.length)
            {
                if (!isDir)
                    throw new Exception("FAT32: not a directory: " ~ part);
                current = cluster;
            }
            else
            {
                if (isDir)
                    throw new Exception("FAT32: is a directory: " ~ part);
                return readChain(cluster, size);
            }
        }
        throw new Exception("FAT32: empty path");
    }
}

/// Parse the geometry from a volume's boot sector.
Fat32Geometry readFat32Geometry(BlockDevice vol)
{
    auto boot = new ubyte[vol.sectorSize()];
    vol.read(0, boot);
    if (boot[510] != 0x55 || boot[511] != 0xAA)
        throw new Exception("FAT32: missing boot signature");
    Fat32Geometry g;
    g.bytesPerSector = getU16(boot, 11);
    g.sectorsPerCluster = boot[13];
    g.reservedSectors = getU16(boot, 14);
    g.numFats = boot[16];
    g.fatSizeSectors = getU32(boot, 36);
    g.rootCluster = getU32(boot, 44);
    g.totalSectors = getU32(boot, 32);
    return g;
}

// --- shared helpers -------------------------------------------------------

private ubyte[11] fitLabelBytes(string label)
{
    ubyte[11] bytes;
    bytes[] = ' ';
    size_t n = 0;
    foreach (ch; label)
    {
        if (n >= 11)
            break;
        bytes[n++] = cast(ubyte) toUpper(ch);
    }
    return bytes;
}

private string[] splitPath(string path)
{
    string[] parts;
    foreach (part; path.split('/'))
        if (part.length > 0)
            parts ~= part;
    return parts;
}

private ubyte[] makeDotEntry(string name, uint cluster)
{
    auto entry = new ubyte[32];
    entry[0 .. 11] = ' '; // the 8.3 name field is space-padded
    entry[0] = '.';
    if (name.length == 2)
        entry[1] = '.';
    entry[11] = 0x10;
    putU16(entry, 20, cast(ushort) (cluster >> 16));
    putU16(entry, 26, cast(ushort) (cluster & 0xFFFF));
    return entry;
}

private string sfnToString(const(ubyte)[] sfn)
{
    auto base = appender!string();
    foreach (i; 0 .. 8)
    {
        auto c = cast(char) sfn[i];
        if (c == ' ')
            break;
        base.put(c);
    }
    auto ext = appender!string();
    foreach (i; 8 .. 11)
    {
        auto c = cast(char) sfn[i];
        if (c == ' ')
            break;
        ext.put(c);
    }
    return ext.data.length > 0 ? base.data ~ "." ~ ext.data : base.data;
}

private string lfnPart(const(ubyte)[] e)
{
    wchar[] chars;
    void add(size_t off)
    {
        auto v = getU16(e, off);
        if (v != 0xFFFF && v != 0x0000)
            chars ~= cast(wchar) v;
    }
    add(1);
    add(3);
    add(5);
    add(7);
    add(9);
    add(14);
    add(16);
    add(18);
    add(20);
    add(22);
    add(24);
    add(28);
    add(30);
    return toUTF8(chars);
}

private ubyte lfnChecksum(const(ubyte)[] sfn)
{
    ubyte sum = 0;
    foreach (c; sfn)
        sum = cast(ubyte) (((sum & 1) << 7) + (sum >> 1) + c);
    return sum;
}

private bool equalsIgnoreCase(string a, string b)
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (toLower(a[i]) != toLower(b[i]))
            return false;
    return true;
}

private struct ShortName
{
    ubyte[11] bytes;
    bool needsLfn;
}

private string sanitizeShort(string s)
{
    auto result = appender!string();
    foreach (ch; s)
    {
        if (isAlpha(ch))
            result.put(toUpper(ch));
        else if (isDigit(ch))
            result.put(ch);
        else if (ch < 128)
        {
            if (ch == '$' || ch == '%' || ch == '\'' || ch == '-' || ch == '_' ||
                ch == '@' || ch == '~' || ch == '`' || ch == '!' || ch == '(' ||
                ch == ')' || ch == '{' || ch == '}' || ch == '^' || ch == '#' ||
                ch == '&')
                result.put(ch);
            else
                result.put('_');
        }
        else
            result.put('_');
    }
    return result.data;
}

private ShortName makeShortName(string name, ref uint counter)
{
    string base = name;
    string ext = "";
    long dot = -1;
    foreach (i, ch; name)
        if (ch == '.')
            dot = cast(long) i;
    if (dot > 0)
    {
        base = name[0 .. cast(size_t) dot];
        ext = name[cast(size_t) dot + 1 .. $];
    }
    auto baseSan = sanitizeShort(base);
    auto extSan = sanitizeShort(ext);

    ShortName result;
    result.bytes[] = ' ';
    bool fits = baseSan.length >= 1 && baseSan.length <= 8 && extSan.length <= 3;
    if (fits)
    {
        foreach (i, ch; baseSan)
            result.bytes[i] = cast(ubyte) ch;
        foreach (i, ch; extSan)
            result.bytes[8 + i] = cast(ubyte) ch;
    }
    else
    {
        auto stem = baseSan.length > 0 ? baseSan : "FILE";
        ++counter;
        auto num = to!string(counter);
        if (stem.length + 1 + num.length > 8)
            stem = stem[0 .. (8 - 1 - num.length)];
        if (stem.length == 0)
            stem = "F";
        auto shortBase = stem ~ "~" ~ num;
        foreach (i, ch; shortBase)
            result.bytes[i] = cast(ubyte) ch;
        auto extUse = extSan.length > 3 ? extSan[0 .. 3] : extSan;
        foreach (i, ch; extUse)
            result.bytes[8 + i] = cast(ubyte) ch;
    }

    auto display = sfnToString(result.bytes[]);
    result.needsLfn = name != display;
    return result;
}

unittest
{
    // Short name stays 8.3; long name needs an LFN entry.
    uint counter;
    auto shortName = makeShortName("BOOTX64.EFI", counter);
    assert(!shortName.needsLfn);
    assert(sfnToString(shortName.bytes[]) == "BOOTX64.EFI");

    auto longName = makeShortName("Fedora-Workstation-Live.iso", counter);
    assert(longName.needsLfn);
    assert(counter == 1);
}

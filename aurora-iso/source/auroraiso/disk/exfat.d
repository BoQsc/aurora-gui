/**
 * exFAT formatter, written from scratch.
 *
 * exFAT is the filesystem Windows and Linux both use for large removable media
 * (it has no 4 GiB file limit and no 32 GiB volume limit like FAT32). This
 * module lays down a valid, empty exFAT volume: boot region with checksum, FAT,
 * allocation bitmap, up-case table, and a root directory carrying the volume
 * label. A matching reader validates the result from the on-disk bytes.
 */
module auroraiso.disk.exfat;

import auroraiso.disk.bytes;
import auroraiso.disk.device;
import std.array : appender;
import std.utf : toUTF8;

/// exFAT volume geometry.
struct ExfatGeometry
{
    uint bytesPerSector;
    uint sectorsPerCluster;
    ulong totalSectors;
    uint fatOffset;
    uint fatLength;
    uint clusterHeapOffset;
    uint clusterCount;
    uint rootCluster;
    uint bitmapCluster;
    uint upcaseCluster;
}

/// Absolute byte offset of a cluster in the cluster heap.
ulong exfatClusterOffset(const ExfatGeometry g, uint cluster)
{
    return (cast(ulong) g.clusterHeapOffset +
        cast(ulong) (cluster - 2) * g.sectorsPerCluster) * g.bytesPerSector;
}

private ulong roundUp(ulong value, ulong multiple)
{
    if (multiple == 0)
        return value;
    return ((value + multiple - 1) / multiple) * multiple;
}

private ubyte log2u(uint value)
{
    ubyte result = 0;
    while ((1u << result) < value)
        ++result;
    return result;
}

/// The 60-byte ASCII up-case table used by exfatprogs (checksum 0x4E394AE1).
ubyte[] minimalUpcaseTable()
{
    auto bytes = appender!(ubyte[])();
    void put16(ushort v)
    {
        bytes.put(cast(ubyte) v);
        bytes.put(cast(ubyte) (v >> 8));
    }
    put16(0xFFFF);
    put16(0x0061); // identity for U+0000..U+0060
    foreach (c; 0x41 .. 0x5B)
        put16(cast(ushort) c); // U+0061..U+007A map to A..Z
    put16(0xFFFF);
    put16(0xFF85); // identity for U+007B..U+FFFF
    return bytes.data;
}

/// Rolling 32-bit checksum used for the boot region and the up-case table.
uint exfatChecksum(const(ubyte)[] data)
{
    uint sum = 0;
    foreach (b; data)
        sum = ((sum & 1) ? 0x80000000 : 0) + (sum >> 1) + b;
    return sum;
}

private uint exfatBootChecksum(const(ubyte)[] region, uint bytesPerSector)
{
    const uint numberOfBytes = bytesPerSector * 11;
    uint sum = 0;
    foreach (index; 0 .. numberOfBytes)
    {
        if (index == 106 || index == 107 || index == 112)
            continue;
        sum = ((sum & 1) ? 0x80000000 : 0) + (sum >> 1) + region[index];
    }
    return sum;
}

/// Choose geometry so the allocation bitmap fits in a single cluster.
ExfatGeometry computeExfatGeometry(ulong totalSectors, uint bytesPerSector = 512)
{
    const uint fatOffset = 24;
    uint spc = 8;
    uint clusterHeapOffset = 0;
    uint fatLength = 0;
    uint clusterCount = 0;
    while (true)
    {
        clusterHeapOffset = 32;
        foreach (_; 0 .. 32)
        {
            clusterCount = cast(uint) ((totalSectors - clusterHeapOffset) / spc);
            fatLength = cast(uint) (((cast(ulong) clusterCount + 2) * 4 +
                bytesPerSector - 1) / bytesPerSector);
            const uint minHeap = fatOffset + fatLength;
            const uint aligned = cast(uint) roundUp(minHeap, spc);
            if (aligned == clusterHeapOffset)
                break;
            clusterHeapOffset = aligned;
        }
        const ulong bitmapBytes = (cast(ulong) clusterCount + 7) / 8;
        if (bitmapBytes <= cast(ulong) spc * bytesPerSector && clusterCount >= 3)
            break;
        if (spc >= (1u << 25))
            throw new Exception("exFAT: volume too large for a single-cluster bitmap");
        spc *= 2;
    }

    ExfatGeometry g;
    g.bytesPerSector = bytesPerSector;
    g.sectorsPerCluster = spc;
    g.totalSectors = totalSectors;
    g.fatOffset = fatOffset;
    g.fatLength = fatLength;
    g.clusterHeapOffset = clusterHeapOffset;
    g.clusterCount = clusterCount;
    g.rootCluster = 4;
    g.bitmapCluster = 2;
    g.upcaseCluster = 3;
    return g;
}

/// Format an empty exFAT volume on `vol`.
ExfatGeometry formatExfat(BlockDevice vol, string label = "AURORA-DATA",
    uint volumeSerial = 0x51A2B3C4)
{
    const uint bps = vol.sectorSize() != 0 ? vol.sectorSize() : 512;
    const ulong totalSectors = vol.size() / bps;
    auto g = computeExfatGeometry(totalSectors, bps);

    auto boot = new ubyte[bps];
    boot[0] = 0xEB;
    boot[1] = 0x76;
    boot[2] = 0x90;
    putAscii(boot, 3, "EXFAT   ");
    putU64(boot, 64, 0); // partition offset (relative to this device)
    putU64(boot, 72, g.totalSectors);
    putU32(boot, 80, g.fatOffset);
    putU32(boot, 84, g.fatLength);
    putU32(boot, 88, g.clusterHeapOffset);
    putU32(boot, 92, g.clusterCount);
    putU32(boot, 96, g.rootCluster);
    putU32(boot, 100, volumeSerial);
    putU16(boot, 104, 0x0100);
    putU16(boot, 106, 0);
    boot[108] = 9; // bytes per sector shift (512)
    boot[109] = log2u(g.sectorsPerCluster);
    boot[110] = 1; // number of FATs
    boot[111] = 0x80; // drive select
    boot[112] = 0xFF; // percent in use (unknown)
    boot[bps - 2] = 0x55;
    boot[bps - 1] = 0xAA;

    // Boot region: sectors 0..10, then the checksum sector 11.
    auto region = new ubyte[11 * bps];
    region[0 .. bps] = boot[];
    vol.write(0, region);
    const checksum = exfatBootChecksum(region, bps);
    auto checksumSector = new ubyte[bps];
    foreach (i; 0 .. bps / 4)
        putU32(checksumSector, i * 4, checksum);
    vol.write(cast(ulong) bps * 11, checksumSector);

    // FAT: zero it, then mark the bitmap, up-case, and root clusters.
    const ulong fatBytes = cast(ulong) g.fatLength * bps;
    auto zero = new ubyte[bps];
    const ulong fatBase = cast(ulong) g.fatOffset * bps;
    ulong done = 0;
    while (done < fatBytes)
    {
        auto chunk = bps < fatBytes - done ? bps : cast(uint) (fatBytes - done);
        vol.write(fatBase + done, zero[0 .. chunk]);
        done += chunk;
    }
    auto fatHead = new ubyte[20];
    putU32(fatHead, 0, 0xFFFFFFF8);
    putU32(fatHead, 4, 0xFFFFFFFF);
    putU32(fatHead, 8, 0xFFFFFFFF); // cluster 2: bitmap
    putU32(fatHead, 12, 0xFFFFFFFF); // cluster 3: up-case
    putU32(fatHead, 16, 0xFFFFFFFF); // cluster 4: root directory
    vol.write(fatBase, fatHead);

    // Allocation bitmap (cluster 2): mark clusters 2, 3, and 4 in use.
    const size_t clusterBytes = cast(size_t) g.sectorsPerCluster * bps;
    auto bitmap = new ubyte[clusterBytes];
    bitmap[0] = 0x07;
    vol.write(exfatClusterOffset(g, g.bitmapCluster), bitmap);

    // Up-case table (cluster 3).
    auto upcase = new ubyte[clusterBytes];
    auto table = minimalUpcaseTable();
    upcase[0 .. table.length] = table[];
    vol.write(exfatClusterOffset(g, g.upcaseCluster), upcase);
    const upcaseChecksum = exfatChecksum(table);

    // Root directory (cluster 4).
    auto root = new ubyte[clusterBytes];
    size_t cursor = 0;

    if (label.length > 0)
    {
        auto entry = new ubyte[32];
        entry[0] = 0x83;
        size_t count = 0;
        wstring wide = "";
        foreach (ch; label)
        {
            if (count >= 11)
                break;
            wide ~= cast(wchar) ch;
            ++count;
        }
        entry[1] = cast(ubyte) count;
        foreach (i, c; wide)
            putU16(entry, 2 + i * 2, cast(ushort) c);
        // Note: the volume-label entry has no SetChecksum field; writing one
        // would overwrite the first label character.
        root[cursor .. cursor + 32] = entry[];
        cursor += 32;
    }

    {
        auto entry = new ubyte[32];
        entry[0] = 0x81;
        entry[1] = 0; // bitmap flags: first FAT
        putU32(entry, 20, g.bitmapCluster);
        putU64(entry, 24, (cast(ulong) g.clusterCount + 7) / 8);
        setEntryChecksum(entry);
        root[cursor .. cursor + 32] = entry[];
        cursor += 32;
    }

    {
        auto entry = new ubyte[32];
        entry[0] = 0x82;
        putU32(entry, 4, upcaseChecksum);
        putU32(entry, 20, g.upcaseCluster);
        putU64(entry, 24, table.length);
        setEntryChecksum(entry);
        root[cursor .. cursor + 32] = entry[];
        cursor += 32;
    }

    vol.write(exfatClusterOffset(g, g.rootCluster), root);
    vol.flush();
    return g;
}

private void setEntryChecksum(ubyte[] entry)
{
    ushort checksum = 0;
    foreach (i; 0 .. 32)
    {
        if (i == 2 || i == 3)
            continue;
        checksum = cast(ushort) (((checksum & 1) ? 0x8000 : 0) + (checksum >> 1) + entry[i]);
    }
    putU16(entry, 2, checksum);
}

/// Summary read back from an exFAT volume.
struct ExfatInfo
{
    string label;
    uint clusterCount;
    uint rootCluster;
    bool hasAllocationBitmap;
    bool hasUpcaseTable;
    bool bootChecksumOk;
    bool entryChecksumsOk;
}

/// Parse and validate an exFAT volume (used by the tests).
ExfatInfo readExfat(BlockDevice vol)
{
    const uint bps = vol.sectorSize() != 0 ? vol.sectorSize() : 512;
    auto region = new ubyte[11 * bps];
    vol.read(0, region);
    if (region[3] != 'E' || region[4] != 'X' || region[5] != 'F' ||
        region[6] != 'A' || region[7] != 'T')
        throw new Exception("exFAT: missing signature");

    ExfatInfo info;
    const expected = exfatBootChecksum(region, bps);
    auto checksumSector = new ubyte[bps];
    vol.read(cast(ulong) bps * 11, checksumSector);
    info.bootChecksumOk = getU32(checksumSector, 0) == expected;

    info.clusterCount = getU32(region, 92);
    info.rootCluster = getU32(region, 96);
    const uint clusterHeapOffset = getU32(region, 88);
    const uint sectorsPerCluster = 1u << region[109];
    const size_t clusterBytes = cast(size_t) sectorsPerCluster * bps;

    ExfatGeometry g;
    g.bytesPerSector = bps;
    g.sectorsPerCluster = sectorsPerCluster;
    g.clusterHeapOffset = clusterHeapOffset;

    auto root = new ubyte[clusterBytes];
    vol.read(exfatClusterOffset(g, info.rootCluster), root);
    info.entryChecksumsOk = true;
    for (size_t off = 0; off + 32 <= root.length; off += 32)
    {
        auto entry = root[off .. off + 32];
        if (entry[0] == 0x00)
            break;
        if (entry[0] == 0x83)
        {
            const count = entry[1] < 11 ? entry[1] : 11;
            wchar[] chars;
            foreach (i; 0 .. count)
                chars ~= cast(wchar) getU16(entry, 2 + i * 2);
            info.label = toUTF8(chars);
            continue; // volume label has no SetChecksum field
        }
        else if (entry[0] == 0x81)
            info.hasAllocationBitmap = true;
        else if (entry[0] == 0x82)
            info.hasUpcaseTable = true;
        else
            continue;
        if (!entryChecksumOk(entry))
            info.entryChecksumsOk = false;
    }
    return info;
}

private bool entryChecksumOk(const(ubyte)[] entry)
{
    ushort checksum = 0;
    foreach (i; 0 .. 32)
    {
        if (i == 2 || i == 3)
            continue;
        checksum = cast(ushort) (((checksum & 1) ? 0x8000 : 0) + (checksum >> 1) + entry[i]);
    }
    return checksum == getU16(entry, 2);
}

unittest
{
    // The minimal table is 60 bytes and carries the exfatprogs checksum.
    auto table = minimalUpcaseTable();
    assert(table.length == 60);
    assert(exfatChecksum(table) == 0x4E394AE1);
}

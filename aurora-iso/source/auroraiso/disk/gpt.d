/**
 * GUID Partition Table (with protective MBR) builder and reader, written from
 * scratch. Produces the on-disk bytes Windows, Linux, and UEFI firmware already
 * understand, without calling diskpart or any native partitioning API.
 */
module auroraiso.disk.gpt;

import auroraiso.disk.bytes;
import auroraiso.disk.device;
import std.utf : toUTF8, toUTF16;

/// CRC-32 (reflected, polynomial 0xEDB88320) as required by the GPT spec.
uint crc32(const(ubyte)[] data)
{
    uint crc = 0xFFFFFFFF;
    foreach (b; data)
    {
        crc ^= b;
        foreach (_; 0 .. 8)
            crc = (crc & 1) ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
    }
    return ~crc;
}

/// A 16-byte GUID in GPT on-disk (mixed-endian) order.
struct Guid
{
    ubyte[16] bytes;

    bool opEquals(const Guid other) const
    {
        return bytes[] == other.bytes[];
    }
}

private ubyte hexDigit(char c)
{
    if (c >= '0' && c <= '9')
        return cast(ubyte) (c - '0');
    auto lower = cast(char) (c | 0x20);
    if (lower >= 'a' && lower <= 'f')
        return cast(ubyte) (lower - 'a' + 10);
    throw new Exception("invalid hex digit in GUID");
}

/// Parse "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" into GPT mixed-endian bytes.
Guid guidFromString(string text)
{
    char[32] digits;
    size_t count = 0;
    foreach (ch; text)
    {
        if (ch == '-')
            continue;
        if (count >= 32)
            throw new Exception("GUID too long: " ~ text);
        digits[count++] = ch;
    }
    if (count != 32)
        throw new Exception("GUID wrong length: " ~ text);

    uint d1 = 0;
    foreach (i; 0 .. 8)
        d1 = (d1 << 4) | hexDigit(digits[i]);
    uint d2 = 0;
    foreach (i; 8 .. 12)
        d2 = (d2 << 4) | hexDigit(digits[i]);
    uint d3 = 0;
    foreach (i; 12 .. 16)
        d3 = (d3 << 4) | hexDigit(digits[i]);

    Guid g;
    putU32(g.bytes[], 0, d1);
    putU16(g.bytes[], 4, cast(ushort) d2);
    putU16(g.bytes[], 6, cast(ushort) d3);
    foreach (i; 0 .. 8)
        g.bytes[8 + i] = cast(ubyte) ((hexDigit(digits[16 + 2 * i]) << 4) |
            hexDigit(digits[17 + 2 * i]));
    return g;
}

/// Well-known partition type GUIDs.
immutable Guid typeEfiSystem = guidFromString("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
immutable Guid typeMicrosoftBasicData = guidFromString("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
immutable Guid typeLinuxFilesystem = guidFromString("0FC63DAF-8483-4772-8E79-3D69D8477DE4");

/// One GPT partition entry.
struct GptPartition
{
    Guid type;
    Guid unique;
    ulong firstLba;
    ulong lastLba;
    ulong attributes;
    string name;

    ulong sectors() const
    {
        return lastLba >= firstLba ? lastLba - firstLba + 1 : 0;
    }
}

/// Parsed GPT contents.
struct GptInfo
{
    GptPartition[] partitions;
    ulong firstUsableLba;
    ulong lastUsableLba;
    uint entryCount;
}

private ubyte[] encodeUtf16Le(string text)
{
    auto wide = toUTF16(text);
    auto buffer = new ubyte[wide.length * 2];
    foreach (i, c; wide)
        putU16(buffer, i * 2, cast(ushort) c);
    return buffer;
}

private string decodeUtf16Le(const(ubyte)[] raw)
{
    wchar[] chars;
    for (size_t i = 0; i + 1 < raw.length; i += 2)
    {
        auto value = getU16(raw, i);
        if (value == 0)
            break;
        chars ~= cast(wchar) value;
    }
    return toUTF8(chars);
}

/// Write a protective MBR, a primary GPT, and a backup GPT to `dev`.
void writeGpt(BlockDevice dev, GptPartition[] partitions, Guid diskGuid,
    uint sectorSize = 0)
{
    if (sectorSize == 0)
        sectorSize = dev.sectorSize();
    const ulong totalSectors = dev.size() / sectorSize;
    enum uint entryCount = 128;
    enum uint entrySize = 128;
    enum uint entrySectors = 32; // 128 entries * 128 bytes / 512
    const ulong firstUsable = 2 + entrySectors;
    const ulong lastUsable = totalSectors - 1 - entrySectors - 1;

    if (totalSectors < 2 + 2 * cast(ulong) entrySectors + 2)
        throw new Exception("device too small for a GPT");

    auto entries = new ubyte[entryCount * entrySize];
    foreach (i, p; partitions)
    {
        if (i >= entryCount)
            throw new Exception("too many GPT partitions");
        if (p.firstLba < firstUsable || p.lastLba > lastUsable)
            throw new Exception("partition outside the usable GPT range");
        auto off = i * entrySize;
        putBytes(entries, off, p.type.bytes[]);
        putBytes(entries, off + 16, p.unique.bytes[]);
        putU64(entries, off + 32, p.firstLba);
        putU64(entries, off + 40, p.lastLba);
        putU64(entries, off + 48, p.attributes);
        auto nameBytes = encodeUtf16Le(p.name);
        auto copyLength = nameBytes.length < 72 ? nameBytes.length : 72;
        putBytes(entries, off + 56, nameBytes[0 .. copyLength]);
    }
    const entriesCrc = crc32(entries);

    // Protective MBR at LBA 0.
    auto mbr = new ubyte[sectorSize];
    mbr[446] = 0x00;
    mbr[447] = 0x00;
    mbr[448] = 0x02;
    mbr[449] = 0x00;
    mbr[450] = 0xEE;
    mbr[451] = 0xFF;
    mbr[452] = 0xFF;
    mbr[453] = 0xFF;
    putU32(mbr, 454, 1);
    ulong protective = totalSectors - 1;
    if (protective > 0xFFFFFFFF)
        protective = 0xFFFFFFFF;
    putU32(mbr, 458, cast(uint) protective);
    mbr[sectorSize - 2] = 0x55;
    mbr[sectorSize - 1] = 0xAA;
    dev.write(0, mbr);

    // Primary header at LBA 1.
    auto header = new ubyte[sectorSize];
    putAscii(header, 0, "EFI PART");
    putU32(header, 8, 0x00010000);
    putU32(header, 12, 92);
    putU32(header, 16, 0);
    putU32(header, 20, 0);
    putU64(header, 24, 1);
    putU64(header, 32, totalSectors - 1);
    putU64(header, 40, firstUsable);
    putU64(header, 48, lastUsable);
    putBytes(header, 56, diskGuid.bytes[]);
    putU64(header, 72, 2);
    putU32(header, 80, entryCount);
    putU32(header, 84, entrySize);
    putU32(header, 88, entriesCrc);
    putU32(header, 16, crc32(header[0 .. 92]));
    dev.write(cast(ulong) sectorSize * 1, header);
    dev.write(cast(ulong) sectorSize * 2, entries);

    // Backup entries and header.
    dev.write(cast(ulong) sectorSize * (totalSectors - 1 - entrySectors), entries);
    auto backup = new ubyte[sectorSize];
    backup[] = header[];
    putU64(backup, 24, totalSectors - 1);
    putU64(backup, 32, 1);
    putU64(backup, 72, totalSectors - 1 - entrySectors);
    putU32(backup, 16, 0);
    putU32(backup, 16, crc32(backup[0 .. 92]));
    dev.write(cast(ulong) sectorSize * (totalSectors - 1), backup);

    dev.flush();
}

/// Read back the primary GPT (used by the tests to validate the writer).
GptInfo readGpt(BlockDevice dev, uint sectorSize = 0)
{
    if (sectorSize == 0)
        sectorSize = dev.sectorSize();
    auto header = new ubyte[sectorSize];
    dev.read(cast(ulong) sectorSize * 1, header);
    if (header[0] != 'E' || header[1] != 'F' || header[2] != 'I' ||
        header[3] != ' ' || header[4] != 'P' || header[5] != 'A' ||
        header[6] != 'R' || header[7] != 'T')
        throw new Exception("no GPT signature found");

    const entryCount = getU32(header, 80);
    const entrySize = getU32(header, 84);
    const entriesLba = getU64(header, 72);

    GptInfo info;
    info.firstUsableLba = getU64(header, 40);
    info.lastUsableLba = getU64(header, 48);
    info.entryCount = entryCount;

    auto raw = new ubyte[entryCount * entrySize];
    dev.read(entriesLba * sectorSize, raw);
    foreach (i; 0 .. entryCount)
    {
        auto off = i * entrySize;
        bool empty = true;
        foreach (j; 0 .. 16)
        {
            if (raw[off + j] != 0)
            {
                empty = false;
                break;
            }
        }
        if (empty)
            continue;
        GptPartition p;
        p.type.bytes[] = raw[off .. off + 16];
        p.unique.bytes[] = raw[off + 16 .. off + 32];
        p.firstLba = getU64(raw, off + 32);
        p.lastLba = getU64(raw, off + 40);
        p.attributes = getU64(raw, off + 48);
        p.name = decodeUtf16Le(raw[off + 56 .. off + 128]);
        info.partitions ~= p;
    }
    return info;
}

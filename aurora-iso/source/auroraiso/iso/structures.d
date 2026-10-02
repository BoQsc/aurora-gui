/**
 * On-disk structures and constants of the ISO 9660 (ECMA-119) format, plus the
 * Rock Ridge (IEEE P1282) and El Torito boot-record extensions.
 *
 * This module is deliberately self-contained: it parses raw sector buffers and
 * has no dependency on the Aurora GUI or on any platform API.
 */
module auroraiso.iso.structures;

import auroraiso.iso.endian;

/// ISO 9660 logical block (sector) size. ECMA-119 fixes this at 2048 bytes.
enum uint isoBlockSize = 2048;

/// The first sector at which a volume descriptor may appear.
enum uint isoFirstDescriptorLba = 16;

/// Volume descriptor type codes.
enum ubyte vdBootRecord = 0;
enum ubyte vdPrimary = 1;
enum ubyte vdSupplementary = 2;
enum ubyte vdPartition = 3;
enum ubyte vdTerminator = 255;

/// File flags inside a directory record (ECMA-119 9.1.6).
enum ubyte fileFlagHidden = 0x01;
enum ubyte fileFlagDirectory = 0x02;
enum ubyte fileFlagAssociated = 0x04;
enum ubyte fileFlagRecord = 0x08;
enum ubyte fileFlagProtection = 0x10;
enum ubyte fileFlagMultiExtent = 0x80;

/// The file identifier used for the "." and ".." entries.
enum ubyte[] selfIdentifier = [0x00];
enum ubyte[] parentIdentifier = [0x01];

/// Decoded directory timestamp (ECMA-119 9.1.5, seven bytes).
struct IsoTimestamp
{
    int year;
    ubyte month;
    ubyte day;
    ubyte hour;
    ubyte minute;
    ubyte second;
    byte gmtOffset;

    string toString() const
    {
        import std.format : format;
        return format("%04d-%02d-%02d %02d:%02d:%02d", year + 1900, month,
            day, hour, minute, second);
    }
}

IsoTimestamp parseDirectoryTimestamp(const(ubyte)[] buffer, size_t off)
    pure nothrow @nogc @safe
{
    IsoTimestamp value;
    if (!hasRange(buffer, off, 7))
        return value;
    value.year = buffer[off];
    value.month = buffer[off + 1];
    value.day = buffer[off + 2];
    value.hour = buffer[off + 3];
    value.minute = buffer[off + 4];
    value.second = buffer[off + 5];
    value.gmtOffset = cast(byte) buffer[off + 6];
    return value;
}

/**
 * One parsed directory record. `identifier` and `systemUse` are slices of the
 * caller's sector buffer and must not outlive it.
 */
struct IsoDirectoryRecord
{
    bool valid;
    ubyte recordLength;
    ubyte extAttrLength;
    uint extent;
    uint dataLength;
    ubyte flags;
    ubyte identifierLength;
    const(ubyte)[] identifier;
    const(ubyte)[] systemUse;

    bool isDirectory() const pure nothrow @nogc @safe
    {
        return (flags & fileFlagDirectory) != 0;
    }

    bool isMultiExtent() const pure nothrow @nogc @safe
    {
        return (flags & fileFlagMultiExtent) != 0;
    }

    bool isSelf() const pure nothrow @nogc @safe
    {
        return identifierLength == 1 && identifier.length == 1 &&
            identifier[0] == 0x00;
    }

    bool isParent() const pure nothrow @nogc @safe
    {
        return identifierLength == 1 && identifier.length == 1 &&
            identifier[0] == 0x01;
    }
}

/**
 * Parse a directory record starting at `off`. Returns `valid = false` when the
 * record is a zero-length end-of-sector marker or is malformed.
 */
IsoDirectoryRecord parseDirectoryRecord(const(ubyte)[] buffer, size_t off)
    pure nothrow @nogc @safe
{
    IsoDirectoryRecord record;
    if (!hasRange(buffer, off, 33))
        return record;

    const length = buffer[off];
    record.recordLength = length;
    if (length == 0)
        return record;
    if (!hasRange(buffer, off, length) || length < 33)
        return record;

    record.extAttrLength = buffer[off + 1];
    record.extent = readBoth32(buffer, off + 2);
    record.dataLength = readBoth32(buffer, off + 10);
    record.flags = buffer[off + 25];
    record.identifierLength = buffer[off + 32];

    const identifierStart = off + 33;
    if (!hasRange(buffer, identifierStart, record.identifierLength))
        return record;
    record.identifier = buffer[identifierStart .. identifierStart + record.identifierLength];

    size_t systemUseStart = identifierStart + record.identifierLength;
    if ((record.identifierLength & 1) != 0)
        ++systemUseStart; // Records are padded to an even length.
    if (systemUseStart < off + length)
        record.systemUse = buffer[systemUseStart .. off + length];

    record.valid = true;
    return record;
}

/// Parsed El Torito boot-record summary.
struct ElToritoInfo
{
    bool present;
    uint bootCatalogLba;
    string platform;      // "x86", "Power PC", "Mac", "EFI", or "unknown"
    bool bootable;
    ubyte mediaType;
    uint loadSegment;
    ubyte systemType;
    ushort sectorCount;
    uint loadLba;
}

/// Human-readable platform id used by El Torito validation entries.
string elToritoPlatformName(ubyte id) pure nothrow @nogc @safe
{
    switch (id)
    {
        case 0x00: return "x86";
        case 0x01: return "Power PC";
        case 0x02: return "Mac";
        case 0xEF: return "EFI";
        default: return "unknown";
    }
}

/// True when a sector is a boot record containing the El Torito identifier.
bool isElToritoRecord(const(ubyte)[] sector) pure nothrow @nogc @safe
{
    if (sector.length < 40 || sector[0] != vdBootRecord)
        return false;
    static immutable string magic = "EL TORITO SPECIFICATION";
    if (!hasRange(sector, 7, magic.length))
        return false;
    foreach (i; 0 .. magic.length)
        if (sector[7 + i] != magic[i])
            return false;
    return true;
}

unittest
{
    ubyte[] sector = new ubyte[isoBlockSize];
    // Build a minimal "." record: length 34, extent 20, length 2048, dir flag.
    sector[0] = 34;
    writeBoth32(sector, 2, 20);
    writeBoth32(sector, 10, 2048);
    sector[25] = fileFlagDirectory;
    sector[32] = 1;
    sector[33] = 0x00;
    auto record = parseDirectoryRecord(sector, 0);
    assert(record.valid);
    assert(record.recordLength == 34);
    assert(record.extent == 20);
    assert(record.dataLength == 2048);
    assert(record.isDirectory());
    assert(record.isSelf());

    auto end = parseDirectoryRecord(sector, 34);
    assert(!end.valid); // Zero length marks the end of the sector.
}

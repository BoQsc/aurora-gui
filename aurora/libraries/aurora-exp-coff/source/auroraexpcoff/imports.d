// SPDX-License-Identifier: 0BSD
/// Short import object parsing for COFF import libraries.
module auroraexpcoff.imports;

enum ushort importSignatureLow = 0x0000;
enum ushort importSignatureHigh = 0xFFFF;

/// One short import member: DLL, symbol, hint, and import kind.
struct ShortImport
{
    string dll;
    string symbol;
    ushort hint;
    ushort type;
    ubyte nameType;
}

/// True when the member is a short import object; fills `result`.
bool tryParseImport(const(ubyte)[] data, out ShortImport result)
{
    if (data.length < 21)
        return false;
    if (data[0] != 0 || data[1] != 0 || data[2] != 0xFF || data[3] != 0xFF)
        return false;
    if (data.length < 6 || data[4] != 0 || data[5] != 0)
        return false; // version 2 is a bigobj COFF, not a short import
    result.hint = cast(ushort) (data[16] | (data[17] << 8));
    const flags = cast(ushort) (data[18] | (data[19] << 8));
    result.type = flags & 3;
    result.nameType = (flags >> 2) & 3;

    size_t offset = 20;
    size_t end = offset;
    while (end < data.length && data[end] != 0)
        ++end;
    if (end == data.length)
        return false;
    result.symbol = cast(string) data[offset .. end].idup;
    offset = end + 1;
    end = offset;
    while (end < data.length && data[end] != 0)
        ++end;
    if (end == data.length)
        return false;
    result.dll = cast(string) data[offset .. end].idup;
    return result.dll.length != 0 && result.symbol.length != 0;
}

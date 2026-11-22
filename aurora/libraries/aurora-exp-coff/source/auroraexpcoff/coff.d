// SPDX-License-Identifier: 0BSD
/**
 * Strict COFF object reader.
 *
 * Parses the 20-byte file header, the section table, per-section relocations,
 * the symbol table with auxiliary records, and the string table. Long section
 * names (`/nnn`) and long symbol names are resolved through the string table.
 * Every offset is bounds-checked; malformed input throws `CoffError`.
 */
module auroraexpcoff.coff;

import core.stdc.string : memcpy;
import std.format : format;

enum size_t fileHeaderSize = 20;
enum size_t sectionHeaderSize = 40;
enum size_t relocationSize = 10;
enum size_t symbolSize = 18;
enum size_t bigobjSymbolSize = 20;

/// Raised for malformed or unsupported COFF input.
class CoffError : Exception
{
    this(string message)
    {
        super(message);
    }
}

align(1) struct CoffFileHeader
{
    ushort machine;
    ushort numberOfSections;
    uint timeDateStamp;
    uint pointerToSymbolTable;
    uint numberOfSymbols;
    ushort sizeOfOptionalHeader;
    ushort characteristics;
}
static assert(CoffFileHeader.sizeof == fileHeaderSize);

align(1) struct CoffSectionHeader
{
    char[8] name;
    uint virtualSize;
    uint virtualAddress;
    uint sizeOfRawData;
    uint pointerToRawData;
    uint pointerToRelocations;
    uint pointerToLinenumbers;
    ushort numberOfRelocations;
    ushort numberOfLinenumbers;
    uint characteristics;
}
static assert(CoffSectionHeader.sizeof == sectionHeaderSize);

align(1) struct CoffRelocation
{
    uint virtualAddress;
    uint symbolTableIndex;
    ushort type;
}
static assert(CoffRelocation.sizeof == relocationSize);

align(1) struct CoffSymbol
{
    char[8] name;
    uint value;
    int sectionNumber;
    ushort type;
    ubyte storageClass;
    ubyte numberOfAuxSymbols;
}
static assert(CoffSymbol.sizeof == bigobjSymbolSize);

private T loadStruct(T)(const(ubyte)[] data, size_t offset, string what)
{
    if (offset > data.length || T.sizeof > data.length - offset)
        throw new CoffError(what ~ ": truncated");
    T value = void;
    memcpy(&value, data.ptr + offset, T.sizeof);
    return value;
}

private uint readU32(const(ubyte)[] data, size_t offset, string what)
{
    return loadStruct!uint(data, offset, what);
}

private ushort readU16(const(ubyte)[] data, size_t offset, string what)
{
    if (offset > data.length || 2 > data.length - offset)
        throw new CoffError(what ~ ": truncated");
    return cast(ushort) (data[offset] | (data[offset + 1] << 8));
}

private int asciiLower(int value)
{
    return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

private bool startsWithIgnoreCase(const(char)[] text, size_t offset, string prefix)
{
    if (offset + prefix.length > text.length)
        return false;
    foreach (index; 0 .. prefix.length)
        if (asciiLower(text[offset + index]) != asciiLower(prefix[index]))
            return false;
    return true;
}

/// Extract `/DEFAULTLIB:name` directives from `.drectve` text.
string[] parseDefaultLibraries(const(char)[] text)
{
    string[] result;
    size_t offset;
    while (offset < text.length)
    {
        size_t consumed;
        if (startsWithIgnoreCase(text, offset, "/DEFAULTLIB:"))
            consumed = 12;
        else if (startsWithIgnoreCase(text, offset, "-defaultlib:"))
            consumed = 12;
        else
        {
            ++offset;
            continue;
        }
        offset += consumed;
        while (offset < text.length && (text[offset] == ' ' || text[offset] == '\t'))
            ++offset;
        bool quoted = offset < text.length && text[offset] == '"';
        if (quoted)
            ++offset;
        const start = offset;
        while (offset < text.length)
        {
            if (quoted ? text[offset] == '"'
                       : (text[offset] == ' ' || text[offset] == '\t'))
                break;
            ++offset;
        }
        if (offset > start)
        {
            auto name = text[start .. offset];
            if (name.length > 4
                && asciiLower(name[$ - 4]) == '.'
                && asciiLower(name[$ - 3]) == 'l'
                && asciiLower(name[$ - 2]) == 'i'
                && asciiLower(name[$ - 1]) == 'b')
                name = name[0 .. $ - 4];
            result ~= name.idup;
        }
        if (quoted && offset < text.length)
            ++offset;
    }
    return result;
}

/// COMDAT selection from a section auxiliary record.
struct SectionAux
{
    bool found;
    ubyte selection;
    ushort associatedSection;
}

/// One parsed COFF object file.
struct CoffObject
{
    ubyte[] bytes;
    CoffFileHeader header;
    CoffSectionHeader[] sections;
    CoffRelocation[][] relocations;
    CoffSymbol[] symbols;
    size_t symbolStride;
    size_t stringTableOffset;
    size_t stringTableSize;

    static CoffObject load(const(ubyte)[] data)
    {
        CoffObject object;
        size_t sectionTable;
        size_t count;
        bool bigobj;
        if (data.length >= 56
            && data[0] == 0 && data[1] == 0
            && data[2] == 0xFF && data[3] == 0xFF
            && readU16(data, 4, "bigobj header") >= 2)
        {
            // ANON_OBJECT_HEADER_BIGOBJ: fields after the 56-byte header.
            object.header.machine = readU16(data, 6, "bigobj header");
            object.header.numberOfSections = 0;
            object.header.timeDateStamp = readU32(data, 8, "bigobj header");
            object.header.pointerToSymbolTable = readU32(data, 48, "bigobj header");
            object.header.numberOfSymbols = readU32(data, 52, "bigobj header");
            object.header.sizeOfOptionalHeader = 0;
            object.header.characteristics = 0;
            sectionTable = 56;
            count = cast(size_t) readU32(data, 44, "bigobj header");
            bigobj = true;
        }
        else
        {
            object.header = loadStruct!CoffFileHeader(data, 0, "COFF header");
            sectionTable = fileHeaderSize
                + cast(size_t) object.header.sizeOfOptionalHeader;
            count = cast(size_t) object.header.numberOfSections;
            bigobj = false;
        }
        if (object.header.machine == 0)
            throw new CoffError("COFF header: machine is zero");
        if (sectionTable > data.length
            || count > (data.length - sectionTable) / sectionHeaderSize)
            throw new CoffError("section table: truncated");
        object.sections = new CoffSectionHeader[count];
        foreach (index; 0 .. count)
            object.sections[index] = loadStruct!CoffSectionHeader(
                data, sectionTable + index * sectionHeaderSize, "section header");

        const symbolCount = cast(size_t) object.header.numberOfSymbols;
        const symbolOffset = cast(size_t) object.header.pointerToSymbolTable;
        object.symbolStride = bigobj ? bigobjSymbolSize : symbolSize;
        if (symbolCount != 0)
        {
            if (symbolOffset > data.length
                || symbolCount > (data.length - symbolOffset) / object.symbolStride)
                throw new CoffError("symbol table: truncated");
            object.symbols = new CoffSymbol[symbolCount];
            foreach (index; 0 .. symbolCount)
            {
                const offset = symbolOffset + index * object.symbolStride;
                CoffSymbol symbol;
                foreach (byteIndex; 0 .. 8)
                    symbol.name[byteIndex] = data[offset + byteIndex];
                symbol.value = readU32(data, offset + 8, "symbol");
                if (bigobj)
                {
                    symbol.sectionNumber = cast(int) readU32(data, offset + 12, "symbol");
                    symbol.type = readU16(data, offset + 16, "symbol");
                    symbol.storageClass = data[offset + 18];
                    symbol.numberOfAuxSymbols = data[offset + 19];
                }
                else
                {
                    symbol.sectionNumber = cast(short) readU16(data, offset + 12, "symbol");
                    symbol.type = readU16(data, offset + 14, "symbol");
                    symbol.storageClass = data[offset + 16];
                    symbol.numberOfAuxSymbols = data[offset + 17];
                }
                object.symbols[index] = symbol;
            }
        }

        object.stringTableOffset = symbolOffset + symbolCount * object.symbolStride;
        if (symbolCount != 0 && object.stringTableOffset + 4 <= data.length)
        {
            object.stringTableSize = readU32(data, object.stringTableOffset,
                "string table size");
            if (object.stringTableSize < 4
                || object.stringTableOffset + object.stringTableSize > data.length)
                throw new CoffError("string table: truncated");
        }
        else
            object.stringTableSize = 0;

        object.relocations = new CoffRelocation[][count];
        foreach (index; 0 .. count)
        {
            const section = object.sections[index];
            const relocationCount = cast(size_t) section.numberOfRelocations;
            if (relocationCount == 0)
                continue;
            const offset = cast(size_t) section.pointerToRelocations;
            if (offset > data.length
                || relocationCount > (data.length - offset) / relocationSize)
                throw new CoffError(format("section %d relocations: truncated",
                    index));
            object.relocations[index] = new CoffRelocation[relocationCount];
            foreach (relocation; 0 .. relocationCount)
                object.relocations[index][relocation] = loadStruct!CoffRelocation(
                    data, offset + relocation * relocationSize, "relocation");
        }

        object.bytes = cast(ubyte[]) data.dup;
        return object;
    }

    private string stringAt(size_t offset, string what) const
    {
        if (objectStringTableEmpty)
            throw new CoffError(what ~ ": no string table");
        const absolute = stringTableOffset + offset;
        if (offset < 4 || absolute >= stringTableOffset + stringTableSize)
            throw new CoffError(what ~ ": string offset is outside the table");
        size_t end = absolute;
        while (end < stringTableOffset + stringTableSize && bytes[end] != 0)
            ++end;
        if (end == stringTableOffset + stringTableSize)
            throw new CoffError(what ~ ": unterminated string");
        return cast(string) bytes[absolute .. end].idup;
    }

    private bool objectStringTableEmpty() const
    {
        return stringTableSize == 0;
    }

    /// Resolved section name (handles `/nnn` long names).
    string sectionName(size_t index) const
    {
        if (index >= sections.length)
            throw new CoffError("section index out of range");
        const raw = sections[index].name;
        size_t length;
        while (length < raw.length && raw[length] != 0)
            ++length;
        if (length == 0)
            return "";
        if (raw[0] == '/')
        {
            uint offset;
            foreach (position; 1 .. length)
            {
                if (raw[position] < '0' || raw[position] > '9')
                    throw new CoffError("section name: invalid long-name offset");
                offset = offset * 10 + cast(uint) (raw[position] - '0');
            }
            return stringAt(offset, "section name");
        }
        return raw[0 .. length].idup;
    }

    /// Resolved symbol name (inline or string-table long name).
    string symbolName(size_t index) const
    {
        if (index >= symbols.length)
            throw new CoffError("symbol index out of range");
        const raw = symbols[index].name;
        if (raw[0] == 0 && raw[1] == 0 && raw[2] == 0 && raw[3] == 0)
        {
            uint offset = cast(uint) raw[4]
                | (cast(uint) raw[5] << 8)
                | (cast(uint) raw[6] << 16)
                | (cast(uint) raw[7] << 24);
            return stringAt(offset, "symbol name");
        }
        size_t length;
        while (length < raw.length && raw[length] != 0)
            ++length;
        return raw[0 .. length].idup;
    }

    /// Symbols excluding auxiliary records.
    size_t[] primarySymbols() const
    {
        size_t[] result;
        size_t index;
        while (index < symbols.length)
        {
            result ~= index;
            index += 1 + symbols[index].numberOfAuxSymbols;
        }
        return result;
    }

    size_t relocationCount() const
    {
        size_t total;
        foreach (block; relocations)
            total += block.length;
        return total;
    }

    /// `/DEFAULTLIB` directives carried by this object's `.drectve` sections.
    string[] defaultLibraries() const
    {
        string[] result;
        foreach (index; 0 .. sections.length)
        {
            const name = sectionName(index);
            if (name.length < ".drectve".length
                || name[0 .. ".drectve".length] != ".drectve")
                continue;
            const section = sections[index];
            const start = cast(size_t) section.pointerToRawData;
            if (start > bytes.length || section.sizeOfRawData > bytes.length - start)
                continue;
            result ~= parseDefaultLibraries(
                cast(const(char)[]) bytes[start .. start + section.sizeOfRawData]);
        }
        return result;
    }

    /// Selection byte and associated section from the section's aux record.
    SectionAux sectionAux(size_t index) const
    {
        const sectionNameValue = sectionName(index);
        foreach (symbolIndex; primarySymbols())
        {
            const symbol = symbols[symbolIndex];
            if (symbol.storageClass != 3 || symbol.numberOfAuxSymbols == 0
                || symbol.sectionNumber != cast(int) (index + 1)
                || symbol.value != 0
                || symbolName(symbolIndex) != sectionNameValue)
                continue;
            const auxOffset = cast(size_t) header.pointerToSymbolTable
                + (symbolIndex + 1) * symbolStride;
            if (auxOffset + 18 > bytes.length)
                throw new CoffError("section aux record: truncated");
            SectionAux aux;
            aux.found = true;
            aux.associatedSection = readU16(bytes, auxOffset + 12,
                "section aux record");
            aux.selection = bytes[auxOffset + 14];
            return aux;
        }
        return SectionAux(false, 0, 0);
    }

    size_t rawSize(size_t index) const
    {
        return sections[index].sizeOfRawData;
    }
}

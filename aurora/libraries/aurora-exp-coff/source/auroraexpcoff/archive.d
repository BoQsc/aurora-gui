// SPDX-License-Identifier: 0BSD
/**
 * COFF archive (`.lib`) reader.
 *
 * Parses the global header, 60-byte member headers, the `//` long-name table,
 * and the `/` linker members. Member data is exposed by index; symbol lookup
 * scans member COFF symbol tables, which is sufficient for verification and
 * straightforward archive extraction.
 */
module auroraexpcoff.archive;

import auroraexpcoff.coff : CoffError, CoffObject, parseDefaultLibraries;
import std.format : format;

enum archiveMagic = "!<arch>\n";

class ArchiveError : Exception
{
    this(string message)
    {
        super(message);
    }
}

struct ArchiveMember
{
    string name;
    size_t headerOffset;
    size_t dataOffset;
    size_t size;
    bool special;
}

struct CoffArchive
{
    ubyte[] bytes;
    ArchiveMember[] members;
    size_t[string] symbolMembers;
    bool hasSymbolIndex;

    static CoffArchive load(const(ubyte)[] data)
    {
        if (data.length < archiveMagic.length
            || data[0 .. archiveMagic.length] != cast(const(ubyte)[]) archiveMagic)
            throw new ArchiveError("missing archive magic");
        CoffArchive archive;
        archive.bytes = cast(ubyte[]) data.dup;

        size_t offset = archiveMagic.length;
        while (offset + 60 <= data.length)
        {
            const header = data[offset .. offset + 60];
            if (header[58] != '`' || header[59] != '\n')
                throw new ArchiveError("member header: bad terminator");
            const nameField = trim(header[0 .. 16]);
            const sizeField = trim(header[48 .. 58]);
            size_t size;
            foreach (character; sizeField)
            {
                if (character < '0' || character > '9')
                    throw new ArchiveError("member header: invalid size");
                size = size * 10 + (character - '0');
            }
            ArchiveMember member;
            member.headerOffset = offset;
            member.dataOffset = offset + 60;
            member.size = size;
            member.special = nameField == "/" || nameField == "//";
            member.name = nameField;
            if (member.dataOffset + size > data.length)
                throw new ArchiveError("member data: truncated");
            archive.members ~= member;
            offset = member.dataOffset + size + (size & 1);
        }
        archive.buildSymbolIndex();
        return archive;
    }

    private static uint readBigEndian(const(ubyte)[] data, size_t offset)
    {
        return (cast(uint) data[offset] << 24)
            | (cast(uint) data[offset + 1] << 16)
            | (cast(uint) data[offset + 2] << 8)
            | cast(uint) data[offset + 3];
    }

    /// Parse the first `/` linker member into symbol → member-header offset.
    private void buildSymbolIndex()
    {
        foreach (member; members)
        {
            if (member.name != "/")
                continue;
            const blob = bytes[member.dataOffset .. member.dataOffset + member.size];
            if (blob.length < 4)
                return;
            const count = cast(size_t) readBigEndian(blob, 0);
            if (count > (blob.length - 4) / 4)
                return;
            size_t nameOffset = 4 + count * 4;
            foreach (index; 0 .. count)
            {
                const memberOffset = cast(size_t) readBigEndian(blob, 4 + index * 4);
                if (nameOffset >= blob.length)
                    break;
                size_t end = nameOffset;
                while (end < blob.length && blob[end] != 0)
                    ++end;
                const name = cast(string) blob[nameOffset .. end].idup;
                if (name.length != 0)
                    symbolMembers[name] = memberOffset;
                nameOffset = end + 1;
            }
            hasSymbolIndex = true;
            return;
        }
    }

    private size_t memberAtOffset(size_t offset) const
    {
        foreach (index, member; members)
            if (member.headerOffset == offset || member.dataOffset == offset)
                return index;
        return size_t.max;
    }

    private static string trim(const(ubyte)[] field)
    {
        size_t start;
        size_t end = field.length;
        while (start < end && (field[start] == ' ' || field[start] == 0))
            ++start;
        while (end > start && (field[end - 1] == ' ' || field[end - 1] == 0))
            --end;
        return cast(string) field[start .. end].idup;
    }

    /// Resolve `/nnn` member names through the `//` long-name table.
    string memberName(size_t index) const
    {
        if (index >= members.length)
            throw new ArchiveError("member index out of range");
        const name = members[index].name;
        if (name.length < 2 || name[0] != '/')
            return name;
        bool digits = true;
        foreach (character; name[1 .. $])
            if (character < '0' || character > '9')
                digits = false;
        if (!digits)
            return name;
        uint longOffset;
        foreach (character; name[1 .. $])
            longOffset = longOffset * 10 + (character - '0');
        foreach (member; members)
            if (member.name == "//")
            {
                if (longOffset >= member.size)
                    throw new ArchiveError("long-name offset is outside the table");
                const start = member.dataOffset + longOffset;
                size_t end = start;
                while (end < member.dataOffset + member.size
                    && bytes[end] != 0 && bytes[end] != '\n')
                    ++end;
                return cast(string) bytes[start .. end].idup;
            }
        return name;
    }

    /// Member bytes by index.
    const(ubyte)[] memberData(size_t index) const
    {
        if (index >= members.length)
            throw new ArchiveError("member index out of range");
        const member = members[index];
        return bytes[member.dataOffset .. member.dataOffset + member.size];
    }

    /// First member whose COFF symbol table defines `symbol`.
    size_t findMember(string symbol) const
    {
        if (symbol in symbolMembers)
        {
            const index = memberAtOffset(symbolMembers[symbol]);
            if (index != size_t.max)
                return index;
        }
        if (hasSymbolIndex)
            return size_t.max;
        foreach (index, member; members)
        {
            if (member.special)
                continue;
            try
            {
                const object = CoffObject.load(memberData(index));
                foreach (symbolIndex; object.primarySymbols())
                    if (object.symbolName(symbolIndex) == symbol)
                        return index;
            }
            catch (CoffError)
            {
                continue;
            }
            catch (ArchiveError)
            {
                continue;
            }
        }
        return size_t.max;
    }

    /// `/DEFAULTLIB` directives from all `.drectve` sections in the archive.
    string[] defaultLibraries() const
    {
        string[] result;
        foreach (index, member; members)
        {
            if (member.special)
                continue;
            const data = memberData(index);
            if (data.length < 20)
                continue;
            const machine = cast(uint) data[0] | (cast(uint) data[1] << 8);
            if (machine == 0)
                continue; // short import object
            const sections = cast(size_t) data[2] | (cast(size_t) data[3] << 8);
            const optional = cast(size_t) data[16] | (cast(size_t) data[17] << 8);
            const table = 20 + optional;
            foreach (sectionIndex; 0 .. sections)
            {
                const offset = table + sectionIndex * 40;
                if (offset + 40 > data.length)
                    break;
                const name = data[offset .. offset + 8];
                if (name.length < 8 || name[0 .. 8] != cast(const(ubyte)[]) ".drectve")
                    continue;
                const rawSize = cast(size_t) data[offset + 16]
                    | (cast(size_t) data[offset + 17] << 8)
                    | (cast(size_t) data[offset + 18] << 16)
                    | (cast(size_t) data[offset + 19] << 24);
                const rawPointer = cast(size_t) data[offset + 20]
                    | (cast(size_t) data[offset + 21] << 8)
                    | (cast(size_t) data[offset + 22] << 16)
                    | (cast(size_t) data[offset + 23] << 24);
                if (rawPointer > data.length || rawSize > data.length - rawPointer)
                    continue;
                result ~= parseDefaultLibraries(
                    cast(const(char)[]) data[rawPointer .. rawPointer + rawSize]);
            }
        }
        return result;
    }
}

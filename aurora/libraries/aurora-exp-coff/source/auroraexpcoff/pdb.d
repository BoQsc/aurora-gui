// SPDX-License-Identifier: 0BSD
/**
 * Minimal stripped PDB writer.
 *
 * Emits an MSF 7.0 container with the PDB info, TPI, DBI, symbol-record,
 * section-header, and publics streams. The symbol stream carries S_PUB32
 * records for defined, non-absolute symbols; the publics stream carries an
 * empty name hash and an address map into the symbol records.
 */
module auroraexpcoff.pdb;

import std.algorithm.sorting : sort;

struct PdbSymbol
{
    string name;
    uint rva;
}

private enum size_t pageSize = 4096;

private void put16(ref ubyte[] data, ushort value)
{
    data ~= cast(ubyte) value;
    data ~= cast(ubyte) (value >> 8);
}

private void put32(ref ubyte[] data, uint value)
{
    foreach (shift; 0 .. 4)
        data ~= cast(ubyte) (value >> (shift * 8));
}

private struct PeSection
{
    ubyte[40] header;
    uint virtualAddress;
    uint virtualSize;
    uint rawSize;
}

private struct Record
{
    uint section;
    uint offset;
    string name;
}

/// Build a stripped PDB for the already-linked PE image.
ubyte[] buildPdb(const(ubyte)[] image, PdbSymbol[] symbols,
    const(ubyte)[16] guid, uint age)
{
    if (image.length < 0x40)
        return null;
    const peOffset = *cast(const(uint*)) (image.ptr + 0x3C);
    if (peOffset + 24 > image.length || image[peOffset] != 'P'
        || image[peOffset + 1] != 'E' || image[peOffset + 2] != 0
        || image[peOffset + 3] != 0)
        return null;
    const coff = peOffset + 4;
    const sectionCount = *cast(const(ushort*)) (image.ptr + coff + 2);
    const optionalSize = *cast(const(ushort*)) (image.ptr + coff + 16);
    const table = coff + 20 + optionalSize;
    if (table + sectionCount * 40 > image.length)
        return null;
    PeSection[] sections;
    sections.length = sectionCount;
    foreach (index; 0 .. sectionCount)
    {
        const offset = table + index * 40;
        PeSection section;
        foreach (byteIndex; 0 .. 40)
            section.header[byteIndex] = image[offset + byteIndex];
        section.virtualSize = *cast(const(uint*)) (image.ptr + offset + 8);
        section.virtualAddress = *cast(const(uint*)) (image.ptr + offset + 12);
        section.rawSize = *cast(const(uint*)) (image.ptr + offset + 16);
        sections[index] = section;
    }

    Record[] records;
    foreach (symbol; symbols)
    {
        if (symbol.name.length == 0 || symbol.name[0] == '.' || symbol.name[0] == '$')
            continue;
        foreach (sectionIndex, section; sections)
        {
            const span = section.virtualSize > section.rawSize
                ? section.virtualSize : section.rawSize;
            if (symbol.rva >= section.virtualAddress
                && symbol.rva < section.virtualAddress + span)
            {
                Record record;
                record.section = cast(uint) sectionIndex + 1;
                record.offset = symbol.rva - section.virtualAddress;
                record.name = symbol.name;
                records ~= record;
                break;
            }
        }
    }
    records.sort!((left, right) =>
        left.section != right.section ? left.section < right.section
        : left.offset != right.offset ? left.offset < right.offset
        : left.name < right.name);

    ubyte[] symbolStream;
    uint[] sectionFirst;
    sectionFirst.length = sectionCount;
    foreach (record; records)
    {
        const recordStart = cast(uint) symbolStream.length;
        if (sectionFirst[record.section - 1] == 0)
            sectionFirst[record.section - 1] = recordStart;
        put16(symbolStream, 0); // length placeholder
        put16(symbolStream, 0x110E); // S_PUB32
        put32(symbolStream, 0); // flags
        put32(symbolStream, record.offset);
        put16(symbolStream, cast(ushort) record.section);
        foreach (character; record.name)
            symbolStream ~= cast(ubyte) character;
        symbolStream ~= 0;
        const length = cast(ushort) (symbolStream.length - recordStart - 2);
        symbolStream[recordStart] = cast(ubyte) length;
        symbolStream[recordStart + 1] = cast(ubyte) (length >> 8);
    }
    put16(symbolStream, 0); // record terminator

    ubyte[] info;
    put32(info, 20000404);
    put32(info, 0x12345678);
    put32(info, age);
    foreach (byteValue; guid)
        info ~= byteValue;
    put32(info, 0); // no named streams

    ubyte[] tpi;
    put32(tpi, 20040203);
    put32(tpi, 56);
    put32(tpi, 0x1000);
    put32(tpi, 0x1000);
    put32(tpi, 0);
    put16(tpi, 0xFFFF);
    put16(tpi, 0xFFFF);
    put32(tpi, 4);
    put32(tpi, 1);
    foreach (index; 0 .. 6)
        put32(tpi, 0);

    ubyte[] dbi;
    put32(dbi, 0xFFFFFFFF);
    put32(dbi, 19990903);
    put32(dbi, age);
    put16(dbi, 0xFFFF);
    put16(dbi, 0);
    put16(dbi, 6);
    put16(dbi, 0);
    put16(dbi, 4);
    put16(dbi, 0);
    foreach (index; 0 .. 5)
        put32(dbi, 0);
    put32(dbi, 0);
    put32(dbi, 22);
    put32(dbi, 0);
    put16(dbi, 0);
    put16(dbi, 0x8664);
    put32(dbi, 0);
    foreach (index; 0 .. 11)
        put16(dbi, index == 5 ? cast(ushort) 5 : cast(ushort) 0xFFFF);

    ubyte[] sectionStream;
    foreach (section; sections)
        foreach (byteValue; section.header)
            sectionStream ~= byteValue;

    ubyte[] publics;
    put32(publics, 24);
    put32(publics, cast(uint) (sectionCount * 4));
    put32(publics, 0);
    put32(publics, 0);
    put16(publics, 0);
    put16(publics, 0);
    put32(publics, 0);
    put32(publics, cast(uint) sectionCount);
    put32(publics, 0xFFFFFFFF);
    put32(publics, 0xEFFE0000 + 19990810);
    put32(publics, 0);
    put32(publics, 0);
    put32(publics, 0);
    put32(publics, 0);
    foreach (offset; sectionFirst)
        put32(publics, offset);

    ubyte[][] streams;
    streams.length = 7;
    streams[0] = null;
    streams[1] = info;
    streams[2] = tpi;
    streams[3] = dbi;
    streams[4] = symbolStream;
    streams[5] = sectionStream;
    streams[6] = publics;

    size_t[][ ] streamPages;
    streamPages.length = streams.length;
    size_t[] pageCounts;
    pageCounts.length = streams.length;
    foreach (index; 0 .. streams.length)
        pageCounts[index] = (streams[index].length + pageSize - 1) / pageSize;

    size_t rootPages = 1;
    ubyte[] root;
    size_t streamStart;
    foreach (iteration; 0 .. 4)
    {
        streamStart = 5 + rootPages;
        size_t nextPage = streamStart;
        foreach (index; 0 .. streams.length)
        {
            streamPages[index] = null;
            foreach (page; 0 .. pageCounts[index])
                streamPages[index] ~= nextPage++;
        }
        root = null;
        put32(root, cast(uint) streams.length);
        foreach (stream; streams)
            put32(root, cast(uint) stream.length);
        foreach (pages; streamPages)
            foreach (page; pages)
                put32(root, cast(uint) page);
        const neededRootPages = (root.length + pageSize - 1) / pageSize;
        if (neededRootPages <= rootPages)
            break;
        rootPages = neededRootPages;
    }

    size_t totalPages = streamStart;
    foreach (count; pageCounts)
        totalPages += count;
    ubyte[][] pages;
    pages.length = totalPages;
    foreach (index; 0 .. totalPages)
        pages[index] = new ubyte[pageSize];

    const magic = "Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0";
    foreach (index; 0 .. magic.length)
        pages[0][index] = magic[index];
    *cast(uint*) (pages[0].ptr + 0x20) = pageSize;
    *cast(uint*) (pages[0].ptr + 0x24) = 1;
    *cast(uint*) (pages[0].ptr + 0x28) = cast(uint) totalPages;
    *cast(uint*) (pages[0].ptr + 0x2C) = cast(uint) root.length;
    *cast(uint*) (pages[0].ptr + 0x30) = 0;
    *cast(uint*) (pages[0].ptr + 0x34) = 3;
    foreach (index; 0 .. rootPages)
        *cast(uint*) (pages[3].ptr + index * 4) = cast(uint) (4 + index);
    foreach (index; 0 .. root.length)
        pages[4 + index / pageSize][index % pageSize] = root[index];
    foreach (index; 0 .. streams.length)
        foreach (part, page; streamPages[index])
        {
            const start = part * pageSize;
            const remaining = streams[index].length - start;
            const length = remaining < pageSize ? remaining : pageSize;
            pages[page][0 .. length] = streams[index][start .. start + length];
        }

    ubyte[] file;
    file.length = totalPages * pageSize;
    foreach (index; 0 .. totalPages)
        file[index * pageSize .. (index + 1) * pageSize] = pages[index];
    return file;
}

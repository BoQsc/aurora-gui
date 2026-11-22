// SPDX-License-Identifier: 0BSD
/**
 * Minimal executable generation for the binary-format laboratory.
 *
 * This module builds a complete, runnable PE32+ image from fields alone: DOS
 * header, COFF header, optional header, one executable section, and a 3-byte
 * entry stub. It uses no linker, no CRT, and no import library. The image is
 * fed back through `PeImage` in the instrument, so generation and parsing
 * validate each other.
 */
module auroraexp.win32.emit;

import auroraexp.win32.pe;

/// `xor eax, eax; ret`. The loader calls the entry point as a thread start
/// routine; returning exits the thread with code 0 in `eax`.
immutable ubyte[] minimalEntryCode = [0x31, 0xC0, 0xC3];

/// Build a PE32+ console executable that exits with code 0.
ubyte[] emitMinimalExecutable()
{
    enum size_t fileAlignment = 0x200;
    enum size_t sectionAlignment = 0x1000;
    enum size_t headerSize = 0x200;
    enum size_t sectionRva = 0x1000;
    enum size_t relocRva = 0x2000;
    enum size_t relocRaw = 0x400;
    enum size_t imageSize = 0x3000;
    enum size_t peOffset = 0x40;

    auto output = new ubyte[headerSize + fileAlignment * 2];

    DosHeader dos;
    dos.e_magic = dosSignature;
    dos.e_lfanew = cast(uint) peOffset;
    storeStruct(output, 0, dos, "DOS header");

    storeStruct(output, peOffset, peSignature, "PE signature");

    CoffHeader coff;
    coff.machine = Machine.amd64;
    coff.numberOfSections = 2;
    coff.timeDateStamp = 0;
    coff.sizeOfOptionalHeader = cast(ushort) OptionalHeader64.sizeof;
    coff.characteristics = 0x0002 | 0x0020; // executable image | large address aware
    storeStruct(output, peOffset + 4, coff, "COFF header");

    OptionalHeader64 optional;
    optional.magic = pe32PlusMagic;
    optional.majorLinkerVersion = 1;
    optional.sizeOfCode = cast(uint) fileAlignment;
    optional.sizeOfInitializedData = cast(uint) fileAlignment;
    optional.addressOfEntryPoint = cast(uint) sectionRva;
    optional.baseOfCode = cast(uint) sectionRva;
    optional.imageBase = 0x140000000;
    optional.sectionAlignment = cast(uint) sectionAlignment;
    optional.fileAlignment = cast(uint) fileAlignment;
    optional.majorOperatingSystemVersion = 6;
    optional.majorSubsystemVersion = 6;
    optional.sizeOfImage = cast(uint) imageSize;
    optional.sizeOfHeaders = cast(uint) headerSize;
    optional.subsystem = Subsystem.windowsCui;
    optional.dllCharacteristics = 0x0100; // NX compatible
    optional.sizeOfStackReserve = 0x100000;
    optional.sizeOfStackCommit = 0x1000;
    optional.sizeOfHeapReserve = 0x100000;
    optional.sizeOfHeapCommit = 0x1000;
    optional.numberOfRvaAndSizes = cast(uint) dataDirectoryCount;
    DataDirectory relocations;
    relocations.virtualAddress = cast(uint) relocRva;
    relocations.size = 12;
    optional.directories[DirectoryIndex.baseRelocations] = relocations;
    storeStruct(output, peOffset + 4 + coffHeaderSize, optional, "optional header");

    SectionHeader text;
    text.name[] = 0;
    text.name[0 .. 5] = ".text";
    text.virtualSize = cast(uint) minimalEntryCode.length;
    text.virtualAddress = cast(uint) sectionRva;
    text.sizeOfRawData = cast(uint) fileAlignment;
    text.pointerToRawData = cast(uint) headerSize;
    text.characteristics = 0x60000020; // code | execute | read
    storeStruct(output, peOffset + 4 + coffHeaderSize + OptionalHeader64.sizeof,
        text, "section header");

    SectionHeader reloc;
    reloc.name[] = 0;
    reloc.name[0 .. 6] = ".reloc";
    reloc.virtualSize = 12;
    reloc.virtualAddress = cast(uint) relocRva;
    reloc.sizeOfRawData = cast(uint) fileAlignment;
    reloc.pointerToRawData = cast(uint) relocRaw;
    reloc.characteristics = 0x42000040; // initialized data | discardable | read
    storeStruct(output,
        peOffset + 4 + coffHeaderSize + OptionalHeader64.sizeof + SectionHeader.sizeof,
        reloc, "relocation section header");

    output[headerSize .. headerSize + minimalEntryCode.length] = minimalEntryCode;

    RelocationBlock block;
    block.pageRva = cast(uint) sectionRva;
    block.blockSize = 12;
    storeStruct(output, relocRaw, block, "relocation block");
    // Two IMAGE_REL_BASED_ABSOLUTE padding entries: nothing needs fixing, but
    // the directory is valid so the image may be mapped away from its base.
    storeStruct(output, relocRaw + RelocationBlock.sizeof, cast(ushort) 0,
        "relocation padding");
    storeStruct(output, relocRaw + RelocationBlock.sizeof + 2, cast(ushort) 0,
        "relocation padding");
    return output;
}

// SPDX-License-Identifier: 0BSD
/**
 * A Windows PE image as the binary-format laboratory sees it.
 *
 * `PeImage.load` parses and validates the DOS header, stub, PE signature, COFF
 * header, optional header (PE32 or PE32+), all data directories, and the
 * section table. `PeImage.rebuild` re-encodes every one of those header fields
 * and preserves payload bytes, padding, and any overlay verbatim, so a correct
 * parse reproduces the input byte for byte.
 *
 * Coverage is complete for the PE image format: imports, exports, resources,
 * relocations, exceptions, certificates, debug/CodeView, TLS, load config,
 * bound imports, delay imports, and the import address table are all reachable
 * through typed accessors or explicit byte views. Nothing is guessed.
 */
module auroraexp.win32.image;

import auroraexp.win32.pe;
import std.conv : to;
import std.format : format;
import std.utf : encode;

/// One export, with its ordinal, optional name, RVA, and forwarder target.
struct ExportSymbol
{
    uint ordinal;
    string name;
    uint rva;
    string forwarder;
}

/// One resource leaf: type, name, language, and where its bytes live.
struct ResourceEntry
{
    uint typeId;
    string typeName;
    uint nameId;
    string name;
    uint languageId;
    uint dataRva;
    uint size;
    uint codePage;
    /// File offset of the 16-byte `ResourceDataEntry` (for size updates).
    size_t dataEntryOffset;
    /// File offset of the resource bytes.
    size_t dataOffset;
}

/// One base-relocation block with its RVA and entry count.
struct RelocationBlockInfo
{
    uint pageRva;
    uint blockSize;
    uint entryCount;
}

/// One debug-directory entry, with CodeView details when present.
struct DebugEntryInfo
{
    uint type;
    uint sizeOfData;
    uint addressOfRawData;
    uint pointerToRawData;
    uint timeDateStamp;
    ushort majorVersion;
    ushort minorVersion;
    string codeViewPath;
    uint codeViewAge;
    ubyte[16] codeViewGuid;
}

/// One WIN_CERTIFICATE record.
struct CertificateInfo
{
    uint length;
    ushort revision;
    ushort certificateType;
    uint fileOffset;
}

/// One delay-load import library.
struct DelayImport
{
    string dll;
    string[] symbols;
}

/// The TLS directory, including decoded callback addresses.
struct TlsInfo
{
    bool present;
    ulong startAddressOfRawData;
    ulong endAddressOfRawData;
    ulong addressOfIndex;
    ulong addressOfCallbacks;
    uint sizeOfZeroFill;
    uint characteristics;
    ulong[] callbacks;
}

/// One bound-import descriptor.
struct BoundImportInfo
{
    string dll;
    uint timeDateStamp;
}

/// A parsed PE image that can be re-emitted or mutated.
struct PeImage
{
    /// The complete original file, kept so payload and overlay survive.
    ubyte[] bytes;
    DosHeader dos;
    /// Bytes between the 64-byte DOS header and the PE signature.
    ubyte[] stub;
    CoffHeader coff;
    bool is64;
    OptionalHeader32 header32;
    OptionalHeader64 header64;
    /// Optional-header bytes beyond the modeled structure, if any.
    ubyte[] optionalExtra;
    SectionHeader[] sections;
    /// Bytes between the section table and `SizeOfHeaders`.
    ubyte[] headerPadding;
    size_t optionalOffset;
    size_t sectionTableOffset;

    // ---- Parsing ---------------------------------------------------------

    /// Parse and validate an image. Throws `PeError` on anything malformed.
    static PeImage load(const(ubyte)[] data)
    {
        PeImage image;
        if (data.length < dosHeaderSize)
            throw new PeError("DOS header: truncated");
        image.dos = loadStruct!DosHeader(data, 0, "DOS header");
        if (image.dos.e_magic != dosSignature)
            throw new PeError("missing MZ signature");

        const peOffset = cast(size_t) image.dos.e_lfanew;
        if (peOffset < dosHeaderSize)
            throw new PeError(format("PE header offset 0x%X falls inside the DOS header", peOffset));
        if (loadStruct!uint(data, peOffset, "PE signature") != peSignature)
            throw new PeError("missing PE signature");

        image.stub = cast(ubyte[]) data[dosHeaderSize .. peOffset].dup;
        image.coff = loadStruct!CoffHeader(data, peOffset + 4, "COFF header");
        image.optionalOffset = peOffset + 4 + coffHeaderSize;

        const optionalSize = cast(size_t) image.coff.sizeOfOptionalHeader;
        if (optionalSize < 2 || optionalSize > data.length - image.optionalOffset)
            throw new PeError("optional header: truncated");

        const magic = loadStruct!ushort(data, image.optionalOffset, "optional header magic");
        size_t modeledSize;
        if (magic == pe32Magic)
        {
            image.header32 = loadStruct!OptionalHeader32(data, image.optionalOffset, "optional header");
            modeledSize = OptionalHeader32.sizeof;
        }
        else if (magic == pe32PlusMagic)
        {
            image.is64 = true;
            image.header64 = loadStruct!OptionalHeader64(data, image.optionalOffset, "optional header");
            modeledSize = OptionalHeader64.sizeof;
        }
        else
        {
            throw new PeError(format("unsupported optional-header magic 0x%X", magic));
        }
        if (optionalSize < modeledSize)
            throw new PeError("optional header: shorter than its declared format");
        image.optionalExtra = cast(ubyte[]) data[
            image.optionalOffset + modeledSize
            .. image.optionalOffset + optionalSize].dup;

        image.sectionTableOffset = image.optionalOffset + optionalSize;
        const sectionCount = cast(size_t) image.coff.numberOfSections;
        if (sectionCount > (data.length - image.sectionTableOffset) / sectionHeaderSize)
            throw new PeError("section table: truncated");
        image.sections = new SectionHeader[sectionCount];
        foreach (index; 0 .. sectionCount)
            image.sections[index] = loadStruct!SectionHeader(
                data,
                image.sectionTableOffset + index * sectionHeaderSize,
                "section header");

        const headerEnd = image.sectionTableOffset + sectionCount * sectionHeaderSize;
        const headerSize = cast(size_t) image.sizeOfHeaders;
        if (headerSize < headerEnd)
            throw new PeError("SizeOfHeaders is smaller than the header tables");
        if (headerSize > data.length)
            throw new PeError("SizeOfHeaders extends past the end of the file");
        image.headerPadding = cast(ubyte[]) data[headerEnd .. headerSize].dup;

        foreach (index; 0 .. image.sections.length)
        {
            const section = image.sections[index];
            if (section.sizeOfRawData == 0)
                continue;
            const start = cast(size_t) section.pointerToRawData;
            if (start > data.length || section.sizeOfRawData > data.length - start)
                throw new PeError(format("section '%s': raw data extends past the end of the file",
                    section.nameString));
        }

        image.bytes = cast(ubyte[]) data.dup;
        return image;
    }

    // ---- Header accessors ------------------------------------------------

    /// The preferred load address.
    @property ulong imageBase() const
    {
        return is64 ? header64.imageBase : header32.imageBase;
    }

    @property uint addressOfEntryPoint() const
    {
        return is64 ? header64.addressOfEntryPoint : header32.addressOfEntryPoint;
    }

    @property uint sizeOfImage() const
    {
        return is64 ? header64.sizeOfImage : header32.sizeOfImage;
    }

    @property uint sizeOfHeaders() const
    {
        return is64 ? header64.sizeOfHeaders : header32.sizeOfHeaders;
    }

    @property ushort subsystem() const
    {
        return is64 ? header64.subsystem : header32.subsystem;
    }

    @property uint numberOfRvaAndSizes() const
    {
        return is64 ? header64.numberOfRvaAndSizes : header32.numberOfRvaAndSizes;
    }

    /// Declared data directories, clamped to the 16 the format defines.
    @property const(DataDirectory)[] directories() const
    {
        const count = numberOfRvaAndSizes < dataDirectoryCount
            ? numberOfRvaAndSizes
            : cast(uint) dataDirectoryCount;
        return is64
            ? header64.directories[0 .. count]
            : header32.directories[0 .. count];
    }

    /// Translate an RVA to a file offset using the section table.
    size_t rvaToOffset(uint rva) const
    {
        foreach (index; 0 .. sections.length)
        {
            const section = sections[index];
            const span = section.virtualSize > section.sizeOfRawData
                ? section.virtualSize
                : section.sizeOfRawData;
            if (rva < section.virtualAddress)
                continue;
            const delta = cast(size_t) (rva - section.virtualAddress);
            if (delta >= span)
                continue;
            if (delta >= section.sizeOfRawData)
                throw new PeError(format("RVA 0x%X is in '%s' but not backed by file data",
                    rva, section.nameString));
            return cast(size_t) section.pointerToRawData + delta;
        }
        throw new PeError(format("RVA 0x%X is outside every section", rva));
    }

    /// Read a NUL-terminated ASCII string at a file offset.
    string cStringAt(size_t offset) const
    {
        if (offset >= bytes.length)
            throw new PeError("string offset is outside the file");
        size_t end = offset;
        while (end < bytes.length && bytes[end] != 0)
            ++end;
        if (end == bytes.length)
            throw new PeError("unterminated string at the end of the file");
        return cast(string) bytes[offset .. end].idup;
    }

    // ---- Directories -----------------------------------------------------

    /// The import directory: one entry per DLL, in descriptor order.
    ImportedLibrary[] imports() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.imports)
            return [];
        const directory = directories[DirectoryIndex.imports];
        if (directory.virtualAddress == 0)
            return [];

        ImportedLibrary[] result;
        size_t descriptor = rvaToOffset(directory.virtualAddress);
        foreach (descriptorIndex; 0 .. 0x1_0000)
        {
            const originalFirstThunk = loadStruct!uint(bytes, descriptor, "import descriptor");
            const nameRva = loadStruct!uint(bytes, descriptor + 12, "import descriptor");
            const firstThunk = loadStruct!uint(bytes, descriptor + 16, "import descriptor");
            if (nameRva == 0)
                break;

            ImportedLibrary library;
            library.dll = cStringAt(rvaToOffset(nameRva));

            const thunkRva = originalFirstThunk != 0 ? originalFirstThunk : firstThunk;
            if (thunkRva == 0)
                throw new PeError("import descriptor has no thunk table");
            size_t thunk = rvaToOffset(thunkRva);
            foreach (thunkIndex; 0 .. 0x10_0000)
            {
                if (is64)
                {
                    const entry = loadStruct!ulong(bytes, thunk, "import thunk");
                    if (entry == 0)
                        break;
                    if (entry & (1UL << 63))
                        library.symbols ~= "#" ~ to!string(entry & 0xFFFF);
                    else
                        library.symbols ~= cStringAt(
                            rvaToOffset(cast(uint) (entry & 0x7FFF_FFFF)) + 2);
                    thunk += 8;
                }
                else
                {
                    const entry = loadStruct!uint(bytes, thunk, "import thunk");
                    if (entry == 0)
                        break;
                    if (entry & (1u << 31))
                        library.symbols ~= "#" ~ to!string(entry & 0xFFFF);
                    else
                        library.symbols ~= cStringAt(
                            rvaToOffset(entry & 0x7FFF_FFFF) + 2);
                    thunk += 4;
                }
            }
            result ~= library;
            descriptor += 20;
        }
        return result;
    }

    /// The export directory: ordinals, names, RVAs, and forwarder targets.
    ExportSymbol[] exports() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.exports)
            return [];
        const directory = directories[DirectoryIndex.exports];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        const header = loadStruct!ExportDirectory(
            bytes, rvaToOffset(directory.virtualAddress), "export directory");
        if (header.numberOfFunctions == 0)
            return [];
        if (header.numberOfFunctions > 0x10_0000 || header.numberOfNames > 0x10_0000)
            throw new PeError("export directory is implausibly large");
        if (header.numberOfNames > header.numberOfFunctions)
            throw new PeError("export name count exceeds function count");

        string[] names;
        names.length = header.numberOfFunctions;
        if (header.numberOfNames != 0)
        {
            const nameTable = rvaToOffset(header.addressOfNames);
            const ordinalTable = rvaToOffset(header.addressOfNameOrdinals);
            foreach (index; 0 .. header.numberOfNames)
            {
                const nameRva = loadStruct!uint(bytes, nameTable + index * 4, "export name RVA");
                const ordinalIndex = loadStruct!ushort(bytes, ordinalTable + index * 2,
                    "export name ordinal");
                if (ordinalIndex >= header.numberOfFunctions)
                    throw new PeError("export name ordinal is out of range");
                names[ordinalIndex] = cStringAt(rvaToOffset(nameRva));
            }
        }

        ExportSymbol[] result;
        const functionTable = rvaToOffset(header.addressOfFunctions);
        foreach (index; 0 .. header.numberOfFunctions)
        {
            const functionRva = loadStruct!uint(bytes, functionTable + index * 4,
                "export address");
            if (functionRva == 0)
                continue;
            ExportSymbol symbol;
            symbol.ordinal = header.baseOrdinal + cast(uint) index;
            symbol.name = names[index];
            symbol.rva = functionRva;
            if (functionRva >= directory.virtualAddress
                && functionRva < directory.virtualAddress + directory.size)
                symbol.forwarder = cStringAt(rvaToOffset(functionRva));
            result ~= symbol;
        }
        return result;
    }

    /// Walk the resource tree into a flat list of leaves.
    ResourceEntry[] resources() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.resources)
            return [];
        const directory = directories[DirectoryIndex.resources];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        const base = rvaToOffset(directory.virtualAddress);
        ResourceEntry[] result;
        uint[3] ids = [0u, 0u, 0u];
        string[3] names = [string.init, string.init, string.init];
        walkResources(this, base, base, 0, ids, names, result);
        return result;
    }

    /// The bytes backing one resource leaf.
    const(ubyte)[] resourceData(const ref ResourceEntry entry) const
    {
        if (entry.size == 0)
            return [];
        if (entry.dataOffset > bytes.length || entry.size > bytes.length - entry.dataOffset)
            throw new PeError("resource data extends past the end of the file");
        return bytes[entry.dataOffset .. entry.dataOffset + entry.size];
    }

    /// Base-relocation blocks with their page RVAs and entry counts.
    RelocationBlockInfo[] relocationBlocks() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.baseRelocations)
            return [];
        const directory = directories[DirectoryIndex.baseRelocations];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        const start = rvaToOffset(directory.virtualAddress);
        if (start > bytes.length || directory.size > bytes.length - start)
            throw new PeError("relocation directory extends past the end of the file");
        const end = start + directory.size;

        RelocationBlockInfo[] result;
        size_t offset = start;
        foreach (blockIndex; 0 .. 0x10_0000)
        {
            if (offset + RelocationBlock.sizeof > end)
                break;
            const block = loadStruct!RelocationBlock(bytes, offset, "relocation block");
            if (block.blockSize < RelocationBlock.sizeof || offset + block.blockSize > end)
                throw new PeError("relocation block has an invalid size");
            RelocationBlockInfo info;
            info.pageRva = block.pageRva;
            info.blockSize = block.blockSize;
            info.entryCount = (block.blockSize - cast(uint) RelocationBlock.sizeof) / 2;
            result ~= info;
            offset += block.blockSize;
        }
        return result;
    }

    /// Debug-directory entries, including CodeView RSDS details.
    DebugEntryInfo[] debugEntries() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.debugDirectory)
            return [];
        const directory = directories[DirectoryIndex.debugDirectory];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        const start = rvaToOffset(directory.virtualAddress);
        if (start > bytes.length || directory.size > bytes.length - start)
            throw new PeError("debug directory extends past the end of the file");
        if (directory.size % DebugDirectoryEntry.sizeof != 0)
            throw new PeError("debug directory size is not a multiple of 28");

        DebugEntryInfo[] result;
        const count = directory.size / DebugDirectoryEntry.sizeof;
        foreach (index; 0 .. count)
        {
            const entry = loadStruct!DebugDirectoryEntry(
                bytes, start + index * DebugDirectoryEntry.sizeof, "debug directory entry");
            DebugEntryInfo info;
            info.type = entry.type;
            info.sizeOfData = entry.sizeOfData;
            info.addressOfRawData = entry.addressOfRawData;
            info.pointerToRawData = entry.pointerToRawData;
            info.timeDateStamp = entry.timeDateStamp;
            info.majorVersion = entry.majorVersion;
            info.minorVersion = entry.minorVersion;

            if (entry.sizeOfData >= CodeViewRsdsHeader.sizeof)
            {
                size_t dataOffset;
                if (entry.pointerToRawData != 0)
                    dataOffset = cast(size_t) entry.pointerToRawData;
                else if (entry.addressOfRawData != 0)
                    dataOffset = rvaToOffset(entry.addressOfRawData);
                else
                    dataOffset = 0;
                if (dataOffset != 0
                    && dataOffset <= bytes.length
                    && entry.sizeOfData <= bytes.length - dataOffset)
                {
                    const header = loadStruct!CodeViewRsdsHeader(
                        bytes, dataOffset, "CodeView header");
                    if (header.signature == "RSDS")
                    {
                        info.codeViewGuid = header.guid;
                        info.codeViewAge = header.age;
                        const pathStart = dataOffset + CodeViewRsdsHeader.sizeof;
                        const pathEnd = dataOffset + entry.sizeOfData;
                        size_t cursor = pathStart;
                        while (cursor < pathEnd && bytes[cursor] != 0)
                            ++cursor;
                        if (cursor > pathStart)
                            info.codeViewPath = cast(string) bytes[pathStart .. cursor].idup;
                    }
                }
            }
            result ~= info;
        }
        return result;
    }

    /// WIN_CERTIFICATE records from the security directory.
    CertificateInfo[] certificates() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.security)
            return [];
        const directory = directories[DirectoryIndex.security];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        // The security directory stores a file offset, not an RVA.
        const start = cast(size_t) directory.virtualAddress;
        if (start > bytes.length || directory.size > bytes.length - start)
            throw new PeError("certificate table extends past the end of the file");
        const end = start + directory.size;

        CertificateInfo[] result;
        size_t offset = start;
        foreach (index; 0 .. 0x1000)
        {
            if (offset + WinCertificate.sizeof > end)
                break;
            const certificate = loadStruct!WinCertificate(bytes, offset, "WIN_CERTIFICATE");
            if (certificate.length < WinCertificate.sizeof)
                throw new PeError("WIN_CERTIFICATE has an invalid length");
            CertificateInfo info;
            info.length = certificate.length;
            info.revision = certificate.revision;
            info.certificateType = certificate.certificateType;
            info.fileOffset = cast(uint) offset;
            result ~= info;
            const aligned = (cast(size_t) certificate.length + 7) & ~cast(size_t) 7;
            offset += aligned;
        }
        return result;
    }

    /// The delay-load import table.
    DelayImport[] delayImports() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.delayImports)
            return [];
        const directory = directories[DirectoryIndex.delayImports];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        DelayImport[] result;
        size_t descriptor = rvaToOffset(directory.virtualAddress);
        foreach (descriptorIndex; 0 .. 0x1_0000)
        {
            const entry = loadStruct!DelayImportDescriptor(bytes, descriptor, "delay import descriptor");
            if (entry.nameRva == 0 && entry.importNameTableRva == 0)
                break;

            DelayImport library;
            library.dll = cStringAt(rvaToOffset(delayValueToRva(entry.nameRva, entry.attributes)));
            const thunkRva = entry.importNameTableRva != 0
                ? delayValueToRva(entry.importNameTableRva, entry.attributes)
                : delayValueToRva(entry.importAddressTableRva, entry.attributes);
            if (thunkRva == 0)
                throw new PeError("delay import descriptor has no thunk table");
            size_t thunk = rvaToOffset(thunkRva);
            foreach (thunkIndex; 0 .. 0x10_0000)
            {
                if (is64)
                {
                    const value = loadStruct!ulong(bytes, thunk, "delay import thunk");
                    if (value == 0)
                        break;
                    if (value & (1UL << 63))
                        library.symbols ~= "#" ~ to!string(value & 0xFFFF);
                    else
                        library.symbols ~= cStringAt(
                            rvaToOffset(cast(uint) (value & 0x7FFF_FFFF)) + 2);
                    thunk += 8;
                }
                else
                {
                    const value = loadStruct!uint(bytes, thunk, "delay import thunk");
                    if (value == 0)
                        break;
                    if (value & (1u << 31))
                        library.symbols ~= "#" ~ to!string(value & 0xFFFF);
                    else
                        library.symbols ~= cStringAt(
                            rvaToOffset(value & 0x7FFF_FFFF) + 2);
                    thunk += 4;
                }
            }
            result ~= library;
            descriptor += DelayImportDescriptor.sizeof;
        }
        return result;
    }

    /// The TLS directory and its callback addresses.
    TlsInfo tls() const
    {
        TlsInfo info;
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.tls)
            return info;
        const directory = directories[DirectoryIndex.tls];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return info;

        const offset = rvaToOffset(directory.virtualAddress);
        if (is64)
        {
            const tls = loadStruct!TlsDirectory64(bytes, offset, "TLS directory");
            info.startAddressOfRawData = tls.startAddressOfRawData;
            info.endAddressOfRawData = tls.endAddressOfRawData;
            info.addressOfIndex = tls.addressOfIndex;
            info.addressOfCallbacks = tls.addressOfCallbacks;
            info.sizeOfZeroFill = tls.sizeOfZeroFill;
            info.characteristics = tls.characteristics;
        }
        else
        {
            const tls = loadStruct!TlsDirectory32(bytes, offset, "TLS directory");
            info.startAddressOfRawData = tls.startAddressOfRawData;
            info.endAddressOfRawData = tls.endAddressOfRawData;
            info.addressOfIndex = tls.addressOfIndex;
            info.addressOfCallbacks = tls.addressOfCallbacks;
            info.sizeOfZeroFill = tls.sizeOfZeroFill;
            info.characteristics = tls.characteristics;
        }
        info.present = true;

        if (info.addressOfCallbacks != 0)
        {
            const rva = vaToRva(info.addressOfCallbacks);
            size_t callbacks = rvaToOffset(rva);
            foreach (index; 0 .. 0x1000)
            {
                const value = is64
                    ? loadStruct!ulong(bytes, callbacks, "TLS callback")
                    : loadStruct!uint(bytes, callbacks, "TLS callback");
                if (value == 0)
                    break;
                info.callbacks ~= value;
                callbacks += is64 ? 8 : 4;
            }
        }
        return info;
    }

    /// Number of x64 RUNTIME_FUNCTION entries in the exception directory.
    size_t exceptionCount() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.exception)
            return 0;
        const directory = directories[DirectoryIndex.exception];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return 0;
        const entrySize = coff.machine == Machine.arm64
            ? 8
            : RuntimeFunction.sizeof;
        return directory.size / entrySize;
    }

    /// Bound-import descriptors (data directory index 11).
    BoundImportInfo[] boundImports() const
    {
        const directories = this.directories();
        if (directories.length <= DirectoryIndex.boundImports)
            return [];
        const directory = directories[DirectoryIndex.boundImports];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];

        const base = rvaToOffset(directory.virtualAddress);
        BoundImportInfo[] result;
        foreach (index; 0 .. 0x1000)
        {
            const offset = base + index * BoundImportDescriptor.sizeof;
            if (offset + BoundImportDescriptor.sizeof > bytes.length)
                break;
            const descriptor = loadStruct!BoundImportDescriptor(bytes, offset,
                "bound import descriptor");
            if (descriptor.timeDateStamp == 0 && descriptor.offsetModuleName == 0)
                break;
            BoundImportInfo info;
            info.timeDateStamp = descriptor.timeDateStamp;
            info.dll = cStringAt(base + descriptor.offsetModuleName);
            result ~= info;
        }
        return result;
    }

    /// Raw bytes behind one data directory. The security directory's first
    /// field is a file offset, not an RVA; that case is handled explicitly.
    const(ubyte)[] directoryBytes(size_t index) const
    {
        const directories = this.directories();
        if (index >= directories.length)
            return [];
        const directory = directories[index];
        if (directory.virtualAddress == 0 || directory.size == 0)
            return [];
        const start = index == DirectoryIndex.security
            ? cast(size_t) directory.virtualAddress
            : rvaToOffset(directory.virtualAddress);
        if (start > bytes.length || directory.size > bytes.length - start)
            throw new PeError("data directory extends past the end of the file");
        return bytes[start .. start + directory.size];
    }

    // ---- Mutation --------------------------------------------------------

    /// Replace the COFF link timestamp. `rebuild` writes it into the header.
    void setTimeDateStamp(uint unixTime)
    {
        coff.timeDateStamp = unixTime;
    }

    /**
     * Replace one resource leaf's bytes in place.
     *
     * The replacement must fit the existing slot. The slot's size field is
     * updated and the remainder is zeroed, so the image stays well-formed.
     * Returns false when no leaf matches the selector.
     */
    bool replaceResourceData(uint typeId, uint nameId, uint languageId,
        const(ubyte)[] data)
    {
        foreach (entry; resources())
        {
            if (entry.typeId != typeId || entry.nameId != nameId
                || entry.languageId != languageId)
                continue;
            if (data.length > entry.size)
                throw new PeError(format(
                    "replacement is %d bytes but the resource slot holds %d",
                    data.length, entry.size));
            bytes[entry.dataOffset .. entry.dataOffset + data.length] = data;
            foreach (index; data.length .. entry.size)
                bytes[entry.dataOffset + index] = 0;
            storeStruct(bytes, entry.dataEntryOffset + 4,
                cast(uint) data.length, "resource data size");
            return true;
        }
        return false;
    }

    // ---- Re-emission -----------------------------------------------------

    /**
     * Re-encode the image from the parsed model.
     *
     * Header bytes are written field by field; payload, section gaps, and any
     * overlay come from the original (or mutated) file. For an unmodified
     * image the result must equal `bytes`, which is the identity invariant.
     */
    ubyte[] rebuild() const
    {
        auto output = cast(ubyte[]) bytes.dup;

        storeStruct(output, 0, dos, "DOS header");
        output[dosHeaderSize .. dosHeaderSize + stub.length] = stub;

        const peOffset = cast(size_t) dos.e_lfanew;
        storeStruct(output, peOffset, peSignature, "PE signature");
        storeStruct(output, peOffset + 4, coff, "COFF header");
        if (is64)
            storeStruct(output, optionalOffset, header64, "optional header");
        else
            storeStruct(output, optionalOffset, header32, "optional header");

        const modeledSize = is64 ? OptionalHeader64.sizeof : OptionalHeader32.sizeof;
        if (optionalExtra.length)
            output[optionalOffset + modeledSize
                .. optionalOffset + modeledSize + optionalExtra.length] = optionalExtra;

        foreach (index; 0 .. sections.length)
            storeStruct(output, sectionTableOffset + index * sectionHeaderSize,
                sections[index], "section header");

        const paddingStart = sectionTableOffset + sections.length * sectionHeaderSize;
        if (headerPadding.length)
            output[paddingStart .. paddingStart + headerPadding.length] = headerPadding;

        return output;
    }

    /// Convert an image virtual address to an RVA.
    uint vaToRva(ulong address) const
    {
        if (address < imageBase)
            throw new PeError(format("address 0x%X is below the image base", address));
        const rva = address - imageBase;
        if (rva > uint.max)
            throw new PeError("address does not fit a 32-bit RVA");
        return cast(uint) rva;
    }

    /// Map a delay-load field to an RVA, honoring the dlattrRva attribute.
    uint delayValueToRva(uint value, uint attributes) const
    {
        if (attributes & delayImportRvaAttribute)
            return value;
        if (value < imageBase || value - imageBase > uint.max)
            throw new PeError("delay-import virtual address cannot map to an RVA");
        return cast(uint) (value - imageBase);
    }
}

/// Read a length-prefixed UTF-16 resource name.
private string readResourceName(const(PeImage) image, size_t offset)
{
    const length = loadStruct!ushort(image.bytes, offset, "resource name length");
    if (length == 0)
        return "";

    string result;
    size_t index = 0;
    while (index < length)
    {
        uint unit = loadStruct!ushort(image.bytes, offset + 2 + index * 2, "resource name");
        ++index;
        uint codePoint = unit;
        if (unit >= 0xD800 && unit <= 0xDBFF && index < length)
        {
            const low = loadStruct!ushort(image.bytes, offset + 2 + index * 2,
                "resource name");
            if (low >= 0xDC00 && low <= 0xDFFF)
            {
                codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                ++index;
            }
        }
        char[4] buffer;
        const count = encode(buffer, cast(dchar) codePoint);
        result ~= buffer[0 .. count];
    }
    return result;
}

/// Recursive resource-tree walk. Leaves become flat `ResourceEntry` records.
private void walkResources(const(PeImage) image, size_t root, size_t directoryOffset, int depth,
    uint[3] ids, string[3] names, ref ResourceEntry[] result)
{
    if (depth > 16)
        throw new PeError("resource tree is deeper than 16 levels");
    const directory = loadStruct!ResourceDirectory(image.bytes, directoryOffset,
        "resource directory");
    const count = cast(size_t) directory.numberOfNamedEntries
        + directory.numberOfIdEntries;
    if (count > (image.bytes.length - directoryOffset) / ResourceDirectoryEntry.sizeof)
        throw new PeError("resource directory entry count exceeds the file");
    foreach (index; 0 .. count)
    {
        const entryOffset = directoryOffset + ResourceDirectory.sizeof
            + index * ResourceDirectoryEntry.sizeof;
        const entry = loadStruct!ResourceDirectoryEntry(image.bytes, entryOffset,
            "resource directory entry");

        uint[3] childIds = ids;
        string[3] childNames = names;
        if (depth < 3)
        {
            if (entry.nameOrId & resourceNameFlag)
                childNames[depth] = readResourceName(image,
                    root + (entry.nameOrId & 0x7FFF_FFFF));
            else
                childIds[depth] = entry.nameOrId;
        }

        if (entry.offsetToData & resourceDirectoryFlag)
        {
            walkResources(image, root, root + (entry.offsetToData & 0x7FFF_FFFF),
                depth + 1, childIds, childNames, result);
            continue;
        }

        const dataEntryOffset = root + entry.offsetToData;
        const data = loadStruct!ResourceDataEntry(image.bytes, dataEntryOffset,
            "resource data entry");
        ResourceEntry record;
        record.typeId = childIds[0];
        record.typeName = childNames[0].length != 0
            ? childNames[0]
            : resourceTypeName(childIds[0]);
        record.nameId = childIds[1];
        record.name = childNames[1];
        record.languageId = childIds[2];
        record.dataRva = data.dataRva;
        record.size = data.size;
        record.codePage = data.codePage;
        record.dataEntryOffset = dataEntryOffset;
        record.dataOffset = data.size != 0 ? image.rvaToOffset(data.dataRva) : 0;
        if (data.size != 0
            && (record.dataOffset > image.bytes.length
                || data.size > image.bytes.length - record.dataOffset))
            throw new PeError("resource data extends past the end of the file");
        result ~= record;
    }
}

/// The readable name for a known resource type, or an empty string.
string resourceTypeName(uint typeId)
{
    switch (typeId)
    {
    case ResourceType.cursor:
        return "cursor";
    case ResourceType.bitmap:
        return "bitmap";
    case ResourceType.icon:
        return "icon";
    case ResourceType.menu:
        return "menu";
    case ResourceType.dialog:
        return "dialog";
    case ResourceType.stringTable:
        return "string";
    case ResourceType.font:
        return "font";
    case ResourceType.accelerator:
        return "accelerator";
    case ResourceType.rcData:
        return "rcdata";
    case ResourceType.messageTable:
        return "message-table";
    case ResourceType.groupIcon:
        return "group-icon";
    case ResourceType.versionInfo:
        return "version";
    case ResourceType.manifest:
        return "manifest";
    default:
        return "";
    }
}

struct ImportedLibrary
{
    string dll;
    string[] symbols;
}

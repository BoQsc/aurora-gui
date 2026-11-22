// SPDX-License-Identifier: 0BSD
/**
 * On-disk Windows PE/COFF definitions for the binary-format laboratory.
 *
 * Every structure is declared field by field at its specified on-disk size and
 * checked with `static assert`. Adding, removing, or reordering a field fails
 * the build instead of silently shifting a read.
 *
 * No Windows SDK header is used or translated. The layouts come from the
 * Microsoft PE/COFF specification (revision 11), which documents the format.
 */
module auroraexp.win32.pe;

import core.stdc.string : memcpy;

version (LittleEndian) {}
else static assert(0, "PE images are little-endian; this host is not");

/// "MZ", the first two bytes of a DOS/PE image.
enum ushort dosSignature = 0x5A4D;
/// "PE\0\0", read as a little-endian `uint`.
enum uint peSignature = 0x0000_4550;

enum ushort pe32Magic = 0x010B;
enum ushort pe32PlusMagic = 0x020B;

enum size_t dosHeaderSize = 64;
enum size_t coffHeaderSize = 20;
enum size_t sectionHeaderSize = 40;
enum size_t dataDirectoryCount = 16;

/// PE/COFF `Machine` values the laboratory names explicitly.
enum Machine : ushort
{
    unknown = 0x0000,
    i386 = 0x014C,
    amd64 = 0x8664,
    arm64 = 0xAA64,
}

/// PE/COFF `Subsystem` values the laboratory names explicitly.
enum Subsystem : ushort
{
    unknown = 0,
    native = 1,
    windowsGui = 2,
    windowsCui = 3,
}

/// Indices into the optional header's data-directory array.
enum DirectoryIndex : size_t
{
    exports = 0,
    imports = 1,
    resources = 2,
    exception = 3,
    security = 4,
    baseRelocations = 5,
    debugDirectory = 6,
    architecture = 7,
    globalPointer = 8,
    tls = 9,
    loadConfig = 10,
    boundImports = 11,
    importAddressTable = 12,
    delayImports = 13,
    clrRuntime = 14,
    reserved = 15,
}

/// Raised for every malformed or unsupported image the laboratory rejects.
class PeError : Exception
{
    this(string message)
    {
        super(message);
    }
}

/// The 64-byte DOS header. Only `e_magic` and `e_lfanew` are interpreted; the
/// remaining fields are carried so a rebuild reproduces them.
align(1) struct DosHeader
{
    ushort e_magic;
    ushort e_cblp;
    ushort e_cp;
    ushort e_crlc;
    ushort e_cparhdr;
    ushort e_minalloc;
    ushort e_maxalloc;
    ushort e_ss;
    ushort e_sp;
    ushort e_csum;
    ushort e_ip;
    ushort e_cs;
    ushort e_lfarlc;
    ushort e_ovno;
    ushort[4] e_res;
    ushort e_oemid;
    ushort e_oeminfo;
    ushort[10] e_res2;
    uint e_lfanew;
}
static assert(DosHeader.sizeof == dosHeaderSize);

/// The 20-byte COFF file header that follows the PE signature.
align(1) struct CoffHeader
{
    ushort machine;
    ushort numberOfSections;
    uint timeDateStamp;
    uint pointerToSymbolTable;
    uint numberOfSymbols;
    ushort sizeOfOptionalHeader;
    ushort characteristics;
}
static assert(CoffHeader.sizeof == coffHeaderSize);

/// One 8-byte data-directory entry.
align(1) struct DataDirectory
{
    uint virtualAddress;
    uint size;
}
static assert(DataDirectory.sizeof == 8);

/// The PE32 optional header (magic 0x10B), including all 16 directories.
align(1) struct OptionalHeader32
{
    ushort magic;
    ubyte majorLinkerVersion;
    ubyte minorLinkerVersion;
    uint sizeOfCode;
    uint sizeOfInitializedData;
    uint sizeOfUninitializedData;
    uint addressOfEntryPoint;
    uint baseOfCode;
    uint baseOfData;
    uint imageBase;
    uint sectionAlignment;
    uint fileAlignment;
    ushort majorOperatingSystemVersion;
    ushort minorOperatingSystemVersion;
    ushort majorImageVersion;
    ushort minorImageVersion;
    ushort majorSubsystemVersion;
    ushort minorSubsystemVersion;
    uint win32VersionValue;
    uint sizeOfImage;
    uint sizeOfHeaders;
    uint checkSum;
    ushort subsystem;
    ushort dllCharacteristics;
    uint sizeOfStackReserve;
    uint sizeOfStackCommit;
    uint sizeOfHeapReserve;
    uint sizeOfHeapCommit;
    uint loaderFlags;
    uint numberOfRvaAndSizes;
    DataDirectory[dataDirectoryCount] directories;
}
static assert(OptionalHeader32.sizeof == 224);

/// The PE32+ optional header (magic 0x20B), including all 16 directories.
/// `baseOfData` is absent and `imageBase` plus the stack/heap fields are wider.
align(1) struct OptionalHeader64
{
    ushort magic;
    ubyte majorLinkerVersion;
    ubyte minorLinkerVersion;
    uint sizeOfCode;
    uint sizeOfInitializedData;
    uint sizeOfUninitializedData;
    uint addressOfEntryPoint;
    uint baseOfCode;
    ulong imageBase;
    uint sectionAlignment;
    uint fileAlignment;
    ushort majorOperatingSystemVersion;
    ushort minorOperatingSystemVersion;
    ushort majorImageVersion;
    ushort minorImageVersion;
    ushort majorSubsystemVersion;
    ushort minorSubsystemVersion;
    uint win32VersionValue;
    uint sizeOfImage;
    uint sizeOfHeaders;
    uint checkSum;
    ushort subsystem;
    ushort dllCharacteristics;
    ulong sizeOfStackReserve;
    ulong sizeOfStackCommit;
    ulong sizeOfHeapReserve;
    ulong sizeOfHeapCommit;
    uint loaderFlags;
    uint numberOfRvaAndSizes;
    DataDirectory[dataDirectoryCount] directories;
}
static assert(OptionalHeader64.sizeof == 240);

/// One 40-byte section-table entry.
align(1) struct SectionHeader
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

    /// The section name without its NUL padding.
    @property string nameString() const
    {
        size_t length;
        while (length < name.length && name[length] != '\0')
            ++length;
        return name[0 .. length].idup;
    }
}
static assert(SectionHeader.sizeof == sectionHeaderSize);

/// Resource directory entries set this bit to point at a subdirectory.
enum uint resourceDirectoryFlag = 0x8000_0000;
/// Resource directory entries set this bit to mark a named (UTF-16) entry.
enum uint resourceNameFlag = 0x8000_0000;

/// The resource types the laboratory names explicitly. Others stay numeric.
enum ResourceType : uint
{
    cursor = 1,
    bitmap = 2,
    icon = 3,
    menu = 4,
    dialog = 5,
    stringTable = 6,
    fontDirectory = 7,
    font = 8,
    accelerator = 9,
    rcData = 10,
    messageTable = 11,
    groupCursor = 12,
    groupIcon = 14,
    versionInfo = 16,
    dialogInclude = 17,
    plugAndPlay = 19,
    vxd = 20,
    animatedCursor = 21,
    animatedIcon = 22,
    html = 23,
    manifest = 24,
}

/// The 40-byte export directory (data directory index 0).
align(1) struct ExportDirectory
{
    uint characteristics;
    uint timeDateStamp;
    ushort majorVersion;
    ushort minorVersion;
    uint nameRva;
    uint baseOrdinal;
    uint numberOfFunctions;
    uint numberOfNames;
    uint addressOfFunctions;
    uint addressOfNames;
    uint addressOfNameOrdinals;
}
static assert(ExportDirectory.sizeof == 40);

/// A resource directory node (data directory index 2 points at the root).
align(1) struct ResourceDirectory
{
    uint characteristics;
    uint timeDateStamp;
    ushort majorVersion;
    ushort minorVersion;
    ushort numberOfNamedEntries;
    ushort numberOfIdEntries;
}
static assert(ResourceDirectory.sizeof == 16);

/// One resource directory entry: a name or numeric ID, and either a child
/// directory offset or a data-entry offset, relative to the resource root.
align(1) struct ResourceDirectoryEntry
{
    uint nameOrId;
    uint offsetToData;
}
static assert(ResourceDirectoryEntry.sizeof == 8);

/// The 16-byte leaf that points at resource bytes.
align(1) struct ResourceDataEntry
{
    uint dataRva;
    uint size;
    uint codePage;
    uint reserved;
}
static assert(ResourceDataEntry.sizeof == 16);

/// A base-relocation block header (data directory index 5).
align(1) struct RelocationBlock
{
    uint pageRva;
    uint blockSize;
}
static assert(RelocationBlock.sizeof == 8);

/// One 28-byte debug directory entry (data directory index 6).
align(1) struct DebugDirectoryEntry
{
    uint characteristics;
    uint timeDateStamp;
    ushort majorVersion;
    ushort minorVersion;
    uint type;
    uint sizeOfData;
    uint addressOfRawData;
    uint pointerToRawData;
}
static assert(DebugDirectoryEntry.sizeof == 28);

/// The stable prefix of a CodeView RSDS record inside a debug entry.
align(1) struct CodeViewRsdsHeader
{
    char[4] signature;
    ubyte[16] guid;
    uint age;
}
static assert(CodeViewRsdsHeader.sizeof == 24);

/// "RSDS" stored as a little-endian uint.
enum uint codeViewRsdsSignature = 0x5344_5352;

/// One WIN_CERTIFICATE header (data directory index 4).
align(1) struct WinCertificate
{
    uint length;
    ushort revision;
    ushort certificateType;
}
static assert(WinCertificate.sizeof == 8);

/// A 20-byte import descriptor: the raw form the loader rewrites.
align(1) struct ImportDescriptor
{
    uint originalFirstThunk;
    uint timeDateStamp;
    uint forwarderChain;
    uint name;
    uint firstThunk;
}
static assert(ImportDescriptor.sizeof == 20);

/// A 32-byte delay-load import descriptor (data directory index 13).
align(1) struct DelayImportDescriptor
{
    uint attributes;
    uint nameRva;
    uint moduleHandleRva;
    uint importAddressTableRva;
    uint importNameTableRva;
    uint boundImportAddressTableRva;
    uint unloadInformationTableRva;
    uint timeDateStamp;
}
static assert(DelayImportDescriptor.sizeof == 32);

/// Delay-load attribute bit: fields are RVAs, not virtual addresses.
enum uint delayImportRvaAttribute = 0x1;

/// The 24-byte TLS directory for PE32 (data directory index 9).
align(1) struct TlsDirectory32
{
    uint startAddressOfRawData;
    uint endAddressOfRawData;
    uint addressOfIndex;
    uint addressOfCallbacks;
    uint sizeOfZeroFill;
    uint characteristics;
}
static assert(TlsDirectory32.sizeof == 24);

/// The 40-byte TLS directory for PE32+.
align(1) struct TlsDirectory64
{
    ulong startAddressOfRawData;
    ulong endAddressOfRawData;
    ulong addressOfIndex;
    ulong addressOfCallbacks;
    uint sizeOfZeroFill;
    uint characteristics;
}
static assert(TlsDirectory64.sizeof == 40);

/// One 12-byte x64 RUNTIME_FUNCTION entry (data directory index 3).
align(1) struct RuntimeFunction
{
    uint beginAddress;
    uint endAddress;
    uint unwindInfoAddress;
}
static assert(RuntimeFunction.sizeof == 12);

/// An 8-byte bound-import descriptor (data directory index 11).
align(1) struct BoundImportDescriptor
{
    uint timeDateStamp;
    ushort offsetModuleName;
    ushort numberOfModuleForwarderRefs;
}
static assert(BoundImportDescriptor.sizeof == 8);


/// Read one structure from `data` at `offset`, with an explicit truncation
/// message. Comparison of equal structs is byte comparison for these PODs.
T loadStruct(T)(const(ubyte)[] data, size_t offset, string what)
{
    if (offset > data.length || T.sizeof > data.length - offset)
        throw new PeError(what ~ ": truncated");
    T value = void;
    memcpy(&value, data.ptr + offset, T.sizeof);
    return value;
}

/// Write one structure into `data` at `offset`.
void storeStruct(T)(ubyte[] data, size_t offset, T value, string what)
{
    if (offset > data.length || T.sizeof > data.length - offset)
        throw new PeError(what ~ ": no room in the output image");
    memcpy(data.ptr + offset, &value, T.sizeof);
}

/// A readable machine name for the laboratory's summary output.
string machineName(ushort machine)
{
    switch (machine)
    {
    case Machine.i386:
        return "i386";
    case Machine.amd64:
        return "amd64";
    case Machine.arm64:
        return "arm64";
    default:
        return "unknown";
    }
}

/// A readable subsystem name for the laboratory's summary output.
string subsystemName(ushort subsystem)
{
    switch (subsystem)
    {
    case Subsystem.native:
        return "native";
    case Subsystem.windowsGui:
        return "windows-gui";
    case Subsystem.windowsCui:
        return "windows-console";
    default:
        return "unknown";
    }
}

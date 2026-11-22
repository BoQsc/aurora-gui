// SPDX-License-Identifier: 0BSD
/**
 * A from-scratch PE image loader for the binary-format laboratory.
 *
 * The loader does what the Windows loader does for the parts modeled here:
 * reserve the image, copy headers and sections, apply base relocations, resolve
 * imports through `LoadLibraryA`/`GetProcAddress`, set section protections,
 * flush the instruction cache, and run the entry point in a new thread.
 *
 * It is not a replacement for the system loader. TLS callbacks, exception
 * unwind registration, manifest/SxS activation, and forwarded exports are
 * outside this loader's contract, and it refuses images whose bitness differs
 * from its own.
 */
module auroraexp.win32.loader;

import auroraexp.win32.image;
import auroraexp.win32.pe;
import core.stdc.string : memcpy;
import core.sys.windows.windows;
import std.format : format;
import std.string : fromStringz;

/// Raised when an image cannot be mapped or run.
class LoadError : Exception
{
    this(string message)
    {
        super(message);
    }
}

/// One section as placed in the mapped image.
struct SectionPlacement
{
    string name;
    void* address;
    size_t bytes;
    DWORD protection;
}

/// The result of mapping an image.
struct MappedImage
{
    void* base;
    size_t sizeOfImage;
    ulong preferredBase;
    ulong entryPoint;
    long relocationDelta;
    size_t relocationsApplied;
    size_t importsResolved;
    SectionPlacement[] sections;
}

/// Map an image into this process and prepare it to run.
MappedImage mapImage(const(ubyte)[] data)
{
    const image = PeImage.load(data);
    if (image.is64 != (size_t.sizeof == 8))
        throw new LoadError("image bitness does not match the loader");

    MappedImage mapped;
    mapped.preferredBase = image.imageBase;
    mapped.sizeOfImage = image.sizeOfImage;
    if (mapped.sizeOfImage == 0)
        throw new LoadError("SizeOfImage is zero");

    void* base = VirtualAlloc(cast(void*) mapped.preferredBase, mapped.sizeOfImage,
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (base is null)
        base = VirtualAlloc(null, mapped.sizeOfImage,
            MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (base is null)
        throw new LoadError(format("VirtualAlloc failed (%u)", GetLastError()));
    mapped.base = base;
    mapped.relocationDelta = cast(long) cast(ulong) base
        - cast(long) image.imageBase;

    const directories = image.directories();
    if (mapped.relocationDelta != 0)
    {
        if (directories.length <= DirectoryIndex.baseRelocations
            || directories[DirectoryIndex.baseRelocations].virtualAddress == 0)
            throw new LoadError("image needs relocation but has no relocation directory");
    }

    const headerBytes = cast(size_t) image.sizeOfHeaders;
    if (headerBytes > data.length || headerBytes > mapped.sizeOfImage)
        throw new LoadError("SizeOfHeaders is outside the image");
    memcpy(base, data.ptr, headerBytes);

    auto loaded = cast(ubyte*) base;
    if (loaded[0] != 'M' || loaded[1] != 'Z')
        throw new LoadError("mapped headers do not start with MZ");

    foreach (index; 0 .. image.sections.length)
    {
        const section = image.sections[index];
        SectionPlacement placement;
        placement.name = section.nameString;
        placement.address = loaded + section.virtualAddress;
        placement.bytes = section.sizeOfRawData;
        placement.protection = sectionProtection(section.characteristics);

        if (section.sizeOfRawData != 0)
        {
            const source = cast(size_t) section.pointerToRawData;
            if (source > data.length || section.sizeOfRawData > data.length - source)
                throw new LoadError(format("section '%s' raw data is outside the file",
                    section.nameString));
            if (section.virtualAddress + section.sizeOfRawData > mapped.sizeOfImage)
                throw new LoadError(format("section '%s' does not fit SizeOfImage",
                    section.nameString));
            memcpy(loaded + section.virtualAddress, data.ptr + source,
                section.sizeOfRawData);
        }
        mapped.sections ~= placement;
    }

    if (mapped.relocationDelta != 0)
        applyRelocations(image, mapped);
    resolveImports(image, mapped);
    protectImage(image, mapped);
    FlushInstructionCache(GetCurrentProcess(), base, mapped.sizeOfImage);

    mapped.entryPoint = cast(ulong) base + image.addressOfEntryPoint;
    return mapped;
}

/// Run the mapped entry point in a new thread and return its exit code.
ulong runEntry(const ref MappedImage mapped)
{
    DWORD threadId;
    auto thread = CreateThread(null, 0,
        cast(LPTHREAD_START_ROUTINE) cast(void*) mapped.entryPoint,
        null, 0, &threadId);
    if (thread is null)
        throw new LoadError(format("CreateThread failed (%u)", GetLastError()));
    scope (exit) CloseHandle(thread);

    if (WaitForSingleObject(thread, 30_000) != WAIT_OBJECT_0)
        throw new LoadError("entry thread did not finish");
    DWORD exitCode;
    if (GetExitCodeThread(thread, &exitCode) == 0)
        throw new LoadError("GetExitCodeThread failed");
    return exitCode;
}

/// Release the mapping allocated by `mapImage`.
void unmapImage(ref MappedImage mapped)
{
    if (mapped.base is null)
        return;
    VirtualFree(mapped.base, 0, MEM_RELEASE);
    mapped.base = null;
}

/// Apply base relocations for a mapping that landed away from its preference.
private void applyRelocations(const PeImage image, ref MappedImage mapped)
{
    const directories = image.directories();
    const directory = directories[DirectoryIndex.baseRelocations];
    if (directory.virtualAddress == 0 || directory.size == 0)
        throw new LoadError("relocation directory is empty");

    auto base = cast(ubyte*) mapped.base;
    const end = directory.virtualAddress + directory.size;
    uint offset = directory.virtualAddress;
    while (offset + RelocationBlock.sizeof <= end)
    {
        const block = cast(const(RelocationBlock)*)(base + offset);
        if (block.blockSize < RelocationBlock.sizeof
            || offset + block.blockSize > end)
            throw new LoadError("relocation block has an invalid size");
        const count = (block.blockSize - RelocationBlock.sizeof) / 2;
        const entries = cast(const(ushort)*)(base + offset + RelocationBlock.sizeof);
        foreach (index; 0 .. count)
        {
            const value = entries[index];
            const type = cast(uint) (value >> 12);
            auto target = base + block.pageRva + (value & 0x0FFF);
            switch (type)
            {
            case 0: // IMAGE_REL_BASED_ABSOLUTE: padding, nothing to do
                break;
            case 3: // IMAGE_REL_BASED_HIGHLOW
                *cast(uint*) target += cast(uint) mapped.relocationDelta;
                ++mapped.relocationsApplied;
                break;
            case 10: // IMAGE_REL_BASED_DIR64
                *cast(ulong*) target += cast(ulong) mapped.relocationDelta;
                ++mapped.relocationsApplied;
                break;
            default:
                throw new LoadError(format("unsupported relocation type %u", type));
            }
        }
        offset += block.blockSize;
    }
}

/// Resolve the import table and fill the import address table.
private void resolveImports(const PeImage image, ref MappedImage mapped)
{
    const directories = image.directories();
    if (directories.length <= DirectoryIndex.imports)
        return;
    const directory = directories[DirectoryIndex.imports];
    if (directory.virtualAddress == 0 || directory.size == 0)
        return;

    auto base = cast(ubyte*) mapped.base;
    uint descriptorRva = directory.virtualAddress;
    foreach (index; 0 .. 0x1_0000)
    {
        const descriptor = cast(const ImportDescriptor*)(base + descriptorRva);
        if (descriptor.name == 0)
            break;

        const moduleName = fromStringz(cast(const(char)*) (base + descriptor.name));
        auto dllModule = LoadLibraryA(cast(LPCSTR) (base + descriptor.name));
        if (dllModule is null)
            throw new LoadError(format("LoadLibraryA failed for %s (%u)",
                moduleName, GetLastError()));

        const thunkRva = descriptor.originalFirstThunk != 0
            ? descriptor.originalFirstThunk
            : descriptor.firstThunk;
        if (thunkRva == 0)
            throw new LoadError("import descriptor has no thunk table");
        const lookup = cast(const size_t*)(base + thunkRva);
        auto addressTable = cast(size_t*)(base + descriptor.firstThunk);
        const ordinalFlag = image.is64 ? (1UL << 63) : (1UL << 31);

        foreach (slot; 0 .. 0x10_0000)
        {
            const value = lookup[slot];
            if (value == 0)
                break;
            FARPROC resolved;
            if (value & ordinalFlag)
                resolved = GetProcAddress(dllModule,
                    cast(LPCSTR) (cast(size_t) (value & 0xFFFF)));
            else
                resolved = GetProcAddress(dllModule,
                    cast(LPCSTR) (base + cast(uint) (value & 0x7FFF_FFFF) + 2));
            if (resolved is null)
                throw new LoadError(format("GetProcAddress failed for %s",
                    moduleName));
            addressTable[slot] = cast(size_t) resolved;
            ++mapped.importsResolved;
        }
        descriptorRva += ImportDescriptor.sizeof;
    }
}

/// Set each section's page protection and make the header page read-only.
private void protectImage(const PeImage image, ref MappedImage mapped)
{
    foreach (ref placement; mapped.sections)
    {
        if (placement.bytes == 0)
            continue;
        DWORD previous;
        if (VirtualProtect(placement.address, placement.bytes,
            placement.protection, &previous) == 0)
            throw new LoadError(format("VirtualProtect failed for %s (%u)",
                placement.name, GetLastError()));
    }
    DWORD previous;
    if (image.sizeOfHeaders != 0)
        VirtualProtect(mapped.base, image.sizeOfHeaders, PAGE_READONLY, &previous);
}

/// Translate section characteristics into a page protection value.
private DWORD sectionProtection(uint characteristics)
{
    const execute = (characteristics & 0x2000_0000) != 0;
    const read = (characteristics & 0x4000_0000) != 0;
    const write = (characteristics & 0x8000_0000) != 0;
    if (execute && write)
        return PAGE_EXECUTE_READWRITE;
    if (execute)
        return PAGE_EXECUTE_READ;
    if (write)
        return PAGE_READWRITE;
    if (read)
        return PAGE_READONLY;
    return PAGE_NOACCESS;
}

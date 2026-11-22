// SPDX-License-Identifier: 0BSD
/**
 * First-stage COFF linker.
 *
 * Merges sections from one or more objects, resolves defined symbols to output
 * RVAs, applies REL32 relocations, and emits a PE32+ image at the preferred
 * base. Archive extraction, import libraries, COMDAT selection, and absolute
 * relocation generation are the following stages.
 */
module auroraexpcoff.link;

import auroraexp.win32.pe;
import auroraexpcoff.coff;
import auroraexpcoff.archive : ArchiveError, CoffArchive;
import auroraexpcoff.imports : ShortImport, tryParseImport;
import auroraexpcoff.pdb : PdbSymbol, buildPdb;
import core.stdc.stdlib : getenv;
import std.algorithm.sorting : sort;
import std.file : write;
import std.format : format;
import std.string : fromStringz;

/// Raised when the objects cannot be linked by this stage.
class LinkError : Exception
{
    this(string message)
    {
        super(message);
    }
}

private struct OutputSection
{
    string name;
    ubyte[] data;
    uint characteristics;
    size_t virtualAddress;
    size_t rawAddress;
    size_t virtualSize;
}

private struct ImportSlot
{
    ShortImport info;
    size_t thunkOffset;
    size_t hintOffset;
}

private struct ImportDll
{
    string name;
    size_t descriptorOffset;
    size_t nameOffset;
    size_t iltOffset;
    size_t iatOffset;
    ImportSlot[] slots;
}

private size_t alignmentOf(uint characteristics)
{
    const encoded = (characteristics >> 20) & 0xF;
    if (encoded <= 1)
        return 1;
    const alignment = size_t(1) << (encoded - 1);
    return alignment > 0x2000 ? 0x2000 : alignment;
}

private size_t alignUp(size_t value, size_t alignment)
{
    return alignment <= 1 ? value : (value + alignment - 1) / alignment * alignment;
}

/// COMDAT identity: the first external symbol at offset zero in the section.
private string sectionKey(ref CoffObject object, size_t index)
{
    foreach (symbolIndex; object.primarySymbols())
    {
        const symbol = object.symbols[symbolIndex];
        size_t symbolSection;
        if (!effectiveSection(symbol.sectionNumber, symbolSection)
            || symbolSection != index
            || symbol.value != 0
            || (symbol.storageClass != 2 && symbol.storageClass != 5))
            continue;
        const name = object.symbolName(symbolIndex);
        if (name.length != 0)
            return name;
    }
    return "";
}

/// Decode a COFF section number, including DMD's weak/COMDAT high-bit form.
private bool effectiveSection(int sectionNumber, out size_t index)
{
    if (sectionNumber > 0)
    {
        index = cast(size_t) (sectionNumber - 1);
        return true;
    }
    if (sectionNumber == -1 || sectionNumber == -2)
        return false;
    const raw = cast(ushort) sectionNumber;
    if ((raw & 0x8000) != 0)
    {
        const plain = raw & 0x7FFF;
        index = cast(size_t) plain + 32767;
        return true;
    }
    return false;
}

/// Strip COFF section-group suffixes and drop non-image sections.
private string outputSectionName(string name)
{
    foreach (prefix; [".drectve", ".debug$", ".llvm_addrsig", ".note"])
        if (name.length >= prefix.length && name[0 .. prefix.length] == prefix)
            return "";
    size_t dollar;
    while (dollar < name.length && name[dollar] != '$')
        ++dollar;
    return dollar == 0 ? name : name[0 .. dollar];
}

private uint readU32(ubyte[] data, size_t offset)
{
    if (offset + 4 > data.length)
        throw new LinkError("relocation target is outside its section");
    return cast(uint) data[offset]
        | (cast(uint) data[offset + 1] << 8)
        | (cast(uint) data[offset + 2] << 16)
        | (cast(uint) data[offset + 3] << 24);
}

private void writeU32(ubyte[] data, size_t offset, uint value)
{
    if (offset + 4 > data.length)
        throw new LinkError("relocation target is outside its section");
    data[offset] = cast(ubyte) value;
    data[offset + 1] = cast(ubyte) (value >> 8);
    data[offset + 2] = cast(ubyte) (value >> 16);
    data[offset + 3] = cast(ubyte) (value >> 24);
}

private void writeU16(ubyte[] data, size_t offset, ushort value)
{
    if (offset + 2 > data.length)
        throw new LinkError("relocation target is outside its section");
    data[offset] = cast(ubyte) value;
    data[offset + 1] = cast(ubyte) (value >> 8);
}

private ulong readU64(ubyte[] data, size_t offset)
{
    if (offset + 8 > data.length)
        throw new LinkError("relocation target is outside its section");
    ulong value;
    foreach (index; 0 .. 8)
        value |= cast(ulong) data[offset + index] << (index * 8);
    return value;
}

private void writeU64(ubyte[] data, size_t offset, ulong value)
{
    if (offset + 8 > data.length)
        throw new LinkError("relocation target is outside its section");
    foreach (index; 0 .. 8)
        data[offset + index] = cast(ubyte) (value >> (index * 8));
}

private struct BaseReloc
{
    uint rva;
    ushort type;
}

private ubyte[] buildRelocations(BaseReloc[] entries)
{
    entries.sort!((left, right) => left.rva < right.rva);
    ubyte[] data;
    size_t index;
    while (index < entries.length)
    {
        const blockStart = data.length;
        const page = entries[index].rva & ~0xFFFu;
        foreach (offset; 0 .. 8)
            data ~= 0;
        size_t count;
        while (index < entries.length
            && (entries[index].rva & ~0xFFFu) == page)
        {
            const entry = cast(ushort) (entries[index].rva & 0xFFF)
                | cast(ushort) (entries[index].type << 12);
            data ~= cast(ubyte) entry;
            data ~= cast(ubyte) (entry >> 8);
            ++index;
            ++count;
        }
        if (count & 1)
        {
            data ~= 0;
            data ~= 0;
        }
        const blockSize = data.length - blockStart;
        writeU32(data, blockStart, page);
        writeU32(data, blockStart + 4, cast(uint) blockSize);
    }
    return data;
}

/// Link objects, pulling archive members for undefined symbols.
ubyte[] link(CoffObject[] objects, CoffArchive[] archives, string entryName,
    ushort subsystem = 3, string[] requiredSymbols = null,
    string pdbPath = null)
{
    CoffObject[] working = objects.dup;
    ShortImport[] imports;
    bool[string] importedSymbols;
    bool[string] loadedMembers;
    bool[string] requiredAttempted;
    string[] required = [entryName];
    if (requiredSymbols !is null)
        required ~= requiredSymbols;
    bool[string] attempted;
    bool progressed = true;
    while (progressed)
    {
        progressed = false;
        bool[string] definedSymbols;
        string[] undefinedSymbols;
        foreach (ref object; working)
            foreach (symbolIndex; object.primarySymbols())
            {
                const name = object.symbolName(symbolIndex);
                const symbol = object.symbols[symbolIndex];
                if (symbol.sectionNumber == 0)
                    undefinedSymbols ~= name;
                else
                    definedSymbols[name] = true;
            }

        foreach (name; required)
        {
            if (name in definedSymbols || name in requiredAttempted)
                continue;
            requiredAttempted[name] = true;
            foreach (archiveIndex, archive; archives)
            {
                const member = archive.findMember(name);
                if (member == size_t.max)
                    continue;
                const memberKey = format("%d/%d", archiveIndex, member);
                if (memberKey in loadedMembers)
                    continue;
                loadedMembers[memberKey] = true;
                try
                {
                    working ~= CoffObject.load(archive.memberData(member));
                }
                catch (CoffError)
                {
                    throw new LinkError("import-library member is not yet supported: "
                        ~ archive.memberName(member));
                }
                progressed = true;
                break;
            }
        }

        foreach (name; undefinedSymbols)
        {
            if (name in definedSymbols || name in attempted)
                continue;
            attempted[name] = true;
            foreach (archiveIndex, archive; archives)
            {
                const member = archive.findMember(name);
                if (member == size_t.max)
                    continue;
                const memberKey = format("%d/%d", archiveIndex, member);
                if (memberKey in loadedMembers)
                    continue;
                loadedMembers[memberKey] = true;
                try
                {
                    ShortImport parsed;
                    if (tryParseImport(archive.memberData(member), parsed))
                    {
                        if (parsed.symbol !in importedSymbols)
                        {
                            importedSymbols[parsed.symbol] = true;
                            imports ~= parsed;
                        }
                        progressed = true;
                        break;
                    }
                    working ~= CoffObject.load(archive.memberData(member));
                }
                catch (CoffError)
                {
                    throw new LinkError("import-library member is not yet supported: "
                        ~ archive.memberName(member));
                }
                progressed = true;
                break;
            }
        }
    }
    return linkObjects(working, imports, entryName, subsystem, pdbPath);
}

/// Link the objects into a PE32+ image that enters at `entryName`.
ubyte[] link(CoffObject[] objects, string entryName, ushort subsystem = 3,
    string pdbPath = null)
{
    return linkObjects(objects, [], entryName, subsystem, pdbPath);
}

private ubyte[] linkObjects(CoffObject[] objects, ShortImport[] imports,
    string entryName, ushort subsystem, string pdbPath)
{
    if (objects.length == 0)
        throw new LinkError("no input objects");

    // COMDAT selection: ANY/NODUPLICATES keep the first identity; an
    // ASSOCIATIVE section survives only when its leader survives.
    bool[][] keep;
    ubyte[][] selections;
    ushort[][] associates;
    string[][] sectionKeys;
    foreach (ref object; objects)
    {
        const sectionCount = object.sections.length;
        bool[] kept;
        ubyte[] selection;
        ushort[] associated;
        string[] keys;
        string[] names;
        kept.length = sectionCount;
        selection.length = sectionCount;
        associated.length = sectionCount;
        keys.length = sectionCount;
        names.length = sectionCount;
        kept[] = true;
        foreach (index; 0 .. sectionCount)
            names[index] = object.sectionName(index);
        foreach (symbolIndex; object.primarySymbols())
        {
            const symbol = object.symbols[symbolIndex];
            size_t section;
            if (!effectiveSection(symbol.sectionNumber, section)
                || section >= sectionCount)
                continue;
            const name = object.symbolName(symbolIndex);
            if (symbol.storageClass == 3 && symbol.numberOfAuxSymbols > 0
                && symbol.value == 0 && name == names[section])
            {
                const auxOffset = cast(size_t) object.header.pointerToSymbolTable
                    + (symbolIndex + 1) * object.symbolStride;
                if (auxOffset + 18 <= object.bytes.length)
                {
                    selection[section] = object.bytes[auxOffset + 14];
                    associated[section] = cast(ushort) (
                        object.bytes[auxOffset + 12]
                        | (object.bytes[auxOffset + 13] << 8));
                }
            }
            if (symbol.value == 0
                && (symbol.storageClass == 2 || symbol.storageClass == 5)
                && keys[section].length == 0 && name.length != 0)
                keys[section] = name;
        }
        keep ~= kept;
        selections ~= selection;
        associates ~= associated;
        sectionKeys ~= keys;
    }
    bool[string] chosen;
    foreach (objectIndex, ref object; objects)
        foreach (index; 0 .. object.sections.length)
        {
            if (selections[objectIndex][index] != 1
                && selections[objectIndex][index] != 2)
                continue;
            const key = sectionKeys[objectIndex][index];
            if (key.length == 0)
                continue;
            if (key in chosen)
                keep[objectIndex][index] = false;
            else
                chosen[key] = true;
        }
    foreach (objectIndex, ref object; objects)
        foreach (index; 0 .. object.sections.length)
        {
            if (selections[objectIndex][index] != 5)
                continue;
            const leader = cast(size_t) associates[objectIndex][index];
            keep[objectIndex][index] = leader != 0 && leader - 1 < object.sections.length
                && keep[objectIndex][leader - 1];
        }

    OutputSection[] outputs;
    size_t[string] outputIndex;
    size_t[][] sectionBase;
    size_t[][] sectionOutput;

    foreach (objectIndex, ref object; objects)
    {
        size_t[] bases;
        size_t[] mapped;
        bases.length = object.sections.length;
        mapped.length = object.sections.length;
        foreach (sectionIndex; 0 .. object.sections.length)
        {
            if (!keep[objectIndex][sectionIndex])
            {
                bases[sectionIndex] = 0;
                mapped[sectionIndex] = size_t.max;
                continue;
            }
            const section = object.sections[sectionIndex];
            const name = outputSectionName(object.sectionName(sectionIndex));
            if (name.length == 0)
            {
                bases[sectionIndex] = 0;
                mapped[sectionIndex] = size_t.max;
                continue;
            }
            size_t index;
            if (name in outputIndex)
                index = outputIndex[name];
            else
            {
                index = outputs.length;
                outputIndex[name] = index;
                outputs ~= OutputSection(name, null, section.characteristics, 0, 0, 0);
            }
            while (outputs[index].data.length % alignmentOf(section.characteristics) != 0)
                outputs[index].data ~= 0;
            bases[sectionIndex] = outputs[index].data.length;
            mapped[sectionIndex] = index;

            const uninitialized = (section.characteristics & 0x00000080) != 0;
            if (section.sizeOfRawData != 0 && !uninitialized)
            {
                const start = cast(size_t) section.pointerToRawData;
                if (start > object.bytes.length
                    || section.sizeOfRawData > object.bytes.length - start)
                    throw new LinkError(format("section '%s': raw data outside the object",
                        name));
                outputs[index].data ~= object.bytes[
                    start .. start + section.sizeOfRawData];
            }
            const reserved = section.virtualSize > section.sizeOfRawData
                ? section.virtualSize : section.sizeOfRawData;
            const end = bases[sectionIndex] + reserved;
            while (outputs[index].data.length < end)
                outputs[index].data ~= 0;
            if (section.virtualSize > outputs[index].virtualSize)
                outputs[index].virtualSize = section.virtualSize;
        }
        sectionBase ~= bases;
        sectionOutput ~= mapped;
    }

    ImportDll[] importDlls;
    size_t idataIndex = size_t.max;
    size_t importTextIndex = size_t.max;
    ulong importDirectoryRva;
    uint importDirectorySize;
    if (imports.length != 0)
    {
        foreach (info; imports)
        {
            size_t dllIndex = size_t.max;
            foreach (index, ref dll; importDlls)
                if (dll.name == info.dll)
                {
                    dllIndex = index;
                    break;
                }
            if (dllIndex == size_t.max)
            {
                ImportDll dll;
                dll.name = info.dll;
                importDlls ~= dll;
                dllIndex = importDlls.length - 1;
            }
            ImportSlot slot;
            slot.info = info;
            importDlls[dllIndex].slots ~= slot;
        }

        if (".text" in outputIndex)
            importTextIndex = outputIndex[".text"];
        else
        {
            importTextIndex = outputs.length;
            outputIndex[".text"] = importTextIndex;
            outputs ~= OutputSection(".text", null, 0x60000020, 0, 0, 0);
        }
        idataIndex = outputs.length;
        outputIndex[".idata"] = idataIndex;
        outputs ~= OutputSection(".idata", null, 0xC0000040, 0, 0, 0);

        void zeros(size_t count)
        {
            foreach (index; 0 .. count)
                outputs[idataIndex].data ~= 0;
        }

        foreach (ref dll; importDlls)
        {
            dll.descriptorOffset = outputs[idataIndex].data.length;
            zeros(20);
        }
        foreach (ref dll; importDlls)
        {
            dll.iltOffset = outputs[idataIndex].data.length;
            zeros((dll.slots.length + 1) * 8);
            dll.iatOffset = outputs[idataIndex].data.length;
            zeros((dll.slots.length + 1) * 8);
        }
        foreach (ref dll; importDlls)
            foreach (ref slot; dll.slots)
            {
                while (outputs[idataIndex].data.length % 2 != 0)
                    outputs[idataIndex].data ~= 0;
                slot.hintOffset = outputs[idataIndex].data.length;
                outputs[idataIndex].data ~= cast(ubyte) (slot.info.hint & 0xFF);
                outputs[idataIndex].data ~= cast(ubyte) (slot.info.hint >> 8);
                foreach (character; slot.info.symbol)
                    outputs[idataIndex].data ~= cast(ubyte) character;
                outputs[idataIndex].data ~= 0;
            }
        foreach (ref dll; importDlls)
        {
            while (outputs[idataIndex].data.length % 2 != 0)
                outputs[idataIndex].data ~= 0;
            dll.nameOffset = outputs[idataIndex].data.length;
            foreach (character; dll.name)
                outputs[idataIndex].data ~= cast(ubyte) character;
            outputs[idataIndex].data ~= 0;
        }
        foreach (ref dll; importDlls)
            foreach (ref slot; dll.slots)
                if (slot.info.type == 0)
                {
                    while (outputs[importTextIndex].data.length % 4 != 0)
                        outputs[importTextIndex].data ~= 0;
                    slot.thunkOffset = outputs[importTextIndex].data.length;
                    outputs[importTextIndex].data ~=
                        [0xFF, 0x25, 0, 0, 0, 0];
                }
    }

    size_t tlsIndex = size_t.max;
    size_t tlsDirIndex = size_t.max;
    ulong tlsDirectoryRva;
    uint tlsDirectorySize;
    if (".tls" in outputIndex)
    {
        tlsIndex = outputIndex[".tls"];
        tlsDirIndex = outputs.length;
        outputs ~= OutputSection(".tlsdir", new ubyte[40], 0x40000040,
            0, 0, 0);
    }

    size_t debugIndex = size_t.max;
    ulong debugDirectoryRva;
    uint debugDirectorySize;
    ubyte[16] pdbGuid;
    if (pdbPath !is null)
    {
        ulong hash = 1469598103934665603UL;
        foreach (character; pdbPath)
        {
            hash ^= cast(ubyte) character;
            hash *= 1099511628211UL;
        }
        foreach (index; 0 .. 16)
            pdbGuid[index] = cast(ubyte) (hash >> ((index % 8) * 8))
                ^ cast(ubyte) (index >= 8 ? 0xA5 : 0x5A);
        debugIndex = outputs.length;
        outputs ~= OutputSection(".debug",
            new ubyte[28 + 24 + pdbPath.length + 1], 0x42000040, 0, 0, 0);
    }

    // Virtual layout; raw offsets are assigned after fixups and .reloc size.
    enum size_t headerSize = 0x400;
    size_t virtual = 0x1000;
    foreach (ref output; outputs)
    {
        output.virtualAddress = virtual;
        const span = output.data.length > output.virtualSize
            ? output.data.length : output.virtualSize;
        virtual += alignUp(span, 0x1000);
    }
    size_t imageSize;

    if (imports.length != 0)
    {
        const idataVa = outputs[idataIndex].virtualAddress;
        const textVa = outputs[importTextIndex].virtualAddress;
        auto idata = outputs[idataIndex].data;
        auto text = outputs[importTextIndex].data;
        foreach (ref dll; importDlls)
        {
            writeU32(idata, dll.descriptorOffset,
                cast(uint) (idataVa + dll.iltOffset));
            writeU32(idata, dll.descriptorOffset + 12,
                cast(uint) (idataVa + dll.nameOffset));
            writeU32(idata, dll.descriptorOffset + 16,
                cast(uint) (idataVa + dll.iatOffset));
            foreach (index, ref slot; dll.slots)
            {
                const hintRva = idataVa + slot.hintOffset;
                writeU64(idata, dll.iltOffset + index * 8, hintRva);
                writeU64(idata, dll.iatOffset + index * 8, hintRva);
                if (slot.info.type == 0)
                {
                    const target = idataVa + dll.iatOffset + index * 8;
                    const place = textVa + slot.thunkOffset;
                    writeU32(text, slot.thunkOffset + 2,
                        cast(uint) (cast(long) target - cast(long) (place + 6)));
                }
            }
        }
        importDirectoryRva = idataVa;
        importDirectorySize = cast(uint) idata.length;
    }

    // Resolve defined symbols to RVAs.
    struct Resolved
    {
        bool defined;
        bool absolute;
        ulong rva;
        size_t outputSection;
        size_t sectionOffset;
    }
    Resolved[string] symbols;
    foreach (objectIndex, ref object; objects)
        foreach (symbolIndex; object.primarySymbols())
        {
            const symbol = object.symbols[symbolIndex];
            const name = object.symbolName(symbolIndex);
            Resolved resolved;
            size_t sectionIndex;
            if (effectiveSection(symbol.sectionNumber, sectionIndex))
            {
                if (sectionIndex >= object.sections.length
                    || !keep[objectIndex][sectionIndex]
                    || sectionOutput[objectIndex][sectionIndex] == size_t.max)
                    continue;
                const outputIndexValue = sectionOutput[objectIndex][sectionIndex];
                resolved.outputSection = outputIndexValue;
                resolved.sectionOffset = sectionBase[objectIndex][sectionIndex]
                    + symbol.value;
                resolved.rva = outputs[outputIndexValue].virtualAddress
                    + resolved.sectionOffset;
                resolved.defined = true;
                symbols[name] = resolved;
            }
            else if (symbol.sectionNumber == -1)
            {
                resolved.defined = true;
                resolved.absolute = true;
                resolved.rva = symbol.value;
                symbols[name] = resolved;
            }
            else if (name !in symbols)
            {
                symbols[name] = resolved;
            }
        }

    if (imports.length != 0)
    {
        const idataVa = outputs[idataIndex].virtualAddress;
        const textVa = outputs[importTextIndex].virtualAddress;
        foreach (ref dll; importDlls)
            foreach (index, ref slot; dll.slots)
            {
                Resolved imported;
                imported.defined = true;
                imported.rva = idataVa + dll.iatOffset + index * 8;
                if (slot.info.type == 0)
                {
                    Resolved thunk;
                    thunk.defined = true;
                    thunk.rva = textVa + slot.thunkOffset;
                    if (slot.info.symbol !in symbols
                        || !symbols[slot.info.symbol].defined)
                        symbols[slot.info.symbol] = thunk;
                }
                else if (slot.info.symbol !in symbols
                    || !symbols[slot.info.symbol].defined)
                    symbols[slot.info.symbol] = imported;
                const importedName = "__imp_" ~ slot.info.symbol;
                if (importedName !in symbols || !symbols[importedName].defined)
                    symbols[importedName] = imported;
            }
    }

    if ("__ImageBase" !in symbols || !symbols["__ImageBase"].defined)
    {
        Resolved imageBase;
        imageBase.defined = true;
        imageBase.absolute = true;
        imageBase.rva = 0x140000000UL;
        symbols["__ImageBase"] = imageBase;
    }

    if (auto rawMapPath = getenv("AURORA_LINK_MAP"))
    {
        const mapPath = cast(string) fromStringz(rawMapPath).idup;
        string text;
        foreach (name, resolved; symbols)
            if (resolved.defined)
                text ~= format("%s 0x%X%s\n", name, resolved.rva,
                    resolved.absolute ? " ABS" : "");
        write(mapPath, text);
    }

    if (tlsDirIndex != size_t.max)
    {
        const tlsStart = 0x140000000UL + outputs[tlsIndex].virtualAddress;
        const tlsRawSize = outputs[tlsIndex].data.length;
        const tlsEnd = tlsStart + tlsRawSize;
        const zeroFill = outputs[tlsIndex].virtualSize > tlsRawSize
            ? outputs[tlsIndex].virtualSize - tlsRawSize : 0;
        ulong indexAddress;
        if ("_tls_index" in symbols && symbols["_tls_index"].defined)
            indexAddress = 0x140000000UL + symbols["_tls_index"].rva;

        auto directory = outputs[tlsDirIndex].data;
        writeU64(directory, 0, tlsStart);
        writeU64(directory, 8, tlsEnd);
        writeU64(directory, 16, indexAddress);
        writeU64(directory, 24, 0);
        writeU32(directory, 32, cast(uint) zeroFill);
        writeU32(directory, 36, 0);
        tlsDirectoryRva = outputs[tlsDirIndex].virtualAddress;
        tlsDirectorySize = 40;

        if ("_tls_used" in symbols && symbols["_tls_used"].defined)
        {
            const used = symbols["_tls_used"];
            if (used.outputSection < outputs.length
                && used.sectionOffset + 24 <= outputs[used.outputSection].data.length)
            {
                auto data = outputs[used.outputSection].data;
                writeU64(data, used.sectionOffset, tlsStart);
                writeU64(data, used.sectionOffset + 8, tlsEnd);
                writeU64(data, used.sectionOffset + 16, indexAddress);
            }
        }
    }

    if (entryName !in symbols || !symbols[entryName].defined)
        throw new LinkError("entry symbol not defined: " ~ entryName);
    const entryRva = symbols[entryName].rva;

    // Apply relocations against defined symbols.
    BaseReloc[] baseRelocations;
    foreach (objectIndex, ref object; objects)
        foreach (sectionIndex; 0 .. object.sections.length)
        {
            const outputIndexValue = sectionOutput[objectIndex][sectionIndex];
            if (outputIndexValue == size_t.max)
                continue;
            foreach (relocation; object.relocations[sectionIndex])
            {
                const symbolIndex = cast(size_t) relocation.symbolTableIndex;
                if (symbolIndex >= object.symbols.length)
                    throw new LinkError("relocation symbol index out of range");
                const symbolName = object.symbolName(symbolIndex);
                if (relocation.type == 0) // IMAGE_REL_AMD64_ABSOLUTE
                    continue;
                const symbol = object.symbols[symbolIndex];
                ulong symbolRva;
                bool symbolAbsolute;
                bool localResolution;
                size_t sectionIndexForSymbol;
                if (effectiveSection(symbol.sectionNumber, sectionIndexForSymbol))
                {
                    if (sectionIndexForSymbol < object.sections.length
                        && keep[objectIndex][sectionIndexForSymbol]
                        && sectionOutput[objectIndex][sectionIndexForSymbol] != size_t.max)
                    {
                        const outputIndexForSymbol =
                            sectionOutput[objectIndex][sectionIndexForSymbol];
                        symbolRva = outputs[outputIndexForSymbol].virtualAddress
                            + sectionBase[objectIndex][sectionIndexForSymbol]
                            + symbol.value;
                        localResolution = true;
                    }
                }
                else if (symbol.sectionNumber == -1)
                {
                    symbolRva = symbol.value;
                    symbolAbsolute = true;
                    localResolution = true;
                }
                if (!localResolution)
                {
                    if (symbolName !in symbols || !symbols[symbolName].defined)
                        throw new LinkError("undefined symbol: " ~ symbolName);
                    symbolRva = symbols[symbolName].rva;
                    symbolAbsolute = symbols[symbolName].absolute;
                }
                const target = sectionBase[objectIndex][sectionIndex]
                    + relocation.virtualAddress;
                const place = outputs[outputIndexValue].virtualAddress + target;
                switch (relocation.type)
                {
                case 4:
                case 5:
                case 6:
                case 7:
                case 8:
                case 9: // IMAGE_REL_AMD64_REL32 .. REL32_5
                {
                    const addend = readU32(outputs[outputIndexValue].data, target);
                    // Relative to the end of the field plus the type suffix.
                    const targetAddress = symbolAbsolute
                        ? symbolRva
                        : 0x140000000UL + symbolRva;
                    const placeAddress = 0x140000000UL + place;
                    const value = cast(long) targetAddress + cast(long) addend
                        - cast(long) (placeAddress + 4
                            + (relocation.type - 4));
                    writeU32(outputs[outputIndexValue].data, target,
                        cast(uint) value);
                    break;
                }
                case 1: // IMAGE_REL_AMD64_ADDR64
                {
                    const addend = readU64(outputs[outputIndexValue].data, target);
                    const value = (symbolAbsolute ? 0 : 0x140000000UL)
                        + symbolRva + addend;
                    writeU64(outputs[outputIndexValue].data, target, value);
                    baseRelocations ~= BaseReloc(cast(uint) place, 10);
                    break;
                }
                case 3: // IMAGE_REL_AMD64_ADDR32NB
                {
                    const addend = readU32(outputs[outputIndexValue].data, target);
                    const value = symbolRva + addend;
                    writeU32(outputs[outputIndexValue].data, target,
                        cast(uint) value);
                    break;
                }
                case 10: // IMAGE_REL_AMD64_SECTION
                {
                    size_t sourceSection;
                    if (!effectiveSection(symbol.sectionNumber, sourceSection))
                        throw new LinkError("SECTION relocation needs a section symbol");
                    if (!keep[objectIndex][sourceSection]
                        || sectionOutput[objectIndex][sourceSection] == size_t.max)
                        throw new LinkError("SECTION relocation targets a discarded section");
                    writeU16(outputs[outputIndexValue].data, target,
                        cast(ushort) (sectionOutput[objectIndex][sourceSection] + 1));
                    break;
                }
                case 11: // IMAGE_REL_AMD64_SECREL
                {
                    ulong offsetInOutput;
                    size_t sourceSection;
                    if (effectiveSection(symbol.sectionNumber, sourceSection))
                    {
                        if (!keep[objectIndex][sourceSection]
                            || sectionOutput[objectIndex][sourceSection] == size_t.max)
                            throw new LinkError("SECREL relocation targets a discarded section");
                        offsetInOutput = sectionBase[objectIndex][sourceSection]
                            + symbol.value;
                    }
                    else if (symbolName in symbols && symbols[symbolName].defined)
                        offsetInOutput = symbols[symbolName].sectionOffset;
                    else
                        throw new LinkError("undefined SECREL symbol: " ~ symbolName);
                    writeU32(outputs[outputIndexValue].data, target,
                        cast(uint) offsetInOutput);
                    break;
                }
                default:
                    throw new LinkError(format(
                        "unsupported relocation type %d for %s",
                        relocation.type, symbolName));
                }
            }
        }

    ulong relocRva;
    uint relocSize;
    if (baseRelocations.length != 0)
    {
        OutputSection reloc;
        reloc.name = ".reloc";
        reloc.data = buildRelocations(baseRelocations);
        reloc.characteristics = 0x42000040;
        reloc.virtualAddress = alignUp(virtual, 0x1000);
        reloc.virtualSize = reloc.data.length;
        outputs ~= reloc;
        virtual = reloc.virtualAddress + alignUp(reloc.data.length, 0x1000);
        relocRva = reloc.virtualAddress;
        relocSize = cast(uint) reloc.data.length;
    }
    imageSize = alignUp(virtual, 0x1000);
    size_t raw = headerSize;
    foreach (ref output; outputs)
    {
        output.rawAddress = raw;
        raw += alignUp(output.data.length, 0x200);
    }

    if (debugIndex != size_t.max)
    {
        auto data = outputs[debugIndex].data;
        const rva = outputs[debugIndex].virtualAddress;
        const rawAddress = outputs[debugIndex].rawAddress;
        writeU32(data, 12, 2); // IMAGE_DEBUG_TYPE_CODEVIEW
        writeU32(data, 16, cast(uint) (24 + pdbPath.length + 1));
        writeU32(data, 20, cast(uint) (rva + 28));
        writeU32(data, 24, cast(uint) (rawAddress + 28));
        data[28] = 'R';
        data[29] = 'S';
        data[30] = 'D';
        data[31] = 'S';
        foreach (index; 0 .. 16)
            data[32 + index] = pdbGuid[index];
        writeU32(data, 48, 1); // age
        foreach (index, character; pdbPath)
            data[52 + index] = cast(ubyte) character;
        data[52 + pdbPath.length] = 0;
        debugDirectoryRva = rva;
        debugDirectorySize = 28;
    }

    // Emit PE32+.
    size_t totalSize = headerSize;
    foreach (output; outputs)
        totalSize += alignUp(output.data.length, 0x200);
    auto image = new ubyte[totalSize];

    DosHeader dos;
    dos.e_magic = dosSignature;
    dos.e_lfanew = 0x40;
    storeStruct(image, 0, dos, "DOS header");
    storeStruct(image, dos.e_lfanew, peSignature, "PE signature");

    CoffHeader coff;
    coff.machine = Machine.amd64;
    coff.numberOfSections = cast(ushort) outputs.length;
    coff.sizeOfOptionalHeader = cast(ushort) OptionalHeader64.sizeof;
    coff.characteristics = 0x0002 | 0x0020;
    storeStruct(image, dos.e_lfanew + 4, coff, "COFF header");

    OptionalHeader64 optional;
    optional.magic = pe32PlusMagic;
    optional.majorLinkerVersion = 1;
    optional.sizeOfCode = cast(uint) headerSize;
    optional.addressOfEntryPoint = cast(uint) entryRva;
    optional.baseOfCode = cast(uint) outputs[0].virtualAddress;
    optional.imageBase = 0x140000000;
    optional.sectionAlignment = 0x1000;
    optional.fileAlignment = 0x200;
    optional.majorOperatingSystemVersion = 6;
    optional.majorSubsystemVersion = 6;
    optional.sizeOfImage = cast(uint) imageSize;
    optional.sizeOfHeaders = cast(uint) headerSize;
    optional.subsystem = subsystem;
    optional.dllCharacteristics = 0x0100;
    optional.sizeOfStackReserve = 0x100000;
    optional.sizeOfStackCommit = 0x1000;
    optional.sizeOfHeapReserve = 0x100000;
    optional.sizeOfHeapCommit = 0x1000;
    optional.numberOfRvaAndSizes = cast(uint) dataDirectoryCount;
    if (debugDirectorySize != 0)
    {
        DataDirectory directory;
        directory.virtualAddress = cast(uint) debugDirectoryRva;
        directory.size = debugDirectorySize;
        optional.directories[DirectoryIndex.debugDirectory] = directory;
    }
    if (tlsDirectorySize != 0)
    {
        DataDirectory directory;
        directory.virtualAddress = cast(uint) tlsDirectoryRva;
        directory.size = tlsDirectorySize;
        optional.directories[DirectoryIndex.tls] = directory;
    }
    if (".pdata" in outputIndex)
    {
        const pdataIndex = outputIndex[".pdata"];
        DataDirectory directory;
        directory.virtualAddress = cast(uint) outputs[pdataIndex].virtualAddress;
        directory.size = cast(uint) outputs[pdataIndex].data.length;
        optional.directories[DirectoryIndex.exception] = directory;
    }
    if (importDirectorySize != 0)
    {
        DataDirectory directory;
        directory.virtualAddress = cast(uint) importDirectoryRva;
        directory.size = importDirectorySize;
        optional.directories[DirectoryIndex.imports] = directory;
    }
    if (relocSize != 0)
    {
        DataDirectory directory;
        directory.virtualAddress = cast(uint) relocRva;
        directory.size = relocSize;
        optional.directories[DirectoryIndex.baseRelocations] = directory;
    }
    storeStruct(image, dos.e_lfanew + 4 + coffHeaderSize, optional,
        "optional header");

    const sectionTable = dos.e_lfanew + 4 + coffHeaderSize
        + OptionalHeader64.sizeof;
    foreach (index, ref output; outputs)
    {
        SectionHeader header;
        header.name[] = 0;
        const name = output.name.length > 8 ? output.name[0 .. 8] : output.name;
        foreach (position, character; name)
            header.name[position] = character;
        header.virtualSize = cast(uint) (output.data.length > output.virtualSize
            ? output.data.length : output.virtualSize);
        header.virtualAddress = cast(uint) output.virtualAddress;
        header.sizeOfRawData = cast(uint) alignUp(output.data.length, 0x200);
        header.pointerToRawData = cast(uint) output.rawAddress;
        header.characteristics = output.characteristics;
        storeStruct(image, sectionTable + index * SectionHeader.sizeof, header,
            "section header");
        if (output.data.length != 0)
            image[output.rawAddress .. output.rawAddress + output.data.length]
                = output.data;
    }

    if (debugIndex != size_t.max)
    {
        PdbSymbol[] pdbSymbols;
        foreach (name, resolved; symbols)
            if (resolved.defined && !resolved.absolute
                && resolved.rva <= uint.max && name.length != 0)
                pdbSymbols ~= PdbSymbol(name, cast(uint) resolved.rva);
        const pdb = buildPdb(image, pdbSymbols, pdbGuid, 1);
        if (pdb.length != 0)
            write(pdbPath, pdb);
    }

    return image;
}

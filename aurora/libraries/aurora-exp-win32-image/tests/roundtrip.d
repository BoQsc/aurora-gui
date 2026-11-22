// SPDX-License-Identifier: 0BSD
/**
 * `pe-roundtrip` - the binary-format laboratory's instrument.
 *
 * Loads a Windows image, prints every modeled directory, re-encodes the image
 * from the parsed model, and compares the result with the input. It exits
 * nonzero on the first differing byte.
 *
 * Mutations (both require an output path):
 *   --stamp <unix-seconds>                 replace the COFF link timestamp
 *   --replace-resource <type>/<name>/<lang> <file>
 *                                          replace a resource leaf in place
 *
 * Inspection:
 *   --dump-resource <type>/<name>/<lang> <file>
 *                                          write a resource leaf's bytes
 *
 * Usage: pe-roundtrip <image.exe> [output.exe] [--self-test] [flags]
 */
module roundtrip;

import auroraexp.win32.image;
import auroraexp.win32.emit;
import auroraexp.win32.pe;
import core.time : MonoTime;
import std.conv : to;
import std.file : read, write;
import std.format : format;
import std.stdio : stderr, writeln;
import std.string : split;

int main(string[] args)
{
    string inputPath;
    string outputPath;
    string[] positional;
    bool selfTest;
    bool quiet;
    string stampText;
    string replaceSelector;
    string replacePath;
    string dumpSelector;
    string dumpPath;
    string emitPath;

    for (size_t index = 1; index < args.length; ++index)
    {
        const argument = args[index];
        if (argument == "--self-test")
            selfTest = true;
        else if (argument == "--quiet")
            quiet = true;
        else if (argument == "--stamp" && index + 1 < args.length)
            stampText = args[++index];
        else if (argument == "--replace-resource" && index + 2 < args.length)
        {
            replaceSelector = args[++index];
            replacePath = args[++index];
        }
        else if (argument == "--dump-resource" && index + 2 < args.length)
        {
            dumpSelector = args[++index];
            dumpPath = args[++index];
        }
        else if (argument == "--emit" && index + 1 < args.length)
            emitPath = args[++index];
        else if (argument.length > 1 && argument[0] == '-')
        {
            stderr.writeln("unknown or incomplete option: ", argument);
            return 2;
        }
        else
            positional ~= argument;
    }
    if (emitPath.length != 0)
    {
        try
        {
            const bytes = emitMinimalExecutable();
            const image = PeImage.load(bytes);
            const rebuilt = image.rebuild();
            if (rebuilt.length != bytes.length)
                throw new PeError("emitted image did not rebuild to its own size");
            foreach (offset; 0 .. bytes.length)
                if (rebuilt[offset] != bytes[offset])
                    throw new PeError(format("emitted image differs at offset 0x%X", offset));
            write(emitPath, rebuilt);
            writeln("emitted=", emitPath, " bytes=", rebuilt.length);
            summarize(image, true);
            return 0;
        }
        catch (PeError error)
        {
            stderr.writeln("emit failed: ", error.msg);
            return 1;
        }
        catch (Exception error)
        {
            stderr.writeln("emit failed: ", error.msg);
            return 1;
        }
    }
    if (positional.length == 0 || positional.length > 2)
    {
        stderr.writeln("usage: pe-roundtrip <image.exe> [output.exe] [--self-test]");
        return 2;
    }
    inputPath = positional[0];
    if (positional.length == 2)
        outputPath = positional[1];
    const mutating = stampText.length != 0 || replaceSelector.length != 0;
    if (mutating && outputPath.length == 0)
    {
        stderr.writeln("a mutation requires an output path");
        return 2;
    }

    try
    {
        const loadStart = MonoTime.currTime;
        const data = cast(const(ubyte)[]) read(inputPath);
        auto image = PeImage.load(data);
        writeln("loadUs=", (MonoTime.currTime - loadStart).total!"usecs");

        summarize(image, quiet);

        if (dumpSelector.length != 0)
            dumpResource(image, dumpSelector, dumpPath);
        if (selfTest)
            selfTestRejections(image);
        if (selfTest)
            selfTestMutations(image);

        if (stampText.length != 0)
        {
            image.setTimeDateStamp(to!uint(stampText));
            writeln("stamp=", to!uint(stampText));
        }
        if (replaceSelector.length != 0)
            replaceResource(image, replaceSelector, replacePath);

        const rebuildStart = MonoTime.currTime;
        const rebuilt = image.rebuild();
        writeln("rebuildUs=", (MonoTime.currTime - rebuildStart).total!"usecs");
        if (rebuilt.length != image.bytes.length)
        {
            stderr.writeln("rebuild changed the file size");
            return 1;
        }
        if (!mutating)
        {
            foreach (offset; 0 .. image.bytes.length)
            {
                if (rebuilt[offset] != image.bytes[offset])
                {
                    stderr.writeln("rebuilt image differs at offset 0x",
                        format("%X", offset));
                    return 1;
                }
            }
            writeln("rebuilt=identical");
        }
        else
            writeln("rebuilt=mutated");

        if (outputPath.length)
        {
            write(outputPath, rebuilt);
            writeln("wrote=", outputPath);
        }
        return 0;
    }
    catch (PeError error)
    {
        stderr.writeln("rejected: ", error.msg);
        return 1;
    }
    catch (Exception error)
    {
        stderr.writeln("failed: ", error.msg);
        return 1;
    }
}

/// Print every header-level and directory-level fact the laboratory models.
void summarize(const ref PeImage image, bool quiet)
{
    writeln("bytes=", image.bytes.length);
    writeln("format=", image.is64 ? "PE32+" : "PE32");
    writeln("machine=", format("0x%04X", image.coff.machine), " ",
        machineName(image.coff.machine));
    writeln("subsystem=", image.subsystem, " ", subsystemName(image.subsystem));
    writeln("imageBase=0x", format("%X", image.imageBase));
    writeln("entry=0x", format("%X", image.addressOfEntryPoint));
    writeln("sizeOfImage=", image.sizeOfImage);
    writeln("sizeOfHeaders=", image.sizeOfHeaders);
    writeln("timeDateStamp=", image.coff.timeDateStamp);

    writeln("sections=", image.sections.length);
    if (!quiet)
        foreach (index; 0 .. image.sections.length)
        {
            const section = image.sections[index];
            writeln("section ", section.nameString,
                " rva=0x", format("%X", section.virtualAddress),
                " raw=0x", format("%X", section.pointerToRawData),
                " size=0x", format("%X", section.sizeOfRawData));
        }

    const directories = image.directories();
    writeln("directories=", directories.length);
    foreach (index; 0 .. directories.length)
    {
        if (directories[index].virtualAddress == 0)
            continue;
        writeln("directory ", index,
            " model=", directoryModel(index),
            " rva=0x", format("%X", directories[index].virtualAddress),
            " size=0x", format("%X", directories[index].size));
    }

    const libraries = image.imports();
    size_t total;
    foreach (index; 0 .. libraries.length)
        total += libraries[index].symbols.length;
    writeln("imports=", total);
    foreach (index; 0 .. libraries.length)
        writeln("dll ", libraries[index].dll, " ", libraries[index].symbols.length);

    const exports = image.exports();
    writeln("exports=", exports.length);
    if (!quiet)
        foreach (index; 0 .. exports.length)
        {
            writeln("export ", exports[index].ordinal,
                " ", exports[index].name.length ? exports[index].name : "-",
                " rva=0x", format("%X", exports[index].rva),
                exports[index].forwarder.length
                    ? " forwarder=" ~ exports[index].forwarder : "");
        }

    const resources = image.resources();
    writeln("resources=", resources.length);
    if (!quiet)
        foreach (index; 0 .. resources.length)
        {
            const resource = resources[index];
            writeln("resource type=", resource.typeName.length
                    ? (resource.typeId != 0
                        ? resource.typeName ~ "(" ~ to!string(resource.typeId) ~ ")"
                        : resource.typeName)
                    : to!string(resource.typeId),
                " name=", resource.name.length
                    ? resource.name : "#" ~ to!string(resource.nameId),
                " lang=", resource.languageId,
                " rva=0x", format("%X", resource.dataRva),
                " size=", resource.size);
        }

    const blocks = image.relocationBlocks();
    uint relocationEntries;
    foreach (index; 0 .. blocks.length)
        relocationEntries += blocks[index].entryCount;
    writeln("relocations=", blocks.length, " entries=", relocationEntries);

    const debugEntries = image.debugEntries();
    writeln("debug=", debugEntries.length);
    if (!quiet)
        foreach (index; 0 .. debugEntries.length)
        {
            writeln("debug type=", debugEntries[index].type,
                " size=", debugEntries[index].sizeOfData,
                " stamp=", debugEntries[index].timeDateStamp,
                debugEntries[index].codeViewPath.length
                    ? " pdb=" ~ debugEntries[index].codeViewPath : "");
        }

    const certificates = image.certificates();
    writeln("certificates=", certificates.length);
    if (!quiet)
        foreach (index; 0 .. certificates.length)
            writeln("certificate length=", certificates[index].length,
                " revision=", certificates[index].revision,
                " type=", certificates[index].certificateType);

    const delayImports = image.delayImports();
    writeln("delayImports=", delayImports.length);
    if (!quiet)
        foreach (index; 0 .. delayImports.length)
            writeln("delay ", delayImports[index].dll, " ",
                delayImports[index].symbols.length);

    const tls = image.tls();
    writeln("tls=", tls.present ? "present" : "absent",
        " callbacks=", tls.callbacks.length);

    writeln("exceptions=", image.exceptionCount());

    const bound = image.boundImports();
    writeln("boundImports=", bound.length);
    if (!quiet)
        foreach (index; 0 .. bound.length)
            writeln("bound ", bound[index].dll, " stamp=", bound[index].timeDateStamp);
}

/// The model name for one data directory.
string directoryModel(size_t index)
{
    switch (index)
    {
    case DirectoryIndex.exports:
        return "exports";
    case DirectoryIndex.imports:
        return "imports";
    case DirectoryIndex.resources:
        return "resources";
    case DirectoryIndex.exception:
        return "exceptions";
    case DirectoryIndex.security:
        return "certificates";
    case DirectoryIndex.baseRelocations:
        return "relocations";
    case DirectoryIndex.debugDirectory:
        return "debug";
    case DirectoryIndex.architecture:
        return "architecture(raw)";
    case DirectoryIndex.globalPointer:
        return "global-pointer(raw)";
    case DirectoryIndex.tls:
        return "tls";
    case DirectoryIndex.loadConfig:
        return "load-config(raw)";
    case DirectoryIndex.boundImports:
        return "bound-imports";
    case DirectoryIndex.importAddressTable:
        return "iat";
    case DirectoryIndex.delayImports:
        return "delay-imports";
    case DirectoryIndex.clrRuntime:
        return "clr(raw)";
    case DirectoryIndex.reserved:
        return "reserved(raw)";
    default:
        return "unknown";
    }
}

/// Parse `type/name/language` into three numeric identifiers.
uint[3] parseSelector(string selector)
{
    const parts = selector.split("/");
    if (parts.length != 3)
        throw new Exception("selector must be TYPE/NAME/LANGUAGE");
    uint[3] result;
    foreach (index; 0 .. 3)
        result[index] = to!uint(parts[index]);
    return result;
}

/// Find one resource by numeric selector.
bool findResource(const ref PeImage image, uint[3] selector,
    out ResourceEntry found)
{
    foreach (entry; image.resources())
    {
        if (entry.typeId == selector[0] && entry.nameId == selector[1]
            && entry.languageId == selector[2])
        {
            found = entry;
            return true;
        }
    }
    return false;
}

/// Write one resource leaf to a file.
void dumpResource(const ref PeImage image, string selectorText, string path)
{
    const selector = parseSelector(selectorText);
    ResourceEntry entry;
    if (!findResource(image, selector, entry))
        throw new PeError("resource not found: " ~ selectorText);
    const data = image.resourceData(entry);
    write(path, data);
    writeln("dumped=", path, " size=", data.length);
}

/// Replace one resource leaf from a file.
void replaceResource(ref PeImage image, string selectorText, string path)
{
    const selector = parseSelector(selectorText);
    const data = cast(const(ubyte)[]) read(path);
    if (!image.replaceResourceData(selector[0], selector[1], selector[2], data))
        throw new PeError("resource not found: " ~ selectorText);
    writeln("replaced=", selectorText, " size=", data.length);
}

void selfTestRejections(const ref PeImage image)
{
    expectRejected("truncated file", () { PeImage.load(image.bytes[0 .. 32]); });

    auto brokenSignature = image.bytes.dup;
    brokenSignature[cast(size_t) image.dos.e_lfanew] ^= 0xFF;
    expectRejected("broken PE signature", () { PeImage.load(brokenSignature); });

    auto brokenSections = image.bytes.dup;
    const coffOffset = cast(size_t) image.dos.e_lfanew + 4;
    brokenSections[coffOffset + 2] = 0xFF;
    brokenSections[coffOffset + 3] = 0xFF;
    expectRejected("impossible section count", () { PeImage.load(brokenSections); });

    writeln("self-test=ok");
}

void selfTestMutations(const ref PeImage image)
{
    auto stamped = PeImage.load(image.bytes);
    stamped.setTimeDateStamp(0x5F5E100);
    const rebuilt = stamped.rebuild();
    const reparsed = PeImage.load(rebuilt);
    if (reparsed.coff.timeDateStamp != 0x5F5E100)
        throw new Exception("timestamp did not survive the rebuild");

    size_t differences;
    foreach (offset; 0 .. rebuilt.length)
        if (rebuilt[offset] != image.bytes[offset])
            ++differences;
    if (differences != 4)
        throw new Exception(format("timestamp stamp changed %d bytes, expected 4",
            differences));
    writeln("self-test timestamp-stamp=4-bytes");

    ResourceEntry first;
    if (!findResource(image, [ResourceType.icon, 1, 1033], first))
        foreach (entry; image.resources())
        {
            first = entry;
            break;
        }
    if (first.size <= 1)
        return;

    auto resourceCopy = PeImage.load(image.bytes);
    const shortened = image.resourceData(first)[0 .. first.size - 1];
    if (!resourceCopy.replaceResourceData(first.typeId, first.nameId,
        first.languageId, shortened))
        throw new Exception("resource replacement did not find its target");
    const reparsedResource = PeImage.load(resourceCopy.rebuild());
    bool matched;
    foreach (entry; reparsedResource.resources())
        if (entry.typeId == first.typeId && entry.nameId == first.nameId
            && entry.languageId == first.languageId
            && entry.size == first.size - 1)
            matched = true;
    if (!matched)
        throw new Exception("resource size did not update");
    writeln("self-test resource-replace=ok");
}

void expectRejected(string label, void delegate() action)
{
    try
    {
        action();
    }
    catch (PeError)
    {
        writeln("self-test ", label, "=rejected");
        return;
    }
    throw new Exception("expected PeError: " ~ label);
}

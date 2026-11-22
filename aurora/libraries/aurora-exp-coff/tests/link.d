// SPDX-License-Identifier: 0BSD
/// `coff-link` - link COFF objects into a PE32+ executable.
///
/// Simple mode:  coff-link <output.exe> <entry-symbol> <object.obj|library.lib>...
/// lld mode:     coff-link /OUT:... /ENTRY:... /SUBSYSTEM:... /LIBPATH:...
///                           /DEFAULTLIB:... /NODEFAULTLIB:... <inputs>
///
/// lld mode exists so DMD can use this linker through `LINKCMD64`.
module link_cli;

import auroraexpcoff.archive : ArchiveError, CoffArchive;
import auroraexpcoff.coff : CoffError, CoffObject;
import auroraexpcoff.link : LinkError, link;
import std.algorithm.searching : endsWith, startsWith;
import std.file : exists, read, write;
import std.path : buildPath, setExtension;
import std.stdio : stderr, writeln;

private enum archivePrefix = "!<arch>\n";

private CoffObject[] objects;
private CoffArchive[] archives;
private bool[string] loadedFiles;

private void addFile(string path)
{
    if (path in loadedFiles)
        return;
    loadedFiles[path] = true;
    const data = cast(const(ubyte)[]) read(path);
    if (data.length >= 8 && data[0 .. 8] == cast(const(ubyte)[]) archivePrefix)
        archives ~= CoffArchive.load(data);
    else
    {
        try
            objects ~= CoffObject.load(data);
        catch (CoffError error)
            throw new Exception(path ~ ": " ~ error.msg);
    }
}

private string resolveLibrary(string name, string[] libpaths)
{
    if (exists(name))
        return name;
    const file = name.endsWith(".lib") ? name : name ~ ".lib";
    foreach (path; libpaths)
    {
        auto candidate = buildPath(path, file);
        if (exists(candidate))
            return candidate;
        candidate = buildPath(path, "..", file);
        if (exists(candidate))
            return candidate;
    }
    return null;
}

private int lldMain(string[] options)
{
    string output;
    string entry = "mainCRTStartup";
    ushort subsystem = 3;
    string[] inputs;
    string[] libpaths;
    string[] defaultlibs;
    string[] requiredSymbols;
    string pdbPath;
    bool debugInfo;
    bool[string] suppressed;

    foreach (option; options)
    {
        if (option.startsWith("/OUT:"))
            output = option[5 .. $];
        else if (option.startsWith("/ENTRY:"))
            entry = option[7 .. $];
        else if (option.startsWith("/SUBSYSTEM:WINDOWS"))
            subsystem = 2;
        else if (option.startsWith("/SUBSYSTEM:CONSOLE"))
            subsystem = 3;
        else if (option.startsWith("/LIBPATH:"))
            libpaths ~= option[9 .. $];
        else if (option.startsWith("/DEFAULTLIB:"))
            defaultlibs ~= option[12 .. $];
        else if (option.startsWith("/NODEFAULTLIB:"))
        {
            auto name = option[14 .. $];
            if (name.endsWith(".lib"))
                name = name[0 .. $ - 4];
            suppressed[name] = true;
        }
        else if (option.startsWith("/EXPORT:"))
            requiredSymbols ~= option[8 .. $];
        else if (option == "/DEBUG")
            debugInfo = true;
        else if (option.startsWith("/PDB:"))
            pdbPath = option[5 .. $];
        else if (option.length != 0 && option[0] == '/')
        {
            // NOLOGO, DEBUG, OPT, MACHINE, EXPORT, MANIFEST, and similar.
        }
        else
            inputs ~= option;
    }

    if (output.length == 0)
    {
        stderr.writeln("coff-link: no /OUT: option");
        return 2;
    }
    if (debugInfo && pdbPath.length == 0)
        pdbPath = setExtension(output, ".pdb");

    try
    {
        foreach (input; inputs)
        {
            if (exists(input))
                addFile(input);
            else if (input.endsWith(".lib"))
            {
                const resolved = resolveLibrary(input, libpaths);
                if (resolved is null)
                    throw new Exception("library not found: " ~ input);
                addFile(resolved);
            }
            else
                addFile(input);
        }
        foreach (name; defaultlibs)
        {
            auto plain = name;
            if (plain.endsWith(".lib"))
                plain = plain[0 .. $ - 4];
            if (plain in suppressed)
                continue;
            const resolved = resolveLibrary(name, libpaths);
            if (resolved is null)
                continue;
            addFile(resolved);
        }
        bool[string] loadedLibraries;
        foreach (name; defaultlibs)
        {
            auto plain = name;
            if (plain.endsWith(".lib"))
                plain = plain[0 .. $ - 4];
            loadedLibraries[plain] = true;
        }
        foreach (pass; 0 .. 8)
        {
            string[] discovered;
            foreach (ref object; objects)
                discovered ~= object.defaultLibraries();
            foreach (ref archive; archives)
                discovered ~= archive.defaultLibraries();
            bool progressed;
            foreach (name; discovered)
            {
                auto plain = name;
                if (plain.endsWith(".lib"))
                    plain = plain[0 .. $ - 4];
                if (plain in suppressed || plain in loadedLibraries)
                    continue;
                const resolved = resolveLibrary(name, libpaths);
                if (resolved is null)
                    continue;
                addFile(resolved);
                loadedLibraries[plain] = true;
                progressed = true;
            }
            if (!progressed)
                break;
        }
        const image = link(objects, archives, entry, subsystem, requiredSymbols,
            debugInfo ? pdbPath : null);
        write(output, image);
        return 0;
    }
    catch (LinkError error)
    {
        stderr.writeln("coff-link: ", error.msg);
        return 1;
    }
    catch (CoffError error)
    {
        stderr.writeln("coff-link: object rejected: ", error.msg);
        return 1;
    }
    catch (ArchiveError error)
    {
        stderr.writeln("coff-link: library rejected: ", error.msg);
        return 1;
    }
    catch (Exception error)
    {
        stderr.writeln("coff-link: ", error.msg);
        return 1;
    }
}

int main(string[] args)
{
    if (args.length >= 2 && args[1].startsWith("/"))
        return lldMain(args[1 .. $]);

    if (args.length < 4)
    {
        stderr.writeln("usage: coff-link <output.exe> <entry-symbol> <object.obj>...");
        return 2;
    }
    try
    {
        foreach (path; args[3 .. $])
            addFile(path);
        const image = link(objects, archives, args[2]);
        write(args[1], image);
        writeln("linked=", args[1], " bytes=", image.length);
        return 0;
    }
    catch (LinkError error)
    {
        stderr.writeln("link failed: ", error.msg);
        return 1;
    }
    catch (CoffError error)
    {
        stderr.writeln("object rejected: ", error.msg);
        return 1;
    }
}

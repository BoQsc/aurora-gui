// SPDX-License-Identifier: 0BSD
/**
 * `pe-load` - map a PE image with the laboratory loader and run its entry.
 *
 * This does not call CreateProcess or LoadLibrary for the image itself. The
 * loader reserves the image, copies headers and sections, applies relocations,
 * resolves imports, protects sections, and starts the entry point in a thread
 * inside this process.
 *
 * Usage: pe-load <image.exe> [--map-only]
 */
module load;

import auroraexp.win32.loader;
import std.file : read;
import std.format : format;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    string path;
    bool mapOnly;

    foreach (argument; args[1 .. $])
    {
        if (argument == "--map-only")
            mapOnly = true;
        else if (argument.length != 0 && argument[0] == '-')
        {
            stderr.writeln("unknown option: ", argument);
            return 2;
        }
        else if (path.length == 0)
            path = argument;
        else
        {
            stderr.writeln("unexpected argument: ", argument);
            return 2;
        }
    }
    if (path.length == 0)
    {
        stderr.writeln("usage: pe-load <image.exe> [--map-only]");
        return 2;
    }

    try
    {
        const data = cast(const(ubyte)[]) read(path);
        auto mapped = mapImage(data);

        writeln("preferredBase=0x", format("%X", mapped.preferredBase));
        writeln("mappedBase=0x", format("%X", cast(ulong) mapped.base));
        writeln("sizeOfImage=", mapped.sizeOfImage);
        writeln("relocationDelta=", mapped.relocationDelta);
        writeln("relocations=", mapped.relocationsApplied);
        writeln("imports=", mapped.importsResolved);
        foreach (ref placement; mapped.sections)
            writeln("section ", placement.name,
                " at=0x", format("%X", cast(ulong) placement.address),
                " bytes=", placement.bytes,
                " protect=0x", format("%X", placement.protection));
        writeln("entry=0x", format("%X", mapped.entryPoint));

        if (mapOnly)
        {
            writeln("mapped=yes");
            unmapImage(mapped);
            return 0;
        }

        const exitCode = runEntry(mapped);
        writeln("threadExit=", exitCode);
        unmapImage(mapped);
        return exitCode == 0 ? 0 : 1;
    }
    catch (Exception error)
    {
        stderr.writeln("load failed: ", error.msg);
        return 1;
    }
}

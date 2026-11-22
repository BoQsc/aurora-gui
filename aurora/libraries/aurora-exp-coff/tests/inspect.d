// SPDX-License-Identifier: 0BSD
/// `coff-inspect` - print a COFF object's headers, sections, and symbols.
module inspect;

import auroraexpcoff.coff;
import std.file : read;
import std.format : format;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("usage: coff-inspect <object.obj>");
        return 2;
    }
    try
    {
        const data = cast(const(ubyte)[]) read(args[1]);
        const object = CoffObject.load(data);
        writeln("machine=", format("0x%04X", object.header.machine));
        writeln("sections=", object.sections.length);
        writeln("symbols=", object.symbols.length);
        writeln("relocations=", object.relocationCount());
        foreach (index; 0 .. object.sections.length)
        {
            const section = object.sections[index];
            writeln("section ", object.sectionName(index),
                " raw=", section.sizeOfRawData,
                " relocations=", object.relocations[index].length,
                " characteristics=", format("0x%08X", section.characteristics));
        }
        const primary = object.primarySymbols();
        writeln("primarySymbols=", primary.length);
        size_t printed;
        foreach (index; primary)
        {
            if (printed == 40)
            {
                writeln("… ", primary.length - printed, " more");
                break;
            }
            const symbol = object.symbols[index];
            writeln("symbol ", object.symbolName(index),
                " section=", symbol.sectionNumber,
                " value=0x", format("%X", symbol.value),
                " storage=", symbol.storageClass);
            ++printed;
        }
        return 0;
    }
    catch (CoffError error)
    {
        stderr.writeln("rejected: ", error.msg);
        return 1;
    }
}

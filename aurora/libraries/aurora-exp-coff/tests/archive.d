// SPDX-License-Identifier: 0BSD
/// `coff-archive` - inspect a COFF `.lib` archive and resolve a symbol.
///
/// Usage: coff-archive <library.lib> <symbol>
module archive_cli;

import auroraexpcoff.archive;
import std.file : read;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: coff-archive <library.lib> <symbol>");
        return 2;
    }
    try
    {
        const archive = CoffArchive.load(cast(const(ubyte)[]) read(args[1]));
        writeln("members=", archive.members.length);
        const index = archive.findMember(args[2]);
        if (index == size_t.max)
        {
            writeln("symbol=", args[2], " found=no");
            return 1;
        }
        writeln("symbol=", args[2], " found=yes");
        writeln("member=", archive.memberName(index));
        writeln("memberBytes=", archive.members[index].size);
        return 0;
    }
    catch (ArchiveError error)
    {
        stderr.writeln("rejected: ", error.msg);
        return 1;
    }
}

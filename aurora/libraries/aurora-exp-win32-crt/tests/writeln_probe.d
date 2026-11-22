// SPDX-License-Identifier: 0BSD
/// Phase 1 probe: Phobos text output through the Aurora CRT.
module writeln_probe;

import std.stdio : writeln;

void main()
{
    writeln("writeln from the Aurora CRT");
}

// SPDX-License-Identifier: 0BSD
/**
 * End-to-end test: emit a minimal PE image, parse and rebuild it, map it with
 * the laboratory loader, run its entry point, and release the mapping.
 *
 * This is the strongest form the laboratory can produce in one process: the
 * bytes are built from fields, not read from a file; the same bytes are then
 * mapped by our own loader; the entry point executes and returns exit code 0.
 *
 * Run: dub run --config=emit-load-test --compiler=dmd
 */
module emit_load;

import auroraexp.win32.emit;
import auroraexp.win32.image;
import auroraexp.win32.loader;
import core.sys.windows.windows : PAGE_EXECUTE_READ, PAGE_READONLY;
import std.format : format;
import std.stdio : stderr, writeln;

private void fail(string message)
{
    stderr.writeln("emit-load test failed: ", message);
    throw new Exception(message);
}

int main()
{
    const bytes = emitMinimalExecutable();
    if (bytes.length != 0x600)
        fail("emitted image is not 1536 bytes");

    const image = PeImage.load(bytes);
    if (image.sections.length != 2)
        fail("emitted image does not have two sections");
    if (image.sections[0].nameString != ".text")
        fail("first section is not .text");
    if (image.sections[1].nameString != ".reloc")
        fail("second section is not .reloc");
    if (image.addressOfEntryPoint != 0x1000)
        fail("entry point is not 0x1000");
    if (image.imports().length != 0)
        fail("emitted image unexpectedly imports a library");

    const rebuilt = image.rebuild();
    if (rebuilt.length != bytes.length)
        fail("rebuild changed the image size");
    foreach (offset; 0 .. bytes.length)
        if (rebuilt[offset] != bytes[offset])
            fail("rebuild differs from the emitted bytes");

    const text = image.rvaToOffset(0x1000);
    if (bytes[text] != 0x31 || bytes[text + 1] != 0xC0 || bytes[text + 2] != 0xC3)
        fail("entry code is not xor eax,eax; ret");

    auto mapped = mapImage(bytes);
    scope (exit) unmapImage(mapped);

    const base = cast(ulong) mapped.base;
    if (mapped.entryPoint != base + image.addressOfEntryPoint)
        fail("mapped entry point is not base + AddressOfEntryPoint");
    if (mapped.importsResolved != 0)
        fail("loader resolved imports for an image without any");

    if (mapped.sections.length != 2)
        fail("loader did not place two sections");
    if (mapped.sections[0].name != ".text"
        || mapped.sections[0].protection != PAGE_EXECUTE_READ)
        fail(".text is not mapped as executable read");
    if (mapped.sections[1].name != ".reloc"
        || mapped.sections[1].protection != PAGE_READONLY)
        fail(".reloc is not mapped read-only");

    const header = cast(const(ubyte)*) mapped.base;
    if (header[0] != 'M' || header[1] != 'Z')
        fail("mapped headers do not start with MZ");
    if (header[cast(size_t) image.dos.e_lfanew] != 'P'
        || header[cast(size_t) image.dos.e_lfanew + 1] != 'E')
        fail("mapped headers do not carry the PE signature");

    if (mapped.relocationDelta != 0 && mapped.relocationsApplied != 0)
        fail("loader applied fixups although the padding block has none");

    const exitCode = runEntry(mapped);
    if (exitCode != 0)
        fail("entry thread did not exit with code 0");

    writeln("emit-load: ok preferred=0x", format("%X", mapped.preferredBase),
        " mapped=0x", format("%X", base),
        " delta=", mapped.relocationDelta,
        " entry=0x", format("%X", mapped.entryPoint));
    return 0;
}

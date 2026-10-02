/**
 * Standalone integration test for the independent ISO 9660 implementation.
 *
 * Build and run without the Aurora GUI or dub:
 *   dmd -unittest -Isource -i -run tests/iso_unit.d
 *
 * The module-level `unittest` blocks in source/auroraiso/iso/*.d run first,
 * then `main` performs an end-to-end write/read/extract round trip.
 */
module iso_unit;

import auroraiso.iso;
import std.algorithm : canFind, map, sort;
import std.array : array, join;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, write;
import std.path : buildPath;
import std.stdio : stderr;

int failures;

void note(string text)
{
    stderr.writeln(text);
}

void check(bool condition, string label)
{
    if (!condition)
    {
        ++failures;
        note("FAIL: " ~ label);
    }
    else
    {
        note("ok  : " ~ label);
    }
}

ubyte[] makePattern(size_t length, uint seed)
{
    auto data = new ubyte[length];
    uint value = seed * 2654435761u + 12345u;
    foreach (i; 0 .. length)
    {
        value = value * 1664525u + 1013904223u;
        data[i] = cast(ubyte)(value >> 24);
    }
    return data;
}

void main()
{
    const root = "build/isotest";
    if (exists(root))
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "src"));
    mkdirRecurse(buildPath(root, "src/dir/sub"));
    mkdirRecurse(buildPath(root, "out"));

    const hello = "Hello, ISO 9660 world!\n";
    auto nested = makePattern(5000, 7);
    auto deep = makePattern(200000, 42);

    write(buildPath(root, "src/hello.txt"), hello);
    write(buildPath(root, "src/empty.txt"), cast(ubyte[]) []);
    write(buildPath(root, "src/My File.txt"), "mixed case name\n");
    write(buildPath(root, "src/dir/nested.bin"), nested);
    write(buildPath(root, "src/dir/sub/deep.bin"), deep);

    const isoPath = buildPath(root, "test.iso");
    IsoWriterOptions options;
    options.volumeId = "AURORA_TEST";
    auto writeResult = createIsoFromDirectory(buildPath(root, "src"), isoPath, options);
    check(writeResult.ok, "create ISO from directory: " ~ writeResult.error);
    check(exists(isoPath), "ISO file exists on disk");
    check(writeResult.fileCount == 5, "writer counted 5 files");
    check(writeResult.directoryCount == 2, "writer counted 2 directories");

    // --- Read back with Joliet preferences ---
    auto image = new IsoImage(isoPath);
    check(image.volumeId() == "AURORA_TEST", "volume id round-trips");
    check(image.hasJoliet(), "Joliet descriptor detected");
    check(image.volumeSpaceSectors() > 16, "volume space size sane");

    auto rootNodes = image.rootNodes();
    rootNodes.sort!((a, b) => a.name < b.name)();
    auto rootNames = rootNodes.map!(n => n.name).array;
    check(rootNames.canFind("hello.txt"), "root lists hello.txt with Joliet name");
    check(rootNames.canFind("My File.txt"), "root lists mixed-case name via Joliet");
    check(rootNames.canFind("empty.txt"), "root lists empty.txt");
    check(rootNames.canFind("dir"), "root lists directory 'dir'");

    auto helloRead = cast(string) image.readFile("/hello.txt");
    check(helloRead == hello, "file content round-trips");

    auto emptyRead = image.readFile("/empty.txt");
    check(emptyRead.length == 0, "empty file stays empty");

    IsoNode nestedNode;
    check(image.find("/dir/nested.bin", nestedNode), "find nested file");
    check(nestedNode.size == nested.length, "nested size matches");

    auto nestedRead = image.readFile("/dir/nested.bin");
    check(nestedRead == nested, "nested binary content round-trips");

    auto deepRead = image.readFile("/dir/sub/deep.bin");
    check(deepRead == deep, "deep binary content round-trips");

    // Case-insensitive lookup.
    check(image.readFile("/DIR/SUB/DEEP.BIN") == deep, "case-insensitive path lookup");

    // --- Primary tree with Rock Ridge names ---
    IsoReadOptions primaryOptions;
    primaryOptions.preferJoliet = false;
    primaryOptions.useRockRidge = true;
    auto primaryImage = new IsoImage(isoPath, primaryOptions);
    auto primaryNames = primaryImage.rootNodes().map!(n => n.name).array;
    check(primaryNames.canFind("My File.txt"),
        "Rock Ridge NM preserves mixed-case name in primary tree");

    // --- Primary tree with Rock Ridge disabled: plain 8.3 ISO names ---
    IsoReadOptions plainOptions;
    plainOptions.preferJoliet = false;
    plainOptions.useRockRidge = false;
    auto plainImage = new IsoImage(isoPath, plainOptions);
    auto plainNames = plainImage.rootNodes().map!(n => n.name).array;
    check(plainNames.canFind("HELLO.TXT"),
        "plain ISO names are upper-case in primary tree");
    check(plainNames.canFind("MY_FILE.TXT"),
        "plain ISO names sanitize spaces in primary tree");
    plainImage.close();

    // --- Extraction ---
    const outputDir = buildPath(root, "out");
    auto stats = extractAll(image, outputDir);
    check(stats.files == 5, "extracted 5 files");
    check(readText(buildPath(outputDir, "hello.txt")) == hello, "extracted hello.txt");
    check(read(buildPath(outputDir, "dir/nested.bin")) == nested, "extracted nested.bin");
    check(exists(buildPath(outputDir, "dir/sub/deep.bin")), "extracted deep tree");

    image.close();
    primaryImage.close();

    if (failures == 0)
        note("\nALL TESTS PASSED");
    else
        note("\n" ~ cast(string)(failures.to!string) ~ " TEST(S) FAILED");
}

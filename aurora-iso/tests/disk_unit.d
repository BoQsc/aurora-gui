/**
 * Standalone tests for the from-scratch disk layer (GPT + FAT32 + exFAT).
 *
 * Build and run without the GUI or dub:
 *   dmd -unittest -Isource -i -run tests/disk_unit.d
 *
 * The whole multi-partition layout is built into an in-memory disk image and
 * then validated by independent readers that parse the on-disk bytes back.
 * The image is also dumped to build/layout_test.img so it can be mounted or
 * inspected by hand.
 */
module disk_unit;

import auroraiso.disk;
import auroraiso.iso;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, remove, rmdirRecurse, write;
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
        data[i] = cast(ubyte) (value >> 24);
    }
    return data;
}

void main()
{
    // --- Primitive checks -------------------------------------------------
    check(crc32(cast(ubyte[]) "123456789") == 0xCBF43926, "CRC-32 known vector");
    check(exfatChecksum(minimalUpcaseTable()) == 0x4E394AE1, "exFAT up-case checksum");

    auto efiGuid = guidFromString("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
    check(efiGuid.bytes[0] == 0x28 && efiGuid.bytes[1] == 0x73 &&
        efiGuid.bytes[2] == 0x2A && efiGuid.bytes[3] == 0xC1,
        "GUID parses into mixed-endian bytes");

    // --- Build a small source tree and an ISO -----------------------------
    const root = "build/disktest";
    if (exists(root))
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "src/EFI/BOOT"));
    mkdirRecurse(buildPath(root, "src/dir/sub"));

    const hello = "Hello, from-scratch FAT32!\n";
    auto bootx64 = makePattern(120000, 11);
    auto deep = makePattern(9000, 22);

    write(buildPath(root, "src/hello.txt"), hello);
    write(buildPath(root, "src/EFI/BOOT/BOOTX64.EFI"), bootx64);
    write(buildPath(root, "src/dir/sub/deep.bin"), deep);
    write(buildPath(root, "src/My Long File.txt"), "long name payload\n");

    const isoPath = buildPath(root, "test.iso");
    IsoWriterOptions isoOptions;
    isoOptions.volumeId = "DISK_TEST";
    auto writeResult = createIsoFromDirectory(buildPath(root, "src"), isoPath, isoOptions);
    check(writeResult.ok, "create ISO: " ~ writeResult.error);

    auto image = new IsoImage(isoPath);

    // --- Build the whole layout in memory ---------------------------------
    const deviceBytes = 96UL * 1024 * 1024;
    auto dev = new MemoryBlockDevice(deviceBytes);
    LayoutOptions options;
    options.fatLabel = "AURORA-ISO";
    options.dataLabel = "AURORA-DATA";
    auto result = writeIsoLayout(dev, image, options);
    check(result.gpt.partitions.length == 2, "GPT has two partitions");
    check(result.filesCopied == 4, "four files copied into FAT32");

    // --- Validate the GPT -------------------------------------------------
    auto gpt = readGpt(dev);
    check(gpt.partitions.length == 2, "GPT re-reads two partitions");
    if (gpt.partitions.length == 2)
    {
        check(gpt.partitions[0].type.opEquals(typeEfiSystem), "partition 1 is EFI System");
        check(gpt.partitions[1].type.opEquals(typeMicrosoftBasicData),
            "partition 2 is Microsoft Basic Data");
        check(gpt.partitions[0].name == "AURORA-ISO", "partition 1 name round-trips");
        check(gpt.partitions[0].firstLba == 2048, "partition 1 starts at 1 MiB");
        check(gpt.partitions[1].firstLba > gpt.partitions[0].lastLba,
            "partition 2 follows partition 1");
    }

    // Primary GPT header CRC must verify.
    {
        auto header = new ubyte[512];
        dev.read(512, header);
        const stored = getU32(header, 16);
        putU32(header, 16, 0);
        check(crc32(header[0 .. 92]) == stored, "primary GPT header CRC verifies");
    }

    // --- Validate FAT32 partition 1 --------------------------------------
    auto fatDevice = new SubDevice(dev, gpt.partitions[0].firstLba * 512,
        gpt.partitions[0].sectors() * 512, 512);
    auto fatReader = new Fat32Reader(fatDevice);
    auto rootNames = fatReader.listRootNames();
    check(rootNames.canFind("hello.txt"), "FAT32 root lists hello.txt");
    check(rootNames.canFind("EFI"), "FAT32 root lists EFI directory");
    check(rootNames.canFind("My Long File.txt"), "FAT32 long name round-trips");

    check(cast(string) fatReader.readFile("/hello.txt") == hello,
        "FAT32 file content round-trips");
    check(fatReader.readFile("/EFI/BOOT/BOOTX64.EFI") == bootx64,
        "FAT32 nested EFI boot file round-trips");
    check(fatReader.readFile("/dir/sub/deep.bin") == deep,
        "FAT32 deep nested binary round-trips");

    // --- Validate exFAT data partition 2 ---------------------------------
    auto dataDevice = new SubDevice(dev, gpt.partitions[1].firstLba * 512,
        gpt.partitions[1].sectors() * 512, 512);
    auto exfat = readExfat(dataDevice);
    check(exfat.label == "AURORA-DATA", "exFAT volume label round-trips");
    check(exfat.hasAllocationBitmap, "exFAT has an allocation bitmap entry");
    check(exfat.hasUpcaseTable, "exFAT has an up-case table entry");
    check(exfat.bootChecksumOk, "exFAT boot-region checksum verifies");
    check(exfat.entryChecksumsOk, "exFAT root entry checksums verify");

    image.close();

    // --- Dump the image for manual inspection ----------------------------
    const imagePath = buildPath(root, "layout_test.img");
    write(imagePath, dev.raw());
    check(exists(imagePath), "layout image written to disk for inspection");
    note("     image: " ~ imagePath ~
        " (" ~ (dev.raw().length / (1024 * 1024)).to!string ~ " MiB)");

    // --- File-backed device round trip -----------------------------------
    {
        const filePath = buildPath(root, "file_device.bin");
        auto fileDevice = new FileBlockDevice(filePath, 1 << 20, 512);
        auto payload = makePattern(4096, 99);
        fileDevice.write(12345, payload);
        fileDevice.flush();
        auto readBack = new ubyte[4096];
        fileDevice.read(12345, readBack);
        check(readBack == payload, "FileBlockDevice write/read round-trips");
        check(fileDevice.size() == (1 << 20), "FileBlockDevice reports its size");
        fileDevice.close();
        remove(filePath);
    }

    if (failures == 0)
        note("\nALL DISK TESTS PASSED");
    else
        note("\n" ~ failures.to!string ~ " DISK TEST(S) FAILED");
}

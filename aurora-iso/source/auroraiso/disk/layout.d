/**
 * High-level multi-partition layout: build a GPT, format a FAT32 partition and
 * copy the ISO contents into it, then format the remaining space as a data
 * partition. This is the experimental, fully from-scratch alternative to
 * byte-for-byte raw ("dd") writing; the plain raw path stays the default.
 */
module auroraiso.disk.layout;

import auroraiso.disk.device;
import auroraiso.disk.exfat;
import auroraiso.disk.fat32;
import auroraiso.disk.gpt;
import auroraiso.iso;

import std.array : appender;

/// Knobs for the layout writer.
struct LayoutOptions
{
    string fatLabel = "AURORA-ISO";
    string dataLabel = "AURORA-DATA";
    bool useExfatData = true;
    /// EFI System Partition type boots on UEFI; Basic Data is auto-mounted by Windows.
    bool fatPartitionIsEsp = true;
    ulong alignBytes = 1 << 20;
    ulong minFatBytes = 64UL * 1024 * 1024;
    ulong fatSlackBytes = 32UL * 1024 * 1024;
}

/// What the layout writer produced.
struct LayoutResult
{
    GptInfo gpt;
    ulong fatBytes;
    ulong dataBytes;
    uint filesCopied;
    ulong bytesCopied;
    bool dataIsExfat;
}

private ulong roundUp(ulong value, ulong multiple)
{
    if (multiple == 0)
        return value;
    return ((value + multiple - 1) / multiple) * multiple;
}

private bool guidIsZero(const Guid g)
{
    foreach (b; g.bytes)
        if (b != 0)
            return false;
    return true;
}

private Guid randomGuid()
{
    import std.random : uniform;
    Guid g;
    foreach (i; 0 .. 16)
        g.bytes[i] = cast(ubyte) uniform(0, 256);
    g.bytes[7] = cast(ubyte) ((g.bytes[7] & 0x0F) | 0x40);
    g.bytes[8] = cast(ubyte) ((g.bytes[8] & 0x3F) | 0x80);
    return g;
}

private string relativePath(string imagePath)
{
    auto value = imagePath;
    while (value.length > 0 && (value[0] == '/' || value[0] == '\\'))
        value = value[1 .. $];
    return value;
}

/// Size the two partitions for a device of `deviceBytes` holding `payloadBytes`.
private void planPartitions(ulong deviceBytes, ulong payloadBytes,
    LayoutOptions opts, out ulong p1Start, out ulong p1End,
    out ulong p2Start, out ulong p2End)
{
    const uint sector = 512;
    const ulong totalSectors = deviceBytes / sector;
    const ulong alignSectors = opts.alignBytes / sector;
    const ulong firstUsable = 34;
    const ulong lastUsable = totalSectors - 34;

    auto fatBytes = roundUp(payloadBytes + opts.fatSlackBytes, opts.alignBytes);
    if (fatBytes < opts.minFatBytes)
        fatBytes = opts.minFatBytes;
    const ulong fatSectors = fatBytes / sector;

    p1Start = roundUp(firstUsable, alignSectors);
    p1End = p1Start + fatSectors - 1;
    p2Start = roundUp(p1End + 1, alignSectors);
    p2End = lastUsable;
    if (p2Start >= lastUsable)
        throw new Exception("device too small for the two-partition layout");
}

/// Write the full layout to `dev`.
LayoutResult writeIsoLayout(BlockDevice dev, IsoImage image, LayoutOptions opts,
    scope void delegate(string message, double fraction) onProgress = null,
    scope bool delegate() cancel = null)
{
    const uint sector = dev.sectorSize() != 0 ? dev.sectorSize() : 512;

    ulong payload = 0;
    foreach (node; image.walk("/", true, cancel))
    {
        if (node.isDirectory || node.isSymlink)
            continue;
        payload += node.size;
    }

    ulong p1Start, p1End, p2Start, p2End;
    planPartitions(dev.size(), payload, opts, p1Start, p1End, p2Start, p2End);

    auto diskGuid = randomGuid();
    GptPartition[] partitions;
    GptPartition part1;
    part1.type = opts.fatPartitionIsEsp ? typeEfiSystem : typeMicrosoftBasicData;
    part1.unique = randomGuid();
    part1.firstLba = p1Start;
    part1.lastLba = p1End;
    part1.name = opts.fatLabel;
    partitions ~= part1;

    GptPartition part2;
    part2.type = typeMicrosoftBasicData;
    part2.unique = randomGuid();
    part2.firstLba = p2Start;
    part2.lastLba = p2End;
    part2.name = opts.dataLabel;
    partitions ~= part2;

    if (onProgress !is null)
        onProgress("Writing GPT", 0.02);
    writeGpt(dev, partitions, diskGuid, sector);

    // Partition 1: FAT32 holding the ISO contents.
    auto fatDevice = new SubDevice(dev, p1Start * sector,
        (p1End - p1Start + 1) * sector, sector);
    if (onProgress !is null)
        onProgress("Formatting FAT32 partition", 0.05);
    auto fatGeometry = formatFat32(fatDevice, opts.fatLabel);
    auto fatWriter = new Fat32Writer(fatDevice, fatGeometry);

    LayoutResult result;
    uint copied;
    ulong bytesCopied;
    foreach (node; image.walk("/", true, cancel))
    {
        if (cancel !is null && cancel())
            throw new Exception("cancelled");
        const relative = relativePath(node.path);
        if (relative.length == 0)
            continue;
        if (node.isDirectory)
        {
            fatWriter.mkdir(relative);
        }
        else if (node.isSymlink)
        {
            continue;
        }
        else
        {
            auto data = image.readFile(node.path, cancel);
            fatWriter.writeFile(relative, data);
            ++copied;
            bytesCopied += data.length;
            if (onProgress !is null)
            {
                const fraction = payload == 0 ? 0.9 : 0.1 + 0.8 *
                    (cast(double) bytesCopied / cast(double) payload);
                onProgress("Copying " ~ node.path, fraction);
            }
        }
    }
    fatDevice.flush();

    // Partition 2: data partition for the remaining space.
    auto dataDevice = new SubDevice(dev, p2Start * sector,
        (p2End - p2Start + 1) * sector, sector);
    if (onProgress !is null)
        onProgress("Formatting data partition", 0.92);
    if (opts.useExfatData)
        formatExfat(dataDevice, opts.dataLabel);
    else
        formatFat32(dataDevice, opts.dataLabel);
    dataDevice.flush();

    if (onProgress !is null)
        onProgress("Done", 1.0);

    result.gpt = readGpt(dev, sector);
    result.fatBytes = (p1End - p1Start + 1) * sector;
    result.dataBytes = (p2End - p2Start + 1) * sector;
    result.filesCopied = copied;
    result.bytesCopied = bytesCopied;
    result.dataIsExfat = opts.useExfatData;
    return result;
}

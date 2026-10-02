/**
 * Extraction helpers: copy files and directory trees out of an `IsoImage`
 * onto the local filesystem. Kept separate from the reader so the reader stays
 * purely about parsing.
 */
module auroraiso.iso.extract;

import auroraiso.iso.reader;
import std.file : exists, mkdirRecurse, write;
import std.path : buildPath, dirName;

/// Counters reported after an extraction run.
struct ExtractStats
{
    uint files;
    uint directories;
    uint symlinksSkipped;
    ulong bytes;
}

/// Extract the whole image under `destination`, mirroring the directory layout.
ExtractStats extractAll(IsoImage image, string destination,
    scope void delegate(string currentPath) onProgress = null,
    scope bool delegate() cancel = null)
{
    ExtractStats stats;
    mkdirRecurse(destination);
    foreach (node; image.walk("/", true, cancel))
    {
        if (cancel !is null && cancel())
            break;
        const relative = relativePath(node.path);
        if (relative.length == 0)
            continue;
        const target = buildPath(destination, relative);
        if (node.isDirectory)
        {
            mkdirRecurse(target);
            ++stats.directories;
        }
        else if (node.isSymlink)
        {
            ++stats.symlinksSkipped;
        }
        else
        {
            mkdirRecurse(dirName(target));
            auto data = image.readFile(node.path, cancel);
            write(target, data);
            ++stats.files;
            stats.bytes += data.length;
        }
        if (onProgress !is null)
            onProgress(node.path);
    }
    return stats;
}

/// Extract a single file to `destinationPath`.
void extractFile(IsoImage image, string imagePath, string destinationPath,
    scope bool delegate() cancel = null)
{
    auto data = image.readFile(imagePath, cancel);
    mkdirRecurse(dirName(destinationPath));
    write(destinationPath, data);
}

/// Convert "/a/b/c" into "a/b/c" for joining with a local directory.
private string relativePath(string imagePath)
{
    auto value = imagePath;
    while (value.length > 0 && (value[0] == '/' || value[0] == '\\'))
        value = value[1 .. $];
    return value;
}

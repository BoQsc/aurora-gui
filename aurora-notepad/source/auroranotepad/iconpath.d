module auroranotepad.iconpath;

import aurora.image : RgbaImage, loadPngImage;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;

/** Resolve `aurora-notepad.ico` beside the executable or in the cwd. */
string notepadIconPath()
{
    return resolveAsset("aurora-notepad.ico");
}

/** Resolve `aurora-notepad.png` beside the executable or in the cwd. */
string notepadImagePath()
{
    return resolveAsset("aurora-notepad.png");
}

/** Resolve the prefiltered titlebar derivative generated from the source PNG. */
string notepadTitleImagePath()
{
    return resolveAsset("aurora-notepad-title.png");
}

/**
 * Load the title icon with transparent RGB edge colors repaired.
 *
 * The source PNG uses black RGB in fully transparent pixels. Linear sampling
 * of straight-alpha RGBA otherwise lets that black bleed into the tiny title
 * icon. Propagating the nearest nontransparent RGB into transparent pixels
 * keeps the alpha unchanged while making both Aurora renderers scale the icon
 * cleanly.
 */
RgbaImage loadNotepadTitleImage(string path)
{
    auto source = loadPngImage(path);
    auto pixels = source.pixels().dup;
    const width = source.width();
    const height = source.height();
    const count = cast(size_t) width * cast(size_t) height;
    int[] distance;
    distance.length = count;
    distance[] = -1;
    int[] queue;
    queue.length = count;
    size_t head;
    size_t tail;

    foreach (index; 0 .. count)
    {
        if (pixels[index * 4 + 3] != 0)
        {
            distance[index] = 0;
            queue[tail++] = cast(int) index;
        }
    }
    if (tail == 0) return source;

    while (head < tail)
    {
        const current = queue[head++];
        const x = current % width;
        const y = current / width;
        const sourceOffset = cast(size_t) current * 4;

        if (x > 0)
        {
            const next = current - 1;
            if (distance[next] < 0)
            {
                distance[next] = distance[current] + 1;
                const target = cast(size_t) next * 4;
                pixels[target .. target + 3] = pixels[sourceOffset .. sourceOffset + 3];
                queue[tail++] = next;
            }
        }
        if (x + 1 < width)
        {
            const next = current + 1;
            if (distance[next] < 0)
            {
                distance[next] = distance[current] + 1;
                const target = cast(size_t) next * 4;
                pixels[target .. target + 3] = pixels[sourceOffset .. sourceOffset + 3];
                queue[tail++] = next;
            }
        }
        if (y > 0)
        {
            const next = current - width;
            if (distance[next] < 0)
            {
                distance[next] = distance[current] + 1;
                const target = cast(size_t) next * 4;
                pixels[target .. target + 3] = pixels[sourceOffset .. sourceOffset + 3];
                queue[tail++] = next;
            }
        }
        if (y + 1 < height)
        {
            const next = current + width;
            if (distance[next] < 0)
            {
                distance[next] = distance[current] + 1;
                const target = cast(size_t) next * 4;
                pixels[target .. target + 3] = pixels[sourceOffset .. sourceOffset + 3];
                queue[tail++] = next;
            }
        }
    }
    return new RgbaImage(width, height, pixels);
}

private string resolveAsset(string name)
{
    try
    {
        const beside = buildPath(dirName(thisExePath()), name);
        if (exists(beside)) return beside;
    }
    catch (Exception)
    {
    }
    if (exists(name)) return name;
    return "";
}

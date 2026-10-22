module notepad_glyph_test;

import experiment.aurorahost.notepad_close_glyph : renderCloseGlyph;
import std.format : format;
import std.stdio : writeln;

version (Windows)
    import experiment.aurorahost.crt.msvcrt_shim;

private ubyte alphaAt(const(ubyte)[] pixels, int size, int x, int y)
{
    return pixels[(y * size + x) * 4 + 3];
}

void main()
{
    // The 10 px logical glyph maps to 10, 13, and 15 physical pixels at
    // 100%, 125%, and 150% DPI respectively.
    foreach (size; [10, 13, 15])
    {
        const image = renderCloseGlyph(size);
        assert(image.width() == size && image.height() == size);
        const pixels = image.pixels();
        const center = (size - 1) / 2;
        assert(alphaAt(pixels, size, center, center) == 255,
            format("close glyph center is not opaque at %dx%d", size, size));

        int coreCount, partialCount;
        int coreLeft = size, coreTop = size, coreRight = -1, coreBottom = -1;
        foreach (y; 0 .. size)
        {
            foreach (x; 0 .. size)
            {
                const alpha = alphaAt(pixels, size, x, y);
                if (alpha > 0 && alpha < 255)
                    ++partialCount;
                if (alpha < 200)
                    continue;
                ++coreCount;
                if (x < coreLeft) coreLeft = x;
                if (y < coreTop) coreTop = y;
                if (x > coreRight) coreRight = x;
                if (y > coreBottom) coreBottom = y;
            }
        }
        assert(coreRight - coreLeft + 1 >= size - 1 &&
            coreBottom - coreTop + 1 >= size - 1,
            format("close glyph is too small at %dx%d", size, size));
        assert(coreCount < size * size / 2,
            format("close glyph is a filled block at %dx%d", size, size));
        assert(partialCount > 0,
            format("close glyph has no antialiased fringe at %dx%d", size, size));

        // Even physical sizes put their endpoints on pixel boundaries, so the
        // falling stroke's core is one column to the left of the odd-size case.
        const even = (size & 1) == 0;
        const last = even ? size - 2 : size - 1;
        foreach (i; 0 .. last + 1)
        {
            const otherX = even ? size - 2 - i : size - 1 - i;
            assert(alphaAt(pixels, size, i, i) >= 245,
                format("close glyph rising stroke is broken at %dx%d", size, size));
            assert(alphaAt(pixels, size, otherX, i) >= 245,
                format("close glyph falling stroke is broken at %dx%d", size, size));
        }

        if (size == 10)
        {
            int fullNeighbors;
            foreach (dy; -1 .. 2)
                foreach (dx; -1 .. 2)
                    if (alphaAt(pixels, size, center + dx, center + dy) == 255)
                        ++fullNeighbors;
            assert(fullNeighbors == 1,
                "100% close glyph must have a single full-opacity center pixel");
            assert(alphaAt(pixels, size, 1, 0) == 0,
                "100% close glyph retains a low-coverage halo pixel");
        }
    }
    writeln("notepad close glyph test passed: sizes 10, 13, 15");
}
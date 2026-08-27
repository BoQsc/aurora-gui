module dtextrender;

import aurora.font : FontFace;
import std.stdio : writeln, writefln, writef, File;
import std.conv : to;

// Render a full string with the pure-D engine onto a white background and write
// a grayscale PGM (0=black glyph, 255=white) with a common baseline row, for
// pixel-comparison against the OS (authoritative) reference.
private void writePgm(string path, int w, int h, const(ubyte)[] alpha)
{
    auto f = File(path, "w");
    f.writeln("P2");
    f.writeln(w, " ", h);
    f.writeln("255");
    int idx;
    foreach (y; 0 .. h)
    {
        foreach (x; 0 .. w)
        {
            f.write(alpha[idx++].to!string);
            if (x != w - 1) f.write(" ");
        }
        f.write("\n");
    }
    f.close();
}

int main(string[] args)
{
    if (args.length < 5) { writeln("usage: dtextrender <font> <px> <out.pgm> <text>"); return 1; }
    const fontPath = args[1];
    const pixel = to!int(args[2]);
    const outPath = args[3];
    const text = args[4];

    auto face = FontFace.load(fontPath);

    // Layout: place each glyph from a common baseline at row `baselineRow`.
    const ascentPx = face.ascent(pixel);
    const baselineRow = ascentPx + 4; // top padding
    const pad = 4;
    const imageH = baselineRow + face.descent(pixel) + pad;
    const imageW = 1000;
    ubyte[] alpha = new ubyte[imageW * imageH];
    alpha[] = 255;

    void fill(int sx, int sy, int w, int h, ubyte value)
    {
        foreach (yy; 0 .. h)
        {
            const dstRow = sy + yy;
            if (dstRow < 0 || dstRow >= imageH) continue;
            foreach (xx; 0 .. w)
            {
                const dst = cast(size_t) dstRow * imageW + (sx + xx);
                if (sx + xx < 0 || sx + xx >= imageW) continue;
                if (value < alpha[dst]) alpha[dst] = value;
            }
        }
    }

    int pen = 4;
    foreach (ch; text)
    {
        const g = face.glyphIndex(ch);
        auto bm = face.rasterizeGlyph(g, pixel, 4);
        if (bm.width > 0 && bm.height > 0)
        {
            // bearingX is the left offset from the pen; bearingY is from the
            // baseline up to the top of the bitmap. Place baseline at baselineRow.
            const left = pen + bm.bearingX;
            const top = baselineRow - bm.bearingY;
            foreach (yy; 0 .. bm.height)
            {
                foreach (xx; 0 .. bm.width)
                {
                    const a = bm.alpha[cast(size_t) yy * bm.width + xx];
                    if (a == 0) continue;
                    fill(left + xx, top + yy, 1, 1,
                        cast(ubyte) (255 - a));
                }
            }
        }
        pen += bm.advance;
    }

    writePgm(outPath, imageW, imageH, alpha);
    writefln("wrote %s (%dx%d) baselineRow=%d", outPath, imageW, imageH, baselineRow);
    return 0;
}

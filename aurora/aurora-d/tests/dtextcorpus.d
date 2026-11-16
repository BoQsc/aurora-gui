module dtextcorpus;

import aurora.font : FontFace;
import std.stdio : writeln, writefln;

int main(string[] args)
{
    string[] fonts = [
        "C:\\Windows\\Fonts\\consola.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
        "C:\\Windows\\Fonts\\calibri.ttf",
        "C:\\Windows\\Fonts\\verdanai.ttf"
    ];
    int[] sizes = [9, 11, 12, 13, 16, 24, 32, 48];
    const corpus = "Idle0123456789:Il1OoXxHWwABKZ@#%&()[]{}<>`~^|/\\";

    int totalBlank;
    foreach (fontPath; fonts)
    {
        auto face = FontFace.tryLoad(fontPath);
        if (face is null) { writeln("skip ", fontPath); continue; }
        int fontBlank;
        foreach (px; sizes)
        {
            foreach (ch; corpus)
            {
                auto g = face.glyphIndex(ch);
                if (g == 0) continue;
                auto bm = face.rasterizeGlyph(g, px, 4);
                if (bm.width <= 0 || bm.height <= 0) ++fontBlank;
            }
        }
        writeln(fontPath, " blanks=", fontBlank);
        totalBlank += fontBlank;
    }
    writefln("TOTAL blanks=%d", totalBlank);
    return totalBlank == 0 ? 0 : 1;
}

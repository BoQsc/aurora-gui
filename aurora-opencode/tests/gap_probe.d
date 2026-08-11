module auroraopencode_gap_probe;

import aurora;
import std.conv : to;
import std.stdio : writefln, writeln;

void measure(FontSystem fonts, FontFace face, string label, double tracking)
{
    const int pixelSize = 17;
    const dstring word = "sk sp st av To AV wait"d;
    TextLayoutOptions options;
    options.pixelSize = pixelSize;
    options.wrap = false;
    options.role = FontRole.ui;
    options.overrideFace = face;
    options.letterSpacing = tracking;
    auto layout = fonts.textEngine.layout(word, options);

    writefln("== %s at %spx tracking=%s width=%s ==",
        label, pixelSize, tracking, layout.width);
    foreach (index; 0 .. layout.glyphs.length)
    {
        const g = layout.glyphs[index];
        dstring ch = word[g.clusterStart .. g.clusterEnd];
        auto a = fonts.atlas.glyphByIndex(g.font, g.glyphIndex,
            pixelSize, fonts.renderMode);
        string gap = "-";
        if (index + 1 < layout.glyphs.length)
        {
            const nextG = layout.glyphs[index + 1];
            auto nextA = fonts.atlas.glyphByIndex(nextG.font,
                nextG.glyphIndex, pixelSize, fonts.renderMode);
            const gapPx = (nextG.x + nextA.bearingX) -
                (g.x + a.bearingX + a.region.width);
            gap = to!string(gapPx);
        }
        writefln("  '%s' x=%s adv=%s bX=%s inkW=%s gap=%s",
            ch, to!string(g.x), a.advance, a.bearingX, a.region.width, gap);
    }
}

int main()
{
    auto fonts = FontSystem.sharedInstance();
    auto regular = cast(FontFace) fonts.uiFace;
    auto bold = SystemFonts.sansBold();
    measure(fonts, regular, "regular", 0.0);
    measure(fonts, bold, "bold", 0.0);
    measure(fonts, bold, "bold+tracking", 1.0);
    return 0;
}

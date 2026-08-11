module auroraopencode_bold_probe;

import aurora;
import std.stdio : writefln, writeln;

void dumpWord(FontSystem fonts, FontFace face, string label)
{
    TextLayoutOptions options;
    options.pixelSize = 17;
    options.wrap = false;
    options.role = FontRole.ui;
    options.overrideFace = face;
    const dstring word = "bold word"d;
    auto layout = fonts.textEngine.layout(word, options);
    writefln("== %s (face id %s) width=%s ==", label,
        face is null ? 0 : face.identity(), layout.width);
    foreach (glyph; layout.glyphs)
    {
        dstring ch = word[glyph.clusterStart .. glyph.clusterEnd];
        const fontId = glyph.font is null ? 0 : glyph.font.identity();
        writefln("  '%s' fontId=%s x=%s advance=%s",
            ch, fontId, glyph.x, glyph.advanceX);
    }
    foreach (run; layout.runs)
    {
        const fontId = run.font is null ? 0 : run.font.identity();
        writefln("  run fontId=%s script=%s dir=%s", fontId, run.script, run.direction);
    }
}

int main()
{
    auto fonts = FontSystem.sharedInstance();
    auto regular = cast(FontFace) fonts.uiFace;
    auto bold = SystemFonts.sansBold();
    writeln("regular id=", regular.identity(), " bold id=", bold.identity());
    dumpWord(fonts, regular, "regular");
    dumpWord(fonts, bold, "bold");
    dumpKerning(fonts, regular, "regular");
    dumpKerning(fonts, bold, "bold");
    return 0;
}

void dumpKerning(FontSystem fonts, FontFace face, string label)
{
    TextLayoutOptions options;
    options.pixelSize = 17;
    options.wrap = false;
    options.role = FontRole.ui;
    options.overrideFace = face;
    const dstring word = "AVATAR To Wait AVE"d;
    auto layout = fonts.textEngine.layout(word, options);
    writefln("== %s kerning word width=%s ==", label, layout.width);
    foreach (glyph; layout.glyphs)
    {
        dstring ch = word[glyph.clusterStart .. glyph.clusterEnd];
        writefln("  '%s' x=%s advance=%s", ch, glyph.x, glyph.advanceX);
    }
}

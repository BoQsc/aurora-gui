module text_default_chat_probe;

import aurora;
import auroraopencode.markdown : composeMarkdown, parseMarkdown, paintMarkdown;
import std.stdio : writeln;

int main(string[] args)
{
    auto fonts = FontSystem.sharedInstance();
    writeln("UI face: ", fonts.uiFace.path());
    writeln("Mono face: ", fonts.monospaceFace.path());
    auto atlas = new GlyphAtlas();
    auto glyph = atlas.glyphByIndex(fonts.monospaceFace,
        fonts.monospaceFace.glyphIndex('X'), 17, FontRenderMode.sharp, 0);
    bool[4] quadrants;
    foreach (y; 0 .. glyph.region.height)
    foreach (x; 0 .. glyph.region.width)
        if (atlas.pixels()[(glyph.region.y + y) * atlas.width() + glyph.region.x + x] > 40)
            quadrants[(y >= glyph.region.height / 2 ? 2 : 0) +
                (x >= glyph.region.width / 2 ? 1 : 0)] = true;
    writeln("17px mono X quadrants: ", quadrants);
    auto list = new DrawList(fonts);
    list.reset(Size(1000, 480), Color.rgb(18, 20, 24));
    auto canvas = Canvas(list, 1000, 480);
    immutable sample = "# Chat glyph regression\n\n"d ~
        "Letters: ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz\n\n"d ~
        "Numbers: 0123456789 17px 125% 1,234.567 -89 +42\n\n"d ~
        "Inline code: `SYNTAX Xx 0123456789 =+-*/ <> [] {} ()`\n\n"d ~
        "```d\nint X = 1234567890;\nfloat result = 17.25 / 8.0;\n```\n"d;
    auto composition = composeMarkdown(parseMarkdown(sample), 960, false);
    paintMarkdown(canvas, composition, 20, 12);
    int y = 310;
    foreach (size; [13, 14, 16, 17, 18])
    {
        TextLayoutOptions options;
        options.overrideFace = fonts.monospaceFace;
        options.pixelSize = size;
        options.wrap = false;
        canvas.drawLayout(Point(20, y), fonts.textEngine.layout(
            "Xx 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz"d,
            options), Color.rgb(240, 240, 240));
        y += 30;
    }
    auto surface = new Surface(1000, 480);
    SoftwareRenderer.renderInto(list, surface);
    surface.savePpm(args[1]);
    return 0;
}

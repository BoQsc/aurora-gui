module native_text_audit_sheet;

import aurora;
import std.conv : to;
import std.file : write;
import std.json : JSONValue;
import std.math : floor;
import std.process : environment;

int main(string[] args)
{
    assert(args.length == 4, "glyph_sheet font size prefix");
    const size = args[2].to!int;
    const cellWidth = size * 2 + 16;
    const cellHeight = size * 2 + 24;
    enum columns = 16;
    enum rows = 6;
    const width = columns * cellWidth;
    const height = rows * cellHeight;
    auto fonts = new FontSystem(args[1], args[1]);
    auto list = new DrawList(fonts);
    const dark = environment.get("AURORA_TEST_DARK", "0") == "1";
    const phase = environment.get("AURORA_TEST_PHASE", "0").to!double;
    const background = dark ? Color.rgb(24, 24, 24) : Color.rgb(255, 255, 255);
    const foreground = dark ? Color.rgb(240, 240, 240) : Color.rgb(0, 0, 0);
    list.reset(Size(width, height), background);
    auto canvas = Canvas(list, width, height);
    JSONValue info;
    info["width"] = width;
    info["height"] = height;
    info["pixel_size"] = size;
    info["cell_width"] = cellWidth;
    info["cell_height"] = cellHeight;
    JSONValue[] glyphs;
    foreach (index; 0 .. 94)
    {
        const codepoint = cast(dchar) (33 + index);
        const only = environment.get("AURORA_TEST_CHARACTER", "");
        if (only.length && only != [codepoint].to!string) continue;
        TextLayoutOptions options;
        options.overrideFace = fonts.uiFace;
        options.pixelSize = size;
        options.wrap = false;
        auto layout = fonts.textEngine.layout([codepoint], options);
        foreach (ref glyph; layout.glyphs) glyph.x += phase;
        const x = (index % columns) * cellWidth + 8;
        const y = (index / columns) * cellHeight + 8;
        canvas.drawLayout(Point(x, y), layout, foreground);
        foreach (g; layout.glyphs)
        {
            JSONValue item;
            item["id"] = g.glyphIndex;
            item["x"] = x + g.x;
            item["y"] = floor(y + g.y + 0.5);
            item["codepoint"] = cast(uint) codepoint;
            item["cell"] = index;
            glyphs ~= item;
        }
    }
    info["glyphs"] = glyphs;
    auto surface = new Surface(width, height);
    SoftwareRenderer.renderInto(list, surface);
    surface.savePpm(args[3] ~ ".ppm");
    write(args[3] ~ ".json", info.toPrettyString());
    return 0;
}

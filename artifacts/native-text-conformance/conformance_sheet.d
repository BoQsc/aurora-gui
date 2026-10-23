module aurora.text.conformance_sheet;

import aurora;
import aurora.text.layout : TextLayout, PositionedGlyph;
import std.conv : to;
import std.file : readText, write;
import std.json : JSONValue, parseJSON;
import std.process : environment;

int main(string[] args)
{
    assert(args.length == 4, "conformance-sheet font job.json prefix");
    const job = parseJSON(readText(args[2]));
    const size = cast(int) job["pixel_size"].integer;
    const phase = job["phase_eighths"].integer / 8.0;
    const dark = job["dark"].boolean;
    const ids = job["glyph_ids"].array;
    enum columns = 8;
    const rows = (ids.length + columns - 1) / columns;
    const cellWidth = 4 * size + 32;
    const cellHeight = 4 * size + 32;
    const width = columns * cellWidth;
    const height = cast(int) rows * cellHeight;
    auto fonts = new FontSystem(args[1], args[1]);
    auto list = new DrawList(fonts);
    const background = dark ? Color.rgb(24, 24, 24) : Color.rgb(255, 255, 255);
    const foreground = dark ? Color.rgb(240, 240, 240) : Color.rgb(0, 0, 0);
    list.reset(Size(width, height), background);
    auto canvas = Canvas(list, width, height);
    JSONValue info;
    info["width"] = width; info["height"] = height;
    info["pixel_size"] = size;
    info["cell_width"] = cellWidth; info["cell_height"] = cellHeight;
    info["columns"] = columns;
    JSONValue[] glyphs;
    foreach (index, value; ids)
    {
        const id = cast(uint) value.integer;
        assert(id < fonts.uiFace.glyphCount());
        const x = cast(int) (index % columns) * cellWidth + size + 12;
        const y = cast(int) (index / columns) * cellHeight + size * 2 + 12;
        auto layout = new TextLayout(null);
        layout.pixelSize = size;
        layout.glyphs = [PositionedGlyph(fonts.uiFace, id, 0, 1, phase, 0.0)];
        canvas.drawLayout(Point(x, y), layout, foreground);
        JSONValue glyph;
        glyph["id"] = id; glyph["x"] = x + phase; glyph["y"] = y;
        glyph["cell"] = index;
        glyphs ~= glyph;
    }
    info["glyphs"] = glyphs;
    auto surface = new Surface(width, height);
    SoftwareRenderer.renderInto(list, surface);
    surface.savePpm(args[3] ~ ".ppm");
    write(args[3] ~ ".json", info.toPrettyString());
    return 0;
}

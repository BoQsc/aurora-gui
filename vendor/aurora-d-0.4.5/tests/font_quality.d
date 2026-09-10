module tests.font_quality;

// Capture the real Canvas/atlas/software path and export the shaped glyph
// origins for an independently rasterized native reference.
import aurora;
import std.conv : to;
import std.file : write;
import std.json : JSONValue;
import std.math : ceil, floor;
import std.stdio : writeln;
import std.process : environment;

int main(string[] args)
{
    if (args.length != 5)
    {
        writeln("usage: font_quality <font-file> <pixel-size> <output-prefix> <text>");
        return 1;
    }
    auto fonts = new FontSystem(args[1], args[1],
        environment.get("AURORA_TEST_SMOOTH", "0") == "1" ?
            FontRenderMode.smooth : FontRenderMode.sharp);
    assert(fonts.uiFace.isOpenType(), "An outline font is required");
    TextLayoutOptions options;
    options.overrideFace = fonts.uiFace;
    options.pixelSize = args[2].to!int;
    options.wrap = false;
    auto layout = fonts.textEngine.layout(args[4].to!dstring, options);
    const width = cast(int) ceil(layout.width) + 24;
    const height = cast(int) ceil(layout.height) + 16;
    JSONValue info;
    info["width"] = width;
    info["height"] = height;
    info["pixel_size"] = options.pixelSize;
    info["font"] = args[1];
    info["text"] = args[4];
    JSONValue[] glyphs;
    foreach (g; layout.glyphs)
    {
        JSONValue entry;
        entry["id"] = g.glyphIndex;
        entry["x"] = 8.0 + g.x;
        entry["y"] = floor(8.0 + g.y + 0.5);
        glyphs ~= entry;
    }
    info["glyphs"] = glyphs;
    write(args[3] ~ ".json", info.toPrettyString());
    foreach (dark; [false, true])
    {
        const bg = dark ? Color.rgb(24, 24, 24) : Color.rgb(255, 255, 255);
        const fg = dark ? Color.rgb(240, 240, 240) : Color.rgb(0, 0, 0);
        auto list = new DrawList(fonts);
        list.reset(Size(width, height), bg);
        auto canvas = Canvas(list, width, height);
        canvas.drawLayout(Point(8, 8), layout, fg);
        auto surface = new Surface(width, height);
        SoftwareRenderer.renderInto(list, surface);
        surface.savePpm(args[3] ~ (dark ? "-dark.ppm" : "-light.ppm"));
        // Both Canvas backends must consume the same phase/coverage policy.
        auto immediate = new Surface(width, height);
        immediate.clear(bg);
        auto direct = Canvas(immediate, fonts);
        direct.drawLayout(Point(8, 8), layout, fg);
        assert(surface.pixels() == immediate.pixels(), "Canvas paths disagree");
    }
    return 0;
}

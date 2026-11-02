module markdown_viewport_contracts;

import aurora;
import auroraopencode.markdown;
import core.time : MonoTime;
import std.array : replicate;
import std.algorithm : sort;
import std.stdio : writeln;
import std.utf : toUTF32;
import aurora.render.drawlist : DrawList;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : TextLayoutOptions;

private void verifyClippedText()
{
    auto fonts = FontSystem.sharedInstance();
    TextLayoutOptions options;
    options.pixelSize = 19;
    options.maxWidth = 550;
    options.wrap = true;
    // Combining marks, fallback glyphs and RTL runs must keep their actual ink.
    auto layout = fonts.textEngine.layout(
        "Italic f j Á ∑ Привіт العربية שָׁלוֹם 世界 🌍\n"d.replicate(80), options);
    foreach (offset; [0, 117, 503, 1107])
    {
        auto expected = new Surface(800, 600);
        auto actual = new Surface(800, 600);
        auto reference = Canvas(expected).translated(17, -offset).clipped(Rect(23, offset + 37, 480, 320));
        auto indexed = Canvas(actual).translated(17, -offset).clipped(Rect(23, offset + 37, 480, 320));
        reference.drawLayout(Point(10, 23), layout, Color.rgb(232, 234, 240), false);
        indexed.drawLayout(Point(10, 23), layout, Color.rgb(232, 234, 240));
        assert(actual.pixels() == expected.pixels(), "Visibility index changed clipped software pixels");
    }
    foreach (dpi; [96, 120, 144, 192, 96])
    foreach (offset; [0, 117, 503])
    {
        auto expected = new DrawList();
        auto actual = new DrawList();
        const scale = DisplayScale.fromDpi(dpi);
        const size = Size(800, 600);
        expected.reset(size, Size(800 * dpi / 96, 600 * dpi / 96), scale, Color.rgb(0, 0, 0));
        actual.reset(size, Size(800 * dpi / 96, 600 * dpi / 96), scale, Color.rgb(0, 0, 0));
        auto reference = Canvas(expected, 800, 600).translated(17, -offset).clipped(Rect(23, offset + 37, 480, 320));
        auto indexed = Canvas(actual, 800, 600).translated(17, -offset).clipped(Rect(23, offset + 37, 480, 320));
        reference.drawLayout(Point(10, 23), layout, Color.rgb(232, 234, 240), false);
        indexed.drawLayout(Point(10, 23), layout, Color.rgb(232, 234, 240));
        assert(actual.vertices == expected.vertices && actual.indices == expected.indices,
            "Visibility index changed clipped GPU geometry at fractional DPI");
        assert(actual.rgbaImages.length == expected.rgbaImages.length);
        foreach (i, image; actual.rgbaImages)
            assert(image.destination == expected.rgbaImages[i].destination &&
                image.clip == expected.rgbaImages[i].clip);
    }
    writeln("PASS indexed/reference text equality: translated clips, Unicode, software and GPU at 96/120/144/192 DPI");
}

private long paintSamples(ref MdComposition composition, int offset)
{
    auto surface = new Surface(800, 600);
    long[] samples;
    foreach (_; 0 .. 5)
    {
        auto canvas = Canvas(surface).translated(17, -offset);
        const start = MonoTime.currTime;
        paintMarkdown(canvas, composition, 10, 23);
        samples ~= (MonoTime.currTime - start).total!"usecs";
    }
    samples.sort();
    return samples[2];
}

int main()
{
    verifyClippedText();
    const prose = "A paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).\n\n".replicate(600);
    const code = "```text\n" ~ "0123456789abcdef".replicate(750) ~ "\n```\n\n";
    foreach (name, text; ["paragraphs": prose, "long_code_line": code])
    {
        const started = MonoTime.currTime;
        auto composition = composeMarkdown(parseMarkdown(toUTF32(text)), 740, false);
        writeln(name, " compose_us=", (MonoTime.currTime - started).total!"usecs",
            " items=", composition.items.length, " height=", composition.height);
        foreach (offset; [0, cast(int) composition.height / 2, cast(int) composition.height - 550])
        {
            const elapsed = paintSamples(composition, offset);
            writeln(name, " offset=", offset, " median_paint_us=", elapsed);
            assert(elapsed < 200_000, "A cached long reply blocks a frame for hundreds of milliseconds");
        }
    }
    writeln("PASS long Markdown viewport exercise");
    return 0;
}

module auroraopencode_markdown_unit;

import aurora;
import auroraopencode.markdown : MarkdownBlock, BlockType, composeMarkdown,
    parseMarkdown;
import std.stdio : writefln, writeln;
import std.utf : toUTF32;

void dumpBlocks(MarkdownBlock[] blocks)
{
    writefln("blocks: %s", blocks.length);
    foreach (block; blocks)
        writefln("  type=%s level=%s runs=%s codeLines=%s items=%s",
            block.type, block.level, block.runs.length,
            block.codeLines.length, block.items.length);
}

int main()
{
    const markdown =
        "# Streaming markdown\n\n" ~
        "This is a **bold** phrase, an *italic* one, and `inline code`. " ~
        "A [link](https://opencode.ai) is underlined.\n\n" ~
        "- first bullet with **bold** item\n" ~
        "- second bullet\n\n" ~
        "1. ordered one\n" ~
        "2. ordered two\n\n" ~
        "> A quoted line stays indented with a bar.\n\n" ~
        "```d\nimport std.stdio;\nvoid main() { writeln(\"hi\"); }\n```\n\n" ~
        "---\n\n" ~
        "Trailing paragraph after the rule.";

    auto blocks = parseMarkdown(toUTF32(markdown));
    dumpBlocks(blocks);

    auto fonts = FontSystem.sharedInstance();
    auto regular = cast(FontFace) fonts.uiFace;
    auto bold = SystemFonts.sansBold();
    writefln("regular face id: %s", regular is null ? 0 : regular.identity());
    writefln("bold face id:    %s", bold is null ? 0 : bold.identity());
    writefln("distinct: %s", regular !is bold);

    TextLayoutOptions ro;
    ro.pixelSize = 17;
    ro.wrap = false;
    ro.role = FontRole.ui;
    ro.overrideFace = regular;
    auto rw = fonts.textEngine.layout("bold phrase"d, ro);
    TextLayoutOptions bo;
    bo.pixelSize = 17;
    bo.wrap = false;
    bo.role = FontRole.ui;
    bo.overrideFace = bold;
    auto bw = fonts.textEngine.layout("bold phrase"d, bo);
    writefln("regular width: %s  bold width: %s  (bold should be wider)",
        rw.width, bw.width);

    TextLayoutOptions options;
    options.pixelSize = 22;
    options.wrap = false;
    options.role = FontRole.ui;
    options.overrideFace = cast(FontFace) fonts.uiFace;
    auto probe = fonts.textEngine.layout("Streaming markdown"d, options);
    writefln("probe: lines=%s", probe.lines.length);
    foreach (line; probe.lines)
        writefln("  line width=%s height=%s ascent=%s descent=%s baseline=%s",
            line.width, line.height, line.ascent, line.descent, line.baseline);
    writefln("probe height=%s", probe.height);

    auto comp = composeMarkdown(blocks, 800, false);
    writefln("composition: items=%s height=%s cursorPx=%s",
        comp.items.length, comp.height, comp.cursorPx);
    foreach (item; comp.items)
        writefln("  item kind=%s x=%s y=%s w=%s h=%s layout=%s",
            item.kind, item.x, item.y, item.w, item.h,
            item.layout is null ? "null" : "ok");
    return 0;
}

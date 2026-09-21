module auroraopencode.markdown;

import aurora;
import auroraopencode.core : opencodeFontBase, opencodeFontTitle;
import std.algorithm.comparison : max, min;
import std.array : insertInPlace;
import std.conv : to;
import std.math : ceil;
import std.string : indexOf, lastIndexOf;
import std.typecons : Tuple, tuple;

enum InlineStyle : ubyte
{
    text,
    bold,
    italic,
    boldItalic,
    code,
    link
}

struct InlineRun
{
    InlineStyle style = InlineStyle.text;
    dstring text;
    dstring target;
    bool strike;
}

enum BlockType : ubyte
{
    paragraph,
    heading,
    codeBlock,
    bulletList,
    orderedList,
    blockquote,
    rule
}

struct MarkdownBlock
{
    BlockType type;
    int level;
    InlineRun[] runs;
    InlineRun[][] items;
    // Source indentation depth of each list item (0 = top level), so nested
    // sub-lists render indented under their parent instead of collapsing to
    // the same left edge.
    int[] itemDepths;
    dstring[] codeLines;
    int orderedStart;
    InlineRun[] flowPieces;
    InlineRun[][] itemFlowPieces;
    bool flowPiecesReady;
    // Fenced code is intrinsically line-oriented and does not need to be
    // reshaped when only the surrounding panel width changes.
    TextLayout[] codeLineLayouts;
    int codeLayoutPixelSize;
}

enum MdItemKind : ubyte
{
    text,
    panel,
    rule,
    quoteBar
}

struct MdItem
{
    MdItemKind kind;
    double x = 0;
    double y = 0;
    double w = 0;
    double h = 0;
    TextLayout layout;
    Color color;
    bool underline;
    bool strike;
    bool codePill;
    bool clipText;
    double clipX;
    double clipW;
    dstring target;   // link URL for text items, empty otherwise
    dstring codeText; // source text for code-block panels (copy button)
}

struct MdComposition
{
    MdItem[] items;
    double height = 0;
    double cursorX = 0;
    double cursorY = 0;
    int cursorPx = 0;
    // Space the final block would have added after itself. `composeMarkdownInto`
    // omits it from `height` (a composed list should not reserve space below its
    // last block); the incremental composer adds it back for a committed chunk
    // that is still followed by more content.
    double trailingGap = 0;
}

private immutable Color mdText = Color.fromHex(0xe8e8ec);
private immutable Color mdHeading = Color.fromHex(0xffffff);
private immutable Color mdBold = Color.fromHex(0xf4f4f8);
private immutable Color mdItalic = Color.fromHex(0xb8b8c4);
private immutable Color mdCodeText = Color.fromHex(0x9fe8c8);
private immutable Color mdCodeBg = Color.fromHex(0x1e2a24);
private immutable Color mdPanelBg = Color.fromHex(0x1a1a20);
private immutable Color mdLink = Color.fromHex(0x8b7cf6);
private immutable Color mdQuote = Color.fromHex(0x9a9aa5);
private immutable Color mdRule = Color.fromHex(0x33333d);

private immutable double boldLetterSpacing = 1.0;

private bool isSpace(dchar c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t';
}

// Treat non-ASCII letters as word characters too, so emphasis delimiters do not
// split words written in scripts such as Cyrillic or Greek.
private bool isAlnum(dchar c) @safe pure nothrow @nogc
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') || c > 0x7f;
}

private dstring trimStart(dstring s)
{
    size_t i;
    while (i < s.length && isSpace(s[i])) ++i;
    return s[i .. $];
}

// Count leading indentation in spaces, treating a tab as four columns.
private int lineIndent(dstring line)
{
    int spaces;
    foreach (ch; line)
    {
        if (ch == ' ') ++spaces;
        else if (ch == '\t') spaces += 4;
        else break;
    }
    return spaces;
}

private dstring trimEnd(dstring s)
{
    while (s.length > 0 && isSpace(s[$ - 1]))
        s = s[0 .. $ - 1];
    return s;
}

private dstring trim(dstring s)
{
    return trimEnd(trimStart(s));
}

private dstring[] splitLines(dstring text)
{
    dstring[] lines;
    dstring current;
    foreach (ch; text)
    {
        if (ch == '\n')
        {
            lines ~= current;
            current = "";
        }
        else if (ch != '\r')
        {
            current ~= ch;
        }
    }
    if (current.length > 0 || lines.length == 0)
        lines ~= current;
    return lines;
}

private dstring joinLines(dstring[] lines)
{
    dstring result;
    foreach (line; lines)
    {
        if (line.length == 0) continue;
        if (result.length > 0) result ~= ' ';
        result ~= line;
    }
    return result;
}

private struct FenceInfo
{
    bool valid;
    dchar ch;
    int len;
}

private FenceInfo detectFence(dstring line)
{
    FenceInfo info;
    if (line.length < 3) return info;
    const ch = line[0];
    if (ch != '`' && ch != '~') return info;
    int n;
    while (n < line.length && line[n] == ch) ++n;
    if (n < 3) return info;
    info.valid = true;
    info.ch = ch;
    info.len = n;
    return info;
}

private bool isClosingFence(dstring line, const FenceInfo fence)
{
    auto t = trimStart(line);
    if (t.length < 3) return false;
    int n;
    while (n < t.length && t[n] == fence.ch) ++n;
    if (n < fence.len) return false;
    foreach (k; n .. t.length)
    {
        if (!isSpace(t[k])) return false;
    }
    return true;
}

/// Index just past the last blank line at or after `from` that safely ends a
/// block outside a fenced code block. Returns `from` when there is no such
/// boundary. The scan always starts outside a fence because a commit point is
/// itself always outside one, so successive calls need no carried state. This
/// lets a growing streamed document be composed incrementally: everything
/// before the returned index can be parsed and composed once and reused while
/// only the tail is recomposed per frame.
size_t markdownCommitPoint(dstring text, size_t from)
{
    FenceInfo fence;
    size_t commit = from;
    size_t lineStart = from;
    for (size_t i = from; i < text.length; ++i)
    {
        if (text[i] != '\n') continue;
        auto line = text[lineStart .. i];
        if (fence.valid)
        {
            if (isClosingFence(line, fence)) fence = FenceInfo.init;
        }
        else
        {
            auto t = trim(line);
            auto detected = detectFence(t);
            if (detected.valid) fence = detected;
            else
            {
                bool blank = true;
                foreach (ch; line)
                    if (ch != ' ' && ch != '\t' && ch != '\r')
                    {
                        blank = false;
                        break;
                    }
                if (blank) commit = i + 1;
            }
        }
        lineStart = i + 1;
    }
    return commit;
}

private bool isRule(dstring line)
{
    if (line.length < 3) return false;
    const ch = line[0];
    if (ch != '-' && ch != '_' && ch != '*') return false;
    foreach (c; line)
    {
        if (c != ch && !isSpace(c)) return false;
    }
    return true;
}

private bool parseOrdered(dstring line, out int start, out size_t contentStart)
{
    size_t i;
    int value;
    while (i < line.length && line[i] >= '0' && line[i] <= '9')
    {
        value = value * 10 + (line[i] - '0');
        ++i;
    }
    if (i == 0 || i >= line.length) return false;
    if (line[i] != '.' && line[i] != ')') return false;
    if (i + 1 >= line.length || !isSpace(line[i + 1])) return false;
    start = value;
    contentStart = i + 1;
    return true;
}

private bool isBullet(dstring line)
{
    if (line.length == 0) return false;
    if (line[0] != '-' && line[0] != '*' && line[0] != '+') return false;
    return line.length == 1 || isSpace(line[1]);
}

private InlineStyle mergeStyle(InlineStyle outer, InlineStyle inner)
{
    if (outer == InlineStyle.bold)
    {
        if (inner == InlineStyle.italic) return InlineStyle.boldItalic;
        if (inner == InlineStyle.boldItalic) return InlineStyle.boldItalic;
        return InlineStyle.bold;
    }
    if (outer == InlineStyle.italic)
    {
        if (inner == InlineStyle.bold) return InlineStyle.boldItalic;
        if (inner == InlineStyle.boldItalic) return InlineStyle.boldItalic;
        return InlineStyle.italic;
    }
    return InlineStyle.boldItalic;
}

private size_t findCloser(dstring text, size_t start, size_t end, dchar ch, int n,
    bool wordBoundary = false)
{
    for (size_t i = start; i + n <= end; ++i)
    {
        bool match = true;
        for (int k = 0; k < n; ++k)
        {
            if (text[i + k] != ch)
            {
                match = false;
                break;
            }
        }
        if (!match) continue;
        if (wordBoundary)
        {
            // CommonMark: a `_` run bounded by alphanumerics on both sides is
            // intraword and may neither open nor close emphasis.
            const beforeWord = i > 0 && isAlnum(text[i - 1]);
            const afterWord = i + n < end && isAlnum(text[i + n]);
            if (beforeWord && afterWord) continue;
        }
        return i;
    }
    return end;
}

private InlineRun[] parseRuns(dstring text, size_t start, size_t end)
{
    InlineRun[] result;
    dchar[] buf;

    void flush()
    {
        if (buf.length == 0) return;
        if (result.length > 0 && result[$ - 1].style == InlineStyle.text)
            result[$ - 1].text ~= buf.idup;
        else
            result ~= InlineRun(InlineStyle.text, buf.idup);
        buf.length = 0;
    }

    size_t i = start;
    while (i < end)
    {
        const c = text[i];
        if (c == '\\' && i + 1 < end)
        {
            buf ~= text[i + 1];
            i += 2;
            continue;
        }
        if (c == '`')
        {
            size_t close = i + 1;
            bool closed;
            while (close < end)
            {
                if (text[close] == '`')
                {
                    closed = true;
                    break;
                }
                ++close;
            }
            flush();
            const codeText = closed ? text[i + 1 .. close] : text[i + 1 .. end];
            if (codeText.length > 0)
            {
                if (result.length > 0 && result[$ - 1].style == InlineStyle.code)
                    result[$ - 1].text ~= codeText.idup;
                else
                    result ~= InlineRun(InlineStyle.code, codeText.idup);
            }
            i = closed ? close + 1 : end;
            continue;
        }
        if (c == '[')
        {
            // `std.string.indexOf` returns `ptrdiff_t`, and -1 means "not
            // found". Comparing that signed sentinel against an unsigned index
            // promotes -1 to size_t.max, and using it as a slice bound slices
            // to the end of address space. With bounds checks off in the
            // release build (the shipped build) that oversized slice was then
            // copied into the run list, corrupting the heap; the process later
            // died inside MSVCR120's memcpy with no usable stack. Validate the
            // sentinel and cast before any comparison or slice.
            const closeIndex = indexOf(text, ']', i + 1);
            if (closeIndex > 0)
            {
                const close = cast(size_t) closeIndex;
                if (close > i && close + 1 < end && text[close + 1] == '(')
                {
                    const closeParenIndex = indexOf(text, ')', close + 2);
                    if (closeParenIndex > 0)
                    {
                        const closeParen = cast(size_t) closeParenIndex;
                        if (closeParen > close && closeParen < end)
                        {
                            flush();
                            const label = text[i + 1 .. close];
                            const target = text[close + 2 .. closeParen];
                            if (label.length > 0 && target.length > 0)
                                result ~= InlineRun(InlineStyle.link, label.idup,
                                    target.idup);
                            else
                                buf ~= text[i .. closeParen + 1];
                            i = closeParen + 1;
                            continue;
                        }
                    }
                }
            }
            buf ~= '[';
            ++i;
            continue;
        }
        if (c == '~' && i + 1 < end && text[i + 1] == '~')
        {
            // GitHub-flavoured strikethrough: `~~text~~`.
            const close = findCloser(text, i + 2, end, '~', 2);
            if (close < end)
            {
                flush();
                foreach (run; parseRuns(text, i + 2, close))
                {
                    run.strike = true;
                    result ~= run;
                }
                i = close + 2;
                continue;
            }
            buf ~= c;
            ++i;
            continue;
        }
        if (c == '*' || c == '_')
        {
            int n = 1;
            while (i + n < end && text[i + n] == c) ++n;
            const underscore = c == '_';
            if (underscore)
            {
                // Underscores inside a word (`snake_case`, `file_name`) are
                // literal text, not emphasis, per CommonMark.
                const beforeWord = i > 0 && isAlnum(text[i - 1]);
                const afterWord = i + n < end && isAlnum(text[i + n]);
                if (beforeWord && afterWord)
                {
                    buf ~= c;
                    ++i;
                    continue;
                }
            }
            const close = findCloser(text, i + n, end, c, n, underscore);
            if (close < end)
            {
                flush();
                InlineStyle style;
                if (c == '*')
                {
                    if (n >= 3) style = InlineStyle.boldItalic;
                    else if (n == 2) style = InlineStyle.bold;
                    else style = InlineStyle.italic;
                }
                else
                {
                    style = n >= 2 ? InlineStyle.boldItalic : InlineStyle.italic;
                }
                auto inner = parseRuns(text, i + n, close);
                foreach (run; inner)
                {
                    run.style = mergeStyle(style, run.style);
                    result ~= run;
                }
                i = close + n;
                continue;
            }
            buf ~= c;
            ++i;
            continue;
        }
        buf ~= c;
        ++i;
    }
    flush();
    return result;
}

private InlineRun[] parseInline(dstring text)
{
    return parseRuns(text, 0, text.length);
}

MarkdownBlock[] parseMarkdown(dstring text)
{
    MarkdownBlock[] blocks;
    auto lines = splitLines(text);

    dstring[] paraLines;
    int paraLevel;
    int listKind;
    int listStart;
    InlineRun[][] listItems;
    int[] listDepths;
    dstring[] quoteLines;

    void flushPara()
    {
        if (paraLines.length == 0) return;
        MarkdownBlock block;
        block.level = paraLevel;
        block.type = paraLevel > 0 ? BlockType.heading : BlockType.paragraph;
        block.runs = parseInline(joinLines(paraLines));
        blocks ~= block;
        paraLines.length = 0;
        paraLevel = 0;
    }

    void flushList()
    {
        if (listItems.length == 0) return;
        MarkdownBlock block;
        block.type = listKind == 2 ? BlockType.orderedList : BlockType.bulletList;
        block.orderedStart = listStart;
        block.items = listItems;
        block.itemDepths = listDepths;
        blocks ~= block;
        listItems.length = 0;
        listDepths.length = 0;
        listKind = 0;
    }

    void flushQuote()
    {
        if (quoteLines.length == 0) return;
        MarkdownBlock block;
        block.type = BlockType.blockquote;
        block.runs = parseInline(joinLines(quoteLines));
        blocks ~= block;
        quoteLines.length = 0;
    }

    for (size_t li = 0; li < lines.length; ++li)
    {
        auto t = trim(lines[li]);
        if (t.length == 0)
        {
            flushPara();
            flushList();
            flushQuote();
            continue;
        }

        auto fence = detectFence(t);
        if (fence.valid)
        {
            flushPara();
            flushList();
            flushQuote();
            MarkdownBlock block;
            block.type = BlockType.codeBlock;
            ++li;
            for (; li < lines.length; ++li)
            {
                if (isClosingFence(lines[li], fence)) break;
                block.codeLines ~= lines[li];
            }
            blocks ~= block;
            continue;
        }

        if (t[0] == '#')
        {
            size_t n;
            while (n < t.length && t[n] == '#') ++n;
            if (n <= 6 && (n == t.length || isSpace(t[n])))
            {
                flushPara();
                flushList();
                flushQuote();
                paraLevel = cast(int) n;
                paraLines ~= trim(t[n .. $]);
                continue;
            }
        }

        if (isRule(t))
        {
            flushPara();
            flushList();
            flushQuote();
            MarkdownBlock block;
            block.type = BlockType.rule;
            blocks ~= block;
            continue;
        }

        if (t[0] == '>')
        {
            flushPara();
            flushList();
            quoteLines ~= trim(t[1 .. $]);
            continue;
        }

        int orderedStart;
        size_t contentStart;
        if (parseOrdered(t, orderedStart, contentStart))
        {
            flushPara();
            flushQuote();
            if (listKind != 2)
            {
                flushList();
                listKind = 2;
                listStart = orderedStart;
            }
            listItems ~= parseInline(trim(t[contentStart .. $]));
            listDepths ~= min(6, lineIndent(lines[li]) / 2);
            continue;
        }

        if (isBullet(t))
        {
            flushPara();
            flushQuote();
            if (listKind != 1)
            {
                flushList();
                listKind = 1;
            }
            listItems ~= parseInline(trim(t[1 .. $]));
            listDepths ~= min(6, lineIndent(lines[li]) / 2);
            continue;
        }

        flushList();
        flushQuote();
        paraLines ~= t;
    }
    flushPara();
    flushList();
    flushQuote();
    return blocks;
}

private TextLayout shapeOne(dstring text, int pixelSize, bool mono, bool bold)
{
    TextLayoutOptions options;
    options.pixelSize = pixelSize;
    options.wrap = false;
    auto fonts = FontSystem.sharedInstance();
    if (mono)
    {
        options.role = FontRole.monospace;
    }
    else
    {
        options.role = FontRole.ui;
        options.overrideFace = cast(FontFace) (bold
            ? SystemFonts.sansBold() : fonts.uiFace);
        if (bold) options.letterSpacing = boldLetterSpacing;
    }
    // Inline markdown shaping is independent of the available paragraph
    // width. Cache these word/style layouts so resizing only performs cheap
    // flow placement instead of invoking the Unicode shaper again for every
    // width visited by the window border.
    return fonts.textEngine.layoutCached(text, options);
}

private struct PendingText
{
    TextLayout layout;
    InlineStyle style;
    double x;
    double w;
    dstring target;
    bool strike;
    double ascent;
}

private Color styleColor(InlineStyle style, Color baseColor)
{
    switch (style)
    {
        case InlineStyle.bold:
        case InlineStyle.boldItalic:
            return mdBold;
        case InlineStyle.italic:
            return mdItalic;
        case InlineStyle.code:
            return mdCodeText;
        case InlineStyle.link:
            return mdLink;
        case InlineStyle.text:
        default:
            return baseColor;
    }
}

private Tuple!(dstring, dstring) splitRun(dstring text, TextLayout layout,
    double targetWidth)
{
    size_t best;
    foreach (cluster; layout.visualClusters)
    {
        if (cluster.xMax <= targetWidth + 0.01 && cluster.logicalEnd > best)
            best = cluster.logicalEnd;
    }
    if (best == 0 || best >= text.length)
    {
        if (layout.visualClusters.length > 0)
            best = layout.visualClusters[0].logicalEnd;
    }
    if (best >= text.length)
        return tuple(text, ""d);
    const sp = lastIndexOf(text[0 .. best], ' ');
    if (sp > 0)
        return tuple(text[0 .. sp], text[sp + 1 .. $]);
    return tuple(text[0 .. best], text[best .. $]);
}

private void addTextItem(ref MdComposition c, PendingText p, double lineTop,
    double lineAscent, int pixelSize)
{
    MdItem item;
    item.kind = MdItemKind.text;
    item.layout = p.layout;
    item.x = p.x;
    item.w = p.w;
    item.y = lineTop + lineAscent - p.ascent;
    item.color = styleColor(p.style, mdText);
    item.underline = p.style == InlineStyle.link;
    item.strike = p.strike;
    item.codePill = p.style == InlineStyle.code;
    item.target = p.target;
    if (p.layout.lines.length > 0)
        item.h = p.layout.lines[0].height;
    c.items ~= item;
    c.cursorX = item.x + item.w;
    c.cursorY = item.y;
    c.cursorPx = pixelSize;
}

private double composeRuns(ref MdComposition c, InlineRun[] runs, int lineWidth,
    double top, Color baseColor, int pixelSize, double indent)
{
    PendingText[] pending;
    double x = indent;
    double lineTop = top;
    double lineAscent = 0;
    double lineDescent = 0;

    void closeLine()
    {
        foreach (p; pending)
            addTextItem(c, p, lineTop, lineAscent, pixelSize);
        lineTop += lineAscent + lineDescent;
        pending.length = 0;
        x = indent;
        lineAscent = 0;
        lineDescent = 0;
    }

    foreach (piece; runs)
    {
        auto run = piece;
        if (run.text.length == 0) continue;
        const whitespace = isSpace(run.text[0]);
        if (whitespace && pending.length == 0)
            continue;
        auto layout = shapeOne(run.text, pixelSize,
            run.style == InlineStyle.code,
            run.style == InlineStyle.bold ||
            run.style == InlineStyle.boldItalic);
        // `shapeOne` returns whatever the shaper produced, and a null layout
        // dereferenced here took the whole process down mid-repaint (a native
        // access violation resolving to this function). The widget tree is
        // already painted when a bubble composes, so a null must be skipped,
        // not assumed away - the same guard `Box.onMeasure` and
        // `Canvas.drawLayout` carry for their own null inputs.
        if (layout is null || layout.lines.length == 0) continue;
        const line = layout.lines[0];
        const w = line.width;
        if (w <= 0) continue;

        if (x + w > lineWidth && pending.length > 0)
        {
            closeLine();
            if (whitespace) continue;
        }

        // Exceptionally long unbroken tokens still need a grapheme-safe split.
        // This path is linear for normal prose because words enter it at most
        // once; paragraph suffixes are never fed back through the shaper.
        if (pending.length == 0 && x + w > lineWidth)
        {
            dstring remainder = run.text;
            while (remainder.length > 0)
            {
                auto remainderLayout = shapeOne(remainder, pixelSize,
                    run.style == InlineStyle.code,
                    run.style == InlineStyle.bold ||
                    run.style == InlineStyle.boldItalic);
                if (remainderLayout is null || remainderLayout.lines.length == 0) break;
                const remainderLine = remainderLayout.lines[0];
                if (x + remainderLine.width <= lineWidth)
                {
                    pending ~= PendingText(remainderLayout, run.style, x,
                        remainderLine.width, run.target, run.strike,
                        remainderLine.ascent);
                    lineAscent = max(lineAscent, remainderLine.ascent);
                    lineDescent = max(lineDescent, remainderLine.descent);
                    x += remainderLine.width;
                    break;
                }

                auto split = splitRun(remainder, remainderLayout,
                    max(1.0, lineWidth - x));
                if (split[0].length == 0) break;
                auto prefixLayout = shapeOne(split[0], pixelSize,
                    run.style == InlineStyle.code,
                    run.style == InlineStyle.bold ||
                    run.style == InlineStyle.boldItalic);
                if (prefixLayout !is null && prefixLayout.lines.length > 0)
                {
                    const prefixLine = prefixLayout.lines[0];
                    pending ~= PendingText(prefixLayout, run.style, x,
                        prefixLine.width, run.target, run.strike,
                        prefixLine.ascent);
                    lineAscent = max(lineAscent, prefixLine.ascent);
                    lineDescent = max(lineDescent, prefixLine.descent);
                    x += prefixLine.width;
                }
                closeLine();
                remainder = split[1];
            }
            continue;
        }

        pending ~= PendingText(layout, run.style, x, w, run.target, run.strike,
            line.ascent);
        lineAscent = max(lineAscent, line.ascent);
        lineDescent = max(lineDescent, line.descent);
        x += w;
    }
    if (pending.length > 0) closeLine();
    return lineTop - top;
}

private double blockGap(int pixelSize)
{
    return pixelSize / 2.0;
}

private InlineRun[] splitFlowRuns(InlineRun[] runs)
{
    InlineRun[] pieces;
    foreach (run; runs)
    {
        size_t first;
        while (first < run.text.length)
        {
            const whitespace = isSpace(run.text[first]);
            size_t end = first + 1;
            while (end < run.text.length &&
                isSpace(run.text[end]) == whitespace)
                ++end;
            pieces ~= InlineRun(run.style, run.text[first .. end], run.target,
                run.strike);
            first = end;
        }
    }
    return pieces;
}

private void prepareFlowPieces(ref MarkdownBlock block)
{
    if (block.flowPiecesReady) return;
    block.flowPieces = splitFlowRuns(block.runs);
    block.itemFlowPieces.length = block.items.length;
    foreach (index, item; block.items)
        block.itemFlowPieces[index] = splitFlowRuns(item);
    block.flowPiecesReady = true;
}

void composeMarkdownInto(ref MdComposition c, MarkdownBlock[] blocks,
    int lineWidth,
    bool streaming)
{
    // Reuse retained output storage. Live resize used to leave thousands of
    // short-lived MdItems per width for a later stop-the-world GC pass.
    c.items.length = 0;
    c.height = 0;
    c.cursorX = 0;
    c.cursorY = 0;
    c.cursorPx = 0;
    c.trailingGap = 0;
    const bodyPx = opencodeFontBase;
    double y = 0;
    // The last block must not reserve trailing space: that showed up as a
    // phantom gap below every assistant reply. The amount it would have added is
    // reported so the incremental composer can restore it between chunks.
    double trailingGap = 0;
    foreach (blockIndex, ref block; blocks)
    {
        const isLast = blockIndex + 1 == blocks.length;
        prepareFlowPieces(block);
        switch (block.type)
        {
            case BlockType.paragraph:
                y += composeRuns(c, block.flowPieces, lineWidth, y,
                    mdText, bodyPx, 0);
                if (isLast) trailingGap = blockGap(bodyPx);
                else y += blockGap(bodyPx);
                break;
            case BlockType.heading:
                const px = block.level <= 2 ? opencodeFontTitle : bodyPx;
                y += composeRuns(c, block.flowPieces, lineWidth, y,
                    mdHeading, px, 0);
                if (isLast) trailingGap = blockGap(bodyPx);
                else y += blockGap(bodyPx);
                break;
            case BlockType.codeBlock:
            {
                const pad = 10;
                const inner = maxInt(1, lineWidth - 2 * pad);
                if (block.codeLineLayouts.length != block.codeLines.length ||
                    block.codeLayoutPixelSize != bodyPx)
                {
                    block.codeLineLayouts.length = block.codeLines.length;
                    foreach (index, codeLine; block.codeLines)
                        block.codeLineLayouts[index] = shapeOne(codeLine,
                            bodyPx, true, false);
                    block.codeLayoutPixelSize = bodyPx;
                }

                const panelIndex = c.items.length;
                c.items ~= MdItem.init;
                double codeHeight = 0.0;
                void appendCodeItem(TextLayout layout, double sourceX,
                    double visibleWidth)
                {
                    if (layout is null || layout.lines.length == 0) return;
                    MdItem text;
                    text.kind = MdItemKind.text;
                    text.layout = layout;
                    text.x = pad - sourceX;
                    text.y = y + pad + codeHeight;
                    text.w = visibleWidth;
                    text.h = layout.lines[0].height;
                    text.color = mdCodeText;
                    text.clipText = true;
                    text.clipX = pad;
                    text.clipW = inner;
                    c.items ~= text;
                    codeHeight += text.h;
                }

                foreach (index, codeLine; block.codeLines)
                {
                    auto layout = block.codeLineLayouts[index];
                    if (layout is null || layout.lines.length == 0) continue;
                    if (codeLine.length == 0 || layout.width <= inner)
                    {
                        appendCodeItem(layout, 0, layout.width);
                        continue;
                    }

                    double sourceX = 0.0;
                    while (sourceX < layout.width - 0.01)
                    {
                        const limit = sourceX + inner;
                        double endX = sourceX;
                        foreach (cluster; layout.visualClusters)
                        {
                            if (cluster.xMax <= sourceX + 0.01) continue;
                            if (cluster.xMax <= limit + 0.01)
                                endX = max(endX, cluster.xMax);
                            else
                            {
                                if (endX <= sourceX + 0.01)
                                    endX = cluster.xMax;
                                break;
                            }
                        }
                        if (endX <= sourceX + 0.01)
                            endX = min(layout.width, sourceX + inner);
                        appendCodeItem(layout, sourceX,
                            min(cast(double) inner, endX - sourceX));
                        sourceX = endX;
                    }
                }
                if (codeHeight <= 0) codeHeight = bodyPx + 4;
                const panelH = 2 * pad + codeHeight;
                MdItem panel;
                panel.kind = MdItemKind.panel;
                panel.x = 0;
                panel.y = y;
                panel.w = lineWidth;
                panel.h = panelH;
                panel.color = mdPanelBg;
                foreach (codeLine; block.codeLines)
                {
                    if (panel.codeText.length > 0) panel.codeText ~= '\n';
                    panel.codeText ~= codeLine;
                }
                c.items[panelIndex] = panel;
                y += panelH;
                if (isLast) trailingGap = blockGap(bodyPx);
                else y += blockGap(bodyPx);
                break;
            }
            case BlockType.bulletList:
            case BlockType.orderedList:
            {
                const baseIndent = 22;
                const depthStep = 16;
                int[] orderedCounters;
                for (int index = 0; index < cast(int) block.items.length; ++index)
                {
                    // Indented items keep their nesting depth so a sub-list
                    // sits under its parent rather than at the same left edge.
                    const depth = index < cast(int) block.itemDepths.length
                        ? block.itemDepths[index] : 0;
                    const markerX = depth * depthStep;
                    const indent = baseIndent + markerX;
                    const startIndex = c.items.length;
                    const itemTop = y;
                    dstring markerText;
                    if (block.type == BlockType.orderedList)
                    {
                        // Number each nesting level independently so a nested
                        // ordered list restarts at 1 (or its own start).
                        if (depth >= cast(int) orderedCounters.length)
                            orderedCounters.length = depth + 1;
                        const number = block.orderedStart + orderedCounters[depth];
                        ++orderedCounters[depth];
                        markerText = (to!dstring(number) ~ ".") ~ " ";
                    }
                    else
                        markerText = "- "d;
                    auto marker = shapeOne(markerText, bodyPx, false, false);
                    const itemHeight = composeRuns(c, block.itemFlowPieces[index],
                        lineWidth, itemTop, mdText, bodyPx, indent);
                    if (marker !is null && marker.lines.length > 0)
                    {
                        MdItem markerItem;
                        markerItem.kind = MdItemKind.text;
                        markerItem.layout = marker;
                        markerItem.x = markerX;
                        markerItem.y = itemTop;
                        markerItem.w = marker.lines[0].width;
                        markerItem.color = mdText;
                        markerItem.h = marker.lines[0].height;
                        c.items.insertInPlace(startIndex, markerItem);
                    }
                    y = itemTop + itemHeight;
                }
                if (isLast) trailingGap = blockGap(bodyPx);
                else y += blockGap(bodyPx);
                break;
            }
            case BlockType.blockquote:
            {
                const indent = 14;
                const startIndex = c.items.length;
                const quoteTop = y;
                const quoteHeight = composeRuns(c, block.flowPieces, lineWidth,
                    quoteTop, mdQuote, bodyPx, indent);
                MdItem bar;
                bar.kind = MdItemKind.quoteBar;
                bar.x = 0;
                bar.y = quoteTop;
                bar.w = 3;
                bar.h = quoteHeight;
                bar.color = mdLink;
                c.items.insertInPlace(startIndex, bar);
                y = quoteTop + quoteHeight;
                if (isLast) trailingGap = blockGap(bodyPx);
                else y += blockGap(bodyPx);
                break;
            }
            case BlockType.rule:
            {
                MdItem item;
                item.kind = MdItemKind.rule;
                item.x = 0;
                item.y = y + 4;
                item.w = lineWidth;
                item.h = 1;
                item.color = mdRule;
                c.items ~= item;
                if (isLast) trailingGap = bodyPx;
                else y += bodyPx;
                break;
            }
            default:
                break;
        }
    }
    // Do not paint an inline block cursor after the final glyph. It used the
    // exact glyph advance as its x coordinate, so letters with a right-side
    // overhang could be covered while streaming and appear cut off. The live
    // Thinking/token indicators already communicate that generation continues.
    c.trailingGap = trailingGap;
    c.height = y;
}

MdComposition composeMarkdown(MarkdownBlock[] blocks, int lineWidth,
    bool streaming)
{
    MdComposition result;
    composeMarkdownInto(result, blocks, lineWidth, streaming);
    return result;
}

unittest
{
    // Streaming used to append a solid block cursor at the exact advance of
    // the last glyph. Besides adding a synthetic text item, it could cover the
    // right edge of letters such as W/f/y until the stream settled.
    auto live = composeMarkdown(parseMarkdown("Final glyph W"), 400, true);
    auto settled = composeMarkdown(parseMarkdown("Final glyph W"), 400, false);
    assert(live.items.length == settled.items.length,
        "streaming composition added an overlapping cursor item");
}

/// Incrementally composes a growing markdown document at a fixed line width.
/// Each call takes the full (only ever appended) text; every block already
/// terminated by a blank line outside a fenced code block is parsed and
/// composed exactly once and cached, so a frame during streaming only pays for
/// the current block instead of the whole message. Call `reset` (or change the
/// width) to drop the cache; a width change rebuilds it automatically.
struct MarkdownComposer
{
    int width = -1;
    private size_t committedLen;
    private double committedHeight;
    private MdItem[] committedItems;

    void reset()
    {
        width = -1;
        committedLen = 0;
        committedHeight = 0;
        committedItems.length = 0;
    }

    void compose(ref MdComposition c, dstring text, int lineWidth,
        bool streaming)
    {
        if (width != lineWidth)
        {
            width = lineWidth;
            committedLen = 0;
            committedHeight = 0;
            committedItems.length = 0;
        }

        // Fold every complete block into the committed prefix exactly once.
        const commit = markdownCommitPoint(text, committedLen);
        if (commit > committedLen)
        {
            auto committedBlocks = parseMarkdown(text[committedLen .. commit]);
            MdComposition part;
            composeMarkdownInto(part, committedBlocks, lineWidth, false);
            foreach (ref item; part.items) item.y += committedHeight;
            committedItems ~= part.items;
            // Restore the gap the committed chunk omitted, because it is still
            // followed by the tail.
            committedHeight += part.height + part.trailingGap;
            committedLen = commit;
        }

        // Compose only the still-growing tail and place it below the prefix.
        auto tailBlocks = parseMarkdown(text[committedLen .. $]);
        MdComposition tail;
        composeMarkdownInto(tail, tailBlocks, lineWidth, streaming);
        foreach (ref item; tail.items) item.y += committedHeight;
        c.items = committedItems.dup;
        c.items ~= tail.items;
        c.height = committedHeight + tail.height;
        c.cursorX = tail.cursorX;
        c.cursorY = tail.cursorY + committedHeight;
        c.cursorPx = tail.cursorPx;
        c.trailingGap = tail.trailingGap;
    }
}

void paintMarkdown(ref Canvas canvas, ref MdComposition c, int dx, int dy)
{
    // Paint every background before any glyph. An inline-code run is composed
    // of several MdItem text segments, and each segment paints a padded pill
    // background (item.x - 3, width + 6). If a segment's background were
    // painted immediately before its own glyphs, the next segment's left
    // overhang would erase the right side of the previous segment's final
    // glyph (for example the "X" in `SYNTAX`).
    foreach (item; c.items)
    {
        switch (item.kind)
        {
            case MdItemKind.text:
                if (item.layout !is null && item.codePill &&
                    item.layout.lines.length == 1)
                {
                    canvas.fillRoundedRect(Rect(cast(int)(dx + item.x) - 3,
                        cast(int)(dy + item.y), cast(int)(item.w + 6),
                        cast(int) item.h), 4, mdCodeBg);
                }
                break;
            case MdItemKind.panel:
                canvas.fillRoundedRect(Rect(cast(int)(dx + item.x),
                    cast(int)(dy + item.y), cast(int) item.w,
                    cast(int) item.h), 8, item.color);
                break;
            case MdItemKind.quoteBar:
                canvas.fillRect(Rect(cast(int)(dx + item.x),
                    cast(int)(dy + item.y), cast(int) item.w,
                    cast(int) item.h), item.color);
                break;
            case MdItemKind.rule:
                canvas.fillRect(Rect(cast(int)(dx + item.x),
                    cast(int)(dy + item.y), cast(int) item.w,
                    cast(int) item.h), item.color);
                break;
            default:
                break;
        }
    }

    foreach (item; c.items)
    {
        if (item.kind != MdItemKind.text || item.layout is null) continue;
        if (item.clipText)
        {
            // The first glyph can extend slightly left of its logical origin
            // (italic bearings and antialiasing). Give only the first code-line
            // segment a two-pixel ink margin; continuation segments stay
            // strictly clipped so text from the previous segment cannot leak.
            const firstSegment = item.x >= item.clipX - 0.01;
            const bleed = firstSegment ? 2 : 0;
            auto clipped = canvas.clipped(Rect(
                cast(int)(dx + item.clipX) - bleed, cast(int)(dy + item.y),
                cast(int) item.clipW + bleed * 2,
                cast(int) ceil(item.h)));
            clipped.drawLayout(Point(cast(int)(dx + item.x),
                cast(int)(dy + item.y)), item.layout, item.color);
        }
        else
            canvas.drawLayout(Point(cast(int)(dx + item.x),
                cast(int)(dy + item.y)), item.layout, item.color);
        if (item.underline && item.layout.lines.length == 1)
        {
            const line = item.layout.lines[0];
            canvas.drawLine(Point(cast(int)(dx + item.x),
                cast(int)(dy + item.y + line.ascent + 1)),
                Point(cast(int)(dx + item.x + item.w),
                cast(int)(dy + item.y + line.ascent + 1)),
                item.color, 1);
        }
        if (item.strike && item.layout.lines.length == 1)
        {
            const line = item.layout.lines[0];
            const midY = cast(int)(dy + item.y + line.ascent * 0.55);
            canvas.drawLine(Point(cast(int)(dx + item.x), midY),
                Point(cast(int)(dx + item.x + item.w), midY),
                item.color, 1);
        }
    }
}

unittest
{
    // CommonMark forbids intraword underscore emphasis, so identifiers must
    // survive parsing untouched rather than turning into italics.
    foreach (run; parseMarkdown("use snake_case and file_name here"d)[0].runs)
        assert(run.style == InlineStyle.text,
            "an intraword underscore created emphasis");

    bool sawItalic;
    foreach (run; parseMarkdown("an _emphasised_ word"d)[0].runs)
        if (run.style == InlineStyle.italic) sawItalic = true;
    assert(sawItalic, "underscore emphasis stopped working");

    bool sawStrike;
    foreach (run; parseMarkdown("~~done~~"d)[0].runs)
        if (run.strike) sawStrike = true;
    assert(sawStrike, "~~strikethrough~~ did not parse");
}

unittest
{
    // A nested bullet keeps its depth so it can render indented.
    auto blocks = parseMarkdown("- parent\n  - child\n"d);
    assert(blocks.length == 1, "nested bullets should form one list block");
    assert(blocks[0].itemDepths.length == 2, "missing per-item depth");
    assert(blocks[0].itemDepths[0] == 0 && blocks[0].itemDepths[1] == 1,
        "nested bullet depth was not recorded");
}

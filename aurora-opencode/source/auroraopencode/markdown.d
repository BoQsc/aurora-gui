module auroraopencode.markdown;

import aurora;
import std.algorithm.comparison : max, min;
import std.array : insertInPlace;
import std.conv : to;
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
    bool codePill;
    bool clipText;
    double clipX;
    double clipW;
}

struct MdComposition
{
    MdItem[] items;
    double height = 0;
    double cursorX = 0;
    double cursorY = 0;
    int cursorPx = 0;
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

private dstring trimStart(dstring s)
{
    size_t i;
    while (i < s.length && isSpace(s[i])) ++i;
    return s[i .. $];
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

private size_t findCloser(dstring text, size_t start, size_t end, dchar ch, int n)
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
        if (match) return i;
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
            const close = indexOf(text, ']', i + 1);
            if (close > i && close + 1 < end && text[close + 1] == '(')
            {
                const closeParen = indexOf(text, ')', close + 2);
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
            buf ~= '[';
            ++i;
            continue;
        }
        if (c == '*' || c == '_')
        {
            int n = 1;
            while (i + n < end && text[i + n] == c) ++n;
            const close = findCloser(text, i + n, end, c, n);
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
        blocks ~= block;
        listItems.length = 0;
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
    item.codePill = p.style == InlineStyle.code;
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
        if (layout.lines.length == 0) continue;
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
                if (remainderLayout.lines.length == 0) break;
                const remainderLine = remainderLayout.lines[0];
                if (x + remainderLine.width <= lineWidth)
                {
                    pending ~= PendingText(remainderLayout, run.style, x,
                        remainderLine.width, run.target, remainderLine.ascent);
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
                if (prefixLayout.lines.length > 0)
                {
                    const prefixLine = prefixLayout.lines[0];
                    pending ~= PendingText(prefixLayout, run.style, x,
                        prefixLine.width, run.target, prefixLine.ascent);
                    lineAscent = max(lineAscent, prefixLine.ascent);
                    lineDescent = max(lineDescent, prefixLine.descent);
                    x += prefixLine.width;
                }
                closeLine();
                remainder = split[1];
            }
            continue;
        }

        pending ~= PendingText(layout, run.style, x, w, run.target, line.ascent);
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
            pieces ~= InlineRun(run.style, run.text[first .. end], run.target);
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
    const bodyPx = fontPixelSize(2);
    double y = 0;
    foreach (ref block; blocks)
    {
        prepareFlowPieces(block);
        switch (block.type)
        {
            case BlockType.paragraph:
                y += composeRuns(c, block.flowPieces, lineWidth, y,
                    mdText, bodyPx, 0);
                y += blockGap(bodyPx);
                break;
            case BlockType.heading:
                const px = block.level <= 2 ? fontPixelSize(3) : bodyPx;
                y += composeRuns(c, block.flowPieces, lineWidth, y,
                    mdHeading, px, 0);
                y += blockGap(bodyPx);
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
                c.items[panelIndex] = panel;
                y += panelH + blockGap(bodyPx);
                break;
            }
            case BlockType.bulletList:
            case BlockType.orderedList:
            {
                const indent = 22;
                for (int index = 0; index < cast(int) block.items.length; ++index)
                {
                    const startIndex = c.items.length;
                    const itemTop = y;
                    auto markerText = block.type == BlockType.orderedList
                        ? (to!dstring(block.orderedStart + index) ~ ".") ~ " "
                        : "- "d;
                    auto marker = shapeOne(markerText, bodyPx, false, false);
                    const itemHeight = composeRuns(c, block.itemFlowPieces[index],
                        lineWidth, itemTop, mdText, bodyPx, indent);
                    if (marker.lines.length > 0)
                    {
                        MdItem markerItem;
                        markerItem.kind = MdItemKind.text;
                        markerItem.layout = marker;
                        markerItem.x = 0;
                        markerItem.y = itemTop;
                        markerItem.w = marker.lines[0].width;
                        markerItem.color = mdText;
                        markerItem.h = marker.lines[0].height;
                        c.items.insertInPlace(startIndex, markerItem);
                    }
                    y = itemTop + itemHeight;
                }
                y += blockGap(bodyPx);
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
                y += blockGap(bodyPx);
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
                y += bodyPx;
                break;
            }
            default:
                break;
        }
    }
    if (streaming && c.cursorPx > 0)
    {
        auto cursor = shapeOne("▌"d, c.cursorPx, false, false);
        if (cursor.lines.length > 0)
        {
            MdItem item;
            item.kind = MdItemKind.text;
            item.layout = cursor;
            item.x = c.cursorX;
            item.y = c.cursorY;
            item.w = cursor.lines[0].width;
            item.color = mdText;
            item.h = cursor.lines[0].height;
            c.items ~= item;
        }
    }
    c.height = y;
}

MdComposition composeMarkdown(MarkdownBlock[] blocks, int lineWidth,
    bool streaming)
{
    MdComposition result;
    composeMarkdownInto(result, blocks, lineWidth, streaming);
    return result;
}

void paintMarkdown(ref Canvas canvas, ref MdComposition c, int dx, int dy)
{
    foreach (item; c.items)
    {
        switch (item.kind)
        {
            case MdItemKind.text:
                if (item.layout is null) break;
                if (item.codePill && item.layout.lines.length == 1)
                {
                    canvas.fillRoundedRect(Rect(cast(int)(dx + item.x) - 3,
                        cast(int)(dy + item.y), cast(int)(item.w + 6),
                        cast(int) item.h), 4, mdCodeBg);
                }
                if (item.clipText)
                {
                    auto clipped = canvas.clipped(Rect(
                        cast(int)(dx + item.clipX), cast(int)(dy + item.y),
                        cast(int) item.clipW, cast(int) item.h));
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
}

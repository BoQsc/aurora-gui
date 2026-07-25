module aurora.text.layout;

/**
 * Renderer-neutral Unicode text shaping, fallback, bidi and line layout.
 *
 * Logical indices are UTF-32 code-point offsets. Every externally visible
 * caret and deletion boundary is snapped to an extended grapheme cluster.
 */

import aurora.font : FontFace, FontRole, SystemFonts;
import aurora.text.fontcollection : FontCollection;
import aurora.text.opentype : OpenTypeShaper, ShapeInput, ShapeOptions,
    ShapedGlyph;
import aurora.text.unicode.bidi : BidiResult, ParagraphDirection, resolveBidi;
import aurora.text.unicode.grapheme : ceilGraphemeBoundary,
    floorGraphemeBoundary, graphemeBoundaries, isGraphemeBoundary;
import aurora.text.unicode.linebreak : lineBreakOpportunities;
import aurora.text.unicode.properties : BidiClass, Script, bidiClass, script;
import aurora.types : Point, Rect, Size, maxInt;

import std.algorithm : max, min, sort;
import std.math : abs, ceil, floor;

/// Physical direction of one shaped run.
enum TextDirection : ubyte
{
    leftToRight,
    rightToLeft
}

/// Which visual side to prefer when one logical boundary has two bidi carets.
enum CaretAffinity : ubyte
{
    upstream,
    downstream
}

struct TextLayoutOptions
{
    FontRole role = FontRole.ui;
    FontFace overrideFace;
    int pixelSize = 17;
    int maxWidth;                 /// 0 means unconstrained.
    int tabSpaces = 4;
    bool wrap = true;
    ParagraphDirection paragraphDirection = ParagraphDirection.automatic;
    uint languageTag;
    bool enableKerning = true;
    bool enableLigatures = true;
    bool enableContextualAlternates = true;
    bool enableMarkPositioning = true;
}

struct PositionedGlyph
{
    FontFace font;
    uint glyphIndex;
    size_t clusterStart;
    size_t clusterEnd;
    double x = 0.0;               /// Baseline origin after GPOS X placement.
    double y = 0.0;               /// Baseline origin after GPOS Y placement.
    double advanceX = 0.0;
    ubyte bidiLevel;
    size_t lineIndex;
}

struct GlyphRun
{
    FontFace font;
    Script script = Script.common;
    TextDirection direction = TextDirection.leftToRight;
    ubyte bidiLevel;
    size_t logicalStart;
    size_t logicalEnd;
    size_t glyphStart;
    size_t glyphEnd;
    double x = 0.0;
    double width = 0.0;
    size_t lineIndex;
}

struct TextLine
{
    size_t logicalStart;
    size_t logicalEnd;
    size_t paragraphEnd;          /// Includes a following hard line break.
    size_t runStart;
    size_t runEnd;
    size_t glyphStart;
    size_t glyphEnd;
    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;
    double baseline = 0.0;
    double ascent = 0.0;
    double descent = 0.0;
}

struct VisualCluster
{
    size_t logicalStart;
    size_t logicalEnd;
    size_t lineIndex;
    TextDirection direction = TextDirection.leftToRight;
    double xMin = 0.0;
    double xMax = 0.0;

    double leadingX() const @safe pure nothrow @nogc
    {
        return direction == TextDirection.leftToRight ? xMin : xMax;
    }

    double trailingX() const @safe pure nothrow @nogc
    {
        return direction == TextDirection.leftToRight ? xMax : xMin;
    }
}

struct CaretPosition
{
    size_t logicalIndex;
    size_t lineIndex;
    double x = 0.0;
    double y = 0.0;
    double height = 0.0;
    CaretAffinity affinity = CaretAffinity.downstream;
}

/** Cacheable renderer-neutral result of shaping and laying out a string. */
final class TextLayout
{
    private dstring _text;
    PositionedGlyph[] glyphs;
    GlyphRun[] runs;
    TextLine[] lines;
    VisualCluster[] visualClusters;
    CaretPosition[] carets;
    double width = 0.0;
    double height = 0.0;
    int pixelSize = 17;

    package this(const(dchar)[] source)
    {
        _text = source.idup;
    }

    const(dchar)[] text() const @safe pure nothrow @nogc { return _text; }

    Size measuredSize() const @safe pure nothrow @nogc
    {
        return Size(cast(int) ceil(width), cast(int) ceil(height));
    }

    /** Closest visual caret, preserving the affinity of bidi boundaries. */
    CaretPosition hitTestCaret(double x, double y) const
    {
        if (lines.length == 0)
            return CaretPosition(0, 0, 0.0, 0.0, 0.0,
                CaretAffinity.downstream);
        const lineIndex = lineAtY(y);
        const line = lines[lineIndex];
        bool found;
        CaretPosition best;
        double distance = double.max;
        foreach (candidate; carets)
        {
            if (candidate.lineIndex != lineIndex) continue;
            const next = abs(x - candidate.x);
            if (!found || next < distance || (abs(next - distance) < 0.01 &&
                candidate.affinity == CaretAffinity.downstream &&
                best.affinity != CaretAffinity.downstream))
            {
                best = candidate;
                distance = next;
                found = true;
            }
        }
        return found ? best : CaretPosition(line.logicalStart, lineIndex,
            line.x, line.y, line.height, CaretAffinity.downstream);
    }

    /** Closest grapheme boundary at a visual point. */
    size_t hitTest(double x, double y) const
    {
        return hitTestCaret(x, y).logicalIndex;
    }

    /** Primary visual caret for a logical grapheme boundary. */
    CaretPosition caretPosition(size_t logicalIndex,
        CaretAffinity affinity = CaretAffinity.downstream) const
    {
        logicalIndex = floorGraphemeBoundary(_text, min(logicalIndex, _text.length));
        bool found;
        CaretPosition best;
        foreach (caret; carets)
        {
            if (caret.logicalIndex != logicalIndex) continue;
            if (!found || caret.affinity == affinity)
            {
                best = caret;
                found = true;
                if (caret.affinity == affinity) break;
            }
        }
        if (found) return best;
        if (lines.length == 0) return CaretPosition(logicalIndex, 0, 0, 0, 0);
        const lineIndex = lineForLogical(logicalIndex);
        const line = lines[lineIndex];
        return CaretPosition(logicalIndex, lineIndex, line.x, line.y,
            line.height, affinity);
    }

    Point caretPoint(size_t logicalIndex,
        CaretAffinity affinity = CaretAffinity.downstream) const
    {
        const caret = caretPosition(logicalIndex, affinity);
        return Point(cast(int) floor(caret.x + 0.5),
            cast(int) floor(caret.y + 0.5));
    }

    /** Selection geometry can contain multiple rectangles on a bidi line. */
    Rect[] selectionRects(size_t first, size_t last) const
    {
        first = floorGraphemeBoundary(_text, min(first, _text.length));
        last = ceilGraphemeBoundary(_text, min(last, _text.length));
        if (last < first)
        {
            const swap = first;
            first = last;
            last = swap;
        }
        Rect[] result;
        if (first == last) return result;
        foreach (lineIndex, line; lines)
        {
            struct Span { double a = 0.0; double b = 0.0; }
            Span[] spans;
            foreach (cluster; visualClusters)
            {
                if (cluster.lineIndex != lineIndex ||
                    cluster.logicalEnd <= first || cluster.logicalStart >= last)
                    continue;
                spans ~= Span(cluster.xMin, cluster.xMax);
            }
            if (last > line.logicalEnd && first <= line.logicalEnd &&
                line.paragraphEnd > line.logicalEnd)
                spans ~= Span(line.width, line.width + max(3.0, line.height * 0.25));
            if (spans.length == 0) continue;
            spans.sort!((a, b) => a.a < b.a);
            double start = spans[0].a;
            double end = spans[0].b;
            foreach (span; spans[1 .. $])
            {
                if (span.a <= end + 0.75)
                    end = max(end, span.b);
                else
                {
                    result ~= makeRect(start, line.y, end - start, line.height);
                    start = span.a;
                    end = span.b;
                }
            }
            result ~= makeRect(start, line.y, end - start, line.height);
        }
        return result;
    }

    /**
     * Move one visual insertion stop from an exact caret state.
     *
     * `carets` is stored in line-major, physical left-to-right order.  Two
     * different logical insertion positions may share one x coordinate at a
     * bidi boundary, and both remain distinct states in that sequence.
     */
    CaretPosition visualCaretMove(CaretPosition current, int delta) const
    {
        if (delta == 0 || carets.length == 0) return current;

        ptrdiff_t selected = -1;
        double nearest = double.max;
        foreach (i, candidate; carets)
        {
            if (candidate.logicalIndex != current.logicalIndex) continue;
            const score = (candidate.lineIndex == current.lineIndex ? 0.0 :
                1_000_000.0) + abs(candidate.x - current.x) +
                (candidate.affinity == current.affinity ? 0.0 : 0.001);
            if (score < nearest)
            {
                selected = cast(ptrdiff_t) i;
                nearest = score;
            }
        }
        if (selected < 0) return current;

        const direction = delta < 0 ? -1 : 1;
        ptrdiff_t cursor = selected + direction;
        while (cursor >= 0 && cursor < cast(ptrdiff_t) carets.length)
        {
            const candidate = carets[cast(size_t) cursor];
            const sameLogicalStop = candidate.logicalIndex == current.logicalIndex &&
                candidate.lineIndex == current.lineIndex &&
                abs(candidate.x - current.x) < 0.01;
            if (!sameLogicalStop) return candidate;
            cursor += direction;
        }
        return current;
    }

    /** Move from a logical boundary while retaining the caller's affinity. */
    CaretPosition visualCaretMove(size_t logicalIndex, CaretAffinity affinity,
        int delta) const
    {
        return visualCaretMove(caretPosition(logicalIndex, affinity), delta);
    }

    /**
     * Compatibility helper for callers that do not retain bidi affinity.
     * For rightward movement it starts at the leftmost visual occurrence of
     * an ambiguous logical boundary; leftward movement starts at the
     * rightmost.  This guarantees progress in either physical direction.
     */
    size_t visualMove(size_t logicalIndex, int delta) const
    {
        if (delta == 0 || carets.length == 0) return logicalIndex;
        logicalIndex = floorGraphemeBoundary(_text,
            min(logicalIndex, _text.length));

        // The affinity-free API cannot represent a second visual occurrence of
        // the same logical boundary (for example at a soft wrap).  Start from
        // the first occurrence when moving right or the last when moving left,
        // then return the next *different logical* boundary.
        ptrdiff_t selected = -1;
        if (delta > 0)
        {
            foreach (i, candidate; carets)
                if (candidate.logicalIndex == logicalIndex)
                {
                    selected = cast(ptrdiff_t) i;
                    break;
                }
        }
        else
        {
            for (ptrdiff_t i = cast(ptrdiff_t) carets.length - 1; i >= 0; --i)
                if (carets[cast(size_t) i].logicalIndex == logicalIndex)
                {
                    selected = i;
                    break;
                }
        }
        if (selected < 0) return logicalIndex;

        const direction = delta < 0 ? -1 : 1;
        for (ptrdiff_t i = selected + direction;
            i >= 0 && i < cast(ptrdiff_t) carets.length; i += direction)
            if (carets[cast(size_t) i].logicalIndex != logicalIndex)
                return carets[cast(size_t) i].logicalIndex;
        return logicalIndex;
    }

    /** Leftmost or rightmost visual insertion stop on a laid-out line. */
    CaretPosition lineEdgeCaret(size_t lineIndex, bool rightEdge) const
    {
        if (lines.length == 0)
            return CaretPosition(0, 0, 0.0, 0.0, 0.0,
                CaretAffinity.downstream);
        lineIndex = min(lineIndex, lines.length - 1);
        bool found;
        CaretPosition best;
        foreach (candidate; carets)
        {
            if (candidate.lineIndex != lineIndex) continue;
            if (!found || (rightEdge ? candidate.x > best.x : candidate.x < best.x) ||
                (abs(candidate.x - best.x) < 0.01 &&
                    candidate.affinity == (rightEdge ? CaretAffinity.downstream :
                        CaretAffinity.upstream)))
            {
                best = candidate;
                found = true;
            }
        }
        if (found) return best;
        const line = lines[lineIndex];
        return CaretPosition(rightEdge ? line.logicalEnd : line.logicalStart,
            lineIndex, rightEdge ? line.x + line.width : line.x, line.y,
            line.height, rightEdge ? CaretAffinity.downstream :
                CaretAffinity.upstream);
    }

    size_t lineForLogical(size_t logicalIndex) const @safe pure nothrow @nogc
    {
        if (lines.length == 0) return 0;
        foreach (i, line; lines)
        {
            if (logicalIndex <= line.logicalEnd || i + 1 == lines.length)
                return i;
        }
        return lines.length - 1;
    }

    private size_t lineAtY(double y) const @safe pure nothrow @nogc
    {
        if (y <= lines[0].y) return 0;
        foreach (i, line; lines)
            if (y < line.y + line.height) return i;
        return lines.length - 1;
    }

    private static Rect makeRect(double x, double y, double w, double h)
        @safe pure nothrow @nogc
    {
        const left = cast(int) floor(x);
        const top = cast(int) floor(y);
        const right = cast(int) ceil(x + max(0.0, w));
        const bottom = cast(int) ceil(y + max(0.0, h));
        return Rect(left, top, maxInt(1, right - left), maxInt(1, bottom - top));
    }
}

private struct ClusterInfo
{
    size_t start;
    size_t end;
    Script script = Script.common;
    FontFace font;
    ubyte level;
    double width = 0.0;
    double xMin = double.max;
    double xMax = -double.max;
}

private struct LogicalRun
{
    size_t firstCluster;
    size_t endCluster;
    FontFace font;
    Script script = Script.common;
    ubyte level;
    ShapedGlyph[] glyphs;
    double width = 0.0;
}

private struct ParagraphInfo
{
    size_t start;
    size_t end;
    size_t breakEnd;
    BidiResult bidi;
    ClusterInfo[] clusters;
    bool[] allowedBreaks;
}

/** Shared shaper and fallback state for a window/font system. */
private struct LayoutCacheKey
{
    ulong textHash;
    size_t textLength;
    ulong faceIdentity;
    int pixelSize;
    int maxWidth;
    int tabSpaces;
    uint languageTag;
    ubyte role;
    ubyte paragraphDirection;
    ubyte featureFlags;
}

private struct LayoutCacheEntry
{
    LayoutCacheKey key;
    dstring text;
    TextLayout layout;
}

final class TextLayoutEngine
{
    private enum size_t maxCachedLayouts = 512;
    private enum size_t maxCachedTextLength = 256;

    private FontCollection _uiFonts;
    private FontCollection _monospaceFonts;
    private OpenTypeShaper[ulong] _shapers;
    // Scalar hash buckets avoid relying on runtime hashing of a struct that
    // contains a dynamic array. Each bucket still verifies the complete text
    // and every layout option, so hash collisions cannot return a wrong layout.
    private LayoutCacheEntry[][ulong] _layoutCache;
    private size_t _cachedLayoutCount;

    this(FontCollection uiFonts = null, FontCollection monospaceFonts = null)
    {
        _uiFonts = uiFonts is null ? FontCollection.system(FontRole.ui) : uiFonts;
        _monospaceFonts = monospaceFonts is null ?
            FontCollection.system(FontRole.monospace) : monospaceFonts;
    }

    FontCollection collection(FontRole role)
    {
        return role == FontRole.monospace ? _monospaceFonts : _uiFonts;
    }

    void setCollections(FontCollection uiFonts, FontCollection monospaceFonts)
    {
        if (uiFonts !is null) _uiFonts = uiFonts;
        if (monospaceFonts !is null) _monospaceFonts = monospaceFonts;
        _shapers = null;
        clearLayoutCache();
    }

    void clearLayoutCache()
    {
        _layoutCache = null;
        _cachedLayoutCount = 0;
    }

    /** Cache short, unwrapped interface strings across repaint-only frames. */
    TextLayout layoutCached(const(dchar)[] text,
        TextLayoutOptions options = TextLayoutOptions())
    {
        if (text.length > maxCachedTextLength || options.wrap || options.maxWidth != 0)
            return layout(text, options);

        LayoutCacheKey lookup;
        lookup.textHash = hashText(text);
        lookup.textLength = text.length;
        lookup.faceIdentity = options.overrideFace is null ? 0 :
            options.overrideFace.identity;
        lookup.pixelSize = options.pixelSize;
        lookup.maxWidth = options.maxWidth;
        lookup.tabSpaces = options.tabSpaces;
        lookup.languageTag = options.languageTag;
        lookup.role = cast(ubyte) options.role;
        lookup.paragraphDirection = cast(ubyte) options.paragraphDirection;
        lookup.featureFlags = cast(ubyte) ((options.enableKerning ? 1 : 0) |
            (options.enableLigatures ? 2 : 0) |
            (options.enableContextualAlternates ? 4 : 0) |
            (options.enableMarkPositioning ? 8 : 0));
        const bucketHash = hashCacheKey(lookup);
        if (auto bucket = bucketHash in _layoutCache)
        {
            foreach (entry; *bucket)
                if (entry.key == lookup && entry.text == text)
                    return entry.layout;
        }

        auto result = layout(text, options);
        if (_cachedLayoutCount >= maxCachedLayouts)
            clearLayoutCache();
        _layoutCache[bucketHash] ~= LayoutCacheEntry(lookup, text.idup, result);
        ++_cachedLayoutCount;
        return result;
    }

    private static ulong hashText(const(dchar)[] text)
        @safe pure nothrow @nogc
    {
        ulong value = 1469598103934665603UL;
        foreach (codepoint; text)
        {
            value ^= cast(uint) codepoint;
            value *= 1099511628211UL;
        }
        return value;
    }

    private static ulong hashCacheKey(LayoutCacheKey key)
        @safe pure nothrow @nogc
    {
        ulong value = key.textHash;
        mixHash(value, key.textLength);
        mixHash(value, key.faceIdentity);
        mixHash(value, cast(uint) key.pixelSize);
        mixHash(value, cast(uint) key.maxWidth);
        mixHash(value, cast(uint) key.tabSpaces);
        mixHash(value, key.languageTag);
        mixHash(value, key.role);
        mixHash(value, key.paragraphDirection);
        mixHash(value, key.featureFlags);
        return value;
    }

    private static void mixHash(ref ulong value, ulong item)
        @safe pure nothrow @nogc
    {
        value ^= item + 0x9e3779b97f4a7c15UL + (value << 6) + (value >> 2);
    }

    TextLayout layout(const(dchar)[] text, TextLayoutOptions options = TextLayoutOptions())
    {
        options.pixelSize = maxInt(1, options.pixelSize);
        options.tabSpaces = maxInt(1, options.tabSpaces);
        auto result = new TextLayout(text);
        result.pixelSize = options.pixelSize;
        double y = 0.0;
        size_t paragraphStart;
        while (paragraphStart <= text.length)
        {
            size_t paragraphEnd = paragraphStart;
            while (paragraphEnd < text.length && text[paragraphEnd] != '\n' &&
                text[paragraphEnd] != '\r') ++paragraphEnd;
            size_t breakEnd = paragraphEnd;
            if (breakEnd < text.length)
            {
                if (text[breakEnd] == '\r' && breakEnd + 1 < text.length &&
                    text[breakEnd + 1] == '\n') breakEnd += 2;
                else ++breakEnd;
            }

            auto paragraph = prepareParagraph(text, paragraphStart,
                paragraphEnd, breakEnd, options);
            auto ranges = breakParagraph(paragraph, options);
            if (ranges.length == 0) ranges ~= [cast(size_t) 0, cast(size_t) 0];
            foreach (range; ranges)
                buildLine(result, text, paragraph, range[0], range[1], y, options);

            if (breakEnd >= text.length) break;
            paragraphStart = breakEnd;
        }
        if (result.lines.length == 0)
        {
            auto face = options.overrideFace !is null ? options.overrideFace :
                collection(options.role).primary();
            const h = max(1, face.lineHeight(options.pixelSize));
            TextLine line;
            line.height = h;
            line.ascent = face.ascent(options.pixelSize);
            line.descent = face.descent(options.pixelSize);
            line.baseline = line.ascent;
            result.lines ~= line;
            result.carets ~= CaretPosition(0, 0, 0.0, 0.0, h);
            y = h;
        }
        result.height = y;
        foreach (line; result.lines) result.width = max(result.width, line.width);
        normalizeCarets(result);
        return result;
    }

    private ParagraphInfo prepareParagraph(const(dchar)[] text, size_t start,
        size_t end, size_t breakEnd, TextLayoutOptions options)
    {
        ParagraphInfo paragraph;
        paragraph.start = start;
        paragraph.end = end;
        paragraph.breakEnd = breakEnd;
        const slice = text[start .. end];
        paragraph.bidi = resolveBidi(slice, options.paragraphDirection);
        auto boundaries = graphemeBoundaries(slice);
        if (boundaries.length == 1 && slice.length == 0)
            boundaries ~= 0;
        foreach (i; 0 .. (boundaries.length > 0 ? boundaries.length - 1 : 0))
        {
            ClusterInfo cluster;
            cluster.start = start + boundaries[i];
            cluster.end = start + boundaries[i + 1];
            cluster.level = clusterLevel(paragraph.bidi,
                boundaries[i], boundaries[i + 1]);
            cluster.script = clusterScript(text[cluster.start .. cluster.end]);
            paragraph.clusters ~= cluster;
        }
        resolveScripts(paragraph.clusters);
        auto fonts = collection(options.role);
        foreach (ref cluster; paragraph.clusters)
        {
            auto clusterText = text[cluster.start .. cluster.end];
            if (options.overrideFace !is null &&
                fonts.supportsCluster(options.overrideFace, clusterText))
                cluster.font = options.overrideFace;
            else
                cluster.font = fonts.resolve(clusterText);
        }
        paragraph.allowedBreaks = lineBreakOpportunities(slice);
        measureParagraph(text, paragraph, options);
        return paragraph;
    }

    private void measureParagraph(const(dchar)[] text, ref ParagraphInfo paragraph,
        TextLayoutOptions options)
    {
        auto runs = makeRuns(paragraph.clusters, 0, paragraph.clusters.length);
        foreach (ref run; runs)
        {
            run.glyphs = shapeRun(text, paragraph.clusters, run, options);
            foreach (glyph; run.glyphs)
            {
                run.width += glyph.advanceX;
                const clusterIndex = findCluster(paragraph.clusters,
                    glyph.clusterStart, run.firstCluster, run.endCluster);
                if (clusterIndex < paragraph.clusters.length)
                    paragraph.clusters[clusterIndex].width += max(0.0, glyph.advanceX);
                // A ligature is indivisible for wrapping even if UAX #14 would
                // otherwise permit a boundary inside its source cluster span.
                for (size_t boundary = glyph.clusterStart + 1;
                    boundary < glyph.clusterEnd; ++boundary)
                {
                    if (boundary >= paragraph.start && boundary <= paragraph.end)
                    {
                        const local = boundary - paragraph.start;
                        if (local < paragraph.allowedBreaks.length)
                            paragraph.allowedBreaks[local] = false;
                    }
                }
            }
        }
    }

    private size_t[2][] breakParagraph(const(ParagraphInfo) paragraph,
        TextLayoutOptions options) const
    {
        size_t[2][] result;
        const count = paragraph.clusters.length;
        if (count == 0)
        {
            result ~= [cast(size_t) 0, cast(size_t) 0];
            return result;
        }
        if (!options.wrap || options.maxWidth <= 0)
        {
            result ~= [cast(size_t) 0, count];
            return result;
        }
        size_t first;
        while (first < count)
        {
            double width = 0.0;
            size_t candidate = first;
            size_t chosen = count;
            foreach (i; first .. count)
            {
                const nextWidth = width + paragraph.clusters[i].width;
                if (nextWidth > options.maxWidth && i > first)
                {
                    // Only use a break observed before the overflowing cluster.
                    chosen = candidate > first ? candidate : i;
                    break;
                }
                width = nextWidth;
                const boundary = paragraph.clusters[i].end - paragraph.start;
                if (boundary < paragraph.allowedBreaks.length &&
                    paragraph.allowedBreaks[boundary]) candidate = i + 1;
            }
            if (chosen == count) chosen = count;
            if (chosen <= first) chosen = first + 1;
            result ~= [first, chosen];
            first = chosen;
        }
        return result;
    }

    private void buildLine(TextLayout result, const(dchar)[] text,
        ref ParagraphInfo paragraph, size_t firstCluster, size_t endCluster,
        ref double y, TextLayoutOptions options)
    {
        const lineIndex = result.lines.length;
        const logicalStart = firstCluster < paragraph.clusters.length ?
            paragraph.clusters[firstCluster].start : paragraph.start;
        const logicalEnd = endCluster > firstCluster ?
            paragraph.clusters[endCluster - 1].end : logicalStart;

        auto clusters = paragraph.clusters[firstCluster .. endCluster].dup;
        applyLineTrailingLevels(text, paragraph, clusters, logicalStart, logicalEnd);
        auto logicalRuns = makeRuns(clusters, 0, clusters.length);
        foreach (ref run; logicalRuns)
        {
            // Run indices are local to the line copy.
            run.glyphs = shapeRun(text, clusters, run, options);
            foreach (glyph; run.glyphs) run.width += glyph.advanceX;
        }

        double ascent = 0.0;
        double descent = 0.0;
        double lineHeight = 0.0;
        foreach (run; logicalRuns)
        {
            ascent = max(ascent, cast(double) run.font.ascent(options.pixelSize));
            descent = max(descent, cast(double) run.font.descent(options.pixelSize));
            lineHeight = max(lineHeight, cast(double) run.font.lineHeight(options.pixelSize));
        }
        if (logicalRuns.length == 0)
        {
            auto face = options.overrideFace !is null ? options.overrideFace :
                collection(options.role).primary();
            ascent = face.ascent(options.pixelSize);
            descent = face.descent(options.pixelSize);
            lineHeight = face.lineHeight(options.pixelSize);
        }
        lineHeight = max(lineHeight, ascent + descent);
        lineHeight = max(1.0, lineHeight);
        const baseline = y + ascent;

        const visualRunOrder = orderRunsVisually(text, paragraph, clusters,
            logicalRuns, logicalStart, logicalEnd);
        const runStart = result.runs.length;
        const glyphStart = result.glyphs.length;
        double x = 0.0;
        ClusterInfo[] placed = clusters.dup;
        foreach (ref cluster; placed)
        {
            cluster.xMin = double.max;
            cluster.xMax = -double.max;
        }

        foreach (runIndex; visualRunOrder)
        {
            if (runIndex >= logicalRuns.length) continue;
            auto run = logicalRuns[runIndex];
            const runX = x;
            const rtl = (run.level & 1) != 0;
            double cursor = rtl ? runX + run.width : runX;
            const outputGlyphStart = result.glyphs.length;
            auto shaper = shaperFor(run.font);

            foreach (glyph; run.glyphs)
            {
                double origin;
                if (rtl)
                {
                    cursor -= glyph.advanceX;
                    origin = cursor;
                }
                else
                {
                    origin = cursor;
                    cursor += glyph.advanceX;
                }
                PositionedGlyph positioned;
                positioned.font = run.font;
                positioned.glyphIndex = glyph.glyphIndex;
                positioned.clusterStart = glyph.clusterStart;
                positioned.clusterEnd = glyph.clusterEnd;
                positioned.x = origin + glyph.offsetX;
                positioned.y = baseline - glyph.offsetY;
                positioned.advanceX = glyph.advanceX;
                positioned.bidiLevel = run.level;
                positioned.lineIndex = lineIndex;
                result.glyphs ~= positioned;
                placeGlyphClusters(placed, glyph, origin, rtl, shaper,
                    options.pixelSize);
            }

            GlyphRun outputRun;
            outputRun.font = run.font;
            outputRun.script = run.script;
            outputRun.direction = rtl ? TextDirection.rightToLeft :
                TextDirection.leftToRight;
            outputRun.bidiLevel = run.level;
            outputRun.logicalStart = clusters[run.firstCluster].start;
            outputRun.logicalEnd = clusters[run.endCluster - 1].end;
            outputRun.glyphStart = outputGlyphStart;
            outputRun.glyphEnd = result.glyphs.length;
            outputRun.x = runX;
            outputRun.width = run.width;
            outputRun.lineIndex = lineIndex;
            result.runs ~= outputRun;
            x += run.width;
        }

        // Give zero-width controls a stable caret location and emit one visual
        // cluster per grapheme, sorted into physical order.
        double fallbackX = 0.0;
        foreach (ref cluster; placed)
        {
            if (cluster.xMin == double.max)
            {
                cluster.xMin = fallbackX;
                cluster.xMax = fallbackX;
            }
            fallbackX = max(fallbackX, cluster.xMax);
        }
        VisualCluster[] lineClusters;
        foreach (cluster; placed)
        {
            VisualCluster visual;
            visual.logicalStart = cluster.start;
            visual.logicalEnd = cluster.end;
            visual.lineIndex = lineIndex;
            visual.direction = (cluster.level & 1) ? TextDirection.rightToLeft :
                TextDirection.leftToRight;
            visual.xMin = min(cluster.xMin, cluster.xMax);
            visual.xMax = max(cluster.xMin, cluster.xMax);
            lineClusters ~= visual;
        }
        lineClusters.sort!((a, b)
        {
            if (a.xMin != b.xMin) return a.xMin < b.xMin;
            if (a.xMax != b.xMax) return a.xMax < b.xMax;
            return a.logicalStart < b.logicalStart;
        });
        result.visualClusters ~= lineClusters;

        TextLine line;
        line.logicalStart = logicalStart;
        line.logicalEnd = logicalEnd;
        line.paragraphEnd = endCluster == paragraph.clusters.length ?
            paragraph.breakEnd : logicalEnd;
        line.runStart = runStart;
        line.runEnd = result.runs.length;
        line.glyphStart = glyphStart;
        line.glyphEnd = result.glyphs.length;
        line.y = y;
        line.width = x;
        line.height = lineHeight;
        line.baseline = baseline;
        line.ascent = ascent;
        line.descent = descent;
        result.lines ~= line;

        // Emit insertion states in strict physical left-to-right order.  At
        // a shared x coordinate the right edge of the preceding visual
        // cluster must precede the left edge of the following cluster.  That
        // ordering is observable at bidi embedding boundaries, where two
        // distinct logical positions legitimately occupy the same point.
        foreach (cluster; lineClusters)
        {
            if (cluster.direction == TextDirection.leftToRight)
            {
                result.carets ~= CaretPosition(cluster.logicalStart, lineIndex,
                    cluster.xMin, y, lineHeight, CaretAffinity.downstream);
                result.carets ~= CaretPosition(cluster.logicalEnd, lineIndex,
                    cluster.xMax, y, lineHeight, CaretAffinity.upstream);
            }
            else
            {
                result.carets ~= CaretPosition(cluster.logicalEnd, lineIndex,
                    cluster.xMin, y, lineHeight, CaretAffinity.upstream);
                result.carets ~= CaretPosition(cluster.logicalStart, lineIndex,
                    cluster.xMax, y, lineHeight, CaretAffinity.downstream);
            }
        }
        if (lineClusters.length == 0)
            result.carets ~= CaretPosition(logicalStart, lineIndex, 0.0, y,
                lineHeight, CaretAffinity.downstream);
        y += lineHeight;
    }

    private ShapedGlyph[] shapeRun(const(dchar)[] text,
        const(ClusterInfo)[] clusters, LogicalRun run, TextLayoutOptions options)
    {
        ShapeInput[] input;
        foreach (clusterIndex; run.firstCluster .. run.endCluster)
        {
            const cluster = clusters[clusterIndex];
            foreach (ch; text[cluster.start .. cluster.end])
            {
                if (ch == '\t')
                {
                    foreach (_; 0 .. options.tabSpaces)
                        input ~= ShapeInput(' ', cluster.start, cluster.end);
                }
                else if (ch != '\r' && ch != '\n')
                    input ~= ShapeInput(ch, cluster.start, cluster.end);
            }
        }
        ShapeOptions shapeOptions;
        shapeOptions.script = run.script;
        shapeOptions.languageTag = options.languageTag;
        shapeOptions.pixelSize = options.pixelSize;
        shapeOptions.rightToLeft = (run.level & 1) != 0;
        shapeOptions.enableKerning = options.enableKerning;
        shapeOptions.enableLigatures = options.enableLigatures;
        shapeOptions.enableContextualAlternates = options.enableContextualAlternates;
        shapeOptions.enableMarkPositioning = options.enableMarkPositioning;
        return shaperFor(run.font).shape(input, shapeOptions);
    }

    private OpenTypeShaper shaperFor(FontFace face)
    {
        if (auto existing = face.identity in _shapers) return *existing;
        auto created = new OpenTypeShaper(face);
        _shapers[face.identity] = created;
        return created;
    }

    private static LogicalRun[] makeRuns(ClusterInfo[] clusters,
        size_t first, size_t end)
    {
        LogicalRun[] result;
        size_t cursor = first;
        while (cursor < end)
        {
            LogicalRun run;
            run.firstCluster = cursor;
            run.font = clusters[cursor].font;
            run.script = clusters[cursor].script;
            run.level = clusters[cursor].level;
            ++cursor;
            while (cursor < end && clusters[cursor].font is run.font &&
                clusters[cursor].script == run.script &&
                clusters[cursor].level == run.level)
                ++cursor;
            run.endCluster = cursor;
            result ~= run;
        }
        return result;
    }

    private static size_t[] orderRunsVisually(const(dchar)[] text,
        const(ParagraphInfo) paragraph, const(ClusterInfo)[] clusters,
        const(LogicalRun)[] runs, size_t lineStart, size_t lineEnd)
    {
        size_t[] result;
        if (runs.length == 0) return result;
        auto order = reorderLine(text, paragraph, lineStart, lineEnd);
        foreach (logical; order)
        {
            const global = paragraph.start + logical;
            const cluster = findCluster(clusters, global, 0, clusters.length);
            if (cluster >= clusters.length) continue;
            size_t runIndex;
            foreach (i, run; runs)
                if (cluster >= run.firstCluster && cluster < run.endCluster)
                { runIndex = i; break; }
            if (result.length == 0 || result[$ - 1] != runIndex)
                result ~= runIndex;
        }
        if (result.length == 0)
            foreach (i; 0 .. runs.length) result ~= i;
        // A run should be contiguous under L2. Guard malformed/removed-only
        // input from causing duplicate drawing.
        bool[] seen = new bool[runs.length];
        size_t[] unique;
        foreach (index; result)
            if (index < seen.length && !seen[index])
            { unique ~= index; seen[index] = true; }
        foreach (i; 0 .. runs.length)
            if (!seen[i]) unique ~= i;
        return unique;
    }

    private static size_t[] reorderLine(const(dchar)[] text,
        const(ParagraphInfo) paragraph, size_t lineStart, size_t lineEnd)
    {
        size_t[] order;
        if (lineEnd <= lineStart) return order;
        const localStart = lineStart - paragraph.start;
        const localEnd = lineEnd - paragraph.start;
        auto levels = paragraph.bidi.levels[localStart .. localEnd].dup;
        // UAX #9 L1 is line-specific for trailing whitespace.
        size_t cursor = levels.length;
        while (cursor > 0)
        {
            --cursor;
            if (levels[cursor] == ubyte.max) continue;
            const cls = bidiClass(text[lineStart + cursor]);
            if (!isL1Whitespace(cls)) break;
            levels[cursor] = paragraph.bidi.paragraphLevel;
        }
        ubyte highest;
        ubyte lowestOdd = ubyte.max;
        foreach (i, level; levels)
        {
            if (level == ubyte.max) continue;
            order ~= localStart + i;
            if (level > highest) highest = level;
            if ((level & 1) && level < lowestOdd) lowestOdd = level;
        }
        if (lowestOdd == ubyte.max) return order;
        int current = highest;
        while (current >= lowestOdd)
        {
            size_t at;
            while (at < order.length)
            {
                while (at < order.length &&
                    levels[order[at] - localStart] < current) ++at;
                const begin = at;
                while (at < order.length &&
                    levels[order[at] - localStart] >= current) ++at;
                if (at > begin + 1)
                {
                    size_t left = begin;
                    size_t right = at - 1;
                    while (left < right)
                    {
                        const swap = order[left];
                        order[left] = order[right];
                        order[right] = swap;
                        ++left; --right;
                    }
                }
            }
            --current;
        }
        return order;
    }

    private static void applyLineTrailingLevels(const(dchar)[] text,
        const(ParagraphInfo) paragraph, ref ClusterInfo[] clusters,
        size_t lineStart, size_t lineEnd)
    {
        size_t cursor = lineEnd;
        while (cursor > lineStart)
        {
            const ch = text[cursor - 1];
            if (!isL1Whitespace(bidiClass(ch))) break;
            --cursor;
        }
        foreach (ref cluster; clusters)
            if (cluster.start >= cursor)
                cluster.level = paragraph.bidi.paragraphLevel;
    }

    private static bool isL1Whitespace(BidiClass value)
        @safe pure nothrow @nogc
    {
        return value == BidiClass.ws || value == BidiClass.fsi ||
            value == BidiClass.lri || value == BidiClass.rli ||
            value == BidiClass.pdi || value == BidiClass.s ||
            value == BidiClass.b;
    }

    private static void placeGlyphClusters(ref ClusterInfo[] clusters,
        ShapedGlyph glyph, double origin, bool rtl, OpenTypeShaper shaper,
        int pixelSize)
    {
        size_t first = findCluster(clusters, glyph.clusterStart, 0, clusters.length);
        if (first >= clusters.length) return;
        size_t end = first + 1;
        while (end < clusters.length && clusters[end].start < glyph.clusterEnd)
            ++end;
        const count = max(cast(size_t) 1, end - first);
        double[] physical;
        physical ~= origin;
        auto ligature = shaper.ligatureCarets(glyph.glyphIndex, pixelSize);
        ligature.sort();
        if (ligature.length >= count - 1)
            foreach (i; 0 .. count - 1)
                physical ~= origin + ligature[i];
        else
            foreach (i; 1 .. count)
                physical ~= origin + glyph.advanceX * cast(double) i / count;
        physical ~= origin + glyph.advanceX;
        physical.sort();
        // Remove accidental duplicate final entries from count==1 construction.
        while (physical.length > count + 1) physical.length = physical.length - 1;
        foreach (i; 0 .. count)
        {
            const logical = rtl ? count - 1 - i : i;
            const a = physical[i];
            const b = physical[i + 1];
            auto target = first + logical;
            clusters[target].xMin = min(clusters[target].xMin, min(a, b));
            clusters[target].xMax = max(clusters[target].xMax, max(a, b));
        }
    }

    private static size_t findCluster(const(ClusterInfo)[] clusters,
        size_t logical, size_t first, size_t end) @safe pure nothrow @nogc
    {
        size_t low = first;
        size_t high = min(end, clusters.length);
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (logical < clusters[middle].start) high = middle;
            else if (logical >= clusters[middle].end) low = middle + 1;
            else return middle;
        }
        return clusters.length;
    }

    private static ubyte clusterLevel(const BidiResult bidi,
        size_t start, size_t end) @safe pure nothrow @nogc
    {
        foreach (i; start .. min(end, bidi.levels.length))
            if (bidi.levels[i] != ubyte.max) return bidi.levels[i];
        return bidi.paragraphLevel;
    }

    private static Script clusterScript(const(dchar)[] cluster)
        @safe pure nothrow @nogc
    {
        foreach (ch; cluster)
        {
            const value = script(ch);
            if (value != Script.common && value != Script.inherited &&
                value != Script.unknown) return value;
        }
        return Script.common;
    }

    private static void resolveScripts(ref ClusterInfo[] clusters)
        @safe pure nothrow @nogc
    {
        Script previous = Script.common;
        foreach (ref cluster; clusters)
        {
            if (cluster.script != Script.common &&
                cluster.script != Script.inherited &&
                cluster.script != Script.unknown)
                previous = cluster.script;
            else if (previous != Script.common)
                cluster.script = previous;
        }
        Script next = Script.common;
        for (ptrdiff_t i = cast(ptrdiff_t) clusters.length - 1; i >= 0; --i)
        {
            auto cluster = &clusters[cast(size_t) i];
            if (cluster.script != Script.common &&
                cluster.script != Script.inherited &&
                cluster.script != Script.unknown)
                next = cluster.script;
            else if (next != Script.common)
                cluster.script = next;
        }
    }

    private static void normalizeCarets(TextLayout layout)
    {
        // buildLine already emits line-major physical order.  Do not sort here:
        // equal-x logical states at a bidi boundary have a meaningful crossing
        // order inherited from the adjacent visual clusters.
        CaretPosition[] unique;
        foreach (caret; layout.carets)
        {
            if (unique.length && unique[$ - 1].logicalIndex == caret.logicalIndex &&
                unique[$ - 1].lineIndex == caret.lineIndex &&
                abs(unique[$ - 1].x - caret.x) < 0.01)
                continue;
            unique ~= caret;
        }
        layout.carets = unique;
    }
}

unittest
{
    auto engine = new TextLayoutEngine();
    TextLayoutOptions options;
    options.pixelSize = 24;
    options.wrap = false;

    auto cachedA = engine.layoutCached("Static label"d, options);
    auto cachedB = engine.layoutCached("Static label"d, options);
    assert(cachedA is cachedB);
    engine.clearLayoutCache();
    auto cachedC = engine.layoutCached("Static label"d, options);
    assert(cachedC !is cachedA);

    auto latin = engine.layout("office A\u0301"d, options);
    assert(latin.lines.length == 1);
    assert(latin.width > 0 && latin.glyphs.length > 0);
    assert(latin.hitTest(0, 0) == 0);

    auto mixed = engine.layout("abc \u05D0\u05D1\u05D2"d, options);
    assert(mixed.runs.length >= 2);
    assert(mixed.visualClusters.length == graphemeBoundaries(mixed.text).length - 1);

    auto emoji = "x\U0001F469\u200D\U0001F4BBy"d;
    auto clustered = engine.layout(emoji, options);
    const afterX = clustered.visualMove(0, 1);
    assert(afterX == 1);
    assert(clustered.visualMove(afterX, 1) == 4);

    // Equal-x bidi boundaries retain their physical crossing order.  Logical
    // indices can repeat later in the same visual traversal, but an exact
    // caret state must never become stuck before the physical line edge.
    auto bidi = engine.layout("abc אבג 123"d, options);
    auto caret = bidi.caretPosition(0);
    immutable size_t[] rightOrder = [1, 2, 3, 4, 8, 9, 10, 11, 8, 7, 6, 5, 4];
    foreach (expected; rightOrder)
    {
        const next = bidi.visualCaretMove(caret, 1);
        assert(next.logicalIndex == expected);
        assert(next.lineIndex > caret.lineIndex || next.x >= caret.x);
        caret = next;
    }
    assert(bidi.visualCaretMove(caret, 1) == caret);
    foreach_reverse (expected; rightOrder[0 .. $ - 1])
    {
        caret = bidi.visualCaretMove(caret, -1);
        assert(caret.logicalIndex == expected);
    }
    caret = bidi.visualCaretMove(caret, -1);
    assert(caret.logicalIndex == 0);
    assert(bidi.visualMove(4, 1) == 8);
    assert(bidi.visualMove(4, -1) == 5);
}

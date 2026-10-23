module aurora.text.rasterizer;

import std.algorithm : min, max;
import std.algorithm.sorting : sort;
import std.math : ceil, floor, sqrt;

/// A directed outline segment in bitmap pixel coordinates (y points down).
struct OutlineEdge
{
    double x0, y0, x1, y1;
    double cx = 0, cy = 0;
    bool quadratic;

    /// Quadratic edges must be monotone in y (split at their y extremum).
    double parameterAtY(double y) const
    {
        if (!quadratic) return (y - y0) / (y1 - y0);
        const a = y0 - 2 * cy + y1;
        const b = 2 * (cy - y0);
        const delta = y - y0;
        double t;
        if (a == 0) t = delta / b;
        else
        {
            // The rationalized quadratic root avoids cancellation on curves
            // that are almost lines. Its sign follows the monotone direction.
            const root = sqrt(max(0.0, b * b + 4 * a * delta));
            const denominator = b + (b < 0 || (b == 0 && a < 0) ? -root : root);
            t = denominator == 0 ? 0 : 2 * delta / denominator;
        }
        return max(0.0, min(1.0, t));
    }

    double xAtY(double y) const
    {
        const t = parameterAtY(y);
        if (!quadratic) return x0 + t * (x1 - x0);
        const s = 1 - t;
        return s * s * x0 + 2 * s * t * cx + t * t * x1;
    }

    void splitAt(double t, out OutlineEdge first, out OutlineEdge second) const
    {
        const ax = x0 + t * (cx - x0);
        const ay = y0 + t * (cy - y0);
        const bx = cx + t * (x1 - cx);
        const by = cy + t * (y1 - cy);
        const mx = ax + t * (bx - ax);
        const my = ay + t * (by - ay);
        first = OutlineEdge(x0, y0, mx, my, ax, ay, true);
        second = OutlineEdge(mx, my, x1, y1, bx, by, true);
    }
}

/// Preserve a quadratic exactly, splitting only to make scanline winding well-defined.
void appendQuadraticEdges(OutlineEdge edge, ref OutlineEdge[] edges)
{
    edge.quadratic = true;
    const denominator = edge.y0 - 2 * edge.cy + edge.y1;
    const split = denominator == 0 ? -1 : (edge.y0 - edge.cy) / denominator;
    if (split > 0 && split < 1)
    {
        OutlineEdge first, second;
        edge.splitAt(split, first, second);
        edges ~= first;
        edges ~= second;
    }
    else edges ~= edge;
}

/// Conservative vertical alignment for small text. The font supplies its
/// lowercase/capital alignment zones; horizontal geometry remains untouched.
struct VerticalAlignment
{
    double xHeight;
    double capHeight;

    bool enabled() const
    {
        return xHeight > 1 && capHeight > xHeight &&
            floor(capHeight + 0.75) > floor(xHeight + 0.5);
    }

    double fit(double y) const
    {
        if (!enabled()) return y;
        const xTarget = floor(xHeight + 0.5);
        // A quarter-pixel upward bias avoids shrinking small capitals below
        // their intended height while leaving near-integer heights unchanged.
        const capTarget = floor(capHeight + 0.75);
        // A continuous, strictly increasing map preserves counters, accents,
        // and thin strokes. Never flatten points into a snapping plateau.
        if (y <= 0) return y;
        if (y < xHeight)
            return y * xTarget / xHeight;
        if (y < capHeight)
            return xTarget + (y - xHeight) * (capTarget - xTarget) /
                (capHeight - xHeight);
        return capTarget + (y - capHeight);
    }
}

/// Fit outline edges, then recompute bounds so aligned tops cannot clip.
/// Quadratics are split at zone boundaries before the piecewise affine map.
void alignVertically(ref OutlineEdge[] edges, ref int bearingY,
    ref int height, VerticalAlignment alignment)
{
    if (!alignment.enabled() || edges.length == 0) return;
    // Transforming endpoints alone changes curve geometry. Each retained curve
    // must lie in one alignment zone, so its control point receives the same
    // affine map as every point on the curve. Straight legacy edges keep their
    // existing behavior, preserving the approved renderer.
    bool hasCurves;
    foreach (edge; edges) hasCurves |= edge.quadratic;
    if (hasCurves)
        foreach (boundary; [cast(double) bearingY, bearingY - alignment.xHeight,
                            bearingY - alignment.capHeight])
        {
            OutlineEdge[] split;
            foreach (edge; edges)
            {
                if (edge.quadratic && boundary > min(edge.y0, edge.y1) &&
                    boundary < max(edge.y0, edge.y1))
                {
                    OutlineEdge first, second;
                    edge.splitAt(edge.parameterAtY(boundary), first, second);
                    split ~= first;
                    split ~= second;
                }
                else split ~= edge;
            }
            edges = split;
        }
    double minY = double.infinity, maxY = -double.infinity;
    foreach (ref edge; edges)
    {
        edge.y0 = alignment.fit(bearingY - edge.y0);
        edge.y1 = alignment.fit(bearingY - edge.y1);
        if (edge.quadratic) edge.cy = alignment.fit(bearingY - edge.cy);
        minY = min(minY, min(edge.y0, edge.y1));
        maxY = max(maxY, max(edge.y0, edge.y1));
    }
    bearingY = cast(int) ceil(maxY);
    height = max(0, bearingY - cast(int) floor(minY));
    foreach (ref edge; edges)
    {
        edge.y0 = bearingY - edge.y0;
        edge.y1 = bearingY - edge.y1;
        if (edge.quadratic) edge.cy = bearingY - edge.cy;
    }
}

/**
 * Portable non-zero-winding grayscale coverage for flattened font outlines.
 * Horizontal span coverage is exact. Vertical integration uses midpoint
 * samples, split at every edge endpoint so even sub-sample-height horizontal
 * stems retain their area. Sloped edges are approximated with 2..16 samples
 * per pixel row. No display subpixel order or native font library is needed.
 */
void rasterizeCoverage(const(OutlineEdge)[] edges, ubyte[] alpha,
    int width, int height, int supersample = 4)
{
    assert(width >= 0 && height >= 0);
    assert(alpha.length == cast(size_t) width * height);
    alpha[] = 0;
    if (width == 0 || height == 0 || edges.length == 0) return;

    struct Crossing
    {
        double x;
        int winding;
    }
    const samples = max(1, min(8, supersample)) * 2;
    double[] breaks;
    Crossing[] crossings;
    double[] coverage = new double[width];
    size_t[] active;
    breaks.reserve(edges.length * 2 + samples + 1);
    crossings.reserve(edges.length);
    active.reserve(edges.length);
    foreach (y; 0 .. height)
    {
        coverage[] = 0;
        breaks.length = 0;
        // Only edges whose y range intersects this pixel row can produce a
        // crossing inside it. Selecting them once per row keeps the band loop
        // proportional to the strokes actually present in the row instead of
        // re-testing the whole outline for every band (that was milliseconds
        // per glyph, and a cold transcript page paid it for every new glyph).
        active.length = 0;
        foreach (index, edge; edges)
        {
            if (max(edge.y0, edge.y1) <= y || min(edge.y0, edge.y1) >= y + 1)
                continue;
            active ~= index;
        }
        if (active.length == 0) continue;
        foreach (sample; 0 .. samples + 1)
            breaks ~= y + cast(double) sample / samples;
        foreach (index; active)
        {
            const edge = edges[index];
            if (edge.y0 > y && edge.y0 < y + 1) breaks ~= edge.y0;
            if (edge.y1 > y && edge.y1 < y + 1) breaks ~= edge.y1;
        }
        breaks.sort();
        foreach (band; 1 .. breaks.length)
        {
            const weight = breaks[band] - breaks[band - 1];
            if (weight <= 0) continue;
            const yc = (breaks[band] + breaks[band - 1]) * 0.5;
            crossings.length = 0;
            foreach (index; active)
            {
                const edge = edges[index];
                if (yc < min(edge.y0, edge.y1) ||
                    yc >= max(edge.y0, edge.y1)) continue;
                const t = (yc - edge.y0) / (edge.y1 - edge.y0);
                crossings ~= Crossing(edge.x0 + t * (edge.x1 - edge.x0),
                    edge.y1 > edge.y0 ? 1 : -1);
            }
            crossings.sort!((a, b) => a.x < b.x);
            int winding;
            double left;
            foreach (crossing; crossings)
            {
                // Add every disjoint ink span, including multiple spans in
                // one pixel. Winding, rather than crossing parity, preserves
                // the union of overlapping same-direction contours.
                if (winding != 0)
                {
                    const right = min(cast(double) width, crossing.x);
                    const start = max(0.0, left);
                    if (right > start)
                    {
                        const first = cast(int) floor(start);
                        const last = cast(int) ceil(right);
                        foreach (x; first .. last)
                            coverage[x] += weight *
                                (min(right, x + 1.0) - max(start, cast(double) x));
                    }
                }
                winding += crossing.winding;
                left = crossing.x;
            }
        }
        foreach (x; 0 .. width)
            alpha[cast(size_t) y * width + x] =
                cast(ubyte) (min(1.0, max(0.0, coverage[x])) * 255.0 + 0.5);
    }
}

/// Experimental scan-conversion lattice for native-compatibility work.
/// Unlike area coverage, this counts samples and intentionally quantizes alpha.
void rasterizeSampledCoverage(const(OutlineEdge)[] edges, ubyte[] alpha,
    int width, int height, int samplesX, int samplesY, bool nativeEdges = false)
{
    assert(width >= 0 && height >= 0 && samplesX > 0 && samplesY > 0);
    assert(alpha.length == cast(size_t) width * height);
    if (nativeEdges)
    {
        rasterizeNativeSampledCoverage(edges, alpha, width, height, samplesX, samplesY);
        return;
    }
    alpha[] = 0;
    struct Crossing { double x; int winding; }
    Crossing[] crossings;
    int[] counts = new int[width];
    foreach (y; 0 .. height)
    {
        counts[] = 0;
        foreach (sy; 0 .. samplesY)
        {
            const yc = y + (sy + 0.5) / samplesY;
            crossings.length = 0;
            foreach (edge; edges)
            {
                if (yc < min(edge.y0, edge.y1) || yc >= max(edge.y0, edge.y1)) continue;
                const t = (yc - edge.y0) / (edge.y1 - edge.y0);
                crossings ~= Crossing(edge.x0 + t * (edge.x1 - edge.x0), edge.y1 > edge.y0 ? 1 : -1);
            }
            crossings.sort!((a, b) => a.x < b.x);
            int winding;
            double left;
            foreach (crossing; crossings)
            {
                if (winding != 0)
                {
                    const first = cast(int) ceil(max(0.0, min(cast(double) width, left)) * samplesX - 0.5);
                    const last = cast(int) ceil(max(0.0, min(cast(double) width, crossing.x)) * samplesX - 0.5);
                    foreach (sample; first .. last) counts[sample / samplesX]++;
                }
                winding += crossing.winding;
                left = crossing.x;
            }
        }
        const total = samplesX * samplesY;
        foreach (x; 0 .. width)
            alpha[cast(size_t) y * width + x] = cast(ubyte) ((counts[x] * 255 + total / 2) / total);
    }
}

/// Opt-in native edge experiment. Closing-edge ties are included, and exact
/// half-alpha quantization ties round down. Keep disjoint/overlapping spans a
/// union so a shared boundary never counts the same subpixel twice.
private void rasterizeNativeSampledCoverage(const(OutlineEdge)[] edges, ubyte[] alpha,
    int width, int height, int samplesX, int samplesY)
{
    alpha[] = 0;
    if (width == 0 || height == 0 || edges.length == 0) return;
    struct Crossing { double x; int winding; }
    Crossing[] crossings;
    int[] counts = new int[width];
    bool[] hits = new bool[cast(size_t) width * samplesX];
    foreach (y; 0 .. height)
    {
        counts[] = 0;
        foreach (sy; 0 .. samplesY)
        {
            hits[] = false;
            const yc = y + (sy + 0.5) / samplesY;
            crossings.length = 0;
            foreach (edge; edges)
            {
                if (yc < min(edge.y0, edge.y1) || yc >= max(edge.y0, edge.y1)) continue;
                crossings ~= Crossing(edge.xAtY(yc), edge.y1 > edge.y0 ? 1 : -1);
            }
            crossings.sort!((a, b) => a.x < b.x);
            int winding;
            double left;
            foreach (crossing; crossings)
            {
                const previous = winding;
                winding += crossing.winding;
                if (previous == 0 && winding != 0) left = crossing.x;
                if (previous != 0 && winding == 0)
                {
                    const start = max(0.0, min(cast(double) width, left));
                    const stop = max(0.0, min(cast(double) width, crossing.x));
                    if (stop <= start) continue;
                    const first = max(0, cast(int) ceil(start * samplesX - 0.5));
                    const last = min(width * samplesX, cast(int) floor(stop * samplesX - 0.5) + 1);
                    foreach (sample; first .. last) hits[sample] = true;
                }
            }
            foreach (sample, covered; hits)
                if (covered) ++counts[sample / samplesX];
        }
        const total = samplesX * samplesY;
        foreach (x; 0 .. width)
            alpha[cast(size_t) y * width + x] =
                cast(ubyte) ((counts[x] * 255 + (total - 1) / 2) / total);
    }
}

unittest
{
    import std.math : abs;
    const alignment = VerticalAlignment(6.5, 9.1);
    // An unhinted curve crossing every zone must preserve its original x at
    // each transformed height, including when the contour runs backwards.
    foreach (original; [OutlineEdge(0, 13, 4, 1, 3, 9, true),
                       OutlineEdge(4, 1, 0, 13, 3, 9, true)])
    {
        OutlineEdge[] edges = [original];
        int bearingY = 12, height = 14;
        alignVertically(edges, bearingY, height, alignment);
        assert(edges.length == 4);
        foreach (step; 1 .. 120)
        {
            const y = 1 + step / 10.0;
            const fitted = bearingY - alignment.fit(12 - y);
            bool found;
            foreach (edge; edges)
                if (fitted >= min(edge.y0, edge.y1) && fitted <= max(edge.y0, edge.y1))
                {
                    assert(abs(edge.xAtY(fitted) - original.xAtY(y)) < 1e-10);
                    found = true;
                }
            assert(found);
        }
    }
}

unittest
{
    import std.math : abs;
    // y=t^2 and x=t: invert both ascending and descending curves exactly.
    const curve = OutlineEdge(0, 0, 1, 1, 0.5, 0, true);
    const reverse = OutlineEdge(1, 1, 0, 0, 0.5, 0, true);
    foreach (y; [0.0, 0.0625, 0.25, 0.5625, 1.0])
    {
        assert(abs(curve.xAtY(y) - sqrt(y)) < 1e-12);
        assert(abs(reverse.xAtY(y) - sqrt(y)) < 1e-12);
    }
    // A closed curve whose endpoint y values coincide must still contribute
    // two crossings. Splitting at its extremum preserves both directions.
    OutlineEdge[] split;
    appendQuadraticEdges(OutlineEdge(0, 0, 2, 0, 1, 2, true), split);
    assert(split.length == 2 && split[0].x1 == 1 && split[0].y1 == 1);
    assert(split[1].x0 == split[0].x1 && split[1].y0 == split[0].y1);
    assert(abs(split[0].xAtY(0.75) - 0.5) < 1e-12);
    assert(abs(split[1].xAtY(0.75) - 1.5) < 1e-12);
    // Area bounded by x=y^2: the 4x4 lattice contains exactly six samples.
    OutlineEdge[] outline = [OutlineEdge(0, 0, 1, 1, 0, 0.5, true),
        OutlineEdge(1, 1, 0, 1), OutlineEdge(0, 1, 0, 0)];
    ubyte[] alpha = new ubyte[1];
    rasterizeSampledCoverage(outline, alpha, 1, 1, 4, 4, true);
    assert(alpha[0] == 96, "A quadratic must not be replaced by its endpoint chord");
}

unittest
{
    OutlineEdge[] box(double x0, double y0, double x1, double y1)
    {
        return [OutlineEdge(x0, y0, x1, y0), OutlineEdge(x1, y0, x1, y1),
            OutlineEdge(x1, y1, x0, y1), OutlineEdge(x0, y1, x0, y0)];
    }
    ubyte[] pixels = new ubyte[3];
    rasterizeSampledCoverage(box(0.125, 0, 0.375, 1), pixels, 3, 1, 4, 4);
    assert(pixels == [64, 0, 0], "Approved C retains its half-open closing edge");
    rasterizeSampledCoverage(box(0.125, 0, 0.375, 1), pixels, 3, 1, 4, 4, true);
    assert(pixels == [127, 0, 0], "Native closing-edge ties and half-alpha quantization");
    rasterizeSampledCoverage(box(0, 0, 0.125, 1), pixels, 3, 1, 4, 4, true);
    assert(pixels == [64, 0, 0]);
    rasterizeSampledCoverage(box(0.125, 0, 0.375, 1) ~ box(0.375, 0, 0.625, 1),
        pixels, 3, 1, 4, 4, true);
    assert(pixels == [191, 0, 0], "A shared sample boundary contributes only once");
    rasterizeSampledCoverage(box(0.125, 0, 0.125, 1), pixels, 3, 1, 4, 4, true);
    assert(pixels == [0, 0, 0], "Zero-width outlines must not acquire ink");
    rasterizeSampledCoverage(box(-2, -1, 2, 2) ~ box(0, 0, 2, 1), pixels, 3, 1, 4, 4, true);
    assert(pixels == [255, 255, 0], "Nonzero winding is a union, including clipped contours");
    rasterizeSampledCoverage(null, pixels, 3, 1, 4, 4, true);
    assert(pixels == [0, 0, 0]);
}

unittest
{
    OutlineEdge[] box(double x0, double y0, double x1, double y1)
    {
        return [OutlineEdge(x0, y0, x1, y0), OutlineEdge(x1, y0, x1, y1),
            OutlineEdge(x1, y1, x0, y1), OutlineEdge(x0, y1, x0, y0)];
    }
    ubyte[] pixels = new ubyte[3];
    rasterizeSampledCoverage(box(0.1875, 0, 1.234375, 1), pixels, 3, 1, 8, 1);
    assert(pixels == [223, 64, 0], "Sample-boundary ties must be deterministic");
    rasterizeSampledCoverage(box(0, 0, 0.5, 0.5), pixels, 3, 1, 4, 4);
    assert(pixels == [64, 0, 0]);
    auto overlap = box(-1, -1, 1, 2) ~ box(0, 0, 2, 1);
    rasterizeSampledCoverage(overlap, pixels, 3, 1, 4, 4);
    assert(pixels == [255, 255, 0], "Overlapping contours use nonzero winding");
    rasterizeSampledCoverage(null, pixels, 3, 1, 4, 4);
    assert(pixels == [0, 0, 0]);
}

unittest
{
    const alignment = VerticalAlignment(6.5, 9.1);
    assert(alignment.fit(0) == 0);
    assert(alignment.fit(6.5) == 7);
    assert(alignment.fit(9.1) == 9);
    assert(alignment.fit(-2.5) == -2.5);
    double previous = alignment.fit(-5);
    foreach (step; 1 .. 2001)
    {
        const next = alignment.fit(-5 + step * 0.01);
        assert(next > previous, "Alignment must never collapse or invert a stroke");
        previous = next;
    }
    assert(!VerticalAlignment(6.6, 7.1).enabled(), "Merged target zones must be ignored");

    OutlineEdge[] rectangle(double x0, double y0, double x1, double y1)
    {
        return [OutlineEdge(x0, y0, x1, y0), OutlineEdge(x1, y0, x1, y1),
            OutlineEdge(x1, y1, x0, y1), OutlineEdge(x0, y1, x0, y0)];
    }
    ubyte[] alpha = new ubyte[1];
    foreach (quality; [0, 1, 4, 8, 100])
    {
        rasterizeCoverage(rectangle(0.25, 0.25, 0.75, 0.75), alpha, 1, 1, quality);
        assert(alpha[0] == 64, "Half-width, half-height rectangle has quarter area");
        rasterizeCoverage(rectangle(0, 0.01, 1, 0.06), alpha, 1, 1, quality);
        assert(alpha[0] == 13, "Thin horizontal stems must survive between samples");
    }
    rasterizeCoverage(rectangle(0.01, 0, 0.06, 1), alpha, 1, 1);
    assert(alpha[0] == 13, "Thin vertical stems retain fractional coverage");
    rasterizeCoverage(rectangle(0, 0, 0.25, 1) ~ rectangle(0.75, 0, 1, 1), alpha, 1, 1);
    assert(alpha[0] == 128, "Disjoint spans in a pixel accumulate");
    rasterizeCoverage(rectangle(0, 0, 0.75, 1) ~ rectangle(0.25, 0, 1, 1), alpha, 1, 1);
    assert(alpha[0] == 255, "Overlapping contours do not cut holes or double ink");
    rasterizeCoverage(rectangle(0, 0, 1, 1) ~ rectangle(0.75, 0.25, 0.25, 0.75), alpha, 1, 1);
    assert(alpha[0] == 191, "Opposite-direction counters remain open");
    rasterizeCoverage([OutlineEdge(0, 0, 1, 1), OutlineEdge(1, 1, 0, 1),
        OutlineEdge(0, 1, 0, 0)], alpha, 1, 1);
    assert(alpha[0] == 128, "Diagonal triangle conserves area");
    rasterizeCoverage(rectangle(-1, -1, 2, 2), alpha, 1, 1);
    assert(alpha[0] == 255, "Coverage is clipped to the bitmap");
    rasterizeCoverage(null, alpha, 1, 1);
    assert(alpha[0] == 0, "Reused output is cleared");
}

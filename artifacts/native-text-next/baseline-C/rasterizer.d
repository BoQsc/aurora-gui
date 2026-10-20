module aurora.text.rasterizer;

import std.algorithm : min, max;
import std.algorithm.sorting : sort;
import std.math : ceil, floor;

/// A directed outline segment in bitmap pixel coordinates (y points down).
struct OutlineEdge
{
    double x0, y0, x1, y1;
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

/// Fit flattened edges, then recompute bounds so aligned tops cannot clip.
void alignVertically(ref OutlineEdge[] edges, ref int bearingY,
    ref int height, VerticalAlignment alignment)
{
    if (!alignment.enabled() || edges.length == 0) return;
    double minY = double.infinity, maxY = -double.infinity;
    foreach (ref edge; edges)
    {
        edge.y0 = alignment.fit(bearingY - edge.y0);
        edge.y1 = alignment.fit(bearingY - edge.y1);
        minY = min(minY, min(edge.y0, edge.y1));
        maxY = max(maxY, max(edge.y0, edge.y1));
    }
    bearingY = cast(int) ceil(maxY);
    height = max(0, bearingY - cast(int) floor(minY));
    foreach (ref edge; edges)
    {
        edge.y0 = bearingY - edge.y0;
        edge.y1 = bearingY - edge.y1;
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
    breaks.reserve(edges.length * 2 + samples + 1);
    crossings.reserve(edges.length);
    foreach (y; 0 .. height)
    {
        coverage[] = 0;
        breaks.length = 0;
        foreach (sample; 0 .. samples + 1)
            breaks ~= y + cast(double) sample / samples;
        foreach (edge; edges)
        {
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
            foreach (edge; edges)
            {
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
    int width, int height, int samplesX, int samplesY)
{
    assert(width >= 0 && height >= 0 && samplesX > 0 && samplesY > 0);
    assert(alpha.length == cast(size_t) width * height);
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

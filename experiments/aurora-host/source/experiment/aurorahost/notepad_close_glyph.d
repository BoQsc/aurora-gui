module experiment.aurorahost.notepad_close_glyph;

import aurora.image : RgbaImage;
import std.math : sqrt;

private double distanceToSegment(double px, double py, double ax, double ay,
    double bx, double by)
{
    const dx = bx - ax;
    const dy = by - ay;
    const lengthSquared = dx * dx + dy * dy;
    double t = lengthSquared == 0 ? 0 :
        ((px - ax) * dx + (py - ay) * dy) / lengthSquared;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    const qx = ax + t * dx - px;
    const qy = ay + t * dy - py;
    return sqrt(qx * qx + qy * qy);
}

/**
 * Rasterize the caption close mark at physical resolution. The two crossing
 * strokes are supersampled so the mark stays sharp at 125% and 150% DPI
 * instead of becoming a jagged logical-pixel diagonal.
 */
RgbaImage renderCloseGlyph(int size)
{
    const samples = 8;
    // Center the crossing on a pixel at both even and odd physical sizes.
    // Even sizes use pixel boundaries (0 .. size-1); odd sizes use pixel
    // centers (0.5 .. size-0.5). The 2 px stroke intentionally fills a 3x3
    // center at 100% DPI.
    const start = (size & 1) == 0 ? 0.0 : 0.5;
    const end = start + size - 1;
    // 1.3 px at 100% DPI is the middle ground between the native 1 px stroke
    // and the 1.5 px mark that still read as bold. The width scales to 1.5 px
    // at 150% so the mark keeps its weight without becoming a block.
    const scaledWidth = size * 0.05;
    const halfWidth = scaledWidth < 0.65 ? 0.65 : scaledWidth;
    auto pixels = new ubyte[size * size * 4];
    foreach (y; 0 .. size)
    {
        foreach (x; 0 .. size)
        {
            uint covered;
            foreach (sy; 0 .. samples)
            {
                foreach (sx; 0 .. samples)
                {
                    const px = x + (sx + 0.5) / samples;
                    const py = y + (sy + 0.5) / samples;
                    if (distanceToSegment(px, py, start, start, end, end) <=
                            halfWidth ||
                        distanceToSegment(px, py, end, start, start, end) <=
                            halfWidth)
                        ++covered;
                }
            }
            const offset = (y * size + x) * 4;
            pixels[offset] = 255;
            pixels[offset + 1] = 255;
            pixels[offset + 2] = 255;
            // Keep the solid diagonal core while suppressing the broad
            // low-coverage fringe that read as a shadow beside the axis-
            // aligned minimize and maximize strokes. The smoothstep keeps
            // the remaining antialiased edge from becoming a hard staircase.
            const coverage = covered / cast(double) (samples * samples);
            // Reject the pale fringe: this keeps the 1.5 px geometry but
            // makes its antialiased edge read as ink rather than haze.
            const lowCoverage = 0.20;
            const highCoverage = 0.95;
            double ramp = (coverage - lowCoverage) /
                (highCoverage - lowCoverage);
            ramp = ramp < 0 ? 0 : ramp > 1 ? 1 : ramp;
            const alpha = ramp * ramp * (3 - 2 * ramp);
            pixels[offset + 3] = cast(ubyte) (alpha * 255 + 0.5);
        }
    }
    return new RgbaImage(size, size, pixels);
}
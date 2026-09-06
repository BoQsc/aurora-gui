module aurora.pointer;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.surface : Surface;
import aurora.types : CursorKind, Point, PointF, Rect, Size, clampInt, maxInt,
    minInt;
import std.algorithm.sorting : sort;

/**
 * Aurora-rendered system cursors with the Windows 10 look.
 *
 * The native host cursor and the composited drag pointer never match: the OS
 * cursor is a real aero asset while the old drag pointer was a rough
 * two-triangle sketch, so every drag visibly swapped cursor styles. This
 * module draws faithful Windows-10-style reproductions of all nine cursor
 * kinds through Aurora's own canvas, so the synchronized pointer layer can
 * show the same artwork the native cursor shows.
 *
 * Everything is drawn inside a 40x40 logical box with the cursor hotspot at
 * `systemCursorHotspot(kind)`; the compositor positions the pointer layer at
 * the live pointer position minus that hotspot, so the tip lands exactly on
 * the pointer in both modes. The single analytic-coverage polygon filler
 * below keeps edges smooth in immediate and retained (draw-list) modes alike.
 */

/// Logical extent of every cursor bitmap. Hotspot is always inside it.
enum Size systemCursorSize = Size(40, 40);

/** Hotspot of each cursor inside the 40x40 box. */
Point systemCursorHotspot(CursorKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case CursorKind.arrow:
            return Point(3, 2);
        case CursorKind.hand:
            return Point(15, 4);
        case CursorKind.text:
        case CursorKind.resizeHorizontal:
        case CursorKind.resizeVertical:
        case CursorKind.resizeDiagonalNWSE:
        case CursorKind.resizeDiagonalNESW:
        case CursorKind.move:
        case CursorKind.forbidden:
            return Point(20, 20);
    }
}

private Color cursorOutline() @safe pure nothrow @nogc
{
    return Color.rgb(0, 0, 0);
}

private Color cursorFill() @safe pure nothrow @nogc
{
    return Color.rgb(255, 255, 255);
}

private Color cursorDanger() @safe pure nothrow @nogc
{
    return Color.rgb(232, 17, 35);
}

/**
 * Fill an arbitrary simple polygon with analytic per-pixel coverage.
 * Even-odd rule; edge pixels get fractional alpha so diagonals stay smooth.
 */
private void fillPoly(ref Canvas canvas, const(PointF)[] points, Color color)
{
    if (points.length < 3 || color.a == 0) return;
    double minX = points[0].x;
    double maxX = points[0].x;
    double minY = points[0].y;
    double maxY = points[0].y;
    foreach (point; points[1 .. $])
    {
        if (point.x < minX) minX = point.x;
        if (point.x > maxX) maxX = point.x;
        if (point.y < minY) minY = point.y;
        if (point.y > maxY) maxY = point.y;
    }
    // The clip rect lives in surface/draw-list coordinates while the polygon
    // is in canvas-local ones; convert once so translated canvases clip right.
    const origin = canvas.toSurface(Point(0, 0));
    const clip = canvas.clipRect();
    const clipX0 = clip.x - origin.x;
    const clipX1 = clip.right() - origin.x;
    const clipY0 = clip.y - origin.y;
    const clipY1 = clip.bottom() - origin.y;
    int yStart = maxInt(clipY0, cast(int) minY);
    if (cast(double) yStart + 1.0 <= minY) ++yStart;
    int yEnd = minInt(clipY1, cast(int) maxY + 1);
    if (yStart >= yEnd) return;

    double[16] crossings;
    foreach (y; yStart .. yEnd)
    {
        const centerY = cast(double) y + 0.5;
        size_t count;
        foreach (i; 0 .. points.length)
        {
            const a = points[i];
            const b = points[(i + 1) % points.length];
            if ((a.y <= centerY) == (b.y <= centerY)) continue;
            const x = a.x + (centerY - a.y) / (b.y - a.y) * (b.x - a.x);
            if (count < crossings.length)
                crossings[count++] = x;
        }
        sort(crossings[0 .. count]);
        size_t pair = 0;
        while (pair + 1 < count)
        {
            double x0 = crossings[pair];
            double x1 = crossings[pair + 1];
            pair += 2;
            if (x1 <= x0) continue;
            if (x0 < clipX0) x0 = clipX0;
            if (x1 > clipX1) x1 = clipX1;
            if (x1 <= x0) continue;
            const leftPixel = cast(int) x0;
            const rightPixel = cast(int) (x1 - 1e-9);
            if (leftPixel == rightPixel)
            {
                emitRun(canvas, y, leftPixel, leftPixel, x0, x1, color);
            }
            else
            {
                emitRun(canvas, y, leftPixel, leftPixel, x0, x1, color);
                if (rightPixel > leftPixel + 1)
                    emitRun(canvas, y, leftPixel + 1, rightPixel - 1, x0, x1,
                        color);
                emitRun(canvas, y, rightPixel, rightPixel, x0, x1, color);
            }
        }
    }
}

private void emitRun(ref Canvas canvas, int y, int fromX, int toX, double x0,
    double x1, Color color)
{
    if (toX < fromX) return;
    double coverage;
    if (fromX == toX)
    {
        const lo = x0 > fromX ? x0 : fromX;
        const hi = x1 < fromX + 1.0 ? x1 : fromX + 1.0;
        coverage = hi > lo ? hi - lo : 0.0;
    }
    else
    {
        coverage = 1.0;
    }
    if (coverage <= 0.0) return;
    if (coverage > 1.0) coverage = 1.0;
    const alpha = cast(int) (color.a * coverage + 0.5);
    if (alpha <= 0) return;
    canvas.fillRect(Rect(fromX, y, toX - fromX + 1, 1),
        Color.rgba(color.r, color.g, color.b, clampInt(alpha, 0, 255)));
}

private void fillTriangle(ref Canvas canvas, PointF a, PointF b, PointF c,
    Color color)
{
    PointF[3] points = [a, b, c];
    fillPoly(canvas, points[], color);
}

/** Draw `kind` with its hotspot at `hot`, both in canvas-local coordinates. */
private void drawCursorAt(ref Canvas canvas, CursorKind kind, Point hot)
{
    const outline = cursorOutline();
    const fill = cursorFill();
    const danger = cursorDanger();
    const hx = cast(double) hot.x;
    const hy = cast(double) hot.y;
    final switch (kind)
    {
        case CursorKind.arrow:
        {
            // Classic Windows arrow silhouette, tip at the hotspot.
            PointF[] outer = [
                PointF(hx, hy), PointF(hx, hy + 20),
                PointF(hx + 5, hy + 15), PointF(hx + 7, hy + 22),
                PointF(hx + 10, hy + 21), PointF(hx + 8, hy + 14),
                PointF(hx + 13, hy + 14),
            ];
            fillPoly(canvas, outer, outline);
            // White interior: the outline shrunk about the tip.
            PointF[] inner = [
                PointF(hx + 1.0, hy + 1.0),
                PointF(hx + 1.0, hy + 16.6),
                PointF(hx + 4.9, hy + 12.9),
                PointF(hx + 6.4, hy + 18.2),
                PointF(hx + 8.3, hy + 17.5),
                PointF(hx + 7.0, hy + 12.9),
                PointF(hx + 10.8, hy + 12.9),
            ];
            fillPoly(canvas, inner, fill);
            break;
        }
        case CursorKind.hand:
        {
            // Pointing hand: fingertip at the hotspot, palm below-right.
            // Each white part gets a 1 px black backing for the outline.
            auto finger = (int x0, int y0, int x1, int y1)
            {
                canvas.fillRoundedRect(Rect(x0 - 1, y0 - 1, x1 - x0 + 2,
                    y1 - y0 + 2), 3, outline);
                canvas.fillRoundedRect(Rect(x0, y0, x1 - x0, y1 - y0), 2, fill);
            };
            // Index finger (tallest, fingertip at hotspot).
            finger(cast(int) hx - 2, cast(int) hy, cast(int) hx + 1,
                cast(int) hy + 15);
            // Middle, ring, pinky stepping down to the right, with
            // outline gaps so the fingers read separately.
            finger(cast(int) hx + 3, cast(int) hy + 5, cast(int) hx + 6,
                cast(int) hy + 15);
            finger(cast(int) hx + 8, cast(int) hy + 7, cast(int) hx + 11,
                cast(int) hy + 15);
            finger(cast(int) hx + 13, cast(int) hy + 9, cast(int) hx + 15,
                cast(int) hy + 15);
            // Palm block.
            canvas.fillRoundedRect(Rect(cast(int) hx - 3, cast(int) hy + 14,
                21, 13), 4, outline);
            canvas.fillRoundedRect(Rect(cast(int) hx - 2, cast(int) hy + 15,
                19, 11), 3, fill);
            // Thumb wedge on the left edge of the palm.
            fillTriangle(canvas, PointF(hx - 3, hy + 26),
                PointF(hx - 9, hy + 18), PointF(hx - 3, hy + 17), outline);
            fillTriangle(canvas, PointF(hx - 4, hy + 24),
                PointF(hx - 8, hy + 19), PointF(hx - 4, hy + 18), fill);
            break;
        }
        case CursorKind.text:
        {
            // I-beam: dark stem with a light core, capped by serif bars.
            canvas.fillRect(Rect(cast(int) hx - 2, cast(int) hy - 14, 4, 28),
                outline);
            canvas.fillRect(Rect(cast(int) hx - 1, cast(int) hy - 13, 2, 26),
                fill);
            canvas.fillRect(Rect(cast(int) hx - 6, cast(int) hy - 14, 12, 3),
                outline);
            canvas.fillRect(Rect(cast(int) hx - 5, cast(int) hy - 14, 10, 1),
                fill);
            canvas.fillRect(Rect(cast(int) hx - 6, cast(int) hy + 11, 12, 3),
                outline);
            canvas.fillRect(Rect(cast(int) hx - 5, cast(int) hy + 12, 10, 1),
                fill);
            break;
        }
        case CursorKind.resizeHorizontal:
            drawDoubleArrow(canvas, hot, 1, 0);
            break;
        case CursorKind.resizeVertical:
            drawDoubleArrow(canvas, hot, 0, 1);
            break;
        case CursorKind.resizeDiagonalNWSE:
            drawDoubleArrow(canvas, hot, 1, 1);
            break;
        case CursorKind.resizeDiagonalNESW:
            drawDoubleArrow(canvas, hot, -1, 1);
            break;
        case CursorKind.move:
        {
            // Four-arrow cross with a solid center block.
            fillTriangle(canvas, PointF(hx, hy - 12), PointF(hx - 5, hy - 4),
                PointF(hx + 5, hy - 4), outline);
            fillTriangle(canvas, PointF(hx, hy - 10), PointF(hx - 3, hy - 5),
                PointF(hx + 3, hy - 5), fill);
            fillTriangle(canvas, PointF(hx, hy + 12), PointF(hx - 5, hy + 4),
                PointF(hx + 5, hy + 4), outline);
            fillTriangle(canvas, PointF(hx, hy + 10), PointF(hx - 3, hy + 5),
                PointF(hx + 3, hy + 5), fill);
            fillTriangle(canvas, PointF(hx - 12, hy), PointF(hx - 4, hy - 5),
                PointF(hx - 4, hy + 5), outline);
            fillTriangle(canvas, PointF(hx - 10, hy), PointF(hx - 5, hy - 3),
                PointF(hx - 5, hy + 3), fill);
            fillTriangle(canvas, PointF(hx + 12, hy), PointF(hx + 4, hy - 5),
                PointF(hx + 4, hy + 5), outline);
            fillTriangle(canvas, PointF(hx + 10, hy), PointF(hx + 5, hy - 3),
                PointF(hx + 5, hy + 3), fill);
            canvas.fillRect(Rect(cast(int) hx - 3, cast(int) hy - 3, 6, 6),
                outline);
            canvas.fillRect(Rect(cast(int) hx - 2, cast(int) hy - 2, 4, 4),
                fill);
            break;
        }
        case CursorKind.forbidden:
        {
            // Red ring with a diagonal bar, like the Windows "no" cursor.
            canvas.strokeCircle(Point(cast(int) hx, cast(int) hy), 11, danger, 3);
            const inv = 0.70710678;
            const hw = 1.6;
            const x0 = hx - 8 * inv;
            const y0 = hy + 8 * inv;
            const x1 = hx + 8 * inv;
            const y1 = hy - 8 * inv;
            PointF[] bar = [
                PointF(x0 + hw * inv, y0 + hw * inv),
                PointF(x1 + hw * inv, y1 + hw * inv),
                PointF(x1 - hw * inv, y1 - hw * inv),
                PointF(x0 - hw * inv, y0 - hw * inv),
            ];
            fillPoly(canvas, bar, danger);
            break;
        }
    }
}

private void drawDoubleArrow(ref Canvas canvas, Point hot, int dx, int dy)
{
    const outline = cursorOutline();
    const fill = cursorFill();
    const hx = cast(double) hot.x;
    const hy = cast(double) hot.y;
    if (dx != 0 && dy != 0)
    {
        // Diagonal shaft as a rotated bar polygon.
        const inv = 0.70710678;
        const nx = dy * inv;
        const ny = -dx * inv;
        const ax = hx - 9 * dx * inv * 1.41421356;
        const ay = hy - 9 * dy * inv * 1.41421356;
        const bx = hx + 9 * dx * inv * 1.41421356;
        const by = hy + 9 * dy * inv * 1.41421356;
        PointF[] shaft = [
            PointF(ax + nx * 1.6, ay + ny * 1.6),
            PointF(bx + nx * 1.6, by + ny * 1.6),
            PointF(bx - nx * 1.6, by - ny * 1.6),
            PointF(ax - nx * 1.6, ay - ny * 1.6),
        ];
        fillPoly(canvas, shaft, outline);
        PointF[] core = [
            PointF(ax + nx * 0.6, ay + ny * 0.6),
            PointF(bx + nx * 0.6, by + ny * 0.6),
            PointF(bx - nx * 0.6, by - ny * 0.6),
            PointF(ax - nx * 0.6, ay - ny * 0.6),
        ];
        fillPoly(canvas, core, fill);
        // Arrowheads at both shaft ends, pointing outward.
        drawDiagonalHead(canvas, ax, ay, -dx, -dy, outline, fill);
        drawDiagonalHead(canvas, bx, by, dx, dy, outline, fill);
        return;
    }
    if (dx != 0)
    {
        canvas.fillRect(Rect(cast(int) hx - 9, cast(int) hy - 1, 18, 3),
            outline);
        canvas.fillRect(Rect(cast(int) hx - 9, cast(int) hy, 18, 1), fill);
        const s = dx > 0 ? 1.0 : -1.0;
        fillTriangle(canvas, PointF(hx - 11 * s, hy), PointF(hx - 3 * s, hy - 6),
            PointF(hx - 3 * s, hy + 6), outline);
        fillTriangle(canvas, PointF(hx - 9 * s, hy), PointF(hx - 3 * s, hy - 4),
            PointF(hx - 3 * s, hy + 4), fill);
        fillTriangle(canvas, PointF(hx + 11 * s, hy), PointF(hx + 3 * s, hy - 6),
            PointF(hx + 3 * s, hy + 6), outline);
        fillTriangle(canvas, PointF(hx + 9 * s, hy), PointF(hx + 3 * s, hy - 4),
            PointF(hx + 3 * s, hy + 4), fill);
        return;
    }
    canvas.fillRect(Rect(cast(int) hx - 1, cast(int) hy - 9, 3, 18), outline);
    canvas.fillRect(Rect(cast(int) hx, cast(int) hy - 9, 1, 18), fill);
    const s = dy > 0 ? 1.0 : -1.0;
    fillTriangle(canvas, PointF(hx, hy - 11 * s), PointF(hx - 6, hy - 3 * s),
        PointF(hx + 6, hy - 3 * s), outline);
    fillTriangle(canvas, PointF(hx, hy - 9 * s), PointF(hx - 4, hy - 3 * s),
        PointF(hx + 4, hy - 3 * s), fill);
    fillTriangle(canvas, PointF(hx, hy + 11 * s), PointF(hx - 6, hy + 3 * s),
        PointF(hx + 6, hy + 3 * s), outline);
    fillTriangle(canvas, PointF(hx, hy + 9 * s), PointF(hx - 4, hy + 3 * s),
        PointF(hx + 4, hy + 3 * s), fill);
}

private void drawDiagonalHead(ref Canvas canvas, double ex, double ey, int dx,
    int dy, Color outline, Color fill)
{
    const inv = 0.70710678;
    const ux = dx * inv;
    const uy = dy * inv;
    const nx = -uy;
    const ny = ux;
    const tx = ex + ux * 2.5;
    const ty = ey + uy * 2.5;
    PointF[] outer = [
        PointF(tx, ty),
        PointF(ex + nx * 6 - ux * 4, ey + ny * 6 - uy * 4),
        PointF(ex - nx * 6 - ux * 4, ey - ny * 6 - uy * 4),
    ];
    fillPoly(canvas, outer, outline);
    PointF[] inner = [
        PointF(ex + ux * 2.0, ey + uy * 2.0),
        PointF(ex + nx * 4 - ux * 3, ey + ny * 4 - uy * 3),
        PointF(ex - nx * 4 - ux * 3, ey - ny * 4 - uy * 3),
    ];
    fillPoly(canvas, inner, fill);
}

/**
 * Draws `kind` into the 40x40 cursor box with its hotspot at
 * `systemCursorHotspot(kind)`. The compositor positions the pointer layer at
 * the live pointer position minus that hotspot, so the tip lands exactly on
 * the pointer.
 */
void drawSystemCursor(ref Canvas canvas, CursorKind kind)
{
    const hot = systemCursorHotspot(kind);
    auto shifted = canvas.translated(hot.x, hot.y);
    drawCursorAt(shifted, kind, Point(0, 0));
}

unittest
{
    // Every cursor must paint visible ink, and the arrow hotspot corner must
    // stay inside the artwork (tip at the hotspot, body to the bottom-right).
    // NOTE: Surface starts opaque black, so clear to transparent first.
    foreach (kind; [CursorKind.arrow, CursorKind.hand, CursorKind.text,
        CursorKind.resizeHorizontal, CursorKind.resizeVertical,
        CursorKind.resizeDiagonalNWSE, CursorKind.resizeDiagonalNESW,
        CursorKind.move, CursorKind.forbidden])
    {
        auto surface = new Surface(40, 40);
        surface.clear(Color.rgba(0, 0, 0, 0));
        auto canvas = Canvas(surface);
        drawSystemCursor(canvas, kind);
        int ink;
        foreach (pixel; surface.pixels())
            if ((pixel & 0xff000000) != 0) ++ink;
        assert(ink > 60, "cursor has no ink");
        assert(ink < 1500, "cursor overpaints the box");
    }

    // The arrow tip sits at its hotspot with ink extending down-right only.
    {
        auto surface = new Surface(40, 40);
        surface.clear(Color.rgba(0, 0, 0, 0));
        auto canvas = Canvas(surface);
        drawSystemCursor(canvas, CursorKind.arrow);
        int upperLeft;
        int lowerRight;
        foreach (y; 0 .. 40) foreach (x; 0 .. 40)
        {
            if ((surface.pixels()[y * 40 + x] & 0xff000000) == 0) continue;
            if (x < 20 && y < 20) ++upperLeft;
            else if (x >= 20 && y >= 20) ++lowerRight;
        }
        assert(upperLeft > lowerRight * 3, "arrow ink must cluster top-left");
    }

    // The forbidden cursor must contain red ring pixels.
    {
        auto surface = new Surface(40, 40);
        surface.clear(Color.rgba(0, 0, 0, 0));
        auto canvas = Canvas(surface);
        drawSystemCursor(canvas, CursorKind.forbidden);
        int red;
        foreach (pixel; surface.pixels())
        {
            const r = (pixel >> 16) & 0xff;
            const g = (pixel >> 8) & 0xff;
            const b = pixel & 0xff;
            if ((pixel & 0xff000000) != 0 && r > 150 && g < 110 && b < 110)
                ++red;
        }
        assert(red > 40, "forbidden cursor must show a red ring");
    }
}

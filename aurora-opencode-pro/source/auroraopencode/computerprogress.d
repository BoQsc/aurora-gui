module auroraopencode.computerprogress;

import std.algorithm : min;

/// A coarse RGB grid suppresses cursor movement, JPEG noise and small animated
/// objects. It measures visible change, never whether an intended task succeeded.
struct DesktopObservation
{
    enum columns = 96, rows = 54;
    int width, height;
    ubyte[columns * rows * 3] cells;
    bool valid;
}

DesktopObservation observeDesktop(int width, int height, in ubyte[] rgb)
{
    DesktopObservation result;
    if (width <= 0 || height <= 0 ||
        rgb.length != cast(size_t) width * height * 3) return result;
    result.width = width;
    result.height = height;
    result.valid = true;
    foreach (gy; 0 .. result.rows)
        foreach (gx; 0 .. result.columns)
        {
            uint[3] sum;
            // Sixteen samples per cell; bounded work even on a 4K desktop.
            foreach (sy; 0 .. 4)
                foreach (sx; 0 .. 4)
                {
                    const x = min(width - 1,
                        (gx * 8 + sx * 2 + 1) * width / (result.columns * 8));
                    const y = min(height - 1,
                        (gy * 8 + sy * 2 + 1) * height / (result.rows * 8));
                    const p = (cast(size_t) y * width + x) * 3;
                    foreach (c; 0 .. 3) sum[c] += rgb[p + c];
                }
            foreach (c; 0 .. 3)
                result.cells[(gy * result.columns + gx) * 3 + c] = cast(ubyte)(sum[c] / 16);
        }
    return result;
}

bool desktopVisiblyChanged(in DesktopObservation a, in DesktopObservation b)
{
    if (!a.valid || !b.valid || a.width != b.width || a.height != b.height)
        return true; // Missing evidence must never justify suppressing input.
    int changed, edgeChanged;
    foreach (cell; 0 .. a.columns * a.rows)
    {
        int delta;
        foreach (c; 0 .. 3)
        {
            const d = cast(int) a.cells[cell * 3 + c] - b.cells[cell * 3 + c];
            delta += d < 0 ? -d : d;
        }
        if (delta < 24) continue;
        ++changed;
        const row = cell / a.columns;
        const column = cell % a.columns;
        if ((row < a.rows / 10 && column < a.columns * 4 / 5) ||
            (row >= a.rows * 3 / 4 && row < a.rows - 2)) ++edgeChanged;
    }
    // Dialogue and selection panels can change while most of the scene stays
    // still. Exclude corner button hover effects and the taskbar clock from this
    // more sensitive check; broader changes anywhere still count above.
    return changed >= 104 || edgeChanged >= 16;
}

struct DesktopClickProgress
{
    private size_t target;
    private int anchorX, anchorY, attempts;
    private bool virtualMode;
    private uint button;
    private bool recoveryOffered, recoveryRetry;
    private DesktopObservation after;

    void reset() { this = typeof(this).init; }

    private bool sameArea(size_t window, bool mode, int x, int y, uint mouseButton) const
    {
        const dx = cast(long) x - anchorX;
        const dy = cast(long) y - anchorY;
        return target == window && virtualMode == mode && button == mouseButton &&
            dx * dx + dy * dy <= 240L * 240L;
    }

    bool refuses(size_t window, bool mode, int x, int y,
        in DesktopObservation before, uint mouseButton = 0)
    {
        if (!sameArea(window, mode, x, y, mouseButton) || desktopVisiblyChanged(after, before))
            reset();
        if (attempts >= 3 && recoveryRetry)
        {
            recoveryRetry = false;
            return false;
        }
        return attempts >= 3;
    }

    /// Focused evidence permits one retry per stalled cluster, not a reset on
    /// every repeated refusal. A changed state or approach starts a new cluster.
    bool offerFocusedRecovery()
    {
        if (recoveryOffered) return false;
        recoveryOffered = recoveryRetry = true;
        return true;
    }

    void record(size_t window, bool mode, int x, int y,
        in DesktopObservation before, in DesktopObservation current, uint mouseButton = 0)
    {
        if (!sameArea(window, mode, x, y, mouseButton))
        {
            reset();
            target = window;
            virtualMode = mode;
            button = mouseButton;
            anchorX = x;
            anchorY = y;
        }
        attempts = desktopVisiblyChanged(before, current) ? 0 : attempts + 1;
        after = current;
    }
}

/// Repeated drags can move scenery in the wrong direction. Require explicit
/// re-grounding after three in the same direction, even when pixels change.
struct DesktopDragProgress
{
    private DesktopClickProgress sequence;

    void reset() { sequence.reset(); }

    private uint approach(int x, int y, int x2, int y2, uint button) const
    {
        const dx = cast(long) x2 - x, dy = cast(long) y2 - y;
        const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
        const horizontal = ax >= ay * 2 ? (dx >= 0 ? 1 : 2) : 0;
        const vertical = ay >= ax * 2 ? (dy >= 0 ? 3 : 4) : 0;
        const direction = horizontal ? horizontal : vertical ? vertical :
            5 + (dx < 0 ? 2 : 0) + (dy < 0 ? 1 : 0);
        return button * 16 + direction;
    }

    private DesktopObservation stable() const
    {
        DesktopObservation result;
        result.valid = true;
        result.width = result.height = 1;
        return result;
    }

    bool refuses(size_t window, bool mode, int x, int y, int x2, int y2, uint button)
    {
        return sequence.refuses(window, mode, 0, 0, stable(), approach(x, y, x2, y2, button));
    }

    void record(size_t window, bool mode, int x, int y, int x2, int y2, uint button)
    {
        sequence.record(window, mode, 0, 0, stable(), stable(), approach(x, y, x2, y2, button));
    }

    bool offerFocusedRecovery() { return sequence.offerFocusedRecovery(); }
}

struct DesktopRegion
{
    int x, y, width, height;
    ubyte[] rgb;
}

/// Copy from the same native capture used for the refusal. Origin and dimensions
/// describe the actual clamped crop, so coordinate mapping stays unambiguous.
DesktopRegion cropDesktop(int width, int height, in ubyte[] rgb,
    int x, int y, int w, int h)
{
    DesktopRegion region;
    if (width <= 0 || height <= 0 || w <= 0 || h <= 0 ||
        rgb.length != cast(size_t) width * height * 3) return region;
    region.x = x < 0 ? 0 : min(x, width - 1);
    region.y = y < 0 ? 0 : min(y, height - 1);
    region.width = min(w, width - region.x);
    region.height = min(h, height - region.y);
    region.rgb.length = cast(size_t) region.width * region.height * 3;
    foreach (row; 0 .. region.height)
    {
        const src = (cast(size_t)(region.y + row) * width + region.x) * 3;
        const dst = cast(size_t) row * region.width * 3;
        region.rgb[dst .. dst + region.width * 3] = rgb[src .. src + region.width * 3];
    }
    return region;
}

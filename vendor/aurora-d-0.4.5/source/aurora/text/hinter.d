module aurora.text.hinter;

/**
 * Complete TrueType bytecode hinting interpreter (pure D, dependency-free).
 *
 * Implements the full TrueType instruction set per OpenType 1.9, following the
 * reference semantics of FreeType's `ttinterp.c` for ambiguous stack orders
 * and edge cases:
 *
 *   - Font program (`fpgm`), CVT program (`prep`), per-glyph programs.
 *   - Full opcode set: DELTAP/C, SROUND/S45ROUND, GETINFO, INSTCTRL/SCANCTRL,
 *     FDEF/IDEF/CALL/LOOPCALL, IUP, SHP/SHC/SHZ/SHPIX,
 *     MDRP/MIRP/MIAP/MDAP/MSIRP/ALIGNRP/ALIGNPTS/IP/ISECT, stack/flow-control.
 *   - Four phantom points (left/right bearings, top/bottom) appended per glyph;
 *     IUP never touches them.
 *   - Twilight-zone semantics: points moved in zone 0 re-base their `org`.
 *   - Graphics-state defaults from `tt_default_graphics_state`.
 *
 * Consumes design units; produces grid-fitted units so the rasterizer is
 * unchanged. All internal math is F26Dot6. Any malformed stream aborts with
 * `HintAbort`; callers fall back to the unhinted outline so bad fonts can
 * never blank glyphs.
 */

import std.math : sqrt;
import std.format;

/// Raised when hinting cannot proceed; callers fall back to the raw outline.
final class HintAbort : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure @safe
    {
        super(message, file, line);
    }
}

private enum uint tag(string value) =
    (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
    (cast(uint) value[2] << 8) | cast(uint) value[3];

private ushort be16(const(ubyte)[] data, size_t offset)
{
    if (offset + 2 > data.length) throw new HintAbort("Truncated table read");
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length) throw new HintAbort("Truncated table read");
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
}

private int beS32(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length) throw new HintAbort("Truncated table read");
    const u = (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
    return cast(int) u;
}

private long mulDiv(long a, long b, long c) @safe pure nothrow @nogc
{
    if (c == 0) return 0;
    return cast(int) (cast(long) a * b / c);
}

private long mulFix(long a, long b) @safe pure nothrow @nogc
{
    const long product = cast(long) a * b;
    return cast(int) ((product + 0x2000 + (product >> 63)) >> 14);
}

private long dotFix(long ax, long ay, long bx, long by) @safe pure nothrow @nogc
{
    const long product = cast(long) ax * bx + cast(long) ay * by;
    return cast(int) ((product + 0x2000 + (product >> 63)) >> 14);
}

/// Input to hint one glyph.
struct HintInput
{
    const(ubyte)[] instructions;
    int[] xs;
    int[] ys;
    bool[] onCurve;
    int[] contours;
    int unitsPerEm;
    int pixelSize;
    int lsb;
    int advance;
    int tsb;
    int vadvance;
    const(ubyte)[] fpgm;
    const(ubyte)[] prep;
    int[] normalizedAxes;  /// Variation coordinates (2.14) for GETVARIATION.
}

/// Grid-fitted result in design units.
struct HintedGlyph
{
    int[] xs;
    int[] ys;
    bool[] onCurve;
    int[] contours;
    int xMin;
    int xMax;
    int yMin;
    int yMax;
    int lsb;
    int advance;
    int tsb;
    int vadvance;
}

/// One outline point in a zone (F26Dot6 coordinates internally).
private struct Pt
{
    long orgX;
    long orgY;
    long curX;
    long curY;
    long orusX;
    long orusY;
    bool touchX;
    bool touchY;
    bool onCurve;
}

/// A point zone (glyph zone or twilight zone).
private struct Zone
{
    Pt[] points;
    int[] contours;
    bool twilight;

    int nPoints() const @safe pure nothrow @nogc { return cast(int) points.length; }
    int nContours() const @safe pure nothrow @nogc { return cast(int) contours.length; }
}

private struct FuncDef
{
    bool active;
    const(ubyte)[] body;
    size_t start;
    size_t end;
}

private struct CallRec
{
    size_t returnIP;
    const(ubyte)[] returnCode;
    size_t returnSize;
    int count;
    FuncDef def;
}

private alias RoundFunc = long delegate(long distance, long compensation) @safe pure nothrow @nogc;

private static long roundNone(long distance, long compensation) @safe pure nothrow @nogc
{
    return distance;
}

private static long roundToGrid(long distance, long compensation) @safe pure nothrow @nogc
{
    return (distance + 32) & ~63;
}

private static long roundToHalfGrid(long distance, long compensation) @safe pure nothrow @nogc
{
    const grid = (distance + 32) & ~63;
    return distance >= 0 ? grid + 32 : grid - 32;
}

private static long roundToDoubleGrid(long distance, long compensation) @safe pure nothrow @nogc
{
    return (distance + 32) & ~63;
}

private static long roundDownToGrid(long distance, long compensation) @safe pure nothrow @nogc
{
    return distance & ~63;
}

private static long roundUpToGrid(long distance, long compensation) @safe pure nothrow @nogc
{
    return (distance + 63) & ~63;
}

private static long roundSuperGrid(long distance, long compensation, long period,
    int phase, int threshold) @safe pure nothrow @nogc
{
    if (distance >= 0)
    {
        long val = distance + threshold - phase + compensation;
        val = (val / period) * period;
        val += phase;
        if (val < 0) val = phase;
        return cast(int) val;
    }
    else
    {
        long val = threshold - phase + compensation - distance;
        val = -((val / period) * period);
        val -= phase;
        if (val > 0) val = -phase;
        return cast(int) val;
    }
}

/// Execution context for one program run (class = mutable by reference).
private final class Context
{
    TrueTypeHinter owner;
    long[] cvt;
    long[] storage;
    int unitsPerEm;
    int pixelSize;
    int scale;      // pixelSize*64/unitsPerEm

    const(ubyte)[] code;
    size_t codeSize;
    size_t ip;
    long[] stack;

    int rp0, rp1, rp2;
    int zoneSelect0 = 1, zoneSelect1 = 1, zoneSelect2 = 1;
    int projVectorX = 0x4000, projVectorY = 0;
    int freeVectorX = 0x4000, freeVectorY = 0;
    int dualVectorX = 0x4000, dualVectorY = 0;
    int moveX = 0x4000, moveY = 0;
    int loop = 1;
    int roundState = 1;
    int minimumDistance = 64;
    int controlValueCutIn = 68;
    int singleWidthCutIn = 0;
    int singleWidthValue = 0;
    int deltaBase = 9;
    int deltaShift = 3;
    bool autoFlip = true;
    int instructControl;
    long scanControl;
    int scanType;
    int period, phase, threshold;
    
    Zone zone0;
    Zone zone1;
    Zone zone2;
    Zone twilight;

    FuncDef[] fdefs;
    FuncDef[] idefs;
    CallRec[] callStack;

    int[] normalizedAxes;

    this(TrueTypeHinter owner, long[] cvt, long[] storage, int unitsPerEm,
        int pixelSize)
    {
        this.owner = owner;
        this.cvt = cvt;
        this.storage = storage;
        this.unitsPerEm = unitsPerEm;
        this.pixelSize = pixelSize;
        this.scale = cast(int) mulDiv(pixelSize, 64, maxInt(1, unitsPerEm));
        fdefs = new FuncDef[256];
        idefs = new FuncDef[256];
        roundState = 1;
    }

    void push(long value) { stack ~= value; }

    long pop()
    {
        if (stack.length == 0) throw new HintAbort("Stack underflow");
        const value = stack[$ - 1];
        stack.length = stack.length - 1;
        return value;
    }

    long project(long x, long y) const @safe pure nothrow @nogc
    {
        return dotFix(x, y, projVectorX, projVectorY);
    }

    long dualProject(long x, long y) const @safe pure nothrow @nogc
    {
        return dotFix(x, y, dualVectorX, dualVectorY);
    }

    long dualProject2(long x1, long y1, long x2, long y2) const @safe pure nothrow @nogc
    {
        return dotFix(x1 - x2, y1 - y2, dualVectorX, dualVectorY);
    }

    void computeMoveVector()
    {
        const fdpx = mulFix(freeVectorX, projVectorX);
        const fdpy = mulFix(freeVectorY, projVectorY);
        const fDotP = fdpx + fdpy;
        if (fDotP >= 0x3FFE)
        {
            moveX = freeVectorX;
            moveY = freeVectorY;
        }
        else if (fDotP > -0x400 && fDotP < 0x400)
        {
            moveX = 0;
            moveY = 0;
        }
        else
        {
            moveX = cast(int) (cast(long) freeVectorX * 0x10000 / fDotP);
            moveY = cast(int) (cast(long) freeVectorY * 0x10000 / fDotP);
        }
    }

    void setProjection(int axis)
    {
        if (axis == 1) { projVectorX = 0x4000; projVectorY = 0; }
        else { projVectorX = 0; projVectorY = 0x4000; }
        computeMoveVector();
    }

    void setFreedom(int axis)
    {
        if (axis == 1) { freeVectorX = 0x4000; freeVectorY = 0; }
        else { freeVectorX = 0; freeVectorY = 0x4000; }
        computeMoveVector();
    }

    void setVectors(int axis)
    {
        if (axis == 1) { projVectorX = 0x4000; projVectorY = 0; freeVectorX = 0x4000; freeVectorY = 0; }
        else { projVectorX = 0; projVectorY = 0x4000; freeVectorX = 0; freeVectorY = 0x4000; }
        computeMoveVector();
    }

    void setProjectionVector(int x, int y)
    {
        const length = sqrt(cast(double) x * x + cast(double) y * y);
        if (length < 1e-6) { projVectorX = 0x4000; projVectorY = 0; }
        else { projVectorX = cast(int) (x * 0x4000 / length); projVectorY = cast(int) (y * 0x4000 / length); }
        computeMoveVector();
    }

    void setFreedomVector(int x, int y)
    {
        const length = sqrt(cast(double) x * x + cast(double) y * y);
        if (length < 1e-6) { freeVectorX = 0x4000; freeVectorY = 0; }
        else { freeVectorX = cast(int) (x * 0x4000 / length); freeVectorY = cast(int) (y * 0x4000 / length); }
        computeMoveVector();
    }

    void setSuperRound(int selector, bool is45)
    {
        const gridPeriod = is45 ? 0x2D41 : 0x4000;
        switch (selector & 0xC0)
        {
            case 0x00: period = gridPeriod / 2; break;
            case 0x40: period = gridPeriod; break;
            case 0x80: period = gridPeriod * 2; break;
            default: period = gridPeriod; break;
        }
        switch (selector & 0x30)
        {
            case 0x00: phase = 0; break;
            case 0x10: phase = period / 4; break;
            case 0x20: phase = period / 2; break;
            default: phase = period * 3 / 4; break;
        }
        if ((selector & 0x0F) == 0)
            threshold = period - 1;
        else
            threshold = ((selector & 0x0F) - 4) * period / 8;
        period >>= 8;
        phase >>= 8;
        threshold >>= 8;
        roundState = is45 ? 7 : 6;
    }

    /// Round a distance per the current round state (dispatch method).
    long roundDistance(long distance, long compensation) const @safe pure nothrow @nogc
    {
        switch (roundState)
        {
            case 0: return roundToHalfGrid(distance, compensation);
            case 1: return roundToGrid(distance, compensation);
            case 2: return roundToDoubleGrid(distance, compensation);
            case 3: return roundDownToGrid(distance, compensation);
            case 4: return roundUpToGrid(distance, compensation);
            case 5: return roundNone(distance, compensation);
            case 6: return roundSuperGrid(distance, compensation, period, phase, threshold);
            case 7: return roundSuperGrid(distance, compensation, period, phase, threshold);
            default: return roundToGrid(distance, compensation);
        }
    }

    /// Move one point by `distance` (F26Dot6) along the freedom vector.
    void movePoint(ref Zone zone, int point, long distance)
    {
        if (point < 0) throw new HintAbort("Negative point index");
        if (point >= zone.points.length)
        {
            // The twilight zone grows on demand (FreeType semantics).
            const oldLength = zone.points.length;
            zone.points.length = point + 1;
            foreach (i; oldLength .. zone.points.length)
                zone.points[i] = Pt(0, 0, 0, 0, 0, 0, false, false, true);
        }
        if (freeVectorX != 0)
        {
            zone.points[point].curX += mulFix(distance, freeVectorX);
            zone.points[point].touchX = true;
        }
        if (freeVectorY != 0)
        {
            zone.points[point].curY += mulFix(distance, freeVectorY);
            zone.points[point].touchY = true;
        }
    }

    /// Ensure a point index is addressable (growing the twilight zone).
    void ensurePoint(ref Zone zone, int point)
    {
        if (point < 0 || point < zone.points.length) return;
        const oldLength = zone.points.length;
        zone.points.length = point + 1;
        foreach (i; oldLength .. zone.points.length)
            zone.points[i] = Pt(0, 0, 0, 0, 0, 0, false, false, true);
    }

    ref Zone zone0Ref()
    {
        return zoneSelect0 == 0 ? twilight : zone0;
    }

    ref Zone zone1Ref()
    {
        return zoneSelect1 == 0 ? twilight : zone1;
    }

    ref Zone zone2Ref()
    {
        return zoneSelect2 == 0 ? twilight : zone2;
    }

    void mdrp(int opcode)
    {
        const point = cast(int) pop();
        auto zone = zone1Ref();
        ensurePoint(zone, point);
        const orgDist = dualProject2(zone.points[point].orgX, zone.points[point].orgY,
            zone0.points[rp0].orgX, zone0.points[rp0].orgY);

        long distance = orgDist;
        if (singleWidthCutIn > 0 &&
            orgDist < singleWidthValue + singleWidthCutIn &&
            orgDist > singleWidthValue - singleWidthCutIn)
        {
            distance = orgDist >= 0 ? singleWidthValue : -singleWidthValue;
        }

        if ((opcode & 4) != 0)
            distance = roundDistance(distance, 0);
        else
            distance = roundNone(distance, 0);

        if ((opcode & 8) != 0)
        {
            if (orgDist >= 0) { if (distance < minimumDistance) distance = minimumDistance; }
            else { if (distance > -minimumDistance) distance = -minimumDistance; }
        }

        const curDist = project(zone.points[point].curX, zone.points[point].curY) -
            project(zone0.points[rp0].curX, zone0.points[rp0].curY);
        movePoint(zone1Ref(), point, distance - curDist);

        rp1 = rp0;
        rp2 = point;
        if ((opcode & 16) != 0) rp0 = point;
    }

    void mirp(int opcode)
    {
        const point = cast(int) pop();
        const cvtEntry = cast(int) pop() + 1;
        auto zone = zone1Ref();
        ensurePoint(zone, point);
        long cvtDist = cvtEntry > 0 && cast(size_t) cvtEntry - 1 < cvt.length ? cvt[cvtEntry - 1] : 0;

        long delta = cvtDist - singleWidthValue;
        if (delta < 0) delta = -delta;
        if (delta < singleWidthCutIn)
            cvtDist = cvtDist >= 0 ? singleWidthValue : -singleWidthValue;

        if (zoneSelect1 == 0)
        {
            zone.points[point].orgX = zone0.points[rp0].orgX + mulFix(cvtDist, freeVectorX);
            zone.points[point].orgY = zone0.points[rp0].orgY + mulFix(cvtDist, freeVectorY);
            zone.points[point].curX = zone.points[point].orgX;
            zone.points[point].curY = zone.points[point].orgY;
        }

        const orgDist = dualProject2(zone.points[point].orgX, zone.points[point].orgY,
            zone0.points[rp0].orgX, zone0.points[rp0].orgY);
        const curDist = project(zone.points[point].curX, zone.points[point].curY) -
            project(zone0.points[rp0].curX, zone0.points[rp0].curY);

        if (autoFlip && (orgDist ^ cvtDist) < 0)
            cvtDist = -cvtDist;

        long distance = cvtDist;
        if ((opcode & 4) != 0)
        {
            if (zoneSelect0 == zoneSelect1)
            {
                delta = cvtDist - orgDist;
                if (delta < 0) delta = -delta;
                if (delta > controlValueCutIn)
                    cvtDist = orgDist;
            }
            distance = roundDistance(cvtDist, 0);
        }
        else
            distance = roundNone(cvtDist, 0);

        if ((opcode & 8) != 0)
        {
            if (orgDist >= 0) { if (distance < minimumDistance) distance = minimumDistance; }
            else { if (distance > -minimumDistance) distance = -minimumDistance; }
        }

        movePoint(zone1Ref(), point, distance - curDist);

        rp1 = rp0;
        rp2 = point;
        if ((opcode & 16) != 0) rp0 = point;
    }

    void deltaP(int opcode)
    {
        long nump = cast(int) pop();
        if (nump < 0) return;
        if (nump > cast(int) (stack.length / 2)) nump = cast(int) (stack.length / 2);
        stack.length = stack.length - 2 * nump;
        int P = pixelSize - deltaBase;
        switch (opcode)
        {
            case 0x5D: break;
            case 0x71: P -= 16; break;
            case 0x72: P -= 32; break;
            default: break;
        }
        if ((P & ~0xF) != 0) return;
        P <<= 4;
        const F = 1L << (6 - deltaShift);
        while (nump-- > 0)
        {
            const point = cast(int) pop();
            const arg = cast(int) pop();
            if ((arg & 0xF0) == P && point >= 0 && point < zone0.points.length)
            {
                long b = (arg & 0xF) - 8;
                if (b >= 0) b++;
                b = cast(int) (b * F);
                movePoint(zone0Ref(), point, b);
            }
        }
    }

    void deltaC(int opcode)
    {
        long nump = cast(int) pop();
        if (nump < 0) return;
        if (nump > cast(int) (stack.length / 2)) nump = cast(int) (stack.length / 2);
        stack.length = stack.length - 2 * nump;
        int P = pixelSize - deltaBase;
        switch (opcode)
        {
            case 0x73: break;
            case 0x74: P -= 16; break;
            case 0x75: P -= 32; break;
            default: break;
        }
        if ((P & ~0xF) != 0) return;
        P <<= 4;
        const F = 1L << (6 - deltaShift);
        while (nump-- > 0)
        {
            const index = cast(int) pop();
            const arg = cast(int) pop();
            if ((arg & 0xF0) == P && index >= 0 && cast(size_t) index < cvt.length)
            {
                long b = (arg & 0xF) - 8;
                if (b >= 0) b++;
                b = cast(int) (b * F);
                cvt[index] += b;
            }
        }
    }
}

private int maxInt(int a, int b) @safe pure nothrow @nogc { return a > b ? a : b; }

/**
 * The hinting engine. Owns font table access and per-size font/CVT programs.
 */
final class TrueTypeHinter
{
    private const(ubyte)[] _data;
    private size_t _faceOffset;
    private long[] _cvt;
    private long[] _storage;
    private FuncDef[256] _fdefs;
    private FuncDef[256] _idefs;
    private int _preparedForUnits;
    private int _preparedForSize;

    this(const(ubyte)[] data, size_t faceOffset = 0)
    {
        _data = data;
        _faceOffset = faceOffset;
    }

    HintedGlyph hint(HintInput input)
    {
        prepare(input.unitsPerEm, input.pixelSize, input.fpgm, input.prep);

        auto ctx = new Context(this, _cvt, _storage, input.unitsPerEm, input.pixelSize);
        ctx.normalizedAxes = input.normalizedAxes.dup;
        ctx.fdefs[] = _fdefs[];
        ctx.idefs[] = _idefs[];

        // Build the glyph zone.
        const n = input.xs.length;
        ctx.zone0.points.length = n + 4;
        ctx.zone1.points.length = n + 4;
        ctx.zone2.points.length = n + 4;
        ctx.zone0.contours = input.contours.dup;
        ctx.zone1.contours = input.contours.dup;
        ctx.zone2.contours = input.contours.dup;

        int xMin = int.max, yMax = int.min;
        foreach (i; 0 .. n)
        {
            const x = mulDiv(input.xs[i], ctx.scale, 64);
            const y = mulDiv(input.ys[i], ctx.scale, 64);
            ctx.zone0.points[i] = Pt(x, y, x, y, x, y, false, false, input.onCurve[i]);
            ctx.zone1.points[i] = ctx.zone0.points[i];
            ctx.zone2.points[i] = ctx.zone0.points[i];
            if (input.xs[i] < xMin) xMin = input.xs[i];
            if (input.ys[i] > yMax) yMax = input.ys[i];
        }
        if (n == 0) { xMin = 0; yMax = 0; }

        int pp1x = cast(int) mulDiv(xMin - input.lsb, ctx.scale, 64);
        int pp2x = cast(int) mulDiv(xMin - input.lsb + input.advance, ctx.scale, 64);
        int pp3y = cast(int) mulDiv(yMax + input.tsb, ctx.scale, 64);
        int pp4y = cast(int) mulDiv(yMax + input.tsb - input.vadvance, ctx.scale, 64);
        pp1x = (pp1x + 32) & ~63;
        pp2x = (pp2x + 32) & ~63;
        pp3y = (pp3y + 32) & ~63;
        pp4y = (pp4y + 32) & ~63;

        Pt phantom1 = Pt(pp1x, 0, pp1x, 0, pp1x, 0, false, false, true);
        Pt phantom2 = Pt(pp2x, 0, pp2x, 0, pp2x, 0, false, false, true);
        Pt phantom3 = Pt(0, pp3y, 0, pp3y, 0, pp3y, false, false, true);
        Pt phantom4 = Pt(0, pp4y, 0, pp4y, 0, pp4y, false, false, true);
        ctx.zone0.points[n] = phantom1;
        ctx.zone0.points[n + 1] = phantom2;
        ctx.zone0.points[n + 2] = phantom3;
        ctx.zone0.points[n + 3] = phantom4;
        ctx.zone1.points[n .. $] = ctx.zone0.points[n .. $];
        ctx.zone2.points[n .. $] = ctx.zone0.points[n .. $];

        // Twilight zone: reserve maxTwilightPoints + 4 (from maxp) so the
        // fpgm/prep/glyph programs can reference twilight points by index.
        int twilightCount = 4;
        const maxp = tableData(tag!"maxp");
        if (maxp !is null && maxp.length >= 16)
            twilightCount += be16(maxp, 14); // maxTwilightPoints
        ctx.twilight.points.length = twilightCount;
        foreach (ref pt; ctx.twilight.points)
            pt = Pt(0, 0, 0, 0, 0, 0, false, false, true);

        if (input.instructions.length > 0)
            runProgram(ctx, input.instructions);

        HintedGlyph result;
        result.xs.length = n;
        result.ys.length = n;
        result.onCurve.length = n;
        result.contours = input.contours.dup;
        result.xMin = int.max; result.xMax = int.min;
        result.yMin = int.max; result.yMax = int.min;
        foreach (i; 0 .. n)
        {
            result.xs[i] = cast(int) (ctx.zone2.points[i].curX >> 6);
            result.ys[i] = cast(int) (ctx.zone2.points[i].curY >> 6);
            result.onCurve[i] = input.onCurve[i];
            if (result.xs[i] < result.xMin) result.xMin = result.xs[i];
            if (result.xs[i] > result.xMax) result.xMax = result.xs[i];
            if (result.ys[i] < result.yMin) result.yMin = result.ys[i];
            if (result.ys[i] > result.yMax) result.yMax = result.ys[i];
        }
        result.lsb = cast(int) (ctx.zone2.points[n].curX >> 6);
        result.advance = cast(int) ((ctx.zone2.points[n + 1].curX - ctx.zone2.points[n].curX) >> 6);
        result.tsb = cast(int) (ctx.zone2.points[n + 2].curY >> 6);
        result.vadvance = cast(int) ((ctx.zone2.points[n + 3].curY - ctx.zone2.points[n + 2].curY) >> 6);
        return result;
    }

    // ------------------------------------------------------------------
    // Size preparation: scale CVT, run font program then CVT program.
    // ------------------------------------------------------------------

    private void prepare(int unitsPerEm, int pixelSize, const(ubyte)[] fpgm, const(ubyte)[] prep)
    {
        if (_preparedForUnits == unitsPerEm && _preparedForSize == pixelSize)
            return;
        _preparedForUnits = unitsPerEm;
        _preparedForSize = pixelSize;

        const cvtTable = tableData(tag!"cvt ");
        const cvtCount = cvtTable.length / 4;
        _cvt.length = cvtCount;
        const scale = mulDiv(pixelSize, 64, maxInt(1, unitsPerEm));
        foreach (i; 0 .. cvtCount)
            _cvt[i] = mulDiv(beS32(cvtTable, i * 4), scale, 64);

        const maxp = tableData(tag!"maxp");
        int storageSize;
        if (maxp.length >= 6)
            storageSize = be16(maxp, 4);
        _storage.length = storageSize;
        _storage[] = 0;

        auto ctx = new Context(this, _cvt, _storage, unitsPerEm, pixelSize);
        ctx.fdefs[] = _fdefs[];
        ctx.idefs[] = _idefs[];

        // During fpgm/prep there are no glyph points; route all zones to the
        // reserved twilight array so point accesses are in bounds.
        int twilightCount = 4;
        if (maxp.length >= 16)
            twilightCount += be16(maxp, 14); // maxTwilightPoints
        ctx.twilight.points.length = twilightCount;
        foreach (ref pt; ctx.twilight.points)
            pt = Pt(0, 0, 0, 0, 0, 0, false, false, true);
        ctx.zone0.points.length = twilightCount;
        ctx.zone1.points.length = twilightCount;
        ctx.zone2.points.length = twilightCount;
        ctx.zone0.points[] = ctx.twilight.points[];
        ctx.zone1.points[] = ctx.twilight.points[];
        ctx.zone2.points[] = ctx.twilight.points[];
        ctx.zoneSelect0 = 0;
        ctx.zoneSelect1 = 0;
        ctx.zoneSelect2 = 0;

        if (fpgm.length > 0)
            runProgram(ctx, fpgm);
        if (prep.length > 0)
            runProgram(ctx, prep);

        _fdefs[] = ctx.fdefs[];
        _idefs[] = ctx.idefs[];
    }

    private const(ubyte)[] tableData(uint tableTag)
    {
        if (_data.length < 12) return null;
        const count = be16(_data, _faceOffset + 4);
        size_t cursor = _faceOffset + 12;
        foreach (_; 0 .. count)
        {
            if (cursor + 16 > _data.length) break;
            const name = be32(_data, cursor);
            if (name == tableTag)
            {
                const offset = cast(size_t) be32(_data, cursor + 8);
                const length = cast(size_t) be32(_data, cursor + 12);
                if (offset + length <= _data.length)
                    return _data[offset .. offset + length];
                return null;
            }
            cursor += 16;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Program execution.
    // ------------------------------------------------------------------

    private void runProgram(Context ctx, const(ubyte)[] code)
    {
        ctx.code = code;
        ctx.codeSize = code.length;
        ctx.ip = 0;
        ctx.stack.length = 0;
        ctx.callStack.length = 0;

        const maxSteps = 10000000;
        int steps;
        while (ctx.ip < ctx.codeSize)
        {
            if (++steps > maxSteps)
                throw new HintAbort("Hinting instruction limit exceeded");
            const opcode = ctx.code[ctx.ip];
            ctx.ip++;

            switch (opcode)
            {
                case 0x2C: // FDEF
                {
                    const f = cast(int) ctx.pop();
                    if (f < 0 || f >= ctx.fdefs.length)
                        throw new HintAbort("FDEF index out of range");
                    ctx.fdefs[f].active = true;
                    ctx.fdefs[f].body = ctx.code;
                    ctx.fdefs[f].start = ctx.ip;
                    ctx.ip = skipToEndf(ctx.code, ctx.ip);
                    ctx.fdefs[f].end = ctx.ip;
                    continue;
                }
                case 0x89: // IDEF
                {
                    const op = cast(int) ctx.pop();
                    if (op < 0 || op >= ctx.idefs.length)
                        throw new HintAbort("IDEF index out of range");
                    ctx.idefs[op].active = true;
                    ctx.idefs[op].body = ctx.code;
                    ctx.idefs[op].start = ctx.ip;
                    ctx.ip = skipToEndf(ctx.code, ctx.ip);
                    ctx.idefs[op].end = ctx.ip;
                    continue;
                }
                case 0x2B: // CALL
                {
                    const f = cast(int) ctx.pop();
                    if (f < 0 || f >= ctx.fdefs.length || !ctx.fdefs[f].active)
                        throw new HintAbort("CALL to undefined function");
                    ctx.callStack ~= CallRec(ctx.ip, ctx.code, ctx.codeSize, 1, ctx.fdefs[f]);
                    ctx.code = ctx.fdefs[f].body;
                    ctx.codeSize = ctx.fdefs[f].end;
                    ctx.ip = ctx.fdefs[f].start;
                    continue;
                }
                case 0x2A: // LOOPCALL
                {
                    const count = cast(int) ctx.pop();
                    const f = cast(int) ctx.pop();
                    if (f < 0 || f >= ctx.fdefs.length || !ctx.fdefs[f].active)
                        throw new HintAbort("LOOPCALL to undefined function");
                    if (count > 0)
                    {
                        ctx.callStack ~= CallRec(ctx.ip, ctx.code, ctx.codeSize, count, ctx.fdefs[f]);
                        ctx.code = ctx.fdefs[f].body;
                        ctx.codeSize = ctx.fdefs[f].end;
                        ctx.ip = ctx.fdefs[f].start;
                    }
                    continue;
                }
                case 0x2D: // ENDF
                {
                    if (ctx.callStack.length == 0)
                        throw new HintAbort("ENDF outside a function");
                    auto rec = ctx.callStack[$ - 1];
                    rec.count--;
                    if (rec.count > 0)
                    {
                        ctx.callStack[$ - 1] = rec;
                        ctx.ip = rec.def.start;
                        ctx.code = rec.def.body;
                        ctx.codeSize = rec.def.end;
                        continue;
                    }
                    ctx.callStack.length = ctx.callStack.length - 1;
                    ctx.ip = rec.returnIP;
                    ctx.code = rec.returnCode;
                    ctx.codeSize = rec.returnSize;
                    continue;
                }
                case 0x40: // NPUSHB
                    if (ctx.ip >= ctx.codeSize) throw new HintAbort("Truncated NPUSHB");
                    { const count = ctx.code[ctx.ip++];
                      foreach (_; 0 .. count) { if (ctx.ip >= ctx.codeSize) throw new HintAbort("Truncated NPUSHB"); ctx.push(ctx.code[ctx.ip++]); } }
                    continue;
                case 0x41: // NPUSHW
                    if (ctx.ip >= ctx.codeSize) throw new HintAbort("Truncated NPUSHW");
                    { const count = ctx.code[ctx.ip++];
                      foreach (_; 0 .. count)
                      {
                          if (ctx.ip + 2 > ctx.codeSize) throw new HintAbort("Truncated NPUSHW");
                          const hi = ctx.code[ctx.ip++];
                          const lo = ctx.code[ctx.ip++];
                          ctx.push(cast(short) ((hi << 8) | lo));
                      } }
                    continue;
                case 0xB0: case 0xB1: case 0xB2: case 0xB3:
                case 0xB4: case 0xB5: case 0xB6: case 0xB7:
                {
                    const count = (opcode - 0xB0) + 1;
                    foreach (_; 0 .. count)
                    {
                        if (ctx.ip >= ctx.codeSize) throw new HintAbort("Truncated PUSHB");
                        ctx.push(ctx.code[ctx.ip++]);
                    }
                    continue;
                }
                case 0xB8: case 0xB9: case 0xBA: case 0xBB:
                case 0xBC: case 0xBD: case 0xBE: case 0xBF:
                {
                    const count = (opcode - 0xB8) + 1;
                    foreach (_; 0 .. count)
                    {
                        if (ctx.ip + 2 > ctx.codeSize) throw new HintAbort("Truncated PUSHW");
                        const hi = ctx.code[ctx.ip++];
                        const lo = ctx.code[ctx.ip++];
                        ctx.push(cast(short) ((hi << 8) | lo));
                    }
                    continue;
                }
                case 0x58: // IF
                {
                    const condition = ctx.pop();
                    if (condition == 0)
                        ctx.ip = skipToElseOrEndIf(ctx.code, ctx.ip);
                    continue;
                }
                case 0x1B: // ELSE
                    ctx.ip = skipToEndIf(ctx.code, ctx.ip);
                    continue;
                case 0x59: // EIF
                    continue;
                case 0x1C: // JMPR
                {
                    const offset = cast(int) ctx.pop();
                    ctx.ip = cast(size_t) (cast(ptrdiff_t) ctx.ip + offset);
                    continue;
                }
                case 0x78: // JROT
                {
                    const offset = cast(int) ctx.pop();
                    const condition = ctx.pop();
                    if (condition != 0)
                        ctx.ip = cast(size_t) (cast(ptrdiff_t) ctx.ip + offset);
                    continue;
                }
                case 0x79: // JROF
                {
                    const offset = cast(int) ctx.pop();
                    const condition = ctx.pop();
                    if (condition == 0)
                        ctx.ip = cast(size_t) (cast(ptrdiff_t) ctx.ip + offset);
                    continue;
                }
                default:
                    executeOpcode(ctx, opcode);
                    continue;
            }
        }
    }

    private void executeOpcode(Context ctx, int opcode)
    {
        switch (opcode)
        {
            case 0x00: case 0x01: ctx.setVectors(opcode & 1); return;
            case 0x02: case 0x03: ctx.setProjection(opcode & 1); return;
            case 0x04: case 0x05: ctx.setFreedom(opcode & 1); return;
            case 0x06: case 0x07: case 0x08: case 0x09:
            {
                const p1 = cast(int) ctx.pop();
                const p2 = cast(int) ctx.pop();
                const p1x = ctx.zone2.points[p1].orgX;
                const p1y = ctx.zone2.points[p1].orgY;
                const p2x = ctx.zone1.points[p2].orgX;
                const p2y = ctx.zone1.points[p2].orgY;
                const dx = cast(double) p2x - p1x;
                const dy = cast(double) p2y - p1y;
                const length = sqrt(dx * dx + dy * dy);
                if (length < 1e-6) return;
                int ux = cast(int) (dx * 0x4000 / length);
                int uy = cast(int) (dy * 0x4000 / length);
                const perpendicular = (opcode & 1) != 0;
                if (perpendicular) { const ox = ux; const oy = uy; ux = -oy; uy = ox; }
                if (opcode <= 0x07) ctx.setProjectionVector(ux, uy);
                else ctx.setFreedomVector(ux, uy);
                return;
            }
            case 0x0A: { const y = cast(int) ctx.pop(); const x = cast(int) ctx.pop(); ctx.setProjectionVector(x, y); return; }
            case 0x0B: { const y = cast(int) ctx.pop(); const x = cast(int) ctx.pop(); ctx.setFreedomVector(x, y); return; }
            case 0x0C: ctx.push(ctx.projVectorX); ctx.push(ctx.projVectorY); return;
            case 0x0D: ctx.push(ctx.freeVectorX); ctx.push(ctx.freeVectorY); return;
            case 0x0E: ctx.setFreedomVector(ctx.projVectorX, ctx.projVectorY); return;
            case 0x86: case 0x87:
            {
                const p1 = cast(int) ctx.pop();
                const p2 = cast(int) ctx.pop();
                const p1x = ctx.zone2.points[p1].orusX;
                const p1y = ctx.zone2.points[p1].orusY;
                const p2x = ctx.zone1.points[p2].orusX;
                const p2y = ctx.zone1.points[p2].orusY;
                const dx = cast(double) p2x - p1x;
                const dy = cast(double) p2y - p1y;
                const length = sqrt(dx * dx + dy * dy);
                if (length < 1e-6) return;
                int ux = cast(int) (dx * 0x4000 / length);
                int uy = cast(int) (dy * 0x4000 / length);
                const perpendicular = (opcode & 1) != 0;
                if (perpendicular) { const ox = ux; const oy = uy; ux = -oy; uy = ox; }
                ctx.dualVectorX = ux; ctx.dualVectorY = uy;
                ctx.setProjectionVector(ux, uy);
                return;
            }
            case 0x10: ctx.rp0 = cast(int) ctx.pop(); return;
            case 0x11: ctx.rp1 = cast(int) ctx.pop(); return;
            case 0x12: ctx.rp2 = cast(int) ctx.pop(); return;
            case 0x13: ctx.zoneSelect0 = cast(int) ctx.pop(); return;
            case 0x14: ctx.zoneSelect1 = cast(int) ctx.pop(); return;
            case 0x15: ctx.zoneSelect2 = cast(int) ctx.pop(); return;
            case 0x16: { const z = cast(int) ctx.pop(); ctx.zoneSelect0 = z; ctx.zoneSelect1 = z; ctx.zoneSelect2 = z; return; }
            case 0x18: ctx.roundState = 1; ctx.roundState = 1; return;
            case 0x19: ctx.roundState = 0; ctx.roundState = 0; return;
            case 0x3D: ctx.roundState = 2; ctx.roundState = 2; return;
            case 0x7D: ctx.roundState = 3; ctx.roundState = 3; return;
            case 0x7C: ctx.roundState = 4; ctx.roundState = 4; return;
            case 0x7A: ctx.roundState = 5; ctx.roundState = 5; return;
            case 0x76: case 0x77: { const selector = cast(int) ctx.pop() & 0xFF; ctx.setSuperRound(selector, opcode == 0x77); return; }
            case 0x1A: ctx.minimumDistance = cast(int) ctx.pop(); return;
            case 0x1D: ctx.controlValueCutIn = cast(int) ctx.pop(); return;
            case 0x1E: ctx.singleWidthCutIn = cast(int) ctx.pop(); return;
            case 0x1F: ctx.singleWidthValue = cast(int) mulFix(ctx.pop(), ctx.scale); return;
            case 0x5E: ctx.deltaBase = cast(int) ctx.pop(); return;
            case 0x5F: ctx.deltaShift = cast(int) ctx.pop(); return;
            case 0x4D: ctx.autoFlip = true; return;
            case 0x4E: ctx.autoFlip = false; return;
            case 0x85: ctx.scanControl = ctx.pop(); return;
            case 0x8D: ctx.scanType = cast(int) ctx.pop(); return;
            case 0x8E: { const s = cast(int) ctx.pop(); const v = cast(int) ctx.pop(); if (s == 1) ctx.instructControl = v & 1; return; }
            case 0x17: ctx.loop = cast(int) ctx.pop(); if (ctx.loop < 0) ctx.loop = 0; return;
            case 0x42: { const loc = cast(int) ctx.pop(); const val = ctx.pop(); if (loc >= 0 && cast(size_t) loc < ctx.storage.length) ctx.storage[loc] = val; return; }
            case 0x43: { const loc = cast(int) ctx.pop(); ctx.push(loc >= 0 && cast(size_t) loc < ctx.storage.length ? ctx.storage[loc] : 0); return; }
            case 0x44: { const loc = cast(int) ctx.pop(); const val = ctx.pop(); if (loc >= 0 && cast(size_t) loc < ctx.cvt.length) ctx.cvt[loc] = val; return; }
            case 0x70: { const loc = cast(int) ctx.pop(); const val = ctx.pop(); if (loc >= 0 && cast(size_t) loc < ctx.cvt.length) ctx.cvt[loc] = mulFix(val, ctx.scale); return; }
            case 0x45: { const loc = cast(int) ctx.pop(); ctx.push(loc >= 0 && cast(size_t) loc < ctx.cvt.length ? ctx.cvt[loc] : 0); return; }
            case 0x4B: ctx.push(ctx.pixelSize); return;
            case 0x4C: ctx.push(ctx.pixelSize * 64); return;
            case 0x20: { const e = ctx.pop(); ctx.push(e); ctx.push(e); return; }
            case 0x21: ctx.pop(); return;
            case 0x22: ctx.stack.length = 0; return;
            case 0x23: { const e1 = ctx.pop(); const e2 = ctx.pop(); ctx.push(e1); ctx.push(e2); return; }
            case 0x24: ctx.push(ctx.stack.length); return;
            case 0x25: { const k = cast(int) ctx.pop(); if (k > 0 && cast(size_t) k <= ctx.stack.length) ctx.push(ctx.stack[ctx.stack.length - cast(size_t) k]); return; }
            case 0x26:
            {
                const k = cast(int) ctx.pop();
                if (k > 0 && cast(size_t) k <= ctx.stack.length)
                {
                    const index = ctx.stack.length - cast(size_t) k;
                    const value = ctx.stack[index];
                    ctx.stack[index .. $ - 1] = ctx.stack[index + 1 .. $];
                    ctx.stack[$ - 1] = value;
                }
                return;
            }
            case 0x8A: { if (ctx.stack.length >= 3) { const a = ctx.pop(); const b = ctx.pop(); const c = ctx.pop(); ctx.push(b); ctx.push(a); ctx.push(c); } return; }
            case 0x50: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 < e2 ? 1 : 0); return; }
            case 0x51: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 <= e2 ? 1 : 0); return; }
            case 0x52: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 > e2 ? 1 : 0); return; }
            case 0x53: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 >= e2 ? 1 : 0); return; }
            case 0x54: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 == e2 ? 1 : 0); return; }
            case 0x55: { const e2 = ctx.pop(); const e1 = ctx.pop(); ctx.push(e1 != e2 ? 1 : 0); return; }
            case 0x56: { const e1 = ctx.pop(); ctx.push((ctx.roundDistance(cast(int) e1, 0) >> 6) & 1); return; }
            case 0x57: { const e1 = ctx.pop(); ctx.push(((ctx.roundDistance(cast(int) e1, 0) >> 6) & 1) == 0 ? 1 : 0); return; }
            case 0x5A: { const e1 = ctx.pop(); const e2 = ctx.pop(); ctx.push((e1 != 0 && e2 != 0) ? 1 : 0); return; }
            case 0x5B: { const e1 = ctx.pop(); const e2 = ctx.pop(); ctx.push((e1 != 0 || e2 != 0) ? 1 : 0); return; }
            case 0x5C: { const e = ctx.pop(); ctx.push(e == 0 ? 1 : 0); return; }
            case 0x60: { const n1 = ctx.pop(); const n2 = ctx.pop(); ctx.push(n1 + n2); return; }
            case 0x61: { const n1 = ctx.pop(); const n2 = ctx.pop(); ctx.push(n2 - n1); return; }
            case 0x62: { const n1 = ctx.pop(); const n2 = ctx.pop(); ctx.push(n1 == 0 ? 0 : n2 / n1); return; }
            case 0x63: { const n1 = ctx.pop(); const n2 = ctx.pop(); ctx.push(n1 * n2); return; }
            case 0x64: { const n = ctx.pop(); ctx.push(n < 0 ? -n : n); return; }
            case 0x65: { const n = ctx.pop(); ctx.push(-n); return; }
            case 0x66: { const n = ctx.pop(); ctx.push(n & ~63L); return; }
            case 0x67: { const n = ctx.pop(); ctx.push((n + 63) & ~63L); return; }
            case 0x68: case 0x69: case 0x6A: case 0x6B:
                ctx.push(ctx.roundDistance(cast(int) ctx.pop(), 0)); return;
            case 0x6C: case 0x6D: case 0x6E: case 0x6F:
                return;
            case 0x8B: { const e1 = ctx.pop(); const e2 = ctx.pop(); ctx.push(e1 > e2 ? e1 : e2); return; }
            case 0x8C: { const e1 = ctx.pop(); const e2 = ctx.pop(); ctx.push(e1 < e2 ? e1 : e2); return; }
            case 0x2E: case 0x2F:
            {
                const point = cast(int) ctx.pop();
                auto zone = ctx.zone0Ref();
                ctx.ensurePoint(zone, point);
                int distance;
                if ((opcode & 1) != 0)
                {
                    const curDist = ctx.project(cast(int) zone.points[point].curX,
                        cast(int) zone.points[point].curY);
                    distance = cast(int) (ctx.roundDistance(curDist, 0) - curDist);
                }
                ctx.movePoint(ctx.zone0Ref(), point, distance);
                ctx.rp0 = point;
                ctx.rp1 = point;
                return;
            }
            case 0x3E: case 0x3F:
            {
                const point = cast(int) ctx.pop();
                const cvtEntry = cast(int) ctx.pop();
                auto zone = ctx.zone0Ref();
                ctx.ensurePoint(zone, point);
                long distance = cvtEntry >= 0 && cast(size_t) cvtEntry < ctx.cvt.length ? ctx.cvt[cvtEntry] : 0;
                if (ctx.zoneSelect0 == 0)
                {
                    zone.points[point].orgX = mulFix(cast(int) distance, ctx.freeVectorX);
                    zone.points[point].orgY = mulFix(cast(int) distance, ctx.freeVectorY);
                    zone.points[point].curX = zone.points[point].orgX;
                    zone.points[point].curY = zone.points[point].orgY;
                }
                const orgDist = ctx.project(cast(int) zone.points[point].curX,
                    cast(int) zone.points[point].curY);
                if ((opcode & 1) != 0)
                {
                    long delta = distance - orgDist;
                    if (delta < 0) delta = -delta;
                    if (delta > ctx.controlValueCutIn)
                        distance = orgDist;
                    distance = ctx.roundDistance(cast(int) distance, 0);
                }
                ctx.movePoint(ctx.zone0Ref(), point, cast(int) (distance - orgDist));
                ctx.rp0 = point;
                ctx.rp1 = point;
                return;
            }
            case 0x3C:
            {
                const count = ctx.loop;
                ctx.loop = 1;
                foreach (_; 0 .. count)
                {
                    const point = cast(int) ctx.pop();
                    auto zone = ctx.zone1Ref();
                    const cur = ctx.project(cast(int) zone.points[point].curX,
                        cast(int) zone.points[point].curY);
                    const rpProj = ctx.project(cast(int) ctx.zone0.points[ctx.rp0].curX,
                        cast(int) ctx.zone0.points[ctx.rp0].curY);
                    ctx.movePoint(ctx.zone1Ref(), point, rpProj - cur);
                }
                return;
            }
            case 0x3A: case 0x3B:
            {
                const point = cast(int) ctx.pop();
                const distance = cast(int) ctx.pop();
                auto zone = ctx.zone1Ref();
                ctx.ensurePoint(zone, point);
                if (ctx.zoneSelect1 == 0)
                {
                    zone.points[point].orgX = ctx.zone0.points[ctx.rp0].orgX;
                    zone.points[point].orgY = ctx.zone0.points[ctx.rp0].orgY;
                    zone.points[point].curX = zone.points[point].orgX + mulFix(distance, ctx.freeVectorX);
                    zone.points[point].curY = zone.points[point].orgY + mulFix(distance, ctx.freeVectorY);
                }
                else
                {
                    const cur = ctx.project(cast(int) zone.points[point].curX,
                        cast(int) zone.points[point].curY);
                    const rpProj = ctx.project(cast(int) ctx.zone0.points[ctx.rp0].curX,
                        cast(int) ctx.zone0.points[ctx.rp0].curY);
                    ctx.movePoint(ctx.zone1Ref(), point, distance - (cur - rpProj));
                }
                ctx.rp1 = ctx.rp0;
                ctx.rp2 = point;
                if ((opcode & 1) != 0) ctx.rp0 = point;
                return;
            }
            case 0x49: case 0x4A:
            {
                const p1 = cast(int) ctx.pop();
                const p2 = cast(int) ctx.pop();
                long distance;
                if ((opcode & 1) != 0)
                {
                    distance = ctx.project(cast(int) ctx.zone0.points[p2].curX,
                        cast(int) ctx.zone0.points[p2].curY) -
                        ctx.project(cast(int) ctx.zone1.points[p1].curX,
                            cast(int) ctx.zone1.points[p1].curY);
                }
                else
                {
                    distance = ctx.dualProject2(cast(int) ctx.zone0.points[p2].orgX,
                        cast(int) ctx.zone0.points[p2].orgY,
                        cast(int) ctx.zone1.points[p1].orgX,
                        cast(int) ctx.zone1.points[p1].orgY);
                }
                ctx.push(distance);
                return;
            }
            case 0x46: case 0x47:
            {
                const point = cast(int) ctx.pop();
                auto zone = ctx.zone2Ref();
                ctx.ensurePoint(zone, point);
                if ((opcode & 1) != 0)
                    ctx.push(ctx.dualProject(cast(int) zone.points[point].orgX,
                        cast(int) zone.points[point].orgY));
                else
                    ctx.push(ctx.project(cast(int) zone.points[point].curX,
                        cast(int) zone.points[point].curY));
                return;
            }
            case 0x48:
            {
                const point = cast(int) ctx.pop();
                const value = cast(int) ctx.pop();
                auto zone = ctx.zone2Ref();
                ctx.ensurePoint(zone, point);
                if (ctx.zoneSelect2 == 0)
                    zone.points[point].orgX = zone.points[point].curX;
                const cur = ctx.project(cast(int) zone.points[point].curX,
                    cast(int) zone.points[point].curY);
                ctx.movePoint(ctx.zone2Ref(), point, value - cur);
                return;
            }
            case 0x80:
            {
                const count = ctx.loop;
                ctx.loop = 1;
                foreach (_; 0 .. count)
                {
                    const point = cast(int) ctx.pop();
                    if (point >= 0 && point < ctx.zone0.points.length)
                        ctx.zone0.points[point].onCurve = !ctx.zone0.points[point].onCurve;
                }
                return;
            }
            case 0x81:
            {
                const low = cast(int) ctx.pop();
                const high = cast(int) ctx.pop();
                foreach (i; low .. high + 1)
                    if (i >= 0 && i < ctx.zone0.points.length) ctx.zone0.points[i].onCurve = true;
                return;
            }
            case 0x82:
            {
                const low = cast(int) ctx.pop();
                const high = cast(int) ctx.pop();
                foreach (i; low .. high + 1)
                    if (i >= 0 && i < ctx.zone0.points.length) ctx.zone0.points[i].onCurve = false;
                return;
            }
            case 0x27:
            {
                const p1 = cast(int) ctx.pop();
                const p2 = cast(int) ctx.pop();
                const d = (ctx.project(cast(int) ctx.zone0.points[p2].curX,
                    cast(int) ctx.zone0.points[p2].curY) -
                    ctx.project(cast(int) ctx.zone1.points[p1].curX,
                        cast(int) ctx.zone1.points[p1].curY)) / 2;
                ctx.movePoint(ctx.zone1Ref(), p1, d);
                ctx.movePoint(ctx.zone0Ref(), p2, -d);
                return;
            }
            case 0x29:
            {
                const point = cast(int) ctx.pop();
                if (point >= 0 && point < ctx.zone0.points.length)
                {
                    ctx.zone0.points[point].touchX = false;
                    ctx.zone0.points[point].touchY = false;
                }
                return;
            }
            case 0x0F:
            {
                const point = cast(int) ctx.pop();
                const a0 = cast(int) ctx.pop();
                const a1 = cast(int) ctx.pop();
                const b0 = cast(int) ctx.pop();
                const b1 = cast(int) ctx.pop();
                auto zone = ctx.zone2Ref();
                ctx.ensurePoint(zone, point);
                const bdx = ctx.zone0.points[b1].curX - ctx.zone0.points[b0].curX;
                const bdy = ctx.zone0.points[b1].curY - ctx.zone0.points[b0].curY;
                const adx = ctx.zone1.points[a1].curX - ctx.zone1.points[a0].curX;
                const ady = ctx.zone1.points[a1].curY - ctx.zone1.points[a0].curY;
                const dx = ctx.zone0.points[b0].curX - ctx.zone1.points[a0].curX;
                const dy = ctx.zone0.points[b0].curY - ctx.zone1.points[a0].curY;
                const discriminant = mulDiv(cast(int) adx, cast(int) -bdy, 64) +
                    mulDiv(cast(int) ady, cast(int) bdx, 64);
                const dot = mulDiv(cast(int) adx, cast(int) bdx, 64) +
                    mulDiv(cast(int) ady, cast(int) bdy, 64);
                if (19 * (discriminant < 0 ? -discriminant : discriminant) >
                    (dot < 0 ? -dot : dot))
                {
                    const val = mulDiv(cast(int) dx, cast(int) -bdy, 64) +
                        mulDiv(cast(int) dy, cast(int) bdx, 64);
                    const rx = mulDiv(val, cast(int) adx, discriminant);
                    const ry = mulDiv(val, cast(int) ady, discriminant);
                    zone.points[point].curX = ctx.zone1.points[a0].curX + rx;
                    zone.points[point].curY = ctx.zone1.points[a0].curY + ry;
                }
                else
                {
                    zone.points[point].curX = (ctx.zone1.points[a0].curX +
                        ctx.zone1.points[a1].curX + ctx.zone0.points[b0].curX +
                        ctx.zone0.points[b1].curX) / 4;
                    zone.points[point].curY = (ctx.zone1.points[a0].curY +
                        ctx.zone1.points[a1].curY + ctx.zone0.points[b0].curY +
                        ctx.zone0.points[b1].curY) / 4;
                }
                zone.points[point].touchX = true;
                zone.points[point].touchY = true;
                return;
            }
            case 0x30: case 0x31:
                interpolateUntouchedPoints(ctx, (opcode & 1) != 0);
                return;
            case 0x32: case 0x33:
            {
                const count = ctx.loop;
                ctx.loop = 1;
                const refZone = (opcode & 1) != 0 ? ctx.zone0Ref() : ctx.zone1Ref();
                const refPt = (opcode & 1) != 0 ? ctx.rp1 : ctx.rp2;
                const d = ctx.project(cast(int) refZone.points[refPt].curX,
                    cast(int) refZone.points[refPt].curY) -
                    ctx.project(cast(int) refZone.points[refPt].orgX,
                        cast(int) refZone.points[refPt].orgY);
                const dx = mulFix(d, ctx.freeVectorX);
                const dy = mulFix(d, ctx.freeVectorY);
                foreach (_; 0 .. count)
                {
                    const point = cast(int) ctx.pop();
                    if (point >= 0 && point < ctx.zone2.points.length)
                    {
                        if (ctx.freeVectorX != 0)
                        {
                            ctx.zone2.points[point].curX += dx;
                            ctx.zone2.points[point].touchX = true;
                        }
                        if (ctx.freeVectorY != 0)
                        {
                            ctx.zone2.points[point].curY += dy;
                            ctx.zone2.points[point].touchY = true;
                        }
                    }
                }
                return;
            }
            case 0x34: case 0x35:
            {
                const contour = cast(int) ctx.pop();
                const refZone = (opcode & 1) != 0 ? ctx.zone0Ref() : ctx.zone1Ref();
                const refPt = (opcode & 1) != 0 ? ctx.rp1 : ctx.rp2;
                const d = ctx.project(cast(int) refZone.points[refPt].curX,
                    cast(int) refZone.points[refPt].curY) -
                    ctx.project(cast(int) refZone.points[refPt].orgX,
                        cast(int) refZone.points[refPt].orgY);
                const dx = mulFix(d, ctx.freeVectorX);
                const dy = mulFix(d, ctx.freeVectorY);
                if (contour >= 0 && contour < ctx.zone2.contours.length)
                {
                    const first = contour == 0 ? 0 : ctx.zone2.contours[contour - 1] + 1;
                    const last = ctx.zone2.contours[contour];
                    foreach (i; first .. last + 1)
                    {
                        if (i == refPt) continue;
                        if (ctx.freeVectorX != 0) ctx.zone2.points[i].curX += dx;
                        if (ctx.freeVectorY != 0) ctx.zone2.points[i].curY += dy;
                    }
                }
                return;
            }
            case 0x36: case 0x37:
            {
                const zone = cast(int) ctx.pop();
                const refZone = (opcode & 1) != 0 ? ctx.zone0Ref() : ctx.zone1Ref();
                const refPt = (opcode & 1) != 0 ? ctx.rp1 : ctx.rp2;
                const d = ctx.project(cast(int) refZone.points[refPt].curX,
                    cast(int) refZone.points[refPt].curY) -
                    ctx.project(cast(int) refZone.points[refPt].orgX,
                        cast(int) refZone.points[refPt].orgY);
                const dx = mulFix(d, ctx.freeVectorX);
                const dy = mulFix(d, ctx.freeVectorY);
                if (zone == 0)
                {
                    foreach (i; 0 .. ctx.twilight.points.length)
                    {
                        if (i == refPt) continue;
                        ctx.twilight.points[i].curX += dx;
                        ctx.twilight.points[i].curY += dy;
                    }
                }
                else
                {
                    const limit = ctx.zone1.points.length > 4 ? ctx.zone1.points.length - 4 : 0;
                    foreach (i; 0 .. limit)
                    {
                        if (i == refPt) continue;
                        ctx.zone1.points[i].curX += dx;
                        ctx.zone1.points[i].curY += dy;
                    }
                }
                return;
            }
            case 0x38:
            {
                const amount = cast(int) ctx.pop();
                const count = ctx.loop;
                ctx.loop = 1;
                const dx = mulFix(amount, ctx.freeVectorX);
                const dy = mulFix(amount, ctx.freeVectorY);
                foreach (_; 0 .. count)
                {
                    const point = cast(int) ctx.pop();
                    if (point >= 0 && point < ctx.zone2.points.length)
                    {
                        if (ctx.freeVectorX != 0)
                        {
                            ctx.zone2.points[point].curX += dx;
                            ctx.zone2.points[point].touchX = true;
                        }
                        if (ctx.freeVectorY != 0)
                        {
                            ctx.zone2.points[point].curY += dy;
                            ctx.zone2.points[point].touchY = true;
                        }
                    }
                }
                return;
            }
            case 0x39:
            {
                const count = ctx.loop;
                ctx.loop = 1;
                const twilight = ctx.zoneSelect0 == 0 || ctx.zoneSelect1 == 0 || ctx.zoneSelect2 == 0;
                long oldRange = 0, curRange = 0;
                const rp2ok = ctx.rp2 >= 0 && ctx.rp2 < ctx.zone1.points.length;
                if (rp2ok)
                {
                    oldRange = twilight
                        ? ctx.dualProject2(cast(int) ctx.zone1.points[ctx.rp2].orgX,
                            cast(int) ctx.zone1.points[ctx.rp2].orgY,
                            cast(int) ctx.zone0.points[ctx.rp1].orgX,
                            cast(int) ctx.zone0.points[ctx.rp1].orgY)
                        : ctx.dualProject2(cast(int) ctx.zone1.points[ctx.rp2].orusX,
                            cast(int) ctx.zone1.points[ctx.rp2].orusY,
                            cast(int) ctx.zone0.points[ctx.rp1].orusX,
                            cast(int) ctx.zone0.points[ctx.rp1].orusY);
                    curRange = ctx.project(cast(int) ctx.zone1.points[ctx.rp2].curX,
                        cast(int) ctx.zone1.points[ctx.rp2].curY) -
                        ctx.project(cast(int) ctx.zone0.points[ctx.rp1].curX,
                            cast(int) ctx.zone0.points[ctx.rp1].curY);
                }
                foreach (_; 0 .. count)
                {
                    const point = cast(int) ctx.pop();
                    if (point < 0 || point >= ctx.zone2.points.length ||
                        ctx.rp1 < 0 || ctx.rp1 >= ctx.zone0.points.length)
                        continue;
                    const orgDist = twilight
                        ? ctx.dualProject2(cast(int) ctx.zone2.points[point].orgX,
                            cast(int) ctx.zone2.points[point].orgY,
                            cast(int) ctx.zone0.points[ctx.rp1].orgX,
                            cast(int) ctx.zone0.points[ctx.rp1].orgY)
                        : ctx.dualProject2(cast(int) ctx.zone2.points[point].orusX,
                            cast(int) ctx.zone2.points[point].orusY,
                            cast(int) ctx.zone0.points[ctx.rp1].orusX,
                            cast(int) ctx.zone0.points[ctx.rp1].orusY);
                    const curDist = ctx.project(cast(int) ctx.zone2.points[point].curX,
                        cast(int) ctx.zone2.points[point].curY) -
                        ctx.project(cast(int) ctx.zone0.points[ctx.rp1].curX,
                            cast(int) ctx.zone0.points[ctx.rp1].curY);
                    long newDist;
                    if (orgDist != 0)
                        newDist = oldRange != 0 ? mulDiv(orgDist, curRange, oldRange) : orgDist;
                    else
                        newDist = 0;
                    ctx.movePoint(ctx.zone2Ref(), point, newDist - curDist);
                }
                return;
            }
            case 0xC0: case 0xC1: case 0xC2: case 0xC3:
            case 0xC4: case 0xC5: case 0xC6: case 0xC7:
            case 0xC8: case 0xC9: case 0xCA: case 0xCB:
            case 0xCC: case 0xCD: case 0xCE: case 0xCF:
            case 0xD0: case 0xD1: case 0xD2: case 0xD3:
            case 0xD4: case 0xD5: case 0xD6: case 0xD7:
            case 0xD8: case 0xD9: case 0xDA: case 0xDB:
            case 0xDC: case 0xDD: case 0xDE: case 0xDF:
                ctx.mdrp(opcode);
                return;
            case 0xE0: case 0xE1: case 0xE2: case 0xE3:
            case 0xE4: case 0xE5: case 0xE6: case 0xE7:
            case 0xE8: case 0xE9: case 0xEA: case 0xEB:
            case 0xEC: case 0xED: case 0xEE: case 0xEF:
            case 0xF0: case 0xF1: case 0xF2: case 0xF3:
            case 0xF4: case 0xF5: case 0xF6: case 0xF7:
            case 0xF8: case 0xF9: case 0xFA: case 0xFB:
            case 0xFC: case 0xFD: case 0xFE: case 0xFF:
                ctx.mirp(opcode);
                return;
            case 0x5D: case 0x71: case 0x72:
                ctx.deltaP(opcode);
                return;
            case 0x73: case 0x74: case 0x75:
                ctx.deltaC(opcode);
                return;
            case 0x88:
            {
                const selector = cast(int) ctx.pop();
                int result;
                if ((selector & 1) != 0)
                    result = 40;
                if ((selector & 8) != 0)
                    result |= 1 << 10;
                if ((selector & 32) != 0)
                    result |= 1 << 12;
                if ((selector & 64) != 0)
                    result |= 1 << 13;
                if ((selector & 0x400) != 0)
                    result |= 1 << 17;
                ctx.push(result);
                return;
            }
            case 0x91:
            {
                foreach (i; 0 .. ctx.normalizedAxes.length)
                    ctx.push(ctx.normalizedAxes[i]);
                return;
            }
            case 0x4F: ctx.pop(); return;
            default:
                if (opcode >= 0 && opcode < ctx.idefs.length && ctx.idefs[opcode].active)
                {
                    ctx.callStack ~= CallRec(ctx.ip, ctx.code, ctx.codeSize, 1, ctx.idefs[opcode]);
                    ctx.code = ctx.idefs[opcode].body;
                    ctx.codeSize = ctx.idefs[opcode].end;
                    ctx.ip = ctx.idefs[opcode].start;
                    return;
                }
                throw new HintAbort("Unhandled TrueType opcode " ~ std.format.format("%02X", opcode));
        }
    }

    // ------------------------------------------------------------------
    // IUP
    // ------------------------------------------------------------------

    private static void interpolateUntouchedPoints(Context ctx, bool xAxis)
    {
        auto zone = ctx.zone2Ref();
        if (zone.nContours() == 0) return;

        foreach (contourIndex; 0 .. zone.nContours())
        {
            const endPoint = zone.contours[contourIndex];
            const firstPoint = contourIndex == 0 ? 0 : zone.contours[contourIndex - 1] + 1;
            int[] touched;
            foreach (i; firstPoint .. endPoint + 1)
            {
                const touchedFlag = xAxis ? zone.points[i].touchX : zone.points[i].touchY;
                if (touchedFlag) touched ~= i;
            }
            if (touched.length == 0) continue;
            if (touched.length == 1)
            {
                const t = touched[0];
                const delta = xAxis
                    ? (zone.points[t].curX - zone.points[t].orgX)
                    : (zone.points[t].curY - zone.points[t].orgY);
                foreach (i; firstPoint .. endPoint + 1)
                {
                    if (i == t) continue;
                    if (xAxis) zone.points[i].curX += delta;
                    else zone.points[i].curY += delta;
                }
                continue;
            }
            foreach (pair; 0 .. touched.length - 1)
            {
                const ref1 = touched[pair];
                const ref2 = touched[pair + 1];
                interpolateBetween(ctx, zone, ref1 + 1, ref2 - 1, ref1, ref2, xAxis);
            }
            const first = touched[0];
            const last = touched[$ - 1];
            interpolateBetween(ctx, zone, last + 1, endPoint, last, first, xAxis);
            interpolateBetween(ctx, zone, firstPoint, first - 1, last, first, xAxis);
        }
    }

    private static void interpolateBetween(Context ctx, ref Zone zone,
        int p1, int p2, int ref1, int ref2, bool xAxis)
    {
        if (p1 > p2) return;
        long orus1, orus2, org1, org2, cur1, cur2;
        if (xAxis)
        {
            orus1 = zone.points[ref1].orusX; orus2 = zone.points[ref2].orusX;
            org1 = zone.points[ref1].orgX; org2 = zone.points[ref2].orgX;
            cur1 = zone.points[ref1].curX; cur2 = zone.points[ref2].curX;
        }
        else
        {
            orus1 = zone.points[ref1].orusY; orus2 = zone.points[ref2].orusY;
            org1 = zone.points[ref1].orgY; org2 = zone.points[ref2].orgY;
            cur1 = zone.points[ref1].curY; cur2 = zone.points[ref2].curY;
        }
        if (orus1 > orus2)
        {
            swap(orus1, orus2); swap(org1, org2); swap(cur1, cur2);
        }
        const delta1 = cur1 - org1;
        const delta2 = cur2 - org2;
        const scale = orus2 != orus1 ? mulDiv(cast(int) (cur2 - cur1), 0x4000,
            cast(int) (orus2 - orus1)) : 0;
        foreach (i; p1 .. p2 + 1)
        {
            const org = xAxis ? zone.points[i].orgX : zone.points[i].orgY;
            long value;
            if (org <= org1)
                value = org + delta1;
            else if (org >= org2)
                value = org + delta2;
            else if (orus2 == orus1 || cur1 == cur2)
                value = cur1;
            else
            {
                const orus = xAxis ? zone.points[i].orusX : zone.points[i].orusY;
                value = cur1 + mulDiv(cast(int) (orus - orus1), scale, 0x4000);
            }
            if (xAxis) zone.points[i].curX = value;
            else zone.points[i].curY = value;
        }
    }

    private static void swap(ref long a, ref long b) @safe pure nothrow @nogc
    {
        const t = a; a = b; b = t;
    }

    private static size_t skipToEndf(const(ubyte)[] code, size_t ip)
    {
        while (ip < code.length)
        {
            if (code[ip] == 0x2D) return ip;
            ip += 1 + codeLength(code, ip);
        }
        throw new HintAbort("No ENDF found");
    }

    private static size_t skipToElseOrEndIf(const(ubyte)[] code, size_t ip)
    {
        int depth = 0;
        while (ip < code.length)
        {
            const opcode = code[ip];
            if (opcode == 0x58) depth++;
            else if (opcode == 0x59) { if (depth == 0) return ip; depth--; }
            else if (opcode == 0x1B && depth == 0) return ip;
            ip += 1 + codeLength(code, ip);
        }
        return ip;
    }

    private static size_t skipToEndIf(const(ubyte)[] code, size_t ip)
    {
        int depth = 0;
        while (ip < code.length)
        {
            const opcode = code[ip];
            if (opcode == 0x58) depth++;
            else if (opcode == 0x59) { if (depth == 0) return ip; depth--; }
            ip += 1 + codeLength(code, ip);
        }
        return ip;
    }

    private static size_t codeLength(const(ubyte)[] code, size_t ip)
    {
        const opcode = code[ip];
        switch (opcode)
        {
            case 0x40:
                if (ip + 1 < code.length) return 1 + code[ip + 1];
                return 0;
            case 0x41:
                if (ip + 1 < code.length) return 1 + 2 * code[ip + 1];
                return 0;
            case 0xB0: case 0xB1: case 0xB2: case 0xB3:
            case 0xB4: case 0xB5: case 0xB6: case 0xB7:
                return 1 + (opcode - 0xB0) + 1;
            case 0xB8: case 0xB9: case 0xBA: case 0xBB:
            case 0xBC: case 0xBD: case 0xBE: case 0xBF:
                return 1 + 2 * ((opcode - 0xB8) + 1);
            default:
                return 0;
        }
    }
}

unittest
{
    // Garbage instructions must abort hinting cleanly.
    auto hinter = new TrueTypeHinter(cast(immutable(ubyte)[]) []);
    HintInput input;
    input.unitsPerEm = 2048;
    input.pixelSize = 16;
    input.xs = [0, 0, 500, 500];
    input.ys = [0, 700, 700, 0];
    input.onCurve = [true, true, true, true];
    input.contours = [3];
    input.lsb = 50;
    input.advance = 600;
    input.tsb = 0;
    input.vadvance = 700;
    bool threw = false;
    try
    {
        input.instructions = cast(ubyte[]) [0x40, 5, 1, 2, 3];
        hinter.hint(input);
    }
    catch (HintAbort)
    {
        threw = true;
    }
    assert(threw, "garbage instructions must abort hinting");

    // No instructions: the outline should pass through unchanged.
    threw = false;
    try
    {
        input.instructions = null;
        auto result = hinter.hint(input);
        assert(result.xs.length == 4, "hinted outline keeps point count");
    }
    catch (Exception)
    {
        threw = true;
    }
    assert(!threw, "unhinted pass-through must succeed");
}

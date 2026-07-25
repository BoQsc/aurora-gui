module aurora.types;

/** Windows and other desktop APIs conventionally use 96 logical units per inch. */
enum uint LogicalDpi = 96;

/** Integer two-dimensional point. */
struct Point
{
    int x;
    int y;

    Point opBinary(string op)(Point rhs) const
    if (op == "+")
    {
        return Point(x + rhs.x, y + rhs.y);
    }

    Point opBinary(string op)(Point rhs) const
    if (op == "-")
    {
        return Point(x - rhs.x, y - rhs.y);
    }
}

/** Subpixel logical point used for pointer latching and compositor transforms. */
struct PointF
{
    double x;
    double y;

    this(double valueX, double valueY) @safe pure nothrow @nogc
    {
        x = valueX;
        y = valueY;
    }

    this(Point value) @safe pure nothrow @nogc
    {
        x = value.x;
        y = value.y;
    }

    PointF opBinary(string op)(PointF rhs) const
    if (op == "+")
    {
        return PointF(x + rhs.x, y + rhs.y);
    }

    PointF opBinary(string op)(PointF rhs) const
    if (op == "-")
    {
        return PointF(x - rhs.x, y - rhs.y);
    }

    Point rounded() const @safe pure nothrow @nogc
    {
        return Point(roundNearest(x), roundNearest(y));
    }

    private static int roundNearest(double value) @safe pure nothrow @nogc
    {
        return value >= 0.0 ? cast(int) (value + 0.5) : cast(int) (value - 0.5);
    }
}

/** Integer width and height. */
struct Size
{
    int width;
    int height;

    bool empty() const @safe pure nothrow @nogc
    {
        return width <= 0 || height <= 0;
    }
}

/**
 * Relationship between Aurora's logical UI coordinates and native framebuffer
 * pixels. Logical coordinates are defined at 96 DPI; renderers always receive
 * physical pixel coordinates.
 */
struct DisplayScale
{
    uint dpiX = LogicalDpi;
    uint dpiY = LogicalDpi;

    static DisplayScale fromDpi(uint x, uint y = 0) @safe pure nothrow @nogc
    {
        DisplayScale result;
        result.dpiX = x == 0 ? LogicalDpi : x;
        result.dpiY = y == 0 ? result.dpiX : y;
        return result;
    }

    double x() const @safe pure nothrow @nogc
    {
        return cast(double) (dpiX == 0 ? LogicalDpi : dpiX) / cast(double) LogicalDpi;
    }

    double y() const @safe pure nothrow @nogc
    {
        return cast(double) (dpiY == 0 ? LogicalDpi : dpiY) / cast(double) LogicalDpi;
    }

    bool isIdentity() const @safe pure nothrow @nogc
    {
        return (dpiX == 0 || dpiX == LogicalDpi) && (dpiY == 0 || dpiY == LogicalDpi);
    }

    int logicalToPhysicalX(double value) const @safe pure nothrow @nogc
    {
        return roundCoordinate(value * x());
    }

    int logicalToPhysicalY(double value) const @safe pure nothrow @nogc
    {
        return roundCoordinate(value * y());
    }

    int physicalToLogicalX(double value) const @safe pure nothrow @nogc
    {
        return floorCoordinate(value / x());
    }

    int physicalToLogicalY(double value) const @safe pure nothrow @nogc
    {
        return floorCoordinate(value / y());
    }

    Point logicalToPhysical(Point value) const @safe pure nothrow @nogc
    {
        return Point(logicalToPhysicalX(value.x), logicalToPhysicalY(value.y));
    }

    Point logicalToPhysical(PointF value) const @safe pure nothrow @nogc
    {
        return Point(logicalToPhysicalX(value.x), logicalToPhysicalY(value.y));
    }

    PointF physicalToLogicalPrecise(Point value) const @safe pure nothrow @nogc
    {
        return PointF(cast(double) value.x / x(), cast(double) value.y / y());
    }

    Point physicalToLogical(Point value) const @safe pure nothrow @nogc
    {
        return Point(physicalToLogicalX(value.x), physicalToLogicalY(value.y));
    }

    Size logicalToPhysical(Size value) const @safe pure nothrow @nogc
    {
        return Size(maxInt(1, logicalToPhysicalX(value.width)),
            maxInt(1, logicalToPhysicalY(value.height)));
    }

    Size physicalToLogical(Size value) const @safe pure nothrow @nogc
    {
        return Size(maxInt(1, roundCoordinate(value.width / x())),
            maxInt(1, roundCoordinate(value.height / y())));
    }

    Rect logicalToPhysical(Rect value) const @safe pure nothrow @nogc
    {
        const left = logicalToPhysicalX(value.x);
        const top = logicalToPhysicalY(value.y);
        const right = logicalToPhysicalX(value.right());
        const bottom = logicalToPhysicalY(value.bottom());
        return Rect(left, top, maxInt(0, right - left), maxInt(0, bottom - top));
    }

    double uniform() const @safe pure nothrow @nogc
    {
        return (x() + y()) * 0.5;
    }

    private static int roundCoordinate(double value) @safe pure nothrow @nogc
    {
        return value >= 0.0 ? cast(int) (value + 0.5) : cast(int) (value - 0.5);
    }

    private static int floorCoordinate(double value) @safe pure nothrow @nogc
    {
        const truncated = cast(int) value;
        return value < cast(double) truncated ? truncated - 1 : truncated;
    }
}

/** Integer rectangle using a half-open right/bottom edge. */
struct Rect
{
    int x;
    int y;
    int width;
    int height;

    int right() const @safe pure nothrow @nogc { return x + width; }
    int bottom() const @safe pure nothrow @nogc { return y + height; }
    bool empty() const @safe pure nothrow @nogc { return width <= 0 || height <= 0; }

    bool contains(Point p) const @safe pure nothrow @nogc
    {
        return p.x >= x && p.y >= y && p.x < right() && p.y < bottom();
    }

    bool contains(int px, int py) const @safe pure nothrow @nogc
    {
        return px >= x && py >= y && px < right() && py < bottom();
    }

    Rect translated(int dx, int dy) const @safe pure nothrow @nogc
    {
        return Rect(x + dx, y + dy, width, height);
    }

    Rect inset(int amount) const @safe pure nothrow @nogc
    {
        return inset(amount, amount, amount, amount);
    }

    Rect inset(int left, int top, int rightInset, int bottomInset) const
        @safe pure nothrow @nogc
    {
        const newWidth = maxInt(0, width - left - rightInset);
        const newHeight = maxInt(0, height - top - bottomInset);
        return Rect(x + left, y + top, newWidth, newHeight);
    }

    Rect intersection(Rect other) const @safe pure nothrow @nogc
    {
        const nx = maxInt(x, other.x);
        const ny = maxInt(y, other.y);
        const nr = minInt(right(), other.right());
        const nb = minInt(bottom(), other.bottom());
        return Rect(nx, ny, maxInt(0, nr - nx), maxInt(0, nb - ny));
    }

    Rect unionRect(Rect other) const @safe pure nothrow @nogc
    {
        if (empty()) return other;
        if (other.empty()) return this;
        const nx = minInt(x, other.x);
        const ny = minInt(y, other.y);
        const nr = maxInt(right(), other.right());
        const nb = maxInt(bottom(), other.bottom());
        return Rect(nx, ny, nr - nx, nb - ny);
    }
}

struct Insets
{
    int left;
    int top;
    int right;
    int bottom;

    this(int all) @safe pure nothrow @nogc
    {
        left = top = right = bottom = all;
    }

    this(int horizontal, int vertical) @safe pure nothrow @nogc
    {
        left = right = horizontal;
        top = bottom = vertical;
    }
}

enum Orientation : ubyte
{
    horizontal,
    vertical
}

enum HorizontalAlign : ubyte
{
    left,
    center,
    right
}

enum VerticalAlign : ubyte
{
    top,
    middle,
    bottom
}

enum CursorKind : ubyte
{
    arrow,
    hand,
    text,
    resizeHorizontal,
    resizeVertical,
    resizeDiagonalNWSE,
    resizeDiagonalNESW,
    move,
    forbidden
}

int minInt(int a, int b) @safe pure nothrow @nogc
{
    return a < b ? a : b;
}

int maxInt(int a, int b) @safe pure nothrow @nogc
{
    return a > b ? a : b;
}

int clampInt(int value, int low, int high) @safe pure nothrow @nogc
{
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

double clampDouble(double value, double low, double high) @safe pure nothrow @nogc
{
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

unittest
{
    auto a = Rect(0, 0, 20, 20);
    auto b = Rect(10, 8, 20, 20);
    assert(a.contains(Point(0, 0)));
    assert(!a.contains(Point(20, 20)));
    assert(a.intersection(b) == Rect(10, 8, 10, 12));

    const scale = DisplayScale.fromDpi(144);
    assert(scale.logicalToPhysical(Size(100, 80)) == Size(150, 120));
    assert(scale.physicalToLogical(Point(149, 74)) == Point(99, 49));
    assert(scale.physicalToLogical(Size(150, 75)) == Size(100, 50));
    assert(scale.logicalToPhysical(Rect(1, 2, 3, 4)) == Rect(2, 3, 4, 6));
}

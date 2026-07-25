module aurora.render.drawlist;

import aurora.color : Color;
import aurora.text.atlas : AtlasGlyph, FontSystem;
import aurora.types : DisplayScale, Point, Rect, Size, clampInt, maxInt, minInt;
import std.math : PI, cos, sin, sqrt;

struct DrawVertex
{
    float x;
    float y;
    float u;
    float v;
    float r;
    float g;
    float b;
    float a;
}

enum DrawBatchKind : ubyte
{
    triangles,
    rgbImage
}

/** One CPU RGB image draw retained alongside vector geometry. */
struct RgbImageCommand
{
    Rect destination;
    Rect clip;
    int width;
    int height;
    ubyte[] pixels;
    bool linearFiltering = true;
}

struct DrawBatch
{
    uint firstIndex;
    uint indexCount;
    Rect clip;
    DrawBatchKind kind = DrawBatchKind.triangles;
    uint imageIndex;
}

/** Ordered 2D triangle stream consumed by every renderer backend. */
final class DrawList
{
    DrawVertex[] vertices;
    uint[] indices;
    DrawBatch[] batches;
    RgbImageCommand[] rgbImages;
    Color clearColor = Color.rgba(0, 0, 0, 0);
    FontSystem fonts;
    Size logicalViewport;
    Size viewport;
    DisplayScale displayScale;

    this(FontSystem fontSystem = null)
    {
        fonts = fontSystem is null ? FontSystem.sharedInstance() : fontSystem;
    }

    void reset(Size size, Color clear)
    {
        reset(size, size, DisplayScale.init, clear);
    }

    /** Reset with distinct logical and physical extents for high-DPI output. */
    void reset(Size logicalSize, Size framebufferSize, DisplayScale scale, Color clear)
    {
        vertices.length = 0;
        indices.length = 0;
        batches.length = 0;
        rgbImages.length = 0;
        logicalViewport = logicalSize;
        viewport = framebufferSize;
        displayScale = scale;
        clearColor = clear;
    }

    bool empty() const @safe pure nothrow @nogc
    {
        return indices.length == 0 && rgbImages.length == 0;
    }

    /** Add an RGB24 image in logical coordinates while preserving draw order. */
    void addRgbImage(Rect destination, int width, int height, ubyte[] pixels,
        Rect clip, bool linearFiltering = true)
    {
        if (destination.empty() || width <= 0 || height <= 0) return;
        const required = cast(size_t) width * cast(size_t) height * 3;
        if (pixels.length < required) return;
        const deviceDestination = logicalToDevice(destination);
        const deviceClip = logicalToDevice(clip);
        if (clippedOut(deviceDestination, deviceClip)) return;

        RgbImageCommand command;
        command.destination = deviceDestination;
        command.clip = deviceClip;
        command.width = width;
        command.height = height;
        command.pixels = pixels;
        command.linearFiltering = linearFiltering;
        const imageIndex = cast(uint) rgbImages.length;
        rgbImages ~= command;

        DrawBatch batch;
        batch.clip = deviceClip;
        batch.kind = DrawBatchKind.rgbImage;
        batch.imageIndex = imageIndex;
        batches ~= batch;
    }

    void addSolidRect(Rect rect, Color color, Rect clip)
    {
        addSolidRectDevice(logicalToDevice(rect), color, logicalToDevice(clip));
    }

    private void addSolidRectDevice(Rect rect, Color color, Rect clip)
    {
        if (rect.empty() || color.a == 0 || clippedOut(rect, clip)) return;
        addQuad(rect, color, color, color, color, 0.5f, 0.5f, 0.5f, 0.5f, clip);
    }

    /** Add one solid logical-space triangle to the ordered stream. */
    void addSolidTriangle(Point a, Point b, Point c, Color color, Rect clip)
    {
        if (color.a == 0) return;
        const da = logicalToDevice(a);
        const db = logicalToDevice(b);
        const dc = logicalToDevice(c);
        const deviceClip = logicalToDevice(clip);
        const left = minInt(da.x, minInt(db.x, dc.x));
        const top = minInt(da.y, minInt(db.y, dc.y));
        const right = maxInt(da.x, maxInt(db.x, dc.x));
        const bottom = maxInt(da.y, maxInt(db.y, dc.y));
        if (clippedOut(Rect(left, top, maxInt(1, right - left + 1),
            maxInt(1, bottom - top + 1)), deviceClip)) return;
        const firstIndex = cast(uint) indices.length;
        indices ~= addVertex(vertex(da.x, da.y, 0.5f, 0.5f, color));
        indices ~= addVertex(vertex(db.x, db.y, 0.5f, 0.5f, color));
        indices ~= addVertex(vertex(dc.x, dc.y, 0.5f, 0.5f, color));
        finishBatch(firstIndex, deviceClip);
    }

    void addVerticalGradient(Rect rect, Color top, Color bottom, Rect clip)
    {
        addVerticalGradientDevice(logicalToDevice(rect), top, bottom, logicalToDevice(clip));
    }

    private void addVerticalGradientDevice(Rect rect, Color top, Color bottom, Rect clip)
    {
        if (rect.empty() || clippedOut(rect, clip)) return;
        addQuad(rect, top, top, bottom, bottom, 0.5f, 0.5f, 0.5f, 0.5f, clip);
    }

    void addTexturedRect(Rect rect, AtlasGlyph glyph, Color color, Rect clip)
    {
        addTexturedRectDevice(logicalToDevice(rect), glyph, color, logicalToDevice(clip));
    }

    /** Add an atlas quad whose destination and clip are already framebuffer pixels. */
    void addTexturedRectDevice(Rect rect, AtlasGlyph glyph, Color color, Rect clip)
    {
        if (rect.empty() || !glyph.hasPixels() || color.a == 0 || clippedOut(rect, clip)) return;
        const u0 = cast(float) glyph.region.x;
        const v0 = cast(float) glyph.region.y;
        const u1 = cast(float) glyph.region.right();
        const v1 = cast(float) glyph.region.bottom();
        addQuad(rect, color, color, color, color, u0, v0, u1, v1, clip);
    }

    void addLine(Point from, Point to, Color color, int thickness, Rect clip)
    {
        addLineDevice(logicalToDevice(from), logicalToDevice(to), color,
            logicalLengthToDevice(thickness), logicalToDevice(clip));
    }

    private void addLineDevice(Point from, Point to, Color color, int thickness, Rect clip)
    {
        if (color.a == 0) return;
        thickness = maxInt(1, thickness);
        const dx = cast(double) to.x - from.x;
        const dy = cast(double) to.y - from.y;
        const length = sqrt(dx * dx + dy * dy);
        if (length < 0.0001)
        {
            addSolidRectDevice(Rect(from.x - thickness / 2, from.y - thickness / 2,
                thickness, thickness), color, clip);
            return;
        }
        const half = cast(double) thickness * 0.5;
        const nx = -dy / length * half;
        const ny = dx / length * half;
        DrawVertex[4] quad;
        quad[0] = vertex(from.x + nx, from.y + ny, 0.5f, 0.5f, color);
        quad[1] = vertex(to.x + nx, to.y + ny, 0.5f, 0.5f, color);
        quad[2] = vertex(to.x - nx, to.y - ny, 0.5f, 0.5f, color);
        quad[3] = vertex(from.x - nx, from.y - ny, 0.5f, 0.5f, color);
        addQuadVertices(quad, clip);
    }

    void addCircle(Point center, int radius, Color color, Rect clip)
    {
        addCircleDevice(logicalToDevice(center), logicalLengthToDevice(radius), color,
            logicalToDevice(clip));
    }

    private void addCircleDevice(Point center, int radius, Color color, Rect clip)
    {
        if (radius <= 0 || color.a == 0) return;
        const bounds = Rect(center.x - radius, center.y - radius, radius * 2, radius * 2);
        if (clippedOut(bounds, clip)) return;
        const segments = clampInt(radius * 2, 16, 72);
        const firstIndex = cast(uint) indices.length;
        const centerIndex = addVertex(vertex(center.x, center.y, 0.5f, 0.5f, color));
        uint firstBoundary;
        uint previous;
        foreach (segment; 0 .. segments)
        {
            const angle = -PI / 2.0 + 2.0 * PI * segment / segments;
            const index = addVertex(vertex(center.x + cos(angle) * radius,
                center.y + sin(angle) * radius, 0.5f, 0.5f, color));
            if (segment == 0) firstBoundary = index;
            else
            {
                indices ~= centerIndex;
                indices ~= previous;
                indices ~= index;
            }
            previous = index;
        }
        indices ~= centerIndex;
        indices ~= previous;
        indices ~= firstBoundary;
        finishBatch(firstIndex, clip);
    }

    void addCircleStroke(Point center, int radius, Color color, int thickness, Rect clip)
    {
        addCircleStrokeDevice(logicalToDevice(center), logicalLengthToDevice(radius), color,
            logicalLengthToDevice(thickness), logicalToDevice(clip));
    }

    private void addCircleStrokeDevice(Point center, int radius, Color color,
        int thickness, Rect clip)
    {
        if (radius <= 0 || color.a == 0) return;
        thickness = maxInt(1, thickness);
        const inner = maxInt(0, radius - thickness);
        if (inner == 0)
        {
            addCircleDevice(center, radius, color, clip);
            return;
        }
        const bounds = Rect(center.x - radius, center.y - radius, radius * 2, radius * 2);
        if (clippedOut(bounds, clip)) return;
        const segments = clampInt(radius * 2, 16, 72);
        const firstIndex = cast(uint) indices.length;
        uint firstOuter;
        uint firstInner;
        uint previousOuter;
        uint previousInner;
        foreach (segment; 0 .. segments)
        {
            const angle = -PI / 2.0 + 2.0 * PI * segment / segments;
            const outer = addVertex(vertex(center.x + cos(angle) * radius,
                center.y + sin(angle) * radius, 0.5f, 0.5f, color));
            const inside = addVertex(vertex(center.x + cos(angle) * inner,
                center.y + sin(angle) * inner, 0.5f, 0.5f, color));
            if (segment == 0)
            {
                firstOuter = outer;
                firstInner = inside;
            }
            else
            {
                addRingIndices(previousOuter, previousInner, outer, inside);
            }
            previousOuter = outer;
            previousInner = inside;
        }
        addRingIndices(previousOuter, previousInner, firstOuter, firstInner);
        finishBatch(firstIndex, clip);
    }

    void addRoundedRect(Rect rect, int radius, Color color, Rect clip)
    {
        addRoundedRectDevice(logicalToDevice(rect), logicalLengthToDevice(radius), color,
            logicalToDevice(clip));
    }

    private void addRoundedRectDevice(Rect rect, int radius, Color color, Rect clip)
    {
        if (rect.empty() || color.a == 0 || clippedOut(rect, clip)) return;
        radius = clampInt(radius, 0, minInt(rect.width, rect.height) / 2);
        if (radius <= 0)
        {
            addSolidRectDevice(rect, color, clip);
            return;
        }

        // Keep the large interior on the software renderer's rectangular
        // fast path. A center-to-perimeter fan gives every rounded-corner
        // triangle a large bounding box, which makes full-window redraws
        // unnecessarily expensive even though only the corners are curved.
        addSolidRectDevice(Rect(rect.x + radius, rect.y,
            maxInt(0, rect.width - radius * 2), rect.height), color, clip);
        addSolidRectDevice(Rect(rect.x, rect.y + radius, radius,
            maxInt(0, rect.height - radius * 2)), color, clip);
        addSolidRectDevice(Rect(rect.right() - radius, rect.y + radius, radius,
            maxInt(0, rect.height - radius * 2)), color, clip);

        const steps = clampInt(radius / 2 + 2, 3, 12);
        const firstIndex = cast(uint) indices.length;
        addCornerFan(rect.x + radius, rect.y + radius, radius,
            PI, PI * 1.5, steps, color);
        addCornerFan(rect.right() - radius, rect.y + radius, radius,
            -PI / 2.0, 0.0, steps, color);
        addCornerFan(rect.right() - radius, rect.bottom() - radius, radius,
            0.0, PI / 2.0, steps, color);
        addCornerFan(rect.x + radius, rect.bottom() - radius, radius,
            PI / 2.0, PI, steps, color);
        finishBatch(firstIndex, clip);
    }

    /** Convert a logical Aurora coordinate to a framebuffer pixel boundary. */
    int logicalToDeviceX(double value) const @safe pure nothrow @nogc
    {
        return displayScale.logicalToPhysicalX(value);
    }

    /** Convert a logical Aurora coordinate to a framebuffer pixel boundary. */
    int logicalToDeviceY(double value) const @safe pure nothrow @nogc
    {
        return displayScale.logicalToPhysicalY(value);
    }

    Point logicalToDevice(Point value) const @safe pure nothrow @nogc
    {
        return displayScale.logicalToPhysical(value);
    }

    Rect logicalToDevice(Rect value) const @safe pure nothrow @nogc
    {
        return displayScale.logicalToPhysical(value);
    }

    int logicalLengthToDevice(int value) const @safe pure nothrow @nogc
    {
        if (value <= 0) return 0;
        const x = displayScale.logicalToPhysicalX(value);
        const y = displayScale.logicalToPhysicalY(value);
        return maxInt(1, (x + y + 1) / 2);
    }

    private void addQuad(Rect rect, Color c0, Color c1, Color c2, Color c3,
        float u0, float v0, float u1, float v1, Rect clip)
    {
        DrawVertex[4] quad;
        quad[0] = vertex(rect.x, rect.y, u0, v0, c0);
        quad[1] = vertex(rect.right(), rect.y, u1, v0, c1);
        quad[2] = vertex(rect.right(), rect.bottom(), u1, v1, c2);
        quad[3] = vertex(rect.x, rect.bottom(), u0, v1, c3);
        addQuadVertices(quad, clip);
    }

    private void addQuadVertices(ref DrawVertex[4] quad, Rect clip)
    {
        const firstIndex = cast(uint) indices.length;
        const base = cast(uint) vertices.length;
        vertices ~= quad[];
        indices ~= base;
        indices ~= base + 1;
        indices ~= base + 2;
        indices ~= base;
        indices ~= base + 2;
        indices ~= base + 3;
        finishBatch(firstIndex, clip);
    }

    private uint addVertex(DrawVertex value)
    {
        const result = cast(uint) vertices.length;
        vertices ~= value;
        return result;
    }

    private void addRingIndices(uint outer0, uint inner0, uint outer1, uint inner1)
    {
        indices ~= outer0;
        indices ~= outer1;
        indices ~= inner1;
        indices ~= outer0;
        indices ~= inner1;
        indices ~= inner0;
    }

    private void finishBatch(uint firstIndex, Rect clip)
    {
        const count = cast(uint) indices.length - firstIndex;
        if (count == 0) return;
        if (batches.length > 0)
        {
            const lastIndex = batches.length - 1;
            if (batches[lastIndex].kind == DrawBatchKind.triangles &&
                batches[lastIndex].clip == clip &&
                batches[lastIndex].firstIndex + batches[lastIndex].indexCount == firstIndex)
            {
                batches[lastIndex].indexCount += count;
                return;
            }
        }
        DrawBatch batch;
        batch.firstIndex = firstIndex;
        batch.indexCount = count;
        batch.clip = clip;
        batch.kind = DrawBatchKind.triangles;
        batches ~= batch;
    }

    private static bool clippedOut(Rect rect, Rect clip) @safe pure nothrow @nogc
    {
        return rect.intersection(clip).empty();
    }

    private static DrawVertex vertex(double x, double y, float u, float v, Color color)
        @safe pure nothrow @nogc
    {
        return DrawVertex(cast(float) x, cast(float) y, u, v,
            color.r / 255.0f, color.g / 255.0f, color.b / 255.0f, color.a / 255.0f);
    }

    private void addCornerFan(double cx, double cy, double radius,
        double start, double end, int steps, Color color)
    {
        const center = addVertex(vertex(cx, cy, 0.5f, 0.5f, color));
        uint previous;
        foreach (step; 0 .. steps + 1)
        {
            const t = cast(double) step / steps;
            const angle = start + (end - start) * t;
            const current = addVertex(vertex(cx + cos(angle) * radius,
                cy + sin(angle) * radius, 0.5f, 0.5f, color));
            if (step > 0)
            {
                indices ~= center;
                indices ~= previous;
                indices ~= current;
            }
            previous = current;
        }
    }
}

unittest
{
    auto list = new DrawList();
    list.reset(Size(100, 100), Color.rgb(0, 0, 0));
    list.addSolidRect(Rect(2, 3, 20, 10), Color.rgb(255, 0, 0), Rect(0, 0, 100, 100));
    assert(list.vertices.length == 4);
    assert(list.indices.length == 6);
    assert(list.batches.length == 1);

    list.reset(Size(100, 80), Size(150, 120), DisplayScale.fromDpi(144),
        Color.rgb(0, 0, 0));
    list.addSolidRect(Rect(1, 2, 3, 4), Color.rgb(255, 255, 255),
        Rect(0, 0, 100, 80));
    assert(list.viewport == Size(150, 120));
    assert(list.logicalViewport == Size(100, 80));
    assert(list.vertices[0].x == 2.0f && list.vertices[0].y == 3.0f);
    assert(list.vertices[2].x == 6.0f && list.vertices[2].y == 9.0f);
    assert(list.batches[0].clip == Rect(0, 0, 150, 120));
}

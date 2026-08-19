module auroraweb.paint;

/**
 * Render a laid-out DOM tree into an Aurora `Surface`/`Canvas`.
 *
 * Walks the tree in paint order (element then descendants), drawing:
 *
 * - background color for elements with a non-transparent background;
 * - borders (currently a single 1px line around the content box);
 * - inline text using Aurora's text layout so shaping, bidi and wrapping are
 *   the same as everywhere else in Aurora;
 * - `img` elements' `alt`/`src` (the `src` is left to the loader/network layer
 *   to fetch and set into an `RgbaImage`; paint draws it when present);
 * - `hr`, `br` spacing.
 *
 * Painting is deterministic and uses only the element boxes already computed
 * by `auroraweb.layout`.
 */

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.font : FontRole;
import aurora.image : RgbaImage;
import aurora.text.layout : TextLayout, TextLayoutOptions;
import aurora.types : Point, Rect;
import auroraweb.dom : ComputedStyle, Element, TextNode;

import std.conv : to;
import std.string : indexOf, lastIndexOf, split, startsWith, strip, toLower;
import std.algorithm : max;
import std.math : abs;

/// Paint a full tree into a surface's canvas.
void paintTree(Element root, Canvas canvas)
{
    paintElement(root, canvas);
}

/// Paint one element (and its children). Boxes carry absolute coordinates.
private void paintElement(Element element, Canvas canvas)
{
    if (element.style.display == "none" || element.style.visibility == "hidden")
        return;

    const absX = element.box.x;
    const absY = element.box.y;

    // Background
    const bg = parseColor(element.style.background);
    if (bg.present)
    {
        canvas.fillRect(Rect(absX, absY,
            element.box.width, element.box.height), bg.color);
    }

    // CSS background-image (drawn over the solid background color).
    auto bgImage = cast(RgbaImage) element.backgroundImage;
    if (bgImage !is null)
    {
        auto dst = backgroundDestRect(element, bgImage);
        if (dst.width > 0 && dst.height > 0)
            canvas.drawImage(dst, bgImage);
    }

    // Border: draw per-side using the box's border widths.
    const bColor = parseColorOrDefault(element.style.borderColor, Color.rgb(0, 0, 0));
    if (element.box.borderTop > 0)
        canvas.fillRect(Rect(absX, absY, element.box.width, element.box.borderTop), bColor);
    if (element.box.borderBottom > 0)
        canvas.fillRect(Rect(absX, absY + element.box.height - element.box.borderBottom,
            element.box.width, element.box.borderBottom), bColor);
    if (element.box.borderLeft > 0)
        canvas.fillRect(Rect(absX, absY, element.box.borderLeft, element.box.height), bColor);
    if (element.box.borderRight > 0)
        canvas.fillRect(Rect(absX + element.box.width - element.box.borderRight, absY,
            element.box.borderRight, element.box.height), bColor);

    const innerX = absX + element.box.paddingLeft + element.box.borderLeft;
    const innerY = absY + element.box.paddingTop + element.box.borderTop;
    const innerWidth = max(0, element.box.width - element.box.paddingLeft - element.box.paddingRight);

    // Text children inline — use layout-assigned positions (absolute).
    if (element.tag != "img" && element.tag != "input")
    {
        foreach (child; element.children)
        {
            auto text = cast(TextNode) child;
            if (text !is null)
            {
                drawTextRun(canvas, text.data, Point(text.layoutX, text.layoutY),
                    element.style, innerWidth);
                continue;
            }
        }
    }

    // Image element
    if (element.tag == "img" && (element.box.width > 0 && element.box.height > 0))
    {
        auto image = cast(RgbaImage) element.image;
        if (image !is null)
            canvas.drawImage(Rect(absX, absY, element.box.width, element.box.height), image);
        else
        {
            // Placeholder box while the image loads.
            canvas.fillRect(Rect(absX, absY, element.box.width, element.box.height),
                Color.rgb(220, 220, 220));
        }
    }

    // hr
    if (element.tag == "hr" && element.box.height > 0)
    {
        canvas.drawLine(Point(absX, absY + element.box.height / 2),
            Point(absX + element.box.width, absY + element.box.height / 2),
            Color.rgb(120, 120, 120));
    }

    // Children
    foreach (child; element.elements)
        paintElement(child, canvas);
}

/// Compute the destination rect for a CSS background-image honoring
/// `background-size`: cover, contain, an explicit pixel pair, a single
/// pixel length (height keeps aspect ratio), or auto (intrinsic size).
private Rect backgroundDestRect(Element element, RgbaImage image)
{
    const boxX = element.box.x;
    const boxY = element.box.y;
    const boxW = element.box.width;
    const boxH = element.box.height;
    const imgW = image.width();
    const imgH = image.height();
    const size = element.style.backgroundSize.toLower().strip();

    int w = imgW;
    int h = imgH;
    if (size == "cover" || size == "contain")
    {
        if (boxW <= 0 || boxH <= 0) return Rect(boxX, boxY, 0, 0);
        const scaleW = cast(double) boxW / imgW;
        const scaleH = cast(double) boxH / imgH;
        double scale = size == "cover"
            ? (scaleW > scaleH ? scaleW : scaleH)
            : (scaleW < scaleH ? scaleW : scaleH);
        if (size == "cover")
        {
            // cover: at least one dimension exactly fills the box; the other
            // may overflow (cropped).
            w = cast(int)(imgW * scale);
            h = cast(int)(imgH * scale);
        }
        else
        {
            // contain: fit fully inside the box.
            w = cast(int)(imgW * scale);
            h = cast(int)(imgH * scale);
        }
    }
    else if (size != "auto" && size.length)
    {
        auto parts = size.split();
        if (parts.length == 1)
        {
            // Single length: width is explicit, height preserves the ratio.
            auto wp = parts[0];
            if (wp.length >= 2 && wp[$ - 2 .. $] == "px")
                w = wp[0 .. $ - 2].strip().to!int;
            if (w > 0)
                h = (imgH * w) / imgW;
        }
        else if (parts.length >= 2)
        {
            auto wp = parts[0];
            auto hp = parts[1];
            if (wp.length >= 2 && wp[$ - 2 .. $] == "px")
                w = wp[0 .. $ - 2].strip().to!int;
            if (hp.length >= 2 && hp[$ - 2 .. $] == "px")
                h = hp[0 .. $ - 2].strip().to!int;
        }
    }

    if (w <= 0 || h <= 0) return Rect(boxX, boxY, 0, 0);

    // Center the image within the box.
    int x = boxX + (boxW - w) / 2;
    int y = boxY + (boxH - h) / 2;
    return Rect(x, y, w, h);
}

/// Draw a text run using Aurora's TextLayout, wrapped at the given width.
/// Uses the SAME shaping call as layout (`textEngine.layout` with an explicit
/// pixelSize) so paint and layout agree; `canvas.layoutText` takes a
/// typographic *scale* (2 = body ~17px), not a pixel size.
private void drawTextRun(Canvas canvas, string text, Point origin,
    ComputedStyle style, int maxWidth)
{
    if (text.length == 0) return;

    // Parse font size from style.
    auto px = style.pxLength(style.fontSize);
    auto pixelSize = px >= 0 ? px : 16;

    dchar[] dtext;
    foreach (ch; text) dtext ~= ch;

    import aurora.text.layout : TextLayoutOptions;
    import aurora.text.atlas : FontSystem;
    TextLayoutOptions options;
    options.role = FontRole.ui;
    options.pixelSize = max(1, pixelSize);
    options.maxWidth = maxWidth;
    options.wrap = maxWidth > 0;
    auto layout = FontSystem.sharedInstance().textEngine.layout(dtext, options);
    canvas.drawLayout(origin, layout, parseColorOrDefault(style.color, Color.rgb(0, 0, 0)));
}

private struct NullableColor
{
    Color color;
    bool present;
}

private NullableColor parseColor(string value)
{
    if (value.length == 0 || value == "transparent") return NullableColor.init;
    const v = value.strip().toLower();
    if (v[0] == '#')
    {
        if (v.length == 4)
        {
            return NullableColor(Color.rgb(
                hexDigit(v[1]) * 17,
                hexDigit(v[2]) * 17,
                hexDigit(v[3]) * 17), true);
        }
        if (v.length == 7)
        {
            return NullableColor(Color.rgb(
                (hexDigit(v[1]) << 4) | hexDigit(v[2]),
                (hexDigit(v[3]) << 4) | hexDigit(v[4]),
                (hexDigit(v[5]) << 4) | hexDigit(v[6])), true);
        }
        return NullableColor.init;
    }
    // rgb()/rgba()/hsl()/hsla()
    if (v.startsWith("rgba") || v.startsWith("rgb(") || v.startsWith("hsl") || v.startsWith("hsla"))
    {
        import std.conv : to;
        auto open = indexOf(v, "(");
        auto close = indexOf(v, ")");
        if (open >= 0 && close > open)
        {
            auto fn = v[0 .. open];
            auto args = v[open + 1 .. close];
            // Replace any '/' separators and collapse whitespace.
            string[] parts;
            foreach (p; args.split(","))
            {
                auto q = p.strip();
                auto slash = indexOf(q, "/");
                if (slash >= 0)
                {
                    parts ~= q[0 .. slash].strip();
                    parts ~= q[slash + 1 .. $].strip();
                }
                else if (q.length) parts ~= q;
            }
            int r, g, b;
            double a = 1.0;
            if (fn.startsWith("hsl"))
            {
                // hsl(h, s%, l%) / hsla(h, s%, l%, a)
                auto h = parts.length > 0 ? parts[0].to!double : 0.0;
                auto s = parts.length > 1 ? parsePercent(parts[1]) : 0.0;
                auto l = parts.length > 2 ? parsePercent(parts[2]) : 0.0;
                auto rgb = hslToRgb(h, s, l);
                r = rgb.r; g = rgb.g; b = rgb.b;
                if (parts.length > 3) a = parseAlpha(parts[3]);
            }
            else
            {
                auto rc = parts.length > 0 ? parseChannel(parts[0]) : 0;
                auto gc = parts.length > 1 ? parseChannel(parts[1]) : 0;
                auto bc = parts.length > 2 ? parseChannel(parts[2]) : 0;
                r = rc; g = gc; b = bc;
                if (parts.length > 3) a = parseAlpha(parts[3]);
            }
            return NullableColor(Color.rgba(r, g, b, cast(int)(a * 255)), true);
        }
        return NullableColor.init;
    }
    switch (v)
    {
        case "red": return NullableColor(Color.rgb(255, 0, 0), true);
        case "green": return NullableColor(Color.rgb(0, 128, 0), true);
        case "blue": return NullableColor(Color.rgb(0, 0, 255), true);
        case "black": return NullableColor(Color.rgb(0, 0, 0), true);
        case "white": return NullableColor(Color.rgb(255, 255, 255), true);
        case "gray", "grey": return NullableColor(Color.rgb(128, 128, 128), true);
        case "silver": return NullableColor(Color.rgb(192, 192, 192), true);
        case "maroon": return NullableColor(Color.rgb(128, 0, 0), true);
        case "purple": return NullableColor(Color.rgb(128, 0, 128), true);
        case "fuchsia": return NullableColor(Color.rgb(255, 0, 255), true);
        case "lime": return NullableColor(Color.rgb(0, 255, 0), true);
        case "olive": return NullableColor(Color.rgb(128, 128, 0), true);
        case "yellow": return NullableColor(Color.rgb(255, 255, 0), true);
        case "navy": return NullableColor(Color.rgb(0, 0, 128), true);
        case "teal": return NullableColor(Color.rgb(0, 128, 128), true);
        case "aqua", "cyan": return NullableColor(Color.rgb(0, 255, 255), true);
        case "orange": return NullableColor(Color.rgb(255, 165, 0), true);
        default: return NullableColor.init;
    }
}

private Color parseColorOrDefault(string value, Color fallback)
{
    auto c = parseColor(value);
    return c.present ? c.color : fallback;
}

private int hexDigit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

/// Parse a percentage value like "50%" into 0..100 (or a bare 0..255 int).
private int parseChannel(string s)
{
    import std.conv : to;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return (t[0 .. $ - 1].strip().to!int * 255) / 100;
    return t.to!int;
}

private double parsePercent(string s)
{
    import std.conv : to;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return t[0 .. $ - 1].strip().to!double / 100.0;
    return t.to!double;
}

private double parseAlpha(string s)
{
    import std.conv : to;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return t[0 .. $ - 1].strip().to!double / 100.0;
    return t.to!double;
}

/// Convert HSL (h in degrees, s/l in 0..1) to an RGB tuple.
private Color hslToRgb(double h, double s, double l)
{
    // Normalize hue.
    h = h % 360.0;
    if (h < 0) h += 360.0;
    double c = (1.0 - (2.0 * l - 1.0).abs) * s;
    double hp = h / 60.0;
    double x = c * (1.0 - ((hp % 2.0) - 1.0).abs);
    double r1 = 0, g1 = 0, b1 = 0;
    if (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else { r1 = c; b1 = x; }
    double m = l - c / 2.0;
    return Color.rgb(cast(int)((r1 + m) * 255), cast(int)((g1 + m) * 255), cast(int)((b1 + m) * 255));
}

unittest
{
    auto c1 = parseColor("rgb(10, 20, 30)");
    assert(c1.present && c1.color.r == 10 && c1.color.g == 20 && c1.color.b == 30, "rgb parse");
    auto c2 = parseColor("rgba(255, 0, 0, 0.5)");
    assert(c2.present && c2.color.r == 255 && c2.color.a == 127, "rgba alpha");
    auto c3 = parseColor("hsl(0, 100%, 50%)");
    assert(c3.present && c3.color.r == 255 && c3.color.g == 0 && c3.color.b == 0, "hsl red");
    auto c4 = parseColor("hsla(120, 100%, 50%, 1.0)");
    assert(c4.present && c4.color.g == 255, "hsla green");
}

unittest
{
    import aurora.surface : Surface;
    import aurora.render.drawlist : DrawList;
    import aurora.render.software : SoftwareRenderer;
    import aurora.types : Size;
    import std.conv : to;

    // Paint an element with a small RgbaImage as background-image and verify
    // pixels actually change inside its box.
    {
        // A 4x4 bright red opaque image.
        ubyte[4 * 4 * 4] pixels;
        foreach (i, ref p; pixels)
        {
            switch (i % 4)
            {
                case 0: p = 255; break;      // R
                case 1: p = 0; break;        // G
                case 2: p = 0; break;        // B
                default: p = 255; break;     // A
            }
        }
        auto img = new RgbaImage(4, 4, pixels);

        auto element = new Element("div");
        element.style.display = "block";
        element.style.background = "rgb(0, 0, 255)";
        element.style.backgroundSize = "auto";
        element.backgroundImage = img;
        element.box.x = 10;
        element.box.y = 10;
        element.box.width = 40;
        element.box.height = 40;

        auto surface = new Surface(80, 80);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(element, canvas);

        // The box should now contain red background-image pixels (not the
        // original white, and not the blue background at its center). With
        // background-size:auto the 4x4 image is drawn at intrinsic size,
        // centered: rect (28,28)-(32,32).
        auto p = surface.pixel(30, 30);
        assert((p & 0xff) == 0, "blue channel should be 0 (red image), got " ~ (p & 0xff).to!string);
        assert(((p >> 16) & 0xff) >= 250, "red channel should be ~255, got " ~ ((p >> 16) & 0xff).to!string);
        // The image was drawn over the blue solid background.
        auto corner = surface.pixel(12, 12);
        assert((corner & 0xff) >= 250, "blue background should show at the corner, got " ~ (corner & 0xff).to!string);
    }

    // background-size: cover scales the image to fill the box (aspect kept).
    {
        ubyte[4 * 4 * 4] pixels;
        foreach (i, ref p; pixels)
        {
            switch (i % 4)
            {
                case 0: p = 0; break;
                case 1: p = 255; break;
                case 2: p = 0; break;
                default: p = 255; break;
            }
        }
        auto img = new RgbaImage(4, 4, pixels);

        auto element = new Element("div");
        element.style.display = "block";
        element.style.backgroundSize = "cover";
        element.backgroundImage = img;
        element.box.x = 0;
        element.box.y = 0;
        element.box.width = 80;
        element.box.height = 40;

        auto surface = new Surface(80, 80);
        surface.clear(Color.rgb(0, 0, 0));
        auto canvas = Canvas(surface);
        paintElement(element, canvas);

        // cover on a 2:1 box with a 1:1 image scales to 80x80, so the center
        // horizontal band is filled with the (green) image and the vertical
        // edges are cropped.
        auto mid = surface.pixel(40, 20);
        assert(((mid >> 8) & 0xff) >= 250, "cover should fill the middle with green, got " ~ ((mid >> 8) & 0xff).to!string);
    }
}

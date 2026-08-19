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
import std.algorithm : max, min, sort;
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
    const width = element.box.width;
    const height = element.box.height;

    // box-shadow: a semi-transparent copy of the box offset by (H,V), painted
    // BEHIND the element so its corners round like the box they come from.
    paintShadow(element, canvas, absX, absY, width, height);

    const radius = roundedRadius(element, width, height);

    // Background (rounded corners when border-radius > 0).
    const bg = parseColor(element.style.background);
    if (bg.present)
    {
        if (radius > 0)
            canvas.fillRoundedRect(Rect(absX, absY, width, height), radius,
                withOpacity(bg.color, element.style.opacity));
        else
            canvas.fillRect(Rect(absX, absY, width, height),
                withOpacity(bg.color, element.style.opacity));
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
    const bColor = withOpacity(parseColorOrDefault(element.style.borderColor,
        Color.rgb(0, 0, 0)), element.style.opacity);
    if (element.box.borderTop > 0)
        canvas.fillRect(Rect(absX, absY, width, element.box.borderTop), bColor);
    if (element.box.borderBottom > 0)
        canvas.fillRect(Rect(absX, absY + height - element.box.borderBottom,
            width, element.box.borderBottom), bColor);
    if (element.box.borderLeft > 0)
        canvas.fillRect(Rect(absX, absY, element.box.borderLeft, height), bColor);
    if (element.box.borderRight > 0)
        canvas.fillRect(Rect(absX + width - element.box.borderRight, absY,
            element.box.borderRight, height), bColor);

    const innerX = absX + element.box.paddingLeft + element.box.borderLeft;
    const innerY = absY + element.box.paddingTop + element.box.borderTop;
    const innerWidth = max(0, width - element.box.paddingLeft - element.box.paddingRight);

    // display:list-item — draw a small filled bullet at the left of the content
    // edge (roughly the first line's box height from the top).
    if (element.style.display == "list-item")
    {
        auto bulletColor = parseColorOrDefault(element.style.color, Color.rgb(0, 0, 0));
        const int bulletR = 3;
        const int bulletCX = innerX + bulletR + 2;
        const int bulletCY = innerY + bulletR + 2;
        canvas.fillCircle(Point(bulletCX, bulletCY), bulletR,
            withOpacity(bulletColor, element.style.opacity));
    }

    // Text children inline — use layout-assigned positions (absolute).
    if (element.tag != "img" && element.tag != "input")
    {
        foreach (child; element.children)
        {
            auto text = cast(TextNode) child;
            if (text !is null)
            {
                drawTextRun(canvas, text.data, Point(text.layoutX, text.layoutY),
                    element.style, innerWidth, text);
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

    // Children, positioned elements painted last and sorted by z-index
    // (higher z-index on top).
    if (element.style.display != "inline" &&
        element.style.display != "inline-block" &&
        element.style.display != "inline-flex")
    {
        Element[] normal;
        Element[] positioned;
        foreach (child; element.elements)
        {
            auto childStyle = child.style;
            if (childStyle.isPositioned())
                positioned ~= child;
            else
                normal ~= child;
        }
        if (positioned.length > 1)
            positioned.sort!(q{ a.style.zIndex < b.style.zIndex })();
        foreach (child; normal)
            paintElement(child, canvas);
        foreach (child; positioned)
            paintElement(child, canvas);
    }
    else
    {
        foreach (child; element.elements)
            paintElement(child, canvas);
    }
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
        import auroraweb.dom : cssInt;
        auto parts = size.split();
        if (parts.length == 1)
        {
            // Single length: width is explicit, height preserves the ratio.
            auto wp = parts[0];
            if (wp.length >= 2 && wp[$ - 2 .. $] == "px")
                w = cssInt(wp[0 .. $ - 2].strip());
            if (w > 0)
                h = (imgH * w) / imgW;
        }
        else if (parts.length >= 2)
        {
            auto wp = parts[0];
            auto hp = parts[1];
            if (wp.length >= 2 && wp[$ - 2 .. $] == "px")
                w = cssInt(wp[0 .. $ - 2].strip());
            if (hp.length >= 2 && hp[$ - 2 .. $] == "px")
                h = cssInt(hp[0 .. $ - 2].strip());
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
    ComputedStyle style, int maxWidth, TextNode node)
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
    auto color = parseColorOrDefault(style.color, Color.rgb(0, 0, 0));
    if (style.opacity < 1.0)
        color = withOpacity(color, style.opacity);
    canvas.drawLayout(origin, layout, color);

    // text-decoration: underline / line-through / overline.
    if (style.textDecoration != "none" && node !is null && node.layoutWidth > 0)
    {
        const int x0 = origin.x;
        const int x1 = origin.x + node.layoutWidth;
        // The layout's ascent puts the baseline near the bottom of the em box.
        int baseline = origin.y + pixelSize - 3;
        if (style.textDecoration == "underline")
            baseline += 1;
        else if (style.textDecoration == "overline")
            baseline = origin.y + 1;
        canvas.drawLine(Point(x0, baseline), Point(x1, baseline), color);
    }
}

/// The element's border-radius in px (0 when not rounded). The single-value
/// and four-value syntaxes (`Npx Npx Npx Npx` = top-left top-right bottom-right
/// bottom-left) are parsed; the largest corner radius drives the paint pass.
private int roundedRadius(Element element, int width, int height)
{
    import auroraweb.dom : cssInt;
    const s = element.style.borderRadius.strip();
    if (s.length == 0 || s == "0") return 0;
    auto parts = s.split();
    int r = 0;
    foreach (part; parts)
    {
        auto t = part.strip();
        if (t.length >= 2 && t[$ - 2 .. $] == "px")
            r = max(r, cssInt(t[0 .. $ - 2].strip()));
        else if (t.length >= 1 && t[$ - 1] == '%')
            r = max(r, (min(width, height) * cssInt(t[0 .. $ - 1].strip())) / 100);
        else
            r = max(r, cssInt(t));
    }
    return r;
}

/// Scale a color's alpha by the element's opacity (0..1).
private Color withOpacity(Color c, double opacity)
{
    if (opacity >= 1.0) return c;
    if (opacity <= 0.0) return Color(c.r, c.g, c.b, 0);
    return Color(c.r, c.g, c.b, cast(ubyte) (c.a * opacity));
}

/// Paint a simple box-shadow behind the element: a semi-transparent copy of
/// the box offset by (H,V). A 3-rect approximation approximates a small blur.
private void paintShadow(Element element, Canvas canvas,
    int absX, int absY, int width, int height)
{
    const shadow = element.style.boxShadowColor;
    if (shadow == "none") return;
    const offX = element.style.pxLength(element.style.boxShadowH);
    const offY = element.style.pxLength(element.style.boxShadowV);
    const blur = element.style.pxLength(element.style.boxShadowBlur);
    if (offX < 0) return;   // negative offsets unsupported; ignore.
    if (width <= 0 || height <= 0) return;

    auto color = parseColorOrDefault(shadow, Color.rgba(0, 0, 0, 76));
    const sx = absX + offX;
    const sy = absY + offY;
    const radius = roundedRadius(element, width, height);
    // 3-rect blur approximation: a soft core with two fainter outer rims.
    if (blur > 0)
    {
        const core = withOpacity(color, 0.5);
        const mid = withOpacity(color, 0.25);
        const outer = withOpacity(color, 0.12);
        canvas.fillRoundedRect(Rect(sx, sy, width, height), radius, outer);
        canvas.fillRoundedRect(Rect(sx, sy, width, height), radius, mid);
        canvas.fillRoundedRect(Rect(sx, sy, width, height), radius, core);
    }
    else
    {
        canvas.fillRoundedRect(Rect(sx, sy, width, height), radius, color);
    }
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
    import auroraweb.dom : cssInt;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return (cssInt(t[0 .. $ - 1].strip()) * 255) / 100;
    return cssInt(t);
}

private double parsePercent(string s)
{
    import auroraweb.dom : cssDouble;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return cssDouble(t[0 .. $ - 1].strip()) / 100.0;
    return cssDouble(t);
}

private double parseAlpha(string s)
{
    import auroraweb.dom : cssDouble;
    const t = s.strip();
    if (t.length >= 1 && t[$ - 1] == '%')
        return cssDouble(t[0 .. $ - 1].strip()) / 100.0;
    return cssDouble(t);
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

unittest
{
    import aurora.surface : Surface;
    import std.conv : to;

    // A display:list-item element paints a filled bullet inside its content
    // edge: the bullet area must be non-white (dark) after painting.
    {
        auto li = new Element("li");
        li.style.display = "list-item";
        li.style.color = "black";
        li.box.x = 10;
        li.box.y = 10;
        li.box.width = 100;
        li.box.height = 20;
        li.box.paddingLeft = 6;
        li.box.paddingTop = 4;

        auto surface = new Surface(60, 40);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(li, canvas);

        // Bullet center: innerX=16, innerY=14, radius 3 -> around (21, 19).
        auto p = surface.pixel(21, 19);
        auto lum = (p & 0xff) + ((p >> 8) & 0xff) + ((p >> 16) & 0xff);
        assert(lum < 400,
            "bullet area should be dark (drawn), lum=" ~ lum.to!string);
        // Outside the bullet the surface stays white.
        auto white = surface.pixel(5, 30);
        assert(((white >> 16) & 0xff) >= 250 && (white & 0xff) >= 250,
            "outside the bullet should stay white");
    }
}

unittest
{
    import aurora.surface : Surface;
    import std.conv : to;

    // --- border-radius: a 40x20 element with radius 10 draws in the center
    // but leaves the corners white (rounded clip) ---
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#ff0000";
        el.style.borderRadius = "10px";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 40;
        el.box.height = 20;

        auto surface = new Surface(40, 20);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(el, canvas);

        auto center = surface.pixel(20, 10);
        assert(((center >> 16) & 0xff) >= 250,
            "center must be red (drawn), got " ~ center.to!string);
        auto corner = surface.pixel(0, 0);
        auto cornerLum = (corner & 0xff) + ((corner >> 8) & 0xff) + ((corner >> 16) & 0xff);
        assert(cornerLum >= 750,
            "corner must stay white (rounded clip), lum=" ~ cornerLum.to!string);
        // A pixel inside the circle near the top-left (4,4 with r=10) is drawn.
        auto inside = surface.pixel(4, 4);
        assert(((inside >> 16) & 0xff) >= 250,
            "pixel inside the corner arc must be red, got " ~ inside.to!string);
    }

    // --- opacity: a 0.5-opacity blue element blends with white -> lighter
    // (red channel rises from 0 toward 128 while opacity 1 keeps red = 0) ---
    {
        auto opaque = new Element("div");
        opaque.style.display = "block";
        opaque.style.background = "#0000ff";
        opaque.style.opacity = 1.0;
        opaque.box.x = 0; opaque.box.y = 0;
        opaque.box.width = 10; opaque.box.height = 10;

        auto half = new Element("div");
        half.style.display = "block";
        half.style.background = "#0000ff";
        half.style.opacity = 0.5;
        half.box.x = 0; half.box.y = 0;
        half.box.width = 10; half.box.height = 10;

        auto s1 = new Surface(10, 10);
        s1.clear(Color.rgb(255, 255, 255));
        paintElement(opaque, Canvas(s1));

        auto s2 = new Surface(10, 10);
        s2.clear(Color.rgb(255, 255, 255));
        paintElement(half, Canvas(s2));

        auto pFull = s1.pixel(5, 5);
        auto pHalf = s2.pixel(5, 5);
        assert(((pFull & 0xff) & 0xff) >= 250, "opacity 1 must be solid blue");
        assert(((pHalf >> 16) & 0xff) > ((pFull >> 16) & 0xff),
            "opacity 0.5 blue on white must be lighter than opacity 1, red=" ~
            ((pHalf >> 16) & 0xff).to!string ~ " vs " ~ ((pFull >> 16) & 0xff).to!string);
    }

    // --- box-shadow: semi-transparent offset rect paints outside the box ---
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#0000ff";
        el.style.boxShadowH = "5px";
        el.style.boxShadowV = "5px";
        el.style.boxShadowBlur = "0px";
        el.style.boxShadowColor = "rgba(0, 0, 0, 0.8)";
        el.box.x = 5; el.box.y = 5;
        el.box.width = 30; el.box.height = 20;

        auto surface = new Surface(60, 40);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(el, canvas);

        // Shadow lands at (10,10,30,20). A pixel at (37,27) is inside the
        // shadow but OUTSIDE the element box (5..35,5..25) and must be shaded.
        auto shadowPx = surface.pixel(37, 27);
        auto lum = (shadowPx & 0xff) + ((shadowPx >> 8) & 0xff) + ((shadowPx >> 16) & 0xff);
        assert(lum < 700,
            "shadow area must be shaded (non-white), lum=" ~ lum.to!string);
        // Inside the element box the blue background shows.
        auto bodyPx = surface.pixel(10, 10);
        assert(((bodyPx & 0xff) & 0xff) >= 250,
            "element body must be blue, got " ~ bodyPx.to!string);
    }

    // --- text-decoration: underline draws a line under the run ---
    {
        auto el = new Element("p");
        el.style.display = "block";
        el.style.fontSize = "16px";
        el.style.color = "#000000";
        el.style.textDecoration = "underline";
        el.box.x = 0; el.box.y = 0;
        el.box.width = 100; el.box.height = 30;
        el.box.paddingTop = 0; el.box.paddingLeft = 0;

        auto tn = new TextNode(el, "Hello world");
        tn.layoutX = 0;
        tn.layoutY = 0;
        tn.layoutWidth = 60;
        el.children ~= tn;

        auto surface = new Surface(100, 30);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(el, canvas);

        // The underline sits at y = layoutY + 16 - 3 + 1 = 14, spanning x 0..60.
        bool darkUnder = false;
        for (int x = 5; x < 55; x++)
        {
            auto p = surface.pixel(x, 14);
            auto lum = (p & 0xff) + ((p >> 8) & 0xff) + ((p >> 16) & 0xff);
            if (lum < 200) { darkUnder = true; break; }
        }
        assert(darkUnder,
            "underline must draw dark pixels along the baseline, text-decoration=" ~
            el.style.textDecoration);
    }
}

unittest
{
    import aurora.surface : Surface;
    import std.conv : to;

    // --- z-index paint order: the positioned child with higher z-index paints
    // on top of an overlapping sibling ---
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.background = "#ffffff";
        parent.box.x = 0; parent.box.y = 0;
        parent.box.width = 60; parent.box.height = 60;

        auto low = new Element("div");
        low.style.display = "block";
        low.style.position = "absolute";
        low.style.zIndex = 1;
        low.style.background = "#ff0000";
        low.box.x = 5; low.box.y = 5;
        low.box.width = 40; low.box.height = 40;

        auto high = new Element("div");
        high.style.display = "block";
        high.style.position = "absolute";
        high.style.zIndex = 2;
        high.style.background = "#0000ff";
        high.box.x = 15; high.box.y = 15;
        high.box.width = 30; high.box.height = 30;

        low.parent = parent; high.parent = parent;
        parent.children ~= low; parent.children ~= high;
        parent.elements ~= low; parent.elements ~= high;

        auto surface = new Surface(60, 60);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(parent, canvas);

        // Center (30,30) is covered by both; z-index 2 (blue) must win.
        auto center = surface.pixel(30, 30);
        assert(((center & 0xff) >= 250),
            "high z-index element (blue) must paint on top at the overlap, got " ~
            center.to!string);
        // A pixel only covered by the low element (blue=0) stays red.
        auto onlyLow = surface.pixel(7, 7);
        assert(((onlyLow >> 16) & 0xff) >= 250,
            "area only under the z-index:1 element must stay red, got " ~
            onlyLow.to!string);
    }
}

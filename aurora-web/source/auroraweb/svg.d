/**
 * Minimal, original SVG rasteriser.
 *
 * Original code for Aurora (CC0 / 0BSD) — no third-party source is included.
 *
 * Real pages serve a large share of their icons and artwork as SVG, which the
 * shared image decoder did not understand, so those images rendered blank.
 * This module renders the subset those files actually use:
 *
 *   - root width/height/viewBox scaling
 *   - <rect>, <circle>, <ellipse>, <line>, <polyline>, <polygon>, <path>, <g>
 *   - path commands M m L l H h V v C c S s Q q T t Z z
 *   - transform="translate|scale|matrix|rotate" (composed down the tree)
 *   - fill / fill-opacity / stroke / stroke-width / opacity / display:none
 *
 * Cubic and quadratic curves are flattened to line segments; strokes are drawn
 * as thick segments. That covers filled and outlined icons and simple artwork.
 */
module auroraweb.svg;

import aurora.image : RgbaImage;
import std.math : cos, sin, tan, sqrt, atan2, fabs;
import std.algorithm : min, max;
import std.string : indexOf, lastIndexOf, split, strip, toLower;
import std.conv : to;

/// An RGBA colour with a 0..255 alpha.
private struct Rgba { ubyte r, g, b, a; }

/// A 2x3 affine transform: x' = a*x + c*y + e, y' = b*x + d*y + f.
private struct Mat
{
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

    double applyX(double x, double y) const { return a * x + c * y + e; }
    double applyY(double x, double y) const { return b * x + d * y + f; }
}

/// `n` applied AFTER `m`.
private Mat mul(Mat n, Mat m)
{
    Mat r;
    r.a = n.a * m.a + n.c * m.b;
    r.b = n.b * m.a + n.d * m.b;
    r.c = n.a * m.c + n.c * m.d;
    r.d = n.b * m.c + n.d * m.d;
    r.e = n.a * m.e + n.c * m.f + n.e;
    r.f = n.b * m.e + n.d * m.f + n.f;
    return r;
}

/// One point in user space.
private struct Pt { double x, y; }

/// A parsed element: its tag name, attributes and whether it self-closes.
private struct Tag
{
    string name;
    string[string] attrs;
    bool closing;
    bool selfClosing;
}

/// True when these bytes look like an SVG document.
bool looksLikeSvg(const(ubyte)[] bytes)
{
    auto n = min(bytes.length, size_t(512));
    // Deliberately ASCII-only: this runs on raw, possibly non-UTF-8 bytes, and
    // std.uni's lowercasing overran on malformed sequences.
    auto head = cast(string) bytes[0 .. n];
    return indexOf(head, "<svg") >= 0 || indexOf(head, "<SVG") >= 0;
}

/// Split on `sep` at parenthesis depth 0, so `rgba(1, 2, 3, 0.5)` stays whole.
private string[] splitTopLevel(string s, char sep)
{
    string[] outArr;
    int depth = 0;
    size_t start = 0;
    foreach (i, ch; s)
    {
        if (ch == '(') depth++;
        else if (ch == ')') depth--;
        else if (ch == sep && depth == 0)
        {
            outArr ~= s[start .. i].strip();
            start = i + 1;
        }
    }
    outArr ~= s[start .. $].strip();
    return outArr;
}

/// Build a small SVG document that paints a CSS gradient, so the engine's own
/// SVG gradient rasteriser can draw `linear-gradient(...)` and
/// `radial-gradient(...)` backgrounds (which used to paint nothing at all).
/**
 * One colour stop as written: its colour plus the positions it declares, if
 * any. A stop may carry two positions, which spans a hard colour band.
 * Positions are fractions of the gradient line (`-1` means "not written").
 */
private struct RawStop
{
    string colour;
    double pos1 = -1;
    double pos2 = -1;
}

/// Parse `<colour> [<pos> [<pos>]]`, right to left: a trailing token is a
/// position when it is a percentage (kept as a fraction) or a length (divided by
/// the gradient line's length `len`, with a bare number read as px). A colour
/// can contain spaces (`rgb(1, 2, 3)`) but never ends in either form, so this
/// cannot eat the colour. A stop whose first position is omitted gets CSS's own
/// default, which the caller fills in.
private RawStop parseRawStop(string body, double len)
{
    RawStop s;
    auto rest = body.strip();
    double[2] pos;
    int have = 0;
    while (have < 2)
    {
        const sp = lastIndexOf(rest, ' ');
        if (sp <= 0) break;
        auto tail = rest[sp + 1 .. $].strip();
        if (tail.length == 0) { rest = rest[0 .. sp].strip(); continue; }
        double v = -1;
        if (tail[$ - 1] == '%')
        {
            try v = to!double(tail[0 .. $ - 1]) / 100.0;
            catch (Exception) break;
        }
        else
        {
            string num = tail;
            const tl = tail.toLower();
            if (tl.length >= 2 && tl[$ - 2 .. $] == "px") num = tail[0 .. $ - 2];
            try v = to!double(num);
            catch (Exception) break;
            if (len > 0) v /= len;
        }
        pos[1 - have] = v;      // collected right to left
        have++;
        rest = rest[0 .. sp].strip();
    }
    s.colour = rest;
    if (have >= 2) { s.pos1 = pos[0]; s.pos2 = pos[1]; }
    else if (have == 1) s.pos1 = pos[1];
    return s;
}

string gradientToSvg(string css, int w, int h)
{
    import std.conv : to;
    import std.math : PI, cos, sin;
    const lower = css.toLower();
    const isRadial = indexOf(lower, "radial-gradient(") >= 0;
    const open = indexOf(css, '(');
    if (open < 0) return "";
    const close = lastIndexOf(css, ')');
    if (close <= open) return "";
    auto parts = splitTopLevel(css[open + 1 .. close], ',');
    if (parts.length < 2) return "";

    // The default linear-gradient direction is `to bottom`: the gradient line
    // runs from the box's top edge to its bottom edge. Starting it at the centre
    // (y1 = 0.5) painted every `linear-gradient(a, b)` with the first stop flat
    // over the top half, which this fixture's b1-default-no-angle case catches.
    double x1 = 0.5, y1 = 0.0, x2 = 0.5, y2 = 1.0;
    size_t stopFrom = 0;
    // Radial shape: its centre as box fractions, and (for a circle) its radius
    // in pixels.
    bool radialCircle = false;
    double cx0 = 0.5, cy0 = 0.5, radialR = 0;
    if (!isRadial)
    {
        auto first = parts[0].toLower();
        if (first.length && (indexOf(first, "deg") >= 0 || indexOf(first, "to ") == 0))
        {
            stopFrom = 1;
            double deg = 180.0;
            const di = indexOf(first, "deg");
            if (di >= 0)
            {
                try deg = to!double(first[0 .. di].strip());
                catch (Exception) deg = 180.0;
            }
            else if (indexOf(first, "right") >= 0) deg = 90.0;
            else if (indexOf(first, "left") >= 0) deg = 270.0;
            else if (indexOf(first, "top") >= 0) deg = 0.0;
            const rad = deg * PI / 180.0;
            const dx = sin(rad), dy = -cos(rad);
            x1 = 0.5 - dx / 2;
            y1 = 0.5 - dy / 2;
            x2 = 0.5 + dx / 2;
            y2 = 0.5 + dy / 2;
        }
    }
    else
    {
        // A radial gradient's first part names its shape, size and centre:
        // `circle at 18% 14%`, `ellipse farthest-corner`, or nothing at all.
        // Only a part that is not one of those is a colour stop. Ignoring the
        // centre left every glow at SVG's default 50% 50%: boqsc.eu's body glow
        // is declared at `18% 14%` of a 1256x2224 body, so the engine painted it
        // in the middle of the page instead of near the hero.
        auto head = parts[0].toLower().strip();
        const hasAt = indexOf(head, "at ") >= 0;
        const isShape = hasAt || indexOf(head, "circle") >= 0 ||
            indexOf(head, "ellipse") >= 0 || indexOf(head, "closest-") >= 0 ||
            indexOf(head, "farthest-") >= 0;
        if (isShape)
        {
            stopFrom = 1;
            radialCircle = indexOf(head, "circle") >= 0;
            if (hasAt)
            {
                // `at <x> <y>`: either may be a percentage, a length (a fraction
                // of that axis) or a side keyword.
                int seen = 0;
                foreach (tok; split(head[indexOf(head, "at ") + 3 .. $], ' '))
                {
                    auto t = tok.strip();
                    if (t.length == 0) continue;
                    double v = -1;
                    if (t == "center") v = 0.5;
                    else if (t == "left" || t == "top") v = 0.0;
                    else if (t == "right" || t == "bottom") v = 1.0;
                    else if (t[$ - 1] == '%')
                    {
                        try v = to!double(t[0 .. $ - 1]) / 100.0;
                        catch (Exception) v = -1;
                    }
                    else
                    {
                        auto lenTok = t;
                        const tl = t.toLower();
                        if (tl.length >= 2 && tl[$ - 2 .. $] == "px")
                            lenTok = t[0 .. $ - 2];
                        try v = to!double(lenTok);
                        catch (Exception) v = -1;
                        const axis = seen == 0 ? w : h;
                        v = v >= 0 && axis > 0 ? v / axis : -1;
                    }
                    if (v < 0) continue;
                    if (seen == 0) cx0 = v; else cy0 = v;
                    if (++seen == 2) break;
                }
            }
            if (radialCircle)
            {
                // CSS's default ending shape is `farthest-corner`, so the radius
                // reaches the centre's farthest corner and the stop percentages
                // are fractions of it. The other three keywords are one distance
                // each from the same four corners and four sides.
                const px = cx0 * w, py = cy0 * h;
                double minCorner = double.max, maxCorner = 0;
                foreach (cxx; [0.0, cast(double) w])
                    foreach (cyy; [0.0, cast(double) h])
                    {
                        const d = sqrt((cxx - px) * (cxx - px) +
                            (cyy - py) * (cyy - py));
                        minCorner = min(minCorner, d);
                        maxCorner = max(maxCorner, d);
                    }
                const minSide = min(min(min(px, w - px), py), h - py);
                const maxSide = max(max(max(px, w - px), py), h - py);
                radialR = maxCorner;
                if (indexOf(head, "closest-corner") >= 0) radialR = minCorner;
                else if (indexOf(head, "closest-side") >= 0) radialR = minSide;
                else if (indexOf(head, "farthest-side") >= 0) radialR = maxSide;
                // `circle <length>` gives the radius outright.
                auto before = head[indexOf(head, "circle") + 6 .. $];
                const at2 = indexOf(before, "at ");
                if (at2 >= 0) before = before[0 .. at2];
                foreach (tok; split(before, ' '))
                {
                    auto t = tok.strip();
                    if (t.length == 0) continue;
                    auto lenTok = t;
                    const tl = t.toLower();
                    if (tl.length >= 2 && tl[$ - 2 .. $] == "px")
                        lenTok = t[0 .. $ - 2];
                    double v = -1;
                    try v = to!double(lenTok);
                    catch (Exception) continue;
                    if (v > 0) { radialR = v; break; }
                }
                if (radialR <= 0) radialR = 0.5 * h;
            }
        }
    }

    auto stops = parts[stopFrom .. $];
    if (stops.length < 2) return "";
    // `repeating-linear-gradient` repeats its stops along the line. Dropping the
    // flag drew ONE ramp and left everything past the last stop flat: boqsc.eu's
    // page-wide veil is `repeating-linear-gradient(90deg, transparent 0 399px,
    // rgba(255,255,255,0.05) 399px 400px)` - a 1px grid of white lines - and the
    // flat tail washed the whole page with 5% white (the washed-out tone).
    const isRepeating = indexOf(lower, "repeating-") >= 0;

    // Absolute stop positions (`399px`) are a length along the gradient line, so
    // the line's extent is needed to turn them into offsets; a percentage needs
    // no conversion.
    double lineLen = h;
    if (isRadial)
        lineLen = radialR > 0 ? radialR : 0.5 * sqrt(cast(double) w * cast(double) w +
            cast(double) h * cast(double) h);
    else
    {
        const adx = x1 > x2 ? x1 - x2 : x2 - x1;
        const ady = y1 > y2 ? y1 - y2 : y2 - y1;
        lineLen = w * adx + h * ady;
        if (lineLen <= 0) lineLen = w;
    }

    RawStop[] raws;
    foreach (stop; stops)
    {
        auto body2 = stop.strip();
        if (body2.length == 0) continue;
        raws ~= parseRawStop(body2, lineLen);
    }
    if (raws.length < 2) return "";
    // CSS fills in the positions a stop omits: the first stop starts at 0, the
    // last ends at 1, and the rest sit evenly between their positioned
    // neighbours. The old code gave every stop `i/(n-1)`, which is only the same
    // when nothing declared a position.
    if (raws[0].pos1 < 0) raws[0].pos1 = 0.0;
    if (raws[$ - 1].pos1 < 0) raws[$ - 1].pos1 = 1.0;
    {
        size_t i = 0;
        while (i < raws.length)
        {
            if (raws[i].pos1 >= 0) { i++; continue; }
            size_t j = i;
            while (raws[j].pos1 < 0) j++;
            const before = raws[i - 1].pos1;
            const after = raws[j].pos1;
            const steps = cast(double)(j - i + 1);
            foreach (m; i .. j)
                raws[m].pos1 = before + (after - before) *
                    cast(double)(m - i + 1) / steps;
            i = j;
        }
    }
    // A repeating gradient's period is the last stop's position: tile the stops
    // over the whole line so the rasteriser draws every repeat. Tiling here (not
    // in the rasteriser) keeps one code path for both forms.
    if (isRepeating)
    {
        double lastPos = raws[0].pos1;
        foreach (r; raws)
            lastPos = max(lastPos, r.pos2 >= 0 ? r.pos2 : r.pos1);
        const period = lastPos - raws[0].pos1;
        if (period > 1e-6)
        {
            RawStop[] tiled = raws.dup;
            for (double shift = period; raws[0].pos1 + shift <= 1.0;
                shift += period)
                foreach (r; raws)
                {
                    RawStop t = r;
                    t.pos1 = r.pos1 + shift;
                    if (r.pos2 >= 0) t.pos2 = r.pos2 + shift;
                    tiled ~= t;
                }
            raws = tiled;
        }
    }
    string outS = "<svg xmlns='http://www.w3.org/2000/svg' width='" ~ w.to!string ~
        "' height='" ~ h.to!string ~ "'><defs>";
    if (isRadial && radialCircle && radialR > 0)
        // User space, so the radius is one circle rather than an ellipse
        // stretched to the box. `at` percentages are box fractions, so they are
        // scaled by the box's own axis.
        outS ~= "<radialGradient id='g' gradientUnits='userSpaceOnUse' cx='" ~
            (cx0 * w).to!string ~ "' cy='" ~ (cy0 * h).to!string ~
            "' r='" ~ radialR.to!string ~ "'>";
    else if (isRadial)
        outS ~= "<radialGradient id='g' cx='" ~ cx0.to!string ~
            "' cy='" ~ cy0.to!string ~ "'>";
    else
        outS ~= "<linearGradient id='g' x1='" ~ x1.to!string ~ "' y1='" ~ y1.to!string ~
            "' x2='" ~ x2.to!string ~ "' y2='" ~ y2.to!string ~ "'>";
    foreach (r; raws)
    {
        outS ~= "<stop offset='" ~ r.pos1.to!string ~ "' stop-color='" ~ r.colour ~ "'/>";
        // A stop written with two positions holds its colour across the span,
        // which is how a hard colour band is spelled.
        if (r.pos2 >= 0)
            outS ~= "<stop offset='" ~ r.pos2.to!string ~ "' stop-color='" ~ r.colour ~ "'/>";
    }
    outS ~= isRadial ? "</radialGradient>" : "</linearGradient>";
    outS ~= "</defs><rect width='" ~ w.to!string ~ "' height='" ~ h.to!string ~
        "' fill='url(#g)'/></svg>";
    return outS;
}

/// Parse a CSS colour for use as an SVG's inherited `currentColor`, defaulting
/// to black (SVG's own default fill). Lets hosts feed the element's `color` in
/// without exposing this module's colour type.
Rgba svgCssColor(string css)
{
    if (css.length == 0) return Rgba(0, 0, 0, 255);
    return parseColor(css.strip(), Rgba(0, 0, 0, 255));
}

/// Render SVG bytes to an image, or return null when nothing usable is found.
/// `currentColor` is the CSS colour the SVG inherits, used by `currentColor`
/// fills — the form nearly every icon file uses.
RgbaImage decodeSvg(const(ubyte)[] bytes, Rgba currentColor = Rgba(0, 0, 0, 255))
{
    // Tag and attribute markup is ASCII; drop any high bytes before it reaches
    // case-folding. std.uni.toLower overran on malformed UTF-8 and crashed the
    // browser on a real page's SVG.
    auto raw = cast(string) bytes;
    auto clean = new ubyte[](raw.length);
    foreach (k, c; cast(const(ubyte)[]) raw)
        clean[k] = c < 0x80 ? c : cast(ubyte) ' ';
    auto text = cast(string) clean;
    auto tags = parseTags(text);
    if (!tags.length) return null;

    // Find the root <svg>.
    Tag root;
    bool haveRoot = false;
    foreach (t; tags)
        if (t.name == "svg" && !t.closing) { root = t; haveRoot = true; break; }
    if (!haveRoot) return null;

    const vb = parseViewBox(root);
    const attrW = attrLen(root, "width", 0);
    const attrH = attrLen(root, "height", 0);
    // With a viewBox, user units are the viewBox rectangle and the viewport is
    // width/height (spec default 300x150). WITHOUT one, user units ARE the
    // viewport pixels — treating them as 300x150 shrank unscaled artwork down
    // to sub-pixel size, so an 8x8 SVG rendered as nothing at all.
    double vw = vb[2], vh = vb[3];
    double boxX = vb[0], boxY = vb[1];
    if (!(vw > 0) || !(vh > 0))
    {
        vw = attrW > 0 ? attrW : 300;
        vh = attrH > 0 ? attrH : 150;
        boxX = 0;
        boxY = 0;
    }
    int outW = attrW > 0 ? attrW : cast(int) (vw + 0.5);
    int outH = attrH > 0 ? attrH : cast(int) (vh + 0.5);
    outW = min(outW, 4096);
    outH = min(outH, 4096);
    if (outW <= 0 || outH <= 0) return null;

    auto pixels = new ubyte[](outW * outH * 4);
    if (outW <= 0 || outH <= 0) return null;

    // viewBox(-> viewport) transform, then the render scale.
    Mat base;
    base.a = outW / vw;
    base.d = outH / vh;
    base.e = -boxX * base.a;
    base.f = -boxY * base.d;

    auto ctx = StyleCtx();
    // A shape with no `fill` attribute uses the inherited CSS `fill`. Pages
    // colour icon markup with `svg { fill: currentColor }` and give the shapes
    // no attribute at all, so defaulting to opaque black made those icons vanish
    // against a dark toolbar. `currentColor` defaults to black, so callers that
    // pass no ink colour keep the previous behaviour exactly.
    ctx.fill = currentColor;
    ctx.hasFill = true;
    ctx.stroke = Rgba(0, 0, 0, 0);
    ctx.strokeWidth = 1;
    collectGradients(tags, ctx.gradients);
    ctx.currentColor = currentColor;


    renderChildren(tags, 0, pixels, outW, outH, base, ctx);
    return new RgbaImage(outW, outH, pixels);
}

/// Collect every <linearGradient>/<radialGradient> with its <stop> children.
private void collectGradients(Tag[] tags, ref Gradient[string] outGrads)
{
    foreach (i, t; tags)
    {
        if (t.name != "lineargradient" && t.name != "radialgradient") continue;
        auto idAttr = "id" in t.attrs;
        if (idAttr is null || !(*idAttr).strip().length) continue;

        Gradient g;
        auto units = "gradientunits" in t.attrs;
        if (units !is null) g.userSpace = toLower((*units).strip()) == "userspaceonuse";
        if (t.name == "radialgradient")
        {
            g.radial = true;
            g.cx = attrNum(t, "cx", 0.5);
            g.cy = attrNum(t, "cy", 0.5);
            g.r = attrNum(t, "r", 0.5);
        }
        else
        {
            g.x1 = attrNum(t, "x1", 0);
            g.y1 = attrNum(t, "y1", 0);
            g.x2 = attrNum(t, "x2", 1);
            g.y2 = attrNum(t, "y2", 0);
        }

        // Stops are the <stop> elements belonging to this gradient element.
        int depth = 0;
        foreach (j; i + 1 .. tags.length)
        {
            auto s = tags[j];
            if (s.closing)
            {
                if (s.name == t.name && depth == 0) break;
                depth--;
                continue;
            }
            if (s.name == t.name && !s.selfClosing) depth++;
            if (s.name != "stop") continue;

            GradStop st;
            auto oc = "offset" in s.attrs;
            st.offset = oc is null ? 0 : attrNum(s, "offset", 0);
            if (oc !is null && (*oc).strip().length && (*oc).strip()[$ - 1] == '%')
                st.offset = firstNumber(*oc) / 100.0;
            auto sc = "stop-color" in s.attrs;
            st.color = sc is null ? Rgba(0, 0, 0, 255) : parseColor((*sc), Rgba(0, 0, 0, 255));
            auto so = "stop-opacity" in s.attrs;
            if (so !is null)
            {
                auto v = firstNumber(*so);
                if (v >= 0 && v <= 1) st.color.a = clamp8(255.0 * v);
            }
            g.stops ~= st;
        }
        if (g.stops.length) outGrads[(*idAttr).strip()] = g;
    }
}

/// The colour of a gradient at position `t` (0..1), interpolating between stops.
private Rgba sampleGradient(Gradient g, double t)
{
    if (!g.stops.length) return Rgba(0, 0, 0, 255);
    if (t <= g.stops[0].offset) return g.stops[0].color;
    foreach (i; 0 .. g.stops.length - 1)
    {
        auto a = g.stops[i], b = g.stops[i + 1];
        if (t <= b.offset)
        {
            auto span = b.offset - a.offset;
            auto f = span > 0 ? (t - a.offset) / span : 0.0;
            return Rgba(clamp8(a.color.r + (b.color.r - a.color.r) * f),
                clamp8(a.color.g + (b.color.g - a.color.g) * f),
                clamp8(a.color.b + (b.color.b - a.color.b) * f),
                clamp8(a.color.a + (b.color.a - a.color.a) * f));
        }
    }
    return g.stops[$ - 1].color;
}

/// Inherited presentation state.
private struct StyleCtx
{
    Rgba fill;
    bool hasFill;
    Rgba stroke;
    double strokeWidth;
    double opacity = 1.0;
    Mat transform;
    int depth;
    string gradientId;                      /// `fill="url(#id)"`, "" when solid.
    Gradient[string] gradients;             /// Gradients declared anywhere in the file.
    Rgba currentColor;                      /// CSS `color`, for `currentColor` fills.
}

/// One colour stop inside a gradient.
private struct GradStop { double offset; Rgba color; }

/// A linear gradient. Coordinates are 0..1 object fractions by default, or user
/// space when `gradientUnits="userSpaceOnUse"`.
private struct Gradient
{
    double x1 = 0, y1 = 0, x2 = 1, y2 = 0;
    bool userSpace = false;
    GradStop[] stops;
    bool radial = false;              /// radialGradient rather than linear.
    double cx = 0.5, cy = 0.5, r = 0.5;  /// centre and radius (radial only).
}

// ---------------------------------------------------------------------------
// Tag scanning
// ---------------------------------------------------------------------------

/// Scan `<!-- -->`, `<tag ...>`, `</tag>` and `<tag ... />` into Tag records.
private Tag[] parseTags(string s)
{
    Tag[] outTags;
    size_t i = 0;
    while (i < s.length)
    {
        auto lt = indexOf(s, "<", i);
        if (lt < 0) break;
        if (lt + 3 < s.length && s[lt .. lt + 4] == "<!--")
        {
            auto end = indexOf(s, "-->", lt + 4);
            i = end < 0 ? s.length : end + 3;
            continue;
        }
        auto gt = indexOf(s, ">", lt + 1);
        if (gt < 0) break;
        auto inner = s[lt + 1 .. gt].strip();
        i = gt + 1;
        if (!inner.length || inner[0] == '!' || inner[0] == '?') continue;

        Tag t;
        if (inner[0] == '/')
        {
            t.closing = true;
            t.name = toLower(inner[1 .. $].strip());
            outTags ~= t;
            continue;
        }
        if (inner[$ - 1] == '/')
        {
            t.selfClosing = true;
            inner = inner[0 .. $ - 1].strip();
        }
        size_t k = 0;
        while (k < inner.length && !isSpace(inner[k]) && inner[k] != '/') k++;
        t.name = toLower(inner[0 .. k]);
        parseAttrs(inner[k .. $], t.attrs);
        outTags ~= t;
    }
    return outTags;
}

private bool isSpace(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/// Parse `name="value"` / `name='value'` / `name=value` pairs.
private void parseAttrs(string s, ref string[string] attrs)
{
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && (isSpace(s[i]) || s[i] == '/')) i++;
        auto start = i;
        while (i < s.length && s[i] != '=' && !isSpace(s[i])) i++;
        if (i >= s.length) break;
        auto name = toLower(s[start .. i].strip());
        while (i < s.length && isSpace(s[i])) i++;
        if (i >= s.length || s[i] != '=') { i++; continue; }
        i++;
        while (i < s.length && isSpace(s[i])) i++;
        if (i >= s.length) break;
        string value;
        if (s[i] == '"' || s[i] == '\'')
        {
            auto q = s[i];
            i++;
            auto e = indexOf(s, q, i);
            if (e < 0) e = s.length;
            value = s[i .. e];
            i = e + 1;
        }
        else
        {
            auto st = i;
            while (i < s.length && !isSpace(s[i])) i++;
            value = s[st .. i];
        }
        if (name.length) attrs[name] = value.strip();
    }
}

// ---------------------------------------------------------------------------
// Small parsers
// ---------------------------------------------------------------------------

/// `viewBox="minX minY w h"` → [minX, minY, w, h] (empty when absent).
private double[4] parseViewBox(Tag root)
{
    // NOTE: D default-initialises floating point to NaN, and `NaN <= 0` is
    // false — so an uninitialised array here silently poisoned every coordinate
    // and the rasteriser painted nothing.
    double[4] vb = [0.0, 0.0, 0.0, 0.0];
    auto it = "viewbox" in root.attrs;
    if (it is null) return vb;
    auto parts = nums(*it);
    if (parts.length >= 4)
    {
        vb[0] = parts[0];
        vb[1] = parts[1];
        vb[2] = parts[2];
        vb[3] = parts[3];
    }
    return vb;
}

/// A length attribute in user units (px/pt ignored; percentages → 0).
private int attrLen(Tag t, string name, int fallback)
{
    auto it = name in t.attrs;
    if (it is null) return fallback;
    auto s = (*it).strip();
    if (!s.length) return fallback;
    if (s[$ - 1] == '%') return fallback;
    auto v = firstNumber(s);
    return v > 0 ? cast(int) (v + 0.5) : fallback;
}

/// All numbers in a string (handles "1,2 3-4" style lists).
private double[] nums(string s)
{
    double[] outNums;
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && !isNumStart(s, i)) i++;
        if (i >= s.length) break;
        auto st = i;
        if (s[i] == '+' || s[i] == '-') i++;
        while (i < s.length && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.')) i++;
        if (i < s.length && (s[i] == 'e' || s[i] == 'E')) i++;
        try outNums ~= to!double(s[st .. i]);
        catch (Exception) {}
    }
    return outNums;
}

private bool isNumStart(string s, size_t i)
{
    auto c = s[i];
    if (c >= '0' && c <= '9') return true;
    if (c == '.') return true;
    if ((c == '+' || c == '-') && i + 1 < s.length)
        return (s[i + 1] >= '0' && s[i + 1] <= '9') || s[i + 1] == '.';
    return false;
}

/// The first number in a string, or 0.
private double firstNumber(string s)
{
    auto n = nums(s);
    return n.length ? n[0] : 0.0;
}

/// Parse `#rgb`, `#rrggbb`, `rgb(r,g,b)`, `rgba(...)` or a few named colours.
private Rgba parseColor(string s, Rgba fallback)
{
    auto v = s.strip();
    if (!v.length) return fallback;
    auto lower = toLower(v);
    if (lower == "none" || lower == "transparent") return Rgba(0, 0, 0, 0);
    if (lower == "black") return Rgba(0, 0, 0, 255);
    if (lower == "white") return Rgba(255, 255, 255, 255);
    if (lower == "red") return Rgba(255, 0, 0, 255);
    if (lower == "green") return Rgba(0, 128, 0, 255);
    if (lower == "blue") return Rgba(0, 0, 255, 255);
    if (lower == "gray" || lower == "grey") return Rgba(128, 128, 128, 255);
    if (lower == "currentcolor") return fallback;
    if (v[0] == '#')
    {
        auto hex = v[1 .. $];
        if (hex.length >= 6)
        {
            int r = hexVal(hex[0 .. 2]);
            int g = hexVal(hex[2 .. 4]);
            int b = hexVal(hex[4 .. 6]);
            if (r >= 0 && g >= 0 && b >= 0)
                return Rgba(cast(ubyte) r, cast(ubyte) g, cast(ubyte) b, 255);
        }
        else if (hex.length >= 3)
        {
            int r = hexVal(hex[0 .. 1]), g = hexVal(hex[1 .. 2]), b = hexVal(hex[2 .. 3]);
            if (r >= 0 && g >= 0 && b >= 0)
                return Rgba(cast(ubyte) (r * 17), cast(ubyte) (g * 17),
                    cast(ubyte) (b * 17), 255);
        }
        return fallback;
    }
    if (lower.length >= 4 && lower[0 .. 4] == "rgb(" || lower.length >= 5 &&
        lower[0 .. 5] == "rgba(")
    {
        auto open = indexOf(v, "(");
        auto close = lastIndexOf(v, ")");
        if (open >= 0 && close > open)
        {
            auto parts = nums(v[open + 1 .. close]);
            if (parts.length >= 3)
            {
                auto a = parts.length >= 4 ? parts[3] : 1.0;
                if (lower.length >= 5 && lower[0 .. 5] == "rgba(" && a <= 1.0)
                    a = a;
                return Rgba(clamp8(parts[0]), clamp8(parts[1]), clamp8(parts[2]),
                    clamp8(a <= 1.0 && parts.length >= 4 ? a * 255 : 255));
            }
        }
    }
    // url(#id), gradients and anything else: no solid colour.
    return fallback;
}

private ubyte clamp8(double v)
{
    if (v < 0) return 0;
    if (v > 255) return 255;
    return cast(ubyte) (v + 0.5);
}

private int hexVal(string h)
{
    int v = 0;
    foreach (c; h)
    {
        int d = -1;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        if (d < 0) return -1;
        v = v * 16 + d;
    }
    return v;
}

/// Parse a transform list into a matrix (leftmost applied first).
private Mat parseTransform(string s)
{
    Mat m;
    size_t i = 0;
    while (i < s.length)
    {
        auto open = indexOf(s, "(", i);
        if (open < 0) break;
        auto close = indexOf(s, ")", open);
        if (close < 0) break;
        auto name = toLower(s[i .. open].strip());
        auto a = nums(s[open + 1 .. close]);
        i = close + 1;
        Mat t;
        if (name == "translate" && a.length >= 1)
        {
            t.e = a[0];
            t.f = a.length >= 2 ? a[1] : 0;
        }
        else if (name == "scale" && a.length >= 1)
        {
            t.a = a[0];
            t.d = a.length >= 2 ? a[1] : a[0];
        }
        else if (name == "matrix" && a.length >= 6)
        {
            t.a = a[0]; t.b = a[1]; t.c = a[2];
            t.d = a[3]; t.e = a[4]; t.f = a[5];
        }
        else if ((name == "rotate" || name == "skewx" || name == "skewy") && a.length >= 1)
        {
            auto deg = (name == "skewy") ? 0.0 : a[0];
            auto rad = deg * 3.14159265358979 / 180.0;
            auto cs = cos(rad), sn = sin(rad);
            if (name == "rotate")
            {
                t.a = cs; t.b = sn; t.c = -sn; t.d = cs;
                if (a.length >= 3)
                {
                    t.e = a[1] - cs * a[1] + sn * a[2];
                    t.f = a[2] - sn * a[1] - cs * a[2];
                }
            }
            else if (name == "skewx")
            {
                t.c = tan(rad);
            }
            else
            {
                t.b = tan(rad);
            }
        }
        m = mul(t, m);
    }
    return m;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Walk the tag stream below `startTag`, rendering children of the svg root.
private void renderChildren(Tag[] tags, size_t start, ubyte[] px, int w, int h,
    Mat parentTransform, StyleCtx parentCtx)
{
    // Depth starts at the svg root: children of <svg> are depth 1.
    StyleCtx ctx = parentCtx;
    ctx.transform = parentTransform;
    int depth = 1;
    int skipTo = -1;
    // Transform in force at each nesting level: `levelT[d]` is the transform a
    // container at depth d hands to the elements inside it (depth d+1), and
    // `levelT[0]` is the caller's transform. The tag list is scanned flat, so
    // without this chain a <g> transform reached only the <g> itself and every
    // nested group transform was dropped - Sketch/Figma exports wrap their
    // artwork in a translating <g>, which then painted shifted and clipped.
    Mat[] levelT;
    levelT ~= parentTransform;
    // Presentation attributes inherit down the tree exactly as transforms do:
    // `fill` on a <g> applies to the shapes inside it (SVG 1.1 section 11.3).
    // Only the transform used to be carried, so a container's fill was dropped
    // and its shapes fell back to `currentColor` - djangoproject.com's wordmark
    // sets a white fill on a <g> and turned near-black in the dark theme.
    StyleCtx[] levelCtx;
    levelCtx ~= ctx;

    for (size_t i = start; i < tags.length; i++)
    {
        auto t = tags[i];
        if (t.closing)
        {
            depth--;
            if (skipTo >= 0 && depth < skipTo)
            {
                skipTo = -1;
            }
            continue;
        }
        if (depth < 1) continue;
        if (skipTo >= 0)
        {
            if (!t.selfClosing) depth++;
            continue;
        }

        // Local style: inherit from the enclosing container, then apply this
        // element's presentation attributes.
        auto local = depth - 1 < cast(int) levelCtx.length
            ? levelCtx[depth - 1] : ctx;
        local.depth = depth;
        applyPresentation(t, local);
        auto it = "transform" in t.attrs;
        const inherited = depth - 1 < cast(int) levelT.length
            ? levelT[depth - 1] : parentTransform;
        local.transform = it !is null
            ? mul(parseTransform(*it), inherited) : inherited;

        bool hidden = false;
        auto disp = "display" in t.attrs;
        if (disp !is null && toLower((*disp).strip()) == "none") hidden = true;

        if (hidden)
        {
            // Skip this element and its subtree.
            if (!t.selfClosing) skipTo = depth;
            continue;
        }


        if (t.name == "g" || t.name == "svg" || t.name == "defs" || t.name == "symbol")
        {
            if (!t.selfClosing)
            {
                if (t.name == "defs" || t.name == "symbol") skipTo = depth;
                else
                {
                    // The group's own transform is what its children inherit.
                    if (levelT.length <= depth) levelT.length = depth + 1;
                    levelT[depth] = local.transform;
                    // Its presentation attributes, likewise.
                    if (levelCtx.length <= depth) levelCtx.length = depth + 1;
                    levelCtx[depth] = local;
                    depth++;
                }
            }
            continue;
        }

        drawElement(t, local, px, w, h);
        if (!t.selfClosing) depth++;
    }
}

/// Apply fill/stroke/opacity attributes from an element onto a style context.
private void applyPresentation(Tag t, ref StyleCtx ctx)
{
    if (auto f = "fill" in t.attrs)
    {
        auto v = (*f).strip();
        if (v.length)
        {
            if (toLower(v) == "none")
            {
                ctx.hasFill = false;
                ctx.gradientId = "";
            }
            else if (toLower(v) == "currentcolor")
            {
                // `fill="currentColor"` is how essentially every icon file
                // inherits its colour from CSS. Without this the fill stayed at
                // SVG's default black and icons vanished against dark pages.
                ctx.fill = ctx.currentColor;
                ctx.hasFill = true;
                ctx.gradientId = "";
            }
            else if (v.length > 5 && toLower(v[0 .. 4]) == "url(")
            {
                // Gradient (or pattern) reference: resolve to the gradient's
                // stops, with its first stop as the colour fallback.
                auto id = v[4 .. $];
                auto close = indexOf(id, ")");
                if (close >= 0) id = id[0 .. close];
                id = id.strip();
                if (id.length && id[0] == '#') id = id[1 .. $];
                ctx.gradientId = id;
                ctx.hasFill = true;
                auto gi = id in ctx.gradients;
                if (gi !is null && (*gi).stops.length) ctx.fill = (*gi).stops[0].color;
            }
            else
            {
                auto c = parseColor(v, ctx.fill);
                if (c.a > 0 || toLower(v) != "none")
                {
                    ctx.fill = c;
                    ctx.hasFill = true;
                    ctx.gradientId = "";
                }
            }
        }
    }
    if (auto fo = "fill-opacity" in t.attrs)
    {
        auto v = firstNumber(*fo);
        if (v >= 0 && v <= 1) ctx.fill.a = clamp8(255.0 * v);
    }
    if (auto st = "stroke" in t.attrs)
    {
        auto v = (*st).strip();
        if (toLower(v) == "none") ctx.stroke = Rgba(0, 0, 0, 0);
        else ctx.stroke = parseColor(v, Rgba(0, 0, 0, 0));
    }
    if (auto sw = "stroke-width" in t.attrs)
    {
        auto v = firstNumber(*sw);
        if (v > 0) ctx.strokeWidth = v;
    }
    if (auto op = "opacity" in t.attrs)
    {
        auto v = firstNumber(*op);
        if (v >= 0 && v <= 1)
        {
            ctx.opacity *= v;
            ctx.fill.a = clamp8(ctx.fill.a * v);
            ctx.stroke.a = clamp8(ctx.stroke.a * v);
        }
    }
}

/// Draw one shape element.
private void drawElement(Tag t, StyleCtx ctx, ubyte[] px, int w, int h)
{
    auto m = ctx.transform;
    switch (t.name)
    {
        case "rect":
        {
            auto x = attrNum(t, "x", 0), y = attrNum(t, "y", 0);
            auto rw = attrNum(t, "width", 0), rh = attrNum(t, "height", 0);
            if (rw <= 0 || rh <= 0) return;
            Pt[] pts = [Pt(x, y), Pt(x + rw, y), Pt(x + rw, y + rh), Pt(x, y + rh)];
            fillPts(pts, m, ctx, px, w, h);
            return;
        }
        case "circle":
        {
            auto cx = attrNum(t, "cx", 0), cy = attrNum(t, "cy", 0);
            auto r = attrNum(t, "r", 0);
            if (r <= 0) return;
            fillPts(ellipsePts(cx, cy, r, r), m, ctx, px, w, h);
            return;
        }
        case "ellipse":
        {
            auto cx = attrNum(t, "cx", 0), cy = attrNum(t, "cy", 0);
            auto rx = attrNum(t, "rx", 0), ry = attrNum(t, "ry", 0);
            if (rx <= 0 || ry <= 0) return;
            fillPts(ellipsePts(cx, cy, rx, ry), m, ctx, px, w, h);
            return;
        }
        case "line":
        {
            auto x1 = attrNum(t, "x1", 0), y1 = attrNum(t, "y1", 0);
            auto x2 = attrNum(t, "x2", 0), y2 = attrNum(t, "y2", 0);
            Pt[] pts = [Pt(x1, y1), Pt(x2, y2)];
            strokePts(pts, m, ctx, px, w, h);
            return;
        }
        case "polyline":
        case "polygon":
        {
            auto pv = "points" in t.attrs;
            if (pv is null) return;
            auto numsP = nums(*pv);
            Pt[] pts;
            for (size_t k = 0; k + 1 < numsP.length; k += 2)
                pts ~= Pt(numsP[k], numsP[k + 1]);
            if (pts.length < 2) return;
            if (t.name == "polygon")
                fillPts(pts, m, ctx, px, w, h);
            else
                strokePts(pts, m, ctx, px, w, h);
            return;
        }
        case "path":
        {
            auto dv = "d" in t.attrs;
            if (dv is null) return;
            auto subpaths = flattenPath(*dv);
            // A compound path (more than one closed subpath) must be filled with
            // its subpaths tested TOGETHER, or an inner contour is filled over
            // its parent instead of becoming a hole. Gradients keep the
            // per-subpath path, which is the common single-subpath case anyway.
            Pt[][] compound;
            if (ctx.hasFill && ctx.fill.a > 0 && ctx.gradientId.length == 0)
                foreach (sp; subpaths)
                    if (sp.points.length >= 2 && sp.closed)
                        compound ~= toDevice(sp.points, m);
            if (compound.length > 1)
                rasterFillPolys(px, w, h, compound, ctx.fill);
            else
                foreach (sp; subpaths)
                    if (sp.points.length >= 2 && sp.closed && ctx.hasFill)
                        fillPts(sp.points, m, ctx, px, w, h);
            foreach (sp; subpaths)
                if (sp.points.length >= 2)
                    strokePts(sp.points, m, ctx, px, w, h);
            return;
        }
        default:
            return;
    }
}

private double attrNum(Tag t, string name, double fallback)
{
    auto it = name in t.attrs;
    if (it is null) return fallback;
    auto s = (*it).strip();
    if (!s.length) return fallback;
    if (s[$ - 1] == '%') return fallback;
    return firstNumber(s);
}

/// Points around an ellipse (closed), sampled densely enough for icons.
private Pt[] ellipsePts(double cx, double cy, double rx, double ry)
{
    Pt[] pts;
    enum int steps = 72;
    foreach (i; 0 .. steps)
    {
        auto th = 2.0 * 3.14159265358979 * i / steps;
        pts ~= Pt(cx + rx * cos(th), cy + ry * sin(th));
    }
    return pts;
}

/// Fill a polygon through a transform, then stroke it if a stroke is set.
private void fillPts(Pt[] pts, Mat m, StyleCtx ctx, ubyte[] px, int w, int h)
{
    Pt[] dev;
    foreach (p; pts) dev ~= Pt(m.applyX(p.x, p.y), m.applyY(p.x, p.y));
    if (ctx.hasFill && (ctx.fill.a > 0 || ctx.gradientId.length))
    {
        Gradient g;
        auto haveGrad = false;
        if (ctx.gradientId.length)
        {
            auto gi = ctx.gradientId in ctx.gradients;
            if (gi !is null && (*gi).stops.length)
            {
                g = *gi;
                haveGrad = true;
            }
        }
        if (!haveGrad)
        {
            rasterFill(px, w, h, dev, ctx.fill);
        }
        else
        {
            // Device-space gradient axis. objectBoundingBox (the default) maps
            // the 0..1 fractions onto this shape's device bounding box;
            // userSpaceOnUse passes user coordinates through the transform.
            double gx1, gy1, gx2, gy2;
            double spanX = 0, spanY = 0;
            double minX = dev[0].x, maxX = dev[0].x;
            double minY = dev[0].y, maxY = dev[0].y;
            foreach (p; dev)
            {
                minX = min(minX, p.x);
                maxX = max(maxX, p.x);
                minY = min(minY, p.y);
                maxY = max(maxY, p.y);
            }
            spanX = maxX - minX;
            spanY = maxY - minY;

            if (g.radial)
            {
                if (g.userSpace)
                {
                    gx1 = m.applyX(g.cx, g.cy);
                    gy1 = m.applyY(g.cx, g.cy);
                    gy2 = g.r;
                }
                else
                {
                    gx1 = minX + g.cx * spanX;
                    gy1 = minY + g.cy * spanY;
                    // objectBoundingBox radii are fractions of the bounding box's
                    // normalised diagonal.
                    gy2 = g.r * sqrt(spanX * spanX + spanY * spanY) / sqrt(2.0);
                }
                // Centre in gx1/gy1, radius in gy2 (see rasterGradient).
                rasterGradient(px, w, h, dev, g, gx1, gy1, 0, gy2, true);
                if (ctx.stroke.a > 0)
                    rasterStroke(px, w, h, dev, true, ctx.strokeWidth, ctx.stroke);
                return;
            }

            if (g.userSpace)
            {
                gx1 = m.applyX(g.x1, g.y1);
                gy1 = m.applyY(g.x1, g.y1);
                gx2 = m.applyX(g.x2, g.y2);
                gy2 = m.applyY(g.x2, g.y2);
            }
            else
            {
                gx1 = minX + g.x1 * spanX;
                gy1 = minY + g.y1 * spanY;
                gx2 = minX + g.x2 * spanX;
                gy2 = minY + g.y2 * spanY;
            }
            rasterGradient(px, w, h, dev, g, gx1, gy1, gx2, gy2, false);
        }
    }
    if (ctx.stroke.a > 0) rasterStroke(px, w, h, dev, true, ctx.strokeWidth, ctx.stroke);
}

/// Scanline fill where each pixel takes its colour from a linear gradient.
private void rasterGradient(ubyte[] px, int w, int h, Pt[] pts, Gradient g,
    double gx1, double gy1, double gx2, double gy2, bool radial)
{
    if (pts.length < 3) return;
    auto dx = gx2 - gx1, dy = gy2 - gy1;
    auto len2 = dx * dx + dy * dy;
    // For a radial gradient gx1/gy1 is the centre and gy2 the radius.
    auto radius = gy2;
    auto gcx = gx1, gcy = gy1;

    double minY = pts[0].y, maxY = pts[0].y;
    foreach (p; pts)
    {
        minY = min(minY, p.y);
        maxY = max(maxY, p.y);
    }
    int y0 = cast(int) (minY < 0 ? 0 : minY);
    int y1 = cast(int) (maxY + 1);
    if (y1 > h) y1 = h;
    double[] xs;
    foreach (y; y0 .. y1)
    {
        xs.length = 0;
        auto sy = y + 0.5;
        foreach (i; 0 .. pts.length)
        {
            auto a = pts[i];
            auto b = pts[(i + 1) % pts.length];
            if ((a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy))
            {
                auto t = (sy - a.y) / (b.y - a.y);
                xs ~= a.x + t * (b.x - a.x);
            }
        }
        if (xs.length < 2) continue;
        sortNums(xs);
        for (size_t k = 0; k + 1 < xs.length; k += 2)
        {
            int xa = cast(int) (xs[k] + 0.5);
            int xb = cast(int) (xs[k + 1] + 0.5);
            if (xa < 0) xa = 0;
            if (xb > w) xb = w;
            foreach (x; xa .. xb)
            {
                double t;
                if (radial)
                {
                    auto ddx = x + 0.5 - gcx, ddy = sy - gcy;
                    t = radius > 0 ? sqrt(ddx * ddx + ddy * ddy) / radius : 1.0;
                }
                else
                {
                    t = len2 > 0
                        ? ((x + 0.5 - gx1) * dx + (sy - gy1) * dy) / len2 : 1.0;
                }
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                blend(px, w, h, x, y, sampleGradient(g, t));
            }
        }
    }
}

private void strokePts(Pt[] pts, Mat m, StyleCtx ctx, ubyte[] px, int w, int h)
{
    if (ctx.stroke.a <= 0) return;
    Pt[] dev;
    foreach (p; pts) dev ~= Pt(m.applyX(p.x, p.y), m.applyY(p.x, p.y));
    rasterStroke(px, w, h, dev, false, ctx.strokeWidth, ctx.stroke);
    if (ctx.hasFill && ctx.fill.a > 0 && pts.length >= 3)
        rasterFill(px, w, h, dev, ctx.fill);
}

/// Even-odd scanline fill of a device-space polygon.
private void rasterFill(ubyte[] px, int w, int h, Pt[] pts, Rgba col)
{
    if (pts.length < 3) return;
    double minY = pts[0].y, maxY = pts[0].y;
    foreach (p; pts)
    {
        minY = min(minY, p.y);
        maxY = max(maxY, p.y);
    }
    int y0 = cast(int) (minY < 0 ? 0 : minY);
    int y1 = cast(int) (maxY + 1);
    if (y1 > h) y1 = h;
    double[] xs;
    foreach (y; y0 .. y1)
    {
        xs.length = 0;
        auto sy = y + 0.5;
        foreach (i; 0 .. pts.length)
        {
            auto a = pts[i];
            auto b = pts[(i + 1) % pts.length];
            if ((a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy))
            {
                auto t = (sy - a.y) / (b.y - a.y);
                xs ~= a.x + t * (b.x - a.x);
            }
        }
        if (xs.length < 2) continue;
        sortNums(xs);
        for (size_t k = 0; k + 1 < xs.length; k += 2)
        {
            int xa = cast(int) (xs[k] + 0.5);
            int xb = cast(int) (xs[k + 1] + 0.5);
            if (xa < 0) xa = 0;
            if (xb > w) xb = w;
            foreach (x; xa .. xb) blend(px, w, h, x, y, col);
        }
    }
}

/// Map user-space points into device space through `m`.
private Pt[] toDevice(Pt[] pts, Mat m)
{
    Pt[] dev;
    foreach (p; pts) dev ~= Pt(m.applyX(p.x, p.y), m.applyY(p.x, p.y));
    return dev;
}

/// Even-odd fill of a COMPOUND path: several subpaths tested together.
///
/// `rasterFill` fills one polygon at a time, so a second subpath nested inside
/// the first was filled solid instead of punching a hole. Letterforms rely on
/// this: django's header logo draws "d" as an outer contour plus its counter
/// and sets `fill-rule="evenodd"`, and the naive per-subpath fill rendered the
/// "d" as a white blob. Counting crossings across every subpath before the
/// parity test is what makes an inner contour a hole.
private void rasterFillPolys(ubyte[] px, int w, int h, Pt[][] polys, Rgba col)
{
    size_t total;
    double minY = double.infinity, maxY = -double.infinity;
    foreach (poly; polys)
    {
        total += poly.length;
        foreach (p; poly)
        {
            minY = min(minY, p.y);
            maxY = max(maxY, p.y);
        }
    }
    if (total < 3) return;
    int y0 = cast(int) (minY < 0 ? 0 : minY);
    int y1 = cast(int) (maxY + 1);
    if (y1 > h) y1 = h;
    double[] xs;
    foreach (y; y0 .. y1)
    {
        xs.length = 0;
        auto sy = y + 0.5;
        foreach (poly; polys)
        {
            if (poly.length < 3) continue;
            foreach (i; 0 .. poly.length)
            {
                auto a = poly[i];
                auto b = poly[(i + 1) % poly.length];
                if ((a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy))
                {
                    auto t = (sy - a.y) / (b.y - a.y);
                    xs ~= a.x + t * (b.x - a.x);
                }
            }
        }
        if (xs.length < 2) continue;
        sortNums(xs);
        for (size_t k = 0; k + 1 < xs.length; k += 2)
        {
            int xa = cast(int) (xs[k] + 0.5);
            int xb = cast(int) (xs[k + 1] + 0.5);
            if (xa < 0) xa = 0;
            if (xb > w) xb = w;
            foreach (x; xa .. xb) blend(px, w, h, x, y, col);
        }
    }
}

/// Draw a polyline as thick segments (and a square at each joint).
private void rasterStroke(ubyte[] px, int w, int h, Pt[] pts, bool closed,
    double width, Rgba col)
{
    if (pts.length < 2) return;
    auto half = width <= 0 ? 0.5 : width / 2.0;
    auto n = pts.length;
    foreach (i; 0 .. (closed ? n : n - 1))
    {
        auto a = pts[i];
        auto b = pts[(i + 1) % n];
        double dx = b.x - a.x, dy = b.y - a.y;
        auto len = sqrt(dx * dx + dy * dy);
        if (len <= 0.00001)
        {
            quad(px, w, h, a, col, half, 0, 1, 0);
            continue;
        }
        dx /= len;
        dy /= len;
        Pt[] seg = [
            Pt(a.x - dy * half, a.y + dx * half),
            Pt(b.x - dy * half, b.y + dx * half),
            Pt(b.x + dy * half, b.y - dx * half),
            Pt(a.x + dy * half, a.y - dx * half),
        ];
        rasterFill(px, w, h, seg, col);
    }
}

/// A small square cap around a point (used for zero-length segments).
private void quad(ubyte[] px, int w, int h, Pt c, Rgba col, double half,
    double dx, double dy, double nx)
{
    Pt[] seg = [
        Pt(c.x - half, c.y - half), Pt(c.x + half, c.y - half),
        Pt(c.x + half, c.y + half), Pt(c.x - half, c.y + half),
    ];
    rasterFill(px, w, h, seg, col);
}

/// Source-over blend of `col` at (x, y).
private void blend(ubyte[] px, int w, int h, int x, int y, Rgba col)
{
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    auto idx = (y * w + x) * 4;
    auto sa = col.a / 255.0;
    if (sa <= 0) return;
    auto da = px[idx + 3] / 255.0;
    auto oa = sa + da * (1 - sa);
    if (oa <= 0) return;
    foreach (c; 0 .. 3)
    {
        auto sc = (c == 0) ? col.r : ((c == 1) ? col.g : col.b);
        auto dc = px[idx + c];
        px[idx + c] = cast(ubyte) ((sc * sa + dc * da * (1 - sa)) / oa + 0.5);
    }
    px[idx + 3] = cast(ubyte) (oa * 255.0 + 0.5);
}

/// Simple insertion sort for the crossing list (short lists only).
private void sortNums(double[] a)
{
    foreach (i; 1 .. a.length)
    {
        auto v = a[i];
        auto j = i;
        while (j > 0 && a[j - 1] > v)
        {
            a[j] = a[j - 1];
            j--;
        }
        a[j] = v;
    }
}

// ---------------------------------------------------------------------------
// Path flattening
// ---------------------------------------------------------------------------

private struct SubPath { Pt[] points; bool closed; }

/// Flatten a `d` attribute into subpaths of line segments.
private SubPath[] flattenPath(string d)
{
    SubPath[] outPaths;
    SubPath cur;
    double cx = 0, cy = 0;       // current point
    double sx = 0, sy = 0;       // subpath start
    char prevCmd = 0;
    double lastCtrlX = 0, lastCtrlY = 0;

    size_t i = 0;
    char cmd = 0;
    while (i < d.length)
    {
        while (i < d.length && (isSpace(d[i]) || d[i] == ',')) i++;
        if (i >= d.length) break;
        auto c = d[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
        {
            cmd = c;
            i++;
        }
        auto rel = cmd >= 'a' && cmd <= 'z';
        auto up = cast(char) ((cmd >= 'a' && cmd <= 'z') ? cmd - 32 : cmd);
        auto args = readArgs(d, i);
        // Reuse the previous command's argument count when args are implicit.
        if (args.length == 0 && up != 'Z' && up != 'M' && up != 'L' && up != 'H' &&
            up != 'V' && up != 'C' && up != 'S' && up != 'Q' && up != 'T')
            break;
        switch (up)
        {
            case 'M':
            {
                if (args.length < 2) break;
                if (cur.points.length >= 2) outPaths ~= cur;
                cur = SubPath();
                cx = rel ? cx + args[0] : args[0];
                cy = rel ? cy + args[1] : args[1];
                sx = cx;
                sy = cy;
                cur.points ~= Pt(cx, cy);
                // Extra coordinate pairs after M are implicit L.
                for (size_t k = 2; k + 1 < args.length; k += 2)
                {
                    cx = rel ? cx + args[k] : args[k];
                    cy = rel ? cy + args[k + 1] : args[k + 1];
                    cur.points ~= Pt(cx, cy);
                }
                break;
            }
            case 'L':
            {
                foreach (k; 0 .. args.length / 2)
                {
                    cx = rel ? cx + args[2 * k] : args[2 * k];
                    cy = rel ? cy + args[2 * k + 1] : args[2 * k + 1];
                    cur.points ~= Pt(cx, cy);
                }
                break;
            }
            case 'H':
            {
                foreach (k; 0 .. args.length)
                {
                    cx = rel ? cx + args[k] : args[k];
                    cur.points ~= Pt(cx, cy);
                }
                break;
            }
            case 'V':
            {
                foreach (k; 0 .. args.length)
                {
                    cy = rel ? cy + args[k] : args[k];
                    cur.points ~= Pt(cx, cy);
                }
                break;
            }
            case 'C':
            {
                foreach (k; 0 .. args.length / 6)
                {
                    auto x1 = rel ? cx + args[6 * k] : args[6 * k];
                    auto y1 = rel ? cy + args[6 * k + 1] : args[6 * k + 1];
                    auto x2 = rel ? cx + args[6 * k + 2] : args[6 * k + 2];
                    auto y2 = rel ? cy + args[6 * k + 3] : args[6 * k + 3];
                    auto x = rel ? cx + args[6 * k + 4] : args[6 * k + 4];
                    auto y = rel ? cy + args[6 * k + 5] : args[6 * k + 5];
                    cubicTo(cur.points, cx, cy, x1, y1, x2, y2, x, y);
                    lastCtrlX = x2;
                    lastCtrlY = y2;
                    cx = x; cy = y;
                }
                break;
            }
            case 'S':
            {
                foreach (k; 0 .. args.length / 4)
                {
                    auto x2 = rel ? cx + args[4 * k] : args[4 * k];
                    auto y2 = rel ? cy + args[4 * k + 1] : args[4 * k + 1];
                    auto x = rel ? cx + args[4 * k + 2] : args[4 * k + 2];
                    auto y = rel ? cy + args[4 * k + 3] : args[4 * k + 3];
                    double x1 = cx, y1 = cy;
                    if (prevCmd == 'C' || prevCmd == 'S')
                    {
                        x1 = 2 * cx - lastCtrlX;
                        y1 = 2 * cy - lastCtrlY;
                    }
                    cubicTo(cur.points, cx, cy, x1, y1, x2, y2, x, y);
                    lastCtrlX = x2;
                    lastCtrlY = y2;
                    cx = x; cy = y;
                }
                break;
            }
            case 'Q':
            {
                foreach (k; 0 .. args.length / 4)
                {
                    auto x1 = rel ? cx + args[4 * k] : args[4 * k];
                    auto y1 = rel ? cy + args[4 * k + 1] : args[4 * k + 1];
                    auto x = rel ? cx + args[4 * k + 2] : args[4 * k + 2];
                    auto y = rel ? cy + args[4 * k + 3] : args[4 * k + 3];
                    quadTo(cur.points, cx, cy, x1, y1, x, y);
                    lastCtrlX = x1;
                    lastCtrlY = y1;
                    cx = x; cy = y;
                }
                break;
            }
            case 'T':
            {
                foreach (k; 0 .. args.length / 2)
                {
                    auto x = rel ? cx + args[2 * k] : args[2 * k];
                    auto y = rel ? cy + args[2 * k + 1] : args[2 * k + 1];
                    double x1 = cx, y1 = cy;
                    if (prevCmd == 'Q' || prevCmd == 'T')
                    {
                        x1 = 2 * cx - lastCtrlX;
                        y1 = 2 * cy - lastCtrlY;
                    }
                    quadTo(cur.points, cx, cy, x1, y1, x, y);
                    lastCtrlX = x1;
                    lastCtrlY = y1;
                    cx = x; cy = y;
                }
                break;
            }
            case 'Z':
            {
                cur.closed = true;
                if (cur.points.length >= 2) outPaths ~= cur;
                cur = SubPath();
                cx = sx;
                cy = sy;
                break;
            }
            case 'A':
            {
                // Elliptical arc: rx ry x-axis-rotation large-arc sweep x y
                foreach (k; 0 .. args.length / 7)
                {
                    auto rx = args[7 * k], ry = args[7 * k + 1];
                    auto rot = args[7 * k + 2];
                    auto largeArc = args[7 * k + 3] != 0;
                    auto sweep = args[7 * k + 4] != 0;
                    auto x = rel ? cx + args[7 * k + 5] : args[7 * k + 5];
                    auto y = rel ? cy + args[7 * k + 6] : args[7 * k + 6];
                    arcTo(cur.points, cx, cy, rx, ry, rot, largeArc, sweep, x, y);
                    cx = x;
                    cy = y;
                }
                break;
            }
            default:
                // Unknown command: stop cleanly rather than misparse.
                i = d.length;
                break;
        }
        prevCmd = up;
    }
    if (cur.points.length >= 2) outPaths ~= cur;
    return outPaths;
}

/// Read numeric arguments starting at `i` (stops at the next command letter).
private double[] readArgs(string d, ref size_t i)
{
    auto start = i;
    while (i < d.length)
    {
        auto c = d[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) break;
        i++;
    }
    return nums(d[start .. i]);
}

/// Append a flattened cubic Bézier from (x0,y0) to (x3,y3).
/// Append a flattened elliptical arc (SVG implementation notes F.6.5: endpoint
/// parameterisation converted to centre parameterisation, then sampled).
private void arcTo(ref Pt[] pts, double x0, double y0, double rx, double ry,
    double rotationDeg, bool largeArc, bool sweep, double x1, double y1)
{
    const pi = 3.14159265358979;
    if (rx == 0 || ry == 0 || (x0 == x1 && y0 == y1))
    {
        pts ~= Pt(x1, y1);
        return;
    }
    rx = fabs(rx);
    ry = fabs(ry);
    auto phi = rotationDeg * pi / 180.0;
    auto cosp = cos(phi), sinp = sin(phi);

    auto dx2 = (x0 - x1) / 2.0, dy2 = (y0 - y1) / 2.0;
    auto x1p = cosp * dx2 + sinp * dy2;
    auto y1p = -sinp * dx2 + cosp * dy2;

    // Scale radii up if they are too small to span the endpoints.
    auto lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1)
    {
        auto s = sqrt(lambda);
        rx *= s;
        ry *= s;
    }

    auto num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    auto den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    auto co = den > 0 ? sqrt(num > 0 ? num / den : 0.0) : 0.0;
    if (largeArc == sweep) co = -co;
    auto cxp = co * rx * y1p / ry;
    auto cyp = -co * ry * x1p / rx;

    auto cx = cosp * cxp - sinp * cyp + (x0 + x1) / 2.0;
    auto cy = sinp * cxp + cosp * cyp + (y0 + y1) / 2.0;

    double angleBetween(double ux, double uy, double vx, double vy)
    {
        return atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    }
    auto ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
    auto vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
    auto theta1 = angleBetween(1, 0, ux, uy);
    auto dtheta = angleBetween(ux, uy, vx, vy);
    if (!sweep && dtheta > 0) dtheta -= 2 * pi;
    else if (sweep && dtheta < 0) dtheta += 2 * pi;

    enum int steps = 24;
    foreach (k; 1 .. steps + 1)
    {
        auto t = theta1 + dtheta * k / steps;
        auto ct = cos(t), st = sin(t);
        pts ~= Pt(cx + rx * ct * cosp - ry * st * sinp,
            cy + rx * ct * sinp + ry * st * cosp);
    }
}

private void cubicTo(ref Pt[] pts, double x0, double y0, double x1, double y1,
    double x2, double y2, double x3, double y3)
{
    enum int steps = 16;
    foreach (k; 1 .. steps + 1)
    {
        auto t = cast(double) k / steps;
        auto mt = 1 - t;
        auto x = mt * mt * mt * x0 + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t * t * t * x3;
        auto y = mt * mt * mt * y0 + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t * t * t * y3;
        pts ~= Pt(x, y);
    }
}

/// Append a flattened quadratic Bézier from (x0,y0) to (x2,y2).
private void quadTo(ref Pt[] pts, double x0, double y0, double x1, double y1,
    double x2, double y2)
{
    enum int steps = 12;
    foreach (k; 1 .. steps + 1)
    {
        auto t = cast(double) k / steps;
        auto mt = 1 - t;
        auto x = mt * mt * x0 + 2 * mt * t * x1 + t * t * x2;
        auto y = mt * mt * y0 + 2 * mt * t * y1 + t * t * y2;
        pts ~= Pt(x, y);
    }
}

unittest
{
    // Intrinsic size comes from the width/height attributes.
    auto a = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='12'>" ~
        "<rect width='16' height='12' fill='#ff0000'/>" ~
        "<circle cx='8' cy='6' r='4' fill='blue'/></svg>";
    assert(looksLikeSvg(cast(const(ubyte)[]) a), "looksLikeSvg must detect SVG bytes");

    auto ia = decodeSvg(cast(const(ubyte)[]) a);
    assert(ia !is null, "a simple SVG must rasterise");
    assert(ia.width() == 16 && ia.height() == 12,
        "intrinsic size must come from the width/height attributes");
    // The red rectangle must actually be painted (RGBA order).
    auto pa = ia.pixels();
    assert(pa.length == 16 * 12 * 4, "the pixel buffer must be RGBA8");
    // (1,1) is inside the red rectangle but outside the blue circle at (8,6)r4.
    auto cornerA = (1 * 16 + 1) * 4;
    assert(pa[cornerA] >= 200 && pa[cornerA + 1] <= 60 && pa[cornerA + 2] <= 60 &&
        pa[cornerA + 3] >= 200,
        "the rect fill must be red; got " ~ to!string([pa[cornerA], pa[cornerA + 1],
            pa[cornerA + 2], pa[cornerA + 3]]));
    // The circle centre must be blue: two shapes really are painted.
    auto midA = (6 * 16 + 8) * 4;
    assert(pa[midA + 2] >= 200 && pa[midA] <= 60,
        "the circle fill must be blue; got " ~ to!string([pa[midA], pa[midA + 1],
            pa[midA + 2], pa[midA + 3]]));

    // A viewBox scales user units up to the declared viewport.
    auto b = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8' " ~
        "viewBox='0 0 4 4'><rect width='4' height='4' fill='#000000'/></svg>";
    auto ib = decodeSvg(cast(const(ubyte)[]) b);
    assert(ib !is null && ib.width() == 8 && ib.height() == 8,
        "viewBox must scale to the declared viewport");

    // A stroked path — the shape most icon files use — must rasterise.
    auto c2 = "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>" ~
        "<path d='M4 12 L12 4 L20 12' fill='none' stroke='black' stroke-width='2'/></svg>";
    auto ic = decodeSvg(cast(const(ubyte)[]) c2);
    assert(ic !is null && ic.width() == 24, "a stroked path must rasterise");

    // Curves and groups likewise.
    auto d2 = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>" ~
        "<g transform='translate(2,2) scale(0.5)'>" ~
        "<path d='M0 0 C10 0 10 10 20 10 Z' fill='#334455'/>" ~
        "<rect x='1' y='1' width='4' height='4' fill='#ffffff'/></g></svg>";
    auto id2 = decodeSvg(cast(const(ubyte)[]) d2);
    assert(id2 !is null && id2.width() == 20, "curves and transforms must rasterise");

    // Presentation attributes inherit through containers (SVG 1.1 section
    // 11.3): a `<g fill>` colours the shapes inside it even when they carry no
    // fill of their own. djangoproject.com's wordmark is exactly this markup,
    // and without the rule its paths took the element's CSS colour.
    auto gf = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'>" ~
        "<g fill='#ff0000'><rect width='8' height='8'/></g></svg>";
    auto igf = decodeSvg(cast(const(ubyte)[]) gf);
    assert(igf !is null, "a group-filled SVG must rasterise");
    {
        auto pgf = igf.pixels();
        const midGf = (4 * 8 + 4) * 4;
        assert(pgf[midGf] >= 200 && pgf[midGf + 1] <= 60 && pgf[midGf + 2] <= 60,
            "a <g fill> must colour the shapes inside it; got " ~
            to!string([pgf[midGf], pgf[midGf + 1], pgf[midGf + 2], pgf[midGf + 3]]));
    }
    // A group that turns the fill off must clear it for its own subtree only.
    auto gn = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'>" ~
        "<g fill='#ff0000'><g fill='none'><rect width='8' height='8'/></g></g></svg>";
    auto ign = decodeSvg(cast(const(ubyte)[]) gn);
    assert(ign !is null, "a fill='none' group must still rasterise");
    assert(ign.pixels()[(4 * 8 + 4) * 4 + 3] == 0,
        "a nested fill='none' must clear the inherited fill");

    // Other formats must not be claimed by the SVG path.
    auto png = cast(const(ubyte)[]) "\x89PNG\r\n\x1a\n";
    assert(!looksLikeSvg(png), "PNG bytes must not look like SVG");

    // `fill="currentColor"` takes the inherited CSS colour — how icons work. A
    // white icon on a dark page used to rasterise black and disappear.
    auto cc = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'>" ~
        "<rect width='8' height='8' fill='currentColor'/></svg>";
    auto icc = decodeSvg(cast(const(ubyte)[]) cc, Rgba(255, 255, 255, 255));
    assert(icc !is null && icc.width() == 8, "a currentColor SVG must rasterise");
    auto pcc = icc.pixels();
    auto midCC = (4 * 8 + 4) * 4;
    assert(pcc[midCC] >= 200 && pcc[midCC + 1] >= 200 && pcc[midCC + 2] >= 200,
        "a currentColor fill must take the inherited colour; got " ~
        to!string([pcc[midCC], pcc[midCC + 1], pcc[midCC + 2], pcc[midCC + 3]]));
    auto iccDefault = decodeSvg(cast(const(ubyte)[]) cc);
    assert(iccDefault !is null, "currentColor must default to black, not fail");

    // Arcs: a circle drawn with two elliptical arc commands, then filled.
    auto e2 = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>" ~
        "<path d='M2 10 A8 8 0 0 1 18 10 A8 8 0 0 1 2 10 Z' fill='#0000ff'/></svg>";
    auto ie = decodeSvg(cast(const(ubyte)[]) e2);
    assert(ie !is null && ie.width() == 20, "an arc path must rasterise");
    auto pe = ie.pixels();
    auto centreE = (10 * 20 + 10) * 4;
    assert(pe[centreE + 2] >= 200 && pe[centreE + 3] >= 200,
        "an arc-drawn circle must fill blue; got " ~ to!string([pe[centreE],
            pe[centreE + 1], pe[centreE + 2], pe[centreE + 3]]));
    // A corner outside the circle must stay untouched.
    auto cornerE = (0 * 20 + 0) * 4;
    assert(pe[cornerE + 3] <= 60,
        "the area outside the arc circle must stay empty; alpha was " ~
        to!string(pe[cornerE + 3]));

    // A CSS linear-gradient must rasterise through the SVG gradient code: a
    // 180deg red->blue ramp is red at the top and blue at the bottom.
    {
        auto svgGrad = gradientToSvg(
            "linear-gradient(180deg, #ff0000 0%, #0000ff 100%)", 8, 8);
        assert(svgGrad.length > 0, "a CSS gradient must produce SVG markup");
        auto gi = decodeSvg(cast(const(ubyte)[]) svgGrad);
        assert(gi !is null && gi.width() == 8,
            "the synthesised gradient must rasterise");
        auto gp = gi.pixels();
        const topG = (0 * 8 + 4) * 4;
        const botG = (7 * 8 + 4) * 4;
        assert(gp[topG] >= 150 && gp[topG + 2] <= 80,
            "180deg starts red at the top; got " ~ to!string([gp[topG],
                gp[topG + 1], gp[topG + 2], gp[topG + 3]]));
        assert(gp[botG + 2] >= 150 && gp[botG] <= 80,
            "180deg ends blue at the bottom; got " ~ to!string([gp[botG],
                gp[botG + 1], gp[botG + 2], gp[botG + 3]]));
    }

    // A linear gradient must ramp across the shape: red left, blue right.
    auto f2 = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='4'>" ~
        "<defs><linearGradient id='g1'><stop offset='0' stop-color='#ff0000'/>" ~
        "<stop offset='1' stop-color='#0000ff'/></linearGradient></defs>" ~
        "<rect width='20' height='4' fill='url(#g1)'/></svg>";
    auto if2 = decodeSvg(cast(const(ubyte)[]) f2);
    assert(if2 !is null && if2.width() == 20, "a gradient-filled SVG must rasterise");
    auto pf = if2.pixels();
    auto leftF = (2 * 20 + 1) * 4;
    auto rightF = (2 * 20 + 18) * 4;
    assert(pf[leftF] >= 150 && pf[leftF + 2] <= 80 && pf[leftF + 3] >= 200,
        "the gradient's left edge must be red; got " ~ to!string([pf[leftF],
            pf[leftF + 1], pf[leftF + 2], pf[leftF + 3]]));
    assert(pf[rightF + 2] >= 150 && pf[rightF] <= 80 && pf[rightF + 3] >= 200,
        "the gradient's right edge must be blue; got " ~ to!string([pf[rightF],
            pf[rightF + 1], pf[rightF + 2], pf[rightF + 3]]));

    // A radial gradient must be centred, not linear: red in the middle, blue
    // by the corner.
    auto r2 = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>" ~
        "<defs><radialGradient id='rg'><stop offset='0' stop-color='#ff0000'/>" ~
        "<stop offset='1' stop-color='#0000ff'/></radialGradient></defs>" ~
        "<rect width='20' height='20' fill='url(#rg)'/></svg>";
    auto ir2 = decodeSvg(cast(const(ubyte)[]) r2);
    assert(ir2 !is null && ir2.width() == 20, "a radial-gradient SVG must rasterise");
    auto pr = ir2.pixels();
    auto midR = (10 * 20 + 10) * 4;
    auto cornerR = (0 * 20 + 0) * 4;
    assert(pr[midR] >= 150 && pr[midR + 2] <= 80 && pr[midR + 3] >= 200,
        "the radial gradient centre must be red; got " ~ to!string([pr[midR],
            pr[midR + 1], pr[midR + 2], pr[midR + 3]]));
    assert(pr[cornerR + 2] >= 150 && pr[cornerR] <= 120 && pr[cornerR + 3] >= 200,
        "the radial gradient corner must tend to blue; got " ~ to!string([pr[cornerR],
            pr[cornerR + 1], pr[cornerR + 2], pr[cornerR + 3]]));
}

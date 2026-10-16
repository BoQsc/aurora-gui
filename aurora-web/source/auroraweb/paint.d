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
import aurora.types : Point, Rect, maxInt, minInt;
import auroraweb.dom : ComputedStyle, Element, TextNode;
import auroraweb.shaping : shapeTextCached;

import std.conv : to;
import std.string : indexOf, lastIndexOf, split, startsWith, strip, toLower;
import std.algorithm : max, min, sort;
import std.math : abs;

/// Fill the canvas with the page background color: the `<body>` background
/// (falling back to the root element's), the way a browser paints the "canvas
/// background". Without this, a dark page body would sit on a white canvas.
void fillCanvasBackground(Canvas canvas, Element root, int width, int height)
{
    _canvasBg = canvasBackgroundColor(root);
    if (!_canvasBg.present) return;
    // Fill the VISIBLE clip (mapped back to this canvas's local coordinates)
    // rather than a page-anchored (0,0,w,h): the page-anchored rect leaves the
    // lower viewport uncovered once the canvas is scrolled. The surface clips
    // the fill, so the cost is exactly the visible area.
    const clip = canvas.clipRect();
    const off = canvas.toSurface(Point(0, 0));
    canvas.fillRect(Rect(clip.x - off.x, clip.y - off.y, clip.width, clip.height),
        _canvasBg.color);
}

/// The color painted across the canvas by `fillCanvasBackground`, so
/// `paintElement` does not paint the very same color again on the `<body>` box
/// (which would double that full-viewport fill every frame).
private NullableColor _canvasBg;

/// The color the page paints across its canvas: the `<body>` background, else
/// the root element's. `present` is false when neither declares a paintable
/// background — then the host's own default clear shows through.
NullableColor canvasBackgroundColor(Element root)
{
    if (root is null) return NullableColor.init;
    Element bgEl = null;
    foreach (e; root.elements)
        if (e.tag == "body")
        {
            bgEl = e;
            break;
        }
    auto value = (bgEl !is null) ? bgEl.style.background : "";
    if (value.length == 0) value = root.style.background;
    if (value.length == 0) return NullableColor.init;
    return parseColor(value);
}

/// Whether the `<body>` element itself paints a background. The body's box spans
/// the whole document, so its own fill covers the viewport at any scroll — which
/// makes it safe for the host to skip its default clear. (The viewport-sized
/// canvas-background fill only covers the top of the document, so it alone is
/// not sufficient when scrolled.)
bool bodyPaintsBackground(Element root)
{
    if (root is null) return false;
    foreach (e; root.elements)
        if (e.tag == "body")
            return parseColor(e.style.background).present;
    return false;
}

/// The viewport scroll offset for the current paint. The engine scrolls by
/// translating the canvas, so the offset is invisible in element coordinates; a
/// `position: sticky` box needs it to know where its containing block sits.
private int _paintScrollY;

/// Paint a full tree into a surface's canvas. `scrollY` is the viewport's scroll
/// offset in px (0 for an unscrolled paint).
void paintTree(Element root, Canvas canvas, int scrollY = 0)
{
    _paintScrollY = scrollY;
    paintElement(root, canvas);
}

/// Translate an element's whole box tree (element boxes and text runs) so a
/// subtree can be painted into a layer whose origin is the element's box corner.
private void translateBoxTree(Element el, int dx, int dy)
{
    el.box.x += dx;
    el.box.y += dy;
    foreach (child; el.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            t.layoutX += dx;
            t.layoutY += dy;
            continue;
        }
        auto ce = cast(Element) child;
        if (ce !is null) translateBoxTree(ce, dx, dy);
    }
}

/// Rasterise a `linear-gradient(...)` mask at a box size (null when the value is
/// not a supported gradient). Straight-alpha RGBA8, so the alpha channel is the
/// mask's coverage.
private RgbaImage gradientMaskImage(string css, int w, int h)
{
    import auroraweb.svg : gradientToSvg, decodeSvg;
    const g = css.strip();
    if (g.length < 16) return null;
    // `linear-gradient(` and `radial-gradient(` are both 16 characters, and the
    // engine's gradient-to-SVG path (and its rasteriser) already handle both.
    const head = g[0 .. 16].toLower();
    if (head != "linear-gradient(" && head != "radial-gradient(") return null;
    auto svg = gradientToSvg(g, max(1, w), max(1, h));
    if (svg.length == 0) return null;
    try return decodeSvg(cast(const(ubyte)[]) svg);
    catch (Throwable) return null;
}

/// Paint `element` (and its subtree) through its `filter` (CSS Filter Effects 1).
/// Layering works exactly like `paintMaskedLayer` — the subtree goes into a layer
/// surface and is drawn back — but the layer's colours are transformed rather
/// than its alpha. Returns false when there is nothing to filter.
private bool paintFilterLayer(Element element, Canvas canvas)
{
    const string spec = element.style.filter.strip();
    if (spec.length == 0 || spec == "none") return false;
    const int w = element.box.width;
    const int h = element.box.height;
    if (w <= 0 || h <= 0) return false;

    import aurora.surface : Surface;
    auto layerSurface = new Surface(w, h);
    layerSurface.clear(Color(0, 0, 0, 0));

    // Paint the subtree into the layer with the element's own filter disabled so
    // this cannot recurse.
    const int bx = element.box.x;
    const int by = element.box.y;
    const string savedFilter = element.style.filter;
    element.style.filter = "none";
    translateBoxTree(element, -bx, -by);
    try paintElement(element, Canvas(layerSurface));
    catch (Throwable) { }
    translateBoxTree(element, bx, by);
    element.style.filter = savedFilter;

    auto lp = layerSurface.pixels();
    applyColourFilterChain(lp, spec);

    // Back to straight-alpha RGBA8 for the canvas (Surface is premultiplied).
    auto rgba = new ubyte[](cast(size_t) w * h * 4);
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const uint p = lp[cast(size_t) y * w + x];
            const uint a = (p >> 24) & 0xff;
            uint r = (p >> 16) & 0xff;
            uint g = (p >> 8) & 0xff;
            uint b = p & 0xff;
            if (a > 0 && a < 255)
            {
                r = min(255, (r * 255 + a / 2) / a);
                g = min(255, (g * 255 + a / 2) / a);
                b = min(255, (b * 255 + a / 2) / a);
            }
            const size_t i = (cast(size_t) y * w + x) * 4;
            rgba[i] = cast(ubyte) r;
            rgba[i + 1] = cast(ubyte) g;
            rgba[i + 2] = cast(ubyte) b;
            rgba[i + 3] = cast(ubyte) a;
        }
    canvas.drawImage(Rect(bx, by, w, h), new RgbaImage(w, h, rgba), false);
    return true;
}

/// Apply a `filter` list to a premultiplied ARGB layer, function by function in
/// order (the spec's composition). Each function is a whole-layer pass. The
/// colour-only functions are implemented; `blur`, `drop-shadow` and `hue-rotate`
/// are skipped rather than approximated. A pixel is skipped only for its own
/// function, so the rest of a list still applies.
private void applyColourFilterChain(uint[] layer, string spec)
{
    import std.string : endsWith, indexOf, lastIndexOf;

    foreach (raw; spec.split())
    {
        const auto fn = raw.strip().toLower();
        if (fn.length == 0) continue;
        const auto open = indexOf(fn, '(');
        const string name = open < 0 ? fn : fn[0 .. open];
        double amount = 1.0;
        if (open >= 0)
        {
            const auto close = lastIndexOf(fn, ')');
            if (close > open)
            {
                const auto inner = fn[open + 1 .. close].strip();
                const bool pct = endsWith(inner, "%");
                const auto num = pct ? inner[0 .. $ - 1].strip() : inner;
                try amount = to!double(num) / (pct ? 100.0 : 1.0);
                catch (Exception) amount = 1.0;
            }
        }

        const bool isGray = name == "grayscale";
        const bool isSepia = name == "sepia";
        const bool isBright = name == "brightness";
        const bool isInvert = name == "invert";
        const bool isSat = name == "saturate";
        const bool isOpacity = name == "opacity";
        if (!isGray && !isSepia && !isBright && !isInvert && !isSat && !isOpacity)
            continue;

        foreach (ref uint p; layer)
        {
            const uint a = (p >> 24) & 0xff;
            if (a == 0) continue;
            // The spec's functions operate on straight colour, so undo the
            // surface's premultiplication, transform, then re-premultiply.
            double r = ((p >> 16) & 0xff) * 255.0 / a;
            double g = ((p >> 8) & 0xff) * 255.0 / a;
            double b = (p & 0xff) * 255.0 / a;
            uint outAlpha = a;

            if (isGray || isSat)
            {
                const double l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                const double t = isGray ? amount : amount;
                r = l + (r - l) * (isGray ? (1.0 - t) : t);
                g = l + (g - l) * (isGray ? (1.0 - t) : t);
                b = l + (b - l) * (isGray ? (1.0 - t) : t);
            }
            else if (isSepia)
            {
                const double nr = 0.393 * r + 0.769 * g + 0.189 * b;
                const double ng = 0.349 * r + 0.686 * g + 0.168 * b;
                const double nb = 0.272 * r + 0.534 * g + 0.131 * b;
                r += (nr - r) * amount;
                g += (ng - g) * amount;
                b += (nb - b) * amount;
            }
            else if (isBright)
            {
                r *= amount;
                g *= amount;
                b *= amount;
            }
            else if (isInvert)
            {
                r += ((255.0 - r) - r) * amount;
                g += ((255.0 - g) - g) * amount;
                b += ((255.0 - b) - b) * amount;
            }
            else if (isOpacity)
                outAlpha = cast(uint) (a * amount);

            r = r < 0.0 ? 0.0 : (r > 255.0 ? 255.0 : r);
            g = g < 0.0 ? 0.0 : (g > 255.0 ? 255.0 : g);
            b = b < 0.0 ? 0.0 : (b > 255.0 ? 255.0 : b);
            p = (outAlpha << 24) |
                (cast(uint) (r * a / 255.0) << 16) |
                (cast(uint) (g * a / 255.0) << 8) |
                cast(uint) (b * a / 255.0);
        }
    }
}

/// Paint `element` (and its subtree) through its `mask-image`.
///
/// A mask cannot be applied to the shared canvas directly: `Canvas` is a vendor
/// struct whose surface is private and the app paints through a DrawList. So the
/// subtree is painted into a layer surface, that layer's premultiplied ARGB is
/// multiplied by the mask's alpha, and the layer is drawn back as an image.
/// Returns false when there is nothing to mask (the caller then paints normally).
private bool paintMaskedLayer(Element element, Canvas canvas)
{
    auto mask = gradientMaskImage(element.style.maskImage, element.box.width,
        element.box.height);
    if (mask is null) return false;
    const int w = element.box.width;
    const int h = element.box.height;
    if (w <= 0 || h <= 0) return false;

    import aurora.surface : Surface;
    auto layerSurface = new Surface(w, h);
    layerSurface.clear(Color(0, 0, 0, 0));

    // Paint the subtree into the layer at the layer's origin, with the element's
    // own mask disabled so this cannot recurse.
    const int bx = element.box.x;
    const int by = element.box.y;
    const string savedMask = element.style.maskImage;
    element.style.maskImage = "none";
    translateBoxTree(element, -bx, -by);
    try paintElement(element, Canvas(layerSurface));
    catch (Throwable) { }
    translateBoxTree(element, bx, by);
    element.style.maskImage = savedMask;

    // Multiply the layer's premultiplied ARGB by the mask's alpha.
    auto lp = layerSurface.pixels();
    auto mp = mask.pixels();
    const int mw = mask.width();
    const int mh = mask.height();
    foreach (y; 0 .. h)
    {
        const int my = (y * mh) / h;
        foreach (x; 0 .. w)
        {
            const int mx = (x * mw) / w;
            const size_t mi = (cast(size_t) my * mw + mx) * 4 + 3;
            const uint ma = mi < mp.length ? cast(uint) mp[mi] : 0;
            if (ma == 255) continue;
            const size_t li = cast(size_t) y * w + x;
            const uint p = lp[li];
            lp[li] = ((((p >> 24) & 0xff) * ma / 255) << 24 |
                      (((p >> 16) & 0xff) * ma / 255) << 16 |
                      (((p >> 8) & 0xff) * ma / 255) << 8 |
                      ((p & 0xff) * ma / 255));
        }
    }

    // Back to straight-alpha RGBA8 for the canvas (Surface is premultiplied).
    auto rgba = new ubyte[](cast(size_t) w * h * 4);
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const uint p = lp[cast(size_t) y * w + x];
            const uint a = (p >> 24) & 0xff;
            uint r = (p >> 16) & 0xff;
            uint g = (p >> 8) & 0xff;
            uint b2 = p & 0xff;
            if (a > 0 && a < 255)
            {
                r = min(255, (r * 255 + a / 2) / a);
                g = min(255, (g * 255 + a / 2) / a);
                b2 = min(255, (b2 * 255 + a / 2) / a);
            }
            const size_t i = (cast(size_t) y * w + x) * 4;
            rgba[i] = cast(ubyte) r;
            rgba[i + 1] = cast(ubyte) g;
            rgba[i + 2] = cast(ubyte) b2;
            rgba[i + 3] = cast(ubyte) a;
        }
    canvas.drawImage(Rect(bx, by, w, h), new RgbaImage(w, h, rgba), false);
    return true;
}

/// Paint one element (and its children). Boxes carry absolute coordinates.
private void paintElement(Element element, Canvas canvas)
{
    // `position: sticky`: pin the box within its containing block while the page
    // scrolls (CSS Position 3). Done by offsetting the painted subtree, and
    // restored afterwards, so layout geometry stays untouched.
    if (element.style.isSticky && _paintScrollY > 0)
    {
        const int topInset = element.style.resolveLength(element.style.top, 0);
        int delta = max(0, _paintScrollY + max(0, topInset) - element.box.y);
        if (delta > 0)
        {
            // Never travel past the containing block's bottom edge.
            auto parent = element.parent;
            if (parent !is null)
            {
                const int room = parent.box.y + parent.box.height -
                    (element.box.y + element.box.height);
                delta = min(delta, max(0, room));
            }
            if (delta > 0)
            {
                translateBoxTree(element, 0, delta);
                scope(exit) translateBoxTree(element, 0, -delta);
            }
        }
    }

    // `mask-image`: paint the whole element through its mask instead of directly.
    if (element.style.maskImage.length && element.style.maskImage != "none" &&
        element.style.display != "none" && element.style.visibility != "hidden" &&
        element.style.display != "inline-block" &&
        element.style.display != "inline" && element.style.display != "inline-flex" &&
        paintMaskedLayer(element, canvas))
        return;

    // `filter`: same layering as the mask (it also covers the whole subtree), but
    // it transforms the layer's colours instead of its alpha.
    if (element.style.filter.length && element.style.filter != "none" &&
        element.style.display != "none" && element.style.visibility != "hidden" &&
        element.style.display != "inline-block" &&
        element.style.display != "inline" && element.style.display != "inline-flex" &&
        paintFilterLayer(element, canvas))
        return;

    // `visibility: hidden` hides the whole subtree. The engine does not inherit
    // `visibility` into unspecified children, so painting a hidden box's
    // descendants would wrongly reveal them; the CSS escape hatch (a descendant
    // declaring `visibility: visible`) is therefore not supported.
    if (element.style.display == "none" || element.style.visibility == "hidden"
        || element.style.visibility == "collapse")
        return;

    const absX = element.box.x;
    const absY = element.box.y;

    // CSS `transform: translate(...)`: shift this element's painting, and via the
    // canvas offset its whole subtree (interact.d mirrors this for hit-testing).
    // Ignoring transforms left every element that pages centre with
    // `translate(-50%, -50%)` in the wrong place.
    int tdx = 0;
    int tdy = 0;
    import auroraweb.layout : transformTranslate;
    transformTranslate(element.style.transform, element.box.width,
        element.box.height, tdx, tdy);
    if (tdx != 0 || tdy != 0)
        canvas = canvas.translated(tdx, tdy);

    // `box.x/box.y` is the border-box origin and `box.width/height` is the
    // CONTENT box (that is what layout stores). Reconstruct the border box so
    // backgrounds, borders and shadows cover padding + border, and use the real
    // content box for clipping and text wrapping.
    const contentW = element.box.width;
    const contentH = element.box.height;
    const borderW = contentW + element.box.paddingLeft + element.box.paddingRight +
        element.box.borderLeft + element.box.borderRight;
    const borderH = contentH + element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;

    // `background-clip: text` (gradient text) does NOT paint the box — the
    // background becomes the glyph fill, so skip the box fill and paint the
    // text in the background color instead.
    const bool textClip = element.style.backgroundClip == "text";

    // Viewport culling: if the border box lies entirely outside the current
    // clip, none of this element's own fills/border/text can be visible, so
    // skip them. Children are still walked — a positioned descendant may
    // overflow this box and still land inside the clip.
    //
    // `clipRect()` is in SURFACE coordinates, while element boxes are in the
    // canvas's local coordinates, so map the box through `toSurface` first —
    // otherwise a scrolled/offset canvas would cull visible elements.
    const clip = canvas.clipRect();
    const tl = canvas.toSurface(Point(absX, absY));
    const br = canvas.toSurface(Point(absX + borderW, absY + borderH));
    const bool selfVisible =
        tl.x < clip.x + clip.width && tl.y < clip.y + clip.height &&
        br.x > clip.x && br.y > clip.y;

    if (selfVisible)
    {
        // box-shadow: a semi-transparent copy of the box offset by (H,V),
        // painted BEHIND the element so its corners round like the box.
        paintShadow(element, canvas, absX, absY, borderW, borderH);

        const radius = roundedRadius(element, borderW, borderH);

        // Background over the padding/border box (rounded corners if radius>0).
        const bg = parseColor(element.style.background);
        // The `<body>` background was already propagated to the canvas by
        // `fillCanvasBackground`; painting it again here is a redundant
        // full-viewport fill of the identical color.
        const bool redundantCanvasBg = element.tag == "body" && bg.present &&
            _canvasBg.present && bg.color.r == _canvasBg.color.r &&
            bg.color.g == _canvasBg.color.g && bg.color.b == _canvasBg.color.b &&
            bg.color.a == _canvasBg.color.a;
        if (bg.present && !textClip && !redundantCanvasBg)
        {
            // A wrapping inline box is fragmented across lines (CSS 9.4.2), and
            // its background belongs on every line it covers — painting only the
            // element's single box decorated the first line and left the rest of
            // a wrapped inline link bare.
            if (element.inlineFragments.length > 1)
            {
                foreach (frag; element.inlineFragments)
                    fillRoundedBox(canvas, frag.x, frag.y, frag.width, frag.height,
                        cornerRadii(element, frag.width, frag.height),
                        withOpacity(bg.color, element.style.opacity));
            }
            else
            {
                fillRoundedBox(canvas, absX, absY, borderW, borderH,
                    cornerRadii(element, borderW, borderH),
                    withOpacity(bg.color, element.style.opacity));
            }
        }

        // CSS background-image (drawn over the solid background color).
        auto bgImage = cast(RgbaImage) element.backgroundImage;
        if (bgImage !is null)
        {
            auto dst = backgroundDestRect(element, bgImage);
            if (dst.width > 0 && dst.height > 0)
            {
                const rep = element.style.backgroundRepeat;
                if (rep == "no-repeat")
                    canvas.drawImage(dst, bgImage);
                else
                {
                    // CSS tiles background images by default, from the padding
                    // box origin. Drawing the image once left everything past
                    // the first tile blank (background-repeat was unimplemented).
                    const int bx = absX + element.box.borderLeft;
                    const int by = absY + element.box.borderTop;
                    const int bw = element.box.width;
                    const int bh = element.box.height;
                    const bool tileX = rep == "repeat" || rep == "repeat-x";
                    const bool tileY = rep == "repeat" || rep == "repeat-y";
                    const int sx = tileX ? bx : dst.x;
                    const int sy = tileY ? by : dst.y;
                    for (int y = sy; y < by + bh; y += dst.height)
                    {
                        for (int x = sx; x < bx + bw; x += dst.width)
                        {
                            auto tile = dst;
                            tile.x = x;
                            tile.y = y;
                            canvas.drawImage(tile, bgImage);
                        }
                    }
                }
            }
        }

        // Border: draw per-side around the border box. Each side resolves its
        // own colour — `border-<side>-color`, then the colour carried inside a
        // `border-<side>`/`border` shorthand, then the `border-color` shorthand,
        // and only then black. A page writing `border-bottom: 1px solid #ccc`
        // must not get a black line.
        const defaultBorderColor = Color.rgb(0, 0, 0);
        auto bst = element.style;
        auto widthSource(string infix, string perSide)
        {
            return perSide.length ? perSide : (infix.length ? infix : bst.border);
        }
        Color sideBorderColor(string perSideColor, string widthSrc, int sideIndex)
        {
            foreach (candidate; [perSideColor, borderColorToken(widthSrc),
                sideToken(bst.borderColor, sideIndex)])
                if (candidate.length)
                    return withOpacity(parseColorOrDefault(candidate, defaultBorderColor),
                        bst.opacity);
            return withOpacity(defaultBorderColor, bst.opacity);
        }
        auto topColor = sideBorderColor(bst.borderTopColor,
            widthSource(bst.borderWidth, bst.borderTopWidth), 0);
        auto bottomColor = sideBorderColor(bst.borderBottomColor,
            widthSource(bst.borderWidth, bst.borderBottomWidth), 2);
        auto leftColor = sideBorderColor(bst.borderLeftColor,
            widthSource(bst.borderWidth, bst.borderLeftWidth), 3);
        auto rightColor = sideBorderColor(bst.borderRightColor,
            widthSource(bst.borderWidth, bst.borderRightWidth), 1);
        // Rounded borders: flat side rectangles would leave SQUARE corners on a
        // rounded box, so when the box has a radius, a solid background and a
        // single border colour the border is drawn as the outer rounded box in
        // the border colour with the padding box punched back out in the
        // background colour. Skipping the flat rectangles is what removes the
        // square corners; the punch only runs over a plain background colour, so
        // background art is never erased.
        const borderRadii = cornerRadii(element, borderW, borderH);
        const bool roundedBorder = borderRadii.maxR() > 0 && bg.present &&
            bgImage is null && sameColor(topColor, bottomColor) &&
            sameColor(topColor, leftColor) && sameColor(topColor, rightColor);
        if (roundedBorder)
        {
            fillRoundedBox(canvas, absX, absY, borderW, borderH, borderRadii, topColor);
            CornerRadii inner = borderRadii;
            const bwL = element.box.borderLeft;
            const bwT = element.box.borderTop;
            const bwR = element.box.borderRight;
            const bwB = element.box.borderBottom;
            inner.tl = max(0, inner.tl - max(bwL, bwT));
            inner.tr = max(0, inner.tr - max(bwR, bwT));
            inner.br = max(0, inner.br - max(bwR, bwB));
            inner.bl = max(0, inner.bl - max(bwL, bwB));
            fillRoundedBox(canvas, absX + bwL, absY + bwT,
                max(0, borderW - bwL - bwR), max(0, borderH - bwT - bwB), inner,
                withOpacity(bg.color, element.style.opacity));
        }
        else
        {
            if (element.box.borderTop > 0)
                canvas.fillRect(Rect(absX, absY, borderW, element.box.borderTop), topColor);
            if (element.box.borderBottom > 0)
                canvas.fillRect(Rect(absX, absY + borderH - element.box.borderBottom,
                    borderW, element.box.borderBottom), bottomColor);
            if (element.box.borderLeft > 0)
                canvas.fillRect(Rect(absX, absY, element.box.borderLeft, borderH), leftColor);
            if (element.box.borderRight > 0)
                canvas.fillRect(Rect(absX + borderW - element.box.borderRight, absY,
                    element.box.borderRight, borderH), rightColor);
        }

        // outline: drawn OUTSIDE the border box (shifted by `outline-offset`)
        // and never part of layout — this is what focus rings use.
        const outlinePx = outlineWidthPx(bst.outlineWidth.length
            ? bst.outlineWidth : bst.outline);
        if (outlinePx > 0)
        {
            const offPx = bst.outlineOffset.length ? max(0, bst.pxLength(bst.outlineOffset)) : 0;
            const d = outlinePx + offPx;
            const outlineColorValue = bst.outlineColor.length
                ? bst.outlineColor : borderColorToken(bst.outline);
            const oc = withOpacity(parseColorOrDefault(outlineColorValue, Color.rgb(0, 0, 0)),
                bst.opacity);
            canvas.fillRect(Rect(absX - d, absY - d, borderW + 2 * d, outlinePx), oc);
            canvas.fillRect(Rect(absX - d, absY + borderH + d - outlinePx,
                borderW + 2 * d, outlinePx), oc);
            canvas.fillRect(Rect(absX - d, absY - d, outlinePx, borderH + 2 * d), oc);
            canvas.fillRect(Rect(absX + borderW + d - outlinePx, absY - d,
                outlinePx, borderH + 2 * d), oc);
        }
    }

    // The content box: inside the border and padding.
    const innerX = absX + element.box.borderLeft + element.box.paddingLeft;
    const innerY = absY + element.box.borderTop + element.box.paddingTop;
    const innerWidth = contentW;
    const innerHeight = contentH;

    // overflow: hidden/scroll/auto — clip the content (text, inline runs, and
    // every descendant box) to this element's content box so children that
    // overflow the parent are not painted outside it.
    // Already normalized at storage time, so no per-frame strip/lower.
    const overflowValue = element.style.overflow;
    const clipsChildren = overflowValue == "hidden" || overflowValue == "scroll" ||
        overflowValue == "auto";
    Canvas contentCanvas = canvas;
    if (clipsChildren)
        contentCanvas = canvas.clipped(Rect(innerX, innerY, contentW, contentH));

    // display:list-item — draw a small filled bullet OUTSIDE the content edge
    // (in the list's left padding/marker area) so it never sits on the text.
    if (selfVisible && element.style.display == "list-item")
    {
        auto bulletColor = parseColorOrDefault(element.style.color, Color.rgb(0, 0, 0));
        const int bulletR = 3;
        const int bulletCX = maxInt(2, innerX - 15);
        const int bulletCY = innerY + bulletR + 2;
        contentCanvas.fillCircle(Point(bulletCX, bulletCY), bulletR,
            withOpacity(bulletColor, element.style.opacity));
    }

    // Text children inline — use layout-assigned positions (absolute).
    if (selfVisible && element.tag != "img" && element.tag != "input")
    {
        foreach (child; element.children)
        {
            auto text = cast(TextNode) child;
            if (text !is null)
            {
                // Paint must shape exactly what layout collapsed for this run,
                // otherwise the markup's indentation reappears as a first-line
                // indent and the lines break differently from the measured box.
                // An inline-level element's box is the fragment it occupied, not
                // the line it sits on: re-wrapping paint's copy to that box broke
                // a link mid-URL and dropped "2026" off the article date. Inline
                // content wraps at the LINE width, i.e. its containing block's
                // content width, so use that (and never less than the run's own
                // measured width).
                const int parentWrap = element.parent !is null
                    ? max(0, element.parent.box.width) : innerWidth;
                const int runWrap = element.style.display == "inline"
                    ? max(max(innerWidth, parentWrap), text.layoutWidth) : innerWidth;
                drawTextRun(contentCanvas,
                    text.paintText.length ? text.paintText : text.data,
                    Point(text.layoutX, text.layoutY),
                    element.style, runWrap, text, textClip);
                continue;
            }
        }
    }

    // Image element (painted inside the content box). Inline <svg> markup is
    // rasterised on load and painted the same way.
    if (selfVisible && (element.tag == "img" || element.tag == "svg") &&
        contentW > 0 && contentH > 0)
    {
        auto image = cast(RgbaImage) element.image;
        const box = Rect(innerX, innerY, contentW, contentH);
        if (image !is null)
        {
            // Honor `object-fit`: "fill" stretches (the CSS default); the others
            // preserve the aspect ratio and are clipped to the content box.
            auto dst = objectFitRect(element, image, box);
            if (dst.width > 0 && dst.height > 0)
            {
                if (element.style.objectFit == "fill" ||
                    element.style.objectFit.length == 0)
                    contentCanvas.drawImage(dst, image);
                else
                    contentCanvas.clipped(box).drawImage(dst, image);
            }
        }
        else
        {
            // No image (still loading, or the fetch failed): a placeholder box
            // plus the `alt` text, which is what a browser shows meanwhile.
            contentCanvas.fillRect(box, Color.rgb(228, 228, 232));
            auto alt = "alt" in element.attrs;
            if (alt !is null && (*alt).length)
            {
                const altSize = element.style.fontSizePx > 0 ?
                    element.style.fontSizePx : 14;
                auto altLayout = shapeTextCached(*alt, altSize,
                    maxInt(1, contentW - 8), true);
                if (altLayout !is null)
                    contentCanvas.drawLayout(Point(innerX + 4, innerY + 4),
                        altLayout, Color.rgb(70, 70, 78));
            }
        }
    }

    // Form controls: paint the control's `value` inside its content box, so
    // typed text is visible (a value is not a child text node).
    if (selfVisible && (element.tag == "input" || element.tag == "textarea"))
    {
        auto value = "value" in element.attrs;
        const textSize = element.style.fontSizePx > 0 ? element.style.fontSizePx : 13;
        const textColor = parseColorOrDefault(element.style.color, Color.rgb(0, 0, 0));
        auto shown = (value !is null) ? *value : "";
        bool placeholderShown = false;
        if (shown.length == 0)
        {
            // An empty field shows its placeholder, like a browser.
            auto ph = "placeholder" in element.attrs;
            if (ph !is null && (*ph).length)
            {
                shown = *ph;
                placeholderShown = true;
            }
        }
        if (shown.length)
        {
            auto layout = shapeTextCached(shown, textSize,
                maxInt(1, contentW - 6), false);
            if (layout !is null)
                contentCanvas.drawLayout(Point(innerX + 3, innerY + 3), layout,
                    placeholderShown ? Color.rgb(150, 150, 156) : textColor);
        }
        // A focused field paints a caret at its caret offset.
        if (element.focused && !placeholderShown)
        {
            size_t at = element.caret;
            if (at > shown.length) at = shown.length;
            int caretX = innerX + 3;
            if (at > 0)
            {
                auto head = shapeTextCached(shown[0 .. at], textSize,
                    maxInt(1, contentW - 6), false);
                if (head !is null) caretX += cast(int) head.width;
            }
            const caretTop = innerY + 3;
            const caretHeight = maxInt(4, textSize);
            if (caretX >= innerX && caretX < innerX + contentW)
                contentCanvas.fillRect(Rect(caretX, caretTop, 1, caretHeight), textColor);
        }
    }

    // hr
    if (selfVisible && element.tag == "hr" && contentH > 0)
    {
        contentCanvas.drawLine(Point(innerX, innerY + contentH / 2),
            Point(innerX + contentW, innerY + contentH / 2),
            Color.rgb(120, 120, 120));
    }

    // Children, positioned elements painted last and sorted by z-index
    // (higher z-index on top).
    // Generated `::before` content paints under the element's own children and
    // `::after` above them (CSS 12 paint order).
    if (element.pseudoBefore !is null)
        paintElement(element.pseudoBefore, contentCanvas);
    if (element.style.display != "inline" &&
        element.style.display != "inline-block" &&
        element.style.display != "inline-flex")
    {
        // Common case: no positioned children — paint in document order without
        // allocating the two temporary arrays on every element every frame.
        bool anyPositioned = false;
        foreach (child; element.elements)
            if (child.style.isPositioned()) { anyPositioned = true; break; }
        if (!anyPositioned)
        {
            foreach (child; element.elements)
                paintElement(child, contentCanvas);
        }
        else
        {
            Element[] normal;
            Element[] positioned;
            foreach (child; element.elements)
            {
                if (child.style.isPositioned())
                    positioned ~= child;
                else
                    normal ~= child;
            }
            if (positioned.length > 1)
                positioned.sort!(q{ a.style.zIndex < b.style.zIndex })();
            foreach (child; normal)
                paintElement(child, contentCanvas);
            foreach (child; positioned)
                paintElement(child, contentCanvas);
        }
    }
    else
    {
        foreach (child; element.elements)
            paintElement(child, contentCanvas);
    }
    if (element.pseudoAfter !is null)
        paintElement(element.pseudoAfter, contentCanvas);

    // overflow: scroll/auto — draw a scrollbar indicator on the right edge
    // when the content is taller than the box (like WebPageView does).
    if (overflowValue == "scroll" || overflowValue == "auto")
    {
        const scrollTrack = contentH;
        if (scrollTrack > 0)
        {
            const int barW = 6;
            const int barX = innerX + max(0, contentW - barW);
            // Thumb height proportional to the fraction of content visible.
            const int thumbH = maxInt(12, scrollTrack * scrollTrack /
                maxInt(scrollTrack + 1, contentBottom(element)));
            const int thumbY = innerY;
            canvas.fillRect(Rect(barX, thumbY, barW, thumbH),
                Color.rgb(160, 170, 180));
        }
    }
}

/// The deepest bottom edge of any content inside `element` (absolute
/// coordinates). Used to decide whether a scroll/auto container overflows.
private int contentBottom(Element element)
{
    int bottom = 0;
    void walk(Element e)
    {
        bottom = maxInt(bottom, e.box.y + e.box.height);
        foreach (child; e.elements) walk(child);
    }
    walk(element);
    return bottom;
}

/// Destination rect for an `<img>` honoring `object-fit`. "fill" (the CSS
/// default) stretches into the box; the others keep the aspect ratio and are
/// centered, and the caller clips them to the content box.
private Rect objectFitRect(Element element, RgbaImage image, Rect box)
{
    const fit = element.style.objectFit;
    const iw = image.width();
    const ih = image.height();
    if (iw <= 0 || ih <= 0) return box;
    if (fit.length == 0 || fit == "fill") return box;

    const double sx = cast(double) box.width / iw;
    const double sy = cast(double) box.height / ih;
    double s;
    if (fit == "contain") s = (sx < sy) ? sx : sy;
    else if (fit == "cover") s = (sx > sy) ? sx : sy;
    else if (fit == "none") s = 1.0;
    else if (fit == "scale-down")
    {
        const double t = (sx < sy) ? sx : sy;
        s = (t > 1.0) ? 1.0 : t;
    }
    else s = (sx < sy) ? sx : sy;   // unknown keyword behaves like `contain`

    const w = maxInt(1, cast(int) (iw * s + 0.5));
    const h = maxInt(1, cast(int) (ih * s + 0.5));
    // `object-position` (CSS Images 3) decides where the fitted image sits: 0%
    // aligns the leading edges, 50% (the initial value) centres, 100% the
    // trailing edges. 0.5 reproduces the old centring exactly.
    const double pctX = positionFraction(element.style.objectPosition, true);
    const double pctY = positionFraction(element.style.objectPosition, false);
    return Rect(box.x + cast(int) ((box.width - w) * pctX),
        box.y + cast(int) ((box.height - h) * pctY), w, h);
}

unittest
{
    // A focused empty field paints a caret at its content origin; an empty
    // field with a `placeholder` paints that text in a muted colour.
    auto field = new Element("input");
    field.box.x = 0;
    field.box.y = 0;
    field.box.width = 100;
    field.box.height = 20;
    field.style.fontSizePx = 13;
    field.style.color = "#000000";
    field.attrs["value"] = "";
    field.focused = true;
    field.caret = 0;

    import aurora.surface : Surface;
    auto s1 = new Surface(100, 20);
    s1.clear(Color.rgb(255, 255, 255));
    paintElement(field, Canvas(s1));
    bool dark = false;
    foreach (y; 4 .. 18)
        if (((s1.pixel(3, y) >> 16) & 0xff) < 128) dark = true;
    assert(dark, "a focused empty field must paint a caret at the content origin");

    field.focused = false;
    field.attrs["placeholder"] = "Name";
    auto s2 = new Surface(100, 20);
    s2.clear(Color.rgb(255, 255, 255));
    paintElement(field, Canvas(s2));
    bool text = false;
    foreach (x; 0 .. 100)
        foreach (y; 0 .. 20)
            if (((s2.pixel(x, y) >> 16) & 0xff) < 200) text = true;
    assert(text, "an empty field must paint its placeholder text");
}

unittest
{
    // object-fit: `fill` stretches; `contain`/`cover` preserve the aspect
    // ratio (and center); `none` keeps the intrinsic size; `scale-down` never
    // upscales.
    ubyte[4 * 2 * 4] px;
    auto img = new RgbaImage(4, 2, px);
    auto el = new Element("img");
    const box = Rect(0, 0, 20, 20);

    el.style.objectFit = "fill";
    auto r = objectFitRect(el, img, box);
    assert(r.width == 20 && r.height == 20, "fill must stretch into the box");

    el.style.objectFit = "contain";
    r = objectFitRect(el, img, box);
    assert(r.width == 20 && r.height == 10, "contain must fit inside the box");
    assert(r.y == 5, "contain must center vertically");

    el.style.objectFit = "cover";
    r = objectFitRect(el, img, box);
    assert(r.width == 40 && r.height == 20, "cover must cover the box");
    assert(r.x == -10, "cover must center horizontally");

    el.style.objectFit = "none";
    r = objectFitRect(el, img, box);
    assert(r.width == 4 && r.height == 2, "none must keep the intrinsic size");

    el.style.objectFit = "scale-down";
    r = objectFitRect(el, img, box);
    assert(r.width == 4 && r.height == 2, "scale-down must not upscale");
}

/// Compute the destination rect for a CSS background-image honoring
/// `background-size`: cover, contain, an explicit pixel pair, a single
/// pixel length (height keeps aspect ratio), or auto (intrinsic size).
private Rect backgroundDestRect(Element element, RgbaImage image)
{
    const boxX = element.box.x;
    const boxY = element.box.y;
    // `box.width/height` is the content box; size-position the background image
    // against the padding/border box, which is what the background covers.
    const boxW = element.box.width + element.box.paddingLeft + element.box.paddingRight +
        element.box.borderLeft + element.box.borderRight;
    const boxH = element.box.height + element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;
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

    // Center the image within the box. (`object-position` applies to replaced
    // content in `objectFitRect`, not to background images.)
    // `background-position` (CSS Backgrounds 3): its initial value is the top
    // left corner, so the default fraction for a background is 0, not 0.5.
    const double pctX = positionFraction(element.style.backgroundPosition, true, 0.0);
    const double pctY = positionFraction(element.style.backgroundPosition, false, 0.0);
    int x = boxX + cast(int) ((boxW - w) * pctX);
    int y = boxY + cast(int) ((boxH - h) * pctY);
    return Rect(x, y, w, h);
}

/// The 0..1 fraction for one axis of a position (`object-position`,
/// `background-position`). Keywords (`left`, `center`, `right`, `top`,
/// `bottom`) and percentages are honoured; anything else falls back to `dflt`,
/// which is the property's own initial value (0.5 centred, 0 top/left).
private double positionFraction(string value, bool horizontal, double dflt = 0.5)
{
    import std.string : endsWith;

    auto parts = value.split();
    if (parts.length == 0) return dflt;
    auto token = parts[0];
    if (!horizontal && parts.length >= 2)
        token = parts[1];
    const tok = token.strip().toLower();
    if (tok == "left" || tok == "top") return 0.0;
    if (tok == "right" || tok == "bottom") return 1.0;
    if (tok == "center") return 0.5;
    if (endsWith(tok, "%"))
    {
        try return to!double(tok[0 .. $ - 1]) / 100.0;
        catch (Exception) return dflt;
    }
    return dflt;
}

/// Draw a text run using Aurora's TextLayout, wrapped at the given width.
/// Uses the SAME shaping call as layout (`textEngine.layout` with an explicit
/// pixelSize) so paint and layout agree; `canvas.layoutText` takes a
/// typographic *scale* (2 = body ~17px), not a pixel size.
private void drawTextRun(Canvas canvas, string text, Point origin,
    ComputedStyle style, int maxWidth, TextNode node, bool useBackgroundColor = false)
{
    if (text.length == 0) return;

    // Parse font size from style.
    auto pixelSize = style.fontSizePx > 0 ? style.fontSizePx : 16;

    // Wrapping width is the content width that layout stored, which is the
    // measured text width truncated to int. Re-wrap with one extra pixel so a
    // run whose measured width rounds down does not drop its final glyph onto
    // a second line (which scattered inline <b>/<i>/<a> runs across lines).
    // `white-space: nowrap`/`pre` never wrap: paint the run on one line even if
    // it overflows its (narrow) box, matching the layout measure.
    const bool noWrap = style.whiteSpace == "nowrap" || style.whiteSpace == "pre";
    const int wrapW = (maxWidth > 0 && !noWrap) ? maxWidth + 1 : 0;
    // Memoized: the layout pass already shaped this exact run.
    auto layout = shapeTextCached(text, pixelSize, wrapW, wrapW > 0,
        style.letterSpacingPx());
    auto color = parseColorOrDefault(style.color, Color.rgb(0, 0, 0));
    // `background-clip: text` gradient text: the glyphs take the background
    // color (the gradient's fallback) rather than the (transparent) text color.
    if (useBackgroundColor)
    {
        auto bc = parseColor(style.background);
        if (bc.present) color = bc.color;
    }
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
/// The colour token inside a `border` / `border-<side>` shorthand (`1px solid
/// red` -> `red`), or "" when the shorthand declares no colour.
private static string borderColorToken(string value)
{
    foreach (token; value.split())
        if (looksLikeColorToken(token)) return token;
    return "";
}

/// True when a border shorthand token is a colour rather than a width or a
/// border-style keyword.
private static bool looksLikeColorToken(string token)
{
    if (token.length == 0) return false;
    foreach (unit; ["px", "em", "rem", "%", "vh", "vw"])
        if (token.length > unit.length && token[$ - unit.length .. $] == unit)
            return false;
    switch (token)
    {
        case "none": case "hidden": case "solid": case "dashed": case "dotted":
        case "double": case "groove": case "ridge": case "inset": case "outset":
            return false;
        default:
            return true;
    }
}

/// One side out of a 1-4 value colour shorthand (`border-color: a b c d`).
/// The width of an `outline` / `outline-width` value, in px (0 when there is
/// none). `auto` — the browser focus ring — is treated as a thin 2px ring.
private static int outlineWidthPx(string value)
{
    import auroraweb.dom : cssInt;
    foreach (token; value.split())
    {
        auto t = token.strip();
        if (t.length >= 2 && t[$ - 2 .. $] == "px") return max(0, cssInt(t[0 .. $ - 2].strip()));
        if (t == "auto") return 2;
        if (t == "thin") return 1;
        if (t == "medium") return 3;
        if (t == "thick") return 5;
    }
    return 0;
}

private static string sideToken(string value, int sideIndex)
{
    auto parts = value.split();
    switch (parts.length)
    {
        case 0: return "";
        case 1: return parts[0];
        case 2: return (sideIndex % 2 == 0) ? parts[0] : parts[1];
        case 3:
            return (sideIndex == 0) ? parts[0] : ((sideIndex == 2) ? parts[2] : parts[1]);
        default: return parts[sideIndex];
    }
}

/// and four-value syntaxes (`Npx Npx Npx Npx` = top-left top-right bottom-right
/// bottom-left) are parsed; the largest corner radius drives the paint pass.
private int roundedRadius(Element element, int width, int height)
{
    return cornerRadii(element, width, height).maxR();
}

/// The per-corner border-radius for an element's current box size. An
/// elliptical value (`10px / 20px`) uses its first group; each corner is
/// clamped to half the box, as browsers do.
private CornerRadii cornerRadii(Element element, int width, int height)
{
    import auroraweb.dom : cssInt;
    const s = element.style.borderRadius.strip();
    if (s.length == 0 || s == "0") return CornerRadii();
    // The token parse depends only on the string; memoize it and apply the
    // percentage against the current box size.
    RadiusTok[] toks;
    if (auto hit = s in _radiusCache) toks = *hit;
    else
    {
        foreach (part; s.split())
        {
            auto t = part.strip();
            if (t == "/") break; // elliptical: the first group is enough
            if (t.length >= 2 && t[$ - 2 .. $] == "px")
                toks ~= RadiusTok(cssInt(t[0 .. $ - 2].strip()), false);
            else if (t.length >= 1 && t[$ - 1] == '%')
                toks ~= RadiusTok(cssInt(t[0 .. $ - 1].strip()), true);
            else
                toks ~= RadiusTok(cssInt(t), false);
        }
        if (_radiusCache.length >= MaxPaintCache) _radiusCache = null;
        _radiusCache[s] = toks;
    }
    int[] values;
    foreach (t; toks)
        values ~= (t.percent ? (min(width, height) * t.value) / 100 : t.value);
    CornerRadii r;
    switch (values.length)
    {
        case 0: break;
        case 1: r.tl = r.tr = r.br = r.bl = values[0]; break;
        case 2: r.tl = r.br = values[0]; r.tr = r.bl = values[1]; break;
        case 3: r.tl = values[0]; r.tr = r.bl = values[1]; r.br = values[2]; break;
        default: r.tl = values[0]; r.tr = values[1]; r.br = values[2]; r.bl = values[3]; break;
    }
    const limit = min(width, height) / 2;
    if (limit > 0)
    {
        r.tl = min(r.tl, limit);
        r.tr = min(r.tr, limit);
        r.br = min(r.br, limit);
        r.bl = min(r.bl, limit);
    }
    return r;
}

/// A border-radius resolved per corner (CSS order: top-left, top-right,
/// True when two colours are identical in every channel.
private static bool sameColor(Color a, Color b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

/// bottom-right, bottom-left).
private struct CornerRadii
{
    int tl;
    int tr;
    int br;
    int bl;

    int maxR() const { return max(max(tl, tr), max(br, bl)); }
    bool uniform() const { return tl == tr && tr == br && br == bl; }
}

/// Fill a box honouring per-corner radii. A uniform radius uses the canvas's
/// single-radius primitive; otherwise the box is composed from a middle cross
/// of square rects plus one rounded square per corner, each sized so only its
/// rounded quadrant lands inside the box.
private static void fillRoundedBox(Canvas canvas, int x, int y, int w, int h,
    CornerRadii r, Color color)
{
    if (r.maxR() <= 0)
    {
        canvas.fillRect(Rect(x, y, w, h), color);
        return;
    }
    if (r.uniform())
    {
        canvas.fillRoundedRect(Rect(x, y, w, h), r.maxR(), color);
        return;
    }
    canvas.fillRect(Rect(x + max(r.tl, r.bl), y,
        w - max(r.tl, r.bl) - max(r.tr, r.br), h), color);
    canvas.fillRect(Rect(x, y + max(r.tl, r.tr), w,
        h - max(r.tl, r.tr) - max(r.br, r.bl)), color);
    void corner(int cx, int cy, int radius)
    {
        if (radius <= 0) return;
        canvas.fillRoundedRect(Rect(cx, cy, 2 * radius, 2 * radius), radius, color);
    }
    corner(x, y, r.tl);
    corner(x + w - 2 * r.tr, y, r.tr);
    corner(x + w - 2 * r.br, y + h - 2 * r.br, r.br);
    corner(x, y + h - 2 * r.bl, r.bl);
}

/// One parsed `border-radius` token (px value, or a percentage flag).
private struct RadiusTok { int value; bool percent; }
private RadiusTok[][string] _radiusCache;

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
    // A spread grows (or, when negative, shrinks) the shadow on every side.
    const spread = element.style.boxShadowSpread.length
        ? element.style.pxLength(element.style.boxShadowSpread) : 0;
    if (width <= 0 || height <= 0) return;

    auto color = parseColorOrDefault(shadow, Color.rgba(0, 0, 0, 76));
    const sx = absX + offX - spread;
    const sy = absY + offY - spread;
    const sw = max(1, width + 2 * spread);
    const sh = max(1, height + 2 * spread);
    auto radii = cornerRadii(element, sw, sh);
    if (spread > 0)
    {
        // A positive spread grows the corner radii along with the box.
        radii.tl += spread;
        radii.tr += spread;
        radii.br += spread;
        radii.bl += spread;
    }
    // 3-rect blur approximation: a soft core with two fainter outer rims.
    if (blur > 0)
    {
        const core = withOpacity(color, 0.5);
        const mid = withOpacity(color, 0.25);
        const outer = withOpacity(color, 0.12);
        fillRoundedBox(canvas, sx, sy, sw, sh, radii, outer);
        fillRoundedBox(canvas, sx, sy, sw, sh, radii, mid);
        fillRoundedBox(canvas, sx, sy, sw, sh, radii, core);
    }
    else
    {
        fillRoundedBox(canvas, sx, sy, sw, sh, radii, color);
    }
}

struct NullableColor
{
    Color color;
    bool present;
}

private NullableColor parseColor(string value)
{
    if (value.length == 0 || value == "transparent") return NullableColor.init;
    // Memoized: paint parses the same style strings (background, border, color,
    // shadow) for every element on every frame.
    if (auto hit = value in _colorCache) return *hit;
    auto result = parseColorUncached(value);
    if (_colorCache.length >= MaxPaintCache) _colorCache = null;
    _colorCache[value] = result;
    return result;
}

/// Parsed-color cache keyed by the raw CSS string. Bounded; cleared when full.
private NullableColor[string] _colorCache;
private enum size_t MaxPaintCache = 4096;

private NullableColor parseColorUncached(string value)
{
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
        // Centred explicitly: the initial `background-position` is the top-left
        // corner (CSS Backgrounds 3), so a centre has to be asked for.
        element.style.backgroundPosition = "center";
        // CSS tiles by default; this case checks the single-image placement.
        element.style.backgroundRepeat = "no-repeat";
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
        // background-size:auto and background-position:center the 4x4 image is
        // drawn at intrinsic size in the middle: rect (28,28)-(32,32).
        auto p = surface.pixel(30, 30);
        assert((p & 0xff) == 0, "blue channel should be 0 (red image), got " ~ (p & 0xff).to!string);
        assert(((p >> 16) & 0xff) >= 250, "red channel should be ~255, got " ~ ((p >> 16) & 0xff).to!string);
        // The image was drawn over the blue solid background.
        auto corner = surface.pixel(12, 12);
        assert((corner & 0xff) >= 250, "blue background should show at the corner, got " ~ (corner & 0xff).to!string);
    }

    // CSS transform: translate shifts an element's painting.
    {
        auto tel = new Element("div");
        tel.style.display = "block";
        tel.style.background = "rgb(255, 0, 0)";
        tel.style.transform = "translate(6px, 0)";
        tel.box.x = 10;
        tel.box.y = 10;
        tel.box.width = 4;
        tel.box.height = 4;
        auto tsurf = new Surface(40, 40);
        tsurf.clear(Color.rgb(255, 255, 255));
        auto tcan = Canvas(tsurf);
        paintElement(tel, tcan);
        auto moved = tsurf.pixel(16, 12);
        // Packed ARGB: red has green 0, white has green 255, so green is what
        // separates them here.
        assert(((moved >> 8) & 0xff) < 50,
            "a translated element must paint 6px right (red at 16,12), got " ~
            to!string(moved));
        auto unmoved = tsurf.pixel(10, 12);
        assert(((unmoved >> 8) & 0xff) >= 200,
            "the untranslated position must stay unpainted, got " ~
            to!string(unmoved));
    }

    // background-repeat defaults to tiling: a 2x2 image repeats across the box.
    {
        ubyte[4 * 2 * 2] tex;
        foreach (i, ref b; tex) b = 0;
        // One opaque red pixel at the tile's top-left; the rest transparent.
        tex[0] = 255;
        tex[1] = 0;
        tex[2] = 0;
        tex[3] = 255;
        auto tileImg = new RgbaImage(2, 2, tex);
        auto el2 = new Element("div");
        el2.style.display = "block";
        el2.style.background = "rgb(0, 0, 255)";
        el2.backgroundImage = tileImg;
        el2.box.x = 0;
        el2.box.y = 0;
        el2.box.width = 6;
        el2.box.height = 6;
        auto surf2 = new Surface(8, 8);
        surf2.clear(Color.rgb(0, 0, 0));
        auto canvas2 = Canvas(surf2);
        paintElement(el2, canvas2);
        // The tile step is 2px, so the red pixel lands at every even offset.
        foreach (py; 0 .. 3)
        {
            foreach (px; 0 .. 3)
            {
                auto q = surf2.pixel(px * 2, py * 2);
                assert(((q >> 16) & 0xff) >= 200,
                    "the default repeat must tile the image; offset (" ~
                    to!string(px * 2) ~ "," ~ to!string(py * 2) ~ ") = " ~ to!string(q));
            }
        }
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

    // --- filter: grayscale drains the colour of the whole subtree ---
    {
        import aurora.surface : Surface;

        auto elF = new Element("div");
        elF.style.display = "block";
        elF.style.background = "#ff0000";
        elF.style.filter = "grayscale(1)";
        elF.box.x = 0;
        elF.box.y = 0;
        elF.box.width = 20;
        elF.box.height = 20;

        auto sF = new Surface(20, 20);
        sF.clear(Color.rgb(255, 255, 255));
        paintElement(elF, Canvas(sF));
        const uint pxF = sF.pixel(10, 10);
        const uint rF = (pxF >> 16) & 0xff;
        const uint gF = (pxF >> 8) & 0xff;
        const uint bF = pxF & 0xff;
        assert(gF > 40 && gF < 200 && rF == gF && gF == bF,
            "grayscale must leave a neutral grey, got r=" ~ to!string(rF) ~
            " g=" ~ to!string(gF) ~ " b=" ~ to!string(bF));
        assert(((pxF >> 24) & 0xff) == 255,
            "grayscale must not change the alpha");
    }

    // --- position: sticky pins the box while the page scrolls ---
    {
        import aurora.surface : Surface;

        auto docK = new Element("body");
        docK.style.display = "block";
        docK.box.x = 0;
        docK.box.y = 0;
        docK.box.width = 200;
        docK.box.height = 600;

        auto bar = new Element("div");
        bar.style.display = "block";
        bar.style.position = "relative";
        bar.style.isSticky = true;
        bar.style.background = "#ff0000";
        bar.box.x = 0;
        bar.box.y = 50;
        bar.box.width = 200;
        bar.box.height = 30;
        bar.parent = docK;
        docK.children ~= bar;
        docK.elements ~= bar;

        auto s0 = new Surface(200, 600);
        s0.clear(Color.rgb(255, 255, 255));
        paintTree(docK, Canvas(s0), 0);
        assert(((s0.pixel(100, 60) >> 16) & 0xff) > 200,
            "at scrollY 0 a sticky box paints at its flow position");

        auto s1 = new Surface(200, 600);
        s1.clear(Color.rgb(255, 255, 255));
        paintTree(docK, Canvas(s1), 120);
        assert(((s1.pixel(100, 125) >> 16) & 0xff) > 200,
            "at scrollY 120 a sticky box must be pinned near the viewport top");
        assert(bar.box.y == 50,
            "sticky is applied at paint time and must not move the box, got y=" ~
            to!string(bar.box.y));
    }

    // --- a radial-gradient mask is honoured too ---
    {
        import aurora.surface : Surface;

        auto elR = new Element("div");
        elR.style.display = "block";
        elR.style.background = "#ffffff";
        elR.style.maskImage =
            "radial-gradient(circle at 50% 50%, rgba(0,0,0,1), rgba(0,0,0,0))";
        elR.box.x = 0;
        elR.box.y = 0;
        elR.box.width = 40;
        elR.box.height = 40;

        auto sr = new Surface(40, 40);
        sr.clear(Color(0, 0, 0, 0));
        paintElement(elR, Canvas(sr));

        const uint centrePx = sr.pixel(20, 20);
        const uint cornerPx = sr.pixel(0, 1);
        assert(((centrePx >> 24) & 0xff) > 150,
            "a radial mask must leave its centre painted; alpha " ~
            to!string((centrePx >> 24) & 0xff));
        assert(((cornerPx >> 24) & 0xff) < 60,
            "a radial mask must fade the corner; alpha " ~
            to!string((cornerPx >> 24) & 0xff));
    }

    // --- a wrapping inline box paints its background on every line fragment ---
    {
        import aurora.surface : Surface;
        import auroraweb.css : parseStylesheet;
        import auroraweb.layout : applyStylesAndLayout;

        auto rulesW = parseStylesheet(`
            body { margin: 0; width: 60px; }
            .wrapLinkA { background: #ff0000; }
        `, 60, 200);
        auto docW = new Element("body");
        auto link = new Element("span");
        link.attrs["class"] = "wrapLinkA";
        docW.children ~= link;
        docW.elements ~= link;
        link.parent = docW;
        auto wrapped = new TextNode(link,
            "alpha beta gamma delta epsilon zeta eta theta iota kappa");
        wrapped.parent = link;
        link.children ~= wrapped;
        applyStylesAndLayout(docW, rulesW, 60, 200);

        assert(link.inlineFragments.length >= 2,
            "a wrapping inline box must be fragmented per line, got " ~
            to!string(link.inlineFragments.length));

        auto wrapSurface = new Surface(60, 200);
        wrapSurface.clear(Color.rgb(255, 255, 255));
        paintElement(docW, Canvas(wrapSurface));
        foreach (i, frag; link.inlineFragments)
        {
            // A single sample could land on a glyph, so scan the fragment's own
            // band for the background colour.
            bool painted = false;
            foreach (dx; 0 .. frag.width)
                foreach (dy; 0 .. min(frag.height, 4))
                {
                    const int sx = frag.x + dx;
                    const int sy = frag.y + dy;
                    if (sx < 0 || sy < 0 || sx >= 60 || sy >= 200) continue;
                    const uint px = wrapSurface.pixel(sx, sy);
                    if (((px >> 16) & 0xff) > 200 && ((px >> 8) & 0xff) < 60)
                    {
                        painted = true;
                        break;
                    }
                }
            assert(painted,
                "fragment " ~ to!string(i) ~ " at (" ~ to!string(frag.x) ~ "," ~
                to!string(frag.y) ~ " " ~ to!string(frag.width) ~ "x" ~
                to!string(frag.height) ~ ") must carry the inline background");
        }
    }

    // --- object-position moves the fitted image inside its box ---
    {
        ubyte[4 * 2 * 4] px2;
        auto img2 = new RgbaImage(4, 2, px2);
        auto el2 = new Element("img");
        const box2 = Rect(0, 0, 20, 20);

        el2.style.objectFit = "contain";
        el2.style.objectPosition = "50% 50%";
        auto centred = objectFitRect(el2, img2, box2);
        assert(centred.y == 5, "the initial object-position centres, got y=" ~
            to!string(centred.y));

        el2.style.objectPosition = "0% 0%";
        auto topLeft = objectFitRect(el2, img2, box2);
        assert(topLeft.x == 0 && topLeft.y == 0,
            "object-position:0% 0% must align both leading edges; value='" ~
            el2.style.objectPosition ~ "' box=" ~ to!string(box2.width) ~ "x" ~
            to!string(box2.height) ~ " fitted=" ~ to!string(topLeft.width) ~ "x" ~
            to!string(topLeft.height) ~ " fracX=" ~
            to!string(positionFraction(el2.style.objectPosition, true)) ~
            " fracY=" ~
            to!string(positionFraction(el2.style.objectPosition, false)) ~
            " got=(" ~ to!string(topLeft.x) ~ "," ~ to!string(topLeft.y) ~ ")");

        // A background's default position is the top-left corner (CSS Backgrounds
        // 3), not the centre that replaced content uses.
        ubyte[4 * 2 * 4] pxB;
        auto imgB = new RgbaImage(4, 2, pxB);
        auto elB = new Element("div");
        elB.box.x = 0;
        elB.box.y = 0;
        elB.box.width = 20;
        elB.box.height = 20;
        elB.style.backgroundSize = "contain";
        auto bgDefault = backgroundDestRect(elB, imgB);
        assert(bgDefault.y == 0 && bgDefault.height == 10,
            "background-position defaults to the top-left corner, got (" ~
            to!string(bgDefault.x) ~ "," ~ to!string(bgDefault.y) ~ ") " ~
            to!string(bgDefault.width) ~ "x" ~ to!string(bgDefault.height));
        elB.style.backgroundPosition = "center bottom";
        auto bgBottom = backgroundDestRect(elB, imgB);
        assert(bgBottom.y == 10,
            "background-position:center bottom must sit at the bottom, got y=" ~
            to!string(bgBottom.y));
    }

    // --- mask-image multiplies the painted layer's alpha ---
    {
        import aurora.surface : Surface;
        import std.conv : to;

        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#ffffff";
        el.style.maskImage = "linear-gradient(180deg, rgba(0,0,0,1), rgba(0,0,0,0))";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 20;
        el.box.height = 20;

        auto surf = new Surface(20, 20);
        surf.clear(Color(0, 0, 0, 0));
        paintElement(el, Canvas(surf));

        const uint top = surf.pixel(10, 1);
        const uint bottom = surf.pixel(10, 18);
        assert(((top >> 24) & 0xff) > 200,
            "a fading mask must leave the start of the layer painted; alpha " ~
            to!string((top >> 24) & 0xff));
        assert(((bottom >> 24) & 0xff) < 40,
            "the faded end of a mask must be nearly transparent; alpha " ~
            to!string((bottom >> 24) & 0xff));
    }

    // --- a wrapped text run paints every line from the block's left edge ---
    {
        auto el = new Element("p");
        el.style.display = "block";
        el.style.fontSize = "16px";
        el.style.color = "#000000";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 160;
        el.box.height = 90;
        el.box.paddingTop = 0;
        el.box.paddingLeft = 0;

        auto tn = new TextNode(el,
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu");
        tn.layoutX = 0;
        tn.layoutY = 0;
        tn.layoutWidth = 160;
        el.children ~= tn;

        auto surface = new Surface(220, 100);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(el, canvas);

        // Group contiguous rows that have ink into line bands: a single row can
        // legitimately contain only ascenders or descenders, so the start of a
        // LINE is the leftmost ink anywhere in its band. A wrapped line painted
        // from a runaway origin would leave its whole band starting far right.
        int paintedRows = 0;
        int bandMin = -1;
        foreach (y; 0 .. 90)
        {
            int firstInk = -1;
            foreach (x; 0 .. 220)
            {
                auto p = surface.pixel(x, y);
                auto lum = (p & 0xff) + ((p >> 8) & 0xff) + ((p >> 16) & 0xff);
                if (lum < 600) { firstInk = x; break; }
            }
            if (firstInk < 0)
            {
                if (bandMin >= 0)
                {
                    assert(bandMin <= 8,
                        "a wrapped line must start at the block's left edge, but " ~
                        "a line begins at x=" ~ to!string(bandMin));
                    bandMin = -1;
                }
                continue;
            }
            paintedRows++;
            bandMin = bandMin < 0 ? firstInk : (firstInk < bandMin ? firstInk : bandMin);
        }
        if (bandMin >= 0)
            assert(bandMin <= 8,
                "a wrapped line must start at the block's left edge, but the " ~
                "last line begins at x=" ~ to!string(bandMin));
        assert(paintedRows > 0, "the text run must paint something");
    }

    // Per-side border colours: the colour inside a `border-<side>` shorthand
    // must be used instead of the default black.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.borderBottomWidth = "2px solid #00ff00"; // what `border-bottom:` stores
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 20;
        el.box.height = 20;
        el.box.borderBottom = 2;

        // `box.height` is the content box, so the border box is 22px tall and
        // the bottom border occupies rows 20..21.
        auto surface = new Surface(24, 24);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto px = surface.pixel(10, 20);
        const r = (px >> 16) & 0xff;
        const g = (px >> 8) & 0xff;
        const bl = px & 0xff;
        assert(g >= 200 && r <= 60 && bl <= 60,
            "the border-bottom shorthand colour must paint that edge, not black");
    }

    // An explicit `border-<side>-color` colours just that side.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.borderLeftColor = "#0000ff";
        el.style.borderLeftWidth = "3px";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 20;
        el.box.height = 20;
        el.box.borderLeft = 3;

        auto surface = new Surface(20, 20);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto px = surface.pixel(1, 10);
        const r = (px >> 16) & 0xff;
        const bl = px & 0xff;
        assert(bl >= 200 && r <= 60, "border-left-color must colour that side");
    }

    // Per-corner radii: `12px 0 0 0` rounds only the top-left corner.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#ff0000";
        el.style.borderRadius = "12px 0 0 0";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 40;
        el.box.height = 40;

        auto surface = new Surface(40, 40);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto center = surface.pixel(20, 20);
        auto tl = surface.pixel(1, 1);
        auto tr = surface.pixel(38, 1);
        assert(((center >> 16) & 0xff) >= 250, "the box body must be painted");
        // `Surface.pixel` returns packed ARGB, so compare the colour channels.
        assert((tl & 0xffffff) == 0xffffff,
            "a 12px top-left radius must round that corner away");
        assert(((tr >> 16) & 0xff) >= 250,
            "the top-right corner must stay square when its radius is 0");
    }

    // Outline: painted outside the border box, so it takes no layout space.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.outline = "2px solid #ff0000";
        el.box.x = 4;
        el.box.y = 4;
        el.box.width = 10;
        el.box.height = 10;

        auto surface = new Surface(20, 20);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto ring = surface.pixel(2, 9);    // 2px above the box's top edge
        auto inside = surface.pixel(9, 9);  // inside the box
        const rr = (ring >> 16) & 0xff;
        const rg = (ring >> 8) & 0xff;
        assert(rr >= 200 && rg <= 60, "the outline must paint outside the border box");
        assert((inside & 0xffffff) == 0xffffff, "the outline must not fill the box interior");
    }

    // box-shadow: a negative offset still paints, on the other side.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#0000ff";
        el.style.boxShadowH = "-4px";
        el.style.boxShadowV = "0px";
        el.style.boxShadowBlur = "0px";
        el.style.boxShadowColor = "#ff0000";
        el.box.x = 8;
        el.box.y = 8;
        el.box.width = 10;
        el.box.height = 10;

        auto surface = new Surface(28, 28);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto left = surface.pixel(6, 13);
        auto inside = surface.pixel(13, 13);
        assert(((left >> 16) & 0xff) >= 200 && ((left >> 8) & 0xff) <= 60,
            "a negative shadow offset must paint the shadow on that side");
        assert(((inside >> 16) & 0xff) <= 60 && (inside & 0xff) >= 200,
            "the element's background must cover the shadow inside the box");
    }

    // box-shadow: the spread extends the shadow past the box on every side.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#0000ff";
        el.style.boxShadowH = "0px";
        el.style.boxShadowV = "0px";
        el.style.boxShadowBlur = "0px";
        el.style.boxShadowSpread = "5px";
        el.style.boxShadowColor = "#ff0000";
        el.box.x = 8;
        el.box.y = 8;
        el.box.width = 10;
        el.box.height = 10;

        auto surface = new Surface(28, 28);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto ring = surface.pixel(5, 13);
        auto inside = surface.pixel(13, 13);
        assert(((ring >> 16) & 0xff) >= 200 && ((ring >> 8) & 0xff) <= 60,
            "the spread must extend the shadow past the box edge");
        assert((inside & 0xff) >= 200, "the background must still cover the box interior");
    }

    // visibility:hidden hides the box and its whole subtree.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.visibility = "hidden";
        parent.style.background = "#ff0000";
        parent.box.x = 0;
        parent.box.y = 0;
        parent.box.width = 20;
        parent.box.height = 20;

        auto child = new Element("div");
        child.style.display = "block";
        child.style.background = "#00ff00";
        child.box.x = 0;
        child.box.y = 0;
        child.box.width = 10;
        child.box.height = 10;
        child.parent = parent;
        parent.children ~= child;
        parent.elements ~= child;

        auto surface = new Surface(20, 20);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(parent, Canvas(surface));

        assert((surface.pixel(15, 15) & 0xffffff) == 0xffffff,
            "a hidden box must not paint its background");
        assert((surface.pixel(5, 5) & 0xffffff) == 0xffffff,
            "a hidden box's children must not paint");
    }

    // A rounded border must not leave square corners.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.background = "#0000ff";
        el.style.borderTopWidth = "3px solid #ff0000";
        el.style.borderRightWidth = "3px solid #ff0000";
        el.style.borderBottomWidth = "3px solid #ff0000";
        el.style.borderLeftWidth = "3px solid #ff0000";
        el.style.borderRadius = "6px";
        el.box.x = 0;
        el.box.y = 0;
        el.box.width = 30;
        el.box.height = 30;
        el.box.borderTop = 3;
        el.box.borderRight = 3;
        el.box.borderBottom = 3;
        el.box.borderLeft = 3;

        auto surface = new Surface(30, 30);
        surface.clear(Color.rgb(255, 255, 255));
        paintElement(el, Canvas(surface));

        auto corner = surface.pixel(0, 0);
        auto edge = surface.pixel(15, 1);
        auto inside = surface.pixel(15, 15);
        assert((corner & 0xffffff) == 0xffffff,
            "a rounded border must not leave a square corner");
        assert(((edge >> 16) & 0xff) >= 200 && ((edge >> 8) & 0xff) <= 60,
            "the straight border run must still be painted");
        assert(((inside >> 16) & 0xff) <= 60 && (inside & 0xff) >= 200,
            "the padding box must keep its background inside a rounded border");
    }



    // A display:list-item element paints a filled bullet inside its content
    // edge: the bullet area must be non-white (dark) after painting.
    {
        auto li = new Element("li");
        li.style.display = "list-item";
        li.style.color = "black";
        li.box.x = 30;
        li.box.y = 10;
        li.box.width = 100;
        li.box.height = 20;
        li.box.paddingLeft = 6;
        li.box.paddingTop = 4;

        auto surface = new Surface(60, 40);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(li, canvas);

        // Marker sits outside the content edge: innerX=36, innerY=14, r=3 ->
        // center at (36-15, 19) = (21, 19).
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

    // --- SVG: the engine's own rasteriser must paint the right pixels ---
    // An 8x8 solid green rectangle decoded from SVG must come out green.
    {
        import auroraweb.svg : looksLikeSvg, decodeSvg;
        auto svgSrc = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'>" ~
            "<rect width='8' height='8' fill='#00ff00'/></svg>";
        assert(looksLikeSvg(cast(const(ubyte)[]) svgSrc), "SVG must be detected");
        auto svgImg = decodeSvg(cast(const(ubyte)[]) svgSrc);
        assert(svgImg !is null, "the SVG must rasterise");

        auto svgEl = new Element("div");
        svgEl.style.display = "block";
        // White behind the image, so a drawn image is unambiguous, and an
        // explicit size so the image is actually scaled into the box.
        svgEl.style.background = "#ffffff";
        svgEl.style.backgroundSize = "auto";
        svgEl.backgroundImage = svgImg;
        svgEl.box.x = 0;
        svgEl.box.y = 0;
        svgEl.box.width = 8;
        svgEl.box.height = 8;
        auto svgSurface = new Surface(8, 8);
        paintElement(svgEl, Canvas(svgSurface));
        auto svgPx = svgSurface.pixel(4, 4);
        // Surface pixels are packed ARGB, so green is bits 8..15.
        assert(((svgPx >> 8) & 0xff) >= 200 && ((svgPx >> 16) & 0xff) <= 60,
            "an SVG fill must paint green; got " ~ svgPx.to!string);
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

unittest
{
    import aurora.surface : Surface;
    import std.conv : to;

    // --- overflow:hidden clips children to the parent's content box ---
    // The parent is 40x40 at (0,0). Its child overflows to the bottom-right
    // (down to 100,100). With overflow:hidden the overflow area must stay
    // white (not painted).
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.overflow = "hidden";
        parent.style.background = "#00ff00";
        parent.box.x = 0; parent.box.y = 0;
        parent.box.width = 40; parent.box.height = 40;
        parent.box.paddingLeft = 0; parent.box.paddingTop = 0;

        auto child = new Element("div");
        child.style.display = "block";
        child.style.background = "#ff0000";
        child.box.x = 0; child.box.y = 0;
        child.box.width = 100; child.box.height = 100;

        child.parent = parent;
        parent.children ~= child;
        parent.elements ~= child;

        auto surface = new Surface(120, 120);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(parent, canvas);

        // Inside the parent box the child (red, covering the green parent
        // background from 0,0) paints.
        auto childArea = surface.pixel(20, 20);
        assert(((childArea >> 16) & 0xff) >= 250,
            "child red must paint inside the clip, got " ~ childArea.to!string);
        // OUTSIDE the parent's box (beyond 40,40) the child must NOT paint:
        // the surface stays white.
        auto outsideRight = surface.pixel(60, 20);
        auto lumRight = (outsideRight & 0xff) + ((outsideRight >> 8) & 0xff) +
            ((outsideRight >> 16) & 0xff);
        assert(lumRight >= 750,
            "child must be clipped right of the parent box, lum=" ~ lumRight.to!string);
        auto outsideBottom = surface.pixel(20, 60);
        auto lumBottom = (outsideBottom & 0xff) + ((outsideBottom >> 8) & 0xff) +
            ((outsideBottom >> 16) & 0xff);
        assert(lumBottom >= 750,
            "child must be clipped below the parent box, lum=" ~ lumBottom.to!string);
        auto outsideCorner = surface.pixel(80, 80);
        auto lumCorner = (outsideCorner & 0xff) + ((outsideCorner >> 8) & 0xff) +
            ((outsideCorner >> 16) & 0xff);
        assert(lumCorner >= 750,
            "child must be clipped at the parent's bottom-right corner, lum=" ~
            lumCorner.to!string);
    }

    // --- overflow:visible lets the child paint outside the parent ---
    // Same geometry, but no overflow property: the red child must be visible
    // at (80,80) — outside the parent's 40x40 box.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.overflow = "visible";
        parent.style.background = "#00ff00";
        parent.box.x = 0; parent.box.y = 0;
        parent.box.width = 40; parent.box.height = 40;

        auto child = new Element("div");
        child.style.display = "block";
        child.style.background = "#ff0000";
        child.box.x = 0; child.box.y = 0;
        child.box.width = 100; child.box.height = 100;

        child.parent = parent;
        parent.children ~= child;
        parent.elements ~= child;

        auto surface = new Surface(120, 120);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(parent, canvas);

        auto far = surface.pixel(80, 80);
        assert(((far >> 16) & 0xff) >= 250,
            "with overflow:visible the child must paint outside the parent, got " ~
            far.to!string);
    }

    // --- overflow:auto draws a scrollbar indicator when content overflows ---
    // A 40x40 box with a 200px-tall child overflows vertically; a dark gray
    // scrollbar thumb must appear along the right edge (inside the box).
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.overflow = "auto";
        parent.style.background = "#ffffff";
        parent.box.x = 0; parent.box.y = 0;
        parent.box.width = 40; parent.box.height = 40;

        auto child = new Element("div");
        child.style.display = "block";
        child.style.background = "#0000ff";
        child.box.x = 0; child.box.y = 0;
        child.box.width = 40; child.box.height = 200;

        child.parent = parent;
        parent.children ~= child;
        parent.elements ~= child;

        auto surface = new Surface(40, 40);
        surface.clear(Color.rgb(255, 255, 255));
        auto canvas = Canvas(surface);
        paintElement(parent, canvas);

        // The scrollbar is at x = innerX + (innerWidth - 6) = 34, spanning
        // 6px wide. A pixel at (36, 10) must be the gray thumb, not white.
        auto thumb = surface.pixel(36, 10);
        auto lum = (thumb & 0xff) + ((thumb >> 8) & 0xff) + ((thumb >> 16) & 0xff);
        assert(lum < 700,
            "overflow:auto must draw a scrollbar thumb on the right edge, lum=" ~
            lum.to!string);
    }
}

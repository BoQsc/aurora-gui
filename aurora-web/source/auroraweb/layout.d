module auroraweb.layout;

/**
 * Block and inline layout with a CSS box model.
 *
 * Produces a `ComputedStyle` for every element and fills each element's `Box`
 * with its final geometry. Supports:
 *
 * - Block layout: vertical stacking of block-level boxes with margins
 *   (including margin collapsing between adjacent vertical margins), padding
 *   and borders.
 * - Inline layout: runs of text and inline elements laid out horizontally,
 *   wrapping at the container width; each text run receives a real position.
 * - Floats (left/right) with a simple wrap-around region.
 * - Flexbox rows: `display:flex` lays children on one row honoring
 *   `flex-grow`, `justify-content`, `align-items` and `gap`.
 * - Positioning: static, relative, absolute (relative to nearest
 *   positioned ancestor, else the root), and fixed (relative to the
 *   viewport, ignoring positioned ancestors), with top/left/right/bottom.
 * - Percentage lengths, min/max-width, min/max-height.
 */

import auroraweb.css : Rule, cascadeFor, applyMediaRules, parseStylesheet,
    keyframeEndState, pseudoElementRules;
import auroraweb.dom : ComputedStyle, Element, InlineFragment, TextNode;
import auroraweb.shaping : shapeTextCached;
import aurora.image : RgbaImage;
import aurora.font : FontRole;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : TextLayout, TextLayoutOptions;

import std.algorithm : max, min;
import std.conv : to;
import std.string : endsWith, indexOf, lastIndexOf, split, strip, toLower;

/// Measure a text run into wrapped lines using Aurora's real text engine.
/// `maxWidth` is the wrap width (0 = no wrap). Returns the TextLayout (or null
/// on failure). This is what makes layout match painting.
private TextLayout shapeText(string text, int pixelSize, int maxWidth)
{
    // Memoized: layout measures every run, and paint then shapes the same runs.
    return shapeTextCached(text, pixelSize, maxWidth, maxWidth > 0);
}

/// Measure the wrapped height of a text run at the given width. Returns the
/// total height in px (0 if unmeasurable/empty).
private int measureTextHeight(string text, int pixelSize, int maxWidth)
{
    if (text.length == 0) return 0;
    auto layout = shapeText(text, pixelSize, maxWidth);
    if (layout is null) return 0;
    return cast(int) layout.height;
}

/// Max-content (intrinsic) width of an element: a single unwrapped line for
/// inline content, or the widest block child. Includes the element's own
/// padding/border. Used to size auto-width flex items to their content (an
/// item with no explicit width must not collapse to 0).
private int intrinsicWidth(Element e, int percentBase)
{
    resolveBoxMetrics(e, percentBase);
    const pixelSize = e.style.fontSizePx > 0 ? e.style.fontSizePx : 16;
    const own = e.box.paddingLeft + e.box.paddingRight + e.box.borderLeft + e.box.borderRight;

    const explicit = e.style.resolveLength(e.style.width, percentBase);
    if (explicit >= 0) return explicit + own;

    int inlineW = 0;
    int blockW = 0;
    bool hasBlock = false;
    foreach (child; e.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            if (t.data.strip().length)
            {
                auto lay = shapeText(t.data, pixelSize, 1_000_000);
                inlineW += lay !is null ? cast(int) lay.width : cast(int)(t.data.length * 8);
            }
            continue;
        }
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto d = ce.style.display;
        if (d == "none") continue;
        // Out-of-flow children (popups, tooltips) do not contribute to the
        // element's intrinsic width.
        if (ce.style.position == "absolute" || ce.style.position == "fixed") continue;
        if (d == "inline" || d == "inline-block" || d == "inline-flex")
            inlineW += intrinsicWidth(ce, percentBase);
        else
        {
            hasBlock = true;
            blockW = max(blockW, intrinsicWidth(ce, percentBase));
        }
    }
    int content = hasBlock ? max(blockW, inlineW) : inlineW;
    // Fallback: no contributory child was seen (e.g. text stored only in the
    // node's own content) — measure the element's text directly.
    if (content == 0)
    {
        auto txt = e.textContent().strip();
        if (txt.length)
        {
            auto lay = shapeText(txt, pixelSize, 1_000_000);
            content = lay !is null ? cast(int) lay.width : cast(int)(txt.length * 8);
        }
    }
    return content + own;
}

/// Min-content width: the widest single word for text, or the widest block
/// child. Used as the automatic minimum size of a flex item (CSS
/// `min-width: auto`) so a shrunk item never forces its own text to wrap.
private int minContentWidth(Element e, int percentBase)
{
    resolveBoxMetrics(e, percentBase);
    const own = e.box.paddingLeft + e.box.paddingRight + e.box.borderLeft + e.box.borderRight;
    const explicit = e.style.resolveLength(e.style.width, percentBase);
    if (explicit >= 0) return explicit + own;
    const pixelSize = e.style.fontSizePx > 0 ? e.style.fontSizePx : 16;

    int widestWord = 0;
    int inlineSum = 0;
    int blockMax = 0;
    bool hasBlock = false;
    foreach (child; e.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            foreach (word; t.data.split())
            {
                auto lay = shapeText(word, pixelSize, 1_000_000);
                if (lay !is null) widestWord = max(widestWord, cast(int) lay.width);
            }
            continue;
        }
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto d = ce.style.display;
        if (d == "none") continue;
        if (ce.style.position == "absolute" || ce.style.position == "fixed") continue;
        if (d == "inline" || d == "inline-block" || d == "inline-flex")
            inlineSum += minContentWidth(ce, percentBase);
        else
        {
            hasBlock = true;
            blockMax = max(blockMax, minContentWidth(ce, percentBase));
        }
    }
    int content = max(widestWord, hasBlock ? blockMax : inlineSum);
    if (content == 0)
    {
        foreach (word; e.textContent().split())
        {
            auto lay = shapeText(word, pixelSize, 1_000_000);
            if (lay !is null) content = max(content, cast(int) lay.width);
        }
    }
    return content + own;
}

/// Resolve styles for every element using the cascade, then lay out.
void applyStylesAndLayout(Element root, Rule[] rules, int viewportWidth, int viewportHeight)
{
    auto active = applyMediaRules(rules, viewportWidth, viewportHeight);
    resolveStyles(root, active, viewportWidth, viewportHeight);
    layout(root, viewportWidth, viewportHeight);
}

/// Resolve computed style for each element and its children.
private void resolveStyles(Element element, Rule[] rules, int viewportWidth, int viewportHeight)
{
    string[string] noCustom;
    resolveStylesInto(element, rules, viewportWidth, viewportHeight, noCustom,
        16, 16, pseudoElementRules(rules, "before"), pseudoElementRules(rules, "after"));
}

/// Resolve styles, inheriting CSS custom properties (`--name`) down the tree.
/// Resolve `font-size` to px: `px` passes through, `rem` scales the root size,
/// `em`/`%` scale the parent size, `vw`/`vh` scale the viewport, and
/// `clamp()/min()/max()` take their first resolvable component. An empty value
/// inherits the parent size.
private int resolveFontSize(in ComputedStyle style, int parentPx)
{
    import auroraweb.dom : cssInt, cssDouble;
    const s = style.fontSize.strip();
    if (s.length == 0) return parentPx;

    int one(string raw)
    {
        const v = raw.strip();
        if (v.length >= 3 && v[$ - 2 .. $] == "px") return cssInt(v[0 .. $ - 2].strip());
        if (v.length >= 3 && v[$ - 3 .. $] == "rem")
            return cast(int)(cssDouble(v[0 .. $ - 3].strip()) * style.rootFontSizePx);
        if (v.length >= 2 && v[$ - 2 .. $] == "em")
            return cast(int)(cssDouble(v[0 .. $ - 2].strip()) * parentPx);
        if (v.length >= 3 && v[$ - 3 .. $] == "vw")
            return style.viewportWidth * cssInt(v[0 .. $ - 3].strip()) / 100;
        if (v.length >= 3 && v[$ - 3 .. $] == "vh")
            return style.viewportHeight * cssInt(v[0 .. $ - 3].strip()) / 100;
        if (v.length >= 2 && v[$ - 1] == '%')
            return parentPx * cssInt(v[0 .. $ - 1].strip()) / 100;
        return -1;
    }

    foreach (fn; ["clamp(", "min(", "max("])
    {
        if (s.length > fn.length && s[0 .. fn.length] == fn && s[$ - 1] == ')')
        {
            // Resolve every component, then combine: clamp(min, val, max) picks
            // the value clamped between its bounds, min() the smallest and max()
            // the largest. Taking the first resolvable component was wrong, so a
            // clamped font size landed on its floor instead of its middle value.
            const inner = s[fn.length .. $ - 1];
            long[] vals;
            int depth = 0;
            size_t start = 0;
            foreach (i, ch; inner)
            {
                if (ch == '(') ++depth;
                else if (ch == ')') --depth;
                else if (ch == ',' && depth == 0)
                {
                    vals ~= one(inner[start .. i]);
                    start = i + 1;
                }
            }
            vals ~= one(inner[start .. $]);
            long[] ok;
            foreach (v; vals)
                if (v >= 0) ok ~= v;
            if (ok.length == 0) return parentPx;
            import std.algorithm : max, min;
            long result = ok[0];
            if (fn == "clamp(" && vals.length >= 3 && vals[0] >= 0 &&
                vals[1] >= 0 && vals[2] >= 0)
                result = max(vals[0], min(vals[1], vals[2]));
            else if (fn == "min(")
                foreach (v; ok) result = min(result, v);
            else if (fn == "max(")
                foreach (v; ok) result = max(result, v);
            return cast(int) result;
        }
    }
    const v = one(s);
    return v >= 0 ? v : parentPx;
}

private void resolveStylesInto(Element element, Rule[] rules, int viewportWidth,
    int viewportHeight, string[string] inheritedCustom, int parentFontPx = 16,
    int rootFontPx = 16, in Rule[] beforeRules = null, in Rule[] afterRules = null)
{
    auto cascade = cascadeFor(element, rules);
    // Custom properties: inherit the parent's (already-settled) map and only
    // copy + settle when THIS element actually declares one. The previous code
    // duplicated the whole map and re-ran the 3-pass `var()` settling for every
    // element on every layout, which dominated style resolution on large pages.
    string[string] custom = inheritedCustom;
    bool addedCustom = false;
    foreach (prop, val; cascade)
        if (prop.length > 2 && prop[0] == '-' && prop[1] == '-')
        {
            if (!addedCustom)
            {
                custom = inheritedCustom.dup;
                addedCustom = true;
            }
            custom[prop] = val;
        }
    if (addedCustom)
    {
        // Settle nested `var()` references between custom properties.
        auto keys = custom.keys;
        foreach (pass; 0 .. 3)
            foreach (k; keys)
                custom[k] = resolveVars(custom[k], custom, 0);
    }

    element.style = computedStyle(element, rules, cascade, custom);
    element.style.viewportWidth = viewportWidth;
    element.style.viewportHeight = viewportHeight;
    element.style.rootFontSizePx = rootFontPx;
    element.style.fontSizePx = resolveFontSize(element.style, parentFontPx);
    // `color` is an inherited property: an element that declares no colour of
    // its own uses its parent's. Without this every such element defaulted to
    // black, so a real page's hero wordmark (`.hero h1` sets no colour, body does)
    // painted black-on-black and looked missing.
    if (element.parent !is null && ("color" !in cascade) &&
        element.style.color == "black")
        element.style.color = element.parent.style.color;
    // The root element establishes the `rem` base for all its descendants.
    const int childRootFont = (element.parent is null) ? element.style.fontSizePx : rootFontPx;
    // Generated pseudo-elements (CSS 12): build the ::before/::after boxes now
    // that this element's style (and inherited custom properties) are settled.
    element.pseudoBefore = buildPseudoElement(element, "before", beforeRules,
        custom, parentFontPx, childRootFont);
    element.pseudoAfter = buildPseudoElement(element, "after", afterRules,
        custom, parentFontPx, childRootFont);
    foreach (child; element.elements)
        resolveStylesInto(child, rules, viewportWidth, viewportHeight, custom,
            element.style.fontSizePx, childRootFont, beforeRules, afterRules);
}

/// Build one generated pseudo-element box, or null when the page has no usable
/// `::before`/`::after` rule for this element (no `content`, or no match). The
/// box is deliberately kept OUT of `children`/`elements` so DOM and script APIs
/// never see it, while layout and paint treat it like any other element.
private Element buildPseudoElement(Element element, string which, in Rule[] rules,
    string[string] custom, int parentFontPx, int rootFontPx)
{
    if (rules.length == 0) return null;
    auto cascade = cascadeFor(element, rules);
    auto contentValue = "content" in cascade;
    if (contentValue is null) return null;
    auto raw = (*contentValue).strip();
    if (raw.length == 0 || raw == "none" || raw == "normal") return null;

    auto pseudo = new Element("::" ~ which);
    pseudo.parent = element;
    pseudo.style = computedStyle(pseudo, rules, cascade, custom);
    // Park the resolved `content` on the node so paint can use it as the box text.
    pseudo.style.content = raw;

    // `content: "text"` / 'text' — strip one surrounding quote pair.
    string text = raw;
    if (text.length >= 2 &&
        ((text[0] == '"' && text[$ - 1] == '"') ||
         (text[0] == '\'' && text[$ - 1] == '\'')))
        text = text[1 .. $ - 1];
    if (text.length)
    {
        auto node = new TextNode(pseudo, text);
        node.parent = pseudo;
        pseudo.children ~= node;
    }
    return pseudo;
}

/// Compute the style map for one element from cascade plus inline style.
private ComputedStyle computedStyle(Element element, in Rule[] rules)
{
    string[string] empty;
    return computedStyle(element, rules, cascadeFor(element, rules), empty);
}

/// Style computation with an inherited custom-property (`--x`) map.
private ComputedStyle computedStyle(Element element, in Rule[] rules,
    string[string] cascadeIn, string[string] custom)
{
    ComputedStyle style;
    // User-agent default display.
    style.display = uaDisplay(element.tag);
    if (element.tag == "th")
        style.fontWeight = "bold";
    applyUserAgentDefaults(style, element.tag);

    // `var(--x)` references are resolved to concrete values before they are
    // applied, using this element's inherited custom-property map.
    string[string] cascade;
    foreach (prop, val; cascadeIn)
        cascade[prop] = resolveVars(val, custom, 0);
    applyDeclaration(style, "display", cascade.get("display", ""));
    applyDeclaration(style, "color", cascade.get("color", ""));
    applyDeclaration(style, "background", cascade.get("background", ""));
    applyDeclaration(style, "background-color", cascade.get("background-color", ""));
    applyDeclaration(style, "background-image", cascade.get("background-image", ""));
    applyDeclaration(style, "background-size", cascade.get("background-size", ""));
    // `aspect-ratio` must be applied here as well as handled in
    // applyDeclaration: this list is what actually feeds the cascade into the
    // style, so a property missing from it never arrives (which is how a
    // landscape figure with aspect-ratio: 1200/520 kept a zero height).
    applyDeclaration(style, "aspect-ratio", cascade.get("aspect-ratio", ""));
    // Same trap this list already documents for `aspect-ratio`: a property that
    // is not named here never reaches the style, however well `applyDeclaration`
    // handles it. `mask-image` and the generated `content` are both needed by
    // real pages (`body::before` fades a grid layer with a gradient mask).
    applyDeclaration(style, "mask-image", cascade.get("mask-image", ""));
    applyDeclaration(style, "-webkit-mask-image",
        cascade.get("-webkit-mask-image", ""));
    applyDeclaration(style, "content", cascade.get("content", ""));
    applyDeclaration(style, "inset", cascade.get("inset", ""));
    applyDeclaration(style, "background-repeat", cascade.get("background-repeat", ""));
    applyDeclaration(style, "font-size", cascade.get("font-size", ""));
    applyDeclaration(style, "font-weight", cascade.get("font-weight", ""));
    applyDeclaration(style, "font-style", cascade.get("font-style", ""));
    applyDeclaration(style, "font-family", cascade.get("font-family", ""));
    applyDeclaration(style, "text-align", cascade.get("text-align", ""));
    applyDeclaration(style, "vertical-align", cascade.get("vertical-align", ""));
    applyDeclaration(style, "clear", cascade.get("clear", ""));
    applyDeclaration(style, "white-space", cascade.get("white-space", ""));
    applyDeclaration(style, "background-clip", cascade.get("background-clip", ""));
    applyDeclaration(style, "border-top-width", cascade.get("border-top-width", ""));
    applyDeclaration(style, "border-right-width", cascade.get("border-right-width", ""));
    applyDeclaration(style, "border-bottom-width", cascade.get("border-bottom-width", ""));
    applyDeclaration(style, "border-left-width", cascade.get("border-left-width", ""));

    applyDeclaration(style, "-webkit-background-clip", cascade.get("-webkit-background-clip", ""));
    applyDeclaration(style, "flex-direction", cascade.get("flex-direction", ""));
    applyDeclaration(style, "width", cascade.get("width", ""));
    applyDeclaration(style, "height", cascade.get("height", ""));
    applyDeclaration(style, "min-width", cascade.get("min-width", ""));
    applyDeclaration(style, "max-width", cascade.get("max-width", ""));
    applyDeclaration(style, "min-height", cascade.get("min-height", ""));
    applyDeclaration(style, "max-height", cascade.get("max-height", ""));
    applyDeclaration(style, "margin", cascade.get("margin", ""));
    applyDeclaration(style, "margin-top", cascade.get("margin-top", ""));
    applyDeclaration(style, "margin-right", cascade.get("margin-right", ""));
    applyDeclaration(style, "margin-bottom", cascade.get("margin-bottom", ""));
    applyDeclaration(style, "margin-left", cascade.get("margin-left", ""));
    applyDeclaration(style, "padding", cascade.get("padding", ""));
    applyDeclaration(style, "padding-top", cascade.get("padding-top", ""));
    applyDeclaration(style, "padding-right", cascade.get("padding-right", ""));
    applyDeclaration(style, "padding-bottom", cascade.get("padding-bottom", ""));
    applyDeclaration(style, "padding-left", cascade.get("padding-left", ""));
    applyDeclaration(style, "border", cascade.get("border", ""));
    applyDeclaration(style, "border-width", cascade.get("border-width", ""));
    applyDeclaration(style, "border-color", cascade.get("border-color", ""));
    applyDeclaration(style, "border-top", cascade.get("border-top", ""));
    applyDeclaration(style, "border-right", cascade.get("border-right", ""));
    applyDeclaration(style, "border-bottom", cascade.get("border-bottom", ""));
    applyDeclaration(style, "border-left", cascade.get("border-left", ""));
    applyDeclaration(style, "position", cascade.get("position", ""));
    applyDeclaration(style, "top", cascade.get("top", ""));
    applyDeclaration(style, "left", cascade.get("left", ""));
    applyDeclaration(style, "right", cascade.get("right", ""));
    applyDeclaration(style, "bottom", cascade.get("bottom", ""));
    applyDeclaration(style, "float", cascade.get("float", ""));
    applyDeclaration(style, "clear", cascade.get("clear", ""));
    applyDeclaration(style, "visibility", cascade.get("visibility", ""));
    applyDeclaration(style, "overflow", cascade.get("overflow", ""));
    applyDeclaration(style, "transform", cascade.get("transform", ""));
    applyDeclaration(style, "flex", cascade.get("flex", ""));
    applyDeclaration(style, "flex-grow", cascade.get("flex-grow", ""));
    applyDeclaration(style, "justify-content", cascade.get("justify-content", ""));
    applyDeclaration(style, "align-items", cascade.get("align-items", ""));
    applyDeclaration(style, "gap", cascade.get("gap", ""));
    applyDeclaration(style, "line-height", cascade.get("line-height", ""));
    applyDeclaration(style, "box-sizing", cascade.get("box-sizing", ""));
    applyDeclaration(style, "grid-template-columns", cascade.get("grid-template-columns", ""));
    applyDeclaration(style, "grid-template-rows", cascade.get("grid-template-rows", ""));
    applyDeclaration(style, "column-gap", cascade.get("column-gap", ""));
    applyDeclaration(style, "row-gap", cascade.get("row-gap", ""));
    applyDeclaration(style, "border-radius", cascade.get("border-radius", ""));
    applyDeclaration(style, "box-shadow", cascade.get("box-shadow", ""));
    applyDeclaration(style, "text-decoration", cascade.get("text-decoration", ""));
    applyDeclaration(style, "opacity", cascade.get("opacity", ""));
    applyDeclaration(style, "z-index", cascade.get("z-index", ""));

    // CSS animations are not run over time. When an animation uses a
    // `forwards`/`both` fill mode, apply its end-state (`to`) keyframe
    // statically -- this is what makes an intro overlay that fades out
    // actually disappear instead of covering the page.
    {
        auto anim = cascade.get("animation", "");
        auto animName = cascade.get("animation-name", "");
        auto fill = cascade.get("animation-fill-mode", "");
        auto combined = toLower(anim ~ " " ~ fill);
        if (indexOf(combined, "forwards") >= 0 || indexOf(combined, "both") >= 0)
        {
            string[] names;
            if (animName.length && animName != "none")
                names = animName.split(",");
            else
                foreach (tok; anim.split(" "))
                {
                    auto t = tok.strip();
                    if (t.length && keyframeEndState(t).length)
                        names ~= t;
                }
            foreach (nm; names)
                foreach (decl; keyframeEndState(nm.strip()))
                    applyDeclaration(style, decl.property, resolveVars(decl.value, custom, 0));
        }
    }

    // Inline style attribute overrides everything.
    auto inlineStyle = "style" in element.attrs;
    if (inlineStyle !is null)
    {
        foreach (decl; parseInlineDeclarations(*inlineStyle))
            applyDeclaration(style, decl.property, decl.value);
    }
    return style;
}

/// Resolve every `var(--name[, fallback])` in `value` using `custom`.
private string resolveVars(string value, string[string] custom, int depth)
{
    if (depth > 12) return value;
    if (indexOf(value, "var(") < 0) return value;
    string result;
    size_t i = 0;
    while (i < value.length)
    {
        auto p = indexOf(value[i .. $], "var(");
        if (p < 0) { result ~= value[i .. $]; break; }
        p += i;
        result ~= value[i .. p];
        size_t j = p + 4;
        int d = 1;
        while (j < value.length && d > 0)
        {
            if (value[j] == '(') d++;
            else if (value[j] == ')') { d--; if (d == 0) break; }
            j++;
        }
        auto inner = value[p + 4 .. (j < value.length ? j : value.length)];
        auto comma = topLevelComma(inner);
        auto name = ((comma < 0) ? inner : inner[0 .. comma]).strip();
        auto fallback = (comma < 0) ? "" : inner[comma + 1 .. $].strip();
        auto it = name in custom;
        if (it !is null) result ~= resolveVars(*it, custom, depth + 1);
        else if (fallback.length) result ~= resolveVars(fallback, custom, depth + 1);
        i = (j < value.length) ? j + 1 : value.length;
    }
    return result;
}

private ptrdiff_t topLevelComma(string s)
{
    int d = 0;
    foreach (k, ch; s)
    {
        if (ch == '(') d++;
        else if (ch == ')') d--;
        else if (ch == ',' && d == 0) return k;
    }
    return -1;
}

/// Best-effort solid color for a `background` that is a gradient list: the
/// Resolve a CSS `transform` list's translation in pixels. Percentages resolve
/// against the element's OWN box, which is what makes the ubiquitous
/// `transform: translate(-50%, -50%)` centring trick work.
void transformTranslate(in string transform, int selfW, int selfH,
    out int dx, out int dy)
{
    import std.conv : to;
    dx = 0;
    dy = 0;
    if (transform.length == 0) return;
    const lower = transform.toLower();
    if (lower == "none") return;

    static int one(string arg, int base_)
    {
        auto a = arg.strip();
        if (a.length == 0) return 0;
        if (a[$ - 1] == '%')
        {
            double p = 0;
            try p = to!double(a[0 .. $ - 1].strip());
            catch (Exception) return 0;
            return cast(int) (p * base_ / 100.0);
        }
        if (a.length > 2 && a[$ - 2 .. $].toLower() == "px") a = a[0 .. $ - 2];
        double v = 0;
        try v = to!double(a.strip());
        catch (Exception) return 0;
        return cast(int) v;
    }

    size_t i = 0;
    while (i < lower.length)
    {
        const open = indexOf(lower[i .. $], '(');
        if (open < 0) break;
        const absOpen = i + open;
        const close = indexOf(lower[absOpen .. $], ')');
        if (close < 0) break;
        const absClose = absOpen + close;
        auto name = lower[i .. absOpen].strip();
        auto args = transform[absOpen + 1 .. absClose];
        if (name == "translate" || name == "translatex" || name == "translatey")
        {
            auto parts = args.split(',');
            if (name != "translatey" && parts.length >= 1)
                dx += one(parts[0], selfW);
            if (name == "translatey" && parts.length >= 1)
                dy += one(parts[0], selfH);
            else if (name == "translate" && parts.length >= 2)
                dy += one(parts[1], selfH);
        }
        i = absClose + 1;
    }
}

/// Extract a `linear-gradient(...)` / `radial-gradient(...)` token, balancing
/// nested parentheses so colours like `rgba(1, 2, 3, 0.5)` survive intact.
private string extractGradientToken(string value)
{
    const lower = value.toLower();
    ptrdiff_t start = -1;
    foreach (kw; ["linear-gradient(", "radial-gradient("])
    {
        const at = indexOf(lower, kw);
        if (at >= 0 && (start < 0 || at < start)) start = at;
    }
    if (start < 0) return "";
    int depth = 0;
    for (auto i = start; i < cast(ptrdiff_t) value.length; i++)
    {
        if (value[i] == '(') depth++;
        else if (value[i] == ')')
        {
            depth--;
            if (depth == 0) return value[start .. i + 1].strip();
        }
    }
    return "";
}

/// first color stop of the last gradient. Gradients are not painted, so this
/// approximates the intended theme rather than leaving the element transparent
/// (which would, e.g., put light text on a white page).
private string solidColorFromBackground(string value)
{
    if (indexOf(value, "gradient(") < 0) return value;
    auto last = lastIndexOf(value, "gradient(");
    auto paren = indexOf(value[last .. $], "(");
    if (paren < 0) return value;
    paren += last;
    size_t j = paren + 1;
    int d = 1;
    while (j < value.length && d > 0)
    {
        if (value[j] == '(') d++;
        else if (value[j] == ')') { d--; if (d == 0) break; }
        j++;
    }
    auto inner = value[paren + 1 .. (j < value.length ? j : value.length)];
    auto c = firstColorInGradient(inner);
    return c.length ? c : value;
}

private string firstColorInGradient(string inner)
{
    string[] parts;
    size_t start = 0;
    int d = 0;
    foreach (k, ch; inner)
    {
        if (ch == '(') d++;
        else if (ch == ')') d--;
        else if (ch == ',' && d == 0) { parts ~= inner[start .. k]; start = k + 1; }
    }
    parts ~= inner[start .. $];
    foreach (part; parts)
    {
        auto p = part.strip();
        if (p.length == 0 || indexOf(p, "transparent") == 0) continue;
        if (indexOf(p, "#") >= 0 || indexOf(p, "rgb") >= 0 || indexOf(p, "hsl") >= 0)
        {
            // Functional colors end at ')'; hex/named colors end at whitespace.
            auto rp = indexOf(p, "rgb");
            auto hp = indexOf(p, "hsl");
            auto fp = (rp >= 0 && (hp < 0 || rp < hp)) ? rp : hp;
            if (fp >= 0)
            {
                auto close = indexOf(p, ")", fp);
                return (close >= 0) ? p[0 .. close + 1] : p;
            }
            auto sp = indexOf(p, " ");
            return (sp < 0) ? p : p[0 .. sp];
        }
    }
    return "";
}

version (unittest)
unittest
{
    // CSS custom properties, var(), gradient fallback, :root, @keyframes.
    auto rules = parseStylesheet(`
        :root { --bg: #050506; --text: rgba(240,238,232,0.9); }
        body { background: radial-gradient(circle, rgba(255,255,255,0.05), transparent 24%),
               linear-gradient(180deg, #070708 0%, #040405 100%);
               color: var(--text); margin: var(--pad, 8px); }
        .intro { background: var(--bg); animation: hide 0.3s forwards; }
        @keyframes hide { to { opacity: 0; visibility: hidden; } }
    `, 1280, 800);

    auto root = new Element("html");
    auto body = new Element("body");
    body.parent = root; root.children ~= body; root.elements ~= body;
    auto intro = new Element("div");
    intro.attrs["class"] = "intro";
    intro.parent = body; body.children ~= intro; body.elements ~= intro;

    applyStylesAndLayout(root, rules, 1280, 800);

    assert(intro.style.background == "#050506",
        "var(--bg) resolved on .intro: " ~ intro.style.background);
    assert(body.style.background == "#070708",
        "gradient fallback color: " ~ body.style.background);
    assert(body.style.margin == "8px", "var() fallback: " ~ body.style.margin);
    assert(body.style.color == "rgba(240,238,232,0.9)", "var(--text): " ~ body.style.color);
    assert(intro.style.opacity == 0.0, "keyframes opacity: " ~ to!string(intro.style.opacity));
    assert(intro.style.visibility == "hidden", "keyframes visibility: " ~ intro.style.visibility);

    // `::before`/`::after` must not match the element they decorate.
    auto rules2 = parseStylesheet(
        `body { background: #101010; } body::before { background: red; }`, 100, 100);
    auto r2 = new Element("body");
    applyStylesAndLayout(r2, rules2, 100, 100);
    assert(r2.style.background == "#101010", "::before must not override body: " ~ r2.style.background);

    // A functional color inside a gradient is extracted whole (not cut at a
    // comma/space inside the parentheses).
    auto rules3 = parseStylesheet(
        `p { background: linear-gradient(90deg, transparent 0 1px, rgba(1, 2, 3, 0.5) 1px 2px); }`,
        100, 100);
    auto p3 = new Element("p");
    applyStylesAndLayout(p3, rules3, 100, 100);
    assert(p3.style.background == "rgba(1, 2, 3, 0.5)", "functional color whole: " ~ p3.style.background);
}

version (unittest)
unittest
{
    // minmax()/calc()/var() grid tracks resolve to real columns (the boqsc.eu
    // hero split: minmax(0, calc(var(--ratio) * 100%)) minmax(0, 1fr)).
    auto rules = parseStylesheet(`
        :root { --hero-split-ratio: 0.38; }
        .hero { display: grid; width: 1000px;
                grid-template-columns: minmax(0, calc(var(--hero-split-ratio) * 100%)) minmax(0, 1fr); }
    `, 1000, 800);
    auto hero = new Element("div");
    hero.attrs["class"] = "hero";
    auto root = new Element("div");
    root.attrs["style"] = "width: 1000px;";
    hero.parent = root; root.children ~= hero; root.elements ~= hero;
    auto a = new Element("div");
    auto b = new Element("div");
    a.parent = hero; b.parent = hero;
    hero.children ~= a; hero.children ~= b;
    hero.elements ~= a; hero.elements ~= b;

    applyStylesAndLayout(root, rules, 1000, 800);
    assert(a.box.width == 380, "col0 width (38%): " ~ a.box.width.to!string);
    assert(b.box.width == 620, "col1 width (1fr): " ~ b.box.width.to!string);
    assert(b.box.x == 380, "col1 x: " ~ b.box.x.to!string);
}

private string uaDisplay(string tag)
{
    switch (tag)
    {
        case "html", "body", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6",
             "ul", "ol", "dl", "dt", "dd", "table", "tr", "form",
             "section", "article", "aside", "header", "footer", "nav",
             "main", "blockquote", "pre", "hr", "fieldset", "figure",
             "figcaption", "address", "video", "audio", "canvas":
            return "block";
        case "li":
            return "list-item";
        case "td", "th":
            return "table-cell";
        case "a", "span", "b", "i", "u", "em", "strong", "small", "sub",
             "sup", "label", "mark", "code", "kbd", "samp", "q", "cite",
             "abbr", "time", "data":
            return "inline";
        case "br":
            return "inline";
        case "img", "svg", "input", "textarea", "select", "button":
            return "inline-block";
        case "head", "title", "meta", "link", "style", "script", "template",
             // The root `svg` box is painted as a rasterised image, so the SVG
             // *inner* element names stay hidden: <text>/<path>/<rect> must not
             // also be laid out as ordinary page boxes or page text. `desc` and
             // `metadata` are accessibility metadata too: without them here a
             // real page painted its illustration's description ("A dark ink-style
             // landscape with mountains, trees, and water.") as visible page text.
             "desc", "metadata",
             "defs", "symbol", "g", "text", "tspan", "path", "rect",
             "circle", "ellipse", "line", "polyline", "polygon", "stop",
             "use", "mask", "clippath", "lineargradient", "radialgradient",
             "marker", "pattern", "filter", "foreignobject":
            return "none";
        default:
            return "inline";
    }
}

/// Baseline user-agent styling for common HTML tags. Applied before the author
/// cascade and inline `style=""`, so page CSS still overrides it. Without this,
/// headings, paragraphs and lists had no default margins or type sizes and
/// every block sat flush against the previous one.
/// Expand tabs to eight spaces. The shaper's own tab advance is unreliable - a
/// real page's `white-space: pre-wrap` link list (whose markup indents each link
/// with tabs) came out LEFT of its content box and was clipped - and an explicit
/// expansion is always positive and predictable.
private string expandTabs(string s)
{
    if (s.length == 0) return s;
    bool hasTab = false;
    foreach (char c; s) if (c == '\t') { hasTab = true; break; }
    if (!hasTab) return s;
    string result;
    result.reserve(s.length + 32);
    foreach (char c; s)
        result ~= (c == '\t') ? "        " : [c];
    return result;
}

private void applyUserAgentDefaults(ref ComputedStyle style, string tag)
{
    switch (tag)
    {
        case "h1":
            style.fontSize = "32px";
            style.fontWeight = "bold";
            style.margin = "21px 0";
            break;
        case "h2":
            style.fontSize = "24px";
            style.fontWeight = "bold";
            style.margin = "19px 0";
            break;
        case "h3":
            style.fontSize = "19px";
            style.fontWeight = "bold";
            style.margin = "18px 0";
            break;
        case "h4":
            style.fontSize = "16px";
            style.fontWeight = "bold";
            style.margin = "21px 0";
            break;
        case "h5":
            style.fontSize = "13px";
            style.fontWeight = "bold";
            style.margin = "22px 0";
            break;
        case "h6":
            style.fontSize = "11px";
            style.fontWeight = "bold";
            style.margin = "24px 0";
            break;
        case "p", "figure", "dl":
            style.margin = "16px 0";
            break;
        case "pre":
            style.margin = "16px 0";
            style.fontFamily = "monospace";
            break;
        case "blockquote":
            style.margin = "16px 40px";
            break;
        case "ul", "ol":
            style.margin = "16px 0";
            style.padding = "0 0 0 40px";
            break;
        case "dd":
            style.margin = "0 0 0 40px";
            break;
        case "hr":
            style.margin = "8px 0";
            break;
        case "b", "strong":
            style.fontWeight = "bold";
            break;
        case "i", "em", "cite", "dfn", "var":
            style.fontStyle = "italic";
            break;
        case "code", "kbd", "samp":
            style.fontFamily = "monospace";
            break;
        case "input", "textarea", "select", "button":
            // Default form-control chrome. Without it these tags paint as an
            // empty box with no border or background, so a text field is
            // invisible and impossible to aim the pointer at.
            style.background = "#ffffff";
            style.color = "#000000";
            style.border = "1px solid";
            style.borderStyle = "solid";
            style.borderColor = "#767676";
            style.fontSize = "13px";
            style.padding = (tag == "button") ? "2px 8px" : "1px 3px";
            // Text fields have no child content, so without a default height
            // they collapse to their padding/border and read as an empty box.
            if (tag == "input" || tag == "select")
                style.height = "20px";
            break;
        default:
            break;
    }
}

private void applyDeclaration(ref ComputedStyle style, string property, string value)
{
    if (value.length == 0) return;
    // Strip a vendor prefix (`-webkit-background-clip` == `background-clip`).
    auto name = property;
    if (name.length > 1 && name[0] == '-')
    {
        auto dash = name[1 .. $].indexOf('-');
        if (dash >= 0) name = name[dash + 2 .. $];
    }
    switch (name)
    {
        case "display":
            if (value == "block" || value == "inline" || value == "inline-block" ||
                value == "flex" || value == "inline-flex" || value == "none" ||
                value == "list-item" ||
                value == "grid" || value == "table" || value == "table-row" ||
                value == "table-cell")
                style.display = value;
            break;
        case "color": style.color = value; break;
        case "background":
            style.background = solidColorFromBackground(value);
            // The `background` SHORTHAND carries the image as well:
            // `background: url(hero.jpg) center/cover no-repeat`. It used to be
            // dropped, so any page declaring its imagery that way rendered with
            // no background image at all.
            {
                auto u = extractUrlToken(value);
                if (u.length) style.backgroundImage = u;
                // The shorthand also carries a gradient (very common for heroes
                // and cards). Without this the property painted nothing.
                auto g = extractGradientToken(value);
                if (g.length) style.backgroundGradient = g;
                // The shorthand carries the repeat mode too.
                const vl = value.toLower();
                if (indexOf(vl, "no-repeat") >= 0) style.backgroundRepeat = "no-repeat";
                else if (indexOf(vl, "repeat-x") >= 0) style.backgroundRepeat = "repeat-x";
                else if (indexOf(vl, "repeat-y") >= 0) style.backgroundRepeat = "repeat-y";
            }
            break;
        case "background-color": style.background = value; break;
        case "background-image":
            // url("...") or none. Anything else (linear-gradient etc.) is
            // treated as none so layout/paint never try to load a bogus URL.
            {
                const v = value.strip();
                if (v == "none" || v.length == 0)
                    style.backgroundImage = "none";
                else if (v.length >= 4 && v[0 .. 4].toLower() == "url(" && v[$ - 1] == ')')
                    style.backgroundImage = v;
                else
                {
                    // A gradient is real content, not an unusable URL: keep the
                    // token so the renderer can rasterise it (they were dropped,
                    // so every gradient background painted nothing).
                    auto g = extractGradientToken(v);
                    style.backgroundGradient = g.length ? g : "none";
                    style.backgroundImage = "none";
                }
            }
            break;
        case "background-size":
            // cover | contain | <len> <len> | <len> | auto
            {
                const v = value.strip().toLower();
                if (v.length == 0) break;
                style.backgroundSize = v;
            }
            break;
        case "background-repeat":
            // repeat | repeat-x | repeat-y | no-repeat (CSS tiles by default).
            {
                const v = value.strip().toLower();
                if (v == "repeat" || v == "repeat-x" || v == "repeat-y" ||
                    v == "no-repeat")
                    style.backgroundRepeat = v;
            }
            break;
        case "font-size": style.fontSize = value; break;
        case "font-weight": style.fontWeight = value; break;
        case "font-style": style.fontStyle = value; break;
        case "font-family": style.fontFamily = value; break;
        case "text-align": style.textAlign = value; break;
        case "vertical-align":
            style.verticalAlign = value.strip().toLower();
            break;

        // Keyword-valued properties are normalized once here (trim + lower) so
        // the paint/layout hot paths compare strings without allocating.
        case "white-space": style.whiteSpace = value.strip().toLower(); break;
        case "background-clip":
            style.backgroundClip = value.strip().toLower();
            break;
        case "width": style.width = value; break;
        case "height": style.height = value; break;
        case "min-width": style.minWidth = value; break;
        case "max-width": style.maxWidth = value; break;
        case "min-height": style.minHeight = value; break;
        case "max-height": style.maxHeight = value; break;
        case "margin": style.margin = value; break;
        case "margin-top": style.marginTop = value; break;
        case "margin-right": style.marginRight = value; break;
        case "margin-bottom": style.marginBottom = value; break;
        case "margin-left": style.marginLeft = value; break;
        case "padding": style.padding = value; break;
        case "padding-top": style.paddingTop = value; break;
        case "padding-right": style.paddingRight = value; break;
        case "padding-bottom": style.paddingBottom = value; break;
        case "padding-left": style.paddingLeft = value; break;
        case "border": style.border = value; break;
        case "border-width": style.borderWidth = value; break;
        case "border-color": style.borderColor = value; break;
        case "border-style": style.borderStyle = value; break;
        // Per-side width/colour longhands, so `border-bottom-width: 3px`
        // overrides a `border` shorthand's width.
        case "border-top-width": style.borderTopWidth = value; break;
        case "border-right-width": style.borderRightWidth = value; break;
        case "border-bottom-width": style.borderBottomWidth = value; break;
        case "border-left-width": style.borderLeftWidth = value; break;

        case "border-top-style": style.borderTopStyle = value; break;
        case "border-right-style": style.borderRightStyle = value; break;
        case "border-bottom-style": style.borderBottomStyle = value; break;
        case "border-left-style": style.borderLeftStyle = value; break;
        case "border-top-color": style.borderTopColor = value; break;
        case "border-right-color": style.borderRightColor = value; break;
        case "border-bottom-color": style.borderBottomColor = value; break;
        case "border-left-color": style.borderLeftColor = value; break;
        case "outline": style.outline = value; break;
        case "outline-color": style.outlineColor = value; break;
        case "outline-width": style.outlineWidth = value; break;
        case "outline-style": style.outlineStyle = value; break;
        case "outline-offset": style.outlineOffset = value; break;
        case "inset":
            // The modern top/right/bottom/left shorthand. Expanding it into the
            // longhands here means a later `top:` declaration still wins, which
            // is the correct cascade behaviour for a shorthand.
            style.top = shorthandToken(value, 0);
            style.right = shorthandToken(value, 1);
            style.bottom = shorthandToken(value, 2);
            style.left = shorthandToken(value, 3);
            break;
        case "border-top": style.borderTopWidth = value; break;
        case "border-right": style.borderRightWidth = value; break;
        case "border-bottom": style.borderBottomWidth = value; break;
        case "border-left": style.borderLeftWidth = value; break;
        case "position":
            // `sticky` is approximated as `relative`: it stays in flow but is
            // still a containing block for absolutely-positioned descendants.
            if (value == "sticky")
                style.position = "relative";
            else if (value == "static" || value == "relative" || value == "absolute" ||
                value == "fixed")
                style.position = value;
            break;
        case "top": style.top = value; break;
        case "left": style.left = value; break;
        case "right": style.right = value; break;
        case "bottom": style.bottom = value; break;
        case "float": if (value == "left" || value == "right" || value == "none")
            style.floatStyle = value; break;
        case "clear": if (value == "left" || value == "right" || value == "both" || value == "none")
            style.clear = value; break;
        case "visibility": style.visibility = value; break;
        case "overflow": style.overflow = value.strip().toLower(); break;
        // CSS `transform`. Only the translate functions are honoured so far;
        // they are by far the most common (hover nudges and the ubiquitous
        // `translate(-50%, -50%)` centring trick), and ignoring them left such
        // elements in the wrong place.
        case "transform": style.transform = value.strip(); break;
        case "object-fit": style.objectFit = value.strip().toLower(); break;
        // `mask-image`: the fading linear-gradient mask pages use to soften a
        // decorative layer. Its alpha multiplies everything the element paints.
        case "mask-image", "-webkit-mask-image":
            style.maskImage = value.strip();
            break;
        // `content` — generates the text of a ::before/::after box. A box is only
        // generated when `content` is present, so this is the switch for the
        // whole feature.
        case "content": style.content = value.strip(); break;

        case "flex":
            // flex: <grow> <shrink> <basis> — use grow.
            {
                auto parts = value.split();
                if (parts.length) style.flexGrow = parts[0] == "none" ? "0" : parts[0];
            }
            break;
        case "flex-grow": style.flexGrow = value; break;
        case "justify-content":
            if (value == "flex-start" || value == "center" || value == "space-between" ||
                value == "space-around" || value == "space-evenly" || value == "flex-end")
                style.justifyContent = value;
            break;
        case "align-items":
            if (value == "stretch" || value == "center" || value == "flex-start" || value == "flex-end")
                style.alignItems = value;
            break;
        case "gap": style.gap = value; break;
        case "aspect-ratio":
            style.aspectRatio = value == "auto" ? "" : value;
            break;
        case "flex-direction":
            if (value == "row" || value == "row-reverse" || value == "column" ||
                value == "column-reverse")
                style.flexDirection = value;
            break;
        case "line-height": style.lineHeight = value; break;
        case "box-sizing":
            if (value == "border-box" || value == "content-box") style.boxSizing = value;
            break;
        case "border-radius": style.borderRadius = value; break;
        case "box-shadow":
            // box-shadow: none | H V blur color
            {
                auto parts = value.strip().split();
                if (parts.length == 0) break;
                if (parts[0] == "none")
                {
                    style.boxShadowH = "0px";
                    style.boxShadowV = "0px";
                    style.boxShadowBlur = "0px";
                    style.boxShadowSpread = "0px";
                    style.boxShadowColor = "none";
                }
                else if (parts.length >= 3)
                {
                    style.boxShadowH = parts[0];
                    style.boxShadowV = parts[1];
                    style.boxShadowBlur = parts[2];
                    // `H V blur [spread] [color] [inset]`: the spread is the
                    // optional fourth length — it used to be swallowed into the
                    // colour, which then failed to parse.
                    const hasSpread = parts.length >= 4 && isResolvableLength(parts[3]);
                    style.boxShadowSpread = hasSpread ? parts[3] : "0px";
                    const colorBegin = hasSpread ? 4 : 3;
                    string color = "";
                    foreach (i; colorBegin .. parts.length)
                    {
                        if (parts[i] == "inset" || parts[i] == "none") continue;
                        color = color.length ? (color ~ " " ~ parts[i]) : parts[i];
                    }
                    style.boxShadowColor = color.length ? color : "rgba(0, 0, 0, 0.3)";
                }
                else
                {
                    style.boxShadowH = "0px";
                    style.boxShadowV = "0px";
                    style.boxShadowBlur = "0px";
                    style.boxShadowColor = "none";
                }
            }
            break;
        case "text-decoration":
            if (value == "underline" || value == "line-through" ||
                value == "overline" || value == "none")
                style.textDecoration = value;
            break;
        case "opacity":
            {
                import auroraweb.dom : cssDouble;
                auto o = cssDouble(value.strip());
                if (o < 0.0) o = 0.0;
                if (o > 1.0) o = 1.0;
                style.opacity = o;
            }
            break;
        case "z-index":
            {
                import auroraweb.dom : cssInt;
                style.zIndex = cssInt(value.strip());
            }
            break;
        case "grid-template-columns": style.gridTemplateColumns = value; break;
        case "grid-template-rows": style.gridTemplateRows = value; break;
        case "column-gap": style.columnGap = value; break;
        case "row-gap": style.rowGap = value; break;
        default: break;
    }
}

/// Parse a style attribute's declarations.
private Declaration[] parseInlineDeclarations(string text)
{
    Declaration[] result;
    size_t i = 0;
    const n = text.length;
    while (i < n)
    {
        ptrdiff_t colon = -1;
        for (auto j = i; j < n; j++)
        {
            if (text[j] == ';') break;
            if (text[j] == ':') { colon = j; break; }
        }
        if (colon < 0) break;
        auto prop = text[i .. colon].strip().toLower();
        auto semi = indexOf(text, ";", colon);
        if (semi < 0) semi = n;
        auto value = text[colon + 1 .. semi].strip();
        if (prop.length && value.length)
            result ~= Declaration(prop, value, false);
        i = semi < 0 ? n : semi + 1;
    }
    return result;
}

private struct Declaration
{
    string property;
    string value;
    bool important;
}

/// Layout the whole tree into the root's box.
void layout(Element root, int viewportWidth, int viewportHeight)
{
    auto flow = FlowContext();
    flow.x = 0;
    flow.y = 0;
    flow.width = viewportWidth;
    flow.height = viewportHeight;
    layoutBlock(root, flow, viewportWidth, null);
    // Root fills viewport width.
    root.box.x = 0;
    root.box.y = 0;
    root.box.width = viewportWidth;
    root.box.height = max(viewportHeight, contentHeight(root));
}

private int contentHeight(Element root)
{
    int bottom = 0;
    void walk(Element e)
    {
        bottom = max(bottom, e.box.y + e.box.height + e.box.marginBottom);
        foreach (child; e.elements)
            walk(child);
    }
    walk(root);
    return bottom;
}

/// Resolve margin/padding/border box values from style strings.
private void resolveBoxMetrics(Element element, int containingWidth)
{
    auto style = element.style;
    bool autoTop, autoRight, autoBottom, autoLeft;
    // Resolve each side from per-side values or the shorthand.
    element.box.marginTop = resolveSide(style, style.marginTop.length ? style.marginTop : style.margin,
        containingWidth, 0, autoTop);
    element.box.marginRight = resolveSide(style, style.marginRight.length ? style.marginRight : style.margin,
        containingWidth, 1, autoRight);
    element.box.marginBottom = resolveSide(style, style.marginBottom.length ? style.marginBottom : style.margin,
        containingWidth, 2, autoBottom);
    element.box.marginLeft = resolveSide(style, style.marginLeft.length ? style.marginLeft : style.margin,
        containingWidth, 3, autoLeft);
    // Vertical `auto` margins are 0 in normal flow; horizontal ones center.
    element.box.marginLeftAuto = autoLeft;
    element.box.marginRightAuto = autoRight;
    // Keep the vertical flags too: for an absolutely positioned box with both
    // insets they distribute the leftover space (CSS 10.6.4).
    element.box.marginTopAuto = autoTop;
    element.box.marginBottomAuto = autoBottom;

    bool dummy;
    element.box.paddingTop = resolveSide(style, style.paddingTop.length ? style.paddingTop : style.padding,
        containingWidth, 0, dummy);
    element.box.paddingRight = resolveSide(style, style.paddingRight.length ? style.paddingRight : style.padding,
        containingWidth, 1, dummy);
    element.box.paddingBottom = resolveSide(style, style.paddingBottom.length ? style.paddingBottom : style.padding,
        containingWidth, 2, dummy);
    element.box.paddingLeft = resolveSide(style, style.paddingLeft.length ? style.paddingLeft : style.padding,
        containingWidth, 3, dummy);

    // Borders. A side's width may come from its own `border-<side>` shorthand
    // (which carries the style and colour too), from `border-width`, or from
    // the `border` shorthand.

    // A border draws — and takes space — only when it has a visible style: an
    // explicit `border-style: none`/`hidden`, or one inside a `border`
    // shorthand, removes the width even if a border-width was declared
    // (CSS 8.5.3). `border-style` is itself a 1-4 value shorthand, so each side
    // is checked against its own token.
    bool isVisibleStyle(string token)
    {
        switch (token)
        {
            case "solid", "dashed", "dotted", "double", "groove", "ridge",
                "inset", "outset":
                return true;
            default:
                return false;
        }
    }
    /// Whether this side draws at all. `none`/`hidden` block it, but the
    /// INITIAL `border-style: none` must not block a style declared inside a
    /// `border`/`border-<side>` shorthand (the engine cannot tell a declared
    /// `none` from the initial value, so a shorthand style wins there).
    bool styleVisible(string sideStyle, string sideShorthand, string list, int sideIndex)
    {
        bool shorthandStyle;
        foreach (cand; [sideShorthand, style.border, list])
            foreach (token; cand.split())
                if (isVisibleStyle(token)) shorthandStyle = true;
        const perSide = sideStyle.length ? shorthandToken(sideStyle, sideIndex) : "";
        const bs = style.borderStyle.length
            ? shorthandToken(style.borderStyle, sideIndex) : "";
        if (!shorthandStyle)
        {
            if (perSide == "none" || perSide == "hidden") return false;
            if (bs == "none" || bs == "hidden") return false;
        }
        if (perSide.length && isVisibleStyle(perSide)) return true;
        if (bs.length && isVisibleStyle(bs)) return true;
        return shorthandStyle;
    }

    // A `border`/`border-<side>` shorthand carries width, style and colour
    // together and applies to the WHOLE side, so its width is the first length
    // token — indexing the token list per side would pick up the style/colour
    // token instead (which made `border: 1px solid red` give a 1px top and a 0px
    // left, right and bottom). `border-width` IS a 1-4 value list, so that keeps
    // the per-side resolution.
    bool isShorthand(string source)
    {
        foreach (token; source.split())
            if (isVisibleStyle(token)) return true;
        return false;
    }
    int shorthandWidth(string source)
    {
        foreach (token; source.split())
        {
            const t = token.strip();
            if (t.length == 0 || isVisibleStyle(t) || t == "none" || t == "hidden") continue;
            const v = style.resolveLength(t, containingWidth);
            if (v >= 0) return v;
            if (t == "thin") return 1;
            if (t == "medium") return 3;
            if (t == "thick") return 5;
        }
        return 0;
    }
    /// First source that yields a positive width wins: the per-side shorthand
    /// (`border-<side>`), then the `border` shorthand, then `border-width`. The
    /// engine does not retain declaration order, and this covers the practical
    /// combinations (`border: 1px solid`, `border: solid; border-width: 2px`,
    /// `border-width: thick`, `border-bottom-width: 3px`). The `thin`/`medium`/
    /// `thick` keywords are lengths too (1/3/5px).
    int borderPx(string sideShorthand, string list, int sideIndex)
    {
        foreach (cand; [sideShorthand, style.border, list])
        {
            if (cand.length == 0) continue;
            int v;
            if (isShorthand(cand))
                v = shorthandWidth(cand);
            else
            {
                const token = shorthandToken(cand, sideIndex).strip();
                if (token == "thin") v = 1;
                else if (token == "medium") v = 3;
                else if (token == "thick") v = 5;
                else v = sideValue(style, cand, containingWidth, sideIndex);
            }
            if (v > 0) return v;
        }
        return 0;
    }

    element.box.borderTop =
        styleVisible(style.borderTopStyle, style.borderTopWidth, style.borderWidth, 0)
        ? borderPx(style.borderTopWidth, style.borderWidth, 0) : 0;
    element.box.borderRight =
        styleVisible(style.borderRightStyle, style.borderRightWidth, style.borderWidth, 1)
        ? borderPx(style.borderRightWidth, style.borderWidth, 1) : 0;
    element.box.borderBottom =
        styleVisible(style.borderBottomStyle, style.borderBottomWidth, style.borderWidth, 2)
        ? borderPx(style.borderBottomWidth, style.borderWidth, 2) : 0;
    element.box.borderLeft =
        styleVisible(style.borderLeftStyle, style.borderLeftWidth, style.borderWidth, 3)
        ? borderPx(style.borderLeftWidth, style.borderWidth, 3) : 0;
}

/// True when a margin/padding/border token is a length the engine can resolve.
/// Extract the first `url(...)` token from a declaration value, or "" when the
/// value carries no URL (used by the `background` shorthand).
private string extractUrlToken(string value)
{
    const v = value.strip();
    auto i = v.toLower().indexOf("url(");
    if (i < 0) return "";
    auto j = v.indexOf(")", i + 4);
    if (j < 0) return "";
    return v[i .. j + 1];
}

/// Keywords (`none`, `solid`, `revert`, ...) and unknown units are not, so they
/// resolve to 0 instead of shrinking the box with an invalid negative value.
private static bool isResolvableLength(string token)
{
    if (token.length >= 5 && token[0 .. 5] == "calc(") return true;
    if (token == "0") return true;
    foreach (unit; ["px", "rem", "%", "em", "vh", "vw", "pt", "pc", "ch", "ex"])
        if (token.length > unit.length && token[$ - unit.length .. $] == unit)
            return true;
    return false;
}

/// Resolve one side of a margin/padding/border shorthand through the same
/// length rules as every other property (px/%/em/rem/vh/vw/calc, where `em`
/// uses THIS element's font size). `auto` is reported through `isAuto` — only
/// margins use it, and only the horizontal ones have an effect. Anything that
/// is not a resolvable length resolves to 0, never a negative length: a
/// shorthand like `border: none` or `margin: 1vh` used to produce -1px.
private int resolveSide(ComputedStyle style, string value, int base, int sideIndex,
    out bool isAuto)
{
    isAuto = false;
    const token = shorthandToken(value, sideIndex);
    if (!token.length) return 0;
    if (token == "auto") { isAuto = true; return 0; }
    if (!isResolvableLength(token)) return 0;
    // The unit is known here, so resolveLength always parses it: a -1 result is
    // a genuine -1px (negative margins are legal), never the "invalid" marker.
    return style.resolveLength(token, base);
}

/// Pick one side out of a 1-4 value shorthand (`margin: a b c d` rules) where
/// sideIndex is 0=top, 1=right, 2=bottom, 3=left. "" for an empty shorthand.
private static string shorthandToken(string value, int sideIndex)
{
    auto parts = value.split();
    switch (parts.length)
    {
        case 0: return "";
        case 1: return parts[0];
        // 2-value shorthand is vertical horizontal: top/bottom = first,
        // left/right = second.
        case 2: return (sideIndex % 2 == 0) ? parts[0] : parts[1];
        case 3:
            return (sideIndex == 0) ? parts[0] : ((sideIndex == 2) ? parts[2] : parts[1]);
        default: return parts[sideIndex];
    }
}

private int sideValue(ComputedStyle style, string value, int containingWidth, int sideIndex)
{
    bool isAuto;
    return resolveSide(style, value, containingWidth, sideIndex, isAuto);
}

/// Clamp a CONTENT height and return the resulting border-box height. For
/// content-box sizing `min-height`/`max-height` apply to the content box, so
/// padding and borders are added AFTER clamping (CSS 10.4). For border-box
/// sizing they apply to the border box, so the sum is clamped instead.
private int contentBoxHeight(Element element, int contentHeight)
{
    const padBorder = element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;
    if (element.style.boxSizing == "border-box")
        return clampMinMaxHeight(element, max(0, contentHeight + padBorder));
    return clampMinMaxHeight(element, max(0, contentHeight)) + padBorder;
}

unittest
{
    // Box model: units, keyword values, auto margins and content-box min/max.
    auto flow = FlowContext();
    flow.x = 0;
    flow.y = 0;
    flow.width = 400;
    flow.height = 300;

    auto block = new Element("div");
    block.style.display = "block";
    block.style.width = "100px";
    block.style.margin = "0 auto";
    layoutBlock(block, flow, 400, null);
    assert(block.box.marginLeftAuto && block.box.marginRightAuto,
        "auto margins must be recorded on the box");
    assert(block.box.marginLeft == 150 && block.box.marginRight == 150,
        "`margin: 0 auto` must center a definite-width block");
    assert(block.box.x == 150, "the centered block must sit at the leftover offset");

    // One-sided auto: the whole leftover goes to that side.
    auto side = new Element("div");
    side.style.display = "block";
    side.style.width = "100px";
    side.style.marginLeft = "auto";
    layoutBlock(side, flow, 400, null);
    assert(side.box.marginLeft == 300 && side.box.marginRight == 0,
        "a one-sided auto margin absorbs the leftover space");

    // em resolves against THIS element's font size, not a fixed 16px.
    auto em = new Element("div");
    em.style.display = "block";
    em.style.fontSizePx = 20;
    em.style.padding = "1em";
    layoutBlock(em, flow, 400, null);
    assert(em.box.paddingTop == 20 && em.box.paddingLeft == 20,
        "em must resolve against the element's own font size");

    // vh resolves against the viewport height.
    auto vh = new Element("div");
    vh.style.display = "block";
    vh.style.viewportHeight = 600;
    vh.style.marginTop = "10vh";
    layoutBlock(vh, flow, 400, null);
    assert(vh.box.marginTop == 60, "vh must resolve against the viewport height");

    // Percentage vertical margins resolve against the containing block WIDTH.
    auto pc = new Element("div");
    pc.style.display = "block";
    pc.style.marginTop = "10%";
    layoutBlock(pc, flow, 400, null);
    assert(pc.box.marginTop == 40, "percentage margins use the containing width");

    // Negative margins stay negative; keyword values become 0, never -1px.
    auto neg = new Element("div");
    neg.style.display = "block";
    neg.style.marginTop = "-10px";
    neg.style.border = "none";
    layoutBlock(neg, flow, 400, null);
    assert(neg.box.marginTop == -10, "a negative margin must be preserved");
    assert(neg.box.borderTop == 0 && neg.box.borderLeft == 0,
        "`border: none` must resolve to 0px, not a negative border");

    // content-box: min/max clamp the CONTENT box, so padding still applies.
    auto cb = new Element("div");
    cb.style.display = "block";
    cb.style.width = "100px";
    cb.style.padding = "10px";
    cb.style.maxWidth = "80px";
    layoutBlock(cb, flow, 400, null);
    assert(cb.box.width == 100,
        "content-box max-width must clamp the content, not the border box");

    // border-box: min/max clamp the border box itself.
    auto bb = new Element("div");
    bb.style.display = "block";
    bb.style.boxSizing = "border-box";
    bb.style.width = "100px";
    bb.style.padding = "10px";
    bb.style.maxWidth = "80px";
    layoutBlock(bb, flow, 400, null);
    assert(bb.box.width == 80, "border-box max-width must clamp the border box");

    // min-width still wins over a smaller declared width.
    auto mn = new Element("div");
    mn.style.display = "block";
    mn.style.width = "50px";
    mn.style.minWidth = "120px";
    layoutBlock(mn, flow, 400, null);
    assert(mn.box.width == 120, "min-width must win over a smaller width");
}

/// Collapse two adjacent vertical margins per CSS:
/// two positive margins take the max; two negative margins take the most
/// negative; one positive and one negative sum to their (possibly negative)
/// result.
private int collapseVerticalMargins(int a, int b)
{
    if (a >= 0 && b >= 0) return max(a, b);
    if (a <= 0 && b <= 0) return min(a, b);
    return a + b;
}

/// Resolve `line-height` into a px line box height. An explicit px value wins;
/// a percentage resolves against THIS element's font size (not the containing
/// block); otherwise the fallback is font-size + 8px breathing room.
private int resolveLineHeight(Element element, int pixelSize)
{
    const explicitLineH = element.style.pxLength(element.style.lineHeight);
    if (explicitLineH > 0) return explicitLineH;
    const percent = element.style.percentValue(element.style.lineHeight);
    if (percent >= 0) return max(1, (pixelSize * percent) / 100);
    return pixelSize + 8;
}

/// Layout a block-level element and its children in normal flow.
/// True when a block's own top margin collapses with its first in-flow child's:
/// nothing separates them (no top border or padding), the block is static and
/// it does not establish a block formatting context (CSS 8.3.1).
private static bool canCollapseWithChild(Element element)
{
    auto style = element.style;
    if (element.box.borderTop != 0 || element.box.paddingTop != 0) return false;
    if (style.position != "static") return false;
    if (style.floatStyle != "none") return false;
    if (style.overflow.length && style.overflow != "visible") return false;
    switch (style.display)
    {
        case "block":
        case "list-item":
        case "table":
            return true;
        default:
            return false; // flex/grid/inline-block/table-cell establish a BFC
    }
}

/// The first child element that participates in normal flow, or null. Leading
/// whitespace text nodes are transparent for collapsing, so they are skipped.
private static Element firstInFlowChild(Element element)
{
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto ps = ce.style.position;
        if (ps == "absolute" || ps == "fixed") continue;
        if (ce.style.display == "none") continue;
        if (ce.style.floatStyle != "none") continue;
        return ce;
    }
    return null;
}

/// True when a box's bottom margin collapses with its last in-flow child's:
/// no bottom border or padding, static positioning, no formatting context
/// (CSS 8.3.1).
private static bool canCollapseBottom(Element element)
{
    auto style = element.style;
    if (element.box.borderBottom != 0 || element.box.paddingBottom != 0) return false;
    if (style.position != "static") return false;
    if (style.floatStyle != "none") return false;
    if (style.overflow.length && style.overflow != "visible") return false;
    switch (style.display)
    {
        case "block":
        case "list-item":
        case "table":
            return true;
        default:
            return false;
    }
}

/// The last child element that participates in normal flow, or null.
private static Element lastInFlowChild(Element element)
{
    Element found = null;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto ps = ce.style.position;
        if (ps == "absolute" || ps == "fixed") continue;
        if (ce.style.display == "none") continue;
        if (ce.style.floatStyle != "none") continue;
        found = ce;
    }
    return found;
}

private void layoutBlock(Element element, ref FlowContext flow, int containingWidth, Element positionedAncestor)
{
    auto style = element.style;

    if (style.display == "none") { element.box.height = 0; return; }

    resolveBoxMetrics(element, containingWidth);
    // `ComputedStyle` is a struct, so writing through the `style` alias above
    // would edit a COPY and the containing block would stay 0 — which made
    // percentage heights and percentage min/max-height resolve against nothing.
    element.style.containingWidth = containingWidth;
    element.style.containingHeight = flow.height;

    // Absolute positioning: removed from flow, relative to positioned ancestor.
    if (style.position == "absolute")
    {
        layoutAbsolute(element, containingWidth, positionedAncestor);
        return;
    }

    // Fixed positioning: removed from flow, relative to the viewport (0,0).
    // Ignores positioned ancestors entirely and never moves on scroll.
    if (style.position == "fixed")
    {
        layoutFixed(element, containingWidth, style.viewportWidth, style.viewportHeight);
        return;
    }

    // `clear` moves a block below the floats it clears (CSS 9.5.2): the flow
    // cursor advances past the bottom of every active float on that side.
    if (style.clear == "left" || style.clear == "right" || style.clear == "both")
    {
        int below = flow.y;
        foreach (f; flow.floats)
        {
            if (style.clear == "left" && f.right) continue;
            if (style.clear == "right" && !f.right) continue;
            below = max(below, f.y + f.height);
        }
        if (below > flow.y) flow.y = below;
    }

    int width = resolveWidth(element, containingWidth);
    element.box.width = width;

    int height = resolveHeight(element);
    element.box.height = max(0, height);

    if (style.floatStyle != "none")
    {
        if (style.floatStyle == "left")
            element.box.x = flow.x;
        else
            element.box.x = flow.x + flow.width - width;
        element.box.y = flow.y;
        flow.floatLeft = max(flow.floatLeft, element.box.x + width);
        // Register the float rect so following inline content wraps around it.
        FloatRect fr;
        fr.x = element.box.x;
        fr.y = element.box.y;
        fr.width = width;
        fr.height = element.box.height;
        fr.right = style.floatStyle == "right";
        flow.floats ~= fr;
        flow.y += element.box.height + element.box.marginBottom;
        layoutChildren(element, flow, element);
        return;
    }

    bool collapseIntoChild = false;
    int effectiveTop = element.box.marginTop;
    if (flow.suppressTopMargin)
    {
        // This element's margin-top was already collapsed into its parent, so
        // it must not add space again here (CSS 8.3.1).
        flow.suppressTopMargin = false;
        effectiveTop = 0;
    }
    else if (canCollapseWithChild(element))
    {
        // A parent's top margin collapses with its first in-flow child's when
        // nothing separates them: the child's margin then moves the PARENT down
        // instead of adding space inside it.
        auto fc = firstInFlowChild(element);
        if (fc !is null)
        {
            bool childTopAuto;
            const childTop = resolveSide(fc.style,
                fc.style.marginTop.length ? fc.style.marginTop : fc.style.margin,
                containingWidth, 0, childTopAuto);
            if (childTop > 0)
            {
                effectiveTop = collapseVerticalMargins(element.box.marginTop, childTop);
                collapseIntoChild = true;
            }
        }
    }

    // Margin collapsing with the previous sibling's bottom margin. A negative
    // margin-top pulls the box up (possibly overlapping the previous box); a
    // negative margin-bottom pulls following content up by the same amount.
    element.box.y = flow.y + effectiveTop;
    if (flow.hasPrevBlock)
    {
        const collapsed = collapseVerticalMargins(flow.prevBottomMargin, effectiveTop);
        element.box.y = flow.y + (collapsed - flow.prevBottomMargin);
    }

    element.box.x = flow.x + element.box.marginLeft;
    element.box.width = width;

    // `margin: auto` on a block with a definite width absorbs the leftover
    // space — this is how `margin: 0 auto` centers content (CSS 10.3.3).
    if ((element.box.marginLeftAuto || element.box.marginRightAuto) &&
        style.width.length && style.resolveLength(style.width, containingWidth) >= 0)
    {
        const leftover = max(0, containingWidth - width -
            element.box.marginLeft - element.box.marginRight);
        if (element.box.marginLeftAuto && element.box.marginRightAuto)
        {
            element.box.marginLeft = leftover / 2;
            element.box.marginRight = leftover - leftover / 2;
        }
        else if (element.box.marginLeftAuto)
            element.box.marginLeft = leftover;
        else
            element.box.marginRight = leftover;
        element.box.x = flow.x + element.box.marginLeft;
    }

    // `position: relative` offsets the box — and everything inside it — from
    // its normal-flow position, without moving any other box (CSS 9.4.3). The
    // flow advance below therefore uses the in-flow top, not the offset one.
    const int layoutTop = element.box.y;
    if (style.position == "relative")
    {
        const relLeft = style.resolveLength(style.left, containingWidth);
        const relRight = style.resolveLength(style.right, containingWidth);
        if (relLeft >= 0)
            element.box.x += relLeft;
        else if (relRight >= 0)
            element.box.x -= relRight;
        const relTop = style.resolveLength(style.top, flow.height);
        const relBottom = style.resolveLength(style.bottom, flow.height);
        if (relTop >= 0)
            element.box.y += relTop;
        else if (relBottom >= 0)
            element.box.y -= relBottom;
    }

    // A DEFINITE height is known before the children are laid out, so publish it
    // now: a child's percentage height resolves against this box's content
    // height, and `box.height` is otherwise only assigned after the children
    // (from the content) — which would leave the child resolving against 0.
    if (height >= 0)
        element.box.height = max(0, height);

    // Layout children in a nested flow constrained by our content box.
    auto childFlow = FlowContext();
    childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    childFlow.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    childFlow.width = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);
    // A child's percentage height resolves against a DEFINITE containing-block
    // height (CSS 10.5) — this box's own content height, which `box.height`
    // holds — and only falls back to the flow height when this box's height is
    // auto. (`box.height` is assigned above, before any child flow is built.)
    childFlow.height = height >= 0 ? element.box.height : flow.height;
    // The first child's margin-top was already collapsed into this box.
    childFlow.suppressTopMargin = collapseIntoChild;
    childFlow.lineEnd = childFlow.x + childFlow.width;

    layoutChildren(element, childFlow, element);

    // Compute this block's height from explicit style or its content.
    int finalHeight = height;
    if (height < 0)
    {
        auto innerBottom = max(childFlow.y, childFlow.inlineBottomAbs);
        innerBottom += element.box.paddingBottom + element.box.borderBottom;
        finalHeight = max(0, innerBottom - element.box.y);
    }
    // `aspect-ratio` with an auto height: the box height follows the used width
    // (CSS Sizing 4). A real page's landscape figure declares
    // width: min(100%, 35.7rem) with aspect-ratio: 1200 / 520; without this it
    // stayed 444x0, its artwork drew nothing, and the column collapsed with it.
    {
        const ratio = parseAspectRatio(element.style.aspectRatio);
        if (ratio > 0.0 && element.box.width > 0 &&
            element.style.resolveLength(element.style.height,
                element.style.containingHeight) < 0)
            finalHeight = cast(int) (element.box.width / ratio);
    }
    finalHeight = clampMinMaxHeight(element, finalHeight);
    element.box.height = finalHeight;

    // A parent with an auto height collapses its bottom margin with its last
    // in-flow child's, so that margin escapes to the parent's bottom edge
    // (CSS 8.3.1). The child's margin is already inside the measured content
    // height, so move it out of the box and fold it into this box's own bottom
    // margin — the flow advance below then keeps following content in place.
    if (height < 0 && canCollapseBottom(element))
    {
        auto lc = lastInFlowChild(element);
        if (lc !is null)
        {
            bool childBottomAuto;
            const childBottom = resolveSide(lc.style,
                lc.style.marginBottom.length ? lc.style.marginBottom : lc.style.margin,
                containingWidth, 2, childBottomAuto);
            if (childBottom > 0)
            {
                element.box.height = max(0, finalHeight - childBottom);
                element.box.marginBottom = collapseVerticalMargins(element.box.marginBottom,
                    childBottom);
            }
        }
    }

    // Positioned (absolute/fixed) children are laid out now that this box's
    // size is known, so their percentage top/bottom/left/right resolve against
    // the final containing block rather than a not-yet-measured one.
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto ps = ce.style.position;
        if (ps != "absolute" && ps != "fixed") continue;
        if (ps == "fixed")
            layoutFixed(ce, width, style.viewportWidth, style.viewportHeight);
        else
            layoutAbsolute(ce, width, (style.position != "static") ? element : positionedAncestor);
    }

    // Advance the flow past this box (including bottom margin). A negative
    // margin-bottom pulls following content up by the same amount (may overlap).
    flow.prevBottomMargin = element.box.marginBottom;
    flow.hasPrevBlock = true;
    const bottom = layoutTop + element.box.height + element.box.marginBottom;
    if (bottom > flow.y) flow.y = bottom;
}

/// Lay out the DIRECT text-node and inline-element children of a block on a
/// shared inline line, advancing a horizontal cursor and wrapping at the
/// block's content width using real shaped measurement. Whitespace-only text
/// nodes between block elements are skipped.
/// Height of a shaped run's glyphs, used for CSS half-leading inside a taller
/// line box. Falls back to the font size when the shaper reports no height.
private int fontHeightOf(T)(T layout, int pixelSize)
{
    try
    {
        const h = cast(int) layout.measuredSize().height;
        if (h > 0) return h;
    }
    catch (Exception)
    {
    }
    return pixelSize;
}

private void layoutDirectText(Element element, ref FlowContext flow,
    size_t from = 0, size_t to = size_t.max)
{
    const pixelSize = element.style.fontSizePx > 0 ? element.style.fontSizePx : 16;
    // line-height: an explicit px value sizes the line boxes; a percentage
    // resolves against THIS element's font-size; otherwise fall back to
    // font-size + 8px breathing room.
    const lineH = resolveLineHeight(element, pixelSize);
    // `white-space: nowrap` (and `pre`) never wrap a line: measure without a
    // wrap width so a narrow box cannot split the text into stray fragments.
    const bool noWrapText = element.style.whiteSpace == "nowrap" ||
        element.style.whiteSpace == "pre";
    int cursorX = flow.x;
    int cursorY = flow.y;
    int lineIndex = flow.lineCount;
    const int baseLine = flow.lineCount;
    int maxBottom = 0;

    // Track the horizontal extent of each line laid out here (relative to
    // flow.lineCount, matching TextNode.lineIndex) so a later text-align pass
    // can shift a finished line into the block's content width.
    int[] lineStartX;
    int[] lineEndX;

    void noteLine(int lineIdx, int startX, int endX)
    {
        // Store relative to the entry line count so later indexing stays
        // 0-based regardless of the absolute line this block started at.
        const int rel = lineIdx - baseLine;
        while (lineStartX.length <= rel)
        {
            lineStartX ~= int.max;
            lineEndX ~= int.min;
        }
        lineStartX[rel] = min(lineStartX[rel], startX);
        lineEndX[rel] = max(lineEndX[rel], endX);
    }

    void wrapTo(int leftEdge, int rightEdge)
    {
        if (cursorX < leftEdge) cursorX = leftEdge;
        if (cursorX > rightEdge && cursorX > leftEdge)
        {
            cursorX = leftEdge;
            cursorY += lineH;
            lineIndex++;
        }
    }

    // Inline elements placed during this pass, with the line they started on,
    // so the text-align shift can target each one precisely.
    Element[] placedElements;
    int[] placedElementLines;

    foreach (childIndex, child; element.children)
    {
        if (childIndex < from || (to != size_t.max && childIndex >= to)) continue;
        auto text = cast(TextNode) child;
        if (text !is null)
        {
            if (text.data.strip().length == 0)
            {
                // Preformatted text (`<pre>` / white-space: pre|pre-line|
                // pre-wrap) preserves newlines as real line breaks (e.g. the
                // "Find me online." link list), instead of collapsing them to
                // a space.
                const bool preformatted = element.tag == "pre" ||
                    element.style.whiteSpace == "pre" ||
                    element.style.whiteSpace == "pre-wrap" ||
                    element.style.whiteSpace == "pre-line";
                if (preformatted && indexOf(text.data, "\n") >= 0)
                {
                    cursorY += lineH;
                    lineIndex++;
                    cursorX = flow.lineLeft(cursorY, lineH);
                    maxBottom = max(maxBottom, cursorY + lineH);
                    text.layoutX = 0; text.layoutY = 0; text.layoutWidth = 0; text.lineIndex = 0;
                    continue;
                }
                // Whitespace-only node: collapse to a single space between
                // inline runs, but ignore if it's the only content on a line
                // (i.e. a newline between block elements).
                if (cursorX > flow.x) cursorX += pixelSize / 2;
                text.layoutX = 0; text.layoutY = 0; text.layoutWidth = 0; text.lineIndex = 0;
                continue;
            }
            const int leftEdge = flow.lineLeft(cursorY, lineH);
            const int rightEdge = flow.lineRight(cursorY, lineH);
            const int innerW = max(0, rightEdge - cursorX);
            const string runText = collapsibleText(element, text);
            text.paintText = runText;
            auto layout = shapeText(runText, pixelSize,
                noWrapText ? 1_000_000 : innerW);
            if (layout !is null && layout.lines.length > 0)
            {
                // The run may wrap internally to multiple lines. Advance the
                // cursor to the END of the run's last line so following inline
                // content continues correctly instead of overlapping.
                wrapTo(leftEdge, rightEdge);
                text.layoutX = cursorX;
                // CSS half-leading: when the line box is taller than the run
                // (a generous line-height, a stretched flex item, a 48px dock
                // row), the glyphs are centred in the line, not pinned to its
                // top. Painting at the top made every such label sit high —
                // the visible "labels detached from their icons".
                const int runH = fontHeightOf(layout, pixelSize);
                text.layoutY = cursorY + max(0, (lineH - runH) / 2);
                text.layoutWidth = cast(int) layout.width;
                text.lineIndex = lineIndex;
                const nLines = cast(int) layout.lines.length;
                if (nLines > 1)
                {
                    // Record each wrapped line's own width so the text-align
                    // shift can center/right-align every line individually.
                    for (int li = 0; li < nLines; li++)
                    {
                        const int llx = (li == 0) ? cursorX : leftEdge;
                        const int lw = cast(int) layout.lines[li].width;
                        noteLine(lineIndex + li, llx, llx + lw);
                        // The wrapping inline box this run belongs to is
                        // fragmented per line (CSS 9.4.2), so its background and
                        // border follow every line it covers rather than just
                        // the first.
                        auto inlineParent = cast(Element) text.parent;
                        if (inlineParent !is null && inlineParent.style.display == "inline")
                            inlineParent.inlineFragments ~=
                                InlineFragment(llx, cursorY + li * lineH, lw, lineH);
                    }
                    // More than one line: consume the extra lines, then place
                    // the cursor at the start of the next line (the run's last
                    // line began at the left edge).
                    cursorY += (nLines - 1) * lineH;
                    lineIndex += nLines - 1;
                    cursorX = leftEdge;
                }
                else
                {
                    noteLine(lineIndex, cursorX, cursorX + cast(int) layout.width);
                    auto inlineParent = cast(Element) text.parent;
                    if (inlineParent !is null && inlineParent.style.display == "inline")
                        inlineParent.inlineFragments ~= InlineFragment(
                            cursorX, cursorY, cast(int) layout.width, lineH);
                    cursorX += cast(int) layout.width;
                }
                maxBottom = max(maxBottom, cursorY + lineH);
                continue;
            }
            // Fallback: no shaped layout.
            const int textWidth = cast(int)(runText.length * 8);
            wrapTo(leftEdge, rightEdge);
            text.layoutX = cursorX;
            // Same half-leading rule for the fallback (unshaped) case.
            text.layoutY = cursorY + max(0, (lineH - pixelSize) / 2);
            text.layoutWidth = textWidth;
            text.lineIndex = lineIndex;
            noteLine(lineIndex, cursorX, cursorX + textWidth);
            cursorX += textWidth;
            maxBottom = max(maxBottom, cursorY + lineH);
            continue;
        }
        auto ce = cast(Element) child;
        if (ce !is null && (ce.style.display == "inline" || ce.style.display == "inline-block"))
        {
            // Positioned inline elements are removed from flow and positioned
            // independently (by layoutBlock via layoutChildren); never lay them
            // out on the inline cursor.
            if (ce.style.position == "absolute" || ce.style.position == "fixed")
                continue;
            // `<br>` forces a line break on the inline cursor.
            if (ce.tag == "br")
            {
                cursorY += lineH;
                lineIndex++;
                cursorX = flow.lineLeft(cursorY, lineH);
                ce.box.x = cursorX;
                ce.box.y = cursorY;
                ce.box.width = 0;
                ce.box.height = lineH;
                maxBottom = max(maxBottom, cursorY + lineH);
                continue;
            }
            const int leftEdge = flow.lineLeft(cursorY, lineH);
            const int rightEdge = flow.lineRight(cursorY, lineH);
            // Measure the inline element's text content.
            int cw;
            int ceLines = 1;
            // Advance to the next line *before* shaping this run. Shaping against
            // a cursor that the previous inline content had already pushed past
            // the line's right edge gave the run a far too narrow width, so an
            // inline element wrapped mid-content (a URL broke after a few
            // characters, and the article date fell onto a second line) even
            // though the line had room for it.
            wrapTo(leftEdge, rightEdge);
            if (ce.style.display == "inline-block")
                cw = resolveWidth(ce, flow.width);
            else
            {
                auto lay = shapeText(ce.textContent(), pixelSize,
                    noWrapText ? 1_000_000 : max(0, rightEdge - cursorX));
                if (lay !is null && lay.lines.length > 0)
                {
                    cw = cast(int) lay.width;
                    ceLines = cast(int) lay.lines.length;
                }
                else
                    cw = cast(int)(ce.textContent().length * 8);
            }
            wrapTo(leftEdge, rightEdge);
            // The inline path must resolve its box metrics too, or an
            // inline-level box's padding/margins are all zero here.
            resolveBoxMetrics(ce, flow.width);
            // Inline-level boxes honour their horizontal margin and padding: the
            // box starts after margin-left, and the content that follows starts
            // after the box's right padding/border/margin (CSS 8.3/8.4 for
            // inline-level boxes). Without this an inline-block icon's margins
            // and padding consumed no line space at all.
            const bool inlineBox = ce.style.display == "inline-block";
            const int leadIn = inlineBox ? ce.box.marginLeft : 0;
            const int leadOut = inlineBox
                ? ce.box.marginRight + ce.box.borderLeft + ce.box.borderRight +
                    ce.box.paddingLeft + ce.box.paddingRight : 0;
            ce.box.x = cursorX + leadIn;
            ce.box.y = cursorY;
            ce.box.width = cw;
            ce.box.height = ceLines * lineH;
            // An inline-block with an explicit height uses that height (like a
            // real box); otherwise it is a content-sized line box.
            if (ce.style.display == "inline-block")
            {
                ce.style.containingHeight = flow.height;
                const ih = resolveHeight(ce);
                if (ih >= 0) ce.box.height = ih;
            }
            // Inline vertical alignment. The line box spans
            // `cursorY .. cursorY + lineH`; `baseline` (the default) puts the
            // box's bottom edge on the text baseline (cursorY + ascent, with
            // ascent ~= font-size), the other keywords position it against the
            // line box.
            if (ce.style.display == "inline-block")
            {
                const int baseline = cursorY + pixelSize;
                switch (ce.style.verticalAlign)
                {
                    case "top", "text-top":
                        ce.box.y = cursorY;
                        break;
                    case "bottom", "text-bottom":
                        ce.box.y = cursorY + lineH - ce.box.height;
                        break;
                    case "middle":
                        ce.box.y = cursorY + (lineH - ce.box.height) / 2;
                        break;
                    default: // baseline (and any unit length, approximated)
                        ce.box.y = baseline - ce.box.height;
                        break;
                }
            }
            noteLine(lineIndex, cursorX, cursorX + cw);
            placedElements ~= ce;
            placedElementLines ~= lineIndex;
            // Advance the cursor past the inline element. If its content
            // wrapped internally, the next run continues on the next line.
            if (ceLines > 1)
            {
                cursorY += (ceLines - 1) * lineH;
                lineIndex += ceLines - 1;
                cursorX = leftEdge;
            }
            else
            {
                cursorX += cw + leadIn + leadOut;
            }
            // Layout the inline element's own children (text inside <b>, <i>, ...).
            auto sub = FlowContext();
            // Text inside an inline-block starts after its own left padding and
            // border, not on the box's outer edge.
            sub.x = ce.box.x + (inlineBox ? ce.box.borderLeft + ce.box.paddingLeft : 0);
            sub.y = ce.box.y;            // ... and its top line
            sub.width = max(0, flow.width -
                (inlineBox ? ce.box.borderLeft + ce.box.borderRight +
                    ce.box.paddingLeft + ce.box.paddingRight : 0));
            sub.height = flow.height;
            sub.lineEnd = rightEdge;
            sub.lineCount = lineIndex;
            layoutDirectText(ce, sub);
            // Merge back the sub-flow's text bottom.
            maxBottom = max(maxBottom, cursorY + lineH);
            lineIndex = max(lineIndex, sub.lineCount);
            continue;
        }
        // Any other direct child (block) was laid out by layoutChildren.
    }
    if (maxBottom > 0)
    {
        flow.contentBottom = max(flow.contentBottom, maxBottom - flow.y);
        flow.lineCount = max(flow.lineCount, lineIndex + 1);
        if (maxBottom > flow.inlineBottomAbs) flow.inlineBottomAbs = maxBottom;
    }

    // text-align: center/right — shift each finished line so it sits inside
    // the block's content width. (justify is not implemented; left is the
    // default and needs no shift.)
    const textAlign = element.style.textAlign;
    if ((textAlign == "center" || textAlign == "right") && lineStartX.length)
    {
        const int innerLeft = flow.x;
        const int innerRight = flow.lineEnd;
        const int availW = max(0, innerRight - innerLeft);
        int[] shifts;
        foreach (idx; 0 .. lineStartX.length)
        {
            int shift = 0;
            if (lineEndX[idx] > lineStartX[idx])
            {
                const int lineW = lineEndX[idx] - lineStartX[idx];
                if (textAlign == "center")
                    shift = (availW - lineW) / 2;
                else
                    shift = availW - lineW;
                if (shift < 0) shift = 0;
            }
            shifts ~= shift;
        }
        foreach (idx, shift; shifts)
        {
            if (shift <= 0) continue;
            // The recorded line indices are relative to baseLine, while
            // TextNode.lineIndex is absolute — map between them.
            const int absLine = baseLine + cast(int) idx;
            // Direct text runs on this line.
            foreach (child; element.children)
            {
                auto text = cast(TextNode) child;
                if (text !is null)
                {
                    if (text.lineIndex == absLine && text.layoutWidth > 0)
                        text.layoutX += shift;
                    continue;
                }
            }
            // Inline elements on this line (and their nested inline text).
            foreach (i, ce; placedElements)
            {
                if (placedElementLines[i] == baseLine + idx)
                    shiftSubtree(ce, shift);
            }
        }
    }
}

/// True when an inset (`top`/`left`/`right`/`bottom`) was actually declared. The
/// sign cannot be used: insets may legitimately be negative (`right: -0.9rem`
/// hangs an ornament off the right edge), which `>= 0` would read as unset.
private bool insetGiven(string value)
{
    const s = value.strip().toLower();
    return s.length > 0 && s != "auto";
}

/// Shift an inline element and all its descendant inline text runs by `shift`
/// px. Used by the text-align pass so a moved inline box carries its text.
/// Shift an element's whole box tree — every descendant element box and text
/// run — by `shift` px. Used when a flex item is repositioned after its contents
/// were laid out: the inline-only helper below left block children behind, so a
/// real nav's links overlapped their neighbour.
private void shiftBoxTree(Element ce, int shift)
{
    if (shift == 0) return;
    ce.box.x += shift;
    foreach (child; ce.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            if (t.layoutWidth > 0) t.layoutX += shift;
            continue;
        }
        auto e2 = cast(Element) child;
        if (e2 is null) continue;
        shiftBoxTree(e2, shift);
    }
}

private void shiftSubtree(Element ce, int shift)
{
    if (shift == 0) return;
    ce.box.x += shift;
    foreach (child; ce.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            if (t.layoutWidth > 0) t.layoutX += shift;
            continue;
        }
        auto e2 = cast(Element) child;
        if (e2 !is null) shiftSubtree(e2, shift);
    }
}

private int clampMinMaxWidth(Element element, int width)
{
    auto style = element.style;
    auto minW = style.resolveLength(style.minWidth, style.containingWidth);
    auto maxW = style.resolveLength(style.maxWidth, style.containingWidth);
    if (minW >= 0) width = max(width, minW);
    if (maxW >= 0) width = min(width, maxW);
    return width;
}

private int clampMinMaxHeight(Element element, int height)
{
    auto style = element.style;
    auto minH = style.resolveLength(style.minHeight, style.containingHeight);
    auto maxH = style.resolveLength(style.maxHeight, style.containingHeight);
    if (minH >= 0) height = max(height, minH);
    if (maxH >= 0) height = min(height, maxH);
    return height;
}

private int resolveWidth(Element element, int containingWidth)
{
    auto style = element.style;
    auto widthPx = style.resolveLength(style.width, containingWidth);
    int width;
    if (widthPx >= 0)
    {
        // min/max apply to the CONTENT box for content-box sizing and to the
        // border box for border-box sizing (CSS 10.4). Clamping after padding
        // was added made `width:100px; padding:10px; max-width:80px` wrong.
        const padBorder = element.box.paddingLeft + element.box.paddingRight +
            element.box.borderLeft + element.box.borderRight;
        if (style.boxSizing == "border-box")
            return clampMinMaxWidth(element, max(0, widthPx));
        return clampMinMaxWidth(element, max(0, widthPx)) + padBorder;
    }
    else if (style.display == "inline-block")
    {
        // An inline-block with a decoded image sizes to the image's intrinsic
        // width; otherwise shrink-to-fit its content — measure the widest
        // unwrapped text line instead of a fixed placeholder. A fixed 16px box
        // truncated every `<a style="display:inline-block">` to one glyph.
        auto img = cast(RgbaImage) element.image;
        if (img !is null)
            width = img.width();
        else
        {
            const pixelSize = style.fontSizePx > 0 ? style.fontSizePx : 16;
            const content = element.textContent();
            if (content.strip().length)
            {
                auto lay = shapeText(content, pixelSize, 0);
                width = lay !is null ? cast(int) lay.width
                    : cast(int)(content.length * 8);
            }
            else
                width = 16;
        }
    }
    else
        width = containingWidth - element.box.paddingLeft - element.box.paddingRight -
            element.box.borderLeft - element.box.borderRight - element.box.marginLeft -
            element.box.marginRight;
    return clampMinMaxWidth(element, max(0, width));
}

/// The text as it must be shaped and painted. For every `white-space` other than
/// `pre`/`pre-wrap`/`pre-line`, runs of whitespace collapse to a single space and
/// leading/trailing whitespace is dropped (CSS Text 3). Markup indentation is not
/// content: without this the newlines and tabs preceding a block's text were
/// shaped as real advance, so a real page's paragraph began ~141px into its own
/// box and gained a blank first line.
private string collapsibleText(Element element, TextNode node)
{
    const preserved = element.tag == "pre" ||
        element.style.whiteSpace == "pre" ||
        element.style.whiteSpace == "pre-wrap" ||
        element.style.whiteSpace == "pre-line";
    if (preserved) return expandTabs(node.data);
    string result;
    bool pendingSpace = false;
    bool started = false;
    foreach (char c; node.data)
    {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f')
        {
            if (started) pendingSpace = true;
            continue;
        }
        if (pendingSpace)
        {
            result ~= ' ';
            pendingSpace = false;
        }
        result ~= c;
        started = true;
    }
    // Keep one trailing space: CSS keeps a run's trailing whitespace so that
    // following inline content ("Date added: <time>…</time>") still gets its
    // separating space. At the end of a block it is not painted, so it is safe.
    if (pendingSpace) result ~= ' ';
    return result;
}

/// Parse `aspect-ratio: <w> / <h>` (or a bare number) into width/height. Returns
/// 0 when the value is unusable (`auto`, empty, or a zero/degenerate ratio).
private double parseAspectRatio(string value)
{
    import auroraweb.dom : cssDouble;
    import std.string : indexOf;
    const s = value.strip();
    if (s.length == 0 || s == "auto") return 0.0;
    const slash = indexOf(s, "/");
    if (slash < 0)
    {
        const v = cssDouble(s);
        return v > 0.0 ? v : 0.0;
    }
    const left = s[0 .. slash].strip();
    const right = s[slash + 1 .. $].strip();
    if (left.length == 0 || right.length == 0) return 0.0;
    const w = cssDouble(left);
    const h = cssDouble(right);
    if (w <= 0.0 || h <= 0.0) return 0.0;
    return w / h;
}

private int resolveHeight(Element element)
{
    auto style = element.style;
    auto heightPx = style.resolveLength(style.height, style.containingHeight);
    if (heightPx >= 0)
    {
        const padBorder = element.box.paddingTop + element.box.paddingBottom +
            element.box.borderTop + element.box.borderBottom;
        if (style.boxSizing == "border-box")
            return clampMinMaxHeight(element, max(0, heightPx));
        // content-box: clamp the content, then add padding+border (CSS 10.4).
        return clampMinMaxHeight(element, max(0, heightPx)) + padBorder;
    }
    // `aspect-ratio` (CSS Sizing 4): with a definite width, an auto height is
    // width / ratio. A real page's landscape figure declares
    // `aspect-ratio: 1200 / 520` (with width: min(100%, 35.7rem)); without this
    // it measured 444x0, so the whole illustration drew nothing and the column
    // above it collapsed.
    {
        const ratio = parseAspectRatio(style.aspectRatio);
        if (ratio > 0.0 && element.box.width > 0)
        {
            const derived = cast(int) (element.box.width / ratio);
            return clampMinMaxHeight(element, max(0, derived));
        }
    }
    // A replaced element with a decoded image and no explicit height uses the
    // image's intrinsic ratio: height = used width * intrinsicHeight /
    // intrinsicWidth (CSS 10.6.2). Limiting this to `inline-block` left a
    // block-level <img> with `height: auto` at ZERO height — a real page's
    // 1920x1080 lead photo laid out as a 735x0 sliver, so the image was there
    // but invisible. -1 means "auto — caller measures content".
    auto img = cast(RgbaImage) element.image;
    if (img !is null && img.width() > 0 && img.height() > 0)
    {
        const used = element.box.width;
        const scaled = used > 0
            ? cast(int) ((cast(long) used * img.height()) / img.width())
            : img.height();
        return clampMinMaxHeight(element, max(0, scaled));
    }
    return -1; // auto — caller measures content.
}

private void layoutAbsolute(Element element, int containingWidth, Element positionedAncestor)
{
    auto style = element.style;
    // Determine the containing block: nearest positioned ancestor or root.
    Element cb = positionedAncestor;
    int cbX = 0, cbY = 0, cbW = containingWidth, cbH = style.containingHeight;

    if (cb !is null)
    {
        cbX = cb.box.x + cb.box.paddingLeft + cb.box.borderLeft;
        cbY = cb.box.y + cb.box.paddingTop + cb.box.borderTop;
        cbW = cb.box.width - cb.box.paddingLeft - cb.box.paddingRight - cb.box.borderLeft - cb.box.borderRight;
        cbH = cb.box.height;
    }

    const w = resolveWidth(element, cbW);
    const h = style.resolveLength(style.height, cbH);
    element.box.width = w;
    element.box.height = h >= 0 ? clampMinMaxHeight(element, max(0, h)) : 0;

    const topV = style.resolveLength(style.top, cbH);
    const leftV = style.resolveLength(style.left, cbW);
    const rightV = style.resolveLength(style.right, cbW);
    const bottomV = style.resolveLength(style.bottom, cbH);

    // "Given" must be decided from the declaration, not from the sign: insets may
    // legitimately be NEGATIVE (`right: -0.9rem` is how a real page hangs a
    // decorative ornament off the right edge). Treating `>= 0` as the given test
    // made a negative inset look unset, so such an element fell back to the left
    // edge instead of the right one.
    bool insetGiven(string value)
    {
        const s = value.strip().toLower();
        return s.length > 0 && s != "auto";
    }
    const bool topGiven = insetGiven(style.top);
    const bool leftGiven = insetGiven(style.left);
    const bool rightGiven = insetGiven(style.right);
    const bool bottomGiven = insetGiven(style.bottom);

    // `margin: auto` is detected from the style text: the per-side longhand
    // wins over the `margin` shorthand, and `auto` is still a keyword here
    // (the resolver reports it only as a value, not as a flag).
    bool sideAuto(string perSide, int idx)
    {
        return shorthandToken(perSide.length ? perSide : style.margin, idx) == "auto";
    }

    // CSS 10.3.7: with `width: auto` and BOTH insets given, the used width is
    // solved from the containing block instead of stretching to the full width
    // (and the element then ignores `right` entirely).
    int absW = w;
    if (style.resolveLength(style.width, cbW) < 0 && leftGiven && rightGiven)
    {
        absW = max(0, cbW - leftV - rightV - element.box.marginLeft -
            element.box.marginRight - element.box.paddingLeft -
            element.box.paddingRight - element.box.borderLeft -
            element.box.borderRight);
        element.box.width = absW;
    }
    // Same rule vertically (CSS 10.6.4): `height: auto` with both insets is
    // solved from the containing block rather than collapsing or stretching.
    int absH = h;
    if (style.resolveLength(style.height, cbH) < 0 && topGiven && bottomGiven)
    {
        absH = max(0, cbH - topV - bottomV - element.box.marginTop -
            element.box.marginBottom - element.box.paddingTop -
            element.box.paddingBottom - element.box.borderTop -
            element.box.borderBottom);
        element.box.height = absH;
    }

    // `margin: auto` on an axis whose two insets are both given distributes the
    // leftover space (CSS 10.3.7 horizontal / 10.6.4 vertical) — this is how
    // absolutely positioned overlays centre themselves.
    if (leftGiven && rightGiven &&
        (sideAuto(style.marginLeft, 3) || sideAuto(style.marginRight, 1)))
    {
        const spare = max(0, cbW - leftV - rightV - absW);
        if (sideAuto(style.marginLeft, 3) && sideAuto(style.marginRight, 1))
            element.box.marginLeft = element.box.marginRight = spare / 2;
        else if (sideAuto(style.marginLeft, 3))
            element.box.marginLeft = spare;
        else
            element.box.marginRight = spare;
    }
    if (topGiven && bottomGiven &&
        (sideAuto(style.marginTop, 0) || sideAuto(style.marginBottom, 2)))
    {
        const spare = max(0, cbH - topV - bottomV - absH);
        if (sideAuto(style.marginTop, 0) && sideAuto(style.marginBottom, 2))
            element.box.marginTop = element.box.marginBottom = spare / 2;
        else if (sideAuto(style.marginTop, 0))
            element.box.marginTop = spare;
        else
            element.box.marginBottom = spare;
    }

    if (leftGiven)
        element.box.x = cbX + leftV + element.box.marginLeft;
    else if (rightGiven)
        element.box.x = cbX + cbW - absW - rightV - element.box.marginRight;
    else
        element.box.x = cbX + element.box.marginLeft;

    if (topGiven)
        element.box.y = cbY + topV + element.box.marginTop;
    else if (bottomGiven)
        element.box.y = cbY + cbH - absH - bottomV - element.box.marginBottom;
    else
        element.box.y = cbY + element.box.marginTop;

    // Children of an absolute element lay out normally inside it.
    auto childFlow = FlowContext();
    childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    childFlow.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    childFlow.width = max(0, absW - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);
    childFlow.height = cbH;
    childFlow.lineEnd = childFlow.x + childFlow.width;
    // Honor the element's OWN display (a flex/grid popup lays its children as
    // items, not as stacked blocks).
    layoutContents(element, childFlow, element);

    // CSS 10.6.4: an absolutely positioned box with `height: auto` shrink-to-fits
    // its content (unless both vertical insets are given, which was solved above).
    // It used to be forced to exactly 0, so every auto-height overlay, tooltip
    // and decorative absolutely positioned ornament collapsed to nothing — a real
    // page's hero ornament measured 0x0 with its artwork laid out inside it.
    if (style.resolveLength(style.height, cbH) < 0 && !(topGiven && bottomGiven))
    {
        const int contentTop = element.box.y + element.box.paddingTop +
            element.box.borderTop;
        int contentBottom = contentTop;
        foreach (child; element.children)
        {
            auto childEl = cast(Element) child;
            if (childEl !is null)
            {
                if (childEl.style.display == "none") continue;
                contentBottom = max(contentBottom, childEl.box.y + childEl.box.height);
                continue;
            }
            auto childText = cast(TextNode) child;
            if (childText !is null)
                contentBottom = max(contentBottom, childText.layoutY +
                    (style.fontSizePx > 0 ? style.fontSizePx : 16));
        }
        element.box.height = clampMinMaxHeight(element,
            max(0, contentBottom - contentTop));
    }
}

/// Lay out a `position:fixed` element relative to the viewport (0,0). The
/// containing block is always the viewport: positioned ancestors are ignored
/// and the box never moves on scroll. The element is removed from flow, so it
/// never pushes following siblings.
private void layoutFixed(Element element, int containingWidth, int viewportWidth, int viewportHeight)
{
    auto style = element.style;
    // Fixed containing block = the viewport.
    const cbX = 0;
    const cbY = 0;
    const cbW = viewportWidth;
    const cbH = viewportHeight;

    const w = resolveWidth(element, cbW);
    const h = style.resolveLength(style.height, cbH);
    element.box.width = w;
    element.box.height = h >= 0 ? clampMinMaxHeight(element, max(0, h)) : 0;

    // With `width`/`height` auto and BOTH insets given, the used size fills the
    // inset rectangle (CSS 10.3.7 horizontal / 10.6.4 vertical). A fixed layer
    // declared as `inset: 0` used to collapse to zero height, so a real page's
    // full-viewport decorative grid layer never covered anything.
    const bool fixedLeft = insetGiven(style.left);
    const bool fixedRight = insetGiven(style.right);
    const bool fixedTop = insetGiven(style.top);
    const bool fixedBottom = insetGiven(style.bottom);
    const int fixedLeftV = style.resolveLength(style.left, cbW);
    const int fixedRightV = style.resolveLength(style.right, cbW);
    const int fixedTopV = style.resolveLength(style.top, cbH);
    const int fixedBottomV = style.resolveLength(style.bottom, cbH);
    if (style.resolveLength(style.width, cbW) < 0 && fixedLeft && fixedRight)
        element.box.width = max(0, cbW - fixedLeftV - fixedRightV -
            element.box.marginLeft - element.box.marginRight -
            element.box.paddingLeft - element.box.paddingRight -
            element.box.borderLeft - element.box.borderRight);
    if (style.resolveLength(style.height, cbH) < 0 && fixedTop && fixedBottom)
        element.box.height = max(0, cbH - fixedTopV - fixedBottomV -
            element.box.marginTop - element.box.marginBottom -
            element.box.paddingTop - element.box.paddingBottom -
            element.box.borderTop - element.box.borderBottom);

    const topV = style.resolveLength(style.top, cbH);
    const leftV = style.resolveLength(style.left, cbW);
    const rightV = style.resolveLength(style.right, cbW);
    const bottomV = style.resolveLength(style.bottom, cbH);

    if (leftV >= 0)
        element.box.x = cbX + leftV + element.box.marginLeft;
    else if (rightV >= 0)
        element.box.x = cbX + cbW - w - rightV - element.box.marginRight;
    else
        element.box.x = cbX + element.box.marginLeft;

    if (topV >= 0)
        element.box.y = cbY + topV + element.box.marginTop;
    else if (bottomV >= 0)
        element.box.y = cbY + cbH - h - bottomV - element.box.marginBottom;
    else
        element.box.y = cbY + element.box.marginTop;

    // Children of a fixed element lay out normally inside it.
    auto childFlow = FlowContext();
    childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    childFlow.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    childFlow.width = max(0, w - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);
    childFlow.height = cbH;
    childFlow.lineEnd = childFlow.x + childFlow.width;
    layoutChildren(element, childFlow, element);
}

/// Lay out an element's in-flow children IN DOCUMENT ORDER. A run of inline
/// content is laid out as soon as a following block-level box appears, so a
/// later block can never jump above earlier inline content (an inline-block
/// button followed by a block used to render with the block on top).
///
/// Two details matter for not perturbing existing pages:
///  * inter-block whitespace does not start a run, and
///  * a run is only flushed at a block boundary when it contains an inline
///    element. Text-only runs keep accumulating and are laid out at the end,
///    exactly as before — flushing every stray text node onto its own line
///    before each block added hundreds of pixels of blank space to real pages.
private void layoutChildren(Element element, ref FlowContext flow, Element positionedAncestor)
{
    // Generated `::before`/`::after` boxes (CSS 12) take part in this flow even
    // though they are deliberately NOT in `children`/`elements` afterwards (so
    // DOM and script APIs never observe them). They are spliced into the child
    // lists for the duration of this pass only, `::before` first and `::after`
    // last, exactly where CSS places generated content — so the out-of-flow loop
    // below and in-flow placement (including inline and inline-block runs) both
    // work unchanged, and script never sees the extra nodes.
    auto savedChildren = element.children;
    auto savedElements = element.elements;
    scope(exit)
    {
        element.children = savedChildren;
        element.elements = savedElements;
    }
    if (element.pseudoBefore !is null || element.pseudoAfter !is null)
    {
        typeof(element.children) splicedChildren;
        typeof(element.elements) splicedElements;
        if (element.pseudoBefore !is null)
        {
            splicedChildren ~= element.pseudoBefore;
            splicedElements ~= element.pseudoBefore;
        }
        splicedChildren ~= savedChildren;
        splicedElements ~= savedElements;
        if (element.pseudoAfter !is null)
        {
            splicedChildren ~= element.pseudoAfter;
            splicedElements ~= element.pseudoAfter;
        }
        element.children = splicedChildren;
        element.elements = splicedElements;
    }

    // Absolutely/fixed positioned children are out of this flow, so the loops
    // below skip them — and nobody laid them out afterwards: they kept their
    // default 0x0 box. A real page's decorative ornament (`position: absolute`
    // with a declared height, inside a grid item) measured 0x0 for exactly this
    // reason. Placement only depends on the containing block, never on sibling
    // layout, so doing it up front is correct and order-independent.
    foreach (child; element.children)
    {
        auto positioned = cast(Element) child;
        if (positioned is null) continue;
        if (positioned.style.position != "absolute" &&
            positioned.style.position != "fixed") continue;
        auto cb = (element.style.position == "relative" ||
                   element.style.position == "absolute" ||
                   element.style.position == "fixed") ? element : positionedAncestor;
        // `fixed` is relative to the viewport and ignores positioned ancestors.
        if (positioned.style.position == "fixed")
            layoutFixed(positioned, flow.width, positioned.style.viewportWidth,
                positioned.style.viewportHeight);
        else
            layoutAbsolute(positioned, flow.width, cb);
    }



    size_t runStart = 0;
    bool runPending = false;
    // Only runs that contain an inline ELEMENT are flushed at a block
    // boundary. Text-only runs keep accumulating and are laid out at the end
    // exactly as before, because laying stray text out on its own line before
    // every block added hundreds of pixels of blank space to real pages.
    bool runHasElement = false;
    foreach (childIndex, child; element.children)
    {
        auto childElement = cast(Element) child;
        if (childElement is null)
        {
            // Whitespace between block boxes does not start an inline run: the
            // block structure already separates the content, and treating it as
            // inline content adds a line box before every block (which is why
            // an earlier attempt at ordering the children added hundreds of
            // pixels of blank space to real pages).
            auto textChild = cast(TextNode) child;
            if (textChild !is null && textChild.data.strip().length == 0)
                continue;
            if (!runPending) { runPending = true; runStart = childIndex; }
            continue;
        }
        auto childStyle = childElement.style;
        if (childStyle.position == "absolute" || childStyle.position == "fixed")
            continue;
        if (childStyle.display == "inline" || childStyle.display == "inline-block")
        {
            if (!runPending) { runPending = true; runStart = childIndex; }
            runHasElement = true;
            continue;
        }
        if (runPending && runHasElement)
        {
            const savedX = flow.x;
            layoutDirectText(element, flow, runStart, childIndex);
            flow.x = savedX;
            if (flow.inlineBottomAbs > flow.y) flow.y = flow.inlineBottomAbs;
            runPending = false;
            runHasElement = false;
        }
        if (childStyle.display == "flex" || childStyle.display == "inline-flex")
            layoutFlex(childElement, flow, positionedAncestor);
        else if (childStyle.display == "grid")
            layoutGrid(childElement, flow, positionedAncestor);
        else if (childStyle.display == "table" || childElement.tag == "table")
            layoutTable(childElement, flow, positionedAncestor);
        else if (childStyle.display == "table-row" || childElement.tag == "tr")
            layoutTableRow(childElement, flow, positionedAncestor);
        else if (childStyle.display == "table-cell" || childElement.tag == "td" || childElement.tag == "th")
            layoutTableCell(childElement, flow, positionedAncestor);
        else
            layoutBlock(childElement, flow, flow.width, positionedAncestor);
    }
    if (runPending)
    {
        const savedX = flow.x;
        layoutDirectText(element, flow, runStart, element.children.length);
        flow.x = savedX;
    }
}

/// Layout a single inline element (or inline-block) at the current flow point.
private void layoutInlineElement(Element element, ref FlowContext flow, Element positionedAncestor)
{
    if (element.style.display == "inline-block")
    {
        layoutInlineBlock(element, flow, positionedAncestor);
        return;
    }
    layoutInlineChildren(element, flow, positionedAncestor);
}

private void layoutInlineChildren(Element element, ref FlowContext flow, Element positionedAncestor)
{
    int currentLineX = flow.x;
    int currentLineY = flow.y;
    int lineIndex = flow.lineCount;
    const lineHeight = element.style.resolveLength(element.style.lineHeight, 0) > 0 ?
        element.style.resolveLength(element.style.lineHeight, 0) : 18;

    void emitLine()
    {
        flow.x = flow.x; // cursor stays; caller uses flow.
    }

    foreach (child; element.children)
    {
        auto text = cast(TextNode) child;
        if (text !is null)
        {
            const string runText = collapsibleText(element, text);
            text.paintText = runText;
            const int textWidth = cast(int)(runText.length * 8);
            // Shape the line around active floats.
            const int leftEdge = flow.lineLeft(currentLineY, lineHeight);
            const int rightEdge = flow.lineRight(currentLineY, lineHeight);
            if (currentLineX < leftEdge) currentLineX = leftEdge;
            if (currentLineX + textWidth > rightEdge && currentLineX > leftEdge)
            {
                currentLineX = leftEdge;
                currentLineY += lineHeight;
                lineIndex++;
            }
            text.layoutX = currentLineX;
            text.layoutY = currentLineY;
            text.layoutWidth = textWidth;
            text.lineIndex = lineIndex;
            currentLineX += textWidth;
            flow.contentBottom = max(flow.contentBottom, currentLineY + lineHeight - flow.y);
            continue;
        }
        auto childElement = cast(Element) child;
        if (childElement !is null)
        {
            const int cw = childElement.style.display == "inline-block" ?
                resolveWidth(childElement, flow.width) :
                cast(int)(childElement.textContent().length * 8);
            const int leftEdge2 = flow.lineLeft(currentLineY, lineHeight);
            const int rightEdge2 = flow.lineRight(currentLineY, lineHeight);
            if (currentLineX < leftEdge2) currentLineX = leftEdge2;
            if (currentLineX + cw > rightEdge2 && currentLineX > leftEdge2)
            {
                currentLineX = leftEdge2;
                currentLineY += lineHeight;
                lineIndex++;
            }
            if (childElement.style.display == "inline-block")
            {
                childElement.box.x = currentLineX;
                childElement.box.y = currentLineY;
                childElement.box.width = resolveWidth(childElement, flow.width);
                childElement.box.height = resolveHeight(childElement) >= 0 ?
                    resolveHeight(childElement) : 18;
                currentLineX += childElement.box.width;
                layoutChildren(childElement, flow, positionedAncestor);
            }
            else
            {
                // Recurse into inline element's children, preserving the line cursor.
                auto savedX = currentLineX;
                auto savedY = currentLineY;
                auto savedLine = lineIndex;
                layoutInlineChildren(childElement, flow, positionedAncestor);
                // The recursion advanced flow; reconcile our cursor.
                currentLineX = max(currentLineX, childElement.children.length ? currentLineX : savedX);
                currentLineY = max(currentLineY, flow.y);
                lineIndex = max(lineIndex, flow.lineCount);
            }
            flow.contentBottom = max(flow.contentBottom, currentLineY + lineHeight - flow.y);
        }
    }
    flow.y += max(0, (lineIndex + 1) * lineHeight - flow.contentBottom * 0);
    // Ensure flow.y advances past all lines laid out here.
    flow.y = max(flow.y, flow.y + lineHeight * max(1, lineIndex + 1));
}

private void layoutInlineBlock(Element element, ref FlowContext flow, Element positionedAncestor)
{
    resolveBoxMetrics(element, flow.width);
    const auto width = resolveWidth(element, flow.width);
    if (flow.x + width > flow.lineEnd && flow.x > flow.lineEnd - flow.width)
        flow.newLine();
    element.box.x = flow.x;
    element.box.y = flow.y;
    element.box.width = width;
    element.box.height = resolveHeight(element) >= 0 ? resolveHeight(element) : 18;
    flow.x += width;
    layoutChildren(element, flow, positionedAncestor);
}

/// Lay out an element's children according to the element's OWN display type.
/// Used for grid/flex items, which may themselves be flex/grid containers
/// (nested flex/grid); `positioned` means the element's box is already placed
/// by its parent, so it must not be repositioned here.
private void layoutContents(Element element, ref FlowContext flow, Element positionedAncestor)
{
    auto d = element.style.display;
    if (d == "flex" || d == "inline-flex")
        layoutFlex(element, flow, positionedAncestor, true);
    else if (d == "grid")
        layoutGrid(element, flow, positionedAncestor, true);
    else if (d == "table" || element.tag == "table")
        layoutTable(element, flow, positionedAncestor);
    else if (d == "table-row" || element.tag == "tr")
        layoutTableRow(element, flow, positionedAncestor);
    else if (d == "table-cell" || element.tag == "td" || element.tag == "th")
        layoutTableCell(element, flow, positionedAncestor);
    else
    {
        layoutChildren(element, flow, positionedAncestor);
        // Lay the item's own direct text (e.g. an inline `span` flex item):
        // otherwise its text has no position and paints at the origin.
        layoutDirectText(element, flow);
    }
}

/// Lay a flex/grid container's OWN direct text (an anonymous item) inside its
/// content box, so text like a `<button>Label</button>` does not paint at (0,0).
private void layOwnDirectText(Element element, int innerX, int innerY, int innerW,
    int containingHeight)
{
    bool has = false;
    foreach (ch; element.children)
    {
        auto t = cast(TextNode) ch;
        if (t !is null && t.data.strip().length) { has = true; break; }
    }
    if (!has) return;
    auto tf = FlowContext();
    tf.x = innerX;
    tf.y = innerY;
    tf.width = max(0, innerW);
    tf.lineEnd = innerX + max(0, innerW);
    tf.height = containingHeight;
    layoutDirectText(element, tf);
}

private void layoutFlex(Element element, ref FlowContext flow, Element positionedAncestor,
    bool positioned = false)
{
    const bool inline = element.style.display == "inline-flex";
    if (!positioned)
    {
        resolveBoxMetrics(element, flow.width);
        element.box.x = flow.x + element.box.marginLeft;
        element.box.y = flow.y + element.box.marginTop;

        int width = resolveWidth(element, flow.width);
        // An inline-flex container with no explicit width sizes to its content
        // (like an inline-block), never filling the containing block.
        if (inline && element.style.resolveLength(element.style.width, flow.width) < 0)
            width = 0;
        element.box.width = width;
    }
    int width = element.box.width;

    // Content box.
    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);



    // Children flex items.
    auto style = element.style;
    // `gap` may be px/rem/em/%/calc — resolve it, not just px.
    const gapPx = max(0, style.resolveLength(style.gap, innerW));

    int[] itemWidths;
    int totalFlex = 0;
    Element[] items;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        // Positioned children are removed from the flex flow.
        if (ce.style.position == "absolute" || ce.style.position == "fixed")
            continue;
        // `display: none` removes the element from the box tree entirely, so it
        // must not take a flex slot or contribute width. A hidden sibling link
        // widened a real page's social row by 63px and made the next item
        // overlap its neighbour.
        if (ce.style.display == "none") continue;
        items ~= ce;
        resolveBoxMetrics(ce, innerW);
        import auroraweb.dom : cssInt;
        auto growStr = ce.style.flexGrow;
        int grow = growStr.length ? cssInt(growStr) : 0;
        totalFlex += grow;
        auto basis = ce.style.resolveLength(ce.style.width, innerW);
        // Auto width: a growing item starts at 0 and takes a share of the
        // remaining space; a non-growing item sizes to its content.
        if (basis < 0)
            basis = grow == 0 ? intrinsicWidth(ce, innerW) : 0;
        itemWidths ~= basis >= 0 ? basis : 0;
    }

    // flex-direction: column — the main axis is vertical. Items stack top to
    // bottom and, by default (align-items: stretch), fill the content width.
    if (style.flexDirection == "column" || style.flexDirection == "column-reverse")
    {
        int cy = innerY;
        int totalH = 0;
        foreach (ce; items)
        {
            resolveBoxMetrics(ce, innerW);
            const int wExp = ce.style.resolveLength(ce.style.width, innerW);
            const int w = wExp >= 0 ? wExp : innerW;
            ce.box.x = innerX;
            ce.box.y = cy;
            ce.box.width = w;
            const int hExp = ce.style.resolveLength(ce.style.height, style.containingHeight);
            auto sub = FlowContext();
            sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
            sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
            sub.width = max(0, w - ce.box.paddingLeft - ce.box.paddingRight -
                ce.box.borderLeft - ce.box.borderRight);
            sub.lineEnd = sub.x + sub.width;
            const int subTop = sub.y;
            layoutContents(ce, sub, ce);
            const int contentH = max(sub.contentBottom, sub.y - subTop);
            ce.box.height = hExp >= 0 ? hExp
                : contentBoxHeight(ce, contentH);
            cy += ce.box.height + gapPx;
            totalH += ce.box.height + gapPx;
        }
        if (items.length) totalH -= gapPx;
        const int hExp2 = element.style.resolveLength(element.style.height, style.containingHeight);
        element.box.height = hExp2 >= 0 ? hExp2
            : contentBoxHeight(element, totalH);
        layOwnDirectText(element, innerX, innerY, innerW, style.containingHeight);
        foreach (child; element.children)
        {
            auto ce = cast(Element) child;
            if (ce is null) continue;
            if (ce.style.position != "absolute" && ce.style.position != "fixed") continue;
            auto cb = (element.style.position == "relative" ||
                       element.style.position == "absolute" ||
                       element.style.position == "fixed") ? element : positionedAncestor;
            layoutAbsolute(ce, innerW, cb);
        }
        flow.prevBottomMargin = element.box.marginBottom;
        flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
        return;
    }

    const int fixedTotal = sumWidths(itemWidths);
    const int gapTotal = gapPx * cast(int)max(0, items.length - 1);
    // Items occupy their OUTER size on the main axis (content + padding + border
    // + margins). Free space and the grow distribution must be measured against
    // that, or a centred row of padded items is off by their padding (a test
    // showed 110 instead of 90).
    int outerTotal = 0;
    foreach (i, ce; items)
        outerTotal += itemWidths[i] + ce.box.paddingLeft + ce.box.paddingRight +
            ce.box.borderLeft + ce.box.borderRight +
            ce.box.marginLeft + ce.box.marginRight;
    const int remaining = innerW - outerTotal - gapTotal;
    if (totalFlex > 0)
    {
        // Distribute remaining proportionally to flex-grow.
        foreach (i, ce; items)
        {
            import auroraweb.dom : cssInt;
            auto growStr = ce.style.flexGrow;
            int grow = growStr.length ? cssInt(growStr) : 0;
            if (grow > 0)
            {
                const int share = (remaining * grow) / totalFlex;
                itemWidths[i] = itemWidths[i] + share;
            }
        }
    }

    // Clamp each flex item's resolved width to its own min/max-width. The
    // container clamp in resolveWidth is not enough — per-item max-width must
    // cap the grown width (e.g. flex-grow:1 + max-width:50px in a wide row).
    foreach (i, ce; items)
    {
        ce.style.containingWidth = innerW;
        ce.style.containingHeight = element.style.containingHeight;
        itemWidths[i] = clampMinMaxWidth(ce, max(0, itemWidths[i]));
    }

    // Automatic minimum size: a flex item with `width:auto` never shrinks
    // below its min-content width, or its own text would wrap needlessly.
    foreach (i, ce; items)
    {
        if (ce.style.resolveLength(ce.style.width, innerW) >= 0) continue;
        ce.style.containingWidth = innerW;
        itemWidths[i] = max(itemWidths[i], minContentWidth(ce, innerW));
    }

    // justify-content.
    int cursor = innerX;
    // Measured AFTER the grow pass: it changes itemWidths, so a pre-grow total
    // overstates the free space and pushes a centred row off its container
    // (the real page's toolbar jumped to x=1292 before this was fixed).
    int used = gapTotal;
    foreach (i, ce; items)
        used += itemWidths[i] + ce.box.paddingLeft + ce.box.paddingRight +
            ce.box.borderLeft + ce.box.borderRight +
            ce.box.marginLeft + ce.box.marginRight;
    // Free space is never negative: browsers keep overflowing content inside the
    // container (the overflow-safe behaviour). Without this clamp a centred row
    // whose items overflowed began to the LEFT of its own content box - a real
    // page's nav link started 24px left of its container and clipped its
    // neighbour.
    const int freeSpace = innerW > used ? innerW - used : 0;
    if (style.justifyContent == "center")
        cursor = innerX + freeSpace / 2;
    else if (style.justifyContent == "flex-end")
        cursor = innerX + freeSpace;
    // space-between / space-around / space-evenly distribute the free space as
    // extra gaps. These were accepted by the parser but never applied, so every
    // navbar, toolbar and card row using them packed to the left instead.
    int gapExtra = 0;
    int lead = 0;
    if (items.length > 0 && innerW > used)
    {
        const int free = innerW - used;
        const int n = cast(int) items.length;
        if (style.justifyContent == "space-between")
            gapExtra = n > 1 ? free / (n - 1) : 0;
        else if (style.justifyContent == "space-around")
        {
            gapExtra = free / n;
            lead = gapExtra / 2;
        }
        else if (style.justifyContent == "space-evenly")
        {
            gapExtra = free / (n + 1);
            lead = gapExtra;
        }
    }
    if (lead > 0) cursor = innerX + lead;

    int maxChildHeight = 0;
    int[] xs;
    foreach (i, ce; items)
    {
        // CSS places the item's border box after its own left/top margin, and
        // the cursor then advances by the item's outer size. Ignoring margins
        // made margined items sit too far left and overlap their neighbour -
        // the nav's "Home" link (margin-left) landed on top of "Contact".
        ce.box.x = cursor + ce.box.marginLeft;
        ce.box.y = innerY + ce.box.marginTop;
        ce.box.width = itemWidths[i];
        resolveBoxMetrics(ce, innerW);
        const itemH = resolveHeight(ce);
        ce.box.height = itemH >= 0 ? itemH : 0;
        xs ~= cursor + ce.box.marginLeft;
        // box.width is the CONTENT box, so the row must advance by the item's
        // outer size: content + padding + border + margins. Counting only the
        // content width overlapped every padded or bordered item - toolbar
        // buttons, pills, cards (a test showed the next item at 40 instead of 70).
        cursor += itemWidths[i] + ce.box.paddingLeft + ce.box.paddingRight +
            ce.box.borderLeft + ce.box.borderRight +
            ce.box.marginLeft + ce.box.marginRight + gapPx + gapExtra;
        // Lay out the item's children inside the item's OWN box (not the
        // container's), then grow the item to fit its content. Without this,
        // flex items had zero height and their text all painted at (0,0),
        // overlapping other content.
        auto sub = FlowContext();
        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
        sub.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight -
            ce.box.borderLeft - ce.box.borderRight);
        sub.lineEnd = sub.x + sub.width;
        const int subTop = sub.y;
        layoutContents(ce, sub, ce);
        // Content height must include the flow ADVANCE as well as the painted
        // extent: an item whose content is inline ELEMENTS (not direct text) only
        // advances the flow, and measuring the extent alone collapsed those
        // items to zero height (the dock's flyout labels went 48px -> 0).
        const int contentH = max(sub.contentBottom, sub.y - subTop);
        if (itemH < 0 && contentH > 0)
            ce.box.height = max(0, contentH + ce.box.paddingTop + ce.box.paddingBottom);
        maxChildHeight = max(maxChildHeight, ce.box.height);
        // An item's own layout may have made it WIDER than the pre-layout
        // estimate (an inline-flex item with auto width sizes to its content), so
        // every following item must advance by the actual width. Advancing by the
        // estimate let a real page's social row sit 36px narrower than the box it
        // painted, and the next item overlapped it.
        if (ce.box.width > itemWidths[i])
        {
            cursor += ce.box.width - itemWidths[i];
            itemWidths[i] = ce.box.width;
        }
    }

    // margin-left:auto / margin-right:auto / margin:auto on an item absorbs
    // ALL leftover space like justify-content would: a left-auto margin pushes
    // the item (and everything after it) to the far side; a right-auto margin
    // pulls the following items toward the right edge; both auto margins
    // center the item. The margins already resolved to 0 in normal flow, so
    // detect the `auto` keyword in the style strings directly.
    int[] autoLeft;
    int[] autoRight;
    foreach (i, ce; items)
    {
        const ml = ce.style.marginLeft.strip().toLower();
        const mr = ce.style.marginRight.strip().toLower();
        const shorthand = ce.style.margin.strip().toLower();
        if (ml == "auto" || (ml.length == 0 && shorthand.indexOf("auto") >= 0))
            autoLeft ~= cast(int) i;
        if (mr == "auto" || (mr.length == 0 && shorthand.indexOf("auto") >= 0))
            autoRight ~= cast(int) i;
    }
    if (autoLeft.length || autoRight.length)
    {
        const itemsW = sumWidths(itemWidths);
        const gapPaid = gapPx * cast(int)max(0, items.length - 1);
        int leftover = innerW - itemsW - gapPaid;
        if (leftover < 0) leftover = 0;
        // CSS gives each auto margin an equal share of the free space, and a
        // margin only moves the items that follow it. Handing every auto item
        // the whole leftover moved later items twice — on a real page the nav's
        // "Home" ended up overlapping "Contact".
        const int autoMargins = cast(int) autoLeft.length + cast(int) autoRight.length;
        const int share = autoMargins > 0 ? leftover / autoMargins : 0;
        if (share > 0)
        {
            int shift = 0;
            foreach (i, ce; items)
            {
                bool leftAuto = false, rightAuto = false;
                foreach (l; autoLeft) if (l == i) { leftAuto = true; break; }
                foreach (r; autoRight) if (r == i) { rightAuto = true; break; }
                if (leftAuto) shift += share;
                if (shift > 0)
                {
                    // Move the item AND everything inside it. Shifting only the
                    // item box left its children behind, so a flyout's labels
                    // were painted to the left of the item they belong to.
                    shiftBoxTree(ce, shift);
                }
                if (rightAuto) shift += share;
            }
        }
    }

    // align-items on the row's cross axis (CSS Flexbox 8.3). Only `center` used
    // to be honoured, so a toolbar declaring `align-items: flex-start` centred
    // its buttons and one declaring `flex-end` packed them to the top. `stretch`
    // needs no work here: items already resolve their own height.
    if (style.alignItems == "flex-start" || style.alignItems == "start")
    {
        foreach (ce; items)
            ce.box.y = innerY;
    }
    else if (style.alignItems == "flex-end" || style.alignItems == "end")
    {
        foreach (ce; items)
            ce.box.y = innerY + maxChildHeight - ce.box.height;
    }
    else if (style.alignItems == "center")
    {
        foreach (ce; items)
            ce.box.y = innerY + (maxChildHeight - ce.box.height) / 2;
    }

    // An inline-flex container with no explicit width sizes to its content:
    // the sum of its items' widths (+ gaps + padding + border).
    if (inline && element.style.resolveLength(element.style.width, flow.width) < 0)
    {
        // A bare text child is an anonymous flex item (CSS Flexbox 4.1), so its
        // measured width must count. Without this a label such as
        // `<summary>Tools</summary>` collapsed to its padding width (17px for a
        // 27px label), so every toolbar entry overflowed its own box and the
        // whole row was crammed against the viewport edge.
        int textW = 0;
        foreach (child; element.children)
        {
            auto tn = cast(TextNode) child;
            if (tn is null) continue;
            const px = element.style.fontSizePx > 0 ? element.style.fontSizePx : 16;
            auto lay = shapeText(tn.data, px, 0);
            if (lay !is null) textW = max(textW, cast(int) lay.width);
        }
        // Sum the items' OUTER sizes (content + padding + border + margins): an
        // auto-width container was sized from content widths alone, so it came
        // out narrower than the boxes it held (80 instead of 110 in a test).
        int itemsW = textW;
        foreach (i, ce; items)
            itemsW += itemWidths[i] + ce.box.paddingLeft + ce.box.paddingRight +
                ce.box.borderLeft + ce.box.borderRight +
                ce.box.marginLeft + ce.box.marginRight;
        itemsW += gapPx * cast(int)max(0, items.length - 1);
        const totalW = itemsW + element.box.paddingLeft + element.box.paddingRight +
            element.box.borderLeft + element.box.borderRight;
        width = clampMinMaxWidth(element, max(0, totalW));
        element.box.width = width;
    }

    // Container height = tallest child (+ padding/border). A flex container
    // whose only content is its OWN direct text (`<button>Label</button>`) has
    // no flex items at all, so maxChildHeight stayed 0 and the box collapsed:
    // the text overflowed a zero-height box with no hit area (a real page's
    // "Public" owner pill measured 26x0).
    const int pxSize = element.style.fontSizePx > 0 ? element.style.fontSizePx : 16;
    int contentHeight = maxChildHeight;
    foreach (ch; element.children)
    {
        auto t = cast(TextNode) ch;
        if (t !is null && t.data.strip().length)
        {
            contentHeight = max(contentHeight, resolveLineHeight(element, pxSize));
            break;
        }
    }
    const hPx = resolveHeight(element);
    element.box.height = hPx >= 0 ? hPx : contentBoxHeight(element, contentHeight);

    layOwnDirectText(element, innerX, innerY, innerW, style.containingHeight);

    // Lay out absolutely/fixed positioned children, which are not flex items.
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce.style.position != "absolute" && ce.style.position != "fixed") continue;
        auto cb = (element.style.position == "relative" ||
                   element.style.position == "absolute" ||
                   element.style.position == "fixed") ? element : positionedAncestor;
        layoutAbsolute(ce, innerW, cb);
    }

    flow.prevBottomMargin = element.box.marginBottom;
    flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
}

private int sumWidths(int[] widths)
{
    int total = 0;
    foreach (w; widths) total += w;
    return total;
}

/// Parse a grid-template-columns value into resolved column widths.
private int[] resolveGridTracks(string value, int innerW)
{
    import auroraweb.dom : cssInt;
    int[] result;
    int fixedTotal = 0;
    int frCount = 0;
    auto parts = splitGridTracks(value);
    // First pass: fixed lengths + count fr.
    foreach (rawPart; parts)
    {
        auto part = normalizeTrack(rawPart);
        if (part.length == 0) continue;
        if (part == "auto" || part == "1fr" || part.endsWith("fr"))
        {
            // fr or auto.
            auto fr = part.length >= 2 && part[$ - 2 .. $] == "fr" ?
                (part.length == 2 ? 1 : cssInt(part[0 .. $ - 2])) : 0;
            if (fr > 0) frCount += fr;
            continue;
        }
        auto w = part.strip();
        auto px = w.length >= 2 && w[$ - 2 .. $] == "px" ? cssInt(w[0 .. $ - 2]) :
            (w.length >= 1 && w[$ - 1] == '%' ? (innerW * cssInt(w[0 .. $ - 1])) / 100 : cssInt(w));
        result ~= px;
        fixedTotal += px;
    }
    // Second pass: fill fr slots with remaining / frCount.
    const remaining = innerW - fixedTotal;
    int[] finalTracks;
    foreach (rawPart; parts)
    {
        auto part = normalizeTrack(rawPart);
        if (part.length == 0) continue;
        if (part == "auto" || part.endsWith("fr"))
        {
            auto fr = part.length >= 2 && part[$ - 2 .. $] == "fr" ?
                (part.length == 2 ? 1 : cssInt(part[0 .. $ - 2])) : 0;
            if (fr > 0 && frCount > 0)
                finalTracks ~= (remaining * fr) / frCount;
            else if (frCount == 0)
                finalTracks ~= 0;
        }
        else
        {
            // Reuse fixed width from first pass.
            auto w = part.strip();
            auto px = w.length >= 2 && w[$ - 2 .. $] == "px" ? cssInt(w[0 .. $ - 2]) :
                (w.length >= 1 && w[$ - 1] == '%' ? (innerW * cssInt(w[0 .. $ - 1])) / 100 : cssInt(w));
            finalTracks ~= px;
        }
    }
    return finalTracks;
}

/// Split a track list on top-level whitespace (spaces inside `(...)` ignored).
private string[] splitGridTracks(string value)
{
    string[] parts;
    string buf;
    int depth = 0;
    foreach (ch; value)
    {
        if (ch == '(') { depth++; buf ~= ch; }
        else if (ch == ')') { depth--; buf ~= ch; }
        else if ((ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f') && depth == 0)
        {
            if (buf.length) { parts ~= buf; buf = ""; }
        }
        else buf ~= ch;
    }
    if (buf.length) parts ~= buf;
    return parts;
}

/// Reduce `minmax(a, b)`/`calc(...)` track tokens to a simple length token.
private string normalizeTrack(string token)
{
    auto t = token.strip();
    if (t.length > 7 && t[$ - 1] == ')' && t[0 .. 7] == "minmax(")
    {
        auto inner = t[7 .. $ - 1];
        auto comma = topLevelCommaAt(inner);
        if (comma >= 0) t = inner[comma + 1 .. $].strip();
    }
    if (t.length > 5 && t[$ - 1] == ')' && t[0 .. 5] == "calc(")
        t = evalSimpleCalc(t[5 .. $ - 1]);
    return t;
}

private ptrdiff_t topLevelCommaAt(string s)
{
    int d = 0;
    foreach (k, ch; s)
    {
        if (ch == '(') d++;
        else if (ch == ')') d--;
        else if (ch == ',' && d == 0) return k;
    }
    return -1;
}

private struct Len { double value; string unit; }

private Len parseLen(string s)
{
    s = s.strip();
    size_t i = 0;
    while (i < s.length && (s[i] == '.' || s[i] == '+' || s[i] == '-' ||
        (s[i] >= '0' && s[i] <= '9')))
        i++;
    Len l;
    if (i > 0)
        try l.value = to!double(s[0 .. i]);
        catch (Exception) l.value = 0;
    l.unit = s[i .. $].strip();
    return l;
}

/// Evaluate a simple `calc()`: `<n><u> * <n><u>`, `<n><u> + <n><u>`, or a
/// single length. Enough for `calc(var(--x) * 100%)`.
private string evalSimpleCalc(string expr)
{
    auto e = expr.strip();
    foreach (op; ['*', '+'])
    {
        auto idx = indexOf(e, op);
        if (idx > 0)
        {
            auto l = parseLen(e[0 .. idx]);
            auto r = parseLen(e[idx + 1 .. $]);
            double n = (op == '*') ? l.value * r.value : l.value + r.value;
            auto unit = l.unit.length ? l.unit : r.unit;
            if (unit.length)
                return to!string(cast(long) (n + (n < 0 ? -0.5 : 0.5))) ~ unit;
            return to!string(n);
        }
    }
    return e;
}

/// Grid layout: auto-placement across template columns, fr sizing.
private void layoutGrid(Element element, ref FlowContext flow, Element positionedAncestor,
    bool positioned = false)
{
    if (!positioned)
    {
        resolveBoxMetrics(element, flow.width);
        element.box.x = flow.x + element.box.marginLeft;
        element.box.y = flow.y + element.box.marginTop;
        element.box.width = resolveWidth(element, flow.width);
    }
    const width = element.box.width;

    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);

    auto style = element.style;
    auto tracks = resolveGridTracks(style.gridTemplateColumns, innerW);
    if (tracks.length == 0) tracks = [innerW];
    // Explicit row tracks (px/%); auto rows are sized from content.
    auto rowTracks = style.gridTemplateRows.length ?
        resolveGridTracks(style.gridTemplateRows, style.containingHeight) : null;
    const colGap = style.columnGap.length ? max(0, style.resolveLength(style.columnGap, innerW)) : 0;
    const rowGap = style.rowGap.length ? max(0, style.resolveLength(style.rowGap, innerW)) : 0;

    Element[] items;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        // Absolutely/fixed positioned children are out of the grid flow (they
        // are laid out separately below) and must not consume a grid cell.
        if (ce.style.position == "absolute" || ce.style.position == "fixed")
            continue;
        // A hidden child consumes no grid cell either.
        if (ce.style.display == "none") continue;
        items ~= ce;
    }

    // First pass: lay each item into its cell to learn its intrinsic height.
    int cursorX = innerX;
    int cursorY = innerY;
    int rowIndex = 0;
    int colIndex = 0;
    int[] rowHeights;        // content height per row
    rowHeights ~= 0;
    int[] rowExplicit;       // explicit row track height per row (-1 = auto)
    if (rowTracks !is null)
        foreach (r; rowTracks) rowExplicit ~= r;
    foreach (ce; items)
    {
        if (colIndex >= tracks.length)
        {
            colIndex = 0;
            rowIndex++;
            cursorX = innerX;
            rowHeights ~= 0;
            // Advance cursorY by the just-finished row's height + gap.
            if (rowIndex - 1 < cast(int) rowHeights.length)
                cursorY += (rowIndex - 1 < cast(int) rowHeights.length ?
                    rowHeights[rowIndex - 1] : 18) + rowGap;
        }
        ce.box.x = cursorX;
        ce.box.y = cursorY;
        ce.box.width = tracks[colIndex];
        resolveBoxMetrics(ce, ce.box.width);
        // Item intrinsic height: explicit height, or content-based estimate.
        const hPx = ce.style.resolveLength(ce.style.height, style.containingHeight);
        int itemH = hPx >= 0 ? hPx : 18;
        // Lay the cell's children to measure content.
        auto sub = FlowContext();
        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
        sub.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight);
        sub.lineEnd = sub.x + sub.width;
        const int subTop = sub.y;
        layoutContents(ce, sub, ce);
        // Content height = the deeper of the inline-text bottom and how far
        // block children advanced the flow. (Block children only move `flow.y`;
        // using contentBottom alone made every grid row ~one line tall, so rows
        // overlapped.)
        const int contentH = max(sub.contentBottom, sub.y - subTop);
        if (contentH > 0)
            itemH = max(itemH, contentH + ce.box.paddingTop + ce.box.paddingBottom);
        ce.box.height = itemH;
        // Apply an explicit row track height if one is defined for this row.
        int rowH = itemH;
        if (rowIndex < cast(int) rowExplicit.length && rowExplicit[rowIndex] >= 0)
            rowH = rowExplicit[rowIndex];
        if (rowIndex < cast(int) rowHeights.length)
            rowHeights[rowIndex] = max(rowHeights[rowIndex], rowH);
        cursorX += ce.box.width + colGap;
        colIndex++;
    }

    // Second pass: position items using the final row heights.
    cursorX = innerX;
    cursorY = innerY;
    rowIndex = 0;
    colIndex = 0;
    foreach (ce; items)
    {
        if (colIndex >= tracks.length)
        {
            colIndex = 0;
            rowIndex++;
            cursorX = innerX;
            if (rowIndex < cast(int) rowHeights.length)
                cursorY += rowHeights[rowIndex - 1] + rowGap;
        }
        ce.box.x = cursorX;
        ce.box.y = cursorY;
        cursorX += ce.box.width + colGap;
        colIndex++;
    }
    // Container height from the last row.
    int totalH = cursorY;
    if (rowHeights.length > 0)
        totalH = cursorY + rowHeights[$ - 1];
    totalH += element.box.paddingBottom + element.box.borderBottom;
    const hPx2 = element.style.resolveLength(element.style.height, style.containingHeight);
    element.box.height = hPx2 >= 0 ? hPx2 : max(0, totalH);

    // Second pass: the items were laid during the measuring pass, while row
    // heights were still estimates, so absolutely positioned descendants were
    // placed against a not-yet-sized containing block and came out 0x0 (a real
    // page's decorative hero ornament disappeared). Re-lay each item in its final
    // cell now that the row heights are known.
    {
        int px = innerX;
        int py = innerY;
        int pr = 0;
        int pc = 0;
        foreach (ce; items)
        {
            if (pc >= cast(int) tracks.length)
            {
                pc = 0;
                pr++;
                px = innerX;
                if (pr - 1 < cast(int) rowHeights.length)
                    py += rowHeights[pr - 1] + rowGap;
            }
            ce.box.x = px;
            ce.box.y = py;
            ce.box.width = tracks[pc];
            auto itemFlow = FlowContext();
            itemFlow.x = px;
            itemFlow.y = py;
            itemFlow.width = tracks[pc];
            itemFlow.height = pr < cast(int) rowHeights.length ? rowHeights[pr] : 0;
            itemFlow.lineEnd = px + tracks[pc];
            layoutContents(ce, itemFlow, ce);
            px += tracks[pc] + colGap;
            pc++;
        }
    }

    layOwnDirectText(element, innerX, innerY, innerW, style.containingHeight);

    // Lay out absolutely/fixed positioned children, which are not grid items.
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce.style.position != "absolute" && ce.style.position != "fixed") continue;
        auto cb = (element.style.position == "relative" ||
                   element.style.position == "absolute" ||
                   element.style.position == "fixed") ? element : positionedAncestor;
        layoutAbsolute(ce, innerW, cb);
    }

    flow.prevBottomMargin = element.box.marginBottom;
    flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
}

/// Basic table layout: table -> rows -> cells.
private void layoutTable(Element element, ref FlowContext flow, Element positionedAncestor)
{
    resolveBoxMetrics(element, flow.width);
    element.box.x = flow.x + element.box.marginLeft;
    element.box.y = flow.y + element.box.marginTop;
    const width = resolveWidth(element, flow.width);
    element.box.width = width;

    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);

    // Collect rows and cell counts to compute equal column widths.
    int maxCols = 0;
    int rowCount = 0;
    Element[] rows;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce.tag == "tr") { rows ~= ce; rowCount++; }
    }
    foreach (row; rows)
    {
        int cols = 0;
        foreach (c; row.elements)
            if (c.tag == "td" || c.tag == "th") cols++;
        maxCols = max(maxCols, cols);
    }
    if (maxCols == 0) maxCols = 1;
    const colW = innerW / maxCols;

    int y = innerY;
    foreach (row; rows)
    {
        row.box.x = innerX;
        row.box.y = y;
        row.box.width = innerW;
        int x = innerX;
        int rowH = 0;
        foreach (c; row.elements)
        {
            if (c.tag != "td" && c.tag != "th") continue;
            c.box.x = x;
            c.box.y = y;
            c.box.width = colW;
            resolveBoxMetrics(c, colW);
            const hPx = c.style.resolveLength(c.style.height, 0);
            c.box.height = hPx >= 0 ? hPx : 18;
            rowH = max(rowH, c.box.height);
            // Paint children inside cell.
            auto sub = FlowContext();
            sub.x = c.box.x + c.box.paddingLeft;
            sub.y = c.box.y + c.box.paddingTop;
            sub.width = max(0, colW - c.box.paddingLeft - c.box.paddingRight);
            sub.lineEnd = sub.x + sub.width;
            layoutChildren(c, sub, c);
            x += colW;
        }
        row.box.height = rowH;
        y += rowH;
    }
    element.box.height = max(0, y - innerY) + element.box.paddingBottom + element.box.borderBottom;
    flow.prevBottomMargin = element.box.marginBottom;
    flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
}

private void layoutTableRow(Element element, ref FlowContext flow, Element positionedAncestor)
{
    // Rows are handled by the parent table layout; standalone treat as block.
    layoutBlock(element, flow, flow.width, positionedAncestor);
}

private void layoutTableCell(Element element, ref FlowContext flow, Element positionedAncestor)
{
    layoutBlock(element, flow, flow.width, positionedAncestor);
}

/// A float's placement rectangle (absolute coordinates).
struct FloatRect
{
    int x;
    int y;
    int width;
    int height;
    bool right;   /// right float (content must start before its left edge).
}

/// Flow context: the cursor for normal-flow layout.
private struct FlowContext
{
    int x;
    int y;
    int width;
    int height;
    int lineEnd;          /// Right edge of the current line.
    int contentBottom;    /// Bottom of the deepest inline content.
    int inlineBottomAbs;  /// Absolute bottom of the deepest inline content.
    int floatLeft;        /// Rightmost float left edge.
    FloatRect[] floats;   /// Active float rects for line shaping.
    int prevBottomMargin; /// Previous block's bottom margin (for collapsing).
    bool hasPrevBlock;    /// Whether any block has been laid out in this flow.
    bool suppressTopMargin; /// Parent/child collapsing already counted this
                            /// element's own margin-top above it.
    int lineCount;        /// Number of lines laid out so far.

    /// The usable left edge of the current line, after any left floats.
    int lineLeft(int lineY, int lineHeight) const
    {
        int left = x;
        foreach (f; floats)
        {
            if (f.right) continue;
            if (lineY + lineHeight <= f.y) continue;
            if (lineY >= f.y + f.height) continue;
            left = max(left, f.x + f.width);
        }
        return left;
    }

    /// The usable right edge of the current line, before any right floats.
    int lineRight(int lineY, int lineHeight) const
    {
        int right = lineEnd;
        foreach (f; floats)
        {
            if (!f.right) continue;
            if (lineY + lineHeight <= f.y) continue;
            if (lineY >= f.y + f.height) continue;
            right = min(right, f.x);
        }
        return right;
    }

    void newLine()
    {
        x = 0;
        y += 18; // line height
        lineEnd = width;
    }
}

// ---------------------------------------------------------------------------
// Unittests for layout depth
// ---------------------------------------------------------------------------
unittest
{
    import auroraweb.dom : Element;

    // 1. Three sibling blocks stack without overlap.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        auto a = new Element("div"); a.style.display = "block"; a.style.height = "20px";
        auto b = new Element("div"); b.style.display = "block"; b.style.height = "30px";
        auto c = new Element("div"); c.style.display = "block"; c.style.height = "10px";
        a.parent = parent; b.parent = parent; c.parent = parent;
        parent.children ~= a; parent.children ~= b; parent.children ~= c;
        parent.elements ~= a; parent.elements ~= b; parent.elements ~= c;

        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(a, flow, 100, null);
        layoutBlock(b, flow, 100, null);
        layoutBlock(c, flow, 100, null);
        assert(a.box.y == 0, "a.y should be 0, got " ~ a.box.y.to!string);
        assert(b.box.y == 20, "b.y should be 20, got " ~ b.box.y.to!string);
        assert(c.box.y == 50, "c.y should be 50, got " ~ c.box.y.to!string);
        assert(c.box.y >= b.box.y + b.box.height, "c must not overlap b");
    }

    // 2. Nested div height contains its child.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        auto child = new Element("div"); child.style.display = "block"; child.style.height = "40px";
        child.parent = parent;
        parent.children ~= child; parent.elements ~= child;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(parent, flow, 100, null);
        assert(parent.box.height >= 40, "parent must contain child, h=" ~ parent.box.height.to!string);
    }

    // 3. Percentage width: 50% of 1000 == 500.
    {
        auto child = new Element("div");
        child.style.display = "block";
        child.style.width = "50%";
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 1000; flow.height = 400;
        layoutBlock(child, flow, 1000, null);
        assert(child.box.width == 500, "50% of 1000 should be 500, got " ~ child.box.width.to!string);
    }

    // 4. Margin collapsing: 20px + 30px -> 30px gap.
    {
        auto a = new Element("div"); a.style.display = "block"; a.style.height = "10px";
        a.style.marginBottom = "20px";
        auto b = new Element("div"); b.style.display = "block"; b.style.height = "10px";
        b.style.marginTop = "30px";
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(a, flow, 100, null);
        layoutBlock(b, flow, 100, null);
        assert(b.box.y - (a.box.y + a.box.height) == 30,
            "collapsed gap should be 30, got " ~ (b.box.y - (a.box.y + a.box.height)).to!string);
    }

    // 5. Absolute positioning at top:10 left:20, no sibling push.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.position = "relative";
        auto abs = new Element("div"); abs.style.display = "block";
        abs.style.position = "absolute";
        abs.style.top = "10px"; abs.style.left = "20px";
        abs.style.width = "50px"; abs.style.height = "30px";
        auto sib = new Element("div"); sib.style.display = "block"; sib.style.height = "10px";
        abs.parent = parent; sib.parent = parent;
        parent.children ~= abs; parent.children ~= sib;
        parent.elements ~= abs; parent.elements ~= sib;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 400;
        layoutBlock(parent, flow, 200, null);
        layoutBlock(abs, flow, 200, parent);
        layoutBlock(sib, flow, 200, parent);
        assert(abs.box.x == 20, "abs.x should be 20, got " ~ abs.box.x.to!string);
        assert(abs.box.y == 10, "abs.y should be 10, got " ~ abs.box.y.to!string);
        assert(sib.box.y >= 0 && sib.box.y <= 15, "absolute should not push sibling, sib.y=" ~ sib.box.y.to!string);
    }

    // 6. Flex row: 3 children flex:1 in 300px -> 100px each.
    {
        auto flex = new Element("div");
        flex.style.display = "flex";
        flex.style.width = "300px";
        Element[] kids;
        foreach (i; 0 .. 3)
        {
            auto k = new Element("div");
            k.style.display = "block";
            k.style.flexGrow = "1";
            k.parent = flex;
            flex.children ~= k; flex.elements ~= k;
            kids ~= k;
        }
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 100;
        layoutFlex(flex, flow, null);
        assert(kids[0].box.width == 100, "flex child 0 width should be 100, got " ~ kids[0].box.width.to!string);
        assert(kids[1].box.width == 100, "flex child 1 width should be 100, got " ~ kids[1].box.width.to!string);
        assert(kids[2].box.width == 100, "flex child 2 width should be 100, got " ~ kids[2].box.width.to!string);
        assert(kids[1].box.x == 100, "flex child 1 x should be 100, got " ~ kids[1].box.x.to!string);
        assert(kids[2].box.x == 200, "flex child 2 x should be 200, got " ~ kids[2].box.x.to!string);
    }
}

unittest
{
    import auroraweb.dom : Element;

    // Grid: grid-template-columns: 100px 1fr 2fr in a 400px container.
    {
        auto grid = new Element("div");
        grid.style.display = "grid";
        grid.style.width = "400px";
        grid.style.gridTemplateColumns = "100px 1fr 2fr";
        Element[] kids;
        foreach (i; 0 .. 3)
        {
            auto k = new Element("div");
            k.style.display = "block";
            k.style.height = "10px";
            k.parent = grid;
            grid.children ~= k; grid.elements ~= k;
            kids ~= k;
        }
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 400; flow.height = 100;
        layoutGrid(grid, flow, null);
        assert(kids[0].box.width == 100, "grid col0 = 100, got " ~ kids[0].box.width.to!string);
        assert(kids[1].box.width == 100, "grid col1 (1fr) = 100, got " ~ kids[1].box.width.to!string);
        assert(kids[2].box.width == 200, "grid col2 (2fr) = 200, got " ~ kids[2].box.width.to!string);
        assert(kids[1].box.x == 100, "grid item1 x = 100, got " ~ kids[1].box.x.to!string);
        assert(kids[2].box.x == 200, "grid item2 x = 200, got " ~ kids[2].box.x.to!string);
    }

    // Grid rows: explicit grid-template-rows + auto rows sized from content.
    {
        auto grid = new Element("div");
        grid.style.display = "grid";
        grid.style.width = "100px";
        grid.style.gridTemplateColumns = "100px";
        grid.style.gridTemplateRows = "50px auto";
        Element[] kids;
        foreach (i; 0 .. 2)
        {
            auto k = new Element("div");
            k.style.display = "block";
            k.style.height = "80px";
            k.parent = grid;
            grid.children ~= k; grid.elements ~= k;
            kids ~= k;
        }
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 300;
        layoutGrid(grid, flow, null);
        // Row 0 uses the explicit 50px track; row 1 auto-sizes to content (80px).
        assert(kids[0].box.y == 0, "grid row0 y = 0, got " ~ kids[0].box.y.to!string);
        assert(kids[1].box.y >= 50, "grid row1 y should be at least 50 (explicit row), got " ~ kids[1].box.y.to!string);
        assert(kids[1].box.y == 50, "grid row1 y = 50, got " ~ kids[1].box.y.to!string);
        assert(kids[1].box.height == 80, "grid row1 auto height = 80, got " ~ kids[1].box.height.to!string);
    }

    // box-sizing: border-box — 100px width + 10px padding => outer 100, content 80.
    {
        auto el = new Element("div");
        el.style.display = "block";
        el.style.width = "100px";
        el.style.padding = "10px";
        el.style.boxSizing = "border-box";
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 100;
        layoutBlock(el, flow, 200, null);
        assert(el.box.width == 100, "border-box width stays 100, got " ~ el.box.width.to!string);
        assert(el.box.paddingLeft == 10, "paddingLeft=10, got " ~ el.box.paddingLeft.to!string);
    }

    // Table: 2 rows x 2 cols, equal columns.
    {
        auto table = new Element("table");
        table.style.display = "table";
        table.style.width = "200px";
        Element[] rows;
        foreach (r; 0 .. 2)
        {
            auto tr = new Element("tr");
            tr.style.display = "table-row";
            tr.parent = table;
            table.children ~= tr; table.elements ~= tr;
            rows ~= tr;
            foreach (c; 0 .. 2)
            {
                auto td = new Element("td");
                td.style.display = "table-cell";
                td.style.height = "20px";
                td.parent = tr;
                tr.children ~= td; tr.elements ~= td;
            }
        }
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 100;
        layoutTable(table, flow, null);
        auto r0 = cast(Element) table.elements[0];
        auto td00 = cast(Element) r0.elements[0];
        auto td01 = cast(Element) r0.elements[1];
        auto r1 = cast(Element) table.elements[1];
        auto td10 = cast(Element) r1.elements[0];
        assert(td00.box.x == 0, "td00.x = 0, got " ~ td00.box.x.to!string);
        assert(td01.box.x == 100, "td01.x = 100, got " ~ td01.box.x.to!string);
        assert(td10.box.y >= td00.box.y + td00.box.height, "row2 below row1");
    }
}

unittest
{
    import auroraweb.css : parseStylesheet, applyMediaRules;

    // Media queries: only matching rules survive.
    auto css = `@media (max-width: 400px) { .a { color: red; } }` ~
               `.b { color: blue; }` ~
               `@media (min-width: 100px) and (max-width: 300px) { .c { color: green; } }`;
    auto rules = parseStylesheet(css, 200, 100);
    assert(rules.length == 3, "all three rules parsed (including media), got " ~ rules.length.to!string);
    auto active = applyMediaRules(rules, 200, 100);
    assert(active.length == 3, "at 200 all three match (max400, plain, min100+max300), got " ~ active.length.to!string);
    auto activeWide = applyMediaRules(rules, 600, 100);
    assert(activeWide.length == 1, "at 600 only .b matches, got " ~ activeWide.length.to!string);
}

unittest
{
    import auroraweb.dom : Element;

    // Float wrapping: a left float pushes following inline text to its right
    // edge on the same vertical span.
    {
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 200;
        flow.lineEnd = 200;
        // Register a 60px-wide left float at y=0..40.
        FloatRect fr;
        fr.x = 0; fr.y = 0; fr.width = 60; fr.height = 40; fr.right = false;
        flow.floats ~= fr;

        auto container = new Element("div");
        container.style.display = "block";
        container.style.width = "200px";
        auto textNode = new TextNode(container, "abcdefghijklmnopqrstuvwxyz");
        container.children ~= textNode;

        layoutDirectText(container, flow);
        // The first line (y=0, within the float's span) must start at x=60.
        assert(textNode.layoutX == 60,
            "first line should start after the float (x=60), got " ~ textNode.layoutX.to!string);
    }

    // A right float: text must stop before its left edge.
    {
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 200;
        flow.lineEnd = 200;
        FloatRect fr;
        fr.x = 140; fr.y = 0; fr.width = 60; fr.height = 40; fr.right = true;
        flow.floats ~= fr;

        auto container = new Element("div");
        container.style.display = "block";
        container.style.width = "200px";
        auto textNode = new TextNode(container, "abcdefghijklmnopqrstuvwxyz");
        container.children ~= textNode;

        layoutDirectText(container, flow);
        // Text starts at 0 but must wrap before x=140 (float's left edge).
        // First line width is bounded by 140, so the 26-char text (208px)
        // wraps; textNode.layoutX for the wrapped portion should be < 140.
        assert(textNode.layoutX >= 0, "right-float text starts at 0");
        assert(textNode.layoutX < 140, "right-float text must stay left of x=140, got " ~ textNode.layoutX.to!string);
    }
}

unittest
{
    import auroraweb.dom : Element;
    import aurora.image : RgbaImage;
    import std.conv : to;

    // <img> intrinsic sizing: no CSS size -> box equals the decoded image
    // dimensions; an explicit width with `height: auto` scales the height by the
    // image's intrinsic ratio (CSS 10.6.2), and an explicit height overrides it.
    {
        ubyte[100 * 50 * 4] pixels;
        foreach (i, ref p; pixels) p = 200;
        auto img = new RgbaImage(100, 50, pixels);

        auto bare = new Element("img");
        bare.style.display = "inline-block";
        bare.image = img;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 200;
        flow.lineEnd = 300;
        layoutInlineBlock(bare, flow, null);
        assert(bare.box.width == 100, "img intrinsic width should be 100, got " ~ bare.box.width.to!string);
        assert(bare.box.height == 50, "img intrinsic height should be 50, got " ~ bare.box.height.to!string);

        auto styled = new Element("img");
        styled.style.display = "inline-block";
        styled.style.width = "200px";
        styled.image = img;
        auto flow2 = FlowContext();
        flow2.x = 0; flow2.y = 0; flow2.width = 300; flow2.height = 200;
        flow2.lineEnd = 300;
        layoutInlineBlock(styled, flow2, null);
        assert(styled.box.width == 200, "img with width:200px should be 200, got " ~ styled.box.width.to!string);
        // 100x50 image at width:200px -> height 200 * 50/100 = 100. Keeping the
        // intrinsic 50 here was the bug that left real pages' images zero-height.
        assert(styled.box.height == 100,
            "a 100x50 img at width:200px must scale to height 100, got " ~
            styled.box.height.to!string);
    }
}

unittest
{
    import auroraweb.dom : Element;
    import std.conv : to;

    // --- position: fixed ---
    // A fixed element is positioned relative to the viewport (0,0), ignoring
    // any positioned ancestor, and does not push siblings in normal flow.
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        parent.style.position = "relative";
        // Give the positioned ancestor an offset so a viewport-relative result
        // is clearly distinguishable from an ancestor-relative one.
        parent.box.x = 100;
        parent.box.y = 50;
        parent.box.width = 300;
        parent.box.height = 300;

        auto fixed = new Element("div");
        fixed.style.display = "block";
        fixed.style.position = "fixed";
        fixed.style.top = "10px";
        fixed.style.left = "20px";
        fixed.style.width = "50px";
        fixed.style.height = "30px";

        auto sib = new Element("div");
        sib.style.display = "block";
        sib.style.height = "10px";

        fixed.parent = parent; sib.parent = parent;
        parent.children ~= fixed; parent.children ~= sib;
        parent.elements ~= fixed; parent.elements ~= sib;

        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 400;

        // Fixed is relative to the viewport, NOT the positioned ancestor at
        // (100,50): box must land at (20,10), not (120,60).
        layoutFixed(fixed, 200, 600, 400);
        assert(fixed.box.x == 20,
            "fixed.x should be viewport-relative 20, got " ~ fixed.box.x.to!string);
        assert(fixed.box.y == 10,
            "fixed.y should be viewport-relative 10, got " ~ fixed.box.y.to!string);

        // The sibling following the fixed element is not pushed.
        layoutBlock(sib, flow, 200, parent);
        assert(sib.box.y >= 0 && sib.box.y <= 15,
            "fixed must not push siblings, sib.y=" ~ sib.box.y.to!string);
    }

    // --- right/bottom anchors relative to the viewport ---
    {
        auto fixed = new Element("div");
        fixed.style.display = "block";
        fixed.style.position = "fixed";
        fixed.style.right = "10px";
        fixed.style.bottom = "5px";
        fixed.style.width = "40px";
        fixed.style.height = "20px";
        layoutFixed(fixed, 200, 600, 400);
        assert(fixed.box.x == 600 - 10 - 40,
            "fixed right edge should sit 10px from viewport right, x=" ~ fixed.box.x.to!string);
        assert(fixed.box.y == 400 - 5 - 20,
            "fixed bottom edge should sit 5px from viewport bottom, y=" ~ fixed.box.y.to!string);
    }

    // --- position: fixed is removed from flow; a block after it in a parent
    // that also contains a normal sibling stacks normally ---
    {
        auto parent = new Element("div");
        parent.style.display = "block";
        auto fixed = new Element("div");
        fixed.style.display = "block";
        fixed.style.position = "fixed";
        fixed.style.top = "0px";
        fixed.style.left = "0px";
        fixed.style.height = "100px";
        auto a = new Element("div");
        a.style.display = "block";
        a.style.height = "10px";
        fixed.parent = parent; a.parent = parent;
        parent.children ~= fixed; parent.children ~= a;
        parent.elements ~= fixed; parent.elements ~= a;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(parent, flow, 100, null);
        // The fixed child never consumed flow space, so the normal sibling
        // sits at the top (y=0), not pushed down by the 100px fixed box.
        assert(a.box.y == 0,
            "fixed child must not push the next sibling, a.y=" ~ a.box.y.to!string);
    }
}

unittest
{
    import auroraweb.dom : Element, TextNode;
    import std.conv : to;

    // --- text-align: center / right shifts laid-out lines ---
    // A centered run with measured width W in a 200px content width must start
    // at (200 - W)/2; a right-aligned run must end at the right edge.
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.width = "200px";
        container.style.textAlign = "center";
        auto textNode = new TextNode(container, "Hello Aurora");
        container.children ~= textNode;

        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 200;
        flow.lineEnd = 200;
        layoutDirectText(container, flow);
        // The run was placed, then centered: layoutX = (200 - width)/2.
        assert(textNode.layoutWidth > 0, "run should be measured");
        assert(textNode.layoutX == (200 - textNode.layoutWidth) / 2,
            "centered run x should be (200 - " ~ textNode.layoutWidth.to!string ~ ")/2 = " ~
            ((200 - textNode.layoutWidth) / 2).to!string ~ ", got " ~ textNode.layoutX.to!string);
        assert(textNode.layoutX + textNode.layoutWidth <= 200,
            "centered run must stay within the content width");
    }

    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.width = "200px";
        container.style.textAlign = "right";
        auto textNode = new TextNode(container, "Right Aligned");
        container.children ~= textNode;

        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 200; flow.height = 200;
        flow.lineEnd = 200;
        layoutDirectText(container, flow);
        assert(textNode.layoutWidth > 0, "run should be measured");
        assert(textNode.layoutX == 200 - textNode.layoutWidth,
            "right-aligned run should end at the right edge, x=" ~
            textNode.layoutX.to!string ~ " width=" ~ textNode.layoutWidth.to!string);
    }

    // --- line-height: an explicit px value sizes the line boxes ---
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.lineHeight = "40px";
        auto textNode = new TextNode(container, "Tall line");
        container.children ~= textNode;

        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 300;
        flow.lineEnd = 300;
        layoutDirectText(container, flow);
        // The single line occupies a 40px line box: contentBottom must be 40.
        assert(flow.contentBottom == 40,
            "line-height:40px should give a 40px line box, contentBottom=" ~
            flow.contentBottom.to!string);
        // CSS half-leading: the glyphs are centred in the 40px line box instead
        // of pinned to its top, so the run's y is the leading offset (8 for this
        // font's 24px run). Painting at the line top made generous-line-height
        // labels sit visibly high.
        assert(textNode.layoutY > 0 && textNode.layoutY < 40,
            "the run must sit inside the 40px line box, y=" ~
            textNode.layoutY.to!string);
    }

    // --- display: list-item (uaDisplay for <li>) ---
    {
        auto li = new Element("li");
        li.style = computedStyle(li, []);
        assert(li.style.display == "list-item",
            "li should default to display:list-item, got " ~ li.style.display);
        // A div with display:list-item resolves the same way.
        auto div = new Element("div");
        div.style = computedStyle(div, []);
        div.style.display = "list-item";
        assert(div.style.display == "list-item",
            "explicit display:list-item is preserved");
    }
}

unittest
{
    import std.conv : to;

    // --- inline-flex sizing ---
    // An inline-flex container with no explicit width sizes to its content:
    // three 50px items + two 4px gaps = 158px total (no margin/padding/border).
    {
        auto flex = new Element("div");
        flex.style.display = "inline-flex";
        flex.style.gap = "4px";
        Element[] kids;
        foreach (i; 0 .. 3)
        {
            auto k = new Element("div");
            k.style.display = "block";
            k.style.width = "50px";
            k.style.height = "10px";
            k.parent = flex;
            flex.children ~= k; flex.elements ~= k;
            kids ~= k;
        }
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 600; flow.height = 100;
        layoutFlex(flex, flow, null);
        assert(flex.box.width == 158,
            "inline-flex width should shrink to content (158), got " ~ flex.box.width.to!string);
        assert(kids[0].box.x == 0, "inline-flex child0 x=0, got " ~ kids[0].box.x.to!string);
        assert(kids[1].box.x == 54, "inline-flex child1 x=54, got " ~ kids[1].box.x.to!string);
        assert(kids[2].box.x == 108, "inline-flex child2 x=108, got " ~ kids[2].box.x.to!string);
    }

    // --- inline-flex wrapping a bare text child ---
    // A text child is an anonymous flex item (CSS Flexbox 4.1), so the label
    // must size to its text rather than collapsing to its padding width. This
    // is what made `<summary>Tools</summary>` measure 17px for 27px of text.
    {
        auto label = new Element("summary");
        label.style.display = "inline-flex";
        auto labelText = new TextNode(label, "Tools");
        label.children ~= labelText;
        auto lf = FlowContext();
        lf.x = 0;
        lf.y = 0;
        lf.width = 600;
        lf.height = 100;
        layoutFlex(label, lf, null);
        assert(label.box.width > 20,
            "an inline-flex label must size to its text, got " ~
            label.box.width.to!string);
    }

    // --- a flex container whose only content is its own direct text ---
    // --- auto margins take equal shares and never overlap their siblings ---
    // --- justify-content: space-between actually distributes the free space ---
    // --- display: none children take no part in flex layout ---
    // --- flex items advance by their ACTUAL width, not the estimate ---
    // --- a second layout pass must not leave a child behind its container ---
    // --- flex items honour their own margins ---
    // --- a re-layout at a different width must reassign every box ---
    // --- a row advances by the item's OUTER size (padding and border) ---
    // --- centring accounts for the items' outer sizes ---
    // --- block horizontal margins, including `margin: 0 auto` centring ---
    // --- CSS transform: translate, percentages against the element's own box ---
    // --- clamp()/min()/max() resolve like CSS, not to the first component ---
    // --- an <img> with height:auto uses the image's intrinsic ratio ---
    // --- `color` inherits from an ancestor when the element sets none ---
    // --- aspect-ratio derives an auto height from the used width ---
    // --- align-items shifts flex items on the cross axis ---
    {
        auto rulesA = parseStylesheet(`
            body { margin: 0; }
            .rowA { display: flex; align-items: flex-end; }
            .tallA { width: 20px; height: 40px; }
            .shortA2 { width: 20px; height: 10px; }
        `, 200, 200);
        auto docA = new Element("body");
        auto rowA = new Element("div");
        rowA.attrs["class"] = "rowA";
        docA.children ~= rowA;
        docA.elements ~= rowA;
        rowA.parent = docA;
        auto tallA = new Element("div");
        tallA.attrs["class"] = "tallA";
        auto shortA = new Element("div");
        shortA.attrs["class"] = "shortA2";
        rowA.children ~= tallA;
        rowA.elements ~= tallA;
        tallA.parent = rowA;
        rowA.children ~= shortA;
        rowA.elements ~= shortA;
        shortA.parent = rowA;
        applyStylesAndLayout(docA, rulesA, 200, 200);
        assert(shortA.box.y == tallA.box.y + tallA.box.height - shortA.box.height,
            "align-items:flex-end must pack items to the cross-axis end, got y=" ~
            to!string(shortA.box.y) ~ " want " ~
            to!string(tallA.box.y + tallA.box.height - shortA.box.height));
    }

    // --- generated ::before/::after boxes take part in the flow ---
    {
        auto rulesP = parseStylesheet(`
            body { margin: 0; }
            .gen::before { content: "->"; display: inline-block; width: 20px;
                           height: 10px; }
            .gen::after { content: ""; display: block; height: 24px; }
        `, 200, 200);
        auto docP = new Element("body");
        auto gen = new Element("div");
        gen.attrs["class"] = "gen";
        docP.children ~= gen;
        docP.elements ~= gen;
        gen.parent = docP;
        auto label = new TextNode(gen, "word");
        label.parent = gen;
        gen.children ~= label;
        applyStylesAndLayout(docP, rulesP, 200, 200);

        assert(gen.pseudoBefore !is null && gen.pseudoAfter !is null,
            "a matching ::before/::after rule with content must generate a box");
        // The generated boxes are NOT visible to DOM/script APIs.
        assert(gen.children.length == 1 && gen.elements.length == 0,
            "generated boxes must stay out of children/elements, got " ~
            to!string(gen.children.length) ~ " children and " ~
            to!string(gen.elements.length) ~ " elements");
        assert(gen.pseudoBefore.box.width == 20 && gen.pseudoBefore.box.height == 10,
            "an in-flow generated box must be laid out, got " ~
            to!string(gen.pseudoBefore.box.width) ~ "x" ~
            to!string(gen.pseudoBefore.box.height));
        assert(gen.pseudoAfter.box.height == 24,
            "a block generated box must be laid out, got height " ~
            to!string(gen.pseudoAfter.box.height));
    }

    // --- a NEGATIVE inset is a value, not "unset" ---
    {
        auto rulesN = parseStylesheet(`
            body { margin: 0; }
            .ornN { position: absolute; top: 0; right: -10px; width: 100px;
                    height: 20px; }
        `, 400, 300);
        auto docN = new Element("body");
        auto ornN = new Element("div");
        ornN.attrs["class"] = "ornN";
        docN.children ~= ornN;
        docN.elements ~= ornN;
        ornN.parent = docN;
        applyStylesAndLayout(docN, rulesN, 400, 300);
        assert(ornN.box.x == 310,
            "right:-10px with width:100px in a 400px box starts at x=310 " ~
            "(a negative inset must not read as unset), got " ~
            to!string(ornN.box.x));
    }

    // --- absolutely positioned descendants of a grid item get a real box ---
    {
        auto rulesG = parseStylesheet(`
            body { margin: 0; }
            .g { display: grid; }
            .item { position: relative; }
            .orn { position: absolute; top: 0; height: 40px; width: 20px; }
        `, 400, 300);
        auto docG = new Element("body");
        auto g = new Element("div");
        g.attrs["class"] = "g";
        auto item = new Element("div");
        item.attrs["class"] = "item";
        auto orn = new Element("div");
        orn.attrs["class"] = "orn";
        item.children ~= orn;
        item.elements ~= orn;
        orn.parent = item;
        g.children ~= item;
        g.elements ~= item;
        item.parent = g;
        docG.children ~= g;
        docG.elements ~= g;
        g.parent = docG;
        applyStylesAndLayout(docG, rulesG, 400, 300);
        assert(orn.box.height == 40,
            "an absolutely positioned descendant of a grid item must be placed " ~
            "against the sized item, got height " ~ to!string(orn.box.height));
    }

    // --- an absolutely positioned box with auto height shrink-to-fits ---
    {
        auto rulesA = parseStylesheet(`
            body { margin: 0; }
            .ornament { position: absolute; top: 8px; left: 0; width: 40px; }
            .ornament .dot { display: block; height: 32px; }
        `, 400, 300);
        auto docA = new Element("body");
        auto orn = new Element("div");
        orn.attrs["class"] = "ornament";
        auto dot = new Element("div");
        dot.attrs["class"] = "dot";
        orn.children ~= dot;
        orn.elements ~= dot;
        dot.parent = orn;
        docA.children ~= orn;
        docA.elements ~= orn;
        orn.parent = docA;
        applyStylesAndLayout(docA, rulesA, 400, 300);
        assert(orn.box.height == 32,
            "an auto-height absolutely positioned box must shrink to fit its " ~
            "content (CSS 10.6.4), got " ~ to!string(orn.box.height));
    }

    // --- SVG metadata (<desc>/<title>/<defs>) must never render as text ---
    // --- markup indentation is not content (white-space: normal) ---
    {
        auto el = new Element("p");
        auto tn = new TextNode(el, "\n\t\t\t\t\t\t\tAlpha beta   gamma\ndelta ");
        assert(collapsibleText(el, tn) == "Alpha beta gamma delta ",
            "white-space:normal must collapse the markup's newlines and tabs, " ~
            "keeping one trailing space: got '" ~ collapsibleText(el, tn) ~ "'");
        // Preformatted text keeps every character, except tabs, which expand to
        // spaces (see expandTabs) so their advance is always positive.
        auto pre = new Element("pre");
        auto ptn = new TextNode(pre, "\n\tkeep me\n");
        assert(collapsibleText(pre, ptn) == "\n        keep me\n",
            "<pre> must keep its whitespace, with tabs expanded: got '" ~
            collapsibleText(pre, ptn) ~ "'");
    }

    {
        auto root5 = new Element("body");
        auto svg = new Element("svg");
        auto desc = new Element("desc");
        svg.children ~= desc;
        svg.elements ~= desc;
        desc.parent = svg;
        root5.children ~= svg;
        root5.elements ~= svg;
        svg.parent = root5;
        applyStylesAndLayout(root5, parseStylesheet("", 400, 300), 400, 300);
        assert(desc.style.display == "none",
            "an SVG <desc> is accessibility metadata, not content: a real page " ~
            "painted its illustration description as visible page text (display=" ~
            desc.style.display ~ ")");
        assert(desc.box.height == 0 && desc.box.width == 0,
            "an SVG <desc> must occupy no box");
    }

    {
        // Through the real cascade, not by poking the field: the earlier version
        // of this test passed while the property never reached the style.
        auto rules4 = parseStylesheet(`
            body { margin: 0; }
            .scene { width: 444px; aspect-ratio: 1200 / 520; }
        `, 1350, 800);
        auto doc4 = new Element("body");
        auto scene = new Element("figure");
        scene.attrs["class"] = "scene";
        doc4.children ~= scene;
        doc4.elements ~= scene;
        scene.parent = doc4;
        applyStylesAndLayout(doc4, rules4, 1350, 800);
        // 444 / (1200/520) = 192.4 -> 192
        assert(scene.box.height == 192,
            "aspect-ratio 1200/520 at width 444 is 192, got " ~
            to!string(scene.box.height));

        auto el = new Element("figure");
        el.style.display = "block";
        el.style.aspectRatio = "auto";
        el.box.width = 444;
        assert(resolveHeight(el) == -1,
            "aspect-ratio:auto leaves an auto height to the content");
    }

    {
        auto rules3 = parseStylesheet(`
            body { color: #f0eee8; }
            h1 { font-weight: 500; }
        `, 400, 300);
        auto doc3 = new Element("body");
        auto h = new Element("h1");
        doc3.children ~= h;
        doc3.elements ~= h;
        h.parent = doc3;
        applyStylesAndLayout(doc3, rules3, 400, 300);
        assert(h.style.color == "#f0eee8",
            "an element with no colour of its own must inherit it (a real page's " ~
            "hero wordmark painted black instead of the body colour), got '" ~
            h.style.color ~ "'");
    }

    {
        auto el = new Element("img");
        el.style.display = "block"; // the real page sets img { display: block }
        el.style.height = "auto";
        el.image = new RgbaImage(1920, 1080, new ubyte[](1920 * 1080 * 4));
        el.box.width = 735; // resolved from width:100%
        const h = resolveHeight(el);
        // 735 * 1080 / 1920 = 413
        assert(h == 413,
            "a block-level image with height:auto takes 735*1080/1920 = 413, got " ~
            to!string(h));
    }

    // --- max-width caps a block's width ---
    {
        auto rules2 = parseStylesheet(`
            body { margin: 0; width: 800px; }
            #wide { width: 739px; max-width: 34rem; }
        `, 800, 800);
        auto doc2 = new Element("body");
        auto wide = new Element("div");
        wide.attrs["id"] = "wide";
        doc2.children ~= wide;
        doc2.elements ~= wide;
        wide.parent = doc2;
        applyStylesAndLayout(doc2, rules2, 800, 800);
        assert(wide.box.width == 544,
            "max-width:34rem must cap a 739px block at 544, got " ~
            to!string(wide.box.width));
    }

    {
        auto cs = ComputedStyle();
        cs.viewportWidth = 1350;
        cs.viewportHeight = 800;
        cs.rootFontSizePx = 16;
        cs.fontSizePx = 16;
        // The exact inset a real page used for its dock bar: 11vw = 148px, which
        // is inside [4rem, 11rem] = [64, 176], so clamp() yields 148.
        assert(cs.resolveLength("clamp(4rem, 11vw, 11rem)", 0) == 148,
            "clamp(4rem, 11vw, 11rem) at 1350 wide is 148, got " ~
            to!string(cs.resolveLength("clamp(4rem, 11vw, 11rem)", 0)));
        // Below the lower bound it clamps up to the min.
        assert(cs.resolveLength("clamp(100px, 10px, 200px)", 0) == 100,
            "a value below clamp()'s floor must clamp up to it");
        // Above the upper bound it clamps down to the max.
        assert(cs.resolveLength("clamp(10px, 300px, 200px)", 0) == 200,
            "a value above clamp()'s ceiling must clamp down to it");
        assert(cs.resolveLength("min(10px, 20px, 30px)", 0) == 10,
            "min() takes the smallest argument");
        assert(cs.resolveLength("max(10px, 20px, 30px)", 0) == 30,
            "max() takes the largest argument");
    }

    {
        int dx = 0;
        int dy = 0;
        transformTranslate("translate(-50%, -50%)", 40, 20, dx, dy);
        assert(dx == -20 && dy == -10,
            "translate(-50%,-50%) of a 40x20 element is (-20,-10), got (" ~
            to!string(dx) ~ "," ~ to!string(dy) ~ ")");
        transformTranslate("translateY(-4px)", 40, 20, dx, dy);
        assert(dx == 0 && dy == -4,
            "translateY(-4px) is (0,-4), got (" ~ to!string(dx) ~ "," ~
            to!string(dy) ~ ")");
        transformTranslate("none", 40, 20, dx, dy);
        assert(dx == 0 && dy == 0, "transform:none must not shift");
    }

    // --- adjacent vertical margins collapse to the larger one ---
    // --- @media width queries select the right rules ---
    // Responsive pages put their real layout in @media blocks; ignoring the
    // condition makes every page render with only its base styles.
    {
        auto mrules = parseStylesheet(`
            body { margin: 0; }
            #mq { width: 10px; height: 10px; }
            @media (min-width: 600px) { #mq { width: 200px; } }
            @media (max-width: 599px) { #mq { width: 30px; } }
        `, 800, 800);
        auto mdoc = new Element("body");
        auto mq = new Element("div");
        mq.attrs["id"] = "mq";
        mdoc.children ~= mq;
        mdoc.elements ~= mq;
        mq.parent = mdoc;
        applyStylesAndLayout(mdoc, mrules, 800, 800);
        assert(mq.box.width == 200,
            "at 800px wide the min-width:600px rule must apply (200 expected), " ~
            "got " ~ to!string(mq.box.width));
        applyStylesAndLayout(mdoc, mrules, 400, 800);
        assert(mq.box.width == 30,
            "at 400px wide the max-width:599px rule must apply (30 expected), " ~
            "got " ~ to!string(mq.box.width));
    }

    // CSS collapses adjoining vertical margins: a 20px bottom margin meeting a
    // 30px top margin leaves 30px, not 50. Adding them puts extra gaps between
    // every stacked block on a page.
    {
        auto vrules = parseStylesheet(`
            body { margin: 0; width: 300px; }
            .a { height: 10px; margin-bottom: 20px; }
            .b { height: 10px; margin-top: 30px; }
        `, 300, 300);
        auto vdoc = new Element("body");
        auto va = new Element("div");
        va.attrs["class"] = "a";
        auto vb = new Element("div");
        vb.attrs["class"] = "b";
        foreach (it; [va, vb])
        {
            vdoc.children ~= it;
            vdoc.elements ~= it;
            it.parent = vdoc;
        }
        applyStylesAndLayout(vdoc, vrules, 300, 300);
        assert(va.box.y == 0,
            "the first block starts at the top (0 expected), got " ~
            to!string(va.box.y));
        assert(vb.box.y == 40,
            "collapsed margins leave 30px between the blocks (40 expected, " ~
            "50 would be uncollapsed), got " ~ to!string(vb.box.y));
    }

    // The most common centring technique on the web is a fixed-width block with
    // auto left/right margins; a plain block margin must indent too.
    {
        auto rules = parseStylesheet(`
            body { margin: 0; width: 300px; }
            #indent { width: 100px; margin-left: 20px; }
            #center { width: 100px; margin-left: auto; margin-right: auto; }
        `, 300, 300);
        auto bdoc = new Element("body");
        auto bind = new Element("div");
        bind.attrs["id"] = "indent";
        auto bcen = new Element("div");
        bcen.attrs["id"] = "center";
        foreach (it; [bind, bcen])
        {
            bdoc.children ~= it;
            bdoc.elements ~= it;
            it.parent = bdoc;
        }
        applyStylesAndLayout(bdoc, rules, 300, 300);
        assert(bind.box.x == 20,
            "a block's left margin must indent it (20 expected), got " ~
            to!string(bind.box.x));
        assert(bcen.box.x == 100,
            "margin:0 auto must centre a fixed-width block (100 expected), got " ~
            to!string(bcen.box.x));
    }

    // Two padded items (60 outer each = 120) centred in 300 must start at 90.
    // Measuring the free space from content widths alone put them 20px right.
    {
        auto crow2 = new Element("div");
        crow2.style.display = "flex";
        crow2.style.justifyContent = "center";
        Element[] cits;
        foreach (k; 0 .. 2)
        {
            auto it = new Element("a");
            it.style.display = "inline-flex";
            it.style.width = "40px";
            it.style.padding = "10px";
            crow2.children ~= it;
            crow2.elements ~= it;
            it.parent = crow2;
            cits ~= it;
        }
        auto cf = FlowContext();
        cf.x = 0;
        cf.y = 0;
        cf.width = 300;
        cf.height = 60;
        cf.lineEnd = 300;
        layoutFlex(crow2, cf, null);
        assert(cits[0].box.x == 90,
            "centred padded items must start at 90 (outer sizes), got " ~
            to!string(cits[0].box.x));
        assert(cits[1].box.x == 150,
            "the second centred item belongs at 150, got " ~
            to!string(cits[1].box.x));
    }

    // box.width is the content box, so the next item must start after the
    // item's content plus its padding and border. Counting only the content
    // width would overlap every padded item - toolbar buttons, pills, cards.
    {
        auto prow2 = new Element("div");
        // inline-flex with auto width also proves the container's own width
        // counts the items' outer sizes.
        prow2.style.display = "inline-flex";
        auto pa2 = new Element("a");
        pa2.style.display = "inline-flex";
        pa2.style.width = "40px";
        pa2.style.padding = "10px";
        pa2.style.border = "5px solid #000";
        auto pb2 = new Element("a");
        pb2.style.display = "inline-flex";
        pb2.style.width = "40px";
        foreach (it; [pa2, pb2])
        {
            prow2.children ~= it;
            prow2.elements ~= it;
            it.parent = prow2;
        }
        auto pf3 = FlowContext();
        pf3.x = 0;
        pf3.y = 0;
        pf3.width = 400;
        pf3.height = 60;
        pf3.lineEnd = 400;
        layoutFlex(prow2, pf3, null);
        // 40 content + 20 padding + 10 border = 70 outer.
        assert(pb2.box.x >= 70,
            "the next item must start after the previous item's outer size " ~
            "(70 expected), got " ~ to!string(pb2.box.x));
        assert(prow2.box.width >= 110,
            "an auto-width container must span the items' outer sizes " ~
            "(110 expected), got " ~ to!string(prow2.box.width));
    }

    // --- overflowing content stays inside the container (overflow-safe) ---
    // A row whose items are wider than its content box must not start to the
    // LEFT of that box: browsers align the content inside. A real page's nav
    // link was placed 24px left of its container and clipped its neighbour.
    {
        auto orow2 = new Element("div");
        orow2.style.display = "flex";
        orow2.style.justifyContent = "center";
        auto o1b = new Element("a");
        o1b.style.display = "inline-flex";
        o1b.style.width = "120px";
        auto o2b = new Element("a");
        o2b.style.display = "inline-flex";
        o2b.style.width = "120px";
        foreach (it; [o1b, o2b])
        {
            orow2.children ~= it;
            orow2.elements ~= it;
            it.parent = orow2;
        }
        auto oflow = FlowContext();
        oflow.x = 0;
        oflow.y = 0;
        oflow.width = 200; // 240 of content in a 200 box: overflows
        oflow.height = 60;
        oflow.lineEnd = 200;
        layoutFlex(orow2, oflow, null);
        assert(o1b.box.x == 0,
            "overflowing centred content must start at the content box, got " ~
            to!string(o1b.box.x));
    }

    // With justify-content:center the items' x depends on the container width.
    // A box left over from a wider pass (instead of being reassigned) is exactly
    // how a real page's nav link kept an x from an earlier pass and clipped its
    // neighbour.
    {
        auto crow = new Element("div");
        crow.style.display = "flex";
        crow.style.justifyContent = "center";
        auto c1 = new Element("a");
        c1.style.display = "inline-flex";
        c1.style.width = "40px";
        auto c2 = new Element("a");
        c2.style.display = "inline-flex";
        c2.style.width = "40px";
        foreach (it; [c1, c2])
        {
            crow.children ~= it;
            crow.elements ~= it;
            it.parent = crow;
        }
        auto wide = FlowContext();
        wide.x = 0;
        wide.y = 0;
        wide.width = 500;
        wide.height = 60;
        wide.lineEnd = 500;
        layoutFlex(crow, wide, null);
        // 500 - 80 = 420 free, centred: first item at 210.
        assert(c1.box.x == 210,
            "centred first item should be at 210, got " ~ to!string(c1.box.x));
        // Re-lay narrower: 200 - 80 = 120 free, so the first item must move left.
        auto narrow2 = FlowContext();
        narrow2.x = 0;
        narrow2.y = 0;
        narrow2.width = 200;
        narrow2.height = 60;
        narrow2.lineEnd = 200;
        layoutFlex(crow, narrow2, null);
        assert(c1.box.x == 60,
            "a re-layout must reassign positions (60 expected), got " ~
            to!string(c1.box.x));
        // Centre packs the items together (no extra gaps): c2 follows c1.
        assert(c2.box.x == 100,
            "the second item must be reassigned too (100 expected), got " ~
            to!string(c2.box.x));
    }

    // CSS puts the item's border box at cursor + margin-left and advances the
    // cursor by the item's outer size (width + margins). Ignoring that made
    // margined items sit too far left and overlap their neighbour - the nav's
    // "Home" link ended up on top of "Contact".
    {
        auto mrow = new Element("div");
        mrow.style.display = "flex";
        auto ma = new Element("div");
        ma.style.width = "50px";
        ma.style.marginLeft = "20px";
        auto mb = new Element("div");
        mb.style.width = "50px";
        mb.style.marginLeft = "10px";
        foreach (it; [ma, mb])
        {
            mrow.children ~= it;
            mrow.elements ~= it;
            it.parent = mrow;
        }
        auto mf = FlowContext();
        mf.x = 0;
        mf.y = 0;
        mf.width = 300;
        mf.height = 60;
        mf.lineEnd = 300;
        layoutFlex(mrow, mf, null);
        assert(ma.box.x == 20,
            "the first item's border box starts after its left margin, got " ~
            to!string(ma.box.x));
        assert(mb.box.x == 80,
            "the next item starts after the previous item's outer size, got " ~
            to!string(mb.box.x));
    }

    // The same tree laid out twice at different available widths must end
    // consistent: every item's contents stay inside it and items never overlap.
    // On a real page a child link kept the x from a stale pass while its
    // container had moved, so it clipped its neighbour.
    {
        auto prow = new Element("div");
        prow.style.display = "flex";
        auto pa = new Element("div");
        pa.style.width = "100px";
        auto pb = new Element("div");
        pb.style.display = "inline-flex"; // auto width: sizes to its content
        auto pbChild = new Element("span");
        pbChild.style.width = "150px";
        pb.children ~= pbChild;
        pb.elements ~= pbChild;
        pbChild.parent = pb;
        auto pc = new Element("div");
        pc.style.width = "50px";
        foreach (it; [pa, pb, pc])
        {
            prow.children ~= it;
            prow.elements ~= it;
            it.parent = prow;
        }
        // First pass: plenty of room.
        auto pf1 = FlowContext();
        pf1.x = 0;
        pf1.y = 0;
        pf1.width = 400;
        pf1.height = 60;
        pf1.lineEnd = 400;
        layoutFlex(prow, pf1, null);
        // Second pass: tighter, which moves every item.
        auto pf2 = FlowContext();
        pf2.x = 0;
        pf2.y = 0;
        pf2.width = 300;
        pf2.height = 60;
        pf2.lineEnd = 300;
        layoutFlex(prow, pf2, null);
        assert(pbChild.box.x >= pb.box.x,
            "a child must not sit behind its container after relayout: child=" ~
            to!string(pbChild.box.x) ~ " container=" ~ to!string(pb.box.x));
        assert(pc.box.x >= pb.box.x + pb.box.width,
            "following items must sit after the container's actual box: pb=" ~
            to!string(pb.box.x) ~ "+" ~ to!string(pb.box.width) ~ " pc=" ~
            to!string(pc.box.x));
    }

    // An inline-flex item with auto width sizes to its content during its own
    // layout, which can exceed the pre-layout estimate. Following items must sit
    // after the real box, or they overlap (a real page's social row did).
    {
        auto orow = new Element("div");
        orow.style.display = "flex";
        auto o1 = new Element("div");
        o1.style.display = "inline-flex";
        auto innerChild = new Element("span");
        innerChild.style.width = "60px";
        o1.children ~= innerChild;
        o1.elements ~= innerChild;
        innerChild.parent = o1;
        auto o2 = new Element("div");
        o2.style.width = "20px";
        orow.children ~= o1;
        orow.elements ~= o1;
        o1.parent = orow;
        orow.children ~= o2;
        orow.elements ~= o2;
        o2.parent = orow;
        auto of = FlowContext();
        of.x = 0;
        of.y = 0;
        of.width = 300;
        of.height = 60;
        of.lineEnd = 300;
        layoutFlex(orow, of, null);
        assert(o2.box.x >= o1.box.x + o1.box.width,
            "a following item must sit after the previous item's actual box: o1=" ~
            to!string(o1.box.x) ~ "+" ~ to!string(o1.box.width) ~ " o2=" ~
            to!string(o2.box.x));
    }

    // A hidden sibling must not take a flex slot or contribute width.
    {
        auto hrow = new Element("div");
        hrow.style.display = "inline-flex";
        auto h1 = new Element("span");
        h1.style.width = "20px";
        auto h2 = new Element("span");
        h2.style.display = "none";
        h2.style.width = "40px";
        auto h3 = new Element("span");
        h3.style.width = "20px";
        foreach (it; [h1, h2, h3])
        {
            hrow.children ~= it;
            hrow.elements ~= it;
            it.parent = hrow;
        }
        auto hf = FlowContext();
        hf.x = 0;
        hf.y = 0;
        hf.width = 300;
        hf.height = 60;
        hf.lineEnd = 300;
        layoutFlex(hrow, hf, null);
        assert(hrow.box.width <= 45,
            "a display:none child must not widen an inline-flex container, got " ~
            hrow.box.width.to!string);
        assert(h3.box.x == 20,
            "visible siblings must pack together, third item at " ~
            to!string(h3.box.x));
    }

    // Three 20px items in a 200px row: 140px free, split into two 70px gaps, so
    // the items sit at 0, 90 and 180 with the last flush to the right edge. The
    // parser accepted space-between without ever applying it, which packed every
    // navbar, toolbar and card row to the left.
    {
        auto srow = new Element("div");
        srow.style.display = "flex";
        srow.style.justifyContent = "space-between";
        Element[] three;
        foreach (k; 0 .. 3)
        {
            auto it = new Element("span");
            it.style.width = "20px";
            srow.children ~= it;
            srow.elements ~= it;
            it.parent = srow;
            three ~= it;
        }
        auto sf = FlowContext();
        sf.x = 0;
        sf.y = 0;
        sf.width = 200;
        sf.height = 50;
        sf.lineEnd = 200;
        layoutFlex(srow, sf, null);
        assert(three[0].box.x == 0,
            "space-between keeps the first item at the start, got " ~
            to!string(three[0].box.x));
        assert(three[1].box.x == 90,
            "space-between centres the middle item, got " ~
            to!string(three[1].box.x));
        assert(three[2].box.x == 180,
            "space-between puts the last item flush right, got " ~
            to!string(three[2].box.x));
    }

    // Each auto margin gets free_space / number_of_auto_margins. Handing every
    // auto item the whole leftover moved later items twice, so a real page's nav
    // put "Home" on top of "Contact".
    {
        auto row = new Element("div");
        row.style.display = "flex";
        auto a1 = new Element("a");
        a1.style.marginLeft = "auto";
        a1.style.width = "20px";
        auto a2 = new Element("a");
        a2.style.marginLeft = "auto";
        a2.style.width = "20px";
        a2.children ~= new TextNode(a2, "Hi");
        // A non-inline child must travel with the item too: the engine's
        // inline-only helper left block children behind, so a real nav's links
        // (inside a flex row) ended up overlapping their neighbour.
        auto inner = new Element("div");
        inner.style.display = "block";
        a2.children ~= inner;
        a2.elements ~= inner;
        inner.parent = a2;
        row.children ~= a1;
        row.elements ~= a1;
        a1.parent = row;
        row.children ~= a2;
        row.elements ~= a2;
        a2.parent = row;
        auto rf2 = FlowContext();
        rf2.x = 0;
        rf2.y = 0;
        rf2.width = 300;
        rf2.height = 60;
        rf2.lineEnd = 300;
        layoutFlex(row, rf2, null);
        assert(a2.box.x >= a1.box.x + a1.box.width,
            "auto-margined siblings must not overlap: a1=" ~
            to!string(a1.box.x) ~ " w=" ~ to!string(a1.box.width) ~
            " a2=" ~ to!string(a2.box.x));
        // A shifted item carries its children: the text must stay inside it.
        auto tn2 = cast(TextNode) a2.children[0];
        assert(tn2 !is null && tn2.layoutX >= a2.box.x,
            "a shifted flex item must carry its text: text=" ~
            (tn2 is null ? "null".dup : to!string(tn2.layoutX)) ~
            " box=" ~ to!string(a2.box.x));
        assert(inner.box.x >= a2.box.x,
            "a shifted item must carry a block child: inner=" ~
            to!string(inner.box.x) ~ " box=" ~ to!string(a2.box.x));
    }

    // `<button>Label</button>` must be as tall as its text: with no flex items
    // maxChildHeight stayed 0, so the box collapsed to zero height and the
    // text overflowed it with no hit area.
    {
        auto btn = new Element("button");
        btn.style.display = "inline-flex";
        auto tn = new TextNode(btn, "Public");
        btn.children ~= tn;
        auto bf = FlowContext();
        bf.x = 0;
        bf.y = 0;
        bf.width = 200;
        bf.height = 200;
        bf.lineEnd = 200;
        layoutFlex(btn, bf, null);
        assert(btn.box.height > 8,
            "an inline-flex button must be as tall as its text, got " ~
            btn.box.height.to!string);
    }



    // --- z-index parse ---
    {
        auto el = new Element("div");
        el.style = computedStyle(el, []);
        assert(el.style.zIndex == 0, "default z-index is 0");
        auto cssRules = parseStylesheet(`#z2 { z-index: 2; }`);
        auto el2 = new Element("div");
        el2.attrs["id"] = "z2";
        el2.style = computedStyle(el2, cssRules);
        assert(el2.style.zIndex == 2,
            "z-index:2 should parse to 2, got " ~ el2.style.zIndex.to!string);
    }

    // --- opacity parse + clamp ---
    {
        auto el = new Element("div");
        el.style = computedStyle(el, []);
        assert(el.style.opacity == 1.0, "default opacity is 1");
        auto cssRules = parseStylesheet(`.o { opacity: 0.5; }`);
        auto el2 = new Element("div");
        el2.attrs["class"] = "o";
        el2.style = computedStyle(el2, cssRules);
        assert(el2.style.opacity == 0.5,
            "opacity:0.5 should parse to 0.5, got " ~ el2.style.opacity.to!string);
    }
}

unittest
{
    import auroraweb.dom : Element;
    import std.conv : to;

    // --- Negative margins collapse ---
    // Sibling A has margin-bottom:-20px, sibling B has margin-top:-30px.
    // One positive + one negative margin sum; both are negative here, so the
    // most negative (-30px) wins and B overlaps A's bottom by 30px.
    {
        auto a = new Element("div"); a.style.display = "block";
        a.style.height = "40px"; a.style.marginBottom = "-20px";
        auto b = new Element("div"); b.style.display = "block";
        b.style.height = "20px"; b.style.marginTop = "-30px";
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(a, flow, 100, null);
        layoutBlock(b, flow, 100, null);
        // a: y=0..40, margin-bottom -20 -> next flow y = 20.
        // b: margin-top -30 collapses with -20 to -30 (most negative):
        //    border-box gap = -30, so b's top = a's bottom (40) - 30 = 10.
        assert(a.box.y == 0, "a.y should be 0, got " ~ a.box.y.to!string);
        assert(a.box.height == 40, "a.height should be 40, got " ~ a.box.height.to!string);
        assert(b.box.y == 10,
            "b.y should be 10 (a bottom 40 - collapsed -30 margin), got " ~ b.box.y.to!string);
        // The two boxes overlap by exactly 30px (a's bottom 30px of vertical
        // extent is covered by b's top).
        const overlap = (a.box.y + a.box.height) - b.box.y;
        assert(overlap == 30,
            "b should overlap a by 30px, got " ~ overlap.to!string);
    }

    // --- Mixed-sign margin collapsing: negative + positive sums ---
    // A's bottom margin +20 and B's top margin -10 sum to +10 (per CSS:
    // one positive + one negative -> sum).
    {
        auto a = new Element("div"); a.style.display = "block";
        a.style.height = "10px"; a.style.marginBottom = "20px";
        auto b = new Element("div"); b.style.display = "block";
        b.style.height = "10px"; b.style.marginTop = "-10px";
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 100; flow.height = 400;
        layoutBlock(a, flow, 100, null);
        layoutBlock(b, flow, 100, null);
        assert(b.box.y == 20,
            "20 + (-10) = 10 collapsed -> b.y should be 10 + 10 (height) = 20, got " ~ b.box.y.to!string);
        assert(b.box.y - (a.box.y + a.box.height) == 10,
            "gap should be 10, got " ~ (b.box.y - (a.box.y + a.box.height)).to!string);
    }

    // --- Flex item min/max-width clamp ---
    // A single flex-grow:1 item in a 300px container with max-width:50px must
    // stay at 50px (the container would otherwise give it the full 300px).
    {
        auto flex = new Element("div");
        flex.style.display = "flex";
        flex.style.width = "300px";
        auto kid = new Element("div");
        kid.style.display = "block";
        kid.style.flexGrow = "1";
        kid.style.maxWidth = "50px";
        kid.style.height = "10px";
        kid.parent = flex;
        flex.children ~= kid; flex.elements ~= kid;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 100;
        layoutFlex(flex, flow, null);
        assert(kid.box.width == 50,
            "flex item with flex-grow:1 and max-width:50px must stay 50px, got " ~
            kid.box.width.to!string);
        // And it should hug the left edge (flex-start).
        assert(kid.box.x == 0, "flex item x=0, got " ~ kid.box.x.to!string);
    }

    // --- Flex min-width clamp ---
    // A flex-grow:0 item with an explicit 10px width but min-width:80px must
    // resolve to 80px.
    {
        auto flex = new Element("div");
        flex.style.display = "flex";
        flex.style.width = "300px";
        auto kid = new Element("div");
        kid.style.display = "block";
        kid.style.width = "10px";
        kid.style.minWidth = "80px";
        kid.parent = flex;
        flex.children ~= kid; flex.elements ~= kid;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 100;
        layoutFlex(flex, flow, null);
        assert(kid.box.width == 80,
            "flex item min-width:80px should clamp to 80, got " ~ kid.box.width.to!string);
    }

    // --- Flex margin-left:auto pushes the item to the far side ---
    // Two items in a 300px container; the second has margin-left:auto so it
    // ends flush at the right edge (x = 300 - width).
    {
        auto flex = new Element("div");
        flex.style.display = "flex";
        flex.style.width = "300px";
        auto k1 = new Element("div");
        k1.style.display = "block"; k1.style.width = "40px"; k1.style.height = "10px";
        auto k2 = new Element("div");
        k2.style.display = "block"; k2.style.width = "60px"; k2.style.height = "10px";
        k2.style.marginLeft = "auto";
        k1.parent = flex; k2.parent = flex;
        flex.children ~= k1; flex.children ~= k2;
        flex.elements ~= k1; flex.elements ~= k2;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 100;
        layoutFlex(flex, flow, null);
        assert(k1.box.x == 0, "first item x=0, got " ~ k1.box.x.to!string);
        assert(k2.box.x == 240,
            "margin-left:auto item should sit at the far side (x=240), got " ~
            k2.box.x.to!string);
        assert(k2.box.x + k2.box.width == 300,
            "auto-margin item must end at the container's right edge, got " ~
            (k2.box.x + k2.box.width).to!string);
    }

    // --- Percentage line-height resolves against font-size ---
    // line-height:200% with a 16px font gives 32px line boxes.
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.fontSize = "16px";
        container.style.fontSizePx = 16;
        container.style.lineHeight = "200%";
        auto textNode = new TextNode(container, "Double spaced");
        container.children ~= textNode;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 300;
        flow.lineEnd = 300;
        layoutDirectText(container, flow);
        assert(flow.contentBottom == 32,
            "line-height:200% of 16px font should give 32px line boxes, got " ~
            flow.contentBottom.to!string);
    }

    // --- Percentage line-height uses the element's font-size, not the
    // containing block's (the container font is 40px, the child line-height
    // resolves against ITS OWN 16px font) ---
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.fontSize = "40px";
        container.style.fontSizePx = 40;
        container.style.lineHeight = "200%";
        auto textNode = new TextNode(container, "Child sized");
        container.children ~= textNode;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 300;
        flow.lineEnd = 300;
        layoutDirectText(container, flow);
        assert(flow.contentBottom == 80,
            "200% of 40px font should be 80px line boxes, got " ~
            flow.contentBottom.to!string);
    }

    // --- Inline-block baseline alignment ---
    // A text run then an inline-block: the inline-block's bottom must align
    // with the text baseline (baseline = cursorY + ascent, ascent ~ font-size).
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.fontSize = "16px";
        container.style.fontSizePx = 16;
        auto tn = new TextNode(container, "ab");
        auto ib = new Element("span");
        ib.style.display = "inline-block";
        ib.style.width = "20px";
        ib.style.height = "40px";
        tn.parent = container; ib.parent = container;
        container.children ~= tn; container.children ~= ib;
        container.elements ~= ib;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 300;
        flow.lineEnd = 300;
        layoutDirectText(container, flow);
        // Text sits on the first line at y=0; baseline = 0 + 16 = 16.
        // The inline-block's bottom must be on that baseline: y = 16 - 40.
        assert(ib.box.y == 16 - 40,
            "inline-block bottom should align with the baseline (y=" ~ (16 - 40).to!string ~
            "), got " ~ ib.box.y.to!string);
        assert(ib.box.y + ib.box.height == 16,
            "inline-block bottom must be exactly on the baseline, got " ~
            (ib.box.y + ib.box.height).to!string);
    }
}



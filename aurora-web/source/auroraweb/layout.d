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

import auroraweb.css : Rule, RuleIndex, buildRuleIndex, candidatesFor, cascadeFor,
    applyMediaRules, parseStylesheet,
    keyframeEndState, pseudoElementRules;
import auroraweb.dom : ComputedStyle, Element, InlineFragment, TextNode;
import auroraweb.shaping : cssFace, cssFaceOrStandard, normalLineHeight, shapeTextCached;
import aurora.image : RgbaImage;
import aurora.font : FontFace, FontRole;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : TextLayout, TextLayoutOptions;

import std.algorithm : max, min;
import std.conv : to;
import std.string : endsWith, indexOf, lastIndexOf, split, strip, toLower;

/// The face this style's `font-family`/`font-weight`/`font-style` select, or the
/// browser's standard font for a style that names none. Paint resolves it
/// identically, so measurement and painting always shape with the same face.
private const(FontFace) faceOf(const ComputedStyle* style)
{
    return style is null ? null
        : cssFaceOrStandard(style.fontFamily, style.fontWeight, style.fontStyle);
}

/// Measure a text run into wrapped lines using Aurora's real text engine.
/// `maxWidth` is the wrap width (0 = no wrap). Returns the TextLayout (or null
/// on failure). This is what makes layout match painting.
private TextLayout shapeText(string text, int pixelSize, int maxWidth,
    double letterSpacing = 0.0, const(FontFace) face = null)
{
    // Memoized: layout measures every run, and paint then shapes the same runs.
    return shapeTextCached(text, pixelSize, maxWidth, maxWidth > 0, letterSpacing, face);
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

/// ASCII case-insensitive comparison. Used for HTML attribute values such as
/// `type`; `std.ascii.toLower` is char-wise only, so it cannot be applied to a
/// whole string.
private bool asciiCaseEquals(string a, string b)
{
    if (a.length != b.length) return false;
    foreach (idx; 0 .. a.length)
    {
        char x = a[idx];
        char y = b[idx];
        if (x >= 'A' && x <= 'Z') x = cast(char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = cast(char)(y + 32);
        if (x != y) return false;
    }
    return true;
}

/// True for a flex container whose main axis is horizontal: its items sit side
/// by side, so its intrinsic width is the SUM of theirs rather than the widest.
private bool isRowFlexContainer(Element e)
{
    const d = e.style.display;
    if (d != "flex" && d != "inline-flex") return false;
    return e.style.flexDirection != "column" && e.style.flexDirection != "column-reverse";
}

/// Max-content (intrinsic) width of an element: a single unwrapped line for
/// inline content, or the widest block child. Includes the element's own
/// padding/border. Used to size auto-width flex items to their content (an
/// item with no explicit width must not collapse to 0).
/// `applyTextTransform` for the common `none` case: the intrinsic width passes
/// run once per text node, so allocating an identical copy every time showed up
/// in the layout timing.
private string transformed(string transform, string text)
{
    return transform == "uppercase" || transform == "lowercase" ||
        transform == "capitalize" ? applyTextTransform(transform, text) : text;
}

/// Does the `size` attribute govern this control's own width? Chromium sizes a
/// *text entry* control by the number of characters that fit; the other input
/// types have rules of their own (a checkbox/radio/date control is fixed, a
/// submit button shrink-to-fits its label, a file control has its own chrome),
/// so the intrinsic control model below must not claim those.
private bool controlSizedByChars(Element e)
{
    if (e.tag != "input" && e.tag != "textarea") return false;
    if (e.tag == "textarea") return true;              // `cols`, default 20
    if (auto t = "type" in e.attrs)
    {
        const type = (*t).strip().toLower();
        return type.length == 0 || type == "text" || type == "search" ||
            type == "tel" || type == "url" || type == "email" ||
            type == "password" || type == "number";
    }
    return true;                                       // no type = text
}

/// The number of line boxes a `textarea` shows: its `rows` attribute, default 2
/// (Chromium's UA sheet). Its height is that many line boxes plus chrome.
private int textareaRows(Element e)
{
    if (auto v = "rows" in e.attrs)
    {
        const n = (*v).strip();
        if (n.length)
            try
            {
                const parsed = to!int(n);
                if (parsed >= 1) return parsed;
            }
            catch (Exception) { /* a malformed attribute keeps the default */ }
    }
    return 2;
}

/// The `width: auto` CONTENT width of a text control, or `-1` when the control
/// model does not govern this element (`own` is its padding + border).
///
/// A control is replaced-like: its automatic width is its intrinsic control
/// width, not the containing block's. Without this an `input` stretched to its
/// container — the placeholder fixture's fields measured 1264px wide where Edge
/// gives 177 — and any field inside a wide column did the same on a real page.
///
/// Chromium derives that width from the `size` attribute in characters. Fitted
/// against Edge's own boxes for a `size` sweep (4/10/20/40 at the 13.3333px
/// control font, at 16px and at 20px) the BORDER box is exactly
///
///     size x avgCharWidth + round(2.1 x fontPx) + 9
///
/// where `avgCharWidth` is the face's mean advance over the lowercase alphabet,
/// digits and space — 0.503em for Arial, i.e. the 7px Edge reports at 13.3333px
/// and 8px at 16px. All ten measured boxes reproduce to the pixel, and the model
/// follows the face, so a control set in a wider family widens with it.
private int controlContentWidth(Element e, int own)
{
    if (!controlSizedByChars(e)) return -1;
    int chars = 20;                                    // Chromium's default
    const attr = e.tag == "textarea" ? "cols" : "size";
    if (auto v = attr in e.attrs)
    {
        const n = (*v).strip();
        if (n.length)
            try
            {
                const parsed = to!int(n);
                if (parsed >= 1) chars = parsed;
            }
            catch (Exception) { /* a malformed attribute keeps the default */ }
    }
    const fontPx = e.style.fontSizePx > 0 ? e.style.fontSizePx : 16;
    // The font-SCALED term follows the CSS font size, not the engine's integer
    // text pixel size: Chromium's control font is 13.3333px, and rounding that
    // to 13 loses a pixel of it (176 where Edge gives 177). The per-character
    // term stays the engine's own measurement, because that is the size the
    // glyphs are actually shaped at.
    double cssPx = fontPx;
    if (endsWith(e.style.fontSize, "px"))
        try cssPx = to!double(e.style.fontSize[0 .. $ - 2]);
        catch (Exception) { /* not a plain px length: keep the integer size */ }
    // One shaped run of the reference set, memoized by the shape cache.
    auto measured = shapeText("abcdefghijklmnopqrstuvwxyz0123456789 ", fontPx,
        0, 0.0, faceOf(&e.style));
    const int avg = measured !is null && measured.width > 0
        ? cast(int) (measured.width / 37.0 + 0.5) : max(1, fontPx / 2);
    const int borderBox = chars * avg + cast(int) (2.1 * cssPx + 0.5) + 9;
    return max(0, borderBox - own);
}

/// A width derived from a measured text run, rounded UP to whole pixels.
///
/// Boxes are stored as whole pixels, so truncating a measured run makes the box
/// narrower than the text it holds and the run then wraps onto a second line -
/// where a browser, which keeps fractional widths internally, keeps one. Each of
/// django's 13px uppercase header labels was 1px narrower than its own text, so
/// every label wrapped and the menu came out 16px too tall with two rows of ink
/// where Edge paints one. `TextLayout.measuredSize` rounds up the same way.
private static int measuredWidth(const TextLayout run, int fallback)
{
    if (run is null || run.width <= 0) return fallback;
    const int whole = cast(int) run.width;
    return run.width > whole ? whole + 1 : whole;
}

private int intrinsicWidth(Element e, int percentBase)
{
    resolveBoxMetrics(e, percentBase);
    const pixelSize = e.style.fontSizePx > 0 ? e.style.fontSizePx : 16;
    const own = e.box.paddingLeft + e.box.paddingRight + e.box.borderLeft + e.box.borderRight;

    const explicit = e.style.resolveLength(e.style.width, percentBase);
    if (explicit >= 0) return explicit + own;

    // A text control's automatic width is its own, not its content's.
    const int control = controlContentWidth(e, own);
    if (control >= 0) return control + own;

    int inlineW = 0;
    int blockW = 0;
    bool hasBlock = false;
    // A flex row's items sit side by side, so its intrinsic width is the sum of
    // their contributions. Taking the widest (block semantics) measured an
    // `ul{display:flex}` around ten links as ONE link wide, which left a real
    // site's header menu box 109px wide around 668px of content: the menu was
    // clipped at its first link by the ancestor's `overflow:hidden`.
    const rowFlex = isRowFlexContainer(e);
    const gapPx = rowFlex ? max(0, e.style.resolveLength(e.style.gap, percentBase)) : 0;
    int itemCount = 0;
    foreach (child; e.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            // `strip` would treat U+00A0 as whitespace: a `&nbsp;` run is inline
            // content and must contribute its own width.
            if (!isCollapsibleWhitespaceOnly(t.data))
            {
                // `text-transform` widens a run (`uppercase`), and the inline
                // layout shapes the transformed text. Measuring the raw text
                // here under-sized the box, so django's `li>a` (uppercase,
                // inherited from `header nav li`) received the 52px width of
                // "Overview" for the ~70px "OVERVIEW" it actually painted, and
                // the flex item then wrapped its own label mid-word.
                auto lay = shapeText(transformed(e.style.textTransform, t.data),
                    pixelSize, 1_000_000, 0.0, faceOf(&e.style));
                inlineW += measuredWidth(lay, cast(int)(t.data.length * 8));
                itemCount++;
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
        if (rowFlex)
        {
            // Every in-flow child of a flex container is an item (an inline one
            // is blockified), and items do not overlap: sum them.
            inlineW += intrinsicWidth(ce, percentBase);
            itemCount++;
        }
        else if (d == "inline" || d == "inline-block" || d == "inline-flex")
            inlineW += intrinsicWidth(ce, percentBase);
        else
        {
            hasBlock = true;
            blockW = max(blockW, intrinsicWidth(ce, percentBase));
        }
    }
    if (rowFlex && itemCount > 1) inlineW += gapPx * (itemCount - 1);
    int content = hasBlock ? max(blockW, inlineW) : inlineW;
    // Fallback: no contributory child was seen (e.g. text stored only in the
    // node's own content) — measure the element's text directly.
    if (content == 0)
    {
        auto txt = transformed(e.style.textTransform, e.textContent().strip());
        if (txt.length)
        {
            auto lay = shapeText(txt, pixelSize, 1_000_000, 0.0, faceOf(&e.style));
            content = measuredWidth(lay, cast(int)(txt.length * 8));
        }
    }
    return content + own;
}

/// Min-content width: the widest single word for text, or the widest block
/// child. Used as the automatic minimum size of a flex item (CSS
/// `min-width: auto`) so a shrunk item never forces its own text to wrap.
private int minContentWidth(Element e, int percentBase, bool ignoreSpecifiedWidth = false)
{
    resolveBoxMetrics(e, percentBase);
    const own = e.box.paddingLeft + e.box.paddingRight + e.box.borderLeft + e.box.borderRight;
    const explicit = e.style.resolveLength(e.style.width, percentBase);
    if (explicit >= 0 && !ignoreSpecifiedWidth) return explicit + own;
    const pixelSize = e.style.fontSizePx > 0 ? e.style.fontSizePx : 16;

    int widestWord = 0;
    int inlineSum = 0;
    int blockMax = 0;
    bool hasBlock = false;
    // Min-content follows the same main-axis rule: a flex row is as wide as the
    // sum of its items' min-content contributions.
    const rowFlex = isRowFlexContainer(e);
    const gapPx = rowFlex ? max(0, e.style.resolveLength(e.style.gap, percentBase)) : 0;
    int itemCount = 0;
    foreach (child; e.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            // Same reason as `intrinsicWidth`: the automatic minimum size must
            // measure what is painted, or a shrunk flex item wraps its label.
            foreach (word; transformed(e.style.textTransform, t.data).split())
            {
                auto lay = shapeText(word, pixelSize, 1_000_000, 0.0, faceOf(&e.style));
                widestWord = max(widestWord, measuredWidth(lay, 0));
            }
            if (!isCollapsibleWhitespaceOnly(t.data)) itemCount++;
            continue;
        }
        auto ce = cast(Element) child;
        if (ce is null) continue;
        auto d = ce.style.display;
        if (d == "none") continue;
        if (ce.style.position == "absolute" || ce.style.position == "fixed") continue;
        if (rowFlex)
        {
            inlineSum += minContentWidth(ce, percentBase);
            itemCount++;
        }
        else if (d == "inline" || d == "inline-block" || d == "inline-flex")
            inlineSum += minContentWidth(ce, percentBase);
        else
        {
            hasBlock = true;
            blockMax = max(blockMax, minContentWidth(ce, percentBase));
        }
    }
    if (rowFlex && itemCount > 1) inlineSum += gapPx * (itemCount - 1);
    int content = max(widestWord, hasBlock ? blockMax : inlineSum);
    if (content == 0)
    {
        foreach (word; transformed(e.style.textTransform, e.textContent()).split())
        {
            auto lay = shapeText(word, pixelSize, 1_000_000, 0.0, faceOf(&e.style));
            content = max(content, measuredWidth(lay, 0));
        }
    }
    return content + own;
}

version (unittest)
unittest
{
    // A flex row is as wide as the SUM of its items; a flex column as wide as
    // the widest. Using the block rule (widest) for a row under-measured
    // `display:flex` rows enough to clip a real page's header menu at its first
    // link, because the ancestor's `overflow:hidden` used the wrong width.
    auto flexRow = new Element("div");
    flexRow.style.display = "flex";
    foreach (i; 0 .. 3)
    {
        auto item = new Element("div");
        item.style.display = "block"; // as the cascade would give a flex item
        item.style.width = "100px";
        item.parent = flexRow;
        flexRow.children ~= item;
        flexRow.elements ~= item;
    }
    assert(intrinsicWidth(flexRow, 1000) == 300, "a flex row sums its items");
    assert(minContentWidth(flexRow, 1000) == 300, "a flex row's min-content sums too");
    flexRow.style.flexDirection = "column";
    assert(intrinsicWidth(flexRow, 1000) == 100, "a flex column takes its widest item");
    assert(minContentWidth(flexRow, 1000) == 100, "a flex column's min-content is its widest");

    // `input[type=hidden]` is a form-only field: it must not be laid out or
    // painted, or a page's search form shows a stray box beside the field.
    auto hiddenInput = new Element("input");
    hiddenInput.attrs["type"] = "hidden";
    applyUserAgentDefaults(hiddenInput.style, hiddenInput);
    assert(hiddenInput.style.display == "none", "input[type=hidden] must not paint");
    auto textInput = new Element("input");
    textInput.attrs["type"] = "text";
    applyUserAgentDefaults(textInput.style, textInput);
    assert(textInput.style.display != "none", "a text input keeps its control chrome");
    // Attribute values are case-insensitive in HTML.
    auto upperHidden = new Element("input");
    upperHidden.attrs["type"] = "HIDDEN";
    applyUserAgentDefaults(upperHidden.style, upperHidden);
    assert(upperHidden.style.display == "none", "type=HIDDEN must not paint either");
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
    // Index the rules once per pass. Without it the cascade scanned every rule
    // for every element, which made style resolution ~500x the cost of layout
    // on a real page (2274 rules).
    auto cascadeIndex = buildRuleIndex(rules);
    resolveStylesInto(element, rules, cascadeIndex, viewportWidth, viewportHeight,
        noCustom, 16, 16, pseudoElementRules(rules, "before"),
        pseudoElementRules(rules, "after"), pseudoElementRules(rules, "placeholder"));
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
        // `$ - 3` was an off-by-one: "11vw" ends in "1vw", never "vw", so every
        // vw/vh font size resolved to -1. clamp() then rejected that component
        // and fell back to its first valid one, so a real page's hero type sat
        // at its floor (56px) instead of clamp(3.5rem, 11vw, 7rem) = 112px.
        if (v.length >= 3 && v[$ - 2 .. $] == "vw")
            return style.viewportWidth * cssInt(v[0 .. $ - 2].strip()) / 100;
        if (v.length >= 3 && v[$ - 2 .. $] == "vh")
            return style.viewportHeight * cssInt(v[0 .. $ - 2].strip()) / 100;
        if (v.length >= 2 && v[$ - 1] == '%')
            // `cssInt` truncated the fraction: a page's 62.5% rem base became
            // 62%, so a 16px parent yielded 9px instead of the intended 10px.
            return cast(int)(parentPx * cssDouble(v[0 .. $ - 1].strip()) / 100.0 + 0.5);
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

private void resolveStylesInto(Element element, Rule[] rules, in RuleIndex cascadeIndex,
    int viewportWidth, int viewportHeight, string[string] inheritedCustom,
    int parentFontPx = 16, int rootFontPx = 16, in Rule[] beforeRules = null,
    in Rule[] afterRules = null, in Rule[] placeholderRules = null)
{
    auto cascade = cascadeFor(element, rules, candidatesFor(cascadeIndex, element));
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
    // Inherited text properties (CSS 2.1 6.2 / 10.2). An element that declares
    // none of its own takes its parent's computed value, but the initial values
    // held in `ComputedStyle` won instead. django's
    // `header nav li{font-size:1.3rem; font-weight:700}` therefore never reached
    // the `<a>` children: the menu measured ~25% too wide at 16px, wrapped past
    // its 1076px container and pushed the header from 68px to 136px tall.
    const int inheritedFontPx = element.parent is null ? -1
        : inheritStyleFromParent(element.style, element.parent.style, cascade);
    element.style.fontSizePx = inheritedFontPx >= 0
        ? inheritedFontPx : resolveFontSize(element.style, parentFontPx);
    // The root element establishes the `rem` base for all its descendants.
    const int childRootFont = (element.parent is null) ? element.style.fontSizePx : rootFontPx;
    // `::placeholder` (CSS Pseudo 4): the hint a control paints while it is
    // empty. The declaration lives on the control's selector but describes the
    // hint, so it is resolved into its own field instead of the control's
    // `color` - a page sets the two differently (Chromium's UA sheet mutes the
    // hint; django's dark theme un-mutes it with `var(--body-fg)`).
    if (placeholderRules.length &&
        (element.tag == "input" || element.tag == "textarea"))
    {
        auto placeholderCascade = cascadeFor(element, placeholderRules);
        if ("color" in placeholderCascade)
        {
            auto placeholderStyle = computedStyle(element, placeholderRules,
                placeholderCascade, custom);
            element.style.placeholderColor = placeholderStyle.color;
        }
    }
    // Generated pseudo-elements (CSS 12): build the ::before/::after boxes now
    // that this element's style (and inherited custom properties) are settled.
    element.pseudoBefore = buildPseudoElement(element, "before", beforeRules,
        custom, parentFontPx, childRootFont);
    element.pseudoAfter = buildPseudoElement(element, "after", afterRules,
        custom, parentFontPx, childRootFont);
    foreach (child; element.elements)
        resolveStylesInto(child, rules, cascadeIndex, viewportWidth, viewportHeight, custom,
            element.style.fontSizePx, childRootFont, beforeRules, afterRules,
            placeholderRules);
}

/// Apply the CSS inherited properties (CSS 2.1 6.2 / 10.2) that a box does not
/// declare itself from the box it belongs to.
///
/// Each guard also requires the value to still be the initial one, so a UA rule
/// (`h1{font-size:32px}`) or an author declaration is never overwritten.
///
/// Returns the parent's settled font pixels when `font-size` was inherited, else
/// -1: resolving the inherited string again would re-apply it (a child of a 62.5%
/// root would recompute 62.5% of 10px instead of adopting the settled size).
///
/// Both real children and generated `::before`/`::after` boxes use this: a pseudo-
/// element inherits from the element it decorates (CSS 2.1 12.1), and an icon face
/// is declared on the element (`i.icon`), never repeated on its pseudo, so a
/// generated box that kept the "inherit" sentinel resolved the STANDARD font for
/// its `content` glyph and painted a tofu box instead of the icon.
private int inheritStyleFromParent(ref ComputedStyle child, in ComputedStyle parent,
    string[string] declared)
{
    int inheritedFontPx = -1;
    if ("font-size" !in declared && child.fontSize == "16px")
    {
        child.fontSize = parent.fontSize;
        inheritedFontPx = parent.fontSizePx;
    }
    if ("font-weight" !in declared && child.fontWeight == "400")
        child.fontWeight = parent.fontWeight;
    if ("font-style" !in declared && child.fontStyle == "normal")
        child.fontStyle = parent.fontStyle;
    if ("font-family" !in declared && child.fontFamily.length == 0)
        child.fontFamily = parent.fontFamily;
    if ("line-height" !in declared && child.lineHeight == "auto")
        child.lineHeight = parent.lineHeight;
    if ("letter-spacing" !in declared && child.letterSpacing == "normal")
        child.letterSpacing = parent.letterSpacing;
    if ("text-align" !in declared && child.textAlign == "left")
        child.textAlign = parent.textAlign;
    if ("text-transform" !in declared && child.textTransform == "none")
        child.textTransform = parent.textTransform;
    if ("text-indent" !in declared && child.textIndent == "0px")
        child.textIndent = parent.textIndent;
    if ("white-space" !in declared && child.whiteSpace == "")
        child.whiteSpace = parent.whiteSpace;
    if ("visibility" !in declared && child.visibility == "visible")
        child.visibility = parent.visibility;
    // `color` is an inherited property: an element that declares no colour of its
    // own uses its parent's. Without this every such element defaulted to black,
    // so a real page's hero wordmark (`.hero h1` sets no colour, body does)
    // painted black-on-black and looked missing.
    if ("color" !in declared && child.color == "black")
        child.color = parent.color;
    return inheritedFontPx;
}

/// The value of one hexadecimal digit, or -1 when the character is not one.
private int hexValueOf(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decode the CSS escape sequences of a `content` string (CSS Syntax 3, 4.3.7).
///
/// A `\` followed by up to six hex digits is that code point, and one optional
/// whitespace character after the digits is consumed with it; a `\` before any
/// other character stands for that character. Real pages write icon glyphs this
/// way — FontAwesome's `content: "\f002"` — and laying out the six literal
/// characters put a stray `\f002` where the magnifier glyph belongs (documented
/// in docs/rendering-status.md).
private string decodeCssContentEscapes(string text)
{
    char[] outChars;
    for (size_t i = 0; i < text.length;)
    {
        const char c = text[i];
        if (c != '\\')
        {
            outChars ~= c;
            i++;
            continue;
        }
        i++;                          // consume the backslash itself
        if (i >= text.length) break;  // a trailing backslash escapes nothing
        uint value = 0;
        size_t digits = 0;
        for (; i < text.length && digits < 6; digits++)
        {
            const d = hexValueOf(text[i]);
            if (d < 0) break;
            value = value * 16 + cast(uint) d;
            i++;
        }
        if (digits == 0)
        {
            // `\<char>` stands for that character, so `\""` is a quote.
            outChars ~= text[i];
            i++;
            continue;
        }
        if (i < text.length && (text[i] == ' ' || text[i] == '\t' ||
            text[i] == '\n' || text[i] == '\r' || text[i] == '\f'))
            i++;
        // Not a Unicode scalar value: the REPLACEMENT CHARACTER (CSS Syntax 3).
        if (value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF))
            value = 0xFFFD;
        // UTF-8 by hand, so the module needs no extra import for a rare path.
        if (value < 0x80)
            outChars ~= cast(char) value;
        else if (value < 0x800)
        {
            outChars ~= cast(char) (0xC0 | (value >> 6));
            outChars ~= cast(char) (0x80 | (value & 0x3F));
        }
        else if (value < 0x10000)
        {
            outChars ~= cast(char) (0xE0 | (value >> 12));
            outChars ~= cast(char) (0x80 | ((value >> 6) & 0x3F));
            outChars ~= cast(char) (0x80 | (value & 0x3F));
        }
        else
        {
            outChars ~= cast(char) (0xF0 | (value >> 18));
            outChars ~= cast(char) (0x80 | ((value >> 12) & 0x3F));
            outChars ~= cast(char) (0x80 | ((value >> 6) & 0x3F));
            outChars ~= cast(char) (0x80 | (value & 0x3F));
        }
    }
    return cast(string) outChars;
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
    // A generated box is styled as a child of the element it decorates, so it
    // takes that element's inherited properties (`font-family` above all: the
    // icon faces live there) and resolves its lengths against the same context.
    pseudo.style.viewportWidth = element.style.viewportWidth;
    pseudo.style.viewportHeight = element.style.viewportHeight;
    pseudo.style.rootFontSizePx = element.style.rootFontSizePx;
    const int pseudoFontPx = inheritStyleFromParent(pseudo.style, element.style, cascade);
    pseudo.style.fontSizePx = pseudoFontPx >= 0
        ? pseudoFontPx : resolveFontSize(pseudo.style, element.style.fontSizePx);
    // Park the resolved `content` on the node so paint can use it as the box text.
    pseudo.style.content = raw;

    // `content: "text"` / 'text' — strip one surrounding quote pair.
    string text = raw;
    if (text.length >= 2 &&
        ((text[0] == '"' && text[$ - 1] == '"') ||
         (text[0] == '\'' && text[$ - 1] == '\'')))
        text = text[1 .. $ - 1];
    text = decodeCssContentEscapes(text);
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
    applyUserAgentDefaults(style, element);

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
    applyDeclaration(style, "object-position", cascade.get("object-position", ""));
    applyDeclaration(style, "background-position", cascade.get("background-position", ""));
    applyDeclaration(style, "filter", cascade.get("filter", ""));
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
    applyDeclaration(style, "flex-shrink", cascade.get("flex-shrink", ""));
    applyDeclaration(style, "flex-basis", cascade.get("flex-basis", ""));
    applyDeclaration(style, "flex-wrap", cascade.get("flex-wrap", ""));
    applyDeclaration(style, "align-content", cascade.get("align-content", ""));
    applyDeclaration(style, "justify-content", cascade.get("justify-content", ""));
    applyDeclaration(style, "align-items", cascade.get("align-items", ""));
    applyDeclaration(style, "align-self", cascade.get("align-self", ""));
    applyDeclaration(style, "gap", cascade.get("gap", ""));
    applyDeclaration(style, "line-height", cascade.get("line-height", ""));
    applyDeclaration(style, "text-transform", cascade.get("text-transform", ""));
    applyDeclaration(style, "letter-spacing", cascade.get("letter-spacing", ""));
    applyDeclaration(style, "text-indent", cascade.get("text-indent", ""));
    applyDeclaration(style, "box-sizing", cascade.get("box-sizing", ""));
    applyDeclaration(style, "table-layout", cascade.get("table-layout", ""));
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
            // Either property may carry the name, and a shorthand-expanded
            // `animation-name` can hold the WHOLE value ("intro-hide 0.32s ease
            // 0.5s forwards"), which matched no keyframe and applied nothing -
            // a real page's intro overlay then stayed covering the page. Take
            // any token from either property that names a known keyframe.
            string[] names;
            foreach (cand; [animName, anim])
                foreach (tok; cand.split(" "))
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
    // `strip` here is std.string.strip, which trims by Unicode whitespace and
    // THROWS on invalid UTF-8: transform() is often the first place a raw
    // `style="transform: translate(-50%, -50%)"` attribute reaches, and that text
    // may be a byte slice that is not valid UTF-8 (or may hold a NUL). Use a
    // byte-wise trim that cannot throw. Found by loading a page whose inline
    // transform crashed the whole render.
    static string trimSpace(string s)
    {
        size_t a = 0;
        size_t b = s.length;
        while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r' ||
                         s[a] == '\f' || s[a] == '\v')) ++a;
        while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n' ||
                         s[b - 1] == '\r' || s[b - 1] == '\f' || s[b - 1] == '\v')) --b;
        return s[a .. b];
    }
    dx = 0;
    dy = 0;
    if (transform.length == 0) return;
    // toLower here is std.uni.toLower, which throws UTFException on a byte slice
    // that is not valid UTF-8. `transform` is often the raw value of an inline
    // `style` attribute, so it can be a slice of a page's bytes: compare the
    // letters ASCII-case-insensitively instead of lowercasing the whole string.
    const lower = asciiLowered(transform);
    if (lower == "none") return;
    static int one(string arg, int base_) @safe
    {
        auto a = trimSpace(arg);
        if (a.length == 0) return 0;
        if (a[$ - 1] == '%')
        {
            double p = 0;
            try p = to!double(trimSpace(a[0 .. $ - 1]));
            catch (Exception) return 0;
            return cast(int) (p * base_ / 100.0);
        }
        if (a.length > 2 && asciiLowered(a[$ - 2 .. $]) == "px") a = a[0 .. $ - 2];
        // Splitting the argument list on the comma leaves whitespace on each side
        // (`translate(10px, 20px)`), which to!double rejects. Anything without a
        // digit is not a length we can resolve, so resolve it to 0.
        a = trimSpace(a);
        if (a.length == 0 || !((a[0] >= '0' && a[0] <= '9') ||
            a[0] == '-' || a[0] == '+' || a[0] == '.'))
            return 0;
        double v = 0;
        try v = to!double(trimSpace(a));
        catch (Exception) return 0;
        return cast(int) v;
    }

    size_t i = 0;
    while (i < lower.length)
    {
        const open = indexOf(lower[i .. $], "(");
        if (open < 0) break;
        const absOpen = i + open;
        const close = indexOf(lower[absOpen .. $], ")");
        if (close < 0) break;
        const absClose = absOpen + close;
        auto name = trimSpace(lower[i .. absOpen]);
        auto args = transform[absOpen + 1 .. absClose];
        if (name == "translate" || name == "translatex" || name == "translatey")
        {
            // `split(',')` resolves to std.string.split (this module imports that
            // selectively), NOT std.array.split. std.string.split takes a variadic
            // delimiter and splits on WHITESPACE when given one, so
            // `translate(-50%, -50%)` came through as one token and the transformer
            // then tried to parse "-50%, -50%" as a number and threw. Split on the
            // character explicitly and trim each side instead.
            string[] parts;
            size_t start = 0;
            while (start <= args.length)
            {
                auto commaAt = indexOf(args[start .. $], ",");
                if (commaAt < 0) { parts ~= args[start .. $]; break; }
                parts ~= args[start .. start + commaAt];
                start += commaAt + 1;
            }
            if (name != "translatey" && parts.length >= 1)
                dx += one(parts[0], selfW);
            if (name == "translatey" && parts.length >= 1)
                dy += one(parts[0], selfH);
            else if (name == "translate")
                dy += one(parts.length >= 2 ? parts[1] : "", selfH);
        }
        i = absClose + 1;
    }
}

/// ASCII-only lowercasing that cannot throw. CSS text reaching these helpers is
/// frequently a raw byte slice of the document (or an inline `style` attribute)
/// that is not valid UTF-8, and `std.uni.toLower` throws UTFException on it -
/// which aborted the whole layout for a page whose transform or gradient held
/// one bad byte.
private string asciiLowered(string s) @trusted
{
    auto buf = new char[s.length];
    foreach (k, c; s)
        buf[k] = (c >= 'A' && c <= 'Z') ? cast(char) (c + 32) : c;
    return cast(string) buf[0 .. s.length];
}

/// Extract a `linear-gradient(...)` / `radial-gradient(...)` token, balancing
/// nested parentheses so colours like `rgba(1, 2, 3, 0.5)` survive intact.
private string extractGradientToken(string value)
{
    const lower = asciiLowered(value);
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
    // The real page declares the ratio on .hero ITSELF rather than :root, which
    // is the arrangement that failed: the var() sits in the same block as the
    // custom property it reads.
    auto rules = parseStylesheet(`
        .hero { --hero-split-ratio: 0.38; display: grid; width: 1000px;
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

/// Baseline user-agent styling for common HTML tags. Applied before the author
/// cascade and inline `style=""`, so page CSS still overrides it. Without this,
/// headings, paragraphs and lists had no default margins or type sizes and
/// every block sat flush against the previous one.
private void applyUserAgentDefaults(ref ComputedStyle style, Element e)
{
    const tag = e.tag;
    switch (tag)
    {
        case "body":
            // Chromium's html.css declares `body { margin: 8px }`, which is what
            // insets a page that never mentions its own margin: without it every
            // paragraph began 8px left of the reference and wrapped at the full
            // viewport width instead of the body's content width.
            style.margin = "8px";
            break;
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
        case "a":
            // Chromium's html.css styles every anchor that carries an `href`
            // (`a:-webkit-any-link` matches both `:link` and `:visited`) with
            // `color: -webkit-link; text-decoration: underline`. Without this a
            // page that never names a link colour of its own painted every link
            // in the inherited text colour with no underline at all, where the
            // reference showed -webkit-link blue underlined - measured in the
            // inline-block fixture as rgb(0,0,238) across the label's rows
            // against our solid green pill. An anchor with no href is a
            // placeholder, not a link, so it keeps the inherited style.
            if ("href" in e.attrs)
            {
                style.color = "#0000EE";
                style.textDecoration = "underline";
            }
            break;
        case "input", "textarea", "select", "button":
            // `<input type="hidden">` is a form-only field: browsers hide it in
            // the UA stylesheet. Without this it was laid out with the default
            // control chrome, so a real page's search form rendered a stray
            // white square beside its text field.
            if (tag == "input" && asciiCaseEquals(e.attrs.get("type", ""), "hidden"))
            {
                style.display = "none";
                break;
            }
            // Default form-control chrome. Without it these tags paint as an
            // empty box with no border or background, so a text field is
            // invisible and impossible to aim the pointer at.
            style.background = "#ffffff";
            style.color = "#000000";
            style.border = "1px solid";
            style.borderStyle = "solid";
            style.borderColor = "#767676";
            // Chromium's html.css styles these with the `font` SHORTHAND:
            // `font: 400 13.3333px Arial`, which names the FAMILY as well as the
            // size. Setting only the size left a field with no family of its own,
            // so a control inherited the page's (the inheritance guard adopts the
            // parent's family while the child's is empty) and its hint text was
            // painted in that face. Measured on the placeholder fixture against
            // an Edge frame of the same file, the same 15-character placeholder
            // came out 106px wide in the engine against 88px in Edge — the field
            // was set in the page's monospace body font where Edge used Arial —
            // and the identical ~20% overshoot sat in django's header search
            // placeholder (192px engine vs 157px Edge).
            style.fontFamily = "Arial";
            style.fontSize = "13.3333px";
            // 2px of block padding, not 1: with the control's 1px border that is
            // the 6px of chrome Edge spends around a field's line box, which is
            // what the measured control heights come to (see layoutBlock: 21px
            // at the 13.3333px control font, 22 at 14px, 24 at 16px).
            style.padding = (tag == "button") ? "2px 8px" : "2px 3px";
            // A TEXT control has no child content, yet it is not a zero-height
            // box: its inner editor holds one empty line box. That line box is
            // now measured from the control's own font at layout time, so the
            // height follows the page's font size instead of ignoring it. The
            // other input types (a checkbox, a radio, a date control) have no
            // line box of their own, so they keep a UA height.
            if (tag == "input" && !controlSizedByChars(e))
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
            {
                // Stays in flow (and so is a containing block), but is pinned
                // within its containing block while the page scrolls.
                style.position = "relative";
                style.isSticky = true;
            }
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
        case "object-position": style.objectPosition = value.strip(); break;
        case "background-position": style.backgroundPosition = value.strip(); break;
        case "filter": style.filter = value.strip(); break;
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
            // flex: <grow> [<shrink>] [<basis>] (CSS Flexbox 7.1.1). A single
            // number sets grow and leaves basis at 0, so equal-sized items stay
            // equal regardless of their content; `flex: auto` is `1 1 auto`,
            // `flex: none` is `0 0 auto`.
            {
                auto parts = value.split();
                const string kw = parts.length ? asciiLowered(parts[0]) : "";
                if (kw == "none")
                {
                    style.flexGrow = "0";
                    style.flexShrink = "0";
                    style.flexBasis = "auto";
                }
                else if (kw == "auto")
                {
                    style.flexGrow = "1";
                    style.flexShrink = "1";
                    style.flexBasis = "auto";
                }
                else if (kw == "initial")
                {
                    style.flexGrow = "0";
                    style.flexShrink = "1";
                    style.flexBasis = "auto";
                }
                else if (parts.length)
                {
                    style.flexGrow = parts[0];
                    style.flexShrink = parts.length > 1 ? parts[1] : "1";
                    style.flexBasis = parts.length > 2 ? parts[2] : "0px";
                }
            }
            break;
        case "flex-grow": style.flexGrow = value; break;
        case "flex-shrink": style.flexShrink = value; break;
        case "flex-basis": style.flexBasis = value; break;
        case "flex-wrap": style.flexWrap = value.strip().toLower(); break;
        case "align-content":
            if (value == "flex-start" || value == "start" || value == "center" ||
                value == "space-between" || value == "space-around" ||
                value == "space-evenly" || value == "flex-end" || value == "end" ||
                value == "stretch")
                style.alignContent = value;
            break;
        case "justify-content":
            if (value == "flex-start" || value == "center" || value == "space-between" ||
                value == "space-around" || value == "space-evenly" || value == "flex-end")
                style.justifyContent = value;
            break;
        case "align-items":
            if (value == "stretch" || value == "center" || value == "flex-start" || value == "flex-end")
                style.alignItems = value;
            break;
        case "align-self":
            if (value == "auto" || value == "stretch" || value == "center" ||
                value == "flex-start" || value == "flex-end" ||
                value == "start" || value == "end")
                style.alignSelf = value;
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
        case "text-transform":
            if (value == "none" || value == "uppercase" || value == "lowercase" ||
                value == "capitalize")
                style.textTransform = value;
            break;
        case "letter-spacing": style.letterSpacing = value.strip(); break;
        case "text-indent": style.textIndent = value.strip(); break;
        case "box-sizing":
            if (value == "border-box" || value == "content-box") style.boxSizing = value;
            break;
        case "table-layout":
            if (value == "fixed" || value == "auto") style.tableLayout = value;
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

/// Clamp an auto CONTENT height and return the CONTENT height to store in
/// `box.height` (which is the content box everywhere in this engine; paint
/// rebuilds the border box by adding padding). `min-height`/`max-height` apply
/// to the content box for content-box sizing and to the border box for
/// border-box sizing (CSS 10.4), so a border-box element subtracts the padding
/// and border again after clamping - the exact mirror of `resolveHeight`.
/// Adding the border box here instead painted a padded flex/grid/table
/// container one padding-and-border taller than Edge: a `padding:10px;
/// border:5px` row laid out 100px tall where Edge lays out 70.
private int clampedContentHeight(Element element, int contentHeight)
{
    const padBorder = element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;
    if (element.style.boxSizing == "border-box")
        return max(0, clampMinMaxHeight(element, max(0, contentHeight) + padBorder) - padBorder);
    return clampMinMaxHeight(element, max(0, contentHeight));
}

/// The height of an element's BORDER box.
///
/// `box.height` stores the CONTENT box everywhere (paint.d adds the padding when
/// it draws the border box, and CSS 10.6 measures an auto height from the
/// content edge), so any placement that must clear the box - a following
/// sibling, or a parent measuring itself - has to add the element's own padding
/// and border. Advancing the flow by the content box left every padded
/// container 30px short: a `padding:10px;border:5px` block advanced by 50 where
/// Edge puts the next sibling at 80, and the parent of a padded header measured
/// 16px too small, shifting everything below it.
private int borderBoxHeight(const Element element)
{
    return element.box.height + element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;
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
    // content-box: `box.width` is the CONTENT box, and max-width clamps it, so
    // the clamped content (80) is what is stored - padding is added only when
    // paint reconstructs the border box.
    assert(cb.box.width == 80,
        "content-box max-width must clamp the content; got " ~ cb.box.width.to!string);

    // border-box: min/max clamp the border box itself.
    auto bb = new Element("div");
    bb.style.display = "block";
    bb.style.boxSizing = "border-box";
    bb.style.width = "100px";
    bb.style.padding = "10px";
    bb.style.maxWidth = "80px";
    layoutBlock(bb, flow, 400, null);
    // border-box: max-width clamps the BORDER box to 80, so the stored CONTENT
    // box is 80 minus the 20px of horizontal padding.
    assert(bb.box.width == 60,
        "border-box max-width clamps the border box, leaving 60 content; got " ~
        bb.box.width.to!string);

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
/// block); otherwise the fallback is the font's own normal line height.
private int resolveLineHeight(Element element, int pixelSize)
{
    const explicitLineH = element.style.pxLength(element.style.lineHeight);
    if (explicitLineH > 0) return explicitLineH;
    const percent = element.style.percentValue(element.style.lineHeight);
    if (percent >= 0) return max(1, (pixelSize * percent) / 100);
    // A bare number (`line-height: 1.5`) is a multiple of the element's own font
    // size (CSS 2.1 10.8.1), the commonest form on the web, and previously fell
    // through to the fixed "font size + 8px" leading.
    {
        import std.ascii : isDigit;
        const raw = element.style.lineHeight.strip();
        bool numeric = raw.length > 0;
        foreach (ch; raw)
            if (!isDigit(ch) && ch != '.')
            {
                numeric = false;
                break;
            }
        if (numeric)
        {
            import std.conv : to;
            try
            {
                const mult = to!double(raw);
                if (mult > 0) return max(1, cast(int)(pixelSize * mult + 0.5));
            }
            catch (Exception) {}
        }
    }
    return normalLineHeight(pixelSize, faceOf(&element.style));
}

/// Where an inline-block's BORDER box top goes inside its line box: `baseline`
/// (the default) stands the box on the text baseline, the other keywords
/// position it against the line box (CSS 10.8.1). `padTop`/`padBottom` are the
/// box's padding+border insets, because `box.y` is the border box origin while
/// the keywords describe where the whole (border) box or its content sits.
private int inlineBlockTop(string verticalAlign, int cursorY, int lineH, int boxHeight,
    int baseline, int padTop, int padBottom)
{
    switch (verticalAlign)
    {
        case "top", "text-top":
            return cursorY;
        case "bottom", "text-bottom":
            return cursorY + lineH - boxHeight - padTop - padBottom;
        case "middle":
            return cursorY + (lineH - boxHeight - padTop - padBottom) / 2;
        default: // baseline (and any unit length, approximated)
            return baseline - boxHeight - padTop;
    }
}

/// True when a run is only whitespace (which `white-space: normal` collapses).
private bool whitespaceOnly(string text)
{
    foreach (ch; text)
        if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' && ch != '\f')
            return false;
    return text.length > 0;
}

/// True when `white-space` keeps runs of whitespace instead of collapsing them.
private bool preservesWhitespace(string whiteSpace)
{
    return whiteSpace == "pre" || whiteSpace == "pre-wrap" ||
        whiteSpace == "pre-line";
}

/// The advance of one U+0020 in `face` at `pixelSize`. A whitespace-only run
/// shapes to zero glyphs, so the width comes from the difference between a run
/// with and without a space; `shapeTextCached` memoizes both.
private int spaceAdvance(FaceT)(int pixelSize, FaceT face)
{
    const a = shapeTextCached("m m", pixelSize, 0, false, 0.0, face);
    const b = shapeTextCached("mm", pixelSize, 0, false, 0.0, face);
    if (a !is null && b !is null)
    {
        const diff = cast(int) a.width - cast(int) b.width;
        if (diff > 0) return diff;
    }
    return pixelSize / 4 > 1 ? pixelSize / 4 : 1;
}

/// Layout a block-level element and its children in normal flow.
/// True when `element` is laid out as a flex item, i.e. its parent is a flex
/// container.
private static bool isFlexItem(Element element)
{
    auto parent = element.parent;
    if (parent is null) return false;
    const d = parent.style.display;
    return d == "flex" || d == "inline-flex";
}

/// True when the element's declared `float` actually applies.
///
/// CSS Flexbox 4.1: `float` has no effect on a flex item - the used value is
/// `none` and the item stays on its flex line. django's header menu is
/// `ul{display:flex;align-items:center}` holding `li{float:left}` items whose
/// links carry `padding:10px`; honouring that float took the items out of the
/// flex line, so the row came out 20px too tall and its labels painted 10px
/// above where Edge paints the same page.
private static bool floatApplies(Element element)
{
    return element.style.floatStyle != "none" && !isFlexItem(element);
}

/// True when a block's own top margin collapses with its first in-flow child's:
/// nothing separates them (no top border or padding), the block is static and
/// it does not establish a block formatting context (CSS 8.3.1).
private static bool canCollapseWithChild(Element element)
{
    auto style = element.style;
    if (element.box.borderTop != 0 || element.box.paddingTop != 0) return false;
    if (style.position != "static") return false;
    if (floatApplies(element)) return false;
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

/// True when a box is inline-level: it is part of its parent's INLINE content,
/// so its margins never collapse with the parent's in either direction
/// (CSS 8.3.1). Folding an inline-block child's margin into its paragraph moved
/// the paragraph down by the child's margin-top, measured the paragraph from
/// that shifted origin, and then let the child's margin-bottom escape out of the
/// paragraph's own height: `<p><a style="display:inline-block;margin:15px 0">`
/// measured 56px around a line whose bottom was 71px, so the paragraph was 15px
/// short of its own content and the button overflowed it.
private static bool isInlineLevelBox(string display)
{
    switch (display)
    {
        case "inline":
        case "inline-block":
        case "inline-flex":
        case "inline-grid":
        case "inline-table":
            return true;
        default:
            return false;
    }
}

/// The root element's own margins never collapse (CSS 8.3.1), so the root box
/// must not be treated as collapsing with its first/last child: doing so
/// swallowed the child's margin into a root box whose origin is the viewport's,
/// and the page then lost that space entirely. A `body { margin: 8px }` (the
/// browser default) plus an `h1`'s own margin put the heading 8px lower than a
/// browser places it, and the body's own margin vanished.
private static bool collapsesWithChildren(Element element)
{
    return element.parent !is null;
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
        if (floatApplies(ce)) continue;
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
    if (floatApplies(element)) return false;
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
        if (floatApplies(ce)) continue;
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
    // `max-width` must clamp an AUTO width too, in any unit, and BEFORE the
    // auto-margin leftover below is computed (CSS 10.4). resolveWidth's own
    // clamp handled an explicit px width but not an auto width with an em
    // max-width, so `max-width: 26em; margin: auto` computed a leftover of 0
    // and never centred - a real page's body sat flush left instead of centred.
    if (style.resolveLength(style.width, containingWidth) < 0 &&
        style.maxWidth.length)
    {
        const int maxW = style.resolveLength(style.maxWidth, containingWidth);
        if (maxW >= 0 && width > maxW) width = maxW;
    }
    element.box.width = width;

    int height = resolveHeight(element);
    element.box.height = max(0, height);

    if (floatApplies(element))
    {
        // CSS 9.5.1: a float goes as far to its own side as possible on the
        // current line, but it may not overlap a float that is already active in
        // this block formatting context; when it does not fit beside them it is
        // pushed below the offending float. Placing every float at `flow.x`
        // regardless stacked docs.djangoproject.com's footer: its two floated
        // `<li>`s both landed at x=71 on top of each other instead of sitting
        // beside the left-floated logo, and p.copyright's text painted over them.
        const bool left = style.floatStyle == "left";
        int fx = left ? flow.x : flow.x + flow.width - width;
        int fy = flow.y;
        bool shifted = true;
        for (int guard = 0; shifted && guard < 32; )
        {
            shifted = false;
            foreach (f; flow.floats)
            {
                // `height` is 0 while a float's auto height is still unknown, so
                // treat the candidate as a one-pixel band: enough to detect that
                // it starts on the same line as an active float.
                const int bandH = height > 0 ? height : 1;
                if (f.y >= fy + bandH || f.y + f.height <= fy) continue;
                if (fx + width <= f.x || f.x + f.width <= fx) continue;
                if (left)
                {
                    if (f.x + f.width + width <= flow.x + flow.width)
                    {
                        fx = f.x + f.width;
                        shifted = true;
                    }
                    else
                    {
                        fy = f.y + f.height;
                        fx = flow.x;
                        shifted = true;
                    }
                }
                else if (f.x - width >= flow.x)
                {
                    fx = f.x - width;
                    shifted = true;
                }
                else
                {
                    fy = f.y + f.height;
                    fx = flow.x + flow.width - width;
                    shifted = true;
                }
            }
            if (shifted) guard++;
        }
        element.box.x = fx;
        element.box.y = fy;
        // A float is a block box in its own formatting context: it lays its
        // children inside its OWN content box and takes an auto height from
        // them (CSS 9.5). Reusing the parent's flow laid django's docs
        // `main{float:left;width:62%}` children against the full 1196px
        // container, so the article overflowed the column and every following
        // box stacked below it - and the 741px float itself measured 0px tall.
        const int floatContentTop = element.box.y + element.box.paddingTop +
            element.box.borderTop;
        auto floatFlow = FlowContext();
        floatFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
        floatFlow.y = floatContentTop;
        // `width` is already the CONTENT width (Element.box.width), so padding
        // and border must not be subtracted again - doing so wrapped the
        // fundraiser card's "Support Django!" heading onto two lines.
        floatFlow.width = max(0, width);
        floatFlow.height = flow.height;
        floatFlow.lineEnd = floatFlow.x + floatFlow.width;
        floatFlow.suppressTopMargin = true;
        layoutChildren(element, floatFlow, element);
        if (style.resolveLength(style.height, containingWidth) < 0)
        {
            // A float is a block formatting context root, so its auto height also
            // covers the floats it contains (CSS 10.6.7). docs.djangoproject.com's
            // footer has `div.footer-logo{float:left}` holding only
            // `a.logo{float:left}`: without this the logo measured 388x0 and the
            // next floats were not pushed beside it.
            int contentBottom = max(floatFlow.y, floatFlow.inlineBottomAbs);
            foreach (f; floatFlow.floats)
                contentBottom = max(contentBottom, f.y + f.height);
            element.box.height = clampMinMaxHeight(element,
                max(0, contentBottom - floatContentTop) +
                element.box.paddingTop + element.box.paddingBottom +
                element.box.borderTop + element.box.borderBottom);
        }
        flow.floatLeft = max(flow.floatLeft, element.box.x + width);
        // Register the float rect so following inline content wraps around it.
        FloatRect fr;
        fr.x = element.box.x;
        fr.y = element.box.y;
        fr.width = width;
        fr.height = element.box.height;
        fr.right = style.floatStyle == "right";
        flow.floats ~= fr;
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
    else if (collapsesWithChildren(element) && canCollapseWithChild(element))
    {
        // A parent's top margin collapses with its first in-flow child's when
        // nothing separates them: the child's margin then moves the PARENT down
        // instead of adding space inside it.
        auto fc = firstInFlowChild(element);
        // Only a BLOCK-LEVEL first child collapses with the parent; an
        // inline-level child is the parent's inline content.
        if (fc !is null && !isInlineLevelBox(fc.style.display))

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
    // A declared `max-width` also makes the width definite: CSS 10.4 step 3
    // resolves the auto margins against the clamped width, which is why every
    // browser centres `max-width: 26em; margin: auto`. Requiring `width` meant
    // such a block was laid out flush left (a real page's body sat at x=0 in a
    // 1000px viewport instead of (1000-416)/2 = 292).
    if ((element.box.marginLeftAuto || element.box.marginRightAuto) &&
        (style.resolveLength(style.width, containingWidth) >= 0 ||
         style.maxWidth.length > 0))
    {
        // CSS 10.3.3's equation covers the whole outer box, not just the
        // content width: mL + bL + pL + width + pR + bR + mR = containing
        // width. Omitting the padding and borders made `margin: auto` centre a
        // padded box too far right (a real page's body: (1000-416)/2 = 292
        // instead of (1000-416-64)/2 = 260).
        // Only a NON-auto margin is a constraint here. Subtracting an `auto`
        // margin's current value double-counted it on a second layout pass:
        // after pass 1 distributed 260, pass 2 computed
        // 1000 - 416 - 64 - 260 - 260 = 0 and un-centred the body.
        const int fixedLeft = element.box.marginLeftAuto ? 0 : element.box.marginLeft;
        const int fixedRight = element.box.marginRightAuto ? 0 : element.box.marginRight;
        const leftover = max(0, containingWidth - width -
            element.box.paddingLeft - element.box.paddingRight -
            element.box.borderLeft - element.box.borderRight -
            fixedLeft - fixedRight);

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
    childFlow.width = max(0, width);
    // `resolveWidth` returns, and `box.width` holds, the CONTENT box (CSS
    // 10.3.3), so the padding/border must NOT be taken off a second time.
    // Subtracting them again gave every padded block 2x its padding less text
    // width: django's `header nav li > a` (padding 10px, content 62px) laid its
    // label out in 42px, so "NEWS" broke into four glyph-per-line fragments and
    // each nav item counted an empty extra line box.

    // A child's percentage height resolves against a DEFINITE containing-block
    // height (CSS 10.5) — this box's own content height, which `box.height`
    // holds — and only falls back to the flow height when this box's height is
    // auto. (`box.height` is assigned above, before any child flow is built.)
    childFlow.height = height >= 0 ? element.box.height : flow.height;
    // The first child's margin-top was already collapsed into this box.
    childFlow.suppressTopMargin = collapseIntoChild;
    childFlow.lineEnd = childFlow.x + childFlow.width;
    // Active floats must be visible to nested in-flow content so its lines
    // shorten around them (CSS 9.5). Leaving the list behind meant the float
    // rects registered in a parent flow were invisible to a descendant block:
    // django's footer logos never pushed the small print aside, so the copyright
    // lines painted straight on top of them.
    childFlow.floats = flow.floats;
    // Where this element's own (and its descendants') floats start in that list:
    // the inherited ones are already accounted for by the ancestor that owns
    // them, so a formatting context root must only measure its own.
    const size_t floatBase = childFlow.floats.length;
    // A float is contained by the nearest BLOCK FORMATTING CONTEXT (CSS 2.1
    // 9.4.1), not by the box that happens to declare it. So when this block is
    // not itself a BFC root, the rects belong to the surrounding flow and must
    // be handed up: the reference case is a float declared inside a plain
    // (non-BFC) child, where the block that follows never saw the float and its
    // lines ran straight over it. The guard is what keeps that hand-off from
    // escaping past a real BFC root - without it the rects climbed out of an
    // `overflow:hidden` container and every ancestor re-shortened its lines,
    // which reflowed django's whole footer.
    bool bfcRoot = floatApplies(element) ||
        element.style.position == "absolute" ||
        element.style.position == "fixed" ||
        (element.style.overflow.length && element.style.overflow != "visible");
    if (!bfcRoot)
        switch (element.style.display)
        {
            // Display types that are formatting contexts of their own (CSS
            // Display 3) contain their floats too: an inline-block, a table
            // cell or caption, a flow-root, a flex or grid container.
            case "inline-block", "inline-flex", "flow-root", "table-cell",
                "table-caption", "table", "flex", "grid", "inline-grid":
                bfcRoot = true;
                break;
            default:
                break;
        }

    layoutChildren(element, childFlow, element);

    if (!bfcRoot && childFlow.floats.length > flow.floats.length)
        flow.floats = childFlow.floats;

    // Compute this block's height from explicit style or its content.
    int finalHeight = height;
    if (height < 0)
    {
        auto innerBottom = max(childFlow.y, childFlow.inlineBottomAbs);
        // CSS 2.1 10.6.7: a formatting context root's auto height also reaches
        // the bottom margin edge of its bottom-most float. This is what makes
        // `overflow:hidden` clear the floats it contains, and it is why the
        // rects handed up from a non-BFC child have to be counted here: without
        // it the container measured 40px around a 60px float and the next
        // sibling's bar was drawn over it.
        if (bfcRoot)
            foreach (fl; childFlow.floats[floatBase .. $])
                innerBottom = max(innerBottom, fl.y + fl.height);
        // `innerBottom` is the CONTENT bottom in absolute coordinates - the inner
        // flow starts at the content origin - so the content height is measured
        // straight from the content top. Adding this box's own padding and border
        // here stored the BORDER height, which paint then padded a second time,
        // so every auto-height padded block painted one padding-and-border too
        // tall (a `padding:10px;border:5px` box drew 110px where Edge draws 80).
        finalHeight = max(0, innerBottom - element.box.y - element.box.paddingTop -
            element.box.borderTop);
    }
    // An EMPTY text control is one line tall, not zero: its inner editor holds a
    // single empty line box, and the box model adds the control's own padding and
    // border on top of it. The engine measured 0 for a control with no children,
    // so the UA sheet had to hard-code a height - a fixed 20px that ignored the
    // page's font size and was a pixel short even at the default. Measured against
    // Edge's frames of the control fixture, a one-line control is
    // line-height(normal) + 6px of chrome at every size: 21px at the 13.3333px
    // control font, 22px at 14px and 24px at 16px.
    if (height < 0 && finalHeight == 0 &&
        (controlSizedByChars(element) || element.tag == "select" ||
         element.tag == "button"))
    {
        const int lineBox = resolveLineHeight(element,
            style.fontSizePx > 0 ? style.fontSizePx : 16);
        finalHeight = lineBox *
            (element.tag == "textarea" ? textareaRows(element) : 1);
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
    if (height < 0 && collapsesWithChildren(element) && canCollapseBottom(element))
    {
        auto lc = lastInFlowChild(element);
        // Same rule at the bottom edge: an inline-level last child's margin stays
        // inside the parent's line box, and therefore inside its height.
        if (lc !is null && !isInlineLevelBox(lc.style.display))
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
    const bottom = layoutTop + borderBoxHeight(element) + element.box.marginBottom;
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

/// Run `body` with `element`'s generated `::before`/`::after` boxes spliced into
/// its child lists, then restore them (CSS 12 / 2.1 12.1).
///
/// Layout and paint must see a generated box as part of its element's content,
/// while DOM and script APIs must never observe it, so the splice is scoped to one
/// pass. `::before` goes first and `::after` last, exactly where CSS places
/// generated content. `layoutChildren` splices the same way for a block's own
/// pass; this covers the places that read an element's children directly instead
/// (its own inline pass, which is where an inline `i.icon`'s glyph has to be
/// measured — without it the icon contributed no width and painted nothing).
private void withGeneratedBoxes(Element element, scope void delegate() body)
{
    if (element.pseudoBefore is null && element.pseudoAfter is null)
    {
        body();
        return;
    }
    auto savedChildren = element.children;
    auto savedElements = element.elements;
    scope(exit)
    {
        element.children = savedChildren;
        element.elements = savedElements;
    }
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
    body();
}

private void layoutDirectText(Element element, ref FlowContext flow,
    size_t from = 0, size_t to = size_t.max)
{
    const pixelSize = element.style.fontSizePx > 0 ? element.style.fontSizePx : 16;
    // The block's own content top. `flow.y` is advanced as lines are laid out,
    // so measuring the content height against its FINAL value double-counted
    // the advance: the reduced inline-block case reported a 56px paragraph
    // where its line bottom was 86px from the content top of 15, and the
    // fixture's paragraph was short by the same 15px.
    const int contentOrigin = flow.y;
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
            if (isCollapsibleWhitespaceOnly(text.data))
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
                // The collapsed space advances by the face's own U+0020, not a
                // hard-coded half-em: 8px at 16px placed the inline-block after
                // it 4px right of where a browser puts it (the face's space is
                // 4.4px at 16px).
                if (cursorX > flow.x)
                    cursorX += spaceAdvance(pixelSize, faceOf(&element.style));
                text.layoutX = 0; text.layoutY = 0; text.layoutWidth = 0; text.lineIndex = 0;
                continue;
            }
            const int leftEdge = flow.lineLeft(cursorY, lineH);
            const int rightEdge = flow.lineRight(cursorY, lineH);
            const int innerW = max(0, rightEdge - cursorX);
            string runText = collapsibleText(element, text);
            // A collapsible space at the start of a LINE is removed (CSS Text 3
            // 4.1.1). The sibling rule in `collapsibleText` cannot see the
            // cursor, so a run that begins this line drops the separator here -
            // the same test the whitespace-only branch above makes.
            if (cursorX <= flow.x && runText.length > 0 && runText[0] == ' ')
                runText = runText[1 .. $];
            text.paintText = runText;
                auto layout = shapeText(runText, pixelSize,
                    noWrapText ? 1_000_000 : innerW, element.style.letterSpacingPx(),
                    faceOf(&element.style));
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
                // A soft wrap must not leave a trailing EMPTY line box: the
                // shaper emits one when a run's last cluster ends at the wrap
                // boundary (every uppercase nav label did), and counting it made
                // each `header nav li > a` 52px tall around one 16px line of
                // text. A real line break (`<br>`, preformatted newlines) is
                // handled by its own branch and never reaches this point.
                int nLines = cast(int) layout.lines.length;
                while (nLines > 1 && layout.lines[nLines - 1].glyphEnd <=
                    layout.lines[nLines - 1].glyphStart)
                    nLines--;
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
            // A run that is only whitespace - the single collapsed space between
            // two inline-blocks - has no glyphs to measure, but it still
            // advances. 8px per character doubled that gap (the face's space is
            // 4.4px at 16px), so the second chip sat 3px right of a browser's.
            const int textWidth = whitespaceOnly(runText)
                ? spaceAdvance(pixelSize, faceOf(&element.style))
                : cast(int)(runText.length * 8);
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
                // A whitespace-only run collapses to ONE space (CSS Text 3) and
                // has no glyphs to shape. The newline between two inline-blocks
                // must advance a space (4.4px at 16px), not the ~8px a shaped
                // newline produced - that put the second chip 3px right of where
                // a browser places it.
                if (whitespaceOnly(ce.textContent()) && !preservesWhitespace(ce.style.whiteSpace))
                    cw = spaceAdvance(pixelSize, faceOf(&ce.style));
                else
                {
                    auto lay = shapeText(ce.textContent(), pixelSize,
                        noWrapText ? 1_000_000 : max(0, rightEdge - cursorX), 0.0,
                        faceOf(&ce.style));
                    if (lay !is null && lay.lines.length > 0)
                    {
                        // The used width is the fractional advance sum rounded to
                        // a device pixel (Edge paints 198 for 197.921), not
                        // truncated - a truncation made every shrink-to-fit
                        // inline box a pixel narrow.
                        cw = cast(int) (lay.width + 0.5);
                        ceLines = cast(int) lay.lines.length;
                    }
                    else
                        cw = cast(int)(ce.textContent().length * 8);
                }
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
                else
                    // `height: auto` inline-blocks are sized by their OWN content
                    // (CSS 10.6.2). `ceLines * lineH` above used the containing
                    // block's line height, so a 14px/`line-height:1` box inside a
                    // 16px body measured 21px where every browser uses 14 - and
                    // the baseline below then pushed it 7px above the text.
                    ce.box.height = resolveLineHeight(ce,
                        ce.style.fontSizePx > 0 ? ce.style.fontSizePx : pixelSize);
            }
            // Inline vertical alignment. The line box spans
            // `cursorY .. cursorY + lineH`; `baseline` (the default) puts the
            // box's bottom edge on the text baseline (cursorY + ascent, with
            // ascent ~= font-size), the other keywords position it against the
            // line box.
            if (ce.style.display == "inline-block")
            {
                const int baseline = cursorY + pixelSize;
                // `box.y` is the BORDER box origin: paint insets the content by
                // padding+border, exactly as it does for blocks. The `baseline`
                // keyword puts the box's CONTENT bottom on the baseline, so the
                // top inset comes off too - without it a bordered inline-block
                // painted padding+border lower than the line (the webfont
                // fixture was 2px low).
                // The line box contains the box's MARGIN box (CSS 10.8.1), so
                // the box can never stick out above the line's top: a baseline
                // placement that ignores `margin-top` paints the box above the
                // paragraph that owns it (the homepage CTA sat 15px too high
                // and was clipped by the page edge).
                ce.box.y = max(inlineBlockTop(ce.style.verticalAlign, cursorY, lineH,
                    ce.box.height, baseline,
                    ce.box.paddingTop + ce.box.borderTop,
                    ce.box.paddingBottom + ce.box.borderBottom),
                    cursorY + ce.box.marginTop);
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
            // ... and its top line, below the box's own top inset for the same
            // reason: an inline-block's content starts inside its border.
            sub.y = ce.box.y + (inlineBox ? ce.box.borderTop + ce.box.paddingTop : 0);
            sub.width = max(0, flow.width -
                (inlineBox ? ce.box.borderLeft + ce.box.borderRight +
                    ce.box.paddingLeft + ce.box.paddingRight : 0));
            sub.height = flow.height;
            // An inline-block's own text is aligned inside ITS content box, not
            // inside the parent's line. Handing it the parent's `rightEdge` made
            // django's centred CTA centre its label within the whole paragraph:
            // the label sat 241px right of its button, and the reconciler below
            // then dragged the button after its own label. A plain inline box
            // (`<b>`, `<em>`) really does share the parent's line.
            // An inline-block with `width:auto` was sized FROM its content, so
            // its own content must not wrap inside it. `cw` is that content's
            // fractional advance rounded to a device pixel, and the rounding can
            // land a fraction BELOW the content's own width (28 for 28.4px of
            // text); laying the content out at that rounded width then re-wrapped
            // its last cluster onto a second line. The phantom line counted in
            // the sub-flow's content bottom, so an auto-height box grew to twice
            // its one real line (28x46 for a single 18px line, and 141 instead of
            // 118 for the CTA fixture banner) and the shared line cursor advanced
            // below the label. Give the interior the content's own max-content
            // width; a specified width still wraps normally.
            int innerCw = cw;
            if (inlineBox && ce.style.resolveLength(ce.style.width, flow.width) < 0)
            {
                const int ceSize = ce.style.fontSizePx > 0
                    ? ce.style.fontSizePx : pixelSize;
                auto innerLay = shapeText(ce.textContent(), ceSize, 0,
                    ce.style.letterSpacingPx(), faceOf(&ce.style));
                if (innerLay !is null)
                {
                    const int measured = cast(int) innerLay.width;
                    innerCw = max(innerCw, measured < innerLay.width
                        ? measured + 1 : measured);
                }
            }
            sub.lineEnd = inlineBox ? sub.x + max(0, innerCw) : rightEdge;
            sub.lineCount = lineIndex;
            withGeneratedBoxes(ce, { layoutDirectText(ce, sub); });
            // The box was sized from its own line height before the content was
            // laid out; wrapped text can need more. Grow the box to the content
            // it actually has and re-place it - the baseline depends on the
            // height - then lay the content out once more at the final offset.
            // Text height does not depend on `y`, so this settles in one step.
            if (ce.style.display == "inline-block" && resolveHeight(ce) < 0 &&
                sub.contentBottom > ce.box.height)
            {
                ce.box.height = sub.contentBottom;
                ce.box.y = max(inlineBlockTop(ce.style.verticalAlign, cursorY, lineH,
                    ce.box.height, cursorY + pixelSize,
                    ce.box.paddingTop + ce.box.borderTop,
                    ce.box.paddingBottom + ce.box.borderBottom),
                    cursorY + ce.box.marginTop);
                sub.y = ce.box.y + ce.box.borderTop + ce.box.paddingTop;
                withGeneratedBoxes(ce, { layoutDirectText(ce, sub); });
            }
            // Block-level children are not inline content: the run above lays
            // out the box's own TEXT only, so such a child kept its 0x0 default
            // box and an auto height stayed one line tall. Edge sizes an
            // inline-block wrapper to the children it contains - an 80x20 chip
            // made the wrapper 80x20, not 16x18. Gated on having element
            // children, so the common text-only inline-block (a button label, a
            // badge) keeps exactly the path it had.
            if (ce.style.display == "inline-block" && hasBoxChild(ce))
            {
                const int contentTop = sub.y;
                layoutInlineBlockChildren(ce, sub, positionedAncestorOf(ce));
                const int contentH = max(sub.contentBottom,
                    inlineBlockChildBottom(ce, contentTop) - contentTop);
                if (resolveHeight(ce) < 0 && contentH > ce.box.height)
                {
                    ce.box.height = contentH;
                    ce.box.y = max(inlineBlockTop(ce.style.verticalAlign, cursorY, lineH,
                        ce.box.height, cursorY + pixelSize,
                        ce.box.paddingTop + ce.box.borderTop,
                        ce.box.paddingBottom + ce.box.borderBottom),
                        cursorY + ce.box.marginTop);
                    sub.y = ce.box.y + ce.box.borderTop + ce.box.paddingTop;
                    layoutInlineBlockChildren(ce, sub, positionedAncestorOf(ce));
                }
            }
            // Merge back the sub-flow's text bottom. An inline-level box can be
            // TALLER than the strut, and the line box must grow to contain it
            // (CSS 10.8.1): a 40px inline-block inside a 20px line left the line
            // box at 20px, so the row's background stopped halfway down the box
            // and everything after it sat 20px too high.
            // The line box must contain the box's BORDER box, not just its
            // content: an inline-block with padding or a border is taller than
            // `height`, and the row after it has to clear that (CSS 10.8.1).
            // It must contain the MARGIN box as well. Django's homepage CTA has
            // `margin:15px 0` plus a higher-specificity `margin-bottom:40px`,
            // and a line that stopped at the border box measured the button's
            // paragraph 0px tall while Edge measured 101px - most of the ~55px
            // of accumulated height the homepage lost below its hero.
            // `height` is the CONTENT box - the paint adds its own insets - so
            // the border box needs all four insets, not just the bottom two.
            // The fixture's 46px content with `pad=10,20` paints 66px tall
            // while the line bottom measured 56px, and Edge's own paragraph is
            // then about 10px taller than the engine's for every padded chip.
            maxBottom = max(maxBottom, max(cursorY + lineH,
                ce.box.y + ce.box.height +
                    (inlineBox ? ce.box.paddingTop + ce.box.borderTop +
                        ce.box.paddingBottom + ce.box.borderBottom +
                        ce.box.marginBottom : 0)));

            lineIndex = max(lineIndex, sub.lineCount);
            continue;
        }
        // Any other direct child (block) was laid out by layoutChildren.
    }
    if (maxBottom > 0)
    {
        flow.contentBottom = max(flow.contentBottom, maxBottom - contentOrigin);
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

    // Keep every inline box seated on its own text. The renderer lays the page
    // out repeatedly (it settles images over several passes, and a resize
    // re-lays out), and a repeat pass re-seats the box at the line start while
    // placing the text is skipped once it already has a width - so the aligned
    // text keeps its x and the box drifts off its own label. A real page's
    // centred white call-to-action label ended up outside its green button on
    // the white banner, which made the button look empty. Re-derive the box from
    // the text only when the text has left the content box entirely, so content
    // centred inside a wider inline-block stays exactly where it is.
    foreach (i, ce; placedElements)
    {
        const int firstText = firstPlacedTextX(ce);
        if (firstText == int.max) continue;
        const int contentRight = ce.box.x + ce.box.borderLeft +
            ce.box.paddingLeft + ce.box.width;
        if (firstText >= contentRight)
            ce.box.x = firstText - ce.box.paddingLeft - ce.box.borderLeft;
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

/// Shift an element's whole box tree vertically — every descendant element box
/// and text run — by `dy` px. The horizontal helper above has no `y` twin and a
/// flex item's cross-axis position is only settled after its contents have been
/// laid out, so the later move needs one.
private void shiftBoxTreeY(Element ce, int dy)
{
    if (dy == 0) return;
    ce.box.y += dy;
    foreach (child; ce.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            if (t.layoutWidth > 0) t.layoutY += dy;
            continue;
        }
        auto e2 = cast(Element) child;
        if (e2 is null) continue;
        shiftBoxTreeY(e2, dy);
    }
}

/// Place a flex item on its container's cross axis, carrying its contents.
///
/// An item's own cross size — and therefore its centred or end-aligned `y` — is
/// only known once its contents have been laid out, so alignment runs after that
/// and must move the subtree too. Moving the box alone left djangoproject.com's
/// header nav painting its links ~10px above where Edge puts them: the nav was
/// centred in the row (y 10 -> 18) while its `ul` stayed at the old y.
private void placeItemY(Element ce, int targetY)
{
    shiftBoxTreeY(ce, targetY - ce.box.y);
}

/// The leftmost placed text run inside `e` - its own text plus any nested inline
/// descendants - or `int.max` when it holds none. Used to keep an inline box
/// seated on its own text after an alignment shift.
private int firstPlacedTextX(Element e)
{
    int best = int.max;
    foreach (child; e.children)
    {
        auto t = cast(TextNode) child;
        if (t !is null)
        {
            if (t.layoutWidth > 0) best = min(best, t.layoutX);
            continue;
        }
        auto e2 = cast(Element) child;
        if (e2 !is null) best = min(best, firstPlacedTextX(e2));
    }
    return best;
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

/// Resolve `text-indent` (CSS Text 3) to a first-line pixel offset.
///
/// `resolveLength` cannot be used here: it reports an unparseable/`auto` value
/// as -1, which is indistinguishable from a legal NEGATIVE length. A real page
/// hides an image-replaced logo's text with `text-indent:-1000%`, and that
/// collapsed to -1px - too small to see, so the text kept painting over the
/// logo. Percentages and ems also have to be resolved against the right base.
private int resolveTextIndent(ComputedStyle style, int containingWidth)
{
    import std.conv : to;
    const raw = style.textIndent.strip();
    if (raw.length == 0 || raw == "auto" || raw == "none") return 0;
    size_t k = 0;
    if (k < raw.length && (raw[k] == '-' || raw[k] == '+')) k++;
    while (k < raw.length && raw[k] >= '0' && raw[k] <= '9') k++;
    if (k < raw.length && raw[k] == '.')
    {
        k++;
        while (k < raw.length && raw[k] >= '0' && raw[k] <= '9') k++;
    }
    if (k == 0) return 0;
    double num;
    try num = to!double(raw[0 .. k]);
    catch (Exception) return 0;
    const unit = raw[k .. $].strip().toLower();
    if (unit == "%") return cast(int) (num / 100.0 * containingWidth);
    if (unit == "em")
        return cast(int) (num * (style.fontSizePx > 0 ? style.fontSizePx : 16));
    if (unit == "rem")
        return cast(int) (num * (style.rootFontSizePx > 0 ? style.rootFontSizePx : 16));
    return cast(int) num;               // px, and unitless (0)
}

private int resolveWidth(Element element, int containingWidth)
{
    auto style = element.style;
    auto widthPx = style.resolveLength(style.width, containingWidth);
    int width;
    if (widthPx >= 0)
    {
        // `box.width` is the CONTENT box everywhere else in this engine (paint
        // reconstructs the border box by adding padding), so this branch must
        // return a content width too. It used to return a BORDER width - and
        // with `box-sizing: border-box` (a near-universal reset) that made every
        // padded element `padding` wider than its declared size, so boxes
        // overflowed their columns. A real page's hero面板 came out 69px too
        // wide and its grid items stacked instead of sitting side by side.
        const padBorder = element.box.paddingLeft + element.box.paddingRight +
            element.box.borderLeft + element.box.borderRight;
        if (style.boxSizing == "border-box")
        {
            // min/max clamp the BORDER box (CSS 10.4); the stored value is the
            // content box, i.e. the clamped border box minus padding/border.
            return max(0, clampMinMaxWidth(element, max(0, widthPx)) - padBorder);
        }
        // content-box: the declared width IS the content width; clamping applies
        // to the content (CSS 10.3.3).
        return clampMinMaxWidth(element, max(0, widthPx));
    }

    // `width: auto` on a text control is the control's intrinsic width, not the
    // containing block's: a control is replaced-like. Stretching an `input` to
    // its column left the placeholder fixture's fields 1264px wide against
    // Edge's 177, and it is the same rule that makes a field on a real page as
    // wide as its `size` attribute says.
    const int control = controlContentWidth(element, element.box.paddingLeft +
        element.box.paddingRight + element.box.borderLeft + element.box.borderRight);
    if (control >= 0) return clampMinMaxWidth(element, control);

    if (style.display == "inline-block")
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
                auto lay = shapeText(content, pixelSize, 0, 0.0, faceOf(&element.style));
                // The shaped advance sum is fractional (197.921 for 20 Roboto
                // `m`s at 14px); the used width is that rounded to a device
                // pixel, the way Edge paints it (198). Truncating made every
                // shrink-to-fit inline-block a pixel narrow and shifted the
                // inline-blocks after it.
                width = lay !is null ? cast(int) (lay.width + 0.5)
                    : cast(int)(content.length * 8);
            }
            else
            {
                // No text of its own: shrink-to-fit the element children it
                // wraps. The fixed 16px placeholder made a `display:inline-block`
                // wrapper around an 80x20 chip 16px wide, so the chip painted
                // 16px wide and the next inline-block sat 64px left of where
                // Edge puts it.
                bool hasElementChild = false;
                foreach (ch; element.elements)
                    if (ch !is null && ch.style.display != "none")
                    {
                        hasElementChild = true;
                        break;
                    }
                int fit = 0;
                if (hasElementChild)
                {
                    // `intrinsicWidth` reports a border-box width, while
                    // `resolveWidth` must return the CONTENT width.
                    const int intrinsic = intrinsicWidth(element, containingWidth);
                    const int own = element.box.paddingLeft + element.box.paddingRight +
                        element.box.borderLeft + element.box.borderRight;
                    fit = intrinsic - own;
                }
                width = fit > 0 ? fit : 16;
            }
        }
    }
    else
        width = containingWidth - element.box.paddingLeft - element.box.paddingRight -
            element.box.borderLeft - element.box.borderRight - element.box.marginLeft -
            element.box.marginRight;
    return clampMinMaxWidth(element, max(0, width));
}

/// Apply `text-transform` (CSS Text 3). ASCII-only folding: markup is untrusted
/// and `std.uni` case mapping can overrun non-ASCII sequences.
private string applyTextTransform(string transform, string text)
{
    import std.ascii : toLower, toUpper;
    if (transform != "uppercase" && transform != "lowercase" &&
        transform != "capitalize")
        return text;
    auto chars = text.dup;
    bool atWordStart = true;
    foreach (i, c; chars)
    {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f')
        {
            atWordStart = true;
            continue;
        }
        if (transform == "uppercase")
            chars[i] = cast(char) toUpper(c);
        else if (transform == "lowercase")
            chars[i] = cast(char) toLower(c);
        else if (atWordStart)
            chars[i] = cast(char) toUpper(c);
        atWordStart = false;
    }
    return chars.idup;
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
    if (preserved)
        return applyTextTransform(element.style.textTransform, expandTabs(node.data));
    string result;
    bool pendingSpace = false;
    bool started = false;
    // Leading whitespace is a separator too when inline content precedes this
    // node: dropping it unconditionally painted "<a>DOCUMENTATION</a> end" as
    // "DOCUMENTATIONend". Only the first node of a formatting context really
    // begins a line, the mirror of `canSeparate` below; the cursor still
    // overrides this where the layout knows the line's own left edge. A node the
    // element does not list (a detached run) is the only content there is, so it
    // begins the context too.
    const bool atContextStart =
        element.children.length == 0 || element.children[0] is node;
    foreach (char c; node.data)
    {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f')
        {
            if (started || !atContextStart) pendingSpace = true;
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
    // Keep one trailing space where it can still separate inline content — a
    // run's trailing whitespace is what gives "Date added: <time>…</time>" its
    // space. At the end of a BLOCK it can separate nothing, and counting it as
    // an advance made the box one line taller: every indented `</p>` produced a
    // blank line, which is most of the vertical drift on a real page.
    const inlineLevel = element.style.display == "inline" ||
        element.style.display == "inline-block" ||
        element.style.display == "inline-flex";
    const canSeparate = inlineLevel || element.children.length == 0 ||
        !(element.children[$ - 1] is node);
    if (pendingSpace && canSeparate) result ~= ' ';
    return applyTextTransform(element.style.textTransform, result);
}

/// Whether a text node is nothing but collapsible whitespace (CSS Text 3: only
/// space, tab, newline, CR and form feed collapse). `std.string.strip` uses
/// Unicode whitespace, which wrongly includes U+00A0, so it discarded a
/// `<div>&nbsp;</div>` as an empty text node: the element then had no line box
/// at all and collapsed to zero height instead of one line of space.
private bool isCollapsibleWhitespaceOnly(string s)
{
    foreach (char c; s)
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '\f')
            return false;
    return true;
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

/// The CONTENT-box height a declared `height` resolves to, or -1 for `auto`.
/// `box.height` is the CONTENT box everywhere else in this engine (paint
/// reconstructs the border box by adding padding), so this is the exact mirror of
/// `resolveWidth`. It used to clamp the content and then ADD padding+border, so
/// paint added them a second time: the box-model fixture's
/// `height:70px;padding:11px;border:7px` painted 142px tall where Edge paints 106
/// (70 + 22 + 14), while its width was already correct.
///
/// `base` is the height a percentage resolves against: the parent's flow height
/// for an in-flow box, the positioned ancestor's padding box for an absolutely
/// positioned one, the viewport for a fixed one.
private int resolveDefiniteHeight(Element element, int base)
{
    auto style = element.style;
    const declared = style.resolveLength(style.height, base);
    if (declared < 0) return -1;
    const clamped = clampMinMaxHeight(element, max(0, declared));
    // `box-sizing:border-box` declares the BORDER box, so the content height is
    // what padding and border leave. The absolutely positioned path used to store
    // the declaration as the content height instead: an
    // `position:absolute; box-sizing:border-box; height:40px; padding:0 20px;
    // border:4px solid` box painted 48px tall where Edge paints 40 (the
    // box-geometry fixture's `l1-border-box-sizing` row), while the in-flow path
    // (`resolveHeight`) already subtracted them.
    if (style.boxSizing == "border-box")
    {
        const padBorder = element.box.paddingTop + element.box.paddingBottom +
            element.box.borderTop + element.box.borderBottom;
        return max(0, clamped - padBorder);
    }
    return clamped;
}

private int resolveHeight(Element element)
{
    auto style = element.style;
    const definite = resolveDefiniteHeight(element, style.containingHeight);
    if (definite >= 0) return definite;
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
        // An absolutely positioned element is positioned against the PADDING box
        // of its containing block, so `top:0`/`left:0` sit at the inner edge of
        // the BORDER - padding does not inset them. This used the content box, so
        // every absolute child inside a padded ancestor was shifted inward by
        // that padding and sized against a too-narrow width (a real page's
        // top-right decoration measured 33px off, and `width:100%` overlays came
        // out short by the padding).
        cbX = cb.box.x + cb.box.borderLeft;
        cbY = cb.box.y + cb.box.borderTop;
        cbW = cb.box.width + cb.box.paddingLeft + cb.box.paddingRight;
        cbH = cb.box.height + cb.box.paddingTop + cb.box.paddingBottom;
    }

    // An out-of-flow element normally never takes the in-flow child path that
    // resolves its own box, yet everything below reads box.margin*, box.padding*
    // and box.border* as already resolved - and so do the content origin and
    // painted box of a flex/grid/table container. Without this,
    // `position:absolute; width:300px; padding:0 30px` laid out and painted as a
    // 300px box with no padding at all and started its items at the border edge,
    // while Edge paints the 360px padding box and starts them at x=50.
    // Resolving here (the containing block width is known by now) keeps this
    // ahead of every consumer and is idempotent across passes.
    resolveBoxMetrics(element, cbW);

    const w = resolveWidth(element, cbW);
    // `resolveDefiniteHeight`, not a bare `resolveLength`: the declaration is a
    // border-box height when `box-sizing` says so, exactly as in the in-flow path.
    const h = resolveDefiniteHeight(element, cbH);
    element.box.width = w;
    element.box.height = h >= 0 ? h : 0;
    // Whether this element ends up with a height of its own, which is what its
    // children's percentage heights resolve against.
    bool heightDefinite = h >= 0;
    const bool heightAuto = h < 0;

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
    if (heightAuto && topGiven && bottomGiven)
    {
        absH = max(0, cbH - topV - bottomV - element.box.marginTop -
            element.box.marginBottom - element.box.paddingTop -
            element.box.paddingBottom - element.box.borderTop -
            element.box.borderBottom);
        element.box.height = absH;
        heightDefinite = true;
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
    // `absW` is the CONTENT width - `resolveWidth` returns the content box and
    // the both-insets rule above solves `cbW - insets - margins - padding -
    // border` - so the padding and border must NOT be taken off a second time.
    // Subtracting them again gave every child of a padded absolutely positioned
    // box 2x its padding less width: a `width:380px; padding:10px` cell laid its
    // children out 360px wide where Edge paints 380px, and a `clear:left` bar
    // inside another came out 20px short of Edge's.
    childFlow.width = max(0, absW);
    // A child's percentage height resolves against THIS element's content box
    // (CSS 10.5), not against this element's own containing block. Handing the
    // children `cbH` left `.j1 { position:absolute; height:80px } > i {
    // height:50% }` standing 0 tall - `cbH` was the empty body's height - where
    // Edge reports 40 (the box-geometry fixture's `j1-child-50-percent-height`
    // row). An element with no height of its own keeps the containing-block base.
    childFlow.height = heightDefinite ? element.box.height : cbH;
    childFlow.lineEnd = childFlow.x + childFlow.width;
    // Honor the element's OWN display (a flex/grid popup lays its children as
    // items, not as stacked blocks).
    layoutContents(element, childFlow, element);

    // CSS 10.3.7: with `width: auto` and only ONE inset given, the used width is
    // shrink-to-fit - never below the min-content width, never above the space
    // left by the given inset, and taking the preferred content width when it
    // fits. Only the both-insets case was handled above, so an absolutely
    // positioned flex bar stretched to `max-width` instead: a real page's
    // pill-shaped dock left an empty half running across the viewport. Measured
    // after the children are laid out so flex gaps and wrapping are counted.
    if (style.resolveLength(style.width, cbW) < 0 && !(leftGiven && rightGiven))
    {
        int contentRight = childFlow.x;
        foreach (child; element.children)
        {
            auto childEl = cast(Element) child;
            if (childEl is null || childEl.style.display == "none") continue;
            contentRight = max(contentRight, childEl.box.x + childEl.box.width +
                childEl.box.marginRight);
        }
        const int fitPadBorder = element.box.paddingLeft + element.box.paddingRight +
            element.box.borderLeft + element.box.borderRight;
        const int fitAvailable = cbW - (leftGiven ? leftV : 0) - (rightGiven ? rightV : 0);
        const int fitWanted = min(max(0, contentRight - childFlow.x),
            max(0, fitAvailable - fitPadBorder));
        const int fitW = clampMinMaxWidth(element, fitWanted) + fitPadBorder;
        if (fitW > 0 && fitW != absW)
        {
            absW = fitW;
            element.box.width = absW;
            if (rightGiven)
                element.box.x = cbX + cbW - absW - rightV - element.box.marginRight;
            childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
            childFlow.width = max(0, absW - fitPadBorder);
            childFlow.lineEnd = childFlow.x + childFlow.width;
            layoutContents(element, childFlow, element);
        }
    }

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
                // An absolutely positioned box establishes a block formatting
                // context, so an in-flow child's bottom margin stays INSIDE it
                // (CSS 8.3.1) and the auto height must reach that child's bottom
                // MARGIN edge (CSS 10.6.7). Dropping the margin made a padded
                // cell measure 80px where Edge measures 90, so its own
                // background and the box after it sat 10px high.
                const bool inFlowChild = childEl.style.position != "absolute" &&
                    childEl.style.position != "fixed";
                contentBottom = max(contentBottom, childEl.box.y + childEl.box.height +
                    (inFlowChild ? childEl.box.marginBottom : 0));
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

    int w = resolveWidth(element, cbW);
    // Same rule as the absolute path above: a declared height is a border-box
    // height when `box-sizing:border-box` says so.
    const h = resolveDefiniteHeight(element, cbH);
    element.box.width = w;
    element.box.height = h >= 0 ? h : 0;

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
    // CSS 10.3.7: with `width:auto` and both insets NOT given, a fixed box
    // shrink-to-fits its content. Filling the containing block instead stretched
    // django's docs widget - declared `position:fixed; right:15px; bottom:15px`
    // - across the whole viewport (x=-15, width=1300), so its list drew off the
    // left edge instead of sitting at the bottom right.
    if (style.resolveLength(style.width, cbW) < 0 && !(fixedLeft && fixedRight))
    {
        const int avail = fixedLeft ? max(0, cbW - fixedLeftV)
            : fixedRight ? max(0, cbW - fixedRightV) : cbW;
        w = clampMinMaxWidth(element, min(intrinsicWidth(element, avail), avail));
        element.box.width = w;
    }
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
    // CSS Text 3 `text-indent`: the first line's start shifts.
    const indent = resolveTextIndent(element.style, childFlow.width);
    if (indent != 0) childFlow.x += indent;
    layoutChildren(element, childFlow, element);
    // CSS 10.6.4: an auto-height fixed box takes its content's height, the rule
    // the absolute path already follows. Forcing 0 left django's docs widget a
    // 486x0 box, so its language list had no box to be positioned in.
    if (style.resolveLength(style.height, cbH) < 0 && !(fixedTop && fixedBottom))
    {
        const int contentTop = element.box.y + element.box.paddingTop +
            element.box.borderTop;
        const int contentBottom = max(childFlow.y, childFlow.inlineBottomAbs);
        element.box.height = clampMinMaxHeight(element,
            max(0, contentBottom - contentTop) + element.box.paddingTop +
            element.box.paddingBottom + element.box.borderTop +
            element.box.borderBottom);
        // A bottom-anchored box was placed from the stale auto height; move it
        // up now that the content height is known.
        if (topV < 0 && bottomV >= 0)
        {
            const int newY = cbY + cbH - element.box.height - bottomV -
                element.box.marginBottom;
            // The children were laid against the stale y, so they must move with
            // the box: painting uses their own boxes, so leaving them behind put
            // django's language widget 117px below its own re-placed box.
            shiftFixedSubtreeY(element, newY - element.box.y);
            element.box.y = newY;
        }
    }
}

/// Shift a laid-out subtree vertically by `dy` (used when a fixed box is moved
/// after its auto height becomes known).
private void shiftFixedSubtreeY(Element element, int dy)
{
    if (dy == 0) return;
    foreach (child; element.elements)
    {
        child.box.y += dy;
        shiftFixedSubtreeY(child, dy);
    }
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
    // A pending run is flushed before the block that follows it, whether it
    // holds an inline element or only text. CSS 2.1 9.2.1.1 makes text before a
    // block-level sibling an anonymous block box that keeps document order;
    // laying the block out first put its line above the label that precedes it
    // ("<div>2 block:<span style=display:block>X</span></div>").
    // Whitespace-only text nodes never start a run (below), so this cannot
    // reintroduce the blank line boxes an unconditional flush added to indented
    // real pages.
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
            // Only collapsible whitespace is ignorable here; a `&nbsp;` run is
            // real inline content (see `isCollapsibleWhitespaceOnly`).
            if (textChild !is null && isCollapsibleWhitespaceOnly(textChild.data))
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
            continue;
        }
        if (runPending)
        {
            const savedX = flow.x;
            layoutDirectText(element, flow, runStart, childIndex);
            flow.x = savedX;
            if (flow.inlineBottomAbs > flow.y) flow.y = flow.inlineBottomAbs;
            runPending = false;
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
    // The same metric the block and text paths advance by, so a line box and the
    // cursor moving past it agree. This read a fixed 18px and ignored percent and
    // bare-number line heights entirely.
    const lineHeight = resolveLineHeight(element, element.style.fontSizePx > 0 ?
        element.style.fontSizePx : 16);

    void emitLine()
    {
        flow.x = flow.x; // cursor stays; caller uses flow.
    }

    // Generated `::before`/`::after` boxes are part of this inline box's content
    // (CSS 12). `layoutChildren` splices them into `children` for a block's own
    // pass, but an INLINE element's content is placed by the enclosing block's
    // inline pass, which reaches it here — so an inline `i.icon` never measured
    // its `::before` glyph and the icon painted nothing. The membership test keeps
    // the already-spliced case from measuring the same box twice.
    bool alreadyInChildren(Element p)
    {
        foreach (c; element.children)
            if (c is p) return true;
        return false;
    }
    typeof(element.children) inlineChildren;
    if (element.pseudoBefore !is null && !alreadyInChildren(element.pseudoBefore))
        inlineChildren ~= element.pseudoBefore;
    inlineChildren ~= element.children;
    if (element.pseudoAfter !is null && !alreadyInChildren(element.pseudoAfter))
        inlineChildren ~= element.pseudoAfter;
    foreach (child; inlineChildren)
    {
        auto text = cast(TextNode) child;
        if (text !is null)
        {
            // Shape the line around active floats.
            const int leftEdge = flow.lineLeft(currentLineY, lineHeight);
            const int rightEdge = flow.lineRight(currentLineY, lineHeight);
            if (currentLineX < leftEdge) currentLineX = leftEdge;
            string runText = collapsibleText(element, text);
            // Same line-start rule as the block path, and the same shape as the
            // whitespace-only branch that follows: a separator at the start of a
            // line is removed, one in the middle of a line is kept.
            if (currentLineX <= leftEdge && runText.length > 0 && runText[0] == ' ')
                runText = runText[1 .. $];
            text.paintText = runText;
            const int textWidth = cast(int)(runText.length * 8);
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

/// True when an element has at least one element child that generates a box.
private static bool hasBoxChild(Element element)
{
    foreach (child; element.elements)
        if (child !is null && child.style.display != "none") return true;
    return false;
}

/// The nearest positioned ancestor of `element` (including `element` itself),
/// i.e. the containing block its absolutely positioned descendants resolve
/// against. `layoutDirectText` is entered without a threaded
/// `positionedAncestor`, so it derives the one that applies to the inline-block
/// whose block children it lays out instead of reaching for a name that is not
/// in scope there.
private static Element positionedAncestorOf(Element element)
{
    for (auto a = element; a !is null; a = a.parent)
    {
        auto p = a.style.position;
        if (p == "relative" || p == "absolute" || p == "fixed") return a;
    }
    return null;
}

/// Lay out the ELEMENT children of an inline-block through the normal child
/// path. The inline run places the box itself and lays out its own text, but a
/// block-level child (a fixed-size chip, an icon wrapper) never reached
/// `layoutChildren`, so it kept its 0x0 default box and the wrapper stayed one
/// line tall where Edge sizes the wrapper to the children it contains.
private void layoutInlineBlockChildren(Element element, ref FlowContext inner,
    Element positionedAncestor)
{
    if (!hasBoxChild(element)) return;
    withGeneratedBoxes(element, { layoutChildren(element, inner, positionedAncestor); });
}

/// The bottom border edge of an inline-block's in-flow element children, so an
/// auto-height wrapper can be measured from the content it actually contains.
private static int inlineBlockChildBottom(Element element, int fallback)
{
    int bottom = fallback;
    foreach (child; element.elements)
    {
        auto ce = cast(Element) child;
        if (ce is null || ce.style.display == "none") continue;
        auto ps = ce.style.position;
        if (ps == "absolute" || ps == "fixed") continue;
        bottom = max(bottom, ce.box.y + ce.box.height + ce.box.marginBottom);
    }
    return bottom;
}

private void layoutInlineBlock(Element element, ref FlowContext flow, Element positionedAncestor)
{
    resolveBoxMetrics(element, flow.width);
    const auto width = resolveWidth(element, flow.width);
    // `width` is the CONTENT width; the box the parent flow must clear is the
    // border box, i.e. content plus padding and border.
    const borderW = width + element.box.paddingLeft + element.box.paddingRight +
        element.box.borderLeft + element.box.borderRight;
    if (flow.x + borderW > flow.lineEnd && flow.x > flow.lineEnd - flow.width)
        flow.newLine();
    element.box.x = flow.x;
    element.box.y = flow.y;
    element.box.width = width;
    element.box.height = resolveHeight(element) >= 0 ? resolveHeight(element) : 18;
    // Lay the inline-block's children INSIDE it, starting at its content origin.
    // The parent cursor used to be advanced past the box BEFORE the children ran,
    // so an inline-block's own text was laid out to the RIGHT of the box: a real
    // page's white-on-white call to action painted its label outside the green
    // button (which then looked empty) and every chip/badge sat beside its pill.
    auto inner = flow;
    inner.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    inner.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    inner.lineEnd = inner.x + element.box.width;
    layoutChildren(element, inner, positionedAncestor);
    flow.x += borderW;
}

/// Lay out an element's children according to the element's OWN display type.
/// Used for grid/flex items, which may themselves be flex/grid containers
/// (nested flex/grid); `positioned` means the element's box is already placed
/// by its parent, so it must not be repositioned here.
private void layoutContents(Element element, ref FlowContext flow, Element positionedAncestor)
{
    // A flex/grid item reaches its content through here, not the block child
    // flow, so `text-indent` must be applied for it too - django's header logo
    // is a flex item that hides its text behind the logo image this way.
    const indent = resolveTextIndent(element.style, flow.width);
    if (indent != 0) flow.x += indent;
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
        element.box.y = collapsedTopY(flow, element);

        int width = resolveWidth(element, flow.width);
        // An inline-flex container with no explicit width sizes to its content
        // (like an inline-block), never filling the containing block.
        if (inline && element.style.resolveLength(element.style.width, flow.width) < 0)
            width = 0;
        element.box.width = width;
    }
    int width = element.box.width;

    // `width` (from `resolveWidth`) is the CONTENT box - the contract `paint` relies
    // on when it rebuilds the border box - so the item region below is `width` itself:
    // re-subtracting the padding/border would shrink every padded container's region.
    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width);



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
        // `flex-basis` sets the item's initial main size; `auto` (the initial
        // value) falls back to `width`. An auto width falls back to content, or
        // to 0 for a growing item (which then takes a share of the free space).
        const int basisLen = ce.style.resolveLength(ce.style.flexBasis, innerW);
        auto basis = basisLen >= 0 ? basisLen : ce.style.resolveLength(ce.style.width, innerW);
        if (basis < 0)
            basis = grow == 0 ? intrinsicWidth(ce, innerW) : 0;
        itemWidths ~= basis >= 0 ? basis : 0;
    }

    // flex-direction: column — the main axis is vertical. Items stack top to
    // bottom (bottom to top for `column-reverse`), `justify-content` distributes
    // the main-axis free space, and `align-items`/`align-self` place each item on
    // the horizontal cross axis, where the default `stretch` fills the content
    // width (CSS Flexbox 9.3-9.5). Only the naive top-left stacking used to be
    // implemented, so a centred, end-aligned or space-distributed column rendered
    // against the corner and `column-reverse` was ignored entirely.
    if (style.flexDirection == "column" || style.flexDirection == "column-reverse")
    {
        const bool reverse = style.flexDirection == "column-reverse";
        // Measure each item first: its own content height on the main axis and
        // its content width on the cross axis.
        int[] itemHts;
        int[] itemWds;
        int totalH = 0;
        foreach (ce; items)
        {
            resolveBoxMetrics(ce, innerW);
            const int wExp = ce.style.resolveLength(ce.style.width, innerW);
            const int w = wExp >= 0 ? wExp : innerW;
            ce.box.width = w;
            auto sub = FlowContext();
            sub.x = innerX + ce.box.marginLeft + ce.box.paddingLeft + ce.box.borderLeft;
            sub.y = innerY + ce.box.marginTop + ce.box.paddingTop + ce.box.borderTop;
            sub.width = max(0, w - ce.box.paddingLeft - ce.box.paddingRight -
                ce.box.borderLeft - ce.box.borderRight);
            sub.lineEnd = sub.x + sub.width;
            const int subTop = sub.y;
            layoutContents(ce, sub, ce);
            const int contentH = max(sub.contentBottom, sub.y - subTop);
            const int hExp = ce.style.resolveLength(ce.style.height, style.containingHeight);
            const int h = hExp >= 0 ? hExp : contentBoxHeight(ce, contentH);
            ce.box.height = h;
            itemHts ~= h;
            itemWds ~= w;
            totalH += h + ce.box.marginTop + ce.box.marginBottom + gapPx;
        }
        if (items.length) totalH -= gapPx;
        const int hExp2 = element.style.resolveLength(element.style.height, style.containingHeight);
        const int innerH = hExp2 >= 0 ? max(0, hExp2) : contentBoxHeight(element, totalH);

        // justify-content (main axis, CSS Flexbox 9.5). An item's own main-axis
        // `auto` margin absorbs the free space first and disables justify-content
        // (CSS Flexbox 8.1): `margin-top:auto` pins an item to the bottom of a
        // column, the standard way to keep a footer at the card's foot.
        const int n = cast(int) items.length;
        const int free = innerH > totalH ? innerH - totalH : 0;
        int autoMain = 0;
        foreach (ce; items)
            autoMain += (ce.box.marginTopAuto ? 1 : 0) + (ce.box.marginBottomAuto ? 1 : 0);
        int lead = 0;
        int gapExtra = 0;
        if (autoMain == 0)
        {
            if (style.justifyContent == "center")
                lead = free / 2;
            else if (style.justifyContent == "flex-end" || style.justifyContent == "end")
                lead = free;
            else if (style.justifyContent == "space-between")
                gapExtra = n > 1 ? free / (n - 1) : 0;
            else if (style.justifyContent == "space-around")
            {
                gapExtra = n > 0 ? free / n : 0;
                lead = gapExtra / 2;
            }
            else if (style.justifyContent == "space-evenly")
            {
                gapExtra = n > 0 ? free / (n + 1) : 0;
                lead = gapExtra;
            }
        }
        const int autoShare = autoMain > 0 ? free / autoMain : 0;
        int[] effTop;
        int[] effBot;
        effTop.length = items.length;
        effBot.length = items.length;
        foreach (i, ce; items)
        {
            effTop[i] = ce.box.marginTopAuto ? autoShare : ce.box.marginTop;
            effBot[i] = ce.box.marginBottomAuto ? autoShare : ce.box.marginBottom;
        }

        // Place on the main axis; `column-reverse` packs from the bottom edge.
        if (reverse)
        {
            int cursorBottom = innerY + innerH - lead;
            foreach (i, ce; items)
            {
                ce.box.y = cursorBottom - effBot[i] - itemHts[i];
                cursorBottom -= itemHts[i] + effTop[i] + effBot[i] + gapPx + gapExtra;
            }
        }
        else
        {
            int cursorTop = innerY + lead;
            foreach (i, ce; items)
            {
                ce.box.y = cursorTop + effTop[i];
                cursorTop += itemHts[i] + effTop[i] + effBot[i] + gapPx + gapExtra;
            }
        }

        // align-items / align-self on the cross axis (horizontal for a column).
        // A cross-axis `auto` margin absorbs that free space and overrides
        // align-self (CSS Flexbox 8.1).
        foreach (i, ce; items)
        {
            const string alignValue = (ce.style.alignSelf.length && ce.style.alignSelf != "auto")
                ? ce.style.alignSelf : style.alignItems;
            const int outerW = itemWds[i] + ce.box.paddingLeft + ce.box.paddingRight +
                ce.box.borderLeft + ce.box.borderRight + ce.box.marginLeft + ce.box.marginRight;
            if (ce.box.marginLeftAuto || ce.box.marginRightAuto)
            {
                if (ce.box.marginLeftAuto && ce.box.marginRightAuto)
                    ce.box.x = innerX + (innerW - outerW) / 2;
                else if (ce.box.marginLeftAuto)
                    ce.box.x = innerX + (innerW - outerW);
                else
                    ce.box.x = innerX;
            }
            else if (alignValue == "center")
                ce.box.x = innerX + ce.box.marginLeft + (innerW - outerW) / 2;
            else if (alignValue == "flex-end" || alignValue == "end")
                ce.box.x = innerX + ce.box.marginLeft + (innerW - outerW);
            else
                ce.box.x = innerX + ce.box.marginLeft;
        }

        // Re-lay out each item inside its final box so its children and text
        // move with it and a percentage height resolves against the placed box.
        foreach (i, ce; items)
        {
            auto sub = FlowContext();
            sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
            sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
            sub.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight -
                ce.box.borderLeft - ce.box.borderRight);
            sub.lineEnd = sub.x + sub.width;
            sub.height = itemHts[i];
            layoutContents(ce, sub, ce);
        }

        element.box.height = hExp2 >= 0 ? hExp2 : contentBoxHeight(element, totalH);
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
        // A flex container is a block-level box, so its bottom margin collapses
        // with the next sibling's top margin (CSS 8.3.1). Recording the margin
        // without marking the previous box left the next sibling on the
        // non-collapsing branch and added its margin in full, so the fixture's
        // grid started at y=70 where Edge puts it at y=60.
        flow.hasPrevBlock = true;
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
    // The widths before `flex-grow` is applied: a wrapping container distributes
    // free space per line, so each line needs the un-grown base widths.
    int[] baseWidths = itemWidths.dup;
    // The main size is definite only when the container has a specified width or
    // is not an inline-level shrink-to-fit box (CSS Flexbox 9.2). An auto-width
    // inline-flex has no free space to distribute: its items keep their base
    // sizes and the container then sizes to their sum.
    const bool mainDefinite = !(inline &&
        element.style.resolveLength(element.style.width, flow.width) < 0);
    if (mainDefinite && remaining > 0 && totalFlex > 0)
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
    else if (mainDefinite && remaining < 0)
    {
        // Flexbox 9.7: the items overflow, so `flex-shrink` (initial 1) takes
        // space back, weighted by shrink × base size, down to the automatic
        // minimum size. Without this an overflowing row spilled out of its
        // container where Edge compresses the shrinking items.
        import auroraweb.dom : cssInt;
        int totalShrink = 0;
        foreach (i, ce; items)
        {
            const int s = ce.style.flexShrink.length ? cssInt(ce.style.flexShrink) : 1;
            totalShrink += s * baseWidths[i];
        }
        if (totalShrink > 0)
        {
            const int over = -remaining;
            foreach (i, ce; items)
            {
                const int s = ce.style.flexShrink.length ? cssInt(ce.style.flexShrink) : 1;
                const int cut = (over * s * baseWidths[i]) / totalShrink;
                // The automatic minimum size: the content-based minimum, i.e. the
                // smaller of the specified size and the min-content width. The
                // item's OWN `width` is not the content suggestion, so it is
                // ignored here — otherwise a `width:200px;flex-shrink:1` item
                // would floor back at 200 and never shrink.
                ce.style.containingWidth = innerW;
                const int minC = minContentWidth(ce, innerW, true);
                const int floorW = ce.style.resolveLength(ce.style.width, innerW) >= 0
                    ? min(baseWidths[i], minC) : minC;
                itemWidths[i] = max(floorW, max(0, baseWidths[i] - cut));
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

    // flex-wrap: wrap — items that do not fit continue on a following line
    // (CSS Flexbox 9.3). Only containers that ask for wrapping take this path;
    // `nowrap` (the default) keeps the single-line code below byte-identical, so
    // no existing page can change behaviour here.
    if (style.flexWrap == "wrap" && items.length > 0)
    {
        // A line is formed from each item's base size. An auto-width item's base
        // size is floored at its content (the automatic minimum size, CSS
        // Flexbox 4.5), exactly as the single-line path floors it just above.
        // Without it a wrapping container measured django's auto-width header
        // menu a few pixels narrow and folded its last label ("DONATE") under
        // the heart, where Edge keeps the whole menu on one line.
        foreach (i, ce; items)
        {
            if (ce.style.resolveLength(ce.style.width, innerW) >= 0) continue;
            ce.style.containingWidth = innerW;
            baseWidths[i] = max(baseWidths[i], minContentWidth(ce, innerW));
        }

        // Partition into lines by outer width, using the base (pre-grow) widths.
        int[][] lines;
        {
            int[] current;
            int usedW = 0;
            foreach (i, ce; items)
            {
                const int outer = baseWidths[i] + ce.box.paddingLeft + ce.box.paddingRight +
                    ce.box.borderLeft + ce.box.borderRight +
                    ce.box.marginLeft + ce.box.marginRight;
                const int withThis = usedW + outer + (current.length ? gapPx : 0);
                if (current.length && withThis > innerW)
                {
                    lines ~= current;
                    current = [];
                    current ~= cast(int) i;
                    usedW = outer;
                }
                else
                {
                    current ~= cast(int) i;
                    usedW = withThis;
                }
            }
            if (current.length) lines ~= current;
        }

        import auroraweb.dom : cssInt;
        int lineTop = innerY;
        int[] lineHeights;
        foreach (line; lines)
        {
            // This line's item widths, then its share of the free space.
            int[] widths = new int[line.length];
            int used = 0;
            int lineFlex = 0;
            foreach (k, i; line)
            {
                auto ce = items[i];
                widths[k] = baseWidths[i];
                used += widths[k] + ce.box.paddingLeft + ce.box.paddingRight +
                    ce.box.borderLeft + ce.box.borderRight +
                    ce.box.marginLeft + ce.box.marginRight;
                auto gs = ce.style.flexGrow;
                lineFlex += gs.length ? cssInt(gs) : 0;
            }
            if (line.length > 1) used += gapPx * (line.length - 1);
            const int lineFreeRaw = innerW > used ? innerW - used : 0;
            if (lineFlex > 0)
            {
                foreach (k, i; line)
                {
                    auto gs = items[i].style.flexGrow;
                    const int g = gs.length ? cssInt(gs) : 0;
                    if (g > 0) widths[k] += (lineFreeRaw * g) / lineFlex;
                }
            }
            int usedAfter = 0;
            foreach (k, i; line)
            {
                auto ce = items[i];
                usedAfter += widths[k] + ce.box.paddingLeft + ce.box.paddingRight +
                    ce.box.borderLeft + ce.box.borderRight +
                    ce.box.marginLeft + ce.box.marginRight;
            }
            if (line.length > 1) usedAfter += gapPx * (line.length - 1);
            const int lineFree = innerW > usedAfter ? innerW - usedAfter : 0;
            const int lineN = cast(int) line.length;
            int lineGapExtra = 0;
            int lineLead = 0;
            if (style.justifyContent == "center")
                lineLead = lineFree / 2;
            else if (style.justifyContent == "flex-end")
                lineLead = lineFree;
            else if (style.justifyContent == "space-between")
                lineGapExtra = lineN > 1 ? lineFree / (lineN - 1) : 0;
            else if (style.justifyContent == "space-around")
            {
                lineGapExtra = lineFree / lineN;
                lineLead = lineGapExtra / 2;
            }
            else if (style.justifyContent == "space-evenly")
            {
                lineGapExtra = lineFree / (lineN + 1);
                lineLead = lineGapExtra;
            }
            // Main-axis `auto` margins absorb a line's free space before
            // `justify-content` applies (CSS Flexbox 8.1), so they win outright
            // and the line's free space becomes zero. The single-line path does
            // this as well; without it a wrapping container left an auto-margined
            // item flush against its neighbour, so django's header menu
            // (`margin-left:auto; order:2`) never reached the container's right
            // edge the way Edge renders it.
            int[] extraL = new int[line.length];
            int[] extraR = new int[line.length];
            int autoCount = 0;
            foreach (k, i; line)
            {
                auto ce = items[i];
                const ml = ce.style.marginLeft.strip().toLower();
                const mr = ce.style.marginRight.strip().toLower();
                const shorthand = ce.style.margin.strip().toLower();
                if (ml == "auto" || (ml.length == 0 && shorthand.indexOf("auto") >= 0))
                { extraL[k] = 1; autoCount++; }
                if (mr == "auto" || (mr.length == 0 && shorthand.indexOf("auto") >= 0))
                { extraR[k] = 1; autoCount++; }
            }
            if (autoCount > 0)
            {
                const int share = lineFree / autoCount;
                foreach (k, i; line)
                {
                    if (extraL[k] != 0) extraL[k] = share;
                    if (extraR[k] != 0) extraR[k] = share;
                }
                lineLead = 0;
                lineGapExtra = 0;
            }
            int lineCursor = innerX + lineLead;
            int lineH = 0;
            foreach (k, i; line)
            {
                auto ce = items[i];
                resolveBoxMetrics(ce, innerW);
                ce.box.x = lineCursor + ce.box.marginLeft + extraL[k];
                ce.box.y = lineTop + ce.box.marginTop;
                ce.box.width = widths[k];
                const int itemH = resolveHeight(ce);
                ce.box.height = itemH >= 0 ? itemH : 0;
                auto sub = FlowContext();
                sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
                sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
                sub.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight -
                    ce.box.borderLeft - ce.box.borderRight);
                sub.lineEnd = sub.x + sub.width;
                const int subTop = sub.y;
                layoutContents(ce, sub, ce);
                const int contentH = max(sub.contentBottom, sub.y - subTop);
                if (itemH < 0 && contentH > 0)
                    ce.box.height = max(0,
                        contentH + ce.box.paddingTop + ce.box.paddingBottom);
                // The line's cross size covers the item's cross margins, and the
                // aligned position is the margin box, exactly as the single-line
                // row path above does (CSS Flexbox 9.4 and 9.6).
                lineH = max(lineH, ce.box.height + ce.box.marginTop + ce.box.marginBottom);
                lineCursor += widths[k] + ce.box.paddingLeft + ce.box.paddingRight +
                    ce.box.borderLeft + ce.box.borderRight +
                    ce.box.marginLeft + ce.box.marginRight + gapPx + lineGapExtra +
                    extraL[k] + extraR[k];
            }
            // align-items / align-self inside this line's cross size.
            foreach (k, i; line)
            {
                auto ce = items[i];
                const string alignValue =
                    (ce.style.alignSelf.length && ce.style.alignSelf != "auto")
                    ? ce.style.alignSelf : style.alignItems;
                // `stretch` (the initial value) grows an auto-cross-size item to
                // this line's cross size; its contents are re-laid out inside
                // the taller box (CSS Flexbox 8.3), matching Edge where the
                // engine used to leave the item at its content height.
                if (alignValue == "stretch" && resolveHeight(ce) < 0)
                {
                    const int target = lineH - ce.box.marginTop - ce.box.marginBottom -
                        ce.box.paddingTop - ce.box.paddingBottom -
                        ce.box.borderTop - ce.box.borderBottom;
                    if (target > ce.box.height)
                    {
                        ce.box.height = target;
                        auto sub = FlowContext();
                        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
                        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
                        sub.width = max(0, ce.box.width - ce.box.paddingLeft -
                            ce.box.paddingRight - ce.box.borderLeft - ce.box.borderRight);
                        sub.lineEnd = sub.x + sub.width;
                        sub.height = ce.box.height;
                        layoutContents(ce, sub, ce);
                    }
                }
                else if (alignValue == "flex-end" || alignValue == "end")
                    placeItemY(ce, lineTop + lineH - ce.box.height - ce.box.marginBottom);
                else if (alignValue == "center")
                    placeItemY(ce, lineTop + (lineH - ce.box.height - ce.box.marginTop -
                        ce.box.marginBottom) / 2 + ce.box.marginTop);
            }
            lineHeights ~= lineH;
            lineTop += lineH;
        }
        // align-content distributes the cross space left over when the container
        // is taller than its lines (CSS Flexbox 8.5). The lines were placed at
        // their natural positions, so each one is shifted by its share and its
        // items re-laid in place; a shifted item's children and text runs move
        // with it because the item is laid out again inside its moved box.
        const int naturalCross = lineTop - innerY;
        const int definiteCross = element.style.resolveLength(element.style.height,
            style.containingHeight);
        if (definiteCross > naturalCross && lines.length > 0)
        {
            const int extraCross = definiteCross - naturalCross;
            const int lineCount = cast(int) lines.length;
            // `align-content: stretch` (and its `normal` initial value) grows
            // every line by an equal share of the left-over cross space, after
            // which `align-items: stretch` fills the taller line (CSS Flexbox
            // 8.5). Leaving the lines packed at the top is what the engine used
            // to do and what Edge does not.
            const bool stretchContent = style.alignContent == "stretch" ||
                style.alignContent == "normal";
            int crossGap = 0;
            int crossLead = 0;
            if (style.alignContent == "center")
                crossLead = extraCross / 2;
            else if (style.alignContent == "flex-end" || style.alignContent == "end")
                crossLead = extraCross;
            else if (style.alignContent == "space-between")
                crossGap = lineCount > 1 ? extraCross / (lineCount - 1) : 0;
            else if (style.alignContent == "space-around")
            {
                crossGap = extraCross / lineCount;
                crossLead = crossGap / 2;
            }
            else if (style.alignContent == "space-evenly")
            {
                crossGap = extraCross / (lineCount + 1);
                crossLead = crossGap;
            }
            if (stretchContent)
            {
                // The last line absorbs the integer remainder so the lines fill
                // the container exactly (its bottom edge is fixed).
                const int base = extraCross / lineCount;
                int shift = 0;
                foreach (li, line; lines)
                {
                    const int share = (li == lineCount - 1)
                        ? extraCross - base * (lineCount - 1) : base;
                    const int lineCross = lineHeights[li] + share;
                    const int delta = shift;
                    shift += share;
                    foreach (k, i; line)
                    {
                        auto ce = items[i];
                        ce.box.y += delta;
                        if (resolveHeight(ce) < 0)
                        {
                            const int target = lineCross - ce.box.marginTop -
                                ce.box.marginBottom - ce.box.paddingTop -
                                ce.box.paddingBottom - ce.box.borderTop -
                                ce.box.borderBottom;
                            if (target > ce.box.height) ce.box.height = target;
                        }
                        auto sub = FlowContext();
                        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
                        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
                        sub.width = max(0, ce.box.width - ce.box.paddingLeft -
                            ce.box.paddingRight - ce.box.borderLeft - ce.box.borderRight);
                        sub.lineEnd = sub.x + sub.width;
                        sub.height = ce.box.height;
                        layoutContents(ce, sub, ce);
                    }
                }
            }
            else if (crossLead != 0 || crossGap != 0)
            {
                foreach (li, line; lines)
                {
                    const int delta = crossLead + cast(int) li * crossGap;
                    if (delta == 0) continue;
                    foreach (k, i; line)
                    {
                        auto ce = items[i];
                        ce.box.y += delta;
                        auto sub = FlowContext();
                        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
                        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
                        sub.width = max(0, ce.box.width - ce.box.paddingLeft -
                            ce.box.paddingRight - ce.box.borderLeft - ce.box.borderRight);
                        sub.lineEnd = sub.x + sub.width;
                        layoutContents(ce, sub, ce);
                    }
                }
            }
        }
        element.box.height = element.style.resolveLength(element.style.height,
            style.containingHeight) >= 0
            ? element.style.resolveLength(element.style.height, style.containingHeight)
            : contentBoxHeight(element, lineTop - innerY);
        layOwnDirectText(element, innerX, innerY, innerW, style.containingHeight);
        flow.prevBottomMargin = element.box.marginBottom;
        flow.hasPrevBlock = true;
        flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
        return;
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
        // An item's OUTER cross size is what a flex line measures (CSS Flexbox
        // 9.4), so its cross-axis margins are part of the line. Counting the
        // border box alone left djangoproject.com's header 20px short: the
        // `header .logo{margin:10px 4px}` contributed nothing, so the container
        // measured 36px where Edge makes it 56 and the header ended 20px high.
        maxChildHeight = max(maxChildHeight, ce.box.height + ce.box.marginTop + ce.box.marginBottom);
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

    // The cross size of a single-line row is the container's content height when
    // it is definite, falling back to the tallest item only otherwise (CSS
    // Flexbox 9.4). Measuring against the tallest ITEM alone packed every item
    // to the top of a taller container: a 60px row put its 20px items at y=0
    // instead of centring them at y=20.
    int crossSize = maxChildHeight;
    {
        const int declaredH = element.style.resolveLength(element.style.height,
            style.containingHeight);
        if (declaredH >= 0) crossSize = max(crossSize, declaredH);
    }
    // `stretch` is the flexbox initial value (`align-items` defaults to it): an
    // item whose own cross size is auto grows to fill the line's cross size (CSS
    // Flexbox 8.3). The engine used to leave such items at their content height,
    // so a background-only flex item painted nothing where Edge fills the row.
    // The item's contents are re-laid out inside the taller box so a percentage
    // height or a nested row follows. Applied before the auto-margin pass so the
    // horizontal shift it applies to a stretched item still stands.
    foreach (ce; items)
    {
        const string alignValue = (ce.style.alignSelf.length && ce.style.alignSelf != "auto")
            ? ce.style.alignSelf : style.alignItems;
        if (alignValue != "stretch") continue;
        // A cross-axis `auto` margin absorbs the free space itself and disables
        // stretching (CSS Flexbox 8.1); leave such an item to the auto-margin
        // placement below.
        if (ce.box.marginTopAuto || ce.box.marginBottomAuto) continue;
        if (resolveHeight(ce) >= 0) continue; // a definite cross size: not stretched
        const int target = crossSize - ce.box.marginTop - ce.box.marginBottom -
            ce.box.paddingTop - ce.box.paddingBottom -
            ce.box.borderTop - ce.box.borderBottom;
        if (target <= ce.box.height) continue;
        ce.box.height = target;
        auto sub = FlowContext();
        sub.x = ce.box.x + ce.box.paddingLeft + ce.box.borderLeft;
        sub.y = ce.box.y + ce.box.paddingTop + ce.box.borderTop;
        sub.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight -
            ce.box.borderLeft - ce.box.borderRight);
        sub.lineEnd = sub.x + sub.width;
        // The containing block height for a percentage-height child is the
        // stretched content box, so `height:100%` fills it (CSS 10.5).
        sub.height = ce.box.height;
        layoutContents(ce, sub, ce);
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

    // align-items / align-self on the row's cross axis (CSS Flexbox 8.3 and
    // 8.4). Only `center` used to be honoured, so a toolbar declaring
    // `align-items: flex-start` centred its buttons and one declaring `flex-end`
    // packed them to the top. `align-self` overrides the container per item;
    // `stretch` was already applied to auto-height items above, using the
    // `crossSize` computed there.
    foreach (ce; items)
    {
        // A cross-axis (`margin-top`/`margin-bottom`) `auto` margin absorbs the
        // line's free cross space and overrides `align-self` (CSS Flexbox 8.1):
        // both auto centre the item, a lone top-auto pins it to the bottom.
        if (ce.box.marginTopAuto || ce.box.marginBottomAuto)
        {
            const int outerH = ce.box.height + ce.box.paddingTop + ce.box.paddingBottom +
                ce.box.borderTop + ce.box.borderBottom + ce.box.marginTop + ce.box.marginBottom;
            if (ce.box.marginTopAuto && ce.box.marginBottomAuto)
                placeItemY(ce, innerY + (crossSize - outerH) / 2);
            else if (ce.box.marginTopAuto)
                placeItemY(ce, innerY + crossSize - outerH);
            else
                placeItemY(ce, innerY);
            continue;
        }
        // (`align` is a D keyword, hence the name.)
        const string alignValue = (ce.style.alignSelf.length && ce.style.alignSelf != "auto")
            ? ce.style.alignSelf : style.alignItems;
        // The box that alignment places is the item's MARGIN box (CSS Flexbox
        // 9.6): its cross-axis margins offset it inside the line, which the
        // column branch above already honours. Ignoring them put a margined item
        // flush with the line's start and a centred one off by its own margin -
        // django's 10px-margined logo sat at y=10 where Edge puts it at y=20.
        if (alignValue == "flex-start" || alignValue == "start")
            placeItemY(ce, innerY + ce.box.marginTop);
        else if (alignValue == "flex-end" || alignValue == "end")
            placeItemY(ce, innerY + crossSize - ce.box.height - ce.box.marginBottom);
        else if (alignValue == "center")
            placeItemY(ce, innerY + (crossSize - ce.box.height - ce.box.marginTop -
                ce.box.marginBottom) / 2 + ce.box.marginTop);
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
            auto lay = shapeText(tn.data, px, 0, 0.0, faceOf(&element.style));
            textW = max(textW, measuredWidth(lay, 0));
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
    // `box.height` is the CONTENT box throughout this engine (paint.d rebuilds
    // the border box by adding padding and border), so the auto height must be
    // the content height even for a `box-sizing: border-box` row: using a
    // border-box height here painted a padded border-box row 100px tall where
    // Edge paints 70. `clampedContentHeight` is that content height; the
    // container's own padding and border are added by the painter, not here.
    element.box.height = hPx >= 0 ? hPx : clampedContentHeight(element, contentHeight);

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

    // A grid/table container is a block-level box: mark the previous box so the
    // next sibling's top margin collapses with this box's bottom margin (CSS
    // 8.3.1) instead of being added in full.
    flow.prevBottomMargin = element.box.marginBottom;
    flow.hasPrevBlock = true;
    // The row measured itself as a CONTENT box (clampedContentHeight above), so
    // the flow advances by the border box: without the container's own padding
    // and border the next sibling sat one padding-and-border too high.
    flow.y = max(flow.y, element.box.y + borderBoxHeight(element) + element.box.marginBottom);
}

private int sumWidths(int[] widths)
{
    int total = 0;
    foreach (w; widths) total += w;
    return total;
}

/// Parse a grid-template-columns value into resolved column widths.
private int[] resolveGridTracks(string value, int innerW, int gap = 0)
{
    import auroraweb.dom : cssInt;
    int[] result;
    int fixedTotal = 0;
    int frCount = 0;
    auto parts = splitGridTracks(value);
    int trackCount = 0;
    foreach (rawPart; parts)
        if (normalizeTrack(rawPart).length) trackCount++;
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
    // Second pass: fill fr slots with remaining / frCount. `1fr` distributes the
    // space left after the fixed tracks AND the gaps between the tracks (CSS
    // Grid 11.7): ignoring the gap made every `1fr` track one gap too wide, so a
    // 2-column 10px-gap grid 210px wide got 105px tracks where Edge uses 100 and
    // the last track overflowed the content box.
    const remaining = innerW - fixedTotal - gap * cast(int) max(0, trackCount - 1);
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
/// The y a block-level box takes in `flow`: the flow position plus its top
/// margin, honouring margin collapsing. A box whose top margin already collapsed
/// into its parent (`flow.suppressTopMargin`) must not add it a second time, and
/// it collapses with an adjacent previous block's bottom margin. `layoutFlex`,
/// `layoutGrid` and `layoutTable` used to add `marginTop` unconditionally, so any
/// flex/grid/table container with a top margin was pushed down twice: the
/// flex-grid fixture's `.flex{margin:10px}` painted at y=20 where Edge, and this
/// engine's own `layoutBlock`, put it at y=10.
private int collapsedTopY(ref FlowContext flow, Element element)
{
    int top = element.box.marginTop;
    if (flow.suppressTopMargin)
    {
        flow.suppressTopMargin = false;
        top = 0;
    }
    else if (flow.hasPrevBlock)
        return flow.y + (collapseVerticalMargins(flow.prevBottomMargin, top) -
            flow.prevBottomMargin);
    return flow.y + top;
}

private void layoutGrid(Element element, ref FlowContext flow, Element positionedAncestor,
    bool positioned = false)
{
    if (!positioned)
    {
        resolveBoxMetrics(element, flow.width);
        element.box.x = flow.x + element.box.marginLeft;
        element.box.y = collapsedTopY(flow, element);
        element.box.width = resolveWidth(element, flow.width);
    }
    // As in `layoutFlex`: `width` is the content box, so tracks span `width` itself.
    const width = element.box.width;

    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width);

    auto style = element.style;
    // `gap` is the shorthand that sets BOTH `row-gap` and `column-gap` (CSS Box
    // Alignment 1). Reading only the longhands dropped it: the flex-grid
    // fixture's `gap:9px` was ignored, so its 60px and 90px columns sat at x=10
    // and x=70 back to back where Edge places them at x=10 and x=79. Resolved
    // before the tracks, because the column gap is part of the fr distribution.
    const string colGapSrc = style.columnGap.length ? style.columnGap : style.gap;
    const string rowGapSrc = style.rowGap.length ? style.rowGap : style.gap;
    const colGap = colGapSrc.length ? max(0, style.resolveLength(colGapSrc, innerW)) : 0;
    const rowGap = rowGapSrc.length ? max(0, style.resolveLength(rowGapSrc, innerW)) : 0;
    auto tracks = resolveGridTracks(style.gridTemplateColumns, innerW, colGap);
    if (tracks.length == 0) tracks = [innerW];
    // Explicit row tracks (px/%); auto rows are sized from content.
    auto rowTracks = style.gridTemplateRows.length ?
        resolveGridTracks(style.gridTemplateRows, style.containingHeight, rowGap) : null;

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
    // A track is a ceiling, not a fixed width: an item declaring its own
    // width/max-width keeps it (CSS 9.3). Every place that sizes an item must
    // go through this - the re-lay pass below sets widths again, and forcing an
    // item to the full track made a real page's 42rem hero panel 1080px wide,
    // overflowing its column and clipping its heading.
    int itemWidth(Element ce, int trackW)
    {
        import std.algorithm : max, min;
        int w = trackW;
        const dw = ce.style.resolveLength(ce.style.width, trackW);
        if (dw >= 0) w = min(w, dw);
        const mw = ce.style.resolveLength(ce.style.maxWidth, trackW);
        if (mw >= 0) w = min(w, mw);
        const nw = ce.style.resolveLength(ce.style.minWidth, trackW);
        if (nw >= 0) w = max(w, nw);
        return w;
    }
    // One definition of a grid item's content flow, used by BOTH passes below.
    // Keeping them in step by hand drifted twice: the re-lay used the raw track
    // width and the item's border-box origin, so children wrapped against the
    // wrong width and ignored the item's own padding - a real page's hero
    // heading then sat at the panel's border edge and a floating dock covered it.
    FlowContext itemContentFlow(Element ce, int originX, int originY)
    {
        FlowContext f;
        f.x = originX + ce.box.paddingLeft + ce.box.borderLeft;
        f.y = originY + ce.box.paddingTop + ce.box.borderTop;
        f.width = max(0, ce.box.width - ce.box.paddingLeft - ce.box.paddingRight -
            ce.box.borderLeft - ce.box.borderRight);
        f.lineEnd = f.x + f.width;
        return f;
    }
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
        ce.box.width = itemWidth(ce, tracks[colIndex]);
        // A grid item is its own containing block: percentages and min(100%, …)
        // inside it must resolve against its track, not 0. layoutGrid bypasses
        // layoutBlock - where this is normally set - so a real page's hero panel
        // measured the whole grid width instead of its column.
        ce.style.containingWidth = ce.box.width;
        ce.style.containingHeight = style.containingHeight;
        resolveBoxMetrics(ce, ce.box.width);
        // Item intrinsic height: explicit height, or content-based estimate.
        const hPx = ce.style.resolveLength(ce.style.height, style.containingHeight);
        int itemH = hPx >= 0 ? hPx : 18;
        // Lay the cell's children to measure content.
        auto sub = itemContentFlow(ce, ce.box.x, ce.box.y);
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
    // Container height from the last row. `cursorY` shares `innerY`'s origin and
    // `box.height` is the CONTENT box (paint adds padding and border back), so
    // the content height is the last row's bottom minus that origin. Adding
    // paddingBottom/borderBottom made a padded grid container one content origin
    // plus padding plus border too tall (100px where Edge uses 70).
    int totalH = cursorY;
    if (rowHeights.length > 0)
        totalH = cursorY + rowHeights[$ - 1];
    const hPx2 = element.style.resolveLength(element.style.height, style.containingHeight);
    element.box.height = hPx2 >= 0 ? hPx2 : max(0, totalH - innerY);

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
            ce.box.width = itemWidth(ce, tracks[pc]);
            auto itemFlow = itemContentFlow(ce, px, py);
            itemFlow.height = pr < cast(int) rowHeights.length ? rowHeights[pr] : 0;
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

    // A grid/table container is a block-level box: mark the previous box so the
    // next sibling's top margin collapses with this box's bottom margin (CSS
    // 8.3.1) instead of being added in full.
    flow.prevBottomMargin = element.box.marginBottom;
    flow.hasPrevBlock = true;
    flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
}

/// A cell, whether it came from `<td>`/`<th>` or from `display: table-cell`.
/// Real markup often builds the table model from generic elements (and CSS 17.2
/// allows any element to be a row or a cell), which matched nothing before.
private bool isTableCell(Element e)
{
    return e.tag == "td" || e.tag == "th" || e.style.display == "table-cell";
}

/// Basic table layout: table -> rows -> cells.
private void layoutTable(Element element, ref FlowContext flow, Element positionedAncestor)
{
    // An out-of-flow table's box is already placed - and its padding resolved -
    // by layoutAbsolute. Setting it from this flow a second time added the
    // padding twice, so `position:absolute; left:20px; padding:0 25px` landed at
    // x=45 and, with the flow's cursor, threw the cells further off still.
    const bool positioned = element.style.position == "absolute" ||
        element.style.position == "fixed";
    if (!positioned)
    {
        resolveBoxMetrics(element, flow.width);
        element.box.x = flow.x + element.box.marginLeft;
        element.box.y = collapsedTopY(flow, element);
        element.box.width = resolveWidth(element, flow.width);
    }
    // As in `layoutFlex`: `width` is the content box, so cells span `width` itself.
    const width = element.box.width;

    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width);

    // Collect rows and cell counts to compute equal column widths.
    int maxCols = 0;
    int rowCount = 0;
    Element[] rows;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        // Recognise rows by computed display as well as by tag: a `display:table`
        // built from divs produced an all-zero table because only `<tr>` matched.
        if (ce.tag == "tr" || ce.style.display == "table-row")
        {
            rows ~= ce;
            rowCount++;
        }
    }
    if (rows.length == 0)
    {
        // CSS 17.2: bare cell children of a table container are wrapped in an
        // anonymous table row. It generates no box, but it does the row's work -
        // without it `display:table` + `display:table-cell` laid out as an
        // all-zero table, since only `<tr>` and `display:table-row` matched.
        auto anon = new Element("div");
        anon.style.display = "table-row";
        foreach (child; element.children)
        {
            auto ce = cast(Element) child;
            if (ce !is null && isTableCell(ce)) anon.elements ~= ce;
        }
        if (anon.elements.length)
        {
            rows ~= anon;
            rowCount++;
        }
    }
    foreach (row; rows)
    {
        int cols = 0;
        foreach (c; row.elements)
            if (isTableCell(c)) cols++;
        maxCols = max(maxCols, cols);
    }
    if (maxCols == 0) maxCols = 1;
    const colW = innerW / maxCols;

    // CSS 17.5.2: a column takes the width its FIRST-ROW cell declares, and the
    // space left over is shared by the columns whose cells are `auto`. Giving
    // every column `innerW / maxCols` ignored the declarations entirely, so a
    // table whose first cell is `width:25%` and whose second is `auto` painted
    // 50/50 - the sizing corpus' case 6 put the column boundary at x=1060 where
    // Edge puts it at x=985 (75 + 225 of a 300px table).
    auto colWidths = new int[maxCols];
    auto colFixed = new bool[maxCols];
    bool anyDeclared = false;
    // Only `table-layout: fixed` takes the column widths from the first row's
    // declarations (CSS 17.5.2.1). The default `auto` algorithm sizes columns
    // from their CONTENT and spreads the table's own width across them, so a
    // `display:table` whose only cell says `width:100px` still fills a 300px
    // table - honouring that declaration painted a 100px cell inside a 300px
    // table and broke the flex/table/grid corpus' case 3.
    const bool fixedLayout = element.style.tableLayout == "fixed";
    if (fixedLayout)
    foreach (row; rows)
    {
        int ci = 0;
        foreach (c; row.elements)
        {
            if (!isTableCell(c)) continue;
            if (ci >= maxCols) break;
            // The first row only: CSS 17.5.2.1 lets a later row's declaration
            // narrow its column but not override the first row's.
            const int declaredW = c.style.resolveLength(c.style.width, innerW);
            if (declaredW >= 0 && !colFixed[ci])
            {
                colWidths[ci] = clampMinMaxWidth(c, max(0, declaredW));
                colFixed[ci] = true;
                anyDeclared = true;
            }
            ci++;
        }
        break;
    }
    if (anyDeclared)
    {
        int declared = 0;
        int autoCols = 0;
        foreach (i; 0 .. maxCols)
        {
            if (colFixed[i]) declared += colWidths[i];
            else autoCols++;
        }
        if (autoCols > 0)
        {
            const int rest = max(0, innerW - declared);
            const int share = rest / autoCols;
            int extra = rest % autoCols;
            foreach (i; 0 .. maxCols)
            {
                if (colFixed[i]) continue;
                colWidths[i] = share + (extra > 0 ? 1 : 0);
                if (extra > 0) extra--;
            }
        }
    }
    else
        foreach (i; 0 .. maxCols) colWidths[i] = colW;

    int y = innerY;
    foreach (row; rows)
    {
        row.box.x = innerX;
        row.box.y = y;
        row.box.width = innerW;
        int x = innerX;
        int rowH = 0;
        int ci = 0;
        foreach (c; row.elements)
        {
            if (!isTableCell(c)) continue;
            const int cw = ci < maxCols ? colWidths[ci] : colW;
            c.box.x = x;
            c.box.y = y;
            c.box.width = cw;
            resolveBoxMetrics(c, cw);
            const hPx = c.style.resolveLength(c.style.height, 0);
            c.box.height = hPx >= 0 ? hPx : 18;
            rowH = max(rowH, c.box.height);
            // Paint children inside cell.
            auto sub = FlowContext();
            sub.x = c.box.x + c.box.paddingLeft;
            sub.y = c.box.y + c.box.paddingTop;
            sub.width = max(0, cw - c.box.paddingLeft - c.box.paddingRight);
            sub.lineEnd = sub.x + sub.width;
            layoutChildren(c, sub, c);
            x += cw;
            ci++;
        }
        row.box.height = rowH;
        // Every cell stretches to the row's height (CSS 17.5.3): a single taller
        // cell must not leave its neighbours short of the row they share.
        foreach (c; row.elements)
            if (isTableCell(c)) c.box.height = rowH;
        y += rowH;
    }
    // `y` advanced from `innerY`, so `y - innerY` already is the content height
    // that `box.height` stores; adding paddingBottom/borderBottom made a padded
    // table one padding plus border too tall (85px where Edge uses 70).
    element.box.height = max(0, y - innerY);
    // A grid/table container is a block-level box: mark the previous box so the
    // next sibling's top margin collapses with this box's bottom margin (CSS
    // 8.3.1) instead of being added in full.
    flow.prevBottomMargin = element.box.marginBottom;
    flow.hasPrevBlock = true;
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
        // The BORDER box stays 100; the stored CONTENT box is 100 minus the
        // 20px of horizontal padding.
        assert(el.box.width == 80, "border-box 100 with 10px padding stores 80 content, got " ~
            el.box.width.to!string);
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

    // Fixed table layout: the FIRST row's declarations decide the columns, so a
    // 25% first cell beside an `auto` second splits a 300px table 75/225
    // (CSS 17.5.2.1). The default `auto` algorithm instead spreads the table's
    // own width across its columns, which is why the declarations must be
    // honoured only under `table-layout: fixed` - Edge painted 75/225 for the
    // first and a full-width cell for the second.
    {
        static Element buildTable(string layout, string firstWidth)
        {
            auto table = new Element("table");
            table.style.display = "table";
            table.style.tableLayout = layout;
            table.style.width = "300px";
            auto tr = new Element("tr");
            tr.style.display = "table-row";
            tr.parent = table;
            table.children ~= tr; table.elements ~= tr;
            foreach (w; [firstWidth, ""])
            {
                auto td = new Element("td");
                td.style.display = "table-cell";
                td.style.height = "20px";
                td.style.width = w;
                td.parent = tr;
                tr.children ~= td; tr.elements ~= td;
            }
            return table;
        }
        auto fixedT = buildTable("fixed", "25%");
        auto fixedFlow = FlowContext();
        fixedFlow.x = 0; fixedFlow.y = 0; fixedFlow.width = 300; fixedFlow.height = 100;
        layoutTable(fixedT, fixedFlow, null);
        auto fRow = cast(Element) fixedT.elements[0];
        auto f0 = cast(Element) fRow.elements[0];
        auto f1 = cast(Element) fRow.elements[1];
        assert(f0.box.width == 75, "fixed 25% column = 75, got " ~ f0.box.width.to!string);
        assert(f1.box.x == 75 && f1.box.width == 225,
            "fixed auto column takes the rest (x=75 w=225), got x=" ~ f1.box.x.to!string ~
            " w=" ~ f1.box.width.to!string);

        auto autoT = buildTable("auto", "25%");
        auto autoFlow = FlowContext();
        autoFlow.x = 0; autoFlow.y = 0; autoFlow.width = 300; autoFlow.height = 100;
        layoutTable(autoT, autoFlow, null);
        auto aRow = cast(Element) autoT.elements[0];
        auto a0 = cast(Element) aRow.elements[0];
        auto a1 = cast(Element) aRow.elements[1];
        assert(a0.box.width == 150 && a1.box.x == 150,
            "auto layout keeps equal columns (150/150), got " ~ a0.box.width.to!string);
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
    // --- a root's own padding insets its content, it does not move its box ---
    {
        auto rulesPad = parseStylesheet(`
            html { margin: 0; padding: 0; }
            body { margin: 0; padding: 25px 10px 5px 10px; }
            p { margin: 0; }
        `, 300, 300);
        auto docB = new Element("body");
        auto para = new Element("p");
        docB.children ~= para;
        docB.elements ~= para;
        para.parent = docB;
        auto tB = new TextNode(para, "hello");
        tB.parent = para;
        para.children ~= tB;
        applyStylesAndLayout(docB, rulesPad, 300, 300);
        assert(docB.box.x == 0 && docB.box.y == 0,
            "a body's own padding must not move its box, got (" ~
            to!string(docB.box.x) ~ "," ~ to!string(docB.box.y) ~ ")");
        assert(para.box.x == 10 && para.box.y == 25,
            "a body's padding must inset its content, got p at (" ~
            to!string(para.box.x) ~ "," ~ to!string(para.box.y) ~ ")");

        // Same again but with an explicit <html> parent: the body's padding must
        // not move the html box (a real page's html box was offset by exactly
        // its body's 25vh/2em padding).
        auto htmlEl = new Element("html");
        htmlEl.children ~= docB;
        htmlEl.elements ~= docB;
        docB.parent = htmlEl;
        applyStylesAndLayout(htmlEl, rulesPad, 300, 300);
        assert(htmlEl.box.x == 0 && htmlEl.box.y == 0,
            "with an html parent, html must stay at the origin, got (" ~
            to!string(htmlEl.box.x) ~ "," ~ to!string(htmlEl.box.y) ~ ")");
    }

    // --- a max-width block with margin:auto centres (CSS 10.4 step 3) ---
    {
        import std.conv : to;
        auto rulesC = parseStylesheet(`
            html { margin: 0; padding: 0; }
            body { margin: auto; max-width: 400px; padding: 0; }
        `, 1000, 800);
        auto htmlC = new Element("html");
        auto bodyC = new Element("body");
        bodyC.parent = htmlC;
        htmlC.children ~= bodyC;
        htmlC.elements ~= bodyC;
        applyStylesAndLayout(htmlC, rulesC, 1000, 800);
        assert(bodyC.box.width == 400,
            "max-width must clamp the body to 400, got " ~ to!string(bodyC.box.width));
        // Nothing tested `max-width` with `margin: auto`, which is why the
        // centring could be silently wiped: resolveBoxMetrics re-ran after
        // layout and resolved the `auto` margin back to 0.
        assert(bodyC.box.x == 300,
            "max-width + margin:auto must centre: (1000-400)/2 = 300; got x=" ~
            to!string(bodyC.box.x) ~
            " autoL=" ~ to!string(bodyC.box.marginLeftAuto) ~
            " autoR=" ~ to!string(bodyC.box.marginRightAuto) ~
            " mLeft=" ~ to!string(bodyC.box.marginLeft) ~
            " cw=" ~ to!string(bodyC.style.containingWidth) ~
            " maxW='" ~ bodyC.style.maxWidth ~ "'" ~
            " w='" ~ bodyC.style.width ~ "'");
    }

    // --- max-width + margin:auto + padding still centres ---
    // The isolated test above passes because a block with no padding has auto
    // width equal to the containing width, so the clamp alone yields the right
    // answer. With padding the auto width is (containing - padding), which is
    // what a real page's body has.
    {
        import std.conv : to;
        auto rulesP = parseStylesheet(`
            html { margin: 0; padding: 0; }
            body { margin: auto; max-width: 25em; padding: 10px 20px; }
        `, 1000, 800);
        auto htmlP = new Element("html");
        auto bodyP = new Element("body");
        bodyP.parent = htmlP;
        htmlP.children ~= bodyP;
        htmlP.elements ~= bodyP;
        applyStylesAndLayout(htmlP, rulesP, 1000, 800);
        // `25em` is 400px at the default 16px font size, so this also covers the
        // em path that px happened to mask.
        // CSS 10.3.3: mL + pl + width + pr + mR = containing width,
        // so mL + 20 + 400 + 20 + mR = 1000 -> 280 each. box.x is the
        // border-box origin, i.e. marginLeft.
        assert(bodyP.box.x == 280,
            "padding must be part of the centring maths: (1000-400-40)/2 = 280; got x=" ~
            to!string(bodyP.box.x) ~ " mLeft=" ~ to!string(bodyP.box.marginLeft) ~
            " mRight=" ~ to!string(bodyP.box.marginRight) ~
            " w=" ~ to!string(bodyP.box.width) ~
            " padL=" ~ to!string(bodyP.box.paddingLeft) ~
            " cw=" ~ to!string(bodyP.style.containingWidth));
    }

    // --- example.com's own body declarations must centre ---
    // Its real CSS, copied verbatim, so a failure can be bisected: font
    // shorthand, 26em max-width, auto margins, 25vh/2em padding.
    {
        import std.conv : to;
        auto rulesE = parseStylesheet(`
            html { color-scheme: light dark; }
            body { font: 16px/1.6 system-ui,sans-serif; max-width: 26em;
                   margin: auto; padding: 25vh 2em 2em; text-align: center; }
        `, 1000, 900);
        auto htmlE = new Element("html");
        auto bodyE = new Element("body");
        bodyE.parent = htmlE;
        htmlE.children ~= bodyE;
        htmlE.elements ~= bodyE;
        applyStylesAndLayout(htmlE, rulesE, 1000, 900);
        assert(bodyE.box.width == 416,
            "26em must clamp to 416px, got " ~ to!string(bodyE.box.width));
        assert(bodyE.box.x == 260,
            "example.com's body must centre at (1000-416-64)/2 = 260; got x=" ~
            to!string(bodyE.box.x) ~ " mLeft=" ~ to!string(bodyE.box.marginLeft) ~
            " padL=" ~ to!string(bodyE.box.paddingLeft) ~
            " cw=" ~ to!string(bodyE.style.containingWidth) ~
            " fs=" ~ to!string(bodyE.style.fontSizePx) ~
            " fam=" ~ bodyE.style.fontFamily);
    }

    // --- letter-spacing widens the shaped run ---
    {
        auto rulesL = parseStylesheet(`
            body { margin: 0; }
            .trackL { letter-spacing: 5px; }
        `, 400, 200);
        auto docL = new Element("body");
        auto trackEl = new Element("div");
        trackEl.attrs["class"] = "trackL";
        auto plainEl = new Element("div");
        docL.children ~= trackEl;
        docL.elements ~= trackEl;
        trackEl.parent = docL;
        docL.children ~= plainEl;
        docL.elements ~= plainEl;
        plainEl.parent = docL;
        auto tracked = new TextNode(trackEl, "tracking");
        tracked.parent = trackEl;
        trackEl.children ~= tracked;
        auto plain = new TextNode(plainEl, "tracking");
        plain.parent = plainEl;
        plainEl.children ~= plain;
        applyStylesAndLayout(docL, rulesL, 400, 200);

        assert(trackEl.style.letterSpacingPx() == 5.0,
            "letter-spacing:5px must resolve to 5, got " ~
            to!string(trackEl.style.letterSpacingPx()));
        assert(tracked.layoutWidth > plain.layoutWidth,
            "tracked text must shape wider than untracked; got " ~
            to!string(tracked.layoutWidth) ~ " vs " ~ to!string(plain.layoutWidth));
    }

    // --- text-transform applies before shaping ---
    {
        auto rulesT = parseStylesheet(`
            body { margin: 0; }
            .upT { text-transform: uppercase; }
            .capT { text-transform: capitalize; }
        `, 400, 200);
        auto docT = new Element("body");
        auto upEl = new Element("div");
        upEl.attrs["class"] = "upT";
        auto capEl = new Element("div");
        capEl.attrs["class"] = "capT";
        foreach (x; [upEl, capEl])
        {
            docT.children ~= x;
            docT.elements ~= x;
            x.parent = docT;
        }
        auto upText = new TextNode(upEl, "quiet harbour");
        upText.parent = upEl;
        upEl.children ~= upText;
        auto capText = new TextNode(capEl, "quiet harbour");
        capText.parent = capEl;
        capEl.children ~= capText;
        applyStylesAndLayout(docT, rulesT, 400, 200);

        assert(upText.paintText == "QUIET HARBOUR",
            "text-transform:uppercase must be applied to the shaped and painted " ~
            "text, got '" ~ upText.paintText ~ "'");
        assert(capText.paintText == "Quiet Harbour",
            "text-transform:capitalize must upper-case each word's first letter, got '" ~
            capText.paintText ~ "'");
    }

    // --- align-self overrides align-items for one item ---
    {
        auto rulesS = parseStylesheet(`
            body { margin: 0; }
            .rowS { display: flex; align-items: flex-start; }
            .tallS { width: 20px; height: 40px; }
            .selfEnd { width: 20px; height: 10px; align-self: flex-end; }
            .plainS { width: 20px; height: 10px; }
        `, 200, 200);
        auto docS = new Element("body");
        auto rowS = new Element("div");
        rowS.attrs["class"] = "rowS";
        docS.children ~= rowS;
        docS.elements ~= rowS;
        rowS.parent = docS;
        auto tallS = new Element("div");
        tallS.attrs["class"] = "tallS";
        auto selfEnd = new Element("div");
        selfEnd.attrs["class"] = "selfEnd";
        auto plainS = new Element("div");
        plainS.attrs["class"] = "plainS";
        foreach (x; [tallS, selfEnd, plainS])
        {
            rowS.children ~= x;
            rowS.elements ~= x;
            x.parent = rowS;
        }
        applyStylesAndLayout(docS, rulesS, 200, 200);
        assert(plainS.box.y == tallS.box.y,
            "without align-self an item follows align-items:flex-start, got y=" ~
            to!string(plainS.box.y) ~ " want " ~ to!string(tallS.box.y));
        assert(selfEnd.box.y == tallS.box.y + tallS.box.height - selfEnd.box.height,
            "align-self:flex-end must override the container, got y=" ~
            to!string(selfEnd.box.y) ~ " want " ~
            to!string(tallS.box.y + tallS.box.height - selfEnd.box.height));
    }

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

    // --- align-items centres inside the CONTAINER's cross size ---
    // The container is taller than its items, so the cross size is the declared
    // height (CSS Flexbox 9.4), not the tallest item: centring against the item
    // put the button at the very top of the toolbar row.
    {
        auto rulesC = parseStylesheet(`
            body { margin: 0; }
            .rowC { display: flex; align-items: center; height: 60px; }
            .itemC { width: 20px; height: 20px; }
        `, 200, 200);
        auto docC = new Element("body");
        auto rowC = new Element("div");
        rowC.attrs["class"] = "rowC";
        docC.children ~= rowC;
        docC.elements ~= rowC;
        rowC.parent = docC;
        auto itemC = new Element("div");
        itemC.attrs["class"] = "itemC";
        rowC.children ~= itemC;
        rowC.elements ~= itemC;
        itemC.parent = rowC;
        applyStylesAndLayout(docC, rulesC, 200, 200);
        assert(rowC.box.height == 60, "the row keeps its declared height, got " ~
            rowC.box.height.to!string);
        assert(itemC.box.y == rowC.box.y + (60 - 20) / 2,
            "align-items:center must centre a 20px item in a 60px row at y=20, got " ~
            itemC.box.y.to!string);
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

    // --- a generated box inherits from the element it decorates ---
    // An icon face lives on the element (`i.icon{font-family:FontAwesome}`) and
    // the glyph comes from the pseudo's `content`, so the generated box must take
    // the element's inherited properties (CSS 2.1 12.1). Keeping the "inherit"
    // sentinel made it resolve the STANDARD font for that glyph: a real page's
    // FontAwesome icons (django's search magnifier and theme toggle) had no such
    // outline there and painted as tofu boxes.
    {
        auto rulesI = parseStylesheet(`
            body { margin: 0; font-family: Georgia, serif; color: #101010; }
            .icon { font-family: FontAwesome; color: #44B78B; font-size: 20px; }
            .icon::before { content: "X"; }
            .over::before { content: "y"; font-size: 10px; }
            .glyph::before { content: "\f002"; }
            .spaced::before { content: "\f002 x"; }
        `, 200, 200);
        auto docI = new Element("body");
        auto icon = new Element("i");
        icon.attrs["class"] = "icon";
        auto over = new Element("i");
        over.attrs["class"] = "over";
        auto glyph = new Element("i");
        glyph.attrs["class"] = "glyph";
        auto spaced = new Element("i");
        spaced.attrs["class"] = "spaced";
        docI.children ~= icon;
        docI.children ~= over;
        docI.children ~= glyph;
        docI.children ~= spaced;
        docI.elements ~= icon;
        docI.elements ~= over;
        docI.elements ~= glyph;
        docI.elements ~= spaced;
        icon.parent = docI;
        over.parent = docI;
        glyph.parent = docI;
        spaced.parent = docI;
        applyStylesAndLayout(docI, rulesI, 200, 200);

        assert(icon.pseudoBefore !is null,
            "an icon's ::before box must still be generated");
        assert(icon.pseudoBefore.style.fontFamily == "FontAwesome",
            "a generated box must inherit the element's font family, got '" ~
            icon.pseudoBefore.style.fontFamily ~ "'");
        assert(icon.pseudoBefore.style.color == "#44B78B",
            "a generated box must inherit color, got '" ~
            icon.pseudoBefore.style.color ~ "'");
        assert(icon.pseudoBefore.style.fontSize == "20px" &&
            icon.pseudoBefore.style.fontSizePx == 20,
            "a generated box must inherit settled font pixels, got '" ~
            icon.pseudoBefore.style.fontSize ~ "' / " ~
            to!string(icon.pseudoBefore.style.fontSizePx));
        // The glyph itself must reach the inline flow: an inline `i.icon` is placed
        // by the enclosing block's inline pass, so the generated box's text run is
        // what has to be measured and painted.
        auto iconText = icon.pseudoBefore.children.length
            ? cast(TextNode) icon.pseudoBefore.children[0] : null;
        assert(iconText !is null && iconText.paintText == "X" && iconText.layoutWidth > 0,
            "the generated glyph must be measured inside an inline element, got '" ~
            (iconText is null ? "<no text>" : iconText.paintText) ~ "' width " ~
            (iconText is null ? "n/a" : to!string(iconText.layoutWidth)));
        // A declaration the pseudo DOES carry wins over the inherited value.
        assert(over.pseudoBefore !is null && over.pseudoBefore.style.fontSize == "10px" &&
            over.pseudoBefore.style.fontSizePx == 10,
            "the pseudo's own font-size must win over the inherited one, got '" ~
            over.pseudoBefore.style.fontSize ~ "' / " ~
            to!string(over.pseudoBefore.style.fontSizePx));
        // `content` escapes decode to the glyph itself (CSS Syntax 3, 4.3.7).
        // Every icon face on the real sites is addressed this way, and the six
        // literal characters `\f002` were laid out where the magnifier belongs.
        auto glyphText = glyph.pseudoBefore !is null && glyph.pseudoBefore.children.length
            ? cast(TextNode) glyph.pseudoBefore.children[0] : null;
        assert(glyphText !is null && glyphText.data == "\uF002",
            "the \\f002 escape must decode to one glyph, got " ~
            (glyphText is null ? "<no text>" : glyphText.data));
        // One whitespace character after the hex digits belongs to the escape,
        // so `"\f002 x"` is the glyph followed by a plain `x`.
        auto spacedText = spaced.pseudoBefore !is null && spaced.pseudoBefore.children.length
            ? cast(TextNode) spaced.pseudoBefore.children[0] : null;
        assert(spacedText !is null && spacedText.data == "\uF002x",
            "the space terminating a hex escape must not become content, got " ~
            (spacedText is null ? "<no text>" : spacedText.data));
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
        // font-size must resolve clamp()/vw/vh exactly as resolveLength does.
        // A `$ - 3` off-by-one in resolveFontSize's vw/vh suffix test ("11vw"
        // ends in "1vw", never "vw") made every such font size resolve to -1, so
        // clamp() rejected that component and fell back to its first valid one:
        // a real page's hero type sat at its floor, 56px = 3.5rem, instead of
        // clamp(3.5rem, 11vw, 7rem) = 112px at a 1080px viewport.
        auto fs = ComputedStyle();
        fs.viewportWidth = 1080;
        fs.viewportHeight = 680;
        fs.rootFontSizePx = 16;
        fs.fontSizePx = 16;
        fs.fontSize = "clamp(3.5rem, 11vw, 7rem)";
        const fsPx = resolveFontSize(fs, 16);
        assert(fsPx == 112,
            "clamp(3.5rem, 11vw, 7rem) at 1080 wide must be 112, got " ~
            to!string(fsPx));
        fs.fontSize = "11vw";
        assert(resolveFontSize(fs, 16) == 118,
            "a bare 11vw font-size at 1080 must be 118, got " ~
            to!string(resolveFontSize(fs, 16)));
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

    // A row item's CROSS-axis (vertical) margins belong to the flex line and to
    // the item's own placement: the line's cross size is the item's OUTER cross
    // size (CSS Flexbox 9.4) and alignment places the item's MARGIN box (9.6).
    // Counting only the border box under-measured a real page's header by 20px -
    // `header .logo{margin:10px 4px}` contributed nothing, so the container
    // measured 36px where Edge makes it 56, and the logo's border box landed at
    // the line's start (y=10 from the container) where Edge puts it at y=20.
    {
        auto crow = new Element("div");
        crow.style.display = "flex";
        crow.style.alignItems = "center";
        auto clogo = new Element("div");
        clogo.style.width = "104px";
        clogo.style.height = "36px";
        clogo.style.margin = "10px 4px";
        crow.children ~= clogo;
        crow.elements ~= clogo;
        clogo.parent = crow;

        int[] crossAt;
        string[] alignAt = ["center", "flex-start", "flex-end"];
        foreach (which; alignAt)
        {
            crow.style.alignItems = which;
            auto cf = FlowContext();
            cf.x = 0;
            cf.y = 0;
            cf.width = 300;
            cf.height = 200;
            cf.lineEnd = 300;
            layoutFlex(crow, cf, null);
            crossAt ~= clogo.box.y;
            if (which == "center")
                assert(crow.box.height == 56,
                    "a row's height must include its items' vertical margins " ~
                    "(56), got " ~ to!string(crow.box.height));
        }
        // A 56px line holds a 36px item with 10px margins flush top and bottom,
        // so all three alignments agree on y=10 - and the pre-fix code said 0.
        foreach (i, which; alignAt)
            assert(crossAt[i] == 10,
                "align-items:" ~ which ~ " must place the item's margin box at " ~
                "y=10 in a 56px line, got " ~ to!string(crossAt[i]));
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
        // Text sits on the first line at y=0. The 40px box is taller than the
        // 16px strut, so the line box grows to contain the box's MARGIN box and
        // the baseline moves down to the box's bottom (CSS 10.8.1): the box
        // sits at the line's top and nothing is painted above the line. The
        // earlier expectation here (y = 16 - 40) pinned a box 24px ABOVE its own
        // line, which is what made django's homepage CTA sit above its
        // paragraph and 15px higher than Edge painted it.
        assert(ib.box.y == 0,
            "a tall inline-block sits at the line's top (y=0), got " ~
            ib.box.y.to!string);
        assert(flow.contentBottom >= 40,
            "the line box must grow to contain the tall inline-block (>= 40), got " ~
            flow.contentBottom.to!string);
    }

    // --- a tall inline-block grows its line box (CSS 10.8.1) ---
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.fontSize = "16px";
        container.style.fontSizePx = 16;
        container.style.lineHeight = "20px";
        auto ib = new Element("span");
        ib.style.display = "inline-block";
        ib.style.width = "40px";
        ib.style.height = "40px";
        ib.style.verticalAlign = "top";
        ib.parent = container;
        container.children ~= ib;
        container.elements ~= ib;
        auto flow = FlowContext();
        flow.x = 0; flow.y = 0; flow.width = 300; flow.height = 300;
        flow.lineEnd = 300;
        layoutDirectText(container, flow);
        assert(flow.lineCount >= 1, "the inline-block must occupy a line");
        assert(flow.contentBottom == 40,
            "a 40px inline-block must grow the line box past the 20px strut, got " ~
            flow.contentBottom.to!string);
    }
}

unittest
{
    // --- An inline-block's own margins belong to the line (CSS 10.8.1) ---
    // Reduced from the fixture inlineblock-margin.html, where the paragraph
    // measured 81px: 15 (the paragraph's collapsed top margin) + 46 (the
    // button's content) + 20 (its padding) - that is, the border box only,
    // with the button's own bottom margin contributing nothing even though the
    // used top margin (15, off `margin: 15px 0`) reached the box.
    auto parent = new Element("div");
    parent.style.display = "block";
    parent.style.width = "600px";
    auto para = new Element("p");
    para.style.display = "block";
    para.parent = parent;
    auto btn = new Element("a");
    btn.style.display = "inline-block";
    btn.style.width = "120px";
    btn.style.padding = "10px 20px";
    btn.style.margin = "15px 0";
    btn.style.fontSize = "18px";
    btn.style.lineHeight = "1.3";
    btn.parent = para;
    auto label = new TextNode(btn, "two");
    btn.children ~= label;
    para.children ~= btn;
    para.elements ~= btn;
    parent.children ~= para;
    parent.elements ~= para;

    auto flow = FlowContext();
    flow.x = 0; flow.y = 0; flow.width = 600; flow.height = 600;
    flow.lineEnd = 600;
    layoutBlock(parent, flow, 600, null);

    assert(btn.box.marginTop == 15,
        "a two-value margin shorthand must set the top, got " ~
        btn.box.marginTop.to!string);
    const lineBottom = btn.box.y + btn.box.height + btn.box.paddingTop +
        btn.box.borderTop + btn.box.paddingBottom + btn.box.borderBottom +
        btn.box.marginBottom;
    const paraContentTop = para.box.y + para.box.borderTop + para.box.paddingTop;
    assert(para.box.height == lineBottom - paraContentTop,
        "the line must contain the inline-block's margin box: paragraph " ~
        para.box.height.to!string ~ "px vs line bottom " ~
        lineBottom.to!string ~ "px from content top " ~
        paraContentTop.to!string ~ "px (box y=" ~ btn.box.y.to!string ~
        " h=" ~ btn.box.height.to!string ~ " pad=" ~
        btn.box.paddingTop.to!string ~ "," ~ btn.box.paddingBottom.to!string ~
        " margin=" ~ btn.box.marginTop.to!string ~ "," ~
        btn.box.marginBottom.to!string ~ " para y=" ~ para.box.y.to!string ~
        " parent y=" ~ parent.box.y.to!string ~ " flow=" ~
        flow.y.to!string ~ "," ~ flow.contentBottom.to!string ~
        "," ~ flow.inlineBottomAbs.to!string ~ ")");
}


unittest
{
    // --- Inline run separation (CSS Text 3 4.1.1) ---
    // A collapsible space between an inline element and the text after it is a
    // word separator. A run's leading whitespace used to be dropped
    // unconditionally, so "<a>DOCUMENTATION</a> end" painted "DOCUMENTATIONend".
    {
        auto container = new Element("div");
        container.style.display = "block";
        auto first = new TextNode(container, "1 inline: ");
        auto link = new Element("a");
        link.style.display = "inline";
        link.parent = container;
        auto linkText = new TextNode(link, "DOCUMENTATION");
        link.children ~= linkText;
        auto last = new TextNode(container, " end");
        container.children ~= first;
        container.children ~= link;
        container.children ~= last;
        container.elements ~= link;

        assert(collapsibleText(container, last) == " end",
            "a run after an inline element keeps its separator, got '" ~
            collapsibleText(container, last) ~ "'");
        assert(collapsibleText(container, first) == "1 inline: ",
            "a run's trailing space before inline content is kept, got '" ~
            collapsibleText(container, first) ~ "'");

        // The first node of a formatting context begins a line, so its leading
        // whitespace still collapses away: the rule that keeps markup indentation
        // out of a paragraph's advance.
        auto para = new Element("p");
        auto only = new TextNode(para, "\n   Hello");
        para.children ~= only;
        assert(collapsibleText(para, only) == "Hello",
            "leading whitespace of a line's first run is dropped, got '" ~
            collapsibleText(para, only) ~ "'");

        // A whitespace-only node between two inline elements is a separator too.
        auto between = new TextNode(container, "\n  ");
        auto link2 = new Element("a");
        link2.style.display = "inline";
        container.children ~= between;
        container.children ~= link2;
        container.elements ~= link2;
        assert(collapsibleText(container, between) == " ",
            "whitespace between inline elements collapses to one space, got '" ~
            collapsibleText(container, between) ~ "'");
    }

    // --- A block-level box in an inline context keeps document order ---
    // CSS 2.1 9.2.1.1: the text before it becomes an anonymous block box that
    // stays above it. The run was flushed only when it also contained an inline
    // ELEMENT, so the nested block was placed first and its line came out above
    // the label that precedes it.
    {
        auto container = new Element("div");
        container.style.display = "block";
        container.style.width = "200px";
        auto label = new TextNode(container, "2 block:");
        auto block = new Element("span");
        block.style.display = "block";
        block.parent = container;
        auto blockText = new TextNode(block, "DOCUMENTATION");
        block.children ~= blockText;
        container.children ~= label;
        container.children ~= block;
        container.elements ~= block;

        auto flow = FlowContext();
        flow.x = 0;
        flow.y = 0;
        flow.width = 200;
        flow.height = 200;
        flow.lineEnd = 200;
        layoutChildren(container, flow, null);
        assert(label.layoutY < block.box.y,
            "the text before a block stays above it: label y=" ~
            label.layoutY.to!string ~ " block y=" ~ block.box.y.to!string);
    }
}

unittest
{
    // --- `float` has no effect on a flex item (CSS Flexbox 4.1) ---
    // django's header menu is `ul{display:flex;align-items:center}` holding
    // `li{float:left}` items whose links carry `padding:10px`. Honouring that
    // float pulled the items out of the flex line: the row grew 20px taller
    // than Edge's and the labels painted 10px above Edge's on the same page.
    // The two layouts below differ only in the `float` declaration, so every
    // box must come out identical.
    Element navRow(string floatVal)
    {
        auto ul = new Element("ul");
        ul.style.display = "flex";
        ul.style.alignItems = "center";
        auto li = new Element("li");
        li.style.display = "block";
        li.style.floatStyle = floatVal;
        li.style.fontSizePx = 13;
        li.style.lineHeight = "16px";
        auto a = new Element("a");
        a.style.display = "block";
        a.style.padding = "10px";
        auto label = new TextNode(a, "Overview");
        a.children ~= label;
        a.parent = li;
        li.children ~= a;
        li.elements ~= a;
        li.parent = ul;
        ul.children ~= li;
        ul.elements ~= li;
        auto flow = FlowContext();
        flow.x = 0;
        flow.y = 0;
        flow.width = 400;
        flow.height = 80;
        flow.lineEnd = 400;
        layoutFlex(ul, flow, null);
        return ul;
    }
    auto floated = navRow("left");
    auto plain = navRow("none");
    auto fli = cast(Element) floated.elements[0];
    auto pli = cast(Element) plain.elements[0];
    assert(fli.box.x == pli.box.x && fli.box.y == pli.box.y &&
        fli.box.width == pli.box.width && fli.box.height == pli.box.height,
        "a float must not change a flex item's box: floated " ~
        fli.box.x.to!string ~ "," ~ fli.box.y.to!string ~ " " ~
        fli.box.width.to!string ~ "x" ~ fli.box.height.to!string ~ " vs plain " ~
        pli.box.x.to!string ~ "," ~ pli.box.y.to!string ~ " " ~
        pli.box.width.to!string ~ "x" ~ pli.box.height.to!string);
    assert(floated.box.height == plain.box.height,
        "a float must not change the flex row's height: " ~
        floated.box.height.to!string ~ " vs " ~ plain.box.height.to!string);
    // The item wraps its block child's BORDER box (content + the child's own
    // padding), and the child must stay on ONE line: before measured widths were
    // rounded up, the item's content box was a fraction of a pixel narrower than
    // the label, so every label wrapped and both boxes doubled.
    auto fla = cast(Element) fli.elements[0];
    assert(fli.box.height == fla.box.height + fla.box.paddingTop + fla.box.paddingBottom,
        "the flex item must be as tall as its child's border box: item " ~
        fli.box.height.to!string ~ " child " ~ fla.box.height.to!string ~
        " + " ~ fla.box.paddingTop.to!string ~ "/" ~
        fla.box.paddingBottom.to!string);
    assert(fla.box.height <= 20,
        "a single-line label must not wrap inside its own item, got " ~
        fla.box.height.to!string ~ "px of text");
}

unittest
{
    // --- cross-axis alignment carries the item's contents with it ---
    // An item's own cross size, and so its centred `y`, is only known once its
    // contents have been laid out, so alignment runs last and must move the
    // subtree. django's header centres a nav in a taller row: moving the nav's
    // box alone (y 10 -> 18) left its `ul` and links at the old y, and the menu
    // painted ~10px above where Edge puts it on the same page.
    auto row = new Element("div");
    row.style.display = "flex";
    row.style.alignItems = "center";
    auto tall = new Element("div");
    tall.style.width = "20px";
    tall.style.height = "60px";
    tall.parent = row;
    row.children ~= tall;
    row.elements ~= tall;
    auto nav = new Element("nav");
    nav.style.display = "block";
    nav.style.width = "100px";
    auto link = new Element("a");
    link.style.display = "block";
    auto label = new TextNode(link, "Overview");
    link.children ~= label;
    link.parent = nav;
    nav.children ~= link;
    nav.elements ~= link;
    nav.parent = row;
    row.children ~= nav;
    row.elements ~= nav;

    auto rowFlow = FlowContext();
    rowFlow.x = 0;
    rowFlow.y = 0;
    rowFlow.width = 400;
    rowFlow.height = 400;
    rowFlow.lineEnd = 400;
    layoutFlex(row, rowFlow, null);

    // The 60px sibling makes a 60px line, so the shorter nav is centred below
    // the row's top edge and its text has to travel with it.
    assert(nav.box.y > 0,
        "a centred flex item must move down its line, got y=" ~
        nav.box.y.to!string);
    assert(label.layoutY >= nav.box.y,
        "the aligned item's text must move with its box: text y=" ~
        label.layoutY.to!string ~ " item y=" ~ nav.box.y.to!string);
}



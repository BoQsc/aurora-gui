module auroraweb.dom;

/**
 * Minimal DOM tree shared by the HTML parser, layout, paint and the JS host.
 *
 * A node is either an element (with a tag, attribute map and child list) or a
 * text node. Elements carry a computed style slot that layout fills in, and an
 * opaque JS handle that the JavaScript host sets when the same element is
 * exposed to scripts. Everything here is reference-counted through `Element`
 * and `TextNode` classes so the JS host can keep a node alive beyond one parse.
 */

import core.exception : RangeError;
import std.algorithm : canFind;
import std.conv : to;
import std.string : endsWith, split, strip, toLower;

/// One line fragment of an inline box. Kept in this module (which has no
/// dependency on `aurora.types`) so `Element` can carry fragments cheaply.
struct InlineFragment
{
    int x;
    int y;
    int width;
    int height;
}

/** Attribute storage: a plain associative array of attribute name -> value. */
alias AttrMap = string[string];

/**
 * A DOM element. `parent` is non-null once the node is attached to a tree.
 * `children` holds both element and text children in document order.
 */
final class Element
{
    string tag;            /// Lower-cased tag name, e.g. "p", "div", "a".
    AttrMap attrs;
    Element parent;
    Element[] elements;    /// Element children only.
    TextNode[] textNodes;  /// Text children only, interleaved via `children`.
    Object[] children;     /// Interleaved document-order children.
    ComputedStyle style;   /// Filled by the layout/computed-style pass.
    Box box;               /// Filled by the layout pass.
    Object image;          /// Loaded image (aurora.image.RgbaImage) for <img>, if any.
    Object backgroundImage; /// Decoded image for `background-image`, if any.
    bool imageLoadTried;
    /// Set once an inline SVG's rasterisation has been retried, so a genuinely
    /// unreadable SVG cannot keep the document permanently dirty. Without the
    /// retry, a rasterisation that failed on an early pass (the element's
    /// inherited colour is not resolved yet on the first pass) was marked as
    /// tried and never attempted again, leaving a real page's decorative artwork
    /// with a permanent 0x0 box.
    bool imageRetried;
    /// One line fragment of a wrapping inline box (CSS 9.4.2): an inline element
    /// that spans several lines is split into one fragment per line, and its
    /// background/border must follow each of them rather than only the first.
    /// `x`/`width` cover the content the fragment holds; `height` is the line
    /// height. Empty for block boxes and single-line inlines.
    InlineFragment[] inlineFragments;
    /// Generated `::before`/`::after` boxes (CSS 12). They are deliberately NOT
    /// in `children`/`elements`, so DOM and script APIs never see them, while
    /// layout and paint place and draw them like any other element.
    Element pseudoBefore;
    Element pseudoAfter;      /// <img> fetch already attempted (avoid re-fetching).
    bool backgroundLoadTried; /// `background-image` fetch already attempted.
    bool imageFallbackTried;  /// Chosen srcset/<picture> candidate failed; `src` retried.
    bool hovered;             /// Pointer is over this element (drives `:hover`).
    bool focused;             /// This element has focus (drives `:focus`).
    bool active;              /// Mouse button held on this element (`:active`).
    size_t caret;             /// Caret offset inside a focused text control.

    this(string tag)
    {
        this.tag = tag;
    }

    bool hasClass(string className) const
    {
        auto classAttr = "class" in attrs;
        if (classAttr is null) return false;
        if (className.length == 0) return (*classAttr).split(" ").canFind(className);
        // Scan for the space-delimited token instead of splitting. The cascade
        // calls this once per candidate rule per element, and `split(" ")`
        // allocated an array on every one of those calls - that allocation
        // dominated style resolution on large pages.
        const hay = *classAttr;
        size_t i = 0;
        while (i < hay.length)
        {
            while (i < hay.length && hay[i] == ' ') ++i;
            const start = i;
            while (i < hay.length && hay[i] != ' ') ++i;
            if (i > start && hay[start .. i] == className) return true;
        }
        return false;
    }

    bool hasId(string id) const
    {
        auto idAttr = "id" in attrs;
        return idAttr !is null && *idAttr == id;
    }

    Element firstElementChild()
    {
        return elements.length ? elements[0] : null;
    }

    Element lastElementChild()
    {
        return elements.length ? elements[$ - 1] : null;
    }

    TextNode firstTextChild() const
    {
        foreach (child; children)
        {
            auto text = cast(TextNode) child;
            if (text !is null) return text;
        }
        return null;
    }

    TextNode lastTextChild() const
    {
        foreach_reverse (child; children)
        {
            auto text = cast(TextNode) child;
            if (text !is null) return text;
        }
        return null;
    }

    string textContent() const
    {
        string result;
        foreach (child; children)
        {
            auto text = cast(TextNode) child;
            if (text !is null) result ~= text.data;
            else
            {
                auto element = cast(Element) child;
                if (element !is null) result ~= element.textContent();
            }
        }
        return result;
    }
}

/** A run of text inside an element. The `parent` element owns this node. */
final class TextNode
{
    Element parent;
    string data;
    /// Layout results filled by the layout pass (used by paint).
    int layoutX;
    int layoutY;
    int layoutWidth;
    int lineIndex;
    /// The run as layout collapsed it for painting: under `white-space: normal`
    /// the markup's newlines and tabs collapse to single spaces, and leading and
    /// trailing whitespace is dropped. Paint shapes this string so it agrees with
    /// what layout measured. Empty means "use `data` unchanged".
    string paintText;

    this(Element parent, string data)
    {
        this.parent = parent;
        this.data = data;
    }
}

/** Result of one computed-style evaluation for a single element. */
struct ComputedStyle
{
    string display = "inline";
    string color = "black";
    /// Colour the hint text of an empty form control is painted with (empty =
    /// the engine's neutral placeholder grey). A control's own `color` is the
    /// colour of the text the user types, so the two cannot share one field:
    /// django's dark theme gives its search hint `var(--body-fg)` while the UA
    /// sheet colours the typed text separately.
    string placeholderColor = "";
    string background = "transparent";
    string backgroundImage = "none";
    string backgroundSize = "auto";
    string backgroundGradient = "none"; /// A CSS gradient token, rasterised to backgroundImage.
    string backgroundRepeat = "repeat"; /// CSS initial value: background images tile.
    string transform = "none"; /// CSS `transform` (translate() supported so far).
    string objectFit = "fill";   /// `object-fit` for <img>: fill/contain/cover/none/scale-down
    /// `object-position` (CSS Images 3): where a fitted image sits inside its box.
    /// The initial value centres it.
    string objectPosition = "50% 50%";
    /// `background-position` (CSS Backgrounds 3). Its initial value is the top
    /// left corner, unlike `object-position`'s centre.
    string backgroundPosition = "0% 0%";
    /// `mask-image` (the `linear-gradient(...)` form real pages use to fade a
    /// decorative layer out); "none" paints the layer unmasked.
    string maskImage = "none";
    /// `filter` (CSS Filter Effects 1). The colour-only functions are honoured
    /// (grayscale, sepia, brightness, contrast, saturate, invert, opacity);
    /// `blur`/`drop-shadow` are not implemented.
    string filter = "none";
    /// `content` for a generated pseudo-element box; empty means none was given.
    string content = "";

    string fontSize = "16px";
    string fontWeight = "400";
    string fontStyle = "normal";
    /// The initial CSS value is an empty family list: a page that names no
    /// family is set in the browser's standard font, not in its UI font, and
    /// `system-ui` is the name a page uses when it does want the interface font.
    string fontFamily = "";
    string textAlign = "left";
    /// `text-transform` (CSS Text 3): none / uppercase / lowercase / capitalize.
    /// Applied where text is collapsed, before shaping, so measured widths match
    /// what is painted (`uppercase` makes a run wider).
    string textTransform = "none";
    /// `letter-spacing` (CSS Text 3): `normal` (the initial value) or a length.
    /// Tracking must reach the shaper, not just the paint offset, or measured
    /// widths and painted glyphs disagree.
    string letterSpacing = "normal";
    /// `position: sticky` (CSS 2.2 / Position 3). Laid out in flow like
    /// `relative` (so it is also a containing block), but pinned within its
    /// containing block as the page scrolls — applied at paint time, since the
    /// engine scrolls by translating the canvas.
    bool isSticky = false;
    /// `vertical-align` for inline/inline-box sizing (`baseline` by default).
    string verticalAlign = "baseline";

    string width = "auto";
    string height = "auto";
    string margin = "0px";
    string padding = "0px";
    string border = "0px";
    string position = "static";
    string floatStyle = "none";
    string clear = "none";
    string visibility = "visible";
    string overflow = "visible";
    string minWidth = "auto";
    string maxWidth = "auto";
    string minHeight = "auto";
    string maxHeight = "auto";
    string top = "auto";
    string left = "auto";
    string right = "auto";
    string bottom = "auto";
    string flexGrow = "0";
    /// `flex-shrink` (CSS Flexbox 7.1.1). Empty means the initial value, 1.
    string flexShrink = "";
    /// `flex-basis` (CSS Flexbox 7.1.1). "auto" (the initial value) means use the
    /// item's `width`; a length/percentage is the item's initial main size.
    string flexBasis = "auto";
    string justifyContent = "flex-start";
    string alignItems = "stretch";
    /// `align-self` (CSS Flexbox 8.4): a per-item override of the container's
    /// `align-items`. "auto" means "inherit from the container".
    string alignSelf = "auto";
    string gap = "0px";
    string borderColor = "black";
    string borderStyle = "none";
    string lineHeight = "auto";
    string borderWidth = "0px";
    string borderTopWidth = "";
    string borderRightWidth = "";
    string borderBottomWidth = "";
    string borderLeftWidth = "";
    string marginTop = "";
    string marginRight = "";
    string marginBottom = "";
    string marginLeft = "";
    string paddingTop = "";
    string paddingRight = "";
    string paddingBottom = "";
    string paddingLeft = "";
    string boxSizing = "content-box";
    string tableLayout = "auto";
    string textIndent = "0px";
    string borderTopStyle = "";
    string borderRightStyle = "";
    string borderBottomStyle = "";
    string borderLeftStyle = "";
    string gridTemplateColumns = "";
    string borderTopColor = "";
    string borderRightColor = "";
    string borderBottomColor = "";
    string borderLeftColor = "";
    string outline = "";
    string outlineColor = "";
    string outlineWidth = "";
    string outlineStyle = "";
    string outlineOffset = "";
    string gridTemplateRows = "";
    string columnGap = "";
    string rowGap = "";
    string borderRadius = "0px";
    string boxShadowH = "0px";
    string boxShadowV = "0px";
    string boxShadowBlur = "0px";
    string boxShadowSpread = "0px";
    string boxShadowColor = "none";
    string textDecoration = "none";

    /// Element opacity 0..1 (1 = fully opaque). Applied to the alpha channel
    /// of every fill this element paints (background, border, text, shadow).
    double opacity = 1.0;

    /// Painting order for positioned elements; higher z-index paints on top.
    int zIndex = 0;
    /// `flex-wrap`: whether a flex container's items wrap onto several lines.
    string flexWrap = "nowrap";
    /// `align-content`: how a wrapping flex container distributes its lines on
    /// the cross axis (CSS Flexbox 8.5).
    string alignContent = "normal";

    /// Whether the element participates in stacking (`position` != static).
    bool isPositioned() const
    {
        return position == "relative" || position == "absolute" || position == "fixed";
    }

    /// `letter-spacing` resolved to px (0 for `normal`/unusable values). `em` and
    /// `rem` are relative to this element's font size, which is what real pages
    /// use for label tracking (`.eyebrow { letter-spacing: 0.22em }`).
    double letterSpacingPx() const
    {
        const s = letterSpacing.strip().toLower();
        if (s.length == 0 || s == "normal" || s == "auto") return 0.0;
        const double fontPx = fontSizePx > 0 ? fontSizePx : 16.0;
        double scale = 0.0;
        string numberPart;
        if (endsWith(s, "rem")) { numberPart = s[0 .. $ - 3]; scale = fontPx; }
        else if (endsWith(s, "em")) { numberPart = s[0 .. $ - 2]; scale = fontPx; }
        else if (endsWith(s, "px")) { numberPart = s[0 .. $ - 2]; scale = 1.0; }
        else return 0.0;
        try return to!double(numberPart.strip()) * scale;
        catch (Exception) return 0.0;
    }

    /// The resolved percentage base for widths (set during layout).
    int containingWidth = 0;
    int containingHeight = 0;
    int fontSizePx = 16;         /// Current element font size in px.
    int rootFontSizePx = 16;     /// Root font size in px.
    int viewportWidth = 1280;
    int viewportHeight = 800;
    string whiteSpace;           /// "normal", "pre", "pre-line", "pre-wrap".
    string backgroundClip;       /// "text" = paint the background as glyph fill.
    string flexDirection = "row"; /// "row" | "row-reverse" | "column" | "column-reverse".
    string aspectRatio;          /// "auto", "<w> / <h>" or a bare number (CSS
                                 /// aspect-ratio; derives an auto height).

    /// Parse a px value from a CSS length string; returns -1 if not a px length.
    int pxLength(string prop) const
    {
        const s = prop.strip();
        if (s.length >= 3 && s[$ - 2 .. $] == "px")
            return cssInt(s[0 .. $ - 2].strip());
        // A unitless zero IS a length in CSS. Returning -1 here made
        // `box-shadow: 10px 10px 0 0 #000` resolve its spread to -1, so the
        // shadow was drawn inset by one pixel on every side instead of flush
        // with the box (measured against Edge: 11,11,58,38 versus 10,10,60,40).
        if (s == "0") return 0;
        return -1;
    }

    /// Parse a percentage value; returns -1 if not a percentage.
    int percentValue(string prop) const
    {
        const s = prop.strip();
        if (s.length >= 2 && s[$ - 1] == '%')
            return cssInt(s[0 .. $ - 1].strip());
        return -1;
    }

    /// Resolve a length-or-percentage against a base. Returns -1 if auto.
    int resolveLength(string prop, int base) const
    {
        const s = prop.strip();
        if (s.length == 0) return -1;
        // calc( <expr> ): evaluate over lengths/percentages/numbers.
        if (s.length > 6 && s[0 .. 5] == "calc(" && s[$ - 1] == ')')
            return cast(int) calcEval(s[5 .. $ - 1], base).px;
        // clamp()/min()/max(): each argument is itself a length (often a calc).
        // CSS picks clamp(min, val, max) = the value clamped between the bounds,
        // min() the smallest argument and max() the largest. The resolver used
        // to take the FIRST resolvable argument, so every clamp() collapsed to
        // its floor - a real page's `clamp(4rem, 11vw, 11rem)` inset became 4rem
        // (64px instead of 148px at a 1350px viewport), which shifted its dock
        // bar to x=0 and made the whole top of the page look broken.
        foreach (fn; ["clamp(", "min(", "max("])
        {
            if (s.length > fn.length && s[0 .. fn.length] == fn && s[$ - 1] == ')')
            {
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
                        vals ~= resolveLength(inner[start .. i].strip(), base);
                        start = i + 1;
                    }
                }
                vals ~= resolveLength(inner[start .. $].strip(), base);
                long[] ok;
                foreach (v; vals)
                    if (v >= 0) ok ~= v;
                if (ok.length == 0) return -1;
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
        if (s.length >= 2 && s[$ - 2 .. $] == "px")
            return cssInt(s[0 .. $ - 2].strip());
        if (s.length >= 2 && s[$ - 1] == '%')
            return (base * cssInt(s[0 .. $ - 1].strip())) / 100;
        if (s.length >= 3 && s[$ - 3 .. $] == "rem")
            return cast(int)(cssDouble(s[0 .. $ - 3].strip()) * rootFontSizePx);
        if (s.length >= 2 && s[$ - 2 .. $] == "em")
            return cast(int)(cssDouble(s[0 .. $ - 2].strip()) * fontSizePx);
        if (s.length >= 2 && s[$ - 2 .. $] == "vh")
            return (viewportHeight * cssInt(s[0 .. $ - 2].strip())) / 100;
        if (s.length >= 2 && s[$ - 2 .. $] == "vw")
            return (viewportWidth * cssInt(s[0 .. $ - 2].strip())) / 100;

        // Physical and typographic units: without these the value was reported
        // as "not a length" (-1) and a margin resolver stored that as a real
        // -1px margin (the same trap unitless `0` fell into). 1pt = 96/72px,
        // 1pc = 12pt = 16px, and `ch`/`ex` are approximated at half an em.
        if (s.length >= 2 && s[$ - 2 .. $] == "pt")
            return cast(int)(cssDouble(s[0 .. $ - 2].strip()) * (96.0 / 72.0));
        if (s.length >= 2 && s[$ - 2 .. $] == "pc")
            return cast(int)(cssDouble(s[0 .. $ - 2].strip()) * 16.0);
        if (s.length >= 2 && s[$ - 2 .. $] == "ch")
            return cast(int)(cssDouble(s[0 .. $ - 2].strip()) * (fontSizePx * 0.5));
        if (s.length >= 2 && s[$ - 2 .. $] == "ex")
            return cast(int)(cssDouble(s[0 .. $ - 2].strip()) * (fontSizePx * 0.5));

        // A unitless zero is a valid length in CSS (`margin: 0`, `top: 0`,
        // `left: 0`). Without this the value was reported as "not a length"
        // (-1) and the margin resolver stored that as a real -1px margin, which
        // shifted every element declaring `margin: 0` one pixel up and left and
        // accumulated through nested blocks.
        if (s == "0" || s == "0.0" || s == "-0" || s == "+0")
            return 0;

        return -1;
    }

    /// A value produced while evaluating a `calc()` expression.
    private struct CalcVal { double px; bool isLength; }

    /// Evaluate a simple `calc()` expression (operands are lengths/percentages
    /// or plain numbers, combined with + - * / and parentheses).
    private CalcVal calcEval(string expr, int base) const
    {
        auto e = expr.strip();
        if (e.length == 0) return CalcVal(0, false);
        // Lowest precedence at top level: the LAST top-level '+'/'-'.
        int depth = 0;
        int opPos = -1;
        char opCh = 0;
        foreach (i, c; e)
        {
            if (c == '(') depth++;
            else if (c == ')') depth--;
            else if (depth == 0 && i > 0 && (c == '+' || c == '-')) { opPos = cast(int) i; opCh = c; }
        }
        if (opPos > 0)
        {
            auto l = calcEval(e[0 .. opPos], base);
            auto r = calcEval(e[opPos + 1 .. $], base);
            return CalcVal(opCh == '+' ? l.px + r.px : l.px - r.px, l.isLength || r.isLength);
        }
        depth = 0;
        opPos = -1;
        opCh = 0;
        foreach (i, c; e)
        {
            if (c == '(') depth++;
            else if (c == ')') depth--;
            else if (depth == 0 && i > 0 && (c == '*' || c == '/')) { opPos = cast(int) i; opCh = c; }
        }
        if (opPos > 0)
        {
            auto l = calcEval(e[0 .. opPos], base);
            auto r = calcEval(e[opPos + 1 .. $], base);
            auto v = (opCh == '*') ? l.px * r.px : (r.px != 0 ? l.px / r.px : 0.0);
            return CalcVal(v, l.isLength || r.isLength);
        }
        if (e.length >= 2 && e[0] == '(' && e[$ - 1] == ')')
            return calcEval(e[1 .. $ - 1], base);
        // Operand: number + optional unit.
        size_t k = 0;
        while (k < e.length && (e[k] == '.' || e[k] == '+' || e[k] == '-' ||
            (e[k] >= '0' && e[k] <= '9')))
            k++;
        auto num = k > 0 ? cssDouble(e[0 .. k]) : 0.0;
        auto unit = e[k .. $].strip();
        if (unit == "px") return CalcVal(num, true);
        if (unit == "%") return CalcVal(base * num / 100.0, true);
        if (unit == "rem") return CalcVal(num * rootFontSizePx, true);
        if (unit == "em") return CalcVal(num * fontSizePx, true);
        if (unit == "vh") return CalcVal(viewportHeight * num / 100.0, true);
        if (unit == "vw") return CalcVal(viewportWidth * num / 100.0, true);
        return CalcVal(num, false);
    }

    unittest
    {
        ComputedStyle s;
        s.rootFontSizePx = 16;
        s.fontSizePx = 16;
        s.viewportWidth = 1000;
        s.viewportHeight = 800;
        assert(s.resolveLength("calc(100% - 88px)", 400) == 312, "calc subtraction");
        assert(s.resolveLength("calc(50% + 10px)", 400) == 210, "calc addition");
        assert(s.resolveLength("calc(0.38 * 100%)", 1000) == 380, "calc multiplication");
        assert(s.resolveLength("calc(1rem + 4px)", 400) == 20, "calc rem + px");
    }
}

/// Safely parse the leading integer of a CSS numeric token (e.g. "12px"->12,
/// "1.5"->1, "auto"->0). Never throws.
int cssInt(string s) @safe pure nothrow
{
    import std.conv : to;
    const t = s.strip();
    if (t.length == 0) return 0;
    int sign = 1;
    size_t i = 0;
    if (t[0] == '-') { sign = -1; i = 1; }
    else if (t[0] == '+') { i = 1; }
    int value = 0;
    bool any = false;
    while (i < t.length)
    {
        auto c = t[i];
        if (c >= '0' && c <= '9') { value = value * 10 + (c - '0'); any = true; }
        else break;
        i++;
    }
    return any ? sign * value : 0;
}

/// Safely parse the leading double of a CSS numeric token. Never throws.
double cssDouble(string s) @safe pure nothrow
{
    const t = s.strip();
    if (t.length == 0) return 0.0;
    size_t i = 0;
    if (t[0] == '-' || t[0] == '+') i = 1;
    double value = 0.0;
    double scale = 0.1;
    bool any = false;
    bool dot = false;
    while (i < t.length)
    {
        auto c = t[i];
        if (c >= '0' && c <= '9')
        {
            if (dot) { value += (c - '0') * scale; scale *= 0.1; }
            else value = value * 10 + (c - '0');
            any = true;
        }
        else if (c == '.' && !dot) dot = true;
        else break;
        i++;
    }
    if (!any) return 0.0;
    if (t[0] == '-') return -value;
    return value;
}

/** Placeholder for a laid-out box; the layout module fills this in. */
struct Box
{
    int x;
    int y;
    int width;
    int height;
    int marginTop;
    int marginRight;
    int marginBottom;
    int marginLeft;
    int paddingTop;
    int paddingRight;
    int paddingBottom;
    int paddingLeft;
    int borderTop;
    int borderRight;
    int borderBottom;
    int borderLeft;
    /// `margin: auto` on a horizontal side (used to center a block that has a
    /// definite width, per CSS 10.3.3).
    bool marginLeftAuto;
    bool marginRightAuto;
    /// `margin: auto` on a vertical side (distributes the leftover space for an
    /// absolutely positioned box with both vertical insets, per CSS 10.6.4).
    bool marginTopAuto;
    bool marginBottomAuto;
}

unittest
{
    // CSS keyword values must never throw when parsed as numbers (this crashed
    // the engine on real pages like google.com with "Unexpected 'd'").
    assert(cssInt("auto") == 0);
    assert(cssInt("normal") == 0);
    assert(cssInt("medium") == 0);
    assert(cssInt("thin") == 0);
    assert(cssInt("inherit") == 0);
    assert(cssInt("12px") == 12);
    assert(cssInt("1.5") == 1);
    assert(cssInt("-3") == -3);
    assert(cssInt("100%") == 100);
    assert(cssDouble("1.5") == 1.5);
    assert(cssDouble("bold") == 0.0);
    assert(cssDouble("2.5em") == 2.5);
}

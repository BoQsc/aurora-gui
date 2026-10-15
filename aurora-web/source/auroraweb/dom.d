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
import std.string : split, strip;

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
    bool imageLoadTried;      /// <img> fetch already attempted (avoid re-fetching).
    bool backgroundLoadTried; /// `background-image` fetch already attempted.

    this(string tag)
    {
        this.tag = tag;
    }

    bool hasClass(string className) const
    {
        auto classAttr = "class" in attrs;
        if (classAttr is null) return false;
        return (*classAttr).split(" ").canFind(className);
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
    string background = "transparent";
    string backgroundImage = "none";
    string backgroundSize = "auto";
    string fontSize = "16px";
    string fontWeight = "400";
    string fontStyle = "normal";
    string fontFamily = "system-ui";
    string textAlign = "left";
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
    string justifyContent = "flex-start";
    string alignItems = "stretch";
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
    string gridTemplateColumns = "";
    string gridTemplateRows = "";
    string columnGap = "";
    string rowGap = "";
    string borderRadius = "0px";
    string boxShadowH = "0px";
    string boxShadowV = "0px";
    string boxShadowBlur = "0px";
    string boxShadowColor = "none";
    string textDecoration = "none";

    /// Element opacity 0..1 (1 = fully opaque). Applied to the alpha channel
    /// of every fill this element paints (background, border, text, shadow).
    double opacity = 1.0;

    /// Painting order for positioned elements; higher z-index paints on top.
    int zIndex = 0;

    /// Whether the element participates in stacking (`position` != static).
    bool isPositioned() const
    {
        return position == "relative" || position == "absolute" || position == "fixed";
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

    /// Parse a px value from a CSS length string; returns -1 if not a px length.
    int pxLength(string prop) const
    {
        const s = prop.strip();
        if (s.length >= 3 && s[$ - 2 .. $] == "px")
            return cssInt(s[0 .. $ - 2].strip());
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

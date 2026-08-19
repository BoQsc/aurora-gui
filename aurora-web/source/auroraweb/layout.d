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

import auroraweb.css : Rule, cascadeFor, applyMediaRules;
import auroraweb.dom : ComputedStyle, Element, TextNode;
import aurora.image : RgbaImage;
import aurora.font : FontRole;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : TextLayout, TextLayoutOptions;

import std.algorithm : max, min;
import std.conv : to;
import std.string : endsWith, indexOf, split, strip, toLower;

/// Measure a text run into wrapped lines using Aurora's real text engine.
/// `maxWidth` is the wrap width (0 = no wrap). Returns the TextLayout (or null
/// on failure). This is what makes layout match painting.
private TextLayout shapeText(string text, int pixelSize, int maxWidth)
{
    try
    {
        auto fonts = FontSystem.sharedInstance();
        dchar[] dtext;
        foreach (ch; text) dtext ~= ch;
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.pixelSize = max(1, pixelSize);
        options.maxWidth = maxWidth;
        options.wrap = maxWidth > 0;
        return fonts.textEngine.layout(dtext, options);
    }
    catch (Exception)
    {
        return null;
    }
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

/// Resolve styles for every element using the cascade, then lay out.
void applyStylesAndLayout(Element root, in Rule[] rules, int viewportWidth, int viewportHeight)
{
    auto active = applyMediaRules(rules, viewportWidth, viewportHeight);
    resolveStyles(root, active, viewportWidth, viewportHeight);
    layout(root, viewportWidth, viewportHeight);
}

/// Resolve computed style for each element and its children.
private void resolveStyles(Element element, in Rule[] rules, int viewportWidth, int viewportHeight)
{
    element.style = computedStyle(element, rules);
    element.style.viewportWidth = viewportWidth;
    element.style.viewportHeight = viewportHeight;
    foreach (child; element.elements)
        resolveStyles(child, rules, viewportWidth, viewportHeight);
}

/// Compute the style map for one element from cascade plus inline style.
private ComputedStyle computedStyle(Element element, in Rule[] rules)
{
    ComputedStyle style;
    // User-agent default display.
    style.display = uaDisplay(element.tag);
    if (element.tag == "th")
        style.fontWeight = "bold";

    auto cascade = cascadeFor(element, rules);
    applyDeclaration(style, "display", cascade.get("display", ""));
    applyDeclaration(style, "color", cascade.get("color", ""));
    applyDeclaration(style, "background", cascade.get("background", ""));
    applyDeclaration(style, "background-color", cascade.get("background-color", ""));
    applyDeclaration(style, "background-image", cascade.get("background-image", ""));
    applyDeclaration(style, "background-size", cascade.get("background-size", ""));
    applyDeclaration(style, "font-size", cascade.get("font-size", ""));
    applyDeclaration(style, "font-weight", cascade.get("font-weight", ""));
    applyDeclaration(style, "font-style", cascade.get("font-style", ""));
    applyDeclaration(style, "font-family", cascade.get("font-family", ""));
    applyDeclaration(style, "text-align", cascade.get("text-align", ""));
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

    // Inline style attribute overrides everything.
    auto inlineStyle = "style" in element.attrs;
    if (inlineStyle !is null)
    {
        foreach (decl; parseInlineDeclarations(*inlineStyle))
            applyDeclaration(style, decl.property, decl.value);
    }
    return style;
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
        case "img", "input":
            return "inline-block";
        case "head", "title", "meta", "link", "style", "script", "template":
            return "none";
        default:
            return "inline";
    }
}

private void applyDeclaration(ref ComputedStyle style, string property, string value)
{
    if (value.length == 0) return;
    switch (property)
    {
        case "display":
            if (value == "block" || value == "inline" || value == "inline-block" ||
                value == "flex" || value == "none" || value == "list-item" ||
                value == "grid" || value == "table" || value == "table-row" ||
                value == "table-cell")
                style.display = value;
            break;
        case "color": style.color = value; break;
        case "background": style.background = value; break;
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
                    style.backgroundImage = "none";
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
        case "font-size": style.fontSize = value; break;
        case "font-weight": style.fontWeight = value; break;
        case "font-style": style.fontStyle = value; break;
        case "font-family": style.fontFamily = value; break;
        case "text-align": style.textAlign = value; break;
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
        case "border-top": style.borderTopWidth = value; break;
        case "border-right": style.borderRightWidth = value; break;
        case "border-bottom": style.borderBottomWidth = value; break;
        case "border-left": style.borderLeftWidth = value; break;
        case "position": if (value == "static" || value == "relative" || value == "absolute" ||
            value == "fixed")
            style.position = value; break;
        case "top": style.top = value; break;
        case "left": style.left = value; break;
        case "right": style.right = value; break;
        case "bottom": style.bottom = value; break;
        case "float": if (value == "left" || value == "right" || value == "none")
            style.floatStyle = value; break;
        case "clear": if (value == "left" || value == "right" || value == "both" || value == "none")
            style.clear = value; break;
        case "visibility": style.visibility = value; break;
        case "overflow": style.overflow = value; break;
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
                value == "space-around" || value == "flex-end")
                style.justifyContent = value;
            break;
        case "align-items":
            if (value == "stretch" || value == "center" || value == "flex-start" || value == "flex-end")
                style.alignItems = value;
            break;
        case "gap": style.gap = value; break;
        case "line-height": style.lineHeight = value; break;
        case "box-sizing":
            if (value == "border-box" || value == "content-box") style.boxSizing = value;
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
    // Resolve each side from per-side values or the shorthand.
    element.box.marginTop = resolveSide(style.marginTop.length ? style.marginTop : style.margin,
        containingWidth, 0);
    element.box.marginRight = resolveSide(style.marginRight.length ? style.marginRight : style.margin,
        containingWidth, 1);
    element.box.marginBottom = resolveSide(style.marginBottom.length ? style.marginBottom : style.margin,
        containingWidth, 2);
    element.box.marginLeft = resolveSide(style.marginLeft.length ? style.marginLeft : style.margin,
        containingWidth, 3);

    element.box.paddingTop = resolveSide(style.paddingTop.length ? style.paddingTop : style.padding,
        containingWidth, 0);
    element.box.paddingRight = resolveSide(style.paddingRight.length ? style.paddingRight : style.padding,
        containingWidth, 1);
    element.box.paddingBottom = resolveSide(style.paddingBottom.length ? style.paddingBottom : style.padding,
        containingWidth, 2);
    element.box.paddingLeft = resolveSide(style.paddingLeft.length ? style.paddingLeft : style.padding,
        containingWidth, 3);

    // Borders.
    const bTop = sideValue(style.borderTopWidth.length ? style.borderTopWidth :
        (style.borderWidth.length ? style.borderWidth : style.border), containingWidth, 0);
    const bRight = sideValue(style.borderRightWidth.length ? style.borderRightWidth :
        (style.borderWidth.length ? style.borderWidth : style.border), containingWidth, 1);
    const bBottom = sideValue(style.borderBottomWidth.length ? style.borderBottomWidth :
        (style.borderWidth.length ? style.borderWidth : style.border), containingWidth, 2);
    const bLeft = sideValue(style.borderLeftWidth.length ? style.borderLeftWidth :
        (style.borderWidth.length ? style.borderWidth : style.border), containingWidth, 3);
    element.box.borderTop = bTop;
    element.box.borderRight = bRight;
    element.box.borderBottom = bBottom;
    element.box.borderLeft = bLeft;
}

private int resolveSide(string value, int containingWidth, int sideIndex)
{
    auto parts = value.split();
    if (parts.length == 0) return 0;
    int px(string s)
    {
        import auroraweb.dom : cssInt;
        if (s == "0") return 0;
        if (s.length >= 3 && s[$ - 2 .. $] == "px") return cssInt(s[0 .. $ - 2]);
        if (s.length >= 2 && s[$ - 1] == '%') return (containingWidth * cssInt(s[0 .. $ - 1])) / 100;
        return -1;
    }
    switch (parts.length)
    {
        case 1: return px(parts[0]);
        case 2: return sideIndex < 2 ? px(parts[0]) : px(parts[1]);
        case 3: switch (sideIndex) { case 0: return px(parts[0]); case 1: case 3: return px(parts[1]); default: return px(parts[2]); }
        default: switch (sideIndex) { case 0: return px(parts[0]); case 1: return px(parts[1]); case 2: return px(parts[2]); default: return px(parts[3]); }
    }
}

private int sideValue(string value, int containingWidth, int sideIndex)
{
    return resolveSide(value, containingWidth, sideIndex);
}

/// Layout a block-level element and its children in normal flow.
private void layoutBlock(Element element, ref FlowContext flow, int containingWidth, Element positionedAncestor)
{
    auto style = element.style;

    if (style.display == "none") { element.box.height = 0; return; }

    resolveBoxMetrics(element, containingWidth);
    style.containingWidth = containingWidth;
    style.containingHeight = flow.height;

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

    // Margin collapsing with the previous sibling's bottom margin.
    if (flow.prevBottomMargin > 0)
    {
        const collapsed = max(flow.prevBottomMargin, element.box.marginTop);
        element.box.y = flow.y + (collapsed - flow.prevBottomMargin);
    }
    else
    {
        element.box.y = flow.y + element.box.marginTop;
    }

    element.box.x = flow.x + element.box.marginLeft;
    element.box.width = width;

    // Layout children in a nested flow constrained by our content box.
    auto childFlow = FlowContext();
    childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    childFlow.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    childFlow.width = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);
    childFlow.height = flow.height;
    childFlow.lineEnd = childFlow.x + childFlow.width;

    layoutChildren(element, childFlow, element);
    // Lay out any direct text content inline (wrapping at the content width).
    layoutDirectText(element, childFlow);

    // Compute this block's height from explicit style or its content.
    int finalHeight = height;
    if (height < 0)
    {
        auto innerBottom = childFlow.y + max(childFlow.contentBottom, 0);
        innerBottom += element.box.paddingBottom + element.box.borderBottom;
        finalHeight = max(0, innerBottom - element.box.y);
    }
    finalHeight = clampMinMaxHeight(element, finalHeight);
    element.box.height = finalHeight;

    // Advance the flow past this box (including bottom margin).
    flow.prevBottomMargin = element.box.marginBottom;
    flow.y = max(flow.y, element.box.y + element.box.height + element.box.marginBottom);
}

/// Lay out the DIRECT text-node and inline-element children of a block on a
/// shared inline line, advancing a horizontal cursor and wrapping at the
/// block's content width using real shaped measurement. Whitespace-only text
/// nodes between block elements are skipped.
private void layoutDirectText(Element element, ref FlowContext flow)
{
    const px = element.style.pxLength(element.style.fontSize);
    const pixelSize = px >= 0 ? px : 16;
    // line-height: an explicit px value sizes the line boxes (advance + box
    // height); otherwise fall back to font-size + 8px breathing room.
    const explicitLineH = element.style.pxLength(element.style.lineHeight);
    const lineH = explicitLineH > 0 ? explicitLineH : pixelSize + 8;
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

    foreach (child; element.children)
    {
        auto text = cast(TextNode) child;
        if (text !is null)
        {
            if (text.data.strip().length == 0)
            {
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
            auto layout = shapeText(text.data, pixelSize, innerW);
            if (layout !is null && layout.lines.length > 0)
            {
                // The run may wrap internally to multiple lines. Advance the
                // cursor to the END of the run's last line so following inline
                // content continues correctly instead of overlapping.
                wrapTo(leftEdge, rightEdge);
                text.layoutX = cursorX;
                text.layoutY = cursorY;
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
                    cursorX += cast(int) layout.width;
                }
                maxBottom = max(maxBottom, cursorY + lineH);
                continue;
            }
            // Fallback: no shaped layout.
            const int textWidth = cast(int)(text.data.length * 8);
            wrapTo(leftEdge, rightEdge);
            text.layoutX = cursorX;
            text.layoutY = cursorY;
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
            const int leftEdge = flow.lineLeft(cursorY, lineH);
            const int rightEdge = flow.lineRight(cursorY, lineH);
            // Measure the inline element's text content.
            int cw;
            int ceLines = 1;
            if (ce.style.display == "inline-block")
                cw = resolveWidth(ce, flow.width);
            else
            {
                auto lay = shapeText(ce.textContent(), pixelSize, max(0, rightEdge - cursorX));
                if (lay !is null && lay.lines.length > 0)
                {
                    cw = cast(int) lay.width;
                    ceLines = cast(int) lay.lines.length;
                }
                else
                    cw = cast(int)(ce.textContent().length * 8);
            }
            wrapTo(leftEdge, rightEdge);
            ce.box.x = cursorX;
            ce.box.y = cursorY;
            ce.box.width = cw;
            ce.box.height = ceLines * lineH;
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
                cursorX += cw;
            }
            // Layout the inline element's own children (text inside <b>, <i>, ...).
            auto sub = FlowContext();
            sub.x = ce.box.x;            // text starts at this element's left
            sub.y = ce.box.y;            // ... and its top line
            sub.width = flow.width;
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

/// Shift an inline element and all its descendant inline text runs by `shift`
/// px. Used by the text-align pass so a moved inline box carries its text.
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
        if (style.boxSizing == "border-box")
            width = widthPx; // includes padding+border
        else
            width = widthPx + element.box.paddingLeft + element.box.paddingRight +
                element.box.borderLeft + element.box.borderRight;
    }
    else if (style.display == "inline-block")
    {
        // An inline-block with a decoded image sizes to the image's intrinsic
        // width; otherwise fall back to a 16px placeholder.
        auto img = cast(RgbaImage) element.image;
        if (img !is null)
            width = img.width();
        else
            width = 16;
    }
    else
        width = containingWidth - element.box.paddingLeft - element.box.paddingRight -
            element.box.borderLeft - element.box.borderRight - element.box.marginLeft -
            element.box.marginRight;
    return clampMinMaxWidth(element, max(0, width));
}

private int resolveHeight(Element element)
{
    auto style = element.style;
    auto heightPx = style.resolveLength(style.height, style.containingHeight);
    if (heightPx >= 0)
    {
        if (style.boxSizing == "border-box")
            return clampMinMaxHeight(element, max(0, heightPx));
        return clampMinMaxHeight(element, max(0, heightPx + element.box.paddingTop + element.box.paddingBottom +
            element.box.borderTop + element.box.borderBottom));
    }
    // An inline-block with a decoded image and no explicit height uses the
    // image's intrinsic height. -1 means "auto — caller measures content".
    if (style.display == "inline-block")
    {
        auto img = cast(RgbaImage) element.image;
        if (img !is null)
            return clampMinMaxHeight(element, max(0, img.height()));
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

    // Children of an absolute element lay out normally inside it.
    auto childFlow = FlowContext();
    childFlow.x = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    childFlow.y = element.box.y + element.box.paddingTop + element.box.borderTop;
    childFlow.width = max(0, w - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);
    childFlow.height = cbH;
    childFlow.lineEnd = childFlow.x + childFlow.width;
    layoutChildren(element, childFlow, element);
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

private void layoutChildren(Element element, ref FlowContext flow, Element positionedAncestor)
{
    foreach (child; element.children)
    {
        auto childElement = cast(Element) child;
        if (childElement !is null)
        {
            auto childStyle = childElement.style;
            // Direct inline children are laid out on the block's inline line by
            // layoutDirectText; skip them here so they don't become 0x0 blocks.
            // Positioned children (absolute/fixed) are never laid out inline —
            // they are removed from flow and positioned independently.
            if ((childStyle.display == "inline" || childStyle.display == "inline-block") &&
                childStyle.position != "absolute" && childStyle.position != "fixed")
                continue;
            if (childStyle.display == "flex")
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
            const int textWidth = cast(int)(text.data.length * 8);
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
            const int cw = childElement.style.display == "inline-block" ? 16 :
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

private void layoutFlex(Element element, ref FlowContext flow, Element positionedAncestor)
{
    resolveBoxMetrics(element, flow.width);
    element.box.x = flow.x + element.box.marginLeft;
    element.box.y = flow.y + element.box.marginTop;

    int width = resolveWidth(element, flow.width);
    element.box.width = width;

    // Content box.
    const innerX = element.box.x + element.box.paddingLeft + element.box.borderLeft;
    const innerY = element.box.y + element.box.paddingTop + element.box.borderTop;
    const innerW = max(0, width - element.box.paddingLeft - element.box.paddingRight -
        element.box.borderLeft - element.box.borderRight);

    // Children flex items.
    auto style = element.style;
    const gapPx = style.pxLength(style.gap) >= 0 ? style.pxLength(style.gap) : 0;

    int[] itemWidths;
    int totalFlex = 0;
    Element[] items;
    foreach (child; element.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        items ~= ce;
        resolveBoxMetrics(ce, innerW);
        import auroraweb.dom : cssInt;
        auto growStr = ce.style.flexGrow;
        int grow = growStr.length ? cssInt(growStr) : 0;
        totalFlex += grow;
        auto basis = ce.style.resolveLength(ce.style.width, innerW);
        itemWidths ~= basis >= 0 ? basis : 0;
    }

    const int fixedTotal = sumWidths(itemWidths);
    const int gapTotal = gapPx * cast(int)max(0, items.length - 1);
    const int remaining = innerW - fixedTotal - gapTotal;
    int remainingSplit = remaining;
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
                remainingSplit -= share;
            }
        }
    }

    // justify-content.
    int cursor = innerX;
    const int used = fixedTotal + (totalFlex > 0 ? (remaining - remainingSplit) : 0);
    if (style.justifyContent == "center")
        cursor = innerX + (innerW - used) / 2;
    else if (style.justifyContent == "flex-end")
        cursor = innerX + (innerW - used);
    else if (style.justifyContent == "space-between")
        cursor = innerX; // gap handled below via distributed extra

    int maxChildHeight = 0;
    int[] xs;
    int[] ys;
    foreach (i, ce; items)
    {
        ce.box.x = cursor;
        ce.box.y = innerY;
        ce.box.width = itemWidths[i];
        ce.box.height = resolveHeight(ce) >= 0 ? resolveHeight(ce) : 0;
        xs ~= cursor;
        ys ~= innerY;
        cursor += itemWidths[i] + gapPx;
        layoutChildren(ce, flow, ce);
        maxChildHeight = max(maxChildHeight, ce.box.height);
    }

    // align-items: center.
    if (style.alignItems == "center")
    {
        foreach (i, ce; items)
            ce.box.y = innerY + (maxChildHeight - ce.box.height) / 2;
    }

    // Container height = tallest child (+ padding/border).
    const hPx = resolveHeight(element);
    int finalH = hPx >= 0 ? hPx : maxChildHeight + element.box.paddingTop + element.box.paddingBottom +
        element.box.borderTop + element.box.borderBottom;
    finalH = clampMinMaxHeight(element, max(0, finalH));
    element.box.height = finalH;

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
    // First pass: fixed lengths + count fr.
    foreach (part; value.split())
    {
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
    foreach (part; value.split())
    {
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

/// Grid layout: auto-placement across template columns, fr sizing.
private void layoutGrid(Element element, ref FlowContext flow, Element positionedAncestor)
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
        layoutChildren(ce, sub, ce);
        if (sub.contentBottom > 0)
            itemH = max(itemH, sub.contentBottom + ce.box.paddingTop + ce.box.paddingBottom);
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
    int floatLeft;        /// Rightmost float left edge.
    FloatRect[] floats;   /// Active float rects for line shaping.
    int prevBottomMargin; /// Previous block's bottom margin (for collapsing).
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
    // dimensions; CSS width/height override the intrinsic size.
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
        assert(styled.box.height == 50, "img intrinsic height should remain 50, got " ~ styled.box.height.to!string);
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
        // The run's y is on that first line.
        assert(textNode.layoutY == 0, "run y=0, got " ~ textNode.layoutY.to!string);
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

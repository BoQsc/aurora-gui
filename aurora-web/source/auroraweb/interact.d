module auroraweb.interact;

/**
 * Host-side interaction helpers: hit-testing laid-out elements and resolving
 * link targets. Used by the browser shell to turn real mouse/keyboard input
 * into DOM events, and to know which element the pointer is over (for `:hover`).
 */

import auroraweb.dom : Element;

import std.algorithm : sort;

/// True when the page point (x, y) lies inside the element's BORDER box.
/// `box.x/box.y` is the border-box origin and `box.width/height` is the content
/// box, so padding + border are added back to get the painted extent.
bool boxContains(Element e, int x, int y)
{
    if (e is null) return false;
    const w = e.box.width + e.box.paddingLeft + e.box.paddingRight +
        e.box.borderLeft + e.box.borderRight;
    const h = e.box.height + e.box.paddingTop + e.box.paddingBottom +
        e.box.borderTop + e.box.borderBottom;
    if (w <= 0 || h <= 0) return false;
    return x >= e.box.x && x < e.box.x + w && y >= e.box.y && y < e.box.y + h;
}

/// The topmost laid-out element at a page point. Descends into children that
/// contain the point; positioned children (which paint last) win over normal
/// ones, then higher z-index, then later document order. Returns `root` when no
/// descendant matches.
Element elementAt(Element root, int x, int y)
{
    if (root is null) return null;
    // Deepest element containing the point wins; ties go to later document
    // order (later siblings paint on top). This walks the whole tree instead of
    // gating on each intermediate box: a block whose measured box does not
    // cover an overflowing inline-block child (see the block/inline ordering
    // limitation) must still let a click reach that child.
    Element best = null;
    int bestDepth = -1;
    void visit(Element e, int depth)
    {
        if (e is null) return;
        if (e.style.display == "none" || e.style.visibility == "hidden") return;
        if (boxContains(e, x, y) && depth >= bestDepth)
        {
            best = e;
            bestDepth = depth;
        }
        foreach (c; e.elements) visit(c, depth + 1);
    }
    visit(root, 0);
    return best !is null ? best : root;
}

/// The `href` of the nearest ancestor-or-self `<a>` that carries one ("" when
/// none). Used to decide whether a click should navigate.
string hrefOf(Element e)
{
    auto cur = e;
    while (cur !is null)
    {
        if (cur.tag == "a")
        {
            auto href = "href" in cur.attrs;
            if (href !is null && (*href).length) return *href;
        }
        cur = cur.parent;
    }
    return "";
}

/// The element itself when it is an `<a>` with an href, else the nearest
/// ancestor that is — the anchor whose box hit-testing should use.
Element anchorOf(Element e)
{
    auto cur = e;
    while (cur !is null)
    {
        if (cur.tag == "a")
        {
            auto href = "href" in cur.attrs;
            if (href !is null && (*href).length) return cur;
        }
        cur = cur.parent;
    }
    return null;
}

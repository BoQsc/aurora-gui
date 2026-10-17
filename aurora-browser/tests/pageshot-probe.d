module pageshot;

/**
 * Full-page capture for Aurora Browser.
 *
 * The built-in `--screenshot` path is pinned to a 1080x680 viewport, so it can
 * neither show a page at the window's real width nor show anything below the
 * first screen. This tool drives the real `BrowserRoot` at an arbitrary width
 * and height, paints several times so progressively-loaded images settle, and
 * writes the whole frame to a PPM.
 *
 * usage: pageshot <url> <width> <height> <out.ppm> [paints] [needle] [class]
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, browserTheme, WebPageView;
import auroraweb : WebPage;
import auroraweb.dom : Element, TextNode;

import std.conv : to;
import std.file : readText;
import std.string : indexOf, split;
import std.stdio : stderr, write, writeln;

/// Depth-first search for the page view inside the widget tree.
WebPageView findView(Widget widget)
{
    if (widget is null) return null;
    auto view = cast(WebPageView) widget;
    if (view !is null) return view;
    foreach (child; widget.children)
    {
        auto found = findView(child);
        if (found !is null) return found;
    }
    return null;
}

/// Count generated ::before/::after boxes in the tree and describe the first one
/// that declares a background (so its resolved style can be inspected).
int countPseudos(Element element, ref string desc)
{
    if (element is null) return 0;
    int n = 0;
    foreach (pseudo; [element.pseudoBefore, element.pseudoAfter])
    {
        if (pseudo is null) continue;
        n++;
        if (desc.length == 0)
            desc = element.tag ~ " " ~ pseudo.tag ~ " box=(" ~
                pseudo.box.x.to!string ~ "," ~ pseudo.box.y.to!string ~ " " ~
                pseudo.box.width.to!string ~ "x" ~ pseudo.box.height.to!string ~
                ") display=" ~ pseudo.style.display ~
                " position=" ~ pseudo.style.position ~
                " opacity=" ~ pseudo.style.opacity.to!string ~
                " content=" ~ pseudo.style.content ~
                " mask=" ~ pseudo.style.maskImage ~
                " bg=" ~ (pseudo.style.backgroundGradient.length ?
                    pseudo.style.backgroundGradient :
                    (pseudo.style.backgroundImage.length ?
                        pseudo.style.backgroundImage : pseudo.style.background));
    }
    foreach (child; element.elements)
        n += countPseudos(child, desc);
    return n;
}

/// Count elements carrying a mask-image and report the first one, so a page's
/// masked layer can be confirmed from the real paint path.
int reportMasked(Element element, ref string firstDesc, ref int count)
{
    if (element is null) return 0;
    if (element.style.maskImage.length && element.style.maskImage != "none")
    {
        count++;
        if (firstDesc.length == 0)
            firstDesc = element.tag ~ " box=(" ~ element.box.x.to!string ~ "," ~
                element.box.y.to!string ~ " " ~ element.box.width.to!string ~ "x" ~
                element.box.height.to!string ~ ") mask=" ~ element.style.maskImage;
    }
    foreach (child; element.elements)
        reportMasked(child, firstDesc, count);
    foreach (pseudo; [element.pseudoBefore, element.pseudoAfter])
        if (pseudo !is null) reportMasked(pseudo, firstDesc, count);
    return count;
}

/// True when the class attribute lists `needle` as a whole token, so "footer"
/// matches `class="site-footer"` but not `class="subfooter"`.
bool hasClassToken(string cls, string needle)
{
    foreach (token; cls.split())
        if (token == needle) return true;
    return false;
}

/// Print a subtree with each element's box and the style bits that decide
/// placement, so a collapsed footer column can be traced to the box that owns it.
void printTree(Element element, int depth)
{
    if (element is null || depth > 6) return;
    foreach (i; 0 .. depth) write("  ");
    auto cls = "class" in element.attrs;
    writeln(element.tag, cls !is null ? "." ~ *cls : "",
        " box=(", element.box.x, ",", element.box.y, " ",
        element.box.width, "x", element.box.height, ")",
        " display=", element.style.display,
        " position=", element.style.position,
        " float=", element.style.floatStyle,
        " overflow=", element.style.overflow,
        " pad=", element.box.paddingTop, ",", element.box.paddingRight, ",",
        element.box.paddingBottom, ",", element.box.paddingLeft,
        " mar=", element.box.marginTop, ",", element.box.marginLeft,
        " f=", element.style.fontSize, "/", element.style.lineHeight,
        " fsPx=", element.style.fontSizePx, "/", element.style.rootFontSizePx,
        " declPad=", element.style.padding,
        " declMar=", element.style.margin,
        " lhPadL=", element.style.paddingLeft,
        " lhMarT=", element.style.marginTop);
    foreach (child; element.elements)
        printTree(child, depth + 1);
}

/// Print the subtree of every element carrying `needle` as a tag or class token
/// and return how many were printed. A fixture can stack several cases; stopping
/// at the first hid the rest.
int dumpSubtree(Element element, string needle, int depth)
{
    if (element is null || depth > 20) return 0;
    int found = 0;
    auto cls = "class" in element.attrs;
    if (element.tag == needle || (cls !is null && hasClassToken(*cls, needle)))
    {
        printTree(element, 0);
        // Do not descend into a match: its children are already printed.
        return 1;
    }
    foreach (child; element.elements)
        found += dumpSubtree(child, needle, depth + 1);
    return found;
}

/// Print the boxes of the element whose class contains `needle`, plus its
/// children, so a 0x0 SVG can be told apart from a missing one.
int dumpClass(Element element, string needle, int depth)
{
    if (element is null || depth > 8) return 0;
    auto cls = "class" in element.attrs;
    if (cls !is null && indexOf(*cls, needle) >= 0)
    {
        writeln("  ", element.tag, " .", *cls, " box=(", element.box.x, ",",
            element.box.y, " ", element.box.width, "x", element.box.height, ")");
        foreach (child; element.elements)
            writeln("    child ", child.tag, " box=(", child.box.x, ",",
                child.box.y, " ", child.box.width, "x", child.box.height,
                ") decl=", child.style.width, "|", child.style.height);
        return 1;
    }
    foreach (child; element.elements)
        if (dumpClass(child, needle, depth + 1)) return 1;
    return 0;
}

/// Print the box of every text run containing `needle` (a page can hold more
/// than one copy of a paragraph; reporting only the first hid the painted one).
int countText(Element element, string needle)
{
    if (element is null) return 0;
    int found = 0;
    foreach (child; element.children)
    {
        auto text = cast(TextNode) child;
        if (text !is null && indexOf(text.data, needle) >= 0)
        {
            writeln("  run: layoutX=", text.layoutX, " layoutY=", text.layoutY,
                " layoutWidth=", text.layoutWidth, " lines=", text.lineIndex,
                " data='", text.data.length > 30 ? text.data[0 .. 30] : text.data, "'");
            ++found;
        }
    }
    foreach (child; element.elements)
        found += countText(child, needle);
    return found;
}

/// Render a local HTML fixture through the engine alone: no app chrome and no
/// URL handling, exactly how the reference corpora load a fixture, so a case
/// can be measured with the same probe used against the live sites.
int runFixture(string[] args)
{
    // usage: pageshot --fixture <file.html> <width> <height> <out.ppm> [needle]
    if (args.length < 6)
    {
        stderr.writeln("usage: pageshot --fixture <file.html> <width> <height> <out.ppm> [needle]");
        return 2;
    }
    const path = args[2];
    const w = to!int(args[3]);
    const h = to!int(args[4]);
    const outPath = args[5];
    const needle = args.length >= 7 ? args[6] : "ul";
    auto page = new WebPage(w, h);
    page.setHtml(readText(path));
    page.executeScripts();
    page.layout();
    writeln("fixture viewport=", page.width(), "x", page.height());
    writeln("subtree probe: ", dumpSubtree(page.root(), needle, 0));
    auto surface = new Surface(w, h);
    surface.clear(Color.rgb(255, 255, 255));
    page.paint(surface);
    surface.savePpm(outPath);
    writeln("captured ", w, "x", h, " -> ", outPath);
    return 0;
}

int main(string[] args)
{
    if (args.length < 5)
    {
        stderr.writeln("usage: pageshot <url> <width> <height> <out.ppm> [paints] [needle] [class]");
        return 2;
    }
    if (args[1] == "--fixture")
        return runFixture(args);
    const url = args[1];
    const w = to!int(args[2]);
    const h = to!int(args[3]);
    const outPath = args[4];
    const paints = args.length >= 6 ? to!int(args[5]) : 12;
    // Optional text needle: report the layout position of every run containing
    // it, so a footer overlap can be read from the engine's own numbers.
    const needle = args.length >= 7 ? args[6] : "have been testing";

    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = w;
    options.height = h;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (url.length > 0)
        root.openUrlAtStartup(url);

    auto driver = new UiTestDriver(window);
    driver.resize(Size(w, h));
    // The live browser repaints as images stream in, so paint repeatedly: a
    // single paint would capture the page before its images arrive (and any
    // screenshot forces repaints, which is how it flatters the live app).
    foreach (i; 0 .. paints)
        driver.paint();
    // Same-driver geometry: report the boxes of the page the painter actually
    // used, so the capture can be compared against the engine's own numbers
    // rather than guessed from pixels.
    {
        auto view = findView(root);
        if (view !is null && view.page() !is null)
        {
            auto page = view.page();
            writeln("page viewport=", page.width(), "x", page.height());
            const int runs = countText(page.root(), needle);
            writeln("matching runs: ", runs);
            const classNeedle = args.length >= 8 ? args[7] : "hero__topography";
            writeln("class probe: ", dumpClass(page.root(), classNeedle, 0));
            if (args.length >= 8)
                writeln("subtree probe: ", dumpSubtree(page.root(), classNeedle, 0));
            {
                string firstMasked;
                int maskedCount = 0;
                reportMasked(page.root(), firstMasked, maskedCount);
                writeln("masked elements: ", maskedCount,
                    maskedCount ? "  first: " ~ firstMasked : "");
                string firstPseudo;
                const pseudoCount = countPseudos(page.root(), firstPseudo);
                writeln("generated pseudo boxes: ", pseudoCount,
                    pseudoCount ? "  first: " ~ firstPseudo : "");
            }
        }
        else
            writeln("no page view found");
    }
    window.saveScreenshot(outPath);
    window.close();
    writeln("captured ", w, "x", h, " -> ", outPath);
    return 0;
}

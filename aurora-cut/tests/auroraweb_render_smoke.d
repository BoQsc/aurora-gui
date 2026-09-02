module tests.auroraweb_render_smoke;

/**
 * Headless smoke test for the Aurora Web engine pipeline:
 * HTML -> DOM -> CSS -> (JS) -> layout -> paint -> pixel verification.
 *
 * Builds a sample page with headings, text, a styled box, and a small script
 * that mutates the DOM through the binding, then renders it into an Aurora
 * software surface and asserts on pixels.
 */

import aurora.color : Color;
import aurora.render.drawlist : DrawList;
import aurora.render.software : SoftwareRenderer;
import aurora.surface : Surface;
import aurora.types : Size;
import aurora.canvas : Canvas;
import auroraweb : WebPage;
import auroraweb.dom : Element, TextNode;
import auroraweb.dombind : bindDocument;
import auroraweb.js : JsRuntime, JsValue, JsKind, parseScript;

import std.stdio : writeln;
import std.conv : to;

int main()
{
    // --- Parse + layout + paint a simple document ---
    auto page = new WebPage(600, 400);

    page.setHtml(`
        <html>
        <head>
            <title>Smoke Test</title>
            <style>
                body { font-size: 14px; }
                h1 { color: red; }
                #box { background: #00ff00; width: 100px; height: 50px; }
                .note { color: blue; }
            </style>
        </head>
        <body>
            <h1>Hello Aurora Web</h1>
            <p>This is a paragraph with some text.</p>
            <div id="box"></div>
            <p class="note">Note text</p>
        </body>
        </html>
    `);

    // Extract the <style> content into the stylesheet.
    auto styleEl = findTag(page.root(), "style");
    if (styleEl !is null)
        page.setStylesheet(styleEl.textContent());

    page.layout();

    // Debug: find #box and print its geometry/style.
    {
        Element boxEl = null;
        void walk(Element e)
        {
            if (e.hasId("box")) boxEl = e;
            foreach (c; e.elements) walk(c);
        }
        walk(page.root());
        assert(boxEl !is null && boxEl.box.width == 100 && boxEl.box.height == 50,
            "box geometry should be 100x50");
    }

    // Render into a software surface.
    auto list = new DrawList();
    list.reset(Size(600, 400), Color.rgb(255, 255, 255));
    auto surface = new Surface(600, 400);
    auto canvas = Canvas(list, 600, 400);
    page.paint(canvas, 0, 0);
    SoftwareRenderer.renderInto(list, surface);

    // --- Verify the red h1 text exists somewhere (pixel scan) ---
    bool foundRed = false;
    for (int y = 0; y < 400; y++)
    {
        for (int x = 0; x < 600; x++)
        {
            auto p = surface.pixel(x, y);
            auto r = (p >> 16) & 0xff;
            auto g = (p >> 8) & 0xff;
            auto b = p & 0xff;
            if (r > 180 && g < 80 && b < 80) { foundRed = true; break; }
        }
        if (foundRed) break;
    }
    assert(foundRed, "Expected red text pixels from the h1");

    // Regression: the red h1 text must render in the TOP 40 rows (where layout
    // places the 16px title). Previously `layoutText(dtext, 16, ...)` treated
    // 16 as a typographic scale -> 102px text pushed far below its box.
    {
        bool redTop = false;
        for (int y = 0; y < 40 && !redTop; y++)
            for (int x = 0; x < 600; x++)
            {
                auto p = surface.pixel(x, y);
                auto r = (p >> 16) & 0xff;
                auto g = (p >> 8) & 0xff;
                auto b = p & 0xff;
                if (r > 180 && g < 80 && b < 80) { redTop = true; break; }
            }
        assert(redTop, "h1 text must render within the top 40 rows (16px text)");
    }

    // --- Verify the green box region ---
    bool foundGreen = false;
    for (int y = 0; y < 400; y++)
    {
        for (int x = 0; x < 600; x++)
        {
            auto p = surface.pixel(x, y);
            auto g = (p >> 8) & 0xff;
            auto r = (p >> 16) & 0xff;
            auto b = p & 0xff;
            if (g > 200 && r < 80 && b < 80) { foundGreen = true; break; }
        }
        if (foundGreen) break;
    }
    assert(foundGreen, "Expected green box pixels from #box");

    // Regression: inline text must NOT overlap. "Hello <b>bold</b> world" has
    // three text runs that must advance a horizontal cursor. Previously every
    // direct text node was placed at the same x, overlapping.
    {
        auto inlinePage = new WebPage(500, 200);
        inlinePage.setHtml(`<html><body><p>Hello <b>bold</b> world <i>italic</i> tail</p></body></html>`);
        inlinePage.executeScripts();
        inlinePage.layout();
        Element pEl = null;
        void findP(Element e)
        {
            if (e.tag == "p") pEl = e;
            foreach (c; e.elements) findP(c);
        }
        findP(inlinePage.root());
        assert(pEl !is null, "inline test needs a <p>");
        // Collect distinct x positions of the p's direct text children.
        int[] xs;
        foreach (c; pEl.children)
        {
            auto t = cast(TextNode) c;
            if (t !is null && t.layoutWidth > 0) xs ~= t.layoutX;
        }
        // With real shaping the runs start at increasing x (0, 40+, ...).
        // Guard: at least two distinct non-zero starts, strictly increasing.
        assert(xs.length >= 3, "expected multiple inline text runs, got " ~ xs.length.to!string);
        for (int i = 1; i < cast(int) xs.length; i++)
            assert(xs[i] > xs[i - 1], "inline text runs overlap (x=" ~ xs[i - 1].to!string ~
                " then " ~ xs[i].to!string ~ ")");
    }

    // Regression: a text run that wraps INTERNALLY must advance the cursor to
    // the next line, so the following inline run doesn't overlap the wrapped
    // portion. Narrow container forces the first run to wrap.
    {
        auto wrapPage = new WebPage(300, 400);
        wrapPage.setHtml(`<html><body><p>This first run is deliberately long and will wrap to a second line inside itself, then <b>this bold</b> and trailing text.</p></body></html>`);
        wrapPage.executeScripts();
        wrapPage.layout();
        Element pEl = null;
        void findP(Element e)
        {
            if (e.tag == "p") pEl = e;
            foreach (c; e.elements) findP(c);
        }
        findP(wrapPage.root());
        assert(pEl !is null, "wrap test needs a <p>");
        // The runs after the wrapping first run must NOT share line 0 with it.
        // Collect (y, x) of every direct text child.
        bool sawLaterLine = false;
        foreach (c; pEl.children)
        {
            auto t = cast(TextNode) c;
            if (t !is null && t.layoutWidth > 0 && t.layoutY > 0)
                sawLaterLine = true;
        }
        assert(sawLaterLine, "wrapping run must push following text to a later line");
    }

    // --- JS engine smoke: parse and execute a small program ---
    auto rt = parseScript(`
        var x = 10;
        var y = 20;
        var sum = x + y;
        function add(a, b) { return a + b; }
        var result = add(sum, 5);
        var obj = { name: "aurora", value: result };
        console.log("JS result:", obj.value);
        if (obj.value == 35) {
            console.log("JS OK");
        } else {
            throw "sum mismatch";
        }
    `);
    rt.runScript(rt.makeObject());

    // Verify the result landed in the global scope.
    auto resultVal = rt.globalScope.get("result");
    assert(resultVal.kind == JsKind.number, "JS result should be a number");
    assert(resultVal.numValue == 35, "JS result should be 35");
    auto objVal = rt.globalScope.get("obj");
    assert(objVal.kind == JsKind.object, "JS obj should be an object");
    auto nameVal = rt.globalScope.get("obj"); // obj stored
    auto valueVal = rt.getProp(objVal, rt.makeString("value"));
    assert(valueVal.numValue == 35, "obj.value should be 35");

    // --- DOM binding smoke: document.getElementById ---
    auto jsDoc = bindDocument(page.root(), rt, rt.globalScope);
    auto docVal = jsDoc;
    auto idResult = rt.getProp(docVal, rt.makeString("getElementById"));
    assert(idResult.kind == JsKind.func, "document.getElementById should be a function");

    // Call getElementById("box") and check the wrapper exists.
    JsValue[] args;
    args ~= rt.makeString("box");
    auto boxWrapper = rt.callFunction(idResult, docVal, args);
    assert(boxWrapper.kind == JsKind.object, "getElementById should return an element");
    auto boxId = rt.getProp(boxWrapper, rt.makeString("id"));
    assert(boxId.strValue == "box", "Element id should be 'box'");

    writeln("auroraweb render smoke: ALL PASSED");
    return 0;
}

private Element findTag(Element root, string tag)
{
    if (root.tag == tag) return root;
    foreach (child; root.elements)
    {
        auto found = findTag(child, tag);
        if (found !is null) return found;
    }
    return null;
}

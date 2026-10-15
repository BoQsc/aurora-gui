module auroraweb;

/**
 * Aurora Web — a cross-platform web engine library built on Aurora-D.
 *
 * The public entry point is `WebPage`, which parses HTML and CSS, runs script,
 * lays out the document, and paints it into an Aurora `Surface`/`Canvas`.
 *
 * ```d
 * import auroraweb;
 *
 * auto page = new WebPage(1280, 800);
 * page.setHtml(htmlText);          // <style> and <script> are auto-extracted
 * page.layout();
 * page.paint(surface, 0, 0);
 * ```
 */

import aurora.canvas : Canvas;
import aurora.surface : Surface;
import auroraweb.css : parseStylesheet, Rule;
import auroraweb.dom : Element, TextNode;
import auroraweb.dombind : bindDocument, dispatchHostEvent, dispatchHostEventNoBubble,
    dispatchDocumentEvent, setDocumentScroll;

/// Hex digit value, or -1 for a non-hex character.
private static int hexDigit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decode standard base64, ignoring whitespace. Null on malformed input.
private static ubyte[] decodeBase64(string text)
{
    ubyte[] bytes;
    uint acc = 0;
    int bits = 0;
    foreach (c; text)
    {
        int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '+') v = 62;
        else if (c == '/') v = 63;
        else if (c == '=') break;                       // padding ends the data
        else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        else return null;
        acc = (acc << 6) | cast(uint) v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            bytes ~= cast(ubyte) ((acc >> bits) & 0xFF);
        }
    }
    return bytes;
}

/// Decode a `data:` URL into raw bytes (base64 or percent-encoded payload).
/// Returns null when `url` is not a decodable data URL.
private static ubyte[] decodeDataUrl(string url)
{
    if (url.length < 5 || url[0 .. 5].toLower() != "data:") return null;
    auto comma = url.indexOf(',');
    if (comma < 0) return null;
    const meta = url[5 .. comma];
    const payload = url[comma + 1 .. $];
    if (meta.length >= 7 && meta[$ - 7 .. $].toLower() == ";base64")
        return decodeBase64(payload);
    // Percent-encoded payload (no `;base64`).
    ubyte[] bytes;
    for (size_t i = 0; i < payload.length; ++i)
    {
        if (payload[i] == '%' && i + 2 < payload.length)
        {
            const hi = hexDigit(payload[i + 1]);
            const lo = hexDigit(payload[i + 2]);
            if (hi >= 0 && lo >= 0)
            {
                bytes ~= cast(ubyte) (hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        bytes ~= cast(ubyte) payload[i];
    }
    return bytes;
}

/// Parse the leading decimal number of `text` (0 when there is none).
private static double leadingNumber(string text)
{
    size_t i = 0;
    double value = 0.0;
    bool any = false;
    while (i < text.length && (text[i] == ' ' || text[i] == '\t')) ++i;
    while (i < text.length && text[i] >= '0' && text[i] <= '9')
    {
        value = value * 10.0 + (text[i] - '0');
        any = true;
        ++i;
    }
    if (i < text.length && text[i] == '.')
    {
        ++i;
        double scale = 0.1;
        while (i < text.length && text[i] >= '0' && text[i] <= '9')
        {
            value += (text[i] - '0') * scale;
            scale *= 0.1;
            any = true;
            ++i;
        }
    }
    return any ? value : 0.0;
}

/// Choose one URL from a `srcset` (`"a.png 1x, b.png 2x"`, `"s.jpg 480w, ..."`).
/// Picks the smallest candidate covering `layoutWidth` (width descriptors) or
/// 1x (density descriptors), else the largest available. "" when empty.
private static string pickSrcset(string srcset, int layoutWidth)
{
    string[] urls;
    double[] weights;
    bool[] widthBased;
    size_t start = 0;
    while (start <= srcset.length)
    {
        auto comma = srcset[start .. $].indexOf(',');
        auto piece = (comma < 0 ? srcset[start .. $] :
            srcset[start .. start + comma]).strip();
        start = (comma < 0) ? srcset.length + 1 : start + comma + 1;
        if (!piece.length) continue;
        auto sp = piece.indexOf(' ');
        auto url = (sp < 0) ? piece : piece[0 .. sp].strip();
        auto descriptor = (sp < 0) ? "" : piece[sp + 1 .. $].strip();
        if (!url.length) continue;
        double weight = 1.0;
        bool isWidth = false;
        if (descriptor.length)
        {
            const last = descriptor[$ - 1];
            if (last == 'w') { weight = leadingNumber(descriptor); isWidth = true; }
            else if (last == 'x') weight = leadingNumber(descriptor);
        }
        if (weight <= 0.0) weight = 1.0;
        urls ~= url;
        weights ~= weight;
        widthBased ~= isWidth;
    }
    if (!urls.length) return "";
    if (urls.length == 1) return urls[0];

    bool anyWidth = false;
    foreach (w; widthBased)
        if (w) anyWidth = true;
    const target = anyWidth ? cast(double) layoutWidth : 1.0;
    size_t best = 0;
    bool found = false;
    foreach (i, url; urls)
    {
        if (target > 0.0 && weights[i] >= target &&
            (!found || weights[i] < weights[best]))
        {
            best = i;
            found = true;
        }
    }
    if (!found)
        foreach (i, url; urls)
            if (weights[i] > weights[best]) best = i;
    return urls[best];
}

/// True for the simple media queries `<picture>` sources use in practice:
/// `(min-width: Npx)` / `(max-width: Npx)`. An unrecognised query does not
/// match — the same conservative rule the CSS filter uses for queries the
/// engine cannot evaluate.
private static bool matchesSimpleMedia(string query, int viewportWidth)
{
    auto q = query.strip().toLower();
    if (!q.length) return true;
    size_t pos = 0;
    while (pos < q.length)
    {
        auto open = q[pos .. $].indexOf('(');
        if (open < 0) break;
        open += pos;
        auto close = q[open .. $].indexOf(')');
        if (close < 0) return false;
        const expr = q[open + 1 .. open + close].strip();
        auto colon = expr.indexOf(':');
        if (colon < 0) return false;
        const name = expr[0 .. colon].strip();
        const px = leadingNumber(expr[colon + 1 .. $].strip());
        if (name == "min-width") { if (viewportWidth < px) return false; }
        else if (name == "max-width") { if (viewportWidth > px) return false; }
        else return false;
        pos = open + close + 1;
    }
    return true;
}

/// The URL an `<img>` should actually load: the first matching
/// `<picture><source>` (by media query), then its own `srcset`, then `src`.
private static string effectiveImageSrc(Element img, int viewportWidth)
{
    auto parent = img.parent;
    if (parent !is null && parent.tag == "picture")
    {
        foreach (child; parent.elements)
        {
            if (child.tag != "source") continue;
            auto ss = "srcset" in child.attrs;
            if (ss is null || (*ss).length == 0) continue;
            auto media = "media" in child.attrs;
            if (media !is null && (*media).length &&
                !matchesSimpleMedia(*media, viewportWidth)) continue;
            auto picked = pickSrcset(*ss, img.box.width);
            if (picked.length) return picked;
        }
    }
    auto own = "srcset" in img.attrs;
    if (own !is null && (*own).length)
    {
        auto picked = pickSrcset(*own, img.box.width);
        if (picked.length) return picked;
    }
    auto src = "src" in img.attrs;
    // HTML allows a URL attribute to wrap onto following lines; the value is
    // trimmed before use, so a wrapped `src` still resolves to a real URL.
    return src is null ? "" : (*src).strip();
}

unittest
{
    assert(decodeDataUrl("https://example.com/a.png") is null);
    assert(decodeDataUrl("data:image/png;base64,SGVsbG8=") == cast(ubyte[]) "Hello");
    assert(decodeDataUrl("data:text/plain,A%20B") == cast(ubyte[]) "A B");
    assert(decodeBase64("!!!!") is null, "malformed base64 must fail, not guess");
}

unittest
{
    // srcset/<picture> selection, checked through the resource loader so the
    // chosen candidate is observed exactly as the network layer sees it.
    string[] requested;
    ubyte[] tiny(string url) @safe
    {
        requested ~= url;
        ubyte[] bytes;
        foreach (ch; "P6\n1 1\n255\n") bytes ~= cast(ubyte) ch;
        foreach (v; [255, 0, 0]) bytes ~= cast(ubyte) v;
        return bytes;
    }

    assert(pickSrcset("a.png 1x, b.png 2x", 0) == "a.png", "1x wins at DPR 1");
    assert(pickSrcset("s.jpg 480w, l.jpg 1024w", 600) == "l.jpg",
        "the smallest candidate covering the layout width wins");
    assert(pickSrcset("s.jpg 480w, l.jpg 1024w", 100) == "s.jpg", "480w covers 100px");
    assert(pickSrcset("s.jpg 480w, l.jpg 1024w", 2000) == "l.jpg",
        "with nothing large enough, the largest is used");
    assert(pickSrcset("", 100) == "");
    assert(matchesSimpleMedia("(min-width: 900px)", 500) == false);
    assert(matchesSimpleMedia("(min-width: 900px)", 1000) == true);
    assert(matchesSimpleMedia("(max-width: 600px)", 500) == true);
    assert(matchesSimpleMedia("(orientation: landscape)", 500) == false,
        "an unevaluatable query must not match");

    auto page = new WebPage(800, 600);
    page.setResourceLoader(&tiny);
    page.setHtml(`<html><body><img id="i" style="width:300px" ` ~
        `srcset="small.png 200w, large.png 600w" src="fallback.png" /></body></html>`);
    page.layout();
    // Images load progressively (one per pass), so settle before asserting.
    foreach (settle; 0 .. 4) page.layout();
    assert(requested.length == 1, "exactly one candidate must be fetched");
    assert(requested[0].indexOf("large.png") >= 0,
        "600w must be chosen for a 300px box: " ~ requested[0]);

    requested = [];
    auto pic = new WebPage(500, 400);
    pic.setResourceLoader(&tiny);
    pic.setHtml(`<html><body><picture>` ~
        `<source media="(min-width: 900px)" srcset="wide.png" />` ~
        `<source srcset="mid.png" />` ~
        `<img id="p" src="fallback.png" /></picture></body></html>`);
    pic.layout();
    foreach (settle; 0 .. 4) pic.layout();
    assert(requested.length == 1, "exactly one picture source must be fetched");
    assert(requested[0].indexOf("mid.png") >= 0,
        "the first matching <source> wins: " ~ requested[0]);
}

unittest
{
    // A `data:` image decodes with no network access at all: build a 1x1 red
    // P6 PNM, percent-encode it, and check that <img> decodes it.
    import std.format : format;
    import aurora.image : RgbaImage;

    ubyte[] pnm = cast(ubyte[]) "P6\n1 1\n255\n";
    pnm ~= cast(ubyte[]) [255, 0, 0];
    string encoded;
    foreach (b; pnm)
        encoded ~= "%" ~ format("%02X", b);

    auto page = new WebPage(200, 100);
    page.setHtml(`<html><body><img id="p" src="data:image/x-portable-pixmap,` ~
        encoded ~ `" /></body></html>`);
    page.layout();

    Element imgEl;
    void walk(Element e)
    {
        auto id = "id" in e.attrs;
        if (id !is null && *id == "p") imgEl = e;
        foreach (c; e.elements) walk(c);
    }
    walk(page.root());
    assert(imgEl !is null, "data-URI <img> must exist");
    auto decoded = cast(RgbaImage) imgEl.image;
    assert(decoded !is null, "a data-URI image must be decoded");
    assert(decoded.width == 1 && decoded.height == 1, "decoded size must match");
    assert(imgEl.box.width == 1 && imgEl.box.height == 1,
        "intrinsic sizing must use the data-URI image");
}
import auroraweb.eventloop : EventLoop;
import auroraweb.html : parseHtml;
import auroraweb.js : JsRuntime, JsValue, JsKind, JsScope, Node, parseScript;
import auroraweb.layout : applyStylesAndLayout;
import auroraweb.net : HttpResponse, httpFetch, resolveUrl;
import auroraweb.interact : elementAt, hrefOf;
import auroraweb.paint : paintTree, fillCanvasBackground, canvasBackgroundColor,
    bodyPaintsBackground;

import std.string : indexOf, lastIndexOf, strip, startsWith, toLower;

/**
 * A single loaded web page: DOM, style, scripts, layout, and paint.
 */
final class WebPage
{
    Element _root;
    Rule[] _rules;
    JsRuntime _js;
    int _width;
    int _height;
    bool _documentBound;
    bool _layoutDirty = true;   /// Document/style/viewport changed since last layout.
    bool _imagesPending;        /// A layout pass deferred image fetches (see loadImages).
    int _laidOutWidth = -1;     /// Viewport width used by the most recent layout.
    int _laidOutHeight = -1;    /// Viewport height used by the most recent layout.
    int _layoutGen;             /// Bumped on every completed layout.
    Element _hoverEl;           /// Element under the pointer (drives `:hover`).
    Element _activeEl;          /// Element with the mouse button held (`:active`).
    Element _focusEl;           /// Focused control (drives `:focus`, key input).
    size_t _caret;              /// Caret offset inside the focused control's value.
    /// Resource loader callback: given a URL, return the raw bytes or null.
    /// Used for both <img> decoding and `fetchText`/`fetchBytes`/`fetch`.
    ubyte[] delegate(string url) @safe _resourceLoader;
    /// The URL of the document most recently loaded through `navigate()`.
    string _currentUrl;

    /// Global runtime (so scripts can be loaded incrementally).
    JsRuntime jsRuntime() { return _js; }

    /// Set a callback that loads a URL and returns the raw bytes (network
    /// layer). Feeds both image loading and the `fetch` global.
    void setResourceLoader(ubyte[] delegate(string url) @safe loader)
    {
        _resourceLoader = loader;
    }

    /// Backwards-compatible alias for `setResourceLoader` (kept for existing
    /// callers that used the image-oriented name).
    void setImageLoader(ubyte[] delegate(string url) @safe loader)
    {
        _resourceLoader = loader;
    }

    /// Fetch a URL and decode the response body as UTF-8 text. Returns an
    /// empty string on failure.
    string fetchText(string url)
    {
        auto bytes = fetchBytes(url);
        if (bytes.length == 0) return "";
        import std.utf : toUTF8;
        return toUTF8(cast(const(char)[]) bytes);
    }

    /// Fetch a URL and return the raw response bytes (empty on failure).
    ubyte[] fetchBytes(string url)
    {
        if (_resourceLoader !is null)
        {
            try
            {
                auto bytes = _resourceLoader(url);
                return bytes !is null ? bytes : (cast(ubyte[]) null);
            }
            catch (Exception exc)
            {
                return (cast(ubyte[]) null);
            }
        }
        auto res = httpFetch(url);
        if (res.error.length) return (cast(ubyte[]) null);
        return res.body;
    }

    /// Fetch a URL, and if the response looks like HTML (Content-Type
    /// text/html or the body starts with '<'), parse it as the new document
    /// and run any scripts, then re-layout. Sets `_currentUrl`.
    void navigate(string url)
    {
        _currentUrl = url;
        auto res = _resourceLoader !is null
            ? loaderResponse(url)
            : httpFetch(url);
        if (res.error.length || res.body.length == 0)
        {
            setHtml("<html><body><h1>Navigation failed</h1><p>" ~
                escapeHtml(res.error.length ? res.error
                    : "empty response from " ~ url) ~ "</p></body></html>");
            layout();
            return;
        }

        bool looksLikeHtml = false;
        auto ct = "content-type" in res.headers;
        if (ct !is null && (*ct).toLower().indexOf("text/html") >= 0)
            looksLikeHtml = true;
        if (!looksLikeHtml)
        {
            auto head = toLower(cast(string) res.body[0 .. res.body.length > 64
                ? 64 : res.body.length]);
            if (head.startsWith("<")) looksLikeHtml = true;
        }

        if (looksLikeHtml)
        {
            setHtml(toUTF8Decode(res.body));
            executeScripts();
            layout();
        }
    }

    /// The URL of the most recently navigated document ("" if none).
    string currentUrl() { return _currentUrl; }

    private HttpResponse loaderResponse(string url)
    {
        HttpResponse res;
        res.finalUrl = url;
        try
        {
            auto bytes = _resourceLoader(url);
            res.body = bytes !is null ? bytes : (cast(ubyte[]) null);
            res.status = res.body.length ? 200 : 0;
        }
        catch (Exception exc)
        {
            res.error = exc.msg;
        }
        return res;
    }

    private string escapeHtml(string s)
    {
        string result;
        foreach (ch; s)
        {
            switch (ch)
            {
                case '<': result ~= "&lt;"; break;
                case '>': result ~= "&gt;"; break;
                case '&': result ~= "&amp;"; break;
                default: result ~= ch; break;
            }
        }
        return result;
    }

    private string toUTF8Decode(ubyte[] bytes)
    {
        import std.utf : toUTF8;
        return toUTF8(cast(const(char)[]) bytes);
    }

    this(int width, int height)
    {
        _width = width;
        _height = height;
        _js = new JsRuntime();
    }

    /// Re-target the next `layout()` to a new viewport size.
    void resize(int width, int height)
    {
        const int w = width > 0 ? width : 1;
        const int h = height > 0 ? height : 1;
        if (w != _width || h != _height) _layoutDirty = true;
        _width = w;
        _height = h;
    }

    int width() { return _width; }
    int height() { return _height; }

    /// Parse HTML into the DOM, extracting <style> and <script> blocks.
    /// Scripts are collected but not executed until `executeScripts()` is
    /// called (after the DOM is bound).
    void setHtml(string html)
    {
        // A new document starts with a clean scheduler: no stale timers,
        // animation frames or microtasks leak across a navigation.
        resetEventLoop();
        _root = parseHtml(html);
        _layoutDirty = true;
        _rules = [];
        extractStyles();
        collectScripts();
        bindDocument(_root, _js, _js.globalScope, _resourceLoader);
        _documentBound = true;
    }

    /// Find all <style> elements and append their CSS.
    private void extractStyles()
    {
        if (_root is null) return;
        void walk(Element e)
        {
            if (e.tag == "style")
            {
                auto css = e.textContent();
                if (css.length)
                {
                    auto added = parseStylesheet(css);
                    // An inline block resolves its url() against the document.
                    absolutizeUrls(added, _currentUrl);
                    _rules ~= added;
                }
            }
            else if (e.tag == "link" && isStylesheetLink(e))
            {
                // An external stylesheet. Without this the document was styled
                // only by its inline <style> blocks, so any page whose CSS lives
                // in a linked file (most real pages) rendered largely unstyled.
                auto hrefAttr = "href" in e.attrs;
                const href = hrefAttr is null ? "" : (*hrefAttr).strip();
                if (href.length)
                {
                    string css;
                    try
                    {
                        if (href.length >= 5 && href[0 .. 5].toLower() == "data:")
                            css = toUTF8Decode(decodeDataUrl(href));
                        else
                        {
                            auto target = _currentUrl.length
                                ? resolveUrl(_currentUrl, href) : href;
                            css = toUTF8Decode(fetchBytes(target));
                        }
                    }
                    catch (Exception) css = "";
                    if (css.length)
                    {
                        auto added = parseStylesheet(css);
                        // A linked sheet resolves its url() against ITS OWN URL,
                        // not the document: `url(../img/x.png)` in /css/main.css
                        // must go to /img/x.png.
                        auto base = _currentUrl.length ? resolveUrl(_currentUrl, href) : href;
                        absolutizeUrls(added, base);
                        _rules ~= added;
                    }
                }
            }
            foreach (child; e.elements) walk(child);
        }
        walk(_root);
    }

    /// Serialise an element subtree back to markup, so the SVG rasteriser can
    /// read inline `<svg>` markup exactly as a standalone .svg file.
    private static string svgMarkup(Element root)
    {
        import auroraweb.dom : TextNode;
        import std.array : appender;
        auto sb = appender!string();
        void emit(Element n)
        {
            sb.put('<');
            sb.put(n.tag);
            foreach (k, v; n.attrs)
            {
                sb.put(' ');
                sb.put(k);
                sb.put(`="`);
                sb.put(v);
                sb.put('"');
            }
            sb.put('>');
            foreach (c; n.children)
            {
                auto t = cast(TextNode) c;
                if (t !is null)
                {
                    sb.put(t.data);
                    continue;
                }
                auto el = cast(Element) c;
                if (el !is null) emit(el);
            }
            sb.put("</");
            sb.put(n.tag);
            sb.put('>');
        }
        emit(root);
        return sb.data;
    }

    /// True when a <link> element carries a stylesheet relation.
    private static bool isStylesheetLink(Element e)
    {
        auto rel = "rel" in e.attrs;
        if (rel is null) return false;
        return toLower((*rel).strip()).indexOf("stylesheet") >= 0;
    }

    /// Rewrite relative `url(...)` references in these rules to absolute URLs,
    /// resolved against the stylesheet they came from. Without this a relative
    /// image URL inside an external stylesheet was resolved against the page,
    /// so `url(../img/x.png)` missed and the background rendered blank.
    private static void absolutizeUrls(Rule[] rules, string baseUrl)
    {
        if (!baseUrl.length) return;
        foreach (ref r; rules)
        {
            foreach (ref d; r.declarations)
            {
                const p = d.property;
                if (p != "background" && p != "background-image") continue;
                auto i = indexOf(toLower(d.value), "url(");
                if (i < 0) continue;
                auto j = indexOf(d.value, ")", i + 4);
                if (j < 0) continue;
                auto raw = d.value[i + 4 .. j].strip();
                if (raw.length >= 2 && (raw[0] == '"' || raw[0] == '\'') &&
                    raw[$ - 1] == raw[0])
                    raw = raw[1 .. $ - 1].strip();
                if (!raw.length || raw[0] == '#' || raw[0] == '/') continue;
                if (indexOf(raw, "://") >= 0) continue;
                if (raw.length >= 5 && toLower(raw[0 .. 5]) == "data:") continue;
                auto abs = resolveUrl(baseUrl, raw);
                abs = normalizeUrlPath(abs);
                if (abs.length && abs != raw)
                    d.value = d.value[0 .. i] ~ "url(" ~ abs ~ ")" ~ d.value[j + 1 .. $];
            }
        }
    }

    /// Collapse `.` and `..` path segments in a URL, leaving scheme, host and
    /// any query intact (`.../css/../img/x.png` -> `.../img/x.png`).
    private static string normalizeUrlPath(string url)
    {
        import std.array : split;
        auto schemeEnd = indexOf(url, "://");
        if (schemeEnd < 0) return url;
        auto slash = indexOf(url, "/", schemeEnd + 3);
        if (slash < 0) return url;
        const prefix = url[0 .. slash];
        auto path = url[slash .. $];
        const query = indexOf(path, "?");
        string suffix = "";
        if (query >= 0)
        {
            suffix = path[query .. $];
            path = path[0 .. query];
        }
        string[] keep;
        foreach (seg; path.split("/"))
        {
            if (seg == ".") continue;
            if (seg == "..")
            {
                if (keep.length) keep = keep[0 .. $ - 1];
                continue;
            }
            keep ~= seg;
        }
        auto joined = "";
        foreach (i, seg; keep)
        {
            if (i) joined ~= "/";
            joined ~= seg;
        }
        return prefix ~ joined ~ suffix;
    }

    /// Collect inline <script> content for execution.
    private string[] _pendingScripts;

    private void collectScripts()
    {
        _pendingScripts = [];
        if (_root is null) return;
        void walk(Element e)
        {
            if (e.tag == "script")
            {
                auto code = e.textContent();
                if (code.strip().length)
                    _pendingScripts ~= code;
            }
            foreach (child; e.elements) walk(child);
        }
        walk(_root);
    }

    /// Parse and execute all collected inline scripts in the page runtime.
    void executeScripts()
    {
        if (!_documentBound)
        {
            bindDocument(_root, _js, _js.globalScope, _resourceLoader);
            _documentBound = true;
        }
        foreach (code; _pendingScripts)
        {
            try
            {
                auto program = _js.parseInto(code);
                _js.runProgram(program, _js.makeObject());
            }
            catch (Exception exc)
            {
                // A page script the engine cannot parse or run must not abort
                // the whole navigation: keep the rendered document and go on.
            }
        }
        _pendingScripts = [];
        // Run queued microtasks (Promise/async continuations).
        try _js.pumpMicrotasks();
        catch (Exception exc) {}
        _layoutDirty = true; // scripts may have mutated the DOM
    }

    /// Parse CSS and append to the stylesheet. `baseUrl` is the address the CSS
    /// came from (a linked sheet's own URL, or the document for a <style>), used
    /// to resolve the sheet's relative url() references.
    void setStylesheet(string css, string baseUrl = "")
    {
        if (css.length)
        {
            auto added = parseStylesheet(css);
            absolutizeUrls(added, baseUrl.length ? baseUrl : _currentUrl);
            _rules ~= added;
            _layoutDirty = true;
        }
    }

    /// Parse and execute a script string in the page's runtime.
    void runScript(string source)
    {
        bindDocument(_root, _js, _js.globalScope, _resourceLoader);
        auto program = _js.parseInto(source);
        _js.runProgram(program, _js.makeObject());
        _js.pumpMicrotasks();
        _layoutDirty = true;
    }

    // -----------------------------------------------------------------------
    // Event loop (the browser's cross-platform scheduler)
    // -----------------------------------------------------------------------

    /// The page's event loop. It is owned by the JS runtime so `setTimeout`,
    /// `requestAnimationFrame` and Promise microtasks all share one scheduler
    /// and one clock. The host pumps it a tick at a time.
    EventLoop eventLoop()
    {
        return _js.eventLoop;
    }

    /// Install a fresh event loop and discard everything queued on the old one.
    /// Called automatically on `setHtml` so navigation cannot leak stale work.
    void resetEventLoop()
    {
        _js.eventLoop = new EventLoop();
    }

    /// Feed the loop a fresh monotonic time (ms) and run everything currently
    /// due: queued tasks, expired timers and microtask checkpoints. Returns
    /// true if any work ran, so the host can request a repaint. The host calls
    /// this once per frame/tick with its real clock.
    bool serviceEventLoop(double nowMs)
    {
        auto loop = _js.eventLoop;
        if (loop is null) return false;
        loop.setNow(nowMs);
        const bool ran = loop.runUntilIdle() > 0;
        // Script/timer work may have mutated the DOM: relayout on next paint.
        if (ran) _layoutDirty = true;
        return ran;
    }

    /// Run the "update the rendering" step: the queued animation-frame
    /// callbacks with `timestamp`, then any registered render callbacks.
    /// Returns true if a frame ran. The browser calls this once per repaint.
    bool serviceAnimationFrame(double timestamp)
    {
        auto loop = _js.eventLoop;
        if (loop is null) return false;
        const bool ran = loop.runFrame(timestamp);
        if (ran) _layoutDirty = true; // rAF callbacks commonly mutate the DOM
        return ran;
    }

    /// Whether the page still has pending timers, tasks or animation frames.
    bool hasPendingTasks()
    {
        auto loop = _js.eventLoop;
        return loop !is null && loop.hasPendingWork();
    }

    /// Whether an animation frame is waiting to run.
    bool animationFramePending()
    {
        auto loop = _js.eventLoop;
        return loop !is null && loop.framePending();
    }

    /// Re-layout after DOM/style mutation.
    void layout()
    {
        applyStylesAndLayout(_root, _rules, _width, _height);
        loadImages();
        _laidOutWidth = _width;
        _laidOutHeight = _height;
        // Images are fetched a few per pass, so a pass that deferred work leaves
        // the document dirty: the next paint loads more. Clearing this
        // unconditionally stranded every image after the first pass, which is
        // why a live browser showed none of them.
        _layoutDirty = _imagesPending;
        ++_layoutGen;
    }

    /// Monotonic counter bumped on each completed layout, so hosts can cache
    /// layout-derived values (content height, scroll metrics) per layout instead
    /// of recomputing them every frame.
    int layoutGeneration() const { return _layoutGen; }

    /// Lay out only when the document, style or viewport changed since the last
    /// layout. Paint calls this so an unchanged frame does no layout work.
    void layoutIfNeeded()
    {
        if (!_layoutDirty && _width == _laidOutWidth && _height == _laidOutHeight)
            return;
        layout();
    }

    /// Mark the document as needing a re-layout (DOM/style/JS mutation).
    void markLayoutDirty() { _layoutDirty = true; }

    /// True while the document still needs layout work — including images that
    /// load progressively — so a host keeps requesting frames until it settles.
    bool layoutPending() const { return _layoutDirty; }

    /// The CSS `color` an SVG inherits, so `fill="currentColor"` icons draw in
    /// the page's text colour instead of rasterising black and vanishing against
    /// a dark background — the usual form for toolbar and social icons.
    private auto svgInkColor(Element e)
    {
        import auroraweb.svg : svgCssColor;
        return svgCssColor(e is null ? "" : e.style.color);
    }

    /// Find <img> elements without a decoded image and load them, and decode
    /// any CSS `background-image: url("...")` references.
    private void loadImages()
    {
        _imagesPending = false;
        // Network images are fetched a few per layout pass. A page then becomes
        // visible as soon as its markup and styles are in, instead of waiting
        // for every (often large) image — the difference between a blank second
        // and an instant-feeling load. Local `data:` images are never budgeted.
        // The first layout of a document paints markup and styles only, so the
        // page is visible immediately; later passes fetch one image each and the
        // app repaints as they arrive. (A fresh budget per call would never load
        // an image at all, so this keys off the completed-layout count.)
        // Only the very first paint of the document skips network images (so the
        // page appears immediately). Every later pass fetches without limit, so
        // an image can never be stranded waiting for its turn.
        int networkFetchesLeft = _layoutGen > 0 ? int.max : 0;
        bool deferredFetch = false;
        void walk(Element e)
        {
            // Decide whether this element needs the network. Local work — a
            // `data:` image, inline SVG, or nothing to load — is never budgeted.
            bool needsNetwork = false;
            if (e.tag == "img" && e.image is null && !e.imageLoadTried)
            {
                auto candidate = effectiveImageSrc(e, _width);
                needsNetwork = candidate.length > 0 &&
                    !(candidate.length >= 5 && candidate[0 .. 5].toLower() == "data:");
            }
            else if (e.backgroundImage is null && !e.backgroundLoadTried &&
                e.style.backgroundImage.length > 4 &&
                e.style.backgroundImage[0 .. 4].toLower() == "url(")
            {
                needsNetwork = true;
            }

            // Once this pass's budget is spent, stop visiting: the remaining
            // elements stay untouched (so they are not marked as tried) and the
            // document is marked dirty so the next frame continues.
            if (needsNetwork)
            {
                if (networkFetchesLeft <= 0)
                {
                    deferredFetch = true;
                    _imagesPending = true;
                    _layoutDirty = true;
                    return;
                }
                networkFetchesLeft--;
            }
            // Inline <svg> markup — the shape most icon markup takes in HTML.
            // Serialise the subtree and let the engine's own rasteriser read it.
            if (e.tag == "svg" && e.image is null && !e.imageLoadTried)
            {
                e.imageLoadTried = true;
                try
                {
                    import auroraweb.svg : decodeSvg;
                    auto img = decodeSvg(cast(const(ubyte)[]) svgMarkup(e),
                        svgInkColor(e));
                    if (img !is null) e.image = img;
                }
                catch (Throwable)
                {
                    // Malformed icon markup must never take the browser down.
                }
                // A failure here can be an ordering problem rather than bad
                // markup (the inherited colour the SVG paints with is only known
                // once styles are resolved), so retry exactly once on the next
                // pass. Without this the element stayed 0x0 forever.
                if (e.image is null && !e.imageRetried)
                {
                    e.imageRetried = true;
                    e.imageLoadTried = false;
                    _imagesPending = true;
                    _layoutDirty = true;
                }
            }
            // <img src="...">
            if (e.tag == "img" && e.image is null && !e.imageLoadTried)
            {
                // `<picture>`/`srcset` selection picks the candidate for this
                // layout; a plain `src` is used when neither is present.
                auto srcAttr = "src" in e.attrs;
                // Once a chosen candidate has failed, fall back to the plain
                // `src` — what a browser does with <picture>/srcset.
                auto effective = e.imageFallbackTried && srcAttr !is null
                    ? (*srcAttr).strip() : effectiveImageSrc(e, _width);
                if (!effective.length)
                {
                    // Lazy-loading markup keeps the real URL in a data-*
                    // attribute and leaves `src` empty (or a transparent
                    // placeholder), so nothing was ever fetched and the image
                    // stayed blank across a large class of real pages.
                    foreach (attr; ["data-src", "data-lazy-src", "data-original",
                        "data-actualsrc", "data-image"])
                    {
                        auto v = attr in e.attrs;
                        if (v is null) continue;
                        auto t = (*v).strip();
                        if (t.length)
                        {
                            effective = t;
                            break;
                        }
                    }
                }
                if (effective.length)
                {
                    // Mark BEFORE fetching: a failing/absent URL must not be
                    // re-fetched on every layout (that repeated real network I/O
                    // once per frame while the image stayed unset).
                    e.imageLoadTried = true;
                    try
                    {
                        // `data:` URLs are decoded locally; everything else is
                        // fetched (resolution would mangle a data URL). A page
                        // created without a URL (`setHtml`) has no base to
                        // resolve against, so the relative URL is kept as-is
                        // rather than resolving to the empty string.
                        auto srcValue = effective;
                        auto target = _currentUrl.length
                            ? resolveUrl(_currentUrl, srcValue) : srcValue;
                        auto bytes = (srcValue.length >= 5 &&
                            srcValue[0 .. 5].toLower() == "data:") ?
                            decodeDataUrl(srcValue) :
                            fetchBytes(target);
                        // A candidate that returned nothing (404, unsupported
                        // format) must fall back to the plain `src`, like a
                        // browser, instead of leaving a blank image.
                        if (bytes.length == 0 && !e.imageFallbackTried &&
                            srcAttr !is null && (*srcAttr).strip().length)
                        {
                            e.imageFallbackTried = true;
                            e.imageLoadTried = false;
                            _imagesPending = true;
                            _layoutDirty = true;
                        }
                        if (bytes.length)
                        {
                            // Shared decoder: any supported format (PNG, JPEG,
                            // GIF, BMP, TGA, PNM, ...) plus the engine's own SVG
                            // rasteriser for the icon/artwork files real pages
                            // serve as SVG.
                            import aurora.image : decodeImage, RgbaImage;
                            import auroraweb.svg : looksLikeSvg, decodeSvg;
                            RgbaImage img;
                            try
                            {
                                if (looksLikeSvg(bytes))
                                    img = decodeSvg(bytes, svgInkColor(e));
                                else
                                    img = decodeImage(cast(const(ubyte)[]) bytes, srcValue);
                            }
                            // Throwable, not Exception: the SVG scanner runs on
                            // untrusted markup, and a malformed file must not be
                            // able to take the browser down.
                            catch (Throwable) img = null;
                            if (img is null && !e.imageFallbackTried &&
                                srcAttr !is null && (*srcAttr).strip().length)
                            {
                                // The selected candidate did not load or decode.
                                // Retry once with the fallback `src`, so an
                                // unsupported srcset entry does not leave a
                                // blank image where a browser would show one.
                                e.imageFallbackTried = true;
                                e.imageLoadTried = false;
                                _imagesPending = true;
                                _layoutDirty = true;
                            }
                            if (img !is null)
                            {
                                e.image = img;
                                // Default intrinsic size if no width/height given.
                                if (e.style.width == "auto")
                                    e.box.width = img.width;
                                if (e.style.height == "auto")
                                    e.box.height = img.height;
                            }
                        }
                    }
                    catch (Exception exc)
                    {
                        // Leave the placeholder box; loading errors are non-fatal.
                    }
                }
            }
            // CSS background-image: url("...")
            if (e.backgroundImage is null && !e.backgroundLoadTried &&
                e.style.backgroundImage.length > 4 &&
                e.style.backgroundImage[0 .. 4].toLower() == "url(")
            {
                auto url = urlFromBackgroundImage(e.style.backgroundImage);
                if (url.length)
                {
                    e.backgroundLoadTried = true;
                    try
                    {
                        auto bytes = (url.length >= 5 &&
                            url[0 .. 5].toLower() == "data:") ?
                            decodeDataUrl(url) :
                            fetchBytes(resolveUrl(_currentUrl, url));
                        if (bytes.length)
                        {
                            // Shared decoder so CSS background images work for
                            // every supported format plus SVG.
                            import aurora.image : decodeImage, RgbaImage;
                            import auroraweb.svg : looksLikeSvg, decodeSvg,
                                gradientToSvg;
                            RgbaImage img;
                            // A CSS gradient is real content: rasterise it by
                            // synthesising an SVG and reusing the SVG gradient
                            // code, sized to the element's content box.
                            import std.algorithm : max;
                            const auto grad = e.style.backgroundGradient;
                            if (e.backgroundImage is null && grad.length &&
                                grad != "none")
                            {
                                const int gw = max(1, e.box.width -
                                    e.box.paddingLeft - e.box.paddingRight);
                                const int gh = max(1, e.box.height -
                                    e.box.paddingTop - e.box.paddingBottom);
                                auto gsvg = gradientToSvg(grad, gw, gh);
                                if (gsvg.length)
                                {
                                    try img = decodeSvg(cast(const(ubyte)[]) gsvg,
                                        svgInkColor(e));
                                    catch (Throwable) img = null;
                                }
                            }
                            try
                            {
                                if (img is null && bytes.length)
                                {
                                    if (looksLikeSvg(bytes))
                                        img = decodeSvg(bytes, svgInkColor(e));
                                    else
                                        img = decodeImage(cast(const(ubyte)[]) bytes, url);
                                }
                            }
                            // See above: untrusted SVG markup must not crash.
                            catch (Throwable) img = null;
                            if (img !is null)
                                e.backgroundImage = img;
                        }
                    }
                    catch (Exception exc)
                    {
                        // Background loading errors are non-fatal; leave it unset.
                    }
                }
            }
            foreach (child; e.elements) walk(child);
        }
        if (_root !is null) walk(_root);
    }

    /// Extract the URL inside `url("...")`/`url('...')`/`url(...)`.
    private string urlFromBackgroundImage(string value)
    {
        const open = value.indexOf("(");
        const close = value.lastIndexOf(")");
        if (open < 0 || close <= open) return "";
        auto inner = value[open + 1 .. close].strip();
        if (inner.length >= 2 &&
            ((inner[0] == '"' && inner[$ - 1] == '"') ||
             (inner[0] == '\'' && inner[$ - 1] == '\'')))
            inner = inner[1 .. $ - 1];
        return inner.strip();
    }

    /// Whether the page paints its own canvas background, so the host can skip
    /// clearing to its default color first (that clear is fully overwritten).
    bool hasCanvasBackground()
    {
        return bodyPaintsBackground(_root);
    }

    // -----------------------------------------------------------------------
    // Host interaction: real mouse/keyboard input becomes DOM events, and
    // drives the `:hover` / `:active` / `:focus` state the CSS cascade reads.
    // -----------------------------------------------------------------------

    /// The topmost laid-out element at a page point (null when the page has no
    /// document yet).
    Element elementAtPoint(int x, int y)
    {
        return _root is null ? null : elementAt(_root, x, y);
    }

    private void setChainFlag(Element from, bool value, int which)
    {
        auto cur = from;
        while (cur !is null)
        {
            switch (which)
            {
                case 0: cur.hovered = value; break;
                case 1: cur.active = value; break;
                case 2: cur.focused = value; break;
                default: break;
            }
            cur = cur.parent;
        }
    }

    /// Move the pointer to a page point: updates `:hover` state and fires
    /// `mouseover`/`mouseout`/`mousemove`. Returns true when the styled state
    /// changed (the host should repaint).
    bool pointerMove(int x, int y)
    {
        if (_root is null) return false;
        auto target = elementAt(_root, x, y);
        if (target is _hoverEl)
        {
            dispatchHostEvent(_js, target, "mousemove");
            return false;
        }
        // `mouseenter`/`mouseleave` do not bubble: they fire for each element
        // whose hover state actually changed, i.e. the chains below the shared
        // ancestor of the old and new target.
        auto common = nearestSharedAncestor(_hoverEl, target);
        if (_hoverEl !is null)
        {
            dispatchHostEvent(_js, _hoverEl, "mouseout");
            for (auto e = _hoverEl; e !is null && e !is common; e = e.parent)
                dispatchHostEventNoBubble(_js, e, "mouseleave");
            setChainFlag(_hoverEl, false, 0);
        }
        setChainFlag(target, true, 0);
        _hoverEl = target;
        if (target !is null)
        {
            dispatchHostEvent(_js, target, "mouseover");
            for (auto e = target; e !is null && e !is common; e = e.parent)
                dispatchHostEventNoBubble(_js, e, "mouseenter");
        }
        _layoutDirty = true;
        return true;
    }

    /// The deepest element reachable from both `a` and `b` (null when none).
    private static Element nearestSharedAncestor(Element a, Element b)
    {
        for (auto x = a; x !is null; x = x.parent)
            for (auto y = b; y !is null; y = y.parent)
                if (x is y) return x;
        return null;
    }

    /// The element the pointer is currently over (null when none).
    Element hoveredElement() { return _hoverEl; }

    /// The element with focus (null when none).
    Element focusedElement() { return _focusEl; }

    /// A full click at a page point: `mousedown`, `mouseup`, `click`, with an
    /// `:active` flicker. Returns the `href` to navigate to — "" when the point
    /// is not inside a link, or a handler called `preventDefault()`.
    string click(int x, int y)
    {
        if (_root is null) return "";
        auto target = elementAt(_root, x, y);
        if (target is null) return "";

        focusAt(x, y);

        // Checkable controls toggle on click, then fire input/change.
        auto inputType = "type" in target.attrs;
        if (target.tag == "input" && inputType !is null)
        {
            const kind = (*inputType).toLower();
            if (kind == "checkbox")
            {
                if (("checked" in target.attrs) !is null) target.attrs.remove("checked");
                else target.attrs["checked"] = "";
                dispatchHostEvent(_js, target, "input");
                dispatchHostEvent(_js, target, "change");
                _layoutDirty = true;
            }
            else if (kind == "radio")
            {
                // Exactly one radio per `name` group stays checked.
                auto nameAttr = "name" in target.attrs;
                if (nameAttr !is null)
                {
                    void clear(Element e)
                    {
                        auto t = "type" in e.attrs;
                        auto n = "name" in e.attrs;
                        if (e.tag == "input" && t !is null && n !is null &&
                            (*t).toLower() == "radio" && *n == *nameAttr)
                            e.attrs.remove("checked");
                        foreach (c; e.elements) clear(c);
                    }
                    if (_root !is null) clear(_root);
                }
                target.attrs["checked"] = "";
                dispatchHostEvent(_js, target, "input");
                dispatchHostEvent(_js, target, "change");
                _layoutDirty = true;
            }
        }

        setChainFlag(target, true, 1);
        _activeEl = target;
        _layoutDirty = true;
        bool prevented = dispatchHostEvent(_js, target, "mousedown");
        setChainFlag(target, false, 1);
        _activeEl = null;
        prevented = dispatchHostEvent(_js, target, "mouseup") || prevented;
        prevented = dispatchHostEvent(_js, target, "click") || prevented;
        _layoutDirty = true;
        if (prevented) return "";
        return hrefOf(target);
    }

    /// True when `element` (or an ancestor) is a focusable control.
    private static bool isFocusable(Element e)
    {
        if (e is null) return false;
        switch (e.tag)
        {
            case "input", "textarea", "select", "button", "summary":
                return true;
            default:
                break;
        }
        if ("contenteditable" in e.attrs) return true;
        if ("tabindex" in e.attrs) return true;
        return e.tag == "a" && ("href" in e.attrs) !is null;
    }

    private static Element focusableFrom(Element e)
    {
        auto cur = e;
        while (cur !is null)
        {
            if (isFocusable(cur)) return cur;
            cur = cur.parent;
        }
        return null;
    }

    /// Focus the focusable control at a page point (drives `:focus` and routes
    /// subsequent key/text input). Returns true when something is focused.
    bool focusAt(int x, int y)
    {
        if (_root is null) return false;
        return setFocus(elementAt(_root, x, y));
    }

    /// Focus `target` (or its nearest focusable ancestor); null blurs.
    bool setFocus(Element target)
    {
        auto focusable = focusableFrom(target);
        if (focusable is _focusEl) return focusable !is null;
        if (_focusEl !is null)
        {
            dispatchHostEvent(_js, _focusEl, "blur");
            setChainFlag(_focusEl, false, 2);
        }
        _focusEl = focusable;
        if (focusable !is null)
        {
            setChainFlag(focusable, true, 2);
            dispatchHostEvent(_js, focusable, "focus");
        }
        // A fresh control starts with the caret at the end of its value.
        _caret = focusable is null ? 0 : controlValue(focusable).length;
        if (focusable !is null) focusable.caret = _caret;
        _layoutDirty = true;
        return focusable !is null;
    }

    /// The caret offset inside the focused control (for hosts/tests).
    size_t caretIndex() const { return _caret; }

    /// All focusable controls in document order (Tab traversal order).
    private Element[] focusables()
    {
        Element[] list;
        if (_root is null) return list;
        void walk(Element e)
        {
            if (isFocusable(e)) list ~= e;
            foreach (c; e.elements) walk(c);
        }
        walk(_root);
        return list;
    }

    /// Move focus `dir` steps through the focusable controls (Tab/Shift+Tab).
    private void moveFocus(int dir)
    {
        auto list = focusables();
        if (list.length == 0) { setFocus(null); return; }
        ptrdiff_t cur = -1;
        foreach (i, e; list)
            if (e is _focusEl) { cur = cast(ptrdiff_t) i; break; }
        const n = cast(ptrdiff_t) list.length;
        ptrdiff_t next = (cur < 0) ? (dir > 0 ? 0 : n - 1) : ((cur + dir) % n + n) % n;
        setFocus(list[cast(size_t) next]);
    }

    /// The current `value` of an editable control ("" for others).
    private static string controlValue(Element e)
    {
        auto v = "value" in e.attrs;
        return v is null ? "" : *v;
    }

    /// Insert text into the focused editable control (fires `input`).
    private void typeText(string text)
    {
        auto el = _focusEl;
        if (el is null || text.length == 0) return;
        if (el.tag != "input" && el.tag != "textarea" && !("contenteditable" in el.attrs))
            return;
        // Insert at the caret, like real typing.
        auto cur = controlValue(el);
        if (_caret > cur.length) _caret = cur.length;
        el.attrs["value"] = cur[0 .. _caret] ~ text ~ cur[_caret .. $];
        _caret += text.length;
        el.caret = _caret;
        dispatchHostEvent(_js, el, "input");
        _layoutDirty = true;
    }

    /// Send a key to the focused control: fires `keydown`, inserts printable
    /// characters (Backspace deletes), fires `keyup`. Returns true if handled.
    bool sendKey(string key)
    {
        auto el = _focusEl;
        if (el is null || key.length == 0) return false;
        const prevented = dispatchHostEvent(_js, el, "keydown", key);
        if (!prevented)
        {
            auto typeAttr = "type" in el.attrs;
            const kind = (el.tag == "input" && typeAttr !is null) ?
                (*typeAttr).toLower() : "";
            // Keys that act on the control itself rather than its text.
            if (key == "Tab" || key == "Shift+Tab")
            {
                moveFocus(key == "Tab" ? 1 : -1);
            }
            else if ((key == "Enter" || key == " ") &&
                (el.tag == "button" || el.tag == "summary" || kind == "checkbox" ||
                 kind == "radio" || kind == "submit"))
            {
                // Buttons/checkboxes activate on Enter or Space.
                click(el.box.x + 1, el.box.y + 1);
            }
            else if (key == "Backspace")
            {
                auto cur = controlValue(el);
                if (_caret > cur.length) _caret = cur.length;
                if (_caret > 0)
                {
                    el.attrs["value"] = cur[0 .. _caret - 1] ~ cur[_caret .. $];
                    --_caret;
                    dispatchHostEvent(_js, el, "input");
                    _layoutDirty = true;
                }
            }
            else if (key == "Delete")
            {
                auto cur = controlValue(el);
                if (_caret < cur.length)
                {
                    el.attrs["value"] = cur[0 .. _caret] ~ cur[_caret + 1 .. $];
                    dispatchHostEvent(_js, el, "input");
                    _layoutDirty = true;
                }
            }
            else if (key == "ArrowLeft")
            {
                if (_caret > controlValue(el).length) _caret = controlValue(el).length;
                if (_caret > 0) --_caret;
            }
            else if (key == "ArrowRight")
            {
                if (_caret < controlValue(el).length) ++_caret;
            }
            else if (key == "Home") _caret = 0;
            else if (key == "End") _caret = controlValue(el).length;
            else if (key.length == 1)
                typeText(key);
            else if (key == "Enter")
            {
                // Enter on a form control submits its form, like a browser.
                auto form = el;
                while (form !is null && form.tag != "form") form = form.parent;
                if (form !is null)
                {
                    dispatchHostEvent(_js, form, "submit");
                    _layoutDirty = true;
                }
            }
            el.caret = _caret;
        }
        dispatchHostEvent(_js, el, "keyup", key);
        return true;
    }

    /// Dispatch a `dblclick` at a page point (the second click of a double
    /// click). The event bubbles, like a browser's.
    bool doubleClick(int x, int y)
    {
        if (_root is null) return false;
        auto target = elementAt(_root, x, y);
        if (target is null) return false;
        return dispatchHostEvent(_js, target, "dblclick");
    }

    /// Dispatch a `contextmenu` at a page point (right click). Returns true when
    /// a handler cancelled it, i.e. the host should not show its own menu.
    bool contextMenu(int x, int y)
    {
        if (_root is null) return false;
        auto target = elementAt(_root, x, y);
        if (target is null) return false;
        return dispatchHostEvent(_js, target, "contextmenu");
    }

    /// Dispatch a `wheel` event at a page point (host scroll input). The event
    /// bubbles, so any handler on the chain may cancel it. Returns true when a
    /// handler called `preventDefault()` — the host must then not scroll.
    bool wheel(int x, int y, int deltaY)
    {
        if (_root is null || deltaY == 0) return false;
        auto target = elementAt(_root, x, y);
        if (target is null) return false;
        return dispatchHostEvent(_js, target, "wheel", deltaY);
    }

    /// Tell the page the viewport scrolled: publishes `window.scrollY` /
    /// `document.documentElement.scrollTop` and fires `scroll` on the document
    /// and window, where scrolling pages actually attach their listeners.
    void notifyScroll(int scrollY)
    {
        setDocumentScroll(_js, scrollY);
        dispatchDocumentEvent(_js, "scroll");
    }

    /// Paint the document into a canvas at the given offset.
    void paint(Canvas canvas, int offsetX, int offsetY)
    {
        // Only relayout when the document changed: an unchanged frame is a pure
        // re-draw of boxes already computed by the last layout.
        layoutIfNeeded();
        fillCanvasBackground(canvas, _root, _width, _height);
        paintTree(_root, canvas);
    }

    /// Paint into a surface at (0,0).
    void paint(Surface surface)
    {
        auto canvas = Canvas(surface);
        paint(canvas, 0, 0);
    }

    Element root() { return _root; }
    Rule[] rules() { return _rules; }
}

unittest
{
    // Host interaction: a real click runs the element's inline `onclick`,
    // `:hover` follows the pointer, and typing reaches a focused control.
    // (These are the behaviours the browser shell drives for real input.)
    auto page = new WebPage(800, 600);
    page.setHtml(`<html><body>
        <div class="btn" id="b" onclick='this.setAttribute("data-hit","yes")'>hit</div>
        <input id="i" value="" /><input id="j" value="" />
        <input id="c" type="checkbox" />
        <button id="b2" onclick='this.setAttribute("clicked","yes")'>Go</button>
        </body></html>`);
    page.setStylesheet(
        ".btn { font-size: 10px; } "
        ~ ".btn:hover { font-size: 20px; } "
        ~ "input:focus { font-size: 22px; }");
    page.executeScripts();
    page.layout();

    Element findId(Element e, string id)
    {
        auto it = "id" in e.attrs;
        if (it !is null && *it == id) return e;
        foreach (c; e.elements)
        {
            auto r = findId(c, id);
            if (r !is null) return r;
        }
        return null;
    }

    auto b = findId(page.root(), "b");
    auto field = findId(page.root(), "i");
    assert(b !is null && field !is null, "test elements must exist");

    // Hit-testing finds the element; clicking runs its inline handler.
    assert(page.elementAtPoint(b.box.x + 1, b.box.y + 1) is b);
    page.click(b.box.x + 1, b.box.y + 1);
    assert(("data-hit" in b.attrs) !is null,
        "a host click must run the inline onclick handler");

    // `:hover` follows the pointer and clears when it leaves.
    assert(page.pointerMove(b.box.x + 1, b.box.y + 1));
    page.layout();
    assert(b.style.fontSizePx == 20, ":hover must apply to the hovered element");
    page.pointerMove(795, 595);
    page.layout();
    assert(b.style.fontSizePx == 10, ":hover must clear when the pointer leaves");

    // Focus + typing.
    page.click(field.box.x + 1, field.box.y + 1);
    assert(page.focusedElement() is field, "clicking an input focuses it");
    page.layout();
    assert(field.style.fontSizePx == 22, ":focus must apply");
    page.sendKey("H");
    page.sendKey("i");
    assert(field.attrs.get("value", "") == "Hi", "typing must reach the input");
    page.sendKey("Backspace");
    assert(field.attrs.get("value", "") == "H", "Backspace must delete");

    // Caret-aware editing: arrows move the caret and typing inserts there.
    page.sendKey("ArrowLeft");
    page.sendKey("X");
    assert(field.attrs.get("value", "") == "XH",
        "ArrowLeft then typing must insert before the last character");
    page.sendKey("Home");
    page.sendKey("Z");
    assert(field.attrs.get("value", "") == "ZXH", "Home must move the caret");
    assert(page.caretIndex() == 1, "caret must track the insertion point");
    page.sendKey("Delete");
    assert(field.attrs.get("value", "") == "ZH", "Delete must remove at the caret");

    // Tab traverses the focusable controls in document order.
    auto second = findId(page.root(), "j");
    page.setFocus(field);
    page.sendKey("Tab");
    assert(page.focusedElement() is second, "Tab must move focus to the next control");
    page.sendKey("Shift+Tab");
    assert(page.focusedElement() is field, "Shift+Tab must move focus back");

    // Checkable controls toggle on click.
    auto box = findId(page.root(), "c");
    assert(box !is null);
    page.click(box.box.x + 1, box.box.y + 1);
    assert(("checked" in box.attrs) !is null, "clicking a checkbox must check it");
    page.click(box.box.x + 1, box.box.y + 1);
    assert(("checked" in box.attrs) is null, "clicking again must uncheck it");

    // Space activates a focused button.
    auto btn2 = findId(page.root(), "b2");
    assert(btn2 !is null);
    page.setFocus(btn2);
    page.sendKey(" ");
    assert(("clicked" in btn2.attrs) !is null, "Space must activate the focused button");

    // Wheel events reach page handlers, which may cancel the host scroll.
    auto spun = new WebPage(300, 200);
    spun.setHtml(`<html><body><div id="w" onwheel='this.setAttribute("spun","1")'>a</div>`
        ~ `<div id="wc" onwheel='event.preventDefault(); this.setAttribute("spun","1")'>b</div>`
        ~ `</body></html>`);
    spun.layout();
    auto wEl = findId(spun.root(), "w");
    auto wcEl = findId(spun.root(), "wc");
    assert(wEl !is null && wcEl !is null, "wheel targets must exist");
    assert(!spun.wheel(wEl.box.x + 1, wEl.box.y + 1, -120),
        "a wheel handler that does not preventDefault must not cancel scrolling");
    assert(("spun" in wEl.attrs) !is null, "onwheel must run");
    assert(spun.wheel(wcEl.box.x + 1, wcEl.box.y + 1, -120),
        "preventDefault in onwheel must cancel the host scroll");

    // Double click and right click reach page handlers; contextmenu cancels.
    auto clicks = new WebPage(300, 200);
    clicks.setHtml(`<html><body><div id="d" ondblclick='this.setAttribute("dbl","1")'>d</div>`
        ~ `<div id="r" oncontextmenu='event.preventDefault(); this.setAttribute("menu","1")'>r</div>`
        ~ `</body></html>`);
    clicks.layout();
    auto dEl = findId(clicks.root(), "d");
    auto rEl = findId(clicks.root(), "r");
    assert(dEl !is null && rEl !is null, "click targets must exist");
    clicks.doubleClick(dEl.box.x + 1, dEl.box.y + 1);
    assert(("dbl" in dEl.attrs) !is null, "ondblclick must run");
    assert(clicks.contextMenu(rEl.box.x + 1, rEl.box.y + 1),
        "preventDefault in oncontextmenu must cancel the host menu");
    assert(("menu" in rEl.attrs) !is null, "oncontextmenu must run");

    // mouseenter/mouseleave do not bubble: they fire only for the chains whose
    // hover changed, never for a shared ancestor.
    auto hov = new WebPage(400, 300);
    hov.setHtml(`<html><body><div id="outer" style="width:200px;height:100px"` ~
        ` onmouseenter='this.setAttribute("in","1")'` ~
        ` onmouseleave='this.setAttribute("out","1")'>` ~
        `<div id="a" style="height:30px">a</div><div id="b" style="height:30px">b</div>` ~
        `</div></body></html>`);
    hov.layout();
    auto outerEl = findId(hov.root(), "outer");
    auto aEl = findId(hov.root(), "a");
    auto bEl = findId(hov.root(), "b");
    assert(outerEl !is null && aEl !is null && bEl !is null);
    hov.pointerMove(aEl.box.x + 1, aEl.box.y + 1);
    assert(("in" in outerEl.attrs) !is null,
        "entering the subtree must fire mouseenter on the ancestor");
    assert(("out" in outerEl.attrs) is null, "mouseleave must not fire on entering");
    hov.pointerMove(bEl.box.x + 1, bEl.box.y + 1);
    assert(("out" in outerEl.attrs) is null,
        "moving between children of one parent must not fire mouseleave on it");
    hov.pointerMove(390, 290);
    assert(("out" in outerEl.attrs) !is null,
        "leaving the subtree must fire mouseleave on the ancestor");

    // Scroll events reach document and window listeners, and the page can read
    // the viewport offset through window.scrollY.
    auto sc = new WebPage(300, 200);
    sc.setHtml(`<html><body><p id="s">0</p><div id="t"></div></body></html>`);
    sc.runScript(`document.addEventListener('scroll', function(){` ~
        `document.getElementById('s').textContent = String(window.scrollY); });` ~
        `window.addEventListener('scroll', function(){` ~
        `document.getElementById('t').setAttribute('win','1'); });`);
    sc.notifyScroll(120);
    auto sEl = findId(sc.root(), "s");
    auto tEl = findId(sc.root(), "t");
    assert(sEl !is null && tEl !is null, "scroll listeners must have targets");
    import std.conv : to;
    assert(sEl.textNodes.length && sEl.textNodes[0].data == "120",
        "a document scroll listener must see window.scrollY; got " ~
        (sEl.textNodes.length ? sEl.textNodes[0].data : "<no text node>") ~
        " nodeCount=" ~ to!string(sEl.textNodes.length) ~
        " winAttr=" ~ to!string(("win" in tEl.attrs) !is null));
    assert(("win" in tEl.attrs) !is null, "a window scroll listener must run");

    // Borders take no space without a visible style, and `inset` is the modern
    // top/right/bottom/left shorthand.
    auto bp = new WebPage(400, 300);
    bp.setHtml(`<html><body>` ~
        `<div id="styled" style="border: 1px solid red; width: 50px; height: 20px"></div>` ~
        `<div id="nostyle" style="border-width: 2px; border-style: none; width: 50px; height: 20px"></div>` ~
        `<div id="box" style="position: relative; width: 200px; height: 100px">` ~
        `<div id="child" style="position: absolute; inset: 10px; width: 20px; height: 20px"></div>` ~
        `</div></body></html>`);
    bp.layout();
    auto styled = findId(bp.root(), "styled");
    auto nostyle = findId(bp.root(), "nostyle");
    auto boxEl = findId(bp.root(), "box");
    auto child = findId(bp.root(), "child");
    assert(styled !is null && nostyle !is null && boxEl !is null && child !is null,
        "border/inset fixture elements must exist");
    assert(styled.box.borderTop == 1 && styled.box.borderLeft == 1,
        "a solid border must keep its width");
    assert(nostyle.box.borderTop == 0 && nostyle.box.borderLeft == 0,
        "border-style: none must remove the border width");
    assert(child.box.x == boxEl.box.x + 10 && child.box.y == boxEl.box.y + 10,
        "inset: 10px must place an absolute child 10px inside its containing block");

    // Percentage heights resolve against a definite containing-block height.
    auto pct = new WebPage(400, 400);
    pct.setHtml(`<html><body><div id="outer" style="height:200px">` ~
        `<div id="inner" style="height:50%"></div></div></body></html>`);
    pct.layout();
    auto pctOuter = findId(pct.root(), "outer");
    auto pctInner = findId(pct.root(), "inner");
    assert(pctOuter !is null && pctInner !is null, "percentage-height fixture must exist");
    assert(pctInner.box.height == 100,
        "height:50% must resolve against the parent's definite height");

    // Unitless zero lengths: `margin: 0` must be 0, never stored as a real -1px
    // margin (a -1 dragged every such element one pixel up and left, and the
    // error accumulated through nested blocks).
    auto z0p = new WebPage(300, 200);
    z0p.setHtml(`<html><body>` ~
        `<div id="z0b" style="margin: 0; padding: 0; width: 40px; height: 10px"></div>` ~
        `<div id="z0a" style="position:absolute; top: 0; left: 0; width: 5px; height: 5px"></div>` ~
        `</body></html>`);
    z0p.layout();
    auto z0b = findId(z0p.root(), "z0b");
    auto z0a = findId(z0p.root(), "z0a");
    assert(z0b !is null && z0a !is null, "unitless-zero fixture must exist");
    assert(z0b.box.marginLeft == 0 && z0b.box.marginTop == 0 && z0b.box.paddingLeft == 0,
        "unitless zero must resolve to 0");
    assert(z0b.box.y == 0, "a block with margin:0 must start at the flow origin");
    assert(z0a.box.x == 0 && z0a.box.y == 0,
        "unitless top:0/left:0 must place an absolute box at the containing block origin");

    // Physical and typographic units must resolve to a length, not collapse to
    // the resolver's "not a length" value (-1), which a margin stored as -1px.
    auto un = new WebPage(300, 200);
    un.setHtml(`<html><body><div id="un0" style="margin-top: 12pt; padding-left: 1pc;` ~
        ` width: 20px; height: 10px"></div></body></html>`);
    un.layout();
    auto un0 = findId(un.root(), "un0");
    assert(un0 !is null, "physical-unit fixture must exist");
    assert(un0.box.marginTop == 16, "12pt must resolve to 16px");
    assert(un0.box.paddingLeft == 16, "1pc must resolve to 16px");

    // `clear` drops a block below the floats it clears (CSS 9.5.2).
    auto cl = new WebPage(300, 200);
    cl.setHtml(`<html><body><div id="clWrap">` ~
        `<div id="clFloat" style="float:left; width:20px; height:20px"></div>` ~
        `<div id="clYes" style="clear:left; height:10px"></div>` ~
        `</div></body></html>`);
    cl.layout();
    auto clWrap = findId(cl.root(), "clWrap");
    auto clFloat = findId(cl.root(), "clFloat");
    auto clYes = findId(cl.root(), "clYes");
    assert(clWrap !is null && clFloat !is null && clYes !is null,
        "clear fixture must exist");
    assert(clYes.box.y >= clFloat.box.y + clFloat.box.height,
        "clear:left must move the block below the float");

    // The `background` shorthand must keep its image, not just the colour:
    // real pages declare `background: url(...) center/cover` and used to render
    // with no background image at all.
    {
        auto bgp = new WebPage(200, 100);
        bgp.setHtml(`<html><body><div id="bgsh"` ~
            ` style="background: url(hero.png) center/cover no-repeat"></div></body></html>`);
        bgp.layout();
        auto bgsh = findId(bgp.root(), "bgsh");
        assert(bgsh !is null, "background-shorthand fixture must exist");
        assert(bgsh.style.backgroundImage == "url(hero.png)",
            "the background shorthand must keep its url(); got '" ~
            bgsh.style.backgroundImage ~ "'");
    }

    // An external stylesheet (link rel=stylesheet) must be fetched and applied,
    // not just inline <style> blocks.
    {
        auto lnk = new WebPage(200, 100);
        lnk.setHtml(`<html><head>` ~
            `<link rel="stylesheet" href="data:text/css,body%7Bbackground-color:%23001122%7D">` ~
            `</head><body><div id="styled"></div></body></html>`);
        lnk.layout();
        assert(lnk.root().style.background == "#001122" ||
            lnk.root().style.background.indexOf("001122") >= 0,
            "a linked stylesheet must be fetched and applied; body background was '" ~
            lnk.root().style.background ~ "'");
    }

    // A stylesheet's relative url() must resolve against the SHEET, not the
    // document: `url(../img/x.png)` in /css/main.css reaches /img/x.png.
    {
        auto rel = new WebPage(200, 100);
        rel.setHtml(`<html><body><div id="bgr"></div></body></html>`);
        rel.setStylesheet(`#bgr { background: url(../img/x.png) no-repeat; }`,
            "https://example.com/css/main.css");
        rel.layout();
        auto bgr = findId(rel.root(), "bgr");
        assert(bgr !is null, "stylesheet-relative fixture must exist");
        assert(bgr.style.backgroundImage == "url(https://example.com/img/x.png)",
            "a stylesheet-relative url() must resolve against the sheet; got '" ~
            bgr.style.backgroundImage ~ "'");
    }

    // A lazy-loaded <img> keeps its URL in data-src with an empty src; that URL
    // must still be fetched, or the image renders blank.
    {
        auto lz = new WebPage(200, 100);
        lz.setHtml(`<html><body><img id="lzi" data-src="data:image/png;base64,` ~
            `iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA` ~
            `hKmMIQAAAABJRU5ErkJggg=="></body></html>`);
        lz.layout();
        auto lzi = findId(lz.root(), "lzi");
        assert(lzi !is null, "lazy-load fixture must exist");
        assert(lzi.image !is null, "a data-src image must be fetched and decoded");
    }

    // Inline <svg> markup must be rasterised like an <img>, including intrinsic
    // sizing from its width/height attributes.
    {
        auto isvg = new WebPage(200, 100);
        isvg.setHtml(`<html><body><svg id="ivi" width="8" height="8">` ~
            `<rect width="8" height="8" fill="#ff0000"/></svg></body></html>`);
        isvg.layout();
        // The image is decoded during layout, so the intrinsic size lands on
        // the following pass — exactly as it does for <img>.
        isvg.layout();
        auto ivi = findId(isvg.root(), "ivi");
        assert(ivi !is null, "inline svg fixture must exist");
        assert(ivi.image !is null, "inline <svg> markup must be rasterised");
        assert(ivi.box.width == 8 && ivi.box.height == 8,
            "an inline svg needs intrinsic sizing; got " ~ to!string(ivi.box.width) ~
            "x" ~ to!string(ivi.box.height));
    }

    // Protocol-relative URLs must keep the base's scheme: `//host/x.png` is a
    // host-qualified reference, not a path. Treating it as a path made those
    // images 404 (they resolved to https://currenthost//host/x.png).
    assert(resolveUrl("https://a.example/dir/page.html", "//cdn.example/i.png") ==
        "https://cdn.example/i.png", "protocol-relative keeps the https scheme");
    assert(resolveUrl("http://a.example/dir/page.html", "//cdn.example/i.png") ==
        "http://cdn.example/i.png", "protocol-relative keeps the http scheme");
    // Sanity: ordinary relative and root-relative forms still behave.
    assert(resolveUrl("https://a.example/dir/page.html", "img/x.png") ==
        "https://a.example/dir/img/x.png", "a relative path resolves in place");
    assert(resolveUrl("https://a.example/dir/page.html", "/img/x.png") ==
        "https://a.example/img/x.png", "a root-relative path replaces the path");

    // A srcset candidate that fails to load must fall back to the plain `src`,
    // exactly as a browser does with <picture>/srcset.
    {
        static ubyte[] selective(string url)
        {
            if (indexOf(url, "missing.png") >= 0) return null;
            ubyte[] bytes;
            foreach (ch; "P6\n1 1\n255\n") bytes ~= cast(ubyte) ch;
            foreach (v; [0, 255, 0]) bytes ~= cast(ubyte) v;
            return bytes;
        }
        auto fallbackPage = new WebPage(400, 300);
        fallbackPage.setResourceLoader((string url) @safe { return selective(url); });
        fallbackPage.setHtml(`<html><body><img id="fb" srcset="missing.png 1x" ` ~
            `src="good.png" /></body></html>`);
        foreach (pass; 0 .. 8) fallbackPage.layout();
        auto fb = findId(fallbackPage.root(), "fb");
        assert(fb !is null, "fallback fixture must exist");
        assert(fb.image !is null,
            "a failed srcset candidate must fall back to the plain src");
    }

    // Progressive image loading must leave the document dirty until every image
    // is in. Otherwise a host paints once, sees a clean document, and never
    // fetches the rest — the live browser showed no images at all.
    {
        static ubyte[] oneAtATime(string url)
        {
            ubyte[] bytes;
            foreach (ch; "P6\n1 1\n255\n") bytes ~= cast(ubyte) ch;
            foreach (v; [10, 20, 30]) bytes ~= cast(ubyte) v;
            return bytes;
        }
        static string[] asked;
        asked = [];
        auto prog = new WebPage(400, 300);
        prog.setResourceLoader((string url) @safe { asked ~= url; return oneAtATime(url); });
        prog.setHtml(`<html><body>` ~
            `<img id="a" src="a.png" /><img id="b" src="b.png" />` ~
            `<img id="c" src="c.png" /></body></html>`);
        // The first pass fetches at most one image and must report pending work.
        prog.layout();
        assert(prog.layoutPending(),
            "a pass that deferred images must leave the document dirty");
        // Keep servicing frames until it settles; every image must arrive.
        int passes = 0;
        while (prog.layoutPending() && passes < 12)
        {
            prog.layout();
            ++passes;
        }
        assert(!prog.layoutPending(), "image loading must eventually settle");
        foreach (id; ["a", "b", "c"])
        {
            auto el = findId(prog.root(), id);
            assert(el !is null, "image element " ~ id ~ " must exist");
        }
        // The contract that matters for a live host: the first paint defers the
        // network images (leaving work pending), and the following passes fetch
        // every one of them. Asserted on the fetches, not on decoded pixels,
        // because this fixture's loader serves a synthetic PNM body.
        foreach (want; ["a.png", "b.png", "c.png"])
        {
            bool fetched = false;
            foreach (u; asked) if (u == want) { fetched = true; break; }
            assert(fetched,
                "every image must be fetched across passes; " ~ want ~
                " missing from " ~ to!string(asked));
        }
    }



    // `vertical-align` positions an inline box against its own line box.
    auto va2 = new WebPage(300, 200);
    va2.setHtml(`<html><body><div id="vaL" style="font-size:16px; line-height:40px">` ~
        `<span id="vaT" style="display:inline-block; width:10px; height:10px; vertical-align:top"></span>` ~
        `<span id="vaM" style="display:inline-block; width:10px; height:10px; vertical-align:middle"></span>` ~
        `<span id="vaB" style="display:inline-block; width:10px; height:10px; vertical-align:bottom"></span>` ~
        `</div></body></html>`);
    va2.layout();
    auto vaL = findId(va2.root(), "vaL");
    auto vaT = findId(va2.root(), "vaT");
    auto vaM = findId(va2.root(), "vaM");
    auto vaB = findId(va2.root(), "vaB");
    assert(vaL !is null && vaT !is null && vaM !is null && vaB !is null,
        "vertical-align fixture must exist");
    assert(vaT.box.y == vaL.box.y + vaL.box.paddingTop + vaL.box.borderTop &&
        vaM.box.y == vaT.box.y + 15 && vaB.box.y == vaT.box.y + 30,
        "vertical-align must place top/middle/bottom against the line box");

    // `border-width` keywords, and per-side overrides of a shorthand's width.
    auto bw2 = new WebPage(300, 200);
    bw2.setHtml(`<html><body>` ~
        `<div id="bwT" style="border: solid red; border-width: thick; width: 20px; height: 10px"></div>` ~
        `<div id="bwO" style="border: 1px solid red; border-bottom-width: 3px; width: 20px; height: 10px"></div>` ~
        `</body></html>`);
    bw2.layout();
    auto bwT = findId(bw2.root(), "bwT");
    auto bwO = findId(bw2.root(), "bwO");
    assert(bwT !is null && bwO !is null, "border-width fixture must exist");
    assert(bwT.box.borderTop == 5 && bwT.box.borderLeft == 5,
        "border-width: thick must be 5px on every side");
    assert(bwO.box.borderTop == 1 && bwO.box.borderBottom == 3,
        "border-bottom-width must override the shorthand's width");

    // An inline-block consumes line space for its own margins and padding.
    auto ib = new WebPage(300, 200);
    ib.setHtml(`<html><body><div id="ibL" style="font-size:16px; line-height:20px">` ~
        `<span id="ibA" style="display:inline-block; width:10px; height:10px;` ~
        ` margin-left:10px; margin-right:5px; padding-left:4px; padding-right:6px"></span>` ~
        `<span id="ibB" style="display:inline-block; width:10px; height:10px"></span>` ~
        `</div></body></html>`);
    ib.layout();
    auto ibL = findId(ib.root(), "ibL");
    auto ibA = findId(ib.root(), "ibA");
    auto ibB = findId(ib.root(), "ibB");
    assert(ibL !is null && ibA !is null && ibB !is null, "inline-box fixture must exist");
    const ibLeft = ibL.box.x + ibL.box.paddingLeft + ibL.box.borderLeft;
    assert(ibA.box.x == ibLeft + 10, "an inline-block starts after its margin-left");
    assert(ibB.box.x == ibLeft + 35,
        "inline-block margins and padding must consume line space");

    // Absolute positioning from all four insets, including auto size and
    // auto margins between opposing insets (CSS 10.3.7 / 10.6.4).
    auto ab2 = new WebPage(400, 300);
    ab2.setHtml(`<html><body>` ~
        `<div id="abBox" style="position:relative; width:200px; height:100px">` ~
        `<div id="abW" style="position:absolute; left:10px; right:20px; height:10px"></div>` ~
        `<div id="abH" style="position:absolute; top:10px; bottom:20px; width:10px"></div>` ~
        `<div id="abC" style="position:absolute; left:0px; right:0px; top:0px; bottom:0px;` ~
        ` width:100px; height:20px; margin:auto"></div>` ~
        `</div></body></html>`);
    ab2.layout();
    auto abBox = findId(ab2.root(), "abBox");
    auto abW = findId(ab2.root(), "abW");
    auto abH = findId(ab2.root(), "abH");
    auto abC = findId(ab2.root(), "abC");
    assert(abBox !is null && abW !is null && abH !is null && abC !is null,
        "absolute-inset fixture must exist");
    assert(abW.box.width == 170, "width:auto with both insets must fill 200-10-20");
    assert(abH.box.height == 70, "height:auto with both insets must fill 100-10-20");
    assert(abC.box.x == abBox.box.x + 50 && abC.box.y == abBox.box.y + 40,
        "margin:auto with opposite insets must centre an absolute box");

    // A parent's top margin collapses with its first in-flow child's, unless
    // padding separates them.
    auto col = new WebPage(400, 300);
    col.setHtml(`<html><body>` ~
        `<div id="pre" style="height:10px"></div>` ~
        `<div id="p1"><div id="c1" style="margin-top:30px">x</div></div>` ~
        `<div id="p2" style="padding-top:5px"><div id="c2" style="margin-top:30px">y</div></div>` ~
        `</body></html>`);
    col.layout();
    auto pre = findId(col.root(), "pre");
    auto p1 = findId(col.root(), "p1");
    auto c1 = findId(col.root(), "c1");
    auto p2 = findId(col.root(), "p2");
    auto c2 = findId(col.root(), "c2");
    assert(pre !is null && p1 !is null && c1 !is null && p2 !is null && c2 !is null,
        "collapsing fixture must exist");
    assert(p1.box.y - (pre.box.y + pre.box.height) == 30,
        "the child's top margin must collapse onto the parent's top edge");
    assert(c1.box.y == p1.box.y,
        "the collapsed margin must not also add space inside the parent");
    assert(c2.box.y - p2.box.y == 35,
        "top padding stops collapsing, so the margin applies inside the box");

    // `position: relative` offsets the box and its descendants, but never the
    // position of a following sibling.
    auto rel = new WebPage(400, 300);
    rel.setHtml(`<html><body>` ~
        `<div id="r1" style="position:relative; top:5px; left:10px; height:20px"></div>` ~
        `<div id="r2" style="height:20px"></div>` ~
        `<div id="r3" style="position:relative; top:3px; height:20px">` ~
        `<div id="r3c" style="height:10px"></div></div>` ~
        `</body></html>`);
    rel.layout();
    auto r1 = findId(rel.root(), "r1");
    auto r2 = findId(rel.root(), "r2");
    auto r3 = findId(rel.root(), "r3");
    auto r3c = findId(rel.root(), "r3c");
    assert(r1 !is null && r2 !is null && r3 !is null && r3c !is null,
        "relative-position fixture must exist");
    assert(r1.box.y - (r2.box.y - 20) == 5,
        "`top: 5px` must offset the box from its in-flow position");
    assert(r1.box.x - r2.box.x == 10, "`left: 10px` must offset the box");
    assert(r3.box.y - r2.box.y == 20 + 3,
        "a relative offset must not move the previous sibling's flow position");
    assert(r3c.box.y - r3.box.y == 0,
        "a relative offset must move descendants with the box");

    // A parent's bottom margin collapses with its last in-flow child's, so the
    // child's bottom margin escapes past the parent's bottom edge.
    auto bot = new WebPage(400, 300);
    bot.setHtml(`<html><body>` ~
        `<div id="pb"><div id="cb" style="height:10px; margin-bottom:30px">x</div></div>` ~
        `<div id="after" style="height:10px"></div>` ~
        `</body></html>`);
    bot.layout();
    auto pb = findId(bot.root(), "pb");
    auto cb = findId(bot.root(), "cb");
    auto after = findId(bot.root(), "after");
    assert(pb !is null && cb !is null && after !is null, "bottom-collapse fixture");
    assert(pb.box.height == 10,
        "the child's bottom margin must not be counted inside the parent's height");
    assert(after.box.y - (pb.box.y + pb.box.height) == 30,
        "the collapsed bottom margin must sit between the parent and the next block");

    // box-shadow parsing: the fourth length is the spread, not the colour.
    auto sh = new WebPage(200, 200);
    sh.setHtml(`<html><body><div id="s" style="height:10px;` ~
        `box-shadow: 0 2px 4px 1px rgba(255, 0, 0, 0.5)"></div></body></html>`);
    sh.layout();
    auto shEl = findId(sh.root(), "s");
    assert(shEl !is null, "box-shadow fixture must exist");
    assert(shEl.style.boxShadowSpread == "1px",
        "the fourth length of box-shadow is the spread");
    assert(shEl.style.boxShadowColor.length > 0 && shEl.style.boxShadowColor[0] == 'r',
        "the colour must not swallow the spread token");

    // `visibility: hidden` still reserves layout space.
    auto vis = new WebPage(200, 200);
    vis.setHtml(`<html><body><div id="h" style="visibility:hidden; height:30px"></div>` ~
        `<div id="v" style="height:10px"></div></body></html>`);
    vis.layout();
    auto hEl = findId(vis.root(), "h");
    auto vEl = findId(vis.root(), "v");
    assert(hEl !is null && vEl !is null, "visibility fixture must exist");
    assert(hEl.box.height == 30, "a hidden box must still be laid out");
    assert(vEl.box.y - hEl.box.y == 30,
        "a hidden box must still reserve its space for following content");

    // Hit-testing must still reach an inline-block child even when the
    // enclosing block's measured box does not cover it (the block/inline
    // ordering limitation), otherwise clicks and hover miss such controls.
    auto wrapped = new WebPage(400, 300);
    wrapped.setHtml(`<html><body><div class="row">` ~
        `<div id="inner" onclick='this.setAttribute("hit","1")'>x</div>` ~
        `</div></body></html>`);
    wrapped.setStylesheet(
        ".row { display: block; } "
        ~ "#inner { display: inline-block; padding: 4px; }");
    wrapped.executeScripts();
    wrapped.layout();
    auto inner = findId(wrapped.root(), "inner");
    assert(inner !is null, "wrapped child must exist");
    assert(wrapped.elementAtPoint(inner.box.x + 1, inner.box.y + 1) is inner,
        "hit-testing must reach a child that overflows its wrapper");
    wrapped.click(inner.box.x + 1, inner.box.y + 1);
    assert(("hit" in inner.attrs) !is null,
        "clicking through a wrapper must run the child's handler");
}

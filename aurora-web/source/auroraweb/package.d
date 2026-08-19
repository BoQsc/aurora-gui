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
import auroraweb.dombind : bindDocument;
import auroraweb.html : parseHtml;
import auroraweb.js : JsRuntime, JsValue, JsKind, JsScope, Node, parseScript;
import auroraweb.layout : applyStylesAndLayout;
import auroraweb.net : HttpResponse, httpFetch;
import auroraweb.paint : paintTree;

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
        _width = width > 0 ? width : 1;
        _height = height > 0 ? height : 1;
    }

    int width() { return _width; }
    int height() { return _height; }

    /// Parse HTML into the DOM, extracting <style> and <script> blocks.
    /// Scripts are collected but not executed until `executeScripts()` is
    /// called (after the DOM is bound).
    void setHtml(string html)
    {
        _root = parseHtml(html);
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
                if (css.length) _rules ~= parseStylesheet(css);
            }
            foreach (child; e.elements) walk(child);
        }
        walk(_root);
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
            auto program = _js.parseInto(code);
            _js.runProgram(program, _js.makeObject());
        }
        _pendingScripts = [];
        // Run queued microtasks (Promise/async continuations).
        _js.pumpMicrotasks();
    }

    /// Parse CSS and append to the stylesheet.
    void setStylesheet(string css)
    {
        if (css.length) _rules ~= parseStylesheet(css);
    }

    /// Parse and execute a script string in the page's runtime.
    void runScript(string source)
    {
        bindDocument(_root, _js, _js.globalScope, _resourceLoader);
        auto program = _js.parseInto(source);
        _js.runProgram(program, _js.makeObject());
        _js.pumpMicrotasks();
    }

    /// Re-layout after DOM/style mutation.
    void layout()
    {
        applyStylesAndLayout(_root, _rules, _width, _height);
        loadImages();
    }

    /// Find <img> elements without a decoded image and load them, and decode
    /// any CSS `background-image: url("...")` references.
    private void loadImages()
    {
        if (_resourceLoader is null) return;
        void walk(Element e)
        {
            // <img src="...">
            if (e.tag == "img" && e.image is null)
            {
                auto src = "src" in e.attrs;
                if (src !is null && (*src).length)
                {
                    try
                    {
                        auto bytes = _resourceLoader(*src);
                        if (bytes.length)
                        {
                            import aurora.image : decodePngImage;
                            auto img = decodePngImage(cast(const(ubyte)[]) bytes, *src);
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
            if (e.backgroundImage is null && e.style.backgroundImage.length > 4 &&
                e.style.backgroundImage[0 .. 4].toLower() == "url(")
            {
                auto url = urlFromBackgroundImage(e.style.backgroundImage);
                if (url.length)
                {
                    try
                    {
                        auto bytes = _resourceLoader(url);
                        if (bytes.length)
                        {
                            import aurora.image : decodePngImage;
                            auto img = decodePngImage(cast(const(ubyte)[]) bytes, url);
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
        walk(_root);
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

    /// Paint the document into a canvas at the given offset.
    void paint(Canvas canvas, int offsetX, int offsetY)
    {
        layout();
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

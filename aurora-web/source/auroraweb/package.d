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
import auroraweb.eventloop : EventLoop;
import auroraweb.html : parseHtml;
import auroraweb.js : JsRuntime, JsValue, JsKind, JsScope, Node, parseScript;
import auroraweb.layout : applyStylesAndLayout;
import auroraweb.net : HttpResponse, httpFetch, resolveUrl;
import auroraweb.paint : paintTree, fillCanvasBackground;

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
    int _laidOutWidth = -1;     /// Viewport width used by the most recent layout.
    int _laidOutHeight = -1;    /// Viewport height used by the most recent layout.
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

    /// Parse CSS and append to the stylesheet.
    void setStylesheet(string css)
    {
        if (css.length)
        {
            _rules ~= parseStylesheet(css);
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
        _layoutDirty = false;
    }

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

    /// Find <img> elements without a decoded image and load them, and decode
    /// any CSS `background-image: url("...")` references.
    private void loadImages()
    {
        void walk(Element e)
        {
            // <img src="...">
            if (e.tag == "img" && e.image is null && !e.imageLoadTried)
            {
                auto src = "src" in e.attrs;
                if (src !is null && (*src).length)
                {
                    // Mark BEFORE fetching: a failing/absent URL must not be
                    // re-fetched on every layout (that repeated real network I/O
                    // once per frame while the image stayed unset).
                    e.imageLoadTried = true;
                    try
                    {
                        auto bytes = fetchBytes(resolveUrl(_currentUrl, *src));
                        if (bytes.length)
                        {
                            // Shared decoder: any supported format (PNG, JPEG,
                            // GIF, BMP, TGA, PNM, ...), not just PNG.
                            import aurora.image : decodeImage, RgbaImage;
                            RgbaImage img;
                            try img = decodeImage(cast(const(ubyte)[]) bytes, *src);
                            catch (Exception) img = null;
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
                        auto bytes = fetchBytes(resolveUrl(_currentUrl, url));
                        if (bytes.length)
                        {
                            // Shared decoder so CSS background images work for
                            // every supported format, not just PNG.
                            import aurora.image : decodeImage, RgbaImage;
                            RgbaImage img;
                            try img = decodeImage(cast(const(ubyte)[]) bytes, url);
                            catch (Exception) img = null;
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

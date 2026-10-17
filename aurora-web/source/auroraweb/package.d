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
import aurora.font : FontFace;
import auroraweb.css : parseFontFaces, parseStylesheet, Rule, WebFontFace;
import auroraweb.dom : Element, TextNode;
import auroraweb.dombind : bindDocument, dispatchHostEvent, dispatchHostEventNoBubble,
    dispatchDocumentEvent, evaluateIntersectionObservers, setDocumentScroll, setViewportSize;
import auroraweb.shaping : registerWebFace;
import auroraweb.woff : isWoff, woffToSfnt;
import auroraweb.woff2 : isWoff2, woff2ToSfnt;

/// One `<script>` waiting to run: inline text, or the URL of an external
/// classic script.
private struct PendingScript
{
    string code;   /// Inline source ("" for an external script).
    string src;    /// Absolute URL of an external script ("" for inline).
}

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
import auroraweb.encoding : decodeText, decodeStyleSheet;
import auroraweb.encoding : sniffEncoding;
import auroraweb.interact : elementAt, hrefOf;
import auroraweb.paint : paintTree, fillCanvasBackground, canvasBackgroundColor,
    bodyPaintsBackground;

/// One cached subresource: the bytes plus the freshness rules its response
/// declared. Storing the rules matters because reusing everything forever served
/// a stale stylesheet whenever the server said `no-store`, `no-cache` or gave a
/// `max-age` that had expired (RFC 9111).
private struct CachedResource
{
    ubyte[] bytes;
    bool noStore;             /// `Cache-Control: no-store` - never reusable.
    bool noCache;             /// `Cache-Control: no-cache` - only after revalidation.
    bool mustRevalidate;      /// `Cache-Control: must-revalidate`.
    int maxAgeSeconds = -1;   /// `Cache-Control: max-age=N`, -1 when absent.
    long storedMsec;          /// Monotonic milliseconds when it was stored.
}

/// Milliseconds from a monotonic clock (immune to wall-clock changes).
private long monotonicMsec()
{
    import core.time : MonoTime;
    return MonoTime.currTime.ticks / 10_000L; // ticks are 100ns units
}

/// Read the directives that affect reuse from a Cache-Control value.
private void parseCacheControl(string value, ref CachedResource entry)
{
    import std.array : split;
    foreach (token; value.split(','))
    {
        auto t = token.strip().toLower();
        if (t == "no-store") entry.noStore = true;
        else if (t == "no-cache" || t == "private") entry.noCache = true;
        else if (t == "must-revalidate") entry.mustRevalidate = true;
        else if (t.startsWith("max-age="))
        {
            auto number = t["max-age=".length .. $].strip();
            int seconds;
            bool ok = number.length > 0;
            foreach (c; number)
            {
                if (c < '0' || c > '9') { ok = false; break; }
                seconds = seconds * 10 + (c - '0');
            }
            if (ok) entry.maxAgeSeconds = seconds;
        }
    }
}

/// `true` when a stored copy may be reused without contacting the server.
private bool mayReuse(in CachedResource entry)
{
    if (entry.noStore || entry.noCache || entry.mustRevalidate) return false;
    if (entry.maxAgeSeconds >= 0)
        return monotonicMsec() - entry.storedMsec < entry.maxAgeSeconds * 1000L;
    // Nothing said: reuse it, as a cache does in the absence of freshness
    // information. This is what keeps a second load of a large page cheap.
    return true;
}

/// Subresources (stylesheets, images, scripts) keyed by URL, shared by every
/// page in the process. Without it each load repeated every request: a heavy
/// page spent ~4.5s in its FIRST layout fetching and decoding subresources
/// while each later pass over the same tree cost 6-9ms, so the network round
/// trips - not the layout - were the whole cost. Reload, back/forward and a
/// second tab to the same site now reuse what is already in memory.
private CachedResource[string] _resourceCache;

/// Content-Type of each fetched subresource. The resource loader hands back
/// bytes only, so without this a stylesheet's own charset is unavailable and a
/// windows-1252 sheet's selectors cannot match the document's class names.
private string[string] _resourceContentTypes;
private size_t _resourceCacheBytes;
/// Bound the cache so a long browsing session cannot grow without limit.
private enum size_t MaxResourceCacheBytes = 64 * 1024 * 1024;
private enum size_t MaxResourceCacheEntries = 512;

/// Drop every cached subresource. A failure (`null`) is never stored, so a
/// transient error stays retryable and does not need clearing.
void clearResourceCache()
{
    _resourceCache = null;
    _resourceCacheBytes = 0;
}

/// Number of cached subresources (for tests and telemetry).
size_t resourceCacheSize() { return _resourceCache.length; }

/// Bytes currently held by the cache (for tests and telemetry).
size_t resourceCacheBytes() { return _resourceCacheBytes; }

/// Store freshly downloaded subresource bytes under `url`, remembering the
/// response's cache directives. Bounded, and only the first value for a URL is
/// kept (a second lookup must hit the cache).
private ubyte[] cacheResource(string url, ubyte[] bytes,
    string[string] headers = null)
{
    if (bytes is null || bytes.length == 0 || url.length == 0) return bytes;
    CachedResource entry;
    // The cache outlives the fetch that produced these bytes, and `bytes` may be
    // a slice of a temporary response buffer, so the cache must own its copy.
    // Keeping the caller's slice left a dangling reference that faulted on the
    // next lookup.
    entry.bytes = bytes.dup;
    entry.storedMsec = monotonicMsec();
    if (headers !is null)
        if (auto cc = "cache-control" in headers)
            parseCacheControl(*cc, entry);
    if (entry.noStore) return bytes; // stored nowhere, by the server's request
    if (_resourceCache.length < MaxResourceCacheEntries &&
        _resourceCacheBytes + bytes.length <= MaxResourceCacheBytes &&
        url !in _resourceCache)
    {
        _resourceCache[url] = entry;
        _resourceCacheBytes += bytes.length;
    }
    return bytes;
}

import std.string : indexOf, lastIndexOf, strip, startsWith, toLower;
import std.parallelism : Task;

/// Fetch an image batch on a worker thread and return its responses, by index.
///
/// A worker fetches and does nothing else - no DOM, no resource cache, no
/// trace, no decode - so the calling thread stays the only one touching page
/// state. The batch returns instead of waiting: its caller keeps painting, and
/// a later pass collects the responses (see `WebPage.startImageBatch`).
///
/// The workers ask for one-shot requests (`net.httpFetch` with `keepAlive`
/// false), because a worker that leaves a pooled connection behind takes the
/// process down with it when it exits: measured, a batch reports HTTP 200 for
/// every URL and the process then dies with 0xC0000005, while the same batch
/// whose workers close their own connections exits clean. The connection pool
/// therefore stays the calling thread's, and no worker ever mutates it.
private HttpResponse[] fetchImageBatch(string[] urls)
{
    import auroraweb.net : httpFetch;
    import std.parallelism : taskPool;
    import std.range : iota;
    auto responses = new HttpResponse[](urls.length);
    // Requests started together. Two or three at once always succeeded here,
    // but twenty-four at once against one host did not: every one of them
    // stalled and came back 26 s later as an empty response. So the batch runs
    // in groups, which is also what a browser does - it keeps a few
    // connections per host, not one per pending request.
    enum maxConcurrentRequests = 6;
    foreach (start; iota(0, urls.length, maxConcurrentRequests))
    {
        const stop = start + maxConcurrentRequests < urls.length
            ? start + maxConcurrentRequests : urls.length;
        foreach (i; taskPool.parallel(iota(start, stop)))
        {
            try
            {
                auto res = httpFetch(urls[i], "GET", null, null, false);
                // Recorded whatever it is, so the walk that collects this batch
                // can mark the element tried either way: an image that failed
                // must not be requested again on every following pass (that is
                // how the inline path marked it, and the page would otherwise
                // never settle).
                responses[i] = res;
            }
            catch (Throwable t)
            {
                // One dead subresource must not fail the batch.
                HttpResponse failed;
                failed.finalUrl = urls[i];
                failed.error = t.msg;
                responses[i] = failed;
            }
        }
    }
    return responses;
}

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
    int _docPasses;             /// Completed layout passes for the current document.
    int _imagePasses;           /// Passes that spent image budget (see loadImages).
    bool _webFontsPending;      /// A layout pass deferred a `font-display: swap` download.
    bool _paintedOnce;          /// A frame has been painted since the last navigation.
    size_t _styleInputs;        /// Fingerprint of the tree the styles were resolved from.
    int _docGen;                /// Bumped whenever the document tree is replaced.
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
    /// Optional richer loader that also reports the response's headers. Without
    /// it the memoizing loader path dropped `Cache-Control`, so a `no-store` or
    /// `no-cache` stylesheet was cached and reused like a plain one (RFC 9111).
    ubyte[] delegate(string url, out string[string] headers) @safe
        _resourceLoaderWithHeaders;
    /// The URL of the document most recently loaded through `navigate()`.
    string _currentUrl;
    /// Image URLs the current pass is fetching. `loadImages` walks the document
    /// once to fill this (no network, no element flags touched), starts those
    /// requests together, then walks again with the bytes in hand.
    string[] _pendingImageUrls;
    /// True during that first, collect-only walk: `fetchBytes` records the URL
    /// instead of requesting it.
    bool _collectingUrls;
    /// Responses the pass's parallel batch already fetched, by URL, waiting for
    /// the walk to decode them. Consumed (and emptied) as the walk runs.
    HttpResponse[string] _prefetchedResponses;
    /// The image batch this page started on its own thread and has not collected
    /// yet, the URLs it is fetching, and whether it is still in flight. A pass
    /// that waited for its own batch froze the window for the whole download -
    /// measured 2.2 s for boqsc.eu's 1.6 MB + 3.5 MB pair, with the web-font
    /// pass queued behind it - so a batch is started in one pass and collected
    /// in a later one, and the frames in between paint with the bytes that have
    /// already arrived.
    /// `task()` hands back a heap Task, so the handle is a pointer. It is kept
    /// for the whole batch and never freed by hand: the batch is one per pass,
    /// and freeing it while the pool still refers to it is not worth the risk.
    Task!(fetchImageBatch, string[])* _imageBatch;
    string[] _imageBatchUrls;   /// URLs `_imageBatch` is fetching, in order.
    bool _imageBatchInFlight;   /// `_imageBatch` was started, not yet collected.

    /// Global runtime (so scripts can be loaded incrementally).
    JsRuntime jsRuntime() { return _js; }

    /// Set a callback that loads a URL and returns the raw bytes (network
    /// layer). Feeds both image loading and the `fetch` global.
    void setResourceLoader(ubyte[] delegate(string url) @safe loader)
    {
        _resourceLoader = loader;
    }

    /// Set a loader that also returns the response's headers, so cache
    /// directives from the network survive into the resource cache.
    void setResourceLoaderWithHeaders(
        ubyte[] delegate(string url, out string[string] headers) @safe loader)
    {
        _resourceLoaderWithHeaders = loader;
    }

    /// Backwards-compatible alias for `setResourceLoader` (kept for existing
    /// callers that used the image-oriented name).
    void setImageLoader(ubyte[] delegate(string url) @safe loader)
    {
        _resourceLoader = loader;
    }

    /// Backwards-compatible alias for `setResourceLoaderWithHeaders`.
    void setImageLoaderWithHeaders(
        ubyte[] delegate(string url, out string[string] headers) @safe loader)
    {
        _resourceLoaderWithHeaders = loader;
    }

    /// Fetch a subresource through the loader, memoized by URL. Stylesheets,
    /// images and scripts all come through here, so a reload, a back/forward
    /// or a second tab to the same site reuses the bytes (and the decode that
    /// follows them) instead of repeating the request.
    ubyte[] loadResource(string url)
    {
        if (url.length == 0) return null;
        if (_resourceLoader is null && _resourceLoaderWithHeaders is null)
            return null;
        if (auto hit = url in _resourceCache)
            if (mayReuse(*hit)) return (*hit).bytes;
        ubyte[] bytes;
        string[string] headers;
        try
        {
            if (_resourceLoaderWithHeaders !is null)
                bytes = _resourceLoaderWithHeaders(url, headers);
            else
                bytes = _resourceLoader(url);
        }
        catch (Throwable)
            bytes = null;
        // A failure is never cached: a transient network error must stay
        // retryable on the next load.
        return cacheResource(url, bytes, headers);
    }

    /// `true` when `url` may be served from the cache without a request.
    bool resourceIsReusable(string url)
    {
        if (auto hit = url in _resourceCache) return mayReuse(*hit);
        return false;
    }

    /// Forget one cached subresource, so the next lookup refetches it.
    void invalidateResource(string url)
    {
        if (auto hit = url in _resourceCache)
        {
            _resourceCacheBytes -= (*hit).bytes.length;
            _resourceCache.remove(url);
        }
    }

    version (unittest)
    unittest
    {
        // Cache-Control decides reuse: no-store/no-cache never reuse, max-age is
        // honoured, and a response that says nothing keeps the cheap path.
        clearResourceCache();
        auto page = new WebPage(100, 100);
        auto seeded = cacheResource("plain", cast(ubyte[]) "abc", null);
        assert(seeded.length == 3, "cacheResource returns the bytes");
        assert(page.resourceIsReusable("plain"), "no directives keep the cache useful");

        cacheResource("nostore", cast(ubyte[]) "abc",
            ["cache-control": "no-store"]);
        assert(!page.resourceIsReusable("nostore"),
            "no-store must never be reused");

        cacheResource("nocache", cast(ubyte[]) "abc",
            ["cache-control": "no-cache"]);
        assert(!page.resourceIsReusable("nocache"),
            "no-cache must not be reused without revalidation");

        cacheResource("aged", cast(ubyte[]) "abc",
            ["cache-control": "public, max-age=0"]);
        assert(!page.resourceIsReusable("aged"),
            "an expired max-age must not be reused");

        cacheResource("fresh", cast(ubyte[]) "abc",
            ["cache-control": "public, max-age=600"]);
        assert(page.resourceIsReusable("fresh"),
            "an unexpired max-age is reusable");

        page.invalidateResource("fresh");
        assert(!page.resourceIsReusable("fresh"), "invalidate forgets the entry");
        clearResourceCache();
    }

    version (unittest)
    unittest
    {
        // A loader that also reports headers must feed those headers into the
        // memo, so `no-cache` from the network is not silently cached and
        // reused. Without the header-carrying loader every response looked
        // directive-free and stayed reusable.
        clearResourceCache();
        auto page = new WebPage(100, 100);
        int calls;
        page.setResourceLoaderWithHeaders((string url, out string[string] hdrs) @safe {
            ++calls;
            hdrs = ["cache-control": "no-cache"];
            auto bytes = "abc".dup;
            return cast(ubyte[]) bytes;
        });
        page.loadResource("x");
        assert(calls == 1, "the loader is used the first time");
        assert(!page.resourceIsReusable("x"),
            "no-cache from the loader must not be reusable");
        page.loadResource("x");
        assert(calls == 2, "no-cache must force a second request");
        clearResourceCache();
    }

    version (unittest)
    unittest
    {
        // A URL is fetched once and reused; a failure is not cached.
        clearResourceCache();
        auto page = new WebPage(100, 100);
        int calls;
        page.setResourceLoader((string url) @safe
        {
            ++calls;
            ubyte[] bytes;
            foreach (c; url) bytes ~= cast(ubyte) c;
            return url == "fail" ? null : bytes;
        });
        assert(page.loadResource("a") !is null, "first fetch succeeds");
        assert(page.loadResource("a") !is null, "second fetch succeeds");
        assert(calls == 1, "a repeated URL must come from the cache");
        assert(page.loadResource("fail") is null, "failure propagates");
        assert(page.loadResource("fail") is null, "failure propagates again");
        assert(calls == 3, "a failure must stay retryable, not cached");
        assert(page.loadResource("b") !is null, "a new URL is fetched");
        assert(calls == 4, "a new URL is fetched exactly once");
        clearResourceCache();
        assert(resourceCacheSize() == 0, "clear empties the cache");
        assert(page.loadResource("a") !is null, "cleared cache refetches");
        assert(calls == 5, "cleared cache refetches");
        clearResourceCache();
    }

    /// Fetch a URL and decode the response body as text. Returns an empty
    /// string on failure. Decoding follows the WHATWG Encoding rules (BOM,
    /// Content-Type charset, then the UTF-8/windows-1252 fallback) instead of
    /// assuming UTF-8: a windows-1252 stylesheet's class names and colours were
    /// mangled before, so its rules matched nothing.
    string fetchText(string url)
    {
        auto bytes = fetchBytes(url);
        if (bytes.length == 0) return "";
        return decodeStyleSheet(bytes, contentTypeOf(url), _documentEncoding);
    }

    /// The recorded Content-Type of a fetched subresource ("" when unknown).
    private string contentTypeOf(string url)
    {
        if (auto hit = url in _resourceContentTypes) return *hit;
        return "";
    }

    /// Fetch a URL and return the raw response bytes (empty on failure).
    ubyte[] fetchBytes(string url)
    {
        if (url.length)
        {
            // The pass's collect-only walk records what it would fetch instead
            // of fetching it, so the whole batch can go out together.
            if (_collectingUrls)
            {
                import std.algorithm.searching : canFind;
                // A response this pass's batch already brought needs no request:
                // recording it here sent the worker after bytes the pass was
                // about to decode. djangoproject.com's header and footer both
                // name the same logo SVG, and the second element cost a fresh
                // 78 ms request for a file that was already in hand.
                if (url in _prefetchedResponses) return (cast(ubyte[]) null);
                // Nor does a URL whose bytes are already in the resource cache
                // from an earlier pass - the same image named twice on a page,
                // or an icon reused across pages.
                if (auto hit = url in _resourceCache)
                    if (mayReuse(*hit)) return (cast(ubyte[]) null);
                // One request per URL: two elements naming the same image must
                // not queue it twice.
                if (!_pendingImageUrls.canFind(url)) _pendingImageUrls ~= url;
                return (cast(ubyte[]) null);
            }
            // A response the pass's parallel batch already fetched. It enters the
            // resource cache here, on the calling thread: a worker thread only
            // fetches, because the cache, the trace and the decoder are not
            // shared between threads.
            if (auto pre = url in _prefetchedResponses)
            {
                auto res = *pre;
                _prefetchedResponses.remove(url);
                if (res.body.length == 0) return (cast(ubyte[]) null);
                if (auto ct = "content-type" in res.headers)
                    _resourceContentTypes[url] = *ct;
                return cacheResource(url, res.body, res.headers);
            }
            // Stylesheets, images and scripts all arrive here, so consult the
            // shared cache before touching the network.
            if (auto hit = url in _resourceCache)
                if (mayReuse(*hit)) return (*hit).bytes;
        }
        if (_resourceLoader !is null)
        {
            try
            {
                auto bytes = loadResource(url);
                return bytes !is null ? bytes : (cast(ubyte[]) null);
            }
            catch (Exception exc)
            {
                return (cast(ubyte[]) null);
            }
        }
        auto res = httpFetch(url);
        if (res.error.length) return (cast(ubyte[]) null);
        if (auto ct = "content-type" in res.headers)
            _resourceContentTypes[url] = *ct;
        return cacheResource(url, res.body, res.headers);
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
            // The document's own charset declaration decides how its bytes
            // become text (WHATWG Encoding): a page served as windows-1252
            // without this decoded to mojibake, and its selectors stopped
            // matching the class names it declared.
            _documentEncoding = sniffEncoding(res.body, ct is null ? "" : *ct);
            setHtml(decodeText(res.body, ct is null ? "" : *ct));
            executeScripts();
            layout();
        }
        else
        {
            // A non-HTML response (a plain-text body, or a 404 with a non-HTML
            // content type) still has to leave a renderable document behind.
            // Returning with `_root` null made the next layout() fault, and a
            // viewer that navigates to such a URL showed nothing at all. Render
            // the bytes as text so the response is visible and layout is safe.
            _documentEncoding = sniffEncoding(res.body, ct is null ? "" : *ct);
            const text = decodeText(res.body, ct is null ? "" : *ct);
            setHtml("<html><body><pre>" ~ escapeHtml(text) ~ "</pre></body></html>");
            executeScripts();
            layout();
        }
    }

    /// Encoding of the current document, so an unlabelled stylesheet can
    /// inherit it (CSS 4.4) instead of being guessed at.
    private string _documentEncoding = "";

    /// The URL of the most recently navigated document ("" if none).
    string currentUrl() { return _currentUrl; }

    private HttpResponse loaderResponse(string url)
    {
        HttpResponse res;
        res.finalUrl = url;
        try
        {
            auto bytes = loadResource(url);
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
        // Keep `window.innerWidth`/`innerHeight` and `matchMedia` reporting the
        // viewport the page is about to be laid out in.
        setViewportSize(_js, w, h);
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
        ++_docGen;   // a new tree must always be styled, however alike it looks
        // A new document gets a fresh pass count: its first frames paint markup
        // and styles before any network image is fetched.
        _docPasses = 0;
        _deferredFaces = [];
        _unusedFaces = [];
        _unusedCodePoints = [];
        _webFontsPending = false;
        _paintedOnce = false;
        _layoutDirty = true;
        _rules = [];
        extractStyles();
        collectScripts();
        bindDocument(_root, _js, _js.globalScope, _resourceLoader, _currentUrl,
            _width, _height);
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
                    loadWebFonts(css, _currentUrl);
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
                        {
                            // RFC 2397: everything before the comma is the media
                            // type, whose charset parameter decides how the decoded
                            // bytes become text. Ignoring it decoded a cp1252
                            // `data:` stylesheet as UTF-8, so its selectors lost the
                            // non-ASCII characters they were written with.
                            auto comma = href.indexOf(',');
                            auto mediaType = comma < 0 ? "" : href[0 .. comma];
                            css = decodeStyleSheet(decodeDataUrl(href), mediaType,
                                _documentEncoding);
                        }
                        else
                        {
                            auto target = _currentUrl.length
                                ? resolveUrl(_currentUrl, href) : href;
                            // Decode the sheet by ITS OWN charset when it has one,
                            // else by the document's (CSS 4.4). Decoding it as
                            // UTF-8 unconditionally silently broke every rule whose
                            // selector had a non-ASCII class name.
                            css = decodeStyleSheet(fetchBytes(target),
                                contentTypeOf(target), _documentEncoding);
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
                        // A linked sheet's `@font-face` src resolves against the
                        // sheet, exactly like its url() references.
                        loadWebFonts(css, base);
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

    /// The page's scripts, in document order, collected for `executeScripts`.
    private PendingScript[] _pendingScripts;

    /// Collect the page's scripts, in document order.
    ///
    /// An external `<script src>` is a reference to the code, not the code: the
    /// old collector read only `textContent`, so every script a page kept in a
    /// file — which is where real pages keep their behaviour — was never
    /// fetched and never ran, leaving whatever it was responsible for dead.
    private void collectScripts()
    {
        _pendingScripts = [];
        if (_root is null) return;
        void walk(Element e)
        {
            if (e.tag == "script" && runsAsScript(e))
            {
                if (auto src = "src" in e.attrs)
                {
                    // An empty `src` is a placeholder a template left behind,
                    // not a fetch: there is no source to load.
                    auto rawSrc = (*src).strip();
                    if (rawSrc.length)
                    {
                        PendingScript pending;
                        pending.src = normalizeUrlPath(resolveUrl(_currentUrl, rawSrc));
                        if (pending.src.length) _pendingScripts ~= pending;
                    }
                }
                else
                {
                    auto code = e.textContent();
                    if (code.strip().length)
                    {
                        PendingScript pending;
                        pending.code = code;
                        _pendingScripts ~= pending;
                    }
                }
            }
            foreach (child; e.elements) walk(child);
        }
        walk(_root);
    }

    /// `true` when a `<script>` element's type makes it JavaScript.
    ///
    /// A `type` of "" or `text/javascript` runs. A data block (`application/json`,
    /// `text/template`, ...) does not, and running one would be a script error on
    /// a page that is otherwise fine. A module is skipped: its scope and timing
    /// are deferred by rules the engine does not implement, so evaluating it as a
    /// classic script would run its code at the wrong time with the wrong
    /// bindings — worse than leaving it alone.
    private static bool runsAsScript(Element e)
    {
        auto type = "type" in e.attrs;
        if (type is null) return true;
        auto value = (*type).strip();
        auto semi = indexOf(value, ";");
        if (semi >= 0) value = value[0 .. semi].strip();
        const lower = value.toLower();
        if (lower.length == 0) return true;
        if (lower == "module") return false;
        return lower == "text/javascript" || lower == "application/javascript" ||
            lower == "text/ecmascript" || lower == "application/ecmascript" ||
            lower == "text/jscript" || lower == "text/livescript";
    }

    /// Parse and execute the page's scripts in its runtime, in document order,
    /// then report `DOMContentLoaded`.
    ///
    /// A classic external script blocks the ones after it, so its URL is fetched
    /// here, when the document's address is known and the page's loading state is
    /// settled. A script that cannot be fetched or run is skipped: no page script
    /// may abort a navigation.
    void executeScripts()
    {
        if (!_documentBound)
        {
            bindDocument(_root, _js, _js.globalScope, _resourceLoader, _currentUrl,
                _width, _height);
            _documentBound = true;
        }
        foreach (pending; _pendingScripts)
        {
            auto code = pending.code;
            if (pending.src.length)
            {
                try code = toUTF8Decode(fetchBytes(pending.src));
                catch (Exception exc) continue;
            }
            if (!code.strip().length) continue;
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
        // The document is parsed and its classic scripts have run, so the
        // document's `DOMContentLoaded` listeners fire now: a script that waits
        // for the event before touching the DOM must not be left hanging.
        try dispatchDocumentEvent(_js, "DOMContentLoaded");
        catch (Exception exc) {}
        _layoutDirty = true; // scripts may have mutated the DOM
    }

    /// Downloaded `@font-face` faces, keyed by absolute font URL. A page often
    /// names the same file from several sheets, and one process renders many
    /// pages (the corpus sweeps), so each font is downloaded and parsed once.
    private FontFace[string] _webFontFaces;
    private uint _webFontFileSeq;

    /// Write downloaded font bytes to a per-process temporary file and return
    /// its path. The shaper loads faces from a path, so staging a download is
    /// what lets a page's own font reach it without the engine keeping a copy.
    private string stageFontFile(ubyte[] bytes)
    {
        import std.conv : to;
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildPath;
        const dir = buildPath(tempDir(), "aurora-webfonts");
        mkdirRecurse(dir);
        const path = buildPath(dir, (++_webFontFileSeq).to!string ~ ".ttf");
        write(path, bytes);
        return path;
    }

    /// The bytes a font face is loaded from: a WOFF or WOFF2 container is
    /// unpacked to the sfnt inside it first.
    ///
    /// The shaper reads sfnt (ttf/otf) faces only, so a page whose face is
    /// served as WOFF — FontAwesome, in the Django site's header — would
    /// otherwise register no glyphs at all and fall back to a font that has no
    /// icons. The same holds for WOFF2, which is what most current sites serve
    /// exclusively. Bytes that are neither container, or that fail to unpack,
    /// are returned unchanged: the following load then fails exactly as it did
    /// before.
    private static ubyte[] fontBytesFor(ubyte[] bytes)
    {
        if (isWoff2(bytes))
        {
            string error;
            auto sfnt = woff2ToSfnt(bytes, error);
            return sfnt.length ? sfnt : bytes;
        }
        if (!isWoff(bytes)) return bytes;
        try
        {
            auto sfnt = woffToSfnt(bytes);
            return sfnt.length ? sfnt : bytes;
        }
        catch (Exception exc) return bytes;
    }

    /**
     * Download, stage and register the faces a stylesheet defines with
     * `@font-face`.
     *
     * Every failure is per source and silent: a browser that cannot fetch or
     * parse a face falls back to the next `font-family`, which is exactly what
     * shape resolution already does when no web face is registered. A sheet that
     * defines no face returns after one scan.
     */
    private void loadWebFonts(string css, string baseUrl)
    {
        auto faces = parseFontFaces(css);
        if (!faces.length) return;
        foreach (face; faces)
        {
            // A face that declares `swap` (Google Fonts' `&display=swap`),
            // `fallback` or `optional` must not hold up the first frames: the
            // page paints in its fallback face now and the real one is
            // downloaded while the page is already visible. Fonts measured
            // 2.4 s - the largest single block - of one real page's first
            // paint. `auto` and `block` keep the blocking behaviour.
            if (defersFirstPaint(face) && _docPasses < 2)
            {
                _deferredFaces ~= DeferredFace(face, baseUrl);
                _webFontsPending = true;
                continue;
            }
            loadWebFontFace(face, baseUrl);
        }
    }

    /// One `@font-face` source whose `font-display` lets the earlier frames
    /// paint without it, with the address its `url()` resolves against.
    private struct DeferredFace
    {
        WebFontFace face;
        string baseUrl;
    }

    /// Faces `loadWebFonts` queued because their `font-display` allows the
    /// first passes to paint in the fallback face.
    private DeferredFace[] _deferredFaces;

    /// Faces a pass set aside because their `unicode-range` cannot match any code
    /// point the document's own content draws (see `layout`). They are kept
    /// rather than dropped: text a script inserts later can make one usable, and
    /// they are re-checked as soon as the content changes.
    private DeferredFace[] _unusedFaces;

    /// The document's code points when `_unusedFaces` was last evaluated.
    private uint[] _unusedCodePoints;

    /// True when a face's `font-display` says text may be painted before it
    /// loads. The engine has no font timeout, so the block period of `auto` and
    /// `block` is the whole download; the three swap-style values are the ones
    /// CSS Fonts 4 defines as never blocking text.
    private static bool defersFirstPaint(const WebFontFace face)
    {
        const d = face.display.toLower();
        return d == "swap" || d == "fallback" || d == "optional";
    }

    /// True when a face may be needed for content drawn with these code points. A
    /// face that declares no `unicode-range` is unconstrained; one whose ranges
    /// cannot match any code point the document draws is a subset this page will
    /// never use - a face a browser does not fetch.
    private static bool faceCoversText(const WebFontFace face, const uint[] points)
    {
        if (face.ranges.length == 0) return true;
        foreach (p; points)
            foreach (r; face.ranges)
                if (p >= r.lo && p <= r.hi) return true;
        return false;
    }

    /// Sorted, de-duplicated code points the document's own content can draw: the
    /// text nodes, the attribute values (a `title` or `alt` is drawn in the
    /// page's font), and the CSS `content` strings of `::before`/`::after`, whose
    /// escapes are how an icon font names the glyph it draws.
    private uint[] textCodePoints()
    {
        import std.algorithm : sort;
        uint[] points;
        void add(string s) { foreach (dchar c; s) points ~= cast(uint) c; }
        void walk(Element e)
        {
            if (e is null) return;
            foreach (name, value; e.attrs) add(value);
            foreach (child; e.children)
            {
                if (auto text = cast(TextNode) child) add(text.data);
                else if (auto element = cast(Element) child) walk(element);
            }
        }
        walk(_root);
        foreach (rule; _rules)
        {
            bool generated = false;
            foreach (sel; rule.selectors)
                if (sel.pseudoElement.length) generated = true;
            if (!generated) continue;
            foreach (decl; rule.declarations)
                if (decl.property == "content") addCssContent(decl.value, (uint c) { points ~= c; });
        }
        points.sort();
        uint[] unique;
        foreach (p; points)
            if (unique.length == 0 || unique[$ - 1] != p) unique ~= p;
        return unique;
    }

    /// Hand every code point a CSS string value draws to `sink`: the literal
    /// characters, and each `\XXXXXX` escape, which is how generated content
    /// names a glyph from an icon font.
    private static void addCssContent(string value, scope void delegate(uint) sink)
    {
        string literal;
        void flush()
        {
            if (!literal.length) return;
            foreach (dchar c; literal) sink(cast(uint) c);
            literal = "";
        }
        for (size_t i = 0; i < value.length; i++)
        {
            if (value[i] != '\\') { literal ~= value[i]; continue; }
            size_t j = i + 1;
            uint code;
            int digits;
            while (j < value.length && digits < 6)
            {
                const c = value[j];
                uint d;
                if (c >= '0' && c <= '9') d = c - '0';
                else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
                else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
                else break;
                code = code * 16 + d;
                ++digits;
                ++j;
            }
            if (digits == 0) { literal ~= value[i]; continue; }
            flush();
            if (code <= 0x10FFFF) sink(code);
            i = j - 1;
        }
        flush();
    }

    /// The absolute URL a face loads from, resolved against the sheet that named
    /// it, or "" when it names none. A `data:` URL carries its own bytes and is
    /// returned untouched.
    private static string fontFaceUrl(WebFontFace face, string baseUrl)
    {
        auto url = face.url;
        if (!url.length) return "";
        const lower = url.toLower();
        const isData = lower.length >= 5 && lower[0 .. 5] == "data:";
        if (!isData && indexOf(url, "://") < 0)
            url = normalizeUrlPath(resolveUrl(baseUrl, url));
        return url;
    }

    /// True for a face URL that carries its own bytes instead of naming a file
    /// to download.
    private static bool isDataFontUrl(string url)
    {
        return url.length >= 5 && url[0 .. 5].toLower() == "data:";
    }

    /// Download, stage and register one `@font-face` source. Every failure is
    /// silent: a browser that cannot fetch or parse a face falls back to the
    /// next `font-family`, which is what shape resolution already does when no
    /// web face is registered.
    private void loadWebFontFace(WebFontFace face, string baseUrl)
    {
        const url = fontFaceUrl(face, baseUrl);
        if (!url.length) return;
        const isData = isDataFontUrl(url);
        if (auto cached = url in _webFontFaces)
        {
            if (*cached !is null)
                registerWebFace(face.family, face.weight, face.style, *cached);
            return;
        }
        FontFace loaded;
        try
        {
            auto bytes = isData ? decodeDataUrl(url) : fetchBytes(url);
            if (bytes.length)
                loaded = FontFace.tryLoad(stageFontFile(fontBytesFor(bytes)), 0);
        }
        catch (Exception) loaded = null;
        // A face that fails must not be re-fetched by every sheet naming it.
        _webFontFaces[url] = loaded;
        if (loaded !is null)
            registerWebFace(face.family, face.weight, face.style, loaded);
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
            loadWebFonts(css, baseUrl.length ? baseUrl : _currentUrl);
            _layoutDirty = true;
        }
    }

    /// Parse and execute a script string in the page's runtime.
    ///
    /// The document is bound once per page load. Re-binding for every script
    /// would hand each one a fresh `document`, cookie jar and storage area, so a
    /// page's own state would vanish between its scripts.
    void runScript(string source)
    {
        if (!_documentBound)
        {
            bindDocument(_root, _js, _js.globalScope, _resourceLoader, _currentUrl,
                _width, _height);
            _documentBound = true;
        }
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

    /// Note that the host has painted a frame. A `font-display: swap` face
    /// waits for this: the frame the user just saw drew the fallback face, and
    /// the next pass fetches the real one. `registerWebFace` drops the shaping
    /// caches, so that pass also measures and paints with the real face.
    void notePaint()
    {
        _paintedOnce = true;
        if (_deferredFaces.length) _layoutDirty = true;
    }

    /// Re-layout after DOM/style mutation.
    void layout()
    {
        // A deferred `font-display: swap` face waits for a frame to have been
        // painted: that frame showed the fallback face, which is what `swap`
        // asks for, and this pass downloads the real one. `registerWebFace`
        // drops the face and shaping caches, so this same pass measures and
        // paints the text with it. Keyed on a painted frame and not on a pass
        // count: the engine runs passes of its own inside the blocking
        // navigation, so a pass count let the download back into the load.
        if (_paintedOnce)
        {
            // A subset a page cannot use is a request and a decode spent for
            // nothing, and one measured page's 24 font files were 2.2 s of that
            // pass, so a face whose `unicode-range` cannot match any code point
            // the document draws is set aside instead of fetched.
            if (_unusedFaces.length)
            {
                // Text a script added since then may need one of them after all.
                auto points = textCodePoints();
                if (points != _unusedCodePoints)
                {
                    _deferredFaces ~= _unusedFaces;
                    _unusedFaces = [];
                }
            }
            if (_deferredFaces.length)
            {
                auto queued = _deferredFaces;
                _deferredFaces = [];
                _webFontsPending = false;
                auto points = textCodePoints();
                foreach (q; queued)
                {
                    if (faceCoversText(q.face, points)) loadWebFontFace(q.face, q.baseUrl);
                    else
                    {
                        _unusedFaces ~= q;
                        _unusedCodePoints = points;
                    }
                }
            }
        }
        // Resolving the cascade is the most expensive part of a pass, and the
        // document stays dirty while images trickle in a few per pass. Compare a
        // fingerprint of everything style resolution reads - the rule list, the
        // viewport, and each element's tag, attributes, child count and
        // interaction state - and reuse the computed styles when it is unchanged,
        // rebuilding only geometry. Without this the cascade ran once per arriving
        // image: 18-19 passes on a real page, and one large page's single pass
        // alone exceeded 90 seconds.
        const size_t inputs = styleInputsHash();
        if (inputs == _styleInputs)
        {
            import auroraweb.layout : layoutRoot = layout;
            layoutRoot(_root, _width, _height);
        }
        else
        {
            applyStylesAndLayout(_root, _rules, _width, _height);
            _styleInputs = inputs;
        }
        loadImages();
        _laidOutWidth = _width;
        _laidOutHeight = _height;
        // Images are fetched a few per pass, so a pass that deferred work leaves
        // the document dirty: the next paint loads more. Clearing this
        // unconditionally stranded every image after the first pass, which is
        // why a live browser showed none of them.
        _layoutDirty = _imagesPending || _webFontsPending;
        ++_layoutGen;
        ++_docPasses;
        // `IntersectionObserver` callbacks describe the geometry this pass just
        // produced, so they are delivered here - the point a browser queues them
        // too. A callback usually changes the DOM (adds a class, swaps a lazy
        // image in), so the document is dirty again when one ran.
        if (evaluateIntersectionObservers(_js))
            _layoutDirty = true;
    }

    /// Fingerprint of every input to style resolution (see `layout`). Attributes
    /// carry class/id/inline-style, so a JS-mutated class or custom property
    /// changes the hash and the cascade runs again.
    private size_t styleInputsHash()
    {
        size_t h = 1469598103934665603UL;   // FNV-1a
        void mix(string s)
        {
            foreach (ch; s)
            {
                h ^= cast(size_t) ch;
                h *= 1099511628211UL;
            }
        }
        void mixNum(size_t v)
        {
            foreach (i; 0 .. size_t.sizeof)
            {
                h ^= (v >> (i * 8)) & 0xff;
                h *= 1099511628211UL;
            }
        }
        void walk(Element e)
        {
            if (e is null) return;
            mix(e.tag);
            foreach (name, value; e.attrs)
            {
                mix(name);
                mix(value);
            }
            mix(e.hovered ? "hover" : "");
            mix(e.focused ? "focus" : "");
            mix(e.active ? "active" : "");
            mixNum(e.children.length);
            foreach (child; e.elements) walk(child);
        }
        mixNum(cast(size_t) _rules.ptr);
        mixNum(_rules.length);
        // The tree itself, not just its content: a re-parsed document (a retry
        // after a failed navigation) can be identical in tag/attribute terms yet
        // consist of brand-new elements whose style structs are empty, so it must
        // be styled again even though the content hash matches.
        mixNum(cast(size_t) _docGen);
        mixNum(cast(size_t) _width);
        mixNum(cast(size_t) _height);
        walk(_root);
        return h;
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

    /// Start a pass's recorded image requests together, without waiting for
    /// them. A worker fetches and does nothing else - no DOM, no resource cache,
    /// no trace, no decode - so the calling thread stays the only one touching
    /// page state. A lone URL is fetched here instead: a thread costs more than
    /// the request it carries.
    ///
    /// Returns true when the requests are now in flight on a worker: the caller
    /// must not fetch them itself and must keep asking for frames until a later
    /// pass collects them (see `collectImageBatch`). A pass that waited for its
    /// own batch instead froze the window for the whole download - measured
    /// 2.2 s for boqsc.eu's 1.6 MB + 3.5 MB pair - with the web-font pass queued
    /// behind it, which is the wait this split removes.
    ///
    /// The requests are one-shot (`keepAlive` false) for the reason given in
    /// `fetchImageBatch`: an off-thread socket must not outlive its own thread.
    private bool startImageBatch(string[] urls)
    {
        if (urls.length == 0) return false;
        // A page with its own resource loader owns its fetch path (a host's
        // custom scheme, a test double). A worker goes straight to the network
        // and would bypass it, so such a page keeps the serial walk instead,
        // which calls the loader on this thread as it expects.
        if (_resourceLoader !is null) return false;
        import auroraweb.net : loadTrace, loadTraceEnabled;
        if (loadTraceEnabled)
        {
            // One line per batch: how many requests it decided to start
            // together, and therefore whether they can overlap at all.
            loadTrace("image batch: ", urls.length, " url(s), ",
                urls.length > 1 ? "not waited for" : "fetched here");
            foreach (u; urls) loadTrace("  batch url: ", u);
        }
        if (urls.length == 1)
        {
            try
            {
                auto res = httpFetch(urls[0]);
                if (res.status == 200 && res.body.length)
                    _prefetchedResponses[urls[0]] = res;
            }
            catch (Throwable t)
            {
                if (loadTraceEnabled)
                    loadTrace("  batch fetch threw: ", urls[0], ": ", t.msg);
            }
            return false;
        }
        import std.parallelism : task;
        // The URLs are copied: the worker reads them while this pass walks on
        // and reuses its own collection buffer.
        _imageBatchUrls = urls.dup;
        _imageBatch = task!fetchImageBatch(_imageBatchUrls);
        // A thread of its own, not the shared pool: the batch is one long-lived
        // unit of work, and its groups are themselves spread over the pool (see
        // `fetchImageBatch`). The thread ends with the batch, so an off-thread
        // socket never outlives the call that opened it.
        _imageBatch.executeInNewThread();
        _imageBatchInFlight = true;
        return true;
    }

    /// Take the responses of the image batch this page started, once its worker
    /// is finished, as this pass's prefetched map. Returns false while the batch
    /// is still in flight, so the caller paints and asks again next pass instead
    /// of blocking on the download. `collectedNow` reports whether responses
    /// actually arrived, so the caller can tell "a batch landed" from "there was
    /// no batch" without looking at the map.
    private bool collectImageBatch(out HttpResponse[string] collected,
        out bool collectedNow)
    {
        collected = null;
        collectedNow = false;
        if (!_imageBatchInFlight) return true;
        if (!_imageBatch.done) return false;
        import auroraweb.net : loadTrace, loadTraceEnabled;
        auto responses = _imageBatch.yieldForce;
        _imageBatchInFlight = false;
        collectedNow = true;
        if (loadTraceEnabled)
            foreach (i, url; _imageBatchUrls)
                loadTrace("  batch result: ",
                    i < responses.length ? responses[i].body.length : 0,
                    " bytes  ", url);
        foreach (i, url; _imageBatchUrls)
            // Every recorded response, including a failure: the walk needs to
            // see the URL as "already answered" so it marks the element tried
            // instead of starting the same request again.
            if (i < responses.length && responses[i].finalUrl.length)
                collected[url] = responses[i];
        _imageBatchUrls.length = 0;
        return true;
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
        // Fetch a bounded batch per pass, and none until the document has been
        // laid out a few times. Its markup and styles are then on screen in the
        // first frames, and images keep arriving a few at a time while the host
        // repaints - instead of the whole image load happening in one pass
        // before that frame. Measured on boqsc.eu, the single pre-paint pass was
        // 8.4 s of frozen window with nothing painted until the last byte.
        // Keyed on a pass count rather than on a paint having happened, so a
        // host (or a test) that pumps `layout` still gets its images.
        enum networkImagesPerPass = 2;
        // The first image pass starts a couple of requests, then the budget
        // doubles. A flat pair per pass serialises the heavy images: measured on
        // boqsc.eu, three passes cost 1.06 s + 1.00 s + 2.30 s, because each pair
        // held one 1.6 MB icon plus one small .ico, so the two icons never went
        // out together at all. Ramping keeps the first paint on the first pair
        // (the page still appears at once) and stops a page with many images
        // from paying one fetch wall per pair.
        const int imageBudget = _docPasses >= 3
            ? networkImagesPerPass << (_imagePasses < 4 ? _imagePasses : 4)
            : 0;
        int networkFetchesLeft = imageBudget;
        bool deferredFetch = false;
        void walk(Element e)
        {
            // Whether this element may do network work, decided at the `<img>`
            // and background-image sites below, where the target URL is known.
            // Local work — a `data:` image, inline SVG, or nothing to load — is
            // never budgeted. A response the pass's batch already brought is
            // decoded without budget, since it costs no request: that is what
            // lets the pass which collects a batch finish its images instead of
            // fetching anything of its own (measured: without it those passes
            // did the page's remaining fetches inline, 950 ms and 2055 ms each).
            // Anything else costs one unit of this pass's budget, and out of
            // budget the walk stops at that element, leaving it untouched so it
            // is not marked as tried, for the next frame to continue. The
            // collect-only walk starts no request, but it is what sizes the next
            // batch, so it records at most this pass's budget and stops there.
            bool mayFetch(string target)
            {
                if (target in _prefetchedResponses) return true;
                // Bytes already in the resource cache cost no request either, so
                // they are decoded without budget. Charging for them made the
                // second element naming an image this pass had just fetched wait
                // for a later pass even though the bytes were in hand.
                if (auto hit = target in _resourceCache)
                    if (mayReuse(*hit)) return true;
                if (networkFetchesLeft <= 0)
                {
                    deferredFetch = true;
                    _imagesPending = true;
                    _layoutDirty = true;
                    return false;
                }
                networkFetchesLeft--;
                return true;
            }
            // Inline <svg> markup — the shape most icon markup takes in HTML.
            // Serialise the subtree and let the engine's own rasteriser read it.
            // The collect-only walk does none of this local work: it runs again
            // as the real walk, and an SVG decoded twice would be wasted.
            if (!_collectingUrls && e.tag == "svg" && e.image is null &&
                !e.imageLoadTried)
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
                    // Resolve the target before the mark and the budget check:
                    // a response this pass's batch already brought costs no
                    // budget and is decoded here, while anything else has to
                    // wait for a batch instead of blocking this frame.
                    // `data:` URLs are decoded locally; everything else is
                    // fetched (resolution would mangle a data URL). A page
                    // created without a URL (`setHtml`) has no base to resolve
                    // against, so the relative URL is kept as-is rather than
                    // resolving to the empty string.
                    auto srcValue = effective;
                    auto target = _currentUrl.length
                        ? resolveUrl(_currentUrl, srcValue) : srcValue;
                    const bool localData = srcValue.length >= 5 &&
                        srcValue[0 .. 5].toLower() == "data:";
                    if (!localData && !mayFetch(target)) return;
                    // Mark BEFORE fetching: a failing/absent URL must not be
                    // re-fetched on every layout (that repeated real network I/O
                    // once per frame while the image stayed unset).
                    // During the collect-only walk the element stays untouched,
                    // so the real walk reaches it again and finds the response
                    // this pass's batch fetched.
                    e.imageLoadTried = !_collectingUrls;
                    try
                    {
                        auto bytes = localData ? decodeDataUrl(srcValue)
                            : fetchBytes(target);
                        // A candidate that returned nothing (404, unsupported
                        // format) must fall back to the plain `src`, like a
                        // browser, instead of leaving a blank image.
                        if (!_collectingUrls && bytes.length == 0 &&
                            !e.imageFallbackTried &&
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
                    const bool localData = url.length >= 5 &&
                        url[0 .. 5].toLower() == "data:";
                    if (!localData && !mayFetch(resolveUrl(_currentUrl, url)))
                        return;
                    e.backgroundLoadTried = !_collectingUrls;
                    try
                    {
                        auto bytes = localData ? decodeDataUrl(url)
                            : fetchBytes(resolveUrl(_currentUrl, url));
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
        // Two walks over the same tree. The first only records the URLs this
        // pass would fetch - it starts no request and changes no element flag,
        // so the second walk selects exactly the same elements. Those requests
        // then go out together, and each image arrives over its own connection
        // instead of one request after another end to end: boqsc.eu's four
        // images were 4.8s of its load fetched that way. The second walk is the
        // load itself, and finds each response already in hand.
        //
        // A batch an earlier pass started may have arrived by now: its responses
        // become this pass's prefetched map, and the walk below decodes them on
        // this thread, exactly as when the pass had fetched them itself.
        HttpResponse[string] collected;
        bool collectedNow;
        const bool batchFinished = collectImageBatch(collected, collectedNow);
        _pendingImageUrls.length = 0;
        // The responses the batch brought are in hand before the collect-only
        // walk runs, so that walk neither charges budget for them nor records
        // them for the next batch (see fetchBytes). Recording them made the page
        // re-request images it had just received - djangoproject.com's shared
        // logo SVG among them. `collected` is empty when no batch landed, which
        // is exactly the clear this replaces.
        _prefetchedResponses = collected;
        if (_root !is null && imageBudget > 0 && batchFinished)
        {
            _collectingUrls = true;
            scope (exit) _collectingUrls = false;
            walk(_root);
        }
        // A pass that has just collected a batch starts nothing: the walk below
        // decodes the bytes that arrived, and only what still needs a request is
        // left recorded for the next batch, which the pass after this one starts.
        // Starting a batch here as well re-requested every image that had just
        // landed, so the page re-fetched its own images forever and never
        // settled (measured: the same five URLs at 1.2-4.2 s each, pass after
        // pass, and still pending after 20 s).
        bool startedBatch = false;
        bool walkedToFetch = false;
        if (collectedNow)
        {
            // Nothing new may be requested this pass: the responses the batch
            // brought are decoded without budget (see `mayFetch`) and everything
            // else waits for the batch the next pass starts. Spending the normal
            // budget here let the walk page past the responses it had and fetch
            // the rest of the page's images inline, which is a frame blocked for
            // the whole download again (measured: a 950 ms and a 2055 ms pass).
            networkFetchesLeft = 0;
        }
        else if (batchFinished)
        {
            // Start this pass's requests, but do not wait for them: the bytes
            // arrive while the host paints, and a later pass decodes them.
            // Waiting here was the rest of the freeze - measured 2.2 s for
            // boqsc.eu's 1.6 MB + 3.5 MB pair - with the web-font pass queued
            // behind it. A lone URL is fetched here instead (a thread costs more
            // than the request), and it is then in the map like a batch response.
            startedBatch = startImageBatch(_pendingImageUrls);
            if (startedBatch)
            {
                // The batch is in flight: this pass must fetch nothing of its
                // own. Leaving the budget the collect walk had used in place
                // made the walk request every image the batch had just started
                // a second time on this thread (measured: the batch and the walk
                // fetched each URL at the same instant, and the walk then ran
                // the page's images serially for another 3.5 s).
                networkFetchesLeft = 0;
            }
            else
            {
                networkFetchesLeft = imageBudget;
                walkedToFetch = true;
            }
        }
        else
        {
            // A batch is in flight: this pass fetches nothing of its own, so no
            // element is requested twice. The walk sees an empty map for those
            // URLs and leaves every network image to the pass that collects it.
            networkFetchesLeft = 0;
        }
        deferredFetch = false;
        if (_root !is null) walk(_root);
        // This pass moved requests along - started them, or spent budget on the
        // responses a batch brought - so the next pass may start more of them
        // together (the budget ramp above). A pass that only waited does not
        // count, or a slow batch would ramp the next one's size for nothing.
        if (startedBatch || collectedNow ||
            (walkedToFetch && networkFetchesLeft < imageBudget))
            ++_imagePasses;
        // Keep asking for frames while a batch is in flight, even when the walk
        // above had nothing left to defer: the batch's own responses still have
        // to be collected, and only a later pass can do that.
        if (!batchFinished)
        {
            _imagesPending = true;
            _layoutDirty = true;
        }
        // Responses the batch fetched but the walk did not need are dropped: they
        // were fetched for this pass, and the cache holds the ones that were used.
        _prefetchedResponses = null;
        _pendingImageUrls.length = 0;
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
        // The caller has already translated the canvas by the scroll offset, so
        // pass it along: `position: sticky` boxes need it to pin themselves.
        paintTree(_root, canvas, offsetY);
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

    // example.com's real document: <html> must start at the origin. Synthesised
    // html>body>p trees lay out correctly, so this reproduces the whole path
    // (parse + <style> extraction + layout) from the actual markup.
    {
        import std.conv : to;
        auto ec = new WebPage(1000, 900);
        ec.setHtml(
            `<!doctype html><html lang=en><head><meta charset=utf-8>` ~
            `<link rel=icon href=data:,><title>Example Domain</title><style>` ~
            `html{color-scheme:light dark;background:light-dark(#eee,#222)}` ~
            `body{font:16px/1.6 system-ui,sans-serif;max-width:26em;margin:auto;` ~
            `padding:25vh 2em 2em;text-align:center}</style></head>` ~
            `<body><p>This domain is for use in documentation examples.</p>` ~
            `<script src=/s.js></script></body></html>`);
        // Layout FIRST, and repeatedly: the live page re-runs layout (images,
        // reflow), and asserting before layout measures nothing but zeros.
        // PROVEN by this test: a SINGLE layout centres the body correctly, and
        // this assertion held at x=260 mLeft=260 w=416 cw=1000 fs=16. A SECOND
        // layout() resets the centring to 0 - and a trace inside layoutBlock's
        // auto-margin branch showed it computing 260 on BOTH passes, so the
        // value is lost after the branch, within the second pass or its caller.
        // That is the single remaining step; everything else is verified.
        ec.layout();
        ec.layout();
        auto ecRoot = ec.root();
        assert(ecRoot !is null, "example.com's document must produce a root");
        assert(ecRoot.tag == "html" || ecRoot.tag == "body",
            "the root must be html or body, got " ~ ecRoot.tag);
        if (ecRoot.tag == "html")
            assert(ecRoot.box.x == 0 && ecRoot.box.y == 0,
                "the html box must start at the page origin, got (" ~
                to!string(ecRoot.box.x) ~ "," ~ to!string(ecRoot.box.y) ~ ")");
        // The body's centring through the real document path. The page's exact
        // CSS centres correctly in a constructed tree, so this is the case that
        // differs - asserted here so the difference cannot hide again.
        Element ecBody;
        foreach (e; ecRoot.elements)
            if (e.tag == "body")
            {
                ecBody = e;
                break;
            }
        assert(ecBody !is null, "the document must contain a body");
        // Verified correct on the real document path.
        assert(ecBody.box.width == 416 && ecBody.box.paddingLeft == 32,
            "26em must clamp to 416 and 2em padding to 32; got w=" ~
            to!string(ecBody.box.width) ~ " padL=" ~ to!string(ecBody.box.paddingLeft));
        // The real page's body must centre, and this runs layout() twice - the
        // exact case that used to fail. The leftover in layoutBlock was
        // subtracting the auto margins' already-distributed values, so the
        // second pass computed 1000-416-64-260-260 = 0 and un-centred the body.
        // Only non-auto margins are constraints now.
        assert(ecBody.box.x == 260,
            "example.com's body must centre at (1000-416-64)/2 = 260; got x=" ~
            to!string(ecBody.box.x) ~ " mLeft=" ~ to!string(ecBody.box.marginLeft) ~
            " w=" ~ to!string(ecBody.box.width) ~
            " padL=" ~ to!string(ecBody.box.paddingLeft) ~
            " cw=" ~ to!string(ecBody.style.containingWidth) ~
            " fs=" ~ to!string(ecBody.style.fontSizePx));
    }

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
    // error accumulated through nested blocks). The fixture body pins its own
    // margin so the origin under test is the div's, not the UA body margin.
    auto z0p = new WebPage(300, 200);
    z0p.setHtml(`<html><body style="margin: 0">` ~
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
        // The rule targets <body>, so assert on the body: the root is now the
        // document's <html> (as parseHtml documents), where before it was the
        // synthetic body and this passed by accident.
        Element lnkBody = lnk.root();
        foreach (e; lnkBody.elements)
            if (e.tag == "body")
            {
                lnkBody = e;
                break;
            }
        assert(lnkBody.style.background == "#001122" ||
            lnkBody.style.background.indexOf("001122") >= 0,
            "a linked stylesheet must be fetched and applied; body background was '" ~
            lnkBody.style.background ~ "'");
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

unittest
{
    import std.conv : to;

    // Which `<script>` elements are collected for execution, and what an
    // external one is recorded as. A data block (`application/json` /
    // `application/ld+json`) and a module must not be evaluated as a classic
    // script: running one is a script error on a page that is otherwise fine,
    // and a module's deferred scope is not the classic script's.
    auto page = new WebPage(800, 600);
    // A document has an address: an external script's relative URL resolves
    // against it (a page loaded without one has no script to fetch).
    page._currentUrl = "https://example.com/index.html";
    page.setHtml(
        `<html><head>` ~
        `<script type="application/json">{"a":1}</script>` ~
        `<script type="module">import x from "./y.js";</script>` ~
        `<script type="text/javascript">window.typed = 1;</script>` ~
        `<script type="text/JavaScript; charset=utf-8">window.typed2 = 2;</script>` ~
        `<script>window.plain = 3;</script>` ~
        `<script src="/assets/app.js"></script>` ~
        `<script src="app.js"></script>` ~
        `<script src="https://cdn.example.com/x.js"></script>` ~
        `<script src=""></script>` ~
        `<script type="application/ld+json">{}</script>` ~
        `</head><body></body></html>`);
    string collected;
    foreach (pending; page._pendingScripts)
        collected ~= "[" ~ pending.src ~ "|" ~ pending.code ~ "]";
    assert(page._pendingScripts.length == 6,
        "expected six runnable scripts, got " ~ to!string(page._pendingScripts.length)
        ~ ": " ~ collected);
    assert(page._pendingScripts[0].code == "window.typed = 1;" &&
        page._pendingScripts[1].code == "window.typed2 = 2;" &&
        page._pendingScripts[2].code == "window.plain = 3;",
        "inline scripts must be kept in document order");
    assert(page._pendingScripts[3].src == "https://example.com/assets/app.js" &&
        page._pendingScripts[4].src == "https://example.com/app.js" &&
        page._pendingScripts[5].src == "https://cdn.example.com/x.js",
        "an external script must be collected as its resolved URL: " ~ collected);

    // The document's scripts run, and `DOMContentLoaded` is reported once they
    // have: a script that waits for the event before touching the DOM (the
    // Django header's switcher does) must not be left hanging.
    auto loaded = new WebPage(400, 300);
    loaded.setHtml(`<html><body><p id="p">before</p><script>` ~
        `document.addEventListener("DOMContentLoaded", function () {` ~
        `  document.getElementById("p").textContent = "after";` ~
        `});</script></body></html>`);
    loaded.executeScripts();
    loaded.layout();
    Element findParagraph(Element e)
    {
        if (e is null) return null;
        if (e.tag == "p") return e;
        foreach (child; e.elements)
        {
            auto found = findParagraph(child);
            if (found !is null) return found;
        }
        return null;
    }
    auto p = findParagraph(loaded.root());
    assert(p !is null, "the paragraph must exist");
    assert(p.textContent() == "after",
        "DOMContentLoaded must fire after the document's scripts, got '"
        ~ p.textContent() ~ "'");

    // A script that sets the html element's data attribute — how a page's own
    // theme switcher records the chosen theme — reaches the DOM node.
    auto themed = new WebPage(400, 300);
    themed.setHtml(`<html><body><script>` ~
        `document.documentElement.dataset.theme = "dark";` ~
        `</script></body></html>`);
    themed.executeScripts();
    themed.layout();
    auto themeAttr = "data-theme" in themed.root().attrs;
    assert(themeAttr !is null && *themeAttr == "dark",
        "the script's data-theme must reach the html element");
}

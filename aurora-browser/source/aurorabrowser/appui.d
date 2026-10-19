module aurorabrowser.appui;

/**
 * Aurora Browser UI — the chrome and page-view widgets.
 *
 * The shell follows the repository's current window-shell pattern: a manual
 * top-level `Widget` root (`BrowserRoot`) places every region explicitly, a
 * `FramelessWindowTitleBar` subclass (`BrowserTitleBar`) owns native window
 * movement, work-area maximize/restore, restore-on-drag, aero snapping, the
 * snap-preview overlay, and the owner-drawn system menu, and a disabled
 * `WindowBorder` paints the one-pixel frame. The tab strip is a row of real
 * per-tab `TabButton` widgets (activate on body click, close on the ✕ region),
 * not a single concatenated label.
 *
 * Page content is rendered by the `aurora-web` engine (`WebPage`) into a
 * `WebPageView` widget that overrides `Widget.onPaint` and drives
 * `WebPage.layout`/`WebPage.paint` from the real Aurora `Canvas`.
 *
 * Navigation: `auroraweb:` URLs resolve against a small built-in scheme backed
 * by constant HTML test pages so the shell runs without any network; `http://`
 * and `https://` URLs navigate the real `aurora-web` network layer (WinINet)
 * through `WebPage.navigate`. Plain words are treated as search terms.
 * `<a href>` links hit-tested in the page view navigate the active tab.
 */

import aurora;
import auroraweb;
import auroraweb.dom : Element;

import std.algorithm : startsWith;
import std.conv : to;
import std.file : exists, getcwd, readText, write;
import std.path : baseName, buildPath;
import std.string : indexOf, lastIndexOf, strip, toLower;
import core.memory : GC;
import std.utf : toUTF32;

// ---------------------------------------------------------------------------
// Chrome metrics (logical pixels)
// ---------------------------------------------------------------------------

private enum int BrowserTitleBarHeight = 32;
private enum int BrowserTabStripHeight = 34;
private enum int BrowserTabHeight = 30;
private enum int BrowserTabCloseWidth = 22;
private enum int BrowserToolbarHeight = 44;
private enum int BrowserBookmarksHeight = 28;
private enum int BrowserStatusHeight = 24;
private enum int BrowserNewTabWidth = 32;

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// Windows-10-style light browser palette, shared by the shell and titlebar.
Theme browserTheme()
{
    auto theme = Theme.light();
    theme.windowBackground = Color.fromHex(0xf3f3f3);
    theme.panelBackground = Color.fromHex(0xf7f7f7);
    theme.panelElevated = Color.fromHex(0xffffff);
    theme.text = Color.fromHex(0x1a1a1a);
    theme.textMuted = Color.fromHex(0x5f6368);
    theme.border = Color.fromHex(0xd6d6d6);
    theme.accent = Color.fromHex(0x0078d4);
    theme.accentHover = Color.fromHex(0x106ebe);
    theme.accentPressed = Color.fromHex(0x005a9e);
    theme.selection = Color.fromHex(0xcce8ff);
    theme.selectionText = Color.fromHex(0x1a1a1a);
    theme.fieldBackground = Color.fromHex(0xffffff);
    theme.buttonBackground = Color.fromHex(0xefefef);
    theme.buttonHover = Color.fromHex(0xe2e2e2);
    theme.buttonPressed = Color.fromHex(0xd4d4d4);
    theme.disabled = Color.fromHex(0xb0b0b0);
    theme.danger = Color.fromHex(0xe81123);
    theme.cornerRadius = 4;
    theme.controlHeight = 30;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

/// Windows-10-style dark browser palette.
Theme darkBrowserTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x202020);
    theme.panelBackground = Color.fromHex(0x262626);
    theme.panelElevated = Color.fromHex(0x2b2b2b);
    theme.text = Color.fromHex(0xffffff);
    theme.textMuted = Color.fromHex(0xa0a0a0);
    theme.border = Color.fromHex(0x3f3f3f);
    theme.accent = Color.fromHex(0x4f8cff);
    theme.accentHover = Color.fromHex(0x6ca0ff);
    theme.accentPressed = Color.fromHex(0x3974df);
    theme.selection = Color.fromHex(0x1e6fbf);
    theme.selectionText = Color.fromHex(0xffffff);
    theme.fieldBackground = Color.fromHex(0x1e1e1e);
    theme.buttonBackground = Color.fromHex(0x333333);
    theme.buttonHover = Color.fromHex(0x3c3c3c);
    theme.buttonPressed = Color.fromHex(0x4a4a4a);
    theme.disabled = Color.fromHex(0x6e6e6e);
    theme.danger = Color.fromHex(0xff6b6b);
    theme.cornerRadius = 4;
    theme.controlHeight = 30;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

// ---------------------------------------------------------------------------
// Offline page source
// ---------------------------------------------------------------------------

/// Default home page URL (overridable through the home.txt settings file).
immutable string defaultHomeUrl = "auroraweb:hello";

/// Small settings file that persists the home page across launches.
immutable string homeSettingsFile = "home.txt";

/// Settings file that persists bookmarks across launches (one URL per line).
immutable string bookmarksSettingsFile = "bookmarks.txt";

/// Serialise bookmarks for the settings file: one URL per line.
string bookmarksToText(in string[] urls)
{
    string text;
    foreach (url; urls)
        if (url.length) text ~= url ~ "\n";
    return text;
}

/// Parse the bookmarks settings file back to a URL list.
string[] bookmarksFromText(string text)
{
    string[] urls;
    size_t pos;
    while (pos < text.length)
    {
        auto nl = indexOf(text, "\n", pos);
        auto line = nl < 0 ? text[pos .. $] : text[pos .. nl];
        line = line.strip();
        if (line.length)
        {
            bool seen = false;
            foreach (u; urls) if (u == line) { seen = true; break; }
            if (!seen) urls ~= line;
        }
        if (nl < 0) break;
        pos = nl + 1;
    }
    return urls;
}

/// Path of the bookmarks settings file (same directory as home.txt).
private string bookmarksSettingsPath()
{
    try
    {
        return buildPath(getcwd(), baseName(bookmarksSettingsFile));
    }
    catch (Exception)
    {
        return bookmarksSettingsFile;
    }
}

/// Read persisted bookmarks (empty when the file is missing or unreadable).
private string[] loadBookmarks()
{
    try
    {
        if (exists(bookmarksSettingsPath()))
            return bookmarksFromText(readText(bookmarksSettingsPath()));
    }
    catch (Exception)
    {
    }
    return [];
}

/// Persist bookmarks (best-effort: never fail the interaction for settings).
private void saveBookmarks(in string[] urls)
{
    try
    {
        write(bookmarksSettingsPath(), bookmarksToText(urls));
    }
    catch (Exception)
    {
    }
}

/// Path of the settings file, rooted at the browser working directory (the
/// repo's `aurora-browser/` when run through dub / the bat file).
private string homeSettingsPath()
{
    try
    {
        return buildPath(getcwd(), baseName(homeSettingsFile));
    }
    catch (Exception)
    {
        return homeSettingsFile;
    }
}

/// Read the persisted home URL, falling back to `defaultHomeUrl`.
private string loadHomeUrl()
{
    try
    {
        if (exists(homeSettingsPath()))
        {
            auto text = readText(homeSettingsPath()).strip();
            if (text.length > 0) return text;
        }
    }
    catch (Exception)
    {
    }
    return defaultHomeUrl;
}

/// Persist the home URL (writes the settings file).
private void saveHomeUrl(string url)
{
    try
    {
        write(homeSettingsPath(), url ~ "\n");
    }
    catch (Exception)
    {
        // Settings persistence is best-effort; never fail navigation for it.
    }
}

/// Resolve an `auroraweb:` URL to HTML. Anything else (plain words and other
/// schemes) is treated as a search term. HTTP/HTTPS never reaches this helper;
/// `WebPageView.loadIntoPage` routes those through `WebPage.navigate`.
private string fetchHtml(string url)
{
    const u = url.toLower();

    if (u.startsWith("auroraweb:"))
        return builtInPage(url[u.indexOf(":") + 1 .. $]);

    // A plain word (or anything without a scheme) becomes a search page.
    return builtInPage("search");
}

/// Map an `auroraweb:` path (scheme prefix stripped) to a page body.
private string builtInPage(string path)
{
    const p = path.strip();
    if (p == "hello" || p.length == 0)
        return helloPageHtml();
    if (p == "css")
        return cssPageHtml();
    if (p == "js")
        return jsPageHtml();
    if (p.startsWith("search") || p == "search")
        return searchPageHtml();
    if (p == "links")
        return linksPageHtml();
    if (p == "scroll")
        return scrollPageHtml();
    if (p == "interact")
        return interactPageHtml();
    if (p == "async")
        return asyncPageHtml();
    if (p == "timer")
        return timerPageHtml();
    if (p == "complex")
        return complexPageHtml();
    if (p == "remote")
        return remotePageHtml();
    if (p == "error404")
        return error404PageHtml();
    return errorPageHtml(p, "Unknown page '" ~ p ~ "'. Try auroraweb:hello, " ~
        "auroraweb:css, auroraweb:js, auroraweb:links, auroraweb:async, " ~
        "auroraweb:timer, auroraweb:remote or auroraweb:complex.");
}

/// Page for exercising real interactivity end to end: an inline-`onclick`
/// button, a `:hover` style, and a text input.
private string interactPageHtml()
{
    return `<html><head><style>
      body { background: #f2f2f5; color: #101014; padding: 16px; }
      #btn { display: inline-block; padding: 10px 16px; background: #e8e8ee; font-size: 16px; }
      #btn:hover { background: #ffd54a; font-size: 20px; }
      #out { font-size: 16px; margin-top: 12px; }
      #field { font-size: 16px; width: 220px; }
    </style></head><body>
      <div id="btn" onclick='document.getElementById("out").textContent = "clicked";'
        onwheel='this.setAttribute("wheeled","1")'
        ondblclick='this.setAttribute("dbl","1")'
        onmouseenter='this.setAttribute("entered","1")'
        onmouseleave='this.setAttribute("left","1")'
        oncontextmenu='event.preventDefault(); this.setAttribute("menu","1")'>Click me</div>
      <div id="out">not clicked</div>
      <input id="field" value="type here" />
      <input id="field2" value="" placeholder="Search the docs" />
      <div style="height:600px"></div>
    </body></html>`;
}

/// Tall page to exercise vertical scrolling.
private string scrollPageHtml()
{
    string body;
    body ~= `<!DOCTYPE html><html><head><title>Aurora Scroll</title></head>
<body style="background:#f6f8fa;color:#1b1f23;padding:16px">`;
    body ~= `<h1>Scroll Test</h1>`;
    foreach (i; 0 .. 120)
        body ~= `<p>Paragraph ` ~ to!string(i) ~
            ` — enough text to overflow the viewport and require scrolling.</p>`;
    body ~= `</body></html>`;
    return body;
}

/// Async/await showcase: the inline script uses `async function` + `await`
/// on a Promise to mutate the document after resolution.
private string asyncPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora Async</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Async / Await</h1>
  <p id="status">waiting…</p>
  <script>
    function later(v) {
      return new Promise(function(resolve) { resolve(v * 10); });
    }
    async function run() {
      var a = await later(3);
      var b = await later(a);
      document.getElementById("status").textContent = "3 * 10 * 10 = " + b;
    }
    run();
  </script>
</body>
</html>`;
}

/// Event-loop showcase: the inline script schedules a one-shot timeout, a
/// repeating interval (cleared after a few ticks) and a chain of
/// requestAnimationFrame callbacks. All three are driven by the cross-platform
/// event loop that the browser host pumps from its per-frame tick.
private string timerPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora Event Loop</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Event Loop</h1>
  <p id="t">timeout pending</p>
  <p id="iv">interval pending</p>
  <p id="raf">raf pending</p>
  <script>
    var frames = 0;
    function step() {
      frames++;
      document.getElementById("raf").textContent = "raf frames: " + frames;
      if (frames < 3) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
    setTimeout(function() {
      document.getElementById("t").textContent = "timeout fired";
    }, 20);
    var ticks = 0;
    var handle = setInterval(function() {
      ticks++;
      document.getElementById("iv").textContent = "interval ticks: " + ticks;
      if (ticks >= 3) clearInterval(handle);
    }, 10);
  </script>
</body>
</html>`;
}

/// Home page: title, text, a heading, and a couple of <p> paragraphs.
private string helloPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora Home</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Aurora Browser</h1>
  <p>This page is rendered entirely by the aurora-web engine on Aurora-D.
  There is no Chromium, no WebKit and no network involved.</p>
  <p>Type <b>auroraweb:css</b> to see CSS colors and boxes, or
  <b>auroraweb:js</b> to see the JavaScript engine.</p>
</body>
</html>`;
}

/// Link navigation showcase: an <a href> whose box is hit-tested when the
/// user clicks the rendered page (see WebPageView.hitTestLink). Anchors use
/// `display:inline-block` so the engine's layout pass fills `Element.box`.
private string linksPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora Links</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Links</h1>
  <p><a id="home" style="display:inline-block" href="auroraweb:hello">Home</a></p>
  <p><a id="css-link" style="display:inline-block" href="auroraweb:css">CSS</a></p>
  <p><a id="js-link" style="display:inline-block" href="auroraweb:js">JS</a></p>
</body>
</html>`;
}

/// CSS showcase: inline <style>, colors, margins, borders.
private string cssPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora CSS</title>
  <style>
    .card { background:#ffffff; border:1px solid #d0d7de; padding:12px; margin:12px; }
    h2 { color:#0969da; }
    p.green { color:#1a7f37; }
  </style>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:16px">
  <h2>CSS Support</h2>
  <div class="card"><p class="green">This card uses an inline stylesheet:
  colors, margins, padding and borders.</p></div>
  <div class="card"><p>Only a pragmatic CSS subset is implemented — inline
  block flow, colors, backgrounds and simple boxes.</p></div>
</body>
</html>`;
}

/// JavaScript showcase: inline <script> runs through the D JS interpreter.
private string jsPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora JS</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>JavaScript</h1>
  <p>Inline scripts run on the from-scratch D interpreter:</p>
  <script>
    var nums = [1, 2, 3];
    var total = 0;
    for (var i = 0; i < nums.length; i++) { total += nums[i]; }
    document.body.textContent = "1+2+3 = " + total;
  </script>
</body>
</html>`;
}

/// A realistic page with nested divs, lists, headings and mixed inline
/// content — used to stress the layout for overlap.
private string complexPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head><title>Aurora Complex</title></head>
<body style="background:#f6f8fa;color:#1b1f23;padding:16px">
  <h1>Complex Layout</h1>
  <p>This paragraph has <b>bold</b>, <i>italic</i>, and
  <a href="auroraweb:hello" style="display:inline-block">a link</a> inline.</p>
  <div style="background:#eee;padding:8px;margin:8px">
    <h2>Section A</h2>
    <p>Text inside a box with a <b>nested bold</b> run.</p>
    <ul>
      <li>First item</li>
      <li>Second item with a longer sentence that should wrap across a few words.</li>
      <li>Third</li>
    </ul>
  </div>
  <div style="background:#ddd;padding:8px;margin:8px">
    <h2>Section B</h2>
    <p>Another box with more words to confirm blocks stack correctly and do
    not overlap one another in any way.</p>
  </div>
  <p>Trailing paragraph after both boxes.</p>
</body>
</html>`;
}

/// Search placeholder page for plain words typed in the address bar.
private string searchPageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Aurora Search</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Search</h1>
  <p>Offline shell — a plain word opens this placeholder search page.
  Typing a URL such as <b>auroraweb:hello</b> opens a page.</p>
</body>
</html>`;
}

/// A fake "remote" page (title + paragraphs) so the offline shell can exercise
/// remote-page bookkeeping (title extraction, tab strip labels) with no network.
private string remotePageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>Remote</title>
</head>
<body style="background:#f6f8fa;color:#1b1f23;padding:32px">
  <h1>Remote Page</h1>
  <p>This page mimics a document fetched from the network. It has a
  <b>&lt;title&gt;</b> of "Remote" so tab title extraction can be tested.</p>
  <p><a id="retry" style="display:inline-block" href="auroraweb:hello">Home</a></p>
</body>
</html>`;
}

/// A page that mimics a failed (404-style) remote response. Navigation here
/// must NOT grow the tab's history — the error is treated as a failed load.
private string error404PageHtml()
{
    return `<!DOCTYPE html>
<html>
<head>
  <title>404 Not Found</title>
</head>
<body style="background:#fff0f0;color:#7f1d1d;padding:32px">
  <h1>404 Not Found</h1>
  <p>The requested page could not be found. This mimics an HTTP 404 from a
  remote server; the previous history entry must be preserved.</p>
  <p><a id="retry" style="display:inline-block" href="auroraweb:hello">Go home</a></p>
</body>
</html>`;
}

/// Error page for failed / unsupported navigations. Shows the failing URL, a
/// short reason and a Retry link (display:inline-block so it fills a box for
/// hit-testing) that re-navigates to the failed URL on click.
private string errorPageHtml(string url, string message)
{
    return "<!DOCTYPE html><html><head><title>Navigation error</title></head>" ~
        "<body style=\"background:#fff0f0;color:#7f1d1d;padding:32px\">" ~
        "<h1>Navigation error</h1>" ~
        "<p><b>" ~ escapeHtml(url) ~ "</b></p>" ~
        "<p>" ~ escapeHtml(message) ~ "</p>" ~
        "<p><a id=\"retry\" style=\"display:inline-block;background:#e0b3b3;" ~
        "padding:8px 16px;margin-top:8px\" href=\"" ~ escapeHtml(url) ~
        "\">Retry</a></p></body></html>";
}

/// Escape &, < and > for HTML text/attribute context.
private string escapeHtml(string s)
{
    string result;
    foreach (ch; s)
    {
        switch (ch)
        {
            case '&': result ~= "&amp;"; break;
            case '<': result ~= "&lt;"; break;
            case '>': result ~= "&gt;"; break;
            default:  result ~= ch; break;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Widget that renders a WebPage
// ---------------------------------------------------------------------------

/**
 * Renders one `aurora-web` page. The engine paints into an Aurora Canvas; a
 * widget's `onPaint` is the natural place to call `page.layout()` and
 * `page.paint(canvas, 0, 0)` so the page becomes part of Aurora's retained
 * widget scene. The page view is re-laid out whenever it is resized.
 */
final class WebPageView : Widget
{
    /// Invoked when the user clicks a link; receives the resolved target URL.
    void delegate(string url) onLinkClicked;
    private WebPage _page;
    private int _viewportWidth;
    private int _viewportHeight;
    private string _url;
    private int _scrollY;
    private int _contentHeight;
    private int _contentGen = -1; /// layout generation _contentHeight was computed for
    private string _lastError;   /// reason of the last failed load ("" if ok)
    private string _failedUrl;   /// URL that failed; "" if the last load succeeded
    /// Accumulated host time (ms) fed to the page's event loop each tick.
    private double _loopClockMs;

    this(WebPage page)
    {
        setPage(page);
    }

    void setPage(WebPage page)
    {
        _page = page;
        if (page !is null)
        {
            _viewportWidth = maxInt(1, size().width);
            _viewportHeight = maxInt(1, size().height);
            // Load only what this view was actually given. `currentUrl` falls
            // back to the home page, so loading here made every caller that
            // constructs a view and then navigates pay for the home page TWICE:
            // `newTab` built a view (which loaded the home page), then loaded
            // the same page again - one complete document, its JS realm and its
            // first layout built and thrown away per tab, 77 MiB of live engine
            // state at startup for a document nobody ever saw.
            if (_url.length) loadIntoPage(_url);
        }
        invalidate();
    }

    WebPage page() { return _page; }

    /// Reset the scroll position when a new document is loaded.
    private void resetScroll()
    {
        _scrollY = 0;
    }

    /// Recompute the content height only when the page actually relaid out:
    /// `contentHeight()` is a full-tree walk and paint would otherwise run it on
    /// every frame.
    private void refreshContentHeight()
    {
        if (_page is null)
        {
            _contentHeight = 0;
            return;
        }
        const gen = _page.layoutGeneration();
        if (gen == _contentGen) return;
        _contentHeight = contentHeight();
        _contentGen = gen;
    }

    private int contentHeight()
    {
        if (_page is null) return 0;
        auto root = _page.root();
        if (root is null) return 0;
        int bottom = 0;
        void walk(Element e)
        {
            bottom = maxInt(bottom, e.box.y + e.box.height);
            foreach (c; e.elements) walk(c);
        }
        walk(root);
        return bottom;
    }

    /// Current vertical scroll offset (test-accessible).
    public int scrollYForTesting() const { return _scrollY; }

    void reload()
    {
        if (_page is null) return;
        loadIntoPage(currentUrl());
        invalidate();
    }

    void setUrl(string url)
    {
        if (_page is null) return;
        loadIntoPage(url);
        invalidate();
    }

    /// Start a load without waiting for it. The engine fetches the document on
    /// a worker and applies it in a later pass, so the host keeps painting - the
    /// loading state first, then the page as it arrives. The synchronous
    /// `setUrl` froze the window for the whole round trip: measured 2024 ms on
    /// one page with not a single frame painted, 1529 ms of it a stylesheet the
    /// first layout fetched inline.
    void beginLoad(string url)
    {
        if (_page is null) return;
        setCurrentUrl(url);
        _lastError = "";
        _failedUrl = "";
        _page.beginNavigate(url);
        invalidate();
    }

    /// True while a load started by `beginLoad` has not been applied yet.
    bool loadPending()
    {
        return _page !is null && _page.navigationPending();
    }

    /**
     * Load a document into the page. `auroraweb:` URLs use the offline built-in
     * pages; `http://`/`https://` URLs fetch the real document through the
     * engine's own HTTP client, and `file://` URLs read it from disk
     * (`WebPage.navigate`). Failed fetches show the built-in error page.
     */
    private void loadIntoPage(string url)
    {
        if (_page is null) return;
        const lower = url.toLower();
        _lastError = "";
        _failedUrl = "";
        if (lower.startsWith("auroraweb:"))
        {
            _page.setHtml(fetchHtml(url));
            _page.executeScripts();
        }
        else if (lower.startsWith("http://") || lower.startsWith("https://") ||
            lower.startsWith("file://"))
        {
            _page.navigate(url);
        }
        else
        {
            _page.setHtml(errorPageHtml(url,
                "Unsupported scheme in '" ~ url ~ "'."));
            _page.executeScripts();
        }
        // Lay out at the real viewport size; if the widget has no bounds yet
        // (first frame before layout), use a sane default so the first paint
        // is not a 1px-wide overlapping mess.
        if (_viewportWidth <= 1 && size().width > 1)
        {
            _viewportWidth = size().width;
            _viewportHeight = maxInt(1, size().height);
        }
        if (_viewportWidth <= 1)
            _page.resize(1024, 680);
        else
            _page.resize(_viewportWidth, _viewportHeight);
        _page.layout();
        resetScroll();
        // A fresh document resets its event loop; restart the host clock with it
        // so a page's first timers are measured from load, not from app start.
        _loopClockMs = 0.0;
        refreshContentHeight();

        // Failure detection now that styles are computed and the DOM is laid
        // out: error pages carry a pink background and (for network loads) the
        // engine's "Navigation failed"/"HTTP 404" text. Record the failed URL
        // so the shell can keep history clean.
        if (showsErrorPage())
        {
            _failedUrl = url;
            auto remoteReason = remoteLoadError();
            _lastError = remoteReason.length > 0 ? remoteReason :
                "error page for '" ~ url ~ "'";
        }
    }

    /// Test-only: has the current document navigated the engine (real fetch)?
    public bool isRemoteForTesting() const
    {
        return _url.length > 0 &&
            (_url.toLower().startsWith("http://") ||
             _url.toLower().startsWith("https://"));
    }

    /// Test-only: reason string of the last failed load ("" if the last load
    /// succeeded). This is how a 404-ish remote fetch is surfaced.
    public string errorReasonForTesting() const
    {
        return _lastError;
    }

    /// Test-only: URL of the last failed load ("" if none).
    public string failedUrlForTesting() const
    {
        return _failedUrl;
    }

    /// The layout engine paints error/404 pages with a pink background. Detect
    /// them so the shell can keep history clean (no broken entries).
    public bool showsErrorPage()
    {
        if (_page is null) return false;
        try
        {
            auto root = _page.root();
            if (root is null) return false;
            bool found;
            void walk(Element e)
            {
                if (found) return;
                auto bg = e.style.background.toLower();
                if (bg == "#fff0f0" || bg == "rgb(255, 240, 240)")
                {
                    found = true;
                    return;
                }
                foreach (c; e.elements)
                    walk(c);
            }
            walk(root);
            return found;
        }
        catch (Exception)
        {
        }
        return false;
    }

    /// After a remote fetch, ask the engine whether the document is an error
    /// page ("Navigation failed" / "HTTP 404"). Returns a reason, or "" if the
    /// page loaded fine.
    private string remoteLoadError()
    {
        try
        {
            if (_page is null) return "no page";
            auto root = _page.root();
            if (root is null) return "no document";
            string text = root.textContent();
            auto lower = text.toLower();
            if (lower.indexOf("navigation failed") >= 0)
                return "Navigation failed";
            if (lower.indexOf("http error") >= 0)
                return "HTTP error";
            if (lower.indexOf("http 404") >= 0)
                return "HTTP 404 Not Found";
            if (lower.indexOf("404 not found") >= 0)
                return "HTTP 404 Not Found";
        }
        catch (Exception)
        {
            return "error reading document";
        }
        return "";
    }

    /**
     * Walk the laid-out DOM and return the `href` of the topmost `<a>` element
     * whose box contains the point `(x, y)` in page coordinates. Returns "" if
     * no anchor is under the point. Boxes are absolute page coordinates; the
     * caller adds `_scrollY` to a view-local point before calling.
     */
    public string hitTestLink(int x, int y)
    {
        if (_page is null) return "";
        auto root = _page.root();
        if (root is null) return "";
        string found;
        void walk(Element e)
        {
            if (found.length) return;
            if (e.tag == "a")
            {
                auto href = "href" in e.attrs;
                if (href !is null && (*href).length &&
                    x >= e.box.x && x < e.box.x + e.box.width &&
                    y >= e.box.y && y < e.box.y + e.box.height &&
                    e.style.display != "none")
                {
                    found = *href;
                    return;
                }
            }
            foreach (c; e.elements)
                walk(c);
        }
        walk(root);
        return found;
    }

    /// Is the given view-local point over a link?
    private bool isOverLink(int x, int y)
    {
        return hitTestLink(x, y + _scrollY).length > 0;
    }

    override bool onMouseMove(ref Event event)
    {
        // Pointer over the page: track `:hover` and run mouseover/mousemove
        // handlers. Repaint only when the styled state actually changed.
        if (_page !is null &&
            _page.pointerMove(event.position.x, event.position.y + _scrollY))
            invalidate();
        if (isOverLink(event.position.x, event.position.y))
            setCursor(CursorKind.hand);
        else
            setCursor(CursorKind.arrow);
        return super.onMouseMove(event);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            // A page `contextmenu` handler may cancel the host's own menu.
            if (_page !is null)
                _page.contextMenu(event.position.x, event.position.y + _scrollY);
            return true;
        }
        if (event.button != MouseButton.left)
            return super.onMouseDown(event);
        requestFocus();
        if (_page !is null)
        {
            // Real click: run the page's DOM handlers (inline `onclick`,
            // `addEventListener`), focus whatever is under the pointer, and —
            // when nothing called preventDefault() — follow a link.
            const href = _page.click(event.position.x, event.position.y + _scrollY);
            invalidate();
            if (href.length > 0 && onLinkClicked !is null)
                onLinkClicked(resolveHref(href));
            return true;
        }
        return super.onMouseDown(event);
    }

    /// UI key -> DOM `event.key` name ("" when the page should not see it;
    /// printable characters arrive through onTextInput instead).
    private static string domKeyName(Key key)
    {
        switch (key)
        {
            case Key.backspace: return "Backspace";
            case Key.tab: return "Tab";
            case Key.enter: return "Enter";
            case Key.escape: return "Escape";
            case Key.pageUp: return "PageUp";
            case Key.pageDown: return "PageDown";
            case Key.end: return "End";
            case Key.home: return "Home";
            case Key.left: return "ArrowLeft";
            case Key.up: return "ArrowUp";
            case Key.right: return "ArrowRight";
            case Key.down: return "ArrowDown";
            case Key.insert: return "Insert";
            case Key.deleteKey: return "Delete";
            default: break;
        }
        return "";
    }

    override bool onKeyDown(ref Event event)
    {
        // Only when a page control has focus, and only for editing/navigation
        // keys — printable text comes through onTextInput.
        if (_page !is null && _page.focusedElement() !is null)
        {
            const name = domKeyName(event.key);
            if (name.length > 0)
            {
                _page.sendKey(name);
                invalidate();
                return true;
            }
        }
        return super.onKeyDown(event);
    }

    override bool onTextInput(ref Event event)
    {
        if (_page is null || _page.focusedElement() is null || event.text.length == 0)
            return false;
        import std.utf : encode;
        bool handled = false;
        foreach (ch; event.text)
        {
            if (ch < 0x20 || ch == 0x7f) continue;
            char[4] buf;
            const len = encode(buf, ch);
            if (_page.sendKey(buf[0 .. len].idup)) handled = true;
        }
        if (handled)
        {
            invalidate();
            return true;
        }
        return super.onTextInput(event);
    }

    /// Resolve a possibly-relative `href` against the current URL.
    string resolveHref(string href)
    {
        const base = currentUrl();
        if (href.length == 0) return base;
        if (href.indexOf("://") >= 0 || href.startsWith("about:") ||
            href.startsWith("data:") || href.startsWith("mailto:") ||
            href.startsWith("auroraweb:"))
            return href;
        if (href.length > 0 && href[0] == '#')
            return base;   // fragment-only; no re-navigation for this milestone
        const baseLower = base.toLower();
        if (!(baseLower.startsWith("http://") || baseLower.startsWith("https://")))
            return href;
        auto slash = base.lastIndexOf("/");
        if (slash < 0) slash = base.length;
        auto prefix = base[0 .. slash + 1];
        return prefix ~ href;
    }

    /// URL of the page currently attached to this view.
    string currentUrl()
    {
        if (_url.length > 0) return _url;
        return "auroraweb:hello";
    }

    void setCurrentUrl(string value)
    {
        _url = value;
    }

    /**
     * Pump the page's event loop once per host tick. Aurora's native loop ticks
     * continuously (~4 ms quantum), so this is where a page's `setTimeout`,
     * `setInterval` and `requestAnimationFrame` callbacks actually fire while
     * the browser sits idle. When a callback may have changed the DOM we
     * invalidate so the next paint re-runs style, layout and paint.
     */
    protected override void onTick(double deltaSeconds)
    {
        super.onTick(deltaSeconds);
        if (_page is null) return;
        // Guard against a NaN/absurd delta poisoning the clock forever.
        if (deltaSeconds > 0.0 && deltaSeconds < 10.0)
            _loopClockMs += deltaSeconds * 1000.0;
        bool changed = _page.serviceEventLoop(_loopClockMs);
        if (_page.animationFramePending())
            changed = _page.serviceAnimationFrame(_loopClockMs) || changed;
        // Images load a few per pass, so keep asking for frames while the
        // document still has pending work. Without this the browser painted
        // once and left every remaining image unfetched.
        if (_page.layoutPending())
            changed = true;
        if (changed)
            invalidate();
    }

    protected override void onBoundsChanged()
    {
        // The engine lays out at the viewport size; track it so a resize
        // re-lays-out at the new width.
        const w = size().width;
        const h = size().height;
        if (_page !is null && (w != _viewportWidth || h != _viewportHeight))
        {
            _viewportWidth = maxInt(1, w);
            _viewportHeight = maxInt(1, h);
            _page.resize(_viewportWidth, _viewportHeight);
            _page.layoutIfNeeded();
            refreshContentHeight();
            invalidate();
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_page is null)
        {
            canvas.fillRect(Rect(0, 0, size().width, size().height),
                Color.rgb(255, 255, 255));
            return;
        }
        // Skip the default white clear when the page paints its own canvas
        // background: the page's fill covers the whole viewport anyway, and a
        // full-viewport clear is a real per-frame cost.
        if (!_page.hasCanvasBackground())
            canvas.fillRect(Rect(0, 0, size().width, size().height),
                Color.rgb(255, 255, 255));
        // CRITICAL: ensure the page is laid out at the ACTUAL widget size.
        // If the view had no bounds when the page was loaded (created before
        // layout), the page may still be sized 1x1 -> every character wraps to
        // its own line and all text overlaps into an unreadable mess.
        const w = size().width;
        const h = size().height;
        if (w != _viewportWidth || h != _viewportHeight)
        {
            _viewportWidth = maxInt(1, w);
            _viewportHeight = maxInt(1, h);
            _page.resize(_viewportWidth, _viewportHeight);
        }
        _page.layoutIfNeeded();
        refreshContentHeight();
        // Clip to the widget and translate by the scroll offset.
        auto clipped = canvas.clipped(Rect(0, 0, size().width, size().height));
        auto translated = clipped.translated(0, -_scrollY);
        _page.paint(translated, 0, 0);
        // A painted frame is what a `font-display: swap` face waits for: this
        // frame is on screen, so the next pass may fetch the real face.
        _page.notePaint();
        // Scrollbar indicator (right edge).
        if (_contentHeight > size().height)
        {
            const track = size().height;
            const thumbH = maxInt(24, track * track / _contentHeight);
            const maxScroll = maxInt(0, _contentHeight - size().height);
            const thumbY = (maxScroll > 0) ?
                (track - thumbH) * _scrollY / maxScroll : 0;
            canvas.fillRect(Rect(size().width - 8, thumbY, 6, thumbH),
                Color.rgb(160, 170, 180));
        }
    }

    /// Double-click detection state (the host window may not report clickCount).
    private long _lastClickMs;
    private int _lastClickX;
    private int _lastClickY;

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || _page is null)
            return super.onMouseUp(event);
        // A double click is a second press soon after, at (nearly) the same
        // spot — the same heuristic a browser uses when no click count arrives.
        const x = event.position.x;
        const y = event.position.y;
        const dx = (x > _lastClickX) ? x - _lastClickX : _lastClickX - x;
        const dy = (y > _lastClickY) ? y - _lastClickY : _lastClickY - y;
        const dt = event.timestampMs - _lastClickMs;
        const isDouble = event.clickCount >= 2 ||
            (_lastClickMs != 0 && dt >= 0 && dt <= 500 && dx <= 4 && dy <= 4);
        _lastClickMs = event.timestampMs;
        _lastClickX = x;
        _lastClickY = y;
        if (isDouble)
        {
            _page.doubleClick(x, y + _scrollY);
            invalidate();
            return true;
        }
        return super.onMouseUp(event);
    }

    override bool onMouseWheel(ref Event event)
    {
        if (event.wheelY == 0) return false;
        // A page `wheel` handler may consume the gesture (zoom, carousel); when
        // it cancels the event the view must not also scroll.
        if (_page !is null && _page.wheel(event.position.x,
            event.position.y + _scrollY, event.wheelY))
            return true;
        const maxScroll = maxInt(0, _contentHeight - size().height);
        if (maxScroll == 0) return false;
        _scrollY = clampInt(_scrollY - event.wheelY * 24, 0, maxScroll);
        if (_page !is null) _page.notifyScroll(_scrollY);
        invalidate();
        return true;
    }
}

// ---------------------------------------------------------------------------
// Window chrome pieces (latest Aurora window-shell pattern)
// ---------------------------------------------------------------------------

/**
 * The Aurora Browser titlebar. Product identity lives here; Aurora's
 * `FramelessWindowTitleBar` owns movement, work-area maximize/restore,
 * restore-on-drag, snap-preview mapping, and the owner-drawn system menu.
 */
final class BrowserTitleBar : FramelessWindowTitleBar
{
    this(GuiWindow window)
    {
        super(window);
        setTitle("Aurora Browser");
        setIcon(IconKind.computer);
        setBarHeight(BrowserTitleBarHeight);
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(46);
        setTitleFontSize(12);
        setDarkMode(false);
    }

    /// Re-apply the light or dark Windows-10 palette to the titlebar.
    void setDarkMode(bool dark)
    {
        if (dark)
        {
            setBackground(Color.fromHex(0x2b2b2b));
            setInactiveBackground(Color.fromHex(0x222222));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0xffffff));
            setMutedTextColor(Color.fromHex(0xa0a0a0));
            setButtonHoverColor(Color.fromHex(0x3c3c3c));
            setButtonPressedColor(Color.fromHex(0x4a4a4a));
        }
        else
        {
            setBackground(Color.fromHex(0xf7f7f7));
            setInactiveBackground(Color.fromHex(0xefefef));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x5f6368));
            setButtonHoverColor(Color.fromHex(0xe2e2e2));
            setButtonPressedColor(Color.fromHex(0xd4d4d4));
        }
        setCloseHoverColor(Color.fromHex(0xe81123));
        setClosePressedColor(Color.fromHex(0xc42b1c));
    }
}

/**
 * A one-pixel border painted over every edge so the frameless window looks
 * like a real Windows-10 window. Created disabled so it never intercepts
 * pointer input (the host's hit test skips disabled widgets, exactly like the
 * snap-preview overlay).
 */
final class WindowBorder : Widget
{
    this()
    {
        setEnabled(false);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.strokeRect(Rect(0, 0, bounds().width, bounds().height),
            theme().border, 1);
    }
}

/**
 * One browser tab: a title, an active highlight, and a close (✕) region.
 * Clicking the body activates the tab; clicking the close region asks the
 * shell to close it. This replaces the old single concatenated label, which
 * could not be clicked, switched, or closed.
 */
final class TabButton : Widget
{
    private dstring _title;
    private bool _active;
    private bool _pressed;
    private bool _closeHover;

    void delegate() onActivate;
    void delegate() onClose;

    this(string title = "")
    {
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = BrowserTabHeight;
        layoutHints().minWidth = 110;
        setTitle(title);
    }

    dstring title() const @safe pure nothrow @nogc { return _title; }
    bool active() const @safe pure nothrow @nogc { return _active; }

    void setTitle(string value)
    {
        const next = toUTF32(value);
        if (next == _title) return;
        _title = next;
        recomputeWidth();
        invalidate();
    }

    void setActive(bool value)
    {
        if (_active == value) return;
        _active = value;
        invalidate();
    }

    private void recomputeWidth()
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = fontPixelSize(palette.fontScale);
        options.wrap = false;
        int textWidth;
        try
            textWidth = fontSystem().textEngine.layout(_title, options)
                .measuredSize().width;
        catch (Exception)
            textWidth = cast(int) _title.length * 8;
        layoutHints().preferredWidth =
            clampInt(textWidth + 40 + BrowserTabCloseWidth, 120, 240);
    }

    /// The ✕ close hit region at the tab's right edge.
    Rect closeRect() const @safe pure nothrow @nogc
    {
        return Rect(maxInt(0, bounds().width - BrowserTabCloseWidth - 4),
            maxInt(0, (bounds().height - 18) / 2), BrowserTabCloseWidth, 18);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const w = bounds().width;
        const h = bounds().height;
        if (_active)
            canvas.fillRoundedRect(Rect(0, 3, w, maxInt(1, h - 3)), 5,
                palette.panelElevated);
        else if (hovered())
            canvas.fillRoundedRect(Rect(0, 3, w, maxInt(1, h - 3)), 5,
                palette.buttonHover);
        if (_active)
            canvas.fillRect(Rect(0, 0, w, 3), palette.accent);

        const textRight = BrowserTabCloseWidth + 10;
        canvas.drawTextInRect(
            Rect(12, 0, maxInt(0, w - 12 - textRight), h),
            _title, _active ? palette.text : palette.textMuted,
            palette.fontScale, HorizontalAlign.left, VerticalAlign.middle, true);

        // Close affordance.
        const region = closeRect();
        if (_closeHover)
            canvas.fillRoundedRect(region, 4, palette.buttonPressed);
        const cx = region.x + region.width / 2;
        const cy = region.y + region.height / 2;
        const glyph = _active ? palette.text : palette.textMuted;
        canvas.drawLine(Point(cx - 4, cy - 4), Point(cx + 4, cy + 4), glyph, 2);
        canvas.drawLine(Point(cx + 4, cy - 4), Point(cx - 4, cy + 4), glyph, 2);
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left) return false;
        _pressed = true;
        _closeHover = closeRect().contains(event.position);
        requestFocus();
        captureMouse();
        invalidate();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        const over = closeRect().contains(event.position);
        if (over != _closeHover)
        {
            _closeHover = over;
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pressed) return false;
        _pressed = false;
        releaseMouse();
        const inClose = closeRect().contains(event.position);
        _closeHover = false;
        invalidate();
        if (inClose)
        {
            if (onClose !is null) onClose();
        }
        else if (containsLocal(event.position))
        {
            if (onActivate !is null) onActivate();
        }
        return true;
    }

    protected override void onMouseLeave()
    {
        if (_closeHover)
        {
            _closeHover = false;
            invalidate();
        }
    }
}

// ---------------------------------------------------------------------------
// Address field
// ---------------------------------------------------------------------------

/**
 * The address bar. Intercepts browser shortcuts (Alt+Left/Right, Ctrl+L)
 * so they work even while the field has keyboard focus — the base TextField
 * would otherwise swallow the arrows as caret movement.
 */
final class AddressField : TextField
{
    void delegate() onNavigateBack;
    void delegate() onNavigateForward;
    void delegate() onFocusAddress;

    this(string text = "")
    {
        super(text);
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.l)
        {
            if (onFocusAddress !is null) onFocusAddress();
            return true;
        }
        if (event.alt() && event.key == Key.left)
        {
            if (onNavigateBack !is null) onNavigateBack();
            return true;
        }
        if (event.alt() && event.key == Key.right)
        {
            if (onNavigateForward !is null) onNavigateForward();
            return true;
        }
        return super.onKeyDown(event);
    }
}

// ---------------------------------------------------------------------------
// One open tab
// ---------------------------------------------------------------------------

private struct Tab
{
    WebPage page;
    WebPageView view;
    string[] history;   /// visited URLs, oldest first
    int position;       /// current index in history
    string title;       /// last known page title
}

/// A network load that is still in flight. The engine has its request on a
/// worker, so the app cannot report success or failure when the load is asked
/// for; what the completion must do is recorded here and applied by
/// `BrowserRoot.onTick` once the document is in.
private struct PendingLoad
{
    bool active;
    int tabIndex;        /// tab the load belongs to (the user may switch away)
    string url;
    bool appendHistory;  /// commit a new history entry (address bar, link)
    int prevPosition;    /// history position to restore if the load fails
    string statusPrefix; /// "Loaded", "Back to", "Forward to", "Reloaded"
    bool updateChrome;   /// refresh the address bar, title and bookmark star
}

// ---------------------------------------------------------------------------
// Browser root
// ---------------------------------------------------------------------------

/**
 * The Aurora Browser root. A manual-layout `Widget` (the current window-shell
 * pattern): `onLayout` places the titlebar, tab strip, toolbar, bookmarks bar,
 * content area, status band, snap-preview overlay, and window border
 * explicitly, while each region keeps automatic inner layout (HBox/VBox).
 */
final class BrowserRoot : Widget
{
    private GuiWindow _window;
    private BrowserTitleBar _titleBar;
    private TitleBarSnapPreview _snapPreview;
    private WindowBorder _windowBorder;
    private bool _dark;

    private Tab[] _tabs;
    private int _active;

    private Button _backButton;
    private Button _forwardButton;
    private Button _reloadButton;
    private Button _homeButton;
    private AddressField _address;
    private Button _goButton;
    private Button _newTabButton;
    private Button _bookmarkButton;
    private Button _themeButton;
    private HBox _toolbar;
    private HBox _tabStrip;
    private HBox _bookmarksBar;
    private VBox _content;
    private Panel _statusBand;
    private Label _status;
    private TabButton[] _tabButtons;

    private string[] _bookmarks;   /// bookmarked URLs (order preserved)
    private string _homeUrl;       /// configured home page (persisted)
    private bool _loading;         /// page currently loading (status/button state)
    private PendingLoad _pendingLoad; /// network load still in flight (see onTick)
    /// A running browser keeps owing the OS the collector pages it frees: the
    /// D collector grows its pools to a multiple of the live heap and hands
    /// pages back only on `GC.minimize`, which nothing called. A blank window
    /// holding 127 MiB live kept 268 MiB resident, and one that had painted
    /// kept 672 MiB.
    private int _trimTicks;           /// ticks since the last idle trim

    this(GuiWindow window)
    {
        _window = window;
        _homeUrl = loadHomeUrl();
        // Bookmarks are loaded before the bar is built so saved favourites are
        // on screen immediately instead of vanishing between launches.
        _bookmarks = loadBookmarks();

        _titleBar = add(new BrowserTitleBar(window));

        // Regions, top to bottom. Each is a Box that lays out its own row.
        _tabStrip = add(new HBox(4, Insets(6, 2)));
        _tabStrip.setBackground(browserTheme().panelBackground);
        _toolbar = add(new HBox(6, Insets(8, 7)));
        _toolbar.setBackground(browserTheme().panelElevated);
        _bookmarksBar = add(new HBox(4, Insets(6, 4)));
        _bookmarksBar.setBackground(browserTheme().panelBackground);
        refreshBookmarksBar();
        _content = add(new VBox(0));
        _content.setBackground(Color.rgb(255, 255, 255));
        _statusBand = add(new Panel(browserTheme().panelBackground));
        _status = _statusBand.add(new Label("Ready"));
        _status.setId("br-status");
        _status.setScale(1);

        buildToolbar();
        refreshBookmarksBar();

        // Overlays: added last so they paint above all content. The preview is
        // created disabled, so it never intercepts pointer input.
        _snapPreview = add(new TitleBarSnapPreview());
        _titleBar.setSnapPreview(_snapPreview);
        _windowBorder = add(new WindowBorder());

        newTab(_homeUrl);
        updateStatus("Aurora Browser ready — type a URL or search term, or open "
            ~ "auroraweb:hello, auroraweb:css, auroraweb:js, auroraweb:links.");
        updateChrome();
    }

    // --- chrome construction ---------------------------------------------

    private void buildToolbar()
    {
        _backButton = _toolbar.add(new Button("", IconKind.up));
        _backButton.setId("br-back");
        _backButton.setIconSize(16);
        _backButton.setFlat(true);
        _backButton.layoutHints().preferredWidth = 34;
        _backButton.onClick = delegate() { navigateBack(); };

        _forwardButton = _toolbar.add(new Button("", IconKind.chevronRight));
        _forwardButton.setId("br-forward");
        _forwardButton.setIconSize(16);
        _forwardButton.setFlat(true);
        _forwardButton.layoutHints().preferredWidth = 34;
        _forwardButton.onClick = delegate() { navigateForward(); };

        _reloadButton = _toolbar.add(new Button("", IconKind.refresh));
        _reloadButton.setId("br-reload");
        _reloadButton.setIconSize(16);
        _reloadButton.setFlat(true);
        _reloadButton.layoutHints().preferredWidth = 34;
        _reloadButton.onClick = delegate() { reloadPage(); };

        _homeButton = _toolbar.add(new Button("", IconKind.home));
        _homeButton.setId("br-home");
        _homeButton.setIconSize(16);
        _homeButton.setFlat(true);
        _homeButton.layoutHints().preferredWidth = 34;
        _homeButton.onClick = delegate() { goHome(); };

        _address = _toolbar.add(new AddressField(""));
        _address.setId("br-address");
        _address.setPlaceholder("Enter a URL or search term");
        _address.layoutHints().flex = 1.0;
        _address.onSubmitted = delegate() { go(); };
        _address.onNavigateBack = delegate() { navigateBack(); };
        _address.onNavigateForward = delegate() { navigateForward(); };
        _address.onFocusAddress = delegate()
        {
            _address.requestFocus();
            _address.selectAll();
        };

        _goButton = _toolbar.add(new Button("Go"));
        _goButton.setId("br-go");
        _goButton.setAccent(true);
        _goButton.onClick = delegate() { go(); };

        _bookmarkButton = _toolbar.add(new Button("☆"));
        _bookmarkButton.setId("br-bookmark");
        _bookmarkButton.setFlat(true);
        _bookmarkButton.layoutHints().preferredWidth = 34;
        _bookmarkButton.onClick = delegate() { toggleBookmark(); };

        _themeButton = _toolbar.add(new Button("", IconKind.settings));
        _themeButton.setId("br-theme");
        _themeButton.setIconSize(16);
        _themeButton.setFlat(true);
        _themeButton.layoutHints().preferredWidth = 34;
        _themeButton.onClick = delegate() { toggleDarkMode(); };
    }

    /// Rebuild the tab strip: one `TabButton` per tab, then the "+" button,
    /// then a flex spacer so the tabs stay left-clustered.
    private void refreshTabStrip()
    {
        if (_tabStrip is null) return;
        _tabStrip.clearChildren();
        _tabButtons = [];
        foreach (index, tab; _tabs)
        {
            const title = tab.title.length > 0 ? tab.title : "New tab";
            auto button = _tabStrip.add(new TabButton(title));
            button.setId("br-tab-" ~ to!string(index));
            button.setActive(cast(int) index == _active);
            bindTabButton(button, cast(int) index);
            _tabButtons ~= button;
        }
        _newTabButton = _tabStrip.add(new Button("", IconKind.newDocument));
        _newTabButton.setId("br-newtab");
        _newTabButton.setIconSize(16);
        _newTabButton.setFlat(true);
        _newTabButton.layoutHints().preferredWidth = BrowserNewTabWidth;
        _newTabButton.onClick = delegate() { newTab(_homeUrl); };
        _tabStrip.add(new Spacer(1.0));
    }

    /// Bind a tab button's callbacks. `index` is a function parameter, so each
    /// call has its own stack slot and its delegates do not share the loop
    /// counter (a delegate created directly inside the `foreach` body would
    /// capture one reused variable and every tab would act on the last index).
    private void bindTabButton(TabButton button, int index)
    {
        button.onActivate = delegate() { switchTab(index); };
        button.onClose = delegate() { closeTab(index); };
    }

    // --- navigation -------------------------------------------------------

    /// Normalize user input: https:// prefix for plain host-like words,
    /// auroraweb: search for plain words.
    private string normalizeInput(string input)
    {
        const text = input.strip();
        if (text.length == 0) return "";
        const lower = text.toLower();
        if (lower.startsWith("http://") || lower.startsWith("https://") ||
            lower.startsWith("auroraweb:"))
            return text;
        if (lower.indexOf(".") >= 0 && lower.indexOf(" ") < 0)
            return "https://" ~ text;   // looks like a host name
        return "auroraweb:search?q=" ~ text;   // plain word -> search
    }

    private void go()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        const target = normalizeInput(_address.textUtf8());
        if (target.length == 0) return;
        navigateTo(target);
    }

    /// True for the URLs whose document is a network round trip. Any other
    /// scheme (`auroraweb:`, `file://`) is already local, so it keeps the
    /// synchronous path: deferring a read from disk buys nothing, and the
    /// built-in pages must be ready the moment they are asked for.
    private static bool isNetworkUrl(string url)
    {
        const lower = url.toLower();
        return lower.startsWith("http://") || lower.startsWith("https://");
    }

    /// Start a network load that does not block the window: the chrome shows
    /// its loading state at once, the engine fetches the document on a worker,
    /// and the outcome is applied by `onTick` when the document is in.
    private void beginNetworkLoad(string url, bool appendHistory,
        int prevPosition, string statusPrefix, bool updateChrome)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        _loading = true;
        _reloadButton.setIcon(IconKind.close);
        updateStatus("Loading " ~ url ~ "...");
        tab.view.setCurrentUrl(url);
        _pendingLoad = PendingLoad(true, _active, url, appendHistory,
            prevPosition, statusPrefix, updateChrome);
        tab.view.beginLoad(url);
        invalidate();
    }

    /// Apply a finished network load: the chrome, the status line and, when the
    /// request asked for it, the history entry. `onTick` calls this the moment
    /// the document is in, so the window stayed live for the whole download.
    private void finishNetworkLoad()
    {
        auto req = _pendingLoad;
        _pendingLoad.active = false;
        if (req.tabIndex < 0 || req.tabIndex >= cast(int) _tabs.length) return;
        auto tab = &_tabs[cast(size_t) req.tabIndex];
        const failed = tab.view.errorReasonForTesting().length > 0 ||
            tab.view.showsErrorPage();
        _loading = false;
        _reloadButton.setIcon(IconKind.refresh);
        const isActive = req.tabIndex == _active;
        if (failed)
        {
            tab.position = req.prevPosition;
            if (isActive)
            {
                updateChrome();
                updateStatus("Failed to load " ~ req.url);
            }
            return;
        }
        if (req.appendHistory)
        {
            tab.history.length = cast(size_t) req.prevPosition + 1;
            tab.history ~= req.url;
            tab.position = cast(int) tab.history.length - 1;
        }
        tab.title = pageTitle(tab.view);
        if (isActive && req.updateChrome)
        {
            _address.setText(req.url, false);
            setWindowTitle(tab.title);
            _bookmarkButton.setText(isBookmarked(req.url) ? "★" : "☆");
        }
        updateChrome();
        if (isActive)
            updateStatus(req.statusPrefix ~ " " ~ req.url);
    }

    /// Apply a finished network load, and keep asking for frames while one is
    /// still in flight: the engine's passes are what apply the document, and
    /// the host is what drives them.
    protected override void onTick(double deltaSeconds)
    {
        super.onTick(deltaSeconds);
        serviceSettledTrim();
        if (!_pendingLoad.active) return;
        if (_pendingLoad.tabIndex < 0 ||
            _pendingLoad.tabIndex >= cast(int) _tabs.length) return;
        auto tab = &_tabs[cast(size_t) _pendingLoad.tabIndex];
        if (tab.view.loadPending())
            invalidate();
        else
            finishNetworkLoad();
    }

    /**
     * Give the allocator's unused pages back to the OS while the browser idles.
     *
     * The D collector grows its pools to a multiple of the live heap and frees
     * pages only when `GC.minimize` is called - nothing called it, so a window
     * with 127 MiB live sat at 268 MiB resident, and one that had painted a
     * page sat at 672 MiB. Chrome paints allocate and drop far more than they
     * retain, so this repeats: trimming once is not enough, because the pool
     * grows again on the next repaint and then stays grown.
     *
     * It only runs when no load is in flight (a collection mid-load would stall
     * the very frames the user is waiting for) and only pays for `minimize`
     * when the collector is actually holding a pool it is not using.
     */
    private void serviceSettledTrim()
    {
        if (_pendingLoad.active)
        {
            _trimTicks = 0;
            return;
        }
        if (++_trimTicks < 120) return;
        _trimTicks = 0;
        GC.collect();
        if (GC.stats.freeSize > 32 * 1024 * 1024) GC.minimize();
    }

    private void navigateTo(string url)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        const prevPosition = tab.position;

        // A network document is fetched without blocking the window, so the
        // load starts here and its outcome is applied by `onTick`: the URL is
        // committed to history only once the document is in, exactly as the
        // synchronous path below commits it.
        if (isNetworkUrl(url))
        {
            beginNetworkLoad(url, true, prevPosition, "Loaded", true);
            return;
        }

        // Load first. On a successful load the URL is committed to history;
        // on failure the previous entry is preserved and the error page shown.
        const success = loadUrl(url);
        if (!success)
        {
            tab.position = prevPosition;
            updateChrome();
            updateStatus("Failed to load " ~ url);
            return;
        }

        // Truncate the forward history when a new entry is navigated.
        tab.history.length = cast(size_t) tab.position + 1;
        tab.history ~= url;
        tab.position = cast(int) tab.history.length - 1;
        tab.title = pageTitle(tab.view);
        updateChrome();
        updateStatus("Loaded " ~ url);
    }

    /// Load the URL into the active view, showing the "Loading..." busy state
    /// around the (synchronous) fetch. Returns true on success; false when the
    /// load failed and an error page is now displayed. With `updateChrome`
    /// true the address bar, window title and bookmark button follow the URL.
    private bool loadUrl(string url, bool updateChrome = true)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return false;
        auto tab = &_tabs[_active];

        _loading = true;
        _reloadButton.setIcon(IconKind.close);
        updateStatus("Loading " ~ url ~ "...");
        invalidate();

        tab.view.setCurrentUrl(url);
        tab.view.setUrl(url);
        tab.title = pageTitle(tab.view);

        const failed = tab.view.errorReasonForTesting().length > 0 ||
            tab.view.showsErrorPage();
        const success = !failed;

        _loading = false;
        _reloadButton.setIcon(IconKind.refresh);
        if (updateChrome)
        {
            _address.setText(url, false);
            setWindowTitle(tab.title);
            _bookmarkButton.setText(isBookmarked(url) ? "★" : "☆");
        }
        return success;
    }

    /// Update the chrome after a back/forward navigation to a history entry.
    private void loadHistoryEntry(int index, string statusPrefix)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        const url = tab.history[cast(size_t) index];
        // A network page is re-fetched without blocking the window; the
        // completion sets the title and the status line. History does not move:
        // back and forward already chose the entry.
        if (isNetworkUrl(url))
        {
            beginNetworkLoad(url, false, tab.position, statusPrefix, true);
            return;
        }
        loadUrl(url);
        tab.title = pageTitle(tab.view);
        updateStatus(statusPrefix ~ " " ~ url);
        updateChrome();
    }

    private void navigateBack()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        if (tab.position <= 0) return;
        --tab.position;
        loadHistoryEntry(tab.position, "Back to");
    }

    private void navigateForward()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        if (tab.position + 1 >= cast(int) tab.history.length) return;
        ++tab.position;
        loadHistoryEntry(tab.position, "Forward to");
    }

    private void reloadPage()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        if (isNetworkUrl(tab.view.currentUrl()))
        {
            beginNetworkLoad(tab.view.currentUrl(), false, tab.position,
                "Reloaded", true);
            return;
        }
        loadUrl(tab.view.currentUrl());
        tab.title = pageTitle(tab.view);
        setWindowTitle(tab.title);
        updateStatus("Reloaded " ~ tab.view.currentUrl());
        updateChrome();
    }

    private void goHome()
    {
        navigateTo(_homeUrl);
    }

    private void newTab(string url)
    {
        auto page = new WebPage(maxInt(1, _content.size().width),
            maxInt(1, _content.size().height));
        auto view = new WebPageView(page);
        view.setCurrentUrl(url);
        // The page view must be able to take keyboard focus so typed text and
        // edit keys reach the page's focused control.
        view.setFocusable(true);
        view.onLinkClicked = delegate(string target) { navigateTo(target); };

        Tab tab;
        tab.page = page;
        tab.view = view;
        tab.history = [url];
        tab.position = 0;
        tab.title = "New tab";

        _tabs ~= tab;
        _active = cast(int) _tabs.length - 1;
        switchTab(_active);

        // Commit the initial URL to history only when it loads successfully;
        // otherwise the history entry is dropped and an error page shown.
        // The address bar is cleared so the next typed URL replaces it.
        const loaded = loadUrl(url, false);
        if (loaded)
        {
            _tabs[_active].title = pageTitle(_tabs[_active].view);
            _address.setText("", false);
            setWindowTitle(_tabs[_active].title);
            updateChrome();
            updateStatus("Loaded " ~ url);
        }
        else
        {
            _tabs[_active].history.length = 0;
            _tabs[_active].position = 0;
            _tabs[_active].title = pageTitle(_tabs[_active].view);
            updateChrome();
        }
    }

    private void switchTab(int index)
    {
        if (index < 0 || index >= cast(int) _tabs.length) return;
        _active = index;
        _content.clearChildren();
        auto view = _tabs[cast(size_t) index].view;
        view.layoutHints().flex = 1.0;
        _content.add(view);
        updateChrome();
    }

    private void closeTab(int index)
    {
        if (index < 0 || index >= cast(int) _tabs.length) return;
        _tabs = _tabs[0 .. index] ~ _tabs[index + 1 .. $];
        if (_tabs.length == 0)
        {
            newTab(_homeUrl);
            return;
        }
        if (index < _active) --_active;
        else if (_active >= cast(int) _tabs.length)
            _active = cast(int) _tabs.length - 1;
        switchTab(_active);
    }

    private void closeActiveTab()
    {
        closeTab(_active);
    }

    /// Re-extract the page title from the DOM (best effort).
    private string pageTitle(WebPageView view)
    {
        try
        {
            auto page = view.page();
            if (page is null) return "";
            auto root = page.root();
            if (root is null) return "";
            string title = findTitle(root);
            if (title.length > 0) return title;
        }
        catch (Exception)
        {
        }
        return "Untitled";
    }

    private static string findTitle(Element element)
    {
        if (element.tag == "title")
        {
            const text = element.textContent().strip();
            if (text.length > 0) return text;
        }
        foreach (child; element.elements)
        {
            const found = findTitle(child);
            if (found.length > 0) return found;
        }
        return "";
    }

    private void setWindowTitle(string pageTitleText)
    {
        const title = pageTitleText.length > 0 ? pageTitleText : "New tab";
        const full = title ~ " — Aurora Browser";
        _window.setTitle(full);
        if (_titleBar !is null) _titleBar.setTitle(full);
    }

    private void updateChrome()
    {
        const valid = _active >= 0 && _active < cast(int) _tabs.length;
        const canBack = valid && _tabs[cast(size_t) _active].position > 0;
        const canForward = valid &&
            _tabs[cast(size_t) _active].position + 1 <
            cast(int) _tabs[cast(size_t) _active].history.length;

        if (_backButton !is null) _backButton.setEnabled(canBack);
        if (_forwardButton !is null) _forwardButton.setEnabled(canForward);
        refreshTabStrip();
    }

    private void updateStatus(string text)
    {
        _status.setText(text);
    }

    private void toggleDarkMode()
    {
        _dark = !_dark;
        _window.setTheme(_dark ? darkBrowserTheme() : browserTheme());
        if (_titleBar !is null) _titleBar.setDarkMode(_dark);
        if (_tabStrip !is null)
            _tabStrip.setBackground(_dark ? darkBrowserTheme().panelBackground :
                browserTheme().panelBackground);
        if (_toolbar !is null)
            _toolbar.setBackground(_dark ? darkBrowserTheme().panelElevated :
                browserTheme().panelElevated);
        if (_bookmarksBar !is null)
            _bookmarksBar.setBackground(_dark ? darkBrowserTheme().panelBackground :
                browserTheme().panelBackground);
        if (_statusBand !is null)
            _statusBand.setBackground(_dark ? darkBrowserTheme().panelBackground :
                browserTheme().panelBackground);
        if (_window is null) return;
        _window.setFrameDark(_dark);
        updateStatus(_dark ? "Dark theme enabled" : "Light theme enabled");
        invalidate();
    }

    /// Test-only: current theme mode.
    public bool isDarkForTesting() const { return _dark; }

    // --- bookmarks --------------------------------------------------------

    private bool isBookmarked(string url) const
    {
        foreach (b; _bookmarks)
            if (b == url) return true;
        return false;
    }

    private void toggleBookmark()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        const url = _tabs[cast(size_t) _active].view.currentUrl();
        if (isBookmarked(url))
        {
            string[] keep;
            foreach (b; _bookmarks)
                if (b != url) keep ~= b;
            _bookmarks = keep;
            updateStatus("Removed bookmark: " ~ url);
        }
        else
        {
            _bookmarks ~= url;
            updateStatus("Bookmarked: " ~ url);
        }
        refreshBookmarksBar();
        saveBookmarks(_bookmarks);
        _bookmarkButton.setText(isBookmarked(url) ? "★" : "☆");
    }

    /// Rebuild the bookmarks bar buttons.
    private void refreshBookmarksBar()
    {
        if (_bookmarksBar is null) return;
        _bookmarksBar.clearChildren();
        if (_bookmarks.length == 0)
        {
            auto emptyLabel = _bookmarksBar.add(new Label("Bookmarks"));
            emptyLabel.setId("br-bookmarks-empty");
            return;
        }
        foreach (index, url; _bookmarks)
        {
            auto b = _bookmarksBar.add(new Button(bookmarkLabel(url)));
            b.setId("br-bookmark-" ~ to!string(index));
            b.setFlat(true);
            bindBookmarkButton(b, url);
        }
    }

    /// Bind a bookmark button's click callback (parameter-scoped so the URL is
    /// not shared across loop iterations).
    private void bindBookmarkButton(Button button, string url)
    {
        button.onClick = delegate() {
            if (_active >= 0 && _active < cast(int) _tabs.length)
                navigateTo(url);
        };
    }

    private string bookmarkLabel(string url)
    {
        // Derive a short label from the URL.
        auto lower = url.toLower();
        if (lower.startsWith("auroraweb:"))
            return url["auroraweb:".length .. $].strip();
        if (lower.startsWith("https://"))
            return url["https://".length .. $];
        if (lower.startsWith("http://"))
            return url["http://".length .. $];
        return url;
    }

    // --- input ------------------------------------------------------------

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.t)
        {
            newTab(_homeUrl);
            return true;
        }
        if (shortcut && event.key == Key.h)
        {
            goHome();
            return true;
        }
        if (shortcut && event.key == Key.w && _tabs.length > 1)
        {
            closeActiveTab();
            return true;
        }
        if (shortcut && event.key == Key.l)
        {
            _address.requestFocus();
            _address.selectAll();
            return true;
        }
        if (event.alt() && event.key == Key.left)
        {
            navigateBack();
            return true;
        }
        if (event.alt() && event.key == Key.right)
        {
            navigateForward();
            return true;
        }
        return false;
    }

    // --- layout -----------------------------------------------------------

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
            theme().windowBackground);
    }

    protected override void onLayout()
    {
        const w = bounds().width;
        const h = bounds().height;
        int y = 0;

        const titleH = _titleBar !is null ? _titleBar.barHeight() :
            BrowserTitleBarHeight;
        _titleBar.setBounds(Rect(0, y, w, titleH));
        y += titleH;

        _tabStrip.setBounds(Rect(0, y, w, BrowserTabStripHeight));
        y += BrowserTabStripHeight;

        _toolbar.setBounds(Rect(0, y, w, BrowserToolbarHeight));
        y += BrowserToolbarHeight;

        _bookmarksBar.setBounds(Rect(0, y, w, BrowserBookmarksHeight));
        y += BrowserBookmarksHeight;

        const statusH = BrowserStatusHeight;
        const contentH = maxInt(0, h - y - statusH);
        _content.setBounds(Rect(0, y, w, contentH));
        y += contentH;

        _statusBand.setBounds(Rect(0, y, w, maxInt(0, h - y)));

        _snapPreview.setBounds(Rect(0, 0, w, h));
        _windowBorder.setBounds(Rect(0, 0, w, h));
    }

    // --- test accessors ---------------------------------------------------

    /// Test-only: number of open tabs.
    public size_t tabCountForTesting() const
    {
        return _tabs.length;
    }

    /// Test-only: index of the active tab.
    public int activeTabForTesting() const
    {
        return _active;
    }

    /// Test-only: the active tab's current URL (history position).
    public string currentUrlForTesting()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return "";
        auto tab = _tabs[cast(size_t) _active];
        if (tab.history.length == 0) return "";
        return tab.history[cast(size_t)
            clampInt(tab.position, 0, cast(int) tab.history.length - 1)];
    }

    /// Test-only: tab title (last known page title).
    public string tabTitleForTesting()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return "";
        return _tabs[cast(size_t) _active].title;
    }

    /// Test-only: navigate the active tab without the address bar.
    public void navigateForTesting(string url)
    {
        navigateTo(url);
    }

    /// Test-only: history stack of the active tab.
    public string[] historyForTesting()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length)
            return null;
        return _tabs[cast(size_t) _active].history.dup;
    }

    /// Test-only: current bookmark URLs.
    public string[] bookmarksForTesting() const
    {
        return _bookmarks.dup;
    }

    /// Test-only: is the given URL bookmarked?
    public bool isBookmarkedForTesting(string url) const
    {
        return isBookmarked(url);
    }

    /// Test-only: the active tab's page view (for scroll testing).
    public WebPageView activeViewForTesting()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return null;
        return _tabs[cast(size_t) _active].view;
    }

    /// Test-only: is a page currently loading (busy state)?
    public bool isLoadingForTesting() const
    {
        return _loading;
    }

    /// Test-only: is a progressive network load still in flight?
    public bool loadPendingForTesting() const
    {
        return _pendingLoad.active;
    }

    /// Test-only: commit a progressive load whose document is in, exactly as the
    /// tick after it would. A driver that pumps the page itself - a probe
    /// settling a screenshot - never ticks the root, so without this the capture
    /// keeps the chrome's loading state (empty URL, home title, close icon)
    /// although the page it captured is complete.
    public bool finishLoadForTesting()
    {
        if (!_pendingLoad.active) return false;
        finishNetworkLoad();
        invalidate();
        return true;
    }

    /// Test-only: the configured home page URL.
    public string homeUrlForTesting() const
    {
        return _homeUrl;
    }

    /// Test-only: current status bar text.
    public string statusTextForTesting() const
    {
        return to!string(_status.text());
    }

    /// Test-only: a summary of the tab strip ("[ active ] other · other").
    /// Kept label-shaped so existing callers keep working even though the
    /// strip is now a row of real `TabButton` widgets.
    public string tabStripLabelForTesting() const
    {
        string label;
        foreach (index, tab; _tabs)
        {
            if (index > 0) label ~= "   ";
            const title = tab.title.length > 0 ? tab.title : "New tab";
            if (cast(int) index == _active)
                label ~= "[ " ~ title ~ " ]";
            else
                label ~= title;
        }
        return label;
    }

    /// Test-only: the tab strip's real `TabButton` widgets.
    public TabButton[] tabButtonsForTesting()
    {
        return _tabButtons.dup;
    }

    /// Test-only: switch the active tab (as clicking a tab would).
    public void switchTabForTesting(int index)
    {
        switchTab(index);
    }

    /// Test-only: close a tab (as clicking a tab's ✕ would).
    public void closeTabForTesting(int index)
    {
        closeTab(index);
    }

    /// Test-only: the titlebar widget.
    public BrowserTitleBar titleBarForTesting()
    {
        return _titleBar;
    }

    /// Test-only: the snap-preview overlay.
    public TitleBarSnapPreview snapPreviewForTesting()
    {
        return _snapPreview;
    }

    /// Test-only: set the home page (also persists it to home.txt).
    public void setHomeForTesting(string url)
    {
        setHomeUrl(url);
    }

    /// Configure the home page (also persists it to home.txt).
    private void setHomeUrl(string url)
    {
        if (url == _homeUrl) return;
        _homeUrl = url;
        saveHomeUrl(url);
    }

    /// Open `url` in the first tab on startup (used by the `--url` CLI arg).
    /// Called after the constructor created the initial tab.
    public void openUrlAtStartup(string url)
    {
        if (_tabs.length == 0) return;
        _active = 0;
        switchTab(0);
        navigateTo(url);
        updateChrome();
    }
}

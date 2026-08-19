module aurorabrowser.appui;

/**
 * Aurora Browser UI — the chrome and page-view widgets.
 *
 * The chrome is an Aurora-D widget tree (toolbar buttons, address field, tab
 * strip, status bar). Page content is rendered by the `aurora-web` engine
 * (`WebPage`) into a `WebPageView` widget that overrides `Widget.onPaint` and
 * drives `WebPage.layout`/`WebPage.paint` from the real Aurora `Canvas`.
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
import std.range : empty;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.utf : toUTF32;

// ---------------------------------------------------------------------------
// Offline page source
// ---------------------------------------------------------------------------

/// Default home page URL (overridable through the home.txt settings file).
immutable string defaultHomeUrl = "auroraweb:hello";

/// Small settings file that persists the home page across launches.
immutable string homeSettingsFile = "home.txt";

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
    if (p == "async")
        return asyncPageHtml();
    if (p == "complex")
        return complexPageHtml();
    if (p == "remote")
        return remotePageHtml();
    if (p == "error404")
        return error404PageHtml();
    return errorPageHtml(p, "Unknown page '" ~ p ~ "'. Try auroraweb:hello, " ~
        "auroraweb:css, auroraweb:js, auroraweb:links, auroraweb:async, " ~
        "auroraweb:remote or auroraweb:complex.");
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
    private string _lastError;   /// reason of the last failed load ("" if ok)
    private string _failedUrl;   /// URL that failed; "" if the last load succeeded

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
            loadIntoPage(currentUrl());
        }
        invalidate();
    }

    WebPage page() { return _page; }

    /// Reset the scroll position when a new document is loaded.
    private void resetScroll()
    {
        _scrollY = 0;
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

    /**
     * Load a document into the page. `auroraweb:` URLs use the offline built-in
     * pages; `http://`/`https://` URLs fetch the real document through the
     * engine's WinINet layer (`WebPage.navigate`). Failed network fetches show
     * the built-in error page.
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
        else if (lower.startsWith("http://") || lower.startsWith("https://"))
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
        _contentHeight = contentHeight();

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
        if (isOverLink(event.position.x, event.position.y))
            setCursor(CursorKind.hand);
        else
            setCursor(CursorKind.arrow);
        return super.onMouseMove(event);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left)
            return super.onMouseDown(event);
        const href = hitTestLink(event.position.x, event.position.y + _scrollY);
        if (href.length > 0)
        {
            if (onLinkClicked !is null)
                onLinkClicked(resolveHref(href));
            return true;
        }
        return super.onMouseDown(event);
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
            _page.layout();
            _contentHeight = contentHeight();
            invalidate();
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillRect(Rect(0, 0, size().width, size().height),
            Color.rgb(255, 255, 255));
        if (_page is null) return;
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
        _page.layout();
        _contentHeight = contentHeight();
        // Clip to the widget and translate by the scroll offset.
        auto clipped = canvas.clipped(Rect(0, 0, size().width, size().height));
        auto translated = clipped.translated(0, -_scrollY);
        _page.paint(translated, 0, 0);
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

    override bool onMouseWheel(ref Event event)
    {
        if (event.wheelY == 0) return false;
        const maxScroll = maxInt(0, _contentHeight - size().height);
        if (maxScroll == 0) return false;
        _scrollY = clampInt(_scrollY - event.wheelY * 24, 0, maxScroll);
        invalidate();
        return true;
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

// ---------------------------------------------------------------------------
// Browser root
// ---------------------------------------------------------------------------

final class BrowserRoot : VBox
{
    private GuiWindow _window;
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
    private HBox _tabStrip;
    private Label _status;
    private Label _tabsLabel;
    private VBox _content;
    private HBox _bookmarksBar;
    private string[] _bookmarks;   /// bookmarked URLs (order preserved)
    private string _homeUrl;       /// configured home page (persisted)
    private bool _loading;         /// page currently loading (status/button state)

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        _homeUrl = loadHomeUrl();
        buildChrome();
        newTab(_homeUrl);
        updateStatus("Aurora Browser ready — offline pages only "
            ~ "(auroraweb:hello, auroraweb:css, auroraweb:js, "
            ~ "auroraweb:links).");
        updateChrome();
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

    private void buildChrome()
    {
        // Toolbar row: back / forward / reload, address field, Go.
        auto toolbar = add(new HBox(6, Insets(8, 6)));
        toolbar.layoutHints().preferredHeight = 48;

        _backButton = toolbar.add(new Button("", IconKind.up));
        _backButton.setId("br-back");
        _backButton.setIconSize(16);
        _backButton.layoutHints().preferredWidth = 36;
        _backButton.onClick = delegate() { navigateBack(); };

        _forwardButton = toolbar.add(new Button("", IconKind.up));
        _forwardButton.setId("br-forward");
        _forwardButton.setIconSize(16);
        _forwardButton.layoutHints().preferredWidth = 36;
        // No dedicated forward glyph; mirror the back arrow for now.
        _forwardButton.onClick = delegate() { navigateForward(); };

        _reloadButton = toolbar.add(new Button("", IconKind.refresh));
        _reloadButton.setId("br-reload");
        _reloadButton.setIconSize(16);
        _reloadButton.layoutHints().preferredWidth = 36;
        _reloadButton.onClick = delegate() { reloadPage(); };

        _homeButton = toolbar.add(new Button("", IconKind.home));
        _homeButton.setId("br-home");
        _homeButton.setIconSize(16);
        _homeButton.layoutHints().preferredWidth = 36;
        _homeButton.onClick = delegate() { goHome(); };

        _address = toolbar.add(new AddressField(""));
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

        _goButton = toolbar.add(new Button("Go"));
        _goButton.setId("br-go");
        _goButton.setAccent(true);
        _goButton.onClick = delegate() { go(); };

        _newTabButton = toolbar.add(new Button("New tab", IconKind.newDocument));
        _newTabButton.setId("br-newtab");
        _newTabButton.onClick = delegate() { newTab("auroraweb:hello"); };

        _bookmarkButton = toolbar.add(new Button("★"));
        _bookmarkButton.setId("br-bookmark");
        _bookmarkButton.layoutHints().preferredWidth = 34;
        _bookmarkButton.onClick = delegate() { toggleBookmark(); };

        // Bookmarks bar: a horizontal row of saved links.
        _bookmarksBar = add(new HBox(4, Insets(6, 2)));
        _bookmarksBar.layoutHints().preferredHeight = 26;
        refreshBookmarksBar();

        // Tab strip: one label per tab (no per-tab close buttons yet).
        _tabStrip = add(new HBox(4, Insets(6, 2)));
        _tabStrip.layoutHints().preferredHeight = 30;
        _tabsLabel = _tabStrip.add(new Label(""));
        _tabsLabel.setId("br-tabs");

        // Content area: hosts the active tab's page view (reparented during
        // switchTab).
        _content = add(new VBox(0));
        _content.layoutHints().flex = 1.0;

        // Status bar.
        _status = add(new Label("Ready"));
        _status.setId("br-status");
        _status.layoutHints().preferredHeight = 26;
        _status.setScale(1);
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

    private void navigateTo(string url)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        const prevPosition = tab.position;

        // Load first. On a successful load the URL is committed to history;
        // on failure the previous entry is preserved and the error page shown.
        const success = loadUrl(url);
        if (!success)
        {
            tab.position = prevPosition;
            _tabs[_active] = *tab;
            updateChrome();
            updateStatus("Failed to load " ~ url);
            return;
        }

        // Truncate the forward history when a new entry is navigated.
        tab.history.length = cast(size_t) tab.position + 1;
        tab.history ~= url;
        tab.position = cast(int) tab.history.length - 1;
        tab.title = pageTitle(tab.view);
        _tabs[_active] = *tab;
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
            _window.setTitle(tab.title.length > 0 ? tab.title ~ " — Aurora Browser" :
                "Aurora Browser");
            _bookmarkButton.setText(isBookmarked(url) ? "★" : "☆");
        }
        _tabs[_active] = *tab;
        return success;
    }

    /// Update the chrome after a back/forward navigation to a history entry.
    private void loadHistoryEntry(int index, string statusPrefix)
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        auto tab = &_tabs[_active];
        const url = tab.history[cast(size_t) index];
        loadUrl(url);
        tab.title = pageTitle(tab.view);
        updateStatus(statusPrefix ~ " " ~ url);
        _tabs[_active] = *tab;
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
        loadUrl(tab.view.currentUrl());
        tab.title = pageTitle(tab.view);
        _window.setTitle(tab.title.length > 0 ? tab.title ~ " — Aurora Browser" :
            "Aurora Browser");
        updateStatus("Reloaded " ~ tab.view.currentUrl());
        _tabs[_active] = *tab;
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
        _address.setText("", false);
        if (!loadUrl(url, false))
        {
            tab.history.length = 0;
            tab.position = 0;
            tab.title = pageTitle(view);
            _tabs[_active] = tab;
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

    private void updateChrome()
    {
        const canBack = _active >= 0 && _active < cast(int) _tabs.length &&
            _tabs[cast(size_t) _active].position > 0;
        const canForward = _active >= 0 && _active < cast(int) _tabs.length &&
            _tabs[cast(size_t) _active].position + 1 <
            cast(int) _tabs[cast(size_t) _active].history.length;

        _backButton.setEnabled(canBack);
        _forwardButton.setEnabled(canForward);

        // Tab strip label: "Tab 1 · Tab 2 ..." with the active one in caps.
        if (_tabs.length > 0)
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
            _tabsLabel.setText(label);
        }
        else
            _tabsLabel.setText("");
    }

    private void updateStatus(string text)
    {
        _status.setText(text);
    }

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
            const capturedUrl = url;
            b.onClick = delegate() {
                if (_active >= 0 && _active < cast(int) _tabs.length)
                    navigateTo(capturedUrl);
            };
        }
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

    private void closeActiveTab()
    {
        if (_active < 0 || _active >= cast(int) _tabs.length) return;
        _tabs = _tabs[0 .. _active] ~ _tabs[_active + 1 .. $];
        if (_tabs.length == 0)
        {
            newTab(_homeUrl);
            return;
        }
        if (_active >= cast(int) _tabs.length)
            _active = cast(int) _tabs.length - 1;
        switchTab(_active);
    }

    // --- layout -----------------------------------------------------------

    protected override void onLayout()
    {
        // Ensure the active tab's view fills the content area.
        if (_active >= 0 && _active < cast(int) _tabs.length)
        {
            auto view = _tabs[cast(size_t) _active].view;
            view.setBounds(Rect(0, 0, _content.size().width,
                _content.size().height));
        }
        super.onLayout();
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

    /// Test-only: the tab strip label text.
    public string tabStripLabelForTesting() const
    {
        return to!string(_tabsLabel.text());
    }

    /// Test-only: set the home page (also persists it to home.txt).
    public void setHomeForTesting(string url)
    {
        setHomeUrl(url);
    }
}

module auroraweb.dombind;

/**
 * Connect the JavaScript engine (`auroraweb.js`) to the DOM tree
 * (`auroraweb.dom`). Exposes a `document` global with the query and mutation
 * API a first web page needs.
 *
 * The binder keeps a bidirectional map between Aurora `Element` and the
 * `JsObject` wrapper so scripts can hold references and mutate the tree.
 */

import auroraweb.dom : AttrMap, ComputedStyle, Element, TextNode;
import auroraweb.css : Selector, mediaQueryMatches, selectorMatches;
import auroraweb.js : JsFuncDelegate, JsKind, JsObject, JsRuntime, JsScope,
    JsScriptFunc, JsValue;
import auroraweb.net : Url;

import std.array : split;
import std.conv : to;
import std.string : endsWith, indexOf, replace, strip, toLower, toUpper;

/// Bind a DOM tree into a JS runtime. Returns the `document` object value.
/// `resourceLoader` (if given) enables the `fetch` global for page scripts:
/// the loader is called with a URL string and must return the raw response
/// bytes (or null on failure).
/// `documentUrl` is the address the document was loaded from; `location`, and
/// the origin a cookie is stored against, answer from it. `viewportWidth` and
/// `viewportHeight` are the layout viewport the page is rendered in, which
/// `window.innerWidth`/`innerHeight` and `matchMedia` report.
JsValue bindDocument(Element root, JsRuntime rt, ref JsScope jsScope,
    ubyte[] delegate(string url) @safe resourceLoader = null,
    string documentUrl = "", int viewportWidth = 0, int viewportHeight = 0)
{
    auto binder = new DocumentBinder(rt);
    _hostBinders[rt] = binder;
    return binder.bind(root, jsScope, resourceLoader, documentUrl,
        viewportWidth, viewportHeight);
}

/// One binder per bound document/runtime, so the HOST (the browser shell) can
/// dispatch real user interactions — clicks, key presses, text input — into a
/// page's DOM handlers. Without this, only page-script-initiated
/// `element.dispatchEvent(...)` could ever fire a listener.
private DocumentBinder[JsRuntime] _hostBinders;

/// Fire a NON-bubbling host event (`mouseenter`/`mouseleave`) on one element.
bool dispatchHostEventNoBubble(JsRuntime rt, Element element, string type)
{
    if (rt is null || element is null || type.length == 0) return false;
    if (auto b = rt in _hostBinders)
        return (*b).dispatchForHost(element, type, "", 0, false);
    return false;
}

/// Fire a host-initiated DOM event (`click`, `mousedown`, `mouseup`, `input`,
/// `keydown`, ...) on `element`, bubbling through its ancestors exactly like a
/// real event. `key` populates `event.key` for keyboard events. Returns true
/// when a handler called `preventDefault()`.
bool dispatchHostEvent(JsRuntime rt, Element element, string type, string key = "")
{
    if (rt is null || element is null || type.length == 0) return false;
    if (auto b = rt in _hostBinders)
        return (*b).dispatchForHost(element, type, key, 0);
    return false;
}

/// Same as above, with a numeric detail (used by `wheel` for `event.deltaY`).
bool dispatchHostEvent(JsRuntime rt, Element element, string type, int deltaY)
{
    if (rt is null || element is null || type.length == 0) return false;
    if (auto b = rt in _hostBinders)
        return (*b).dispatchForHost(element, type, "", deltaY);
    return false;
}

/// Internal binder state: the wrapper cache and the runtime.
/// Fire a document/window-level host event (`scroll`, `resize`, ...): the
/// document's own listener, then any `window` listener. Returns true when a
/// handler called `preventDefault()`.
bool dispatchDocumentEvent(JsRuntime rt, string type)
{
    if (rt is null || type.length == 0) return false;
    if (auto b = rt in _hostBinders)
        return (*b).dispatchOnDocument(type);
    return false;
}

/// Publish the document's load state (`document.readyState`). The host moves it
/// from `"loading"` while the document is being parsed, to `"interactive"` when
/// the document's own scripts have run, and to `"complete"` once they are done -
/// the order a page sees. A head script branches on it, so answering nothing
/// (the property did not exist) made a page take its "already ready" path, look
/// for elements that were still being parsed, find none, and never wait for the
/// event it had just decided it did not need.
void setDocumentReadyState(JsRuntime rt, string state)
{
    if (rt is null || state.length == 0) return;
    if (auto b = rt in _hostBinders)
        (*b).setReadyState(state);
}

/// Expose the viewport scroll offset to the page (`window.scrollY`,
/// `window.pageYOffset`, `document.documentElement.scrollTop`), which is what
/// scrolling pages actually read.
void setDocumentScroll(JsRuntime rt, int scrollY)
{
    if (rt is null) return;
    if (auto b = rt in _hostBinders)
        (*b).setViewportScroll(scrollY);
}

/// Publish the layout viewport size to the page (`window.innerWidth`,
/// `innerHeight` and the conditions `matchMedia` answers). The host pushes it
/// exactly like the scroll offset, so a resize keeps a page's view current
/// instead of leaving it with the size the document was first bound at.
void setViewportSize(JsRuntime rt, int width, int height)
{
    if (rt is null) return;
    if (auto b = rt in _hostBinders)
        (*b).setViewportSize(width, height);
}

/// Deliver the `IntersectionObserver` callbacks the geometry of the last layout
/// pass warrants. The page calls this at the end of every layout, which is where
/// a browser queues the callbacks too: pages reveal content, start animations
/// and swap in lazy images from them. Returns true when at least one callback
/// ran, because a callback usually mutates the DOM and the page must lay out
/// again.
bool evaluateIntersectionObservers(JsRuntime rt)
{
    if (rt is null) return false;
    if (auto b = rt in _hostBinders)
        return (*b).evaluateIntersectionObservers();
    return false;
}

/// One stored cookie: its value and the epoch second it expires at. `0` means a
/// session cookie, which lasts for this document's lifetime.
struct Cookie
{
    string value;
    long expires;
}

/// The current time in whole seconds since the Unix epoch.
private long unixNow()
{
    import std.datetime : Clock;
    return Clock.currTime().toUnixTime();
}

/// Parse an integer, or 0 when the text is not one (`max-age=garbage`).
private long parseLongOrZero(string text)
{
    auto t = text.strip();
    if (t.length == 0) return 0;
    long sign = 1;
    size_t i = 0;
    if (t[0] == '-' || t[0] == '+')
    {
        sign = t[0] == '-' ? -1 : 1;
        i = 1;
    }
    if (i >= t.length) return 0;
    long value = 0;
    for (; i < t.length; ++i)
    {
        if (t[i] < '0' || t[i] > '9') return 0;
        value = value * 10 + (t[i] - '0');
    }
    return sign * value;
}

/// Parse a cookie `expires` date (`Wed, 21 Oct 2015 07:28:00 GMT`, the only
/// format left in use; the two 1990s formats differ only in separators).
///
/// Returns false for text that is not such a date: per the cookie spec an
/// invalid `expires` attribute is ignored, which leaves the cookie a session
/// cookie rather than deleting it.
private bool parseCookieDate(string text, out long unixSeconds)
{
    static immutable months = ["jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"];
    int day = -1, month = -1, year = -1, hour = 0, minute = 0, second = 0;
    bool haveTime = false;
    foreach (field; text.replace(",", " ").split())
    {
        if (indexOf(field, ":") >= 0)
        {
            auto time = field.split(":");
            if (time.length != 3) continue;
            hour = cast(int) parseLongOrZero(time[0]);
            minute = cast(int) parseLongOrZero(time[1]);
            second = cast(int) parseLongOrZero(time[2]);
            haveTime = true;
        }
        else if (field.length == 4 && allDigits(field))
            year = cast(int) parseLongOrZero(field);
        else if (month < 0)
        {
            foreach (i, name; months)
                if (field.toLower() == name) { month = cast(int) i; break; }
        }
        else if (day < 0 && allDigits(field))
            day = cast(int) parseLongOrZero(field);
    }
    if (day < 0 || month < 0 || year < 0 || !haveTime) return false;
    import std.datetime : DateTime, SysTime, UTC;
    try
    {
        unixSeconds = SysTime(DateTime(year, month + 1, day, hour, minute, second), UTC()).toUnixTime();
        return true;
    }
    catch (Exception exc)
    {
        return false;   // out-of-range fields: not a date we can honour
    }
}

/// `true` when every character of `text` is an ASCII digit.
private bool allDigits(string text)
{
    if (text.length == 0) return false;
    foreach (c; text)
        if (c < '0' || c > '9') return false;
    return true;
}

/// Keep an `on<event>` DOM property wired to the engine's listener storage:
/// `window.onload = fn` and `document.onclick = fn` must fire exactly like
/// `addEventListener("load", fn)`, because the host dispatches the stored
/// listener rather than reading the property.
private void rememberHandler(JsObject target, string key, JsValue value)
{
    if (target is null || value.kind != JsKind.func) return;
    if (key.length <= 2 || key[0 .. 2] != "on") return;
    target.set("__event_" ~ key[2 .. $], value);
}

/// The platform name the engine reports to `navigator.platform`.
private string hostPlatformName()
{
    version (Windows) return "Win32";
    version (linux) return "Linux x86_64";
    version (OSX) return "MacIntel";
    return "Unknown";
}

/// Apply one `document.cookie = "name=value; expires=...; max-age=..."`.
///
/// `path`, `domain` and `secure` are parsed and ignored: the engine holds one
/// document, so there is no second origin or path a cookie could be scoped
/// against. `max-age` (and an `expires` in the past) deletes the cookie, and a
/// cookie written with an explicit lifetime is dropped once it has passed.
private void applyCookie(ref Cookie[string] jar, string text)
{
    auto parts = text.split(";");
    if (parts.length == 0) return;
    auto first = parts[0].strip();
    auto eq = indexOf(first, "=");
    if (eq <= 0) return;                     // no name: nothing to store
    const name = first[0 .. eq].strip();
    if (name.length == 0) return;
    Cookie c;
    c.value = first[eq + 1 .. $].strip();
    bool remove = false;
    foreach (attrRaw; parts[1 .. $])
    {
        auto attr = attrRaw.strip();
        auto aeq = indexOf(attr, "=");
        const key = (aeq < 0 ? attr : attr[0 .. aeq]).strip().toLower();
        const val = aeq < 0 ? "" : attr[aeq + 1 .. $].strip();
        if (key == "max-age")
        {
            const seconds = parseLongOrZero(val);
            if (seconds <= 0) remove = true;
            else c.expires = unixNow() + seconds;
        }
        else if (key == "expires")
        {
            long when;
            if (parseCookieDate(val, when))
            {
                if (when <= unixNow()) remove = true;
                else c.expires = when;
            }
        }
    }
    if (remove) jar.remove(name);
    else jar[name] = c;
}
/// One observed target of one `IntersectionObserver`: the observer object (its
/// callback and options live there) and the element whose intersection with the
/// viewport decides when the next callback fires.
private struct IoObservation
{
    JsObject observer;
    Element target;
    bool reported;          /// The first (always delivered) callback has run.
    bool lastIntersecting;  /// Intersection state the last callback reported.
    double lastRatio;       /// Ratio the last callback reported.
}

private final class DocumentBinder
{
    JsObject[Element] wrappers;
    JsObject[Element] datasets;
    JsRuntime rt;
    JsValue documentValue;   /// The bound `document` object (for document events).
    JsValue windowValue;     /// The bound `window` object (for window events).
    /// Layout viewport the document is bound in: what `window.innerWidth`,
    /// `innerHeight` and the conditions `matchMedia` answers report.
    int viewportWidth;
    int viewportHeight;
    /// The document's cookie jar by name. A bound document is one origin on one
    /// page load, so a name/value plus an expiry is all `document.cookie` needs.
    Cookie[string] cookies;
    /// The viewport's scroll offset. The host publishes it (see
    /// `setViewportScroll`) so geometry reads are viewport-relative, exactly as
    /// `getBoundingClientRect` and `IntersectionObserverEntry` report them.
    int viewportScrollY;
    /// Live `IntersectionObserver` registrations, one row per observed target.
    IoObservation[] ioObservations;

    this(JsRuntime rt)
    {
        this.rt = rt;
    }

    JsValue bind(Element root, ref JsScope jsScope,
        ubyte[] delegate(string url) @safe resourceLoader, string documentUrl,
        int viewportWidth, int viewportHeight)
    {
        this.viewportWidth = viewportWidth;
        this.viewportHeight = viewportHeight;
        // Build the document object.
        auto docObj = new JsObject();
        docObj.set("title", rt.makeString(documentTitle(root)));

        docObj.set("getElementById", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto id = rt2.toJsString(args[0]);
            auto found = findById(root, id);
            if (found is null) return rt2.makeNull();
            return wrap(found);
        }));

        docObj.set("querySelector", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto sel = rt2.toJsString(args[0]);
            auto parsed = parseCssSelector(sel);
            foreach (child; descendants(root))
            {
                if (selectorMatches(parsed, child))
                    return wrap(child);
            }
            return rt2.makeNull();
        }));

        docObj.set("querySelectorAll", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto sel = rt2.toJsString(args[0]);
            auto parsed = parseCssSelector(sel);
            size_t index = 0;
            foreach (child; descendants(root))
            {
                if (selectorMatches(parsed, child))
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        docObj.set("getElementsByTagName", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto tag = rt2.toJsString(args[0]).toLower();
            size_t index = 0;
            foreach (child; descendants(root))
            {
                if (child.tag == tag)
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        docObj.set("getElementsByClassName", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto cls = rt2.toJsString(args[0]);
            // Accept ".foo" or "foo".
            if (cls.length > 1 && cls[0] == '.') cls = cls[1 .. $];
            if (cls.length == 0) return arr;
            size_t index = 0;
            foreach (child; descendants(root))
            {
                if (child.hasClass(cls))
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        docObj.set("createElement", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto tag = rt2.toJsString(args[0]).toLower();
            auto el = new Element(tag);
            return wrap(el);
        }));

        docObj.set("createTextNode", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto obj = new JsObject();
            obj.set("nodeType", rt2.makeNumber(3));
            obj.set("data", rt2.makeString(rt2.toJsString(args[0])));
            obj.set("__text", rt2.makeString(rt2.toJsString(args[0])));
            return JsValue(JsKind.object, obj);
        }));

        // document.write(html): parse the fragment and append to the body.
        docObj.set("write", rt.makeNativeFunc((thisValue, args, rt2) {
            auto bodyEl = findTag(root, "body");
            if (bodyEl is null) bodyEl = root;
            if (args.length)
            {
                import auroraweb.html : parseFragment;
                foreach (node; parseFragment(rt2.toJsString(args[0])))
                {
                    node.parent = bodyEl;
                    bodyEl.children ~= node;
                    bodyEl.elements ~= node;
                }
            }
            return rt2.makeUndefined();
        }));

        docObj.set("getComputedStyle", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto el = unwrap(args[0]);
            if (el is null) return rt2.makeNull();
            return makeComputedStyle(el, rt2);
        }));

        // body
        auto bodyEl = findTag(root, "body");
        if (bodyEl is null) bodyEl = root;
        docObj.set("body", wrap(bodyEl));
        docObj.set("documentElement", wrap(root));
        docObj.set("__get_readyState", rt.makeNativeFunc((thisValue, args, rt2) {
            return rt2.makeString(readyState);
        }));

        // document.addEventListener: store under the same `__event_<name>` slot
        // the host fires when it dispatches a document-level event (`scroll`,
        // ...). Without this the document object had no addEventListener at all,
        // so document-level listeners silently never ran — and the page could
        // not observe e.g. `window.scrollY` from a `scroll` handler.
        docObj.set("addEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            const evtName = rt2.toJsString(args[0]);
            if (thisValue.obj !is null)
                thisValue.obj.set("__event_" ~ evtName, args[1]);
            return rt2.makeUndefined();
        }));
        docObj.set("removeEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            const evtName = rt2.toJsString(args[0]);
            if (thisValue.obj !is null)
                thisValue.obj.props.remove("__event_" ~ evtName);
            return rt2.makeUndefined();
        }));

        auto docVal = JsValue(JsKind.object, docObj);
        jsScope.declare("document", docVal);

        // Global getComputedStyle(el) — a bare global in browsers.
        jsScope.declare("getComputedStyle", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto el = unwrap(args[0]);
            if (el is null) return rt2.makeNull();
            return makeComputedStyle(el, rt2);
        }));

        // window: minimal global with addEventListener and onload.
        auto windowObj = new JsObject();
        windowObj.set("addEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto name = rt2.toJsString(args[0]);
            rt2.globalScope.declare("__window_" ~ name, args[1]);
            // Also keep it on the window object so the host can fire it.
            if (thisValue.obj !is null)
                thisValue.obj.set("__event_" ~ name, args[1]);
            return rt2.makeUndefined();
        }));
        windowObj.set("document", docVal);
        jsScope.declare("window", JsValue(JsKind.object, windowObj));

        // location: the address the document was loaded from. A page reads it
        // to decide whether it is running on its own host (`location.hostname`
        // guards the Django site's search wiring) and to build absolute URLs.
        auto locationValue = makeLocation(documentUrl);
        windowObj.set("location", locationValue);
        docObj.set("location", locationValue);
        jsScope.declare("location", locationValue);

        // The layout viewport, which scripts read to branch on the screen size.
        windowObj.set("innerWidth", rt.makeNumber(viewportWidth));
        windowObj.set("innerHeight", rt.makeNumber(viewportHeight));
        windowObj.set("outerWidth", rt.makeNumber(viewportWidth));
        windowObj.set("outerHeight", rt.makeNumber(viewportHeight));
        // The engine paints one device pixel per CSS pixel, so the ratio is 1.
        windowObj.set("devicePixelRatio", rt.makeNumber(1.0));
        auto screenObj = rt.makeObject();
        screenObj.obj.set("width", rt.makeNumber(viewportWidth));
        screenObj.obj.set("height", rt.makeNumber(viewportHeight));
        screenObj.obj.set("availWidth", rt.makeNumber(viewportWidth));
        screenObj.obj.set("availHeight", rt.makeNumber(viewportHeight));
        windowObj.set("screen", screenObj);
        // The viewport names are globals too, exactly as in a browser: a page
        // writes `innerWidth` as often as `window.innerWidth`, and a bare name
        // that lives only on the window object resolves to nothing.
        jsScope.declare("innerWidth", rt.makeNumber(viewportWidth));
        jsScope.declare("innerHeight", rt.makeNumber(viewportHeight));
        jsScope.declare("outerWidth", rt.makeNumber(viewportWidth));
        jsScope.declare("outerHeight", rt.makeNumber(viewportHeight));
        jsScope.declare("devicePixelRatio", rt.makeNumber(1.0));
        jsScope.declare("screen", screenObj);

        // matchMedia: answers from the same evaluator the stylesheet's `@media`
        // rules use, so a script's test and the sheet it guards cannot disagree.
        auto matchMediaValue = rt.makeNativeFunc((thisValue, args, rt2) {
            return makeMediaQueryList(args.length ? rt2.toJsString(args[0]) : "");
        });
        windowObj.set("matchMedia", matchMediaValue);
        jsScope.declare("matchMedia", matchMediaValue);

        // document.cookie: the document's cookie jar, reached through a read
        // hook and a write hook. The write hook forwards every other assignment
        // (`document.title = ...`) to the object's ordinary properties.
        docObj.set("__get_cookie", rt.makeNativeFunc((thisValue, args, rt2) {
            return rt2.makeString(cookieHeader());
        }));
        docObj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2 || thisValue.obj is null) return rt2.makeUndefined();
            const key = rt2.toJsString(args[0]);
            if (key == "cookie")
            {
                applyCookie(cookies, rt2.toJsString(args[1]));
                return rt2.makeUndefined();
            }
            rememberHandler(thisValue.obj, key, args[1]);
            thisValue.obj.set(key, args[1]);
            return rt2.makeUndefined();
        }));

        // localStorage/sessionStorage: the Web Storage API, which pages keep
        // small state in (the Django site remembers the chosen theme in one).
        auto local = makeStorage();
        auto session = makeStorage();
        windowObj.set("localStorage", local);
        windowObj.set("sessionStorage", session);
        jsScope.declare("localStorage", local);
        jsScope.declare("sessionStorage", session);

        // navigator: scripts feature-detect through it. It must not claim to be
        // Chrome or Firefox — a page that branches on a false user-agent string
        // takes the wrong path — so it names this engine.
        auto navObj = rt.makeObject();
        navObj.obj.set("userAgent", rt.makeString("Mozilla/5.0 (compatible; AuroraWeb/0.1)"));
        navObj.obj.set("appName", rt.makeString("AuroraWeb"));
        navObj.obj.set("appVersion", rt.makeString("5.0 (compatible; AuroraWeb/0.1)"));
        navObj.obj.set("platform", rt.makeString(hostPlatformName()));
        navObj.obj.set("language", rt.makeString("en-US"));
        auto languagesArr = rt.makeArray();
        languagesArr.obj.set("0", rt.makeString("en-US"));
        languagesArr.obj.arrayLength = 1;
        navObj.obj.set("languages", languagesArr);
        navObj.obj.set("cookieEnabled", rt.makeBoolean(true));
        navObj.obj.set("onLine", rt.makeBoolean(true));
        navObj.obj.set("doNotTrack", rt.makeString(""));
        windowObj.set("navigator", navObj);
        jsScope.declare("navigator", navObj);

        // Global Event constructor: new Event("click") returns a dispatchable
        // event object (type + preventDefault/stopPropagation stubs). Arbitrary
        // props (key, bubbles, ...) can be assigned afterwards by scripts.
        jsScope.declare("Event", rt.makeNativeFunc((thisValue, args, rt2) {
            auto evt = rt2.makeObject();
            evt.obj.set("type", args.length ? rt2.makeString(rt2.toJsString(args[0])) : rt2.makeString(""));
            evt.obj.set("defaultPrevented", rt2.makeBoolean(false));
            evt.obj.set("propagationStopped", rt2.makeBoolean(false));
            evt.obj.set("cancelable", rt2.makeBoolean(false));
            evt.obj.set("preventDefault", rt2.makeNativeFunc((eoThis, eoArgs, eoRt) {
                if (eoThis.obj !is null)
                    eoThis.obj.set("defaultPrevented", eoRt.makeBoolean(true));
                return eoRt.makeUndefined();
            }));
            evt.obj.set("stopPropagation", rt2.makeNativeFunc((eoThis, eoArgs, eoRt) {
                if (eoThis.obj !is null)
                    eoThis.obj.set("propagationStopped", eoRt.makeBoolean(true));
                return eoRt.makeUndefined();
            }));
            return evt;
        }));
        // IntersectionObserver: pages reveal content with it - animation
        // classes, lazy images, sticky headers, a hint that a control is
        // searchable. A script that calls `new IntersectionObserver(...)` in a
        // browser continues past it, so a page whose script would throw here
        // ran none of the code after it (django's header never reached the
        // statement that adds "(Ctrl+K)" to its search field). Targets are
        // evaluated right after every layout pass, so the callback reports the
        // geometry a browser would - including the immediate first callback for
        // whatever is already on screen when `observe()` is called.
        auto intersectionObserverCtor = rt.makeNativeFunc((thisValue, args, rt2) {
            auto observer = rt2.makeObject();
            observer.obj.set("__callback", args.length ? args[0] : rt2.makeUndefined());
            observer.obj.set("__targets", rt2.makeArray());
            observer.obj.set("root", rt2.makeNull());
            observer.obj.set("rootMargin", rt2.makeString("0px"));
            observer.obj.set("thresholds", rt2.makeNumber(0.0));
            if (args.length > 1 && args[1].obj !is null)
            {
                auto options = args[1];
                auto root = options.obj.get("root");
                if (root.kind != JsKind.undefined) observer.obj.set("root", root);
                auto margin = options.obj.get("rootMargin");
                if (margin.kind == JsKind.string) observer.obj.set("rootMargin", margin);
                auto threshold = options.obj.get("threshold");
                if (threshold.kind == JsKind.number || threshold.kind == JsKind.object)
                    observer.obj.set("thresholds", threshold);
            }
            observer.obj.set("observe", rt2.makeNativeFunc((oThis, oArgs, oRt) {
                if (oThis.obj is null || oArgs.length == 0) return oRt.makeUndefined();
                auto target = unwrap(oArgs[0]);
                if (target is null) return oRt.makeUndefined();
                foreach (ref row; ioObservations)
                    if (row.observer is oThis.obj && row.target is target)
                        return oRt.makeUndefined();
                IoObservation row;
                row.observer = oThis.obj;
                row.target = target;
                ioObservations ~= row;
                addObservedTarget(oThis, oArgs[0]);
                return oRt.makeUndefined();
            }));
            observer.obj.set("unobserve", rt2.makeNativeFunc((oThis, oArgs, oRt) {
                if (oThis.obj is null || oArgs.length == 0) return oRt.makeUndefined();
                auto target = unwrap(oArgs[0]);
                IoObservation[] kept;
                foreach (ref row; ioObservations)
                {
                    if (row.observer is oThis.obj && row.target is target) continue;
                    kept ~= row;
                }
                ioObservations = kept;
                removeObservedTarget(oThis, oArgs[0]);
                return oRt.makeUndefined();
            }));
            observer.obj.set("disconnect", rt2.makeNativeFunc((oThis, oArgs, oRt) {
                if (oThis.obj is null) return oRt.makeUndefined();
                IoObservation[] kept;
                foreach (ref row; ioObservations)
                    if (row.observer !is oThis.obj) kept ~= row;
                ioObservations = kept;
                return oRt.makeUndefined();
            }));
            // Entries are delivered as they are computed, so no delivery is
            // ever pending by the time a page asks (`takeRecords` is empty).
            observer.obj.set("takeRecords", rt2.makeNativeFunc((oThis, oArgs, oRt) {
                return oRt.makeArray();
            }));
            return observer;
        });
        windowObj.set("IntersectionObserver", intersectionObserverCtor);
        jsScope.declare("IntersectionObserver", intersectionObserverCtor);

        // fetch: route page fetches through the page's resource loader and
        // expose a minimal Fetch-like response with a synchronous .then() shim.
        if (resourceLoader !is null)
        {
            rt.fetchHandler = (JsValue url, JsValue options, ref JsRuntime rt2) {
                return fetchResponse(rt2, url, resourceLoader);
            };
            rt.installFetchBuiltin();
        }

        // `window` IS the global object in a browser: a name that is not a
        // property of it still resolves (`window.setTimeout`, `window.fetch`),
        // and assigning to one creates a global. These two hooks bridge the
        // directions, so page code that spells a global either way works.
        windowValue = JsValue(JsKind.object, windowObj);
        windowObj.set("window", windowValue);
        windowObj.set("self", windowValue);
        windowObj.set("globalThis", windowValue);
        windowObj.set("top", windowValue);
        windowObj.set("parent", windowValue);
        jsScope.declare("self", windowValue);
        jsScope.declare("globalThis", windowValue);
        jsScope.declare("top", windowValue);
        jsScope.declare("parent", windowValue);
        windowObj.set("__getHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0 || thisValue.obj is null) return rt2.makeUndefined();
            return rt2.globalScope.get(rt2.toJsString(args[0]));
        }));
        windowObj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2 || thisValue.obj is null) return rt2.makeUndefined();
            const key = rt2.toJsString(args[0]);
            if (key == "location")
            {
                // `window.location = "..."` means "navigate there". The engine
                // cannot start a load from inside a script call, so the target
                // is recorded as the address the page now reports.
                auto target = args[1];
                auto loc = thisValue.obj.get("location");
                if (loc.obj !is null && target.kind == JsKind.string)
                    loc.obj.set("href", target);
                return rt2.makeUndefined();
            }
            rememberHandler(thisValue.obj, key, args[1]);
            // Assigning to a `window` property creates a global in a browser.
            if (!thisValue.obj.has(key)) rt2.globalScope.declare(key, args[1]);
            thisValue.obj.set(key, args[1]);
            return rt2.makeUndefined();
        }));
        documentValue = docVal;
        return docVal;
    }

    /// Build the `location` object for the document's address: the parts page
    /// code reads (`href`, `host`, `hostname`, `pathname`, ...).
    private JsValue makeLocation(string url)
    {
        auto obj = rt.makeObject();
        string scheme, host, path, query, fragment;
        ushort port;
        if (url.length)
        {
            auto parsed = Url.parse(url);
            if (parsed.ok)
            {
                scheme = parsed.scheme;
                host = parsed.host;
                port = parsed.port;
                path = parsed.path;
                query = parsed.query;
                fragment = parsed.fragment;
            }
        }
        // A default port is not part of the host a page prints: `location.host`
        // on https://example.com is "example.com", never "example.com:443".
        const defaultPort = cast(ushort) (scheme == "https" ? 443 : 80);
        if (port == defaultPort) port = 0;
        const authority = port ? host ~ ":" ~ to!string(port) : host;
        obj.obj.set("href", rt.makeString(url));
        obj.obj.set("protocol", rt.makeString(scheme.length ? scheme ~ ":" : ""));
        obj.obj.set("hostname", rt.makeString(host));
        obj.obj.set("host", rt.makeString(authority));
        obj.obj.set("port", rt.makeString(port ? to!string(port) : ""));
        obj.obj.set("pathname", rt.makeString(path.length ? path : (url.length ? "/" : "")));
        obj.obj.set("search", rt.makeString(query.length ? "?" ~ query : ""));
        obj.obj.set("hash", rt.makeString(fragment.length ? "#" ~ fragment : ""));
        obj.obj.set("origin", rt.makeString(scheme.length && host.length
            ? scheme ~ "://" ~ authority : ""));
        obj.obj.set("toString", rt.makeNativeFunc((thisValue, args, rt2) {
            auto self = thisValue.obj !is null ? thisValue.obj.get("href") : JsValue.init;
            return rt2.makeString(self.kind == JsKind.string ? self.strValue : "");
        }));
        // Navigation entry points. A page that calls them must not throw, but
        // the engine cannot begin a load from inside a script call, so they
        // record the target address instead of following it.
        JsFuncDelegate navigate = (thisValue, args, rt2) {
            if (args.length && thisValue.obj !is null)
                thisValue.obj.set("href", rt2.makeString(rt2.toJsString(args[0])));
            return rt2.makeUndefined();
        };
        obj.obj.set("assign", rt.makeNativeFunc(navigate));
        obj.obj.set("replace", rt.makeNativeFunc(navigate));
        obj.obj.set("reload", rt.makeNativeFunc((thisValue, args, rt2) {
            return rt2.makeUndefined();
        }));
        return obj;
    }

    /// A `MediaQueryList` for `window.matchMedia(query)`. `.matches` answers
    /// from the viewport the document is laid out in, evaluated by the same code
    /// the stylesheet's `@media` rules use. The engine reflows only when the
    /// host re-lays out the page, so a registered `change` listener is kept but
    /// is not fired by a viewport change.
    private JsValue makeMediaQueryList(string query)
    {
        auto obj = rt.makeObject();
        obj.obj.set("media", rt.makeString(query));
        obj.obj.set("matches", rt.makeBoolean(mediaQueryMatches(query, viewportWidth, viewportHeight)));
        obj.obj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2 || thisValue.obj is null) return rt2.makeUndefined();
            rememberHandler(thisValue.obj, rt2.toJsString(args[0]), args[1]);
            thisValue.obj.set(rt2.toJsString(args[0]), args[1]);
            return rt2.makeUndefined();
        }));
        auto listen = rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2 || thisValue.obj is null || args[1].kind != JsKind.func)
                return rt2.makeUndefined();
            thisValue.obj.set("__event_change", args[1]);
            return rt2.makeUndefined();
        });
        JsFuncDelegate drop = (thisValue, args, rt2) {
            if (thisValue.obj !is null)
                thisValue.obj.set("__event_change", rt2.makeUndefined());
            return rt2.makeUndefined();
        };
        obj.obj.set("addEventListener", listen);
        obj.obj.set("addListener", listen);      // the pre-2016 spelling
        obj.obj.set("removeEventListener", rt.makeNativeFunc(drop));
        obj.obj.set("removeListener", rt.makeNativeFunc(drop));
        obj.obj.set("dispatchEvent", rt.makeNativeFunc((thisValue, args, rt2) {
            return rt2.makeBoolean(true);
        }));
        return obj;
    }

    /// A `Storage` object (`localStorage`/`sessionStorage`): the methods a page
    /// calls plus property-style access (`localStorage.theme = "dark"`), which
    /// pages use interchangeably with `setItem`. The engine has no persistent
    /// profile store, so both areas last for this document.
    private JsValue makeStorage()
    {
        auto store = rt.makeObject();
        store.obj.kind = "Storage";
        string[] order;             // insertion order, which `key(i)` reports
        string[string] items;
        void put(string key, string value)
        {
            if (key in items) items[key] = value;
            else
            {
                items[key] = value;
                order ~= key;
            }
        }
        void take(string key)
        {
            if (key in items) items.remove(key);
            foreach (i, existing; order)
                if (existing == key)
                {
                    order = order[0 .. i] ~ order[i + 1 .. $];
                    break;
                }
        }
        store.obj.set("getItem", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto found = rt2.toJsString(args[0]) in items;
            return found is null ? rt2.makeNull() : rt2.makeString(*found);
        }));
        store.obj.set("setItem", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length >= 2) put(rt2.toJsString(args[0]), rt2.toJsString(args[1]));
            return rt2.makeUndefined();
        }));
        store.obj.set("removeItem", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length) take(rt2.toJsString(args[0]));
            return rt2.makeUndefined();
        }));
        store.obj.set("clear", rt.makeNativeFunc((thisValue, args, rt2) {
            items = null;
            order = null;
            return rt2.makeUndefined();
        }));
        store.obj.set("key", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto index = args[0];
            if (index.kind != JsKind.number && index.kind != JsKind.string)
                return rt2.makeNull();
            const text = index.kind == JsKind.string
                ? index.strValue.strip()
                : to!string(cast(long) index.numValue);
            if (!allDigits(text)) return rt2.makeNull();
            const i = parseLongOrZero(text);
            if (i < 0 || i >= order.length) return rt2.makeNull();
            return rt2.makeString(order[cast(size_t) i]);
        }));
        // Property-style access reads and writes the same map the methods use.
        store.obj.set("__getHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeUndefined();
            const key = rt2.toJsString(args[0]);
            if (key == "length") return rt2.makeNumber(cast(double) order.length);
            auto found = key in items;
            return found is null ? rt2.makeUndefined() : rt2.makeString(*found);
        }));
        store.obj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            put(rt2.toJsString(args[0]), rt2.toJsString(args[1]));
            return rt2.makeUndefined();
        }));
        return store;
    }

    /// The `document.cookie` string: this document's live cookies as
    /// `name=value` pairs separated by "; ".
    private string cookieHeader()
    {
        const now = unixNow();
        string text;
        foreach (name, c; cookies)
        {
            if (c.expires != 0 && c.expires <= now) continue;
            if (text.length) text ~= "; ";
            text ~= name ~ "=" ~ c.value;
        }
        return text;
    }

    /// Update the viewport the page sees after the host resized it.
    void setViewportSize(int width, int height)
    {
        viewportWidth = width;
        viewportHeight = height;
        void publish(string name, double value)
        {
            rt.globalScope.declare(name, rt.makeNumber(value));
        }
        publish("innerWidth", width);
        publish("innerHeight", height);
        publish("outerWidth", width);
        publish("outerHeight", height);
        if (windowValue.obj is null) return;
        windowValue.obj.set("innerWidth", rt.makeNumber(width));
        windowValue.obj.set("innerHeight", rt.makeNumber(height));
        windowValue.obj.set("outerWidth", rt.makeNumber(width));
        windowValue.obj.set("outerHeight", rt.makeNumber(height));
        auto screenObj = windowValue.obj.get("screen");
        if (screenObj.obj !is null)
        {
            screenObj.obj.set("width", rt.makeNumber(width));
            screenObj.obj.set("height", rt.makeNumber(height));
            screenObj.obj.set("availWidth", rt.makeNumber(width));
            screenObj.obj.set("availHeight", rt.makeNumber(height));
        }
    }

    /// Build a minimal Fetch API Response object from the resource loader.
    private JsValue fetchResponse(JsRuntime rt, JsValue urlValue,
        ubyte[] delegate(string url) @safe resourceLoader)
    {
        auto urlStr = urlValue.kind == JsKind.string
            ? urlValue.strValue
            : rt.toJsString(urlValue);
        ubyte[] body;
        bool failed = false;
        string errorText;
        if (urlStr.length == 0)
        {
            failed = true;
            errorText = "fetch requires a URL";
        }
        else
        {
            try
            {
                auto bytes = resourceLoader(urlStr);
                body = bytes !is null ? bytes : (cast(ubyte[]) null);
                if (body.length == 0)
                {
                    failed = true;
                    errorText = "failed to fetch " ~ urlStr;
                }
            }
            catch (Exception exc)
            {
                failed = true;
                errorText = exc.msg;
            }
        }

        auto resp = new JsObject();
        resp.kind = "Object";
        resp.set("ok", rt.makeBoolean(!failed));
        resp.set("status", rt.makeNumber(failed ? 0 : 200));
        resp.set("statusText", rt.makeString(failed ? errorText : "OK"));
        resp.set("url", rt.makeString(urlStr));

        // headers object: lower-cased header name -> value (loader gives raw
        // bytes, so expose only content-type/status metadata here).
        auto headersObj = new JsObject();
        headersObj.kind = "Object";
        resp.set("headers", JsValue(JsKind.object, headersObj));

        // text(): returns the body as a JS string.
        resp.set("text", rt.makeNativeFunc((thisValue, args, rt2) {
            auto respObj = thisValue.obj;
            if (respObj.has("__body"))
            {
                auto b = respObj.get("__body").strValue;
                return rt2.makeString(b);
            }
            return rt2.makeString("");
        }));

        // json(): parse the body with the built-in JSON.parse.
        resp.set("json", rt.makeNativeFunc((thisValue, args, rt2) {
            auto respObj = thisValue.obj;
            auto textVal = respObj.get("__body");
            if (textVal.kind == JsKind.string)
            {
                auto jsonFn = rt2.globalScope.get("JSON");
                if (jsonFn.kind == JsKind.object)
                {
                    auto parseFn = jsonFn.obj.get("parse");
                    if (parseFn.kind == JsKind.func)
                    {
                        JsValue[] parseArgs;
                        parseArgs ~= textVal;
                        return rt2.callFunction(parseFn, jsonFn, parseArgs);
                    }
                }
            }
            return rt2.makeUndefined();
        }));

        if (failed)
        {
            resp.set("__error", rt.makeString(errorText));
            resp.set("__body", rt.makeString(""));
        }
        else
        {
            // Store the raw body as UTF-8 text for text()/json().
            import std.utf : toUTF8;
            resp.set("__body", rt.makeString(toUTF8(cast(const(char)[]) body)));
        }

        // Minimal Promise shim: fetch(...).then(cb) invokes cb synchronously
        // with the response object and returns the response.
        auto thenFn = rt.makeNativeFunc((thisValue, args, rt2) {
            auto respObj = thisValue.obj;
            if (args.length && args[0].kind == JsKind.func)
            {
                JsValue[] cbArgs;
                cbArgs ~= JsValue(JsKind.object, respObj);
                rt2.callFunction(args[0], JsValue(JsKind.object, rt2.globalObject),
                    cbArgs);
            }
            return thisValue;
        });
        resp.set("then", thenFn);

        return JsValue(JsKind.object, resp);
    }

    JsValue wrap(Element el)
    {
        if (auto found = el in wrappers)
            return JsValue(JsKind.object, *found);
        auto obj = new JsObject();
        obj.kind = "Object";
        obj.set("nodeType", rt.makeNumber(1));
        obj.set("tagName", rt.makeString(el.tag.toUpper()));
        obj.set("id", rt.makeString(el.attrs.get("id", "")));
        obj.set("className", rt.makeString(el.attrs.get("class", "")));
        obj.set("style", rt.makeString(el.attrs.get("style", "")));
        obj.set("textContent", rt.makeString(el.textContent()));
        // Element geometry (CSSOM View). Scripts measure layout with these:
        // scroll effects, sticky headers, "reveal on scroll", tooltips and
        // canvas overlays all read `getBoundingClientRect` before they do
        // anything else, and a page whose script throws on the missing method
        // never runs the rest of its code. The numbers come from the box the
        // last layout pass filled in, so a rect read after a layout (or from an
        // observer callback) is the geometry the frame paints.
        obj.set("getBoundingClientRect", rt.makeNativeFunc((thisValue, args, rt2) {
            auto target = unwrap(thisValue);
            if (target is null) return rectValue(0, 0, 0, 0);
            double x, y, w, h;
            borderBoxInViewport(target, x, y, w, h);
            return rectValue(x, y, w, h);
        }));
        obj.set("__get_offsetWidth", rt.makeNativeFunc((thisValue, args, rt2) {
            auto target = unwrap(thisValue);
            if (target is null) return rt2.makeNumber(0);
            double x, y, w, h;
            borderBoxInViewport(target, x, y, w, h);
            return rt2.makeNumber(w);
        }));
        obj.set("__get_offsetHeight", rt.makeNativeFunc((thisValue, args, rt2) {
            auto target = unwrap(thisValue);
            if (target is null) return rt2.makeNumber(0);
            double x, y, w, h;
            borderBoxInViewport(target, x, y, w, h);
            return rt2.makeNumber(h);
        }));
        // The client box is the padding box: the border edge is where the
        // painted border starts, so the borders come back off.
        obj.set("__get_clientWidth", rt.makeNativeFunc((thisValue, args, rt2) {
            auto target = unwrap(thisValue);
            if (target is null) return rt2.makeNumber(0);
            double x, y, w, h;
            borderBoxInViewport(target, x, y, w, h);
            return rt2.makeNumber(w - target.box.borderLeft - target.box.borderRight);
        }));
        obj.set("__get_clientHeight", rt.makeNativeFunc((thisValue, args, rt2) {
            auto target = unwrap(thisValue);
            if (target is null) return rt2.makeNumber(0);
            double x, y, w, h;
            borderBoxInViewport(target, x, y, w, h);
            return rt2.makeNumber(h - target.box.borderTop - target.box.borderBottom);
        }));

        // An `<img>`'s loaded state. Real pages gate a reveal on it — boqsc.eu
        // fades its hero photo in with `if (img.complete && img.naturalWidth > 0)
        // reveal()` and otherwise waits for a `load` listener — so an engine
        // that answers neither leaves a decoded photograph at `opacity: 0`
        // forever. `complete` is a settled image: decoded, or a fetch that is
        // finished failing and will not be retried.
        if (el.tag == "img")
        {
            obj.set("__get_complete", rt.makeNativeFunc((thisValue, args, rt2) {
                auto target = unwrap(thisValue);
                if (target is null) return rt2.makeBoolean(false);
                return rt2.makeBoolean(target.image !is null || target.imageLoadTried);
            }));
            obj.set("__get_naturalWidth", rt.makeNativeFunc((thisValue, args, rt2) {
                import aurora.image : RgbaImage;
                auto target = unwrap(thisValue);
                auto decoded = target is null ? null : cast(RgbaImage) target.image;
                return rt2.makeNumber(decoded is null ? 0 : decoded.width);
            }));
            obj.set("__get_naturalHeight", rt.makeNativeFunc((thisValue, args, rt2) {
                import aurora.image : RgbaImage;
                auto target = unwrap(thisValue);
                auto decoded = target is null ? null : cast(RgbaImage) target.image;
                return rt2.makeNumber(decoded is null ? 0 : decoded.height);
            }));
        }

        // Inline event-handler attributes (`onclick`, `oninput`, `onchange`,
        // ...): compile the attribute source into a handler function and
        // register it exactly like `addEventListener`, so events dispatched by
        // the host (real clicks/keystrokes) run the page's inline handlers.
        foreach (name, source; el.attrs)
        {
            if (name.length <= 2 || name[0 .. 2] != "on") continue;
            if (source.length == 0) continue;
            const evt = name[2 .. $].toLower();
            obj.set("__event_" ~ evt, makeInlineHandler(evt));
        }

        obj.set("getAttribute", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto name = rt2.toJsString(args[0]);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeNull();
            auto it = name in el2.attrs;
            if (it is null) return rt2.makeNull();
            return rt2.makeString(*it);
        }));

        obj.set("setAttribute", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            auto name = rt2.toJsString(args[0]);
            auto value = rt2.toJsString(args[1]);
            el2.attrs[name] = value;
            return rt2.makeUndefined();
        }));

        obj.set("appendChild", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeUndefined();
            auto parentEl = unwrap(thisValue);
            if (parentEl is null) return rt2.makeUndefined();
            auto childValue = args[0];
            if (childValue.kind == JsKind.object)
            {
                auto childEl = unwrap(childValue);
                if (childEl !is null)
                {
                    parentEl.children ~= childEl;
                    parentEl.elements ~= childEl;
                    childEl.parent = parentEl;
                }
                else if (childValue.obj !is null &&
                    childValue.obj.get("__text").kind == JsKind.string)
                {
                    auto textNode = new TextNode(parentEl,
                        rt2.toJsString(childValue.obj.get("__text")));
                    parentEl.children ~= textNode;
                    parentEl.textNodes ~= textNode;
                }
            }
            return childValue;
        }));

        obj.set("removeChild", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeUndefined();
            auto parentEl = unwrap(thisValue);
            if (parentEl is null) return rt2.makeUndefined();
            auto childValue = args[0];
            auto childEl = unwrap(childValue);
            if (childEl !is null)
            {
                foreach (i, child; parentEl.children)
                {
                    if (cast(Element) child is childEl)
                    {
                        parentEl.children = parentEl.children[0 .. i] ~ parentEl.children[i + 1 .. $];
                        break;
                    }
                }
                foreach (i, child; parentEl.elements)
                {
                    if (child is childEl)
                    {
                        parentEl.elements = parentEl.elements[0 .. i] ~ parentEl.elements[i + 1 .. $];
                        break;
                    }
                }
            }
            return childValue;
        }));

        obj.set("addEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            auto evtName = rt2.toJsString(args[0]);
            thisValue.obj.set("__event_" ~ evtName, args[1]);
            return rt2.makeUndefined();
        }));

        obj.set("removeEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto evtName = rt2.toJsString(args[0]);
            thisValue.obj.props.remove("__event_" ~ evtName);
            return rt2.makeUndefined();
        }));

        obj.set("dispatchEvent", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeBoolean(false);
            auto evtArg = args[0];
            string evtName = "";
            JsValue evt;
            if (evtArg.kind == JsKind.object && evtArg.obj !is null)
            {
                // A constructed Event object: read its .type property.
                auto typeVal = evtArg.obj.get("type");
                if (typeVal.kind == JsKind.string) evtName = typeVal.strValue;
                evt = evtArg;
                evt.obj.set("target", thisValue);
            }
            else
            {
                // A string event name.
                evtName = rt2.toJsString(evtArg);
                evt = makeEventObject(rt2, evtName, thisValue);
            }
            if (evtName.length == 0) return rt2.makeBoolean(false);
            fireEventChain(thisValue, rt2, evtName, evt);
            // A click on a submit control (button / input[type=submit]) submits
            // the closest ancestor form.
            if (evtName == "click")
            {
                Element submitControl = null;
                auto walkEl = unwrap(thisValue);
                while (walkEl !is null)
                {
                    if (isSubmitControl(walkEl)) { submitControl = walkEl; break; }
                    walkEl = walkEl.parent;
                }
                if (submitControl !is null)
                {
                    auto formEl = submitControl.parent;
                    while (formEl !is null && formEl.tag != "form")
                        formEl = formEl.parent;
                    if (formEl !is null)
                        performSubmit(formEl, wrap(formEl), rt2);
                }
            }
            return rt2.makeBoolean(true);
        }));

        // innerHTML: getter serializes children; setter parses and replaces.
        obj.set("__innerHTML", makeInnerHtmlHandler(el));
        obj.set("__classList", makeClassList(el));
        obj.set("__styleObj", makeStyleObject(el));
        obj.set("__setHandler", makeElementSetHandler(el));

        // Form controls: expose `form.elements` (array of wrapped named
        // controls) and `form.submit()`.
        obj.set("__get_elements", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            auto arr = rt2.makeArray();
            if (el2 is null || el2.tag != "form") return arr;
            size_t idx = 0;
            foreach (child; collectControls(el2))
            {
                arr.obj.set(to!string(idx), wrap(child));
                idx++;
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));

        obj.set("submit", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            performSubmit(el2, thisValue, rt2);
            return rt2.makeUndefined();
        }));

        // getComputedStyle: computed layout box + declared style.
        obj.set("__get_computedStyle", rt.makeNativeFunc((thisValue, args, rt2) {
            return makeComputedStyle(unwrap(thisValue), rt2);
        }));

        // focus()/blur(): no-op state on the `focused` attribute.
        obj.set("focus", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 !is null) el2.attrs["focused"] = "true";
            return rt2.makeUndefined();
        }));

        obj.set("blur", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 !is null) el2.attrs.remove("focused");
            return rt2.makeUndefined();
        }));

        obj.set("__get_parentNode", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.parent is null) return rt2.makeNull();
            return wrap(el2.parent);
        }));

        obj.set("__get_previousSibling", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.parent is null) return rt2.makeNull();
            foreach (i, child; el2.parent.children)
            {
                auto ce = cast(Element) child;
                if (ce is el2)
                {
                    if (i == 0) return rt2.makeNull();
                    auto prev = cast(Element) el2.parent.children[i - 1];
                    if (prev !is null) return wrap(prev);
                    auto prevText = cast(TextNode) el2.parent.children[i - 1];
                    if (prevText !is null) return wrapTextNode(prevText);
                    return rt2.makeNull();
                }
            }
            return rt2.makeNull();
        }));

        obj.set("__get_nextSibling", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.parent is null) return rt2.makeNull();
            foreach (i, child; el2.parent.children)
            {
                auto ce = cast(Element) child;
                if (ce is el2)
                {
                    if (i + 1 >= el2.parent.children.length) return rt2.makeNull();
                    auto next = cast(Element) el2.parent.children[i + 1];
                    if (next !is null) return wrap(next);
                    auto nextText = cast(TextNode) el2.parent.children[i + 1];
                    if (nextText !is null) return wrapTextNode(nextText);
                    return rt2.makeNull();
                }
            }
            return rt2.makeNull();
        }));

        obj.set("__get_firstElementChild", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.elements.length == 0) return rt2.makeNull();
            return wrap(el2.elements[0]);
        }));

        obj.set("__get_lastElementChild", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.elements.length == 0) return rt2.makeNull();
            return wrap(el2.elements[$ - 1]);
        }));

        obj.set("__get_firstChild", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.children.length == 0) return rt2.makeNull();
            auto first = el2.children[0];
            auto fe = cast(Element) first;
            if (fe !is null) return wrap(fe);
            auto ft = cast(TextNode) first;
            if (ft !is null) return wrapTextNode(ft);
            return rt2.makeNull();
        }));

        obj.set("__get_lastChild", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.children.length == 0) return rt2.makeNull();
            auto last = el2.children[$ - 1];
            auto le = cast(Element) last;
            if (le !is null) return wrap(le);
            auto lt = cast(TextNode) last;
            if (lt !is null) return wrapTextNode(lt);
            return rt2.makeNull();
        }));

        obj.set("__get_children", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            auto arr = rt2.makeArray();
            if (el2 is null) return arr;
            size_t idx = 0;
            foreach (c; el2.children)
            {
                auto ce = cast(Element) c;
                if (ce !is null) { arr.obj.set(to!string(idx), wrap(ce)); idx++; }
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));

        obj.set("__get_childNodes", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            auto arr = rt2.makeArray();
            if (el2 is null) return arr;
            size_t idx = 0;
            foreach (c; el2.children)
            {
                auto ce = cast(Element) c;
                if (ce !is null) { arr.obj.set(to!string(idx), wrap(ce)); }
                else { auto ct = cast(TextNode) c; if (ct !is null) { arr.obj.set(to!string(idx), wrapTextNode(ct)); } }
                idx++;
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));

        // getters wired through property handlers: style, className, textContent,
        // innerHTML need custom get logic. We expose them as native funcs under
        // `__get_<name>` and override getProp in the JS engine to consult these.
        obj.set("__get_innerHTML", makeInnerHtmlGetter(el));
        obj.set("__get_textContent", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.textContent());
        }));
        obj.set("__get_innerText", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.textContent());
        }));
        obj.set("__get_style", rt.makeNativeFunc((thisValue, args, rt2) {
            return thisValue.obj.get("__styleObj");
        }));
        obj.set("__get_classList", rt.makeNativeFunc((thisValue, args, rt2) {
            return thisValue.obj.get("__classList");
        }));
        obj.set("__get_className", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.attrs.get("class", ""));
        }));
        obj.set("__get_id", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.attrs.get("id", ""));
        }));

        obj.set("__get_value", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeString("");
            switch (el2.tag)
            {
                case "button":
                    return rt2.makeString(el2.textContent());
                case "select":
                    return rt2.makeString(selectedOptionValue(el2));
                default:
                    return rt2.makeString(el2.attrs.get("value", ""));
            }
        }));

        obj.set("__get_checked", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeBoolean(el2 !is null && ("checked" in el2.attrs) !is null);
        }));

        obj.set("__get_type", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeString("");
            if (el2.tag == "input" || el2.tag == "button")
                return rt2.makeString(el2.attrs.get("type", "text"));
            return rt2.makeString(el2.tag);
        }));

        obj.set("__get_name", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.attrs.get("name", ""));
        }));

        obj.set("__get_placeholder", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeString(el2 is null ? "" : el2.attrs.get("placeholder", ""));
        }));

        obj.set("__get_focused", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            return rt2.makeBoolean(el2 !is null && ("focused" in el2.attrs) !is null);
        }));

        obj.set("querySelector", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto sel = rt2.toJsString(args[0]);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeNull();
            auto parsed = parseCssSelector(sel);
            foreach (child; descendants(el2))
            {
                if (selectorMatches(parsed, child))
                    return wrap(child);
            }
            return rt2.makeNull();
        }));

        obj.set("querySelectorAll", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto sel = rt2.toJsString(args[0]);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return arr;
            auto parsed = parseCssSelector(sel);
            size_t index = 0;
            foreach (child; descendants(el2))
            {
                if (selectorMatches(parsed, child))
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        // element.matches(selector): does this element match the selector?
        obj.set("matches", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeBoolean(false);
            auto sel = rt2.toJsString(args[0]);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeBoolean(false);
            return rt2.makeBoolean(selectorMatches(parseCssSelector(sel), el2));
        }));

        // element.closest(selector): nearest ancestor (incl. self) matching.
        obj.set("closest", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeNull();
            auto sel = rt2.toJsString(args[0]);
            auto parsed = parseCssSelector(sel);
            auto el2 = unwrap(thisValue);
            while (el2 !is null)
            {
                if (selectorMatches(parsed, el2)) return wrap(el2);
                el2 = el2.parent;
            }
            return rt2.makeNull();
        }));

        // element.contains(other): is other this element or a descendant?
        obj.set("contains", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeBoolean(false);
            auto other = unwrap(args[0]);
            if (other is null) return rt2.makeBoolean(false);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeBoolean(false);
            auto cur = other;
            while (cur !is null)
            {
                if (cur is el2) return rt2.makeBoolean(true);
                cur = cur.parent;
            }
            return rt2.makeBoolean(false);
        }));

        // element.getElementsByTagName("p"): array of wrapped descendants.
        obj.set("getElementsByTagName", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto tag = rt2.toJsString(args[0]).toLower();
            auto el2 = unwrap(thisValue);
            if (el2 is null) return arr;
            size_t index = 0;
            foreach (child; descendants(el2))
            {
                if (child.tag == tag)
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        // element.getElementsByClassName(".x" or "x"): array of wrapped descendants.
        obj.set("getElementsByClassName", rt.makeNativeFunc((thisValue, args, rt2) {
            auto arr = rt2.makeArray();
            if (args.length == 0) return arr;
            auto cls = rt2.toJsString(args[0]);
            if (cls.length > 1 && cls[0] == '.') cls = cls[1 .. $];
            if (cls.length == 0) return arr;
            auto el2 = unwrap(thisValue);
            if (el2 is null) return arr;
            size_t index = 0;
            foreach (child; descendants(el2))
            {
                if (child.hasClass(cls))
                {
                    arr.obj.set(to!string(index), wrap(child));
                    index++;
                }
            }
            arr.obj.arrayLength = index;
            return arr;
        }));

        // dataset: data-* attributes via camelCase property names. The object
        // is cached on the element wrapper and kept in sync: reads refresh the
        // props from the element's data-* attributes, writes update the
        // backing attribute (via the object's __setHandler).
        obj.set("__get_dataset", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeNull();
            auto ds = makeDatasetObject(el2, rt2);
            syncDataset(el2, ds, rt2);
            return ds;
        }));

        // insertAdjacentHTML(position, html).
        obj.set("insertAdjacentHTML", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto pos = rt2.toJsString(args[0]).strip().toLower();
            auto html = rt2.toJsString(args[1]);
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            insertAdjacentHtml(el2, pos, html);
            return rt2.makeUndefined();
        }));

        // remove(): detach this element from its parent.
        obj.set("remove", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 !is null) detachElement(el2);
            return rt2.makeUndefined();
        }));

        // replaceWith(...nodes): replace this element with nodes/text.
        obj.set("replaceWith", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            if (el2.parent !is null)
            {
                insertNodesAt(el2.parent, childrenIndexOf(el2), args, rt2);
                detachElement(el2);
            }
            return rt2.makeUndefined();
        }));

        // before(...nodes) / after(...nodes) / prepend(...nodes) / append(...nodes).
        obj.set("before", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            if (el2.parent !is null)
                insertNodesAt(el2.parent, childrenIndexOf(el2), args, rt2);
            return rt2.makeUndefined();
        }));

        obj.set("after", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            if (el2.parent !is null)
                insertNodesAt(el2.parent, childrenIndexOf(el2) + 1, args, rt2);
            return rt2.makeUndefined();
        }));

        obj.set("prepend", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            insertNodesAt(el2, 0, args, rt2);
            return rt2.makeUndefined();
        }));

        obj.set("append", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            insertNodesAt(el2, el2.children.length, args, rt2);
            return rt2.makeUndefined();
        }));

        // cloneNode(deep): deep (default) or shallow copy.
        obj.set("cloneNode", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeNull();
            bool deep = true;
            if (args.length && args[0].kind == JsKind.boolean)
                deep = args[0].boolValue;
            return wrap(cloneElement(el2, deep));
        }));

        // scrollIntoView(): no-op (the shell has no scroll); records the call.
        obj.set("scrollIntoView", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 !is null) el2.attrs["scrollIntoViewCalled"] = "true";
            return rt2.makeUndefined();
        }));

        wrappers[el] = obj;
        return JsValue(JsKind.object, obj);
    }

    /// A dataset object translating camelCase property names to data-* attrs.
    private JsValue makeDatasetObject(Element el, JsRuntime rt2)
    {
        // Cache one dataset object per element.
        if (auto cached = el in datasets)
            return JsValue(JsKind.object, *cached);
        auto obj = new JsObject();
        obj.kind = "Object";
        obj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto prop = rt2.toJsString(args[0]);
            auto value = rt2.toJsString(args[1]);
            el.attrs["data-" ~ camelToKebab(prop)] = value;
            if (thisValue.obj !is null)
                thisValue.obj.set(prop, args[1]);
            return rt2.makeUndefined();
        }));
        datasets[el] = obj;
        syncDataset(el, JsValue(JsKind.object, obj), rt2);
        return JsValue(JsKind.object, obj);
    }

    /// Refresh the dataset object's properties from the element's data-* attrs.
    private void syncDataset(Element el, JsValue dataset, JsRuntime rt2)
    {
        auto obj = dataset.obj;
        if (obj is null) return;
        foreach (k, v; el.attrs)
        {
            if (k.length > 5 && k[0 .. 5] == "data-")
            {
                auto prop = kebabToCamel(k[5 .. $]);
                if (prop.length) obj.set(prop, rt2.makeString(v));
            }
        }
    }

    /// Parse a fragment and insert nodes into `parent` at index `at`.
    /// Accepts Element wrappers, text strings, and text-node objects.
    private void insertNodesAt(Element parent, size_t at, JsValue[] args, JsRuntime rt2)
    {
        foreach (arg; args)
        {
            if (arg.kind == JsKind.string)
            {
                foreach (node; parseFragmentNodes(arg.strValue))
                {
                    auto ce = cast(Element) node;
                    if (ce !is null) ce.parent = parent;
                    else { auto ct = cast(TextNode) node; if (ct !is null) ct.parent = parent; }
                    insertChild(parent, node, at);
                    at++;
                }
            }
            else if (arg.kind == JsKind.object)
            {
                auto childEl = unwrap(arg);
                if (childEl !is null)
                {
                    detachElement(childEl);
                    childEl.parent = parent;
                    insertChild(parent, childEl, at);
                    at++;
                }
                else if (arg.obj !is null &&
                    arg.obj.get("__text").kind == JsKind.string)
                {
                    auto textNode = new TextNode(parent,
                        arg.obj.get("__text").strValue);
                    insertChild(parent, textNode, at);
                    at++;
                }
            }
        }
    }

    /// Insert a child node (Element or TextNode) into `children` at index `at`,
    /// keeping the elements/textNodes arrays consistent.
    private void insertChild(Element parent, Object node, size_t at)
    {
        if (at > parent.children.length) at = parent.children.length;
        parent.children = parent.children[0 .. at] ~ node ~ parent.children[at .. $];
        auto ce = cast(Element) node;
        if (ce !is null)
        {
            size_t ea = 0;
            foreach (idx, child; parent.children[0 .. at])
            {
                if (cast(Element) child !is null) ea++;
            }
            if (ea > parent.elements.length) ea = parent.elements.length;
            parent.elements = parent.elements[0 .. ea] ~ ce ~ parent.elements[ea .. $];
        }
        else
        {
            auto ct = cast(TextNode) node;
            if (ct !is null)
            {
                size_t ta = 0;
                foreach (idx, child; parent.children[0 .. at])
                {
                    if (cast(TextNode) child !is null) ta++;
                }
                if (ta > parent.textNodes.length) ta = parent.textNodes.length;
                parent.textNodes = parent.textNodes[0 .. ta] ~ ct ~ parent.textNodes[ta .. $];
            }
        }
    }

    /// Index of `el` in its parent's interleaved `children` array; -1 if absent.
    private long childrenIndexOf(Element el)
    {
        if (el.parent is null) return -1;
        foreach (idx, child; el.parent.children)
        {
            auto ce = cast(Element) child;
            if (ce is el) return cast(long) idx;
        }
        return -1;
    }

    /// Detach an element from its parent (children/elements lists).
    private void detachElement(Element el)
    {
        auto parent = el.parent;
        if (parent is null) return;
        parent.children = removeFrom(parent.children, cast(Object) el);
        parent.elements = removeFrom(parent.elements, el);
        el.parent = null;
    }

    /// Remove the first occurrence of `item` from a polymorphic node list.
    private Object[] removeFrom(Object[] list, Object item)
    {
        foreach (i, existing; list)
        {
            if (existing is item)
                return list[0 .. i] ~ list[i + 1 .. $];
        }
        return list;
    }

    /// Remove the first occurrence of `item` from an element list.
    private Element[] removeFrom(Element[] list, Element item)
    {
        foreach (i, existing; list)
        {
            if (existing is item)
                return list[0 .. i] ~ list[i + 1 .. $];
        }
        return list;
    }

    /// Deep or shallow clone of an element (with attrs, children, text).
    private Element cloneElement(Element el, bool deep)
    {
        auto copy = new Element(el.tag);
        foreach (k, v; el.attrs) copy.attrs[k] = v;
        if (deep)
        {
            foreach (child; el.children)
            {
                auto ce = cast(Element) child;
                if (ce !is null)
                {
                    auto childCopy = cloneElement(ce, true);
                    childCopy.parent = copy;
                    copy.children ~= childCopy;
                    copy.elements ~= childCopy;
                }
                else
                {
                    auto ct = cast(TextNode) child;
                    if (ct !is null)
                    {
                        auto textCopy = new TextNode(copy, ct.data);
                        copy.children ~= textCopy;
                        copy.textNodes ~= textCopy;
                    }
                }
            }
        }
        return copy;
    }

    /// Insert HTML parsed from a fragment at the given position.
    private void insertAdjacentHtml(Element el, string position, string html)
    {
        auto nodes = parseFragmentNodes(html);
        switch (position)
        {
            case "beforebegin":
                if (el.parent !is null)
                {
                    auto at = childrenIndexOf(el);
                    if (at < 0) return;
                    foreach (node; nodes)
                    {
                        auto ce = cast(Element) node;
                        if (ce !is null) ce.parent = el.parent;
                        else { auto ct = cast(TextNode) node; if (ct !is null) ct.parent = el.parent; }
                        insertChild(el.parent, node, cast(size_t) at);
                        at++;
                    }
                }
                break;
            case "afterbegin":
                foreach (node; nodes)
                {
                    auto ce = cast(Element) node;
                    if (ce !is null) ce.parent = el;
                    else { auto ct = cast(TextNode) node; if (ct !is null) ct.parent = el; }
                    insertChild(el, node, 0);
                }
                break;
            case "beforeend":
                foreach (node; nodes)
                {
                    auto ce = cast(Element) node;
                    if (ce !is null) ce.parent = el;
                    else { auto ct = cast(TextNode) node; if (ct !is null) ct.parent = el; }
                    insertChild(el, node, el.children.length);
                }
                break;
            case "afterend":
                if (el.parent !is null)
                {
                    auto at = childrenIndexOf(el) + 1;
                    if (at < 0) return;
                    foreach (node; nodes)
                    {
                        auto ce = cast(Element) node;
                        if (ce !is null) ce.parent = el.parent;
                        else { auto ct = cast(TextNode) node; if (ct !is null) ct.parent = el.parent; }
                        insertChild(el.parent, node, cast(size_t) at);
                        at++;
                    }
                }
                break;
            default:
                break;
        }
    }

    /// Parse a fragment into element AND text children. `parseFragment` only
    /// returns elements, dropping bare text; pure-text input yields a single
    /// TextNode instead.
    private Object[] parseFragmentNodes(string html)
    {
        import auroraweb.html : parseFragment;
        Object[] result;
        auto elements = parseFragment(html);
        if (elements.length == 0)
        {
            // Pure text fragment: parseFragment drops bare text.
            if (html.strip().length)
                result ~= new TextNode(null, html);
            return result;
        }
        foreach (element; elements) result ~= element;
        return result;
    }

    JsValue wrapTextNode(TextNode node)
    {
        auto obj = new JsObject();
        obj.kind = "Object";
        obj.set("nodeType", rt.makeNumber(3));
        obj.set("data", rt.makeString(node.data));
        obj.set("__text", rt.makeString(node.data));
        return JsValue(JsKind.object, obj);
    }

    /// Serialize an element's children to HTML.
    private string serializeChildren(Element el)
    {
        import std.string : replace;
        string result;
        void esc(string s)
        {
            result ~= s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
        }
        foreach (child; el.children)
        {
            auto ce = cast(Element) child;
            if (ce !is null)
            {
                result ~= "<" ~ ce.tag;
                foreach (k, v; ce.attrs)
                    result ~= " " ~ k ~ "=\"" ~ v ~ "\"";
                result ~= ">";
                result ~= serializeChildren(ce);
                result ~= "</" ~ ce.tag ~ ">";
            }
            else
            {
                auto ct = cast(TextNode) child;
                if (ct !is null) esc(ct.data);
            }
        }
        return result;
    }

    /// innerHTML setter handler: parses the fragment and replaces children.
    private JsValue makeInnerHtmlHandler(Element el)
    {
        return rt.makeNativeFunc((thisValue, args, rt2) {
            auto parent = unwrap(thisValue);
            if (parent is null) return rt2.makeUndefined();
            if (args.length == 0) return rt2.makeUndefined();
            auto html = rt2.toJsString(args[0]);
            // Clear children.
            parent.children = null;
            parent.elements = null;
            parent.textNodes = null;
            import auroraweb.html : parseFragment;
            foreach (node; parseFragment(html))
            {
                node.parent = parent;
                parent.children ~= node;
                parent.elements ~= node;
            }
            return rt2.makeUndefined();
        });
    }

    private JsValue makeInnerHtmlGetter(Element el)
    {
        return rt.makeNativeFunc((thisValue, args, rt2) {
            auto e = unwrap(thisValue);
            return rt2.makeString(e is null ? "" : serializeChildren(e));
        });
    }

    /// classList native object backed by the element's class attribute.
    private JsValue makeClassList(Element el)
    {
        auto obj = new JsObject();
        obj.kind = "Object";
        import std.algorithm : canFind;
        import std.array : split;
        string[] currentClasses()
        {
            auto c = "class" in el.attrs;
            if (c is null) return [];
            return (*c).split(" ");
        }
        void sync(string[] classes)
        {
            string joined;
            foreach (c; classes) { if (joined.length) joined ~= " "; joined ~= c; }
            el.attrs["class"] = joined;
        }
        obj.set("add", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeUndefined();
            auto cls = rt2.toJsString(args[0]);
            auto list = currentClasses();
            if (!canFind(list, cls)) list ~= cls;
            sync(list);
            return rt2.makeUndefined();
        }));
        obj.set("remove", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeUndefined();
            auto cls = rt2.toJsString(args[0]);
            auto list = currentClasses();
            string[] keep;
            foreach (c; list) if (c != cls) keep ~= c;
            sync(keep);
            return rt2.makeUndefined();
        }));
        obj.set("toggle", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeBoolean(false);
            auto cls = rt2.toJsString(args[0]);
            auto list = currentClasses();
            bool present = canFind(list, cls);
            if (present) { string[] keep; foreach (c; list) if (c != cls) keep ~= c; list = keep; }
            else list ~= cls;
            sync(list);
            return rt2.makeBoolean(!present);
        }));
        obj.set("contains", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeBoolean(false);
            auto cls = rt2.toJsString(args[0]);
            return rt2.makeBoolean(canFind(currentClasses(), cls));
        }));
        return JsValue(JsKind.object, obj);
    }

    /// style object: property writes update the element's style attribute.
    private JsValue makeStyleObject(Element el)
    {
        auto obj = new JsObject();
        obj.kind = "Object";
        // Write handler: el.style.<name> = value  ->  style attribute.
        obj.set("__setHandler", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto prop = rt2.toJsString(args[0]);
            auto value = rt2.toJsString(args[1]);
            auto cssProp = camelToKebab(prop);
            auto style = "style" in el.attrs;
            string s = style !is null ? *style : "";
            // Remove existing declaration for this property.
            string[] kept;
            import std.array : split;
            foreach (decl; s.split(';'))
            {
                auto d = decl.strip();
                if (d.length == 0) continue;
                auto colon = indexOf(d, ":");
                if (colon >= 0)
                {
                    auto name = d[0 .. colon].strip();
                    if (name.toLower() == cssProp) continue;
                }
                kept ~= d;
            }
            if (value.length)
                kept ~= cssProp ~ ": " ~ value;
            string joined;
            foreach (k; kept) { if (joined.length) joined ~= "; "; joined ~= k; }
            el.attrs["style"] = joined;
            return rt2.makeUndefined();
        }));
        // setProperty / getPropertyValue.
        obj.set("setProperty", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto prop = rt2.toJsString(args[0]);
            auto value = rt2.toJsString(args[1]);
            callSetHandler(thisValue, rt2, prop, value);
            return rt2.makeUndefined();
        }));
        obj.set("getPropertyValue", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length == 0) return rt2.makeString("");
            auto prop = rt2.toJsString(args[0]);
            auto cssProp = camelToKebab(prop);
            auto style = "style" in el.attrs;
            if (style is null) return rt2.makeString("");
            import std.array : split;
            foreach (decl; (*style).split(';'))
            {
                auto d = decl.strip();
                auto colon = indexOf(d, ":");
                if (colon >= 0)
                {
                    auto name = d[0 .. colon].strip();
                    if (name.toLower() == cssProp)
                        return rt2.makeString(d[colon + 1 .. $].strip());
                }
            }
            return rt2.makeString("");
        }));
        return JsValue(JsKind.object, obj);
    }

    private void callSetHandler(JsValue styleValue, JsRuntime rt2, string prop, string value)
    {
        auto handler = styleValue.obj.get("__setHandler");
        if (handler.kind == JsKind.func)
        {
            JsValue[] a; a ~= rt2.makeString(prop); a ~= rt2.makeString(value);
            rt2.callFunction(handler, styleValue, a);
        }
    }

    /// Element-level set handler: intercepts `value`/`checked` writes on form
    /// controls so they update the backing attribute (and fire change/input).
    private JsValue makeElementSetHandler(Element el)
    {
        return rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto prop = rt2.toJsString(args[0]);
            auto value = rt2.toJsString(args[1]);
            if (prop == "value")
            {
                el.attrs["value"] = value;
                if (el.tag == "button")
                    setTextContent(el, value);
                fireChangeEvents(el, thisValue, rt2);
                return rt2.makeUndefined();
            }
            if (prop == "checked")
            {
                if (args[1].isTruthy()) el.attrs["checked"] = "true";
                else el.attrs.remove("checked");
                return rt2.makeUndefined();
            }
            // `textContent`/`innerText` writes replace the element's children
            // with a single text node. Without this the assignment only stored
            // a shadow property on the JS wrapper, so `el.textContent = "..."`
            // never changed what the element rendered (and `__get_textContent`
            // still read the unchanged DOM text).
            if (prop == "textContent" || prop == "innerText")
            {
                setTextContent(el, value);
                return rt2.makeUndefined();
            }
            // Unknown props fall back to plain storage on the wrapper so
            // assignments like el.textContent = "..." keep working.
            thisValue.obj.set(prop, args[1]);
            return rt2.makeUndefined();
        });
    }

    /// Replace an element's children with a single text node.
    private void setTextContent(Element el, string text)
    {
        el.children = null;
        el.elements = null;
        el.textNodes = null;
        auto tn = new TextNode(el, text);
        el.children ~= tn;
        el.textNodes ~= tn;
    }

    /// A handler for an inline `on<eventName>="..."` attribute. The attribute
    /// source is read at FIRE time (so `setAttribute` updates take effect) and
    /// runs with `this` bound to the element and the event object available as
    /// the free variable `event`, like a real browser inline handler.
    private JsValue makeInlineHandler(string evtName)
    {
        const attrName = "on" ~ evtName;
        return rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null) return rt2.makeUndefined();
            auto it = attrName in el2.attrs;
            if (it is null || (*it).length == 0) return rt2.makeUndefined();
            try
            {
                rt2.globalScope.declare("__evt",
                    args.length ? args[0] : rt2.makeUndefined());
                auto program = rt2.parseInto("var event = __evt;\n" ~ (*it));
                rt2.runProgram(program, thisValue);
            }
            catch (Exception)
            {
                // A page's broken inline handler must not abort the interaction.
            }
            return rt2.makeUndefined();
        });
    }

    /// Fire a host-initiated event on `el` (a real user interaction). The event
    /// bubbles through ancestors. Returns true when a handler called
    /// `preventDefault()`.
    bool dispatchForHost(Element el, string type, string key = "", int deltaY = 0,
        bool bubbles = true)
    {
        auto wrapper = wrap(el);
        auto evt = makeEventObject(rt, type, wrapper);
        if (key.length)
            evt.obj.set("key", rt.makeString(key));
        if (deltaY != 0)
            evt.obj.set("deltaY", rt.makeNumber(deltaY));
        fireEventChain(wrapper, rt, type, evt, bubbles);
        auto cancelled = evt.obj.get("defaultPrevented");
        return cancelled.kind == JsKind.boolean && cancelled.boolValue;
    }

    /// Build a minimal Event object with preventDefault support.
    /// Fire a document/window-level event (`scroll`) at the object a page
    /// listened on. Returns true when a handler cancelled the event.
    bool dispatchOnDocument(string type)
    {
        auto target = (documentValue.obj !is null) ? documentValue : windowValue;
        if (target.obj is null) return false;
        auto evt = makeEventObject(rt, type, target);
        void run(JsValue holder)
        {
            if (holder.obj is null) return;
            auto handler = holder.obj.get("__event_" ~ type);
            if (handler.kind != JsKind.func) return;
            evt.obj.set("currentTarget", holder);
            JsValue[] callArgs;
            callArgs ~= evt;
            rt.callFunction(handler, holder, callArgs);
        }
        run(documentValue);
        run(windowValue);
        auto cancelled = evt.obj.get("defaultPrevented");
        return cancelled.kind == JsKind.boolean && cancelled.boolValue;
    }

    /// The border box of `el` in the coordinate system `getBoundingClientRect`
    /// reports: the box the layout pass placed at its border edge, shifted by
    /// the viewport scroll so `top` counts down the visible area. `Box.x`/`y`
    /// are the border-box origin while `Box.width`/`height` are the CONTENT
    /// size, so the paddings and borders complete the border box - the same
    /// arithmetic the painter uses to draw the field's own background.
    private void borderBoxInViewport(Element el, out double x, out double y,
        out double width, out double height)
    {
        x = el.box.x;
        y = el.box.y - viewportScrollY;
        width = el.box.width + el.box.paddingLeft + el.box.paddingRight +
            el.box.borderLeft + el.box.borderRight;
        height = el.box.height + el.box.paddingTop + el.box.paddingBottom +
            el.box.borderTop + el.box.borderBottom;
    }

    /// A DOMRect-shaped object (CSSOM View) for the geometry reads.
    private JsValue rectValue(double x, double y, double width, double height)
    {
        auto rect = rt.makeObject();
        rect.obj.set("x", rt.makeNumber(x));
        rect.obj.set("y", rt.makeNumber(y));
        rect.obj.set("left", rt.makeNumber(x));
        rect.obj.set("top", rt.makeNumber(y));
        rect.obj.set("right", rt.makeNumber(x + width));
        rect.obj.set("bottom", rt.makeNumber(y + height));
        rect.obj.set("width", rt.makeNumber(width));
        rect.obj.set("height", rt.makeNumber(height));
        return rect;
    }

    /// Add `target` to the observer's own `__targets` list.
    private void addObservedTarget(JsValue observer, JsValue target)
    {
        if (observer.obj is null) return;
        auto list = observer.obj.get("__targets");
        if (list.obj is null)
        {
            list = rt.makeArray();
            observer.obj.set("__targets", list);
        }
        const size_t at = list.obj.arrayLength;
        list.obj.set(to!string(at), target);
        if (at + 1 > list.obj.arrayLength) list.obj.arrayLength = at + 1;
    }

    /// Drop `target` from the observer's own `__targets` list.
    private void removeObservedTarget(JsValue observer, JsValue target)
    {
        if (observer.obj is null || target.obj is null) return;
        auto list = observer.obj.get("__targets");
        if (list.obj is null) return;
        auto kept = rt.makeArray();
        size_t at = 0;
        for (size_t i = 0; i < list.obj.arrayLength; i++)
        {
            auto item = list.obj.get(to!string(i));
            if (item.obj is target.obj) continue;
            kept.obj.set(to!string(at), item);
            at++;
        }
        kept.obj.arrayLength = at;
        observer.obj.set("__targets", kept);
    }

    /// The observer's threshold list. A page passes one number or an array;
    /// nothing means the single threshold 0 (fire on every entry and exit).
    private double[] observerThresholds(JsValue observer)
    {
        double[] result;
        if (observer.obj !is null)
        {
            auto value = observer.obj.get("thresholds");
            if (value.kind == JsKind.number) result ~= value.numValue;
            else if (value.obj !is null)
            {
                for (size_t i = 0; i < value.obj.arrayLength; i++)
                {
                    auto item = value.obj.get(to!string(i));
                    if (item.kind == JsKind.number) result ~= item.numValue;
                }
            }
        }
        if (result.length == 0) result ~= 0.0;
        import std.algorithm : sort;
        result.sort();
        return result;
    }

    /// Whether the ratio crossed one of the thresholds, which is what makes an
    /// observer report a target that stayed inside (or outside) the root.
    private static bool crossedThreshold(double before, double after,
        double[] thresholds)
    {
        foreach (t; thresholds)
            if ((before < t && after >= t) || (before >= t && after < t))
                return true;
        return false;
    }

    /// One number of a `rootMargin` string, in pixels (`px`, unitless) or as a
    /// fraction of the root (`%`).
    private static double rootMarginValue(string token, out bool isPercent)
    {
        auto t = token.strip();
        isPercent = t.endsWith("%");
        if (isPercent) t = t[0 .. $ - 1];
        else if (t.endsWith("px")) t = t[0 .. $ - 2];
        try return to!double(t.strip());
        catch (Exception) return 0.0;
    }

    /// Grow (or shrink) the root rectangle by a `rootMargin` string, following
    /// the CSS shorthand's 1/2/3/4-value patterns. Percentages resolve against
    /// the matching viewport dimension, as they do in a browser.
    private static void applyRootMargin(string text, double viewportWidth,
        double viewportHeight, ref double rootTop, ref double rootRight,
        ref double rootBottom, ref double rootLeft)
    {
        double[4] value;
        bool[4] percent;
        int count = 0;
        foreach (token; text.split())
        {
            if (count == 4) break;
            value[count] = rootMarginValue(token, percent[count]);
            count++;
        }
        if (count == 0) return;
        const double top = value[0];
        const double right = count > 1 ? value[1] : value[0];
        const double bottom = count > 2 ? value[2] : value[0];
        const double left = count > 3 ? value[3] : (count > 1 ? value[1] : value[0]);
        const bool topPct = percent[0];
        const bool rightPct = count > 1 ? percent[1] : percent[0];
        const bool bottomPct = count > 2 ? percent[2] : percent[0];
        const bool leftPct = count > 3 ? percent[3] : (count > 1 ? percent[1] : percent[0]);
        rootTop += topPct ? top / 100.0 * viewportHeight : top;
        rootBottom += bottomPct ? bottom / 100.0 * viewportHeight : bottom;
        rootLeft += leftPct ? left / 100.0 * viewportWidth : left;
        rootRight += rightPct ? right / 100.0 * viewportWidth : right;
    }

    /// Deliver the callbacks the current geometry warrants, one batch per
    /// observer, in registration order. Returns true when a callback ran.
    bool evaluateIntersectionObservers()
    {
        import std.algorithm : max, min;
        if (ioObservations.length == 0) return false;
        JsObject[] observers;
        JsValue[][] batches;
        const double time = rt.eventLoop !is null ? rt.eventLoop.now() : 0.0;
        foreach (ref row; ioObservations)
        {
            if (row.observer is null || row.target is null) continue;
            double boxX, boxY, boxW, boxH;
            borderBoxInViewport(row.target, boxX, boxY, boxW, boxH);
            double rootTop = 0, rootLeft = 0;
            double rootBottom = viewportHeight, rootRight = viewportWidth;
            auto margin = row.observer.get("rootMargin");
            if (margin.kind == JsKind.string && margin.strValue.strip().length)
                applyRootMargin(margin.strValue, viewportWidth, viewportHeight,
                    rootTop, rootRight, rootBottom, rootLeft);
            const double interLeft = max(boxX, rootLeft);
            const double interTop = max(boxY, rootTop);
            const double interRight = min(boxX + boxW, rootRight);
            const double interBottom = min(boxY + boxH, rootBottom);
            const double interW = max(0.0, interRight - interLeft);
            const double interH = max(0.0, interBottom - interTop);
            const double boxArea = boxW * boxH;
            const double interArea = interW * interH;
            const bool intersecting = interArea > 0.0;
            // A zero-area target still reports whether it is inside the root.
            const double ratio = boxArea > 0.0
                ? (interArea >= boxArea ? 1.0 : interArea / boxArea)
                : (intersecting ? 1.0 : 0.0);
            if (row.reported && intersecting == row.lastIntersecting &&
                !crossedThreshold(row.lastRatio, ratio, observerThresholds(
                    JsValue(JsKind.object, row.observer))))
                continue;
            row.reported = true;
            row.lastIntersecting = intersecting;
            row.lastRatio = ratio;
            auto entry = rt.makeObject();
            entry.obj.set("time", rt.makeNumber(time));
            entry.obj.set("target", wrap(row.target));
            entry.obj.set("rootBounds", rectValue(rootLeft, rootTop,
                rootRight - rootLeft, rootBottom - rootTop));
            entry.obj.set("boundingClientRect", rectValue(boxX, boxY, boxW, boxH));
            entry.obj.set("intersectionRect", rectValue(interLeft, interTop, interW, interH));
            entry.obj.set("isIntersecting", rt.makeBoolean(intersecting));
            entry.obj.set("intersectionRatio", rt.makeNumber(ratio));
            auto value = JsValue(JsKind.object, entry.obj);
            size_t at = observers.length;
            foreach (i, existing; observers)
                if (existing is row.observer) { at = i; break; }
            if (at == observers.length)
            {
                observers ~= row.observer;
                batches ~= [value];
            }
            else
                batches[at] ~= value;
        }
        if (observers.length == 0) return false;
        foreach (i, observer; observers)
        {
            auto callback = observer.get("__callback");
            if (callback.kind != JsKind.func) continue;
            auto entries = rt.makeArray();
            foreach (at, entry; batches[i])
            {
                entries.obj.set(to!string(at), entry);
                if (at + 1 > entries.obj.arrayLength)
                    entries.obj.arrayLength = at + 1;
            }
            JsValue[] args;
            args ~= entries;
            args ~= JsValue(JsKind.object, observer);
            // A failing callback must not tear down the layout pass; the page
            // keeps its observers and reports again on the next crossing.
            try rt.callFunction(callback, JsValue(JsKind.object, observer), args);
            catch (Exception) { rt.lastHadException = true; }
        }
        return true;
    }

    /// `document.readyState`, as the host publishes it through
    /// `setDocumentReadyState`. It starts at the state a document is in while
    /// its own scripts run.
    string readyState = "loading";

    /// Move `document.readyState` to the state the host reports.
    void setReadyState(string state)
    {
        if (state.length) readyState = state;
    }

    /// Publish the viewport scroll offset to the page's globals.
    void setViewportScroll(int scrollY)
    {
        viewportScrollY = scrollY;
        if (windowValue.obj !is null)
        {
            windowValue.obj.set("scrollY", rt.makeNumber(scrollY));
            windowValue.obj.set("pageYOffset", rt.makeNumber(scrollY));
        }
        if (documentValue.obj !is null)
        {
            auto docEl = documentValue.obj.get("documentElement");
            if (docEl.obj !is null)
                docEl.obj.set("scrollTop", rt.makeNumber(scrollY));
        }
    }

    private JsValue makeEventObject(JsRuntime rt2, string evtName, JsValue target)
    {
        auto evt = rt2.makeObject();
        evt.obj.set("type", rt2.makeString(evtName));
        evt.obj.set("target", target);
        evt.obj.set("currentTarget", target);
        evt.obj.set("defaultPrevented", rt2.makeBoolean(false));
        evt.obj.set("propagationStopped", rt2.makeBoolean(false));
        evt.obj.set("cancelable", rt2.makeBoolean(evtName == "submit" || evtName == "click"));
        evt.obj.set("preventDefault", rt2.makeNativeFunc((thisValue, args, rt3) {
            auto eo = thisValue.obj;
            if (eo !is null)
                eo.set("defaultPrevented", rt3.makeBoolean(true));
            return rt3.makeUndefined();
        }));
        evt.obj.set("stopPropagation", rt2.makeNativeFunc((thisValue, args, rt3) {
            auto eo = thisValue.obj;
            if (eo !is null)
                eo.set("propagationStopped", rt3.makeBoolean(true));
            return rt3.makeUndefined();
        }));
        return evt;
    }

    /// Fire a leaf handler, then bubble up ancestors. The submit event is
    /// dispatched through this same bubbling path.
    private void fireEventChain(JsValue targetValue, JsRuntime rt2, string evtName,
        JsValue evt, bool bubbles = true)
    {
        auto cur = targetValue;
        auto curEl = unwrap(cur);
        while (cur.kind == JsKind.object)
        {
            if (evt.kind == JsKind.object && evt.obj !is null)
                evt.obj.set("currentTarget", cur);
            auto handler = cur.obj.get("__event_" ~ evtName);
            if (handler.kind == JsKind.func)
            {
                JsValue[] callArgs; callArgs ~= evt;
                rt2.callFunction(handler, cur, callArgs);
            }
            // stopPropagation() halts the bubble to ancestors.
            if (evt.kind == JsKind.object && evt.obj !is null)
            {
                auto stopped = evt.obj.get("propagationStopped");
                if (stopped.kind == JsKind.boolean && stopped.boolValue) break;
            }
            // Move to parent.
            if (!bubbles) break;
            if (curEl is null || curEl.parent is null) break;
            curEl = curEl.parent;
            cur = wrap(curEl);
        }
    }

    /// Fire a change/input event on the element (leaf + bubble).
    private void fireChangeEvents(Element el, JsValue wrapper, JsRuntime rt2)
    {
        foreach (evtName; ["input", "change"])
        {
            auto evt = makeEventObject(rt2, evtName, wrapper);
            fireEventChain(wrapper, rt2, evtName, evt);
        }
    }

    /// A submit control: <button> or <input type="submit"> (also text/checkbox/radio).
    private bool isSubmitControl(Element el)
    {
        if (el.tag == "button") return true;
        if (el.tag == "input")
        {
            auto t = el.attrs.get("type", "text");
            if (t == "submit" || t == "text" || t == "checkbox" || t == "radio")
                return true;
        }
        return false;
    }

    /// Collect form controls in document order (input/select/textarea/button).
    private Element[] collectControls(Element form)
    {
        Element[] result;
        void walk(Element el)
        {
            foreach (child; el.elements)
            {
                if (isFormControl(child)) result ~= child;
                walk(child);
            }
        }
        walk(form);
        return result;
    }

    private bool isFormControl(Element el)
    {
        switch (el.tag)
        {
            case "input", "select", "textarea", "button":
                return true;
            default:
                return false;
        }
    }

    /// Perform a form submission: dispatch the submit event; if not prevented,
    /// collect name=value pairs and expose the encoded query as `__lastSubmit`.
    private void performSubmit(Element form, JsValue formValue, JsRuntime rt2)
    {
        auto evt = makeEventObject(rt2, "submit", formValue);
        fireEventChain(formValue, rt2, "submit", evt);
        auto cancelled = evt.obj.get("defaultPrevented");
        if (cancelled.kind == JsKind.boolean && cancelled.boolValue) return;
        auto pairs = formPairs(form);
        auto query = encodePairs(pairs);
        auto action = form.attrs.get("action", "");
        rt2.globalScope.declare("__lastSubmit", rt2.makeString(
            action.length ? action ~ "?" ~ query : query));
    }

    private struct NameValue
    {
        string name;
        string value;
    }

    /// Collect name=value pairs from the form's controls (in document order).
    private NameValue[] formPairs(Element form)
    {
        NameValue[] pairs;
        foreach (control; collectControls(form))
        {
            auto name = control.attrs.get("name", "");
            if (name.length == 0) continue;
            string value = "";
            switch (control.tag)
            {
                case "input":
                    if (control.attrs.get("type", "text") == "checkbox" ||
                        control.attrs.get("type", "text") == "radio")
                    {
                        if (("checked" in control.attrs) !is null)
                            value = control.attrs.get("value", "on");
                    }
                    else value = control.attrs.get("value", "");
                    break;
                case "textarea":
                {
                    auto va = "value" in control.attrs;
                    value = (va !is null && (*va).length) ? *va : control.textContent();
                    break;
                }
                case "select":
                    value = selectedOptionValue(control);
                    break;
                case "button":
                    value = control.textContent();
                    break;
                default:
                    break;
            }
            pairs ~= NameValue(name, value);
        }
        return pairs;
    }

    private string selectedOptionValue(Element select)
    {
        string fallback;
        foreach (child; select.elements)
        {
            if (child.tag != "option") continue;
            auto value = child.attrs.get("value", "");
            auto text = child.textContent();
            if (value.length == 0) value = text;
            if (fallback.length == 0) fallback = value;
            if (("selected" in child.attrs) !is null)
                return value;
        }
        return fallback;
    }

    /// URL-encode name=value pairs joined with '&'.
    private string encodePairs(NameValue[] pairs)
    {
        string[] parts;
        foreach (pair; pairs)
        {
            if (pair.name.length == 0) continue;
            parts ~= urlEncode(pair.name) ~ "=" ~ urlEncode(pair.value);
        }
        string result;
        foreach (part; parts)
        {
            if (result.length) result ~= "&";
            result ~= part;
        }
        return result;
    }

    private string urlEncode(string s)
    {
        import std.array : appender;
        auto buf = appender!string;
        foreach (ch; s)
        {
            bool unreserved = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == '~';
            if (unreserved)
                buf.put(ch);
            else
            {
                buf.put('%');
                buf.put(hexDigit((ch >> 4) & 0xF));
                buf.put(hexDigit(ch & 0xF));
            }
        }
        return buf.data;
    }

    private char hexDigit(int v)
    {
        return cast(char)(v < 10 ? '0' + v : 'A' + (v - 10));
    }

    /// Computed style for an element: color/fontSize/display from the computed
    /// style (or the inline style attribute), width/height from the layout box.
    private JsValue makeComputedStyle(Element el, JsRuntime rt2)
    {
        auto obj = rt2.makeObject();
        obj.obj.kind = "Object";
        if (el is null)
        {
            obj.obj.set("color", rt2.makeString(""));
            obj.obj.set("fontSize", rt2.makeString(""));
            obj.obj.set("display", rt2.makeString(""));
            obj.obj.set("width", rt2.makeString(""));
            obj.obj.set("height", rt2.makeString(""));
            return obj;
        }
        string color = "black";
        string fontSize = "16px";
        string display = "inline";
        if (el.style.fontSize.length)
        {
            color = el.style.color;
            fontSize = el.style.fontSize;
            display = el.style.display;
        }
        // Inline style attribute wins when no computed style was computed.
        auto styleAttr = "style" in el.attrs;
        if (styleAttr !is null)
        {
            import std.array : split;
            foreach (decl; (*styleAttr).split(';'))
            {
                auto d = decl.strip();
                auto colon = indexOf(d, ":");
                if (colon < 0) continue;
                auto prop = d[0 .. colon].strip().toLower();
                auto value = d[colon + 1 .. $].strip();
                switch (prop)
                {
                    case "color": color = value; break;
                    case "font-size": fontSize = value; break;
                    case "display": display = value; break;
                    default: break;
                }
            }
        }
        string width = el.box.width > 0 ? to!string(el.box.width) ~ "px" : "auto";
        string height = el.box.height > 0 ? to!string(el.box.height) ~ "px" : "auto";
        obj.obj.set("color", rt2.makeString(color));
        obj.obj.set("fontSize", rt2.makeString(fontSize));
        obj.obj.set("display", rt2.makeString(display));
        obj.obj.set("width", rt2.makeString(width));
        obj.obj.set("height", rt2.makeString(height));
        return obj;
    }

    private string camelToKebab(string s)
    {
        string result;
        foreach (ch; s)
        {
            if (ch >= 'A' && ch <= 'Z')
            {
                if (result.length) result ~= "-";
                result ~= cast(char)(ch - 'A' + 'a');
            }
            else result ~= ch;
        }
        return result;
    }

    private string kebabToCamel(string s)
    {
        string result;
        bool upperNext;
        foreach (ch; s)
        {
            if (ch == '-') { upperNext = true; continue; }
            if (upperNext && ch >= 'a' && ch <= 'z')
            {
                result ~= cast(char)(ch - 'a' + 'A');
                upperNext = false;
            }
            else
            {
                result ~= ch;
                upperNext = false;
            }
        }
        return result;
    }

    Element unwrap(JsValue value)
    {
        if (value.kind != JsKind.object && value.kind != JsKind.func) return null;
        if (value.obj is null) return null;
        foreach (el, wrapper; wrappers)
            if (wrapper is value.obj) return el;
        return null;
    }

    private Element[] descendants(Element root)
    {
        Element[] result;
        void walk(Element el)
        {
            foreach (child; el.elements)
            {
                result ~= child;
                walk(child);
            }
        }
        walk(root);
        return result;
    }

    private Element findById(Element root, string id)
    {
        if (root.hasId(id)) return root;
        foreach (child; root.elements)
        {
            auto found = findById(child, id);
            if (found !is null) return found;
        }
        return null;
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

    private string documentTitle(Element root)
    {
        auto title = findTag(root, "title");
        if (title is null) return "";
        return title.textContent().strip();
    }
}

/// Parse a single CSS selector string into an auroraweb.css.Selector.
private Selector parseCssSelector(string text)
{
    import auroraweb.css : parseStylesheet;
    auto rules = parseStylesheet(text ~ " { color: black; }");
    if (rules.length == 0 || rules[0].selectors.length == 0)
        return Selector.init;
    return rules[0].selectors[0];
}

unittest
{
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    // Verify the new combinators/attribute selectors flow through the JS
    // query API: querySelector("div > p"), querySelectorAll("[href]"),
    // querySelectorAll(".a + .b").
    //
    // The engine's HTML parser autocloses block ancestors, so `<div><p>`
    // flattens to body siblings; the `div > p` tree is built through the JS
    // runtime (createElement + appendChild) which wires parent/child links,
    // then queried through the same querySelector API. Attribute selectors
    // are exercised against parsed HTML.
    auto root = parseHtml(`
        <html><body>
            <a href="https://example.com/">link</a>
            <span href="">span-href</span>
        </body></html>
    `);
    auto rt = parseScript(`
        var d = document.createElement("div");
        var p1 = document.createElement("p"); p1.setAttribute("class", "a"); p1.textContent = "one";
        var p2 = document.createElement("p"); p2.setAttribute("class", "b"); p2.textContent = "two";
        var p3 = document.createElement("p"); p3.setAttribute("class", "a"); p3.textContent = "three";
        d.appendChild(p1); d.appendChild(p2); d.appendChild(p3);
        var sec = document.createElement("section");
        sec.appendChild(document.createElement("p"));
        d.appendChild(sec);
        document.body.appendChild(d);

        var direct = document.querySelector("div > p");
        var directTag = direct ? direct.tagName : "none";
        var directParent = direct ? direct.parentNode.tagName : "none";
        var divDirectAll = document.querySelectorAll("div > p");
        var divDirectCount = divDirectAll.length;
        var secondSibling = document.querySelector(".a + .b");
        var secondTag = secondSibling ? secondSibling.tagName : "none";
        var secondClass = secondSibling ? secondSibling.className : "none";
        var classSiblingAll = document.querySelectorAll(".a + .b");
        var classSiblingCount = classSiblingAll.length;
        var hrefAll = document.querySelectorAll("[href]");
        var hrefCount = hrefAll.length;
        var hrefFirstTag = hrefAll[0] ? hrefAll[0].tagName : "none";
        __directTag = directTag;
        __directParent = directParent;
        __directCount = divDirectCount;
        __secondTag = secondTag;
        __secondClass = secondClass;
        __classSiblingCount = classSiblingCount;
        __hrefCount = hrefCount;
        __hrefFirstTag = hrefFirstTag;
    `);
    bindDocument(root, rt, rt.globalScope);
    rt.runScript(rt.makeObject());

    auto directTag = rt.globalScope.get("__directTag");
    assert(directTag.kind == JsKind.string && directTag.strValue == "P",
        "querySelector('div > p') should return the first direct p, got " ~ directTag.strValue);

    auto directParent = rt.globalScope.get("__directParent");
    assert(directParent.kind == JsKind.string && directParent.strValue == "DIV",
        "the div > p result's parent should be a DIV, got " ~ directParent.strValue);

    auto directCount = rt.globalScope.get("__directCount");
    assert(directCount.kind == JsKind.number && directCount.numValue == 3,
        "querySelectorAll('div > p') should find 3 direct p children, got " ~
        (directCount.kind == JsKind.number ? directCount.numValue.to!string : "?"));

    auto secondTag = rt.globalScope.get("__secondTag");
    assert(secondTag.kind == JsKind.string && secondTag.strValue == "P",
        "querySelector('.a + .b') should return a p element");

    auto secondClass = rt.globalScope.get("__secondClass");
    assert(secondClass.kind == JsKind.string && secondClass.strValue == "b",
        "querySelector('.a + .b') should return the element with class b, got " ~ secondClass.strValue);

    auto classSiblingCount = rt.globalScope.get("__classSiblingCount");
    assert(classSiblingCount.kind == JsKind.number && classSiblingCount.numValue == 1,
        "querySelectorAll('.a + .b') should find exactly 1 (the p.b after p.a), got " ~
        (classSiblingCount.kind == JsKind.number ? classSiblingCount.numValue.to!string : "?"));

    auto hrefCount = rt.globalScope.get("__hrefCount");
    assert(hrefCount.kind == JsKind.number && hrefCount.numValue == 2,
        "querySelectorAll('[href]') should find 2 elements, got " ~
        (hrefCount.kind == JsKind.number ? hrefCount.numValue.to!string : "?"));

    auto hrefFirstTag = rt.globalScope.get("__hrefFirstTag");
    assert(hrefFirstTag.kind == JsKind.string && hrefFirstTag.strValue == "A",
        "first [href] element should be an anchor, got " ~ hrefFirstTag.strValue);
}

unittest
{
    // The fetch global bound to a FAKE resource loader (no real network).
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    string fakeUrl;
    auto loader = (string url) @safe {
        fakeUrl = url;
        return cast(ubyte[]) `{"greeting":"hello aurora","n":42}`.dup;
    };

    auto root = parseHtml(`<html><body></body></html>`);
    auto rt = parseScript(`
        var seenText = null;
        var seenStatus = 0;
        var seenJson = null;
        fetch("https://fake.example/data.json").then(function(r) {
            seenStatus = r.status;
            seenText = r.text();
            seenJson = r.json();
        });
    `);
    bindDocument(root, rt, rt.globalScope, loader);
    rt.runScript(rt.makeObject());

    assert(fakeUrl == "https://fake.example/data.json",
        "loader should receive the fetch URL, got " ~ fakeUrl);

    auto seenStatus = rt.globalScope.get("seenStatus");
    assert(seenStatus.kind == JsKind.number && seenStatus.numValue == 200,
        "response status should be 200");

    auto seenText = rt.globalScope.get("seenText");
    assert(seenText.kind == JsKind.string, "seenText should be a string");
    assert(seenText.strValue == `{"greeting":"hello aurora","n":42}`,
        "text() should return the body: " ~ seenText.strValue);

    auto seenJson = rt.globalScope.get("seenJson");
    assert(seenJson.kind == JsKind.object, "json() should return an object");
    auto greeting = seenJson.obj.get("greeting");
    assert(greeting.kind == JsKind.string && greeting.strValue == "hello aurora",
        "json().greeting should parse");
}

unittest
{
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    auto root = parseHtml(`<html><body><div id="a" class="one two"><span>hi</span></div></body></html>`);
    auto rt = parseScript(`
        var el = document.getElementById("a");
        var docOk = el !== null;
        var winOk = (typeof window !== "undefined");
        var out = "";
        // innerHTML getter.
        out += el.innerHTML;
        // classList.
        el.classList.add("three");
        var hasThree = el.classList.contains("three");
        el.classList.remove("one");
        // style.
        el.style.color = "red";
        el.style.setProperty("font-size", "20px");
        var fs = el.style.getPropertyValue("font-size");
        // event bubbling: parent handler fires when child dispatches.
        var bubbled = false;
        var span = el.firstChild;
        el.addEventListener("click", function(e) { bubbled = true; });
        if (span) span.dispatchEvent("click");
        __out = out;
        __hasThree = hasThree;
        __fs = fs;
        __bubbled = bubbled;
        __styleAttr = el.getAttribute("style");
        __classAttr = el.getAttribute("class");
        __docOk = docOk;
        __winOk = winOk;
    `);
    bindDocument(root, rt, rt.globalScope);
    rt.runScript(rt.makeObject());

    auto innerOut = rt.globalScope.get("__out");
    assert(innerOut.kind == JsKind.string, "innerHTML should be a string");
    assert(innerOut.strValue.length > 0, "innerHTML should not be empty");

    auto hasThree = rt.globalScope.get("__hasThree");
    assert(hasThree.kind == JsKind.boolean && hasThree.boolValue == true,
        "classList.contains('three') should be true after add");

    auto fs = rt.globalScope.get("__fs");
    assert(fs.kind == JsKind.string && fs.strValue == "20px",
        "getPropertyValue('font-size') should be 20px, got " ~ fs.strValue);

    auto bubbled = rt.globalScope.get("__bubbled");
    assert(bubbled.kind == JsKind.boolean && bubbled.boolValue == true,
        "event should bubble to parent");

    auto styleAttr = rt.globalScope.get("__styleAttr");
    assert(styleAttr.kind == JsKind.string && styleAttr.strValue.length > 0,
        "style writes should update the style attribute");

    auto classAttr = rt.globalScope.get("__classAttr");
    assert(classAttr.kind == JsKind.string && classAttr.strValue == "two three",
        "classList ops should update class attribute, got " ~ classAttr.strValue);
}

unittest
{
    // Form controls: value/checked/type/name/placeholder getters & setters,
    // form.elements, form.submit() -> __lastSubmit, and document.write.
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    auto root = parseHtml(`
        <html><body>
            <form id="f" action="auroraweb:search">
                <input type="text" name="q" value="hello" placeholder="Search...">
                <input type="checkbox" name="agree" checked>
                <input type="submit" value="Go">
                <textarea name="notes">note text</textarea>
                <select name="kind">
                    <option value="a">A</option>
                    <option value="b" selected>B</option>
                </select>
                <button type="submit" name="btn">Send</button>
            </form>
        </body></html>
    `);
    auto rt = parseScript(`
        var form = document.getElementById("f");
        var input = form.elements[0];
        var checkbox = form.elements[1];
        var submit = form.elements[2];
        var textarea = form.elements[3];
        var select = form.elements[4];
        var button = form.elements[5];
        var inputValue = input.value;
        var inputType = input.type;
        var inputName = input.name;
        var inputPlaceholder = input.placeholder;
        var checkedBefore = checkbox.checked;
        checkbox.checked = false;
        var checkedAfter = checkbox.checked;
        checkbox.checked = true;
        var checkedRestored = checkbox.checked;
        var elementsCount = form.elements.length;
        input.value = "x";
        var updatedValue = input.value;
        var updatedAttr = input.getAttribute("value");
        textarea.value = "new notes";
        var textareaAttr = textarea.getAttribute("value");
        var buttonText = button.value;
        var buttonType = button.type;
        form.submit();
        var lastSubmit = __lastSubmit;
        var submitEventFired = false;
        form.addEventListener("submit", function(e) { submitEventFired = true; e.preventDefault(); });
        form.submit();
        var preventedLastSubmit = __lastSubmit;
        var selectValue = select.value;
        var selectName = select.name;
        var plainValue = document.body.value;
        document.write("<p id='written'>written</p>");
        var writtenEl = document.getElementById("written");
        var writtenTag = writtenEl ? writtenEl.tagName : "none";
        var writtenText = writtenEl ? writtenEl.textContent : "none";
        input.focus();
        var focusedAttr = input.getAttribute("focused");
        var cs = getComputedStyle(input);
        var csColor = cs.color;
        __inputValue = inputValue;
        __inputType = inputType;
        __inputName = inputName;
        __inputPlaceholder = inputPlaceholder;
        __checkedBefore = checkedBefore;
        __checkedAfter = checkedAfter;
        __checkedRestored = checkedRestored;
        __elementsCount = elementsCount;
        __updatedValue = updatedValue;
        __updatedAttr = updatedAttr;
        __textareaAttr = textareaAttr;
        __buttonText = buttonText;
        __buttonType = buttonType;
        __lastSubmit = lastSubmit;
        __submitEventFired = submitEventFired;
        __preventedLastSubmit = preventedLastSubmit;
        __selectValue = selectValue;
        __selectName = selectName;
        __plainValue = plainValue;
        __writtenTag = writtenTag;
        __writtenText = writtenText;
        __focusedAttr = focusedAttr;
        __csColor = csColor;
    `);
    bindDocument(root, rt, rt.globalScope);
    rt.runScript(rt.makeObject());

    auto checkStr = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.string && v.strValue == expected,
            name ~ " wrong: got '" ~ rt.toJsString(v) ~ "' want '" ~ expected ~ "'");
    };
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected,
            name ~ " wrong: got " ~ rt.toJsString(v));
    };
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected,
            name ~ " wrong: got " ~ rt.toJsString(v));
    };

    checkStr("__inputValue", "hello");
    checkStr("__inputType", "text");
    checkStr("__inputName", "q");
    checkStr("__inputPlaceholder", "Search...");
    checkBool("__checkedBefore", true);
    checkBool("__checkedAfter", false);
    checkBool("__checkedRestored", true);
    checkNum("__elementsCount", 6);
    checkStr("__updatedValue", "x");
    checkStr("__updatedAttr", "x");
    checkStr("__textareaAttr", "new notes");
    checkStr("__buttonText", "Send");
    checkStr("__buttonType", "submit");
    checkStr("__selectValue", "b");
    checkStr("__selectName", "kind");
    checkStr("__plainValue", "");
    checkBool("__submitEventFired", true);
    checkStr("__preventedLastSubmit", "auroraweb:search?q=x&agree=on&notes=new%20notes&kind=b&btn=Send");
    checkStr("__writtenTag", "P");
    checkStr("__writtenText", "written");
    checkStr("__focusedAttr", "true");
    checkStr("__csColor", "black");

    auto lastSubmit = rt.globalScope.get("__lastSubmit");
    assert(lastSubmit.kind == JsKind.string, "__lastSubmit should be a string");
    auto expected = "auroraweb:search?q=x&agree=on&notes=new%20notes&kind=b&btn=Send";
    assert(lastSubmit.strValue == expected,
        "form.submit() should produce the encoded query, got '" ~ lastSubmit.strValue ~ "' want '" ~ expected ~ "'");
}

unittest
{
    // Element traversal/query (closest/matches/contains/getElementsBy*),
    // dataset, mutation (insertAdjacentHTML/remove/after/before/append/
    // prepend/replaceWith), cloneNode, scrollIntoView no-op, stopPropagation,
    // and the global Event constructor + dispatchEvent.
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    auto root = parseHtml(`
        <html><body>
            <main id="main">
                <section id="sec" class="card" data-user-id="42" data-theme-mode="dark">
                    <p class="note">first</p>
                    <p class="note">second</p>
                    <span class="tail">tail</span>
                </section>
            </main>
        </body></html>
    `);
    auto rt = parseScript(`
        var main = document.getElementById("main");
        var sec = document.getElementById("sec");
        var note = main.getElementsByClassName(".note")[0];
        var allNotes = main.getElementsByClassName(".note");
        var span = main.getElementsByTagName("span")[0];
        var paras = sec.getElementsByTagName("p");
        var docParas = document.getElementsByTagName("p");
        var docCards = document.getElementsByClassName(".card");

        // closest / matches / contains.
        var closestCard = note.closest(".card");
        var closestSelf = note.closest("p.note");
        var closestNone = note.closest("table");
        var noteMatches = note.matches(".note");
        var noteNotMatches = note.matches("span");
        var mainContainsSpan = main.contains(span);
        var spanContainsMain = span.contains(main);

        // dataset read + write.
        var userId = sec.dataset.userId;
        var themeMode = sec.dataset.themeMode;
        sec.dataset.role = "dialog";
        var roleAttr = sec.getAttribute("data-role");

        // insertAdjacentHTML: beforebegin / afterend.
        var markerBefore = document.createElement("em");
        markerBefore.textContent = "BEFORE";
        sec.insertAdjacentHTML("beforebegin", "<em>ins-before</em>");
        var markerAfter = document.createElement("em");
        markerAfter.textContent = "AFTER";
        sec.insertAdjacentHTML("afterend", "<em>ins-after</em>");
        var prevSibling = sec.previousSibling;
        var nextSibling = sec.nextSibling;

        // insertAdjacentHTML inside the section.
        sec.insertAdjacentHTML("afterbegin", "<em>first-child</em>");
        sec.insertAdjacentHTML("beforeend", "<em>last-child</em>");
        var firstChildTag = sec.firstElementChild ? sec.firstElementChild.tagName : "none";
        var lastChildTag = sec.lastElementChild ? sec.lastElementChild.tagName : "none";
        var childrenAfterIns = sec.children.length;

        // remove().
        var doomed = document.createElement("div");
        doomed.id = "doomed";
        sec.appendChild(doomed);
        var beforeRemove = sec.children.length;
        doomed.remove();
        var afterRemove = sec.children.length;
        var doomedGone = document.getElementById("doomed") === null;

        // after() / before() with a text string and an element.
        span.after(" tail-text");
        var afterSpan = span.nextSibling;
        var fresh = document.createElement("b");
        fresh.textContent = "B";
        span.before(fresh);
        var beforeSpan = span.previousSibling;

        // append() / prepend().
        var outer = document.createElement("div");
        outer.id = "outer";
        var c1 = document.createElement("i");
        c1.textContent = "i1";
        var c2 = document.createElement("i");
        c2.textContent = "i2";
        document.body.appendChild(outer);
        outer.append(c1, c2, "appended-text");
        var outerCount = outer.children.length;
        var outerTextTail = outer.lastChild;
        var c3 = document.createElement("i");
        c3.textContent = "p0";
        outer.prepend(c3);
        var outerFirstTag = outer.firstElementChild ? outer.firstElementChild.tagName : "none";

        // cloneNode(deep): children copied, independent.
        var cloned = sec.cloneNode(true);
        var cloneTag = cloned.tagName;
        var cloneParas = cloned.getElementsByTagName("p").length;
        var cloneChildCount = cloned.children.length;
        var cloneNotSame = cloned !== sec;
        cloned.getElementsByTagName("p")[0].textContent = "changed";
        var originalFirst = sec.getElementsByTagName("p")[0].textContent;

        // cloneNode(false): no children.
        var shallow = sec.cloneNode(false);
        var shallowCount = shallow.children.length;

        // replaceWith().
        var victim = document.createElement("u");
        victim.textContent = "victim";
        sec.appendChild(victim);
        var replacement = document.createElement("strong");
        replacement.textContent = "replacement";
        victim.replaceWith(replacement);
        var replacementFound = sec.getElementsByTagName("strong").length;
        var victimGone = sec.getElementsByTagName("u").length;

        // scrollIntoView() must not throw and records the call.
        sec.scrollIntoView();
        var scrollCalled = sec.getAttribute("scrollIntoViewCalled");

        // stopPropagation halts bubbling: use a fresh subtree so handlers do
        // not overwrite each other (single handler slot per event name).
        var chainAMain = document.createElement("section");
        chainAMain.className = "chainAMain";
        sec.appendChild(chainAMain);
        var chainA = document.createElement("div");
        chainA.className = "chainA";
        chainAMain.appendChild(chainA);
        var leaf = document.createElement("span");
        leaf.className = "leaf";
        chainA.appendChild(leaf);
        var leafFired = false;
        var chainAFired = false;
        var chainAMainFired = false;
        leaf.addEventListener("click", function(e) { leafFired = true; });
        chainA.addEventListener("click", function(e) { chainAFired = true; });
        chainAMain.addEventListener("click", function(e) { chainAMainFired = true; });

        var stopTop = document.createElement("section");
        stopTop.className = "stopTop";
        sec.appendChild(stopTop);
        var stopChain = document.createElement("div");
        stopChain.className = "stopChain";
        stopTop.appendChild(stopChain);
        var stopLeaf = document.createElement("span");
        stopLeaf.className = "stopleaf";
        stopChain.appendChild(stopLeaf);
        var stopLeafFired = false;
        var stopChainFired = false;
        var stopTopFired = false;
        stopLeaf.addEventListener("click", function(e) {
            stopLeafFired = true;
            e.stopPropagation();
        });
        stopChain.addEventListener("click", function(e) { stopChainFired = true; });
        stopTop.addEventListener("click", function(e) { stopTopFired = true; });

        // dispatchEvent with a string name bubbles to all ancestors.
        leaf.dispatchEvent("click");
        var bubbledAll = leafFired && chainAFired && chainAMainFired;

        // dispatchEvent with a constructed Event; stopPropagation prevents the
        // bubble above the target's own handlers.
        stopLeaf.dispatchEvent(new Event("click"));
        var stopBubbled = stopLeafFired && !stopChainFired && !stopTopFired;
        var stopStoppedMain = !stopTopFired;

        // Global Event constructor + arbitrary props (key) reach the handler.
        var keyEvent = new Event("keydown");
        keyEvent.key = "Enter";
        var gotKey = "none";
        var keyTarget = document.createElement("input");
        sec.appendChild(keyTarget);
        keyTarget.addEventListener("keydown", function(e) {
            gotKey = e.key + "/" + e.type;
        });
        keyTarget.dispatchEvent(keyEvent);
        var keyHandled = gotKey;

        // event.target / preventDefault / defaultPrevented on constructed Event.
        var pd = false;
        var targetName = "none";
        var submitBtn = document.createElement("button");
        submitBtn.type = "submit";
        sec.appendChild(submitBtn);
        submitBtn.addEventListener("submit", function(e) {
            targetName = e.target === submitBtn ? "button" : "other";
            e.preventDefault();
            pd = e.defaultPrevented;
        });

        __closestCard = closestCard ? closestCard.tagName + "." + closestCard.className : "none";
        __closestSelf = closestSelf ? closestSelf.tagName : "none";
        __closestNone = closestNone === null;
        __noteMatches = noteMatches;
        __noteNotMatches = noteNotMatches;
        __mainContainsSpan = mainContainsSpan;
        __spanContainsMain = spanContainsMain;
        __allNotesCount = allNotes.length;
        __parasCount = paras.length;
        __docParasCount = docParas.length;
        __docCardsCount = docCards.length;
        __userId = userId;
        __themeMode = themeMode;
        __roleAttr = roleAttr;
        __prevSibling = prevSibling ? prevSibling.tagName : "none";
        __nextSibling = nextSibling ? nextSibling.tagName : "none";
        __firstChildTag = firstChildTag;
        __lastChildTag = lastChildTag;
        __childrenAfterIns = childrenAfterIns;
        __beforeRemove = beforeRemove;
        __afterRemove = afterRemove;
        __doomedGone = doomedGone;
        __afterSpanText = afterSpan ? afterSpan.data : "none";
        __beforeSpanTag = beforeSpan ? beforeSpan.tagName : "none";
        __outerCount = outerCount;
        __outerTextTail = outerTextTail ? outerTextTail.data : "none";
        __outerFirstTag = outerFirstTag;
        __cloneTag = cloneTag;
        __cloneParas = cloneParas;
        __cloneChildCount = cloneChildCount;
        __cloneNotSame = cloneNotSame;
        __originalFirst = originalFirst;
        __shallowCount = shallowCount;
        __replacementFound = replacementFound;
        __victimGone = victimGone;
        __scrollCalled = scrollCalled;
        __bubbledAll = bubbledAll;
        __stopBubbled = stopBubbled;
        __stopStoppedMain = stopStoppedMain;
        __keyHandled = keyHandled;
    `);
    bindDocument(root, rt, rt.globalScope);
    rt.runScript(rt.makeObject());

    auto checkStr = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.string && v.strValue == expected,
            name ~ " wrong: got '" ~ rt.toJsString(v) ~ "' want '" ~ expected ~ "'");
    };
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected,
            name ~ " wrong: got " ~ rt.toJsString(v));
    };
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected,
            name ~ " wrong: got " ~ rt.toJsString(v));
    };

    checkStr("__closestCard", "SECTION.card");
    checkStr("__closestSelf", "P");
    checkBool("__closestNone", true);
    checkBool("__noteMatches", true);
    checkBool("__noteNotMatches", false);
    checkBool("__mainContainsSpan", true);
    checkBool("__spanContainsMain", false);
    checkNum("__allNotesCount", 2);
    checkNum("__parasCount", 2);
    checkNum("__docParasCount", 2);
    checkNum("__docCardsCount", 1);
    checkStr("__userId", "42");
    checkStr("__themeMode", "dark");
    checkStr("__roleAttr", "dialog");
    checkStr("__prevSibling", "EM");
    checkStr("__nextSibling", "EM");
    checkStr("__firstChildTag", "EM");
    checkStr("__lastChildTag", "EM");
    checkNum("__childrenAfterIns", 5);
    checkNum("__beforeRemove", 6);
    checkNum("__afterRemove", 5);
    checkBool("__doomedGone", true);
    checkStr("__afterSpanText", " tail-text");
    checkStr("__beforeSpanTag", "B");
    checkNum("__outerCount", 2);
    checkStr("__outerTextTail", "appended-text");
    checkStr("__outerFirstTag", "I");
    checkStr("__cloneTag", "SECTION");
    checkNum("__cloneParas", 2);
    checkNum("__cloneChildCount", 6);
    checkBool("__cloneNotSame", true);
    checkStr("__originalFirst", "first");
    checkNum("__shallowCount", 0);
    checkNum("__replacementFound", 1);
    checkNum("__victimGone", 0);
    checkStr("__scrollCalled", "true");
    checkBool("__bubbledAll", true);
    checkBool("__stopBubbled", true);
    checkBool("__stopStoppedMain", true);
    checkStr("__keyHandled", "Enter/keydown");
}

unittest
{
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    // Regression: `el.textContent = "..."` must replace the element's children
    // (previously it only stored a shadow property on the JS wrapper, so the
    // DOM never changed and reads returned the old text). `innerText` is an
    // alias for the same read/write.
    auto root = parseHtml(`<html><body><p id="p">old</p></body></html>`);
    auto rt = parseScript(
        `var el = document.getElementById("p");` ~
        `el.textContent = "new";` ~
        `__read = el.textContent;` ~
        `__inner = el.innerText;`);
    bindDocument(root, rt, rt.globalScope);
    rt.runScript(rt.makeObject());
    auto read = rt.globalScope.get("__read");
    assert(read.kind == JsKind.string && read.strValue == "new",
        "textContent round-trip failed: " ~ rt.toJsString(read));
    auto inner = rt.globalScope.get("__inner");
    assert(inner.kind == JsKind.string && inner.strValue == "new",
        "innerText round-trip failed: " ~ rt.toJsString(inner));
    // The DOM node itself must hold the new text.
    string domText;
    void walk(Element e)
    {
        if (domText.length) return;
        if (e.tag == "p") { domText = e.textContent(); return; }
        foreach (c; e.elements) walk(c);
    }
    walk(root);
    assert(domText == "new", "DOM text node not updated, got '" ~ domText ~ "'");
}

unittest
{
    import auroraweb.html : parseHtml;
    import auroraweb.js : parseScript;

    // The browser surface a real page's own scripts reach for: `matchMedia`
    // answered from the layout viewport, the `document.cookie` jar, the Web
    // Storage areas, `location` and its parts, and the two directions of the
    // `window` bridge (a global read through `window`, and an assignment to a
    // `window` property becoming a global). The Django site's theme switcher
    // uses every one of these before it can show its icons.
    auto root = parseHtml(`<html><body><p id="p">hi</p></body></html>`);
    auto rt = parseScript(
        `__mq = window.matchMedia("(min-width: 100px) and (max-width: 1000px)").matches;` ~
        `__mqFar = matchMedia("(min-width: 5000px)").matches;` ~
        `__mqMedia = matchMedia("(min-width: 100px)").media;` ~
        `__inner = window.innerWidth + "x" + innerHeight;` ~
        `__setTimeout = typeof setTimeout;` ~
        `document.cookie = "theme=dark; path=/";` ~
        `document.cookie = "seen=1";` ~
        `__cookie = document.cookie;` ~
        `localStorage.setItem("theme", "dark");` ~
        `localStorage.other = "x";` ~
        `__store = localStorage.getItem("theme");` ~
        `__storeProp = localStorage.other;` ~
        `__storeLen = localStorage.length;` ~
        `__storeKey0 = localStorage.key(0);` ~
        `localStorage.removeItem("other");` ~
        `__storeLen2 = localStorage.length;` ~
        `__missing = String(localStorage.getItem("nope"));` ~
        `__href = location.href;` ~
        `__host = location.hostname;` ~
        `__path = location.pathname;` ~
        `document.title = "t";` ~
        `__docTitle = document.title;` ~
        `window.created = 42;` ~
        `__created = created;` ~
        `__selfIsWindow = (window === self);`);
    bindDocument(root, rt, rt.globalScope, null, "https://example.com/x?q=1", 640, 480);
    rt.runScript(rt.makeObject());

    string get(string name)
    {
        return rt.toJsString(rt.globalScope.get(name));
    }
    assert(get("__mq") == "true", "matchMedia in range: " ~ get("__mq"));
    assert(get("__mqFar") == "false", "matchMedia out of range: " ~ get("__mqFar"));
    assert(get("__mqMedia") == "(min-width: 100px)", "media string: " ~ get("__mqMedia"));
    assert(get("__inner") == "640x480", "innerWidth/innerHeight: " ~ get("__inner"));
    assert(get("__setTimeout") == "function", "global through window: " ~ get("__setTimeout"));
    assert(get("__cookie") == "theme=dark; seen=1", "cookie header: " ~ get("__cookie"));
    assert(get("__store") == "dark", "storage getItem: " ~ get("__store"));
    assert(get("__storeProp") == "x", "storage property read: " ~ get("__storeProp"));
    assert(get("__storeLen") == "2", "storage length: " ~ get("__storeLen"));
    assert(get("__storeKey0") == "theme", "storage key(0): " ~ get("__storeKey0"));
    assert(get("__storeLen2") == "1", "storage length after remove: " ~ get("__storeLen2"));
    assert(get("__missing") == "null", "missing item is null: " ~ get("__missing"));
    assert(get("__href") == "https://example.com/x?q=1", "location.href: " ~ get("__href"));
    assert(get("__host") == "example.com", "location.hostname: " ~ get("__host"));
    assert(get("__path") == "/x", "location.pathname: " ~ get("__path"));
    assert(get("__docTitle") == "t", "document.title: " ~ get("__docTitle"));
    assert(get("__created") == "42", "window property became a global: " ~ get("__created"));
    assert(get("__selfIsWindow") == "true", "window === self: " ~ get("__selfIsWindow"));

    // A resize is published to the page, so its `innerWidth` and `matchMedia`
    // answer the viewport it is laid out in rather than the one it was bound at.
    setViewportSize(rt, 800, 600);
    rt.runProgram(rt.parseInto(`__w = innerWidth + "x" + innerHeight;` ~
        `__wide = matchMedia("(min-width: 700px)").matches;`), rt.makeObject());
    assert(get("__w") == "800x600", "resized innerWidth: " ~ get("__w"));
    assert(get("__wide") == "true", "resized matchMedia: " ~ get("__wide"));
}

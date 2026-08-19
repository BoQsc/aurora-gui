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
import auroraweb.css : Selector, selectorMatches;
import auroraweb.js : JsFuncDelegate, JsKind, JsObject, JsRuntime, JsScope,
    JsScriptFunc, JsValue;

import std.array : split;
import std.conv : to;
import std.string : indexOf, strip, toLower, toUpper;

/// Bind a DOM tree into a JS runtime. Returns the `document` object value.
/// `resourceLoader` (if given) enables the `fetch` global for page scripts:
/// the loader is called with a URL string and must return the raw response
/// bytes (or null on failure).
JsValue bindDocument(Element root, JsRuntime rt, ref JsScope jsScope,
    ubyte[] delegate(string url) @safe resourceLoader = null)
{
    auto binder = new DocumentBinder(rt);
    return binder.bind(root, jsScope, resourceLoader);
}

/// Internal binder state: the wrapper cache and the runtime.
private final class DocumentBinder
{
    JsObject[Element] wrappers;
    JsRuntime rt;

    this(JsRuntime rt)
    {
        this.rt = rt;
    }

    JsValue bind(Element root, ref JsScope jsScope,
        ubyte[] delegate(string url) @safe resourceLoader)
    {
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

        // body
        auto bodyEl = findTag(root, "body");
        if (bodyEl is null) bodyEl = root;
        docObj.set("body", wrap(bodyEl));
        docObj.set("documentElement", wrap(root));

        auto docVal = JsValue(JsKind.object, docObj);
        jsScope.declare("document", docVal);

        // window: minimal global with addEventListener and onload.
        auto windowObj = new JsObject();
        windowObj.set("addEventListener", rt.makeNativeFunc((thisValue, args, rt2) {
            if (args.length < 2) return rt2.makeUndefined();
            auto name = rt2.toJsString(args[0]);
            rt2.globalScope.declare("__window_" ~ name, args[1]);
            return rt2.makeUndefined();
        }));
        windowObj.set("document", docVal);
        jsScope.declare("window", JsValue(JsKind.object, windowObj));

        // fetch: route page fetches through the page's resource loader and
        // expose a minimal Fetch-like response with a synchronous .then() shim.
        if (resourceLoader !is null)
        {
            rt.fetchHandler = (JsValue url, JsValue options, ref JsRuntime rt2) {
                return fetchResponse(rt2, url, resourceLoader);
            };
            rt.installFetchBuiltin();
        }

        return docVal;
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
            auto evtName = args.length ? rt2.toJsString(args[0]) : "";
            // Build an event object.
            auto evt = rt2.makeObject();
            evt.obj.set("type", rt2.makeString(evtName));
            evt.obj.set("target", thisValue);
            evt.obj.set("currentTarget", thisValue);
            // Fire the leaf handler first, then bubble up ancestors.
            auto cur = thisValue;
            auto curEl = unwrap(cur);
            while (cur.kind == JsKind.object)
            {
                auto handler = cur.obj.get("__event_" ~ evtName);
                if (handler.kind == JsKind.func)
                {
                    JsValue[] callArgs; callArgs ~= evt;
                    rt2.callFunction(handler, cur, callArgs);
                }
                // Move to parent.
                if (curEl is null || curEl.parent is null) break;
                curEl = curEl.parent;
                cur = wrap(curEl);
            }
            return rt2.makeBoolean(true);
        }));

        // innerHTML: getter serializes children; setter parses and replaces.
        obj.set("__innerHTML", makeInnerHtmlHandler(el));
        obj.set("__classList", makeClassList(el));
        obj.set("__styleObj", makeStyleObject(el));

        obj.set("__get_parentNode", rt.makeNativeFunc((thisValue, args, rt2) {
            auto el2 = unwrap(thisValue);
            if (el2 is null || el2.parent is null) return rt2.makeNull();
            return wrap(el2.parent);
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

        wrappers[el] = obj;
        return JsValue(JsKind.object, obj);
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

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
    JsObject[Element] datasets;
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
            return rt2.makeUndefined();
        }));
        windowObj.set("document", docVal);
        jsScope.declare("window", JsValue(JsKind.object, windowObj));

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

    /// Build a minimal Event object with preventDefault support.
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
    private void fireEventChain(JsValue targetValue, JsRuntime rt2, string evtName, JsValue evt)
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

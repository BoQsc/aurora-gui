module auroraweb.js;

/**
 * A self-contained JavaScript engine written in D.
 *
 * This is a tree-walking interpreter that implements a pragmatic ECMAScript
 * subset:
 *
 * - Lexing: identifiers, keywords, numbers (int/float), strings (single and
 *   double quotes, escapes), operators, punctuation.
 * - Values: `JsValue` is a tagged union of `undefined`, `null`, `boolean`,
 *   `number` (double), `string`, `object` (map), `array`, `function`
 *   (native or script), with `typeof` semantics.
 * - Objects and arrays with property get/set through a prototype chain.
 * - Functions: script functions create closures capturing the defining sc;
 *   native functions are D delegates called with the `this` value and args.
 * - Control flow: `var`, `let`, `const`, `if/else`, `while`, `for`,
 *   `for-in`, `function` declarations, return, throw/try/catch.
 * - Operators: arithmetic, comparison, equality, logical, assignment,
 *   unary, typeof, ternary, member access, call, new (minimal).
 *
 * It is deliberately not a JIT, not fully spec-conformant, and not intended to
 * run complex frameworks. It is the owned, auditable engine for the Aurora web
 * platform, to be extended incrementally.
 */

import std.algorithm : findSplit, max;
import std.array : appender;
import std.conv : to;
import std.math : isNaN;
import std.string : strip, toLower, toUpper, indexOf, startsWith, endsWith;

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/** Kind tag for a JS value. */
enum JsKind
{
    undefined,
    nullValue,
    boolean,
    number,
    string,
    object,
    array,
    func
}

/// Forward declaration.
alias JsFuncDelegate = JsValue delegate(JsValue thisValue, JsValue[] args, ref JsRuntime rt);

/**
 * A JavaScript value. Objects and functions are heap references (`JsObject`
 * with `kind`). Script functions carry their body AST node id and closure.
 */
struct JsValue
{
    JsKind kind = JsKind.undefined;
    bool boolValue;
    double numValue;
    string strValue;
    JsObject obj;             /// Object/array.
    JsFuncDelegate nativeFunc;  /// Native function.
    JsScriptFunc scriptFunc;    /// Script function.

    this(JsKind k) { kind = k; }
    this(JsKind k, bool b) { kind = k; boolValue = b; }
    this(JsKind k, double n) { kind = k; numValue = n; }
    this(JsKind k, string s) { kind = k; strValue = s; }
    this(JsKind k, JsObject o) { kind = k; obj = o; }
    this(JsKind k, JsObject o, JsFuncDelegate f, JsScriptFunc s)
    {
        kind = k; obj = o; nativeFunc = f; scriptFunc = s;
    }

    bool isTruthy() const
    {
        final switch (kind)
        {
            case JsKind.undefined, JsKind.nullValue: return false;
            case JsKind.boolean: return boolValue;
            case JsKind.number: return numValue != 0.0 && !isNaN(numValue);
            case JsKind.string: return strValue.length > 0;
            case JsKind.object, JsKind.array, JsKind.func: return true;
        }
    }
}

/// Reference to a JS object/array heap node.
final class JsObject
{
    string kind = "Object";       /// "Object", "Array", "Function".
    JsValue[string] props;        /// Own properties.
    JsObject proto;               /// Prototype chain.
    JsValue[string] arrayItems;   /// For arrays: numeric-index storage (string keys "0","1",...).
    size_t arrayLength;

    bool has(string key) const { return (key in props) !is null; }

    void set(string key, JsValue value)
    {
        props[key] = value;
    }

    JsValue get(string key)
    {
        auto it = key in props;
        if (it !is null) return *it;
        if (proto !is null) return proto.get(key);
        return JsValue.init;
    }
}

/// A script-defined function value.
struct JsScriptFunc
{
    string[] params;
    Node bodyNode;     /// Body statement node.
    JsScope closure;             /// Captured defining scope.
    bool isAsync;      /// async function — result wrapped in a Promise.
    bool isArrow;      /// arrow function — lexical this/closure.
}

/// A sc chain (for var/let/function resolution).
final class JsScope
{
    JsValue[string] vars;
    JsScope parent;
    string name;

    this(string name, JsScope parent)
    {
        this.name = name;
        this.parent = parent;
    }

    void declare(string key, JsValue value)
    {
        vars[key] = value;
    }

    bool set(string key, JsValue value)
    {
        auto cur = this;
        while (cur !is null)
        {
            if ((key in cur.vars) !is null)
            {
                cur.vars[key] = value;
                return true;
            }
            cur = cur.parent;
        }
        return false;
    }

    JsValue get(string key)
    {
        auto cur = this;
        while (cur !is null)
        {
            auto it = key in cur.vars;
            if (it !is null) return *it;
            cur = cur.parent;
        }
        return JsValue.init;
    }

    bool has(string key)
    {
        auto cur = this;
        while (cur !is null)
        {
            if ((key in cur.vars) !is null) return true;
            cur = cur.parent;
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// AST node kinds and nodes
// ---------------------------------------------------------------------------

/// AST node kinds.
enum NodeKind
{
    program,        // statements[]
    block,          // statements[]
    exprStmt,       // value
    varDecl,        // names[], init (may be empty)
    ifStmt,         // test, thenNode, elseNode
    whileStmt,      // test, body
    forStmt,        // initNode, test, update, body
    forInStmt,      // target name, objectNode, body
    forOfStmt,      // target name, iterableNode, body (for ... of)
    functionDecl,   // name, params[], bodyNode
    arrow,          // params[], bodyNode; boolValue = expression-body (no braces)
    returnStmt,     // value
    throwStmt,      // value
    tryStmt,        // body, catchName, catchBody
    templateLit,    // parts: children contain stringLit nodes and expr nodes
    awaitExpr,      // value
    // Expressions
    numberLit,      // numValue
    stringLit,      // strValue
    boolLit,        // boolValue
    nullLit,
    identifier,     // name
    thisExpr,
    arrayLit,       // elements[]
    objectLit,      // keys[], values[]
    unary,          // op, operand
    binary,         // op, left, right
    logical,        // op ("&&","||"), left, right
    ternary,        // test, thenNode, elseNode
    assign,         // target (identifier/member), value; op for compound
    update,         // op ("++"/"--"), target; boolValue = prefix
    member,         // object, property (identifier name or expr)
    call,           // callee, args[]
    newExpr,        // callee, args[]
}

/// AST node. Stored as a class so the parser can mutate it by reference.
final class Node
{
    NodeKind kind;
    string name;              /// identifier name / operator.
    string[] names;           /// var/param names.
    JsValue[] values;         /// literals / elements.
    Node[] children;          /// child nodes.
    bool boolValue;
    double numValue;
    string strValue;
    string[] params;
    string op;
    ulong order;              /// Execution order assigned at parse time (for await resume).

    this(NodeKind kind) { this.kind = kind; }
}

// ---------------------------------------------------------------------------
// Runtime and object constructors
// ---------------------------------------------------------------------------

/// The interpreter runtime. Holds global sc, AST, and object heap.
final class JsRuntime
{
    JsScope globalScope;
    JsObject globalObject;      /// Global object (for `globalThis`).
    Node[] nodes;      /// All AST nodes created during parsing.
    bool lastHadException;
    JsValue pendingException;
    bool returned;          /// Set when a return statement fired.
    JsValue returnValue;    /// The value carried by that return.
    int debugStep;
    /// Optional handler installed by the DOM binder for the `fetch` global.
    /// Null (default) means no `fetch` is exposed to page scripts.
    JsValue delegate(JsValue url, JsValue options, ref JsRuntime rt) fetchHandler;

    /// Microtask queue for Promise continuations.
    JsValue[] _microtasks;
    /// Await-resume frames for async functions.
    struct AwaitFrame
    {
        Node awaitNode;      /// The awaitExpr node to resume at.
        JsScope sc;          /// The scope at suspension.
        JsValue thisValue;
        bool resolved;       /// Whether the awaited value is ready.
        JsValue resolvedValue;
        JsValue bodyFn;      /// The async function JsValue (for re-entry).
    }
    AwaitFrame[] _awaitFrames;
    bool _awaitPending;      /// Set while an async body is suspended on await.
    /// Active resume frame while re-running an async body after await resolves.
    AwaitFrame* _activeResume;
    /// The async function currently executing (set by callFunction).
    JsValue _currentAsyncBody;
    /// Timer list for setTimeout/setInterval. Each entry: (ms due, fn, id, repeat).
    struct Timer
    {
        double dueAt;
        JsValue fn;
        long id;
        bool repeat;
    }
    Timer[] _timers;
    long _nextTimerId = 1;
    double _nowMs;         /// Monotonic milliseconds; advanced by pumpTimers.

    void queueMicrotask(JsValue continuation)
    {
        _microtasks ~= continuation;
    }

    /// Run all pending microtasks synchronously.
    void pumpMicrotasks()
    {
        while (_microtasks.length)
        {
            auto tasks = _microtasks;
            _microtasks = null;
            foreach (t; tasks)
            {
                if (t.kind == JsKind.func)
                {
                    JsValue[] args;
                    callFunction(t, JsValue(JsKind.object, globalObject), args);
                }
            }
        }
    }

    /// Advance the internal clock and run due timers. Returns ms to next timer.
    double pumpTimers()
    {
        // Advance time to the next due timer (or by a fixed step).
        double nextDue = double.max;
        foreach (t; _timers)
            if (t.dueAt < nextDue) nextDue = t.dueAt;
        if (_timers.length == 0) return double.max;
        _nowMs = max(_nowMs, nextDue);
        // Run all timers that are now due.
        Timer[] still;
        foreach (t; _timers)
        {
            if (t.dueAt <= _nowMs)
            {
                JsValue[] args;
                callFunction(t.fn, JsValue(JsKind.object, globalObject), args);
                if (t.repeat)
                {
                    auto nt = t;
                    nt.dueAt = _nowMs + 100; // repeat interval placeholder
                    still ~= nt;
                }
            }
            else still ~= t;
        }
        _timers = still;
        double minNext = double.max;
        foreach (t; _timers)
            if (t.dueAt < minNext) minNext = t.dueAt;
        return minNext;
    }

    long installTimer(JsValue fn, double delayMs, bool repeat)
    {
        auto id = _nextTimerId++;
        Timer t;
        t.dueAt = _nowMs + delayMs;
        t.fn = fn;
        t.id = id;
        t.repeat = repeat;
        _timers ~= t;
        return id;
    }

    this()
    {
        globalScope = new JsScope("global", null);
        globalObject = new JsObject();
        globalObject.kind = "Object";
        installBuiltins();
    }

    /// Convert a JS value to its string representation.
    string toJsString(JsValue value)
    {
    if (value.kind == JsKind.undefined) return "undefined";
    final switch (value.kind)
    {
        case JsKind.undefined: return "undefined";
        case JsKind.nullValue: return "null";
        case JsKind.boolean: return value.boolValue ? "true" : "false";
        case JsKind.number:
            if (isNaN(value.numValue)) return "NaN";
            if (value.numValue == double.infinity) return "Infinity";
            if (value.numValue == -double.infinity) return "-Infinity";
            // Negative zero renders as "0" (matches JS String(-0) === "0").
            if (value.numValue == 0.0) return "0";
            if (value.numValue == cast(long) value.numValue)
                return to!string(cast(long) value.numValue);
            {
                // Reasonable float precision: 0.1 -> "0.1", avoid trailing
                // exponent noise from D's default formatting.
                auto f = to!string(value.numValue);
                if (indexOf(f, "e") == -1 && indexOf(f, "E") == -1 &&
                    (indexOf(f, ".") == -1 || f.length > 24))
                    return f;
                return formatFloat(value.numValue);
            }
        case JsKind.string: return value.strValue;
        case JsKind.object: return "[object Object]";
        case JsKind.array: return arrayToString(value);
        case JsKind.func: return "function() { [aurora code] }";
    }
    }

    /// Render a float without exponent notation (0.1 -> "0.1"), matching JS.
    private string formatFloat(double v)
    {
        // Snapshot the sign bit to preserve -0.0 (handled by caller) and to
        // keep the digit loop below sign-agnostic.
        import std.math : floor;
        bool neg = v < 0.0;
        if (neg) v = -v;
        if (v >= 1e20) return to!string(neg ? -v : v);  // enormous -> exponent form
        // Extract integer and fractional parts.
        long intPart = cast(long) floor(v);
        double frac = v - floor(v);
        string result = to!string(intPart);
        if (frac != 0.0)
        {
            // Walk up to 16 fractional digits, trimming trailing zeros.
            double scale = frac;
            string digits;
            int maxDigits = 16;
            int count = 0;
            while (scale > 0.0 && count < maxDigits)
            {
                scale *= 10.0;
                auto d = cast(long) floor(scale);
                digits ~= cast(char)('0' + d);
                scale -= cast(double) d;
                count++;
            }
            // Trim trailing zeroes.
            while (digits.length && digits[$ - 1] == '0') digits.length--;
            if (digits.length) result ~= "." ~ digits;
        }
        return neg ? "-" ~ result : result;
    }

    private string arrayToString(JsValue value)
    {
        auto obj = value.obj;
        string result;
        for (size_t i = 0; i < obj.arrayLength; i++)
        {
            if (i) result ~= ",";
            auto item = obj.get(to!string(i));
            if (item.kind == JsKind.undefined || item.kind == JsKind.nullValue)
                continue;
            result ~= toJsString(item);
        }
        return result;
    }

    /// JSON.stringify implementation (objects, arrays, strings, numbers, booleans, null).
    string jsStringify(JsValue value)
    {
        final switch (value.kind)
        {
            case JsKind.undefined: return "null";
            case JsKind.nullValue: return "null";
            case JsKind.boolean: return value.boolValue ? "true" : "false";
            case JsKind.number:
                if (isNaN(value.numValue) || value.numValue == double.infinity ||
                    value.numValue == -double.infinity) return "null";
                if (value.numValue == cast(int) value.numValue)
                    return to!string(cast(int) value.numValue);
                return to!string(value.numValue);
            case JsKind.string:
                return jsonEscape(value.strValue);
            case JsKind.func: return "null";
            case JsKind.array:
            {
                string result = "[";
                for (size_t i = 0; i < value.obj.arrayLength; i++)
                {
                    if (i) result ~= ",";
                    result ~= jsStringify(value.obj.get(to!string(i)));
                }
                return result ~ "]";
            }
            case JsKind.object:
            {
                string result = "{";
                size_t idx = 0;
                foreach (key, val; value.obj.props)
                {
                    if (val.kind == JsKind.func || val.kind == JsKind.undefined) continue;
                    if (idx) result ~= ",";
                    result ~= jsonEscape(key) ~ ":" ~ jsStringify(val);
                    idx++;
                }
                return result ~ "}";
            }
        }
    }

    private string jsonEscape(string s)
    {
        string result;
        foreach (ch; s)
        {
            switch (ch)
            {
                case '"': result ~= "\\\""; break;
                case '\\': result ~= "\\\\"; break;
                case '\n': result ~= "\\n"; break;
                case '\t': result ~= "\\t"; break;
                case '\r': result ~= "\\r"; break;
                default: result ~= ch; break;
            }
        }
        return "\"" ~ result ~ "\"";
    }

    /// JSON.parse implementation.
    JsValue jsParseValue(string s, ref size_t p)
    {
        import std.string : lastIndexOf;
        skipWs(s, p);
        if (p >= s.length) return makeUndefined();
        char c = s[p];
        if (c == '{')
        {
            p++;
            auto obj = makeObject();
            skipWs(s, p);
            if (p < s.length && s[p] == '}') { p++; return obj; }
            while (p < s.length)
            {
                skipWs(s, p);
                if (s[p] != '"') return obj;
                p++;
                auto key = jsonParseString(s, p);
                skipWs(s, p);
                if (p < s.length && s[p] == ':') p++;
                auto val = jsParseValue(s, p);
                obj.obj.set(key, val);
                skipWs(s, p);
                if (p < s.length && s[p] == ',') { p++; continue; }
                if (p < s.length && s[p] == '}') { p++; break; }
                break;
            }
            return obj;
        }
        if (c == '[')
        {
            p++;
            auto arr = makeArray();
            skipWs(s, p);
            if (p < s.length && s[p] == ']') { p++; return arr; }
            size_t idx = 0;
            while (p < s.length)
            {
                auto val = jsParseValue(s, p);
                arr.obj.set(to!string(idx), val);
                idx++;
                skipWs(s, p);
                if (p < s.length && s[p] == ',') { p++; continue; }
                if (p < s.length && s[p] == ']') { p++; break; }
                break;
            }
            arr.obj.arrayLength = idx;
            return arr;
        }
        if (c == '"')
        {
            p++;
            return makeString(jsonParseString(s, p));
        }
        // Number
        if ((c >= '0' && c <= '9') || c == '-')
        {
            auto start = p;
            while (p < s.length && ((s[p] >= '0' && s[p] <= '9') || s[p] == '.' || s[p] == '-' || s[p] == '+' || s[p] == 'e' || s[p] == 'E'))
                p++;
            auto numStr = s[start .. p];
            return makeNumber(to!double(numStr));
        }
        // true / false / null
        if (p + 4 <= s.length && s[p .. p + 4] == "true") { p += 4; return makeBoolean(true); }
        if (p + 5 <= s.length && s[p .. p + 5] == "false") { p += 5; return makeBoolean(false); }
        if (p + 4 <= s.length && s[p .. p + 4] == "null") { p += 4; return makeNull(); }
        return makeUndefined();
    }

    private void skipWs(string s, ref size_t p)
    {
        while (p < s.length && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r'))
            p++;
    }

    private string jsonParseString(string s, ref size_t p)
    {
        string result;
        while (p < s.length)
        {
            char c = s[p];
            if (c == '"') { p++; break; }
            if (c == '\\' && p + 1 < s.length)
            {
                p++;
                auto esc = s[p];
                switch (esc)
                {
                    case 'n': result ~= '\n'; break;
                    case 't': result ~= '\t'; break;
                    case 'r': result ~= '\r'; break;
                    case '\\': result ~= '\\'; break;
                    case '"': result ~= '"'; break;
                    case '/': result ~= '/'; break;
                    case 'b': result ~= '\b'; break;
                    case 'f': result ~= '\f'; break;
                    default: result ~= esc; break;
                }
                p++;
            }
            else { result ~= c; p++; }
        }
        return result;
    }

    /// Create a number, string, boolean, null, undefined, array, object.
    JsValue makeNumber(double n) { return JsValue(JsKind.number, n); }
    JsValue makeString(string s) { return JsValue(JsKind.string, s); }
    JsValue makeBoolean(bool b) { return JsValue(JsKind.boolean, b); }
    JsValue makeUndefined() { return JsValue(JsKind.undefined); }
    JsValue makeNull() { return JsValue(JsKind.nullValue); }
    JsValue makeObject()
    {
        auto obj = new JsObject();
        obj.kind = "Object";
        obj.proto = objectProto;
        return JsValue(JsKind.object, obj);
    }
    JsValue makeArray()
    {
        auto obj = new JsObject();
        obj.kind = "Array";
        obj.arrayLength = 0;
        obj.proto = arrayProto;
        return JsValue(JsKind.array, obj);
    }
    JsValue makeNativeFunc(JsFuncDelegate func)
    {
        auto obj = new JsObject();
        obj.kind = "Function";
        obj.proto = functionProto;
        auto protoObj = new JsObject();
        protoObj.kind = "Object";
        protoObj.proto = objectProto;
        obj.set("prototype", JsValue(JsKind.object, protoObj));
        return JsValue(JsKind.func, obj, func, JsScriptFunc.init);
    }
    JsValue makeScriptFunc(string[] params, Node bodyNode, JsScope closure)
    {
        auto obj = new JsObject();
        obj.kind = "Function";
        obj.proto = functionProto;
        JsScriptFunc sf;
        sf.params = params;
        sf.bodyNode = bodyNode;
        sf.closure = closure;
        // Every function has a .prototype property (used by `new`).
        auto protoObj = new JsObject();
        protoObj.kind = "Object";
        protoObj.proto = objectProto;
        obj.set("prototype", JsValue(JsKind.object, protoObj));
        return JsValue(JsKind.func, obj, null, sf);
    }

    /// Create an Error-kind object value.
    JsValue makeErrorValue(string name, string message)
    {
        auto obj = new JsObject();
        obj.kind = "Object";
        obj.proto = errorProto;
        obj.set("name", makeString(name));
        obj.set("message", makeString(message));
        return JsValue(JsKind.object, obj);
    }

    /// Get a property with ToString coercion on the key.
    JsValue getProp(JsValue obj, JsValue key)
    {
        if (obj.kind == JsKind.object || obj.kind == JsKind.array || obj.kind == JsKind.func)
        {
            if (obj.kind == JsKind.array)
            {
                const k = toJsString(key);
                if (k == "length") return makeNumber(cast(double) obj.obj.arrayLength);
            }
            const k = toJsString(key);
            // Custom getter routing (e.g. element.style, .innerHTML, .textContent).
            auto getter = obj.obj.get("__get_" ~ k);
            if (getter.kind == JsKind.func)
            {
                JsValue[] a;
                return callFunction(getter, obj, a);
            }
            return obj.obj.get(k);
        }
        // Primitives: box string/number methods minimally.
        if (obj.kind == JsKind.string)
        {
            const s = toJsString(key);
            if (s == "length") return makeNumber(cast(double) obj.strValue.length);
            // Bind string methods: return a native func capturing the receiver string.
            auto proto = stringProto.get(s);
            if (proto.kind != JsKind.undefined)
            {
                if (proto.kind == JsKind.func && proto.nativeFunc !is null)
                {
                    const receiver = obj.strValue;
                    auto bound = makeNativeFunc((thisValue, args, rt) {
                        return proto.nativeFunc(rt.makeString(receiver), args, rt);
                    });
                    return bound;
                }
                return proto;
            }
        }
        return makeUndefined();
    }

    void setProp(JsValue obj, JsValue key, JsValue value)
    {
        if (obj.kind == JsKind.object || obj.kind == JsKind.array || obj.kind == JsKind.func)
        {
            const k = toJsString(key);
            // If the object has a custom set handler (e.g. style objects that
            // write back to the DOM element's style attribute), use it.
            auto handler = obj.obj.get("__setHandler");
            if (handler.kind == JsKind.func)
            {
                JsValue[] a; a ~= key; a ~= value;
                callFunction(handler, obj, a);
                return;
            }
            if (obj.kind == JsKind.array)
            {
                // Numeric index writes extend the array.
                if (isNonNegIntString(k) && k.length < 16)
                {
                    auto n = to!size_t(k);
                    if (n >= obj.obj.arrayLength) obj.obj.arrayLength = n + 1;
                }
            }
            obj.obj.set(k, value);
        }
    }

    private bool isNonNegIntString(string s)
    {
        if (s.length == 0) return false;
        foreach (ch; s) if (ch < '0' || ch > '9') return false;
        return true;
    }

    /// Execute the parsed program (node 0 is the Program node).
    JsValue runScript(JsValue globalThisArg)
    {
        hoistVars(nodes[0], globalScope);
        return execNode(nodes[0], globalScope, globalThisArg);
    }

    /// Parse source into THIS runtime's node table (so functions/closures see
    /// the same globals), returning the Program node to execute.
    Node parseInto(string source)
    {
        auto parser = Parser(source, this);
        parser.parseProgram();
        return nodes[$ - 1];
    }

    /// Execute a previously parsed program node in the global scope.
    JsValue runProgram(Node program, JsValue globalThisArg)
    {
        if (program is null) return makeUndefined();
        hoistVars(program, globalScope);
        return execNode(program, globalScope, globalThisArg);
    }

    /// Hoist all `var` declarations in a statement tree to the given scope
    /// (function/global scope), declared as undefined before any statement runs.
    /// Function bodies are NOT descended into: their vars hoist to their own scope.
    private void hoistVars(Node node, JsScope sc)
    {
        if (node is null) return;
        switch (node.kind)
        {
            case NodeKind.program, NodeKind.block:
                foreach (child; node.children) hoistVars(child, sc);
                break;
            case NodeKind.varDecl:
                // Declare only if not already declared (params/arguments take precedence).
                foreach (name; node.names)
                    if (!sc.has(name)) sc.declare(name, makeUndefined());
                break;
            case NodeKind.ifStmt:
                if (node.children.length > 1) hoistVars(node.children[1], sc);
                if (node.children.length > 2) hoistVars(node.children[2], sc);
                break;
            case NodeKind.whileStmt:
                if (node.children.length > 1) hoistVars(node.children[1], sc);
                break;
            case NodeKind.forStmt:
                if (node.children.length >= 1) hoistVars(node.children[0], sc);
                if (node.children.length >= 4) hoistVars(node.children[3], sc);
                break;
            case NodeKind.forInStmt, NodeKind.forOfStmt:
                if (node.children.length >= 1) hoistVars(node.children[0], sc);
                break;
            case NodeKind.exprStmt:
                break;
            case NodeKind.functionDecl:
                break;  // nested functions hoist into their own scope
            case NodeKind.returnStmt, NodeKind.throwStmt, NodeKind.tryStmt:
                break;
            default:
                break;
        }
    }

    // --- builtins ---
    JsObject arrayProto;
    JsObject functionProto;
    JsObject objectProto;
    JsObject stringProto;
    JsObject errorProto;
    JsObject promiseProto;
    JsObject setProto;
    JsObject mapProto;

    void installBuiltins()
    {
        objectProto = new JsObject();
        objectProto.kind = "Object";

        arrayProto = new JsObject();
        arrayProto.kind = "Array";
        arrayProto.proto = objectProto;

        functionProto = new JsObject();
        functionProto.kind = "Function";
        functionProto.proto = objectProto;

        stringProto = new JsObject();
        stringProto.kind = "String";
        stringProto.proto = objectProto;

        // console
        auto consoleObj = new JsObject();
        consoleObj.set("log", makeNativeFunc((thisValue, args, rt) {
            string output;
            foreach (i, arg; args)
            {
                if (i) output ~= " ";
                output ~= rt.toJsString(arg);
            }
            import std.stdio : writeln;
            writeln(output);
            return rt.makeUndefined();
        }));
        consoleObj.set("error", consoleObj.get("log"));
        consoleObj.set("warn", consoleObj.get("log"));
        auto consoleVal = JsValue(JsKind.object, consoleObj);
        globalScope.declare("console", consoleVal);

        // Math
        auto mathObj = new JsObject();
        mathObj.set("PI", makeNumber(3.141592653589793));
        mathObj.set("floor", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(0);
            return rt.makeNumber(cast(double) cast(long) args[0].numValue);
        }));
        mathObj.set("round", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(0);
            auto n = args[0].numValue;
            return rt.makeNumber(cast(double) (n >= 0 ? cast(long)(n + 0.5) : cast(long)(n - 0.5)));
        }));
        mathObj.set("abs", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(0);
            return rt.makeNumber(args[0].numValue < 0 ? -args[0].numValue : args[0].numValue);
        }));
        mathObj.set("max", makeNativeFunc((thisValue, args, rt) {
            double m = -double.max;
            foreach (arg; args) if (arg.numValue > m) m = arg.numValue;
            return rt.makeNumber(args.length ? m : -double.infinity);
        }));
        mathObj.set("min", makeNativeFunc((thisValue, args, rt) {
            double m = double.max;
            foreach (arg; args) if (arg.numValue < m) m = arg.numValue;
            return rt.makeNumber(args.length ? m : double.infinity);
        }));
        auto mathVal = JsValue(JsKind.object, mathObj);
        globalScope.declare("Math", mathVal);

        // parseInt
        globalScope.declare("parseInt", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(double.nan);
            auto s = rt.toJsString(args[0]);
            long radix = args.length > 1 ? cast(long)args[1].numValue : 10;
            if (radix == 0) radix = 10;
            if (radix < 2 || radix > 36) return rt.makeNumber(double.nan);
            long result = 0;
            bool started = false;
            size_t i = 0;
            // Skip leading whitespace.
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
            bool neg = false;
            if (i < s.length && s[i] == '-') { neg = true; i++; }
            else if (i < s.length && s[i] == '+') i++;
            // Hex/octal prefixes.
            if (radix == 16 && i + 1 < s.length && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X'))
                i += 2;
            long digitValue(char c)
            {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'z') return c - 'a' + 10;
                if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
                return -1;
            }
            while (i < s.length)
            {
                auto d = digitValue(s[i]);
                if (d < 0 || d >= radix) break;
                result = result * radix + d;
                started = true;
                i++;
            }
            if (!started) return rt.makeNumber(double.nan);
            return rt.makeNumber(cast(double)(neg ? -result : result));
        }));

        globalScope.declare("parseFloat", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(double.nan);
            auto s = rt.toJsString(args[0]);
            double result = 0;
            bool started = false;
            bool dot = false;
            double scale = 0.1;
            foreach (ch; s)
            {
                if (ch >= '0' && ch <= '9')
                {
                    if (dot) { result += (ch - '0') * scale; scale *= 0.1; }
                    else result = result * 10 + (ch - '0');
                    started = true;
                }
                else if (ch == '.' && !dot) dot = true;
                else if (started) break;
                else if (ch == ' ') continue;
                else break;
            }
            return rt.makeNumber(started ? result : double.nan);
        }));

        globalScope.declare("isNaN", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeBoolean(true);
            return rt.makeBoolean(isNaN(rt.toNumber(args[0])));
        }));
        globalScope.declare("isFinite", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeBoolean(false);
            return rt.makeBoolean(!isNaN(args[0].numValue) && args[0].numValue != double.infinity &&
                args[0].numValue != -double.infinity);
        }));

        // Object
        globalScope.declare("Object", makeNativeFunc((thisValue, args, rt) {
            return rt.makeObject();
        }));
        // Array
        globalScope.declare("Array", makeNativeFunc((thisValue, args, rt) {
            auto arr = rt.makeArray();
            foreach (i, arg; args)
            {
                arr.obj.set(to!string(i), arg);
            }
            arr.obj.arrayLength = args.length;
            return arr;
        }));
        // String
        globalScope.declare("String", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeString("");
            return rt.makeString(rt.toJsString(args[0]));
        }));
        // Number
        globalScope.declare("Number", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeNumber(0);
            return rt.makeNumber(rt.toNumber(args[0]));
        }));
        globalScope.get("Number").obj.set("isNaN", makeNativeFunc((thisValue, args, rt) {
            return rt.makeBoolean(args.length > 0 && args[0].kind == JsKind.number && isNaN(args[0].numValue));
        }));
        globalScope.get("Number").obj.set("parseFloat", makeNativeFunc((thisValue, args, rt) {
            return args.length ? rt.makeNumber(rt.toNumber(args[0])) : rt.makeNumber(double.nan);
        }));
        globalScope.get("Number").obj.set("parseInt", globalScope.get("parseInt"));
        globalScope.get("Number").obj.set("isFinite", globalScope.get("isFinite"));
        globalScope.get("Number").obj.set("isInteger", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0 || args[0].kind != JsKind.number) return rt.makeBoolean(false);
            auto n = args[0].numValue;
            return rt.makeBoolean(!isNaN(n) && n != double.infinity && n != -double.infinity && n == cast(long) n);
        }));
        // Boolean
        globalScope.declare("Boolean", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0) return rt.makeBoolean(false);
            return rt.makeBoolean(args[0].isTruthy());
        }));

        // Array.prototype.push, pop, length handled inline in object get for array kind.
        arrayProto.set("push", makeNativeFunc((thisValue, args, rt) {
            foreach (arg; args)
            {
                thisValue.obj.set(to!string(thisValue.obj.arrayLength), arg);
                thisValue.obj.arrayLength++;
            }
            return rt.makeNumber(cast(double) thisValue.obj.arrayLength);
        }));
        arrayProto.set("pop", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj.arrayLength == 0) return rt.makeUndefined();
            thisValue.obj.arrayLength--;
            auto result = thisValue.obj.get(to!string(thisValue.obj.arrayLength));
            return result;
        }));
        arrayProto.set("join", makeNativeFunc((thisValue, args, rt) {
            string sep = args.length ? rt.toJsString(args[0]) : ",";
            string result;
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                if (i) result ~= sep;
                auto item = thisValue.obj.get(to!string(i));
                if (item.kind == JsKind.undefined || item.kind == JsKind.nullValue) continue;
                result ~= rt.toJsString(item);
            }
            return rt.makeString(result);
        }));

        // --- String prototype methods (usable on string primitives) ---
        void installStringMethods()
        {
            // Resolve the receiver string (primitive or __str-bound wrapper).
            auto recv = (JsValue thisValue) @system {
                if (thisValue.kind == JsKind.string) return thisValue.strValue;
                if (thisValue.kind == JsKind.object && thisValue.obj.has("__str"))
                    return thisValue.obj.get("__str").strValue;
                return "";
            };
            stringProto.set("charAt", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long idx = args.length ? cast(long)args[0].numValue : 0;
                if (idx < 0 || idx >= cast(long)s.length) return rt.makeString("");
                return rt.makeString(to!string(s[cast(size_t)idx]));
            }));
            stringProto.set("charCodeAt", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long idx = args.length ? cast(long)args[0].numValue : 0;
                if (idx < 0 || idx >= cast(long)s.length) return rt.makeNumber(double.nan);
                return rt.makeNumber(cast(double) cast(int) s[cast(size_t)idx]);
            }));
            stringProto.set("indexOf", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                auto sub = args.length ? args[0].strValue : "";
                long pos = args.length > 1 ? cast(long)args[1].numValue : 0;
                if (pos < 0) pos = 0;
                if (pos > cast(long)s.length) pos = cast(long)s.length;
                auto idx = indexOf(s[cast(size_t)pos .. $], sub);
                return rt.makeNumber(idx == -1 ? -1 : cast(double)(idx + pos));
            }));
            stringProto.set("slice", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long len = cast(long)s.length;
                long b = args.length ? cast(long)args[0].numValue : 0;
                long e = args.length > 1 ? cast(long)args[1].numValue : len;
                if (b < 0) b += len; if (b < 0) b = 0;
                if (e < 0) e += len; if (e > len) e = len;
                if (e < b) e = b;
                return rt.makeString(s[cast(size_t)b .. cast(size_t)e]);
            }));
            stringProto.set("substring", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long len = cast(long)s.length;
                long a = args.length ? cast(long)args[0].numValue : 0;
                long b = args.length > 1 ? cast(long)args[1].numValue : len;
                if (a < 0) a = 0; if (a > len) a = len;
                if (b < 0) b = 0; if (b > len) b = len;
                long start = a < b ? a : b;
                long end = a < b ? b : a;
                return rt.makeString(s[cast(size_t)start .. cast(size_t)end]);
            }));
            stringProto.set("toUpperCase", makeNativeFunc((thisValue, args, rt) @system {
                return rt.makeString(toUpper(recv(thisValue)));
            }));
            stringProto.set("toLowerCase", makeNativeFunc((thisValue, args, rt) @system {
                return rt.makeString(toLower(recv(thisValue)));
            }));
            stringProto.set("split", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                string sep;
                if (args.length && args[0].kind != JsKind.undefined) sep = args[0].strValue;
                auto arr = rt.makeArray();
                size_t idx = 0;
                if (sep.length == 0)
                {
                    foreach (ch; s) { arr.obj.set(to!string(idx), rt.makeString(to!string(ch))); idx++; }
                }
                else
                {
                    string[] parts;
                    if (s.length == 0) parts ~= "";
                    else
                    {
                        size_t start = 0;
                        while (true)
                        {
                            auto p = indexOf(s[start .. $], sep);
                            if (p == -1) { parts ~= s[start .. $]; break; }
                            parts ~= s[start .. start + cast(size_t)p];
                            start += cast(size_t)p + sep.length;
                        }
                    }
                    foreach (p; parts) { arr.obj.set(to!string(idx), rt.makeString(p)); idx++; }
                }
                arr.obj.arrayLength = idx;
                return arr;
            }));
            stringProto.set("trim", makeNativeFunc((thisValue, args, rt) @system {
                return rt.makeString(strip(recv(thisValue)));
            }));
            stringProto.set("replace", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                if (args.length < 2) return rt.makeString(s);
                auto find = args[0].strValue;
                if (find.length == 0) return rt.makeString(s);
                auto idx = indexOf(s, find);
                if (idx == -1) return rt.makeString(s);
                string result;
                result ~= s[0 .. cast(size_t)idx];
                if (args[1].kind == JsKind.func)
                {
                    JsValue[] fargs;
                    fargs ~= rt.makeString(find);
                    fargs ~= rt.makeNumber(cast(double) idx);
                    fargs ~= rt.makeString(s);
                    auto replacement = rt.callFunction(args[1], rt.makeUndefined(), fargs);
                    result ~= rt.toJsString(replacement);
                }
                else
                    result ~= args[1].strValue;
                result ~= s[cast(size_t)idx + find.length .. $];
                return rt.makeString(result);
            }));
            stringProto.set("startsWith", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                auto sub = args.length ? args[0].strValue : "";
                return rt.makeBoolean(startsWith(s, sub));
            }));
            stringProto.set("endsWith", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                auto sub = args.length ? args[0].strValue : "";
                return rt.makeBoolean(endsWith(s, sub));
            }));
            stringProto.set("includes", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                auto sub = args.length ? args[0].strValue : "";
                return rt.makeBoolean(indexOf(s, sub) != -1);
            }));
            stringProto.set("lastIndexOf", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                auto sub = args.length ? args[0].strValue : "";
                long pos = args.length > 1 ? cast(long)args[1].numValue : cast(long)s.length;
                if (pos < 0) pos = 0;
                if (pos > cast(long)s.length) pos = cast(long)s.length;
                if (sub.length == 0) return rt.makeNumber(cast(double) pos);
                for (long i = pos - cast(long)sub.length; i >= 0; i--)
                {
                    auto idx = indexOf(s[cast(size_t)i .. $], sub);
                    if (idx == 0) return rt.makeNumber(cast(double) i);
                }
                return rt.makeNumber(-1);
            }));
            stringProto.set("repeat", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long count = args.length ? cast(long)args[0].numValue : 0;
                if (count <= 0) return rt.makeString("");
                string result;
                for (long i = 0; i < count; i++) result ~= s;
                return rt.makeString(result);
            }));
            stringProto.set("padStart", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long target = args.length ? cast(long)args[0].numValue : 0;
                string pad = args.length > 1 && args[1].kind == JsKind.string ? args[1].strValue : " ";
                if (cast(long)s.length >= target || pad.length == 0) return rt.makeString(s);
                string result;
                auto needed = target - cast(long)s.length;
                for (long i = 0; i < needed; i++)
                    result ~= pad[cast(size_t)(i % cast(long)pad.length)];
                result ~= s;
                return rt.makeString(result);
            }));
            stringProto.set("padEnd", makeNativeFunc((thisValue, args, rt) @system {
                auto s = recv(thisValue);
                long target = args.length ? cast(long)args[0].numValue : 0;
                string pad = args.length > 1 && args[1].kind == JsKind.string ? args[1].strValue : " ";
                if (cast(long)s.length >= target || pad.length == 0) return rt.makeString(s);
                string result = s;
                auto needed = target - cast(long)s.length;
                for (long i = 0; i < needed; i++)
                    result ~= pad[cast(size_t)(i % cast(long)pad.length)];
                return rt.makeString(result);
            }));
        }
        installStringMethods();

        // --- Array prototype methods ---
        arrayProto.set("forEach", makeNativeFunc((thisValue, args, rt) {
            if (!args.length) return rt.makeUndefined();
            auto cb = args[0];
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                JsValue[] fargs;
                fargs ~= thisValue.obj.get(to!string(i));
                fargs ~= rt.makeNumber(cast(double) i);
                fargs ~= thisValue;
                rt.callFunction(cb, thisValue, fargs);
            }
            return rt.makeUndefined();
        }));
        arrayProto.set("map", makeNativeFunc((thisValue, args, rt) {
            auto res = rt.makeArray();
            if (!args.length) return res;
            auto cb = args[0];
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                JsValue[] fargs;
                fargs ~= thisValue.obj.get(to!string(i));
                fargs ~= rt.makeNumber(cast(double) i);
                fargs ~= thisValue;
                res.obj.set(to!string(i), rt.callFunction(cb, thisValue, fargs));
            }
            res.obj.arrayLength = thisValue.obj.arrayLength;
            return res;
        }));
        arrayProto.set("filter", makeNativeFunc((thisValue, args, rt) {
            auto res = rt.makeArray();
            if (!args.length) return res;
            auto cb = args[0];
            size_t resIdx = 0;
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                JsValue[] fargs;
                fargs ~= item;
                fargs ~= rt.makeNumber(cast(double) i);
                fargs ~= thisValue;
                if (rt.callFunction(cb, thisValue, fargs).isTruthy())
                {
                    res.obj.set(to!string(resIdx), item);
                    resIdx++;
                }
            }
            res.obj.arrayLength = resIdx;
            return res;
        }));
        arrayProto.set("reduce", makeNativeFunc((thisValue, args, rt) {
            auto cb = args.length ? args[0] : JsValue.init;
            size_t i = 0;
            JsValue acc;
            if (args.length > 1) acc = args[1];
            else
            {
                if (thisValue.obj.arrayLength == 0) return rt.makeUndefined();
                acc = thisValue.obj.get(to!string(0));
                i = 1;
            }
            for (; i < thisValue.obj.arrayLength; i++)
            {
                JsValue[] fargs;
                fargs ~= acc;
                fargs ~= thisValue.obj.get(to!string(i));
                fargs ~= rt.makeNumber(cast(double) i);
                fargs ~= thisValue;
                acc = rt.callFunction(cb, thisValue, fargs);
            }
            return acc;
        }));
        arrayProto.set("indexOf", makeNativeFunc((thisValue, args, rt) {
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                if (args.length && rt.strictEquals(item, args[0])) return rt.makeNumber(cast(double) i);
            }
            return rt.makeNumber(-1);
        }));
        arrayProto.set("slice", makeNativeFunc((thisValue, args, rt) {
            long len = cast(long)thisValue.obj.arrayLength;
            long b = args.length ? cast(long)args[0].numValue : 0;
            long e = args.length > 1 ? cast(long)args[1].numValue : len;
            if (b < 0) b += len; if (b < 0) b = 0;
            if (e < 0) e += len; if (e > len) e = len;
            if (e < b) e = b;
            auto res = rt.makeArray();
            size_t oi = 0;
            for (long i = b; i < e; i++)
            {
                res.obj.set(to!string(oi), thisValue.obj.get(to!string(i)));
                oi++;
            }
            res.obj.arrayLength = oi;
            return res;
        }));
        arrayProto.set("concat", makeNativeFunc((thisValue, args, rt) {
            auto res = rt.makeArray();
            size_t oi = 0;
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                res.obj.set(to!string(oi), thisValue.obj.get(to!string(i)));
                oi++;
            }
            foreach (arg; args)
            {
                if (arg.kind == JsKind.array)
                {
                    for (size_t i = 0; i < arg.obj.arrayLength; i++)
                    {
                        res.obj.set(to!string(oi), arg.obj.get(to!string(i)));
                        oi++;
                    }
                }
                else { res.obj.set(to!string(oi), arg); oi++; }
            }
            res.obj.arrayLength = oi;
            return res;
        }));
        arrayProto.set("reverse", makeNativeFunc((thisValue, args, rt) {
            size_t len = thisValue.obj.arrayLength;
            for (size_t i = 0; i < len / 2; i++)
            {
                auto a = thisValue.obj.get(to!string(i));
                auto b = thisValue.obj.get(to!string(len - 1 - i));
                thisValue.obj.set(to!string(i), b);
                thisValue.obj.set(to!string(len - 1 - i), a);
            }
            return thisValue;
        }));
        arrayProto.set("shift", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj.arrayLength == 0) return rt.makeUndefined();
            auto first = thisValue.obj.get(to!string(0));
            for (size_t i = 1; i < thisValue.obj.arrayLength; i++)
                thisValue.obj.set(to!string(i - 1), thisValue.obj.get(to!string(i)));
            thisValue.obj.arrayLength--;
            return first;
        }));
        arrayProto.set("unshift", makeNativeFunc((thisValue, args, rt) {
            size_t n = args.length;
            size_t oldLen = thisValue.obj.arrayLength;
            for (size_t i = oldLen; i > 0; i--)
                thisValue.obj.set(to!string(i + n - 1), thisValue.obj.get(to!string(i - 1)));
            foreach (i, arg; args)
                thisValue.obj.set(to!string(i), arg);
            thisValue.obj.arrayLength = oldLen + n;
            return rt.makeNumber(cast(double) thisValue.obj.arrayLength);
        }));
        arrayProto.set("lastIndexOf", makeNativeFunc((thisValue, args, rt) {
            long i = cast(long)thisValue.obj.arrayLength - 1;
            if (args.length && (thisValue.obj.arrayLength == 0)) return rt.makeNumber(-1);
            if (args.length == 0) return rt.makeNumber(-1);
            for (; i >= 0; i--)
            {
                auto item = thisValue.obj.get(to!string(i));
                if (rt.strictEquals(item, args[0])) return rt.makeNumber(cast(double) i);
            }
            return rt.makeNumber(-1);
        }));
        arrayProto.set("includes", makeNativeFunc((thisValue, args, rt) {
            long n = cast(long)thisValue.obj.arrayLength;
            long fromIndex = args.length > 1 ? cast(long)args[1].numValue : 0;
            if (fromIndex < 0) fromIndex = n + fromIndex;
            if (fromIndex < 0) fromIndex = 0;
            for (long i = fromIndex; i < n; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                if (rt.strictEquals(item, args[0])) return rt.makeBoolean(true);
            }
            return rt.makeBoolean(false);
        }));
        arrayProto.set("find", makeNativeFunc((thisValue, args, rt) {
            if (!args.length || args[0].kind != JsKind.func) return rt.makeUndefined();
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                JsValue[] fargs; fargs ~= item; fargs ~= rt.makeNumber(cast(double) i); fargs ~= thisValue;
                if (rt.callFunction(args[0], thisValue, fargs).isTruthy()) return item;
            }
            return rt.makeUndefined();
        }));
        arrayProto.set("findIndex", makeNativeFunc((thisValue, args, rt) {
            if (!args.length || args[0].kind != JsKind.func) return rt.makeNumber(-1);
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                JsValue[] fargs; fargs ~= item; fargs ~= rt.makeNumber(cast(double) i); fargs ~= thisValue;
                if (rt.callFunction(args[0], thisValue, fargs).isTruthy()) return rt.makeNumber(cast(double) i);
            }
            return rt.makeNumber(-1);
        }));
        arrayProto.set("every", makeNativeFunc((thisValue, args, rt) {
            if (!args.length || args[0].kind != JsKind.func) return rt.makeBoolean(false);
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                JsValue[] fargs; fargs ~= item; fargs ~= rt.makeNumber(cast(double) i); fargs ~= thisValue;
                if (!rt.callFunction(args[0], thisValue, fargs).isTruthy()) return rt.makeBoolean(false);
            }
            return rt.makeBoolean(true);
        }));
        arrayProto.set("some", makeNativeFunc((thisValue, args, rt) {
            if (!args.length || args[0].kind != JsKind.func) return rt.makeBoolean(false);
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
            {
                auto item = thisValue.obj.get(to!string(i));
                JsValue[] fargs; fargs ~= item; fargs ~= rt.makeNumber(cast(double) i); fargs ~= thisValue;
                if (rt.callFunction(args[0], thisValue, fargs).isTruthy()) return rt.makeBoolean(true);
            }
            return rt.makeBoolean(false);
        }));
        arrayProto.set("flat", makeNativeFunc((thisValue, args, rt) {
            auto res = rt.makeArray();
            size_t oi = 0;
            void appendItem(JsValue item)
            {
                if (item.kind == JsKind.array)
                {
                    for (size_t i = 0; i < item.obj.arrayLength; i++)
                    {
                        res.obj.set(to!string(oi), item.obj.get(to!string(i)));
                        oi++;
                    }
                }
                else
                {
                    res.obj.set(to!string(oi), item);
                    oi++;
                }
            }
            for (size_t i = 0; i < thisValue.obj.arrayLength; i++)
                appendItem(thisValue.obj.get(to!string(i)));
            res.obj.arrayLength = oi;
            return res;
        }));

        // --- Function.prototype.call / apply ---
        functionProto.set("call", makeNativeFunc((thisValue, args, rt) {
            auto target = thisValue;
            JsValue[] callArgs;
            if (args.length > 1) callArgs = args[1 .. $];
            JsValue thisArg = args.length ? args[0] : rt.makeUndefined();
            return rt.callFunction(target, thisArg, callArgs);
        }));
        functionProto.set("apply", makeNativeFunc((thisValue, args, rt) {
            auto target = thisValue;
            JsValue thisArg = args.length ? args[0] : rt.makeUndefined();
            JsValue[] callArgs;
            if (args.length > 1 && args[1].kind == JsKind.array)
            {
                for (size_t i = 0; i < args[1].obj.arrayLength; i++)
                    callArgs ~= args[1].obj.get(to!string(i));
            }
            return rt.callFunction(target, thisArg, callArgs);
        }));
        functionProto.set("bind", makeNativeFunc((thisValue, args, rt) {
            auto target = thisValue;
            auto boundThis = args.length ? args[0] : rt.makeUndefined();
            JsValue[] pre;
            if (args.length > 1) pre = args[1 .. $];
            auto boundFn = rt.makeNativeFunc((bt, bargs, brt) {
                JsValue[] all = pre ~ bargs;
                return brt.callFunction(target, boundThis, all);
            });
            // A bound function still reports as callable, and preserves the
            // target's prototype so `new bound()` and instanceof keep working.
            if (target.kind == JsKind.func)
            {
                auto protoVal = target.obj.get("prototype");
                if (protoVal.kind == JsKind.object || protoVal.kind == JsKind.array)
                    boundFn.obj.set("prototype", protoVal);
            }
            return boundFn;
        }));

        // --- Object constructor & statics ---
        auto objectFnObj = globalScope.get("Object").obj;
        objectFnObj.set("keys", makeNativeFunc((thisValue, args, rt) {
            auto arr = rt.makeArray();
            size_t idx = 0;
            if (args.length)
            {
                auto obj = args[0];
                if (obj.kind == JsKind.object || obj.kind == JsKind.array)
                {
                    foreach (key, _; obj.obj.props)
                    {
                        if (obj.kind == JsKind.array && key == "length") continue;
                        arr.obj.set(to!string(idx), rt.makeString(key));
                        idx++;
                    }
                    if (obj.kind == JsKind.array)
                    {
                        foreach (i; 0 .. obj.obj.arrayLength)
                        {
                            auto k = to!string(i);
                            if ((k in obj.obj.props) is null)
                            {
                                arr.obj.set(to!string(idx), rt.makeString(k));
                                idx++;
                            }
                        }
                    }
                }
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));
        objectFnObj.set("assign", makeNativeFunc((thisValue, args, rt) {
            auto target = args.length ? args[0] : rt.makeObject();
            foreach (i; 1 .. args.length)
            {
                auto src = args[i];
                if (src.kind == JsKind.object || src.kind == JsKind.array)
                {
                    foreach (key, val; src.obj.props)
                    {
                        if (src.kind == JsKind.array && key == "length") continue;
                        target.obj.set(key, val);
                    }
                    if (src.kind == JsKind.array)
                    {
                        foreach (j; 0 .. src.obj.arrayLength)
                        {
                            auto k = to!string(j);
                            if ((k in src.obj.props) is null)
                                target.obj.set(k, src.obj.get(k));
                        }
                    }
                }
            }
            return target;
        }));
        objectFnObj.set("create", makeNativeFunc((thisValue, args, rt) {
            auto obj = new JsObject();
            obj.kind = "Object";
            if (args.length && (args[0].kind == JsKind.object || args[0].kind == JsKind.array || args[0].kind == JsKind.func))
                obj.proto = args[0].obj;
            return JsValue(JsKind.object, obj);
        }));
        // Shared key enumeration for entries/values (own enumerable props).
        objectFnObj.set("entries", makeNativeFunc((thisValue, args, rt) {
            auto arr = rt.makeArray();
            size_t idx = 0;
            if (args.length && (args[0].kind == JsKind.object || args[0].kind == JsKind.array))
            {
                auto obj = args[0];
                string[] keys;
                foreach (key, _; obj.obj.props)
                {
                    if (obj.kind == JsKind.array && key == "length") continue;
                    keys ~= key;
                }
                if (obj.kind == JsKind.array)
                {
                    foreach (i; 0 .. obj.obj.arrayLength)
                    {
                        auto k = to!string(i);
                        if ((k in obj.obj.props) is null) keys ~= k;
                    }
                }
                foreach (key; keys)
                {
                    auto pair = rt.makeArray();
                    pair.obj.set("0", rt.makeString(key));
                    pair.obj.set("1", obj.obj.get(key));
                    pair.obj.arrayLength = 2;
                    arr.obj.set(to!string(idx), pair);
                    idx++;
                }
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));
        objectFnObj.set("values", makeNativeFunc((thisValue, args, rt) {
            auto arr = rt.makeArray();
            size_t idx = 0;
            if (args.length && (args[0].kind == JsKind.object || args[0].kind == JsKind.array))
            {
                auto obj = args[0];
                string[] keys;
                foreach (key, _; obj.obj.props)
                {
                    if (obj.kind == JsKind.array && key == "length") continue;
                    keys ~= key;
                }
                if (obj.kind == JsKind.array)
                {
                    foreach (i; 0 .. obj.obj.arrayLength)
                    {
                        auto k = to!string(i);
                        if ((k in obj.obj.props) is null) keys ~= k;
                    }
                }
                foreach (key; keys)
                {
                    arr.obj.set(to!string(idx), obj.obj.get(key));
                    idx++;
                }
            }
            arr.obj.arrayLength = idx;
            return arr;
        }));

        // --- Array.isArray ---
        auto arrayFnObj = globalScope.get("Array").obj;
        arrayFnObj.set("isArray", makeNativeFunc((thisValue, args, rt) {
            return rt.makeBoolean(args.length && args[0].kind == JsKind.array);
        }));

        // --- instanceof wiring: builtin constructors expose their shared
        // prototype objects so `[] instanceof Array`, `{} instanceof Object`,
        // `function(){} instanceof Function` all hold.
        globalScope.get("Array").obj.set("prototype", JsValue(JsKind.object, arrayProto));
        globalScope.get("Object").obj.set("prototype", JsValue(JsKind.object, objectProto));
        globalScope.get("String").obj.set("prototype", JsValue(JsKind.object, stringProto));
        auto functionFn = makeNativeFunc((thisValue, args, rt) { return rt.makeUndefined(); });
        functionFn.obj.set("prototype", JsValue(JsKind.object, functionProto));
        globalScope.declare("Function", functionFn);

        // --- Error constructors ---
        errorProto = new JsObject();
        errorProto.kind = "Object";
        errorProto.proto = objectProto;
        void installErrorCtor(string name)
        {
            auto ctor = makeNativeFunc((thisValue, args, rt) {
                string msg = args.length ? rt.toJsString(args[0]) : "";
                return makeErrorValue(name, msg);
            });
            // Set the constructor's prototype so `instanceof` works with the
            // error instances created by makeErrorValue.
            ctor.obj.set("prototype", JsValue(JsKind.object, errorProto));
            globalScope.declare(name, ctor);
        }
        installErrorCtor("Error");
        installErrorCtor("TypeError");
        installErrorCtor("RangeError");
        installErrorCtor("SyntaxError");

        // --- JSON ---
        auto jsonObj = new JsObject();
        jsonObj.set("stringify", makeNativeFunc((thisValue, args, rt) {
            return rt.makeString(args.length ? rt.jsStringify(args[0]) : "undefined");
        }));
        jsonObj.set("parse", makeNativeFunc((thisValue, args, rt) {
            if (!args.length) return rt.makeUndefined();
            auto s = args[0].strValue;
            size_t p = 0;
            auto result = rt.jsParseValue(s, p);
            return result;
        }));
        globalScope.declare("JSON", JsValue(JsKind.object, jsonObj));

        // --- typeof ---
        globalScope.declare("typeof", makeNativeFunc((thisValue, args, rt) {
            return rt.makeString(args.length ? rt.typeOfString(args[0]) : "undefined");
        }));

        globalScope.declare("NaN", makeNumber(double.nan));
        globalScope.declare("Infinity", makeNumber(double.infinity));
        globalScope.declare("undefined", makeUndefined());

        installPromiseBuiltins();
        installSetMapBuiltins();
        installTimerBuiltins();
    }

    /// Promise constructor + prototype (then/catch/finally), Promise.resolve.
    private void installPromiseBuiltins()
    {
        promiseProto = new JsObject();
        promiseProto.kind = "Promise";
        promiseProto.proto = objectProto;

        // promise.then(onFulfilled, onRejected)
        promiseProto.set("then", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            auto state = thisValue.obj.get("__state");
            auto value = thisValue.obj.get("__value");
            auto resultPromise = rt.makePromiseObj();
            auto onFulfilled = args.length >= 1 ? args[0] : rt.makeUndefined();
            if (state.kind == JsKind.string && state.strValue == "resolved")
            {
                if (onFulfilled.kind == JsKind.func)
                {
                    JsValue[] a; a ~= value;
                    auto res = rt.callFunction(onFulfilled, thisValue, a);
                    resultPromise.obj.set("__state", rt.makeString("resolved"));
                    resultPromise.obj.set("__value", res);
                }
                else
                {
                    resultPromise.obj.set("__state", rt.makeString("resolved"));
                    resultPromise.obj.set("__value", value);
                }
                return resultPromise;
            }
            // Pending: register continuation.
            auto thens = thisValue.obj.get("__thens");
            if (thens.kind == JsKind.array)
            {
                auto cont = rt.makeObject();
                cont.obj.set("onFulfilled", onFulfilled);
                cont.obj.set("resultPromise", resultPromise);
                thens.obj.set(to!string(thens.obj.arrayLength), cont);
                thens.obj.arrayLength++;
            }
            return resultPromise;
        }));
        promiseProto.set("catch", makeNativeFunc((thisValue, args, rt) {
            // Reuse then with the reject handler in the reject slot.
            return rt.callFunction(thisValue.obj.get("then"), thisValue,
                [rt.makeUndefined(), args.length ? args[0] : rt.makeUndefined()]);
        }));

        globalScope.declare("Promise", makeNativeFunc((thisValue, args, rt) {
            auto p = rt.makePromiseObj();
            if (args.length && args[0].kind == JsKind.func)
            {
                // executor(resolve, reject)
                auto resolveFn = rt.makeNativeFunc((thisValue2, args2, rt2) {
                    p.obj.set("__state", rt2.makeString("resolved"));
                    p.obj.set("__value", args2.length ? args2[0] : rt2.makeUndefined());
                    // Flush pending thens.
                    auto thens = p.obj.get("__thens");
                    if (thens.kind == JsKind.array)
                    {
                        for (size_t i = 0; i < thens.obj.arrayLength; i++)
                        {
                            auto cont = thens.obj.get(to!string(i));
                            auto onF = cont.obj.get("onFulfilled");
                            auto rp = cont.obj.get("resultPromise");
                            if (onF.kind == JsKind.func)
                            {
                                JsValue[] a; a ~= p.obj.get("__value");
                                auto res = rt2.callFunction(onF, p, a);
                                rp.obj.set("__state", rt2.makeString("resolved"));
                                rp.obj.set("__value", res);
                            }
                            else
                            {
                                rp.obj.set("__state", rt2.makeString("resolved"));
                                rp.obj.set("__value", p.obj.get("__value"));
                            }
                        }
                    }
                    return rt2.makeUndefined();
                });
                auto rejectFn = rt.makeNativeFunc((thisValue2, args2, rt2) {
                    p.obj.set("__state", rt2.makeString("rejected"));
                    p.obj.set("__value", args2.length ? args2[0] : rt2.makeUndefined());
                    return rt2.makeUndefined();
                });
                JsValue[] eargs; eargs ~= resolveFn; eargs ~= rejectFn;
                rt.callFunction(args[0], p, eargs);
            }
            return p;
        }));

        globalScope.declare("Promise_resolve_internal", makeNativeFunc((thisValue, args, rt) {
            return args.length ? rt.resolvePromise(args[0]) : rt.resolvePromise(rt.makeUndefined());
        }));
        // Public Promise.resolve
        globalScope.get("Promise").obj.set("resolve", makeNativeFunc((thisValue, args, rt) {
            return args.length ? rt.resolvePromise(args[0]) : rt.resolvePromise(rt.makeUndefined());
        }));
    }

    /// Set and Map native builtins.
    private void installSetMapBuiltins()
    {
        setProto = new JsObject();
        setProto.kind = "Set";
        setProto.proto = objectProto;
        setProto.set("add", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) { store = rt.makeObject(); thisValue.obj.set("__store", store); }
            store.obj.set(key, rt.makeBoolean(true));
            return thisValue;
        }));
        setProto.set("has", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeBoolean(false);
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeBoolean(false);
            return rt.makeBoolean((key in store.obj.props) !is null);
        }));
        setProto.set("delete", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeBoolean(false);
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeBoolean(false);
            auto existed = (key in store.obj.props) !is null;
            store.obj.props.remove(key);
            return rt.makeBoolean(existed);
        }));
        setProto.set("forEach", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            if (args.length == 0 || args[0].kind != JsKind.func) return rt.makeUndefined();
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeUndefined();
            foreach (key, _; store.obj.props)
            {
                JsValue[] a; a ~= rt.makeString(key); a ~= rt.makeString(key); a ~= thisValue;
                rt.callFunction(args[0], thisValue, a);
            }
            return rt.makeUndefined();
        }));

        globalScope.declare("Set", makeNativeFunc((thisValue, args, rt) {
            auto obj = new JsObject();
            obj.kind = "Set";
            obj.proto = setProto;
            obj.set("size", rt.makeNumber(0));
            obj.set("__store", rt.makeObject());
            return JsValue(JsKind.object, obj);
        }));

        mapProto = new JsObject();
        mapProto.kind = "Map";
        mapProto.proto = objectProto;
        mapProto.set("set", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto val = args.length > 1 ? args[1] : rt.makeUndefined();
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) { store = rt.makeObject(); thisValue.obj.set("__store", store); }
            store.obj.set(key, val);
            auto order = thisValue.obj.get("__order");
            if (order.kind != JsKind.array) { order = rt.makeArray(); thisValue.obj.set("__order", order); }
            if ((key in store.obj.props) !is null && !orderContains(order, key))
                order.obj.set(to!string(order.obj.arrayLength), rt.makeString(key)), order.obj.arrayLength++;
            return thisValue;
        }));
        mapProto.set("get", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeUndefined();
            return store.obj.get(key);
        }));
        mapProto.set("has", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeBoolean(false);
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeBoolean(false);
            return rt.makeBoolean((key in store.obj.props) !is null);
        }));
        mapProto.set("delete", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeBoolean(false);
            auto key = args.length ? rt.toJsString(args[0]) : "undefined";
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeBoolean(false);
            auto existed = (key in store.obj.props) !is null;
            store.obj.props.remove(key);
            return rt.makeBoolean(existed);
        }));
        mapProto.set("forEach", makeNativeFunc((thisValue, args, rt) {
            if (thisValue.obj is null) return rt.makeUndefined();
            if (args.length == 0 || args[0].kind != JsKind.func) return rt.makeUndefined();
            auto store = thisValue.obj.get("__store");
            if (store.kind != JsKind.object) return rt.makeUndefined();
            foreach (key, v; store.obj.props)
            {
                JsValue[] a; a ~= v; a ~= rt.makeString(key); a ~= thisValue;
                rt.callFunction(args[0], thisValue, a);
            }
            return rt.makeUndefined();
        }));

        globalScope.declare("Map", makeNativeFunc((thisValue, args, rt) {
            auto obj = new JsObject();
            obj.kind = "Map";
            obj.proto = mapProto;
            obj.set("size", rt.makeNumber(0));
            obj.set("__store", rt.makeObject());
            obj.set("__order", rt.makeArray());
            return JsValue(JsKind.object, obj);
        }));
    }

    private bool orderContains(JsValue arr, string key)
    {
        if (arr.kind != JsKind.array) return false;
        for (size_t i = 0; i < arr.obj.arrayLength; i++)
            if (arr.obj.get(to!string(i)).strValue == key) return true;
        return false;
    }

    /// setTimeout / setInterval.
    private void installTimerBuiltins()
    {
        globalScope.declare("setTimeout", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0 || args[0].kind != JsKind.func) return rt.makeNumber(0);
            auto delay = args.length > 1 ? args[1].numValue : 0;
            return rt.makeNumber(cast(double) rt.installTimer(args[0], delay, false));
        }));
        globalScope.declare("setInterval", makeNativeFunc((thisValue, args, rt) {
            if (args.length == 0 || args[0].kind != JsKind.func) return rt.makeNumber(0);
            auto delay = args.length > 1 ? args[1].numValue : 0;
            return rt.makeNumber(cast(double) rt.installTimer(args[0], delay, true));
        }));
    }

    /// Install the `fetch` global bound to `fetchHandler`. Called by the DOM
    /// binder once the page-provided handler is available. The handler itself
    /// is set through `fetchHandler` before calling this.
    void installFetchBuiltin()
    {
        if (fetchHandler is null) return;
        if (globalScope.has("fetch")) return;
        auto fetchFn = makeNativeFunc((thisValue, args, rt) {
            auto handler = rt.fetchHandler;
            if (handler is null) return rt.makeUndefined();
            JsValue url = args.length ? args[0] : rt.makeUndefined();
            JsValue options = args.length > 1 ? args[1] : rt.makeUndefined();
            return handler(url, options, rt);
        });
        globalScope.declare("fetch", fetchFn);
    }

    // --- error helpers ---
    JsValue makeError(string message)
    {
        auto obj = new JsObject();
        obj.set("name", makeString("Error"));
        obj.set("message", makeString(message));
        return JsValue(JsKind.object, obj);
    }

    /// Execute a node. Returns the value.
    JsValue execNode(Node node, ref JsScope sc, JsValue thisValue)
    {
        if (node is null) return makeUndefined();
        // During an async-body resume, skip nodes already executed before the
        // awaited node (identified by parse-time execution order).
        if (_activeResume !is null)
        {
            if (node.kind == NodeKind.awaitExpr && node is _activeResume.awaitNode)
            {
                // Resume point: return the awaited resolved value.
                return _activeResume.resolvedValue;
            }
            if (node.order > 0 && node.order <= _activeResume.awaitNode.order)
                return makeUndefined();  // already executed — do not re-run.
        }
        final switch (node.kind)
        {
            case NodeKind.program, NodeKind.block:
            {
                foreach (child; node.children)
                {
                    execNode(child, sc, thisValue);
                    if (returned) return returnValue;
                }
                return makeUndefined();
            }
            case NodeKind.exprStmt:
                return execNode(node.children[0], sc, thisValue);
            case NodeKind.thisExpr: return thisValue;
            case NodeKind.varDecl:
            {
                foreach (i, name; node.names)
                {
                    JsValue init = makeUndefined();
                    if (i < node.children.length)
                        init = execNode(node.children[i], sc, thisValue);
                    // If already hoisted (declared as undefined at scope start),
                    // just set the new value; otherwise declare it.
                    if (sc.has(name)) sc.set(name, init);
                    else sc.declare(name, init);
                }
                return makeUndefined();
            }
            case NodeKind.ifStmt:
            {
                auto test = execNode(node.children[0], sc, thisValue);
                if (test.isTruthy())
                    return execNode(node.children[1], sc, thisValue);
                else if (node.children.length > 2)
                    return execNode(node.children[2], sc, thisValue);
                return makeUndefined();
            }
            case NodeKind.whileStmt:
            {
                while (execNode(node.children[0], sc, thisValue).isTruthy())
                {
                    execNode(node.children[1], sc, thisValue);
                    if (returned) return returnValue;
                }
                return makeUndefined();
            }
            case NodeKind.forStmt:
            {
                auto innerScope = new JsScope("for", sc);
                if (node.children.length >= 1)
                    execNode(node.children[0], innerScope, thisValue);
                while (node.children.length < 2 || execNode(node.children[1], innerScope, thisValue).isTruthy())
                {
                    if (node.children.length >= 4)
                        execNode(node.children[3], innerScope, thisValue);
                    if (returned) return returnValue;
                    if (node.children.length >= 3)
                        execNode(node.children[2], innerScope, thisValue);
                }
                return makeUndefined();
            }
            case NodeKind.forInStmt:
            {
                auto objValue = execNode(node.children[1], sc, thisValue);
                string[] keys;
                if (objValue.kind == JsKind.object || objValue.kind == JsKind.array)
                {
                    foreach (key, _; objValue.obj.props) keys ~= key;
                }
                auto innerScope = new JsScope("for-in", sc);
                foreach (key; keys)
                {
                    innerScope.declare(node.name, makeString(key));
                    execNode(node.children[0], innerScope, thisValue);
                }
                return makeUndefined();
            }
            case NodeKind.forOfStmt:
            {
                auto iterable = execNode(node.children[1], sc, thisValue);
                auto innerScope = new JsScope("for-of", sc);
                if (iterable.kind == JsKind.array)
                {
                    for (size_t i = 0; i < iterable.obj.arrayLength; i++)
                    {
                        innerScope.declare(node.name, iterable.obj.get(to!string(i)));
                        execNode(node.children[0], innerScope, thisValue);
                        if (returned) return returnValue;
                    }
                }
                else if (iterable.kind == JsKind.string)
                {
                    foreach (ch; iterable.strValue)
                    {
                        innerScope.declare(node.name, makeString(to!string(ch)));
                        execNode(node.children[0], innerScope, thisValue);
                        if (returned) return returnValue;
                    }
                }
                return makeUndefined();
            }
            case NodeKind.functionDecl:
            {
                auto fn = makeScriptFunc(node.params, node.children[0], sc);
                if (node.boolValue)
                {
                    // async function.
                    fn.scriptFunc.isAsync = true;
                }
                if (node.name.length)
                    sc.declare(node.name, fn);
                return fn;
            }
            case NodeKind.arrow:
            {
                // Arrow: capture the defining scope; lexical this is the current
                // thisValue, captured into the function value's closure scope.
                auto fn = makeScriptFunc(node.params, node.children[0], sc);
                fn.scriptFunc.isArrow = true;
                // Store the lexical this in the closure scope under a sentinel.
                fn.scriptFunc.closure.vars["__arrow_this"] = thisValue;
                return fn;
            }
            case NodeKind.templateLit:
            {
                string result;
                foreach (child; node.children)
                {
                    auto v = execNode(child, sc, thisValue);
                    result ~= toJsString(v);
                }
                return makeString(result);
            }
            case NodeKind.awaitExpr:
            {
                auto v = execNode(node.children[0], sc, thisValue);
                if (v.kind == JsKind.object && v.obj !is null &&
                    v.obj.get("__isPromise").isTruthy())
                {
                    auto state = v.obj.get("__state");
                    if (state.kind == JsKind.string && state.strValue == "resolved")
                        return v.obj.get("__value");
                    // Pending promise: suspend this async body.
                    if (_activeResume !is null && _activeResume.awaitNode is node)
                        return _activeResume.resolvedValue;
                    // Record the suspension frame.
                    AwaitFrame frame;
                    frame.awaitNode = node;
                    frame.sc = sc;
                    frame.thisValue = thisValue;
                    frame.resolved = false;
                    frame.bodyFn = _currentAsyncBody;
                    _awaitFrames ~= frame;
                    _awaitPending = true;
                    // Register a then continuation that resumes the body.
                    auto thenFn = v.obj.get("then");
                    if (thenFn.kind == JsKind.func)
                    {
                        auto resumeNative = makeNativeFunc((thisValue2, args2, rt2) {
                            // The promise resolved: re-enter the async body.
                            if (rt2._awaitFrames.length == 0) return rt2.makeUndefined();
                            auto f = rt2._awaitFrames[$ - 1];
                            rt2._awaitFrames.length = rt2._awaitFrames.length - 1;
                            f.resolved = true;
                            f.resolvedValue = args2.length ? args2[0] : rt2.makeUndefined();
                            // Defer the actual re-entry to a microtask so the
                            // current call stack unwinds first.
                            AwaitFrame captured = f;
                            rt2.queueMicrotask(rt2.makeNativeFunc((thisValue3, args3, rt3) {
                                if (captured.bodyFn.kind == JsKind.func)
                                {
                                    // Set the resume frame so execNode skips
                                    // already-executed nodes up to the await.
                                    rt3._activeResume = &captured;
                                    rt3._awaitPending = false;
                                    JsValue[] a;
                                    rt3.callFunction(captured.bodyFn, rt3.makeUndefined(), a);
                                    rt3._activeResume = null;
                                }
                                return rt3.makeUndefined();
                            }));
                            return rt2.makeUndefined();
                        });
                        JsValue[] targs; targs ~= resumeNative;
                        callFunction(thenFn, v, targs);
                    }
                    return makeUndefined();
                }
                return v;
            }
            case NodeKind.returnStmt:
            {
                JsValue val = makeUndefined();
                if (node.children.length)
                    val = execNode(node.children[0], sc, thisValue);
                returned = true;
                returnValue = val;
                return val;
            }
            case NodeKind.throwStmt:
            {
                pendingException = execNode(node.children[0], sc, thisValue);
                lastHadException = true;
                throw new JsThrowException();
            }
            case NodeKind.tryStmt:
            {
                auto innerScope = new JsScope("try", sc);
                execTryBody(node, innerScope, thisValue);
                return makeUndefined();
            }
            // Expressions
            case NodeKind.numberLit: return makeNumber(node.numValue);
            case NodeKind.stringLit: return makeString(node.strValue);
            case NodeKind.boolLit: return makeBoolean(node.boolValue);
            case NodeKind.nullLit: return makeNull();
            case NodeKind.identifier: return sc.get(node.name);
            case NodeKind.arrayLit:
            {
                auto arr = makeArray();
                foreach (i, child; node.children)
                    arr.obj.set(to!string(i), execNode(child, sc, thisValue));
                arr.obj.arrayLength = node.children.length;
                return arr;
            }
            case NodeKind.objectLit:
            {
                auto obj = makeObject();
                foreach (i, key; node.names)
                    obj.obj.set(key, execNode(node.children[i], sc, thisValue));
                return obj;
            }
            case NodeKind.unary:
            {
                auto operand = execNode(node.children[0], sc, thisValue);
                switch (node.op)
                {
                    case "!": return makeBoolean(!operand.isTruthy());
                    case "-": return makeNumber(-toNumber(operand));
                    case "+": return makeNumber(toNumber(operand));
                    case "typeof": return makeString(typeOfString(operand));
                    default: return makeUndefined();
                }
            }
            case NodeKind.binary:
            {
                auto left = execNode(node.children[0], sc, thisValue);
                auto right = execNode(node.children[1], sc, thisValue);
                return applyBinary(node.op, left, right);
            }
            case NodeKind.logical:
            {
                auto left = execNode(node.children[0], sc, thisValue);
                if (node.op == "&&")
                {
                    if (!left.isTruthy()) return left;
                    return execNode(node.children[1], sc, thisValue);
                }
                else // ||
                {
                    if (left.isTruthy()) return left;
                    return execNode(node.children[1], sc, thisValue);
                }
            }
            case NodeKind.ternary:
            {
                auto test = execNode(node.children[0], sc, thisValue);
                if (test.isTruthy())
                    return execNode(node.children[1], sc, thisValue);
                return execNode(node.children[2], sc, thisValue);
            }
            case NodeKind.assign:
            {
                auto target = node.children[0];
                const op = node.op.length ? node.op : "=";
                if (op == "=")
                {
                    auto value = execNode(node.children[1], sc, thisValue);
                    return assignToTarget(target, value, sc, thisValue);
                }
                // Compound assignment: read old value, apply op, write back.
                auto oldValue = readTarget(target, sc, thisValue);
                auto rightValue = execNode(node.children[1], sc, thisValue);
                auto newValue = applyBinary(op[0 .. $ - 1], oldValue, rightValue);
                return assignToTarget(target, newValue, sc, thisValue);
            }
            case NodeKind.update:
            {
                auto target = node.children[0];
                auto oldValue = readTarget(target, sc, thisValue);
                auto newValue = makeNumber(oldValue.numValue + (node.op == "++" ? 1 : -1));
                auto result = assignToTarget(target, newValue, sc, thisValue);
                // Prefix returns the new value, postfix the old.
                return node.boolValue ? result : oldValue;
            }
            case NodeKind.member:
            {
                auto objValue = execNode(node.children[0], sc, thisValue);
                JsValue key;
                if (node.children.length > 1)
                    key = execNode(node.children[1], sc, thisValue);
                else key = makeString(node.name);
                return getProp(objValue, key);
            }
            case NodeKind.call:
            {
                auto calleeNode = node.children[0];
                auto calleeValue = execNode(calleeNode, sc, thisValue);
                JsValue[] args;
                foreach (child; node.children[1 .. $])
                    args ~= execNode(child, sc, thisValue);
                // Method call: bind the receiver object as `this`.
                if (calleeNode.kind == NodeKind.member)
                {
                    auto receiver = execNode(calleeNode.children[0], sc, thisValue);
                    return callFunction(calleeValue, receiver, args);
                }
                // Plain call: `this` is the global object.
                return callFunction(calleeValue, JsValue(JsKind.object, globalObject), args);
            }
            case NodeKind.newExpr:
            {
                auto calleeValue = execNode(node.children[0], sc, thisValue);
                JsValue[] args;
                foreach (child; node.children[1 .. $])
                    args ~= execNode(child, sc, thisValue);
                // Create a fresh object whose proto is the callee's .prototype.
                auto newObj = makeObject();
                if (calleeValue.kind == JsKind.func)
                {
                    auto protoVal = calleeValue.obj.get("prototype");
                    if (protoVal.kind == JsKind.object || protoVal.kind == JsKind.array)
                        newObj.obj.proto = protoVal.obj;
                }
                auto result = callFunction(calleeValue, newObj, args);
                // If the constructor returned an object, use it; else the new object.
                if (result.kind == JsKind.object || result.kind == JsKind.array ||
                    result.kind == JsKind.func)
                    return result;
                return newObj;
            }
        }
    }

    /// Execute a try statement's body and catch. Kept in a separate method
    /// because DMD mishandles exception regions when `try/catch` and a
    /// `throw` share the same `switch` statement inside one function.
    private void execTryBody(Node node, ref JsScope sc, JsValue thisValue)
    {
        try
        {
            execNode(node.children[0], sc, thisValue);
        }
        catch (JsThrowException)
        {
            if (node.children.length >= 2)
            {
                auto catchScope = new JsScope("catch", sc);
                catchScope.declare(node.name, pendingException);
                execNode(node.children[1], catchScope, thisValue);
            }
            lastHadException = false;
        }
    }

    /// Resolve a call target (function value) and invoke it.
    JsValue callFunction(JsValue callee, JsValue thisArg, JsValue[] args)
    {
        if (callee.kind == JsKind.func)
        {
            if (callee.nativeFunc !is null)
            {
                auto rt = this;
                return callee.nativeFunc(thisArg, args, rt);
            }
            auto sf = callee.scriptFunc;
            // On resume after await, reuse the suspended scope so variables
            // declared before the await keep their values.
            JsScope fnScope;
            if (_activeResume !is null)
                fnScope = _activeResume.sc;
            else
                fnScope = new JsScope("function", sf.closure);
            foreach (i, param; sf.params)
            {
                fnScope.declare(param, i < args.length ? args[i] : makeUndefined());
            }
            // Define arguments object.
            auto argumentsObj = makeArray();
            foreach (i, arg; args) argumentsObj.obj.set(to!string(i), arg);
            argumentsObj.obj.arrayLength = args.length;
            fnScope.declare("arguments", argumentsObj);
            // Hoist var declarations in the body (skip on await-resume; the
            // scope already holds the suspended values).
            if (_activeResume is null)
                hoistVars(sf.bodyNode, fnScope);
            // Declare the function name for recursion.
            bool wasReturning = returned;
            JsValue wasReturnValue = returnValue;
            returned = false;
            returnValue = makeUndefined();
            // Arrow functions use the captured lexical `this`.
            JsValue effectiveThis = thisArg;
            if (sf.isArrow)
            {
                auto lit = "__arrow_this" in sf.closure.vars;
                if (lit !is null) effectiveThis = *lit;
            }
            // Async functions: expose the body for await-resume re-entry, and
            // run the body under the active resume frame when resuming.
            JsValue savedAsyncBody = _currentAsyncBody;
            if (sf.isAsync)
                _currentAsyncBody = callee;
            AwaitFrame* savedResume = _activeResume;
            bool wasAwaitPending = _awaitPending;
            _awaitPending = false;
            execNode(sf.bodyNode, fnScope, effectiveThis);
            // If the body suspended on an await, the result promise resolves
            // later via the resume microtask.
            const suspended = _awaitPending;
            _activeResume = savedResume;
            _currentAsyncBody = savedAsyncBody;
            if (!suspended)
                _awaitPending = wasAwaitPending;
            JsValue result = makeUndefined();
            if (returned)
            {
                result = returnValue;
            }
            returned = wasReturning;
            returnValue = wasReturnValue;
            // Async functions wrap their result in a resolved Promise.
            if (sf.isAsync)
            {
                result = resolvePromise(result);
            }
            return result;
        }
        // Not callable
        return makeUndefined();
    }

    /// Create a resolved promise with the given value.
    JsValue resolvePromise(JsValue value)
    {
        auto p = makePromiseObj();
        p.obj.set("__state", makeString("resolved"));
        p.obj.set("__value", value);
        // Run any queued then continuations.
        return p;
    }

    /// Create a new Promise object wrapper.
    JsValue makePromiseObj()
    {
        auto obj = new JsObject();
        obj.kind = "Promise";
        obj.set("__isPromise", makeBoolean(true));
        obj.set("__state", makeString("pending"));
        obj.set("__value", makeUndefined());
        obj.set("__thens", makeArray());
        obj.proto = promiseProto;
        return JsValue(JsKind.object, obj);
    }

    /// Best-effort await: if the promise is already resolved, return value;
    /// otherwise register a continuation microtask and return undefined.
    private JsValue awaitPromise(JsValue promise, ref JsScope sc, JsValue thisValue, Node awaitNode)
    {
        auto state = promise.obj.get("__state");
        if (state.kind == JsKind.string && state.strValue == "resolved")
            return promise.obj.get("__value");
        // Not yet resolved: return undefined (the continuation resumes via the
        // promise's then handlers, which re-enter the body).
        return makeUndefined();
    }

    /// Read the current value of an assignment target (identifier or member).
    private JsValue readTarget(Node target, ref JsScope sc, JsValue thisValue)
    {
        if (target.kind == NodeKind.identifier)
            return sc.get(target.name);
        if (target.kind == NodeKind.member)
        {
            auto objValue = execNode(target.children[0], sc, thisValue);
            if (target.children.length > 1)
                return getProp(objValue, execNode(target.children[1], sc, thisValue));
            return getProp(objValue, makeString(target.name));
        }
        return makeUndefined();
    }

    /// Write a value to an assignment target, returning the written value.
    private JsValue assignToTarget(Node target, JsValue value, ref JsScope sc, JsValue thisValue)
    {
        if (target.kind == NodeKind.identifier)
        {
            const name = target.name;
            if (!sc.has(name)) sc.declare(name, value);
            else sc.set(name, value);
            return value;
        }
        if (target.kind == NodeKind.member)
        {
            auto objValue = execNode(target.children[0], sc, thisValue);
            if (target.children.length > 1)
                setProp(objValue, execNode(target.children[1], sc, thisValue), value);
            else setProp(objValue, makeString(target.name), value);
            return value;
        }
        return value;
    }

    private string typeOfString(JsValue value)
    {
        switch (value.kind)
        {
            case JsKind.undefined: return "undefined";
            case JsKind.nullValue: return "object";
            case JsKind.boolean: return "boolean";
            case JsKind.number: return "number";
            case JsKind.string: return "string";
            case JsKind.func: return "function";
            case JsKind.object: return "object";
            case JsKind.array: return "object";
            default: return "unknown";
        }
    }

    private JsValue applyBinary(string op, JsValue left, JsValue right)
    {
        switch (op)
        {
            case "+":
                // String concatenation if either is a string.
                if (left.kind == JsKind.string || right.kind == JsKind.string)
                    return makeString(toJsString(left) ~ toJsString(right));
                return makeNumber(toNumber(left) + toNumber(right));
            case "-": return makeNumber(toNumber(left) - toNumber(right));
            case "*": return makeNumber(toNumber(left) * toNumber(right));
            case "/": { auto r = toNumber(right); return r == 0 ? makeNumber(double.infinity) : makeNumber(toNumber(left) / r); }
            case "%": return makeNumber(cast(double) (cast(long) toNumber(left) % cast(long) toNumber(right)));
            case "<": return makeBoolean(relationalCompare(left, right) == -1);
            case ">": return makeBoolean(relationalCompare(left, right) == 1);
            case "<=": return makeBoolean(relationalCompare(left, right) != 1);
            case ">=": return makeBoolean(relationalCompare(left, right) != -1);
            case "==": return makeBoolean(looseEquals(left, right));
            case "===": return makeBoolean(strictEquals(left, right));
            case "!=": return makeBoolean(!looseEquals(left, right));
            case "!==": return makeBoolean(!strictEquals(left, right));
            case "&": return makeNumber(cast(double) (cast(long) toNumber(left) & cast(long) toNumber(right)));
            case "|": return makeNumber(cast(double) (cast(long) toNumber(left) | cast(long) toNumber(right)));
            case "^": return makeNumber(cast(double) (cast(long) toNumber(left) ^ cast(long) toNumber(right)));
            case "<<": return makeNumber(cast(double) (cast(long) toNumber(left) << cast(long) toNumber(right)));
            case ">>": return makeNumber(cast(double) (cast(long) toNumber(left) >> cast(long) toNumber(right)));
            case "instanceof": return makeBoolean(instanceOf(left, right));
            default: return makeUndefined();
        }
    }

    /// Relational comparison: -1 (a<b), 0 (equal), 1 (a>b). Strings compare
    /// lexically when both operands are strings; otherwise numeric.
    private int relationalCompare(JsValue left, JsValue right)
    {
        if (left.kind == JsKind.string && right.kind == JsKind.string)
        {
            if (left.strValue < right.strValue) return -1;
            if (left.strValue > right.strValue) return 1;
            return 0;
        }
        auto l = toNumber(left);
        auto r = toNumber(right);
        if (l == r) return 0;
        return l < r ? -1 : 1;
    }

    private bool looseEquals(JsValue left, JsValue right)
    {
        if (left.kind == right.kind)
        {
            switch (left.kind)
            {
                case JsKind.boolean: return left.boolValue == right.boolValue;
                // NaN never equals itself.
                case JsKind.number: return !isNaN(left.numValue) && left.numValue == right.numValue;
                case JsKind.string: return left.strValue == right.strValue;
                case JsKind.undefined: return right.kind == JsKind.undefined;
                case JsKind.nullValue: return right.kind == JsKind.nullValue;
                case JsKind.object, JsKind.array, JsKind.func:
                    return left.obj is right.obj;
                default: return false;
            }
        }
        // null == undefined
        if ((left.kind == JsKind.nullValue && right.kind == JsKind.undefined) ||
            (left.kind == JsKind.undefined && right.kind == JsKind.nullValue))
            return true;
        // ToPrimitive for arrays: "1" ~ "" is already handled for strings.
        // A string against null/undefined is never equal.
        if (left.kind == JsKind.string && (right.kind == JsKind.nullValue || right.kind == JsKind.undefined))
            return false;
        if (right.kind == JsKind.string && (left.kind == JsKind.nullValue || left.kind == JsKind.undefined))
            return false;
        // null/undefined never equal anything else (incl. false/0).
        if (left.kind == JsKind.nullValue || left.kind == JsKind.undefined) return false;
        if (right.kind == JsKind.nullValue || right.kind == JsKind.undefined) return false;
        // Coerce arrays/objects via ToPrimitive -> number/string.
        if (left.kind == JsKind.array) return looseEquals(makeString(arrayToString(left)), right);
        if (right.kind == JsKind.array) return looseEquals(left, makeString(arrayToString(right)));
        if (left.kind == JsKind.boolean) return looseEquals(makeNumber(left.boolValue ? 1 : 0), right);
        if (right.kind == JsKind.boolean) return looseEquals(left, makeNumber(right.boolValue ? 1 : 0));
        if (left.kind == JsKind.number && right.kind == JsKind.string)
            return left.numValue == parseStringNumber(right.strValue);
        if (left.kind == JsKind.string && right.kind == JsKind.number)
            return parseStringNumber(left.strValue) == right.numValue;
        // Object vs number/string: no further coercion in this subset.
        return false;
    }

    /// Number() coercion: full string forms (whitespace, sign, Infinity, NaN,
    /// hex), plus array ToPrimitive via join.
    private double toNumber(JsValue value)
    {
        switch (value.kind)
        {
            case JsKind.number: return value.numValue;
            case JsKind.boolean: return value.boolValue ? 1.0 : 0.0;
            case JsKind.nullValue: return 0.0;
            case JsKind.undefined: return double.nan;
            case JsKind.string: return parseStringNumber(value.strValue);
            case JsKind.array:
            {
                auto s = arrayToString(value);
                if (s.length == 0) return 0.0;
                return parseStringNumber(s);
            }
            case JsKind.object: return double.nan;
            case JsKind.func: return double.nan;
            default: return double.nan;
        }
    }

    private double parseStringNumber(string s)
    {
        size_t i = 0;
        const n = s.length;
        // Skip leading whitespace.
        while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
        // Optional sign.
        bool neg = false;
        bool sawSign = false;
        if (i < n && (s[i] == '+' || s[i] == '-'))
        {
            neg = s[i] == '-';
            sawSign = true;
            i++;
        }
        // Skip whitespace between sign and the number body.
        while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
        // Empty string (after whitespace) -> 0 (JS: Number("") === 0), but a
        // bare sign with no body is NaN.
        if (i >= n) return sawSign ? double.nan : 0.0;
        // Infinity / NaN literals.
        if (i + 7 < n && s[i] == 'I' && s[i .. i + 8] == "Infinity") return neg ? -double.infinity : double.infinity;
        if (i + 2 < n && s[i] == 'N' && s[i .. i + 3] == "NaN") return double.nan;
        // Hex.
        if (i + 1 < n && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X'))
        {
            i += 2;
            double hex = 0;
            bool hexStarted = false;
            long digitValue(char c)
            {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                if (c >= 'A' && c <= 'F') return c - 'A' + 10;
                return -1;
            }
            while (i < n)
            {
                auto d = digitValue(s[i]);
                if (d < 0) break;
                hex = hex * 16 + cast(double) d;
                hexStarted = true;
                i++;
            }
            if (!hexStarted) return double.nan;
            return neg ? -hex : hex;
        }
        double result = 0;
        bool started = false;
        bool dot = false;
        double scale = 0.1;
        bool exponent = false;
        bool expStarted = false;
        long expValue = 0;
        bool expNeg = false;
        for (; i < n; i++)
        {
            auto ch = s[i];
            if (ch >= '0' && ch <= '9')
            {
                if (exponent) { expValue = expValue * 10 + (ch - '0'); expStarted = true; }
                else if (dot) { result += (ch - '0') * scale; scale *= 0.1; }
                else result = result * 10 + (ch - '0');
                started = true;
            }
            else if (ch == '.' && !dot && !exponent) dot = true;
            else if ((ch == 'e' || ch == 'E') && started && !exponent)
            {
                exponent = true;
                // Optional exponent sign.
                if (i + 1 < n && (s[i + 1] == '+' || s[i + 1] == '-'))
                {
                    expNeg = s[i + 1] == '-';
                    i++;
                }
            }
            else break;
        }
        if (!started) return double.nan;
        if (exponent && !expStarted) return double.nan;
        if (exponent) result *= pow10(expNeg ? -expValue : expValue);
        return neg ? -result : result;
    }

    /// 10^n as a double, for parsing exponents.
    private double pow10(long e)
    {
        double r = 1.0;
        long n = e < 0 ? -e : e;
        for (long i = 0; i < n; i++) r *= 10.0;
        return e < 0 ? 1.0 / r : r;
    }

    private bool strictEquals(JsValue left, JsValue right)
    {
        if (left.kind != right.kind) return false;
        switch (left.kind)
        {
            case JsKind.boolean: return left.boolValue == right.boolValue;
            // NaN never equals itself.
            case JsKind.number: return !isNaN(left.numValue) && left.numValue == right.numValue;
            case JsKind.string: return left.strValue == right.strValue;
            case JsKind.undefined: return true;
            case JsKind.nullValue: return true;
            case JsKind.object, JsKind.array, JsKind.func:
                return left.obj is right.obj;
            default: return false;
        }
    }

    private bool instanceOf(JsValue left, JsValue right)
    {
        if (right.kind != JsKind.func) return false;
        auto protoVal = right.obj.get("prototype");
        if (protoVal.kind != JsKind.object && protoVal.kind != JsKind.array) return false;
        // Walk the proto chain of left.
        JsObject cur = left.kind == JsKind.object || left.kind == JsKind.array ||
            left.kind == JsKind.func ? left.obj : null;
        while (cur !is null)
        {
            if (cur is protoVal.obj) return true;
            cur = cur.proto;
        }
        return false;
    }
}

/// Exception used to unwind on throw.
final class JsThrowException : Exception
{
    this() { super("js-throw"); }
}

// --- Parser and lexer ---

/// Lexer produces a list of tokens.
enum TokKind
{
    number,
    string,
    templateLit,
    identifier,
    keyword,
    punctuation,
    op,
    eof
}

struct Token
{
    TokKind kind;
    string text;
    double numValue;
}

/// The parser builds a JsRuntime containing AST nodes.
JsRuntime parseScript(string source)
{
    auto rt = new JsRuntime();
    auto parser = Parser(source, rt);
    parser.parseProgram();
    return rt;
}
/// Internal parser class.
private struct Parser
{
    string source;
    JsRuntime rt;
    Token[] tokens;
    size_t pos;

    this(string source, JsRuntime rt)
    {
        this.source = source;
        this.rt = rt;
        tokens = lex(source);
    }

    void parseProgram()
    {
        auto programNode = addNode(NodeKind.program);
        while (pos < tokens.length && tokens[pos].kind != TokKind.eof)
            programNode.children ~= parseStatement();
    }

    // Helpers
    Node addNode(NodeKind kind)
    {
        auto node = new Node(kind);
        node.order = _orderCounter++;
        rt.nodes ~= node;
        return node;
    }

    private ulong _orderCounter = 1;

    Node nodeAt(size_t idx) { return rt.nodes[idx]; }

    Token current() { return pos < tokens.length ? tokens[pos] : Token(TokKind.eof, "", 0); }

    bool at(string text) { return current().kind != TokKind.eof && current().text == text; }

    bool atKeyword(string kw) { return current().kind == TokKind.keyword && current().text == kw; }

    bool atIdentifier() { return current().kind == TokKind.identifier; }

    void advance() { if (pos < tokens.length) pos++; }

    bool match(string text)
    {
        if (at(text)) { advance(); return true; }
        return false;
    }

    bool matchKeyword(string kw)
    {
        if (atKeyword(kw)) { advance(); return true; }
        return false;
    }

    void expect(string text)
    {
        if (!match(text)) throw new Exception("Expected '" ~ text ~ "'");
    }

    void expectKeyword(string kw)
    {
        if (!matchKeyword(kw)) throw new Exception("Expected '" ~ kw ~ "'");
    }

    JsValue makeLiteralFromToken(Token t)
    {
        if (t.kind == TokKind.number) return rt.makeNumber(t.numValue);
        if (t.kind == TokKind.string) return rt.makeString(t.text);
        return rt.makeUndefined();
    }

    // --- Statements ---
    Node parseStatement()
    {
        if (atKeyword("async") && tokens.length > pos + 1 &&
            tokens[pos + 1].kind == TokKind.keyword && tokens[pos + 1].text == "function")
            return parseAsyncFunctionDecl();
        if (atKeyword("var") || atKeyword("let") || atKeyword("const"))
            return parseVarDecl();
        if (atKeyword("function"))
            return parseFunctionDecl();
        if (atKeyword("if"))
            return parseIf();
        if (atKeyword("while"))
            return parseWhile();
        if (atKeyword("for"))
            return parseFor();
        if (atKeyword("return"))
            return parseReturn();
        if (atKeyword("throw"))
            return parseThrow();
        if (atKeyword("try"))
            return parseTry();
        if (at("{"))
            return parseBlock();
        if (at(";"))
        {
            advance();
            auto node = addNode(NodeKind.block);
            return node;
        }
        // Expression statement
        auto expr = parseExpression();
        auto node = addNode(NodeKind.exprStmt);
        node.children ~= expr;
        match(";");
        return node;
    }

    Node parseBlock()
    {
        auto node = addNode(NodeKind.block);
        expect("{");
        while (!at("}") && current().kind != TokKind.eof)
            node.children ~= parseStatement();
        match("}");
        return node;
    }

    Node parseVarDecl()
    {
        const kw = current().text;
        advance(); // var/let/const
        auto node = addNode(NodeKind.varDecl);
        // `let` and `const` are block-scoped (node.boolValue = true). `var` is
        // function-scoped. const is treated as a let binding for now.
        node.boolValue = (kw == "let" || kw == "const");
        while (true)
        {
            if (!atIdentifier()) break;
            auto name = current().text;
            advance();
            node.names ~= name;
            if (match("="))
                node.children ~= parseAssignmentExpression();
            if (!match(",")) break;
        }
        match(";");
        return node;
    }

    Node parseFunctionDecl()
    {
        expectKeyword("function");
        if (!atIdentifier()) throw new Exception("Expected function name");
        auto name = current().text;
        advance();
        auto params = parseParams();
        auto body = parseBlock();
        auto node = addNode(NodeKind.functionDecl);
        node.name = name;
        node.params = params;
        node.children ~= body;
        return node;
    }

    /// async function name(params) { body } — parsed as a normal function decl
    /// marked async; the interpreter wraps its result in a Promise.
    Node parseAsyncFunctionDecl()
    {
        advance(); // async
        expectKeyword("function");
        if (!atIdentifier()) throw new Exception("Expected function name");
        auto name = current().text;
        advance();
        auto params = parseParams();
        auto body = parseBlock();
        auto node = addNode(NodeKind.functionDecl);
        node.name = name;
        node.params = params;
        node.boolValue = true;  // async flag
        node.children ~= body;
        return node;
    }

    string[] parseParams()
    {
        string[] params;
        expect("(");
        while (!at(")") && current().kind != TokKind.eof)
        {
            if (atIdentifier()) { params ~= current().text; advance(); }
            else break;
            if (!match(",")) break;
        }
        expect(")");
        return params;
    }

    Node parseIf()
    {
        auto node = addNode(NodeKind.ifStmt);
        expectKeyword("if");
        expect("(");
        node.children ~= parseExpression();
        expect(")");
        node.children ~= parseStatement();
        if (matchKeyword("else"))
            node.children ~= parseStatement();
        return node;
    }

    Node parseWhile()
    {
        auto node = addNode(NodeKind.whileStmt);
        expectKeyword("while");
        expect("(");
        node.children ~= parseExpression();
        expect(")");
        node.children ~= parseStatement();
        return node;
    }

    Node parseFor()
    {
        expectKeyword("for");
        auto node = addNode(NodeKind.forStmt);
        expect("(");

        // for (var x in obj) — special case.
        if ((atKeyword("var") || atKeyword("let") || atKeyword("const")) && tokenIsForInOf())
        {
            const kw = current().text;
            advance();
            auto name = current().text;
            advance();
            // `of` is a contextual keyword lexed as an identifier.
            const forOf = atIdentifier() && current().text == "of";
            if (forOf) advance();
            if (!forOf) expectKeyword("in");
            node.kind = forOf ? NodeKind.forOfStmt : NodeKind.forInStmt;
            node.name = name;
            node.boolValue = (kw == "let" || kw == "const");
            node.children ~= addNode(NodeKind.block); // body placeholder
            node.children ~= parseExpression();
            expect(")");
            // Body
            auto body = parseStatement();
            node.children[0] = body;
            return node;
        }

        // for (init; test; update)
        Node init;
        if (atKeyword("var") || atKeyword("let") || atKeyword("const"))
        {
            const kw = current().text;
            advance();
            auto varNode = addNode(NodeKind.varDecl);
            varNode.boolValue = (kw == "let" || kw == "const");
            while (true)
            {
                if (!atIdentifier()) break;
                auto name = current().text;
                advance();
                varNode.names ~= name;
                if (match("="))
                    varNode.children ~= parseAssignmentExpression();
                if (!match(",")) break;
            }
            init = varNode;
            match(";");
        }
        else if (!at(";"))
        {
            init = parseExpression();
            match(";");
        }
        else
        {
            match(";");
            init = addNode(NodeKind.block);
        }

        Node test;
        if (!at(";"))
            test = parseExpression();
        else test = addTrueLit();
        match(";");

        Node update = addNode(NodeKind.block);
        if (!at(")"))
            update = parseExpression();
        expect(")");

        auto body = parseStatement();

        node.children ~= init;
        node.children ~= test;
        node.children ~= update;
        node.children ~= body;
        return node;
    }

    private bool tokenIsForInOf()
    {
        // Look ahead: var <name> in|of
        if (pos + 2 >= tokens.length) return false;
        if (tokens[pos + 1].kind != TokKind.identifier) return false;
        if (tokens[pos + 2].kind == TokKind.keyword && tokens[pos + 2].text == "in") return true;
        return tokens[pos + 2].kind == TokKind.identifier && tokens[pos + 2].text == "of";
    }

    private Node addTrueLit()
    {
        auto node = addNode(NodeKind.boolLit);
        node.boolValue = true;
        return node;
    }

    Node parseReturn()
    {
        expectKeyword("return");
        auto node = addNode(NodeKind.returnStmt);
        if (!at(";") && current().kind != TokKind.eof && !at("}"))
            node.children ~= parseExpression();
        match(";");
        return node;
    }

    Node parseThrow()
    {
        expectKeyword("throw");
        auto node = addNode(NodeKind.throwStmt);
        node.children ~= parseExpression();
        match(";");
        return node;
    }

    Node parseTry()
    {
        expectKeyword("try");
        auto node = addNode(NodeKind.tryStmt);
        node.children ~= parseBlock();
        if (matchKeyword("catch"))
        {
            expect("(");
            if (atIdentifier()) { node.name = current().text; advance(); }
            expect(")");
            node.children ~= parseBlock();
        }
        return node;
    }

    // --- Expressions ---
    Node parseExpression()
    {
        return parseAssignment();
    }

    Node parseAssignmentExpression() { return parseAssignment(); }

    Node parseAssignment()
    {
        auto left = parseTernary();
        if (at("=") || at("+=") || at("-=") || at("*=") || at("/=") || at("%=") ||
            at("&=") || at("|=") || at("^="))
        {
            auto op = current().text;
            advance();
            auto value = parseAssignment();
            // Fold += etc into assignment with compound op recorded on the node.
            auto node = addNode(NodeKind.assign);
            node.op = op;
            node.children ~= left;
            node.children ~= value;
            return node;
        }
        return left;
    }

    Node parseTernary()
    {
        auto test = parseLogical();
        if (match("?"))
        {
            auto thenNode = parseAssignment();
            expect(":");
            auto elseNode = parseAssignment();
            auto node = addNode(NodeKind.ternary);
            node.children ~= test;
            node.children ~= thenNode;
            node.children ~= elseNode;
            return node;
        }
        return test;
    }

    Node parseLogical()
    {
        auto left = parseEquality();
        while (true)
        {
            if (match("&&") || match("||"))
            {
                auto op = tokens[pos - 1].text;
                auto right = parseEquality();
                auto node = addNode(NodeKind.logical);
                node.op = op;
                node.children ~= left;
                node.children ~= right;
                left = node;
            }
            else break;
        }
        return left;
    }

    Node parseEquality()
    {
        auto left = parseRelational();
        while (true)
        {
            if (at("==") || at("===") || at("!=") || at("!=="))
            {
                auto op = current().text;
                advance();
                auto right = parseRelational();
                auto node = addNode(NodeKind.binary);
                node.op = op;
                node.children ~= left;
                node.children ~= right;
                left = node;
            }
            else break;
        }
        return left;
    }

    Node parseRelational()
    {
        auto left = parseAdditive();
        while (true)
        {
            if (at("<") || at(">") || at("<=") || at(">=") || atKeyword("instanceof"))
            {
                auto op = current().text;
                advance();
                auto right = parseAdditive();
                auto node = addNode(NodeKind.binary);
                node.op = op;
                node.children ~= left;
                node.children ~= right;
                left = node;
            }
            else break;
        }
        return left;
    }

    Node parseAdditive()
    {
        auto left = parseMultiplicative();
        while (true)
        {
            if (at("+") || at("-"))
            {
                auto op = current().text;
                advance();
                auto right = parseMultiplicative();
                auto node = addNode(NodeKind.binary);
                node.op = op;
                node.children ~= left;
                node.children ~= right;
                left = node;
            }
            else break;
        }
        return left;
    }

    Node parseMultiplicative()
    {
        auto left = parseUnary();
        while (true)
        {
            if (at("*") || at("/") || at("%"))
            {
                auto op = current().text;
                advance();
                auto right = parseUnary();
                auto node = addNode(NodeKind.binary);
                node.op = op;
                node.children ~= left;
                node.children ~= right;
                left = node;
            }
            else break;
        }
        return left;
    }

    Node parseUnary()
    {
        if (at("!") || at("-") || at("+") || at("typeof"))
        {
            auto op = current().text;
            advance();
            auto operand = parseUnary();
            auto node = addNode(NodeKind.unary);
            node.op = op;
            node.children ~= operand;
            return node;
        }
        if (atKeyword("await"))
        {
            advance();
            auto operand = parseUnary();
            auto node = addNode(NodeKind.awaitExpr);
            node.children ~= operand;
            return node;
        }
        if (at("++") || at("--"))
        {
            auto op = current().text;
            advance();
            auto operand = parseUnary();
            auto node = addNode(NodeKind.update);
            node.op = op;
            node.boolValue = true;  // prefix
            node.children ~= operand;
            return node;
        }
        return parsePostfix();
    }

    Node parsePostfix()
    {
        auto expr = parsePrimary();
        while (true)
        {
            if (at("=>") && expr.kind == NodeKind.identifier)
            {
                // Single-parameter arrow: x => expr.
                advance();
                auto node = addNode(NodeKind.arrow);
                node.params ~= expr.name;
                parseArrowBody(node);
                expr = node;
            }
            if (at("."))
            {
                advance();
                if (!atIdentifier()) break;
                auto name = current().text;
                advance();
                auto node = addNode(NodeKind.member);
                node.children ~= expr;
                node.name = name;
                expr = node;
            }
            else if (at("["))
            {
                advance();
                auto key = parseExpression();
                expect("]");
                auto node = addNode(NodeKind.member);
                node.children ~= expr;
                node.children ~= key;
                expr = node;
            }
            else if (at("("))
            {
                advance();
                auto node = addNode(NodeKind.call);
                node.children ~= expr;
                while (!at(")") && current().kind != TokKind.eof)
                {
                    node.children ~= parseAssignment();
                    if (!match(",")) break;
                }
                expect(")");
                expr = node;
            }
            else if (at("++") || at("--"))
            {
                auto op = current().text;
                advance();
                auto node = addNode(NodeKind.update);
                node.op = op;
                node.boolValue = false;  // postfix
                node.children ~= expr;
                expr = node;
            }
            else break;
        }
        return expr;
    }

    Node parsePrimary()
    {
        auto t = current();
        if (t.kind == TokKind.number || t.kind == TokKind.string)
        {
            advance();
            auto node = addNode(t.kind == TokKind.number ? NodeKind.numberLit : NodeKind.stringLit);
            if (t.kind == TokKind.number) node.numValue = t.numValue;
            else node.strValue = t.text;
            return node;
        }
        if (t.kind == TokKind.templateLit)
        {
            // Split the raw template text on ${...} into string/expression
            // chunks. Expression text is re-lexed and parsed into this
            // runtime's node table.
            advance();
            return parseTemplateLit(t.text);
        }
        if (t.kind == TokKind.keyword)
        {
            if (t.text == "true")
            {
                advance();
                auto node = addNode(NodeKind.boolLit);
                node.boolValue = true;
                return node;
            }
            if (t.text == "false")
            {
                advance();
                auto node = addNode(NodeKind.boolLit);
                node.boolValue = false;
                return node;
            }
            if (t.text == "null")
            {
                advance();
                return addNode(NodeKind.nullLit);
            }
            if (t.text == "this")
            {
                advance();
                return addNode(NodeKind.thisExpr);
            }
            if (t.text == "function")
                return parseFunctionExpr();
            if (t.text == "async" && tokens.length > pos + 1 &&
                tokens[pos + 1].kind == TokKind.keyword && tokens[pos + 1].text == "function")
            {
                advance(); // async
                return parseFunctionExpr();
            }
            if (t.text == "typeof")
            {
                advance();
                auto operand = parseUnary();
                auto node = addNode(NodeKind.unary);
                node.op = "typeof";
                node.children ~= operand;
                return node;
            }
            if (t.text == "new")
            {
                advance();
                auto callee = parsePrimary();
                auto node = addNode(NodeKind.newExpr);
                node.children ~= callee;
                if (at("("))
                {
                    advance();
                    while (!at(")") && current().kind != TokKind.eof)
                    {
                        node.children ~= parseAssignment();
                        if (!match(",")) break;
                    }
                    expect(")");
                }
                return node;
            }
            throw new Exception("Unexpected keyword '" ~ t.text ~ "'");
        }
        if (t.kind == TokKind.identifier)
        {
            advance();
            auto node = addNode(NodeKind.identifier);
            node.name = t.text;
            return node;
        }
        if (at("("))
        {
            // Look ahead: if the matching ')' is directly followed by '=>' this
            // is a parenthesized arrow parameter list, not a group expression.
            if (parenFollowedByArrow())
            {
                auto node = addNode(NodeKind.arrow);
                advance(); // (
                while (!at(")") && current().kind != TokKind.eof)
                {
                    if (atIdentifier()) { node.params ~= current().text; advance(); }
                    else break;
                    if (!match(",")) break;
                }
                expect(")");
                parseArrowBody(node);
                return node;
            }
            advance();
            auto expr = parseExpression();
            expect(")");
            return expr;
        }
        if (at("["))
        {
            advance();
            auto node = addNode(NodeKind.arrayLit);
            while (!at("]") && current().kind != TokKind.eof)
            {
                node.children ~= parseAssignment();
                if (!match(",")) break;
            }
            expect("]");
            return node;
        }
        if (at("{"))
        {
            advance();
            auto node = addNode(NodeKind.objectLit);
            while (!at("}") && current().kind != TokKind.eof)
            {
                if (atIdentifier())
                {
                    auto key = current().text;
                    advance();
                    node.names ~= key;
                    if (match(":"))
                        node.children ~= parseAssignment();
                    else node.children ~= addNode(NodeKind.nullLit);
                }
                if (!match(",")) break;
            }
            expect("}");
            return node;
        }
        if (at("new"))
        {
            advance();
            auto callee = parsePrimary();
            auto node = addNode(NodeKind.newExpr);
            node.children ~= callee;
            if (at("("))
            {
                advance();
                while (!at(")") && current().kind != TokKind.eof)
                {
                    node.children ~= parseAssignment();
                    if (!match(",")) break;
                }
                expect(")");
            }
            return node;
        }
        if (at("function"))
            return parseFunctionExpr();
        throw new Exception("Unexpected token '" ~ t.text ~ "'");
    }

    Node parseFunctionExpr()
    {
        expectKeyword("function");
        string name;
        if (atIdentifier()) { name = current().text; advance(); }
        auto params = parseParams();
        auto body = parseBlock();
        // Function expression returns a function value; store as a functionDecl-style node
        // but we return an expression: use a temporary variable trick: create functionDecl
        // named, then reference it. For simplicity, we create a function value node directly.
        auto node = addNode(NodeKind.functionDecl);
        node.name = name;
        node.params = params;
        node.children ~= body;
        return node;
    }

    /// Consume the arrow body: `=> expr` (expression body, boolValue=false) or
    /// `=> { ... }` (block body, boolValue=true).
    void parseArrowBody(Node node)
    {
        expect("=>");
        if (at("{"))
        {
            auto body = parseBlock();
            node.children ~= body;
            node.boolValue = false; // block body
        }
        else
        {
            auto body = parseAssignment();
            node.children ~= body;
            node.boolValue = true;  // expression body
        }
    }

    /// Build a template literal node from raw template text. Splits on
    /// `\${`-unescaped `${` boundaries; expression chunks are parsed as
    /// sub-programs into this runtime. Interpolated expressions can be
    /// arbitrary (nested templates, calls, member access).
    Node parseTemplateLit(string raw)
    {
        auto node = addNode(NodeKind.templateLit);
        string literal;
        size_t i = 0;
        const n = raw.length;
        while (i < n)
        {
            if (i + 1 < n && raw[i] == '$' && raw[i + 1] == '{')
            {
                // Close the current literal run.
                node.children ~= addStringLitNode(literal);
                literal = "";
                // Find the matching '}' respecting nesting, strings, and
                // nested template literals.
                auto depth = 1;
                size_t j = i + 2;
                bool inStr = false;
                char strQuote = 0;
                bool inTemplate = false;
                while (j < n && depth > 0)
                {
                    auto ch = raw[j];
                    if (inStr)
                    {
                        if (ch == '\\') { j += 2; continue; }
                        if (ch == strQuote) inStr = false;
                        j++;
                        continue;
                    }
                    if (inTemplate)
                    {
                        if (ch == '\\') { j += 2; continue; }
                        if (ch == '`') inTemplate = false;
                        else if (ch == '$' && j + 1 < n && raw[j + 1] == '{') depth++;
                        j++;
                        continue;
                    }
                    if (ch == '"' || ch == '\'') { inStr = true; strQuote = ch; j++; continue; }
                    if (ch == '`') { inTemplate = true; j++; continue; }
                    if (ch == '{') depth++;
                    else if (ch == '}') { depth--; if (depth == 0) break; }
                    j++;
                }
                auto exprSource = raw[i + 2 .. j];
                auto exprNode = parseInlineExpression(exprSource);
                node.children ~= exprNode;
                i = j + 1;
            }
            else
            {
                literal ~= raw[i];
                i++;
            }
        }
        node.children ~= addStringLitNode(literal);
        return node;
    }

    private Node addStringLitNode(string s)
    {
        auto n = addNode(NodeKind.stringLit);
        n.strValue = s;
        return n;
    }

    /// Parse a small expression source (e.g. the content of `${...}`) using a
    /// fresh parser that shares THIS runtime's node table.
    private Node parseInlineExpression(string src)
    {
        if (src.strip().length == 0) return addStringLitNode("");
        auto sub = Parser(src, rt);
        auto expr = sub.parseExpression();
        return expr;
    }

    /// True when the ')' that closes the '(' at the current position is
    /// immediately followed by '=>'.
    private bool parenFollowedByArrow()
    {
        auto depth = 1;
        for (size_t k = pos + 1; k < tokens.length; k++)
        {
            if (tokens[k].kind == TokKind.eof) return false;
            if (tokens[k].kind == TokKind.op && tokens[k].text == "(") depth++;
            else if (tokens[k].kind == TokKind.op && tokens[k].text == ")")
            {
                depth--;
                if (depth == 0)
                {
                    if (k + 1 < tokens.length && tokens[k + 1].kind == TokKind.op &&
                        tokens[k + 1].text == "=>")
                        return true;
                    return false;
                }
            }
        }
        return false;
    }
}

/// Lexer: tokenize JS source.
private Token[] lex(string source)
{
    Token[] tokens;
    size_t i = 0;
    const n = source.length;
    bool isDigit(char c) { return c >= '0' && c <= '9'; }
    bool isIdentStart(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$'; }
    bool isIdentChar(char c) { return isIdentStart(c) || isDigit(c); }

    // Keywords
    string[string] keywords;
    foreach (kw; ["var","let","const","function","if","else","while","for","in",
        "return","throw","try","catch","new","typeof","true","false","null","this",
        "instanceof","async","await"])
        keywords[kw] = kw;

    while (i < n)
    {
        auto c = source[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; continue; }
        if (c == '/' && i + 1 < n && source[i + 1] == '/')
        {
            while (i < n && source[i] != '\n') i++;
            continue;
        }
        if (c == '/' && i + 1 < n && source[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < n && !(source[i] == '*' && source[i + 1] == '/')) i++;
            i += 2;
            continue;
        }
        if (isDigit(c))
        {
            auto start = i;
            bool dot = false;
            while (i < n && (isDigit(source[i]) || (source[i] == '.' && !dot)))
            {
                if (source[i] == '.') dot = true;
                i++;
            }
            tokens ~= Token(TokKind.number, source[start .. i], to!double(source[start .. i]));
            continue;
        }
        if (isIdentStart(c))
        {
            auto start = i;
            while (i < n && isIdentChar(source[i])) i++;
            auto word = source[start .. i];
            if (word in keywords)
                tokens ~= Token(TokKind.keyword, word, 0);
            else
                tokens ~= Token(TokKind.identifier, word, 0);
            continue;
        }
        if (c == '"' || c == '\'')
        {
            auto quote = c;
            auto start = i;
            i++;
            auto buf = appender!string;
            while (i < n)
            {
                if (source[i] == quote) { i++; break; }
                if (source[i] == '\\' && i + 1 < n)
                {
                    i++;
                    auto esc = source[i];
                    switch (esc)
                    {
                        case 'n': buf.put('\n'); break;
                        case 't': buf.put('\t'); break;
                        case 'r': buf.put('\r'); break;
                        case '\\': buf.put('\\'); break;
                        case '\'': buf.put('\''); break;
                        case '"': buf.put('"'); break;
                        default: buf.put(esc); break;
                    }
                    i++;
                }
                else { buf.put(source[i]); i++; }
            }
            tokens ~= Token(TokKind.string, buf.data, 0);
            continue;
        }
        if (c == '`')
        {
            // Template literal. Text outside `${...}` is escape-processed;
            // interpolation text is kept verbatim (it is re-lexed by the
            // parser). Nesting of braces/strings/backticks inside `${...}` is
            // tracked so the outer template's closing backtick is found.
            auto start = i;
            i++;
            auto buf = appender!string;
            auto depth = 0;          // `${` nesting level
            bool inStr = false;
            char strQuote = 0;
            while (i < n)
            {
                if (depth == 0)
                {
                    if (source[i] == '`') { i++; break; }
                    if (source[i] == '\\' && i + 1 < n)
                    {
                        auto esc = source[i + 1];
                        if (esc == '`' || esc == '$' || esc == '\\')
                        {
                            buf.put(esc);
                            i += 2;
                            continue;
                        }
                        i++;
                        switch (esc)
                        {
                            case 'n': buf.put('\n'); break;
                            case 't': buf.put('\t'); break;
                            case 'r': buf.put('\r'); break;
                            case '\\': buf.put('\\'); break;
                            default: buf.put('\\'); buf.put(esc); break;
                        }
                        i++;
                        continue;
                    }
                    if (source[i] == '$' && i + 1 < n && source[i + 1] == '{')
                    {
                        depth++;
                        buf.put(source[i]);
                        buf.put(source[i + 1]);
                        i += 2;
                        continue;
                    }
                    buf.put(source[i]);
                    i++;
                    continue;
                }
                // Inside ${...}: copy verbatim, track structure.
                if (inStr)
                {
                    if (source[i] == '\\' && i + 1 < n) { buf.put(source[i]); buf.put(source[i + 1]); i += 2; continue; }
                    if (source[i] == strQuote) inStr = false;
                    buf.put(source[i]);
                    i++;
                    continue;
                }
                if (source[i] == '"' || source[i] == '\'')
                {
                    inStr = true;
                    strQuote = source[i];
                    buf.put(source[i]);
                    i++;
                    continue;
                }
                if (source[i] == '{') { depth++; buf.put(source[i]); i++; continue; }
                if (source[i] == '}')
                {
                    depth--;
                    buf.put(source[i]);
                    i++;
                    continue;
                }
                if (source[i] == '`')
                {
                    // Nested template inside interpolation: find its closing
                    // backtick, copying verbatim.
                    buf.put(source[i]);
                    i++;
                    while (i < n)
                    {
                        if (source[i] == '\\' && i + 1 < n) { buf.put(source[i]); buf.put(source[i + 1]); i += 2; continue; }
                        buf.put(source[i]);
                        if (source[i] == '`') { i++; break; }
                        i++;
                    }
                    continue;
                }
                buf.put(source[i]);
                i++;
            }
            tokens ~= Token(TokKind.templateLit, buf.data, 0);
            continue;
        }
        // Multi-char operators
        if (c == '=' && i + 1 < n && source[i + 1] == '>')
        { tokens ~= Token(TokKind.op, "=>", 0); i += 2; continue; }
        if (c == '=' && i + 1 < n && source[i + 1] == '=')
        {
            if (i + 2 < n && source[i + 2] == '=') { tokens ~= Token(TokKind.op, "===", 0); i += 3; continue; }
            tokens ~= Token(TokKind.op, "==", 0); i += 2; continue;
        }
        if (c == '!' && i + 1 < n && source[i + 1] == '=')
        {
            if (i + 2 < n && source[i + 2] == '=') { tokens ~= Token(TokKind.op, "!==", 0); i += 3; continue; }
            tokens ~= Token(TokKind.op, "!=", 0); i += 2; continue;
        }
        if (c == '<' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "<=", 0); i += 2; continue; }
        if (c == '>' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, ">=", 0); i += 2; continue; }
        if (c == '&' && i + 1 < n && source[i + 1] == '&')
        { tokens ~= Token(TokKind.op, "&&", 0); i += 2; continue; }
        if (c == '|' && i + 1 < n && source[i + 1] == '|')
        { tokens ~= Token(TokKind.op, "||", 0); i += 2; continue; }
        if (c == '+' && i + 1 < n && source[i + 1] == '+')
        { tokens ~= Token(TokKind.op, "++", 0); i += 2; continue; }
        if (c == '-' && i + 1 < n && source[i + 1] == '-')
        { tokens ~= Token(TokKind.op, "--", 0); i += 2; continue; }
        if (c == '+' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "+=", 0); i += 2; continue; }
        if (c == '-' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "-=", 0); i += 2; continue; }
        if (c == '*' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "*=", 0); i += 2; continue; }
        if (c == '/' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "/=", 0); i += 2; continue; }
        if (c == '%' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "%=", 0); i += 2; continue; }
        if (c == '&' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "&=", 0); i += 2; continue; }
        if (c == '|' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "|=", 0); i += 2; continue; }
        if (c == '^' && i + 1 < n && source[i + 1] == '=')
        { tokens ~= Token(TokKind.op, "^=", 0); i += 2; continue; }
        if (c == '<' && i + 1 < n && source[i + 1] == '<')
        { tokens ~= Token(TokKind.op, "<<", 0); i += 2; continue; }
        if (c == '>' && i + 1 < n && source[i + 1] == '>')
        { tokens ~= Token(TokKind.op, ">>", 0); i += 2; continue; }
        // Single-char tokens
        import std.string : indexOf;
        if (indexOf("{}()[];,:.=+-*/%!<>?&|^", to!string(c)) >= 0)
        {
            tokens ~= Token(TokKind.op, to!string(c), 0);
            i++;
            continue;
        }
        // Unknown char: skip.
        i++;
    }
    tokens ~= Token(TokKind.eof, "", 0);
    return tokens;
}

unittest
{
    auto rt = parseScript(
        `var a = 2; var b = 3; var c = a + b * 2;` ~
        `function square(x) { return x * x; }` ~
        `var d = square(c);` ~
        `var arr = [1, 2, 3]; arr.push(4);` ~
        `var o = { name: "x", val: d };` ~
        `if (d == 64 && arr.length == 4 && o.val == 64) { console.log("ok"); }` ~
        `else { throw "fail"; }`);
    rt.runScript(rt.makeObject());
    auto cVal = rt.globalScope.get("c");
    assert(cVal.kind == JsKind.number && cVal.numValue == 8, "c should be 8");
    auto dVal = rt.globalScope.get("d");
    assert(dVal.kind == JsKind.number && dVal.numValue == 64, "d should be 64");
    auto arrVal = rt.globalScope.get("arr");
    assert(arrVal.obj.arrayLength == 4, "arr.length should be 4");
}

unittest
{
    // Prefix/postfix increment and decrement on identifiers and members.
    auto rt = parseScript(
        `var x = 5;` ~
        `var pre = ++x;` ~
        `var post = x++;` ~
        `var preDec = --x;` ~
        `var postDec = x--;` ~
        `var arr = [10, 20, 30];` ~
        `var arrPre = ++arr[1];` ~
        `var arrPost = arr[1]--;` ~
        `var o = { v: 7 };` ~
        `var memPre = --o.v;` ~
        `var memPost = o.v++;`);
    rt.runScript(rt.makeObject());
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    // x: 5 -> ++x=6, x++->6 (x=7), --x=6, x--->6 (x=5). Final x=5.
    checkNum("x", 5);
    checkNum("pre", 6);
    checkNum("post", 6);
    checkNum("preDec", 6);
    checkNum("postDec", 6);
    // arr[1]: 20 -> ++arr[1]=21 -> arr[1]-- yields 21, leaves 20.
    checkNum("arrPre", 21);
    checkNum("arrPost", 21);
    auto arrVal = rt.globalScope.get("arr");
    assert(arrVal.obj.arrayLength == 3, "arr length should stay 3");
    auto el = arrVal.obj.get("1");
    assert(el.kind == JsKind.number && el.numValue == 20, "arr[1] should be 20 after ops");
    // o.v: 7 -> --o.v=6 -> o.v++ yields 6, leaves 7.
    checkNum("memPre", 6);
    checkNum("memPost", 6);
    auto oVal = rt.globalScope.get("o");
    auto ov = oVal.obj.get("v");
    assert(ov.kind == JsKind.number && ov.numValue == 7, "o.v should be 7 after ops");
}

unittest
{
    // Compound assignment on identifiers and members.
    auto rt = parseScript(
        `var a = 10;` ~
        `a += 5;` ~
        `a -= 3;` ~
        `a *= 2;` ~
        `a /= 4;` ~
        `a %= 3;` ~
        `var b = 5;` ~
        `b &= 3;` ~
        `var c = 5;` ~
        `c |= 2;` ~
        `var d = 5;` ~
        `d ^= 1;` ~
        `var arr = [1, 2, 3];` ~
        `arr[0] += 10;` ~
        `var o = { v: 4 };` ~
        `o.v *= 5;` ~
        `var s = "foo";` ~
        `s += "bar";`);
    rt.runScript(rt.makeObject());
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    // a: 10+5=15, -3=12, *2=24, /4=6, %3=0.
    checkNum("a", 0);
    checkNum("b", 1);  // 5&3 = 1
    checkNum("c", 7);  // 5|2 = 7
    checkNum("d", 4);  // 5^1 = 4
    auto arrVal = rt.globalScope.get("arr");
    auto el0 = arrVal.obj.get("0");
    assert(el0.kind == JsKind.number && el0.numValue == 11, "arr[0] should be 11");
    auto oVal = rt.globalScope.get("o");
    auto ov = oVal.obj.get("v");
    assert(ov.kind == JsKind.number && ov.numValue == 20, "o.v should be 20");
    auto sVal = rt.globalScope.get("s");
    assert(sVal.kind == JsKind.string && sVal.strValue == "foobar", "s should be foobar");
}

unittest
{
    // var hoisting: use before declaration yields undefined, assignment works.
    auto rt = parseScript(
        `var early = log();` ~
        `function log() { return h; }` ~
        `var h = 5;`);
    // Note: function log runs AFTER h is assigned because hoisted h is declared
    // as undefined first, then execution assigns. But log() is called during
    // the `var early = log();` statement which runs before `var h = 5;`.
    rt.runScript(rt.makeObject());
    auto earlyVal = rt.globalScope.get("early");
    assert(earlyVal.kind == JsKind.undefined, "early should be undefined from hoisted h");
    auto hVal = rt.globalScope.get("h");
    assert(hVal.kind == JsKind.number && hVal.numValue == 5, "h should be 5");
}

unittest
{
    // this binding in plain calls vs methods, fn.call/apply.
    auto rt = parseScript(
        `var plainThis = null;` ~
        `function f() { if (plainThis === null) plainThis = this; return this; }` ~
        `var plain = f();` ~
        `var o = { name: "obj", getThis: function() { return this; } };` ~
        `var viaMethod = o.getThis();` ~
        `var callThis = {};` ~
        `callThis.tag = "C";` ~
        `var viaCall = f.call(callThis);` ~
        `function sum(a, b) { return a + b; }` ~
        `var viaApply = sum.apply(callThis, [40, 2]);`);
    rt.runScript(rt.makeObject());
    // Plain call: this must be the global object.
    auto plainThis = rt.globalScope.get("plainThis");
    assert(plainThis.kind == JsKind.object, "globalThis should be an object");
    assert(plainThis.obj is rt.globalObject, "this in plain call should be global object");
    auto viaMethod = rt.globalScope.get("viaMethod");
    assert(viaMethod.kind == JsKind.object && viaMethod.obj is rt.globalScope.get("o").obj,
        "method this should be receiver");
    auto viaCall = rt.globalScope.get("viaCall");
    assert(viaCall.kind == JsKind.object && viaCall.obj is rt.globalScope.get("callThis").obj,
        "fn.call thisArg should be used");
    auto viaApply = rt.globalScope.get("viaApply");
    assert(viaApply.kind == JsKind.number && viaApply.numValue == 42, "apply args should work");
}

unittest
{
    // String methods on primitives.
    auto rt = parseScript(
        `var s = "Hello World";` ~
        `var sl = s.slice(6);` ~
        `var su = s.toUpperCase();` ~
        `var sp = "a,b,c".split(",");` ~
        `var t = "  trim me  ".trim();` ~
        `var idx = "abcdef".indexOf("cd");` ~
        `var ch = s.charAt(1);` ~
        `var cc = s.charCodeAt(0);` ~
        `var sub = s.substring(0, 5);` ~
        `var sw = s.startsWith("Hello");` ~
        `var ew = s.endsWith("World");` ~
        `var inc = s.includes("o W");` ~
        `var rep = "foo foo".replace("foo", "bar");` ~
        `var lc = "ABC".toLowerCase();`);
    rt.runScript(rt.makeObject());
    auto checkStr = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.string && v.strValue == expected, name ~ " wrong: got '" ~ rt.toJsString(v) ~ "' want '" ~ expected ~ "'");
    };
    checkStr("sl", "World");
    checkStr("su", "HELLO WORLD");
    auto sp = rt.globalScope.get("sp");
    assert(sp.kind == JsKind.array && sp.obj.arrayLength == 3, "split should give 3 items");
    checkStr("t", "trim me");
    auto idx = rt.globalScope.get("idx");
    assert(idx.kind == JsKind.number && idx.numValue == 2, "indexOf should be 2");
    checkStr("ch", "e");
    auto cc = rt.globalScope.get("cc");
    assert(cc.kind == JsKind.number && cc.numValue == 72, "charCodeAt H is 72");
    checkStr("sub", "Hello");
    auto sw = rt.globalScope.get("sw");
    assert(sw.kind == JsKind.boolean && sw.boolValue, "startsWith true");
    auto ew = rt.globalScope.get("ew");
    assert(ew.kind == JsKind.boolean && ew.boolValue, "endsWith true");
    auto inc = rt.globalScope.get("inc");
    assert(inc.kind == JsKind.boolean && inc.boolValue, "includes true");
    checkStr("rep", "bar foo");
    checkStr("lc", "abc");
}

unittest
{
    // Array methods.
    auto rt = parseScript(
        `var src = [1, 2, 3, 4];` ~
        `var doubled = src.map(function(x) { return x * 2; });` ~
        `var evens = src.filter(function(x) { return x % 2 == 0; });` ~
        `var sum = src.reduce(function(acc, x) { return acc + x; }, 0);` ~
        `var found = src.indexOf(3);` ~
        `var sliced = src.slice(1, 3);` ~
        `var joined2 = src.concat([5, 6]);` ~
        `var rev = [1, 2, 3].reverse();` ~
        `var arr2 = [1, 2];` ~
        `var shifted = arr2.shift();` ~
        `var unshifted = arr2.unshift(0);` ~
        `var fsum = 0;` ~
        `src.forEach(function(x) { fsum = fsum + x; });`);
    rt.runScript(rt.makeObject());
    auto doubled = rt.globalScope.get("doubled");
    assert(doubled.kind == JsKind.array, "doubled is array");
    assert(doubled.obj.arrayLength == 4, "doubled length 4");
    assert(doubled.obj.get("2").numValue == 6, "doubled[2] == 6");
    auto evens = rt.globalScope.get("evens");
    assert(evens.kind == JsKind.array && evens.obj.arrayLength == 2, "evens length 2");
    assert(evens.obj.get("0").numValue == 2, "evens[0] == 2");
    auto sum = rt.globalScope.get("sum");
    assert(sum.kind == JsKind.number && sum.numValue == 10, "reduce sum == 10");
    auto found = rt.globalScope.get("found");
    assert(found.kind == JsKind.number && found.numValue == 2, "indexOf(3) == 2");
    auto sliced = rt.globalScope.get("sliced");
    assert(sliced.kind == JsKind.array && sliced.obj.arrayLength == 2, "slice length 2");
    assert(sliced.obj.get("0").numValue == 2, "sliced[0] == 2");
    auto joined2 = rt.globalScope.get("joined2");
    assert(joined2.kind == JsKind.array && joined2.obj.arrayLength == 6, "concat length 6");
    auto rev = rt.globalScope.get("rev");
    assert(rev.kind == JsKind.array && rev.obj.arrayLength == 3, "reverse length 3");
    assert(rev.obj.get("0").numValue == 3, "reverse[0] == 3");
    auto shifted = rt.globalScope.get("shifted");
    assert(shifted.kind == JsKind.number && shifted.numValue == 1, "shift -> 1");
    auto arr2 = rt.globalScope.get("arr2");
    assert(arr2.obj.arrayLength == 2, "arr2 length 2 after shift+unshift");
    assert(arr2.obj.get("0").numValue == 0, "arr2[0] == 0 after unshift");
    auto fsum = rt.globalScope.get("fsum");
    assert(fsum.kind == JsKind.number && fsum.numValue == 10, "forEach sum == 10");
}

unittest
{
    // JSON.stringify/parse round trip and Object helpers.
    auto rt = parseScript(
        `var obj = { a: 1, b: "two", c: [true, null, { d: 3.5 }] };` ~
        `var json = JSON.stringify(obj);` ~
        `var parsed = JSON.parse(json);` ~
        `var okA = parsed.a == 1;` ~
        `var okB = parsed.b == "two";` ~
        `var okC = parsed.c[0] == true;` ~
        `var okC1 = parsed.c[1] == null;` ~
        `var okC2 = parsed.c[2].d == 3.5;` ~
        `var keys = Object.keys(obj);` ~
        `var copy = {};` ~
        `Object.assign(copy, obj);` ~
        `var copyA = copy.a == 1;` ~
        `var isArr = Array.isArray(obj.c);` ~
        `var isNotArr = Array.isArray(obj);`);
    rt.runScript(rt.makeObject());
    auto json = rt.globalScope.get("json");
    assert(json.kind == JsKind.string, "json is string");
    auto parsed = rt.globalScope.get("parsed");
    assert(parsed.kind == JsKind.object, "parsed is object");
    foreach (n; ["okA", "okB", "okC", "okC1", "okC2"])
    {
        auto v = rt.globalScope.get(n);
        assert(v.kind == JsKind.boolean && v.boolValue, n ~ " should be true");
    }
    auto keys = rt.globalScope.get("keys");
    assert(keys.kind == JsKind.array && keys.obj.arrayLength == 3, "keys length 3");
    auto copyA = rt.globalScope.get("copyA");
    assert(copyA.kind == JsKind.boolean && copyA.boolValue, "assign copy works");
    auto isArr = rt.globalScope.get("isArr");
    assert(isArr.kind == JsKind.boolean && isArr.boolValue, "isArray true");
    auto isNotArr = rt.globalScope.get("isNotArr");
    assert(isNotArr.kind == JsKind.boolean && !isNotArr.boolValue, "isArray false");
    // Verify stringify contains the expected shape (property order is hash-based).
    assert(json.strValue == `{"a":1,"b":"two","c":[true,null,{"d":3.5}]}`
        || json.strValue == `{"a":1,"c":[true,null,{"d":3.5}],"b":"two"}`
        || json.strValue == `{"b":"two","a":1,"c":[true,null,{"d":3.5}]}`
        || json.strValue == `{"b":"two","c":[true,null,{"d":3.5}],"a":1}`
        || json.strValue == `{"c":[true,null,{"d":3.5}],"a":1,"b":"two"}`
        || json.strValue == `{"c":[true,null,{"d":3.5}],"b":"two","a":1}`,
        "stringify mismatch: " ~ json.strValue);
}

unittest
{
    // Error constructors and new Error(...) with message.
    auto rt = parseScript(
        `var e = new Error("boom");` ~
        `var name = e.name;` ~
        `var msg = e.message;` ~
        `var isErr = e instanceof Error;` ~
        `var t = new TypeError("bad type");` ~
        `var tName = t.name;` ~
        `var tMsg = t.message;` ~
        `var r = new RangeError("range");` ~
        `var rName = r.name;` ~
        `var caught = null;` ~
        `try { throw new Error("thrown"); } catch (err) { caught = err.message; }`);
    rt.runScript(rt.makeObject());
    auto name = rt.globalScope.get("name");
    assert(name.kind == JsKind.string && name.strValue == "Error", "err.name == Error");
    auto msg = rt.globalScope.get("msg");
    assert(msg.kind == JsKind.string && msg.strValue == "boom", "err.message == boom");
    auto tName = rt.globalScope.get("tName");
    assert(tName.kind == JsKind.string && tName.strValue == "TypeError", "TypeError name");
    auto tMsg = rt.globalScope.get("tMsg");
    assert(tMsg.kind == JsKind.string && tMsg.strValue == "bad type", "TypeError message");
    auto rName = rt.globalScope.get("rName");
    assert(rName.kind == JsKind.string && rName.strValue == "RangeError", "RangeError name");
    auto caught = rt.globalScope.get("caught");
    assert(caught.kind == JsKind.string && caught.strValue == "thrown", "try/catch caught thrown");
}

unittest
{
    // Prototype chain via new.
    auto rt = parseScript(
        `function Person(name) { this.name = name; }` ~
        `Person.prototype.greet = function() { return "Hi " + this.name; };` ~
        `var p = new Person("Alice");` ~
        `var pName = p.name;` ~
        `var greeting = p.greet();` ~
        `var isPerson = p instanceof Person;` ~
        `function Ctor() { return { custom: true }; }` ~
        `var c = new Ctor();` ~
        `var custom = c.custom;`);
    rt.runScript(rt.makeObject());
    auto pName = rt.globalScope.get("pName");
    assert(pName.kind == JsKind.string && pName.strValue == "Alice", "constructor set this.name");
    auto greeting = rt.globalScope.get("greeting");
    assert(greeting.kind == JsKind.string && greeting.strValue == "Hi Alice", "method via prototype works");
    auto isPerson = rt.globalScope.get("isPerson");
    assert(isPerson.kind == JsKind.boolean && isPerson.boolValue, "instanceof works");
    auto custom = rt.globalScope.get("custom");
    assert(custom.kind == JsKind.boolean && custom.boolValue, "ctor returning object is used");
}

unittest
{
    // typeof and parseInt with radix.
    auto rt = parseScript(
        `var t1 = typeof "str";` ~
        `var t2 = typeof 42;` ~
        `var t3 = typeof true;` ~
        `var t4 = typeof undefined;` ~
        `var t5 = typeof null;` ~
        `var t6 = typeof {};` ~
        `var t7 = typeof [];` ~
        `var t8 = typeof function(){};` ~
        `var p1 = parseInt("0x1F", 16);` ~
        `var p2 = parseInt("101", 2);` ~
        `var p3 = parseInt("42");` ~
        `var p4 = parseInt("-10", 10);`);
    rt.runScript(rt.makeObject());
    auto checkStr = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.string && v.strValue == expected, name ~ " wrong: '" ~ rt.toJsString(v) ~ "'");
    };
    checkStr("t1", "string");
    checkStr("t2", "number");
    checkStr("t3", "boolean");
    checkStr("t4", "undefined");
    checkStr("t5", "object");
    checkStr("t6", "object");
    checkStr("t7", "object");
    checkStr("t8", "function");
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkNum("p1", 31);
    checkNum("p2", 5);
    checkNum("p3", 42);
    checkNum("p4", -10);
}

unittest
{
    // Real continuation-based async/await: await on a pending promise suspends
    // the async body and resumes it after the promise resolves, preserving
    // local variable state and the returned value.
    auto rt = parseScript(
        `var log = [];` ~
        `function later(v) { return new Promise(function(resolve) { resolve(v * 2); }); }` ~
        `async function run() {` ~
        `  var a = 5;` ~
        `  log.push("before-await");` ~
        `  var b = await later(a);` ~
        `  log.push("after-await");` ~
        `  log.push(b);` ~
        `  var c = await later(b);` ~
        `  log.push(c);` ~
        `  return c + 1;` ~
        `}` ~
        `var p = run();` ~
        `p.then(function(r) { log.push("done:" + r); });`);
    rt.runScript(rt.makeObject());
    rt.pumpMicrotasks();
    auto logVal = rt.globalScope.get("log");
    assert(logVal.kind == JsKind.array, "log should be an array");
    string s;
    for (size_t i = 0; i < logVal.obj.arrayLength; i++)
    {
        if (i) s ~= ",";
        s ~= rt.toJsString(logVal.obj.get(to!string(i)));
    }
    assert(s == "before-await,after-await,10,20,done:21",
        "async/await sequence wrong: [" ~ s ~ "]");
}

unittest
{
    // for-of over arrays and strings.
    auto rt = parseScript(
        `var sum = 0;` ~
        `for (var x of [1, 2, 3]) { sum = sum + x; }` ~
        `var chars = "";` ~
        `for (var c of "abc") { chars = chars + c; }` ~
        `var count = 0;` ~
        `var src = [5, 6, 7];` ~
        `for (var y of src) { count++; }` ~
        `var last = 0;` ~
        `for (var z of [10, 20, 30]) { last = z; }`);
    rt.runScript(rt.makeObject());
    auto sum = rt.globalScope.get("sum");
    assert(sum.kind == JsKind.number && sum.numValue == 6, "for-of sum should be 6, got " ~ rt.toJsString(sum));
    auto chars = rt.globalScope.get("chars");
    assert(chars.kind == JsKind.string && chars.strValue == "abc", "for-of string chars should be 'abc', got '" ~ rt.toJsString(chars) ~ "'");
    auto count = rt.globalScope.get("count");
    assert(count.kind == JsKind.number && count.numValue == 3, "for-of count should be 3");
    auto last = rt.globalScope.get("last");
    assert(last.kind == JsKind.number && last.numValue == 30, "for-of last should be 30");
}

unittest
{
    // Number/string coercion edge cases.
    auto rt = parseScript(
        `var n1 = 42;` ~
        `var n2 = 0.1;` ~
        `var n3 = -0;` ~
        `var n4 = NaN;` ~
        `var n5 = Infinity;` ~
        `var s1 = +"42";` ~
        `var s2 = -"3";` ~
        `var s3 = +"  -7.5  ";` ~
        `var s4 = +"0x10";` ~
        `var s5 = +"Infinity";` ~
        `var s6 = +"";` ~
        `var s7 = Number(" 12 ");` ~
        `var rel1 = "apple" < "banana";` ~
        `var rel2 = "banana" > "apple";` ~
        `var rel3 = "10" < "9";`);
    rt.runScript(rt.makeObject());
    auto checkNum = (string name, double expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number && v.numValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    auto checkNumString = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.number, name ~ " should be a number, got " ~ rt.toJsString(v));
        auto s = rt.toJsString(v);
        assert(s == expected, name ~ " string form wrong: '" ~ s ~ "' want '" ~ expected ~ "'");
    };
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkNumString("n1", "42");
    checkNumString("n2", "0.1");
    checkNumString("n3", "0");
    checkNumString("n4", "NaN");
    checkNumString("n5", "Infinity");
    checkNum("s1", 42);
    checkNum("s2", -3);
    checkNum("s3", -7.5);
    checkNum("s4", 16);
    checkNum("s5", double.infinity);
    checkNum("s6", 0);
    checkNum("s7", 12);
    checkBool("rel1", true);
    checkBool("rel2", true);
    checkBool("rel3", true);
}

unittest
{
    // looseEquals edge cases + ToPrimitive for arrays.
    auto rt = parseScript(
        `var e1 = (null == undefined);` ~
        `var e2 = (0 == "");` ~
        `var e3 = (1 == true);` ~
        `var e4 = ("1" == 1);` ~
        `var e5 = ([] == false);` ~
        `var e6 = ([0] == false);` ~
        `var e7 = ("" == false);` ~
        `var e8 = (0 == false);` ~
        `var e9 = (null == 0);`);
    rt.runScript(rt.makeObject());
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkBool("e1", true);
    checkBool("e2", true);
    checkBool("e3", true);
    checkBool("e4", true);
    checkBool("e5", true);
    checkBool("e6", true);
    checkBool("e7", true);
    checkBool("e8", true);
    checkBool("e9", false);
}

unittest
{
    // instanceof: builtin + custom constructors; bind.
    auto rt = parseScript(
        `var ia = [] instanceof Array;` ~
        `var io = {} instanceof Object;` ~
        `var ifn = (function(){}) instanceof Function;` ~
        `function Person(name) { this.name = name; }` ~
        `var p = new Person("Bob");` ~
        `var ip = p instanceof Person;` ~
        `var iv = p instanceof Object;` ~
        `function add(a, b) { return a + b; }` ~
        `var obj2 = { base: 100 };` ~
        `var boundAdd = add.bind(obj2, 40);` ~
        `var bres = boundAdd(2);` ~
        `function greet(greeting) { return greeting + " " + this.name; }` ~
        `var alice = { name: "Alice" };` ~
        `var boundGreet = greet.bind(alice);` ~
        `var bgreet = boundGreet("Hi");`);
    rt.runScript(rt.makeObject());
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkBool("ia", true);
    checkBool("io", true);
    checkBool("ifn", true);
    checkBool("ip", true);
    checkBool("iv", true);
    auto bres = rt.globalScope.get("bres");
    assert(bres.kind == JsKind.number && bres.numValue == 42, "bind prepended args should give 42");
    auto bgreet = rt.globalScope.get("bgreet");
    assert(bgreet.kind == JsKind.string && bgreet.strValue == "Hi Alice", "bind this should be alice");
}

unittest
{
    // Array method gaps: includes/find/findIndex/every/some/flat.
    auto rt = parseScript(
        `var a1 = [1, 2, 3].includes(2);` ~
        `var a2 = [1, 2, 3].includes(5);` ~
        `var a3 = [1, 2, 3, 4].find(function(x) { return x > 2; });` ~
        `var a4 = [1, 2, 3, 4].findIndex(function(x) { return x > 2; });` ~
        `var a5 = [2, 4, 6].every(function(x) { return x % 2 == 0; });` ~
        `var a6 = [2, 3, 4].every(function(x) { return x % 2 == 0; });` ~
        `var a7 = [1, 2, 3].some(function(x) { return x > 2; });` ~
        `var a8 = [1, 2].some(function(x) { return x > 5; });` ~
        `var a9 = [[1, 2], [3, 4]].flat();`);
    rt.runScript(rt.makeObject());
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkBool("a1", true);
    checkBool("a2", false);
    checkBool("a5", true);
    checkBool("a6", false);
    checkBool("a7", true);
    checkBool("a8", false);
    auto a3 = rt.globalScope.get("a3");
    assert(a3.kind == JsKind.number && a3.numValue == 3, "find should return 3");
    auto a4 = rt.globalScope.get("a4");
    assert(a4.kind == JsKind.number && a4.numValue == 2, "findIndex should return 2");
    auto a9 = rt.globalScope.get("a9");
    assert(a9.kind == JsKind.array && a9.obj.arrayLength == 4, "flat length should be 4");
    assert(a9.obj.get("3").numValue == 4, "flat[3] should be 4");
}

unittest
{
    // String repeat/padStart/padEnd/lastIndexOf + Object.entries/values.
    auto rt = parseScript(
        `var r1 = "ab".repeat(3);` ~
        `var p1 = "5".padStart(3, "0");` ~
        `var p2 = "5".padEnd(3, "0");` ~
        `var li1 = "hello world world".lastIndexOf("world");` ~
        `var li2 = "abc".lastIndexOf("x");` ~
        `var o = { x: 1, y: 2 };` ~
        `var ent = Object.entries(o);` ~
        `var vals = Object.values(o);`);
    rt.runScript(rt.makeObject());
    auto checkStr = (string name, string expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.string && v.strValue == expected, name ~ " wrong: '" ~ rt.toJsString(v) ~ "' want '" ~ expected ~ "'");
    };
    checkStr("r1", "ababab");
    checkStr("p1", "005");
    checkStr("p2", "500");
    auto li1 = rt.globalScope.get("li1");
    assert(li1.kind == JsKind.number && li1.numValue == 12, "lastIndexOf should be 12");
    auto li2 = rt.globalScope.get("li2");
    assert(li2.kind == JsKind.number && li2.numValue == -1, "lastIndexOf missing should be -1");
    auto ent = rt.globalScope.get("ent");
    assert(ent.kind == JsKind.array && ent.obj.arrayLength == 2, "entries length 2");
    auto pair0 = ent.obj.get("0");
    auto pair1 = ent.obj.get("1");
    assert(pair0.kind == JsKind.array && pair0.obj.arrayLength == 2, "entry is a pair");
    assert(pair1.kind == JsKind.array && pair1.obj.arrayLength == 2, "entry is a pair");
    // Hash-map iteration order is not guaranteed; check both keys exist with values.
    string k0 = pair0.obj.get("0").strValue;
    string k1 = pair1.obj.get("0").strValue;
    double v0 = pair0.obj.get("1").numValue;
    double v1 = pair1.obj.get("1").numValue;
    assert((k0 == "x" && v0 == 1) || (k0 == "y" && v0 == 2), "entries key/value 0");
    assert((k1 == "x" && v1 == 1) || (k1 == "y" && v1 == 2), "entries key/value 1");
    assert(k0 != k1, "entries distinct keys");
    auto vals = rt.globalScope.get("vals");
    assert(vals.kind == JsKind.array && vals.obj.arrayLength == 2, "values length 2");
}

unittest
{
    // NaN identity + Number.isNaN.
    auto rt = parseScript(
        `var u;` ~
        `var ueq = (u === undefined);` ~
        `var n1 = (NaN !== NaN);` ~
        `var n2 = (NaN == NaN);` ~
        `var n3 = Number.isNaN(NaN);` ~
        `var n4 = Number.isNaN("NaN");` ~
        `var n5 = Number.isNaN(123);`);
    rt.runScript(rt.makeObject());
    auto checkBool = (string name, bool expected) {
        auto v = rt.globalScope.get(name);
        assert(v.kind == JsKind.boolean && v.boolValue == expected, name ~ " wrong: " ~ rt.toJsString(v));
    };
    checkBool("ueq", true);
    checkBool("n1", true);
    checkBool("n2", false);
    checkBool("n3", true);
    checkBool("n4", false);
    checkBool("n5", false);
}

module auroraweb.css;

/**
 * CSS parsing and cascade.
 *
 * Supports the practical subset needed by a first web engine: a parser for
 * rule lists (`selector { prop: value; ... }`), simple and compound selectors
 * (type, `#id`, `.class`, `*`), descendant and comma-separated selector lists,
 * and a cascade that applies the highest-specificity matching rule for each
 * property, with later rules winning ties and `!important` overriding normal
 * declarations.
 */

import auroraweb.dom : Element;

import std.algorithm : min;
import std.array : appender;
import std.string : indexOf, lastIndexOf, split, strip, toLower;

/// One declaration: a property name and value.
struct Declaration
{
    string property;
    string value;
    bool important;
}

/// A media-query condition attached to a rule. -1 means unset.
struct MediaQuery
{
    int minWidth = -1;
    int maxWidth = -1;
    int minHeight = -1;
    int maxHeight = -1;
    bool anyCondition;   /// Bare `@media { ... }` (always matches).
    bool matched;        /// Set by applyMediaRules.
    string mediaType = "all";   /// "all", "screen" or "print".

    bool matches(int vw, int vh) const
    {
        if (anyCondition) return mediaType == "all" || mediaType == "screen" ||
            (mediaType == "print" && !g_screenMedia);
        if (mediaType == "print") return !g_screenMedia;   // we never print.
        if (mediaType != "all" && mediaType != "screen") return false;
        if (minWidth >= 0 && vw < minWidth) return false;
        if (maxWidth >= 0 && vw > maxWidth) return false;
        if (minHeight >= 0 && vh < minHeight) return false;
        if (maxHeight >= 0 && vh > maxHeight) return false;
        return true;
    }
}

/// Whether the renderer is a screen (true by default). `@media print` rules
/// never apply while we render on screen.
private bool g_screenMedia = true;

/// Parsed `@keyframes` end states: animation name -> the declarations of the
/// `to`/`100%` keyframe. The engine does not animate over time, but pages
/// routinely rely on an animation (usually with `forwards`) to reveal or hide
/// an element, so callers can apply this end state statically.
__gshared Declaration[][string] g_keyframes;

/// The `::before`/`::after` rules for `which` ("before"/"after"), rewritten as
/// ordinary selectors so the existing matcher can match them against the element
/// the pseudo-element belongs to. `isPseudoElement` is the renderer's
/// "never matches a real element" flag, so it is cleared on the copy; the
/// genuine pseudo-element name is kept in `pseudoElement` by the parser.
Rule[] pseudoElementRules(Rule[] rules, string which)
{
    Rule[] outRules;
    foreach (rule; rules)
    {
        Selector[] kept;
        foreach (sel; rule.selectors)
            if (sel.pseudoElement == which)
            {
                auto copied = sel;
                copied.isPseudoElement = false;
                kept ~= copied;
            }
        if (kept.length == 0) continue;
        auto r = rule;
        r.selectors = kept;
        outRules ~= r;
    }
    return outRules;
}

/// The end-state (`to`/`100%`) declarations for an animation name, or null.
Declaration[] keyframeEndState(string name)
{
    auto it = name in g_keyframes;
    return it is null ? null : *it;
}

/// Set the current media type. Pass false when rendering for print.
void setScreenMedia(bool isScreen)
{
    g_screenMedia = isScreen;
}

/// One CSS rule.
struct Rule
{
    Selector[] selectors;   /// Comma-separated selector list.
    Declaration[] declarations;
    MediaQuery media;
}

/// A single complex selector (one compound with optional descendant).
struct Selector
{
    string typeName;        /// "div", "p", or "" for universal.
    string className;       /// ".foo"
    string[] extraClasses;  /// Further ".bar" classes in the same compound; ALL are required.
    string idName;          /// "#bar"
    Selector[] descendants; /// Ancestor selectors for descendant combinator.
    string[] combinators;   /// Per-descendant combinator: "", ">", "+".
    string attrName;        /// "[href]" presence attribute selector.
    string attrValue;       /// "[href=\"...\"]" value test.
    bool attrHasValue;      /// Whether a value was given.
    bool isRoot;            /// `:root` — matches the document root element.
    bool isPseudoElement;   /// `::before`/`::after` — generated content; never a real element.
    /// "before"/"after" when this compound names a generated pseudo-element
    /// (empty otherwise). Kept apart from `isPseudoElement`, which also covers
    /// pseudo-classes the renderer cannot evaluate and therefore never matches:
    /// a genuine `::before`/`::after` rule must survive parsing so the layout can
    /// build the generated box its declarations describe.
    string pseudoElement;
    bool isHover;           /// `:hover` — pointer is over the element.
    bool isFocus;           /// `:focus`/`:focus-visible` — element has focus.
    bool isActive;          /// `:active` — mouse button held on the element.
    bool isFirstChild;      /// `:first-child`.
    bool isLastChild;       /// `:last-child`.
    bool isChecked;         /// `:checked` — a checked input.
    /// `:not(...)` arguments: the element must match NONE of them. Real pages
    /// lean on this heavily — django's `header nav li>:not(.search){padding:10px}`
    /// carries the whole menu spacing. Treating `:not` as an unevaluatable
    /// pseudo-class poisoned the compound, so such rules never applied at all.
    Selector[] negations;
}

/**
 * Parse a stylesheet text into rules.
 *
 * Ignores comments `/* *\/` and `@import` at-rules. Parses `@media` blocks,
 * attaching the condition to each inner rule. Malformed segments are skipped
 * so one bad rule does not poison the whole sheet.
 */
Rule[] parseStylesheet(string css)
{
    return parseStylesheet(css, 1280, 800);
}

Rule[] parseStylesheet(string css, int viewportWidth, int viewportHeight)
{
    Rule[] rules;
    size_t i = 0;
    const n = css.length;

    void skipWhitespace()
    {
        while (i < n && css[i] <= ' ')
            i++;
    }

    void skipComment()
    {
        if (i + 1 < n && css[i] == '/' && css[i + 1] == '*')
        {
            auto end = indexOf(css, "*/", i + 2);
            i = end < 0 ? n : end + 2;
        }
    }

    // Parse the prelude of an @media rule: "(max-width: 400px) and (min-width: 100px)".
    MediaQuery parseMediaQuery(string prelude)
    {
        MediaQuery mq;
        const p = prelude.strip();
        if (p.length == 0) { mq.anyCondition = true; return mq; }
        // Split on ',' (OR groups) — we take the first group that could match.
        auto groups = p.split(',');
        // A leading media type keyword (`screen`, `print`, `all`) applies to
        // every OR-group in the prelude. `not screen` / `not print` are also
        // honored (e.g. `@media not print { ... }`).
        string typeKeyword = "all";
        bool typeNegated = false;
        foreach (partRaw; groups)
        {
            auto part = partRaw.strip().toLower();
            if (part.length == 0 || part[0] == '(') break;
            auto firstWord = part;
            auto sp = indexOf(part, " ");
            if (sp >= 0) firstWord = part[0 .. sp];
            if (firstWord == "not")
            {
                typeNegated = true;
                auto rest = part[sp + 1 .. $].strip();
                if (rest.length) firstWord = rest; else break;
            }
            if (firstWord == "screen" || firstWord == "print" || firstWord == "all")
            {
                typeKeyword = firstWord;
                break;
            }
            break;
        }
        if (typeNegated)
            typeKeyword = (typeKeyword == "screen") ? "print" : (typeKeyword == "print") ? "screen" : "all";
        // Evaluate each group; keep the first that matches (OR semantics).
        // When conditions are present but none match, return a query carrying
        // those conditions (anyCondition == false) so the rule is stored and
        // re-evaluated against the real viewport by `applyMediaRules` -- rather
        // than being treated as condition-free (which made e.g. a
        // `max-width: 1180px` block apply at 1350px).
        MediaQuery firstCondQuery;
        bool haveFirstCond = false;
        foreach (group; groups)
        {
            MediaQuery g;
            g.mediaType = typeKeyword;
            bool hasCond = false;
            auto parts = group.split("and");
            foreach (partRaw; parts)
            {
                auto part = partRaw.strip();
                if (part.length == 0) continue;
                auto lower = part.toLower();
                if (lower == "screen" || lower == "print" || lower == "all" || lower == "only")
                    continue;                    // media type, not a feature condition
                hasCond = true;
                auto paren = indexOf(part, "(");
                auto parenEnd = lastIndexOf(part, ")");
                if (paren < 0 || parenEnd < 0) continue;
                auto inner = part[paren + 1 .. parenEnd].strip();
                auto colon = indexOf(inner, ":");
                if (colon < 0) continue;
                auto prop = inner[0 .. colon].strip().toLower();
                auto val = inner[colon + 1 .. $].strip();
                auto num = parsePxOrZero(val);
                if (prop == "max-width") g.maxWidth = num;
                else if (prop == "min-width") g.minWidth = num;
                else if (prop == "max-height") g.maxHeight = num;
                else if (prop == "min-height") g.minHeight = num;
                else if (prop == "prefers-color-scheme")
                {
                    // The engine renders the LIGHT palette, so a `dark`
                    // preference must never match. Ignoring the unknown feature
                    // left the query's OTHER conditions (e.g. `min-width:768px`)
                    // to satisfy it, so a page's entire dark-theme block applied
                    // on top of its light rules and the two themes mixed: a real
                    // homepage kept the light banner background and took the
                    // dark theme's mint text, which is unreadable. `light` adds
                    // no constraint since that is what we already render.
                    if (val.toLower() == "dark")
                        return MediaQuery(-2, -2, -2, -2, false, false, "");
                }
            }
            if (hasCond)
            {
                if (g.matches(viewportWidth, viewportHeight))
                    return g;                    // this OR-group matches
                if (!haveFirstCond) { firstCondQuery = g; haveFirstCond = true; }
            }
        }
        if (haveFirstCond)
            return firstCondQuery;               // stored; filtered per viewport
        // Bare `@media screen { ... }` / `@media print { ... }` (no condition).
        if (typeKeyword == "screen" || typeKeyword == "print" || typeKeyword == "all")
        {
            MediaQuery typeOnly;
            typeOnly.mediaType = typeKeyword;
            typeOnly.anyCondition = true;
            return typeOnly;
        }
        return MediaQuery(-2, -2, -2, -2, false, false, "");
    }

    // Parse the rules inside a block, optionally tagging each with a media query.
    void parseInner(ptrdiff_t start, ptrdiff_t end, MediaQuery mq)
    {
        auto j = start;
        while (j < end)
        {
            // skip whitespace/comments
            while (j < end && (css[j] <= ' ' || (j + 1 < end && css[j] == '/' && css[j + 1] == '*')))
            {
                if (j + 1 < end && css[j] == '/' && css[j + 1] == '*')
                {
                    auto cend = indexOf(css, "*/", j + 2);
                    j = cend < 0 ? end : cend + 2;
                }
                else j++;
            }
            if (j >= end) break;
            if (css[j] == '@')
            {
                // An at-rule nested inside a block body (@font-face, @supports,
                // ...). This MUST advance `j`, the cursor of THIS loop: the
                // shared `skipImport` moves the outer `i` instead, so `j < end`
                // stayed true forever and the parse never returned - a real
                // stylesheet with an at-rule inside a block hung the page
                // permanently (13 KB of CSS, never finished).
                auto semi = indexOf(css, ";", j);
                auto open = indexOf(css, "{", j);
                if (open >= 0 && (semi < 0 || open < semi))
                {
                    int d = 0;
                    auto k = open;
                    while (k < end)
                    {
                        if (css[k] == '{') d++;
                        else if (css[k] == '}')
                        {
                            d--;
                            if (d == 0) break;
                        }
                        k++;
                    }
                    j = k < end ? k + 1 : end;
                }
                else
                    j = semi < 0 ? end : semi + 1;
                continue;
            }
            auto brace = indexOf(css, "{", j);
            if (brace < 0 || brace >= end) break;
            const selectorText = css[j .. brace].strip();
            auto declStart = brace + 1;
            auto braceEnd = indexOf(css, "}", declStart);
            if (braceEnd < 0 || braceEnd >= end) braceEnd = end;
            const declText = css[declStart .. braceEnd];
            auto selectors = parseSelectorList(selectorText);
            auto declarations = parseDeclarations(declText);
            if (selectors.length && declarations.length)
            {
                Rule r;
                r.selectors = selectors;
                r.declarations = declarations;
                r.media = mq;
                rules ~= r;
            }
            j = braceEnd + 1;
        }
    }

    // Capture the end state of an `@keyframes` block (only `to`/`100%`).
    void parseKeyframeEnd(string name, ptrdiff_t start, ptrdiff_t end)
    {
        if (name.length == 0) return;
        auto j = start;
        while (j < end)
        {
            auto brace = indexOf(css, "{", j);
            if (brace < 0 || brace >= end) break;
            auto sel = css[j .. brace].strip().toLower();
            auto declStart = brace + 1;
            auto braceEnd = indexOf(css, "}", declStart);
            if (braceEnd < 0 || braceEnd > end) braceEnd = end;
            if (sel == "to" || sel == "100%")
                g_keyframes[name] = parseDeclarations(css[declStart .. braceEnd]);
            j = braceEnd + 1;
        }
    }

    while (i < n)
    {
        skipWhitespace();
        skipComment();
        if (i >= n) break;
        if (css[i] == '@')
        {
            // @media or @import.
            if (i + 5 < n && css[i + 1 .. i + 6].toLower() == "media")
            {
                auto brace = indexOf(css, "{", i);
                if (brace < 0) { i = n; continue; }
                auto prelude = css[i + 6 .. brace];
                auto mq = parseMediaQuery(prelude);
                // Find matching close.
                int depth = 0;
                auto k = brace;
                while (k < n)
                {
                    if (css[k] == '{') depth++;
                    else if (css[k] == '}') { depth--; if (depth == 0) { k++; break; } }
                    k++;
                }
                // Store the inner rules with their media condition; the render
                // pass (`applyMediaRules`) decides whether they apply. This way
                // a rule is re-evaluated against the real viewport width.
                parseInner(brace + 1, k > 0 ? k - 1 : k, mq);
                i = k;
                continue;
            }

            // @keyframes / @-webkit-keyframes <name> { ... }
            {
                bool isKf = false;
                size_t nameStart = 0;
                if (i + 10 <= n && css[i + 1 .. i + 10].toLower() == "keyframes")
                {
                    isKf = true;
                    nameStart = i + 10;
                }
                else if (i + 18 <= n && css[i + 1 .. i + 18].toLower() == "-webkit-keyframes")
                {
                    isKf = true;
                    nameStart = i + 18;
                }
                if (isKf)
                {
                    auto brace = indexOf(css, "{", i);
                    if (brace < 0) { i = n; continue; }
                    auto name = css[nameStart .. brace].strip();
                    int depth = 0;
                    auto k = brace;
                    while (k < n)
                    {
                        if (css[k] == '{') depth++;
                        else if (css[k] == '}') { depth--; if (depth == 0) { k++; break; } }
                        k++;
                    }
                    parseKeyframeEnd(name, brace + 1, k > 0 ? k - 1 : k);
                    i = k;
                    continue;
                }
            }

            // Any other at-rule: @import/@charset (they end with `;`), or one
            // with a block (@font-face, @page, @supports, @starting-style, ...).
            // Skip the at-rule's OWN extent. Scanning to the next `;` anywhere
            // is wrong for minified CSS, where an at-rule can contain no `;` at
            // all: `@starting-style{header nav.active{max-height:0}}` sits
            // directly before `@media screen and (min-width: 1280px){header
            // nav{display:block;...}}`, so the cursor resumed INSIDE that media
            // block and consumed `header nav{...}` as garbage selector text.
            // The rule that un-hides a real site's main navigation was dropped,
            // leaving the header with only its logo.
            auto atBrace = indexOf(css, "{", i);
            auto atSemi = indexOf(css, ";", i);
            if (atBrace >= 0 && (atSemi < 0 || atBrace < atSemi))
            {
                int atDepth = 0;
                auto at = atBrace;
                while (at < n)
                {
                    if (css[at] == '{') atDepth++;
                    else if (css[at] == '}') { atDepth--; if (atDepth == 0) { at++; break; } }
                    at++;
                }
                i = at > atBrace ? at : n;
            }
            else
                i = atSemi < 0 ? n : atSemi + 1;
            continue;
        }
        // Find the next top-level "{".
        auto brace = indexOf(css, "{", i);
        if (brace < 0) break;
        const selectorText = css[i .. brace].strip();
        auto declStart = brace + 1;
        auto braceEnd = indexOf(css, "}", declStart);
        if (braceEnd < 0) braceEnd = n;
        const declText = css[declStart .. braceEnd];

        auto selectors = parseSelectorList(selectorText);
        auto declarations = parseDeclarations(declText);
        if (selectors.length && declarations.length)
            rules ~= Rule(selectors, declarations);
        i = braceEnd + 1;
    }
    return rules;
}

private int parsePxOrZero(string s)
{
    import auroraweb.dom : cssInt;
    const t = s.strip();
    if (t.length >= 2 && t[$ - 2 .. $] == "px")
        return cssInt(t[0 .. $ - 2].strip());
    return t.length ? cssInt(t) : 0;
}

/// Filter rules to those whose media condition matches the given viewport.
Rule[] applyMediaRules(in Rule[] rules, int vw, int vh)
{
    Rule[] result;
    foreach (r; rules)
    {
        if (r.media.matches(vw, vh))
            result ~= cast(Rule) r;
    }
    return result;
}

/// Split a comma-separated selector list into individual selectors.
private Selector[] parseSelectorList(string text)
{
    Selector[] result;
    foreach (part; text.split(','))
    {
        auto sel = parseSelector(part.strip());
        if ((sel.isPseudoElement && sel.pseudoElement.length == 0) ||
            (!sel.isRoot && !sel.isUniversal && sel.typeName.length == 0 && sel.className.length == 0 &&
            sel.idName.length == 0 && sel.attrName.length == 0 &&
            !sel.isHover && !sel.isFocus && !sel.isActive &&
            !sel.isFirstChild && !sel.isLastChild && !sel.isChecked &&
            sel.negations.length == 0)
            )
            continue;
        result ~= sel;
    }
    return result;
}

/// Parse one complex selector with descendant combinators.
private Selector parseSelector(string text)
{
    Selector result;
    if (text.length == 0) return result;

    // Tokenize: split on whitespace AND combinator markers (">", "+").
    // Each token is either a compound ("div.foo#bar[href]") or a combinator.
    string[] tokens;
    auto buf = appender!string;
    void flush()
    {
        if (buf.data.length) { tokens ~= buf.data; buf = appender!string; }
    }
    size_t j = 0;
    const m = text.length;
    while (j < m)
    {
        const c = text[j];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') { flush(); j++; }
        else if (c == '>' || c == '+') { flush(); tokens ~= [c]; j++; }
        else { buf.put(c); j++; }
    }
    flush();

    if (tokens.length == 0) return result;

    // Parse every compound, then keep the LAST one as the main (leaf)
    // selector; the others become ancestors in `descendants`, ordered
    // nearest-to-farthest (the reverse of how they appear in the text).
    Selector[] compounds;
    string[] combinators;   // combinator BEFORE each ancestor (descendants[i]).
    foreach (token; tokens)
    {
        if (token == ">" || token == "+")
        {
            if (combinators.length < compounds.length)
                combinators.length = compounds.length;
            combinators[compounds.length - 1] = token;
            continue;
        }
        Selector compound;
        parseCompound(token, compound);
        compounds ~= compound;
    }
    if (compounds.length == 0) return result;

    auto leaf = compounds[$ - 1];
    result.typeName = leaf.typeName;
    result.className = leaf.className;
    result.extraClasses = leaf.extraClasses;
    result.idName = leaf.idName;
    result.attrName = leaf.attrName;
    result.attrValue = leaf.attrValue;
    result.attrHasValue = leaf.attrHasValue;
    result.isRoot = leaf.isRoot;
    result.isPseudoElement = leaf.isPseudoElement;
    result.pseudoElement = leaf.pseudoElement;
    result.isHover = leaf.isHover;
    result.isFocus = leaf.isFocus;
    result.isActive = leaf.isActive;
    result.isFirstChild = leaf.isFirstChild;
    result.isLastChild = leaf.isLastChild;
    result.isChecked = leaf.isChecked;
    result.negations = leaf.negations;
    if (compounds.length > 1)
    {
        foreach_reverse (k; 0 .. compounds.length - 1)
        {
            result.descendants ~= compounds[k];
            auto comb = (k < combinators.length) ? combinators[k] : "";
            result.combinators ~= comb;
        }
    }
    return result;
}

private string[] splitSelectorParts(string text)
{
    string[] parts;
    auto buf = appender!string;
    foreach (ch; text)
    {
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f')
        {
            if (buf.data.length) { parts ~= buf.data; buf = appender!string; }
        }
        else buf.put(ch);
    }
    if (buf.data.length) parts ~= buf.data;
    return parts;
}

private void parseCompound(string part, out Selector compound)
{
    size_t i = 0;
    const n = part.length;
    if (n && part[0] == '*')
    {
        compound.typeName = "*";
        i = 1;
    }
    while (i < n)
    {
        if (part[i] == '.')
        {
            auto start = i + 1;
            i = start;
            // Stop at `:` too, so `:hover`/`:focus`/... after a class or id is
            // parsed as a pseudo-class instead of being swallowed into the name
            // (`.btn:hover` used to become the class "btn:hover").
            while (i < n && part[i] != '.' && part[i] != '#' && part[i] != '[' &&
                part[i] != ':') i++;
            if (start > i) compound.className = "";
            else
            {
                // A compound can carry several classes (`.full-width.container`).
                // Storing only one made `.a.b` match any element with `.b` alone,
                // so a rule silently applied to elements it does not select - a
                // real page's `.container` picked up `.full-width.container`'s
                // `width:100%` and overflowed its viewport.
                auto cls = part[start .. min(i, part.length)];
                if (compound.className.length == 0) compound.className = cls;
                else compound.extraClasses ~= cls;
            }
        }
        else if (part[i] == '#')
        {
            auto start = i + 1;
            i = start;
            while (i < n && part[i] != '.' && part[i] != '#' && part[i] != '[' &&
                part[i] != ':') i++;
            if (start > i) compound.idName = "";
            else compound.idName = part[start .. min(i, part.length)];
        }
        else if (part[i] == '[')
        {
            auto end = indexOf(part, "]", i);
            if (end < 0) break;
            auto inner = part[i + 1 .. end].strip();
            if (inner.length)
            {
                auto eq = indexOf(inner, "=");
                if (eq >= 0)
                {
                    auto name = inner[0 .. eq].strip().toLower();
                    auto value = inner[eq + 1 .. $].strip();
                    // Strip surrounding quotes from the value.
                    if (value.length >= 2 &&
                        ((value[0] == '"' && value[$ - 1] == '"') ||
                         (value[0] == '\'' && value[$ - 1] == '\'')))
                        value = value[1 .. $ - 1];
                    compound.attrName = name;
                    compound.attrValue = value;
                    compound.attrHasValue = true;
                }
                else
                {
                    compound.attrName = inner.strip().toLower();
                    compound.attrValue = "";
                    compound.attrHasValue = false;
                }
            }
            i = end + 1;
        }
        else if (part[i] == ':')
        {
            // Pseudo-class / pseudo-element: consume the name and any `(...)`
            // arguments. `:root` is honored; other pseudo-classes (:hover,
            // :last-child, ::before, ...) are ignored rather than poisoning the
            // compound with a bogus type name.
            i++;
            while (i < n && part[i] == ':') i++;
            auto start = i;
            while (i < n && (isIdentChar(part[i]) || part[i] == '-')) i++;
            auto pname = part[start .. min(i, part.length)].toLower();
            if (pname == "root") compound.isRoot = true;
            else if (pname == "not")
            {
                // `:not(<simple selector>)` (Selectors 3): a negated argument
                // makes the compound match when the argument does NOT.
                bool ok = false;
                if (i < n && part[i] == '(')
                {
                    auto close = i + 1;
                    int depth = 1;
                    while (close < n)
                    {
                        if (part[close] == '(') depth++;
                        else if (part[close] == ')')
                        {
                            depth--;
                            if (depth == 0) break;
                        }
                        close++;
                    }
                    if (close < n)
                    {
                        auto inner = part[i + 1 .. close].strip();
                        i = close + 1;
                        auto neg = parseSelector(inner);
                        // Selectors 3 allows only simple arguments (one
                        // compound, no combinator) and no argument list. An
                        // argument we cannot represent must not make the
                        // compound match everything: leave it unmatchable.
                        if (inner.length && indexOf(inner, ',') < 0 &&
                            neg.descendants.length == 0 && neg.negations.length == 0)
                        {
                            compound.negations ~= neg;
                            ok = true;
                        }
                    }
                }
                if (!ok) compound.isPseudoElement = true;
            }
            else if (pname == "before" || pname == "after")
            {
                compound.isPseudoElement = true;
                compound.pseudoElement = pname;
            }
            // State pseudo-classes the renderer CAN evaluate against the
            // element's tracked interaction state.
            else if (pname == "hover") compound.isHover = true;
            else if (pname == "focus" || pname == "focus-visible")
                compound.isFocus = true;
            else if (pname == "active") compound.isActive = true;
            else if (pname == "first-child") compound.isFirstChild = true;
            else if (pname == "last-child") compound.isLastChild = true;
            else if (pname == "checked") compound.isChecked = true;
            else
                // A pseudo-class we cannot evaluate (:hover, :focus-within,
                // :nth-child, :not(...), ...). Never match the compound:
                // otherwise state-based rules would act as if permanently
                // active, e.g. revealing every tooltip and dropdown menu.
                compound.isPseudoElement = true;
            if (i < n && part[i] == '(')
            {
                int d = 0;
                while (i < n)
                {
                    if (part[i] == '(') d++;
                    else if (part[i] == ')') { d--; i++; if (d == 0) break; continue; }
                    i++;
                }
            }
        }
        else if (isIdentChar(part[i]))
        {
            auto start = i;
            while (i < n && isIdentChar(part[i])) i++;
            if (compound.typeName.length == 0 || compound.typeName == "*")
                compound.typeName = part[start .. min(i, part.length)].toLower();
        }
        else i++;
    }
}

private bool isIdentChar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_';
}

/// Parse a declaration block text into declarations.
private Declaration[] parseDeclarations(string text){
    Declaration[] result;
    size_t i = 0;
    const n = text.length;
    while (i < n)
    {
        // Find the next colon that is not inside parens/strings.
        ptrdiff_t colon = -1;
        int parens = 0;
        for (auto j = i; j < n; j++)
        {
            if (text[j] == '(') parens++;
            else if (text[j] == ')') parens--;
            else if (text[j] == ':' && parens == 0) { colon = j; break; }
            if (text[j] == ';') break;
        }
        if (colon < 0) break;
        auto propEnd = colon;
        // Trim trailing whitespace from property.
        while (propEnd > i && (text[propEnd - 1] == ' ' || text[propEnd - 1] == '\t' ||
            text[propEnd - 1] == '\n' || text[propEnd - 1] == '\r')) propEnd--;
        auto property = text[i .. propEnd].strip().toLower();
        if (property.length == 0) { i = colon + 1; continue; }
        // Find the value terminator (; or end of block).
        ptrdiff_t semi = -1;
        parens = 0;
        for (auto j = colon + 1; j < n; j++)
        {
            if (text[j] == '(') parens++;
            else if (text[j] == ')') parens--;
            else if (text[j] == ';' && parens == 0) { semi = j; break; }
        }
        auto valueEnd = semi < 0 ? n : semi;
        auto rawValue = text[colon + 1 .. valueEnd].strip();
        bool important = false;
        // Detect !important
        auto bang = lastIndexOf(rawValue, "!");
        if (bang >= 0)
        {
            const tail = rawValue[bang + 1 .. $].strip().toLower();
            if (tail == "important") { important = true; rawValue = rawValue[0 .. bang].strip(); }
        }
        if (rawValue.length)
        {
            // `font` is a shorthand (CSS 2.1 15.7). Expand it here, at the
            // position the declaration occupies, so its longhands take part in
            // the cascade in document order like any other declaration. The
            // engine previously carried `font` through as an ordinary property
            // that nothing consumed, so a page lost its font-size, family,
            // weight and line-height at once: `font:16px/20px X` fell through to
            // the "font-size + 8px" leading, a 24px line box for 16px text
            // instead of 20px, and every following line drifted down the page.
            if (property == "font")
            {
                if (!expandFontShorthand(result, rawValue, important))
                    result ~= Declaration(property, rawValue, important);
            }
            else
                result ~= Declaration(property, rawValue, important);
        }
        i = semi < 0 ? n : semi + 1;
    }
    return result;
}

/**
 * Expand a `font` shorthand value into the longhands this renderer applies:
 * `[ <font-style> || <font-variant> || <font-weight> || <font-stretch> ]?
 * <font-size> [ / <line-height> ]? <font-family>`.
 *
 * Returns false when the value is not a shorthand this understands (`inherit`,
 * a system font keyword, or a malformed value), so the caller can keep the
 * original declaration and lose nothing.
 */
private bool expandFontShorthand(ref Declaration[] result, string value,
    bool important)
{
    import std.array : join;

    switch (value.strip().toLower())
    {
        // CSS-wide keywords and the system font keywords are not a font
        // shorthand: leave them for the ordinary property path.
        case "inherit", "initial", "unset", "revert", "revert-layer",
            "caption", "icon", "menu", "message-box", "small-caption",
            "status-bar":
            return false;
        default:
            break;
    }

    auto tokens = value.split();
    if (tokens.length < 2) return false;   // a size and a family are required

    string fontStyle = "normal";
    string fontVariant = "normal";
    string fontWeight = "normal";
    string fontStretch = "normal";

    // Leading keywords, in any order, up to the font size. Every slot they can
    // fill starts out `normal`, and the shorthand resets the ones it omits, so
    // leaving an omitted slot at `normal` is the specified result.
    size_t i = 0;
    while (i + 1 < tokens.length)
    {
        const t = tokens[i].toLower();
        if (t == "italic" || t == "oblique") fontStyle = t;
        else if (t == "small-caps") fontVariant = t;
        else if (t == "bold" || t == "bolder" || t == "lighter") fontWeight = t;
        else if (t == "condensed" || t == "expanded" || t == "semi-condensed" ||
            t == "semi-expanded" || t == "extra-condensed" ||
            t == "extra-expanded" || t == "ultra-condensed" ||
            t == "ultra-expanded") fontStretch = t;
        else if (t == "normal") { /* any one of the four slots above */ }
        else if (t.length == 3 && t[1] == '0' && t[2] == '0' &&
            t[0] >= '1' && t[0] <= '9') fontWeight = t;   // 100 .. 900
        else break;   // the font size starts here
        i++;
    }
    if (i >= tokens.length) return false;

    auto sizeToken = tokens[i];
    string lineHeight;
    const slash = indexOf(sizeToken, '/');
    if (slash >= 0)
    {
        // `16px/20px` in a single token.
        lineHeight = sizeToken[slash + 1 .. $].strip();
        sizeToken = sizeToken[0 .. slash].strip();
    }
    else if (i + 2 < tokens.length && tokens[i + 1] == "/")
    {
        // Spaced form: `16px / 20px Arial`.
        lineHeight = tokens[i + 2];
        i += 2;
    }

    bool sizeOk = sizeToken.length > 0 &&
        (sizeToken[0] == '.' || (sizeToken[0] >= '0' && sizeToken[0] <= '9'));
    if (!sizeOk)
        switch (sizeToken.toLower())
        {
            case "xx-small", "x-small", "small", "medium", "large",
                "x-large", "xx-large", "smaller", "larger":
                sizeOk = true;
                break;
            default:
                break;
        }
    if (!sizeOk) return false;

    if (i + 1 >= tokens.length) return false;
    const family = join(tokens[i + 1 .. $], " ");
    if (family.length == 0) return false;

    result ~= Declaration("font-style", fontStyle, important);
    result ~= Declaration("font-variant", fontVariant, important);
    result ~= Declaration("font-weight", fontWeight, important);
    result ~= Declaration("font-stretch", fontStretch, important);
    result ~= Declaration("font-size", sizeToken, important);
    if (lineHeight.length)
        result ~= Declaration("line-height", lineHeight, important);
    result ~= Declaration("font-family", family, important);
    return true;
}

/// Test whether one selector matches an element.
bool selectorMatches(in Selector sel, Element element)
{
    // Match the main compound.
    if (!compoundMatches(sel, element)) return false;
    // Walk each ancestor selector from nearest to farthest.
    auto current = element;
    // `parseSelector` fills `descendants` nearest-first, and this walk climbs
    // from the element upward (`current = target`), so it must consume them in
    // that same order. Iterating them in reverse matched the OUTERMOST selector
    // first - `.homepage` was found too low, below which the inner compounds
    // could no longer be found - so any selector with two or more ancestors
    // (`.homepage .copy-banner p em`) silently never matched. One-ancestor
    // selectors were unaffected, which is why this hid for so long.
    foreach (idx, desc; sel.descendants)
    {
        auto combinator = (idx < sel.combinators.length) ? sel.combinators[idx] : "";
        if (combinator == ">")
        {
            // The ancestor must be the DIRECT parent of the current element.
            auto target = current.parent;
            if (target is null || !compoundMatches(desc, target)) return false;
            current = target;
        }
        else if (combinator == "+")
        {
            // The ancestor must be the immediately-preceding element sibling.
            auto prev = previousElementSibling(current);
            if (prev is null || !compoundMatches(desc, prev)) return false;
            current = prev;
        }
        else
        {
            // Descendant (space) combinator: walk up the ancestor chain.
            bool found = false;
            auto a = current.parent;
            while (a !is null)
            {
                if (compoundMatches(desc, a)) { found = true; current = a; break; }
                a = a.parent;
            }
            if (!found) return false;
        }
    }
    return true;
}

private Element previousElementSibling(Element element)
{
    if (element.parent is null) return null;
    Element prev = null;
    foreach (child; element.parent.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce is element) return prev;
        prev = ce;
    }
    return null;
}

/// Is there an element sibling before `e` (so `:first-child` fails)?
private bool hasElementBefore(Element e)
{
    if (e.parent is null) return false;
    foreach (child; e.parent.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce is e) return false;
        return true;
    }
    return false;
}

/// Is there an element sibling after `e` (so `:last-child` fails)?
private bool hasElementAfter(Element e)
{
    if (e.parent is null) return false;
    bool seen = false;
    foreach (child; e.parent.children)
    {
        auto ce = cast(Element) child;
        if (ce is null) continue;
        if (ce is e) { seen = true; continue; }
        if (seen) return true;
    }
    return false;
}

private bool compoundMatches(in Selector compound, Element element)
{
    // `::before`/`::after` are generated content, not real elements.
    if (compound.isPseudoElement) return false;
    if (compound.isRoot && element.parent !is null) return false;
    // `:not(...)`: matching any argument disqualifies the element.
    foreach (neg; compound.negations)
        if (compoundMatches(neg, element)) return false;
    if (compound.idName.length && !element.hasId(compound.idName)) return false;
    if (compound.className.length && !element.hasClass(compound.className)) return false;
    foreach (extra; compound.extraClasses)
        if (!element.hasClass(extra)) return false;
    if (compound.typeName.length && compound.typeName != "*" && element.tag != compound.typeName)
        return false;
    if (compound.attrName.length)
    {
        auto it = compound.attrName in element.attrs;
        if (it is null) return false;
        if (compound.attrHasValue && *it != compound.attrValue) return false;
    }
    // Interaction state (`:hover`/`:focus`/`:active`), structural
    // (`:first-child`/`:last-child`) and form (`:checked`) pseudo-classes.
    if (compound.isHover && !element.hovered) return false;
    if (compound.isFocus && !element.focused) return false;
    if (compound.isActive && !element.active) return false;
    if (compound.isChecked && ("checked" in element.attrs) is null) return false;
    if (compound.isFirstChild && hasElementBefore(element)) return false;
    if (compound.isLastChild && hasElementAfter(element)) return false;
    return true;
}

/// Compute the specificity of a selector. (id, class, type)
struct Specificity
{
    int idCount;
    int classCount;
    int typeCount;

    bool opGreater(in Specificity other) const
    {
        if (idCount != other.idCount) return idCount > other.idCount;
        if (classCount != other.classCount) return classCount > other.classCount;
        return typeCount > other.typeCount;
    }
}

Specificity specificityOf(in Selector sel)
{
    Specificity spec;
    if (sel.idName.length) spec.idCount = 1;
    if (sel.className.length) spec.classCount = 1;
    spec.classCount += cast(int) sel.extraClasses.length;
    if (sel.attrName.length) spec.classCount++;
    if (sel.typeName.length && sel.typeName != "*") spec.typeCount = 1;
    foreach (desc; sel.descendants)
    {
        if (desc.idName.length) spec.idCount++;
        if (desc.className.length) spec.classCount++;
        spec.classCount += cast(int) desc.extraClasses.length;
        if (desc.attrName.length) spec.classCount++;
        if (desc.typeName.length && desc.typeName != "*") spec.typeCount++;
    }
    return spec;
}

private bool isUniversal(in Selector sel)
{
    return sel.typeName == "*" && sel.className.length == 0 && sel.idName.length == 0 &&
        sel.extraClasses.length == 0 && sel.attrName.length == 0 && sel.descendants.length == 0;
}

/**
 * Compute the cascade for one element given a rule list.
 *
 * Returns a map from property to (value, important). The caller resolves the
 * final value by giving `!important` declarations priority and then using
 * specificity, then document order.
 */
string[string] cascadeFor(Element element, in Rule[] rules)
{
    int[] all = new int[rules.length];
    foreach (i; 0 .. rules.length) all[i] = cast(int) i;
    return cascadeFor(element, rules, all);
}

/// Rule positions that can match `element`, ascending.
///
/// Rule indexing exists because `cascadeFor` scanned every rule for every
/// element: on a real page (2274 rules) style resolution cost ~500x layout.
/// A selector can only match when its rightmost compound - the Selector itself,
/// since `descendants` holds the ancestors - matches, so bucketing rules by that
/// compound's id, class or tag makes the per-element candidate set tiny.
struct RuleIndex
{
    int[][string] byId;
    int[][string] byClass;
    int[][string] byTag;
    int[] universal;   /// last compound with no id/class/tag: always a candidate
}

RuleIndex buildRuleIndex(in Rule[] rules)
{
    RuleIndex index;
    foreach (i, ref rule; rules)
        foreach (sel; rule.selectors)
        {
            // Pseudo-element selectors describe generated content; the
            // ::before/::after lists are matched separately and stay linear.
            if (sel.isPseudoElement) continue;
            const int at = cast(int) i;
            if (sel.idName.length) index.byId[sel.idName] ~= at;
            else if (sel.className.length) index.byClass[sel.className] ~= at;
            else if (sel.typeName.length && sel.typeName != "*")
            {
                // `compoundMatches` compares the tag exactly against the
                // element's lower-cased tag, so a mixed-case type selector goes
                // to `universal` rather than risk a missed match.
                if (typeSelectorIsLower(sel.typeName)) index.byTag[sel.typeName] ~= at;
                else index.universal ~= at;
            }
            else index.universal ~= at;
        }
    return index;
}

/// True when a tag selector is already lower case (so it can key `byTag`).
private bool typeSelectorIsLower(string name)
{
    foreach (ch; name) if (ch >= 'A' && ch <= 'Z') return false;
    return true;
}

/// Candidate rule positions for `element`, ascending. A superset of every rule
/// whose selectors can match, so the cascade result is identical to the scan.
int[] candidatesFor(in RuleIndex index, Element element)
{
    int[] out_;
    void add(const int[] list) { out_ ~= list; }
    auto idAttr = "id" in element.attrs;
    if (idAttr !is null)
    {
        if (auto p = (*idAttr) in index.byId) add(*p);
    }
    // Split exactly as `Element.hasClass` does, so the candidate set can never
    // miss a class the matcher would accept.
    auto classAttr = "class" in element.attrs;
    if (classAttr !is null)
        foreach (c; (*classAttr).split(" "))
        {
            if (!c.length) continue;
            if (auto p = c in index.byClass) add(*p);
        }
    if (auto p = element.tag in index.byTag) add(*p);
    add(index.universal);
    // The buckets overlap, so duplicates are expected. Sorting once and then
    // dropping repeats linearly is far cheaper than a scan per insertion: a
    // common tag or class can contribute hundreds of candidate rules.
    import std.algorithm.sorting : sort;
    out_.sort;
    size_t kept = 0;
    foreach (i; out_)
        if (kept == 0 || out_[kept - 1] != i) out_[kept++] = i;
    out_.length = kept;
    return out_;
}

/// Cascade over a pre-filtered ascending list of rule positions. `indices` must
/// be a superset of the matching rules in document order; the winner logic
/// depends on nothing else (it compares specificity, then position).
string[string] cascadeFor(Element element, in Rule[] rules, scope const int[] indices)
{
    // Winner for each property: index into rules, and its specificities.
    // Store (ruleIndex, specificity) per property. Because cascadeFor returns
    // a map, we compute the winner inline.
    string[string] result;
    ptrdiff_t[string] ruleIndex;  // rule that currently wins per property
    ptrdiff_t[string] declOrder;  // and the winning declaration's sequence
    Specificity[string] ruleSpec;
    bool[string] ruleImportant;
    ptrdiff_t seq;                // document order across all declarations

    foreach (idx; indices)
    {
        const rule = rules[idx];
        // Find the highest-specificity matching selector in this rule's list.
        Specificity bestSpec;
        bool matches = false;
        foreach (sel; rule.selectors)
        {
            if (selectorMatches(sel, element))
            {
                matches = true;
                auto spec = specificityOf(sel);
                if (spec.opGreater(bestSpec)) bestSpec = spec;
            }
        }
        if (!matches) continue;
        foreach (decl; rule.declarations)
        {
            const thisSeq = seq++;
            auto prop = decl.property;
            auto current = ruleIndex.get(prop, -1);
            if (current == -1)
            {
                ruleIndex[prop] = idx;
                declOrder[prop] = thisSeq;
                ruleSpec[prop] = bestSpec;
                result[prop] = decl.value;
                ruleImportant[prop] = decl.important;
                continue;
            }
            // Determine if new decl wins.
            bool newWins;
            if (decl.important != ruleImportant.get(prop, false))
                newWins = decl.important;
            else
            {
                auto spec = bestSpec;
                auto currentSpec = ruleSpec.get(prop, Specificity.init);
                if (spec.opGreater(currentSpec)) newWins = true;
                else if (!currentSpec.opGreater(spec))
                    // Ties go to the later declaration (CSS 2.1 6.4.1): a later
                    // rule wins, and within one rule a later declaration wins.
                    // Comparing only the rule index meant the FIRST declaration
                    // of a property won inside a single rule, so the very common
                    // shorthand-then-longhand override
                    // (`font: 16px/20px Arial; line-height: 30px`) was ignored.
                    newWins = idx > current ||
                        (idx == current && thisSeq > declOrder.get(prop, -1));
                else newWins = false;
            }
            if (newWins)
            {
                ruleIndex[prop] = idx;
                declOrder[prop] = thisSeq;
                ruleSpec[prop] = bestSpec;
                result[prop] = decl.value;
                ruleImportant[prop] = decl.important;
            }
        }
    }
    return result;
}

unittest
{
    // --- `font` shorthand expansion (CSS 2.1 15.7) ---
    // Before this the shorthand reached the cascade as an inert `font`
    // property, so a page lost its font size, family, weight and line-height
    // together: `font:16px/20px X` then took the engine's "font-size + 8px"
    // leading and every following line sat lower than the reference.
    auto rules = parseStylesheet(
        `p { font: italic bold 16px/20px Arial, sans-serif; }
         h1 { font: 700 2rem Georgia, serif; }
         code { font: 12px/1.5 monospace; }
         pre { font: inherit; }
         div { font: 16px/20px Arial; line-height: 30px; }`);
    auto p = new Element("p");
    auto cascade = cascadeFor(p, rules);
    assert(cascade.get("font-size", "") == "16px",
        "font-size from the shorthand, got '" ~ cascade.get("font-size", "") ~ "'");
    assert(cascade.get("line-height", "") == "20px",
        "line-height from the shorthand, got '" ~ cascade.get("line-height", "") ~ "'");
    assert(cascade.get("font-weight", "") == "bold",
        "font-weight from the shorthand, got '" ~ cascade.get("font-weight", "") ~ "'");
    assert(cascade.get("font-style", "") == "italic",
        "font-style from the shorthand, got '" ~ cascade.get("font-style", "") ~ "'");
    assert(cascade.get("font-family", "") == "Arial, sans-serif",
        "font-family keeps the whole family list, got '" ~
        cascade.get("font-family", "") ~ "'");
    // A multi-word family, a keyword size is not required, and a numeric
    // weight in the leading keyword group.
    auto h1c = cascadeFor(new Element("h1"), rules);
    assert(h1c.get("font-size", "") == "2rem" && h1c.get("font-weight", "") == "700" &&
        h1c.get("font-family", "") == "Georgia, serif",
        "`font: 700 2rem Georgia, serif` must expand fully");
    auto codec = cascadeFor(new Element("code"), rules);
    assert(codec.get("line-height", "") == "1.5",
        "a bare-number line-height survives, got '" ~ codec.get("line-height", "") ~ "'");
    // A longhand written after the shorthand in the SAME rule wins.
    auto divc = cascadeFor(new Element("div"), rules);
    assert(divc.get("line-height", "") == "30px",
        "a later longhand in the same rule must win, got '" ~
        divc.get("line-height", "") ~ "'");
    // `inherit` is a CSS-wide keyword, not a family.
    auto prec = cascadeFor(new Element("pre"), rules);
    assert(prec.get("font-family", "") == "",
        "`font: inherit` must not be read as a family list");
}

unittest
{
    auto rules = parseStylesheet(`h1 { color: red; } #box { background: #00ff00; } .note { color: blue; }`);
    import std.conv : to;
    assert(rules.length == 3, "expected 3 rules, got " ~ rules.length.to!string);
    auto el = new Element("h1");
    auto cascade = cascadeFor(el, rules);
    assert(cascade.get("color", "") == "red", "h1 should be red");
}

unittest
{
    import std.conv : to;

    // --- @media media types: screen/print/all ---
    // Parse at a viewport where every rule matches, so they all get stored;
    // applyMediaRules then re-filters on the queried viewport.
    auto rules = parseStylesheet(`@media print { .a { color: red; } }
        @media screen { .b { color: blue; } }
        @media screen and (max-width: 400px) { .c { color: green; } }
        @media print and (max-width: 400px) { .d { color: orange; } }`, 400, 800);
    assert(rules.length == 4, "four rules parsed, got " ~ rules.length.to!string);

    // On a screen renderer, the print rule never applies.
    setScreenMedia(true);
    auto active = applyMediaRules(rules, 1280, 800);
    assert(active.length == 1, "only .b applies on a wide screen, got " ~ active.length.to!string);
    assert(active[0].media.mediaType == "screen", "the surviving rule should be media screen");

    // @media screen and (max-width: 400px) matches only <= 400.
    auto activeNarrow = applyMediaRules(rules, 400, 800);
    assert(activeNarrow.length == 2, "at 400 both .b and .c apply, got " ~ activeNarrow.length.to!string);
    foreach (r; activeNarrow)
        assert(r.media.mediaType == "screen", "print rules must never apply on screen");
    auto activeWide2 = applyMediaRules(rules, 401, 800);
    assert(activeWide2.length == 1, "at 401 only .b applies, got " ~ activeWide2.length.to!string);

    // Bare @media print / @media screen.
    auto printOnly = parseStylesheet(`@media print { .x { color: black; } }`, 100, 100);
    assert(printOnly.length == 1, "bare @media print parses to one rule");
    auto printActive = applyMediaRules(printOnly, 100, 100);
    assert(printActive.length == 0, "bare @media print does not apply on screen");

    auto screenOnly = parseStylesheet(`@media screen { .y { color: blue; } }`, 100, 100);
    assert(screenOnly.length == 1, "bare @media screen parses to one rule");
    auto screenActive = applyMediaRules(screenOnly, 100, 100);
    assert(screenActive.length == 1, "bare @media screen applies on screen");
}

version (unittest)
unittest
{
    import std.conv : to;
    // A width condition that does not match must not apply. (Regression: the
    // type-only fallback used to return an always-matching query because the
    // default media type is "all", so e.g. `max-width: 1180px` applied at 1350.)
    auto rules = parseStylesheet(`@media (max-width: 1180px) { .a { color: red; } }
        .b { color: blue; }`, 1350, 800);
    assert(applyMediaRules(rules, 1350, 800).length == 1, "only .b applies at 1350");
    assert(applyMediaRules(rules, 1180, 800).length == 2, "the max-width:1180 rule applies at 1180");
    assert(applyMediaRules(rules, 1280, 800).length == 1, "max-width:1180 must not apply at 1280");
}

version (unittest)
unittest
{
    import auroraweb.dom : Element;

    // An unknown at-rule must not desynchronise the parse. `@starting-style`
    // contains no `;`, so the old skip-to-semicolon resumed INSIDE the next
    // rule and consumed it as garbage selector text. django's stylesheet has
    // exactly this shape:
    //   @starting-style{header nav.active{max-height:0}}
    //   @media screen and (min-width: 1280px){header nav{display:block;...}}
    // and the swallowed rule was the one that un-hides the header's main nav,
    // so that whole menu vanished from the render.
    auto rules = parseStylesheet(
        `header nav{display:none;max-height:0}` ~
        `@starting-style{header nav.active{max-height:0}}` ~
        `@media screen and (min-width: 1280px){` ~
        `header nav{display:block;max-height:none}` ~
        `header nav ul{display:flex}}`, 1280, 800);
    auto active = applyMediaRules(rules, 1280, 800);

    auto header = new Element("header");
    auto nav = new Element("nav");
    nav.parent = header;
    header.children ~= nav;
    header.elements ~= nav;
    auto index = buildRuleIndex(active);

    auto cascade = cascadeFor(nav, active, candidatesFor(index, nav));
    assert(cascade.get("display", "") == "block",
        "the @media rule after @starting-style must win: display was '" ~
        cascade.get("display", "") ~ "'");

    // The rule that followed the swallowed one must keep its own selector.
    auto ul = new Element("ul");
    ul.parent = nav;
    nav.children ~= ul;
    nav.elements ~= ul;
    auto ulCascade = cascadeFor(ul, active, candidatesFor(index, ul));
    assert(ulCascade.get("display", "") == "flex",
        "header nav ul{display:flex} must survive the parse: got '" ~
        ulCascade.get("display", "") ~ "'");
}

unittest
{
    // --- Child combinator `>` and adjacent sibling `+` ---
    Element mk(string tag, Element parent)
    {
        auto e = new Element(tag);
        e.parent = parent;
        if (parent !is null) { parent.children ~= e; parent.elements ~= e; }
        return e;
    }

    auto div = mk("div", null);
    auto child1 = mk("p", div);
    auto section = mk("section", div);
    auto deep = mk("p", section);   // grandchild: not a direct child of div
    auto sib1 = mk("p", div);
    auto sib2 = mk("p", div);

    Selector direct = parseSelector("div > p");
    assert(selectorMatches(direct, child1), "div > p must match a direct child");
    assert(!selectorMatches(direct, deep), "div > p must NOT match a grandchild under a section");
    assert(selectorMatches(direct, sib1), "div > p must match sibling direct children");
    assert(selectorMatches(direct, sib2), "div > p must match sibling direct children");

    Selector desc = parseSelector("div p");
    assert(selectorMatches(desc, deep), "div p must match a nested descendant");

    // div children order: child1(p), section, sib1(p), sib2(p).
    Selector adjacent = parseSelector("p + p");
    assert(!selectorMatches(adjacent, child1), "p + p must NOT match the first p (no preceding p sibling)");
    assert(!selectorMatches(adjacent, sib1), "p + p must NOT match sib1 (preceding sibling is section)");
    assert(selectorMatches(adjacent, sib2), "p + p must match sib2 (sib1 precedes it)");
    assert(!selectorMatches(adjacent, deep), "p + p must NOT match deep (no preceding sibling)");
}

unittest
{
    // --- Attribute selectors [attr] and [attr=value] ---
    auto a = new Element("a");
    a.attrs["href"] = "https://example.com/";
    auto div = new Element("div");
    auto p = new Element("p");
    p.attrs["class"] = "note";

    Selector hasHref = parseSelector("a[href]");
    assert(selectorMatches(hasHref, a), "a[href] must match an anchor with href");
    assert(!selectorMatches(hasHref, div), "a[href] must NOT match a div without href");

    Selector hrefVal = parseSelector(`a[href="https://example.com/"]`);
    assert(selectorMatches(hrefVal, a), "a[href=\"...\"] must match the exact href");
    auto b = new Element("a");
    b.attrs["href"] = "https://other.example.com/";
    assert(!selectorMatches(hrefVal, b), "a[href=\"...\"] must NOT match a different href");

    Selector classPresence = parseSelector("[class]");
    assert(selectorMatches(classPresence, p), "[class] must match an element with a class attribute");
    assert(!selectorMatches(classPresence, div), "[class] must NOT match an element without class");

    // Combined with a class.
    Selector combined = parseSelector("p.note[class]");
    assert(selectorMatches(combined, p), "p.note[class] must match p with class note");
}

unittest
{
    // --- `:not(<simple selector>)` ---
    // django's `header nav li>:not(.search){padding:10px}` carries the whole
    // menu spacing. Treating `:not` as an unevaluatable pseudo-class poisoned
    // the compound, so that rule never applied and the menu items ran together
    // with no spacing at all.
    Element mk(string tag, Element parent)
    {
        auto e = new Element(tag);
        e.parent = parent;
        if (parent !is null) { parent.children ~= e; parent.elements ~= e; }
        return e;
    }

    auto header = mk("header", null);
    auto nav = mk("nav", header);
    auto ul = mk("ul", nav);
    auto li = mk("li", ul);
    auto plain = mk("a", li);
    plain.attrs["class"] = "menu-link";
    auto search = mk("a", li);
    search.attrs["class"] = "search";

    Selector noSearch = parseSelector("li>:not(.search)");
    assert(selectorMatches(noSearch, plain), "li>:not(.search) must match an ordinary child");
    assert(!selectorMatches(noSearch, search), "li>:not(.search) must NOT match the search child");

    // A negation next to a type name in the same compound.
    Selector aNoSearch = parseSelector("a:not(.search)");
    assert(selectorMatches(aNoSearch, plain), "a:not(.search) must match a plain anchor");
    assert(!selectorMatches(aNoSearch, search), "a:not(.search) must NOT match .search");

    // The selector-list filter must not discard a compound whose only part is
    // the negation, which is exactly the shape of django's rule.
    auto rules = parseStylesheet(`header nav li>:not(.search){padding:10px}`, 1280, 800);
    assert(rules.length == 1, "a `:not()` rule must survive parsing");
    auto index = buildRuleIndex(rules);
    auto cascade = cascadeFor(plain, rules, candidatesFor(index, plain));
    assert(cascade.get("padding", "") == "10px",
        "the `:not(.search)` rule must reach an ordinary child: got '" ~
        cascade.get("padding", "") ~ "'");
}

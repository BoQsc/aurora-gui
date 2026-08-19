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
    string idName;          /// "#bar"
    Selector[] descendants; /// Ancestor selectors for descendant combinator.
    string[] combinators;   /// Per-descendant combinator: "", ">", "+".
    string attrName;        /// "[href]" presence attribute selector.
    string attrValue;       /// "[href=\"...\"]" value test.
    bool attrHasValue;      /// Whether a value was given.
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
        foreach (group; groups)
        {
            MediaQuery g;
            g.mediaType = typeKeyword;
            bool hasCond = false;
            auto parts = group.split("and");
            bool ok = true;
            foreach (partRaw; parts)
            {
                auto part = partRaw.strip();
                if (part.length == 0) continue;
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
            }
            if (hasCond && g.matches(viewportWidth, viewportHeight))
                return g;  // this OR-group matches
        }
        // Bare `@media screen { ... }` or `@media print { ... }`: no length
        // condition, but the media type still decides whether it applies.
        if (typeKeyword == "screen" || typeKeyword == "print" || typeKeyword == "all")
        {
            MediaQuery typeOnly;
            typeOnly.mediaType = typeKeyword;
            typeOnly.anyCondition = true;
            return typeOnly;
        }
        // No group matched; return an empty condition that will not match.
        return MediaQuery(-2, -2, -2, -2, false, false, "");
    }

    void skipImport()
    {
        // @import url(...); — skip to semicolon.
        auto semi = indexOf(css, ";", i);
        i = semi < 0 ? n : semi + 1;
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
            if (css[j] == '@') { skipImport(); continue; }
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
                // Only include inner rules if the media query matches.
                if (mq.matches(viewportWidth, viewportHeight) || mq.anyCondition)
                    parseInner(brace + 1, k > 0 ? k - 1 : k, mq);
                i = k;
                continue;
            }
            skipImport();
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
        if (!sel.isUniversal && sel.typeName.length == 0 && sel.className.length == 0 &&
            sel.idName.length == 0 && sel.attrName.length == 0)
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
    result.idName = leaf.idName;
    result.attrName = leaf.attrName;
    result.attrValue = leaf.attrValue;
    result.attrHasValue = leaf.attrHasValue;
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
            while (i < n && part[i] != '.' && part[i] != '#' && part[i] != '[') i++;
            if (start > i) compound.className = "";
            else compound.className = part[start .. min(i, part.length)];
        }
        else if (part[i] == '#')
        {
            auto start = i + 1;
            i = start;
            while (i < n && part[i] != '.' && part[i] != '#' && part[i] != '[') i++;
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
            result ~= Declaration(property, rawValue, important);
        i = semi < 0 ? n : semi + 1;
    }
    return result;
}

/// Test whether one selector matches an element.
bool selectorMatches(in Selector sel, Element element)
{
    // Match the main compound.
    if (!compoundMatches(sel, element)) return false;
    // Walk each ancestor selector from nearest to farthest.
    auto current = element;
    foreach_reverse (idx, desc; sel.descendants)
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

private bool compoundMatches(in Selector compound, Element element)
{
    if (compound.idName.length && !element.hasId(compound.idName)) return false;
    if (compound.className.length && !element.hasClass(compound.className)) return false;
    if (compound.typeName.length && compound.typeName != "*" && element.tag != compound.typeName)
        return false;
    if (compound.attrName.length)
    {
        auto it = compound.attrName in element.attrs;
        if (it is null) return false;
        if (compound.attrHasValue && *it != compound.attrValue) return false;
    }
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
    if (sel.attrName.length) spec.classCount++;
    if (sel.typeName.length && sel.typeName != "*") spec.typeCount = 1;
    foreach (desc; sel.descendants)
    {
        if (desc.idName.length) spec.idCount++;
        if (desc.className.length) spec.classCount++;
        if (desc.attrName.length) spec.classCount++;
        if (desc.typeName.length && desc.typeName != "*") spec.typeCount++;
    }
    return spec;
}

private bool isUniversal(in Selector sel)
{
    return sel.typeName == "*" && sel.className.length == 0 && sel.idName.length == 0 &&
        sel.attrName.length == 0 && sel.descendants.length == 0;
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
    // Winner for each property: index into rules, and its specificities.
    // Store (ruleIndex, specificity) per property. Because cascadeFor returns
    // a map, we compute the winner inline.
    string[string] result;
    ptrdiff_t[string] ruleIndex;  // rule that currently wins per property
    Specificity[string] ruleSpec;
    bool[string] ruleImportant;

    foreach (idx, ref rule; rules)
    {
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
            auto prop = decl.property;
            auto current = ruleIndex.get(prop, -1);
            if (current == -1)
            {
                ruleIndex[prop] = idx;
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
                else if (!currentSpec.opGreater(spec)) newWins = idx > current; // later wins ties
                else newWins = false;
            }
            if (newWins)
            {
                ruleIndex[prop] = idx;
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

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
    /// `prefers-color-scheme` requirement: 0 = no such condition, 1 = dark
    /// required, 2 = light required. The condition is recorded, not resolved at
    /// parse time, and `matches` evaluates it against the live preference, so
    /// rules stored from an earlier parse are re-filtered correctly if the
    /// preference changes.
    int scheme;

    bool matches(int vw, int vh) const
    {
        if (scheme == 1 && !prefersDarkScheme()) return false;
        if (scheme == 2 && prefersDarkScheme()) return false;
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

/// Whether `prefers-color-scheme` currently reports `dark`.
bool prefersDarkScheme()
{
    return g_prefersDark;
}

/// Override the reported colour scheme, for a host application that offers its
/// own light/dark setting instead of following the platform.
void setPrefersDarkScheme(bool dark)
{
    g_prefersDark = dark;
}

/// The colour scheme reported to `prefers-color-scheme`: the platform's
/// application preference, which is what a browser answers from. Windows keeps
/// it in the Personalize key as `AppsUseLightTheme`; elsewhere the engine
/// reports light. Read through the native registry API - no shell, no network.
private bool initialPrefersDark()
{
    version (Windows)
    {
        import core.sys.windows.windef : DWORD, HKEY;
        import core.sys.windows.winnt : KEY_READ;
        import core.sys.windows.winreg : HKEY_CURRENT_USER, REG_DWORD,
            RegCloseKey, RegOpenKeyExW, RegQueryValueExW;

        HKEY key;
        if (RegOpenKeyExW(HKEY_CURRENT_USER,
            ("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"w).ptr,
            0, KEY_READ, &key) != 0)
            return false;                   // no personalization key: stay light
        scope (exit) RegCloseKey(key);
        DWORD value;
        DWORD size = value.sizeof;
        DWORD kind;
        if (RegQueryValueExW(key, ("AppsUseLightTheme"w).ptr, null, &kind,
            &value, &size) != 0)
            return false;
        if (kind != REG_DWORD || size != value.sizeof)
            return false;
        return value == 0;                  // 0 = dark, 1 = light
    }
    else
        return false;
}

/// The live preference. Initialized from the platform at startup and overridable
/// by the host application.
private bool g_prefersDark;

static this()
{
    // Read at run time: the platform query has no compile-time interpretation.
    g_prefersDark = initialPrefersDark();
}

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

/// One `unicode-range` segment: a closed range of code points.
struct FontRange
{
    uint lo;   /// First code point in the segment.
    uint hi;   /// Last code point in the segment (`== lo` for a single one).
}

/// One parsed `@font-face` rule: the family it defines and the first source the
/// engine can actually decode.
struct WebFontFace
{
    string family;      /// `font-family` descriptor, unquoted.
    string weight;      /// `font-weight` descriptor ("400", "bold", "700 900" -> "700").
    string style;       /// `font-style` descriptor ("normal"/"italic"/"oblique").
    string url;         /// First `src` url() whose format we can decode.
    string display;     /// `font-display` descriptor ("auto" when it is absent).
    /// `unicode-range` segments, empty when the descriptor is absent. A subset
    /// face declares the code points it can draw, so a caller can skip the
    /// subsets a document's own text cannot use instead of fetching them all:
    /// Google Fonts serves three to six subsets per weight, of which a page
    /// usually needs one.
    FontRange[] ranges;
}

/**
 * Choose the first source in one `@font-face` `src` descriptor that the engine
 * can decode.
 *
 * The engine shapes with uncompressed sfnt faces, can unwrap a WOFF 1.0
 * container (auroraweb.woff) and can decode a WOFF 2.0 container
 * (auroraweb.woff2: brotli plus the table reconstruction), so `truetype`,
 * `opentype`, `woff` and `woff2` sources are usable; `embedded-opentype` and
 * the legacy `svg` font format are not. A candidate the engine cannot decode is
 * skipped and the next one in the same `src` is tried, which is what a browser
 * does, and only if none is usable does the `font-family` fall back.
 *
 * The format must be compared as a whole name, never as a substring: the legacy
 * `format("embedded-opentype")` candidate that FontAwesome lists *first* used to
 * match an `opentype` search and win, so the engine downloaded the EOT file,
 * failed to load it, and rendered every icon-less page with no FontAwesome at all.
 */
private string pickFontSrc(string value)
{
    foreach (candRaw; value.split(","))
    {
        auto cand = candRaw.strip();
        auto open = indexOf(cand, "url(");
        if (open < 0) continue;
        auto close = indexOf(cand, ")", open);
        if (close < 0) continue;
        auto url = cand[open + 4 .. close].strip().strip("\"'").strip();
        if (url.length == 0) continue;
        // A declared format decides.
        auto formats = fontSrcFormats(cand);
        if (formats.length)
        {
            bool usable = false;
            foreach (f; formats)
                if (f == "truetype" || f == "opentype" || f == "woff" || f == "woff2")
                    usable = true;
            if (!usable) continue;
            return url;
        }
        // Without a format hint, only the extensions this engine certainly
        // cannot read are rejected: a hintless source may be any sfnt file (or
        // a script that serves one).
        auto path = url.toLower();
        foreach (sep; ["?", "#"])
        {
            auto cut = indexOf(path, sep);
            if (cut >= 0) path = path[0 .. cut];
        }
        if (endsWith(path, ".eot") || endsWith(path, ".svg"))
            continue;
        return url;
    }
    return null;
}

/// Every format name a `src` candidate declares: `format("woff")` -> ["woff"].
private string[] fontSrcFormats(const string candidate)
{
    string[] names;
    size_t i = 0;
    while (true)
    {
        auto at = indexOf(candidate, "format(", i);
        if (at < 0) break;
        auto open = at + "format(".length - 1;
        auto close = indexOf(candidate, ")", open);
        if (close < 0) break;
        // `format("woff")`, `format(woff)`, `format("woff-variations", "woff")`.
        foreach (raw; candidate[open + 1 .. close].split(","))
        {
            auto name = raw.strip().strip("\"'").strip().toLower();
            if (name.length) names ~= name;
        }
        i = close + 1;
    }
    return names;
}

/// `true` when `value` ends with `suffix` (ASCII, no case folding).
private bool endsWith(string value, string suffix)
{
    return value.length >= suffix.length && value[$ - suffix.length .. $] == suffix;
}

/**
 * Parse the `@font-face` rules of a stylesheet.
 *
 * Kept separate from `parseStylesheet` so the rule list and its cascade are
 * untouched: a font face is not a style rule and must not take part in selector
 * matching.
 */
WebFontFace[] parseFontFaces(string css)
{
    WebFontFace[] faces;
    size_t i = 0;
    const n = css.length;
    while (i < n)
    {
        auto at = indexOf(css, "@font-face", i);
        if (at < 0) break;
        auto open = indexOf(css, "{", at);
        if (open < 0) break;
        int depth = 0;
        auto k = open;
        while (k < n)
        {
            if (css[k] == '{') depth++;
            else if (css[k] == '}')
            {
                depth--;
                if (depth == 0) break;
            }
            k++;
        }
        const body = css[open + 1 .. (k < n ? k : n)];
        i = k < n ? k + 1 : n;
        WebFontFace face;
        foreach (declRaw; body.split(";"))
        {
            auto decl = declRaw.strip();
            auto colon = indexOf(decl, ":");
            if (colon < 0) continue;
            const prop = decl[0 .. colon].strip().toLower();
            const value = decl[colon + 1 .. $].strip();
            if (prop == "font-family") face.family = value.strip("\"'").strip();
            else if (prop == "font-weight")
            {
                // `font-weight: 100 900` (a variable-font range) is beyond the
                // engine's static face model; the first value is the one a
                // non-variable fallback uses.
                auto sp = indexOf(value, " ");
                face.weight = (sp < 0 ? value : value[0 .. sp]).strip();
            }
            else if (prop == "font-style") face.style = value.toLower();
            else if (prop == "src") face.url = pickFontSrc(value);
            else if (prop == "font-display") face.display = value.toLower();
            else if (prop == "unicode-range") face.ranges = parseUnicodeRange(value);
        }
        if (face.family.length && face.url.length) faces ~= face;
    }
    return faces;
}

/// Parse 1-6 hexadecimal digits into a code point (false when the text is not a
/// hexadecimal number).
private bool hexCodePoint(scope const(char)[] text, out uint code)
{
    if (text.length == 0 || text.length > 6) return false;
    uint acc;
    foreach (c; text)
    {
        uint d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return false;
        acc = acc * 16 + d;
    }
    code = acc;
    return true;
}

/// Parse one `unicode-range` descriptor into code-point segments. A segment that
/// does not parse is dropped; an empty result leaves the face unconstrained.
FontRange[] parseUnicodeRange(string value)
{
    FontRange[] ranges;
    foreach (part; value.split(","))
    {
        auto text = part.strip();
        if (text.length < 3 || (text[0] != 'u' && text[0] != 'U') || text[1] != '+')
            continue;
        text = text[2 .. $];
        uint lo, hi;
        bool ok;
        const dash = indexOf(text, "-");
        if (dash > 0)
            ok = hexCodePoint(text[0 .. dash].strip(), lo)
                && hexCodePoint(text[dash + 1 .. $].strip(), hi);
        else if (indexOf(text, "?") >= 0)
        {
            // `U+04??` spans every code point its question marks can stand for.
            char[] low = text.dup;
            char[] high = text.dup;
            foreach (i, c; text)
                if (c == '?') { low[i] = '0'; high[i] = 'F'; }
            ok = hexCodePoint(low, lo) && hexCodePoint(high, hi);
        }
        else if (hexCodePoint(text, lo))
        {
            hi = lo;
            ok = true;
        }
        if (ok && lo <= hi && hi <= 0x10FFFF) ranges ~= FontRange(lo, hi);
    }
    return ranges;
}

/// `unicode-range` is what lets a page fetch only the subsets its text uses.
unittest
{
    auto faces = parseFontFaces("@font-face{font-family:S;src:url(a.woff2);"
        ~ "unicode-range:U+0000-00FF,U+0131,U+2000-206F}");
    assert(faces.length == 1 && faces[0].ranges.length == 3,
        "every segment of the descriptor is kept");
    assert(faces[0].ranges[0].lo == 0 && faces[0].ranges[0].hi == 0xFF,
        "a range keeps both of its ends");
    assert(faces[0].ranges[1].lo == 0x131 && faces[0].ranges[1].hi == 0x131,
        "a single code point spans itself");
    assert(faces[0].ranges[2].lo == 0x2000 && faces[0].ranges[2].hi == 0x206F,
        "the last segment is kept too");

    // The question marks of `U+04??` stand for any hex digit, and a face that
    // says nothing about its ranges stays unconstrained.
    faces = parseFontFaces("@font-face{font-family:W;src:url(b.woff2);"
        ~ "unicode-range:U+04??}");
    assert(faces[0].ranges.length == 1 && faces[0].ranges[0].lo == 0x400
        && faces[0].ranges[0].hi == 0x4FF, "a wildcard segment spans its nibbles");
    faces = parseFontFaces("@font-face{font-family:N;src:url(c.woff2)}");
    assert(faces[0].ranges.length == 0, "an absent unicode-range constrains nothing");
}

/// `font-display` describes whether text may be painted before a face arrives.
unittest
{
    // Google Fonts' `&display=swap` response declares the descriptor that lets
    // a page paint in the fallback face while the download is in flight.
    auto faces = parseFontFaces("@font-face{font-family:S;"
        ~ "src:url(a.woff2) format('woff2');font-display:swap}");
    assert(faces.length == 1 && faces[0].display == "swap",
        "the font-display descriptor is kept so callers can honour it");

    // A sheet that says nothing gets CSS's own default, which does not swap.
    faces = parseFontFaces("@font-face{font-family:B;src:url(b.woff2) format('woff2')}");
    assert(faces.length == 1 && faces[0].display.length == 0,
        "an absent font-display stays absent, i.e. CSS's `auto`");
}

/// `@font-face` sources are picked by what this engine can decode.
unittest
{
    // FontAwesome's real shape: an EOT candidate first (whose
    // `format("embedded-opentype")` must not read as "opentype"), then WOFF,
    // then TrueType, then the legacy SVG font.
    auto faces = parseFontFaces(
        "@font-face{font-family:FontAwesome;"
        ~ "src:url('../fonts/fontawesome-webfont.eot?v=4.2.0');"
        ~ "src:url('../fonts/fontawesome-webfont.eot?#iefix&v=4.2.0') format('embedded-opentype'),"
        ~ "url('../fonts/fontawesome-webfont.woff?v=4.2.0') format('woff'),"
        ~ "url('../fonts/fontawesome-webfont.ttf?v=4.2.0') format('truetype'),"
        ~ "url('../fonts/fontawesome-webfont.svg?v=4.2.0#fontawesomeregular') format('svg');"
        ~ "font-weight:normal;font-style:normal}");
    assert(faces.length == 1, "one @font-face rule");
    assert(faces[0].family == "FontAwesome", "the family descriptor is unquoted");
    assert(faces[0].url == "../fonts/fontawesome-webfont.woff?v=4.2.0",
        "WOFF is decodable, so it wins over the EOT and SVG candidates");
    assert(faces[0].weight == "normal" && faces[0].style == "normal",
        "the weight and style descriptors are kept");

    // A woff2-only face is decodable (auroraweb.woff2), so the family resolves
    // to the real face a browser would use instead of a substitute.
    faces = parseFontFaces("@font-face{font-family:Only2;"
        ~ "src:url(a.woff2) format('woff2')}");
    assert(faces.length == 1 && faces[0].url == "a.woff2",
        "a woff2-only face resolves to its own source");

    // Google Fonts' modern shape: the woff2 candidate comes first and, being
    // decodable, wins — like a browser that negotiated the newest format.
    faces = parseFontFaces("@font-face{font-family:'Roboto';"
        ~ "src:url(https://fonts.gstatic.com/roboto.woff2) format('woff2'),"
        ~ "url(https://fonts.gstatic.com/roboto.woff) format('woff');"
        ~ "font-weight:700}");
    assert(faces.length == 1 &&
        faces[0].url == "https://fonts.gstatic.com/roboto.woff2",
        "the woff2 candidate of a modern webfont request must be used");
    assert(faces[0].weight == "700", "the numeric weight is kept");

    // Sources without a format hint are judged by extension only where the
    // engine certainly cannot read the file.
    faces = parseFontFaces(
        "@font-face{font-family:A;src:url(fonts/a.ttf)}"
        ~ "@font-face{font-family:B;src:url(fonts/b.eot)}"
        ~ "@font-face{font-family:C;src:url(fonts/c.woff)}"
        ~ "@font-face{font-family:D;src:url(fonts/d.eot?#iefix)}"
        ~ "@font-face{font-family:E;src:local('Helvetica'),url(serve.php?id=7)}"
        ~ "@font-face{font-family:F;src:url(fonts/f.woff2)}");
    assert(faces.length == 4, "four of these six faces have a usable source");
    assert(faces[0].url == "fonts/a.ttf", "a plain TrueType url is usable");
    assert(faces[1].url == "fonts/c.woff", "a plain WOFF url is usable");
    assert(faces[2].family == "E" && faces[2].url == "serve.php?id=7",
        "a hintless, extensionless source is still tried");
    assert(faces[3].family == "F" && faces[3].url == "fonts/f.woff2",
        "a plain WOFF2 url is usable");
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

/**
 * Parse the prelude of an `@media` rule, or of a `window.matchMedia` query:
 * "(max-width: 400px) and (min-width: 100px)".
 *
 * `viewportWidth`/`viewportHeight` are the size the query is read against. A
 * comma-separated OR list keeps its first group that matches there, and the
 * condition of the rest is kept for `applyMediaRules` to re-filter against the
 * real viewport; a caller that knows only the query passes the viewport it is
 * asking about.
 *
 * Module level because both callers share it: the stylesheet parser stores each
 * rule's condition for `applyMediaRules` to re-filter, and `mediaQueryMatches`
 * answers a page's `matchMedia` test — a script's query and the sheet's `@media`
 * block must never disagree about the same condition.
 */
private MediaQuery parseMediaQueryString(string prelude, int viewportWidth,
    int viewportHeight)
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
                // Record the condition and let `matches` resolve it against
                // the live preference. Answering it as an unknown feature
                // (or as "dark never matches") left the query's OTHER
                // conditions, e.g. `min-width: 768px`, to satisfy it, so a
                // page's entire dark-theme block applied on top of its light
                // rules and the two themes mixed: a real homepage kept the
                // light banner background and took the dark theme's mint
                // text, which is unreadable.
                auto scheme = val.toLower();
                if (scheme == "dark") g.scheme = 1;
                else if (scheme == "light") g.scheme = 2;
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

/// Answer a media query string, as `window.matchMedia(query).matches` must.
bool mediaQueryMatches(string query, int viewportWidth, int viewportHeight)
{
    return parseMediaQueryString(query, viewportWidth, viewportHeight)
        .matches(viewportWidth, viewportHeight);
}

/// `matchMedia` and the sheet's `@media` rules answer the same condition the
/// same way, at every viewport width.
unittest
{
    const keep = prefersDarkScheme();
    scope (exit) setPrefersDarkScheme(keep);

    setPrefersDarkScheme(false);
    assert(!mediaQueryMatches("(prefers-color-scheme: dark)", 1280, 800),
        "a light preference must not report dark");
    assert(mediaQueryMatches("(prefers-color-scheme: light)", 1280, 800),
        "a light preference reports light");
    assert(mediaQueryMatches("(min-width: 768px)", 1280, 800), "1280 is at least 768");
    assert(!mediaQueryMatches("(min-width: 768px)", 600, 800), "600 is below 768");
    assert(mediaQueryMatches("screen and (max-width: 767px)", 600, 800),
        "a screen-only query matches a narrow viewport");
    assert(mediaQueryMatches("(min-width: 768px) and (max-width: 1023px)", 800, 600),
        "both conditions of a conjunction must hold");
    assert(!mediaQueryMatches("print", 1280, 800), "a print query is false on screen");
    setPrefersDarkScheme(true);
    assert(mediaQueryMatches("(prefers-color-scheme: dark)", 1280, 800),
        "a dark preference reports dark");
    assert(!mediaQueryMatches("(prefers-color-scheme: light)", 1280, 800),
        "a dark preference does not report light");

    // The two paths cannot disagree: a query `matchMedia` reports true is
    // exactly one whose `@media` block applies at that viewport.
    foreach (query; ["(min-width: 768px)", "(max-width: 400px)",
        "(prefers-color-scheme: dark)", "(prefers-color-scheme: light)",
        "screen and (min-width: 1280px)", "print"])
        foreach (vw; [320, 400, 401, 768, 1279, 1280])
        {
            auto rules = parseStylesheet("@media " ~ query ~ "{.a{color:red}}", vw, 800);
            const applied = applyMediaRules(rules, vw, 800).length == 1;
            assert(applied == mediaQueryMatches(query, vw, 800),
                "matchMedia and @media disagree about `" ~ query ~ "`");
        }
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
                auto mq = parseMediaQueryString(prelude, viewportWidth, viewportHeight);
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
            else if (pname == "placeholder" || pname == "webkit-input-placeholder" ||
                pname == "moz-placeholder" || pname == "ms-input-placeholder")
            {
                // `input::placeholder` (and the prefixed spellings pages still
                // ship) styles the hint text of an empty control, not the
                // control itself. Collected like `::before`/`::after` and read
                // by the painter, which otherwise used one hardcoded grey.
                compound.isPseudoElement = true;
                compound.pseudoElement = "placeholder";
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
    // CSS Syntax 4.3.9: an identifier may contain any code point >= U+0080, so
    // the bytes of a non-ASCII class name are part of it. An ASCII-only rule made
    // `.café` in a windows-1252 stylesheet parse as `.caf`, and the rule then
    // matched nothing - the element kept its unstyled colour while Edge applied
    // the rule (verified with the loading harness, routes css-charset-*).
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80;
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
            // `margin`/`padding` are positional shorthands (CSS 2.1 8.1/8.4):
            // a shorthand sets ALL of its longhands, so it must be expanded
            // here too. Carrying it as a single property let a longhand from a
            // lower-priority rule survive and then win in resolveBoxMetrics:
            // django serves `ul{padding-left:20px}` and
            // `header nav ul{padding:0}`, so the header nav kept a phantom 20px
            // left inset (the menu wrapped onto a second line and the header
            // band sat 10px low), and `ol li,ul li{margin-top:10px}` survived
            // `header nav li{margin:0}`.
            else if (!expandBoxShorthand(result, property, rawValue, important))
            {
                if (validDeclarationValue(property, rawValue))
                    result ~= Declaration(property, rawValue, important);
                // else: the value is outside the property's grammar, so the whole
                // declaration is discarded (CSS 2.1 4.1.8) and cannot override an
                // earlier valid declaration.
            }
            // The common `flex-wrap: no-wrap` typo must lose to a base
            // `flex-wrap: wrap` the way a browser does.
        }
        i = semi < 0 ? n : semi + 1;
    }
    return result;
}

/// Whether `value` is valid for the enumerated-keyword properties whose value
/// grammar this engine knows. A value outside that grammar is invalid CSS (CSS
/// 2.1 4.1.8) and is discarded rather than applied, so it cannot beat an earlier
/// valid declaration in the cascade. Properties with open-ended grammars
/// (lengths, colours, shorthands, ...) always pass.
private bool validDeclarationValue(string property, string value)
{
    if (property == "flex-wrap")
    {
        const string v = asciiLower(value);
        return v == "nowrap" || v == "wrap" || v == "wrap-reverse";
    }
    return true;
}

/// ASCII-only lower-casing, safe on arbitrary page bytes. Unlike the std.uni
/// `toLower` used elsewhere in this module it never throws on invalid UTF-8.
private string asciiLower(string s)
{
    char[] out_ = new char[s.length];
    foreach (i, c; s)
        out_[i] = cast(char)((c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c);
    return out_.idup;
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

/// One side of a positional `margin`/`padding` shorthand, or "" when the token
/// is not a length this engine resolves (`auto` is allowed for margins only).
/// An unrecognised side makes the whole shorthand fall back to the ordinary
/// property path rather than applying a half-expanded value.
private string shorthandSideToken(string token, bool allowAuto)
{
    const t = token.strip();
    if (!t.length) return "";
    if (allowAuto && t.length == 4 && asciiLower(t) == "auto") return "auto";
    if (t.length >= 5 && asciiLower(t[0 .. 5]) == "calc(") return t;
    if (t == "0") return t;
    foreach (unit; ["px", "rem", "em", "%", "vh", "vw", "pt", "pc", "ch", "ex"])
        if (t.length > unit.length && asciiLower(t[$ - unit.length .. $]) == unit)
            return t;
    return "";
}

/// Expand a 1-4 value `margin`/`padding` shorthand into its longhands, in the
/// declaration's own position, so the cascade decides exactly as CSS 2.1
/// 8.1/8.4 requires. A shorthand sets ALL of its longhands, so it must clear a
/// longhand an earlier lower-priority rule won. Returns false when the value is
/// not such a shorthand - a CSS-wide keyword or a token that is not a length -
/// letting the caller keep the original declaration and lose nothing.
private bool expandBoxShorthand(ref Declaration[] result, string property,
    string value, bool important)
{
    string[4] sides;
    if (property == "margin")
        sides = ["margin-top", "margin-right", "margin-bottom", "margin-left"];
    else if (property == "padding")
        sides = ["padding-top", "padding-right", "padding-bottom", "padding-left"];
    else
        return false;

    switch (asciiLower(value.strip()))
    {
        case "inherit", "initial", "unset", "revert", "revert-layer":
            return false;   // CSS-wide keyword: not a positional list
        default:
            break;
    }

    const tokens = value.split();
    if (!tokens.length || tokens.length > 4) return false;
    const allowAuto = property == "margin";   // `auto` is margins only
    foreach (token; tokens)
        if (!shorthandSideToken(token, allowAuto).length) return false;

    // 1 value = all sides; 2 = vertical horizontal; 3 = top horizontal bottom;
    // 4 = top right bottom left.
    const top = tokens[0];
    const horizontal = tokens[tokens.length >= 2 ? 1 : 0];
    const bottom = tokens[tokens.length >= 3 ? 2 : 0];
    const left = tokens.length >= 4 ? tokens[3] : horizontal;
    const picked = [top, horizontal, bottom, left];
    foreach (i, side; sides)
        result ~= Declaration(side, picked[i], important);
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
    // --- `margin`/`padding` are positional shorthands (CSS 2.1 8.1/8.4) ---
    // A shorthand sets ALL of its longhands, so it must clear a longhand an
    // earlier lower-priority rule won. django serves `ul{padding-left:20px}`
    // and `header nav ul{padding:0}`; carrying the shorthand un-expanded left
    // the header nav ul with a phantom 20px left inset (its menu wrapped onto a
    // second line and the header band sat 10px below Edge's).
    auto rules = parseStylesheet(
        `ul { padding-left: 20px; margin-top: 10px; }
         header nav ul { padding: 0; margin: 0; }
         .two { padding: 5px 10px; }
         .three { margin: 1px 2px 3px; }
         .auto { margin: 0 auto; }
         .kw { padding: inherit; }
         .late { margin: 0; margin-left: 7px; }`);
    auto header = new Element("header");
    auto nav = new Element("nav");
    nav.parent = header;
    header.children ~= nav;
    header.elements ~= nav;
    auto ul = new Element("ul");
    ul.parent = nav;
    nav.children ~= ul;
    nav.elements ~= ul;

    auto c = cascadeFor(ul, rules);
    assert(c.get("padding-left", "") == "0",
        "`padding: 0` must reset the padding-left an earlier rule won, got '" ~
        c.get("padding-left", "") ~ "'");
    assert(c.get("margin-top", "") == "0",
        "`margin: 0` must reset the margin-top an earlier rule won, got '" ~
        c.get("margin-top", "") ~ "'");

    auto two = new Element("div");
    two.attrs["class"] = "two";
    auto c2 = cascadeFor(two, rules);
    assert(c2.get("padding-top", "") == "5px" && c2.get("padding-right", "") == "10px" &&
        c2.get("padding-bottom", "") == "5px" && c2.get("padding-left", "") == "10px",
        "`padding: 5px 10px` is vertical horizontal");

    auto three = new Element("div");
    three.attrs["class"] = "three";
    auto c3 = cascadeFor(three, rules);
    assert(c3.get("margin-top", "") == "1px" && c3.get("margin-right", "") == "2px" &&
        c3.get("margin-bottom", "") == "3px" && c3.get("margin-left", "") == "2px",
        "3-value shorthand: left mirrors right");

    auto autoEl = new Element("div");
    autoEl.attrs["class"] = "auto";
    auto c4 = cascadeFor(autoEl, rules);
    assert(c4.get("margin-left", "") == "auto" && c4.get("margin-top", "") == "0",
        "`margin: 0 auto` must survive so centred boxes stay centred");

    auto kw = new Element("div");
    kw.attrs["class"] = "kw";
    auto c5 = cascadeFor(kw, rules);
    assert(c5.get("padding", "") == "inherit" && c5.get("padding-left", "") == "",
        "a CSS-wide keyword is not a positional list and must be kept as-is");

    auto late = new Element("div");
    late.attrs["class"] = "late";
    auto c6 = cascadeFor(late, rules);
    assert(c6.get("margin-left", "") == "7px" && c6.get("margin-top", "") == "0",
        "a longhand after the shorthand in the same rule still wins");
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
    import std.conv : to;

    // `prefers-color-scheme` is answered from the live preference rather than
    // assumed, and a query that combines it with another condition has to
    // satisfy both. The preference is read at parse AND at apply time, so a
    // stylesheet parsed before a preference change is still filtered correctly.
    auto keep = prefersDarkScheme();
    scope (exit) setPrefersDarkScheme(keep);

    auto css = `@media (prefers-color-scheme: dark) { .a { color: red; } }
        @media (prefers-color-scheme: light) { .c { color: green; } }
        @media (prefers-color-scheme: dark) and (min-width: 768px) { .d { color: orange; } }
        .b { color: blue; }`;

    setPrefersDarkScheme(false);
    auto lightRules = parseStylesheet(css, 1280, 800);
    assert(applyMediaRules(lightRules, 1280, 800).length == 2,
        "with a light preference only .b and .c apply, got " ~
        applyMediaRules(lightRules, 1280, 800).length.to!string);

    setPrefersDarkScheme(true);
    auto darkRules = parseStylesheet(css, 1280, 800);
    assert(applyMediaRules(darkRules, 1280, 800).length == 3,
        "with a dark preference .a, .b and .d apply, got " ~
        applyMediaRules(darkRules, 1280, 800).length.to!string);
    assert(applyMediaRules(darkRules, 400, 800).length == 2,
        "the dark rule combined with min-width:768px still needs the width");

    // Rules stored under one preference re-filter under the other.
    assert(applyMediaRules(lightRules, 1280, 800).length == 3,
        "a sheet parsed while light follows a later dark preference");
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
    // The shorthand expands to its longhands (CSS 2.1 8.4), so the value shows
    // up on the sides rather than under the shorthand's own name.
    assert(cascade.get("padding-top", "") == "10px" &&
        cascade.get("padding-left", "") == "10px",
        "the `:not(.search)` rule must reach an ordinary child: got '" ~
        cascade.get("padding-top", "") ~ "'");
}

unittest
{
    // --- An invalid declaration value is dropped, not applied ---
    // `flex-wrap: no-wrap` is not in the property's grammar, so a browser
    // discards that declaration and an earlier `flex-wrap: wrap` still wins.
    // The engine used to keep `no-wrap` verbatim and test it with `== "wrap"`,
    // so django's `.container--flex--wrap--mobile` never wrapped its header at
    // desktop and the search field was squeezed into the menu row instead of
    // dropping to a second line the way Edge renders it.
    auto rules = parseStylesheet(
        `.c{flex-wrap:wrap}` ~
        `@media screen and (min-width:768px){.c{flex-wrap:no-wrap}}`, 1280, 800);
    auto active = applyMediaRules(rules, 1280, 800);
    auto c = new Element("div");
    c.attrs["class"] = "c";
    auto index = buildRuleIndex(active);
    assert(cascadeFor(c, active, candidatesFor(index, c)).get("flex-wrap", "") == "wrap",
        "`flex-wrap:no-wrap` is invalid and must leave the base `wrap` in place");

    // A valid value still wins over an earlier one.
    auto ok = parseStylesheet(`.c{flex-wrap:wrap}.c{flex-wrap:nowrap}`, 800, 600);
    auto oc = new Element("div");
    oc.attrs["class"] = "c";
    auto oi = buildRuleIndex(ok);
    assert(cascadeFor(oc, ok, candidatesFor(oi, oc)).get("flex-wrap", "") == "nowrap",
        "a later valid flex-wrap value must still win");
}

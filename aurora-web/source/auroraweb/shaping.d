module auroraweb.shaping;

/**
 * Shared, memoized text shaping for the engine.
 *
 * Layout measures every text run (to size line boxes, wrap, and align), and
 * paint then shapes the exact same runs again to draw them. Without a cache the
 * text engine is invoked twice per run on every layout and every frame, even
 * when neither the text nor its width changed. This module memoizes
 * `textEngine.layout` by (text, pixel size, wrap width, wrap flag) so repeated
 * shaping of unchanged runs is a hash lookup.
 *
 * Shaping is a pure function of its inputs and the process-wide `FontSystem`,
 * so a single cross-module cache is safe and shared by layout and paint.
 */

import aurora.font : FontFace, FontRole;
import aurora.text.layout : TextLayout, TextLayoutOptions;
import aurora.text.atlas : FontSystem;
import aurora.text.fontmanager : FontWeight, SystemFontInventory;

import std.conv : to;
import std.string : split, strip, toLower;

/**
 * Installed faces keyed by "family\x1Fweight\x1Fstyle". Loading a face parses
 * an sfnt file, so each distinct CSS font combination is resolved once.
 */
private FontFace[string] _faces;

/**
 * Faces a page supplied itself through `@font-face`, keyed like `_faces`. A
 * family a page defines wins over the installed family of the same name and over
 * the engine's substitute, which is the CSS order: `@font-face` creates the
 * family the document then names in `font-family`.
 */
private FontFace[string] _webFaces;

/// Register a face downloaded for a page's `@font-face` rule. `weight` and
/// `style` are the CSS descriptors, so the caller does not need this module's
/// descriptor-to-face mapping.
void registerWebFace(string family, string weight, string style, FontFace face)
{
    if (face is null) return;
    const name = family.strip().strip("\"'").strip();
    if (name.length == 0) return;
    const italic = style.toLower() == "italic" || style.toLower() == "oblique";
    _webFaces[name.toLower() ~ "\x1F" ~ weightClass(weight).to!string ~ (italic ? "i" : "u")] = face;
    // Face resolution and shaping are both memoized per CSS combination, so
    // every entry that could have resolved to a substitute must be dropped: a
    // page that shows a webfont must not keep the fallback it shaped with a
    // moment earlier, nor the widths that were measured from that fallback.
    _faces = null;
    _cache = null;
}

/// The face the engine shapes with when no CSS font selects one.
private FontFace defaultFace()
{
    auto fonts = FontSystem.sharedInstance();
    return fonts is null ? null : fonts.face(FontRole.ui);
}

/// Map one CSS family name to an installed face. Generic families resolve to
/// the platform font the reference browser (Chromium on Windows) would pick.
private FontFace familyFace(string family, ushort weight, bool italic)
{
    const name = family.strip().strip("\"'").strip();
    if (name.length == 0) return null;
    if (auto web = (name.toLower() ~ "\x1F" ~ weight.to!string ~ (italic ? "i" : "u")) in _webFaces)
        return *web;
    switch (name.toLower())
    {
        case "monospace":
            auto fonts = FontSystem.sharedInstance();
            return fonts is null ? null : fonts.face(FontRole.monospace);
        case "serif": return SystemFontInventory.loadBest("Times New Roman", weight, italic);
        case "sans-serif": return SystemFontInventory.loadBest("Arial", weight, italic);
        case "cursive": return SystemFontInventory.loadBest("Comic Sans MS", weight, italic);
        case "fantasy": return SystemFontInventory.loadBest("Impact", weight, italic);
        case "system-ui", "ui-sans-serif": return defaultFace();
        default: break;
    }
    return SystemFontInventory.loadBest(name, weight, italic);
}

/// CSS `font-weight` to an OpenType weight class.
private ushort weightClass(string value)
{
    const text = value.strip().toLower();
    switch (text)
    {
        case "", "normal": return FontWeight.normal;
        case "bold", "bolder": return FontWeight.bold;
        case "lighter": return FontWeight.light;
        default: break;
    }
    ushort par = 0;
    foreach (ch; text)
    {
        if (ch < '0' || ch > '9') break;
        par = cast(ushort) (par * 10 + (ch - '0'));
    }
    return par >= 1 && par <= 1000 ? par : FontWeight.normal;
}

/**
 * Resolve a CSS font list (`font-family` order plus `font-weight`/`font-style`)
 * to one installed face, memoized. The first installed family wins, matching the
 * browser's font matching. A null result means "no CSS font matched, keep the
 * engine's default face", so pages that name no family are unaffected.
 */
const(FontFace) cssFace(string fontFamily, string fontWeight = "400",
    string fontStyle = "normal")
{
    if (fontFamily.length == 0) return null;
    const italic = fontStyle == "italic" || fontStyle == "oblique";
    const weight = weightClass(fontWeight);
    const key = fontFamily ~ "\x1F" ~ weight.to!string ~ (italic ? "i" : "u");
    if (auto hit = key in _faces) return *hit;
    FontFace resolved;
    foreach (candidate; fontFamily.split(","))
    {
        resolved = familyFace(candidate, weight, italic);
        if (resolved !is null) break;
    }
    _faces[key] = resolved;
    return resolved;
}

/**
 * `cssFace`, with the browser's *standard* font as the fallback.
 *
 * A style that names no family — or names none that is installed — does not get
 * the UI font. In Chromium a page with no CSS font is set in the standard font,
 * which on Windows is Times New Roman, so a bare `<p>` is serif in every
 * Windows browser. That face matters twice over: the standard font's ascent and
 * descent are also what `line-height: normal` is measured from, so shaping a
 * bare page in the UI font made every line of it taller than the reference as
 * well as the wrong typeface.
 *
 * `system-ui` still resolves to the UI font, because that is the family name a
 * page uses when it does want the interface font.
 */
const(FontFace) cssFaceOrStandard(string fontFamily, string fontWeight = "400",
    string fontStyle = "normal")
{
    if (auto face = cssFace(fontFamily, fontWeight, fontStyle))
        return face;
    const italic = fontStyle == "italic" || fontStyle == "oblique";
    return SystemFontInventory.loadBest("Times New Roman", weightClass(fontWeight), italic);
}

private TextLayout[string] _cache;
private size_t _evictions;
private size_t _shapings;   // real (non-memoized) text-engine invocations
private size_t _hits;       // lookups served from the cache
/// A page with dynamically generated text could otherwise grow the cache
/// without bound; beyond this many entries the cache is dropped and rebuilt.
private enum size_t MaxEntries = 8192;

/// The number of memoized shaped runs currently held (for tests/telemetry).
size_t shapeCacheSize() { return _cache.length; }

/// Real shaping calls performed (cache misses) — telemetry for profiling.
size_t shapeShapingCount() { return _shapings; }

/// Shape requests served from the cache — telemetry for profiling.
size_t shapeHitCount() { return _hits; }

/// Drop all memoized shaping (used when the font system changes).
void clearShapeCache() { _cache = null; }

/**
 * `line-height: normal` (CSS 2.1 10.8.1) in whole device pixels for the face the
 * engine shapes with: ascent + descent + line gap from the font's own metrics.
 *
 * `FontFace.lineHeight`/`ascent`/`descent` round up, which is a pixel too tall
 * for the common faces — Arial at 16px is 18.4px in Chromium but 19 here, so
 * every text block was a pixel per line taller than the reference. The design
 * units are scaled as a fraction and rounded to nearest, matching Chromium's
 * integer geometry (18.4 -> 18).
 */
int normalLineHeight(int pixelSize, const(FontFace) face = null)
{
    const ps = pixelSize < 1 ? 1 : pixelSize;
    try
    {
        auto target = cast(FontFace) face;
        if (target is null)
        {
            auto fonts = FontSystem.sharedInstance();
            auto collection = fonts is null ? null : fonts.collection(FontRole.ui);
            target = collection is null ? null : collection.primary();
        }
        if (target !is null)
        {
            auto metrics = target.openTypeFace();
            if (metrics !is null)
            {
                const units = metrics.ascenderUnits() - metrics.descenderUnits() +
                    metrics.lineGapUnits();
                const px = target.unitsToPixels(cast(double) units, ps);
                // Guard against a degenerate face (zero metrics).
                if (px >= 0.5)
                    return cast(int) (px + 0.5);
            }
            const rounded = target.lineHeight(ps);
            if (rounded > 0) return rounded;
        }
    }
    catch (Exception) {}
    // No font system (headless tooling): 1.125em, the ratio of the common UI faces.
    const fallback = ps + ps / 8;
    return fallback < 1 ? 1 : fallback;
}


/// Shape `text` at `pixelSize`, wrapping at `maxWidth` px (0 = no wrap).
/// Returns null on failure. Memoized across calls.
TextLayout shapeTextCached(string text, int pixelSize, int maxWidth, bool wrap = true,
    double letterSpacing = 0.0, const(FontFace) face = null)
{
    if (text.length == 0) return null;
    const int ps = pixelSize < 1 ? 1 : pixelSize;
    const int wrapW = maxWidth < 0 ? 0 : maxWidth;
    // A compact key: text is the variable part, the rest are fixed-width bits.
    const key = text ~ "\x1F" ~ ps.to!string ~ "\x1F" ~ wrapW.to!string ~
        (wrap && wrapW > 0 ? "w" : "n") ~
        // Tracking changes advances, so it must be part of the cache key or a run
        // would be reused with the wrong spacing.
        (letterSpacing != 0.0 ? "\x1F" ~ letterSpacing.to!string : "") ~
        // The selected face changes every advance, so it belongs in the key too.
        (face is null ? "" : "\x1F#" ~ face.identity.to!string);

    if (auto hit = key in _cache)
    {
        ++_hits;
        return *hit;
    }

    TextLayout layout;
    try
    {
        auto fonts = FontSystem.sharedInstance();
        dchar[] dtext;
        dtext.reserve(text.length);
        // Iterate CODE POINTS, not bytes. `foreach (ch; text)` over a string
        // yields each UTF-8 byte, so widening them one-per-byte turned `café`
        // (C3 A9) into "Ã©" and `’` (E2 80 99) into "â" plus two missing
        // glyphs - every non-ASCII character on every page was mangled.
        import std.utf : byDchar;
        foreach (ch; text.byDchar) dtext ~= ch;
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.pixelSize = ps;
        options.maxWidth = wrapW;
        options.wrap = wrap && wrapW > 0;
        options.letterSpacing = letterSpacing;
        options.overrideFace = cast(FontFace) face;
        layout = fonts.textEngine.layout(dtext, options);
    }
    catch (Exception)
    {
        layout = null;
    }

    if (_cache.length >= MaxEntries)
    {
        _cache = null;
        ++_evictions;
    }
    _cache[key] = layout;
    ++_shapings;
    return layout;
}

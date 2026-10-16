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

import aurora.font : FontRole;
import aurora.text.layout : TextLayout, TextLayoutOptions;
import aurora.text.atlas : FontSystem;

import std.conv : to;

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

/// Shape `text` at `pixelSize`, wrapping at `maxWidth` px (0 = no wrap).
/// Returns null on failure. Memoized across calls.
TextLayout shapeTextCached(string text, int pixelSize, int maxWidth, bool wrap = true,
    double letterSpacing = 0.0)
{
    if (text.length == 0) return null;
    const int ps = pixelSize < 1 ? 1 : pixelSize;
    const int wrapW = maxWidth < 0 ? 0 : maxWidth;
    // A compact key: text is the variable part, the rest are fixed-width bits.
    const key = text ~ "\x1F" ~ ps.to!string ~ "\x1F" ~ wrapW.to!string ~
        (wrap && wrapW > 0 ? "w" : "n") ~
        // Tracking changes advances, so it must be part of the cache key or a run
        // would be reused with the wrong spacing.
        (letterSpacing != 0.0 ? "\x1F" ~ letterSpacing.to!string : "");

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

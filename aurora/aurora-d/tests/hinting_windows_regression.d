module tests.hinting_windows_regression;

import aurora.font : FontFace;
import aurora.text.glyph : GlyphBitmap;
import aurora.text.hinter : hintingCounters;
import std.file : exists;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writefln, writeln;

private ulong fingerprint(GlyphBitmap bitmap)
{
    ulong hash = 14695981039346656037UL;
    foreach (value; bitmap.alpha) hash = (hash ^ value) * 1099511628211UL;
    foreach (value; [bitmap.width, bitmap.height, bitmap.bearingX, bitmap.bearingY, bitmap.advance])
        hash = (hash ^ cast(uint) value) * 1099511628211UL;
    return hash;
}

int main(string[] args)
{
    const previous = environment.get("AURORA_HINTING", null);
    scope (exit)
    {
        if (previous is null) environment.remove("AURORA_HINTING");
        else environment["AURORA_HINTING"] = previous;
    }
    string[] paths;
    if (args.length > 1) paths = args[1 .. $];
    else
    {
        const root = environment.get("WINDIR", "C:/Windows");
        foreach (file; ["segoeui.ttf", "consola.ttf", "arial.ttf", "calibri.ttf",
            "tahoma.ttf", "verdana.ttf", "cour.ttf", "times.ttf"])
            if (exists(buildPath(root, "Fonts", file))) paths ~= buildPath(root, "Fonts", file);
    }
    size_t checks, blanks;
    foreach (path; paths)
    {
        const before = hintingCounters();
        environment["AURORA_HINTING"] = "0";
        auto rawFace = FontFace.load(path);
        environment["AURORA_HINTING"] = "natural";
        auto face = FontFace.load(path);
        environment.remove("AURORA_HINTING");
        auto defaultFace = FontFace.load(path);
        dchar[] corpus;
        foreach (ch; 33 .. 127) corpus ~= cast(dchar) ch;
        corpus ~= "éÅЖйΩα"d;
        foreach (size; [9, 11, 12, 13, 17, 18, 20, 26, 34])
        {
            ulong[dchar] first;
            foreach (ch; corpus)
            {
                if (!face.supports(ch)) continue;
                environment["AURORA_HINTING"] = "0";
                const raw = rawFace.rasterizeGlyph(rawFace.glyphIndex(ch), size, 4);
                environment["AURORA_HINTING"] = "natural";
                auto bitmap = face.rasterizeGlyph(face.glyphIndex(ch), size, 4);
                environment.remove("AURORA_HINTING");
                assert(defaultFace.rasterPhases(size) == face.rasterPhases(size));
                assert(fingerprint(defaultFace.rasterizeGlyph(defaultFace.glyphIndex(ch), size, 4))
                    == fingerprint(bitmap), "The shared default must match reviewed natural hinting");
                environment["AURORA_HINTING"] = "natural";
                ulong rawInk, ink;
                foreach (value; raw.alpha) rawInk += value;
                foreach (value; bitmap.alpha) ink += value;
                if (rawInk && !ink)
                {
                    ++blanks;
                    writefln("BLANK font=%s size=%s char=U+%04X", path, size, cast(uint) ch);
                }
                first[ch] = fingerprint(bitmap);
                ++checks;
            }
            foreach_reverse (ch; corpus)
            {
                if (auto expected = ch in first)
                    assert(fingerprint(face.rasterizeGlyph(face.glyphIndex(ch), size, 4)) == *expected,
                        "Hinting must remain independent of glyph order");
            }
        }
        const after = hintingCounters();
        writefln("Font completed: %s; hint attempts=%s successes=%s fallbacks=%s", path,
            after.attempts - before.attempts, after.successes - before.successes,
            (after.attempts - before.attempts) - (after.successes - before.successes));
    }
    writefln("Natural hinting: %s fonts, %s glyph/size checks plus default equivalence and reverse-order replay, %s blanks.",
        paths.length, checks, blanks);
    return paths.length > 0 && blanks == 0 ? 0 : 1;
}

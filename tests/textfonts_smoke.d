module textfonts_smoke;

import auroracut.textfonts : installedTextFontFamilies, textFontFamilies,
    textFontFilePath, canonicalTextFontName;
import std.algorithm : min;
import std.conv : to;
import std.stdio : writeln;

/// Verifies the font dropdown now exposes the full installed set (not the old
/// hardcoded handful) and that installed families resolve to real files.
int main()
{
    const families = installedTextFontFamilies();
    writeln("installedTextFontFamilies count = ", families.length);

    // The whole point of "more fonts": far more than the old curated 10.
    assert(families.length >= 20,
        "Dropdown exposes only " ~ families.length.to!string ~ " families");

    // Curated favorites must come first (Windows host).
    auto indexOf(string name)
    {
        foreach (i, fam; families)
            if (fam == name) return i;
        return -1;
    }
    assert(indexOf("Segoe UI") == 0,
        "Segoe UI is no longer the first dropdown entry");

    // Every installed family except the generic "Sans" must resolve to a file.
    size_t resolved;
    size_t unresolvable;
    foreach (fam; families)
    {
        const path = textFontFilePath(fam, false, false);
        if (path.length > 0) ++resolved;
        else if (fam != "Sans") ++unresolvable;
    }
    writeln("resolved = ", resolved, "  unresolvable(non-Sans) = ", unresolvable,
        "  of ", families.length);
    assert(unresolvable == 0,
        unresolvable.to!string ~ " installed families did not resolve to a file");

    // A non-curated installed family (the key regression) resolves exactly.
    bool foundNonCurated;
    foreach (fam; families)
    {
        if (fam == "Sans" || fam == "Segoe UI" || fam == "Arial" ||
            fam == "Calibri") continue;
        const path = textFontFilePath(fam, false, false);
        if (path.length > 0)
        {
            foundNonCurated = true;
            writeln("resolved non-curated family '", fam, "' -> ", path);
            break;
        }
    }
    assert(foundNonCurated, "No non-curated installed family resolved");

    // generic "Sans" maps to the fallback face (empty path is accepted).
    assert(canonicalTextFontName("sans-serif") == "Sans");

    writeln("textfonts_smoke: ALL PASSED");
    return 0;
}

module auroracut.textfonts;

import std.algorithm : sort;
import std.file : exists;
import std.path : buildPath;
import std.process : environment;
import std.string : endsWith, replace, strip, toLower;
import aurora.text.fontmanager : SystemFontInventory, InstalledFont, FontWeight;

/** Built-in favorite families shown first in the text-font dropdown. */
immutable string[] preferredTextFontFamilies = [
    "Segoe UI",
    "Arial",
    "Calibri",
    "Consolas",
    "Georgia",
    "Times New Roman",
    "Tahoma",
    "Verdana",
    "Sans"
];

/**
 * Every distinct installed font family, ordered so the curated favorites come
 * first and the remaining installed families follow alphabetically. This lets
 * the text-font dropdown expose all installed fonts instead of a hardcoded
 * handful. */
string[] installedTextFontFamilies()
{
    string[] result;
    foreach (font; SystemFontInventory.installed())
    {
        const fam = strip(font.familyName);
        if (fam.length == 0) continue;
        bool present;
        foreach (existing; result)
            if (existing == fam) { present = true; break; }
        if (!present) result ~= fam;
    }
    sort(result);
    string[] ordered;
    // Only surface curated favorites that are actually installed on this OS.
    foreach (preferred; preferredTextFontFamilies)
        if (preferred != "Sans" && containsFamily(result, preferred))
            ordered ~= preferred;
    foreach (fam; result)
        if (!containsFamily(preferredTextFontFamilies, fam))
            ordered ~= fam;
    ordered ~= "Sans";
    return ordered;
}

private bool containsFamily(const(string)[] list, string family)
{
    foreach (candidate; list)
        if (candidate == family) return true;
    return false;
}

/** Backward-compatible accessor: curated favorites first, then installed set. */
string[] textFontFamilies()
{
    return installedTextFontFamilies();
}
/** Normalize built-in aliases and dropdown families without rejecting a custom
 * family typed into the Inspector. */
string canonicalTextFontName(string family)
{
    const trimmed = strip(family);
    if (trimmed.length == 0) return "Sans";
    const lowered = trimmed.toLower();
    if (lowered == "segoe") return "Segoe UI";
    if (lowered == "times") return "Times New Roman";
    if (lowered == "sans-serif" || lowered == "sans serif") return "Sans";
    foreach (candidate; textFontFamilies)
        if (candidate.toLower() == lowered) return candidate;
    return trimmed;
}

/** Filename used by the common Windows family/style combinations. */
string textFontFilename(string family, bool bold, bool italic)
{
    const name = canonicalTextFontName(family).toLower();
    if (name == "segoe ui")
        return bold && italic ? "segoeuiz.ttf" : bold ? "segoeuib.ttf" :
            italic ? "segoeuii.ttf" : "segoeui.ttf";
    if (name == "arial")
        return bold && italic ? "arialbi.ttf" : bold ? "arialbd.ttf" :
            italic ? "ariali.ttf" : "arial.ttf";
    if (name == "calibri")
        return bold && italic ? "calibriz.ttf" : bold ? "calibrib.ttf" :
            italic ? "calibrii.ttf" : "calibri.ttf";
    if (name == "consolas")
        return bold && italic ? "consolaz.ttf" : bold ? "consolab.ttf" :
            italic ? "consolai.ttf" : "consola.ttf";
    if (name == "georgia")
        return bold && italic ? "georgiaz.ttf" : bold ? "georgiab.ttf" :
            italic ? "georgiai.ttf" : "georgia.ttf";
    if (name == "times new roman")
        return bold && italic ? "timesbi.ttf" : bold ? "timesbd.ttf" :
            italic ? "timesi.ttf" : "times.ttf";
    if (name == "impact") return "impact.ttf";
    if (name == "tahoma") return bold ? "tahomabd.ttf" : "tahoma.ttf";
    if (name == "verdana")
        return bold && italic ? "verdanaz.ttf" : bold ? "verdanab.ttf" :
            italic ? "verdanai.ttf" : "verdana.ttf";
    return "";
}

private string normalizedFontPath(string value)
{
    return value.replace("\\", "/");
}

private bool looksLikeFontFile(string value)
{
    const lowered = value.toLower();
    return lowered.endsWith(".ttf") || lowered.endsWith(".otf") ||
        lowered.endsWith(".ttc");
}

/** Resolve the exact font file used by Aurora's live title and export raster.
 *
 * Built-in Windows dropdown families never fall back to a generic family name.
 * The canonical system path is returned even when `std.file.exists` cannot
 * inspect the shell-backed Fonts directory, preventing several choices from
 * silently becoming the same face.
 *
 * Per-user installed fonts and explicit .ttf/.otf/.ttc paths are still checked
 * first. A missing style-specific face falls back to that family's regular
 * face, not to another family. */
string textFontFilePath(string family, bool bold, bool italic)
{
    const requested = strip(family);
    if (requested.length == 0) return "";

    if (looksLikeFontFile(requested) && exists(requested))
        return normalizedFontPath(requested);

    // Resolve any installed family through the system inventory first. This is
    // what makes truly "more fonts" visible: families that are not in the
    // curated filename table (Inter, Roboto, most variable faces, per-user
    // installs) still get an exact, loadable file. Non-installed generic names
    // (e.g. "Sans") fall through to the curated filename logic below.
    {
        auto matches = SystemFontInventory.find(requested,
            bold ? FontWeight.bold : FontWeight.normal, italic);
        if (matches.length > 0)
            return normalizedFontPath(matches[0].path);
    }

    // Per-user and system font files (curated families) may live in the
    // shell-backed Fonts directory that `SystemFontInventory` cannot always
    // observe, so keep the filename-based lookup as a fallback.
    string[] curatedDirectories()
    {
        string[] dirs;
        version (Windows)
        {
            auto windowsDirectory = environment.get("WINDIR", "C:/Windows");
            dirs ~= buildPath(windowsDirectory, "Fonts");
            const localAppData = environment.get("LOCALAPPDATA", "");
            if (localAppData.length > 0)
                dirs ~= buildPath(localAppData, "Microsoft", "Windows", "Fonts");
        }
        return dirs;
    }

    string findInDirectories(string filename)
    {
        foreach (directory; curatedDirectories())
        {
            const candidate = buildPath(directory, filename);
            if (exists(candidate)) return normalizedFontPath(candidate);
        }
        return "";
    }

    version (Windows)
    {
        const preferredFilename = textFontFilename(requested, bold, italic);
        if (preferredFilename.length == 0) return "";
        const regularFilename = textFontFilename(requested, false, false);

        auto result = findInDirectories(preferredFilename);
        if (result.length > 0) return result;
        if (regularFilename.length > 0 && regularFilename != preferredFilename)
        {
            result = findInDirectories(regularFilename);
            if (result.length > 0) return result;
        }

        // Listed Windows families are deterministic system assets. Do not
        // silently replace one with FFmpeg's generic fallback just because the
        // shell-backed Fonts directory was not observable through exists().
        auto windowsDirectory = environment.get("WINDIR", "C:/Windows");
        const systemFonts = buildPath(windowsDirectory, "Fonts");
        return normalizedFontPath(buildPath(systemFonts, preferredFilename));
    }
    else version (linux)
    {
        const name = canonicalTextFontName(requested).toLower();
        string stem;
        if (name == "dejavu serif" || name == "georgia" ||
            name == "times new roman" || name == "times")
            stem = "DejaVuSerif";
        else if (name == "dejavu sans mono" || name == "consolas")
            stem = "DejaVuSansMono";
        else
            stem = "DejaVuSans";
        const suffix = bold && italic ? "-BoldOblique.ttf" :
            bold ? "-Bold.ttf" : italic ? "-Oblique.ttf" : ".ttf";
        const path = buildPath("/usr/share/fonts/truetype/dejavu",
            stem ~ suffix);
        return exists(path) ? normalizedFontPath(path) : "";
    }
    else version (OSX)
    {
        string[] candidates;
        const name = canonicalTextFontName(requested).toLower();
        if (name == "times new roman" || name == "times")
            candidates = ["/System/Library/Fonts/Times.ttc"];
        else if (name == "consolas")
            candidates = ["/System/Library/Fonts/SFNSMono.ttf",
                "/System/Library/Fonts/Monaco.ttf"];
        else
            candidates = ["/System/Library/Fonts/SFNS.ttf",
                "/System/Library/Fonts/Helvetica.ttc"];
        foreach (path; candidates)
            if (exists(path)) return normalizedFontPath(path);
        return "";
    }
    else
        return "";
}

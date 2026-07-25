module auroracut.textfonts;

import std.file : exists;
import std.path : buildPath;
import std.process : environment;
import std.string : endsWith, replace, strip, toLower;

/** Font families exposed by every Aurora Cut text-font dropdown. */
immutable string[] textFontFamilies = [
    "Segoe UI",
    "Arial",
    "Calibri",
    "Consolas",
    "Georgia",
    "Times New Roman",
    "Impact",
    "Tahoma",
    "Verdana",
    "Sans"
];

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

    version (Windows)
    {
        const preferredFilename = textFontFilename(requested, bold, italic);
        if (preferredFilename.length == 0) return "";
        const regularFilename = textFontFilename(requested, false, false);

        auto windowsDirectory = environment.get("WINDIR", "C:/Windows");
        const systemFonts = buildPath(windowsDirectory, "Fonts");
        const localAppData = environment.get("LOCALAPPDATA", "");
        const userFonts = localAppData.length > 0 ?
            buildPath(localAppData, "Microsoft", "Windows", "Fonts") : "";

        string[] directories;
        if (userFonts.length > 0) directories ~= userFonts;
        directories ~= systemFonts;

        foreach (directory; directories)
        {
            const preferred = buildPath(directory, preferredFilename);
            if (exists(preferred)) return normalizedFontPath(preferred);
            if (regularFilename.length > 0 && regularFilename != preferredFilename)
            {
                const regular = buildPath(directory, regularFilename);
                if (exists(regular)) return normalizedFontPath(regular);
            }
        }

        // Listed Windows families are deterministic system assets. Do not
        // silently replace one with FFmpeg's generic fallback just because the
        // shell-backed Fonts directory was not observable through exists().
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

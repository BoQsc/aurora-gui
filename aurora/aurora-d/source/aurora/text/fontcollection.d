module aurora.text.fontcollection;

/** Ordered, cluster-aware font fallback without a runtime font dependency. */

import aurora.font : FontFace, FontRole, SystemFonts;
import aurora.text.unicode.properties : isDefaultIgnorable;
import std.file : exists;

final class FontCollection
{
    private FontFace[] _faces;

    this(FontFace primary = null)
    {
        if (primary !is null) add(primary);
    }

    const(FontFace)[] faces() const @safe pure nothrow @nogc { return _faces; }
    size_t length() const @safe pure nothrow @nogc { return _faces.length; }

    FontFace primary()
    {
        return _faces.length ? _faces[0] : FontFace.bitmapFallback();
    }

    bool add(FontFace face)
    {
        if (face is null) return false;
        foreach (existing; _faces)
            if (existing.identity == face.identity) return false;
        _faces ~= face;
        return true;
    }

    bool add(string path, uint faceIndex = 0)
    {
        auto face = FontFace.tryLoad(path, faceIndex);
        if (face is null) return false;
        return add(face);
    }

    /** Resolve one complete grapheme cluster to one face. */
    FontFace resolve(const(dchar)[] cluster)
    {
        foreach (face; _faces)
            if (supportsCluster(face, cluster)) return face;
        return primary();
    }

    bool supportsCluster(FontFace face, const(dchar)[] cluster) const
    {
        if (face is null) return false;
        bool sawRenderable;
        foreach (ch; cluster)
        {
            if (isDefaultIgnorable(ch) || ch == '\u200C' || ch == '\u200D' ||
                (ch >= 0xFE00 && ch <= 0xFE0F) ||
                (ch >= 0xE0100 && ch <= 0xE01EF))
                continue;
            sawRenderable = true;
            if (!face.supports(ch)) return false;
        }
        return sawRenderable || cluster.length == 0 || face !is null;
    }

    static FontCollection system(FontRole role, FontFace primary = null)
    {
        auto result = new FontCollection(primary !is null ? primary :
            (role == FontRole.monospace ? SystemFonts.monospace() : SystemFonts.sans()));
        foreach (path; systemFallbackPaths(role))
            if (exists(path)) result.add(path);
        result.add(FontFace.bitmapFallback());
        return result;
    }

    private static string[] systemFallbackPaths(FontRole role)
    {
        string[] paths;
        version (Windows)
        {
            import std.path : buildPath;
            import std.process : environment;
            const root = environment.get("WINDIR", `C:\Windows`);
            paths ~= buildPath(root, "Fonts", "seguisym.ttf");
            paths ~= buildPath(root, "Fonts", "seguiemj.ttf");
            paths ~= buildPath(root, "Fonts", "arial.ttf");
            paths ~= buildPath(root, "Fonts", "malgun.ttf");
            paths ~= buildPath(root, "Fonts", "meiryo.ttc");
        }
        else version (OSX)
        {
            paths ~= "/System/Library/Fonts/Apple Color Emoji.ttc";
            paths ~= "/System/Library/Fonts/Supplemental/Arial Unicode.ttf";
            paths ~= "/System/Library/Fonts/PingFang.ttc";
            paths ~= "/System/Library/Fonts/Hiragino Sans GB.ttc";
        }
        else
        {
            paths ~= "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
            paths ~= "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf";
            paths ~= "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf";
            paths ~= "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf";
            paths ~= "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
            paths ~= "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf";
            paths ~= "/usr/share/fonts/opentype/freefont/FreeSans.otf";
            if (role == FontRole.monospace)
            {
                paths ~= "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
                paths ~= "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf";
            }
        }
        return paths;
    }
}

unittest
{
    auto collection = FontCollection.system(FontRole.ui);
    assert(collection.length > 0);
    assert(collection.resolve("A"d) !is null);
}

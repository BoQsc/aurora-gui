module aurora.text.fontmanager;

/**
 * Pure-D system font inventory and lookup.
 *
 * Scans the standard font directories for each operating system, parses each
 * sfnt/TTC file's `name`, `OS/2` and `cmap` tables directly (no OS font API),
 * and builds a searchable family index. The per-OS directory list is the only
 * platform-specific part, so adding a new OS is one array.
 *
 * The inventory is cached per scan; `rescan()` refreshes it.
 */

import aurora.font : FontFace;
import std.algorithm : filter, map, sort;
import std.file : dirEntries, SpanMode, exists;
import std.path : extension;
import std.process : environment;
import std.utf : toUTF8;
import std.math : abs;
import std.string : toLower;

private enum uint tag(string value) =
    (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
    (cast(uint) value[2] << 8) | cast(uint) value[3];

private ushort be16(const(ubyte)[] data, size_t offset)
{
    if (offset + 2 > data.length) return 0;
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length) return 0;
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
}

/// Font weight classes (OpenType usWeightClass / CSS).
enum FontWeight : ushort
{
    thin = 100,
    extraLight = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semiBold = 600,
    bold = 700,
    extraBold = 800,
    black = 900,
    extraBlack = 950
}

/// Font stretch (OpenType usWidthClass mapped to CSS percentages).
enum FontStretch : ushort
{
    ultraCondensed = 1,
    extraCondensed = 2,
    condensed = 3,
    semiCondensed = 4,
    normal = 5,
    semiExpanded = 6,
    expanded = 7,
    extraExpanded = 8,
    ultraExpanded = 9
}

/// One installed face.
struct InstalledFont
{
    string path;
    uint faceIndex;
    string familyName;      /// Typographic family (nameID 16, else 1).
    string subfamilyName;   /// Typographic subfamily (nameID 17, else 2).
    ushort weight = FontWeight.normal;
    ushort stretch = FontStretch.normal;
    bool italic;
    bool bold;
    uint codepointCoverage; /// Number of mapped codepoints in the cmap.
}

/**
 * System font inventory. `installed()` performs the scan and caches the
 * result; `rescan()` forces a fresh scan.
 */
struct SystemFontInventory
{
    private static InstalledFont[] _installed;
    private static bool _scanned;

    static InstalledFont[] installed()
    {
        if (!_scanned) rescan();
        return _installed;
    }

    static void rescan()
    {
        InstalledFont[] result;
        foreach (directory; fontDirectories())
        {
            if (!exists(directory)) continue;
            foreach (entry; dirEntries(directory, SpanMode.depth))
            {
                if (entry.isDir) continue;
                const ext = extension(entry.name).toLower();
                if (ext != ".ttf" && ext != ".otf" && ext != ".ttc" && ext != ".otc")
                    continue;
                auto meta = parseFileMetadata(entry.name);
                foreach (face; meta)
                    result ~= face;
            }
        }
        result.sort!((a, b) => a.familyName < b.familyName);
        _installed = result;
        _scanned = true;
    }

    static InstalledFont[] find(string familyName,
        ushort weight = FontWeight.normal, bool italic = false,
        ushort stretch = FontStretch.normal)
    {
        InstalledFont[] matches;
        foreach (font; installed())
        {
            if (font.familyName != familyName) continue;
            // Prefer an exact weight/stretch match; otherwise fall back to
            // the closest available weight.
            matches ~= font;
        }
        if (matches.length == 0)
        {
            // Case-insensitive fallback.
            foreach (font; installed())
                if (font.familyName.toLower() == familyName.toLower())
                    matches ~= font;
        }
        if (matches.length == 0) return null;
        return rankMatches(matches, weight, italic, stretch);
    }

    static InstalledFont[] familyMembers(string familyName)
    {
        InstalledFont[] result;
        foreach (font; installed())
            if (font.familyName == familyName || font.familyName.toLower() == familyName.toLower())
                result ~= font;
        return result;
    }

    static FontFace loadBest(string familyName, ushort weight = FontWeight.normal,
        bool italic = false, ushort stretch = FontStretch.normal)
    {
        auto matches = find(familyName, weight, italic, stretch);
        if (matches.length == 0) return null;
        return FontFace.tryLoad(matches[0].path, matches[0].faceIndex);
    }

    /// Load every face of a family into a font collection order.
    static FontFace[] loadFamily(string familyName)
    {
        FontFace[] result;
        auto members = familyMembers(familyName);
        members.sort!((a, b) => a.weight < b.weight);
        foreach (member; members)
        {
            auto face = FontFace.tryLoad(member.path, member.faceIndex);
            if (face !is null) result ~= face;
        }
        return result;
    }

    private static InstalledFont[] rankMatches(InstalledFont[] candidates,
        ushort weight, bool italic, ushort stretch)
    {
        // Score: exact weight = 0, bold/normal nearest = smaller delta; prefer
        // non-italic for italic=false, italic for italic=true; exact stretch.
        InstalledFont best;
        int bestScore = int.max;
        foreach (candidate; candidates)
        {
            int score = 0;
            score += abs(cast(int) candidate.weight - cast(int) weight);
            if (candidate.italic != italic) score += 1000;
            score += abs(cast(int) candidate.stretch - cast(int) stretch);
            if (score < bestScore)
            {
                bestScore = score;
                best = candidate;
            }
        }
        InstalledFont[] result;
        if (best.path.length) result ~= best;
        return result;
    }

    /// Font directories per operating system. Adding an OS = add one array.
    static string[] fontDirectories()
    {
        string[] result;
        version (Windows)
        {
            const root = environment.get("WINDIR", `C:\Windows`);
            result ~= root ~ `\Fonts`;
            const local = environment.get("LOCALAPPDATA", "");
            if (local.length) result ~= local ~ `\Microsoft\Windows\Fonts`;
        }
        else version (OSX)
        {
            result ~= "/System/Library/Fonts";
            result ~= "/Library/Fonts";
            const home = environment.get("HOME", "");
            if (home.length)
            {
                result ~= home ~ "/Library/Fonts";
                result ~= home ~ "/.fonts";
            }
        }
        else
        {
            result ~= "/usr/share/fonts";
            result ~= "/usr/local/share/fonts";
            const home = environment.get("HOME", "");
            if (home.length)
            {
                result ~= home ~ "/.fonts";
                result ~= home ~ "/.local/share/fonts";
            }
            result ~= "/usr/share/fonts/truetype";
            result ~= "/usr/share/fonts/opentype";
        }
        return result;
    }

    private static InstalledFont[] parseFileMetadata(string path)
    {
        InstalledFont[] result;
        try
        {
            import std.file : read;
            auto bytes = cast(immutable(ubyte)[]) read(path);
            if (bytes.length < 12) return result;

            uint faceOffset = 0;
            uint faceCount = 1;
            if (be32(bytes, 0) == tag!"ttcf")
            {
                faceCount = be32(bytes, 8);
                if (faceCount == 0 || faceCount > 64) return result;
            }

            foreach (index; 0 .. faceCount)
            {
                if (be32(bytes, 0) == tag!"ttcf")
                    faceOffset = be32(bytes, 12 + cast(size_t) index * 4);
                auto meta = parseSingleFace(bytes, faceOffset, path, index);
                if (meta.path.length) result ~= meta;
            }
        }
        catch (Exception)
        {
            // Unreadable or malformed file: skip it.
        }
        return result;
    }

    private static InstalledFont parseSingleFace(const(ubyte)[] data,
        size_t faceOffset, string path, uint faceIndex)
    {
        InstalledFont font;
        font.path = path;
        font.faceIndex = faceIndex;
        if (faceOffset + 12 > data.length) return font;

        const signature = be32(data, faceOffset);
        if (signature != 0x00010000 && signature != tag!"true" &&
            signature != tag!"OTTO" && signature != tag!"typ1")
            return font;
        const tableCount = be16(data, faceOffset + 4);
        size_t cursor = faceOffset + 12;

        const(ubyte)[] nameTable;
        const(ubyte)[] os2Table;
        const(ubyte)[] cmapTable;

        foreach (_; 0 .. tableCount)
        {
            if (cursor + 16 > data.length) break;
            const name = be32(data, cursor);
            const offset = cast(size_t) be32(data, cursor + 8);
            const length = cast(size_t) be32(data, cursor + 12);
            const slice = offset + length <= data.length ? data[offset .. offset + length] : null;
            switch (name)
            {
                case tag!"name": nameTable = slice; break;
                case tag!"OS/2": os2Table = slice; break;
                case tag!"cmap": cmapTable = slice; break;
                default: break;
            }
            cursor += 16;
        }

        font.familyName = nameString(nameTable, 16, 1);
        font.subfamilyName = nameString(nameTable, 17, 2);
        if (font.familyName.length == 0) font.familyName = path;

        if (os2Table.length >= 8)
        {
            font.weight = be16(os2Table, 4);         // usWeightClass
            const fsSelection = be16(os2Table, 62);
            font.italic = (fsSelection & 1) != 0;
            font.bold = (fsSelection & 0x20) != 0;
            font.stretch = clampStretch(be16(os2Table, 6)); // usWidthClass
        }
        if (font.weight == 0) font.weight = font.bold ? FontWeight.bold : FontWeight.normal;

        font.codepointCoverage = countCmapCodepoints(cmapTable);
        return font;
    }

    private static ushort clampStretch(ushort value) @safe pure nothrow @nogc
    {
        if (value == 0) return FontStretch.normal;
        if (value < FontStretch.ultraCondensed) return FontStretch.ultraCondensed;
        if (value > FontStretch.ultraExpanded) return FontStretch.ultraExpanded;
        return value;
    }

    /// Read a localized name table string by name ID (Windows English first).
    private static string nameString(const(ubyte)[] nameTable, ushort id,
        ushort fallbackId)
    {
        if (nameTable.length < 6) return "";
        const count = be16(nameTable, 2);
        const storageOffset = be16(nameTable, 4);
        string best;
        string fallback;
        size_t cursor = 6;
        foreach (_; 0 .. count)
        {
            if (cursor + 12 > nameTable.length) break;
            const platform = be16(nameTable, cursor);
            const encoding = be16(nameTable, cursor + 2);
            const nameId = be16(nameTable, cursor + 6);
            const length = be16(nameTable, cursor + 8);
            const offset = be16(nameTable, cursor + 10);
            const stringStart = storageOffset + offset;
            if (stringStart + length > nameTable.length) { cursor += 12; continue; }
            if (nameId == id || nameId == fallbackId)
            {
                string value;
                if (platform == 3 && (encoding == 1 || encoding == 10))
                    value = decodeUtf16BE(nameTable[stringStart .. stringStart + length]);
                else if (platform == 0)
                    value = decodeUtf16BE(nameTable[stringStart .. stringStart + length]);
                else if (platform == 1)
                    value = decodeMacRoman(nameTable[stringStart .. stringStart + length]);
                else
                    value = cast(string) cast(immutable(char)[]) nameTable[stringStart .. stringStart + length];
                if (value.length == 0) { cursor += 12; continue; }
                if (nameId == id) return value;
                if (fallback.length == 0) fallback = value;
            }
            cursor += 12;
        }
        return fallback;
    }

    private static string decodeUtf16BE(const(ubyte)[] bytes)
    {
        // Decode valid UTF-16BE; skip lone surrogates.
        import std.utf : UTFException;
        dstring result;
        size_t i;
        while (i + 1 < bytes.length)
        {
            const unit = (cast(uint) bytes[i] << 8) | bytes[i + 1];
            i += 2;
            if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.length)
            {
                const low = (cast(uint) bytes[i] << 8) | bytes[i + 1];
                if (low >= 0xDC00 && low <= 0xDFFF)
                {
                    result ~= cast(dchar) (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                    i += 2;
                    continue;
                }
            }
            if (unit >= 0xD800 && unit <= 0xDFFF) continue; // skip lone surrogate
            result ~= cast(dchar) unit;
        }
        return toUTF8(result);
    }

    private static string decodeMacRoman(const(ubyte)[] bytes)
    {
        // Minimal Mac Roman (common ASCII subset) fallback; non-ASCII mapped
        // through the standard table where cheap.
        char[] result;
        result.reserve(bytes.length);
        foreach (b; bytes)
            result ~= b < 0x80 ? cast(char) b : cast(char) '?';
        return cast(string) result;
    }

    /// Count mapped codepoints across the cmap's Unicode subtables.
    private static uint countCmapCodepoints(const(ubyte)[] cmapTable)
    {
        if (cmapTable.length < 4) return 0;
        const count = be16(cmapTable, 2);
        uint total;
        foreach (index; 0 .. count)
        {
            const record = 4 + cast(size_t) index * 8;
            if (record + 8 > cmapTable.length) break;
            const platform = be16(cmapTable, record);
            const encoding = be16(cmapTable, record + 2);
            const relative = be32(cmapTable, record + 4);
            const subtable = relative;
            if (subtable + 2 > cmapTable.length) continue;
            const format = be16(cmapTable, subtable);
            if (format == 4)
            {
                const segCount = be16(cmapTable, subtable + 6) / 2;
                const endCodes = subtable + 14;
                uint segTotal;
                foreach (s; 0 .. segCount)
                {
                    const end = be16(cmapTable, endCodes + cast(size_t) s * 2);
                    const startPos = endCodes + cast(size_t) segCount * 2 + 2 +
                        cast(size_t) s * 2;
                    const start = be16(cmapTable, startPos);
                    if (end >= start) segTotal += end - start + 1;
                }
                total = total > segTotal ? total : segTotal;
            }
            else if (format == 12)
            {
                const groups = be32(cmapTable, subtable + 12);
                uint groupTotal;
                foreach (g; 0 .. groups)
                {
                    const entry = subtable + 16 + cast(size_t) g * 12;
                    const start = be32(cmapTable, entry);
                    const end = be32(cmapTable, entry + 4);
                    if (end >= start) groupTotal += end - start + 1;
                }
                total = total > groupTotal ? total : groupTotal;
            }
        }
        return total;
    }
}

unittest
{
    // Directory discovery must at least be non-empty on Windows.
    assert(SystemFontInventory.fontDirectories().length > 0);
}

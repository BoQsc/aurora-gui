/**
 * Text decoding for fetched resources (WHATWG Encoding, pragmatic subset).
 *
 * The engine reads HTTP bodies as raw bytes; HTML, CSS and JS are text and must
 * be decoded to UTF-8 before parsing, or a windows-1252 page turns into
 * mojibake and its selectors/identifiers stop matching (a `class="caf\xe9"` in a
 * cp1252 stylesheet matched nothing, so the styled element rendered unstyled).
 *
 * Labels follow the WHATWG Encoding Standard's aliases for the encodings that
 * matter on the open web: UTF-8, UTF-16 with a BOM, and the windows-1252 family
 * (which the standard also uses for the labels `latin1`/`iso-8859-1`, and as the
 * fallback when a body claims nothing but is not valid UTF-8). Unknown labels
 * fall back to UTF-8 and, when those bytes are not valid UTF-8, to windows-1252 -
 * which is what browsers do to unlabelled pages.
 *
 * Written from the standard's tables; depends only on druntime/Phobos.
 */
module auroraweb.encoding;

import std.conv : to;

/// windows-1252 for bytes 0x80..0x9F (the rest of the range is Latin-1).
private immutable dchar[] cp1252UpperHalf = [
    '\u20AC', '\u0081', '\u201A', '\u0192', '\u201E', '\u2026', '\u2020', '\u2021',
    '\u02C6', '\u2030', '\u0160', '\u2039', '\u0152', '\u008D', '\u017D', '\u008F',
    '\u0090', '\u2018', '\u2019', '\u201C', '\u201D', '\u2022', '\u2013', '\u2014',
    '\u02DC', '\u2122', '\u0161', '\u203A', '\u0153', '\u009D', '\u017E', '\u0178',
];

/// Normalise a charset label to the canonical name, or "" when it is not one we
/// know (the caller then applies the UTF-8-then-windows-1252 fallback).
string normalizeLabel(string label)
{
    string s;
    foreach (c; label)
        s ~= (c >= 'A' && c <= 'Z') ? cast(char) (c + 32) : c;
    // Trailing `;`-parameters and whitespace are already stripped by the caller,
    // but be forgiving about stray whitespace inside the label.
    string t;
    foreach (c; s)
        if (c != ' ' && c != '\t') t ~= c;
    s = t;
    switch (s)
    {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return "utf-8";
        case "utf-16", "utf-16le", "unicodefffe": return "utf-16le";
        case "utf-16be": return "utf-16be";
        case "windows-1252", "cp1252", "x-cp1252", "ansi_x3.4-1968",
             "ascii", "us-ascii", "iso-8859-1", "iso8859-1", "iso_8859-1",
             "l1", "latin1", "cp819", "csisolatin1":
            return "windows-1252";
        default: return "";
    }
}

/// `true` when `bytes` is valid UTF-8 (and does not start with a BOM).
bool isValidUtf8(const(ubyte)[] bytes)
{
    size_t i = 0;
    while (i < bytes.length)
    {
        const b = bytes[i];
        if (b < 0x80)
        {
            i++;
            continue;
        }
        size_t extra;
        uint cp;
        if (b >= 0xC2 && b <= 0xDF) { extra = 1; cp = b & 0x1F; }
        else if (b >= 0xE0 && b <= 0xEF) { extra = 2; cp = b & 0x0F; }
        else if (b >= 0xF0 && b <= 0xF4) { extra = 3; cp = b & 0x07; }
        else return false;
        if (i + extra >= bytes.length) return false;
        foreach (k; 1 .. extra + 1)
        {
            const c = bytes[i + k];
            if ((c & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (c & 0x3F);
        }
        // Reject overlong forms, surrogates and out-of-range code points.
        if (extra == 2 && cp < 0x800) return false;
        if (extra == 3 && cp < 0x10000) return false;
        if (cp >= 0xD800 && cp <= 0xDFFF) return false;
        if (cp > 0x10FFFF) return false;
        i += extra + 1;
    }
    return true;
}

/// Decode bytes as windows-1252 (bytes >= 0xA0 are their own code points).
string decodeCp1252(const(ubyte)[] bytes)
{
    dchar[] chars;
    chars.length = bytes.length;
    foreach (i, b; bytes)
        chars[i] = (b < 0x80) ? cast(dchar) b
            : (b < 0xA0) ? cp1252UpperHalf[b - 0x80]
            : cast(dchar) b;
    return to!string(chars);
}

/// Decode UTF-16 (either byte order) to UTF-8, replacing unpaired surrogates.
string decodeUtf16(const(ubyte)[] bytes, bool littleEndian)
{
    dchar[] chars;
    size_t i = 0;
    while (i + 1 < bytes.length)
    {
        uint unit = littleEndian
            ? (cast(uint) bytes[i] | (cast(uint) bytes[i + 1] << 8))
            : ((cast(uint) bytes[i] << 8) | cast(uint) bytes[i + 1]);
        i += 2;
        if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.length)
        {
            const next = littleEndian
                ? (cast(uint) bytes[i] | (cast(uint) bytes[i + 1] << 8))
                : ((cast(uint) bytes[i] << 8) | cast(uint) bytes[i + 1]);
            if (next >= 0xDC00 && next <= 0xDFFF)
            {
                chars ~= cast(dchar) (0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00));
                i += 2;
                continue;
            }
        }
        chars ~= (unit >= 0xD800 && unit <= 0xDFFF) ? cast(dchar) 0xFFFD : cast(dchar) unit;
    }
    return to!string(chars);
}

/// The `<meta charset>` / `<meta http-equiv="content-type">` label declared in
/// the first 1024 bytes, or "" when none is present (WHATWG Encoding 13.2.3.2).
string metaCharset(const(ubyte)[] bytes)
{
    const window = bytes.length > 1024 ? bytes[0 .. 1024] : bytes;
    auto text = decodeCp1252(window); // the declaration itself is ASCII in practice
    import std.string : toLower, indexOf;
    auto low = toLower(text);
    size_t pos = 0;
    while (true)
    {
        auto at = indexOf(low[pos .. $], "<meta");
        if (at < 0) return "";
        pos += at + 5;
        auto end = indexOf(low[pos .. $], ">");
        if (end < 0) return "";
        auto tag = low[pos .. pos + end];
        auto label = charsetFromTag(tag);
        if (label.length) return label;
        pos += end + 1;
    }
}

/// Pull the charset out of one lower-cased `<meta ...>` tag's attribute text.
private string charsetFromTag(string tag)
{
    import std.string : indexOf;
    auto at = indexOf(tag, "charset");
    if (at < 0) return "";
    size_t i = at + 7;
    while (i < tag.length && (tag[i] == ' ' || tag[i] == '\t' ||
                              tag[i] == '=' || tag[i] == '"' || tag[i] == '\''))
        i++;
    string label;
    while (i < tag.length)
    {
        const c = tag[i];
        const ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == ':';
        if (!ok) break;
        label ~= c;
        i++;
    }
    return label;
}

/// The canonical encoding the bytes and the response header imply, following the
/// WHATWG order: a BOM, then the Content-Type charset, then the document's
/// `<meta>` declaration, then UTF-8 (with the browser's windows-1252 behaviour
/// for unlabelled bytes that are not valid UTF-8).
string sniffEncoding(const(ubyte)[] bytes, string contentType)
{
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return "utf-16le";
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return "utf-16be";
    auto label = charsetFromContentType(contentType);
    if (label.length == 0) label = metaCharset(bytes);
    auto canonical = normalizeLabel(label);
    if (canonical.length) return canonical;
    if (isValidUtf8(bytes)) return "utf-8";
    return "windows-1252";
}

/// Decode a fetched text body to UTF-8.
/// `contentType` is the raw `Content-Type` header value (may be empty).
string decodeText(const(ubyte)[] bytes, string contentType)
{
    if (bytes.length == 0) return "";

    // A UTF-8 BOM is dropped; UTF-16 keeps its BOM-stripping in decodeUtf16.
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        return cast(string) bytes[3 .. $];
    auto encoding = sniffEncoding(bytes, contentType);
    if (encoding == "utf-16le" || encoding == "utf-16be")
    {
        const hasBom = bytes.length >= 2 &&
            ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));
        return decodeUtf16(hasBom ? bytes[2 .. $] : bytes, encoding == "utf-16le");
    }
    if (encoding == "windows-1252") return decodeCp1252(bytes);
    return cast(string) bytes;
}

/// The `charset=` parameter of a Content-Type header value, or "".
string charsetFromContentType(string contentType)
{
    import std.string : toLower, indexOf;
    auto low = toLower(contentType);
    auto at = indexOf(low, "charset=");
    if (at < 0) return "";
    size_t i = at + 8;
    if (i < low.length && (low[i] == '"' || low[i] == '\'')) i++;
    string label;
    while (i < low.length)
    {
        const c = low[i];
        const ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == ':';
        if (!ok) break;
        label ~= c;
        i++;
    }
    return label;
}

/// Decode a CSS/JS body. No `<meta>` sniffing (that is an HTML rule); instead
/// CSS 4.4 applies: BOM, then the sheet's own Content-Type charset, then the
/// referring document's encoding `envEncoding`, then UTF-8. A stylesheet's
/// selector must decode the same way as the document's class names or its rules
/// silently stop matching: an ASCII-only document whose class reached the DOM
/// through `&#233;` never matched a windows-1252 sheet's raw 0xE9 byte, so the
/// element kept its unstyled colour.
string decodeStyleSheet(const(ubyte)[] bytes, string contentType, string envEncoding = "")
{
    if (bytes.length == 0) return "";
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        return cast(string) bytes[3 .. $];
    auto canonical = normalizeLabel(charsetFromContentType(contentType));
    if (canonical == "windows-1252") return decodeCp1252(bytes);
    if (canonical == "utf-16le") return decodeUtf16(bytes, true);
    if (canonical == "utf-16be") return decodeUtf16(bytes, false);
    if (canonical.length == 0 && envEncoding.length &&
        normalizeLabel(envEncoding) == "windows-1252")
        return decodeCp1252(bytes);
    if (isValidUtf8(bytes)) return cast(string) bytes;
    return decodeCp1252(bytes);
}

unittest
{
    // windows-1252: 0xE9 is é, and 0x93/0x94 are the typographic quotes that
    // plain Latin-1 would turn into control characters.
    auto cp = decodeCp1252(cast(ubyte[]) [0x63, 0x61, 0x66, 0xE9]);
    assert(cp == "café", "cp1252 é: " ~ cp);
    auto quotes = decodeCp1252(cast(ubyte[]) [0x93, 0x78, 0x94]);
    assert(quotes == "\u201Cx\u201D", "cp1252 quotes: " ~ quotes);

    // Valid UTF-8 passes through; an unlabelled invalid byte falls back to cp1252.
    assert(decodeText(cast(ubyte[]) "abc", "") == "abc", "ascii passthrough");
    assert(decodeText(cast(ubyte[]) [0xE9], "") == "é", "unlabelled cp1252 fallback");
    auto utf8 = cast(ubyte[]) [0x61, 0xC3, 0xA9];
    assert(decodeText(utf8, "") == "aé", "valid utf-8 passthrough");

    // A meta declaration is honoured when the header carries no charset.
    auto html = cast(ubyte[]) "<meta charset=windows-1252><p>x</p>";
    assert(decodeText(html ~ cast(ubyte[]) [0xE9], "text/html") ==
        decodeText(html, "text/html") ~ "é", "meta charset drives decoding");

    // Content-Type parameters win over the meta.
    assert(charsetFromContentType("text/html; charset=ISO-8859-1") == "iso-8859-1",
        "content-type charset parameter");
    assert(normalizeLabel("ISO-8859-1") == "windows-1252", "latin1 alias");
    assert(charsetFromContentType("text/html") == "", "no parameter");

    // A BOM is stripped, and the byte order is honoured.
    auto bom = cast(ubyte[]) [0xEF, 0xBB, 0xBF, 0x61];
    assert(decodeText(bom, "") == "a", "utf-8 BOM stripped");
    auto u16le = cast(ubyte[]) [0xFF, 0xFE, 0x61, 0x00, 0xE9, 0x00];
    assert(decodeText(u16le, "") == "aé", "utf-16le BOM");
    auto u16be = cast(ubyte[]) [0xFE, 0xFF, 0x00, 0x61, 0x00, 0xE9];
    assert(decodeText(u16be, "") == "aé", "utf-16be BOM");

    // Invalid UTF-8 detection covers overlong forms and stray continuation bytes.
    assert(!isValidUtf8(cast(ubyte[]) [0xC0, 0x80]), "overlong is invalid");
    assert(!isValidUtf8(cast(ubyte[]) [0x80]), "stray continuation is invalid");
    assert(isValidUtf8(cast(ubyte[]) [0xF0, 0x9F, 0x98, 0x80]), "4-byte utf-8 is valid");

    // CSS 4.4: an unlabelled stylesheet inherits the document's encoding, and a
    // labelled one uses its own. The raw 0xE9 byte must become é either way.
    auto sheet = cast(ubyte[]) ".bar.caf\xE9{color:red}";
    assert(decodeStyleSheet(sheet, "text/css; charset=windows-1252") ==
        ".bar.café{color:red}", "the sheet's own charset");
    assert(decodeStyleSheet(sheet, "text/css", "windows-1252") ==
        ".bar.café{color:red}", "inherited document encoding");
    assert(decodeStyleSheet(cast(ubyte[]) ".a{color:red}", "text/css") ==
        ".a{color:red}", "plain ASCII sheet");

    // sniffEncoding reports the encoding the bytes and header imply.
    assert(sniffEncoding(cast(ubyte[]) "abc", "text/html") == "utf-8", "ascii sniffs utf-8");
    assert(sniffEncoding(cast(ubyte[]) [0xE9], "text/html") == "windows-1252",
        "unlabelled invalid utf-8 sniffs windows-1252");
    assert(sniffEncoding(cast(ubyte[]) "abc", "text/html; charset=iso-8859-1") ==
        "windows-1252", "header wins");
}

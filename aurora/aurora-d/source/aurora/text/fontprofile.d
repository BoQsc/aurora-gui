module aurora.text.fontprofile;

// Legacy thin-family classification follows Microsoft Terminal's documented
// DirectWrite behavior. The name comes from the font, never its filename.
// https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/dwrite_helpers.cpp

private ushort u16(const(ubyte)[] bytes, size_t offset) @safe pure nothrow @nogc
{
    return cast(ushort) ((cast(uint) bytes[offset] << 8) | bytes[offset + 1]);
}

private bool matches(const(ubyte)[] bytes, string name, bool utf16) @safe pure nothrow @nogc
{
    if (bytes.length != name.length * (utf16 ? 2 : 1)) return false;
    foreach (i, ch; name)
    {
        if (utf16)
        {
            if (bytes[2 * i] != 0 || bytes[2 * i + 1] != ch) return false;
        }
        else if (bytes[i] != ch) return false;
    }
    return true;
}

bool needsThinCoverageBoost(const(ubyte)[] nameTable) @safe pure nothrow @nogc
{
    if (nameTable.length < 6 || u16(nameTable, 0) > 1) return false;
    const count = u16(nameTable, 2);
    const storage = cast(size_t) u16(nameTable, 4);
    if (count > (nameTable.length - 6) / 12 || storage > nameTable.length) return false;
    int best = -1;
    bool thin;
    foreach (i; 0 .. count)
    {
        const record = 6 + cast(size_t) i * 12;
        const platform = u16(nameTable, record);
        const encoding = u16(nameTable, record + 2);
        const language = u16(nameTable, record + 4);
        const id = u16(nameTable, record + 6);
        if (id != 1 && id != 16) continue;
        const utf16 = platform == 0 || (platform == 3 && (encoding == 0 || encoding == 1 || encoding == 10));
        if (!utf16 && !(platform == 1 && encoding == 0)) continue;
        const length = cast(size_t) u16(nameTable, record + 8);
        const start = storage + u16(nameTable, record + 10);
        if (start > nameTable.length || length > nameTable.length - start || (utf16 && length % 2)) continue;
        const english = (platform == 3 && (language & 0x3ff) == 9) ||
            (platform == 1 && language == 0) || (platform == 0 && language == 0);
        const score = (english ? 16 : 0) + (language == 0x409 ? 8 : 0) + (id == 16 ? 2 : 0);
        if (score <= best) continue;
        best = score;
        thin = false;
        const bytes = nameTable[start .. start + length];
        foreach (name; ["Courier New", "Fixed Miriam Transparent", "Miriam Fixed",
            "Rod", "Rod Transparent", "Simplified Arabic Fixed"])
            if (matches(bytes, name, utf16)) { thin = true; break; }
    }
    return thin;
}

unittest
{
    ubyte[] table(string name, ushort platform = 3, ushort language = 0x409, ushort id = 1)
    {
        ubyte[] value = [0, 0, 0, 1, 0, 18, 0, cast(ubyte) platform, 0, 1,
            cast(ubyte) (language >> 8), cast(ubyte) language, 0, cast(ubyte) id,
            0, cast(ubyte) (name.length * 2), 0, 0];
        foreach (ch; name) { value ~= 0; value ~= cast(ubyte) ch; }
        return value;
    }
    assert(needsThinCoverageBoost(table("Courier New")));
    assert(needsThinCoverageBoost(table("Rod Transparent", 0, 0, 16)));
    assert(!needsThinCoverageBoost(table("Courier New Fake")));
    assert(!needsThinCoverageBoost(table("Consolas")));
    assert(!needsThinCoverageBoost(table("Courier New", 3, 0x409, 4)));
    auto invalid = table("Courier New");
    invalid[17] = 255;
    assert(!needsThinCoverageBoost(invalid));
    assert(!needsThinCoverageBoost(invalid[0 .. 4]));
}

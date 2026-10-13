module auroraopencode.readprogress;

import std.json : JSONValue, parseJSON;
import std.conv : to;
import std.format : format;
import std.string : startsWith;
import auroraopencode.transferprogress : transferBytes;

public struct ReadProgress
{
    string phase, path;
    ulong bytesRead, totalBytes, line, collected, offset = 1, limit;
    long elapsedMs, lastActivityMs;
    bool totalKnown, terminal;
    string[] preview;
    double fraction() const
    {
        if (!totalKnown) return 0;
        if (!totalBytes) return terminal ? 1 : 0;
        return bytesRead >= totalBytes ? 1 : cast(double) bytesRead / totalBytes;
    }
}

private enum prefix = "\x1eaurora-read ";
public string encodeReadProgress(const ref ReadProgress p)
{
    JSONValue v;
    v["phase"] = p.phase;
    v["path"] = p.path;
    static foreach (field; ["bytesRead", "totalBytes", "line", "collected", "offset", "limit"])
        v[field] = cast(long) __traits(getMember, p, field);
    v["elapsedMs"] = p.elapsedMs;
    v["lastActivityMs"] = p.lastActivityMs;
    v["totalKnown"] = p.totalKnown;
    v["terminal"] = p.terminal;
    v["preview"] = JSONValue.emptyArray;
    const first = p.preview.length > 6 ? p.preview.length - 6 : 0;
    foreach (line; p.preview[first .. $])
    {
        size_t end = line.length > 400 ? 400 : line.length;
        while (end < line.length && end > 0 && (cast(ubyte) line[end] & 0xC0) == 0x80) --end;
        v["preview"].array ~= JSONValue(line[0 .. end]);
    }
    return prefix ~ v.toString();
}

public bool decodeReadProgress(string text, out ReadProgress p)
{
    if (!text.startsWith(prefix) || text.length > 32768) return false;
    try
    {
        const v = parseJSON(text[prefix.length .. $]);
        p.phase = v["phase"].str; p.path = v["path"].str;
        static foreach (field; ["bytesRead", "totalBytes", "line", "collected", "offset", "limit"])
        {
            if (v[field].integer < 0) return false;
            __traits(getMember, p, field) = cast(ulong) v[field].integer;
        }
        p.elapsedMs = v["elapsedMs"].integer;
        p.lastActivityMs = v["lastActivityMs"].integer;
        p.totalKnown = v["totalKnown"].boolean;
        p.terminal = v["terminal"].boolean;
        if (p.elapsedMs < 0 || p.lastActivityMs < 0 || v["preview"].array.length > 6) return false;
        foreach (line; v["preview"].array) p.preview ~= line.str;
        return true;
    }
    catch (Exception) return false;
}

public string readProgressText(const ref ReadProgress p)
{
    auto text = p.phase ~ "\nFile: " ~ p.path ~ "\nRequested: line " ~ to!string(p.offset) ~
        (p.limit ? " · up to " ~ to!string(p.limit) ~ " lines" : " · until the output limit");
    if (p.totalKnown)
        text ~= format("\nRead %.0f%% of file bytes · ", p.fraction() * 100) ~
            transferBytes(p.bytesRead) ~ " / " ~ transferBytes(p.totalBytes);
    else text ~= "\nFile size not known yet; no measured percentage.";
    text ~= "\nCurrent line: " ~ to!string(p.line) ~ " · returned " ~ to!string(p.collected) ~ " lines";
    if (!p.terminal)
        text ~= "\nElapsed " ~ to!string(p.elapsedMs / 1000) ~ "s · no new file activity for " ~
            to!string(p.lastActivityMs / 1000) ~ "s · host deadline at most 30s";
    if (p.preview.length)
    {
        text ~= "\nReturned lines so far:";
        foreach (line; p.preview) text ~= "\n" ~ line;
    }
    return text;
}

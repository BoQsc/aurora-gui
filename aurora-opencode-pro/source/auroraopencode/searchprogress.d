module auroraopencode.searchprogress;

import core.time : MonoTime, msecs;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.string : replace, startsWith;
import auroraopencode.transferprogress : transferBytes;

public struct SearchProgress
{
    string phase, root, path, query, filter;
    ulong directories, files, entries, lines, bytes, matches;
    ulong skippedFiltered, skippedDirectories, skippedBinary, skippedLarge, skippedLinks, errors;
    ulong pending;
    long elapsedMs, lastActivityMs;
    bool terminal, partial;
    string[] latest;
}

private enum prefix = "\x1eaurora-search ";

private string bounded(string text, size_t limit)
{
    text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ");
    if (text.length <= limit) return text;
    while (limit && (cast(ubyte) text[limit] & 0xC0) == 0x80) --limit;
    return text[0 .. limit] ~ "…";
}

public string encodeSearchProgress(const ref SearchProgress p)
{
    JSONValue value;
    value["phase"] = bounded(p.phase, 120);
    value["root"] = bounded(p.root, 2000);
    value["path"] = bounded(p.path, 2000);
    value["query"] = bounded(p.query, 600);
    value["filter"] = bounded(p.filter, 300);
    static foreach (field; ["directories", "files", "entries", "lines", "bytes", "matches",
        "skippedFiltered", "skippedDirectories", "skippedBinary", "skippedLarge", "skippedLinks", "errors", "pending"])
        value[field] = cast(long) __traits(getMember, p, field);
    value["elapsedMs"] = p.elapsedMs;
    value["lastActivityMs"] = p.lastActivityMs;
    value["terminal"] = p.terminal;
    value["partial"] = p.partial;
    value["latest"] = JSONValue.emptyArray;
    const first = p.latest.length > 2 ? p.latest.length - 2 : 0;
    foreach (hit; p.latest[first .. $]) value["latest"].array ~= JSONValue(bounded(hit, 360));
    return prefix ~ value.toString();
}

public bool decodeSearchProgress(string text, out SearchProgress p)
{
    if (!text.startsWith(prefix) || text.length > 16384) return false;
    try
    {
        const value = parseJSON(text[prefix.length .. $]);
        static foreach (field; ["phase", "root", "path", "query", "filter"])
            __traits(getMember, p, field) = value[field].str;
        static foreach (field; ["directories", "files", "entries", "lines", "bytes", "matches",
            "skippedFiltered", "skippedDirectories", "skippedBinary", "skippedLarge", "skippedLinks", "errors", "pending"])
        {
            if (value[field].integer < 0) return false;
            __traits(getMember, p, field) = cast(ulong) value[field].integer;
        }
        p.elapsedMs = value["elapsedMs"].integer;
        p.lastActivityMs = value["lastActivityMs"].integer;
        if (p.elapsedMs < 0 || p.lastActivityMs < 0) return false;
        p.terminal = value["terminal"].boolean;
        p.partial = value["partial"].boolean;
        if (value["latest"].array.length > 2) return false;
        foreach (hit; value["latest"].array) p.latest ~= hit.str;
        return true;
    }
    catch (Exception) return false;
}

public string searchProgressText(const ref SearchProgress p, bool preview = true)
{
    string text = p.phase ~ format(" · %.1fs", p.elapsedMs / 1000.0);
    if (p.lastActivityMs >= 1000 && !p.terminal)
        text ~= format(" · no new scan activity for %.1fs", p.lastActivityMs / 1000.0);
    if (p.query.length) text ~= "\nFind: " ~ bounded(p.query, 600) ~
        (p.filter.length ? " · " ~ bounded(p.filter, 300) : "");
    text ~= "\nScope: " ~ bounded(p.root, 2000);
    if (preview && p.path.length) text ~= "\nCurrent: " ~ bounded(p.path, 2000);
    text ~= "\nChecked " ~ to!string(p.files) ~ " files · " ~ to!string(p.directories) ~
        " folders · " ~ to!string(p.entries) ~ " entries · " ~ to!string(p.matches) ~ " matches";
    if (p.lines || p.bytes) text ~= "\nRead " ~ to!string(p.lines) ~ " lines · " ~ transferBytes(p.bytes);
    text ~= "\nSkipped: " ~ to!string(p.skippedFiltered) ~ " filtered · " ~
        to!string(p.skippedDirectories) ~ " generated folders · " ~
        to!string(p.skippedBinary) ~ " binary · " ~ to!string(p.skippedLarge) ~
        " oversized · " ~ to!string(p.skippedLinks) ~ " links · " ~ to!string(p.errors) ~ " unreadable";
    if (p.pending) text ~= " · " ~ to!string(p.pending) ~ " queued entries";
    if (preview) foreach (hit; p.latest) text ~= "\nLatest: " ~ bounded(hit, 360);
    return text;
}

public final class SearchReporter
{
    SearchProgress value;
    private void delegate(string) observer;
    private MonoTime started, next;

    this(string phase, string root, string query, string filter, void delegate(string) observer)
    {
        this.observer = observer;
        started = MonoTime.currTime;
        value.phase = phase; value.root = root; value.path = root;
        value.query = query; value.filter = filter;
    }

    void report(string[] hits = null, bool force = false)
    {
        if (!force && MonoTime.currTime < next) return;
        value.elapsedMs = (MonoTime.currTime - started).total!"msecs";
        value.latest = null;
        const first = hits.length > 2 ? hits.length - 2 : 0;
        foreach (hit; hits[first .. $]) value.latest ~= bounded(hit, 360);
        if (observer !is null) observer(encodeSearchProgress(value));
        next = MonoTime.currTime + 200.msecs;
    }
}

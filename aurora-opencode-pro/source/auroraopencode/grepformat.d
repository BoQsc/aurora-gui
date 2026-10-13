module auroraopencode.grepformat;
import std.regex : ctRegex, matchFirst;
import std.string : splitLines;
import std.array : appender;

/// Compact classic grep history on the wire without modifying saved messages.
public string compactGrepHistory(string text)
{
    auto output = appender!string();
    string lastPath;
    bool changed;
    foreach (line; text.splitLines())
    {
        auto match = matchFirst(line, ctRegex!`^((?:[A-Za-z]:[\\/]|/).*?)([:\-])([0-9]+)\2 (.*)$`);
        if (match.empty) { output.put(line ~ "\n"); continue; }
        const path = match.captures[1];
        if (path != lastPath) { output.put("File: " ~ path ~ "\n"); lastPath = path; }
        output.put(match.captures[3] ~ match.captures[2] ~ " " ~ match.captures[4] ~ "\n");
        changed = true;
    }
    return changed ? output.data : text;
}

module auroraopencode.searchscope;

import auroraopencode.nativeio : NativeCancel;
import core.time : MonoTime, msecs;
import std.algorithm : sort, startsWith;
import std.file : dirEntries, exists, isFile, SpanMode;
import std.path : baseName, buildPath;
import std.string : toLower;

bool narrowsSearchInclude(string include)
{
    return include.length && include != "*" && include != "**" &&
        include != "*.*" && include != "**/*";
}

bool generatedSearchDirectory(string directory)
{
    switch (baseName(directory).toLower())
    {
        case ".git", ".hg", ".svn", ".dub", ".cache", ".idea", ".vscode",
            "build", "dist", "out", "target", "node_modules", "coverage", "__pycache__",
            ".aurora", ".audit-inputs", "artifacts", "screenshots": return true;
        default: return false;
    }
}

private bool projectDirectory(string path)
{
    foreach (manifest; ["dub.json", "dub.sdl", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "CMakeLists.txt", "pom.xml", "build.gradle"])
        if (exists(buildPath(path, manifest)) && isFile(buildPath(path, manifest))) return true;
    return false;
}

// Separator-insensitive project names only, never an approximation of arbitrary
// regex semantics. Returned paths are discovery hints, not content matches.
private string projectName(string query)
{
    string result;
    foreach (ch; query.toLower())
    {
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) result ~= ch;
        else if (ch != '-' && ch != '_' && ch != '.' && ch != '?' && ch != ' ') return "";
    }
    return result.length >= 4 ? result : "";
}

string[] discoverProjectScopes(string root, string query, NativeCancel cancelled = null)
{
    const wanted = projectName(query);
    if (!wanted.length || projectDirectory(root)) return null;
    struct Candidate { string path; bool exact; }
    Candidate[] candidates;
    const deadline = MonoTime.currTime + 250.msecs;
    size_t entries;
    bool stopped() { return entries >= 2000 || MonoTime.currTime >= deadline ||
        (cancelled !is null && cancelled()); }
    void visit(string directory, size_t depth)
    {
        if (stopped()) return;
        string[] children;
        try foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (stopped()) break;
            ++entries;
            if (entry.isDir && !entry.isSymlink && !generatedSearchDirectory(entry.name) &&
                baseName(entry.name).toLower() != "vendor") children ~= entry.name;
        }
        catch (Exception) { return; }
        // Common project containers go before incidental asset/document trees.
        int priority(string path)
        {
            switch (baseName(path).toLower())
            {
                case "apps", "packages", "projects", "experiments", "services", "modules": return 0;
                default: return 1;
            }
        }
        children.sort!((a, b) => priority(a) == priority(b) ? a < b : priority(a) < priority(b));
        foreach (child; children)
        {
            if (stopped()) break;
            const name = projectName(baseName(child));
            bool project;
            try project = projectDirectory(child); catch (Exception) { continue; }
            if (project && name.startsWith(wanted) && candidates.length < 16)
                candidates ~= Candidate(child, name == wanted);
            if (!project && depth < 2) visit(child, depth + 1);
        }
    }
    visit(root, 0);
    candidates.sort!((a, b) => a.exact == b.exact ? a.path < b.path : a.exact);
    string[] result;
    foreach (candidate; candidates) result ~= candidate.path;
    return result;
}

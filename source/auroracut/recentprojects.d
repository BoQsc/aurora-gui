module auroracut.recentprojects;

import auroracut.util : absoluteNormalized, appLog, applicationStateDirectory,
    ensureParentDirectory;
import std.file : exists, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, extension, filenameCmp;
import std.string : strip, toLower;

private enum size_t recentProjectDisplayLimit = 12;
private enum size_t recentProjectStorageLimit = 48;
private string _recentProjectsPathOverride;

void setRecentProjectsFilePathForTesting(string path)
{
    _recentProjectsPathOverride = path;
}

string recentProjectsFilePath()
{
    if (_recentProjectsPathOverride.length > 0)
        return _recentProjectsPathOverride;
    return buildPath(applicationStateDirectory(), "recent-projects.json");
}

private const(JSONValue)* member(const JSONValue value, string key)
{
    if (value.type != JSONType.object) return null;
    auto found = key in value.object;
    return found;
}

private string normalizedProjectPath(string path)
{
    path = path.strip();
    if (path.length == 0) return "";
    if (extension(path).toLower() != ".auroracut") return "";
    return absoluteNormalized(path);
}

private bool containsPath(const string[] paths, string path)
{
    foreach (existing; paths)
        if (filenameCmp(existing, path) == 0) return true;
    return false;
}

private string[] readRecentProjectEntries()
{
    const path = recentProjectsFilePath();
    if (!exists(path)) return [];

    const root = parseJSON(readText(path));
    string[] raw;
    if (root.type == JSONType.array)
    {
        foreach (entry; root.array)
            if (entry.type == JSONType.string) raw ~= entry.str;
    }
    else
    {
        auto projects = member(root, "projects");
        if (projects !is null && projects.type == JSONType.array)
            foreach (entry; projects.array)
                if (entry.type == JSONType.string) raw ~= entry.str;
    }
    return raw;
}

private string[] sanitizeRecentProjects(string[] paths, bool existingOnly,
    size_t limit)
{
    string[] result;
    foreach (path; paths)
    {
        const normalized = normalizedProjectPath(path);
        if (normalized.length == 0) continue;
        if (existingOnly && !exists(normalized)) continue;
        if (containsPath(result, normalized)) continue;
        result ~= normalized;
        if (result.length >= limit) break;
    }
    return result;
}

string[] loadRecentProjects(bool existingOnly = false)
{
    try
    {
        return sanitizeRecentProjects(readRecentProjectEntries(), existingOnly,
            recentProjectDisplayLimit);
    }
    catch (Exception error)
    {
        appLog("Could not read recent projects: " ~ error.toString());
        return [];
    }
}

private string[] loadStoredRecentProjects()
{
    try
    {
        return sanitizeRecentProjects(readRecentProjectEntries(), false,
            recentProjectStorageLimit);
    }
    catch (Exception error)
    {
        appLog("Could not read stored recent projects: " ~ error.toString());
        return [];
    }
}

bool hasUnavailableRecentProjects()
{
    try
    {
        string[] seen;
        foreach (path; readRecentProjectEntries())
        {
            const normalized = normalizedProjectPath(path);
            if (normalized.length == 0) continue;
            if (containsPath(seen, normalized)) continue;
            seen ~= normalized;
            if (!exists(normalized)) return true;
        }
    }
    catch (Exception error)
    {
        appLog("Could not inspect recent projects: " ~ error.toString());
    }
    return false;
}

private void writeRecentProjects(string[] paths)
{
    const sanitized = sanitizeRecentProjects(paths, false,
        recentProjectStorageLimit);
    JSONValue[] projects;
    foreach (path; sanitized) projects ~= JSONValue(path);
    JSONValue root = JSONValue([
        "format": JSONValue("aurora-cut-recent-projects"),
        "version": JSONValue(1L),
        "projects": JSONValue(projects)
    ]);

    const path = recentProjectsFilePath();
    ensureParentDirectory(path);
    write(path, root.toPrettyString());
}

void rememberRecentProject(string path)
{
    try
    {
        const normalized = normalizedProjectPath(path);
        if (normalized.length == 0) return;

        string[] next;
        next ~= normalized;
        foreach (existing; loadStoredRecentProjects())
        {
            if (filenameCmp(existing, normalized) == 0) continue;
            next ~= existing;
            if (next.length >= recentProjectStorageLimit) break;
        }
        writeRecentProjects(next);
    }
    catch (Exception error)
    {
        appLog("Could not update recent projects: " ~ error.toString());
    }
}

void clearRecentProjects()
{
    try writeRecentProjects([]);
    catch (Exception error)
        appLog("Could not clear recent projects: " ~ error.toString());
}

void clearUnavailableRecentProjects()
{
    try writeRecentProjects(loadRecentProjects(true));
    catch (Exception error)
        appLog("Could not clear unavailable recent projects: " ~ error.toString());
}

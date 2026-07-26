module auroracut.recentprojects;

import auroracut.util : absoluteNormalized, appLog, applicationStateDirectory,
    ensureParentDirectory;
import std.file : exists, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, extension, filenameCmp;
import std.string : strip, toLower;

private enum size_t recentProjectLimit = 12;
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

private string[] sanitizeRecentProjects(string[] paths, bool existingOnly)
{
    string[] result;
    foreach (path; paths)
    {
        const normalized = normalizedProjectPath(path);
        if (normalized.length == 0) continue;
        if (existingOnly && !exists(normalized)) continue;
        if (containsPath(result, normalized)) continue;
        result ~= normalized;
        if (result.length >= recentProjectLimit) break;
    }
    return result;
}

string[] loadRecentProjects(bool existingOnly = false)
{
    try
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
        return sanitizeRecentProjects(raw, existingOnly);
    }
    catch (Exception error)
    {
        appLog("Could not read recent projects: " ~ error.toString());
        return [];
    }
}

private void writeRecentProjects(string[] paths)
{
    const sanitized = sanitizeRecentProjects(paths, false);
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
        foreach (existing; loadRecentProjects(false))
        {
            if (filenameCmp(existing, normalized) == 0) continue;
            next ~= existing;
            if (next.length >= recentProjectLimit) break;
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

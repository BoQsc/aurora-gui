module opencodelite.settings;

import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;

struct LiteSettings
{
    string baseUrl = "https://api.openai.com/v1";
    string model = "gpt-4o-mini";
    string apiKey;
}

string defaultSettingsPath()
{
    auto root = environment.get("APPDATA", "");
    if (root.length == 0)
        root = environment.get("LOCALAPPDATA", "");
    if (root.length == 0)
        root = tempDir();
    return buildPath(root, "AuroraOpenCodeLite", "settings.json");
}

LiteSettings loadSettings(string path = null)
{
    LiteSettings settings;
    if (path.length == 0)
        path = defaultSettingsPath();
    if (!exists(path))
        return settings;
    try
    {
        const document = parseJSON(readText(path));
        if ("baseUrl" in document.object)
            settings.baseUrl = document["baseUrl"].str;
        if ("model" in document.object)
            settings.model = document["model"].str;
        if ("apiKey" in document.object)
            settings.apiKey = document["apiKey"].str;
    }
    catch (Exception)
    {
        // A malformed settings file falls back to defaults; the UI can repair it.
    }
    return settings;
}

void saveSettings(in LiteSettings settings, string path = null)
{
    if (path.length == 0)
        path = defaultSettingsPath();
    const directory = dirName(path);
    if (directory.length != 0 && !exists(directory))
        mkdirRecurse(directory);
    JSONValue document;
    document["baseUrl"] = settings.baseUrl;
    document["model"] = settings.model;
    document["apiKey"] = settings.apiKey;
    write(path, document.toString() ~ "\n");
}

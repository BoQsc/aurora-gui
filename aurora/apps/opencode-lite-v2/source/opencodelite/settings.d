module opencodelite.settings;

import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : strip, stripRight;

immutable string openCodeBaseUrl = "https://opencode.ai/zen/go/v1";
immutable string openCodeModel = "deepseek-v4.1-flash";
immutable string openAiBaseUrl = "https://api.openai.com/v1";
immutable string openAiModel = "gpt-4o-mini";

struct LiteSettings
{
    string baseUrl = openCodeBaseUrl;
    string model = openCodeModel;
    string apiKey;
    string openCodeKey;
    string openAiKey;
    string openCodeModelName = openCodeModel;
    string openAiModelName = openAiModel;
    bool thinkingOn = true;
    bool toolsOn;
    bool planOn;
}

bool isOpenCodeBaseUrl(string value)
{
    return normalizeBaseUrl(value) == normalizeBaseUrl(openCodeBaseUrl);
}

bool isOpenAiBaseUrl(string value)
{
    return normalizeBaseUrl(value) == normalizeBaseUrl(openAiBaseUrl);
}

private string normalizeBaseUrl(string value)
{
    return stripRight(strip(value), "/");
}

string defaultSettingsPath()
{
    auto root = environment.get("APPDATA", "");
    if (root.length == 0)
        root = environment.get("LOCALAPPDATA", "");
    if (root.length == 0)
        root = tempDir();
    return buildPath(root, "AuroraOpenCodeLiteV2", "settings.json");
}

LiteSettings loadSettings(string path = null)
{
    LiteSettings settings;
    if (path.length == 0)
        path = defaultSettingsPath();
    if (exists(path))
    {
        try
        {
            const document = parseJSON(readText(path));
            if ("baseUrl" in document.object)
                settings.baseUrl = document["baseUrl"].str;
            if ("model" in document.object)
                settings.model = document["model"].str;
            if ("apiKey" in document.object)
                settings.apiKey = document["apiKey"].str;
            if ("openCodeKey" in document.object)
                settings.openCodeKey = document["openCodeKey"].str;
            if ("openAiKey" in document.object)
                settings.openAiKey = document["openAiKey"].str;
            if ("openCodeModelName" in document.object)
                settings.openCodeModelName = document["openCodeModelName"].str;
            if ("openAiModelName" in document.object)
                settings.openAiModelName = document["openAiModelName"].str;
            if ("thinkingOn" in document.object)
                settings.thinkingOn = document["thinkingOn"].boolean;
            if ("toolsOn" in document.object)
                settings.toolsOn = document["toolsOn"].boolean;
            if ("planOn" in document.object)
                settings.planOn = document["planOn"].boolean;
        }
        catch (Exception)
        {
            // A malformed settings file falls back to defaults; the UI can repair it.
        }
    }
    if (settings.baseUrl.length == 0)
        settings.baseUrl = openCodeBaseUrl;
    if (settings.model.length == 0)
        settings.model = openCodeModel;
    if (settings.openCodeModelName.length == 0)
        settings.openCodeModelName = openCodeModel;
    if (settings.openAiModelName.length == 0)
        settings.openAiModelName = openAiModel;
    if (isOpenCodeBaseUrl(settings.baseUrl))
    {
        if (settings.openCodeKey.length == 0 && settings.apiKey.length > 0)
            settings.openCodeKey = settings.apiKey;
        if (settings.openCodeKey.length == 0)
            settings.openCodeKey = legacyOpenCodeKey();
        if (settings.apiKey.length == 0)
            settings.apiKey = settings.openCodeKey;
    }
    else if (isOpenAiBaseUrl(settings.baseUrl))
    {
        if (settings.openAiKey.length == 0 && settings.apiKey.length > 0)
            settings.openAiKey = settings.apiKey;
        if (settings.apiKey.length == 0)
            settings.apiKey = settings.openAiKey;
    }
    return settings;
}

private string legacyOpenCodeKey()
{
    const appData = environment.get("APPDATA", "");
    foreach (path; [
        buildPath(appData, "Aurora OpenCode", "Aurora OpenCode", "settings.json"),
        buildPath(appData, "Aurora OpenCode", "settings.json"),
    ])
    {
        if (appData.length == 0 || !exists(path))
            continue;
        try
        {
            const document = parseJSON(readText(path));
            if (document.type != JSONType.object)
                continue;
            if (auto key = "apiKey" in document.object)
                if (key.type == JSONType.string && key.str.length > 0)
                    return key.str;
            if (auto keyEntries = "providerKeys" in document.object)
            {
                if (keyEntries.type != JSONType.array)
                    continue;
                foreach (entry; keyEntries.array)
                {
                    if (entry.type != JSONType.object)
                        continue;
                    string providerId;
                    string providerBase;
                    if (auto value = "providerId" in entry.object)
                        if (value.type == JSONType.string)
                            providerId = value.str;
                    if (auto value = "baseUrl" in entry.object)
                        if (value.type == JSONType.string)
                            providerBase = value.str;
                    if (providerId != "opencode" &&
                        (providerBase.length == 0 ||
                         normalizeBaseUrl(providerBase) !=
                         normalizeBaseUrl(openCodeBaseUrl)))
                        continue;
                    string[] keys;
                    foreach (name; ["apiKey", "additionalApiKey"])
                        if (auto value = name in entry.object)
                            if (value.type == JSONType.string)
                                keys ~= value.str;
                    if (auto extra = "extraApiKeys" in entry.object)
                        if (extra.type == JSONType.array)
                            foreach (value; extra.array)
                                if (value.type == JSONType.string)
                                    keys ~= value.str;
                    size_t active;
                    if (auto value = "activeKeyIndex" in entry.object)
                        if (value.type == JSONType.integer && value.integer >= 0)
                            active = cast(size_t) value.integer;
                    if (active < keys.length && keys[active].length > 0)
                        return keys[active];
                    foreach (key; keys)
                        if (key.length > 0)
                            return key;
                }
            }
        }
        catch (Exception)
        {
            // Ignore a damaged legacy file and keep looking.
        }
    }
    auto key = environment.get("OPENCODE_API_KEY", "").strip();
    if (key.length > 0)
        return key;
    const profile = environment.get("USERPROFILE", "");
    if (profile.length == 0)
        return "";
    try
    {
        const authPath = buildPath(profile, ".local", "share", "opencode",
            "auth.json");
        if (!exists(authPath))
            return "";
        const document = parseJSON(readText(authPath));
        foreach (provider; ["opencode-go", "opencode"])
        {
            if (auto entry = provider in document.object)
            {
                if (entry.type != JSONType.object)
                    continue;
                if (auto value = "key" in entry.object)
                    if (value.type == JSONType.string && value.str.length > 0)
                        return value.str;
                if (auto value = "access" in entry.object)
                    if (value.type == JSONType.string && value.str.length > 0)
                        return value.str;
            }
        }
    }
    catch (Exception)
    {
    }
    return "";
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
    document["openCodeKey"] = settings.openCodeKey;
    document["openAiKey"] = settings.openAiKey;
    document["openCodeModelName"] = settings.openCodeModelName;
    document["openAiModelName"] = settings.openAiModelName;
    document["thinkingOn"] = JSONValue(settings.thinkingOn);
    document["toolsOn"] = JSONValue(settings.toolsOn);
    document["planOn"] = JSONValue(settings.planOn);
    write(path, document.toString() ~ "\n");
}

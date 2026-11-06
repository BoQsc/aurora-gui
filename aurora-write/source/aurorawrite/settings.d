/**
 * Aurora Write settings and provider credentials.
 *
 * Aurora Write is a standalone app, but it is part of Aurora: when its own
 * settings do not name a provider it borrows the ones Aurora OpenCode already
 * configured (`%APPDATA%\Aurora OpenCode\settings.json`), read-only. That keeps
 * one place for keys while still letting this app be pointed at any
 * OpenAI-compatible endpoint.
 */
module aurorawrite.settings;

import std.file : exists, readText, write, mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : strip, stripRight, toLower;

/// Everything the app persists.
struct WriteSettings
{
    string baseUrl;
    string apiKey;
    string model;
    /// Send `reasoning_effort: high` on the refinement request.
    bool thinking;
    /// Show the caret card at all.
    bool optimizer = true;
    /// Never contact a provider (offline writing, tests).
    bool offline;
    bool dark;
    /// Where the provider fields came from: `own`, `environment` or
    /// `aurora-opencode`. Informational, never persisted.
    string providerOrigin;

    bool configured() const @safe pure nothrow @nogc
    {
        return baseUrl.length > 0 && model.length > 0;
    }
}

/// This app's own settings file.
string settingsPath()
{
    const overridePath = environment.get("AURORA_WRITE_SETTINGS", "");
    if (overridePath.length > 0) return overridePath;
    const local = environment.get("LOCALAPPDATA", "");
    if (local.length > 0) return buildPath(local, "AuroraWrite", "settings.json");
    return "aurora-write-settings.json";
}

/// Aurora OpenCode's settings file, used only when this app has no provider.
string openCodeSettingsPath()
{
    const roaming = environment.get("APPDATA", "");
    if (roaming.length == 0) return "";
    return buildPath(roaming, "Aurora OpenCode", "settings.json");
}

private string stringField(JSONValue object, string key)
{
    if (object.type != JSONType.object) return "";
    auto found = key in object.object;
    if (found is null || found.type != JSONType.string) return "";
    return found.str;
}

private bool boolField(JSONValue object, string key, bool fallback)
{
    if (object.type != JSONType.object) return fallback;
    auto found = key in object.object;
    if (found is null) return fallback;
    if (found.type != JSONType.true_ && found.type != JSONType.false_)
        return fallback;
    return found.boolean;
}

private bool sameEndpoint(string left, string right)
{
    return left.strip.stripRight("/").toLowerAscii ==
        right.strip.stripRight("/").toLowerAscii;
}

/// Read this app's own settings; a missing or unreadable file yields defaults.
WriteSettings loadOwnSettings()
{
    WriteSettings settings;
    const path = settingsPath();
    if (!exists(path)) return settings;
    try
    {
        const value = parseJSON(readText(path));
        settings.baseUrl = stringField(value, "baseUrl");
        settings.apiKey = stringField(value, "apiKey");
        settings.model = stringField(value, "model");
        settings.thinking = boolField(value, "thinking", false);
        settings.optimizer = boolField(value, "optimizer", true);
        settings.offline = boolField(value, "offline", false);
        settings.dark = boolField(value, "dark", false);
        if (settings.configured()) settings.providerOrigin = "own";
    }
    catch (Exception)
    {
        // A corrupt settings file must not stop the editor from opening.
    }
    return settings;
}

/**
 * Screen-scoped fallback: the provider Aurora OpenCode has configured.
 *
 * OpenCode stores the live key on the root `apiKey` and keeps a per-endpoint
 * key list; the per-endpoint key wins when it exists, because the root key can
 * belong to a different provider than the selected base URL.
 */
private void borrowProvider(JSONValue value, ref WriteSettings settings)
{
    if (value.type != JSONType.object) return;
    const baseUrl = stringField(value, "baseUrl");
    const model = stringField(value, "model");
    if (baseUrl.length == 0 || model.length == 0) return;
    string key = stringField(value, "apiKey");
    if (auto keys = "providerKeys" in value.object)
    {
        if (keys.type == JSONType.array)
        {
            foreach (ref entry; keys.array)
            {
                if (!sameEndpoint(stringField(entry, "baseUrl"), baseUrl))
                    continue;
                const candidate = stringField(entry, "apiKey");
                if (candidate.length > 0) key = candidate;
                break;
            }
        }
    }
    settings.baseUrl = baseUrl;
    settings.model = model;
    settings.apiKey = key;
    settings.providerOrigin = "aurora-opencode";
}

/// Load own settings, then environment overrides, then the OpenCode fallback.
WriteSettings loadSettings()
{
    auto settings = loadOwnSettings();

    const baseUrl = environment.get("AURORA_WRITE_BASE_URL", "");
    const apiKey = environment.get("AURORA_WRITE_API_KEY", "");
    const model = environment.get("AURORA_WRITE_MODEL", "");
    if (baseUrl.length > 0) settings.baseUrl = baseUrl;
    if (model.length > 0) settings.model = model;
    if (apiKey.length > 0) settings.apiKey = apiKey;
    if (baseUrl.length > 0 || model.length > 0 || apiKey.length > 0)
        settings.providerOrigin = "environment";
    const thinking = environment.get("AURORA_WRITE_THINKING", "");
    if (thinking.length > 0) settings.thinking = thinking == "1" ||
        thinking == "on" || thinking == "true";
    const disabled = environment.get("AURORA_WRITE_OPTIMIZER", "");
    if (disabled.length > 0) settings.optimizer = !(disabled == "0" ||
        disabled == "off" || disabled == "false");
    const offline = environment.get("AURORA_WRITE_OFFLINE", "");
    if (offline.length > 0) settings.offline = offline == "1" ||
        offline == "on" || offline == "true";

    if (!settings.configured())
    {
        const path = openCodeSettingsPath();
        if (path.length > 0 && exists(path))
        {
            try borrowProvider(parseJSON(readText(path)), settings);
            catch (Exception) {}
        }
    }
    return settings;
}

/// Persist the fields this app owns.
void saveSettings(const ref WriteSettings settings, string path = "")
{
    const target = path.length > 0 ? path : settingsPath();
    JSONValue root;
    try
    {
        try root = parseJSON(exists(target) ? readText(target) : "{}");
        catch (Exception) root = JSONValue();
    }
    catch (Exception) {}
    if (root.type != JSONType.object) root = JSONValue();
    root["baseUrl"] = settings.baseUrl;
    root["apiKey"] = settings.apiKey;
    root["model"] = settings.model;
    root["thinking"] = settings.thinking;
    root["optimizer"] = settings.optimizer;
    root["offline"] = settings.offline;
    root["dark"] = settings.dark;
    try
    {
        const folder = dirName(target);
        if (folder.length > 0 && folder != "." && !exists(folder))
            mkdirRecurse(folder);
        write(target, root.toString() ~ "\n");
    }
    catch (Exception)
    {
        // Saving settings is best effort; the session keeps working.
    }
}

private string toLowerAscii(string value) @safe pure nothrow
{
    char[] buffer = value.dup;
    foreach (ref char c; buffer)
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return buffer.idup;
}

module aurorastream.settings;

import aurorastream.broadcast : BroadcastQuality, BroadcastSettings;
import std.file : exists, getcwd, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;

/// Portable settings file kept beside the folder Aurora Stream is launched from.
enum settingsFileName = "aurora-stream-settings.json";

enum settingsSchemaVersion = 5;

string settingsFilePath()
{
    try return buildPath(getcwd(), settingsFileName);
    catch (Exception) return settingsFileName;
}

private string backupFilePath()
{
    return settingsFilePath() ~ ".bak";
}

private string temporaryFilePath()
{
    return settingsFilePath() ~ ".tmp";
}

private void recoverInterruptedSave()
{
    const path = settingsFilePath();
    const backup = backupFilePath();
    if (!exists(path) && exists(backup))
    {
        try rename(backup, path);
        catch (Exception) {}
    }
}

private bool hasJsonKey(const JSONValue root, string key)
{
    if (root.type != JSONType.object) return false;
    return (key in root) !is null;
}

private bool jsonBool(const JSONValue root, string key, bool fallback)
{
    if (root.type != JSONType.object) return fallback;
    const value = key in root;
    if (value is null) return fallback;
    if (value.type != JSONType.true_ && value.type != JSONType.false_)
        return fallback;
    return value.boolean;
}

private string jsonString(const JSONValue root, string key, string fallback)
{
    if (root.type != JSONType.object) return fallback;
    const value = key in root;
    if (value is null || value.type != JSONType.string) return fallback;
    return value.str;
}

private BroadcastQuality qualityFromString(string value,
    BroadcastQuality fallback)
{
    switch (value)
    {
        case "2k": return BroadcastQuality.twoK;
        case "4k": return BroadcastQuality.fourK;
        case "1080p": return BroadcastQuality.fullHD;
        default: return fallback;
    }
}

private string qualityToString(BroadcastQuality quality)
{
    switch (quality)
    {
        case BroadcastQuality.twoK: return "2k";
        case BroadcastQuality.fourK: return "4k";
        default: return "1080p";
    }
}

private BroadcastSettings settingsFromJson(string source)
{
    BroadcastSettings settings;
    const root = parseJSON(source);
    if (root.type != JSONType.object)
        throw new Exception("The settings root must be a JSON object.");
    const desktopAudioEnabledWasSaved =
        hasJsonKey(root, "desktopAudioEnabled");

    settings.twitchEnabled = jsonBool(root, "twitchEnabled",
        settings.twitchEnabled);
    settings.twitchServer = jsonString(root, "twitchServer",
        settings.twitchServer);
    settings.twitchKey = jsonString(root, "twitchKey", settings.twitchKey);
    settings.youtubeEnabled = jsonBool(root, "youtubeEnabled",
        settings.youtubeEnabled);
    settings.youtubeServer = jsonString(root, "youtubeServer",
        settings.youtubeServer);
    settings.youtubeKey = jsonString(root, "youtubeKey", settings.youtubeKey);
    settings.desktopAudioDevice = jsonString(root, "desktopAudioDevice",
        settings.desktopAudioDevice);
    settings.desktopAudioEnabled = jsonBool(root, "desktopAudioEnabled",
        settings.desktopAudioEnabled);
    settings.microphoneDevice = jsonString(root, "microphoneDevice",
        settings.microphoneDevice);

    settings.liveSourcePreviewEnabled = jsonBool(root,
        "liveSourcePreviewEnabled", settings.liveSourcePreviewEnabled);

    const cachedNames = "deviceDisplayNameCache" in root;
    if (cachedNames !is null && cachedNames.type == JSONType.object)
    {
        foreach (deviceId, value; cachedNames.object)
            if (deviceId.length > 0 && value.type == JSONType.string &&
                value.str.length > 0)
                settings.deviceDisplayNameCache[deviceId] = value.str;
    }

    // Versions through 0.1.9 incorrectly treated desktop audio as another
    // DirectShow capture input. Those saved values are microphone/filter IDs,
    // not Windows render-endpoint IDs, so do not carry them into WASAPI.
    if (!hasJsonKey(root, "desktopAudioBackend"))
    {
        settings.desktopAudioDevice = "";
        settings.desktopAudioEnabled = true;
    }

    // Schema 3 did not distinguish an intentional disable from an
    // unconfigured first run. Prefer useful desktop audio when migrating it,
    // while allowing an explicit schema-4 false value to win even if a stale
    // endpoint ID is also present.
    if (!desktopAudioEnabledWasSaved)
        settings.desktopAudioEnabled = true;
    if (!settings.desktopAudioEnabled)
        settings.desktopAudioDevice = "";

    settings.sourceQuality = qualityFromString(jsonString(root,
        "sourceQuality", qualityToString(settings.sourceQuality)),
        settings.sourceQuality);
    settings.twitchQuality = qualityFromString(jsonString(root,
        "twitchQuality", qualityToString(settings.twitchQuality)),
        settings.twitchQuality);
    settings.youtubeQuality = qualityFromString(jsonString(root,
        "youtubeQuality", qualityToString(settings.youtubeQuality)),
        settings.youtubeQuality);

    // 0.1.2/0.1.3 stored one shared "quality" setting. Migrate it into
    // the new independent model. The shared source remains 1080p, Twitch
    // remains 1080p, and YouTube now defaults to 1440p unless legacy 4K
    // was explicitly selected.
    if (!hasJsonKey(root, "youtubeQuality") && hasJsonKey(root, "quality"))
    {
        const legacy = qualityFromString(jsonString(root, "quality", "1080p"),
            BroadcastQuality.fullHD);
        settings.sourceQuality = BroadcastQuality.fullHD;
        settings.twitchQuality = BroadcastQuality.fullHD;
        settings.youtubeQuality = legacy == BroadcastQuality.fourK ?
            BroadcastQuality.fourK : BroadcastQuality.twoK;
    }

    // Guard against hand-edited values that are syntactically valid JSON but
    // unsupported by the current UI.
    settings.twitchQuality = BroadcastQuality.fullHD;
    if (settings.youtubeQuality != BroadcastQuality.twoK &&
        settings.youtubeQuality != BroadcastQuality.fourK)
        settings.youtubeQuality = BroadcastQuality.twoK;

    return settings;
}

private string settingsToJson(BroadcastSettings settings)
{
    JSONValue root = JSONValue.emptyObject;
    root["schemaVersion"] = settingsSchemaVersion;
    root["twitchEnabled"] = settings.twitchEnabled;
    root["twitchServer"] = settings.twitchServer;
    root["twitchKey"] = settings.twitchKey;
    root["youtubeEnabled"] = settings.youtubeEnabled;
    root["youtubeServer"] = settings.youtubeServer;
    root["youtubeKey"] = settings.youtubeKey;
    root["sourceQuality"] = qualityToString(settings.sourceQuality);
    root["twitchQuality"] = qualityToString(settings.twitchQuality);
    root["youtubeQuality"] = qualityToString(settings.youtubeQuality);
    root["desktopAudioBackend"] = "wasapi-loopback";
    root["desktopAudioEnabled"] = settings.desktopAudioEnabled;
    root["desktopAudioDevice"] = settings.desktopAudioDevice;
    root["microphoneDevice"] = settings.microphoneDevice;
    root["liveSourcePreviewEnabled"] = settings.liveSourcePreviewEnabled;
    if (settings.deviceDisplayNameCache.length > 0)
    {
        JSONValue cache = JSONValue.emptyObject;
        foreach (deviceId, name; settings.deviceDisplayNameCache)
            cache[deviceId] = name;
        root["deviceDisplayNameCache"] = cache;
    }
    return root.toPrettyString() ~ "\n";
}

BroadcastSettings loadSettings(out bool loaded, out string message)
{
    BroadcastSettings settings;
    loaded = false;
    message = "";
    recoverInterruptedSave();

    const path = settingsFilePath();
    if (!exists(path))
    {
        message = "No saved settings yet. They will be written to " ~ path;
        return settings;
    }

    try
    {
        settings = settingsFromJson(readText(path));

        loaded = true;
        message = "Loaded settings from " ~ path;
        if (exists(backupFilePath()))
        {
            try remove(backupFilePath());
            catch (Exception) {}
        }
    }
    catch (Exception error)
    {
        message = "Could not load " ~ path ~ ": " ~ error.msg ~
            " Defaults were used and the file was left untouched.";
    }
    return settings;
}

bool saveSettings(BroadcastSettings settings, out string error)
{
    error = "";
    const path = settingsFilePath();
    const temporary = temporaryFilePath();
    const backup = backupFilePath();

    try
    {
        if (exists(temporary)) remove(temporary);
        write(temporary, settingsToJson(settings));

        if (exists(backup)) remove(backup);
        if (exists(path)) rename(path, backup);

        try rename(temporary, path);
        catch (Exception replaceError)
        {
            if (!exists(path) && exists(backup))
            {
                try rename(backup, path);
                catch (Exception) {}
            }
            throw replaceError;
        }

        if (exists(backup)) remove(backup);
        return true;
    }
    catch (Exception saveError)
    {
        error = saveError.msg;
        return false;
    }
}

unittest
{
    BroadcastSettings source;
    source.twitchEnabled = false;
    source.twitchServer = "rtmps://twitch.example/app";
    source.twitchKey = "twitch-secret";
    source.youtubeEnabled = true;
    source.youtubeServer = "rtmp://a.rtmp.youtube.com/live2";
    source.youtubeKey = "youtube-secret";
    source.sourceQuality = BroadcastQuality.fourK;
    source.twitchQuality = BroadcastQuality.fullHD;
    source.youtubeQuality = BroadcastQuality.fourK;
    source.desktopAudioDevice = "Desktop Loopback";
    source.desktopAudioEnabled = true;
    source.microphoneDevice = "Microphone";

    const encoded = settingsToJson(source);
    const restored = settingsFromJson(encoded);
    assert(restored.twitchEnabled == source.twitchEnabled);
    assert(restored.twitchServer == source.twitchServer);
    assert(restored.twitchKey == source.twitchKey);
    assert(restored.youtubeEnabled == source.youtubeEnabled);
    assert(restored.youtubeServer == source.youtubeServer);
    assert(restored.youtubeKey == source.youtubeKey);
    assert(restored.sourceQuality == source.sourceQuality);
    assert(restored.twitchQuality == source.twitchQuality);
    assert(restored.youtubeQuality == source.youtubeQuality);
    assert(restored.desktopAudioDevice == source.desktopAudioDevice);
    assert(restored.desktopAudioEnabled == source.desktopAudioEnabled);
    assert(restored.microphoneDevice == source.microphoneDevice);
}

unittest
{
    BroadcastSettings defaults;
    assert(defaults.desktopAudioEnabled);
    assert(defaults.youtubeServer == "rtmp://a.rtmp.youtube.com/live2");
    assert(defaults.sourceQuality == BroadcastQuality.fullHD);
    assert(defaults.twitchQuality == BroadcastQuality.fullHD);
    assert(defaults.youtubeQuality == BroadcastQuality.twoK);

    const legacyDefault = settingsFromJson(`{"quality":"1080p"}`);
    assert(legacyDefault.sourceQuality == BroadcastQuality.fullHD);
    assert(legacyDefault.twitchQuality == BroadcastQuality.fullHD);
    assert(legacyDefault.youtubeQuality == BroadcastQuality.twoK);

    const legacyFourK = settingsFromJson(`{"quality":"4k"}`);
    assert(legacyFourK.youtubeQuality == BroadcastQuality.fourK);
}

unittest
{
    const legacyAudio = settingsFromJson(
        `{"desktopAudioDevice":"@device_cm_old_microphone",` ~
        `"microphoneDevice":"@device_cm_real_microphone"}`);
    assert(legacyAudio.desktopAudioDevice.length == 0);
    assert(legacyAudio.microphoneDevice == "@device_cm_real_microphone");

    const currentAudio = settingsFromJson(
        `{"desktopAudioBackend":"wasapi-loopback",` ~
        `"desktopAudioDevice":"{render-endpoint-id}"}`);
    assert(currentAudio.desktopAudioDevice == "{render-endpoint-id}");
    assert(currentAudio.desktopAudioEnabled);

    const previouslyUnconfiguredAudio = settingsFromJson(
        `{"schemaVersion":3,"desktopAudioBackend":"wasapi-loopback",` ~
        `"desktopAudioDevice":""}`);
    assert(previouslyUnconfiguredAudio.desktopAudioEnabled);
    assert(previouslyUnconfiguredAudio.desktopAudioDevice.length == 0);

    const explicitlyDisabledAudio = settingsFromJson(
        `{"schemaVersion":4,"desktopAudioBackend":"wasapi-loopback",` ~
        `"desktopAudioEnabled":false,` ~
        `"desktopAudioDevice":"{ignored-render-endpoint-id}"}`);
    assert(!explicitlyDisabledAudio.desktopAudioEnabled);
    assert(explicitlyDisabledAudio.desktopAudioDevice.length == 0);
}

unittest
{
    // Device-name cache round-trips, and a missing cache loads as empty.
    BroadcastSettings source;
    source.deviceDisplayNameCache["{render-id}"] = "Speakers (USB)";
    source.deviceDisplayNameCache["@device_cm_mic"] = "Microphone (USB Audio)";

    const restored = settingsFromJson(settingsToJson(source));
    assert(restored.deviceDisplayNameCache.length == 2);
    assert(restored.deviceDisplayNameCache["{render-id}"] == "Speakers (USB)");
    assert(restored.deviceDisplayNameCache["@device_cm_mic"] ==
        "Microphone (USB Audio)");

    const withoutCache = settingsFromJson(`{"schemaVersion":5}`);
    assert(withoutCache.deviceDisplayNameCache.length == 0);

    // Invalid cache entries are ignored instead of crashing.
    const badCache = settingsFromJson(
        `{"schemaVersion":5,"deviceDisplayNameCache":{"ok":"Name","bad":7}}`);
    assert(badCache.deviceDisplayNameCache.length == 1);
    assert(badCache.deviceDisplayNameCache["ok"] == "Name");
}

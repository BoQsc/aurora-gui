module aurorastream.settings;

import aurorastream.broadcast : BroadcastQuality, BroadcastSettings;
import aurorastream.browser : BrowserChoice, browserChoiceFromKey,
    browserChoiceKey;
import std.file : exists, getcwd, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : endsWith;

/// Settings file name, shared by both the per-user and portable locations.
enum settingsFileName = "aurora-stream-settings.json";

enum settingsSchemaVersion = 8;

private bool _portableConfigMode;

/** Enable portable settings. By default the settings file lives in the
 * current user's per-user application-data directory; portable mode keeps it
 * beside the folder Aurora Stream is launched from (the historical behavior).
 * The main() entry points turn this on for a `--portable-config` argument. */
void setPortableConfigMode(bool enabled)
{
    _portableConfigMode = enabled;
}

bool portableConfigMode()
{
    return _portableConfigMode;
}

/// Per-user application-data directory used unless portable mode is enabled.
private string userConfigDirectory()
{
    version (Windows)
    {
        const appData = environment.get("APPDATA", "");
        if (appData.length > 0)
            return buildPath(appData, "Aurora Stream");
    }
    else version (OSX)
    {
        const home = environment.get("HOME", "");
        if (home.length > 0)
            return buildPath(home, "Library", "Application Support",
                "Aurora Stream");
    }
    else version (Posix)
    {
        const xdg = environment.get("XDG_CONFIG_HOME", "");
        if (xdg.length > 0)
            return buildPath(xdg, "Aurora Stream");
        const home = environment.get("HOME", "");
        if (home.length > 0)
            return buildPath(home, ".config", "Aurora Stream");
    }
    return "";
}

string settingsFilePath()
{
    if (!_portableConfigMode)
    {
        const directory = userConfigDirectory();
        if (directory.length > 0)
            return buildPath(directory, settingsFileName);
    }
    try return buildPath(getcwd(), settingsFileName);
    catch (Exception) return settingsFileName;
}

/// Create the settings directory on first save (per-user mode).
private void ensureSettingsDirectory(string path)
{
    const directory = dirName(path);
    if (directory.length > 0 && !exists(directory))
        try mkdirRecurse(directory);
        catch (Exception) {}
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

private int jsonInt(const JSONValue root, string key, int fallback)
{
    if (root.type != JSONType.object) return fallback;
    const value = key in root;
    if (value is null || value.type != JSONType.integer) return fallback;
    return cast(int) value.integer;
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

    // Window/game capture: non-empty windowCaptureHwnd means stream only that
    // window so viewers never see the desktop. Schema 6 introduced these keys;
    // older files simply keep the whole-desktop default.
    settings.windowCaptureHwnd = jsonString(root, "windowCaptureHwnd",
        settings.windowCaptureHwnd);
    settings.windowCaptureLabel = jsonString(root, "windowCaptureLabel",
        settings.windowCaptureLabel);
    settings.windowContentCapture = jsonBool(root, "windowContentCapture",
        settings.windowContentCapture);

    settings.liveSourcePreviewEnabled = jsonBool(root,
        "liveSourcePreviewEnabled", settings.liveSourcePreviewEnabled);

    settings.minimizeToTrayOnStart = jsonBool(root, "minimizeToTrayOnStart",
        settings.minimizeToTrayOnStart);
    settings.closeToTray = jsonBool(root, "closeToTray", settings.closeToTray);

    settings.browserChoice = browserChoiceFromKey(jsonString(root,
        "browserChoice", browserChoiceKey(settings.browserChoice)));

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
    settings.youtubeBitrateKbps = jsonInt(root, "youtubeBitrateKbps", 0);

    // 0.1.2/0.1.3 stored one shared "quality" setting. Migrate it into
    // the new independent model. The shared source remains 1080p, Twitch
    // remains 1080p, and YouTube now defaults to 1080p unless legacy 4K
    // was explicitly selected.
    if (!hasJsonKey(root, "youtubeQuality") && hasJsonKey(root, "quality"))
    {
        const legacy = qualityFromString(jsonString(root, "quality", "1080p"),
            BroadcastQuality.fullHD);
        settings.sourceQuality = BroadcastQuality.fullHD;
        settings.twitchQuality = BroadcastQuality.fullHD;
        settings.youtubeQuality = legacy == BroadcastQuality.fourK ?
            BroadcastQuality.fourK : BroadcastQuality.fullHD;
    }

    // Guard against hand-edited values that are syntactically valid JSON but
    // unsupported by the current UI.
    settings.twitchQuality = BroadcastQuality.fullHD;
    if (settings.youtubeQuality != BroadcastQuality.fullHD &&
        settings.youtubeQuality != BroadcastQuality.twoK &&
        settings.youtubeQuality != BroadcastQuality.fourK)
        settings.youtubeQuality = BroadcastQuality.fullHD;

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
    root["youtubeBitrateKbps"] = settings.youtubeBitrateKbps;
    root["desktopAudioBackend"] = "wasapi-loopback";
    root["desktopAudioEnabled"] = settings.desktopAudioEnabled;
    root["desktopAudioDevice"] = settings.desktopAudioDevice;
    root["microphoneDevice"] = settings.microphoneDevice;
    root["windowCaptureHwnd"] = settings.windowCaptureHwnd;
    root["windowCaptureLabel"] = settings.windowCaptureLabel;
    root["windowContentCapture"] = settings.windowContentCapture;
    root["liveSourcePreviewEnabled"] = settings.liveSourcePreviewEnabled;
    root["minimizeToTrayOnStart"] = settings.minimizeToTrayOnStart;
    root["closeToTray"] = settings.closeToTray;
    root["browserChoice"] = browserChoiceKey(settings.browserChoice);
    if (settings.deviceDisplayNameCache.length > 0)
    {
        JSONValue cache = JSONValue.emptyObject;
        foreach (deviceId, name; settings.deviceDisplayNameCache)
            cache[deviceId] = name;
        root["deviceDisplayNameCache"] = cache;
    }
    return root.toPrettyString() ~ "\n";
}

/// One-time move of a settings file left in the current working directory by
/// older portable launches into the per-user location. Only runs in default
/// (per-user) mode and only when the per-user file does not exist yet, so it
/// never overwrites a newer per-user file with an older portable one.
private void migrateLegacySettings()
{
    if (_portableConfigMode) return;

    const target = settingsFilePath();
    if (exists(target)) return;

    string legacy;
    try legacy = buildPath(getcwd(), settingsFileName);
    catch (Exception) return;
    if (legacy == target) return;

    string source;
    if (exists(legacy))
        source = legacy;
    else
    {
        const legacyBackup = legacy ~ ".bak";
        if (exists(legacyBackup)) source = legacyBackup;
    }
    if (source.length == 0) return;

    ensureSettingsDirectory(target);
    try
    {
        const temporary = temporaryFilePath();
        if (exists(temporary)) remove(temporary);
        write(temporary, readText(source));
        try rename(temporary, target);
        catch (Exception) {}
    }
    catch (Exception) {}
}

BroadcastSettings loadSettings(out bool loaded, out string message)
{
    BroadcastSettings settings;
    loaded = false;
    message = "";
    recoverInterruptedSave();
    migrateLegacySettings();

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
        ensureSettingsDirectory(path);
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
    source.youtubeBitrateKbps = 24_000;
    source.desktopAudioDevice = "Desktop Loopback";
    source.desktopAudioEnabled = true;
    source.microphoneDevice = "Microphone";

    const encoded = settingsToJson(source);
    const restored = settingsFromJson(encoded);
    assert(restored.twitchEnabled == source.twitchEnabled);
    assert(restored.twitchServer == source.twitchServer);
    assert(restored.twitchKey == source.twitchKey);
    assert(restored.youtubeBitrateKbps == source.youtubeBitrateKbps);
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
    assert(defaults.youtubeQuality == BroadcastQuality.fullHD);

    const legacyDefault = settingsFromJson(`{"quality":"1080p"}`);
    assert(legacyDefault.sourceQuality == BroadcastQuality.fullHD);
    assert(legacyDefault.twitchQuality == BroadcastQuality.fullHD);
    assert(legacyDefault.youtubeQuality == BroadcastQuality.fullHD);

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
    // Browser choice round-trips, defaults to the OS default handler, and an
    // unknown/absent key falls back instead of crashing.
    BroadcastSettings source;
    source.browserChoice = BrowserChoice.chrome;
    const restored = settingsFromJson(settingsToJson(source));
    assert(restored.browserChoice == BrowserChoice.chrome);

    assert(settingsFromJson(`{"schemaVersion":5}`).browserChoice ==
        BrowserChoice.defaultBrowser);
    assert(settingsFromJson(
        `{"schemaVersion":5,"browserChoice":"edge"}`).browserChoice ==
        BrowserChoice.edge);
    assert(settingsFromJson(
        `{"schemaVersion":5,"browserChoice":"nonsense"}`).browserChoice ==
        BrowserChoice.defaultBrowser);
}

unittest
{
    // Window/game capture fields round-trip; older settings files (no schema-6
    // keys) keep the whole-desktop default.
    BroadcastSettings source;
    source.windowCaptureHwnd = "1841952";
    source.windowCaptureLabel = "notepad.exe — Notes";
    source.desktopAudioEnabled = true;
    source.twitchEnabled = false;
    source.youtubeEnabled = false;

    const restored = settingsFromJson(settingsToJson(source));
    assert(restored.windowCaptureHwnd == "1841952");
    assert(restored.windowCaptureLabel == "notepad.exe — Notes");

    const legacy = settingsFromJson(`{"schemaVersion":5}`);
    assert(legacy.windowCaptureHwnd.length == 0);
    assert(legacy.windowCaptureLabel.length == 0);

    // Schema 7 adds the window-content-capture toggle; older files (and files
    // that omit it) keep the default off so gdigrab behavior is preserved.
    assert(!legacy.windowContentCapture);
    BroadcastSettings contentSource;
    contentSource.windowCaptureHwnd = "1841952";
    contentSource.windowContentCapture = true;
    const contentRestored = settingsFromJson(settingsToJson(contentSource));
    assert(contentRestored.windowContentCapture);
    const contentExplicitOff = settingsFromJson(
        `{"schemaVersion":7,"windowContentCapture":false}`);
    assert(!contentExplicitOff.windowContentCapture);
    const contentExplicitOn = settingsFromJson(
        `{"schemaVersion":7,"windowContentCapture":true}`);
    assert(contentExplicitOn.windowContentCapture);
}

unittest
{
    // The persisted handle survives a round-trip even when the label is empty.
    BroadcastSettings source;
    source.windowCaptureHwnd = "464340";
    const restored = settingsFromJson(settingsToJson(source));
    assert(restored.windowCaptureHwnd == "464340");
}

unittest
{
    // Schema 8 tray preferences round-trip. Minimize-to-tray is OFF by default
    // for fresh installs / files that never saved the key (auto-hiding while
    // streaming is confusing in practice), while close-to-tray is ON by
    // default; an explicitly saved value is respected.
    BroadcastSettings source;
    source.minimizeToTrayOnStart = true;
    source.closeToTray = true;
    const restored = settingsFromJson(settingsToJson(source));
    assert(restored.minimizeToTrayOnStart);
    assert(restored.closeToTray);

    const defaults = settingsFromJson(`{"schemaVersion":7}`);
    assert(!defaults.minimizeToTrayOnStart);
    assert(defaults.closeToTray);

    const explicitOn = settingsFromJson(
        `{"schemaVersion":8,"minimizeToTrayOnStart":true}`);
    assert(explicitOn.minimizeToTrayOnStart);
    // closeToTray was not specified, so it keeps the enabled default.
    assert(explicitOn.closeToTray);

    // A user who explicitly disabled the option keeps it disabled.
    const explicitOff = settingsFromJson(
        `{"schemaVersion":8,"closeToTray":false,"minimizeToTrayOnStart":false}`);
    assert(!explicitOff.minimizeToTrayOnStart);
    assert(!explicitOff.closeToTray);
}

unittest
{
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

unittest
{
    // Default (per-user) mode resolves into a directory, never a bare file;
    // portable mode falls back to the launch folder. The two paths must
    // never collide with each other's backup/temporary names.
    const previous = portableConfigMode();
    scope (exit) setPortableConfigMode(previous);

    setPortableConfigMode(false);
    const perUser = settingsFilePath();
    assert(perUser.length > 0);
    assert(perUser.endsWith(settingsFileName));
    assert(dirName(perUser).length > 0);
    assert(!perUser.endsWith(".json.bak"));

    setPortableConfigMode(true);
    const portable = settingsFilePath();
    assert(portable.length > 0);
    assert(portable.endsWith(settingsFileName));

    // Portable mode must never equal the per-user location (they use the
    // same file name, so a wrong mode would silently read the wrong file).
    assert(portable != perUser);
}


module auroraopencode.core;

import aurora;
import auroraopencode.logging : logError;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : strip;

// ---------------------------------------------------------------------------
// Shared defaults for the OpenAI-compatible opencode API mirror.
// ---------------------------------------------------------------------------

private immutable string defaultBaseUrl = "https://opencode.ai/zen/go/v1";

/// Legacy demo-proxy host the app used to point at; migrated away so stale
/// saved settings cannot pin the client to the unreachable demo host.
private immutable string legacyDemoBaseUrl = "https://opencode-api.boqsc.eu";
public immutable string defaultModel = "deepseek-v4-flash";

public immutable string[] defaultModels = [
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "gpt-5.6-luna",
    "qwen3.8-max",
    "glm-5.2",
    "grok-4.5",
    "kimi-k3",
    "minimax-m3",
    "mimo-v2.5-pro",
    "hy3"
];

private immutable string[] defaultKeyFileCandidates = [
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode-api/data/key.txt",
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode/data/arena/key.txt"
];

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

public immutable Color opencodeBackground = Color.fromHex(0x111114);
public immutable Color opencodePanel = Color.fromHex(0x16161b);
public immutable Color opencodeElevated = Color.fromHex(0x1c1c23);
public immutable Color opencodeField = Color.fromHex(0x202028);
public immutable Color opencodeBorder = Color.fromHex(0x33333d);
public immutable Color opencodeText = Color.fromHex(0xe8e8ec);
public immutable Color opencodeMuted = Color.fromHex(0x9a9aa5);
public immutable Color opencodeAccent = Color.fromHex(0x8b7cf6);
public immutable Color opencodeSelection = Color.fromHex(0x2b2b36);
public immutable Color opencodePressed = Color.fromHex(0x2f2f3b);
public immutable Color opencodeUserBubble = Color.fromHex(0x2a2f45);
public immutable Color opencodeAssistantBubble = Color.fromHex(0x1f1f27);
public immutable Color opencodeThinkingText = Color.fromHex(0x8d8d99);
public immutable Color opencodeErrorRed = Color.fromHex(0xff6b6b);
public immutable Color opencodeKeyOk = Color.fromHex(0x6fd08c);
public immutable Color opencodeKeyMissing = Color.fromHex(0xffa94d);

public Theme opencodeTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = opencodeBackground;
    theme.panelBackground = opencodePanel;
    theme.panelElevated = opencodeElevated;
    theme.text = opencodeText;
    theme.textMuted = opencodeMuted;
    theme.border = opencodeBorder;
    theme.accent = opencodeAccent;
    theme.selection = opencodeSelection;
    theme.selectionText = opencodeText;
    theme.fieldBackground = opencodeField;
    theme.buttonBackground = opencodeField;
    theme.buttonHover = opencodeSelection;
    theme.buttonPressed = opencodePressed;
    theme.cornerRadius = 8;
    theme.controlHeight = 38;
    return theme;
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

public struct ChatMessage
{
    string role;       // "user" | "assistant"
    string content;
    string reasoning;
    string time;       // "HH:MM" local wall-clock, empty when unknown
    bool failed;       // assistant reply that ended in an error
}

public struct ChatSession
{
    string title;
    string model;
    bool thinking;
    ChatMessage[] messages;
}

public struct Settings
{
    string baseUrl = defaultBaseUrl;
    string apiKey = "";
    string model = defaultModel;
    bool thinking;
}

// ---------------------------------------------------------------------------
// State directory and settings persistence
// ---------------------------------------------------------------------------

private __gshared string stateDirectoryOverride;

/// Test-only: redirect persistence to an isolated directory.
public void setOpencodeStateDirectoryForTesting(string path)
{
    stateDirectoryOverride = path;
}

public string opencodeStateDirectory()
{
    if (stateDirectoryOverride.length > 0) return stateDirectoryOverride;
    const appData = environment.get("APPDATA");
    const base = appData.length > 0 ? appData : ".";
    return buildPath(base, "Aurora OpenCode");
}

public void ensureStateDirectory()
{
    const directory = opencodeStateDirectory();
    if (!exists(directory)) mkdirRecurse(directory);
}

private string readDefaultKeyFile()
{
    // Primary: the real opencode CLI auth store
    // (~/.local/share/opencode/auth.json) which holds the Go-plan and
    // DeepSeek API keys.
    const profile = environment.get("USERPROFILE");
    if (profile.length > 0)
    {
        const authPath = buildPath(profile, ".local", "share", "opencode",
            "auth.json");
        try
        {
            if (exists(authPath))
            {
                auto value = parseJSON(readText(authPath));
                if (value.type == JSONType.object)
                {
                    foreach (provider; ["opencode-go", "deepseek"])
                    {
                        if (auto found = provider in value.object)
                        {
                            if (found.type == JSONType.object)
                            {
                                if (auto key = "key" in found.object)
                                    if (key.type == JSONType.string &&
                                        key.str.length > 0)
                                        return key.str;
                            }
                        }
                    }
                }
            }
        }
        catch (Exception error)
        {
            logError("failed to read opencode auth: " ~ error.msg);
        }
    }
    // Fallback: legacy key files from the web server setup.
    foreach (candidate; defaultKeyFileCandidates)
    {
        try
        {
            if (!exists(candidate)) continue;
            const value = readText(candidate).strip();
            if (value.length > 0) return value;
        }
        catch (Exception) {}
    }
    return "";
}

public Settings loadSettings()
{
    Settings settings;
    const path = buildPath(opencodeStateDirectory(), "settings.json");
    if (exists(path))
    {
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type == JSONType.object)
            {
                if (auto found = "baseUrl" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.baseUrl = found.str;
                if (auto found = "apiKey" in value.object)
                    if (found.type == JSONType.string)
                        settings.apiKey = found.str;
                if (auto found = "model" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.model = found.str;
                if (auto found = "thinking" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.thinking = found.type == JSONType.true_;
            }
        }
        catch (Exception error)
        {
            logError("failed to load settings: " ~ error.msg);
        }
    }
    if (settings.apiKey.length == 0)
        settings.apiKey = environment.get("OPENCODE_API_KEY");
    if (settings.apiKey.length == 0)
        settings.apiKey = readDefaultKeyFile();
    if (settings.model.length == 0) settings.model = defaultModel;
    if (settings.baseUrl.length >= legacyDemoBaseUrl.length &&
        settings.baseUrl[0 .. legacyDemoBaseUrl.length] == legacyDemoBaseUrl)
        settings.baseUrl = defaultBaseUrl;
    return settings;
}

public void saveSettings(const ref Settings settings)
{
    ensureStateDirectory();
    JSONValue root;
    root["baseUrl"] = settings.baseUrl;
    root["apiKey"] = settings.apiKey;
    root["model"] = settings.model;
    root["thinking"] = settings.thinking;
    try write(buildPath(opencodeStateDirectory(), "settings.json"),
        root.toString());
    catch (Exception error)
    {
        logError("failed to save settings: " ~ error.msg);
    }
}

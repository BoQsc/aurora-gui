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

/// Fallback context window (tokens) used when a model is not in the catalog.
private immutable int defaultContextLimit = 128_000;

/**
 * Context window (tokens) for a model.
 *
 * The real opencode reads `model.limit.context` from provider metadata and
 * meters context as `tokens.used / limit.context`. The values below mirror the
 * official opencode model catalog (`https://models.opencode.ai/api.json`, the
 * source the opencode CLI itself fetches) for the models the mirror serves.
 * The fallback is a conservative estimate for unknown models.
 */
public int contextLimitForModel(string model)
{
    switch (model)
    {
        case "deepseek-v4-flash":  return 1_000_000;
        case "deepseek-v4-pro":    return 1_000_000;
        case "gpt-5.6-luna":       return 1_050_000;
        case "qwen3.8-max":        return 1_000_000;
        case "glm-5.2":            return 1_000_000;
        case "grok-4.5":           return 500_000;
        case "kimi-k3":            return 1_048_576;
        case "minimax-m3":         return 512_000;
        case "mimo-v2.5-pro":      return 1_048_576;
        case "hy3":                return 256_000;
        default:                   return defaultContextLimit;
    }
}

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

/// A single function call the model requested while streaming a reply. This
/// mirrors the OpenAI `tool_calls` delta: the id links the result back, and
/// `arguments` is the raw JSON object string the model produced.
public struct OpenCodeToolCall
{
    string id;
    string name;
    string arguments;
}

/// A tool definition advertised to the model in the `tools` request field.
/// `parametersJson` is a JSON Schema object string (e.g. `{"type":"object",...}`).
public struct OpenCodeToolDef
{
    string name;
    string description;
    string parametersJson;
}

/// One message sent in a chat request. Richer than the parallel role/content
/// arrays: assistant messages may carry `toolCalls`, and `tool` role messages
/// carry the `toolCallId` they answer to.
public struct ChatRequestMessage
{
    string role;              // "user" | "assistant" | "tool"
    string content;
    string toolCallId;        // role == "tool"
    OpenCodeToolCall[] toolCalls; // role == "assistant"
}

public struct ChatMessage
{
    string role;       // "user" | "assistant" | "tool"
    string content;
    string reasoning;
    string time;       // "HH:MM" local wall-clock, empty when unknown
    bool failed;       // assistant reply that ended in an error
    int promptTokens;  // usage the API reported for the reply (0 = unknown)
    int completionTokens;
    int totalTokens;
    OpenCodeToolCall[] toolCalls; // assistant replies that invoked tools
    string toolCallId;  // "tool" role results, links back to an assistant call
    string toolName;    // "tool" role results: which tool produced the output
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
    bool toolsEnabled;  // advertise tool definitions to the model
    string workspace;   // working directory the tools run in
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
                if (auto found = "toolsEnabled" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.toolsEnabled = found.type == JSONType.true_;
                if (auto found = "workspace" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.workspace = found.str;
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
    root["toolsEnabled"] = settings.toolsEnabled;
    root["workspace"] = settings.workspace;
    try write(buildPath(opencodeStateDirectory(), "settings.json"),
        root.toString());
    catch (Exception error)
    {
        logError("failed to save settings: " ~ error.msg);
    }
}

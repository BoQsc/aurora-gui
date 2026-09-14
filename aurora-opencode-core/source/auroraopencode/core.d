module auroraopencode.core;

import aurora;
import auroraopencode.logging : logError;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : strip, toLower;

// ---------------------------------------------------------------------------
// Shared defaults for the OpenAI-compatible opencode API mirror.
// ---------------------------------------------------------------------------

private immutable string defaultBaseUrl = "https://api.commandcode.ai/provider/v1";

/// Legacy hosts the app used to point at; migrated away so stale saved
/// settings cannot pin the client to an unreachable or retired provider.
private immutable string[] legacyBaseUrls = [
    "https://opencode-api.boqsc.eu",
    "https://opencode.ai/zen/go/v1"
];
public immutable string defaultModel = "deepseek/deepseek-v4.1-flash";

public immutable string[] defaultModels = [
    "deepseek/deepseek-v4.1-flash",
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-pro",
    "claude-sonnet-5",
    "claude-opus-5",
    "gpt-5.6-luna",
    "gpt-5.5",
    "zai-org/GLM-5.3",
    "Qwen/Qwen3.8-Max",
    "moonshotai/Kimi-K3",
    "MiniMaxAI/MiniMax-M3",
    "xai/grok-4.6",
    "google/gemini-3.8-flash",
    "tencent/hy3-paid"
];

/// True for the conventional local OpenAI-compatible endpoints used by
/// llama-server and similar desktop runtimes. Local servers normally do not
/// require an API key and commonly use plain HTTP.
public bool isLoopbackApiBaseUrl(string value)
{
    value = value.strip().toLower();
    foreach (prefix; ["http://localhost", "http://127.0.0.1",
        "http://[::1]", "https://localhost", "https://127.0.0.1",
        "https://[::1]"])
    {
        if (value.length < prefix.length || value[0 .. prefix.length] != prefix)
            continue;
        if (value.length == prefix.length || value[prefix.length] == ':' ||
            value[prefix.length] == '/')
            return true;
    }
    return false;
}

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
 * `context_length` the CommandCode provider reports from
 * `https://api.commandcode.ai/provider/v1/models` for every model it serves.
 * The legacy (unprefixed) ids are kept so a settings file written before the
 * CommandCode switch still meters correctly. The fallback is a conservative
 * estimate for unknown models.
 */
public int contextLimitForModel(string model)
{
    switch (model)
    {
        // CommandCode provider catalog (context_length from /models).
        case "deepseek/deepseek-v4.1-flash":       return 1_000_000;
        case "deepseek/deepseek-v4-flash":         return 1_000_000;
        case "deepseek/deepseek-v4-flash-fast":    return 1_000_000;
        case "deepseek/deepseek-v4-flash-vision-exp": return 1_000_000;
        case "deepseek/deepseek-v4-pro":           return 1_000_000;
        case "claude-sonnet-5":                    return 1_000_000;
        case "claude-sonnet-4-6":                  return 1_000_000;
        case "claude-fable-5-1":                   return 1_000_000;
        case "claude-fable-5":                     return 1_000_000;
        case "claude-opus-5":                      return 1_000_000;
        case "claude-opus-4-8":                    return 1_000_000;
        case "claude-opus-4-7":                    return 1_000_000;
        case "claude-haiku-4-5-20251001":          return 200_000;
        case "gpt-5.6-sol":                        return 1_050_000;
        case "gpt-5.6-terra":                      return 1_050_000;
        case "gpt-5.6-luna":                       return 1_050_000;
        case "gpt-5.5":                            return 400_000;
        case "gpt-5.4":                            return 400_000;
        case "gpt-5.4-mini":                       return 400_000;
        case "gpt-5.3-codex":                      return 400_000;
        case "moonshotai/Kimi-K3":                 return 1_000_000;
        case "moonshotai/Kimi-K2.7-Code":          return 256_000;
        case "moonshotai/Kimi-K2.7-Code-Highspeed": return 262_000;
        case "moonshotai/Kimi-K2.6":               return 256_000;
        case "moonshotai/Kimi-K2.5":               return 256_000;
        case "zai-org/GLM-5.3":                    return 1_000_000;
        case "zai-org/GLM-5.2":                    return 1_000_000;
        case "zai-org/GLM-5.2-Fast":               return 1_000_000;
        case "zai-org/GLM-5.1":                    return 200_000;
        case "zai-org/GLM-5":                      return 200_000;
        case "z-ai/glm-5.3-flash":                 return 1_048_576;
        case "MiniMaxAI/MiniMax-M3":               return 1_000_000;
        case "MiniMaxAI/MiniMax-M2.7":             return 200_000;
        case "MiniMaxAI/MiniMax-M2.5":             return 200_000;
        case "xiaomi/mimo-v2.5-pro":               return 1_000_000;
        case "xiaomi/mimo-v2.5":                   return 1_000_000;
        case "Qwen/Qwen3.8-Max-0902":              return 1_000_000;
        case "Qwen/Qwen3.8-Max":                   return 1_000_000;
        case "Qwen/Qwen3.8-Flash":                 return 1_000_000;
        case "Qwen/Qwen3.8-27B":                   return 262_144;
        case "Qwen/Qwen3.7-Max":                   return 1_000_000;
        case "Qwen/Qwen3.7-Plus":                  return 1_000_000;
        case "Qwen/Qwen3.7-Flash":                 return 1_000_000;
        case "Qwen/Qwen3.6-Max-Preview":           return 200_000;
        case "Qwen/Qwen3.6-Plus":                  return 200_000;
        case "meituan/LongCat-2.0:free":           return 1_048_576;
        case "stepfun/Step-3.7-Flash":             return 256_000;
        case "stepfun/Step-3.5-Flash":             return 1_000_000;
        case "tencent/hy3-paid":                   return 262_144;
        case "tencent/hy4-preview":                return 1_048_576;
        case "google/gemini-3.8-flash":            return 1_000_000;
        case "google/gemini-3.7-flash":            return 1_048_576;
        case "google/gemini-3.6-flash":            return 1_000_000;
        case "google/gemini-3.5-flash":            return 1_000_000;
        case "google/gemini-3.5-flash-lite":       return 1_000_000;
        case "google/gemini-3.1-flash-lite":       return 1_000_000;
        case "sakana/fugu-ultra":                  return 1_000_000;
        case "nvidia/nemotron-3-ultra-550b-a55b":  return 1_000_000;
        case "thinkingmachines/inkling":           return 256_000;
        case "thinkingmachines/inkling-small":     return 1_000_000;
        case "poolside/laguna-s-2.1-free":         return 256_000;
        case "inclusionai/ling-3.0-flash-sante:free": return 262_144;
        case "meta/muse-spark-1.1":                return 1_048_576;
        case "meta/muse-spark-1.2":                return 1_048_576;
        case "meta/muse-spark-1.2-contributor":    return 1_048_576;
        case "meta/muse-spark-1.3":                return 1_048_576;
        case "meta/muse-spark-1.3-contributor":    return 1_048_576;
        case "xai/grok-4.6":                       return 500_000;
        case "xai/grok-4.5":                       return 500_000;
        // Legacy opencode.ai ids (pre-CommandCode settings files).
        case "deepseek-v4-flash":  return 1_000_000;
        case "deepseek-v4-pro":    return 1_000_000;
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
// Diff rendering: `+N`/added lines use the green, `-M`/removed lines the red,
// with a faint row tint behind each so changes are scannable at a glance.
public immutable Color opencodeDiffAdd = Color.fromHex(0x6fd08c);
public immutable Color opencodeDiffDelete = Color.fromHex(0xff6b6b);
public immutable Color opencodeDiffAddBg = Color.fromHex(0x16281e);
public immutable Color opencodeDiffDeleteBg = Color.fromHex(0x2c1a1d);
public immutable Color opencodeDiffGutter = Color.fromHex(0x5c5c68);

// ---------------------------------------------------------------------------
// Typography and control metrics
// ---------------------------------------------------------------------------
// Matched to the upstream opencode UI (packages/ui/src/styles/theme.css):
// small 13 px, base 14 px, title/large 16 px, display 20 px, on a 4 px grid.
// Aurora's vendored tiers are 13/17/22/30, so the app pins explicit pixel
// sizes wherever the tier alone would render noticeably too large.

/// Small UI text: menus, buttons, captions and the status line.
public enum int opencodeFontSmall = 13;
/// Body text: chat messages, session titles and inputs.
public enum int opencodeFontBase = 14;
/// Section and dialog titles.
public enum int opencodeFontTitle = 16;
/// Largest in-app text.
public enum int opencodeFontDisplay = 20;
/// Height of buttons, inputs and toolbar controls.
public enum int opencodeControlHeight = 28;
/// Height of a single session list row.
public enum int opencodeSessionRowHeight = 32;
/// Height of the merged titlebar/toolbar band.
public enum int opencodeTitleBarHeight = 40;
/// Maximum width of the centered conversation/composer column. Wider than the
/// upstream opencode `--container-3xl` token (48rem = 768 px): the message list
/// and the prompt read as one centered column, but a little more room is given
/// so long lines and tool output fit before stretching edge to edge on a wide
/// window.
public enum int opencodeContentMaxWidth = 1024;
/// Height of the chat composer panel: roughly twice the old single-row input,
/// leaving room for a multi-line prompt with the send button pinned below.
public enum int opencodeComposerHeight = 116;

/// Opt this process into Aurora's crisper text rendering. The bundled TrueType
/// bytecode interpreter is experimental and not conformance-tested: its
/// `natural` grid mode rewrites real glyph outlines incorrectly (observed on
/// Consolas at 17px: `X`/`x` lose a whole stroke, `1`/`I` lose their serifs),
/// and its default interpreter is order-dependent, so hinting is deliberately
/// left OFF. What we do pin is the atlas coverage contrast curve DirectWrite
/// applies to antialiased coverage before compositing, which keeps small text
/// from reading thin and washed out without touching glyph geometry. Must be
/// called before the first window or font is created. An explicit
/// `AURORA_HINTING`/`AURORA_TEXT_CONTRAST` value in the environment wins.
public void enableNativeTextRendering()
{
    if (environment.get("AURORA_TEXT_CONTRAST", "") == "")
        environment["AURORA_TEXT_CONTRAST"] = "0.5";
}

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
    theme.controlHeight = opencodeControlHeight;
    theme.fontScale = cast(int) TextScale.caption;
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
    string toolArgs;    // "tool" role results: the command's arguments (JSON)
    int diffAdditions;  // file-mutating tools: added line count (+N)
    int diffDeletions;  // file-mutating tools: removed line count (-M)
    string toolDiff;    // file-mutating tools: unified diff for the expanded view
    // Message graph: every message names its parent, so an edited prompt or a
    // regenerated reply can be kept alongside the run it replaced (a sibling
    // branch) instead of being discarded. `id` is unique within a session and
    // `parentId` is empty only for a root message.
    string id;
    string parentId;
    // Synthetic control turn (e.g. "you reached the tool-round limit, stop and
    // answer"). It is still sent to the model as a user message, but it is an
    // app instruction rather than the user's own words, so the transcript hides
    // it instead of rendering it as a fake user bubble.
    bool internal;
}

public struct ChatSession
{
    string title;
    string model;
    bool thinking;
    string projectId;  // owning project; empty/unknown maps to the sandbox
    ChatMessage[] messages;
    // The id of the message at the tip of the branch currently shown. The
    // visible conversation is the path from this leaf up through `parentId`s;
    // messages that belong to abandoned branches stay in `messages` untouched
    // so the user can switch back and continue from them.
    string activeLeafId;
}

// ---------------------------------------------------------------------------
// Message graph (branching / edit-run history)
// ---------------------------------------------------------------------------

private __gshared size_t messageIdCounter;

/// A process-unique message id. The wall-clock tick makes collisions across
/// restarts impossible; the counter separates messages created in one tick.
public string newMessageId()
{
    return "m" ~ to!string(Clock.currTime.stdTime) ~ "-" ~
        to!string(messageIdCounter++);
}

/**
 * Repair a session's message graph after loading it from disk (or after a
 * legacy file written before branching existed).
 *
 * Every message gets an id if it is missing, and each message that has no
 * parent is linked to the message before it so an old linear transcript stays
 * a single chain. The active leaf defaults to the last message. Existing ids
 * and parent links (from a branching save) are preserved.
 */
public void ensureMessageGraph(ref ChatSession session)
{
    // A transcript with no ids at all predates branching: rebuild it as a
    // single chain. Once any id exists the session carries real graph info, so
    // an empty parentId is a deliberate root (e.g. the first prompt of a new
    // branch) and must be preserved.
    bool hasGraph;
    foreach (message; session.messages)
        if (message.id.length > 0)
        {
            hasGraph = true;
            break;
        }
    bool[string] seen;
    string previousId;
    foreach (ref message; session.messages)
    {
        const hadId = message.id.length > 0 && (message.id in seen) is null;
        if (!hadId) message.id = newMessageId();
        seen[message.id] = true;
        if (!hasGraph)
        {
            // Legacy linear transcript: chain each message to its predecessor.
            message.parentId = previousId;
        }
        else if (!hadId && message.parentId.length == 0)
        {
            // A message appended without graph info continues the chain.
            message.parentId = previousId;
        }
        else if (message.parentId.length > 0 &&
            (message.parentId in seen) is null)
        {
            // Dangling parent link (corrupt file): reattach to the chain.
            message.parentId = previousId;
        }
        previousId = message.id;
    }
    if (session.activeLeafId.length == 0 ||
        (session.activeLeafId in seen) is null)
    {
        session.activeLeafId = session.messages.length > 0
            ? session.messages[$ - 1].id : "";
    }
}

/**
 * The indices (into `session.messages`) of the visible conversation, ordered
 * root-first. Walks `parentId` links back from the active leaf, so a branch
 * switch only changes which leaf is active — `messages` is never rearranged
 * and abandoned runs stay addressable.
 */
public size_t[] activeMessagePath(const ref ChatSession session)
{
    size_t[] path;
    if (session.messages.length == 0) return path;
    size_t[string] indexById;
    foreach (index, message; session.messages)
        if (message.id.length > 0)
            indexById[message.id] = index;
    string id = session.activeLeafId;
    const fallback = session.messages[$ - 1].id;
    if (id.length == 0 || (id in indexById) is null)
        id = fallback;
    size_t guard = session.messages.length + 1;
    while (id.length > 0 && guard-- > 0)
    {
        auto found = id in indexById;
        if (found is null) break;
        const index = *found;
        path ~= index;
        id = session.messages[index].parentId;
    }
    size_t[] reversed;
    reversed.length = path.length;
    foreach (i, value; path)
        reversed[path.length - 1 - i] = value;
    return reversed;
}

/// The index of the deepest message reachable from `startIndex` (following
/// parent links forward). When a message has several children (branches), the
/// last-appended one is chosen, matching the order the user saw them created.
public size_t deepestDescendant(const ref ChatSession session, size_t startIndex)
{
    if (startIndex >= session.messages.length) return startIndex;
    size_t current = startIndex;
    size_t guard = session.messages.length + 1;
    while (guard-- > 0)
    {
        const id = session.messages[current].id;
        if (id.length == 0) break;
        size_t child = size_t.max;
        foreach (index, message; session.messages)
        {
            if (index <= current) continue;
            if (message.parentId.length > 0 && message.parentId == id)
                child = index;
        }
        if (child == size_t.max) break;
        current = child;
    }
    return current;
}

/// Indices of every message that is a sibling of `messageIndex` (same parent,
/// same role), in array order. Used to offer `< n/m >` version navigation.
public size_t[] siblingMessages(const ref ChatSession session,
    size_t messageIndex)
{
    size_t[] siblings;
    if (messageIndex >= session.messages.length) return siblings;
    const parent = session.messages[messageIndex].parentId;
    const role = session.messages[messageIndex].role;
    foreach (index, message; session.messages)
        if (message.parentId == parent && message.role == role)
            siblings ~= index;
    return siblings;
}

/// A workspace a conversation belongs to. The sandbox project is always
/// present, always first, and is the default for quick chats.
public struct Project
{
    string id;
    string name;
    string path;
}

/// Persisted project list plus the small bits of UI state that belong with it.
public struct ProjectState
{
    Project[] projects;
    string activeId;
    // Sessions-column share of the sessions/chat split. Default is the tuned
    // value the app ships with (a compact conversation list, ~207 px at the
    // default 1200 px window).
    double sessionsRatio = 0.18;
    // The project rail starts as a narrow strip of icon tiles; the user can
    // expand it to show the project names and the New project button.
    bool projectsCollapsed = true;
}

public struct Settings
{
    string baseUrl = defaultBaseUrl;
    string apiKey = "";
    string model = defaultModel;
    bool thinking;
    bool toolsEnabled = true;  // native D tools (run/read/write/remove/glob/grep/dshell); main, on by default
    bool legacyTools;          // additionally expose the bash/cmd/powershell shell tool; off by default
    string workspace;          // working directory the tools run in
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
                    foreach (provider; ["commandcode", "opencode-go", "deepseek"])
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
    bool apiKeyWasConfigured;
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
                    {
                        settings.apiKey = found.str;
                        // An explicitly blank key is meaningful for a local
                        // llama-server. Do not silently replace it with the
                        // user's unrelated CommandCode credential on restart.
                        apiKeyWasConfigured = true;
                    }
                if (auto found = "model" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.model = found.str;
                if (auto found = "thinking" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.thinking = found.type == JSONType.true_;
                if (auto found = "toolsEnabled" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.toolsEnabled = found.type == JSONType.true_;
                if (auto found = "legacyTools" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.legacyTools = found.type == JSONType.true_;
                // Migration: the old "nativeTools" flag was a separate native-only
                // mode. Native tools are now the default, so a user who had them
                // ON wants no legacy shell; someone who had them OFF (shell mode)
                // keeps the legacy shell tool.
                if (auto found = "nativeTools" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.legacyTools = found.type != JSONType.true_;
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
    const allowBlankLocalKey = apiKeyWasConfigured &&
        isLoopbackApiBaseUrl(settings.baseUrl);
    if (!allowBlankLocalKey && settings.apiKey.length == 0)
        settings.apiKey = environment.get("OPENCODE_API_KEY");
    if (!allowBlankLocalKey && settings.apiKey.length == 0)
        settings.apiKey = readDefaultKeyFile();
    if (settings.model.length == 0) settings.model = defaultModel;
    foreach (legacy; legacyBaseUrls)
    {
        if (settings.baseUrl.length < legacy.length) continue;
        if (settings.baseUrl[0 .. legacy.length] != legacy) continue;
        settings.baseUrl = defaultBaseUrl;
        // A key saved for the old host cannot authenticate the new provider.
        settings.apiKey = readDefaultKeyFile();
        break;
    }
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
    root["legacyTools"] = settings.legacyTools;
    root["workspace"] = settings.workspace;
    try write(buildPath(opencodeStateDirectory(), "settings.json"),
        root.toString());
    catch (Exception error)
    {
        logError("failed to save settings: " ~ error.msg);
    }
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

public immutable string sandboxProjectId = "sandbox";
public immutable string sandboxProjectName = "Sandbox";

/// The standard sandbox folder: a dedicated directory under the app's state
/// directory so a brand-new install always has a safe place to chat and run
/// tools without touching any real project.
public string sandboxProjectPath()
{
    return buildPath(opencodeStateDirectory(), "sandbox");
}

public Project makeSandboxProject()
{
    Project project;
    project.id = sandboxProjectId;
    project.name = sandboxProjectName;
    project.path = sandboxProjectPath();
    return project;
}

/// A unique id for a user-added project. The monotonic tick makes collisions
/// impossible across restarts; the counter separates adds in one tick.
public string newProjectId()
{
    static size_t counter;
    return "p" ~ to!string(Clock.currTime.stdTime) ~ "-" ~ to!string(counter++);
}

private string projectsStorePath()
{
    return buildPath(opencodeStateDirectory(), "projects.json");
}

/// Load the project list. The sandbox project is guaranteed to exist and to be
/// first, and the active id is repaired to a real project if it is stale.
public ProjectState loadProjects()
{
    ProjectState state;
    bool sandboxSeen;
    const path = projectsStorePath();
    if (exists(path))
    {
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type == JSONType.object)
            {
                if (auto found = "projects" in value.object)
                {
                    if (found.type == JSONType.array)
                    {
                        foreach (projectValue; found.array)
                        {
                            if (projectValue.type != JSONType.object) continue;
                            Project project;
                            if (auto f = "id" in projectValue.object)
                                project.id = f.str;
                            if (auto f = "name" in projectValue.object)
                                project.name = f.str;
                            if (auto f = "path" in projectValue.object)
                                project.path = f.str;
                            if (project.id.length == 0) continue;
                            if (project.id == sandboxProjectId)
                            {
                                sandboxSeen = true;
                                project.name = sandboxProjectName;
                                if (project.path.length == 0)
                                    project.path = sandboxProjectPath();
                            }
                            else if (project.name.length == 0)
                                project.name = project.id;
                            state.projects ~= project;
                        }
                    }
                }
                if (auto found = "active" in value.object)
                    if (found.type == JSONType.string)
                        state.activeId = found.str;
                if (auto found = "sessionsRatio" in value.object)
                {
                    double ratio = state.sessionsRatio;
                    if (found.type == JSONType.float_) ratio = found.floating;
                    else if (found.type == JSONType.integer)
                        ratio = cast(double) found.integer;
                    if (ratio > 0.05 && ratio < 0.95) state.sessionsRatio = ratio;
                }
                if (auto found = "projectsCollapsed" in value.object)
                    if (found.type == JSONType.true_ ||
                        found.type == JSONType.false_)
                        state.projectsCollapsed = found.type == JSONType.true_;
            }
        }
        catch (Exception error)
        {
            logError("failed to load projects: " ~ error.msg);
        }
    }
    if (!sandboxSeen)
        state.projects = makeSandboxProject() ~ state.projects;
    bool activeFound;
    foreach (project; state.projects)
        if (project.id == state.activeId) activeFound = true;
    if (!activeFound)
        state.activeId = state.projects.length > 0
            ? state.projects[0].id : sandboxProjectId;
    return state;
}

public void saveProjects(const ref ProjectState state)
{
    ensureStateDirectory();
    JSONValue root;
    JSONValue list = JSONValue(string[].init);
    foreach (project; state.projects)
    {
        JSONValue item;
        item["id"] = project.id;
        item["name"] = project.name;
        item["path"] = project.path;
        list.array ~= item;
    }
    root["projects"] = list;
    root["active"] = state.activeId;
    root["sessionsRatio"] = state.sessionsRatio;
    root["projectsCollapsed"] = state.projectsCollapsed;
    try write(projectsStorePath(), root.toString());
    catch (Exception error)
    {
        logError("failed to save projects: " ~ error.msg);
    }
}

public void ensureProjectDirectory(const ref Project project)
{
    if (project.path.length == 0) return;
    try
    {
        if (!exists(project.path)) mkdirRecurse(project.path);
    }
    catch (Exception error)
    {
        logError("failed to create project directory: " ~ error.msg);
    }
}

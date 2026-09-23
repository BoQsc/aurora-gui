module auroraopencode.core;

import aurora;
import auroraopencode.logging : logError;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : indexOf, startsWith, strip, toLower;

// ---------------------------------------------------------------------------
// Shared defaults for the OpenAI-compatible opencode API mirror.
// ---------------------------------------------------------------------------

/// The real OpenCode gateway (OpenCode Zen / "Go" plan): the endpoint the
/// opencode CLI itself talks to. The CLI auth store names this provider
/// `opencode-go` and authenticates it with an `sk-...` key. This is the
/// default provider.
///
/// NOTES for this endpoint (verified live 2026-09-18, opencode.ai/docs/go):
///   * every request must carry a stable `x-opencode-session` header or it is
///     rejected with `MissingSessionID`;
///   * it asks clients to identify with their own product user agent;
///   * some catalog models are served over Anthropic `/messages` or OpenAI
///     `/responses`, not `/chat/completions` (see
///     `openCodeGoSupportsChatCompletions`).
public immutable string opencodeGoBaseUrl = "https://opencode.ai/zen/go/v1";

/// CommandCode's OpenAI-compatible mirror of the same model catalog. It is an
/// alternate provider (postponed as the default on 2026-09-18, see todo.md):
/// set the API base URL and key back to these values to use it. CommandCode
/// keys have the `user_...` shape and its Cloudflare front requires a browser
/// user agent.
public immutable string commandcodeBaseUrl =
    "https://api.commandcode.ai/provider/v1";

private immutable string defaultBaseUrl = opencodeGoBaseUrl;

/// Legacy hosts the app used to point at; migrated away so stale saved
/// settings cannot pin the client to an unreachable or retired provider.
/// `opencode.ai/zen/go/v1` is deliberately NOT here: it is a live, current
/// endpoint (the default), not a retired one.
private immutable string[] legacyBaseUrls = [
    "https://opencode-api.boqsc.eu"
];
public immutable string defaultModel = "deepseek-v4.1-flash";

/// Fallback model ids for the OpenCode Go gateway, used until `/models` is
/// fetched and to rescue a saved model that the provider no longer serves.
/// Only `/chat/completions` models belong here: this client cannot call the
/// `/messages` or `/responses` models.
public immutable string[] defaultModels = [
    "deepseek-v4.1-flash",
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "deepseek-v4-flash-vision-exp",
    "glm-5.3",
    "glm-5.3-flash",
    "glm-5.2",
    "glm-5.1",
    "kimi-k3",
    "kimi-k2.7-code",
    "kimi-k2.6",
    "longcat-2.0",
    "mimo-v2.5",
    "mimo-v2.5-pro",
    "hy4-preview",
    "hy3"
];

/**
 * A selectable API provider preset.
 *
 * Settings lists these and pre-fills the editable base URL, key and model when
 * one is chosen, so switching provider is one click while every field stays
 * editable afterwards (the user can point any preset at a different host or
 * model without losing the preset list).
 */
public struct ProviderPreset
{
    string id;      // stable key: "opencode", "commandcode", "qwen"
    string name;    // display label
    string baseUrl; // default endpoint
    string model;   // default model id for that endpoint
}

/// The provider presets offered by Settings. Order is the display order.
public immutable ProviderPreset[] providerPresets = [
    ProviderPreset("opencode", "OpenCode", opencodeGoBaseUrl,
        "deepseek-v4.1-flash"),
    ProviderPreset("commandcode", "CommandCode", commandcodeBaseUrl,
        "deepseek/deepseek-v4.1-flash"),
    ProviderPreset("qwen", "Qwen 3.8 27B", "http://127.0.0.1:8080/v1",
        "Qwen/Qwen3.8-27B")
];

/// Lowercased, whitespace-trimmed base URL with any trailing slashes removed,
/// so `.../v1` and `.../v1/` identify the same provider.
private string normalizedBaseUrl(string value)
{
    value = value.strip().toLower();
    while (value.length > 0 && value[$ - 1] == '/')
        value = value[0 .. $ - 1];
    return value;
}

/// Index of the preset whose base URL matches `baseUrl`, or -1 for a custom
/// endpoint the user edited by hand.
public int providerPresetIndexForBaseUrl(string baseUrl)
{
    const wanted = normalizedBaseUrl(baseUrl);
    foreach (index, preset; providerPresets)
        if (normalizedBaseUrl(preset.baseUrl) == wanted) return cast(int) index;
    return -1;
}

/// Display label of the provider serving `baseUrl` ("Custom" when edited).
public string providerPresetLabel(string baseUrl)
{
    const index = providerPresetIndexForBaseUrl(baseUrl);
    return index >= 0 ? providerPresets[cast(size_t) index].name : "Custom";
}

unittest
{
    // The preset table drives both the Settings dropdown and the per-provider
    // key resolution, so its contents and matching must stay stable.
    assert(providerPresets.length == 3);
    assert(providerPresetIndexForBaseUrl(opencodeGoBaseUrl) == 0);
    assert(providerPresetIndexForBaseUrl(commandcodeBaseUrl) == 1);
    assert(providerPresetIndexForBaseUrl("http://127.0.0.1:8080/v1") == 2);
    assert(providerPresetIndexForBaseUrl("https://example.com/v1") == -1);
    // A trailing slash identifies the same provider (and therefore its key).
    assert(providerPresetIndexForBaseUrl(opencodeGoBaseUrl ~ "/") == 0);
    assert(providerPresetLabel(opencodeGoBaseUrl) == "OpenCode");
    assert(providerPresetLabel(commandcodeBaseUrl) == "CommandCode");
    assert(providerPresetLabel("https://example.com/v1") == "Custom");
    // A local preset never borrows a cloud credential.
    assert(readProviderKey("qwen") == "");
}

/// The OpenCode Go catalog serves a few models over the Anthropic `/messages`
/// or OpenAI `/responses` shapes. The Aurora client speaks only
/// `/chat/completions`, so offering one of those ids in the picker would make
/// the request fail. Source: the "Endpoints" table in opencode.ai/docs/go
/// (checked 2026-09-18). Unknown ids are treated as supported so a newly added
/// chat-completions model is not hidden.
public bool openCodeGoSupportsChatCompletions(string model)
{
    model = model.strip().toLower();
    switch (model)
    {
        case "grok-4.6":
        case "gpt-5.6-luna":
        case "muse-spark-1.3-contributor":
        case "muse-spark-1.2-contributor":
        case "minimax-m3":
        case "minimax-m2.7":
        case "minimax-m2.5":
        case "qwen3.8-max":
        case "qwen3.8-flash":
        case "qwen3.7-max":
        case "qwen3.7-plus":
        case "qwen3.6-plus":
            return false;
        default:
            return true;
    }
}

/**
 * Lowercased model id with the `vendor/` segment removed.
 *
 * CommandCode serves `vendor/model` ids (`deepseek/deepseek-v4.1-flash`) while
 * the OpenCode gateway serves the same models bare (`deepseek-v4.1-flash`).
 * Comparing the normalized forms lets a model saved under one provider be
 * recognized under the other instead of falling back to the first model in the
 * list.
 */
public string normalizedModelId(string model)
{
    model = model.strip().toLower();
    const slash = model.indexOf('/');
    if (slash > 0) model = model[slash + 1 .. $];
    return model;
}

/// True for any base URL served by the OpenCode gateway (the Go/plan endpoint
/// and the plain Zen endpoint share the request contract).
public bool isOpenCodeApiBaseUrl(string value)
{
    value = value.strip().toLower();
    foreach (prefix; ["https://opencode.ai/", "http://opencode.ai/"])
    {
        if (value.length >= prefix.length && value[0 .. prefix.length] == prefix)
            return true;
    }
    return false;
}

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

/// DeepSeek 4.1 advertises a 1,000,000-token window, but its reliable context
/// is smaller. When the "500K compaction" setting is on, this is the effective
/// window used by both the usage meter and the compaction budget.
public immutable int deepSeekV41CompactLimit = 500_000;

/// True for any DeepSeek 4.1 model, under both the bare OpenCode id
/// (`deepseek-v4.1-flash`) and the CommandCode `vendor/` form
/// (`deepseek/deepseek-v4.1-flash`).
public bool isDeepSeekV41Model(string model)
{
    const id = normalizedModelId(model);
    return id == "deepseek-v4.1" || id.startsWith("deepseek-v4.1-");
}

/// Vision-capable ids known to the gateway, in both bare and `vendor/` forms.
private immutable string[] visionModelIds = [
    // The whole DeepSeek 4.x line accepts inline images, including the default
    // 4.1-flash used by new chats.
    "deepseek-v4.1-flash",
    "deepseek/deepseek-v4.1-flash",
    "deepseek-v4-flash",
    "deepseek/deepseek-v4-flash",
    "deepseek-v4-flash-fast",
    "deepseek/deepseek-v4-flash-fast",
    "deepseek-v4-pro",
    "deepseek/deepseek-v4-pro",
    "deepseek-v4-flash-vision-exp",
    "deepseek/deepseek-v4-flash-vision-exp",
];

/// Model ids (or prefixes) added through AURORA_VISION_MODELS.
private string[] visionModelOverrides()
{
    import std.algorithm : canFind;
    import std.process : environment;
    import std.string : split;
    const raw = environment.get("AURORA_VISION_MODELS", "");
    if (raw.length == 0) return null;
    string[] result;
    foreach (part; raw.split(','))
    {
        const trimmed = part.strip().toLower();
        if (trimmed.length > 0 && !result.canFind(trimmed))
            result ~= trimmed;
    }
    return result;
}

/**
 * Whether a model accepts inline images.
 *
 * The catalog has no per-model capability flag, so this recognizes the vision
 * families the gateway serves (the whole DeepSeek 4.x line, including the
 * default `deepseek-v4.1-flash`) plus any id named `*-vision*`. An unrecognized
 * model is treated as text-only, which is the safe default: an OpenAI
 * `image_url` part sent to a text-only route is a hard 400. Add a local or
 * newly published vision model with AURORA_VISION_MODELS (comma-separated ids
 * or id prefixes).
 */
public bool isVisionModel(string model)
{
    import std.algorithm : canFind, endsWith;
    const id = normalizedModelId(model);
    if (visionModelIds.canFind(id)) return true;
    // Any DeepSeek 4.x id, so a new point release (4.2-flash, 4.1-pro, ...)
    // does not silently fall back to text-only.
    if (id.startsWith("deepseek-v4") ||
        id.startsWith("deepseek/deepseek-v4"))
        return true;
    if (id.endsWith("-vision") || id.endsWith("-vision-exp")) return true;
    foreach (extra; visionModelOverrides())
        if (id == extra || id.startsWith(extra)) return true;
    return false;
}

/**
 * Effective context window (tokens) for a model, as used by the usage meter
 * and the compaction budget.
 *
 * By default this is the catalog window (below). When `compactDeepSeek500k` is
 * set, DeepSeek 4.1 models use `deepSeekV41CompactLimit` instead so compaction
 * happens earlier than their advertised 1,000,000-token limit.
 *
 * The real opencode reads `model.limit.context` from provider metadata and
 * meters context as `tokens.used / limit.context`. The values below mirror the
 * `context_length` the CommandCode provider reports from
 * `https://api.commandcode.ai/provider/v1/models` for every model it serves.
 * The legacy (unprefixed) ids are kept so a settings file written before the
 * CommandCode switch still meters correctly. The fallback is a conservative
 * estimate for unknown models.
 */
public int contextLimitForModel(string model, bool compactDeepSeek500k = false)
{
    if (compactDeepSeek500k && isDeepSeekV41Model(model))
        return deepSeekV41CompactLimit;
    return catalogContextLimitForModel(model);
}

/// The raw catalog window for a model; see `contextLimitForModel`.
private int catalogContextLimitForModel(string model)
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
        // OpenCode gateway catalog (unprefixed ids). Values come from the
        // models.dev catalog for the `opencode` provider where it lists the id,
        // otherwise from the CommandCode entry with the same model, which is
        // the same backend. Ids with no evidence keep the conservative
        // `defaultContextLimit`.
        case "deepseek-v4.1-flash":       return 1_000_000;
        case "deepseek-v4-flash":         return 1_000_000;
        case "deepseek-v4-pro":           return 1_000_000;
        case "deepseek-v4-flash-free":    return 200_000;
        case "deepseek-v4-flash-vision-exp": return 1_000_000;
        case "glm-5.3":                   return 1_000_000;
        case "glm-5.3-flash":             return 1_000_000;
        case "glm-5.2":                   return 1_000_000;
        case "glm-5.1":                   return 204_800;
        case "glm-5":                     return 204_800;
        case "kimi-k3":                   return 1_048_576;
        case "kimi-k2.7-code":            return 262_144;
        case "kimi-k2.6":                 return 262_144;
        case "kimi-k2.5":                 return 262_144;
        case "longcat-2.0":               return 1_000_000;
        case "mimo-v2.5-pro":             return 1_000_000;
        case "mimo-v2.5":                 return 1_000_000;
        case "mimo-v2-pro":               return 1_048_576;
        case "mimo-v2-omni":              return 262_144;
        case "minimax-m3":                return 512_000;
        case "minimax-m2.7":              return 204_800;
        case "minimax-m2.5":              return 204_800;
        case "muse-spark-1.3-contributor": return 1_048_576;
        case "muse-spark-1.2-contributor": return 1_048_576;
        case "qwen3.8-max":               return 1_000_000;
        case "qwen3.8-flash":             return 1_000_000;
        case "qwen3.7-max":               return 1_000_000;
        case "qwen3.7-plus":              return 1_000_000;
        case "qwen3.6-plus":              return 262_144;
        case "qwen3.5-plus":              return 262_144;
        case "grok-4.6":                  return 500_000;
        case "grok-4.5":                  return 500_000;
        case "hy4-preview":               return 1_048_576;
        case "hy3":                       return 262_144;
        case "hy3-preview":               return 256_000;
        default:                   return defaultContextLimit;
    }
}

unittest
{
    // The 500K compaction toggle caps DeepSeek 4.1's effective window for the
    // usage meter and the compaction budget, and leaves every other model
    // (and DeepSeek 4.1 itself when the toggle is off) at its catalog window.
    assert(contextLimitForModel("deepseek/deepseek-v4.1-flash") == 1_000_000);
    assert(contextLimitForModel("deepseek/deepseek-v4.1-flash", true) == 500_000);
    assert(contextLimitForModel("deepseek-v4.1-flash", true) == 500_000);
    assert(contextLimitForModel("deepseek/deepseek-v4-pro", true) == 1_000_000);
    assert(contextLimitForModel("gpt-5.5", true) == 400_000);
}

unittest
{
    // Vision capability decides whether an image part may be sent at all, in
    // both the bare and `vendor/` id forms. The DeepSeek 4.x line is
    // multimodal, so the default model and its point releases must match.
    assert(isVisionModel(defaultModel));
    assert(isVisionModel("deepseek-v4.1-flash"));
    assert(isVisionModel("deepseek/deepseek-v4.1-flash"));
    assert(isVisionModel("deepseek-v4.2-flash"));
    assert(isVisionModel("deepseek-v4-pro"));
    assert(isVisionModel("deepseek-v4-flash-vision-exp"));
    assert(isVisionModel("deepseek/deepseek-v4-flash-vision-exp"));
    assert(isVisionModel("somevendor/MyModel-Vision-Exp"));
    // Text-only models must not match, or a dropped screenshot turns a working
    // chat into a 400.
    assert(!isVisionModel("glm-5.3"));
    assert(!isVisionModel("kimi-k3"));
    assert(!isVisionModel("Qwen/Qwen3.8-27B"));
    assert(!isVisionModel(""));
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
// A conversation whose last turn stopped without completing (a crash, a silent
// stream death, or a user Stop) is flagged in the sidebar with this amber, so
// "needs continue" reads differently from a hard failure red.
public immutable Color opencodeWarning = Color.fromHex(0xf5a623);
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

/// One image carried inline with a user message. `base64Data` is the raw
/// base64 payload (no `data:` prefix); serialization builds the data URL so
/// the wire format stays in one place.
public struct ChatImageAttachment
{
    string mimeType;    // e.g. "image/png"
    string base64Data;  // base64 of the image bytes, no data-URL prefix
    string name;        // original file name, for display and diagnostics
}

/// One message sent in a chat request. Richer than the parallel role/content
/// arrays: assistant messages may carry `toolCalls`, and `tool` role messages
/// carry the `toolCallId` they answer to.
public struct ChatRequestMessage
{
    string role;              // "user" | "assistant" | "tool"
    string content;
    // Provider reasoning state returned with an assistant message. Reasoning
    // models require this exact value to be replayed with the tool_calls it
    // accompanied; omitting it makes the next tool-continuation request fail.
    string reasoningContent;  // role == "assistant" -> reasoning_content
    string toolCallId;        // role == "tool"
    OpenCodeToolCall[] toolCalls; // role == "assistant"
    // Inline images for a multimodal request (role == "user"). When present,
    // `content` is serialized as an OpenAI-compatible parts array
    // (`text` + `image_url`) instead of a bare string.
    ChatImageAttachment[] images;
}

public struct ChatMessage
{
    string role;       // "user" | "assistant" | "tool"
    string content;
    string reasoning;
    string time;       // "HH:MM" local wall-clock, empty when unknown
    bool failed;       // assistant reply that ended in an error
    string finishReason; // provider stop reason; identifies truncated replies
    int promptTokens;  // usage the API reported for the reply (0 = unknown)
    int completionTokens;
    int totalTokens;
    int tokensPerSecondTenths; // output throughput; 123 means 12.3 t/s
    OpenCodeToolCall[] toolCalls; // assistant replies that invoked tools
    string toolCallId;  // "tool" role results, links back to an assistant call
    string toolName;    // "tool" role results: which tool produced the output
    string toolArgs;    // "tool" role results: the command's arguments (JSON)
    int diffAdditions;  // file-mutating tools: added line count (+N)
    int diffDeletions;  // file-mutating tools: removed line count (-M)
    string toolDiff;    // file-mutating tools: unified diff for the expanded view
    long toolElapsedMs; // wall-clock tool duration in ms; 0 hides the label
    double workedSeconds; // user turns: assistant working seconds for this turn
    // Images the user dropped or pasted with this turn. Persisted with the
    // session so a continued or replayed conversation still reaches the model
    // as a vision request instead of silently degrading to text.
    ChatImageAttachment[] images;
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
    // UI-only marker: this message preceded a request whose older context was
    // compacted. It is persisted with the transcript but never sent to a model.
    bool contextCompacted;
}

/// Durable work state kept independently of transcript prose.  The model may
/// restate a plan in chat, but the application must not have to scrape rendered
/// bubbles to discover what remains after a restart.
public struct TaskStep
{
    string text;
    string status; // "pending" | "in_progress" | "completed"
}

public struct ChatSession
{
    // Stable runtime identity. Messages have always had graph ids, but an
    // empty conversation needs an identity too so durable thread events can be
    // recorded before its first prompt is sent.
    string id;
    string title;
    string model;
    bool thinking;
    string projectId;  // owning project; empty/unknown maps to the sandbox
    string objective;
    string taskStatus; // "idle" | "active" | "reviewing" | "verifying" | "completed" | "blocked"
    // Transport/execution lifecycle is intentionally separate from the
    // durable objective. A turn can finish successfully while its objective
    // remains active, and an interrupted turn does not make the objective a
    // blocker by itself.
    string turnStatus; // "idle" | "running" | "completed" | "interrupted" | "failed"
    // Set when a turn reaches a terminal state (completed, interrupted or
    // failed) while the user was looking at a different conversation, and
    // cleared when this conversation is opened. It drives the sidebar's "done,
    // not yet read" dot and must survive a restart so a background turn is not
    // silently missed.
    bool unread;
    TaskStep[] taskSteps;
    string verificationStatus; // "not_required" | "required" | "passed" | "failed"
    // Guidance entered with Enter while a turn is running steers it at the
    // next safe tool boundary. Keeping it here makes steering survive a crash.
    string[] queuedGuidance;
    // Alt+Enter explicitly queues a separate follow-up turn. Unlike steering,
    // these prompts are not injected into the active turn.
    string[] queuedFollowUps;
    ChatMessage[] messages;
    // Model-visible rolling checkpoint. The complete message graph above stays
    // available for display and branch switching; requests on this branch use
    // this note followed by messages after the anchored message.
    string compactionSummary;
    string compactedThroughMessageId;
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

/// A stable id for a durable agent thread. Keep the prefix distinct from
/// message ids so event logs remain readable and accidental cross-linking is
/// easy to spot.
public string newSessionId()
{
    return "t-" ~ newMessageId();
}

/**
 * A stable routing key for one conversation, sent as `x-opencode-session` on
 * every OpenCode gateway request. The gateway uses it to keep prompt caching
 * and scheduling coherent, and rejects requests without it. The first
 * message's graph id is stable for the life of the conversation (across
 * turns, edits and restarts), so it identifies the conversation without the
 * app having to persist a separate id.
 */
public string sessionRoutingKey(const ref ChatSession session)
{
    if (session.messages.length > 0 && session.messages[0].id.length > 0)
        return "aurora-" ~ session.messages[0].id;
    if (session.activeLeafId.length > 0)
        return "aurora-" ~ session.activeLeafId;
    return "aurora-default";
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

/**
 * The two credentials kept for one provider: the main key from Settings, a
 * spare key, and which of the two is currently live. Identified by the preset
 * id when the endpoint is one of `providerPresets`, otherwise by the endpoint
 * itself, so every provider keeps its own pair.
 */
public struct ProviderApiKeys
{
    string providerId;        // preset id, or "" for a hand-edited endpoint
    string baseUrl;           // the endpoint this pair belongs to
    string apiKey;            // main key field
    string additionalApiKey;  // spare key field
    bool additionalKeyActive; // true => the spare key is the live one
}

public struct Settings
{
    string baseUrl = defaultBaseUrl;
    // The LIVE credential for `baseUrl`; see `activeApiKey`.
    string apiKey = "";
    // Per-provider key pairs: each provider keeps its own main and spare key
    // and remembers which of the two is active.
    ProviderApiKeys[] providerKeys;
    string model = defaultModel;
    bool thinking;
    bool toolsEnabled = true;  // native D tools (run/read/write/remove/glob/grep/dshell); main, on by default
    bool legacyTools;          // additionally expose the bash/cmd/powershell shell tool; off by default
    bool showWorkedFor;        // show the "Worked for …" completion separator; off by default
    // Show the durable plan as a floating panel in the transcript's top-right
    // corner, detached from the message flow; on by default.
    bool detachedPlan = true;
    // Optional request targets scoped to the exact endpoint and model.
    ModelContextBudget[] contextBudgets;
    // Automatic request compaction is opt-in for each endpoint and model.
    ModelContextCompaction[] contextCompactions;
    // Optional reasoning effort and llama.cpp budget for each endpoint/model.
    ModelReasoningControl[] reasoningControls;
    bool compactDeepSeek500k; // legacy migration only
    string workspace;          // working directory the tools run in
    // Optional response-verbosity selector: "default" (stock prompt),
    // "concise", or "compact". "default" is a no-op, so an existing settings
    // file that lacks the key keeps the exact previous prompt.
    string verbosity = "default";
}

public struct ModelContextBudget
{
    string baseUrl;
    string model;
    int tokens;
}

public struct ModelContextCompaction
{
    string baseUrl;
    string model;
}

public struct ModelReasoningControl
{
    string baseUrl;
    string model;
    // Empty keeps the existing Thinking-on default of "high".
    string effort;
    // Zero leaves the server's reasoning budget unchanged.
    int budgetTokens;
}

public ModelReasoningControl reasoningControlForModel(const ref Settings settings,
    string baseUrl, string model)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    foreach (control; settings.reasoningControls)
        if (control.baseUrl == endpoint && control.model == model)
            return control;
    return ModelReasoningControl(endpoint, model, "", 0);
}

public void setReasoningControlForModel(ref Settings settings,
    string baseUrl, string model, string effort, int budgetTokens)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    if (endpoint.length == 0 || model.length == 0 ||
        (effort.length > 0 && effort != "low" && effort != "medium" &&
            effort != "high") || budgetTokens < 0 ||
        budgetTokens > 32_768) return;
    foreach (i, control; settings.reasoningControls)
        if (control.baseUrl == endpoint && control.model == model)
        {
            if (effort.length > 0 || budgetTokens > 0)
            {
                settings.reasoningControls[i].effort = effort;
                settings.reasoningControls[i].budgetTokens = budgetTokens;
            }
            else settings.reasoningControls = settings.reasoningControls[0 .. i] ~
                settings.reasoningControls[i + 1 .. $];
            return;
        }
    if (effort.length > 0 || budgetTokens > 0)
        settings.reasoningControls ~= ModelReasoningControl(endpoint, model,
            effort, budgetTokens);
}

public int contextBudgetForModel(const ref Settings settings,
    string baseUrl, string model)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    foreach (budget; settings.contextBudgets)
        if (budget.baseUrl == endpoint && budget.model == model)
            return budget.tokens;
    return 0;
}

public bool contextCompactionForModel(const ref Settings settings,
    string baseUrl, string model)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    foreach (entry; settings.contextCompactions)
        if (entry.baseUrl == endpoint && entry.model == model)
            return true;
    return false;
}

public void setContextCompactionForModel(ref Settings settings,
    string baseUrl, string model, bool enabled)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    if (endpoint.length == 0 || model.length == 0) return;
    foreach (i, entry; settings.contextCompactions)
        if (entry.baseUrl == endpoint && entry.model == model)
        {
            if (!enabled)
                settings.contextCompactions = settings.contextCompactions[0 .. i] ~
                    settings.contextCompactions[i + 1 .. $];
            return;
        }
    if (enabled)
        settings.contextCompactions ~= ModelContextCompaction(endpoint, model);
}

public void setContextBudgetForModel(ref Settings settings,
    string baseUrl, string model, int tokens)
{
    const endpoint = normalizedBaseUrl(baseUrl);
    if (endpoint.length == 0 || model.length == 0) return;
    foreach (i, budget; settings.contextBudgets)
        if (budget.baseUrl == endpoint && budget.model == model)
        {
            if (tokens > 0) settings.contextBudgets[i].tokens = tokens;
            else settings.contextBudgets = settings.contextBudgets[0 .. i] ~
                settings.contextBudgets[i + 1 .. $];
            return;
        }
    if (tokens > 0)
        settings.contextBudgets ~= ModelContextBudget(endpoint, model, tokens);
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

/// Read one provider's `key` from the opencode CLI auth store
/// (`~/.local/share/opencode/auth.json`). "" when the provider or file is
/// missing.
private string readAuthProviderKey(string provider)
{
    const profile = environment.get("USERPROFILE");
    if (profile.length == 0) return "";
    const authPath = buildPath(profile, ".local", "share", "opencode",
        "auth.json");
    try
    {
        if (!exists(authPath)) return "";
        auto value = parseJSON(readText(authPath));
        if (value.type != JSONType.object) return "";
        if (auto found = provider in value.object)
        {
            if (found.type == JSONType.object)
            {
                if (auto key = "key" in found.object)
                    if (key.type == JSONType.string && key.str.length > 0)
                        return key.str;
            }
        }
    }
    catch (Exception error)
    {
        logError("failed to read opencode auth: " ~ error.msg);
    }
    return "";
}

/**
 * Best-known API key for a provider preset id.
 *
 * A local endpoint (qwen) usually needs no key, so this returns "" for it
 * rather than borrowing an unrelated cloud credential. CommandCode also checks
 * the opencode CLI's `~/.config/opencode/commandcode.key` file.
 */
public string readProviderKey(string providerId)
{
    switch (providerId)
    {
        case "commandcode":
        {
            auto key = readAuthProviderKey("commandcode");
            if (key.length > 0) return key;
            const profile = environment.get("USERPROFILE");
            if (profile.length > 0)
            {
                const path = buildPath(profile, ".config", "opencode",
                    "commandcode.key");
                try
                {
                    if (exists(path))
                    {
                        const value = readText(path).strip();
                        if (value.length > 0) return value;
                    }
                }
                catch (Exception) {}
            }
            return readDefaultKeyFile();
        }
        case "qwen":
            return "";
        case "opencode":
        default:
        {
            auto key = readAuthProviderKey("opencode-go");
            if (key.length > 0) return key;
            key = readAuthProviderKey("opencode");
            if (key.length > 0) return key;
            return readDefaultKeyFile();
        }
    }
}

private string readDefaultKeyFile()
{
    // Primary: the real opencode CLI auth store
    // (~/.local/share/opencode/auth.json) which holds the Go-plan and
    // DeepSeek API keys. Prefer the OpenCode gateway credential (the default
    // provider); fall back to the alternate providers.
    foreach (provider; ["opencode-go", "commandcode", "deepseek"])
    {
        auto key = readAuthProviderKey(provider);
        if (key.length > 0) return key;
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
    int settingsVersion;
    int legacyContextBudget;
    const path = buildPath(opencodeStateDirectory(), "settings.json");
    if (exists(path))
    {
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type == JSONType.object)
            {
                if (auto found = "settingsVersion" in value.object)
                    if (found.type == JSONType.integer)
                        settingsVersion = cast(int) found.integer;
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
                if (auto found = "showWorkedFor" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.showWorkedFor = found.type == JSONType.true_;
                if (auto found = "detachedPlan" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.detachedPlan = found.type == JSONType.true_;
                if (auto found = "compactDeepSeek500k" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.compactDeepSeek500k = found.type == JSONType.true_;
                if (auto found = "contextBudgetTokens" in value.object)
                    if (found.type == JSONType.integer &&
                        found.integer >= 0 && found.integer <= 1_000_000)
                        legacyContextBudget = cast(int) found.integer;
                if (auto found = "contextBudgets" in value.object)
                    if (found.type == JSONType.array)
                        foreach (entry; found.array)
                        {
                            if (entry.type != JSONType.object) continue;
                            auto base = "baseUrl" in entry.object;
                            auto model = "model" in entry.object;
                            auto tokens = "tokens" in entry.object;
                            if (base is null || model is null || tokens is null ||
                                base.type != JSONType.string ||
                                model.type != JSONType.string ||
                                tokens.type != JSONType.integer ||
                                tokens.integer <= 0 ||
                                tokens.integer > 1_000_000) continue;
                            setContextBudgetForModel(settings, base.str,
                                model.str, cast(int) tokens.integer);
                        }
                if (auto found = "contextCompactions" in value.object)
                    if (found.type == JSONType.array)
                        foreach (entry; found.array)
                        {
                            if (entry.type != JSONType.object) continue;
                            auto base = "baseUrl" in entry.object;
                            auto model = "model" in entry.object;
                            if (base is null || model is null ||
                                base.type != JSONType.string ||
                                model.type != JSONType.string) continue;
                            setContextCompactionForModel(settings, base.str,
                                model.str, true);
                        }
                if (auto found = "reasoningControls" in value.object)
                    if (found.type == JSONType.array)
                        foreach (entry; found.array)
                        {
                            if (entry.type != JSONType.object) continue;
                            auto base = "baseUrl" in entry.object;
                            auto model = "model" in entry.object;
                            auto effort = "effort" in entry.object;
                            auto budget = "budgetTokens" in entry.object;
                            if (base is null || model is null ||
                                base.type != JSONType.string ||
                                model.type != JSONType.string ||
                                (effort !is null &&
                                    effort.type != JSONType.string) ||
                                (budget !is null &&
                                    (budget.type != JSONType.integer ||
                                     budget.integer < 0 ||
                                     budget.integer > 32_768))) continue;
                            setReasoningControlForModel(settings, base.str,
                                model.str, effort is null ? "" : effort.str,
                                budget is null ? 0 : cast(int) budget.integer);
                        }
                // Unknown or blank values fall through to the "default"
                // initializer, so a hand-edited file cannot change the prompt
                // to something the app does not understand.
                if (auto found = "verbosity" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.verbosity = found.str;
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
                // Per-provider key pairs; entries carrying no key at all are
                // dropped rather than half-restored.
                if (auto found = "providerKeys" in value.object)
                {
                    if (found.type == JSONType.array)
                    {
                        foreach (entry; found.array)
                        {
                            if (entry.type != JSONType.object) continue;
                            ProviderApiKeys keys;
                            if (auto f = "providerId" in entry.object)
                                keys.providerId = f.str;
                            if (auto f = "baseUrl" in entry.object)
                                keys.baseUrl = f.str;
                            if (auto f = "apiKey" in entry.object)
                                keys.apiKey = f.str;
                            if (auto f = "additionalApiKey" in entry.object)
                                keys.additionalApiKey = f.str;
                            if (auto f = "additionalKeyActive" in entry.object)
                                if (f.type == JSONType.true_ ||
                                    f.type == JSONType.false_)
                                    keys.additionalKeyActive =
                                        f.type == JSONType.true_;
                            if (keys.providerId.length == 0 ||
                                (keys.apiKey.length == 0 &&
                                 keys.additionalApiKey.length == 0))
                                continue;
                            settings.providerKeys ~= keys;
                        }
                    }
                }
                // Migration: earlier builds kept one global spare key, and
                // before that a list of named keys with the active value in
                // `apiKey`. Fold whatever they had into the configured
                // provider's pair so no credential is lost on upgrade.
                string legacyAdditionalKey;
                bool legacyAdditionalActive;
                if (auto found = "additionalApiKey" in value.object)
                    if (found.type == JSONType.string)
                        legacyAdditionalKey = found.str;
                if (auto found = "additionalKeyActive" in value.object)
                    if (found.type == JSONType.true_ ||
                        found.type == JSONType.false_)
                        legacyAdditionalActive = found.type == JSONType.true_;
                if (legacyAdditionalKey.length == 0)
                {
                    if (auto found = "savedKeys" in value.object)
                    {
                        if (found.type == JSONType.array)
                        {
                            foreach (entry; found.array)
                            {
                                if (entry.type != JSONType.object) continue;
                                string key;
                                if (auto f = "key" in entry.object)
                                    key = f.str;
                                if (key.length == 0 || key == settings.apiKey)
                                    continue;
                                legacyAdditionalKey = key;
                                break;
                            }
                        }
                    }
                }
                if (legacyAdditionalKey.length > 0 &&
                    findProviderApiKeys(settings, settings.baseUrl) is null)
                {
                    storeProviderApiKeys(settings, settings.baseUrl,
                        settings.apiKey, legacyAdditionalKey,
                        legacyAdditionalActive);
                }
                // Version 2 makes native, structured tools the reliable
                // default for existing installations too. Older builds wrote
                // `legacyTools: true` by default, which kept steering models
                // into fragile shell quoting on Windows. Users can opt back in
                // from Settings after this one-time migration.
                if (settingsVersion < 2)
                    settings.legacyTools = false;
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
    {
        // Resolve the credential for the CONFIGURED provider, not always the
        // OpenCode one. A saved CommandCode endpoint must load the CommandCode
        // key, and a local preset must stay blank instead of borrowing an
        // unrelated cloud credential. Custom (non-preset) endpoints keep the
        // previous env/default behaviour.
        const presetIndex = providerPresetIndexForBaseUrl(settings.baseUrl);
        if (presetIndex >= 0)
        {
            settings.apiKey = readProviderKey(
                providerPresets[cast(size_t) presetIndex].id);
        }
        else
        {
            settings.apiKey = environment.get("OPENCODE_API_KEY");
            if (settings.apiKey.length == 0)
                settings.apiKey = readDefaultKeyFile();
        }
    }
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
    // The provider's stored pair is authoritative: the live key is whichever of
    // its two keys the user toggled active.
    if (auto entry = findProviderApiKeys(settings, settings.baseUrl))
        if (activeKeyOf(*entry).length > 0)
            settings.apiKey = activeKeyOf(*entry);
    if (contextBudgetForModel(settings, settings.baseUrl,
            settings.model) == 0)
    {
        if (legacyContextBudget > 0)
            setContextBudgetForModel(settings, settings.baseUrl,
                settings.model, legacyContextBudget);
        else if (settings.compactDeepSeek500k &&
            isDeepSeekV41Model(settings.model))
            setContextBudgetForModel(settings, settings.baseUrl,
                settings.model, deepSeekV41CompactLimit);
    }
    settings.compactDeepSeek500k = false;
    return settings;
}

public void saveSettings(const ref Settings settings)
{
    ensureStateDirectory();
    JSONValue root;
    root["settingsVersion"] = 2;
    root["baseUrl"] = settings.baseUrl;
    root["apiKey"] = settings.apiKey;
    JSONValue providerKeys = JSONValue(string[].init);
    foreach (keys; settings.providerKeys)
    {
        JSONValue item;
        item["providerId"] = keys.providerId;
        item["baseUrl"] = keys.baseUrl;
        item["apiKey"] = keys.apiKey;
        item["additionalApiKey"] = keys.additionalApiKey;
        item["additionalKeyActive"] = keys.additionalKeyActive;
        providerKeys.array ~= item;
    }
    root["providerKeys"] = providerKeys;
    root["model"] = settings.model;
    root["thinking"] = settings.thinking;
    root["toolsEnabled"] = settings.toolsEnabled;
    root["legacyTools"] = settings.legacyTools;
    root["showWorkedFor"] = settings.showWorkedFor;
    root["detachedPlan"] = settings.detachedPlan;
    JSONValue contextBudgets = JSONValue(string[].init);
    foreach (budget; settings.contextBudgets)
    {
        JSONValue item;
        item["baseUrl"] = budget.baseUrl;
        item["model"] = budget.model;
        item["tokens"] = budget.tokens;
        contextBudgets.array ~= item;
    }
    root["contextBudgets"] = contextBudgets;
    JSONValue contextCompactions = JSONValue(string[].init);
    foreach (entry; settings.contextCompactions)
    {
        JSONValue item;
        item["baseUrl"] = entry.baseUrl;
        item["model"] = entry.model;
        contextCompactions.array ~= item;
    }
    root["contextCompactions"] = contextCompactions;
    JSONValue reasoningControls = JSONValue(string[].init);
    foreach (control; settings.reasoningControls)
    {
        JSONValue item;
        item["baseUrl"] = control.baseUrl;
        item["model"] = control.model;
        item["effort"] = control.effort;
        item["budgetTokens"] = control.budgetTokens;
        reasoningControls.array ~= item;
    }
    root["reasoningControls"] = reasoningControls;
    root["workspace"] = settings.workspace;
    root["verbosity"] = settings.verbosity;
    try write(buildPath(opencodeStateDirectory(), "settings.json"),
        root.toString());
    catch (Exception error)
    {
        logError("failed to save settings: " ~ error.msg);
    }
}

// ---------------------------------------------------------------------------
// Per-provider API keys
// ---------------------------------------------------------------------------

/// Identity of the provider serving `baseUrl`: the preset id for a known
/// endpoint, otherwise the normalized endpoint itself, so a hand-edited host
/// still keeps its own key pair.
public string apiKeyOwnerForBaseUrl(string baseUrl)
{
    const index = providerPresetIndexForBaseUrl(baseUrl);
    if (index >= 0) return providerPresets[cast(size_t) index].id;
    return normalizedBaseUrl(baseUrl);
}

/// The stored key pair for `baseUrl`, or null when that provider has none yet.
public const(ProviderApiKeys)* findProviderApiKeys(const ref Settings settings,
    string baseUrl)
{
    const owner = apiKeyOwnerForBaseUrl(baseUrl);
    if (owner.length == 0) return null;
    foreach (ref const entry; settings.providerKeys)
        if (entry.providerId == owner) return &entry;
    return null;
}

/// Store the two keys and the active-key toggle for the provider serving
/// `baseUrl`, replacing any previous pair for it. A blank endpoint is ignored
/// (there is nothing to key the pair on).
public void storeProviderApiKeys(ref Settings settings, string baseUrl,
    string apiKey, string additionalApiKey, bool additionalKeyActive)
{
    const owner = apiKeyOwnerForBaseUrl(baseUrl);
    if (owner.length == 0) return;
    foreach (ref entry; settings.providerKeys)
    {
        if (entry.providerId != owner) continue;
        entry.baseUrl = baseUrl;
        entry.apiKey = apiKey;
        entry.additionalApiKey = additionalApiKey;
        entry.additionalKeyActive = additionalKeyActive;
        return;
    }
    settings.providerKeys ~= ProviderApiKeys(owner, baseUrl, apiKey,
        additionalApiKey, additionalKeyActive);
}

/// The live key of one stored pair: the spare when it is toggled active and
/// holds a value, otherwise the main key. An empty spare never shadows a
/// filled main key, so switching to it cannot silently drop the credential.
public string activeKeyOf(const ref ProviderApiKeys keys)
{
    return keys.additionalKeyActive && keys.additionalApiKey.length > 0
        ? keys.additionalApiKey : keys.apiKey;
}

/// The key actually sent with requests for the configured `baseUrl`: the
/// provider's own active key when it has a stored pair, else `apiKey`.
public string activeApiKey(const ref Settings settings)
{
    if (auto entry = findProviderApiKeys(settings, settings.baseUrl))
        return activeKeyOf(*entry);
    return settings.apiKey;
}

unittest
{
    // Every provider keeps its own main + spare key, and the toggle decides
    // which of the two is live for that provider only.
    Settings settings;
    assert(activeApiKey(settings) == "");
    storeProviderApiKeys(settings, opencodeGoBaseUrl, "k-open", "s-open", false);
    storeProviderApiKeys(settings, commandcodeBaseUrl, "k-cc", "s-cc", true);
    assert(settings.providerKeys.length == 2);
    settings.baseUrl = opencodeGoBaseUrl;
    assert(activeApiKey(settings) == "k-open");
    settings.baseUrl = commandcodeBaseUrl;
    assert(activeApiKey(settings) == "s-cc");
    // The toggle is per provider: flipping CommandCode back leaves OpenCode's
    // own pair untouched.
    storeProviderApiKeys(settings, commandcodeBaseUrl, "k-cc", "s-cc", false);
    assert(activeApiKey(settings) == "k-cc");
    settings.baseUrl = opencodeGoBaseUrl;
    assert(activeApiKey(settings) == "k-open");
    // A hand-edited endpoint is its own provider, and an empty spare never
    // shadows the main key.
    storeProviderApiKeys(settings, "https://example.com/v1", "k-custom", "",
        true);
    settings.baseUrl = "https://example.com/v1/";
    assert(activeApiKey(settings) == "k-custom");
    // A provider with no stored pair falls back to the live key.
    settings.baseUrl = "https://unknown.example/v1";
    settings.apiKey = "k-live";
    assert(activeApiKey(settings) == "k-live");
    // Re-storing a provider replaces its pair instead of adding another.
    storeProviderApiKeys(settings, commandcodeBaseUrl, "k-cc2", "s-cc2", false);
    assert(settings.providerKeys.length == 3);
}

unittest
{
    // Per-provider key pairs and their toggles survive a save/load round-trip,
    // and the live key follows the configured provider.
    const dir = buildPath(tempDir(), "aurora-opencode-keys-test");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit)
    {
        setOpencodeStateDirectoryForTesting("");
        if (exists(dir)) rmdirRecurse(dir);
    }
    setOpencodeStateDirectoryForTesting(dir);

    Settings saved;
    saved.baseUrl = commandcodeBaseUrl;
    storeProviderApiKeys(saved, opencodeGoBaseUrl, "k-open", "s-open", false);
    storeProviderApiKeys(saved, commandcodeBaseUrl, "k-cc", "s-cc", true);
    saved.apiKey = "s-cc";
    saveSettings(saved);

    Settings loaded = loadSettings();
    assert(loaded.baseUrl == commandcodeBaseUrl);
    assert(loaded.providerKeys.length == 2);
    assert(activeApiKey(loaded) == "s-cc");
    Settings probe = loaded;
    probe.baseUrl = opencodeGoBaseUrl;
    assert(activeApiKey(probe) == "k-open");
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

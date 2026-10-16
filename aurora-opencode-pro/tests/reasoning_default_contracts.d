module reasoning_default_contracts;

// Focused verification of the DeepSeek 4.1 Flash Thinking default: a route the
// user never configured must reason `high` instead of sending reasoning_effort
// none/off, an explicit per-route choice -- `off` included -- must still win, and
// every other model must keep the previous off-by-default behavior so a gateway
// that rejects reasoning_effort is never sent one by default.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets -of=build/reasoning_default_contracts.exe \
//       aurora-opencode-pro/tests/reasoning_default_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/reasoning_default_contracts.exe

import auroraopencode.core : Settings, defaultThinkingForModel,
    effectiveThinkingForModel, loadSettings, reasoningControlForModel,
    saveSettings, setOpencodeStateDirectoryForTesting,
    setReasoningControlForModel;
import auroraopencode.provideradapter : buildChatBody;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.json : parseJSON;
import std.path : buildPath;
import std.stdio : writeln;

private enum string commandCode = "https://api.commandcode.ai/provider/v1";

int main()
{
    assert(defaultThinkingForModel("deepseek-v4.1-flash"));
    assert(defaultThinkingForModel("deepseek/deepseek-v4.1-flash"));
    assert(!defaultThinkingForModel("deepseek/deepseek-v4.1-flash-fast"));
    assert(!defaultThinkingForModel("qwen/qwen3.8-27b"));

    // A Settings file that never recorded a Thinking choice for this route: the
    // raw field is the old off default, and the route must reason high anyway.
    Settings fresh;
    fresh.model = "deepseek/deepseek-v4.1-flash";
    assert(!fresh.thinking, "the raw Thinking field starts off");
    assert(effectiveThinkingForModel(fresh, commandCode, fresh.model),
        "an unconfigured DeepSeek 4.1 Flash route must reason by default");
    const on = parseJSON(buildChatBody(null, null, fresh.model,
        effectiveThinkingForModel(fresh, commandCode, fresh.model), commandCode));
    assert(on["reasoning_effort"].str == "high", on.toString);
    writeln("PASS: an unconfigured DeepSeek 4.1 Flash route sends reasoning_effort high");

    // An explicit effort still wins.
    setReasoningControlForModel(fresh, commandCode, fresh.model, "low", 0);
    assert(effectiveThinkingForModel(fresh, commandCode, fresh.model),
        "an explicit effort must enable Thinking");
    assert(reasoningControlForModel(fresh, commandCode, fresh.model).effort == "low");

    // An explicit Off still wins over the model default.
    setReasoningControlForModel(fresh, commandCode, fresh.model, "off", 0);
    assert(!effectiveThinkingForModel(fresh, commandCode, fresh.model),
        "an explicit Off must not be re-enabled by the model default");
    const off = parseJSON(buildChatBody(null, null, fresh.model, false, commandCode));
    assert(off["reasoning_effort"].str == "off", off.toString);
    writeln("PASS: an explicit per-route choice, Off included, overrides the default");

    // Another model keeps the previous behavior, so an unconfigured gateway is
    // never sent a reasoning option it may reject.
    Settings other;
    other.model = "qwen/qwen3.8-27b";
    assert(!effectiveThinkingForModel(other, commandCode, other.model));
    const none = parseJSON(buildChatBody(null, null, other.model, false,
        "https://example.com/v1"));
    assert(("reasoning_effort" in none.object) is null, none.toString);
    writeln("PASS: an unconfigured non-DeepSeek route still sends no reasoning_effort");

    // The explicit choice survives a Settings round trip.
    const stateDir = buildPath(tempDir, "aurora-reasoning-default");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    saveSettings(fresh);
    const reloaded = loadSettings();
    assert(reloaded.reasoningControls.length == 1 &&
        reasoningControlForModel(reloaded, commandCode, fresh.model).effort == "off",
        "an explicit Off must survive the Settings round trip");
    writeln("reasoning_default_contracts: PASS");
    return 0;
}

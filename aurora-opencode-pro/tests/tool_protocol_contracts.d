module tool_protocol_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.toolprotocol : normalizeToolCalls;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : absolutePath;
import std.stdio : writeln;

int main()
{
    OpenCodeToolCall[] calls = [
        OpenCodeToolCall("call_auto_1", "read", "{}"),
        OpenCodeToolCall("", "read", "{}"),
        OpenCodeToolCall("call_aurora_7_1", "read", "{}"),
        OpenCodeToolCall("call_auto_1", "read", "{}"),
        OpenCodeToolCall("call_aurora_7_1_1", "read", "{}")];
    auto normalized = normalizeToolCalls(calls, null, "", 7);
    assert(normalized[1].id == "call_aurora_7_1_2");
    assert(normalized[0].id == calls[0].id && normalized[2].id == calls[2].id);
    assert(calls[1].id == "", "Normalization mutated the provider event");
    bool[string] seen;
    foreach (call; normalized)
    {
        assert(call.id.length && !(call.id in seen));
        seen[call.id] = true;
    }
    ChatMessage old; old.id = "old"; old.toolCalls = normalized;
    ChatMessage current; current.id = "current"; current.toolCalls = calls;
    auto repeated = normalizeToolCalls(calls, [old, current], "current", 7);
    foreach (call; repeated) assert(!(call.id in seen));
    assert(repeated == normalizeToolCalls(calls, [old, current], "current", 7),
        "Replaying a recorded batch produced different IDs");

    const state = absolutePath("tool-protocol-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9";
    settings.quickTitle = false; saveSettings(settings);
    WindowOptions options; options.width = 1200; options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope (exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Inspect available tools", ""]);
    root.pauseToolContinuationForTesting();
    // An unknown tool is a cheap real scheduler result. The historical bug
    // dropped one of these results and left pendingToolResults permanently > 0.
    root.injectToolCallsForTesting([
        OpenCodeToolCall("call_auto_1", "unknown_a", "{}"),
        OpenCodeToolCall("", "unknown_b", "{}"),
        OpenCodeToolCall("call_auto_1", "unknown_c", "{}")]);
    const settled = MonoTime.currTime + 10.seconds;
    while (root.pendingToolResultsForTesting() && MonoTime.currTime < settled)
    { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    assert(root.pendingToolResultsForTesting() == 0, "Colliding IDs stranded a tool round");
    assert(root.toolMessageCountForTesting() == 3, "A distinct tool result was lost");
    writeln("PASS reserved, blank, duplicate and historical IDs normalize deterministically; all actual scheduler results settle");
    return 0;
}

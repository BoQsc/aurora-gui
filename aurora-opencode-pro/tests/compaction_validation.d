module compaction_validation;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : absolutePath;
import std.stdio : writeln;
import std.string : indexOf;
import std.json : JSONValue;

int main()
{
    const state = absolutePath("compaction-validation-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9/v1";
    settings.apiKey = ""; settings.quickTitle = false; saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    {
        window.onNativeTick(0.02);
        Thread.sleep(5.msecs);
    }
    assert(!root.startupPendingForTesting());
    // A fact in the middle of a long prior message cannot be reconstructed
    // from a deterministic head/tail summary. Measure rather than conceal it.
    root.newChatForTesting();
    const original = "Keep the following project reference data available.\n" ~
        "unrelated historical record\n".replicate(6000) ~
        "CRITICAL_REFERENCE_VALUE=Q9-7316\n" ~
        "unrelated historical record\n".replicate(6000);
    root.addConversationForTesting(["user", "assistant", "user", "assistant", "user"],
        ["Retain reference data for later queries.", "Ready.", original,
         "Reference data received.", "Return CRITICAL_REFERENCE_VALUE exactly."]);
    const count = root.totalMessageCountForTesting();
    foreach (budget; [500_000, 64_000, 16_000])
    {
        const request = root.compactedRequestMessagesForTesting(budget);
        size_t bytes; bool retained;
        foreach (message; request)
        {
            bytes += message.content.length;
            if (message.content.indexOf("CRITICAL_REFERENCE_VALUE=Q9-7316") >= 0) retained = true;
        }
        assert(root.totalMessageCountForTesting() == count && root.messageContentForTesting(2) == original,
            "Compaction modified stored user history");
        if (budget == 500_000) assert(retained);
        JSONValue result; result["budget"] = budget; result["requestBytes"] = cast(long) bytes;
        result["middleFactRetained"] = retained; result["savedHistoryPreserved"] = true;
        writeln("COMPACTION ", result.toString());
    }
    return 0;
}

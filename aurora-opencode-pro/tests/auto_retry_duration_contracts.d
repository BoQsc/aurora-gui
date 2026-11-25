module auto_retry_duration_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

/**
 * A failing provider attempt that is itself longer than the outage budget must
 * not end the automatic recovery.
 *
 * Every real timeout consumes one whole request wait: the provider answers
 * nothing for minutes and WinHTTP gives up at its own 120 s receive timeout,
 * which is the same length as the default outage budget. Counting that wait as
 * recovery time left exactly one automatic re-send for the whole turn, and any
 * later failure was final. The budget is meant to bound the time the turn
 * spends *waiting out* an unavailable provider, so a slow failing request is
 * followed by another automatic attempt.
 *
 * The fixture provider stalls past the budget on its first one or two attempts
 * and then answers, so a passing run proves the re-send happened without the
 * user pressing Retry.
 */
int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run through the automatic-retry fixture provider");
    // The real app's defaults are the same two numbers at full size: a provider
    // request that is left unanswered is abandoned by the inactivity watchdog,
    // and the failed attempt is therefore at least as long as the recovery
    // budget it used to consume.
    environment["AURORA_NETWORK_INACTIVITY_MS"] = "10000";
    environment["AURORA_PROVIDER_OUTAGE_MS"] = "9000";
    const state = buildPath(tempDir(),
        "aurora-auto-retry-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = base; settings.apiKey = "fixture"; settings.model = "slow-fail-once";
    settings.workspace = workspace; settings.toolsEnabled = false;
    settings.quickTitle = false; settings.legacyTools = false;
    saveSettings(settings);
    WindowOptions options;
    options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    bool sawSchedule;
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        if (root.autoResendPendingForTesting()) sawSchedule = true;
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    void until(bool delegate() done, int secondsAllowed = 120)
    {
        const deadline = MonoTime.currTime + secondsAllowed.seconds;
        while (!done() && MonoTime.currTime < deadline) pump();
        assert(done(), "Did not settle: status=" ~ root.turnStatusForTesting() ~
            " content=" ~ root.lastAssistantContentForTesting() ~
            " error=" ~ root.lastAssistantErrorForTesting());
    }
    void ask(string model, string prompt)
    {
        root.newChatForTesting();
        root.setSessionModelForTesting(root.currentSessionForTesting(), model);
        root.setInputForTesting(prompt);
        root.sendForTesting();
        // A scheduled automatic re-send leaves the turn idle between attempts,
        // so the turn has only settled once nothing is waiting to fire.
        until(delegate()
        {
            return !root.turnBusyForTesting() && !root.autoResendPendingForTesting();
        });
    }
    until(delegate() { return !root.startupPendingForTesting(); });

    // One attempt slower than the whole outage budget still recovers.
    ask("slow-fail-once", "Recover from one slow provider failure.");
    assert(root.turnStatusForTesting() == "completed",
        "A slow failing attempt ended the turn: " ~ root.lastAssistantErrorForTesting());
    assert(root.lastAssistantErrorForTesting().length == 0,
        "The recovered turn kept a failed reply: " ~ root.lastAssistantErrorForTesting());
    assert(root.lastAssistantContentForTesting() == "Recovered after the slow failure.",
        "The automatic re-send did not deliver the provider's answer: " ~
        root.lastAssistantContentForTesting());
    assert(sawSchedule, "No automatic re-send was ever scheduled");
    writeln("Slow failure: automatic re-send outlived the budget spent by the attempt");

    // A second slow failure, also longer than the budget, is retried as well.
    sawSchedule = false;
    ask("slow-fail-twice", "Recover from two slow provider failures.");
    assert(root.turnStatusForTesting() == "completed",
        "The second slow failure ended the turn: " ~ root.lastAssistantErrorForTesting());
    assert(root.lastAssistantContentForTesting() == "Recovered after two slow failures.",
        "Repeated recovery did not deliver the provider's answer: " ~
        root.lastAssistantContentForTesting());
    assert(sawSchedule, "Repeated recovery scheduled no re-send");

    // A declined request is still final: replaying it would only hide the reason.
    sawSchedule = false;
    ask("declined", "Report a declined request.");
    assert(root.turnStatusForTesting() == "failed",
        "A declined request was retried instead of reported");
    assert(!sawSchedule, "A declined request scheduled an automatic re-send");
    assert(root.lastAssistantErrorForTesting().indexOf("declined") >= 0 ||
        root.lastAssistantErrorForTesting().indexOf("401") >= 0,
        "The declined request's reason was lost: " ~ root.lastAssistantErrorForTesting());
    writeln("PASS slow failures retry past their own duration; declined requests stay final");
    return 0;
}

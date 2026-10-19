module tool_dispatch_status_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.tools : ChangeContext, ToolCancellation;
import auroraopencode.toolscheduler : scheduleToolBatch;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = absolutePath("tool-status-state-" ~ to!string(MonoTime.currTime.ticks));
    const workspace = buildPath(tempDir(), "aurora-tool-status-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.workspace = workspace;
    settings.baseUrl = "http://127.0.0.1:9";
    settings.model = "fixture";
    settings.toolsEnabled = true;
    settings.quickTitle = false;
    saveSettings(settings);

    // Backpressure can coalesce the start notification with an early stdout
    // chunk before the UI sees either. Preserve that transition and its clock.
    auto client = new OpenCodeClient("http://127.0.0.1:9", "");
    scope(exit) client.closeSession();
    OpenCodeEvent start;
    start.kind = OpenCodeEventKind.toolResult;
    start.toolRunning = true;
    start.toolStarted = true;
    start.requestId = 7;
    start.toolCallId = "quiet";
    start.toolName = "run";
    start.text = "Running command. Waiting for output…";
    client.pushLocalEvent(start);
    auto output = start;
    output.toolStarted = false;
    output.elapsedMs = 12;
    output.text = "hello";
    client.pushLocalEvent(output);
    OpenCodeEvent[] events;
    client.drain(events);
    assert(events.length == 1 && events[0].toolStarted && events[0].elapsedMs == 12 && events[0].text == "hello");
    writeln("PASS coalesced output retains the execution-start transition and elapsed time");

    OpenCodeToolCall[] calls = [
        OpenCodeToolCall("quiet-first", "run", `{"program":"python","args":["-u","-c","import time; time.sleep(0.7)"]}`),
        OpenCodeToolCall("hello-second", "run", `{"program":"python","args":["-u","-c","print('hello')"]}`),
    ];
    auto cancellation = new ToolCancellation();
    scope(exit) cancellation.cancel();
    scheduleToolBatch(client, 8, calls, workspace, cancellation, ChangeContext.init);
    bool firstStarted, secondWaiting, firstFinished, secondStarted;
    size_t completed;
    const deadline = MonoTime.currTime + 8.seconds;
    while (completed < 2 && MonoTime.currTime < deadline)
    {
        client.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.toolResult)
            {
                assert(event.text.indexOf("conversation storage") < 0);
                if (event.toolRunning)
                {
                    if (event.toolCallId == "hello-second" && event.text.indexOf("earlier tools") >= 0)
                        secondWaiting = true;
                    if (event.toolStarted && event.toolCallId == "quiet-first")
                    { firstStarted = true; assert(!firstFinished); }
                    if (event.toolStarted && event.toolCallId == "hello-second")
                    { secondStarted = true; assert(firstFinished); }
                }
                else
                {
                    assert(!event.toolFailed, event.text);
                    if (event.toolCallId == "quiet-first") firstFinished = true;
                    else assert(event.text.indexOf("hello") >= 0);
                    ++completed;
                }
            }
        Thread.sleep(5.msecs);
    }
    assert(completed == 2 && firstStarted && firstFinished && secondWaiting && secondStarted);
    writeln("PASS quiet Python command starts before stdout; the next call waits for the earlier tool and then runs");

    WindowOptions options;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.02);
        root.projectTranscriptForTesting();
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready) pump();
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Run the two fixture commands.", ""]);
    root.injectToolCallsForTesting(calls);
    foreach (call; calls)
        assert(root.liveToolDetailForTesting(call.id).indexOf("conversation storage") < 0);
    bool sawRunning, sawWaiting, screenshotSaved;
    const settled = MonoTime.currTime + 8.seconds;
    while (root.pendingToolResultsForTesting() > 0 && MonoTime.currTime < settled)
    {
        pump();
        const running = root.liveToolDetailForTesting("quiet-first");
        const waiting = root.liveToolDetailForTesting("hello-second");
        sawRunning |= running.indexOf("Running command") >= 0;
        sawWaiting |= waiting.indexOf("earlier tools") >= 0;
        assert(running.indexOf("conversation storage") < 0 && waiting.indexOf("conversation storage") < 0);
        if (!screenshotSaved && running.indexOf("Running command") >= 0 && waiting.indexOf("earlier tools") >= 0)
        {
            window.saveScreenshot("tool-running-status.bmp");
            screenshotSaved = true;
        }
    }
    assert(sawRunning && sawWaiting, "Visible rows did not distinguish running and dependency waiting");
    assert(root.pendingToolResultsForTesting() == 0 && root.toolMessageCountForTesting() == 2);
    assert(root.lastToolResultForTesting().indexOf("hello") >= 0);
    writeln("PASS actual painted chat shows running/dependency stages and settles both calls with real output");
    return 0;
}

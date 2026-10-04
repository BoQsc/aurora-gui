module process_flow_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ChangeContext, ToolCancellation, executeTool;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.utf : validate;

private OpenCodeToolCall program(string id, string code)
{
    JSONValue args;
    args["program"] = "python";
    args["args"] = JSONValue([JSONValue("-u"), JSONValue("-c"), JSONValue(code)]);
    return OpenCodeToolCall(id, "run", args.toString());
}

private bool previewContains(OpenCodeRoot root, string text)
{
    foreach (preview; root.liveToolRowPreviewsForTesting())
        if (preview.indexOf(text) >= 0) return true;
    return false;
}

private void pumpUntil(OpenCodeRoot root, UiTestDriver driver, bool delegate() ready)
{
    const deadline = MonoTime.currTime + 8.seconds;
    while (!ready() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        driver.paint();
        Thread.sleep(20.msecs);
    }
    if (!ready())
    {
        writeln("pending=", root.pendingToolResultsForTesting(), " tools=", root.toolMessageCountForTesting(),
            " result=", root.lastToolResultForTesting(), " previews=", root.liveToolRowPreviewsForTesting());
        foreach (line; root.columnDebugForTesting()) writeln(line);
        assert(false, "Timed out waiting for process flow");
    }
}

int main()
{
    const state = buildPath(tempDir(), "aurora-process-flow-" ~ to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","quickTitle":false,"toolsEnabled":true}`);

    // A stopped batch cannot execute a later mutation, even with a new token
    // already in use by the next batch.
    auto stopped = new ToolCancellation();
    stopped.cancel();
    auto healthy = new ToolCancellation();
    assert(!executeTool(program("healthy", "print('healthy')"), state, healthy).failed);
    const blockedPath = buildPath(state, "cancelled.txt");
    auto blocked = executeTool(OpenCodeToolCall("blocked", "write",
        `{"filePath":"cancelled.txt","content":"must not run"}`), state, stopped);
    assert(blocked.failed && !exists(blockedPath), "Cancelled mutation executed");

    // Observer failures must not strand the process, and previews must arrive
    // while the command is still running, with valid Unicode.
    bool sawEarly;
    const started = MonoTime.currTime;
    auto streamed = executeTool(program("stream",
        "import sys,time; sys.stdout.buffer.write('early 😀世界\\n'.encode()); sys.stdout.flush(); time.sleep(1); print('late')"),
        state, healthy, ChangeContext.init, delegate(string output)
        {
            validate(output);
            if (output.indexOf("early 😀世界") >= 0 &&
                (MonoTime.currTime - started).total!"msecs" < 900) sawEarly = true;
        });
    assert(sawEarly && !streamed.failed && streamed.output.indexOf("late") >= 0,
        "Live output did not precede the completed result");
    auto observerFailure = executeTool(program("observer-failure", "print('still completes')"),
        state, healthy, ChangeContext.init, delegate(string output) { throw new Exception("observer fixture"); });
    assert(!observerFailure.failed, "Observer exception abandoned the command");

    auto large = executeTool(program("large",
        "import sys; sys.stdout.write('START\\n' + 'x'*12000000 + '\\nEND\\n')"), state);
    validate(large.output);
    assert(!large.failed && large.output.length < 30000 &&
        large.output.indexOf("START") >= 0 && large.output.indexOf("END") >= 0,
        "Large output lost its beginning/end or exceeded the bounded preview");
    const marker = "Full output saved to: ";
    const savedAt = large.output.indexOf(marker);
    assert(savedAt >= 0);
    const rest = large.output[cast(size_t) savedAt + marker.length .. $];
    const savedPath = rest[0 .. cast(size_t) rest.indexOf('\n')];
    assert(readText(savedPath).length > 12000000, "Full output was lost");
    writeln("Processes: live Unicode output, bounded large logs, cancellation, observer recovery");

    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    auto driver = new UiTestDriver(window);
    foreach (i; 0 .. 30) { root.tickTree(0.02); driver.paint(); Thread.sleep(10.msecs); }
    root.pauseToolContinuationForTesting();
    root.enableToolsForTesting(state);
    root.newChatForTesting();
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"], ["Run the process"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    auto call = program("ui-stream", "import time; print('visible'+' before completion'); time.sleep(3); print('finished')");
    root.injectToolCallsForTesting([call]);
    writeln("Waiting for first UI output");
    pumpUntil(root, driver, delegate() { return previewContains(root, "visible before completion"); });
    assert(root.pendingToolResultsForTesting() == 1 && root.toolMessageCountForTesting() == 0,
        "Progress was treated as a completed tool result");
    const session = root.currentSessionForTesting();
    root.newChatForTesting();
    root.selectSessionForTesting(session);
    driver.paint();
    assert(previewContains(root, "visible before completion"), "Navigation discarded live output");
    root.rebuildForTesting();
    driver.paint();
    assert(previewContains(root, "visible before completion"), "Rebuild discarded live output");
    window.saveScreenshot("build/process-flow-live.ppm");
    pumpUntil(root, driver, delegate() { return root.pendingToolResultsForTesting() == 0; });
    assert(root.toolMessageCountForTesting() == 1 && root.lastToolResultForTesting().indexOf("finished") >= 0,
        "Command did not report exactly one terminal result");

    root.clickSendButtonForTesting();
    root.newChatForTesting();
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"], ["Cancel this batch"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    auto slow = program("abandoned-process", "import time; print('old worker'+' started'); time.sleep(3)");
    auto abandonedWrite = OpenCodeToolCall("abandoned-write", "write",
        `{"filePath":"abandoned.txt","content":"must not run"}`);
    root.injectToolCallsForTesting([slow, abandonedWrite]);
    writeln("Waiting for abandoned worker output");
    pumpUntil(root, driver, delegate() { return previewContains(root, "old worker started"); });
    root.clickSendButtonForTesting();
    assert(!root.turnBusyForTesting(), "Stop did not release the composer");
    root.addConversationForTesting(["user"], ["Immediately start new work"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.injectToolCallsForTesting([program("replacement", "import time; print('new worker'); time.sleep(1)")]);
    pumpUntil(root, driver, delegate() { return root.pendingToolResultsForTesting() == 0; });
    assert(!exists(buildPath(state, "abandoned.txt")), "New batch resurrected an abandoned mutation");
    assert(root.lastToolResultForTesting().indexOf("new worker") >= 0,
        "Late output replaced the new turn's result");
    root.clickSendButtonForTesting();
    root.shutdownClient();
    writeln("UI: live output survives navigation/rebuild, Stop/resend isolates old workers");
    return 0;
}

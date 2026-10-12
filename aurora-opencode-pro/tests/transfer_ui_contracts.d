module transfer_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.transferprogress;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = "transfer-ui-state-" ~ to!string(MonoTime.currTime.ticks);
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","model":"fixture","toolsEnabled":false}`);
    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope (exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const deadline = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    { root.tickTree(0.02); Thread.sleep(5.msecs); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Move these models and show progress"]);
    auto call = OpenCodeToolCall("large-transfer", "move",
        `{"source":"C:/Models/Qwen.gguf","destinationFolder":"E:/Models"}`);
    root.appendToolRequestBatchForTesting([call]);
    root.seedPendingToolBatchForTesting([call]);
    root.rebuildForTesting();
    TransferProgress progress;
    progress.phase = "Moving";
    progress.path = "C:/Models/Qwen.gguf";
    progress.totalBytes = 14UL * 1024 * 1024 * 1024;
    progress.bytesDone = progress.totalBytes / 2;
    progress.totalFiles = 4;
    progress.filesDone = 2;
    progress.bytesPerSecond = 150 * 1024 * 1024;
    progress.remainingSeconds = 48;
    progress.totalsKnown = true;
    root.injectToolOutputForTesting(call.id, encodeTransferProgress(progress));
    root.tickTree(0.02);
    assert(driver.paint());
    auto fractions = root.liveTransferFractionsForTesting();
    assert(fractions.length == 1 && fractions[0] == 0.5, "Live transfer bar was not projected");
    auto previews = root.liveToolRowPreviewsForTesting();
    assert(previews.length == 1 && previews[0].indexOf("150.0 MiB/s") >= 0 &&
        previews[0].indexOf("48s remaining") >= 0, "Speed and ETA are missing");
    assert(previews[0].indexOf("aurora-transfer") < 0, "Internal progress encoding leaked into UI");
    window.saveScreenshot("build/transfer-progress.ppm");
    root.rebuildForTesting();
    root.tickTree(0.02);
    assert(driver.paint());
    fractions = root.liveTransferFractionsForTesting();
    assert(fractions.length == 1 && fractions[0] == 0.5, "Rebuilding the transcript lost transfer progress");
    assert(root.transcriptRowsSequentialForTesting(), "Progress row overlaps another row");
    progress.totalsKnown = false;
    progress.phase = "Scanning transfer";
    progress.bytesDone = 0;
    root.injectToolOutputForTesting(call.id, encodeTransferProgress(progress));
    root.tickTree(0.02);
    assert(driver.paint());
    assert(root.liveTransferFractionsForTesting().length == 1);
    writeln("Live and collapsed groups paint progress, speed, ETA and unknown-total scanning; projection survives rebuild");
    return 0;
}

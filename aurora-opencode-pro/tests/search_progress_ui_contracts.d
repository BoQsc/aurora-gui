module search_progress_ui_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.searchprogress;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = "search-ui-state-" ~ to!string(MonoTime.currTime.ticks);
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:9","model":"fixture","toolsEnabled":false}`);
    WindowOptions options;
    options.width = 1200; options.height = 800;
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

    foreach (tool; ["grep", "glob", "dshell"])
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Find where the model is loaded and show search activity"]);
        auto call = OpenCodeToolCall("search-" ~ tool, tool,
            tool == "dshell" ? `{"command":"list","path":"C:/Projects/ImageStudio","recursive":true}` :
            `{"pattern":"load_model","path":"C:/Projects/ImageStudio"}`);
        root.appendToolRequestBatchForTesting([call]);
        root.seedPendingToolBatchForTesting([call]);
        root.rebuildForTesting();
        root.tickTree(0.02);
        assert(driver.paint());
        auto row = root.liveToolRowForTesting(call.id);
        assert(row !is null && root.liveSearchCollapsedForTesting(call.id));
        const compactHeight = row.bounds().height;
        const rowOrigin = row.globalOrigin();
        driver.click(Point(rowOrigin.x + 48, rowOrigin.y + 12));
        root.tickTree(0.02); assert(driver.paint());
        assert(!root.liveSearchCollapsedForTesting(call.id) && row.bounds().height > compactHeight,
            "A running search cannot be expanded before progress arrives");
        if (tool != "dshell")
            assert(root.liveToolRowPreviewsForTesting()[0].indexOf("Projects") >= 0,
                "Search request scope is missing before the worker starts");
        SearchProgress progress;
        progress.phase = "Discovering candidate files";
        progress.root = "C:/Projects/ImageStudio";
        progress.path = "C:/Projects/ImageStudio/src/inference.py";
        progress.folder = "C:/Projects/ImageStudio/src";
        progress.query = "load_model";
        progress.filter = "literal, include *.py";
        progress.files = 1248; progress.directories = 82; progress.entries = 1330;
        progress.lines = 56200; progress.bytes = 7 * 1024 * 1024;
        progress.matches = 14; progress.skippedDirectories = 8;
        progress.skippedBinary = 23; progress.skippedLarge = 2;
        progress.elapsedMs = 3400;
        progress.lastActivityMs = 1200;
        progress.latest = ["src/inference.py:42: model = load_model(model_path)",
            "src/inference.py:43: cache = model", "src/inference.py:44: return cache", "src/inference.py:45: # fourth result"];

        progress.candidateFiles = 850;
        root.injectToolOutputForTesting(call.id, encodeSearchProgress(progress));
        root.tickTree(0.02);
        assert(driver.paint());
        assert(root.liveSearchProgressCountForTesting() == 1, tool ~ " has no search activity");
        assert(root.liveSearchFractionsForTesting().length == 0, "Unknown totals must not show a progress bar");
        const previews = root.liveToolRowPreviewsForTesting();
        assert(previews.length == 1 && previews[0].indexOf("1248 files") >= 0 &&
            previews[0].indexOf("14 matches") >= 0 && previews[0].indexOf("load_model(model_path)") >= 0);
        assert(previews[0].indexOf("no new scan activity for 1.2s") >= 0 && previews[0].indexOf("Current:") >= 0);
        assert(previews[0].indexOf("Current folder: C:/Projects/ImageStudio/src") >= 0 &&
            previews[0].indexOf("fourth result") >= 0, "Search folder or partial match list was lost");
        assert(previews[0].indexOf("aurora-search") < 0 && previews[0].indexOf("%") < 0);
        assert(root.transcriptRowsSequentialForTesting(), "Search details overlap transcript rows");
        if (tool == "grep")
        {
            window.saveScreenshot("build/search-discovery.ppm");
            progress.phase = "Searching contents";
            progress.totalsKnown = true;
            progress.candidateFiles = 2000; progress.processedFiles = 1248;
            root.injectToolOutputForTesting(call.id, encodeSearchProgress(progress));
            root.tickTree(0.02);
            assert(driver.paint());
            assert(root.liveSearchFractionsForTesting() == [0.624]);
            assert(root.liveToolRowPreviewsForTesting()[0].indexOf("Processed 1248 of 2000 candidate files · 62% by file") >= 0);
            window.saveScreenshot("build/search-progress.ppm");
            const expandedHeight = row.bounds().height;
            assert(expandedHeight > compactHeight + 100, "Search activity changed without remeasuring the row");
            const origin = row.globalOrigin();
            driver.click(Point(origin.x + 48, origin.y + 12));
            root.tickTree(0.02); assert(driver.paint());
            assert(root.liveSearchCollapsedForTesting(call.id) && row.bounds().height < expandedHeight &&
                root.liveSearchFractionsForTesting() == [0.624],
                "Collapsing a search must keep its measured progress bar");
            driver.click(Point(row.globalOrigin().x + 48, row.globalOrigin().y + 12));
            root.tickTree(0.02); assert(driver.paint());
            foreach (_; 0 .. 20) root.tickTree(0.1);
            assert(driver.paint() && root.liveSearchFractionsForTesting() == [0.624],
                "Time without completed files must not advance measured progress");
        }
        root.rebuildForTesting();
        root.tickTree(0.02);
        assert(driver.paint() && root.liveSearchProgressCountForTesting() == 1);
        assert(!root.liveSearchCollapsedForTesting(call.id), "Individual expansion was lost after a transcript rebuild");
        assert(root.liveSearchFractionsForTesting() == (tool == "grep" ? [0.624] : null));
        progress.phase = "Search paused at checkpoint — more entries remain";
        progress.terminal = progress.partial = true;
        root.injectToolOutputForTesting(call.id, encodeSearchProgress(progress));
        root.tickTree(0.02);
        assert(driver.paint());
        assert(root.liveToolRowPreviewsForTesting()[0].indexOf("more entries remain") >= 0);
        assert(root.liveSearchFractionsForTesting() == (tool == "grep" ? [0.624] : null),
            "Paused progress must keep its actual fraction");
    }
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Inspect four searches independently"]);
    OpenCodeToolCall[] calls;
    foreach (i; 0 .. 4)
        calls ~= OpenCodeToolCall("parallel-" ~ to!string(i), "grep",
            `{"pattern":"needle","path":"C:/Projects/Source"}`);
    root.appendToolRequestBatchForTesting(calls); root.seedPendingToolBatchForTesting(calls);
    root.rebuildForTesting(); root.tickTree(0.02); assert(driver.paint());
    auto firstRow = root.liveToolRowForTesting(calls[0].id);
    driver.click(Point(firstRow.globalOrigin().x + 48, firstRow.globalOrigin().y + 12));
    root.tickTree(0.02); assert(driver.paint());
    assert(!root.liveSearchCollapsedForTesting(calls[0].id) && root.liveSearchCollapsedForTesting(calls[1].id));
    root.rebuildForTesting(); root.tickTree(0.02); assert(driver.paint());
    assert(!root.liveSearchCollapsedForTesting(calls[0].id) && root.liveSearchCollapsedForTesting(calls[1].id));
    assert(root.transcriptRowsSequentialForTesting());
    writeln("PASS independent running search expansion before progress, click handling, size updates, fold state across rebuilds, and four parallel rows");
    writeln("PASS discovery and path listing have no animated bar; grep renders measured progress that survives quiet periods, pause and transcript rebuild");
    return 0;
}

module tests.editor_smoke;

import aurora;
import auroracut.clipboardimage : setClipboardImageProviderForTesting,
    writeDibAsBmpFile;
import auroracut.editor : EditorRoot, InspectorValueField;
import auroracut.model : ClipKind, EditorModel, EffectProperty, TimelineClip,
    TextAlignment, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.project : loadProjectFile;
import auroracut.recentprojects : clearRecentProjects, loadRecentProjects,
    rememberRecentProject, setRecentProjectsFilePathForTesting;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;
import auroracut.util : applicationExportDirectory, projectAutosaveDirectory,
    setApplicationExportDirectoryForTesting, setProjectAutosaveDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
import std.math : fabs, isNaN;
import std.path : baseName, buildPath, dirName;
import std.stdio : writeln;

private Widget findById(Widget root, string requestedId)
{
    if (root is null) return null;
    if (root.id() == requestedId) return root;
    foreach (child; root.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

private size_t countWidgetsOfType(T)(Widget root)
{
    if (root is null) return 0;
    size_t result = cast(T) root !is null ? 1 : 0;
    foreach (child; root.children()) result += countWidgetsOfType!T(child);
    return result;
}

private ContextMenu findOpenContextMenu(Widget root)
{
    if (root is null) return null;
    auto menu = cast(ContextMenu) root;
    if (menu !is null && !menu.dismissed()) return menu;
    foreach (child; root.children())
    {
        menu = findOpenContextMenu(child);
        if (menu !is null) return menu;
    }
    return null;
}

private bool menuHasLabel(ContextMenu menu, dstring label)
{
    if (menu is null) return false;
    foreach (item; menu.items())
        if (!item.separator && item.label == label) return true;
    return false;
}

private bool menuItemChecked(ContextMenu menu, dstring label)
{
    if (menu is null) return false;
    foreach (item; menu.items())
        if (!item.separator && item.label == label) return item.checked;
    return false;
}

private Point menuItemPoint(ContextMenu menu, dstring label)
{
    assert(menu !is null);
    const items = menu.items();
    int y = menu.menuRect().y + 3;
    foreach (index, item; items)
    {
        const height = item.separator ? 4 : menu.rowHeightForTesting();
        if (!item.separator && item.label == label)
            return Point(menu.menuRect().x + 40, y + height / 2);
        y += height;
    }
    assert(false, "Menu item not found for label");
    return Point(0, 0);
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private void assertSequenceTimelineSeparatedFromStatus(SplitPane sequenceSplit,
    TimelineWidget timeline, TimelineHorizontalScrollbar timelineScrollbar,
    Widget statusBar)
{
    auto sequenceArea = sequenceSplit.second();
    const sequenceOrigin = sequenceArea.localToGlobal(Point(0, 0));
    const timelineOrigin = timeline.localToGlobal(Point(0, 0));
    const scrollbarOrigin = timelineScrollbar.localToGlobal(Point(0, 0));
    const statusOrigin = statusBar.localToGlobal(Point(0, 0));
    assert(sequenceOrigin.y + sequenceArea.bounds().height <= statusOrigin.y,
        "Sequence panel overlaps the status bar");
    assert(timelineOrigin.y + timeline.bounds().height <= statusOrigin.y,
        "Sequence timeline overlaps the status bar");
    assert(scrollbarOrigin.y + timelineScrollbar.bounds().height <= statusOrigin.y,
        "Sequence scrollbar overlaps the status bar");
}

private Point mediaRowPoint(ListView list, int index)
{
    const origin = list.localToGlobal(Point(0, 0));
    return Point(origin.x + 70,
        origin.y + index * list.rowHeight() - list.scrollOffset() + list.rowHeight() / 2);
}

private int rowIndexForText(ListView list, dstring text)
{
    const items = list.items();
    foreach (index, item; items)
        if (item.text == text) return cast(int) index;
    return -1;
}

private int rowIndexContaining(ListView list, dstring fragment)
{
    const items = list.items();
    foreach (index, item; items)
        if (item.text.canFind(fragment)) return cast(int) index;
    return -1;
}

private Point clipCenter(TimelineWidget timeline, TrackAddress address, int index)
{
    const rect = timeline.clipRectForTesting(address, index);
    assert(!rect.empty(), "Requested test clip is not visible");
    const origin = timeline.localToGlobal(Point(0, 0));
    return Point(origin.x + rect.x + rect.width / 2,
        origin.y + rect.y + rect.height / 2);
}

private void appendLe16(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte) (value & 0xff);
    data ~= cast(ubyte) ((value >> 8) & 0xff);
}

private void appendLe32(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte) (value & 0xff);
    data ~= cast(ubyte) ((value >> 8) & 0xff);
    data ~= cast(ubyte) ((value >> 16) & 0xff);
    data ~= cast(ubyte) ((value >> 24) & 0xff);
}

private ubyte[] tinyClipboardDib()
{
    ubyte[] dib;
    appendLe32(dib, 40); // BITMAPINFOHEADER
    appendLe32(dib, 2);  // width
    appendLe32(dib, 2);  // height, bottom-up
    appendLe16(dib, 1);  // planes
    appendLe16(dib, 24); // BGR24
    appendLe32(dib, 0);  // BI_RGB
    appendLe32(dib, 16); // two 8-byte rows
    appendLe32(dib, 2835);
    appendLe32(dib, 2835);
    appendLe32(dib, 0);
    appendLe32(dib, 0);

    // Bottom row: blue, white, plus row padding.
    dib ~= [cast(ubyte) 255, 0, 0, 255, 255, 255, 0, 0];
    // Top row: red, green, plus row padding.
    dib ~= [cast(ubyte) 0, 0, 255, 0, 255, 0, 0, 0];
    return dib;
}

private void doubleClickDrag(UiTestDriver driver, Point from, Point to, int steps = 12)
{
    // The second press remains inside Aurora's double-click interval, then is
    // held and moved. This exercises the exact gesture requested by the editor.
    driver.click(from);
    driver.moveTo(from);
    driver.mouseDown();
    foreach (step; 1 .. steps + 1)
    {
        const x = from.x + (to.x - from.x) * step / steps;
        const y = from.y + (to.y - from.y) * step / steps;
        driver.moveTo(Point(x, y));
    }
    driver.mouseUp();
}

private bool waitForMediaCount(EditorRoot editor, ListView mediaList,
    size_t expected, int iterations = 600)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (mediaList.items().length == expected && !editor.importBusyForTesting())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForFrame(EditorRoot editor, PreviewWidget preview,
    double minimumTime, int iterations = 600)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (preview.hasFrame() && preview.frameTime() >= minimumTime) return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForSequencePlayback(EditorRoot editor, PreviewWidget preview)
{
    foreach (_; 0 .. 2_400)
    {
        editor.tickTree(0.02);
        if (editor.sequencePlaybackForTesting() &&
            !editor.playbackAwaitingFirstFrameForTesting() &&
            preview.playing() && preview.hasFrame() &&
            preview.frameTitleForTesting().canFind("Sequence")) return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForPlaybackReady(EditorRoot editor, PreviewWidget preview)
{
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (!editor.playbackAwaitingFirstFrameForTesting() &&
            preview.playing() && preview.hasFrame())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

/// Loop playback advances to `nearEnd`, wraps back below `belowAfter`, and is
/// still running after the wrap.
private bool waitForLoopWrap(EditorRoot editor, double nearEnd, double belowAfter,
    int iterations = 1_800)
{
    bool reachedEnd;
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        const position = editor.playbackPositionForTesting();
        if (position >= nearEnd) reachedEnd = true;
        if (reachedEnd && position <= belowAfter)
            return editor.playbackRunningForTesting();
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForRenderIdle(EditorRoot editor, int iterations = 1_200)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (!editor.renderRunningForTesting()) return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 4,
        "Usage: editor-smoke <base-av.mp4> <overlay.mp4> <audio.mp3>");

    WindowOptions options;
    options.title = "Aurora Cut headless smoke test";
    options.width = 1440;
    options.height = 960;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    const recentPath = buildPath(tempDir(), "aurora-cut-editor-smoke-recent.json");
    const savedProject = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent.auroracut");
    const recentOpenA = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent-open-a.auroracut");
    const recentOpenB = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent-open-b.auroracut");
    const recentDuplicateA = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent-a");
    const recentDuplicateB = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent-b");
    const recentOverflowRoot = buildPath(tempDir(),
        "aurora-cut-editor-smoke-recent-overflow");
    const screenshotPath = buildPath(tempDir(),
        "aurora-cut-editor-smoke-clipboard.bmp");
    const fakeOutputPath = buildPath(tempDir(),
        "aurora-cut-editor-smoke-output.mp4");
    const autosavePath = buildPath(tempDir(),
        "aurora-cut-editor-smoke-autosaves");
    const exportPath = buildPath(tempDir(),
        "aurora-cut-editor-smoke-exports");
    if (exists(recentPath)) remove(recentPath);
    if (exists(savedProject)) remove(savedProject);
    if (exists(recentOpenA)) remove(recentOpenA);
    if (exists(recentOpenB)) remove(recentOpenB);
    if (exists(recentDuplicateA)) rmdirRecurse(recentDuplicateA);
    if (exists(recentDuplicateB)) rmdirRecurse(recentDuplicateB);
    if (exists(recentOverflowRoot)) rmdirRecurse(recentOverflowRoot);
    if (exists(screenshotPath)) remove(screenshotPath);
    if (exists(fakeOutputPath)) remove(fakeOutputPath);
    if (exists(autosavePath)) rmdirRecurse(autosavePath);
    if (exists(exportPath)) rmdirRecurse(exportPath);
    bool fakeClipboardHasImage;
    ulong fakeClipboardSequence = 1;
    setClipboardImageProviderForTesting(
        delegate bool() { return fakeClipboardHasImage; },
        delegate string() { return screenshotPath; },
        delegate ulong() { return fakeClipboardSequence; });
    scope (exit)
    {
        setClipboardImageProviderForTesting(null, null, null);
        setRecentProjectsFilePathForTesting("");
        setProjectAutosaveDirectoryForTesting("");
        setApplicationExportDirectoryForTesting("");
        if (exists(recentPath)) remove(recentPath);
        if (exists(savedProject)) remove(savedProject);
        if (exists(recentOpenA)) remove(recentOpenA);
        if (exists(recentOpenB)) remove(recentOpenB);
        if (exists(recentDuplicateA)) rmdirRecurse(recentDuplicateA);
        if (exists(recentDuplicateB)) rmdirRecurse(recentDuplicateB);
        if (exists(recentOverflowRoot)) rmdirRecurse(recentOverflowRoot);
        if (exists(screenshotPath)) remove(screenshotPath);
        if (exists(fakeOutputPath)) remove(fakeOutputPath);
        if (exists(autosavePath)) rmdirRecurse(autosavePath);
        if (exists(exportPath)) rmdirRecurse(exportPath);
    }
    setRecentProjectsFilePathForTesting(recentPath);
    setProjectAutosaveDirectoryForTesting(autosavePath);
    setApplicationExportDirectoryForTesting(exportPath);
    mkdirRecurse(autosavePath);
    mkdirRecurse(exportPath);
    clearRecentProjects();
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial editor paint failed");
    writeln("[editor-smoke] initial paint");

    auto mediaPanel = requireWidget!Widget(editor, "project-media-panel");
    auto mediaList = requireWidget!ListView(editor, "project-media-list");
    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto timelineScrollbar = requireWidget!TimelineHorizontalScrollbar(editor,
        "sequence-horizontal-scrollbar");
    auto sequenceSplit = requireWidget!SplitPane(editor, "workspace-sequence-split");
    auto statusBar = requireWidget!Widget(editor, "status-bar");
    auto inspectorScroll = requireWidget!ScrollView(editor, "clip-inspector-scroll");
    auto inspectorSourceSection = requireWidget!Widget(editor,
        "inspector-source-section");
    auto scale = requireWidget!InspectorValueField(editor, "clip-scale");
    auto mute = requireWidget!CheckBox(editor, "clip-mute");
    auto gainLabel = requireWidget!Label(editor, "inspector-label-Gain");
    auto gainKey = requireWidget!Button(editor, "inspector-key-Gain");
    auto inlineFont = requireWidget!Button(editor, "preview-inline-font");
    auto inlineSize = requireWidget!TextField(editor, "preview-inline-text-size");
    auto inlineColor = requireWidget!TextField(editor, "preview-inline-color");
    auto inlineBold = requireWidget!Button(editor, "preview-inline-bold");
    auto inlineAlignCenter = requireWidget!Button(editor,
        "preview-inline-align-center");
    auto inspectorAlignRight = requireWidget!Button(editor,
        "clip-text-align-right");
    auto inlineDone = requireWidget!Button(editor, "preview-inline-done");
    auto inspectorTextField = requireWidget!TextField(editor, "clip-text");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playSource = requireWidget!Button(editor, "play-preview");
    auto qualityButton = requireWidget!Button(editor, "preview-quality");
    auto resolutionButton = requireWidget!Button(editor, "composition-resolution");
    auto saveProject = requireWidget!Button(editor, "save-project");
    auto openProject = requireWidget!Button(editor, "open-project");
    auto recentProjects = requireWidget!Button(editor, "recent-projects");
    auto downloadMedia = requireWidget!Button(editor, "download-media-url");
    auto undoButton = requireWidget!Button(editor, "undo");
    auto redoButton = requireWidget!Button(editor, "redo");
    auto revealExport = requireWidget!Button(editor, "reveal-export-output");
    auto compressOutput = requireWidget!Button(editor, "compress-last-output");
    auto addTransitions = requireWidget!Button(editor, "clip-add-transitions");
    auto mp4Compression = requireWidget!Slider(editor, "export-mp4-compression");
    auto mp4CompressionValue = requireWidget!Label(editor,
        "export-mp4-compression-value");
    assert(playSource.text() == "▶"d,
        "Preview transport button must show the play symbol while idle");
    assert(editor.previewQualityHeightForTesting() == 720 &&
        qualityButton.text() == "720p"d,
        "Composition Preview must default to 720p for responsive startup");
    assert(editor.compositionWidthForTesting() == 1920 &&
        editor.compositionHeightForTesting() == 1080 &&
        resolutionButton.text() == "1920×1080"d,
        "MP4 composition/output resolution must default to 1080p");
    assert(openProject.text() == "Open"d &&
        openProject.bounds().x >= saveProject.bounds().right(),
        "Open Project button is not directly to the right of Save");
    assert(recentProjects.text() == "Recent ▾"d &&
        recentProjects.bounds().x >= openProject.bounds().right(),
        "Recent Projects button is not directly to the right of Open");
    assert(downloadMedia.text() == "Download"d,
        "Project Media yt-dlp download button was not created");
    assert(undoButton.text() == "Undo"d && redoButton.text() == "Redo"d &&
        undoButton.bounds().x >= recentProjects.bounds().right() &&
        redoButton.bounds().x >= undoButton.bounds().right(),
        "Global Undo/Redo buttons are not beside the project controls");
    assert(!undoButton.enabled() && !redoButton.enabled(),
        "Global Undo/Redo buttons must start disabled before history exists");
    driver.click(globalCenter(recentProjects));
    auto recentMenu = findOpenContextMenu(editor);
    assert(recentMenu !is null, "Recent Projects button did not open a dropdown");
    assert(recentMenu.menuRect().x == recentProjects.localToGlobal(Point(0, 0)).x &&
        recentMenu.menuRect().y == recentProjects.localToGlobal(
            Point(0, recentProjects.bounds().height)).y + 2,
        "Recent Projects dropdown was not anchored immediately below the button");
    assert(menuHasLabel(recentMenu, "No recent projects"d),
        "Empty Recent Projects dropdown did not explain that there is no history");
    assert(menuHasLabel(recentMenu, "Browse project…"d),
        "Recent Projects dropdown did not include a browse fallback");
    driver.pressKey(Key.escape);
    driver.click(globalCenter(openProject));
    assert(driver.paint(), "Open Project dialog did not paint");
    auto tempAutosaves = requireWidget!Button(editor,
        "open-project-autosaves");
    auto dialogPath = requireWidget!TextField(editor, "file-dialog-path");
    driver.click(globalCenter(tempAutosaves));
    assert(driver.paint(), "Open Project autosaves shortcut did not repaint");
    assert(dialogPath.textUtf8() == projectAutosaveDirectory(),
        "Open Project dialog shortcut did not navigate to the app-state autosaves");
    driver.pressKey(Key.escape);
    assert(!revealExport.enabled() && !editor.revealExportEnabledForTesting(),
        "Export output button must stay disabled until an export completes");
    assert(!compressOutput.enabled() && !editor.compressOutputEnabledForTesting(),
        "Compress previous output button must stay disabled until an MP4 export exists");
    driver.click(globalCenter(resolutionButton));
    assert(driver.paint(), "Composition resolution popup did not paint");
    auto resolutionWidth = requireWidget!TextField(editor,
        "composition-resolution-width");
    auto resolutionHeight = requireWidget!TextField(editor,
        "composition-resolution-height");
    auto resolutionApply = requireWidget!Button(editor,
        "composition-resolution-apply");
    resolutionWidth.setText("854", true);
    resolutionHeight.setText("480", true);
    driver.click(globalCenter(resolutionApply));
    assert(editor.compositionWidthForTesting() == 854 &&
        editor.compositionHeightForTesting() == 480 &&
        resolutionButton.text() == "854×480"d,
        "Custom composition resolution did not apply");
    driver.click(globalCenter(resolutionButton));
    assert(driver.paint(), "Composition resolution restore popup did not paint");
    auto resolutionRestore = requireWidget!Button(editor,
        "composition-resolution-restore");
    driver.click(globalCenter(resolutionRestore));
    assert(editor.compositionWidthForTesting() == 1920 &&
        editor.compositionHeightForTesting() == 1080,
        "Composition resolution restore did not return to 1080p");
    write(fakeOutputPath, "fake mp4 marker");
    editor.setLastExportPathForTesting(fakeOutputPath);
    assert(revealExport.enabled() && editor.revealExportEnabledForTesting() &&
        compressOutput.enabled() && editor.compressOutputEnabledForTesting(),
        "Completed MP4 output did not enable Output and Compress controls");
    driver.click(globalCenter(compressOutput));
    assert(driver.paint(), "Compress previous output popup did not paint");
    auto recompressSlider = requireWidget!Slider(editor, "compress-output-crf");
    auto recompressLabel = requireWidget!Label(editor, "compress-output-crf-value");
    auto recompressStart = requireWidget!Button(editor, "compress-output-start");
    recompressSlider.setValue(31.2);
    assert(recompressLabel.text() == "CRF 31"d &&
        recompressStart.text() == "Compress copy"d,
        "Compress previous output popup did not expose CRF slider and approval button");
    driver.pressKey(Key.escape);
    editor.setLastExportPathForTesting(arguments[1]);
    assert(editor.startCompressLastOutputForTesting(31),
        "Editor-owned previous-output compression did not start");
    assert(waitForRenderIdle(editor),
        "Editor-owned previous-output compression did not finish");
    assert(editor.lastExportPathForTesting() == arguments[1],
        "Compressed MP4 output replaced the remembered normal export path");
    assert(editor.compressOutputEnabledForTesting(),
        "Compress button did not continue remembering the last normal MP4 output");
    mp4Compression.setValue(27.6);
    assert(editor.mp4CompressionCrfForTesting() == 28 &&
        mp4CompressionValue.text() == "CRF 28"d,
        "MP4 compression slider did not update the output CRF");
    assert(findById(editor, "stop-playback") is null,
        "A separate Stop button returned to the transport");
    assert(findById(editor, "import-media") is null,
        "Project Media still contains a redundant visible Import button");
    assert(findById(editor, "add-selected-media") is null,
        "Project Media still contains a redundant Add selected button");
    assert(editor.playbackVideoLagToleranceForTesting() <= 0.080,
        "Playback still allows a visibly desynced video/audio lag window");
    assert(fabs(editor.playbackTransportVisualIntervalForTesting()) < 0.0001,
        "Timeline playhead transport is still throttled instead of tick-smooth");
    assert(inspectorAlignRight !is null,
        "Inspector text alignment controls were not created");
    assert(!inspectorSourceSection.visible(),
        "Source / Timing controls still pollute Effects / Properties");
    assert(countWidgetsOfType!Slider(inspectorScroll) == 0,
        "Effects / Properties still contains long slider controls");
    assert(timelineScrollbar.bounds().height > 0 &&
        timelineScrollbar.bounds().height <= 12,
        "Timeline horizontal scrollbar is not compact");
    assertSequenceTimelineSeparatedFromStatus(sequenceSplit, timeline,
        timelineScrollbar, statusBar);

    {
        editor.saveProjectForTesting(savedProject);
        assert(loadRecentProjects(true).length == 1 &&
            loadRecentProjects(true)[0] == savedProject,
            "Saving a project did not add it to recent projects");

        driver.click(globalCenter(recentProjects));
        recentMenu = findOpenContextMenu(editor);
        assert(recentMenu !is null,
            "Recent Projects dropdown did not open after saving a project");
        assert(menuHasLabel(recentMenu,
            (baseName(savedProject) ~ " — " ~ dirName(savedProject)).to!dstring),
            "Recent Projects dropdown did not show the saved project");
        assert(menuItemChecked(recentMenu,
            (baseName(savedProject) ~ " — " ~ dirName(savedProject)).to!dstring),
            "Recent Projects dropdown did not mark the current project");
        driver.pressKey(Key.escape);

        editor.saveProjectForTesting(recentOpenA);
        editor.saveProjectForTesting(recentOpenB);
        auto openedRecents = loadRecentProjects(true);
        assert(openedRecents.length >= 2 && openedRecents[0] == recentOpenB &&
            openedRecents[1] == recentOpenA,
            "Saving multiple projects did not put the newest project first");
        rememberRecentProject(recentOpenA);
        openedRecents = loadRecentProjects(true);
        assert(openedRecents.length >= 2 && openedRecents[0] == recentOpenA &&
            editor.projectPathForTesting() == recentOpenB,
            "Recent action test could not create a stale stored order");
        driver.click(globalCenter(recentProjects));
        recentMenu = findOpenContextMenu(editor);
        assert(recentMenu !is null,
            "Recent Projects dropdown did not open for action binding test");
        const expectedCurrentRecentLabel =
            (baseName(recentOpenB) ~ " — " ~ dirName(recentOpenB)).to!dstring;
        assert(recentMenu.items().length > 0 &&
            recentMenu.items()[0].label == expectedCurrentRecentLabel,
            "Recent Projects menu did not promote the current project before clicking");
        assert(recentMenu.items()[0].checked,
            "Recent Projects menu did not mark the promoted current project");
        auto menuRect = recentMenu.menuRect();
        driver.click(Point(menuRect.x + 40,
            menuRect.y + 3 + recentMenu.rowHeightForTesting() / 2));
        assert(editor.projectPathForTesting() == recentOpenB,
            "Clicking the first Recent Projects item opened a different project");

        rememberRecentProject(buildPath(tempDir(), "missing-recent.auroracut"));
        driver.click(globalCenter(recentProjects));
        recentMenu = findOpenContextMenu(editor);
        assert(menuHasLabel(recentMenu, "Clear unavailable projects"d),
            "Recent Projects dropdown did not offer cleanup for missing projects");
        driver.pressKey(Key.escape);

        mkdirRecurse(recentDuplicateA);
        mkdirRecurse(recentDuplicateB);
        const duplicatePathA = buildPath(recentDuplicateA,
            "same-name.auroracut");
        const duplicatePathB = buildPath(recentDuplicateB,
            "same-name.auroracut");
        write(duplicatePathA, "{}");
        write(duplicatePathB, "{}");
        clearRecentProjects();
        rememberRecentProject(duplicatePathA);
        rememberRecentProject(duplicatePathB);
        driver.click(globalCenter(recentProjects));
        recentMenu = findOpenContextMenu(editor);
        assert(menuHasLabel(recentMenu, ("same-name.auroracut (" ~
                baseName(recentDuplicateB) ~ ") — " ~ recentDuplicateB).to!dstring),
            "Recent Projects dropdown did not disambiguate the newest duplicate filename");
        assert(menuHasLabel(recentMenu, ("same-name.auroracut (" ~
                baseName(recentDuplicateA) ~ ") — " ~ recentDuplicateA).to!dstring),
            "Recent Projects dropdown did not disambiguate the older duplicate filename");
        driver.pressKey(Key.escape);

        mkdirRecurse(recentOverflowRoot);
        string[] availableOverflowProjects;
        foreach (index; 0 .. 13)
        {
            const folder = buildPath(recentOverflowRoot, "available-" ~
                to!string(index));
            mkdirRecurse(folder);
            const project = buildPath(folder, "overflow.auroracut");
            write(project, "{}");
            rememberRecentProject(project);
            availableOverflowProjects ~= project;
        }
        foreach (index; 0 .. 12)
            rememberRecentProject(buildPath(tempDir(),
                "aurora-cut-editor-smoke-missing-" ~ to!string(index) ~
                ".auroracut"));
        const availableRecents = loadRecentProjects(true);
        assert(availableRecents.length == 12,
            "Missing recent projects suppressed available older projects");
        assert(availableRecents[0] == availableOverflowProjects[$ - 1],
            "Recent Projects available ordering did not keep the newest real project first");
        driver.click(globalCenter(recentProjects));
        recentMenu = findOpenContextMenu(editor);
        assert(menuHasLabel(recentMenu, "Clear unavailable projects"d),
            "Recent Projects dropdown lost cleanup while showing available projects");
        assert(!menuHasLabel(recentMenu, "No recent projects"d),
            "Recent Projects dropdown incorrectly reported empty history while available projects exist");
        driver.pressKey(Key.escape);
    }

    // File dialogs use ListView for the folder/file rows. Its vertical
    // scrollbar must be an input target, not only a painted decoration. The
    // vendored Scrollbar widget pages on a track click and drags only from the
    // thumb, so the probe drives the thumb directly.
    {
        auto dialogList = new ListView();
        dialogList.setBounds(Rect(0, 0, 200, 120));
        dialogList.setRowHeight(30);
        string[] rows;
        foreach (index; 0 .. 20)
            rows ~= "file-" ~ to!string(index);
        dialogList.setStrings(rows);
        auto scrollbar = dialogList.verticalScrollbar();
        assert(scrollbar !is null && scrollbar.scrollable(),
            "File dialog scrollbar is not scrollable for its rows");
        const track = scrollbar.trackRect();
        const thumb = scrollbar.thumbRect();
        assert(!thumb.empty() && thumb.y >= track.y &&
            thumb.bottom() <= track.bottom() && thumb.x >= track.x &&
            thumb.right() <= track.right(),
            "File dialog scrollbar thumb is not inside its track");
        const grab = Point(track.x + track.width / 2,
            thumb.y + maxInt(1, thumb.height / 2));
        Event down;
        down.button = MouseButton.left;
        down.position = grab;
        assert(scrollbar.onMouseDown(down),
            "File dialog scrollbar did not accept mouse-down");
        assert(scrollbar.draggingThumb(),
            "File dialog scrollbar did not enter drag mode");
        assert(dialogList.selectedIndex() < 0,
            "Clicking the file dialog scrollbar selected a file row");
        Event move;
        move.position = Point(track.x + track.width / 2, track.bottom() - 2);
        assert(scrollbar.onMouseMove(move),
            "File dialog scrollbar drag was not followed");
        assert(dialogList.scrollOffset() > 0,
            "Dragging the file dialog scrollbar did not scroll the list");
        Event up;
        up.button = MouseButton.left;
        up.position = move.position;
        assert(scrollbar.onMouseUp(up),
            "File dialog scrollbar did not accept mouse-up");
        assert(!scrollbar.draggingThumb(),
            "File dialog scrollbar did not leave drag mode on mouse-up");
    }

    // The timeline's vertical scrollbar must be a drag target, not only a
    // painted decoration. A wider, interactive thumb lets the user move up and
    // down the sequence directly instead of relying on the mouse wheel.
    {
        auto scrollModel = new EditorModel();
        foreach (lane; 0 .. 4)
        {
            assert(scrollModel.addTrack(
                lane % 2 == 0 ? TrackKind.video : TrackKind.audio) >= 0,
                "Scroll fixture track creation failed");
        }
        auto scrollTimeline = new TimelineWidget(scrollModel);
        scrollTimeline.setBounds(Rect(0, 0, 800, 120));
        assert(scrollTimeline.maxVerticalScrollForTesting() > 0,
            "Vertical scroll fixture did not overflow the viewport");
        const track = scrollTimeline.verticalScrollbarTrackForTesting();
        assert(!track.empty() && track.width >= 10,
            "Timeline vertical scrollbar track is too narrow to grab");
        assert(track.x == scrollTimeline.bounds().width - track.width,
            "Timeline vertical scrollbar is not docked to the right edge");
        const thumbBefore = scrollTimeline.verticalScrollbarThumbForTesting();
        Event down;
        down.button = MouseButton.left;
        down.position = Point(track.x + track.width / 2, thumbBefore.y + 2);
        assert(scrollTimeline.onMouseDown(down),
            "Timeline vertical scrollbar did not accept mouse-down");
        assert(scrollTimeline.draggingVerticalScrollbarForTesting(),
            "Timeline vertical scrollbar did not enter drag mode");
        Event move;
        move.position = Point(track.x + track.width / 2, track.bottom() - 2);
        assert(scrollTimeline.onMouseMove(move),
            "Timeline vertical scrollbar drag was not followed");
        assert(scrollTimeline.verticalScroll() > 0,
            "Dragging the timeline vertical scrollbar did not scroll down");
        Event up;
        up.button = MouseButton.left;
        up.position = move.position;
        assert(scrollTimeline.onMouseUp(up),
            "Timeline vertical scrollbar did not accept mouse-up");
        assert(!scrollTimeline.draggingVerticalScrollbarForTesting(),
            "Timeline vertical scrollbar did not leave drag mode on mouse-up");
        assert(scrollTimeline.verticalScroll() ==
            scrollTimeline.maxVerticalScrollForTesting(),
            "Timeline vertical scrollbar thumb did not reach the bottom");
    }

    // Scrolled rows must be clipped below the ruler. Before the clip a
    // partially scrolled top row painted over the ruler's lower half, so
    // timeline content appeared on top of the ruler while scrolling.
    {
        auto rulerModel = new EditorModel();
        foreach (lane; 0 .. 6)
        {
            assert(rulerModel.addTrack(
                lane % 2 == 0 ? TrackKind.video : TrackKind.audio) >= 0,
                "Ruler-clip fixture track creation failed");
        }
        auto rulerTimeline = new TimelineWidget(rulerModel);
        rulerTimeline.setBounds(Rect(0, 0, 800, 120));
        assert(rulerTimeline.maxVerticalScrollForTesting() > 0,
            "Ruler-clip fixture did not overflow the viewport");
        const rulerTrack = rulerTimeline.verticalScrollbarTrackForTesting();
        const rulerThumb = rulerTimeline.verticalScrollbarThumbForTesting();
        Event down;
        down.button = MouseButton.left;
        down.position = Point(rulerTrack.x + rulerTrack.width / 2,
            rulerThumb.y + 2);
        assert(rulerTimeline.onMouseDown(down));
        Event move;
        move.position = Point(rulerTrack.x + rulerTrack.width / 2,
            rulerTrack.bottom() - 2);
        assert(rulerTimeline.onMouseMove(move));
        Event up;
        up.button = MouseButton.left;
        up.position = move.position;
        assert(rulerTimeline.onMouseUp(up));
        assert(rulerTimeline.verticalScroll() ==
            rulerTimeline.maxVerticalScrollForTesting(),
            "Ruler-clip fixture did not scroll to the bottom");

        auto rulerSurface = new Surface(800, 120);
        auto rulerCanvas = Canvas(rulerSurface);
        rulerTimeline.paintTree(rulerCanvas);
        bool rulerLeaked;
        foreach (y; 0 .. 23)
        {
            const argb = rulerSurface.pixel(700, y);
            if (argb == Color.fromHex(0x1c2027).argb() ||
                argb == Color.fromHex(0x1a2020).argb() ||
                argb == Color.fromHex(0x242930).argb() ||
                argb == Color.fromHex(0x303844).argb())
            {
                rulerLeaked = true;
                break;
            }
        }
        assert(!rulerLeaked,
            "Scrolled timeline row painted over the ruler band");
    }

    // Out-first export marking must create a complete visible zone rather than
    // leaving a lone Out marker and relying on export-time fallback behavior.
    editor.setWorkOutForTesting(4.25);
    assert(editor.hasWorkInForTesting() && editor.hasWorkOutForTesting(),
        "Setting export Out first did not create the implicit In marker");
    assert(fabs(editor.workInForTesting()) < 0.0001 &&
        fabs(editor.workOutForTesting() - 4.25) < 0.0001,
        "Out-first export range did not begin at timeline start");
    editor.clearWorkRangeForTesting();

    // Geometry regression independent of fixture duration: a 60-second title
    // must yield a movable, proportionally sized thumb, and panning must not
    // alter the timeline's pixels-per-second value.
    {
        auto scrollModel = new EditorModel();
        assert(scrollModel.insertTextClip(TrackAddress(TrackKind.video, 0),
            0.0, 60.0, "Scrollbar probe") >= 0);
        auto scrollTimeline = new TimelineWidget(scrollModel);
        scrollTimeline.setBounds(Rect(0, 0, 800, 180));
        scrollTimeline.setZoom(100.0);
        auto scrollProbe = new TimelineHorizontalScrollbar(scrollTimeline);
        scrollProbe.setBounds(Rect(0, 0, 800, 11));
        const zoomBeforePan = scrollTimeline.pixelsPerSecond();
        assert(scrollTimeline.horizontalScrollMaximum() > 0.0);
        scrollTimeline.setHorizontalScroll(
            scrollTimeline.horizontalScrollMaximum() * 0.5);
        const scrollTrack = scrollProbe.trackRectForTesting();
        const scrollThumb = scrollProbe.thumbRectForTesting();
        assert(scrollThumb.width < scrollTrack.width,
            "Horizontal scrollbar thumb does not represent visible duration");
        assert(scrollThumb.x > scrollTrack.x,
            "Horizontal scrollbar thumb did not follow timeline panning");
        assert(fabs(scrollTimeline.pixelsPerSecond() - zoomBeforePan) < 0.0001,
            "Horizontal panning unexpectedly changed timeline zoom");
    }

    // Timeline items snap their start/end edges to the playhead when close.
    // This includes edge-resize previews, not only full-clip drag ghosts.
    {
        auto snapModel = new EditorModel();
        const snapTrack = TrackAddress(TrackKind.video, 0);
        assert(snapModel.insertTextClip(snapTrack, 0.0, 2.0,
            "Snap probe") >= 0);
        auto snapTimeline = new TimelineWidget(snapModel);
        snapTimeline.setBounds(Rect(0, 0, 800, 180));
        snapTimeline.setZoom(100.0);
        snapTimeline.setPlayhead(1.20, false);

        const startSnap = snapTimeline.snappedStartForTesting(1.13,
            0.30, snapTrack);
        assert(fabs(startSnap - snapTimeline.playhead()) < 0.0001,
            "Timeline item start did not snap to nearby playhead");

        const endSnap = snapTimeline.snappedStartForTesting(0.88,
            0.30, snapTrack);
        assert(fabs(endSnap + 0.30 - snapTimeline.playhead()) < 0.0001,
            "Timeline item end did not snap to nearby playhead");

        const resizeSnap = snapTimeline.snappedEdgeForTesting(1.11,
            0.05, 2.0, snapTrack);
        assert(fabs(resizeSnap - snapTimeline.playhead()) < 0.0001,
            "Timeline item edge resize did not snap to nearby playhead");

        snapTimeline.setSnappingEnabled(false);
        const unsnapped = snapTimeline.snappedStartForTesting(1.13,
            0.30, snapTrack);
        assert(fabs(unsnapped - 1.13) < 0.0001,
            "Disabling timeline snapping did not bypass playhead snapping");
    }

    // Items snap to the work-area In/Out markers, the other vertical guide
    // lines drawn in the timeline, for both their start and their tail.
    {
        auto markerModel = new EditorModel();
        const markerTrack = TrackAddress(TrackKind.video, 0);
        assert(markerModel.insertTextClip(markerTrack, 0.0, 1.0,
            "Marker probe") >= 0);
        auto markerTimeline = new TimelineWidget(markerModel);
        markerTimeline.setBounds(Rect(0, 0, 800, 180));
        markerTimeline.setZoom(100.0);
        markerTimeline.setPlayhead(8.0, false);
        markerTimeline.setWorkArea(true, 3.0, true, 5.0);

        const inSnap = markerTimeline.snappedStartForTesting(3.10,
            0.5, markerTrack);
        assert(fabs(inSnap - 3.0) < 0.0001,
            "Timeline item start did not snap to the work-area In marker");
        const outSnap = markerTimeline.snappedStartForTesting(4.95,
            0.5, markerTrack);
        assert(fabs(outSnap - 5.0) < 0.0001,
            "Timeline item start did not snap to the work-area Out marker");
        const tailIn = markerTimeline.snappedStartForTesting(2.45,
            0.5, markerTrack);
        assert(fabs(tailIn + 0.5 - 3.0) < 0.0001,
            "Timeline item tail did not snap to the work-area In marker");
        const tailOut = markerTimeline.snappedStartForTesting(4.45,
            0.5, markerTrack);
        assert(fabs(tailOut + 0.5 - 5.0) < 0.0001,
            "Timeline item tail did not snap to the work-area Out marker");
        const edgeSnap = markerTimeline.snappedEdgeForTesting(4.95,
            0.05, 8.0, markerTrack);
        assert(fabs(edgeSnap - 5.0) < 0.0001,
            "Timeline edge resize did not snap to the work-area Out marker");
    }

    // Items snap to clip edges on other tracks too, not only their own row.
    {
        auto crossModel = new EditorModel();
        const crossV1 = TrackAddress(TrackKind.video, 0);
        const crossV2 = TrackAddress(TrackKind.video, 1);
        assert(crossModel.addTrack(TrackKind.video) >= 0);
        assert(crossModel.insertTextClip(crossV1, 0.0, 2.0,
            "Lower row") >= 0);
        assert(crossModel.insertTextClip(crossV2, 4.0, 2.0,
            "Upper row") >= 0);
        auto crossTimeline = new TimelineWidget(crossModel);
        crossTimeline.setBounds(Rect(0, 0, 800, 180));
        crossTimeline.setZoom(100.0);
        crossTimeline.setPlayhead(9.0, false);

        const crossStart = crossTimeline.snappedStartForTesting(3.90,
            1.0, crossV1);
        assert(fabs(crossStart - 4.0) < 0.0001,
            "Timeline item start did not snap to a clip edge on another track");
        const crossTail = crossTimeline.snappedStartForTesting(2.85,
            1.0, crossV1);
        assert(fabs(crossTail + 1.0 - 4.0) < 0.0001,
            "Timeline item tail did not snap to a clip edge on another track");
        const crossEdge = crossTimeline.snappedEdgeForTesting(4.05,
            0.05, 8.0, crossV1);
        assert(fabs(crossEdge - 4.0) < 0.0001,
            "Timeline edge resize did not snap to a clip edge on another track");
    }

    // While a drag is snapped, a bright guide rule points at the marker and
    // disappears once the pointer is released. Snap to the work-area In marker
    // (3.0s) rather than the playhead, because the composited playhead layer
    // is painted above the base scene and covers the guide at its own X.
    {
        auto guideModel = new EditorModel();
        const guideTrack = TrackAddress(TrackKind.video, 0);
        assert(guideModel.insertTextClip(guideTrack, 0.0, 2.0,
            "Guide probe") >= 0);
        auto guideTimeline = new TimelineWidget(guideModel);
        guideTimeline.setBounds(Rect(0, 0, 800, 180));
        guideTimeline.setZoom(100.0);
        guideTimeline.setPlayhead(8.0, false);
        guideTimeline.setWorkArea(true, 3.0, false, 0.0);
        assert(isNaN(guideTimeline.snapGuideTimeForTesting()),
            "Timeline snap guide was visible before any drag");

        const guideRect = guideTimeline.clipRectForTesting(guideTrack, 0);
        const guideY = guideRect.y + guideRect.height / 2;
        // Press at t=0.50 (a 0.50s grab offset), then drag the clip start near
        // the 3.0s In marker so the ghost snaps onto it.
        const pressX = guideTimeline.timeOriginXForTesting() +
            cast(int) (0.50 * guideTimeline.pixelsPerSecond() + 0.5);
        Event down;
        down.button = MouseButton.left;
        down.position = Point(pressX, guideY);
        assert(guideTimeline.onMouseDown(down),
            "Snap-guide fixture could not press the clip");
        Event move;
        move.position = Point(guideTimeline.timeOriginXForTesting() +
            cast(int) (3.55 * guideTimeline.pixelsPerSecond() + 0.5), guideY);
        assert(guideTimeline.onMouseMove(move),
            "Snap-guide fixture drag was not followed");
        assert(guideTimeline.draggingClip(),
            "Snap-guide fixture did not enter clip drag mode");
        assert(fabs(guideTimeline.snapGuideTimeForTesting() - 3.0) < 0.0001,
            "Timeline snap guide did not point at the In marker while snapping");

        auto guideSurface = new Surface(800, 180);
        auto guideCanvas = Canvas(guideSurface);
        guideTimeline.paintTree(guideCanvas);
        const guideLineX = guideTimeline.timeOriginXForTesting() +
            cast(int) (3.0 * guideTimeline.pixelsPerSecond() + 0.5);
        const guidePixel = guideSurface.pixel(guideLineX, 26);
        const guideRed = (guidePixel >> 16) & 0xff;
        const guideGreen = (guidePixel >> 8) & 0xff;
        const guideBlue = guidePixel & 0xff;
        assert(guideRed > 120 && guideGreen > 120 && guideBlue > 120,
            "Timeline snap guide rule was not painted while snapping");

        Event up;
        up.button = MouseButton.left;
        up.position = move.position;
        assert(guideTimeline.onMouseUp(up),
            "Snap-guide fixture did not accept mouse-up");
        assert(isNaN(guideTimeline.snapGuideTimeForTesting()),
            "Timeline snap guide remained visible after mouse-up");
    }

    // Regression: V1/A1 row paint must never erase the Cut and Text buttons
    // in the permanent tool rail. This reproduces the exact Windows screenshot
    // where only the selected S button remained visible.
    {
        auto snapshot = window.surface();
        const origin = timeline.localToGlobal(Point(0, 0));
        const pitch = snapshot.width();
        const expected = Color.fromHex(0x2a3038).argb();
        const cutPoint = window.displayScale().logicalToPhysical(
            Point(origin.x + 6, origin.y + 30));
        const textPoint = window.displayScale().logicalToPhysical(
            Point(origin.x + 6, origin.y + 52));
        const cutPixel = snapshot.pixels()[cast(size_t) cutPoint.y * pitch + cutPoint.x];
        const textPixel = snapshot.pixels()[cast(size_t) textPoint.y * pitch + textPoint.x];
        assert(cutPixel == expected, "V1 row erased the Cut tool button");
        assert(textPixel == expected, "A1 row erased the Text tool button");
    }
    const timelineToolOrigin = timeline.localToGlobal(Point(0, 0));
    driver.moveTo(Point(timelineToolOrigin.x + 12, timelineToolOrigin.y + 34));
    assert(driver.paint());
    assert(timeline.hoveredToolForTesting() == 1,
        "Cut tool hover did not expose its tooltip");
    driver.moveTo(Point(timelineToolOrigin.x + 140, timelineToolOrigin.y + 120));

    writeln("[editor-smoke] sequence tool rail visible");

    // Exercise the same hit-test/bubbling path used by native WM_DROPFILES.
    auto importWatch = StopWatch(AutoStart.yes);
    driver.dropFiles(globalCenter(mediaPanel),
        [arguments[1], arguments[2], arguments[3], arguments[1], arguments[1] ~ ".txt"]);
    importWatch.stop();
    assert(importWatch.peek.total!"msecs" < 500,
        "Explorer-style drop synchronously waited for FFprobe");
    assert(waitForMediaCount(editor, mediaList, 3),
        "Explorer-style background import did not produce three unique files");
    writeln("[editor-smoke] file drop");

    // The context menu's top-left corner must be immediately beside the pointer.
    const mediaContextPoint = mediaRowPoint(mediaList, 0);
    driver.rightClick(mediaContextPoint);
    auto mediaMenu = findOpenContextMenu(editor);
    assert(mediaMenu !is null, "Project Media right-click did not open a context menu");
    const mediaMenuRect = mediaMenu.menuRect();
    assert(mediaMenuRect.x == mediaContextPoint.x + 2 &&
        mediaMenuRect.y == mediaContextPoint.y + 2,
        "Context menu top-left was not anchored beside the mouse cursor");
    assert(mediaMenu.rowHeightForTesting() == 22 && mediaMenuRect.width <= 280,
        "Context menu did not use the compact editor dimensions");
    assert(menuHasLabel(mediaMenu, "Add to V1"d));
    assert(menuHasLabel(mediaMenu, "Place on new video track at playhead"d));
    assert(menuHasLabel(mediaMenu, "Download with yt-dlp…"d),
        "Project Media context menu is missing yt-dlp import");
    assert(!menuHasLabel(mediaMenu, "Open project…"d),
        "Project Media context menu still exposes Open Project");
    assert(!menuHasLabel(mediaMenu, "Play source in Preview"d),
        "Composition Preview exposed a competing source-player command");
    assert(menuHasLabel(mediaMenu, "Show in File Explorer"d));
    driver.pressKey(Key.escape);
    assert(mediaMenu.dismissed());

    const v1 = TrackAddress(TrackKind.video, 0);
    const a1 = TrackAddress(TrackKind.audio, 0);

    // Drag Project Media directly to the existing V1/A1 tracks.
    driver.drag(mediaRowPoint(mediaList, 0), timeline.pointForTrackTime(v1, 0.05), 16);
    assert(editor.modelForTesting().trackValue(v1).clips.length == 1,
        "Project Media drag did not create a V1 clip");
    assert(fabs(editor.modelForTesting().trackValue(v1).clips[0].start) < 0.0001,
        "The first sequence clip did not snap to 00:00:00");
    assert(undoButton.enabled() && !redoButton.enabled(),
        "Global Undo button did not enable after adding a sequence item");
    driver.click(globalCenter(undoButton));
    assert(editor.modelForTesting().trackValue(v1).clips.length == 0,
        "Global Undo button did not revert the added sequence item");
    assert(redoButton.enabled(),
        "Global Redo button did not enable after undo");
    driver.click(globalCenter(redoButton));
    assert(editor.modelForTesting().trackValue(v1).clips.length == 1,
        "Global Redo button did not restore the sequence item");
    assert(undoButton.enabled() && !redoButton.enabled(),
        "Global Undo/Redo button state was wrong after redo");

// Undo/Redo history popup: the toolbar History button opens a standard flat,
    // numbered list of the timeline actions with the current state highlighted.
    // Clicking an entry jumps straight to that state WITHOUT reordering rows.
    auto historyButton = requireWidget!Button(editor, "history");
    assert(historyButton.text() == "History ▾"d &&
        historyButton.bounds().x >= redoButton.bounds().right(),
        "History button is not directly to the right of Redo");
    driver.click(globalCenter(historyButton));
    assert(driver.paint(), "History popup did not paint");
    auto historyList = requireWidget!ListView(editor, "history-list");
    auto historyHint = requireWidget!Label(editor, "history-hint");
    // The list is a flat chronological history: an Initial state row, then the
    // numbered actions oldest-first, with the current (last, no redo) row
    // highlighted as "You are here".
    assert(rowIndexForText(historyList, "Initial state"d) == 0,
        "History popup did not begin with the Initial state row");
    const setRangeRow = rowIndexContaining(historyList, "Set export range out"d);
    const clearRangeRow = rowIndexContaining(historyList, "Clear export range"d);
    const placeClipRow = rowIndexContaining(historyList, "Place clip"d);
    assert(setRangeRow == 1 && clearRangeRow == 2 && placeClipRow == 3,
        "History popup did not list the actions oldest-first with numbers");
    const currentRow = historyList.selectedIndex();
    assert(currentRow == placeClipRow &&
        currentRow == cast(int) historyList.items().length - 1 &&
        historyList.items()[cast(size_t) currentRow].secondary == "You are here"d,
        "History popup did not highlight the current state");
    assert(historyList.items()[cast(size_t) setRangeRow].secondary ==
        "Click to undo 2 steps"d &&
        historyList.items()[cast(size_t) clearRangeRow].secondary ==
            "Click to undo 1 step"d &&
        historyList.items()[0].secondary == "Click to undo 3 steps"d,
        "History popup did not describe the exact undo step counts");
    assert(historyHint.text().canFind("Undo: "d) &&
        historyHint.text().canFind("Redo: 0 available"d),
        "History popup hint did not report the available undo/redo counts");
    // Snapshot the row order so we can prove clicks never reorder the list.
    dstring[] rowsBefore;
    foreach (item; historyList.items()) rowsBefore ~= item.text;
    // Clicking a past entry undoes straight back to the empty timeline.
    driver.click(mediaRowPoint(historyList, clearRangeRow));
    assert(editor.modelForTesting().trackValue(v1).clips.length == 0,
        "Clicking a past history entry did not undo to that state");
    assert(historyList.selectedIndex() == clearRangeRow &&
        historyList.items()[cast(size_t) clearRangeRow].secondary == "You are here"d,
        "History popup did not highlight the jumped-to state");
    assert(historyList.items()[cast(size_t) placeClipRow].secondary ==
        "Click to redo 1 step"d,
        "History popup did not restyle the future entry as a redo target");
    dstring[] rowsAfterUndo;
    foreach (item; historyList.items()) rowsAfterUndo ~= item.text;
    assert(rowsAfterUndo == rowsBefore,
        "Clicking a history entry reordered the list");
    assert(redoButton.enabled(),
        "History jump did not move the clip state into the redo stack");
    assert(historyHint.text().canFind("Redo: 1 available"d),
        "History popup hint did not update after the undo jump");
    // Clicking the future entry redoes straight back to the placed clip.
    driver.click(mediaRowPoint(historyList, placeClipRow));
    assert(editor.modelForTesting().trackValue(v1).clips.length == 1,
        "Clicking a future history entry did not redo to that state");
    assert(historyList.selectedIndex() == placeClipRow &&
        historyList.items()[cast(size_t) placeClipRow].secondary == "You are here"d,
        "History popup did not highlight the restored current state");
    dstring[] rowsAfterRedo;
    foreach (item; historyList.items()) rowsAfterRedo ~= item.text;
    assert(rowsAfterRedo == rowsBefore,
        "Clicking a future history entry reordered the list");
    assert(undoButton.enabled() && !redoButton.enabled(),
        "History jump did not restore the clip state to the undo stack");
    driver.pressKey(Key.escape);
    assert(findById(editor, "history-list") is null,
        "Esc did not dismiss the History popup");

    // The Export dialog defaults its folder to the app-state Exports folder
    // so rendered output lands in a stable per-user location.
    driver.click(globalCenter(requireWidget!Button(editor, "export-mp4")));
    assert(driver.paint(), "Export dialog did not paint");
    auto exportDialogPath = requireWidget!TextField(editor, "file-dialog-path");
    assert(exportDialogPath.textUtf8() == applicationExportDirectory(),
        "Export dialog did not default to the app-state Exports folder");
    driver.pressKey(Key.escape);
    assert(findById(editor, "file-dialog-path") is null,
        "Esc did not dismiss the Export dialog");

    // Regression: the first clip must keep the timeline viewport anchored at
    // sequence zero. Previously transport auto-follow silently scrolled the
    // ruler to ~00:00:16, making the clipped V1 body look as though it began
    // there even though its real start remained 00:00:00.
    assert(timeline.fitViewForTesting(),
        "The first sequence clip did not enable the default fit view");
    const fitPlayhead = editor.modelForTesting().sequenceDuration() * 0.65;
    timeline.setPlayhead(fitPlayhead, false);
    assert(fabs(timeline.scrollSecondsForTesting()) < 0.0001,
        "Fit view auto-scrolled away from sequence zero");
    assert(fabs(timeline.timeAtXForTesting(timeline.timeOriginXForTesting())) < 0.0001,
        "Timeline zero origin no longer maps to 00:00:00");

    driver.click(globalCenter(resolutionButton));
    assert(driver.paint(), "Composition resolution match popup did not paint");
    auto resolutionMatch = requireWidget!Button(editor,
        "composition-resolution-match-content");
    driver.click(globalCenter(resolutionMatch));
    assert(editor.compositionWidthForTesting() == 320 &&
        editor.compositionHeightForTesting() == 180,
        "Composition resolution did not match the visible video content");
    editor.setCompositionResolutionForTesting(1920, 1080);

    // A timeline item's own resolution can become the sequence resolution from
    // its context menu. MP4 output follows automatically because export uses
    // the same composition canvas.
    driver.rightClick(clipCenter(timeline, v1, 0));
    auto clipResolutionMenu = findOpenContextMenu(editor);
    assert(clipResolutionMenu !is null,
        "Timeline item right-click did not open a context menu");
    assert(menuHasLabel(clipResolutionMenu, "Set sequence resolution to 320×180"d),
        "Timeline item context menu is missing the sequence-resolution command");
    driver.pressKey(Key.escape);
    assert(clipResolutionMenu.dismissed());
    editor.matchClipResolutionForTesting(v1, 0);
    assert(editor.compositionWidthForTesting() == 320 &&
        editor.compositionHeightForTesting() == 180,
        "Matching the sequence resolution to a clip did not apply its canvas");
    editor.setCompositionResolutionForTesting(1920, 1080);

    const selectionPlayheadBefore = timeline.playhead();
    driver.click(clipCenter(timeline, v1, 0));
    assert(fabs(timeline.playhead() - selectionPlayheadBefore) < 0.0001,
        "Selecting a timeline item moved the playhead");

    // Every tool must leave the ruler usable as the single timeline transport
    // surface. This guards the former inconsistency where Cut/Text could trap
    // the playhead or redirect Composition Preview away from sequence time.
    {
        const origin = timeline.localToGlobal(Point(0, 0));
        const cutTool = Point(origin.x + 12, origin.y + 34);
        const textTool = Point(origin.x + 12, origin.y + 56);
        const selectTool = Point(origin.x + 12, origin.y + 12);
        const rulerX1 = timeline.timeOriginXForTesting() +
            cast(int) (0.55 * timeline.pixelsPerSecond());
        const rulerX2 = timeline.timeOriginXForTesting() +
            cast(int) (0.85 * timeline.pixelsPerSecond());
        driver.click(cutTool);
        driver.click(Point(origin.x + rulerX1, origin.y + 8));
        assert(fabs(timeline.playhead() - timeline.timeAtXForTesting(rulerX1)) < 0.02,
            "Cut tool prevented ruler playhead movement");
        driver.click(textTool);
        driver.click(Point(origin.x + rulerX2, origin.y + 8));
        assert(fabs(timeline.playhead() - timeline.timeAtXForTesting(rulerX2)) < 0.02,
            "Text tool prevented ruler playhead movement");
        driver.click(selectTool);
    }

    // The normal one-video sequence must play from the original source
    // immediately. It must not start a full composition render merely because
    // the clip was copied from Project Media to V1.
    timeline.setSelection(v1, 0);
    assert(driver.paint());
    assert(gainLabel.visible() && gainLabel.bounds().height >= 20,
        "Inspector property names collapsed to zero height");
    assert(gainKey.visible() && gainKey.text() == "◇ Key"d,
        "Per-item keyframe control is not visibly labeled");
    enum double directTrimIn = 0.35;
    assert(editor.modelForTesting().setTrimIn(v1, 0, directTrimIn),
        "Direct playback regression setup could not trim the V1 source in-point");
    timeline.modelChanged();
    const playbackLaunchPosition = timeline.playhead();
    assert(playbackLaunchPosition > 0.1,
        "The scrubber-origin regression test requires a non-zero launch position");
    const audioStatsBeforeDirectPlayback = editor.audioStatsForTesting();
    driver.click(globalCenter(playSource));
    assert(editor.directSequencePlaybackForTesting(),
        "Plain V1 playback did not use direct source passthrough");
    // Regression for the Windows screenshot: Play was pressed at a non-zero
    // sequence position, but the Preview scrubber treated that position as its
    // own zero and stayed visually at the far-left edge. Sequence playback and
    // the red timeline playhead must share one absolute 00:00:00-based range.
    assert(fabs(editor.playbackStartForTesting()) < 0.0001,
        "Sequence playback redefined its origin at the launch playhead");
    assert(fabs(editor.scrubMinimumForTesting()) < 0.0001,
        "Preview scrubber is not anchored at sequence 00:00:00");
    assert(fabs(editor.scrubValueForTesting() - playbackLaunchPosition) < 0.02,
        "Preview scrubber does not match the red timeline playhead");
    assert(fabs(editor.scrubMaximumForTesting() -
        editor.modelForTesting().sequenceDuration()) < 0.02,
        "Preview scrubber does not cover the complete sequence duration");
    assert(!editor.renderRunningForTesting(),
        "Plain V1 playback unexpectedly started a composition render");
    assert(editor.playbackAwaitingFirstFrameForTesting() && !preview.playing(),
        "Direct V1 playback bypassed first-frame preroll");
    // Audio is now started PAUSED concurrently with the video decoder so the
    // press-Play-to-sound latency overlaps the video spawn instead of
    // serializing behind it. The transport must still gate presentation on the
    // first prerolled frame: the audio request may already exist (paused), but
    // playback must not be presenting before that frame.
    assert(editor.audioStatsForTesting().requests >
        audioStatsBeforeDirectPlayback.requests,
        "Direct Composition Preview did not start audio concurrently (paused) with the video decoder");
    assert(editor.playbackAwaitingFirstFrameForTesting() && !preview.playing(),
        "Direct V1 playback presented before the first prerolled frame");
    assert(waitForFrame(editor, preview, 0.0, 600),
        "Direct V1 playback did not produce an embedded frame");
    assert(waitForPlaybackReady(editor, preview),
        "Direct V1 playback never locked audio/video playback");
    assert(editor.playbackPositionForTesting() <
        playbackLaunchPosition + directTrimIn - 0.07,
        "Direct Composition Preview used source trim time as the timeline audio clock");
    assert(editor.audioStatsForTesting().requests >
        audioStatsBeforeDirectPlayback.requests,
        "Direct Composition Preview did not request preview audio");

    // Regression: a video decoder that reaches the end of its range must never
    // halt playback with "Video decoder ended before the next frame was ready".
    // The transport no longer pauses to buffer when the decoder lags — it keeps
    // the transport clock running, drains the queued tail frames, and completes
    // at the sequence end. Let the direct stream decode its whole range, then
    // confirm the finished decoder leaves the transport running to the end.
    bool decoderEnded;
    foreach (_; 0 .. 2_000)
    {
        editor.tickTree(0.02);
        if (editor.videoStreamFinishedForTesting())
        {
            decoderEnded = true;
            break;
        }
        if (!editor.playbackRunningForTesting()) break;
        Thread.sleep(2.msecs);
    }
    assert(decoderEnded,
        "Direct video decoder never reached the end of its range");
    assert(editor.playbackRunningForTesting(),
        "Playback finished before the completed decoder could be observed");
    bool completed;
    foreach (_; 0 .. 800)
    {
        editor.tickTree(0.02);
        if (editor.playbackPositionForTesting() >=
            editor.playbackEndForTesting() - 0.03)
        {
            completed = true;
            break;
        }
        if (!editor.playbackRunningForTesting()) break;
        Thread.sleep(5.msecs);
    }
    assert(completed,
        "Playback halted before the sequence end after the video stream ended");
    assert(!editor.statusTextForTesting().canFind(
        "Video decoder ended before the next frame was ready"),
        "A finished video decoder spuriously reported a playback failure");
    driver.pressKey(Key.escape);

    // Background prewarm: after the playhead settles while paused, the editor
    // starts decoding the exact stream Play would use, and pressing Play
    // adopts that stream instead of spawning another FFmpeg process. This is
    // what makes Play feel immediate.
    timeline.setPlayhead(0.45, true);
    editor.tickTree(0.02);
    const videoProcessesBeforePrewarm =
        editor.videoStatsForTesting().processesStarted;
    const audioProcessesBeforePrewarm =
        editor.audioStatsForTesting().processesStarted;
    bool prewarmStarted;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.playbackPrewarmActiveForTesting())
        {
            prewarmStarted = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(prewarmStarted,
        "Paused playhead movement did not start a background playback prewarm");
    // The prewarm enqueues the request immediately but spawns its FFmpeg
    // processes on the worker thread; wait for them to appear.
    bool videoPrewarmed;
    bool audioPrewarmed;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.videoStatsForTesting().processesStarted >
            videoProcessesBeforePrewarm)
            videoPrewarmed = true;
        if (editor.audioStatsForTesting().processesStarted >
            audioProcessesBeforePrewarm)
            audioPrewarmed = true;
        if (videoPrewarmed && audioPrewarmed) break;
        Thread.sleep(10.msecs);
    }
    assert(videoPrewarmed,
        "The playback prewarm did not spawn a video decoder");
    assert(audioPrewarmed,
        "The playback prewarm did not spawn a paused audio decoder");
    bool framesBuffered;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.videoStreamHasReadyFramesForTesting())
        {
            framesBuffered = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(framesBuffered,
        "The playback prewarm never buffered video frames");
    const videoProcessesBeforePlay =
        editor.videoStatsForTesting().processesStarted;
    const audioProcessesBeforePlay =
        editor.audioStatsForTesting().processesStarted;
    driver.click(globalCenter(playSource));
    assert(editor.directSequencePlaybackForTesting(),
        "Prewarmed Play did not use direct source passthrough");
    assert(waitForPlaybackReady(editor, preview),
        "Prewarmed Play did not reach the running transport");
    assert(editor.videoStatsForTesting().processesStarted ==
        videoProcessesBeforePlay,
        "Prewarmed Play spawned a new video decoder instead of adopting the warm stream");
    assert(editor.audioStatsForTesting().processesStarted ==
        audioProcessesBeforePlay,
        "Prewarmed Play spawned a new audio decoder instead of adopting the warm stream");
    driver.pressKey(Key.escape);

    driver.rightClick(globalCenter(preview));
    auto previewMenu = findOpenContextMenu(editor);
    assert(previewMenu !is null && menuHasLabel(previewMenu, "Add text"d),
        "Composition Preview context menu is missing Add text");
    driver.pressKey(Key.escape);

    driver.dropFiles(timeline.pointForTrackTime(a1, 0.10), [arguments[3]]);
    foreach (_; 0 .. 30) editor.tickTree(0.02);
    assert(editor.modelForTesting().trackValue(a1).clips.length == 1,
        "Windows Explorer-style drop directly on A1 did not create an audio clip");

    // Dropping on the top edge creates V2 without adding permanent UI clutter.
    driver.drag(mediaRowPoint(mediaList, 1),
        timeline.newTrackDropPointForTesting(TrackKind.video, 0.20), 18);
    const v2 = TrackAddress(TrackKind.video, 1);
    assert(editor.modelForTesting().trackCount(TrackKind.video) == 2);
    assert(editor.modelForTesting().trackValue(v2).clips.length == 1,
        "Edge drop did not create V2 and place the overlay");

    writeln("[editor-smoke] project media drops");

    // A held second click can move the clip both horizontally and into a new V3.
    // Use a real grab point near the clip's start. Grabbing the visual center
    // of a long clip preserves a many-second grab offset and correctly clamps
    // the moved item to zero when the pointer is dragged back near the origin.
    const v2Start = timeline.pointForTrackTime(v2, 0.55);
    const v3Drop = timeline.newTrackDropPointForTesting(TrackKind.video, 0.90);
    doubleClickDrag(driver, v2Start, v3Drop);
    const v3 = TrackAddress(TrackKind.video, 2);
    assert(editor.modelForTesting().trackCount(TrackKind.video) == 3);
    assert(editor.modelForTesting().trackValue(v2).clips.length == 0);
    assert(editor.modelForTesting().trackValue(v3).clips.length == 1,
        "Double-click-drag did not move the item from V2 to newly created V3");
    const overlayStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    assert(overlayStart > 0.25 && overlayStart < 0.65,
        "The horizontal part of the V2-to-V3 drag was not applied");

    writeln("[editor-smoke] video cross-track drag");

    // Timeline clipboard shortcuts must bubble past the tool shortcuts.
    timeline.setSelection(v3, 0);
    const beforeClipboard = editor.modelForTesting().trackValue(v3).clips.length;
    driver.pressKey(Key.c, cast(uint) KeyModifier.control);
    timeline.setPlayhead(2.4, false);
    driver.pressKey(Key.v, cast(uint) KeyModifier.control);
    assert(editor.modelForTesting().trackValue(v3).clips.length == beforeClipboard + 1,
        "Ctrl+C / Ctrl+V did not copy and paste a timeline item");
    driver.pressKey(Key.d, cast(uint) KeyModifier.control);
    assert(editor.modelForTesting().trackValue(v3).clips.length == beforeClipboard + 2,
        "Ctrl+D did not duplicate the selected timeline item");

    // The equivalent bottom-edge gesture creates A2.
    const audioStart = clipCenter(timeline, a1, 0);
    const a2Drop = timeline.newTrackDropPointForTesting(TrackKind.audio, 0.9);
    doubleClickDrag(driver, audioStart, a2Drop);
    const a2 = TrackAddress(TrackKind.audio, 1);
    assert(editor.modelForTesting().trackCount(TrackKind.audio) == 2);
    assert(editor.modelForTesting().trackValue(a1).clips.length == 0);
    assert(editor.modelForTesting().trackValue(a2).clips.length == 1);

    writeln("[editor-smoke] audio cross-track drag");

    // Keep the compact sequence geometry at one third of the old clip height.
    assert(timeline.clipBodyHeightForTesting() == 20);
    assert(timeline.clipRectForTesting(v3, 0).height == 20,
        "Sequence clip bodies do not leave enough height for normal text");
    // Clip edges resize timeline duration without a modal operation.
    const beforeDuration = editor.modelForTesting().trackValue(v3).clips[0].duration();
    auto edgeRect = timeline.clipRectForTesting(v3, 0);
    auto timelineGlobal = timeline.localToGlobal(Point(0, 0));
    const edgeStart = Point(timelineGlobal.x + edgeRect.right() - 1,
        timelineGlobal.y + edgeRect.y + edgeRect.height / 2);
    driver.drag(edgeStart, Point(edgeStart.x + 24, edgeStart.y), 8);
    assert(editor.modelForTesting().trackValue(v3).clips[0].duration() >= beforeDuration,
        "Dragging a clip edge did not resize its timeline duration");

    timeline.setSelection(v3, 0);
    assert(addTransitions.enabled(),
        "Add transition button did not enable for a selected timeline item");
    addTransitions.activate();
    assert(editor.modelForTesting().trackValue(v3).clips[0].fadeIn > 0.0 &&
        editor.modelForTesting().trackValue(v3).clips[0].fadeOut > 0.0,
        "Add transition button did not apply start and end transitions");
    assert(driver.paint(), "Timeline did not paint visible transition blocks");

    auto transitionClipRect = timeline.clipRectForTesting(v3, 0);
    timelineGlobal = timeline.localToGlobal(Point(0, 0));
    const fadeInPoint = Point(timelineGlobal.x + transitionClipRect.x + 18,
        timelineGlobal.y + transitionClipRect.y + transitionClipRect.height / 2);
    driver.click(fadeInPoint);
    assert(timeline.selectedFadeInTransitionForTesting(),
        "Clicking the start transition block did not select it");
    driver.pressKey(Key.deleteKey);
    assert(editor.modelForTesting().trackValue(v3).clips[0].fadeIn == 0.0 &&
        editor.modelForTesting().trackValue(v3).clips[0].fadeOut > 0.0,
        "Delete did not remove only the selected start transition");

    const fadeOutBefore = editor.modelForTesting().trackValue(v3).clips[0].fadeOut;
    const fadeOutStart = editor.modelForTesting().trackValue(v3).clips[0].start +
        editor.modelForTesting().trackValue(v3).clips[0].duration() -
        fadeOutBefore * 0.5;
    const fadeOutPoint = timeline.pointForTrackTime(v3, fadeOutStart);
    driver.click(fadeOutPoint);
    assert(timeline.selectedFadeOutTransitionForTesting(),
        "Clicking the end transition block did not select it");
    driver.drag(fadeOutPoint, Point(fadeOutPoint.x - 30, fadeOutPoint.y), 8);
    assert(editor.modelForTesting().trackValue(v3).clips[0].fadeOut > fadeOutBefore,
        "Dragging the end transition block did not adjust its duration");
    assert(timeline.selectedFadeOutTransitionForTesting(),
        "Dragging an end transition did not keep that transition selected");

    // Dynamic track and composition operations are exposed through context menus.
    const overlayPoint = clipCenter(timeline, v3, 0);
    driver.rightClick(overlayPoint);
    auto timelineMenu = findOpenContextMenu(editor);
    assert(timelineMenu !is null);
    assert(timelineMenu.menuRect().x == overlayPoint.x + 2 &&
        timelineMenu.menuRect().bottom() == overlayPoint.y - 2,
        "Timeline context menu is not anchored from its bottom-left beside the mouse");
    assert(menuHasLabel(timelineMenu, "Move to track…"d));
    assert(menuHasLabel(timelineMenu, "Move to new video track"d),
        "Move to new video track command is missing from the clip context menu");
    assert(!menuHasLabel(timelineMenu, "Move to new audio track"d),
        "Video-only clip context menu still offers a new audio track");
    assert(menuHasLabel(timelineMenu, "Add video track"d));
    assert(menuHasLabel(timelineMenu, "Add audio track"d));
    assert(menuHasLabel(timelineMenu, "Mute V3"d));
    assert(menuHasLabel(timelineMenu, "Set sequence resolution to 160×90"d),
        "Overlay clip context menu is missing the sequence-resolution command");
    assert(menuHasLabel(timelineMenu, "Reset transform"d));
    assert(!menuHasLabel(timelineMenu, "Move to V1"d) &&
        !menuHasLabel(timelineMenu, "Move to V2"d),
        "Per-lane Move to V* commands still clutter the timeline context menu");

    // The single "Move to track…" command opens a dialog that lists every
    // compatible destination track instead of one menu entry per lane.
    driver.click(menuItemPoint(timelineMenu, "Move to track…"d));
    assert(driver.paint(), "Move to track dialog did not paint");
    auto moveList = requireWidget!ListView(editor, "move-to-track-list");
    auto moveApply = requireWidget!Button(editor, "move-to-track-apply");
    assert(moveList.items().length == 4,
        "Move to track dialog did not list every destination track");
    assert(moveList.items()[0].text == "V1"d &&
        moveList.items()[1].text == "V2"d &&
        moveList.items()[2].text == "V3"d &&
        moveList.items()[3].text == "New video track"d,
        "Move to track dialog listed the wrong destination tracks");
    assert(moveList.items()[2].disabled,
        "Move to track dialog did not disable the clip's current track");
    moveList.setSelectedIndex(1, true);
    driver.click(globalCenter(moveApply));
    assert(editor.modelForTesting().trackValue(v2).clips.length == 1 &&
        editor.modelForTesting().trackValue(v3).clips.length == 2,
        "Move to track dialog did not move the overlay clip to V2");

    // Moving back through the same dialog restores the original arrangement.
    driver.rightClick(clipCenter(timeline, v2, 0));
    auto moveMenu = findOpenContextMenu(editor);
    assert(moveMenu !is null && menuHasLabel(moveMenu, "Move to track…"d));
    driver.click(menuItemPoint(moveMenu, "Move to track…"d));
    assert(driver.paint(), "Move to track dialog did not repaint");
    moveList = requireWidget!ListView(editor, "move-to-track-list");
    moveApply = requireWidget!Button(editor, "move-to-track-apply");
    moveList.setSelectedIndex(2, true);
    driver.click(globalCenter(moveApply));
    assert(editor.modelForTesting().trackValue(v3).clips.length == 3 &&
        editor.modelForTesting().trackValue(v2).clips.length == 0,
        "Move to track dialog did not restore the overlay clip to V3");

    // Text clips must also offer move commands (video-track layers only).
    const probeTextIndex = editor.modelForTesting().insertTextClip(v2, 0.8);
    editor.tickTree(0.05);
    timeline.setSelection(v2, probeTextIndex);
    driver.rightClick(clipCenter(timeline, v2, probeTextIndex));
    auto textMoveMenu = findOpenContextMenu(editor);
    assert(textMoveMenu !is null &&
        menuHasLabel(textMoveMenu, "Move to track…"d) &&
        menuHasLabel(textMoveMenu, "Move to new video track"d),
        "Text clip context menu is missing its move commands");
    assert(!menuHasLabel(textMoveMenu, "Move to new audio track"d),
        "Text clip context menu still offers a new audio track");
    driver.pressKey(Key.escape);
    assert(editor.modelForTesting().removeClip(v2, probeTextIndex),
        "Could not remove the probe text clip");

    // A long menu must remain scrollable rather than losing lower commands.
    driver.rightClick(clipCenter(timeline, v3, 0));
    timelineMenu = findOpenContextMenu(editor);
    assert(timelineMenu !is null,
        "Timeline context menu did not reopen after the move dialog");
    driver.wheel(Point(timelineMenu.menuRect().x + 20,
        timelineMenu.menuRect().y + timelineMenu.menuRect().height / 2), -4);
    driver.pressKey(Key.escape);

    // Animated properties are marked directly on clips. Right-clicking the
    // marker exposes removal and interpolation choices.
    const keyClipStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    assert(editor.modelForTesting().setKeyframe(v3, 0,
        EffectProperty.scale, 0.10, 0.55));
    timeline.visualChanged();
    assert(driver.paint());
    const keyframePoint = timeline.pointForTrackTime(v3, keyClipStart + 0.10);
    driver.rightClick(keyframePoint);
    auto keyframeMenu = findOpenContextMenu(editor);
    assert(keyframeMenu !is null);
    assert(menuHasLabel(keyframeMenu, "Remove keyframe"d));
    assert(menuHasLabel(keyframeMenu, "Linear interpolation"d));
    assert(menuHasLabel(keyframeMenu, "Bezier interpolation"d));
    assert(menuHasLabel(keyframeMenu, "Hold interpolation"d));
    driver.pressKey(Key.escape);

    driver.click(globalCenter(qualityButton));
    auto qualityMenu = findOpenContextMenu(editor);
    assert(qualityMenu !is null);
    assert(menuHasLabel(qualityMenu, "720p preview"d));
    assert(menuHasLabel(qualityMenu, "1080p preview"d));
    assert(menuHasLabel(qualityMenu, "1440p preview"d));
    assert(menuHasLabel(qualityMenu, "2160p preview"d));
    driver.pressKey(Key.escape);

    writeln("[editor-smoke] context menus and quality");

    // Resize the Sequence with its actual SplitPane divider.
    const oldSequenceHeight = sequenceSplit.second().bounds().height;
    const splitOrigin = sequenceSplit.localToGlobal(Point(0, 0));
    const dividerY = splitOrigin.y + sequenceSplit.first().bounds().height + 3;
    const dividerX = splitOrigin.x + sequenceSplit.bounds().width / 2;
    driver.drag(Point(dividerX, dividerY), Point(dividerX, dividerY - 80));
    assert(sequenceSplit.second().bounds().height > oldSequenceHeight + 35);

    assert(inspectorScroll.maxScroll() > 0);
    driver.wheel(globalCenter(inspectorScroll), -5);
    assert(inspectorScroll.scrollY() > 0,
        "Clip Inspector did not scroll to lower transform/audio controls");

    writeln("[editor-smoke] resize and inspector scroll");

    // Select the overlay and make it a picture-in-picture composition. The
    // single Preview transport always plays the timeline, even when Project
    // Media currently has focus.
    driver.click(clipCenter(timeline, v3, 0));
    const scaleBeforeScrub = scale.value();
    const scaleCenter = globalCenter(scale);
    driver.drag(scaleCenter, Point(scaleCenter.x + 18, scaleCenter.y), 6);
    assert(fabs(scale.value() - scaleBeforeScrub) > 0.001,
        "Click-dragging a property value did not scrub it");
    timeline.setPlayhead(keyClipStart + 0.25, true);
    scale.setValue(0.5);
    const keyedScaleClip = editor.modelForTesting().trackValue(v3).clips[0];
    assert(keyedScaleClip.hasKeyframe(EffectProperty.scale, 0.25, 0.02),
        "Editing an animated property did not create a marked keyframe");
    assert(fabs(keyedScaleClip.evaluatedValue(EffectProperty.scale, 0.25) - 0.5) < 0.001);
    driver.click(mediaRowPoint(mediaList, 2));
    editor.setPreviewQualityForTesting(720);
    timeline.setPlayhead(0.60, false);
    const audioStatsBeforeLivePlayback = editor.audioStatsForTesting();
    driver.click(globalCenter(playSource));
    assert(editor.playbackRunningForTesting() &&
        editor.sequencePlaybackForTesting() &&
        editor.playbackAwaitingFirstFrameForTesting() && !preview.playing(),
        "The Preview transport did not enter first-frame preroll");
    assert(waitForSequencePlayback(editor, preview),
        "The live timeline composition never began embedded playback");
    assert(waitForFrame(editor, preview, 0.62, 600));
    assert(editor.audioStatsForTesting().requests >
        audioStatsBeforeLivePlayback.requests,
        "Live Composition Preview did not request preview audio");
    writeln("[editor-smoke] sequence frame title=", preview.frameTitleForTesting(),
        " time=", preview.frameTime());
    assert(preview.frameTitleForTesting().canFind("Sequence"),
        "Preview is not showing the timeline composition");
    const center = preview.pixelForTesting(preview.frameWidth() / 2,
        preview.frameHeight() / 2);
    const corner = preview.pixelForTesting(8, 8);
    assert(center[0] > center[2] + 70,
        "The scaled red V3 overlay is missing from the live Preview");
    assert(corner[2] > corner[0] + 70,
        "The blue V1 base is missing outside the live overlay");

    writeln("[editor-smoke] live sequence preview");

    // Hammer the same coalesced path used by the playback selector. Pointer
    // movement must remain immediate, repaint only retained transport layers,
    // and commit at most one useful decoder restart when the gesture ends.
    const statsBeforeScrub = editor.videoStatsForTesting();
    // Headless ticks do not implicitly present. Flush the playback-start
    // layout and the one follow-up frame caused by changed button widths before
    // measuring only the selector gesture itself.
    foreach (_; 0 .. 3) assert(driver.paint());
    window.resetRendererStats();
    window.resetCompositorStats();
    editor.beginSeekGestureForTesting();
    auto scrubWatch = StopWatch(AutoStart.yes);
    foreach (index; 0 .. 240)
    {
        const target = 0.10 + cast(double) (index % 110) / 100.0;
        editor.seekForTesting(target);
        if (index % 12 == 0) assert(driver.paint());
    }
    scrubWatch.stop();
    assert(editor.seekPendingForTesting());
    assert(scrubWatch.peek.total!"msecs" < 1_500,
        "Rapid playback-selector movement blocked the UI thread");
    const scrubRenderer = window.rendererStats();
    const scrubCompositor = window.compositorStats();
    writeln("[editor-smoke] scrub renderer full=", scrubRenderer.fullSceneRedraws,
        " partial=", scrubRenderer.partialSceneRedraws,
        " dirty=", scrubRenderer.dirtyPixels,
        " cached=", scrubRenderer.cachedSurfaceBuilds,
        " baseBuilds=", scrubCompositor.baseBuilds,
        " layerBuilds=", scrubCompositor.layerBuilds,
        " orderBuilds=", scrubCompositor.layerOrderBuilds);
    assert(scrubRenderer.fullSceneRedraws == 0,
        "Playback-selector movement repainted the full editor window");
    assert(scrubRenderer.partialSceneRedraws > 0);
    assert(scrubCompositor.baseBuilds == 0,
        "Playback-selector movement rebuilt static workspace geometry");
    editor.endSeekGestureForTesting();
    assert(waitForSequencePlayback(editor, preview),
        "Playback did not recover after a rapid selector gesture");
    const statsAfterScrub = editor.videoStatsForTesting();
    assert(statsAfterScrub.processesStarted - statsBeforeScrub.processesStarted < 12,
        "Rapid selector movement spawned excessive decoder processes");
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Rapid selector movement stopped sequence playback");

    writeln("[editor-smoke] coalesced playback selector");

    // Editing mute while the composed sequence is playing must never stop the
    // video decoder or playhead. The change applies to the next render.
    // Select the V1 source clip, which contains embedded audio. The currently
    // selected overlay clip is intentionally video-only, so its audio controls
    // are disabled by the Inspector.
    driver.rightClick(clipCenter(timeline, v1, 0));
    auto avMenu = findOpenContextMenu(editor);
    assert(avMenu !is null &&
        menuHasLabel(avMenu, "Detach audio to separate A track"d),
        "Video-item context menu does not expose audio detachment");
    driver.pressKey(Key.escape);
    timeline.setSelection(v1, 0);
    editor.tickTree(0.02);
    driver.paint();

    foreach (_; 0 .. 120)
    {
        const mutePoint = globalCenter(mute);
        if (editor.hitTest(mutePoint) is mute) break;
        const scrollOrigin = inspectorScroll.localToGlobal(Point(0, 0));
        const scrollBottom = scrollOrigin.y + inspectorScroll.bounds().height;
        if (mutePoint.y < scrollOrigin.y)
            driver.wheel(globalCenter(inspectorScroll), 3);
        else if (mutePoint.y >= scrollBottom)
            driver.wheel(globalCenter(inspectorScroll), -3);
        else
            break;
    }
    assert(editor.hitTest(globalCenter(mute)) is mute,
        "Mute control could not be reached through the scrollable inspector");
    const runningBeforeMute = editor.sequencePlaybackForTesting();
    driver.click(globalCenter(mute));
    assert(runningBeforeMute && editor.sequencePlaybackForTesting() && preview.playing(),
        "Muting a clip stopped active playback");

    // Transform edits likewise invalidate only the next composition render;
    // the already playing proxy and decoder continue without interruption.
    timeline.setSelection(v3, 0);
    editor.tickTree(0.02);
    scale.setValue(0.62);
    const liveChangedClip = editor.modelForTesting().trackValue(v3).clips[0];
    double liveLocal = timeline.playhead() - liveChangedClip.start;
    if (liveLocal < 0.0) liveLocal = 0.0;
    if (liveLocal > liveChangedClip.duration()) liveLocal = liveChangedClip.duration();
    assert(fabs(liveChangedClip.evaluatedValue(EffectProperty.scale, liveLocal) - 0.62) < 0.001);
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Changing a composition transform stopped active playback");

    // Moving a clip while playback is active must not stop or restart the
    // current FFmpeg video snapshot. The edited revision is adopted only after
    // pause/resume or a new Play command.
    const processesBeforeLiveMove = editor.videoStatsForTesting().processesStarted;
    const originalMoveStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    editor.moveClipForTesting(v3, 0, v3, originalMoveStart + 0.10);
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Moving a timeline item interrupted active playback");
    assert(editor.videoStatsForTesting().processesStarted == processesBeforeLiveMove,
        "Moving a timeline item restarted the active video decoder");
    assert(editor.deferredSequenceRefreshForTesting() &&
        editor.modelRevisionForTesting() != editor.playbackRevisionForTesting(),
        "The active playback snapshot was not preserved after a timeline edit");

    driver.pressKey(Key.escape);

    writeln("[editor-smoke] non-blocking edits");

    // Loop playback repeats between the work-area In/Out markers: the transport
    // stays confined to [In, Out] and wraps back to In at the Out marker
    // instead of stopping.
    {
        auto loopButton = requireWidget!Button(editor, "loop-preview");
        assert(loopButton !is null, "Loop button is missing from the transport");
        assert(!editor.loopEnabledForTesting(),
            "Loop playback was enabled before the loop test");

        driver.click(globalCenter(loopButton));
        assert(editor.loopEnabledForTesting(),
            "Loop button did not enable loop playback");

        editor.setWorkInForTesting(0.5);
        editor.setWorkOutForTesting(0.9);
        timeline.setPlayhead(0.5, false);
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Loop playback did not start the sequence");
        assert(fabs(editor.playbackStartForTesting() - 0.5) < 0.001 &&
            fabs(editor.playbackEndForTesting() - 0.9) < 0.001,
            "Loop playback did not confine the transport to the work-area range");
        assert(waitForSequencePlayback(editor, preview),
            "Loop playback never began embedded playback");
        assert(waitForLoopWrap(editor, 0.85, 0.75),
            "Loop playback did not wrap at the work-area Out marker");
        assert(editor.sequencePlaybackForTesting(),
            "Loop playback stopped instead of wrapping");
        assert(editor.playbackPositionForTesting() < 0.8,
            "Loop playback did not return to the work-area In marker");

        driver.click(globalCenter(loopButton));
        assert(!editor.loopEnabledForTesting(),
            "Loop button did not disable loop playback");
        editor.clearWorkRangeForTesting();
        driver.pressKey(Key.escape);
        assert(!editor.playbackRunningForTesting(),
            "Loop test playback did not stop cleanly");
    }

    // The order of operations must not matter: enabling loop, or setting the
    // work-area markers, WHILE sequence playback is running immediately
    // confines the transport to the In/Out markers instead of looping the
    // whole sequence.
    {
        auto loopButton = requireWidget!Button(editor, "loop-preview");
        assert(!editor.loopEnabledForTesting(),
            "Loop playback was already enabled before the mid-playback test");
        editor.clearWorkRangeForTesting();
        editor.setWorkInForTesting(0.5);
        editor.setWorkOutForTesting(0.9);
        timeline.setPlayhead(0.2, false);
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Playback did not start for the mid-playback loop test");
        assert(fabs(editor.playbackStartForTesting()) < 0.001 &&
            editor.playbackEndForTesting() > 0.9 + 0.001,
            "Loop-off playback must span the full sequence, not the markers");
        driver.click(globalCenter(loopButton));
        assert(editor.loopEnabledForTesting(),
            "Loop button did not enable loop playback mid-playback");
        assert(fabs(editor.playbackStartForTesting() - 0.5) < 0.001 &&
            fabs(editor.playbackEndForTesting() - 0.9) < 0.001,
            "Enabling loop mid-playback did not confine the transport to the markers");
        assert(waitForLoopWrap(editor, 0.85, 0.75),
            "Loop enabled mid-flight did not wrap at the Out marker");
        assert(editor.sequencePlaybackForTesting(),
            "Loop playback stopped instead of wrapping");
        // Moving the Out marker while looping re-bounds the wrap point live.
        editor.setWorkOutForTesting(0.7);
        assert(fabs(editor.playbackEndForTesting() - 0.7) < 0.001,
            "Changing the Out marker during loop playback did not re-bounds the range");
        assert(waitForLoopWrap(editor, 0.65, 0.55),
            "Loop playback did not wrap at the moved Out marker");
        driver.click(globalCenter(loopButton));
        assert(!editor.loopEnabledForTesting(),
            "Loop button did not disable loop playback");
        editor.clearWorkRangeForTesting();
        driver.pressKey(Key.escape);
        assert(!editor.playbackRunningForTesting(),
            "Mid-playback loop test playback did not stop cleanly");
    }

    // Regression: a session that first played WITHOUT loop, then paused,
    // then enabled loop and set the markers, must confine the transport to
    // the markers when Play is pressed again. Previously resumePlayback kept
    // the stale full-sequence bounds and the transport wrapped to the
    // sequence start instead of the In marker.
    {
        auto loopButton = requireWidget!Button(editor, "loop-preview");
        assert(!editor.loopEnabledForTesting(),
            "Loop playback was already enabled before the resume-loop test");
        editor.clearWorkRangeForTesting();
        timeline.setPlayhead(0.2, false);
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Playback did not start for the resume-loop test");
        assert(fabs(editor.playbackStartForTesting()) < 0.001,
            "Initial loop-off playback did not start at sequence zero");
        driver.click(globalCenter(playSource));
        assert(!editor.playbackRunningForTesting(),
            "Pause did not stop playback for the resume-loop test");
        editor.setWorkInForTesting(0.5);
        editor.setWorkOutForTesting(0.9);
        driver.click(globalCenter(loopButton));
        assert(editor.loopEnabledForTesting(),
            "Loop button did not enable loop playback while paused");
        assert(fabs(editor.playbackStartForTesting() - 0.5) < 0.001 &&
            fabs(editor.playbackEndForTesting() - 0.9) < 0.001,
            "Enabling loop while paused did not confine the idle transport to the markers");
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Resume after enabling loop did not start sequence playback");
        assert(fabs(editor.playbackStartForTesting() - 0.5) < 0.001 &&
            fabs(editor.playbackEndForTesting() - 0.9) < 0.001,
            "Resume playback lost the loop-confined bounds and reverted to the full sequence");
        assert(waitForLoopWrap(editor, 0.85, 0.75),
            "Resumed loop playback did not wrap at the Out marker");
        assert(editor.sequencePlaybackForTesting(),
            "Resumed loop playback stopped instead of wrapping");
        driver.click(globalCenter(loopButton));
        assert(!editor.loopEnabledForTesting(),
            "Loop button did not disable loop playback");
        editor.clearWorkRangeForTesting();
        driver.pressKey(Key.escape);
        assert(!editor.playbackRunningForTesting(),
            "Resume-loop test playback did not stop cleanly");
    }

    // Setting, clearing, and restoring the export-range In/Out marks must be
    // tracked by global Undo/Redo like any other timeline edit.
    {
        assert(!editor.hasWorkInForTesting() && !editor.hasWorkOutForTesting(),
            "Work-area marks existed before the undo/redo test");
        editor.setWorkInForTesting(0.5);
        editor.setWorkOutForTesting(0.9);
        assert(editor.hasWorkInForTesting() && editor.hasWorkOutForTesting() &&
            fabs(editor.workInForTesting() - 0.5) < 0.001 &&
            fabs(editor.workOutForTesting() - 0.9) < 0.001,
            "Setting the In/Out marks did not stick before the undo test");
        editor.clearWorkRangeForTesting();
        assert(!editor.hasWorkInForTesting() && !editor.hasWorkOutForTesting(),
            "clearWorkRange did not clear the export marks");
        driver.click(globalCenter(undoButton));
        assert(editor.hasWorkInForTesting() && editor.hasWorkOutForTesting() &&
            fabs(editor.workInForTesting() - 0.5) < 0.001 &&
            fabs(editor.workOutForTesting() - 0.9) < 0.001,
            "Undo did not restore the cleared export marks");
        driver.click(globalCenter(undoButton));
        assert(editor.hasWorkInForTesting() && !editor.hasWorkOutForTesting() &&
            fabs(editor.workInForTesting() - 0.5) < 0.001,
            "Undo did not restore the In-only mark state");
        driver.click(globalCenter(undoButton));
        assert(!editor.hasWorkInForTesting() && !editor.hasWorkOutForTesting(),
            "Undo did not reach the no-marks state");
        driver.click(globalCenter(redoButton));
        assert(editor.hasWorkInForTesting() && !editor.hasWorkOutForTesting() &&
            fabs(editor.workInForTesting() - 0.5) < 0.001,
            "Redo did not restore the In-only mark state");
        driver.click(globalCenter(redoButton));
        assert(editor.hasWorkInForTesting() && editor.hasWorkOutForTesting() &&
            fabs(editor.workInForTesting() - 0.5) < 0.001 &&
            fabs(editor.workOutForTesting() - 0.9) < 0.001,
            "Redo did not restore both export marks");
        editor.clearWorkRangeForTesting();
    }

    // The timeline playhead is a free cursor: it must be draggable outside the
    // active playback bounds (the loop In/Out markers) to inspect the rest of
    // the sequence, and must stay parked there until Play is pressed again.
    {
        auto loopButton = requireWidget!Button(editor, "loop-preview");
        assert(!editor.loopEnabledForTesting(),
            "Loop playback was already enabled before the free-playhead test");
        editor.setWorkInForTesting(0.5);
        editor.setWorkOutForTesting(0.9);
        timeline.setPlayhead(0.5, false);
        driver.click(globalCenter(loopButton));
        assert(editor.loopEnabledForTesting(),
            "Loop button did not enable loop playback for the free-playhead test");
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Playback did not start for the free-playhead test");
        assert(fabs(editor.playbackStartForTesting() - 0.5) < 0.001 &&
            fabs(editor.playbackEndForTesting() - 0.9) < 0.001,
            "Loop playback did not confine to the marks for the free-playhead test");
        // Drag the playhead past the loop Out marker: it must park there.
        editor.seekForTesting(1.2);
        foreach (_; 0 .. 10) editor.tickTree(0.02);
        assert(fabs(editor.playbackPositionForTesting() - 1.2) < 0.01,
            "Playhead dragged outside the loop range was clamped or wrapped back into it");
        assert(!editor.playbackRunningForTesting(),
            "Parking the playhead outside the loop range did not stop playback");
        // Dragging before the In marker parks there too.
        editor.seekForTesting(0.2);
        foreach (_; 0 .. 10) editor.tickTree(0.02);
        assert(fabs(editor.playbackPositionForTesting() - 0.2) < 0.01,
            "Playhead dragged before the loop In marker was clamped back into the range");
        // Pressing Play re-enters the loop range and starts from the In marker.
        driver.click(globalCenter(playSource));
        assert(editor.playbackRunningForTesting() &&
            editor.sequencePlaybackForTesting(),
            "Play after parking outside the loop range did not resume");
        const resumed = editor.playbackPositionForTesting();
        assert(resumed >= 0.5 - 0.02 && resumed <= 0.9 + 0.02,
            "Resumed playback did not re-enter the loop range after parking outside");
        driver.click(globalCenter(loopButton));
        assert(!editor.loopEnabledForTesting(),
            "Loop button did not disable loop playback");
        editor.clearWorkRangeForTesting();
        driver.pressKey(Key.escape);
        assert(!editor.playbackRunningForTesting(),
            "Free-playhead test playback did not stop cleanly");
    }

    // The timeline snap toggle must show its active state with the blue accent
    // background, matching the Loop transport button, and clear it when off.
    {
        auto snapButton = requireWidget!Button(editor, "timeline-snap");
        assert(snapButton !is null, "Snap button is missing from the sequence header");
        const accentArgb = Color.fromHex(0x4f8cff).argb();
        // Snap a background pixel just above the vertically-centered text.
        auto snapPixel = delegate() {
            // Move the pointer off the button so it paints the plain accent
            // (a clicked button stays hovered and would render accentHover).
            driver.moveTo(Point(0, 0));
            assert(driver.paint(), "Snap button accent repaint failed");
            auto surface = window.surface();
            const pitch = surface.width();
            const center = globalCenter(snapButton);
            const origin = snapButton.localToGlobal(Point(0, 0));
            const point = window.displayScale().logicalToPhysical(
                Point(center.x, origin.y + 3));
            return surface.pixels()[cast(size_t) point.y * pitch + point.x];
        };
        assert(editor.snappingEnabledForTesting(),
            "Timeline snapping did not start enabled");
        assert(snapButton.text() == "Snap On"d,
            "Snap button did not start with the On label");
        assert(snapPixel() == accentArgb,
            "Snap button was not accented (blue) while snapping is active");
        driver.click(globalCenter(snapButton));
        assert(!editor.snappingEnabledForTesting(),
            "Clicking the snap button did not disable snapping");
        assert(snapButton.text() == "Snap Off"d,
            "Snap button did not switch to the Off label");
        assert(snapPixel() != accentArgb,
            "Snap button stayed accented (blue) after snapping was disabled");
        driver.click(globalCenter(snapButton));
        assert(editor.snappingEnabledForTesting(),
            "Clicking the snap button again did not re-enable snapping");
        assert(snapButton.text() == "Snap On"d,
            "Snap button did not switch back to the On label");
        assert(snapPixel() == accentArgb,
            "Snap button did not regain the blue accent after re-enabling");
    }

    // A clicked (pointer-focused) button must not keep a blue focus ring after
    // the press is released; only keyboard/Tab focus draws the ring.
    {
        auto snapButton = requireWidget!Button(editor, "timeline-snap");
        auto samplePixel = delegate(int localY) {
            driver.moveTo(Point(0, 0));
            assert(driver.paint(), "Focus ring repaint failed");
            auto surface = window.surface();
            const pitch = surface.width();
            const center = globalCenter(snapButton);
            const origin = snapButton.localToGlobal(Point(0, 0));
            const point = window.displayScale().logicalToPhysical(
                Point(center.x, origin.y + localY));
            return surface.pixels()[cast(size_t) point.y * pitch + point.x];
        };
        // Snap is ON (accent/blue) from the previous block. Click to turn it
        // OFF so the button is a plain gray control that would show the ring.
        driver.click(globalCenter(snapButton));
        assert(!editor.snappingEnabledForTesting(),
            "Snap button did not turn off for the focus-ring test");
        assert(snapButton.focused(),
            "Clicked button did not retain focus");
        // The focus ring paints a 1 px blue line inset 2 px from the button
        // edge (local y+2). For a pointer-focused button it must be identical
        // to the plain fill below it (y+4) and carry no blue tint.
        const ringLine = samplePixel(2);
        const fill = samplePixel(4);
        assert(ringLine == fill,
            "Clicked (pointer-focused) button painted a focus ring over its fill");
        assert(!((ringLine & 0xff) > ((ringLine >> 16) & 0xff) + 40),
            "Clicked button focus ring pixel was blue");
        // Restore snapping to ON so later tests are unaffected.
        driver.click(globalCenter(snapButton));
        assert(editor.snappingEnabledForTesting(),
            "Snap button did not turn back on after the focus-ring test");
    }

    // Text placement is one-shot, existing clips remain selectable while the
    // Text tool is armed, and both timeline/Preview double-clicks open editing.
    auto model = editor.modelForTesting();
    const textLane = model.addTrack(TrackKind.video);
    const textTrack = TrackAddress(TrackKind.video, textLane);
    timeline.modelChanged();
    assert(driver.paint());
    const timelineOrigin = timeline.localToGlobal(Point(0, 0));
    const textToolPoint = Point(timelineOrigin.x + 12, timelineOrigin.y + 56);
    const textTrackRect = timeline.trackRectForTesting(textTrack);
    const textTimeX = timeline.timeOriginXForTesting() +
        cast(int) (0.60 * timeline.pixelsPerSecond());
    const textEndX = timeline.timeOriginXForTesting() +
        cast(int) (2.60 * timeline.pixelsPerSecond());
    const textPlacePoint = Point(timelineOrigin.x + textTimeX,
        timelineOrigin.y + textTrackRect.y + textTrackRect.height / 2);
    const textEndPoint = Point(timelineOrigin.x + textEndX, textPlacePoint.y);
    driver.click(textToolPoint);
    driver.click(textPlacePoint);
    assert(model.trackValue(textTrack).clips.length == 0,
        "Text tool created an item without a duration drag");
    driver.drag(textPlacePoint, textEndPoint, 12);
    assert(model.trackValue(textTrack).clips.length == 1);
    assert(model.trackValue(textTrack).clips[0].kind == ClipKind.text);
    assert(fabs(model.trackValue(textTrack).clips[0].duration() - 2.0) < 0.08,
        "Text duration did not match the drag span");
    const firstTitleId = model.trackValue(textTrack).clips[0].id;
    auto textField = preview.titleEditorForTesting(firstTitleId);
    assert(textField !is null,
        "The text item did not create its persistent live preview layer");
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && textField.visible() &&
            preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && textField.visible() &&
        preview.inlineTextEditing(),
        "New text did not focus its persistent live title layer");
    // Text is authored in composition pixels. Preview quality controls only
    // background decode cost and must not become the title's coordinate space.
    assert(preview.titleAuthoredHeightForTesting() == 1080,
        "Preview title geometry used preview quality instead of composition height");
    const fullHdTitlePixels = preview.titlePixelSizeForTesting(firstTitleId);
    const fullHdTitleBounds = textField.bounds();
    const fullHdTitleCenter = Point(fullHdTitleBounds.x + fullHdTitleBounds.width / 2,
        fullHdTitleBounds.y + fullHdTitleBounds.height / 2);
    editor.setCompositionResolutionForTesting(1280, 720);
    const hdTitleBounds = textField.bounds();
    assert(preview.titleAuthoredHeightForTesting() == 720 &&
        preview.titlePixelSizeForTesting(firstTitleId) > fullHdTitlePixels,
        "720p output did not enlarge the authored title in the live preview");
    assert(Point(hdTitleBounds.x + hdTitleBounds.width / 2,
            hdTitleBounds.y + hdTitleBounds.height / 2) == fullHdTitleCenter,
        "Changing output resolution shifted the title's normalized position");
    editor.setCompositionResolutionForTesting(3840, 2160);
    assert(preview.titleAuthoredHeightForTesting() == 2160 &&
        preview.titlePixelSizeForTesting(firstTitleId) < fullHdTitlePixels,
        "2160p output did not shrink the authored title in the live preview");
    editor.setCompositionResolutionForTesting(1920, 1080);
    assert(preview.titlePixelSizeForTesting(firstTitleId) == fullHdTitlePixels,
        "Restoring 1080p did not restore matching live title geometry");
    assert(!inspectorTextField.visible(),
        "A duplicate text-content input remained visible in Effects / Properties");
    // Exercise real text-input dispatch rather than directly mutating the
    // field. Typing must update the one selected title and must never leave the
    // Text tool armed to create another sequence item.
    driver.text("Aurora"d);
    driver.pressKey(Key.space);
    assert(!editor.playbackRunningForTesting(),
        "Space started playback while the inline title editor was focused");
    // Native backends deliver the printable character in the following text
    // input event after key-down. The root shortcut handler must leave it alone.
    driver.text(" "d);
    driver.text("timeline"d);
    assert(model.trackValue(textTrack).clips[0].text == "Aurora timeline");
    assert(model.trackValue(textTrack).clips.length == 1,
        "Typing title text created duplicate timeline items");
    textField.setSelection(0, 6);
    driver.pressKey(Key.c, cast(uint) KeyModifier.control);
    textField.setCursorIndex(textField.textView().length);
    driver.pressKey(Key.v, cast(uint) KeyModifier.control);
    assert(model.trackValue(textTrack).clips[0].text == "Aurora timelineAurora",
        "Ctrl+C / Ctrl+V did not copy and paste focused title text");
    assert(model.trackValue(textTrack).clips.length == 1,
        "Focused title paste triggered timeline-item paste");

    driver.click(globalCenter(inlineFont));
    auto fontMenu = findOpenContextMenu(editor);
    assert(fontMenu !is null && menuHasLabel(fontMenu, "Arial"d) &&
        menuHasLabel(fontMenu, "Tahoma"d) && menuHasLabel(fontMenu, "Verdana"d),
        "Composition Preview is missing the complete font dropdown");
    const fontMenuRect = fontMenu.menuRect();
    // Arial is the second row after Segoe UI.
    driver.click(Point(fontMenuRect.x + 70,
        fontMenuRect.y + 3 + fontMenu.rowHeightForTesting() +
        fontMenu.rowHeightForTesting() / 2));
    assert(inlineFont.text() == "Arial ▾"d,
        "Composition Preview font dropdown did not retain its selection");
    assert(model.trackValue(textTrack).clips[0].fontName == "Arial",
        "Arial menu command resolved to a different captured font");

    // Reopen the menu after the model/inspector synchronization pass. The
    // selected row must remain checked instead of resetting to the final Sans
    // callback captured by the foreach loop.
    driver.click(globalCenter(inlineFont));
    fontMenu = findOpenContextMenu(editor);
    assert(fontMenu !is null && menuItemChecked(fontMenu, "Arial"d),
        "Composition Preview lost the selected font after synchronization");
    const secondFontMenuRect = fontMenu.menuRect();
    // Impact is row 7 (zero-based index 6).
    driver.click(Point(secondFontMenuRect.x + 70,
        secondFontMenuRect.y + 3 + 6 * fontMenu.rowHeightForTesting() +
        fontMenu.rowHeightForTesting() / 2));
    assert(inlineFont.text() == "Impact ▾"d &&
        model.trackValue(textTrack).clips[0].fontName == "Impact",
        "Distinct font menu rows still shared one captured callback value");

    inlineSize.setText("72", true);
    inlineColor.setText("#FFCC00", true);
    driver.click(globalCenter(inlineBold));
    driver.click(globalCenter(inlineAlignCenter));
    const styledText = model.trackValue(textTrack).clips[0];
    assert(styledText.fontName == "Impact" && styledText.textBold,
        "Inline font or bold formatting did not update the selected text item");
    assert(fabs(styledText.textSize - 72.0) < 0.01 &&
        styledText.textColor == 0xffffcc00,
        "Inline size or color formatting did not update the selected text item");
    assert(styledText.textAlignment == TextAlignment.center,
        "Inline text alignment did not update the selected text item");

    // Re-arm Text and click the existing title. It must select, not duplicate.
    driver.click(textToolPoint);
    driver.click(clipCenter(timeline, textTrack, 0));
    assert(model.trackValue(textTrack).clips.length == 1,
        "Text tool created another item when clicking an existing text clip");
    driver.doubleClick(clipCenter(timeline, textTrack, 0));
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && preview.inlineTextEditing(),
        "Timeline double-click did not activate the live title layer");

    // Double-click empty sequence space, hold the second press, and drag a
    // marquee over both titles. Selection must include every intersected item.
    assert(model.insertTextClip(textTrack, 3.20, 0.80, "Second title") >= 0);
    timeline.modelChanged();
    assert(driver.paint());
    const marqueeStartX = timeline.timeOriginXForTesting() +
        cast(int) (0.20 * timeline.pixelsPerSecond());
    const marqueeEndX = timeline.timeOriginXForTesting() +
        cast(int) (4.20 * timeline.pixelsPerSecond());
    const marqueeStart = Point(timelineOrigin.x + marqueeStartX, textPlacePoint.y);
    const marqueeEnd = Point(timelineOrigin.x + marqueeEndX, textPlacePoint.y);
    doubleClickDrag(driver, marqueeStart, marqueeEnd, 16);
    assert(timeline.selectedCountForTesting() == 2,
        "Double-click-drag marquee did not select both timeline items");

    timeline.setPlayhead(0.80, true);
    foreach (_; 0 .. 120)
    {
        editor.tickTree(0.02);
        if (preview.hasCompositionFrame()) break;
        Thread.sleep(20.msecs);
    }
    driver.doubleClick(globalCenter(preview));
    assert(timeline.selectedTrack() == textTrack && timeline.selectedIndex() == 0,
        "Preview double-click did not select the top text item");
    textField = preview.titleEditorForTesting(firstTitleId);
    assert(textField !is null,
        "Preview double-click did not expose the current live title layer");
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && preview.inlineTextEditing(),
        "Preview double-click did not activate the live title layer");
    driver.click(globalCenter(inlineDone));
    assert(!preview.inlineTextEditing(),
        "Done did not close the inline text editor before canvas transforms");
    assert(preview.titleEditorForTesting(firstTitleId) is textField,
        "Done replaced the title instead of keeping the same live layer");
    assert(textField.visible() && textField.readOnly(),
        "The live title layer did not remain visible after editing");

    // Move the selected text directly on the composition canvas. Begin a few
    // pixels away from the prior double-click point so click counting cannot
    // reinterpret the drag as a third click.
    const previewCenter = globalCenter(preview);
    const dragStart = Point(previewCenter.x + 18, previewCenter.y);
    const beforeX = model.trackValue(textTrack).clips[0].positionX;
    const beforeY = model.trackValue(textTrack).clips[0].positionY;
    driver.drag(dragStart, Point(dragStart.x + 64, dragStart.y + 28), 12);
    const movedText = model.trackValue(textTrack).clips[0];
    assert(fabs(movedText.positionX - beforeX) > 0.01 ||
        fabs(movedText.positionY - beforeY) > 0.01,
        "Dragging text in Composition Preview did not update its transform");
    assert(model.trackValue(textTrack).clips.length == 2,
        "Canvas dragging created an extra text item");

    // A rectangular preview drag should create a real cropped upper-layer clip,
    // not a one-off mask. The new cutout remains a normal timeline item and
    // can be corner-scaled immediately.
    timeline.setSelection(v1, 0, false);
    timeline.setPlayhead(0.30, false);
    foreach (_; 0 .. 30) editor.tickTree(0.02);
    const cutoutLane = model.trackCount(TrackKind.video);
    assert(editor.beginCutoutSelectionForTesting(),
        "Cutout selection did not arm for a selected media clip");
    assert(preview.cutoutSelectionArmedForTesting(),
        "Preview did not enter cutout rectangle mode");
    const cutoutDragStart = Point(previewCenter.x - 70, previewCenter.y - 42);
    const cutoutDragEnd = Point(previewCenter.x + 34, previewCenter.y + 46);
    driver.drag(cutoutDragStart, cutoutDragEnd, 12);
    assert(model.trackCount(TrackKind.video) == cutoutLane + 1,
        "Cutout creation did not add an upper video track");
    const cutoutTrack = TrackAddress(TrackKind.video, cutoutLane);
    assert(model.trackValue(cutoutTrack).clips.length == 1,
        "Cutout creation did not place a timeline clip");
    TimelineClip cutoutClip;
    assert(model.copyClip(cutoutTrack, 0, cutoutClip));
    assert(cutoutClip.cropEnabled && cutoutClip.cropWidth < 0.98 &&
        cutoutClip.cropHeight < 0.98,
        "Cutout clip did not store a smaller source crop");
    assert(cutoutClip.muted,
        "Cutout duplicate must be muted so it cannot double embedded audio");
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    const cropWidthBeforeAdjust = cutoutClip.cropWidth;
    assert(editor.beginCutoutAdjustmentForTesting(),
        "Cutout adjustment mode did not arm for an existing cutout");
    assert(preview.cutoutAdjustArmedForTesting(),
        "Preview did not enter cutout adjustment mode");
    const cutoutRightSide = Point(cutoutDragEnd.x,
        (cutoutDragStart.y + cutoutDragEnd.y) / 2);
    driver.drag(cutoutRightSide, Point(cutoutRightSide.x + 38,
        cutoutRightSide.y), 10);
    assert(model.copyClip(cutoutTrack, 0, cutoutClip));
    assert(cutoutClip.cropWidth > cropWidthBeforeAdjust + 0.01,
        "Dragging a cutout side handle did not widen the stored crop");

    const cutoutScaleBefore = cutoutClip.scale;
    const cutoutCorner = Point(cutoutDragEnd.x + 38, cutoutDragStart.y);
    driver.drag(cutoutCorner, Point(cutoutCorner.x + 52, cutoutCorner.y - 32), 10);
    assert(model.copyClip(cutoutTrack, 0, cutoutClip));
    assert(cutoutClip.scale > cutoutScaleBefore + 0.01,
        "Dragging a Composition Preview corner handle did not scale the cutout");

    // A split item moved after a silent gap must remain discoverable as future
    // audible media. The mixed PCM preview graph uses this same timeline shape.
    const gapTrack = TrackAddress(TrackKind.video,
        model.addTrack(TrackKind.video));
    const gapIndex = model.insertClip(0, gapTrack, 100.0);
    assert(gapIndex >= 0);
    const gapRight = model.splitAt(gapTrack, 101.0);
    assert(gapRight >= 0);
    int movedGapRight;
    assert(model.moveClipToTime(gapTrack, gapRight, gapTrack, 103.0,
        movedGapRight));
    assert(fabs(editor.nextTimelineAudioStartForTesting(101.10) - 103.0) < 0.001,
        "Timeline audio lookup missed the next item after a split/move gap");

    // Project Media focus must not replace the timeline monitor with a source
    // frame. Composition Preview remains the timeline at all times.
    const timelineFrameTitle = preview.frameTitleForTesting();
    driver.click(mediaRowPoint(mediaList, 0));
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    assert(preview.frameTitleForTesting() == timelineFrameTitle,
        "Selecting Project Media replaced the timeline composition preview");

    {
        writeDibAsBmpFile(screenshotPath, tinyClipboardDib());
        fakeClipboardHasImage = true;
        ++fakeClipboardSequence;

        const screenshotTrack = TrackAddress(TrackKind.video,
            model.addTrack(TrackKind.video));
        timeline.modelChanged();
        timeline.setSelection(screenshotTrack, -1, false);
        timeline.setPlayhead(0.42, false);

        const mediaBeforeScreenshot = mediaList.items().length;
        driver.pressKey(Key.v, cast(uint) KeyModifier.control);
        assert(waitForMediaCount(editor, mediaList, mediaBeforeScreenshot + 1),
            "Pasted screenshot was not imported as project media");
        assert(model.trackValue(screenshotTrack).clips.length == 1,
            "Pasted screenshot was not placed on the selected video track");
        const screenshotClip = model.trackValue(screenshotTrack).clips[0];
        assert(fabs(screenshotClip.start - 0.42) < 0.001,
            "Pasted screenshot was not placed at the playhead");
        assert(model.assets[screenshotClip.assetIndex].path == screenshotPath,
            "Pasted screenshot did not use the clipboard image file");

        timeline.setSelection(screenshotTrack, 0, false);
        assert(driver.paint());
        const screenshotDurationBefore = screenshotClip.duration();
        auto screenshotRect = timeline.clipRectForTesting(screenshotTrack, 0);
        const screenshotTimelineOrigin = timeline.localToGlobal(Point(0, 0));
        const screenshotEdge = Point(screenshotTimelineOrigin.x + screenshotRect.right() - 2,
            screenshotTimelineOrigin.y + screenshotRect.y + screenshotRect.height / 2);
        driver.drag(screenshotEdge, Point(screenshotEdge.x + 80, screenshotEdge.y), 10);
        TimelineClip resizedScreenshot;
        assert(model.copyClip(screenshotTrack, 0, resizedScreenshot));
        assert(resizedScreenshot.duration() > screenshotDurationBefore + 0.25,
            "Dragging a still-image clip edge did not extend its timeline duration");
        fakeClipboardHasImage = false;
    }

    writeln("[editor-smoke] text selection, canvas transform, and timeline-only preview");

    // Persisted undo/redo history: the stacks are stored INSIDE the project
    // file, so they travel with the project and survive application restarts.
    {
        editor.saveProjectForTesting(recentOpenB);
        const savedData = loadProjectFile(recentOpenB);
        assert(savedData.undo.length == editor.undoCountForTesting(),
            "Project file undo stack did not match the live editor history");
        assert(savedData.redo.length == editor.redoCountForTesting(),
            "Project file redo stack did not match the live editor history");
        assert(savedData.undo.length > 0,
            "Project file should contain the committed timeline actions");

        // Reopening the project restores the stacks on a fresh load.
        editor.openProjectForTesting(recentOpenB);
        assert(editor.undoCountForTesting() == savedData.undo.length &&
            editor.redoCountForTesting() == savedData.redo.length,
            "Opening a project did not restore its saved undo/redo history");
        assert(editor.undoCountForTesting() > 0,
            "Restored history lost the committed timeline actions");
        assert(requireWidget!Button(editor, "undo").enabled(),
            "Restored history did not enable the Undo button");
    }

    // Virtualized painting must not scale with the full clip count.
    auto largeVideo = model.cloneTracks(TrackKind.video);
    largeVideo[0].clips = new TimelineClip[20_000];
    foreach (index, ref clip; largeVideo[0].clips)
    {
        clip.id = 1_000_000 + index;
        clip.assetIndex = 0;
        clip.start = cast(double) index * 0.05;
        clip.inPoint = 0.0;
        clip.outPoint = 0.04;
        clip.scale = 1.0;
        clip.opacity = 1.0;
    }
    model.restoreTimeline(largeVideo, model.cloneTracks(TrackKind.audio));
    timeline.modelChanged();
    timeline.setPlayhead(0.0, false);
    assert(driver.paint());
    assert(timeline.lastPaintedClipCountForTesting() < 400,
        "Timeline paint traversed the full 20,000-clip track instead of the viewport");

    writeln("Aurora Cut multi-track editor smoke test passed.");
    return 0;
}

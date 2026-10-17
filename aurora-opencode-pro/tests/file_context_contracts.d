module file_context_contracts;

import aurora;
import auroraopencode.core : ChatMessage, ChatSession, Settings, ensureMessageGraph,
    loadSettings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.filecontext;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.markdown : InlineStyle, BlockType, looksLikeLocalPath, localPathTokens, parseMarkdown;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.utf : toUTF32;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;

Widget find(Widget widget, string id)
{
    if (widget.id() == id) return widget;
    foreach (child; widget.children())
        if (auto found = find(child, id)) return found;
    return null;
}

void main()
{
    const state = buildPath(tempDir(), "aurora-file-context-" ~ to!string(MonoTime.currTime.ticks));
    const first = buildPath(state, "first project");
    const second = buildPath(state, "second project");
    const metadata = buildPath(state, "metadata");
    foreach (root; [first, second])
    {
        mkdirRecurse(buildPath(root, ".git"));
        mkdirRecurse(buildPath(root, "source"));
        write(buildPath(root, "source", "app.d"), "void main() {}\n");
        write(buildPath(root, "read me.md"), "example");
        write(buildPath(root, "README.md"), "example");
    }
    assert(absoluteFileTarget("source/../README.md:12:4", first) == buildPath(first, "README.md"));
    const uri = "file:///" ~ buildPath(first, "read me.md").replace("\\", "/").replace(" ", "%20");
    assert(absoluteFileTarget(uri, second) == buildPath(first, "read me.md"));
    assert(absoluteFileTarget("https://example.com/source/app.d", first) == "");
    assert(absoluteFileTarget("C:relative.txt", first) == "");
    assert(absoluteFileTarget(`\\server\share\folder\file.txt`, first) == `\\server\share\folder\file.txt`);

    auto store = new FileContextStore(metadata);
    foreach (prose; ["Position/size/coordinates", "block/inline/float/absolute",
        "client/scroll/page", "#9/#11/#14/#29", "and/or", "24/7", "TCP/IP"])
    {
        assert(!looksLikeLocalPath(toUTF32(prose)), "Prose misclassified: " ~ prose);
        assert(localPathTokens(toUTF32(prose)).length == 0, "Prose gained path tokens: " ~ prose);
        foreach (wrapped; [prose, "`" ~ prose ~ "`", "- " ~ prose,
            "| Meaning | Value |\n| --- | --- |\n| " ~ prose ~ " | plain |"])
            foreach (block; parseMarkdown(toUTF32(wrapped)))
            {
                foreach (run; block.runs) assert(run.target.length == 0, "Prose gained a link: " ~ wrapped);
                foreach (item; block.items)
                    foreach (run; item) assert(run.target.length == 0, "List prose gained a link: " ~ wrapped);
                foreach (cell; block.tableCells)
                    foreach (run; cell) assert(run.target.length == 0, "Table prose gained a link: " ~ wrapped);
            }
    }
    foreach (file; ["source/app.d", "./source", "../source", "C:/work/source", `\\server\share\source`, "file:///C:/work/source"])
        assert(looksLikeLocalPath(toUTF32(file)), "Real path lost recognition: " ~ file);
    const authored = parseMarkdown("[specification](https://example.com/client/scroll/page) [folder](./source)"d);
    size_t authoredLinks;
    foreach (run; authored[0].runs)
        if (run.target.length) ++authoredLinks;
    assert(authoredLinks == 2, "Authored web/folder links lost their targets");
    ChatSession session;
    session.id = "conversation-1";
    ChatMessage message;
    message.id = "message-1";
    message.role = "assistant";
    message.content = "See `source/app.d`, README.md, and `read me.md`. " ~
        "[source](source/app.d) https://example.com/source/app.d";
    session.messages ~= message;
    ensureMessageGraph(session);
    assert(store.resolve(session.id, message, "source/app.d", first) == buildPath(first, "source", "app.d"));
    assert(store.resolve(session.id, message, "README.md", first) == buildPath(first, "README.md"));
    assert(store.resolve(session.id, message, "read me.md", first) == buildPath(first, "read me.md"));
    const selected = toUTF32("See read me.md here");
    assert(store.referenceAt(session.id, message, selected, 8, first) == buildPath(first, "read me.md"));
    assert(store.resolve(session.id, message, "ordinary", first) == "");
    foreach (prose; ["Position/size/coordinates", "block/inline/float/absolute", "client/scroll/page", "#9/#11/#14/#29"])
        assert(store.resolve(session.id, message, prose, first) == "", "Prose gained filesystem metadata: " ~ prose);
    mkdirRecurse(buildPath(first, "actual", "nested", "folder"));
    assert(store.resolve(session.id, message, "actual/nested/folder", first) == buildPath(first, "actual", "nested", "folder"));
    assert(store.mainFolder(session, first) == first);
    store.pendingWrite()();
    // Reproduce a sidecar written by the old slash-count recognizer. resolve()
    // must reject it before a new capture has a chance to clean the message.
    const sidecar = buildPath(metadata, toHexString(sha256Of(session.id)) ~ ".json");
    auto savedMetadata = parseJSON(readText(sidecar));
    JSONValue fake;
    fake["mention"] = "Position/size/coordinates";
    fake["target"] = buildPath(first, "Position", "size", "coordinates");
    fake["tool"] = false;
    savedMetadata["messages"][message.id]["references"].array ~= fake;
    write(sidecar, savedMetadata.toString);
    store = new FileContextStore(metadata);
    assert(store.resolve(session.id, message, "Position/size/coordinates", second) == "",
        "A saved false reference bypassed the stricter recognizer");
    assert(store.resolve(session.id, message, "source/app.d", second) == buildPath(first, "source", "app.d"),
        "Moving a chat retargeted a historical reference");
    assert(store.mainFolder(session, second) == first);

    ChatMessage tool;
    tool.id = "message-2"; tool.role = "tool"; tool.toolName = "read";
    tool.parentId = message.id;
    tool.content = `Unrelated file contents: C:\other\unrelated.txt`;
    tool.toolArgs = `{"filePath":"` ~ buildPath(second, "source", "app.d").replace("\\", "\\\\") ~ `"}`;
    session.messages ~= tool;
    session.activeLeafId = tool.id;
    assert(store.mainFolder(session, second) == second, "Structured tool activity should outweigh a prose mention");
    assert(store.setMainFolder(session.id, first, second));
    assert(store.mainFolder(session, second) == first);
    store.pendingWrite()(); // Also verifies replacement of an existing sidecar.
    store = new FileContextStore(metadata);
    ChatSession header; header.id = session.id;
    assert(store.mainFolder(header, second) == first, "Manual choice was lost in unloaded sidebar row");
    store.redetect(session.id);
    assert(store.mainFolder(header, first) == second, "Unloaded row lost persisted inference evidence");
    assert(!store.setMainFolder(session.id, "missing-folder", first));

    ChatSession ambiguous;
    ambiguous.id = "ambiguous";
    foreach (i, folder; [first, second])
    {
        ChatMessage item;
        item.id = "ambiguous-" ~ to!string(i);
        if (i) item.parentId = ambiguous.messages[$ - 1].id;
        item.role = "assistant";
        item.content = buildPath(folder, "source", "app.d");
        // Quotes retain spaces as one reference.
        item.content = "`" ~ item.content ~ "`";
        ambiguous.messages ~= item;
    }
    ensureMessageGraph(ambiguous);
    assert(store.candidates(ambiguous, state).length == 2);
    assert(store.mainFolder(ambiguous, state) == state, "A tie silently chose an arbitrary folder");

    setOpencodeStateDirectoryForTesting(buildPath(state, "ui"));
    Settings settings;
    settings.workspace = first;
    settings.baseUrl = "http://127.0.0.1:1/v1";
    settings.apiKey = "fixture"; settings.model = "fixture";
    settings.quickTitle = false;
    saveSettings(settings);
    assert(loadSettings().smartFileContext);
    WindowOptions options;
    options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const deadline = MonoTime.currTime + seconds(10);
    while (root.startupPendingForTesting() && MonoTime.currTime < deadline)
    { window.onNativeTick(0.02); Thread.sleep(msecs(5)); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.appendToolMessageForTesting("read", "example", `{"filePath":"source/app.d"}`, 0, 0, "");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    assert(root.sessionContextMenuLabelsForTesting(0).canFind("Open main folder"));
    assert(root.sessionContextMenuLabelsForTesting(0).canFind("Re-detect main folder"));
    assert(root.invokeSessionContextMenuItemForTesting(0, "Copy main folder path"));
    root.openMessageContextMenuForTesting(0);
    assert(driver.paint());
    window.saveScreenshot(buildPath(state, "smart-file-context-menu.ppm"));
    root.persistForTesting();
    root.dismissPopupForTesting();
    assert(root.toggleSettingsSectionForTesting("oc-settings-options"));
    auto toggle = cast(CheckBox) find(root, "oc-smart-file-context");
    assert(toggle !is null);
    toggle.setChecked(false, true);
    root.flushRepositoryForTesting();
    assert(!loadSettings().smartFileContext);
    assert(!root.sessionContextMenuLabelsForTesting(0).canFind("Open main folder"));
    assert(!root.sessionContextMenuLabelsForTesting(0).canFind("Re-detect main folder"));
    assert(root.systemPromptViewerTextForTesting().indexOf("## File references") < 0);
    root.dismissPopupForTesting();
    assert(root.toggleSettingsSectionForTesting("oc-settings-options"));
    toggle = cast(CheckBox) find(root, "oc-smart-file-context");
    assert(toggle !is null);
    toggle.setChecked(true, true);
    root.flushRepositoryForTesting();
    assert(loadSettings().smartFileContext);
    assert(root.sessionContextMenuLabelsForTesting(0).canFind("Open main folder"));
    assert(root.systemPromptViewerTextForTesting().indexOf("## File references") >= 0);
    root.dismissPopupForTesting();
    root.newChatForTesting();
    root.beginStreamForTesting();
    const example = "**Yes, the authority exists.** Position/size/coordinates are defined by specs.\n\n" ~
        "- **Positioning contexts:** block/inline/float/absolute layout.\n" ~
        "- **Coordinates as numbers:** client/scroll/page coordinate spaces.\n" ~
        "- **Text metrics:** Unicode UAX #9/#11/#14/#29.\n\n" ~
        "A real file still links: source/app.d and [web reference](https://example.com/spec).";
    root.streamContentForTesting(example);
    root.finishStreamForTesting();
    root.projectTranscriptForTesting();
    assert(driver.paint());
    foreach (prose; ["Position/size/coordinates", "block/inline/float/absolute", "client/scroll/page", "#9/#11/#14/#29"])
        assert(root.messagePathLinkRectForTesting(0, prose).width == 0, "Rendered prose was linked: " ~ prose);
    assert(root.messagePathLinkRectForTesting(0, buildPath(first, "source", "app.d")).width > 0,
        "A real file stopped carrying its absolute target");
    window.saveScreenshot(buildPath(state, "prose-and-real-paths.ppm"));
    writeln("PASS absolute references, filenames, spaces, file URI, UNC, line suffixes, project moves, restart, tool weighting, manual folder, re-detect, unloaded sidebar and ambiguity; artifacts=", state);
}

module auroraopencode_pro_headless_smoke;

import aurora;
import aurora.render.drawlist : DrawList;
import aurora.render.software : SoftwareRenderer;
import aurora.surface : Surface;
import auroraopencode.appui : OpenCodeRoot, SessionListView;
import auroraopencode.core : ChatMessage, ChatRequestMessage, ChatSession,
    OpenCodeToolCall,
    activeMessagePath, ensureMessageGraph, newMessageId,
    opencodeComposerHeight, opencodeContentMaxWidth, opencodeTheme,
    setOpencodeStateDirectoryForTesting, siblingMessages;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import auroraopencode.markdown : MdComposition, composeMarkdown, paintMarkdown,
    parseMarkdown;
import auroraopencode.rebuild : planRebuild, rebuildHelperArgv;
import auroraopencode.runtime : AgentEventKind, readAgentRuntimeEvents;
import auroraopencode.tools : previewToolDiff;
import core.time : msecs, seconds;
import core.thread : Thread;
import std.array : join;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;
import std.process : environment;
import std.string : indexOf, join;
import std.utf : toUTF32;

/// Guard against the experimental TrueType `natural` hinter, whose grid
/// fitting rewrote real glyph outlines (Consolas `X` lost its lower-left arm
/// at 17px). The app must render with hinting off plus the contrast curve.
private void verifyNativeTextGlyphs()
{
    import auroraopencode.core : enableNativeTextRendering;
    enableNativeTextRendering();
    const mode = environment.get("AURORA_HINTING", "");
    assert(mode != "natural" && mode != "1",
        "Native text rendering must not enable the experimental hinter");
    auto fonts = new FontSystem();
    auto face = fonts.monospaceFace;
    auto atlas = new GlyphAtlas(2048, 1024);
    const px = 17;
    const glyph = atlas.glyphByIndex(face, face.glyphIndex('X'), px,
        FontRenderMode.sharp, 0);
    bool[4] quadrants;
    foreach (row; 0 .. glyph.region.height)
        foreach (col; 0 .. glyph.region.width)
        {
            const coverage = atlas.pixels()[
                (glyph.region.y + row) * atlas.width +
                (glyph.region.x + col)];
            if (coverage <= 40) continue;
            const right = col >= glyph.region.width / 2;
            const bottom = row >= glyph.region.height / 2;
            quadrants[(bottom ? 2 : 0) + (right ? 1 : 0)] = true;
        }
    assert(quadrants[0] && quadrants[1] && quadrants[2] && quadrants[3],
        "Mono 'X' is missing a stroke (broken glyph rasterization)");
    writeln("Native text: mono X keeps all four strokes, hinting=",
        mode.length == 0 ? "off" : mode);
}

/// Regression: an inline-code run is split into several pill segments whose
/// padded backgrounds overlap. Backgrounds must be painted before any glyph,
/// otherwise a later segment's 3px left overhang erases the right side of the
/// previous segment's last glyph (the `X` in `SYNTAX` rendered as `>`).
private void verifyInlineCodePillGlyphs()
{
    auto fonts = FontSystem.sharedInstance();
    auto blocks = parseMarkdown("- `SYNTAX OK (27874 chars of JS)` OK\n"d);
    auto composition = composeMarkdown(blocks, 700, false);
    auto list = new DrawList(fonts);
    list.reset(Size(420, 40), Color(18, 20, 24, 255));
    auto canvas = Canvas(list, 420, 40);
    paintMarkdown(canvas, composition, 4, 6);
    auto surface = new Surface(420, 40);
    SoftwareRenderer.renderInto(list, surface);

    foreach (item; composition.items)
    {
        if (!item.codePill || item.layout is null) continue;
        auto text = item.layout.text();
        foreach (glyph; item.layout.glyphs)
        {
            if (glyph.clusterStart >= text.length ||
                text[glyph.clusterStart] != 'X')
                continue;
            const cellX = 4 + cast(int) (item.x + glyph.x);
            const cellY = 6 + cast(int) item.y;
            const advance = maxInt(1, cast(int) (glyph.advanceX + 0.5));
            bool leftInk;
            bool rightInk;
            foreach (row; 0 .. 14)
                foreach (col; 0 .. advance)
                {
                    const x = cellX + col;
                    const y = cellY + row;
                    if (x < 0 || y < 0 || x >= surface.width() ||
                        y >= surface.height())
                        continue;
                    const pixel = surface.pixels()[cast(size_t) y *
                        cast(size_t) surface.width() + cast(size_t) x];
                    const lum = ((pixel >> 16) & 0xff) +
                        ((pixel >> 8) & 0xff) + (pixel & 0xff);
                    if (lum <= 200) continue;
                    if (col >= advance / 2) rightInk = true;
                    else leftInk = true;
                }
            assert(leftInk && rightInk,
                "Inline-code 'X' lost a stroke to an overlapping pill background");
            writeln("Inline code pill: X keeps both strokes");
            return;
        }
    }
    assert(false, "Inline-code pill 'X' not found in the composition");
}

/// Regression: while a reply streams in the bubble composes it incrementally
/// (only the block still growing is recomposed). The result must match a
/// one-shot compose of the whole document, or text would shift and jump as the
/// message arrives.
private void verifyIncrementalMarkdownCompose()
{
    import std.math : abs;
    import auroraopencode.markdown : MarkdownComposer;

    immutable dstring full =
        "# Heading\n\n"d ~
        "A paragraph with **bold**, `code`, and a [link](https://opencode.ai).\n\n"d ~
        "```d\nvoid main() {}\n\nint x = 1;\n```\n\n"d ~
        "## Sub heading\nright after the heading with `x` and a [link](https://y).\n\n"d ~
        "- one\n- two\n- three\n\n"d ~
        "> a quote line\n\n"d ~
        "Final paragraph that keeps growing and growing."d;

    const width = 640;
    MarkdownComposer composer;
    MdComposition incremental;
    for (size_t n = 0; n <= full.length; n += 3)
        composer.compose(incremental, full[0 .. n], width, false);
    composer.compose(incremental, full, width, false);

    auto reference = composeMarkdown(parseMarkdown(full), width, false);

    assert(incremental.items.length == reference.items.length,
        "incremental compose produced a different item count");
    assert(abs(incremental.height - reference.height) < 0.5,
        "incremental compose produced a different height");
    foreach (i; 0 .. reference.items.length)
    {
        assert(incremental.items[i].kind == reference.items[i].kind,
            "incremental compose reordered markdown items");
        assert(abs(incremental.items[i].y - reference.items[i].y) < 0.5,
            "incremental compose placed markdown items at a different y");
        assert(abs(incremental.items[i].x - reference.items[i].x) < 0.5,
            "incremental compose placed markdown items at a different x");
    }
    writeln("Incremental markdown compose matches a full compose");

    // The last block must not reserve a trailing gap (it showed as a phantom gap
    // below every assistant reply). A two-paragraph document is therefore
    // exactly two single-paragraph heights plus one inter-block gap.
    {
        auto one = composeMarkdown(parseMarkdown("same paragraph text\n"d),
            width, false);
        auto two = composeMarkdown(parseMarkdown(
            "same paragraph text\n\nsame paragraph text\n"d), width, false);
        assert(one.trailingGap > 0,
            "a paragraph should report the gap it would add after itself");
        assert(abs(two.height - (2 * one.height + one.trailingGap)) < 0.5,
            "the last markdown block still reserved a trailing gap");
        writeln("No trailing gap below the last markdown block");
    }
}

/// Regression: `std.string.indexOf` returns `ptrdiff_t`, and -1 means "not
/// found". The inline-link parser compared that sentinel against unsigned
/// indices and then used it as a slice bound, so a stray `[` with no `]`
/// (followed later by a `)`) sliced to `size_t.max`. With bounds checks off -
/// the shipped release build - that oversized slice was copied into the run
/// list and corrupted the heap; the process then died inside MSVCR120 with no
/// usable stack. This exact document threw `ArraySliceError` before the fix.
private void verifyStrayBracketParsing()
{
    auto blocks = parseMarkdown("(a [b)"d);
    auto composition = composeMarkdown(blocks, 400, false);
    assert(composition.height >= 0.0,
        "a stray '[' must produce a valid composition");

    // A well-formed link must still parse to a link run with its target.
    auto linked = composeMarkdown(parseMarkdown("[x](https://opencode.ai)"d),
        400, false);
    bool sawLink;
    foreach (item; linked.items)
        if (item.target.length > 0) sawLink = true;
    assert(sawLink, "a well-formed markdown link must still parse");
    writeln("Stray bracket does not slice past the document");
}

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
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

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private JSONValue makeSession(string title, string messageBody)
{
    JSONValue session;
    session["title"] = title;
    session["model"] = "deepseek/deepseek-v4.1-flash";
    session["thinking"] = false;
    JSONValue messages = JSONValue(string[].init);
    JSONValue user;
    user["role"] = "user";
    user["content"] = "Hello";
    user["time"] = "09:00";
    messages.array ~= user;
    JSONValue assistant;
    assistant["role"] = "assistant";
    assistant["content"] = messageBody;
    assistant["time"] = "09:01";
    messages.array ~= assistant;
    session["messages"] = messages;
    return session;
}

private void writeStartupState(string stateDir)
{
    JSONValue root;
    JSONValue sessions = JSONValue(string[].init);
    sessions.array ~= makeSession("alpha one",
        "A [link](https://opencode.ai) and a code block:\n```d\nvoid main() {}\n```");
    sessions.array ~= makeSession("beta two", "Plain reply two.");
    sessions.array ~= makeSession("gamma three", "Plain reply three.");
    root["sessions"] = sessions;
    root["current"] = 1;
    write(buildPath(stateDir, "sessions.json"), root.toString());
}

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-pro-smoke-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    writeStartupState(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);
    verifyNativeTextGlyphs();
    verifyInlineCodePillGlyphs();
    verifyIncrementalMarkdownCompose();
    verifyStrayBracketParsing();

    WindowOptions options;
    options.title = "Aurora OpenCode Pro headless";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);

    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "Initial pro paint failed");
    root.tickTree(0.02);
    assert(driver.paint(), "Second pro paint failed");

    // Git-independent Changes table is always available from the toolbar,
    // including in an ordinary non-repository workspace.
    auto changesButton = requireWidget!Button(root, "oc-changes");
    changesButton.onClick();
    root.tickTree(0.02);
    assert(findById(root, "oc-changes-list") !is null,
        "Changes button did not open the snapshot table");
    assert(!requireWidget!Button(root, "oc-changes-revert-file").enabled(),
        "Revert must be disabled when there is no selected change");
    requireWidget!Button(root, "oc-changes-close").onClick();
    root.tickTree(0.02);
    writeln("Standalone Changes table opens without Git");

    // Context meter starts empty: the restored replies have no API usage yet.
    auto usageBadge = requireWidget!Widget(root, "oc-usage");
    assert(root.contextUsageTextForTesting() == "0%",
        "Context badge should read 0% until usage is reported");
    writeln("Context badge initially: ", root.contextUsageTextForTesting());

    auto sessions = requireWidget!SessionListView(root, "oc-sessions");
    auto filter = requireWidget!TextField(root, "oc-filter");
    assert(root.sessionCountForTesting() == 3, "Expected 3 restored sessions");
    assert(sessions.items().length == 3, "Session list should show 3 rows");
    writeln("Restored sessions: ", sessions.items().length);

    // Filter narrows the list and remaps the selected row.
    filter.setText("beta");
    root.tickTree(0.02);
    assert(sessions.items().length == 1, "Filter did not narrow the list");
    assert(sessions.selectedIndex() == 0, "Filtered current row not selected");
    writeln("Filtered rows: ", sessions.items().length);
    filter.setText("");
    root.tickTree(0.02);
    assert(sessions.items().length == 3, "Clearing the filter did not restore rows");

    // The sidebar sizes its nested header/search VBox from a manual
    // preferredHeight (Box.onLayout lays children out from hints and ignores a
    // child's measured size). That height once hardcoded a stale gap total, so
    // the column came out 6 px short and clipped the search field's bottom
    // border. Assert every header row fits inside the column's bounds so a
    // spacing/row change can never silently clip it again.
    auto headerColumn = requireWidget!Widget(root, "oc-header-column");
    const headerBounds = headerColumn.bounds();
    int headerRows = 0;
    foreach (child; headerColumn.children())
    {
        if (!child.visible()) continue;
        const childBounds = child.bounds();
        assert(childBounds.bottom() <= headerBounds.height,
            "Header row overflows vertically: bottom " ~
            to!string(childBounds.bottom()) ~ " > column height " ~
            to!string(headerBounds.height));
        assert(childBounds.right() <= headerBounds.width,
            "Header row overflows horizontally: right " ~
            to!string(childBounds.right()) ~ " > column width " ~
            to!string(headerBounds.width));
        ++headerRows;
    }
    assert(headerRows == 4, "Expected 4 header rows, got " ~ to!string(headerRows));
    writeln("Header rows fit inside the search column: ", headerRows,
        " rows, ", headerBounds.height, " px");

    // Rename via the sidebar context menu.
    sessions.onContextMenuRequested(1, Point(10, 10));
    root.tickTree(0.02);
    auto menu = cast(ContextMenu) currentTransientPopup(root);
    assert(menu !is null, "Session context menu did not open");
    bool renamed;
    foreach (item; menu.items())
    {
        if (item.label == toUTF32("Rename…"))
        {
            item.action();
            renamed = true;
            break;
        }
    }
    assert(renamed, "Rename item missing from the context menu");
    root.tickTree(0.02);
    assert(driver.paint(), "Rename dialog did not paint after opening");
    auto renameField = requireWidget!TextField(root, "oc-rename-field");
    renameField.setText("Renamed chat");
    root.tickTree(0.02);
    assert(driver.paint(), "Rename field edit did not paint");
    auto renameSave = requireWidget!Button(root, "oc-rename-save");
    driver.click(globalCenter(renameSave));
    root.tickTree(0.02);
    assert(driver.paint(), "Rename dialog did not paint after save");
    assert(root.sessionTitleForTesting(1) == "Renamed chat",
        "Rename did not update the session title");
    writeln("Renamed session title: ", root.sessionTitleForTesting(1));
    dismissTransientPopups(root);
    root.tickTree(0.02);

    // Delete a session via the list's Delete-key hook.
    sessions.onDeleteRequested(0);
    root.tickTree(0.02);
    assert(driver.paint(), "Delete did not repaint");
    assert(root.sessionCountForTesting() == 2, "Delete did not remove a session");
    assert(sessions.items().length == 2, "Session list did not shrink after delete");
    writeln("Sessions after delete: ", root.sessionCountForTesting());

    // Markdown bubbles (code blocks + links) paint and stay interactive.
    root.addConversationForTesting(
        ["assistant"],
        ["```d\nimport std.stdio;\nvoid main() { writeln(\"hi\"); }\n```"]);
    assert(driver.paint(), "Code bubble did not paint");
    writeln("Pro markdown bubble painted");

    // Thinking blocks: collapsed to a slim "Thinking" header by default (like
    // the original opencode app), expand/collapse on click, and the animation
    // clock advances while live.
    root.addConversationForTestingWithReasoning(
        ["assistant"], ["The answer."], ["Let me reason about this first."]);
    assert(root.lastThinkingCollapsedForTesting(),
        "Thinking block should start collapsed");
    root.toggleLastThinkingForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded thinking did not repaint");
    assert(!root.lastThinkingCollapsedForTesting(),
        "Thinking block did not expand on toggle");
    // Regression: a mid-stream rebuild must not snap the reasoning block shut
    // again (the column is rebuilt on every throttled stream event).
    root.rebuildForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Rebuild did not repaint after expanding thinking");
    assert(!root.lastThinkingCollapsedForTesting(),
        "A rebuild collapsed the thinking block the user expanded");
    root.toggleLastThinkingForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapsed thinking did not repaint");
    assert(root.lastThinkingCollapsedForTesting(),
        "Thinking block did not collapse again");
    writeln("Thinking blocks collapse by default and expand on click");

    // Chat quality: only the latest assistant reply carries the action pill
    // (Regenerate / Retry); user messages and older bubbles stay clean. Edit &
    // resend is available from the right-click context menu instead.
    root.addConversationForTesting(["user"], ["A new user message."]);
    assert(root.lastBubbleActionForTesting() == "",
        "User message should not carry an action pill");
    root.addConversationForTesting(["assistant"], ["A normal reply."]);
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Latest assistant reply did not get the Regenerate pill");
    assert(root.lastBubbleSecondaryActionForTesting() == "Continue",
        "Latest assistant reply did not get the Continue pill");
    // Older bubbles (including the user message) have no visible pill.
    const count = root.messageCountForTesting();
    assert(root.bubbleActionForTesting(cast(int) count - 2) == "",
        "Older user bubble should not carry an action pill");
    const totalBeforeRegenerate = root.totalMessageCountForTesting();
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an assistant reply");
    // After dropping the reply, the user message is the last bubble and has no
    // pill; the Regenerate action is back on the context menu.
    assert(root.lastBubbleActionForTesting() == "",
        "After regenerate the last bubble should have no pill");
    const countAfterRegenerate = root.messageCountForTesting();
    assert(countAfterRegenerate == cast(int) count - 1,
        "Regenerate should drop the reply from the visible path");
    assert(root.totalMessageCountForTesting() == totalBeforeRegenerate,
        "Regenerate must keep the replaced reply stored as a branch");

    // Edit & resend the newest user message via the right-click context menu.
    root.openMessageContextMenuForTesting(countAfterRegenerate - 1);
    root.tickTree(0.02);
    assert(driver.paint(), "Message context menu did not paint");
    auto messageMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(messageMenu !is null, "Message context menu did not open");
    bool edited;
    foreach (item; messageMenu.items())
    {
        if (item.label == toUTF32("Edit & resend"))
        {
            item.action();
            edited = true;
            break;
        }
    }
    assert(edited, "Edit & resend missing from the message context menu");
    root.tickTree(0.02);
    assert(driver.paint(), "Edit & resend did not repaint");
    dismissContextMenus(root);
    root.tickTree(0.02);
    assert(root.messageCountForTesting() == countAfterRegenerate,
        "Edit & resend must not remove the original run");
    assert(root.inputTextForTesting() == "A new user message.",
        "Edit & resend did not prefill the input");
    assert(root.pendingEditIndexForTesting() >= 0,
        "Edit & resend did not arm an edit for submit");
    root.cancelPendingEditForTesting();
    writeln("Edit & resend prefilled input: ", root.inputTextForTesting());

    // Regression: the context menu on an older user message targets THAT
    // message, not the last one (D foreach closure capture bug).
    root.addConversationForTesting(
        ["user", "assistant", "user"],
        ["edit me zero", "reply one", "edit me two"]);
    const menuCount = root.messageCountForTesting();
    const totalBeforeOlderEdit = root.totalMessageCountForTesting();
    root.openMessageContextMenuForTesting(cast(int) menuCount - 3);
    root.tickTree(0.02);
    auto olderMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(olderMenu !is null, "Older message context menu did not open");
    bool olderEdited;
    foreach (item; olderMenu.items())
    {
        if (item.label == toUTF32("Edit & resend"))
        {
            item.action();
            olderEdited = true;
            break;
        }
    }
    assert(olderEdited, "Older message Edit & resend missing");
    root.tickTree(0.02);
    dismissContextMenus(root);
    root.tickTree(0.02);
    assert(root.inputTextForTesting() == "edit me zero",
        "Older message Edit & resend targeted the wrong message");
    assert(root.messageCountForTesting() == menuCount,
        "Older message Edit & resend must not remove its own run");
    assert(root.totalMessageCountForTesting() == totalBeforeOlderEdit,
        "Older message Edit & resend must keep the original run stored");
    assert(root.pendingEditIndexForTesting() >= 0,
        "Older message Edit & resend did not arm an edit");
    root.cancelPendingEditForTesting();
    writeln("Context menu targets its own message (no foreach capture bug)");

    // --- Message text selection + Copy (Pro) ----------------------------
    // A trailing assistant keeps the next "regenerate" case ending on an
    // assistant bubble, exactly as it did before this block was inserted.
    root.addConversationForTesting(["user", "assistant"],
        ["select this text", "trailing assistant reply"]);
    const selIndex = root.messageCountForTesting() - 2;
    root.tickTree(0.02);
    assert(driver.paint(), "Selection test did not paint");

    // Dragging across the user bubble selects its text.
    const selOrigin = root.messageTextOriginForTesting(selIndex);
    const selEnd = root.messageTextEndForTesting(selIndex);
    assert(selOrigin.x >= 0 && selEnd.x > selOrigin.x,
        "Message text selection anchors were not found");
    driver.drag(selOrigin, selEnd);
    root.tickTree(0.02);
    assert(driver.paint(), "Drag selection did not repaint");
    assert(root.selectedMessageTextForTesting(selIndex) == "select this text",
        "Dragging across the message did not select its text");

    // Select all from the right-click menu, then Copy the selection.
    root.openMessageContextMenuForTesting(selIndex);
    root.tickTree(0.02);
    assert(driver.paint(), "Selection context menu did not paint");
    auto selMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(selMenu !is null, "Selection context menu did not open");
    bool selectedAll;
    foreach (item; selMenu.items())
        if (item.label == toUTF32("Select all"))
        {
            item.action();
            selectedAll = true;
            break;
        }
    assert(selectedAll, "Select all missing from the message context menu");
    root.tickTree(0.02);
    dismissContextMenus(root);
    assert(root.selectedMessageTextForTesting(selIndex) == "select this text",
        "Select all did not select the whole message");

    root.openMessageContextMenuForTesting(selIndex);
    root.tickTree(0.02);
    selMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(selMenu !is null, "Copy-selection menu did not reopen");
    bool copiedSelection;
    foreach (item; selMenu.items())
        if (item.label == toUTF32("Copy selection"))
        {
            item.action();
            copiedSelection = true;
            break;
        }
    assert(copiedSelection, "Copy selection missing when text is selected");
    assert(root.lastCopiedMessageTextForTesting() == "select this text",
        "Copy selection copied the wrong payload");
    dismissContextMenus(root);
    writeln("Message text selection + copy works from the context menu");

    // Keyboard shortcuts: a drag on transcript text focuses the bubble, so
    // Ctrl+C copies the selection and Ctrl+V pastes it into the composer (the
    // root hands focus back to the input before pasting).
    {
        driver.drag(selOrigin, selEnd);
        root.tickTree(0.02);
        assert(driver.paint(), "Keyboard-selection repaint failed");
        driver.pressKey(Key.c, cast(uint) KeyModifier.control);
        root.tickTree(0.02);
        assert(root.copiedMessageTextForTesting(selIndex) == "select this text",
            "Ctrl+C did not copy the transcript selection: '" ~
            root.copiedMessageTextForTesting(selIndex) ~ "'");
        // Clear the composer first so the paste assertion is exact.
        auto clipInput = requireWidget!TextArea(root, "oc-input");
        clipInput.setText("");
        root.tickTree(0.02);
        driver.pressKey(Key.v, cast(uint) KeyModifier.control);
        root.tickTree(0.02);
        assert(clipInput.textUtf8() == "select this text",
            "Ctrl+V did not paste into the composer: '" ~
            clipInput.textUtf8() ~ "'");
        clipInput.setText("");
        root.tickTree(0.02);
        writeln("Ctrl+C copies transcript selection and Ctrl+V pastes into composer");
    }

    // Regenerate still works after an edit.
    root.addConversationForTesting(
        ["assistant"], ["A reply that will be regenerated."]);
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered after an edit");
    assert(root.lastBubbleActionForTesting() == "Regenerate",
        "Pill did not refresh after the final regenerate");
    writeln("Chat-quality pill stays on the latest assistant reply");

    // --- Message edit + regenerate keep their runs (branch history) -------
    // Regenerating keeps the replaced reply stored and flips between runs with
    // the footer `‹ n/m ›` arrows.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["first prompt", "first answer"]);
    assert(root.messageCountForTesting() == 2,
        "Fresh branch session should show two messages");
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered in the branch session");
    assert(root.messageCountForTesting() == 1,
        "Regenerate should leave only the prompt visible");
    assert(root.totalMessageCountForTesting() == 2,
        "Regenerate must keep the replaced reply stored");
    root.addConversationForTesting(["assistant"], ["second answer"]);
    const branchReplyChild = root.messageCountForTesting() - 1;
    assert(root.bubbleVersionForTesting(branchReplyChild) == "2/2",
        "Regenerated reply should expose two branches");
    assert(root.invokeBubbleVersionPrevForTesting(branchReplyChild),
        "Branch back arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "first answer",
        "Branching back did not show the original reply");
    assert(root.invokeBubbleVersionNextForTesting(branchReplyChild),
        "Branch forward arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "second answer",
        "Branching forward did not return to the new reply");

    // Editing a prompt and submitting branches it instead of overwriting it.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["original prompt", "original answer"]);
    root.editAndResendForTesting(0);
    assert(root.pendingEditIndexForTesting() == 0,
        "Edit did not arm the first prompt");
    assert(root.inputTextForTesting() == "original prompt",
        "Edit did not prefill the prompt");
    assert(root.messageCountForTesting() == 2,
        "Edit must not change the visible conversation before submit");
    const editedIndex = root.commitEditForTesting("edited prompt");
    assert(editedIndex >= 0, "Edit submit did not create a new prompt");
    assert(root.messageVersionCountForTesting(editedIndex) == 2,
        "Edited prompt should have two versions");
    assert(root.totalMessageCountForTesting() == 3,
        "Edit submit must keep the original run stored");
    root.addConversationForTesting(["assistant"], ["edited answer"]);
    const editedUserChild = root.messageCountForTesting() - 2;
    assert(root.bubbleVersionForTesting(editedUserChild) == "2/2",
        "Edited prompt should expose two versions");
    assert(root.invokeBubbleVersionPrevForTesting(editedUserChild),
        "Prompt version back arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "original answer",
        "Switching to the original prompt did not show its answer");
    assert(root.invokeBubbleVersionNextForTesting(editedUserChild),
        "Prompt version forward arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "edited answer",
        "Switching forward did not restore the edited branch");
    // Continuing from a restored branch appends to it without disturbing the
    // other run.
    root.addConversationForTesting(["user"], ["continue here"]);
    assert(root.lastAssistantContentForTesting() == "continue here",
        "Continuing on a restored branch did not append to it");
    assert(root.invokeBubbleVersionPrevForTesting(editedUserChild),
        "Prompt version back arrow failed after continuing");
    assert(root.lastAssistantContentForTesting() == "original answer",
        "Continuing on one branch disturbed the other run");
    writeln("Edit + regenerate keep prior runs and branch navigation works");

    // Core graph persistence: a session saved with ids/activeLeaf must keep its
    // genuine root branch (two prompts sharing an empty parent), while a legacy
    // transcript with no ids is rebuilt as a single chain.
    {
        ChatMessage u1; u1.role = "user"; u1.content = "one";
        u1.id = newMessageId();
        ChatMessage a1; a1.role = "assistant"; a1.content = "answer";
        a1.id = newMessageId(); a1.parentId = u1.id;
        ChatMessage u2; u2.role = "user"; u2.content = "two";
        u2.id = newMessageId();
        ChatMessage a2; a2.role = "assistant"; a2.content = "answer2";
        a2.id = newMessageId(); a2.parentId = u2.id;
        ChatSession branched;
        branched.messages = [u1, a1, u2, a2];
        branched.activeLeafId = a2.id;
        ensureMessageGraph(branched);
        assert(branched.messages[2].parentId == "",
            "ensureMessageGraph relinked a genuine root branch");
        assert(activeMessagePath(branched).length == 2,
            "active path did not follow the second root branch");
        assert(siblingMessages(branched, 0).length == 2,
            "the two prompts should be siblings");
        ChatSession legacy;
        legacy.messages = [u1, a1];
        legacy.messages[0].id = ""; legacy.messages[0].parentId = "";
        legacy.messages[1].id = ""; legacy.messages[1].parentId = "";
        ensureMessageGraph(legacy);
        assert(legacy.messages[1].id.length > 0 &&
            legacy.messages[1].parentId == legacy.messages[0].id,
            "legacy transcript was not rebuilt as a chain");
        assert(activeMessagePath(legacy).length == 2,
            "legacy transcript active path should contain both messages");
    }
    writeln("Message-graph persistence keeps branches and repairs legacy files");

    // App-level round-trip: a regenerated reply survives a real save to
    // sessions.json followed by a startup-style reload, and the reloaded
    // branches stay navigable.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["p1", "a1"]);
    assert(root.prepareRegenerateForTesting(),
        "Regenerate was not offered in the round-trip session");
    root.addConversationForTesting(["assistant"], ["a2"]);
    assert(root.messageCountForTesting() == 2 &&
        root.totalMessageCountForTesting() == 3,
        "Round-trip session was not built with a stored branch");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.messageCountForTesting() == 2,
        "Reloaded branch session lost its active path");
    assert(root.totalMessageCountForTesting() == 3,
        "Reloaded branch session lost a stored run");
    const reloadedReply = root.messageCountForTesting() - 1;
    assert(root.bubbleVersionForTesting(reloadedReply) == "2/2",
        "Reloaded regenerated reply lost its version history");
    assert(root.invokeBubbleVersionPrevForTesting(reloadedReply),
        "Reloaded version back arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "a1",
        "Reloaded branch did not navigate back to the original run");
    assert(root.invokeBubbleVersionNextForTesting(reloadedReply),
        "Reloaded version forward arrow was not clickable");
    assert(root.lastAssistantContentForTesting() == "a2",
        "Reloaded branch did not navigate forward to the new run");
    writeln("Branches survive a save + reload with version navigation intact");
    const branchShots = buildPath(tempDir(), "aurora-opencode-branch-shots");
    if (!exists(branchShots)) mkdirRecurse(branchShots);
    assert(driver.paint(), "Branch viewer did not repaint");
    const branchNav = root.bubbleVersionNavBoundsForTesting(reloadedReply);
    const branchAction = root.bubbleActionBoundsForTesting(reloadedReply);
    assert(branchNav.width > 0 && branchAction.width > 0,
        "Branch version nav or action pill was not laid out");
    assert(branchNav.right() <= branchAction.x,
        "Version nav overlaps the action pill");
    window.saveScreenshot(buildPath(branchShots, "branch-nav.ppm"));
    writeln("Branch screenshot: ", branchShots);

    // Continue extends the current branch instead of replacing the assistant
    // reply. A provider truncation gets a precise non-repetition instruction,
    // and its finish reason survives persistence.
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Write a long answer", "The first portion."]);
    root.setLastFinishReasonForTesting("length");
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.lastBubbleSecondaryActionForTesting() == "Continue",
        "Continue disappeared after session reload");
    const beforeContinueTotal = root.totalMessageCountForTesting();
    assert(root.prepareContinueForTesting(),
        "Continue rejected a settled truncated reply");
    assert(root.totalMessageCountForTesting() == beforeContinueTotal + 1,
        "Continue replaced history instead of extending the branch");
    assert(root.lastUserMessageForTesting().indexOf("output limit") >= 0 &&
        root.lastUserMessageForTesting().indexOf("Do not repeat") >= 0,
        "truncated reply received the wrong continuation instruction: " ~
        root.lastUserMessageForTesting());

    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"],
        ["Implement the feature", "I stopped partway through."]);
    root.setTaskStateForTesting("Implement the feature", "blocked", "required");
    assert(root.prepareContinueForTesting(),
        "Continue rejected an incomplete durable task");
    assert(root.lastUserMessageForTesting().indexOf("durable objective") >= 0 &&
        root.lastUserMessageForTesting().indexOf("do not repeat successful") >= 0,
        "incomplete task received the wrong continuation instruction: " ~
        root.lastUserMessageForTesting());
    assert(root.taskStatusForTesting() == "active",
        "Continue did not resume the durable task state");
    writeln("Continue extends the branch with state-aware instructions");

    // Outgoing-request sanitizer: a stored assistant `tool_calls` message with
    // no (or partial) tool replies must never reach the provider, which
    // otherwise answers HTTP 400 ("insufficient tool messages following
    // tool_calls message").
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["start"]);
    root.appendDanglingToolCallsForTesting("call_dangling");
    root.addConversationForTesting(["user"], ["keep going"]);
    auto dangling = root.requestMessagesForTesting();
    foreach (m; dangling)
    {
        assert(!(m.role == "assistant" && m.toolCalls.length > 0),
            "Dangling assistant tool_calls reached the provider request");
        assert(m.role != "tool",
            "Orphan tool reply reached the provider request");
    }
    writeln("Outgoing request drops unanswered tool_calls (HTTP 400 guard)");

    // A fully-answered exchange is preserved verbatim.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["read it"]);
    root.appendToolRequestTurnForTesting("I need to inspect the file.",
        "call_ok", "read", `{}`);
    root.appendToolReplyForTesting("call_ok", "file contents");
    root.addConversationForTesting(["assistant"], ["done"]);
    auto answeredReqs = root.requestMessagesForTesting();
    bool sawCall, sawReply;
    foreach (i, m; answeredReqs)
    {
        if (m.role == "assistant" && m.toolCalls.length == 1)
        {
            sawCall = true;
            assert(m.reasoningContent == "I need to inspect the file.",
                "Tool continuation dropped provider reasoning_content");
            assert(i + 1 < answeredReqs.length &&
                answeredReqs[i + 1].role == "tool" &&
                answeredReqs[i + 1].toolCallId == "call_ok",
                "Answered tool call lost its adjacent reply");
            sawReply = true;
        }
    }
    assert(sawCall && sawReply,
        "A valid tool exchange was dropped by the sanitizer");
    writeln("Outgoing request keeps tool exchange + reasoning state");

    // Navigation during a turn is a view change, not ownership transfer. The
    // original conversation must keep receiving streamed bytes while a newly
    // created chat stays untouched, and its sidebar activity marker must remain.
    root.newChatForTesting();
    const ownerSession = cast(int) root.sessionCountForTesting() - 1;
    root.addConversationForTesting(["user"], ["work in the background"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.streamReasoningForTesting("planning");
    root.newChatForTesting();
    const viewingSession = root.currentSessionForTesting();
    assert(viewingSession != ownerSession, "New chat did not change the view");
    assert(root.turnOwnerSessionForTesting() == ownerSession,
        "New chat stole ownership from the running turn");
    assert(root.activeSessionRowsForTesting().length > 0,
        "Background turn lost its sidebar activity marker");
    root.streamContentForTesting("finished in the original chat");
    assert(root.lastMessageContentInSessionForTesting(viewingSession).length == 0,
        "Background response leaked into the selected new chat");
    assert(root.lastMessageContentInSessionForTesting(ownerSession) ==
        "finished in the original chat",
        "Background response did not stay with its owning chat before selection");
    root.selectSessionForTesting(ownerSession);
    assert(root.lastAssistantContentForTesting() ==
        "finished in the original chat",
        "Background response did not stay with its owning chat");
    root.finishStreamForTesting();
    writeln("Changing chats preserves the running turn's ownership");

    // True concurrency: two selected-at-different-times conversations own
    // distinct runtimes. Both remain active, output stays isolated, and Stop
    // affects only the conversation currently being viewed.
    root.newChatForTesting();
    const concurrentA = root.currentSessionForTesting();
    root.addConversationForTesting(["user"], ["run A"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.newChatForTesting();
    const concurrentB = root.currentSessionForTesting();
    root.addConversationForTesting(["user"], ["run B"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.queueContentInSessionForTesting(concurrentA, "A partial");
    root.queueContentInSessionForTesting(concurrentB, "B partial");
    root.tickTree(0.01);
    assert(root.sessionTurnBusyForTesting(concurrentA) &&
        root.sessionTurnBusyForTesting(concurrentB),
        "Two conversations did not remain active together");
    assert(root.activeSessionRowsForTesting().indexOf(",") >= 0,
        "Sidebar did not mark both concurrent conversations active");
    assert(root.lastMessageContentInSessionForTesting(concurrentA) ==
        "A partial" &&
        root.lastMessageContentInSessionForTesting(concurrentB) == "B partial",
        "Concurrent stream output crossed conversation boundaries");
    root.clickSendButtonForTesting();
    assert(!root.sessionTurnBusyForTesting(concurrentB),
        "Stop did not release the selected conversation");
    assert(root.sessionTurnBusyForTesting(concurrentA),
        "Stopping conversation B also stopped conversation A");
    root.finishStreamInSessionForTesting(concurrentA);
    writeln("Two conversations run concurrently with isolated Stop/output");

    // The button says Stop while a turn is active, so clicking it must stop
    // unconditionally—even when unsent composer text is present. Previously
    // that text was silently queued as guidance and the turn kept running.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["keep working"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.streamReasoningForTesting("still working");
    root.setInputForTesting("unsent text must remain unsent");
    root.clickSendButtonForTesting();
    assert(!root.turnBusyForTesting(), "Stop did not release the active turn");
    assert(root.queuedGuidanceCountForTesting() == 0,
        "Stop click queued composer text instead of stopping");
    assert(root.inputTextForTesting() == "unsent text must remain unsent",
        "Stop click consumed unsent composer text");
    assert(root.sendButtonTextForTesting() == "Send",
        "Stop did not restore the Send button");
    assert(root.taskStatusForTesting() == "blocked",
        "Stopped task did not leave active state");
    writeln("One Stop click immediately releases the turn");

    // Text that was explicitly submitted during a live turn is different from
    // untouched composer text: it is durable queued guidance. Stop must retain
    // it as a visible user turn rather than silently deleting the user's words.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["keep working"]);
    root.startTurnClockForTesting();
    root.beginStreamForTesting();
    root.queueGuidanceForTesting("also check the rebuild helper");
    root.clickSendButtonForTesting();
    assert(!root.turnBusyForTesting(),
        "Stop did not release a turn with queued guidance");
    assert(root.queuedGuidanceCountForTesting() == 0,
        "preserved guidance remained stranded in the queue");
    const preservedIndex = root.totalMessageCountForTesting() - 1;
    assert(root.messageRoleForTesting(preservedIndex) == "user" &&
        root.messageContentForTesting(preservedIndex) ==
            "also check the rebuild helper",
        "Stop did not preserve submitted guidance as a visible user turn");
    assert(root.taskStatusForTesting() == "blocked",
        "preserving guidance incorrectly kept the stopped task active");
    writeln("Stop preserves already-submitted guidance in the transcript");

    // Compaction is a context-pressure operation, not something performed on
    // every continuation. Below the threshold the model-visible prefix remains
    // stable; above it, old completed tool envelopes are checkpointed while the
    // actively continuing newest pair remains structurally valid.
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["big job"]);
    import std.array : replicate;
    const bigOutput = replicate("x", 20_000);
    foreach (i; 0 .. 12)
    {
        const id = "call_big_" ~ to!string(i);
        root.appendDanglingToolCallsForTesting(id);
        root.appendToolReplyForTesting(id, bigOutput);
    }
    root.addConversationForTesting(["assistant"], ["done"]);
    auto fat = root.requestMessagesForTesting();
    size_t fatBytes;
    foreach (m; fat) fatBytes += m.content.length;
    assert(fatBytes > 200_000, "compaction fixture was not large enough");
    auto stable = root.compactedRequestMessagesForTesting(1_000_000);
    int stableToolGroups;
    foreach (m; stable)
        if (m.role == "assistant" && m.toolCalls.length > 0)
            ++stableToolGroups;
    assert(stable.length == fat.length && stableToolGroups == 12,
        "under-budget request was needlessly compacted");
    auto slim = root.compactedRequestMessagesForTesting(8_000);
    size_t slimBytes;
    int toolCount, compactNotes;
    bool sawPair;
    foreach (i, m; slim)
    {
        slimBytes += m.content.length;
        if (m.role == "tool")
        {
            ++toolCount;
            assert(m.toolCallId.length > 0,
                "compaction dropped a tool reply's toolCallId");
        }
        if (m.role == "system" && m.content.indexOf("## Objective") >= 0 &&
            m.content.indexOf("## Work State") >= 0 &&
            m.content.indexOf("## Next Move") >= 0)
            ++compactNotes;
        assert(m.content.indexOf("earlier message elided") < 0,
            "compaction still emits content-free message placeholders");
        if (m.role == "assistant" && m.toolCalls.length == 1)
        {
            sawPair = true;
            assert(i + 1 < slim.length && slim[i + 1].role == "tool",
                "compaction broke tool-call/reply pairing");
        }
    }
    assert(toolCount == 1,
        "compaction did not retain exactly the active newest tool group");
    assert(compactNotes == 1,
        "compaction did not replace old tool groups with one control note");
    assert(sawPair, "compaction dropped the tool-call messages");
    assert(slimBytes < fatBytes, "compaction did not shrink the request");
    root.addConversationForTesting(["user"], ["Now verify the result."]);
    auto followupHistory = root.compactedRequestMessagesForTesting(8_000);
    foreach (m; followupHistory)
        assert(m.toolCalls.length == 0 && m.role != "tool",
            "new user turn replayed a completed tool/reasoning envelope");
    writeln("Compaction bounds old tool history and preserves recent pairing");

    // Oversized ordinary dialogue is summarized into one structured handoff,
    // preserving objective/work/blocker/next-move semantics for continuation.
    root.newChatForTesting();
    string[] checkpointRoles, checkpointBodies;
    checkpointRoles ~= "user";
    checkpointBodies ~= "Add per-chat draft autosave and verify restart recovery.";
    foreach (i; 0 .. 20)
    {
        checkpointRoles ~= (i % 2 == 0 ? "assistant" : "user");
        checkpointBodies ~= "checkpoint detail " ~ to!string(i) ~ " " ~
            replicate("z", 1_200);
    }
    root.addConversationForTesting(checkpointRoles, checkpointBodies);
    auto checkpointed = root.compactedRequestMessagesForTesting(2_000);
    int structuredCheckpoints;
    foreach (m; checkpointed)
    {
        if (m.role == "system" && m.content.indexOf("## Objective") >= 0 &&
            m.content.indexOf("## Important Details") >= 0 &&
            m.content.indexOf("### Active") >= 0 &&
            m.content.indexOf("### Blocked") >= 0 &&
            m.content.indexOf("## Next Move") >= 0)
            ++structuredCheckpoints;
        assert(m.content.indexOf("earlier message elided") < 0,
            "dialogue compaction emitted a lossy placeholder");
    }
    assert(structuredCheckpoints == 1,
        "oversized dialogue did not produce one structured checkpoint");
    writeln("Oversized dialogue compacts to a structured continuation checkpoint");

    // Long transcripts stay complete in the message graph but only the newest
    // page is materialized. This prevents a pathological chat from allocating
    // hundreds of MB during startup; older pages remain available on demand.
    root.newChatForTesting();
    string[] longRoles, longContents;
    foreach (i; 0 .. 250)
    {
        longRoles ~= "assistant";
        longContents ~= "history " ~ to!string(i);
    }
    root.addConversationForTesting(longRoles, longContents);
    assert(root.hiddenHistoryCountForTesting() == 130,
        "initial history page did not cap materialized messages");
    assert(root.messageColumnVisualCountForTesting() == 121,
        "history page should contain one loader plus 120 messages");
    root.loadOlderHistoryForTesting();
    assert(root.hiddenHistoryCountForTesting() == 10,
        "loading older history did not advance by one page");
    assert(root.requestMessagesForTesting().length == 250,
        "UI paging incorrectly removed stored/request history");
    writeln("Long transcripts render lazily without dropping history");

    // Streaming progress: the client must announce a tool by name as soon as
    // the name appears (arguments still streaming), so the UI can show
    // "Writing page.html ..." instead of looking stalled for several seconds.
    {
        auto client = new OpenCodeClient("https://example.invalid/v1", "k");
        client.resetStreamStateForTesting();
        // No throttle window, so every argument change emits progress and the
        // test never waits on a clock.
        client.setToolProgressIntervalMsForTesting(0);
        client.feedSseForTesting(
            `data: {"choices":[{"delta":{"content":"Creating it"}}]}` ~ "\n" ~
            `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"write","arguments":"{\"filePath\":\"page.html\","}}]}}]}` ~
            "\n");
        OpenCodeEvent[] mid;
        client.drain(mid);
        bool sawProgress;
        foreach (e; mid)
            if (e.kind == OpenCodeEventKind.toolCallDelta &&
                e.toolCalls.length == 1 && e.toolCalls[0].name == "write")
                sawProgress = true;
        assert(sawProgress,
            "Client did not announce the tool call while its args streamed");
        // More of the file body arrives: the client must push another progress
        // event so the live `+N -M` counters grow while the tool is still
        // streaming (this was previously emitted only once per tool name).
        client.feedSseForTesting(
            `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"content\":\"one\\ntwo\\nthree\","}}]}}]}` ~
            "\n");
        OpenCodeEvent[] streamed;
        client.drain(streamed);
        bool sawGrownProgress;
        foreach (e; streamed)
            if (e.kind == OpenCodeEventKind.toolCallDelta &&
                e.toolCalls.length == 1 &&
                e.toolCalls[0].arguments.length > 20)
                sawGrownProgress = true;
        assert(sawGrownProgress,
            "Client did not push throttled progress as the args grew");
        // The terminal event still carries the completed tool call.
        client.feedSseForTesting(
            `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}}"}}]}}]}` ~
            "\n");
        auto finalEvents = client.finishStreamForTesting();
        bool sawFinal;
        foreach (e; finalEvents)
            if (e.kind == OpenCodeEventKind.toolCalls)
                sawFinal = true;
        assert(sawFinal, "Stream did not finish with a toolCalls event");
        writeln("Client announces a tool call while its arguments stream");
    }

    // Live diff preview: a file-mutating tool's arguments are counted as they
    // stream, so the UI can show a growing `+N -M` before the tool runs.
    {
        int adds, dels;
        assert(previewToolDiff("write",
            `{"filePath":"a.txt","content":"one\ntwo\nthr`, adds, dels),
            "Partial write args did not produce a preview");
        assert(adds == 3 && dels == 0,
            "Partial write preview wrong: +" ~ to!string(adds) ~ " -" ~
            to!string(dels));
        assert(previewToolDiff("write",
            `{"filePath":"a.txt","content":"one\ntwo"}`, adds, dels) &&
            adds == 2 && dels == 0,
            "Complete write preview wrong");
        assert(previewToolDiff("edit",
            `{"filePath":"a.txt","oldString":"beta","newString":"BETA\nextra"}`,
            adds, dels) && adds == 2 && dels == 1,
            "Edit preview wrong: +" ~ to!string(adds) ~ " -" ~ to!string(dels));
        assert(!previewToolDiff("read", `{"filePath":"a.txt"}`, adds, dels),
            "Read should not report a diff");
        writeln("Live tool diff preview counts streamed write/edit args");
    }

    // Reasoning progress: CommandCode/DeepSeek gateways stream the chain of
    // thought as `delta.reasoning` (with a parallel `reasoning_details` array),
    // not `reasoning_content`. Missing those keys made the entire reasoning
    // phase look like an endless cold start.
    {
        auto client = new OpenCodeClient("https://example.invalid/v1", "k");
        client.resetStreamStateForTesting();
        client.feedSseForTesting(
            `data: {"choices":[{"delta":{"reasoning":"We","reasoning_details":[{"type":"reasoning.text","text":"We"}]}}]}` ~
            "\n");
        OpenCodeEvent[] events;
        client.drain(events);
        bool sawReasoning;
        int reasoningCount;
        foreach (e; events)
        {
            if (e.kind != OpenCodeEventKind.delta || !e.reasoning) continue;
            ++reasoningCount;
            if (e.text == "We") sawReasoning = true;
        }
        assert(sawReasoning,
            "Client dropped a `reasoning` delta (looks like a cold start)");
        assert(reasoningCount == 1,
            "Reasoning text duplicated from reasoning + reasoning_details");
        // `reasoning_details` is still honored when `reasoning` is absent.
        client.feedSseForTesting(
            `data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"Thinking"}]}}]}` ~
            "\n");
        OpenCodeEvent[] detailEvents;
        client.drain(detailEvents);
        bool sawDetail;
        foreach (e; detailEvents)
            if (e.kind == OpenCodeEventKind.delta && e.reasoning &&
                e.text == "Thinking")
                sawDetail = true;
        assert(sawDetail, "Client dropped a reasoning_details delta");
        writeln("Client surfaces streamed reasoning as it arrives");
    }

    // Context usage meter: the toolbar badge shows the exact model-visible
    // input as a percentage of the context window. Output/billing totals must
    // not make context occupancy jump while a response streams. The
    // limit comes from the model catalog: deepseek-v4.1-flash (the OpenCode
    // gateway id) has a 1,000,000-token context window.
    root.addConversationForTesting(["assistant"], ["A reply that used tokens."]);
    root.recordContextUsageForTesting(240000, 10000, 250000);
    assert(driver.paint(), "Context badge did not paint after usage");
    assert(root.contextUsageTextForTesting() == "24%",
        "Badge should show 240000/1000000 = 24% input context");
    writeln("Context badge after usage: ", root.contextUsageTextForTesting());

    assert(!root.isContextTooltipOpenForTesting(),
        "Tooltip must be closed before hovering the badge");
    driver.moveTo(globalCenter(usageBadge));
    root.tickTree(0.02);
    assert(driver.paint(), "Repaint after hovering the badge failed");
    assert(!root.isContextTooltipOpenForTesting(),
        "Hover tooltip must wait for the hover-intent delay");
    // Rest on the badge until the hover-intent delay elapses.
    foreach (_; 0 .. 20) root.tickTree(0.05);
    assert(driver.paint(), "Tooltip did not paint after hover");
    assert(root.isContextTooltipOpenForTesting(),
        "Hovering the badge did not open the context tooltip");
    const tooltipBounds = root.contextTooltipBoundsForTesting();
    const badgeBounds = root.contextBadgeBoundsForTesting();
    assert(tooltipBounds.height > 0 &&
        tooltipBounds.bottom() <= badgeBounds.y,
        "Context tooltip should open above the badge");
    const tooltip = root.contextTooltipTextForTesting();
    assert(tooltip.length > 0, "Context tooltip text is empty");
    assert(tooltip.indexOf("Context usage") >= 0, "Tooltip lacks the title");
    // Matches both the OpenCode id (`deepseek-v4.1-flash`) and a legacy
    // CommandCode id (`deepseek/deepseek-v4.1-flash`), which contains it.
    assert(tooltip.indexOf("deepseek-v4.1-flash") >= 0,
        "Tooltip lacks the model");
    assert(tooltip.indexOf("1,000,000") >= 0, "Tooltip lacks the context limit");
    assert(tooltip.indexOf("240,000") >= 0, "Tooltip lacks active input");
    assert(tooltip.indexOf("24%") >= 0, "Tooltip lacks the usage percent");
    assert(tooltip.indexOf("10,000") >= 0, "Tooltip lacks last output tokens");
    writeln("Context tooltip shows the usage breakdown on hover");

    // Moving away from the badge dismisses the tooltip.
    driver.moveTo(Point(4, 700));
    root.tickTree(0.02);
    assert(driver.paint(), "Tooltip did not repaint after leaving");
    assert(!root.isContextTooltipOpenForTesting(),
        "Leaving the badge did not dismiss the context tooltip");

    // The meter follows the active session: a session without recorded usage
    // resets the badge, and switching back restores the persisted count.
    sessions.onSelectionChanged(1);
    root.tickTree(0.02);
    assert(root.contextUsageTextForTesting() == "0%",
        "Badge should reset to 0% for a session without usage");
    root.recordEstimatedContextUsageForTesting(13_000);
    assert(root.contextUsageTextForTesting() == "~2%",
        "Provider-less context must show a clearly estimated non-zero value");
    sessions.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.contextUsageTextForTesting() == "24%",
        "Badge should restore the persisted usage for the session");
    root.recordEstimatedContextUsageForTesting(30_000);
    assert(root.contextUsageTextForTesting() == "~3%",
        "A new request estimate must supersede stale exact usage");
    root.recordContextUsageForTesting(30_000, 10_000, 40_000);
    assert(root.contextUsageTextForTesting() == "3%",
        "Fresh prompt usage must replace the estimate without counting output");
    writeln("Context meter follows the active session");

    // --- Projects -------------------------------------------------------
    // The sandbox is the default project (first in the rail) and owns the
    // restored chats. Creating, switching, persisting, and removing projects
    // must all keep each project's conversation list separate.
    auto projects = requireWidget!ListView(root, "oc-projects");
    const sandboxVisible = root.visibleSessionCountForTesting();
    assert(root.projectCountForTesting() == 1,
        "Expected only the sandbox project");
    assert(root.projectNamesForTesting()[0] == "Sandbox",
        "Sandbox must be the first project");
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Sandbox must be active by default");
    assert(root.activeProjectPathForTesting().indexOf("sandbox") >= 0,
        "Sandbox folder should live under the state directory: " ~
        root.activeProjectPathForTesting());
    assert(projects.items().length == 1, "Rail should show one project tile");
    writeln("Sandbox is the default project: ",
        root.activeProjectPathForTesting());

    // Conversations are listed newest-first: the newest-created session is the
    // top row, so visible rows map to descending session indices.
    assert(root.visibleSessionCountForTesting() >= 2,
        "Need at least two restored sessions to check ordering");
    for (int row = 0; row + 1 < root.visibleSessionCountForTesting(); ++row)
        assert(root.visibleSessionIndexAtRowForTesting(row) >
            root.visibleSessionIndexAtRowForTesting(row + 1),
            "Conversations must be listed newest-first");
    assert(root.visibleSessionIndexAtRowForTesting(0) ==
        cast(int) root.sessionCountForTesting() - 1,
        "The newest conversation should be the top row");
    writeln("Conversations are listed newest-first");

    // The merged custom titlebar owns the top band and the project rail starts
    // collapsed to icon width; the toggle expands it and the state persists.
    assert(root.hasCustomTitleBarForTesting(),
        "The merged custom titlebar should own the top band");
    const titleText = root.titleBarTitleForTesting();
    assert(titleText.indexOf("Aurora OpenCode") == 0,
        "The titlebar should show 'Aurora OpenCode' at its left, got '" ~
        titleText ~ "'");
    // ...followed by the exe's build date/time, e.g. "2026-09-14 16:40".
    import std.regex : matchFirst, regex;
    assert(!matchFirst(titleText,
        regex(r"^Aurora OpenCode  \d{4}-\d{2}-\d{2} \d{2}:\d{2}$")).empty,
        "The titlebar should append the exe build date/time, got '" ~
        titleText ~ "'");
    // The title region is sized to its measured content, not the default 2/5 of
    // the band, so the merged toolbar keeps its room.
    assert(root.titleBarTitleWidthForTesting() > 0 &&
        root.titleBarTitleWidthForTesting() <= 320,
        "The title region should be a compact fixed width, got " ~
        to!string(root.titleBarTitleWidthForTesting()));
    writeln("Titlebar left title: ", titleText);
    assert(root.projectsRailCollapsedForTesting(),
        "Project rail should start collapsed");
    assert(root.projectsRailWidthForTesting() <= 48,
        "Collapsed rail should be icon width, got " ~
        to!string(root.projectsRailWidthForTesting()));
    root.toggleProjectsRailForTesting();
    root.tickTree(0.02);
    assert(!root.projectsRailCollapsedForTesting(),
        "Toggling should expand the rail");
    assert(root.projectsRailWidthForTesting() > 48,
        "Expanded rail should be wider than icon width");
    auto railJson = parseJSON(readText(buildPath(stateDir, "projects.json")));
    assert(railJson["projectsCollapsed"].type == JSONType.false_,
        "Expanded rail state was not persisted");
    root.toggleProjectsRailForTesting();
    root.tickTree(0.02);
    assert(root.projectsRailCollapsedForTesting(),
        "Toggling again should collapse the rail");
    assert(driver.paint(), "Rail toggle did not repaint");
    writeln("Project rail collapses to icon width and persists its state");

    // Create a project through the real dialog.
    root.openNewProjectDialogForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "New project dialog did not paint");
    auto projectName = requireWidget!TextField(root, "oc-project-name");
    auto projectPath = requireWidget!TextField(root, "oc-project-path-input");
    const projectDir = buildPath(stateDir, "proj-one");
    projectName.setText("proj-one");
    projectPath.setText(projectDir);
    root.tickTree(0.02);
    driver.click(globalCenter(requireWidget!Button(root, "oc-project-create")));
    root.tickTree(0.02);
    assert(driver.paint(), "New project dialog did not paint after create");
    assert(root.projectCountForTesting() == 2,
        "The dialog did not create the project");
    assert(projects.items().length == 2, "Rail did not gain a tile");
    assert(root.activeProjectNameForTesting() == "proj-one",
        "The new project should become active");
    assert(root.visibleSessionCountForTesting() == 0,
        "A new project starts with no conversations");
    assert(exists(projectDir), "Project folder was not created");
    auto projectTitleRow = requireWidget!Widget(root, "oc-project-title-row");
    auto projectTitle = requireWidget!Widget(root, "oc-project-title");
    auto openFolder = requireWidget!Widget(root, "oc-open-folder");
    assert(projectTitleRow.bounds().height > 0 &&
        projectTitle.bounds().height > 0 && openFolder.bounds().height > 0,
        "Project title row collapsed and hid its title/folder button");
    writeln("Created project: ", root.activeProjectNameForTesting());

    // New chats belong to the active project.
    root.newChatForTesting();
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == 1,
        "New chat is missing from the project list");
    const projectChat = cast(int) root.sessionCountForTesting() - 1;
    assert(root.sessionProjectForTesting(projectChat) ==
        root.activeProjectIdForTesting(),
        "New chat was not tagged with the active project");

    // Switching tiles swaps in that project's own conversation list.
    projects.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Tile 0 must select the sandbox");
    assert(root.visibleSessionCountForTesting() == sandboxVisible,
        "Sandbox did not restore its own conversations");
    projects.onSelectionChanged(1);
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == 1,
        "Switching back did not show the project's chat");
    writeln("Project switching filters the conversation list");

    assert(exists(buildPath(stateDir, "projects.json")),
        "projects.json was not written");

    // The sessions/chat divider is a draggable SplitPane and its width is
    // persisted so the layout survives a restart.
    auto split = requireWidget!SplitPane(root, "oc-split");
    const ratioBefore = root.sessionsRatioForTesting();
    assert(split.ratio() == ratioBefore, "Split ratio accessor mismatch");
    assert(ratioBefore > 0.1 && ratioBefore < 0.5,
        "Unexpected default split ratio: " ~ to!string(ratioBefore));
    root.dragSessionsDividerForTesting(120);
    root.tickTree(0.02);
    assert(root.sessionsRatioForTesting() > ratioBefore,
        "Dragging did not widen the conversation list");
    auto projectsJson = parseJSON(readText(buildPath(stateDir, "projects.json")));
    assert(projectsJson["sessionsRatio"].floating > ratioBefore,
        "Split ratio was not persisted");
    assert(driver.paint(), "Split drag did not repaint");
    writeln("Sessions column is draggable and its width persists");

    // A real pointer drag takes the fast path: the sidebar reflows as the
    // divider moves while the chat pane is only repositioned and clipped, then
    // reflows once on release. Confirm the chat content tracks the new width.
    auto chatScroll = requireWidget!Widget(root, "oc-scroll");
    const chatWidthBefore = chatScroll.bounds().width;
    const splitOrigin = split.localToGlobal(Point(0, 0));
    const dividerX = splitOrigin.x +
        cast(int) (split.bounds().width * root.sessionsRatioForTesting());
    const dragY = splitOrigin.y + split.bounds().height / 2;
    driver.drag(Point(dividerX, dragY), Point(dividerX + 120, dragY), 12);
    root.tickTree(0.02);
    assert(driver.paint(), "Pointer split drag did not repaint");
    assert(chatScroll.bounds().width != chatWidthBefore,
        "Chat pane did not reflow after the pointer drag ended");
    writeln("Pointer split drag reflows the chat pane on release");

    // Centered main column + taller composer: the message list and the prompt
    // share one horizontally centered, max-width column (upstream opencode's
    // `container-3xl`), and the composer is roughly twice the old 58 px input
    // row with the send button pinned to its bottom-right corner.
    auto messageCenter = requireWidget!Widget(root, "oc-message-center");
    auto composerCenter = requireWidget!Widget(root, "oc-composer-center");
    auto messages = requireWidget!Widget(root, "oc-messages");
    auto composer = requireWidget!Widget(root, "oc-composer");
    auto sendButton = requireWidget!Button(root, "oc-send");
    assert(root.composerHeightForTesting() == opencodeComposerHeight,
        "Composer should be " ~ to!string(opencodeComposerHeight) ~
        " px tall, got " ~ to!string(root.composerHeightForTesting()));
    assert(root.composerHeightForTesting() >= 100,
        "Composer should be about twice the old 58 px input row");
    const expectedColumn = minInt(messageCenter.bounds().width,
        opencodeContentMaxWidth);
    assert(root.messageColumnWidthForTesting() == expectedColumn,
        "Conversation column should be capped at " ~
        to!string(opencodeContentMaxWidth) ~ ", got " ~
        to!string(root.messageColumnWidthForTesting()));
    if (messageCenter.bounds().width > opencodeContentMaxWidth)
        assert(root.messageColumnXForTesting() ==
            (messageCenter.bounds().width - expectedColumn) / 2,
            "Conversation column should be horizontally centered, x=" ~
            to!string(root.messageColumnXForTesting()));
    const expectedComposer = minInt(composerCenter.bounds().width,
        opencodeContentMaxWidth);
    assert(composer.bounds().width == expectedComposer,
        "Composer should share the centered column width");
    // The send button sits in the composer's bottom-right corner.
    const sendOrigin = sendButton.localToGlobal(Point(0, 0));
    const composerOrigin = composer.localToGlobal(Point(0, 0));
    assert(sendOrigin.x >= composerOrigin.x + composer.bounds().width / 2,
        "Send button should be on the right half of the composer");
    assert(sendOrigin.y + sendButton.bounds().height <=
        composerOrigin.y + composer.bounds().height,
        "Send button should sit inside the composer");
    assert(sendOrigin.y >= composerOrigin.y + composer.bounds().height / 2,
        "Send button should sit in the lower half of the composer");
    writeln("Chat column is centered; composer is ",
        root.composerHeightForTesting(), " px tall with a bottom-right send");

    // The model selector, context meter, thinking and tools toggles live in the
    // composer footer under the prompt input, not in the title band.
    auto composerControls = requireWidget!Widget(root, "oc-composer-controls");
    auto promptInput = requireWidget!Widget(root, "oc-input");
    const controlsOrigin = composerControls.localToGlobal(Point(0, 0));
    const promptOrigin = promptInput.localToGlobal(Point(0, 0));
    assert(controlsOrigin.y >= promptOrigin.y + promptInput.bounds().height,
        "Composer controls should sit below the prompt input");
    const controlsBottom = controlsOrigin.y + composerControls.bounds().height;
    assert(controlsBottom <= composerOrigin.y + composer.bounds().height,
        "Composer controls should sit inside the composer panel");
    foreach (controlId; ["oc-model", "oc-usage", "oc-thinking", "oc-tools"])
    {
        auto control = requireWidget!Widget(root, controlId);
        const controlOrigin = control.localToGlobal(Point(0, 0));
        assert(controlOrigin.y >= controlsOrigin.y &&
            controlOrigin.y + control.bounds().height <= controlsBottom,
            "Control " ~ controlId ~ " should sit in the composer footer row");
    }
    writeln("Model/context/thinking/tools controls sit in the composer footer");

    // Regression: the stock CheckBox reserves 34 + 12*len px, so "Thinking"
    // claimed 130 px and left a ~70 px dead gap before Tools (which looked
    // detached). Both toggles must now hug their labels and sit as a tight pair.
    auto thinkingToggle = requireWidget!Widget(root, "oc-thinking");
    auto toolsToggle = requireWidget!Widget(root, "oc-tools");
    assert(thinkingToggle.bounds().width < 34 + "Thinking".length * 12,
        "Thinking toggle should hug its label instead of reserving 130 px");
    assert(toolsToggle.bounds().width < 34 + "Tools".length * 12,
        "Tools toggle should hug its label instead of reserving 94 px");
    const toggleGap = toolsToggle.localToGlobal(Point(0, 0)).x -
        (thinkingToggle.localToGlobal(Point(0, 0)).x +
         thinkingToggle.bounds().width);
    assert(toggleGap <= 12,
        "Tools toggle should sit right next to the Thinking toggle");
    writeln("Thinking/Tools toggles hug their labels (gap ", toggleGap, " px)");

    // Hovering Thinking itself (there is no separate '?' badge) opens the
    // explanation above the control so it does not cover the composer.
    driver.moveTo(globalCenter(thinkingToggle));
    root.tickTree(0.02);
    assert(driver.paint(), "Thinking tooltip did not repaint");
    assert(root.isThinkingTooltipOpenForTesting(),
        "Hovering Thinking did not open its tooltip");
    const thinkingTip = root.thinkingTooltipBoundsForTesting();
    const thinkingOrigin = thinkingToggle.localToGlobal(Point(0, 0));
    assert(thinkingTip.height > 0 && thinkingTip.bottom() <= thinkingOrigin.y,
        "Thinking tooltip should open above the toggle");
    assert(root.thinkingTooltipTextForTesting().indexOf(
        "reasoning effort") >= 0,
        "Thinking tooltip lost its explanation");
    driver.moveTo(Point(4, 700));
    root.tickTree(0.02);
    assert(!root.isThinkingTooltipOpenForTesting(),
        "Thinking tooltip stayed open after pointer leave");
    writeln("Thinking tooltip opens above the toggle and dismisses on leave");

    // Removing a project moves its chats to the sandbox.
    root.removeProjectForTesting(1);
    root.tickTree(0.02);
    assert(root.projectCountForTesting() == 1, "Project was not removed");
    assert(root.activeProjectNameForTesting() == "Sandbox",
        "Removing the active project should fall back to the sandbox");
    projects.onSelectionChanged(0);
    root.tickTree(0.02);
    assert(root.visibleSessionCountForTesting() == sandboxVisible + 1,
        "The removed project's chats were not reassigned to the sandbox");
    writeln("Removing a project reassigns its chats to the sandbox");

    // Native tools are the main mode; Legacy tools live in Settings with a
    // hover tooltip, not in the toolbar.
    auto legacyCheck = root.legacyToolsCheckboxForTesting();
    assert(legacyCheck !is null, "Settings dialog missing the Legacy tools checkbox");
    assert(!legacyCheck.checked(), "Legacy tools should be off by default");
    const legacyTip = root.legacyToolsTooltipForTesting();
    assert(legacyTip.indexOf("bash") >= 0,
        "Legacy tools tooltip should explain the shell tool: " ~ legacyTip);
    writeln("Legacy tools checkbox + tooltip present in Settings");

    // Provider selector: Settings offers OpenCode / CommandCode / Qwen 3.8
    // 27B and fills the editable base URL + model for each.
    const providerNames = root.providerPresetNamesForTesting();
    assert(providerNames.length == 3, "Expected three provider presets");
    assert(providerNames[0] == "OpenCode" &&
        providerNames[1] == "CommandCode" &&
        providerNames[2] == "Qwen 3.8 27B",
        "Unexpected provider preset names");
    assert(root.providerSelectorPresentForTesting(),
        "Settings dialog missing the Provider picker");
    const opencodeSelection = root.selectProviderForTesting(0);
    assert(opencodeSelection ==
        "https://opencode.ai/zen/go/v1\ndeepseek-v4.1-flash",
        "OpenCode preset filled the wrong endpoint/model: " ~ opencodeSelection);
    const commandcodeSelection = root.selectProviderForTesting(1);
    assert(commandcodeSelection ==
        "https://api.commandcode.ai/provider/v1\ndeepseek/deepseek-v4.1-flash",
        "CommandCode preset filled the wrong endpoint/model: " ~
        commandcodeSelection);
    const qwenSelection = root.selectProviderForTesting(2);
    assert(qwenSelection == "http://127.0.0.1:8080/v1\nQwen/Qwen3.8-27B",
        "Qwen preset filled the wrong endpoint/model: " ~ qwenSelection);
    // Exercise the real dropdown wiring: opening the Provider context menu
    // must keep the Settings dialog alive and its item action must fill the
    // fields (showContextMenuBelow would have closed the dialog).
    assert(root.providerMenuCountForTesting() == 3,
        "Provider dropdown should offer three presets");
    const fromMenu = root.chooseProviderFromMenuForTesting(1);
    assert(fromMenu ==
        "https://api.commandcode.ai/provider/v1\ndeepseek/deepseek-v4.1-flash",
        "Provider dropdown item did not apply CommandCode: " ~ fromMenu);
    root.dismissPopupForTesting();
    writeln("Provider presets fill the Settings endpoint + model");

    // The provider button must be reachable by a real pointer click inside the
    // Settings popup, and the keep-popups menu must not close the dialog.
    assert(root.providerSelectorPresentForTesting(),
        "Settings did not reopen for the provider click test");
    root.tickTree(0.02);
    assert(driver.paint(), "Settings did not lay out for the provider click test");
    auto providerButton = requireWidget!Button(root, "oc-provider");
    driver.click(globalCenter(providerButton));
    root.tickTree(0.02);
    assert(driver.paint(), "Provider dropdown did not repaint");
    auto providerMenu = cast(ContextMenu) currentTransientPopup(root);
    assert(providerMenu !is null,
        "Clicking the Provider button did not open its dropdown");
    assert(providerMenu.items().length == 3,
        "Provider dropdown should offer three presets");
    assert(findById(root, "oc-settings-base") !is null,
        "Provider dropdown dismissed the Settings dialog");
    writeln("Provider dropdown opens on a real click and keeps Settings open");
    dismissContextMenus(root);
    root.tickTree(0.02);

    // Settings exposes the concise system prompt. Tool-specific syntax remains
    // in the API tool schemas instead of being duplicated here.
    assert(root.systemPromptButtonPresentForTesting(),
        "Settings dialog missing the System prompt button");
    // Settings reveals the folder that stores the user's chats.
    assert(root.chatsFolderButtonPresentForTesting(),
        "Settings dialog missing the Chats folder button");
    writeln("Chats folder button is available from Settings");
    const systemPrompt = root.systemPromptViewerTextForTesting();
    assert(systemPrompt.indexOf("Aurora OpenCode") >= 0,
        "system prompt is missing the identity line");
    assert(systemPrompt.indexOf("# Execution loop") >= 0 &&
        systemPrompt.indexOf("# Operating contract") >= 0,
        "system prompt is missing the execution contract: " ~ systemPrompt);
    assert(systemPrompt.indexOf("name the remaining unknown") >= 0 &&
        systemPrompt.indexOf("evidence phase, not a quota") >= 0,
        "system prompt does not guide progress from evidence");
    assert(systemPrompt.indexOf("within six") < 0 &&
        systemPrompt.indexOf("at most three") < 0,
        "system prompt still contains artificial work quotas");
    writeln("Concise execution-contract prompt is viewable from Settings");
    const promptShots = buildPath(tempDir(), "aurora-opencode-tool-shots");
    if (!exists(promptShots)) mkdirRecurse(promptShots);
    assert(driver.paint(), "System prompt viewer did not repaint");
    window.saveScreenshot(buildPath(promptShots, "system-prompt.ppm"));
    root.dismissPopupForTesting();

    // Tool loop: with tools enabled and a workspace, an injected tool call is
    // executed locally and the result lands as a `tool` role message.
    auto workspaceDir = buildPath(stateDir, "workspace");
    mkdirRecurse(workspaceDir);
    write(buildPath(workspaceDir, "notes.txt"), "hello tool world\n");
    root.enableToolsForTesting(workspaceDir);
    root.pauseToolContinuationForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["What is in notes.txt?"]);
    // The client creates an assistant message (chatBegin) before delivering
    // toolCalls, so mirror that shape here.
    root.addConversationForTesting(["assistant"], [""]);
    OpenCodeToolCall readCall;
    readCall.id = "call_test_1";
    readCall.name = "read";
    readCall.arguments = `{"filePath":"notes.txt"}`;
    OpenCodeToolCall grepCall;
    grepCall.id = "call_test_2";
    grepCall.name = "grep";
    grepCall.arguments = `{"pattern":"tool"}`;
    OpenCodeToolCall runCall;
    runCall.id = "call_test_3";
    runCall.name = "run";
    version (Windows)
        runCall.arguments =
            `{"program":"cmd.exe","args":["/d","/c","echo","run-args-ok"]}`;
    else
        runCall.arguments = `{"program":"/bin/echo","args":["run-args-ok"]}`;
    root.injectToolCallsForTesting([readCall, grepCall, runCall]);
    // The tool worker runs on a background thread; tick the tree so onTick
    // drains the results, up to a short deadline.
    const deadline = Clock.currTime + 5.seconds;
    while (root.toolMessageCountForTesting() < 3 && Clock.currTime < deadline)
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    assert(root.toolMessageCountForTesting() == 3,
        "Tool results did not arrive as tool role messages");
    assert(root.toolResultForTesting(0).indexOf("hello tool world") >= 0,
        "read tool did not return the file contents: " ~
        root.toolResultForTesting(0));
    assert(root.toolResultForTesting(0).indexOf("1: hello tool world") >= 0,
        "read tool did not number lines: " ~ root.toolResultForTesting(0));
    assert(root.toolResultForTesting(1).indexOf("notes.txt") >= 0,
        "grep tool did not find the matching file");
    assert(root.toolResultForTesting(1).indexOf("notes.txt:1: hello tool world") >= 0,
        "grep tool did not return a line-numbered snippet: " ~
        root.toolResultForTesting(1));
    assert(root.toolResultForTesting(2).indexOf("run-args-ok") >= 0,
        "run tool did not execute: " ~ root.toolResultForTesting(2));
    // Regression: a JSON argv array must render as a readable command line,
    // not the old opaque `args=[…]`.
    assert(root.toolArgsDisplayForTesting(0).indexOf("filePath=notes.txt") >= 0,
        "tool args did not render the object value: " ~
        root.toolArgsDisplayForTesting(0));
    const runArgs = root.toolArgsDisplayForTesting(2);
    assert(runArgs.indexOf("[…]") < 0,
        "tool args must not render as the opaque [..] placeholder: " ~ runArgs);
    assert(runArgs.indexOf("program=cmd.exe") >= 0 ||
        runArgs.indexOf("program=/bin/echo") >= 0,
        "run args did not show the program: " ~ runArgs);
    assert(runArgs.indexOf("/d /c echo run-args-ok") >= 0 ||
        runArgs.indexOf("run-args-ok") >= 0,
        "run args array was not flattened into a command line: " ~ runArgs);
    writeln("Tool arg display flattens argv arrays into a command line");
    assert(driver.paint(), "Tool bubble did not paint");
    writeln("Tool loop executed read + grep and landed two tool messages");
    assert(root.messageCountForTesting() >= 3,
        "Tool loop did not append the tool messages to the session");
    writeln("Tool loop preserved the session history");

    // Codex-style action group: the turn's read+grep+run fold into ONE
    // collapsible whose header summarises the whole turn, instead of a context
    // group plus a separate shell bubble.
    assert(root.contextGroupCountForTesting() == 1,
        "the turn's tools did not fold into one action group");
    assert(root.firstToolGroupPartCountForTesting() == 3,
        "action group should contain all three tool parts");
    auto groupHeaders = root.toolGroupHeaderTextsForTesting();
    assert(groupHeaders.length == 1 &&
        groupHeaders[0].indexOf("Ran a command") >= 0 &&
        groupHeaders[0].indexOf("explored 2 files") >= 0,
        "action group header should summarise the turn: " ~
        (groupHeaders.length ? groupHeaders[0] : "<none>"));
    assert(root.firstToolGroupCollapsedForTesting(),
        "action group should start collapsed");
    root.toggleFirstToolGroupForTesting();
    assert(!root.firstToolGroupCollapsedForTesting(),
        "action group did not expand on toggle");
    assert(driver.paint(), "Expanded action group did not repaint");
    const toolShots = buildPath(tempDir(), "aurora-opencode-tool-shots");
    if (!exists(toolShots)) mkdirRecurse(toolShots);
    window.saveScreenshot(buildPath(toolShots, "explored-expanded.ppm"));
    root.toggleFirstToolGroupForTesting();
    assert(root.firstToolGroupCollapsedForTesting(),
        "action group did not collapse again");
    assert(driver.paint(), "Collapsed action group did not repaint");
        window.saveScreenshot(buildPath(toolShots, "explored-collapsed.ppm"));
        writeln("A turn's tools fold into one collapsible action group");

    // Turn timer: Codex renders "Worked for …" as a horizontal completion
    // boundary immediately ABOVE the final answer. It must not be embedded in
    // an earlier action-group header, which reverses the visual relationship.
    {
        root.newChatForTesting();
        // The separator is opt-in and off by default, so enable it for this
        // block; the plain-answer block below re-checks the default-off case.
        root.setShowWorkedForForTesting(true);
        root.addConversationForTesting(["user"], ["Time this turn"]);
        root.addConversationForTesting(["assistant"], [""]);
        root.startTurnClockForTesting();
        OpenCodeToolCall timedCall;
        timedCall.id = "call_timed_1";
        timedCall.name = "read";
        timedCall.arguments = `{"filePath":"notes.txt"}`;
        root.injectToolCallsForTesting([timedCall]);
        const timedDeadline = Clock.currTime + 5.seconds;
        while (root.toolMessageCountForTesting() < 1 &&
            Clock.currTime < timedDeadline)
        {
            root.tickTree(0.02);
            Thread.sleep(20.msecs);
        }
        assert(root.toolMessageCountForTesting() == 1,
            "timed tool did not produce a result");
        // The live action group describes only the action, never elapsed time.
        root.tickTree(2.1);
        auto timedHeaders = root.toolGroupHeaderTextsForTesting();
        assert(timedHeaders.length == 1 &&
            timedHeaders[0].indexOf("Working for") < 0 &&
            timedHeaders[0].indexOf("Worked for") < 0,
            "elapsed time leaked into the action group: " ~
            (timedHeaders.length ? timedHeaders[0] : "(none)"));
        assert(driver.paint(), "Timed live action group did not paint");

        // Stream the final answer, then settle the turn. The rebuild must place
        // the completion boundary between the action group and this answer.
        root.beginStreamForTesting();
        root.streamContentForTesting("Done.");
        root.finishStreamForTesting();
        auto doneSeparators = root.turnCompletionTextsForTesting();
        assert(doneSeparators.length == 1 &&
            doneSeparators[0].indexOf("Worked for ") == 0,
            "settled turn is missing its completion separator");
        int groupIndex = -1;
        int separatorIndex = -1;
        int answerIndex = -1;
        foreach (i, line; root.columnDebugForTesting())
        {
            if (line.indexOf("GROUP ") >= 0) groupIndex = cast(int) i;
            if (line.indexOf("SEPARATOR Worked for ") >= 0)
                separatorIndex = cast(int) i;
            if (line.indexOf("bubble role=assistant") >= 0 &&
                line.indexOf(`txt="Done."`) >= 0)
                answerIndex = cast(int) i;
        }
        assert(groupIndex >= 0 && separatorIndex > groupIndex &&
            answerIndex > separatorIndex,
            "expected action group -> Worked for separator -> final answer");
        // More ticks must not change a finished turn's total.
        root.tickTree(5.0);
        auto frozenSeparators = root.turnCompletionTextsForTesting();
        assert(frozenSeparators.length == 1 &&
            frozenSeparators[0] == doneSeparators[0],
            "the settled timer kept ticking");
        assert(driver.paint(), "Worked-for completion separator did not paint");
        window.saveScreenshot(buildPath(toolShots, "worked-for-separator.ppm"));
        writeln("Worked-for separator precedes final answer and freezes");
    }

    // The separator is opt-in: with the setting off, even a turn that did real
    // tool work gets no boundary. This is the shipped default.
    {
        root.newChatForTesting();
        root.setShowWorkedForForTesting(false);
        assert(root.workedForCheckboxForTesting() !is null,
            "Settings dialog missing the Worked-for checkbox");
        assert(!root.workedForCheckboxForTesting().checked(),
            "Worked-for separator should be off by default");
        root.addConversationForTesting(["user"], ["Time this turn"]);
        root.addConversationForTesting(["assistant"], [""]);
        root.startTurnClockForTesting();
        OpenCodeToolCall offCall;
        offCall.id = "call_off_1";
        offCall.name = "read";
        offCall.arguments = `{"filePath":"notes.txt"}`;
        root.injectToolCallsForTesting([offCall]);
        const offDeadline = Clock.currTime + 5.seconds;
        while (root.toolMessageCountForTesting() < 1 &&
            Clock.currTime < offDeadline)
        {
            root.tickTree(0.02);
            Thread.sleep(20.msecs);
        }
        root.beginStreamForTesting();
        root.streamContentForTesting("Done.");
        root.finishStreamForTesting();
        assert(root.turnCompletionTextsForTesting().length == 0,
            "opted-out turn still received a Worked-for separator");
        writeln("Worked-for separator is off unless enabled in Settings");
        // `workedForCheckboxForTesting` opens the Settings dialog to reach the
        // checkbox; close it, or its full-window overlay consumes the real
        // pointer clicks the later tests dispatch.
        root.dismissPopupForTesting();
    }

    // A quick direct response did not perform reasoning or tool work. Matching
    // Codex, it stays clean instead of putting "Worked for 0s" above every
    // ordinary assistant message.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Answer directly"]);
        root.startTurnClockForTesting();
        root.beginStreamForTesting();
        root.streamContentForTesting("A direct answer.");
        root.finishStreamForTesting();
        assert(root.turnCompletionTextsForTesting().length == 0,
            "plain direct answer unexpectedly received a Worked-for separator");
        writeln("Direct answers omit the Worked-for separator");
    }

    // Nesting: the tool results render as children of the assistant turn that
    // requested them (at the same left edge, not stepped in), and they must
    // actually take layout space. The
    // base VBox sizes children from layoutHints and a plain VBox never
    // publishes its measured size, so a nested tool row was laid out at zero
    // height and the action "disappeared" the moment it became a record.
    {
        root.newChatForTesting();
        root.addConversationForTestingWithReasoning(["user", "assistant"],
            ["check notes", "I'll read the notes."], [null, "reasoning"]);
        OpenCodeToolCall nestedCall;
        nestedCall.id = "call_nest_1";
        nestedCall.name = "read";
        nestedCall.arguments = `{"filePath":"notes.txt"}`;
        root.injectToolCallsForTesting([nestedCall]);
        const nestDeadline = Clock.currTime + 5.seconds;
        while (root.toolMessageCountForTesting() < 1 &&
            Clock.currTime < nestDeadline)
        {
            root.tickTree(0.02);
            Thread.sleep(20.msecs);
        }
        assert(root.toolMessageCountForTesting() == 1,
            "nested read tool did not produce a result");
        assert(driver.paint(), "Nested tool column did not paint");
        // Visual order: [user, assistant, nested tool].
        const assistantX = root.bubbleBoundsForTesting(1).x;
        assert(root.bubbleVisibleForTesting(2),
            "nested tool node must be visible");
        const nested = root.bubbleBoundsForTesting(2);
        assert(nested.height > 0,
            "nested tool node must take layout space");
        // Every collapsible row shares one left edge: a nested tool result
        // must NOT step in under its turn.
        assert(nested.x == assistantX,
            "nested tool node must share the turn's left edge, got x=" ~
            to!string(nested.x) ~ " vs assistant x=" ~ to!string(assistantX));
        writeln("Tool results nest under the assistant turn at one left edge");

        // The whole point: every collapsible row in the transcript lines up on
        // one left edge, whether it is a top-level Thinking header, an
        // "Explored" group, or a tool row nested under a turn. A mixed column
        // (some rows at the column edge, some stepped in) is the bug.
        int edge = -1;
        foreach (i; 0 .. root.messageCountForTesting())
        {
            if (!root.bubbleVisibleForTesting(i)) continue;
            const bounds = root.bubbleBoundsForTesting(i);
            if (bounds.width == 0) continue;
            if (edge < 0) edge = bounds.x;
            assert(bounds.x == edge,
                "transcript row " ~ to!string(i) ~ " is indented: x=" ~
                to!string(bounds.x) ~ " vs " ~ to!string(edge));
        }
        assert(edge >= 0, "no visible rows to compare");
        writeln("Every transcript row shares one left edge (x=", edge, ")");
    }

    // Live diff counters: while the model streams a file-mutating tool's
    // arguments, the in-progress row must show a provisional `+N -M` that
    // grows as the body arrives (a big write used to show no progress at all
    // until the tool finished).
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Write a page"]);
        root.addConversationForTesting(["assistant"], [""]);
        OpenCodeToolCall prep;
        prep.name = "write";
        prep.arguments = `{"filePath":"page.html","content":"<html>\n<body>\n<p>`;
        root.injectToolProgressForTesting([prep]);
        auto rows = root.liveToolRowTextsForTesting();
        auto diffs = root.liveToolRowDiffTextsForTesting();
        assert(rows.length == 1 && diffs.length == 1,
            "Live write row missing");
        assert(diffs[0] == "+3 -0",
            "Live write counters wrong: " ~ diffs[0]);
        // The collapsed action-group header aggregates the provisional counts
        // too, so they stay visible without expanding the group.
        assert(root.totalToolGroupAdditionsForTesting() >= 3,
            "live action-group header did not show the streamed +N");
        assert(driver.paint(), "Live write row did not paint");
        // More of the file body streams in: counters must grow.
        prep.arguments =
            `{"filePath":"page.html","content":"<html>\n<body>\n<p>hi</p>\n</body>\n</html>"}`;
        root.injectToolProgressForTesting([prep]);
        diffs = root.liveToolRowDiffTextsForTesting();
        assert(diffs[0] == "+5 -0",
            "Live write counters did not grow: " ~ diffs[0]);
        // An edit previews both sides as soon as the new string streams.
        OpenCodeToolCall editPrep;
        editPrep.name = "edit";
        editPrep.arguments =
            `{"filePath":"a.txt","oldString":"beta","newString":"BETA\nextra"}`;
        root.injectToolProgressForTesting([editPrep]);
        diffs = root.liveToolRowDiffTextsForTesting();
        assert(diffs.length == 1 && diffs[0] == "+2 -1",
            "Live edit counters wrong: " ~ diffs[0]);
        assert(root.totalToolGroupAdditionsForTesting() >= 2 &&
            root.totalToolGroupDeletionsForTesting() >= 1,
            "live action-group header did not aggregate the edit preview");
        assert(driver.paint(), "Live edit row did not paint");
        // The in-flight row is timed too, so a long command shows how long it
        // has been running. Freeze the value to keep the assertion non-racy and
        // prove the collapsed action-group header aggregates the live timer.
        root.setLiveToolElapsedForTesting(2500);
        assert(root.totalLiveToolElapsedMsForTesting() >= 2500,
            "live tool row did not report its elapsed time");
        assert(root.totalToolGroupElapsedMsForTesting() >= 2500,
            "collapsed action-group header did not aggregate the live duration");
        assert(driver.paint(), "Live elapsed label did not paint");
        root.setLiveToolElapsedForTesting(0);
        writeln("Live tool rows show a running elapsed time");
    }

    // Live phase indicator: the generic activity row covers the gaps where no
    // live tool row exists (before the first token, between tool rounds). While
    // tool rows are streaming or running it is intentionally suppressed — those
    // rows already say what is happening, so showing both was redundant noise.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Do something"]);
        assert(!root.activityVisibleForTesting(),
            "Activity row appeared before any work started");
        // With nothing else to show, the phase row renders and updates in place.
        root.setActivityForTesting("Waiting for the model…");
        assert(root.activityVisibleForTesting(),
            "Activity row did not appear when there was nothing else to show");
        assert(root.activityTextForTesting() == "Waiting for the model…",
            "Activity row shows the wrong phase: " ~
            root.activityTextForTesting());
        root.setActivityForTesting("Thinking…");
        assert(root.activityTextForTesting() == "Thinking…",
            "Activity row did not update its phase");
        // The clock must keep running across a phase change (no reset), so the
        // seconds describe how long the request has been in flight.
        root.tickTree(1.2);
        assert(root.activityDisplayTextForTesting().indexOf("1s") >= 0,
            "Activity row is missing the elapsed seconds: " ~
            root.activityDisplayTextForTesting());
        root.clearActivityForTesting();
        assert(!root.activityVisibleForTesting(),
            "Activity row did not clear when work stopped");
        // A tool-call progress event shows a live tool row instead of the phase
        // row: the phase row must stay suppressed and not duplicate it.
        OpenCodeToolCall prep;
        prep.name = "write";
        prep.arguments = `{"filePath":"page.html","content":"<html>`;
        root.injectToolProgressForTesting([prep]);
        assert(root.liveToolRowTextsForTesting().length == 1,
            "Expected a live tool row while the arguments stream");
        assert(!root.activityVisibleForTesting(),
            "Activity row duplicated the live tool row");
        assert(driver.paint(), "Live tool row did not paint");
        const actShots = buildPath(tempDir(), "aurora-opencode-live-shots");
        if (!exists(actShots)) mkdirRecurse(actShots);
        window.saveScreenshot(buildPath(actShots, "live-tool-row-no-phase.ppm"));
        writeln("Live phase row shows only when no live tool row does");
    }

    // Live token counter: while the reply streams (reasoning, then answer) the
    // Thinking header shows an output-token count that only grows, and it stays
    // after the turn completes. The generic "Writing…" phase word is gone, so
    // nothing vanishes at completion and reads like a file write.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Explain something"]);
        root.beginStreamForTesting();
        assert(root.streamLiveTokensForTesting() == 0,
            "Token count appeared before any token streamed");
        assert(root.activityVisibleForTesting(),
            "The pre-token wait row should still show");
        root.streamReasoningForTesting("Let me think about this carefully.");
        root.tickTree(0.02);
        const long afterReasoning = root.streamLiveTokensForTesting();
        assert(afterReasoning > 0,
            "Reasoning did not start the live token counter");
        const string header = root.streamThinkingHeaderTextForTesting();
        assert(header.indexOf("Thinking") >= 0 && header.indexOf("tokens") >= 0,
            "Thinking header lacks the token count: " ~ header);
        assert(root.activityTextForTesting().indexOf("Writing") < 0,
            "The 'Writing…' phase word is still in the transcript");
        assert(!root.activityVisibleForTesting(),
            "The wait row must be dropped once the header speaks");
        assert(driver.paint(), "Streaming header did not paint");
        Thread.sleep(120.msecs);
        root.streamContentForTesting("Here is the explanation, in full detail.");
        root.tickTree(0.02);
        const long afterContent = root.streamLiveTokensForTesting();
        assert(afterContent > afterReasoning,
            "Token count did not grow with the answer: " ~
            to!string(afterReasoning) ~ " -> " ~ to!string(afterContent));
        assert(root.streamThinkingHeaderTextForTesting().indexOf("t/s") >= 0,
            "Thinking header lacks live token throughput: " ~
            root.streamThinkingHeaderTextForTesting());
        // The provider's exact completion count replaces the local estimate.
        // Use a smaller exact value to guard against the old max-only behavior,
        // which refused to correct an estimate that overshot the tokenizer.
        const int exactCompletion = cast(int) afterContent - 1;
        root.feedUsageForTesting(100, exactCompletion, exactCompletion + 100);
        assert(root.streamLiveTokensForTesting() == exactCompletion,
            "Exact completion tokens did not replace the estimate");
        root.finishStreamForTesting();
        root.tickTree(0.02);
        assert(!root.activityVisibleForTesting(),
            "Completion left the activity row behind");
        const long finalTokens = root.lastAssistantLiveTokensForTesting();
        assert(finalTokens == exactCompletion,
            "The final token count did not persist on the reply: " ~
            to!string(finalTokens));
        const string finalHeader =
            root.lastAssistantThinkingHeaderTextForTesting();
        assert(finalHeader.indexOf("tokens") >= 0,
            "The completed reply lost its token count: " ~ finalHeader);
        assert(driver.paint(), "Completed counted header did not paint");
        const tokenShots = buildPath(tempDir(), "aurora-opencode-token-shots");
        if (!exists(tokenShots)) mkdirRecurse(tokenShots);
        window.saveScreenshot(buildPath(tokenShots, "live-token-counter.ppm"));
        writeln("Live token count grows on the Thinking header and stays");
    }

    // A reasoning round that ends in tool calls does not pass through
    // finishAssistantMessage. Its live count/rate must be persisted before the
    // transient stream bubble is replaced by the settled tool-call wrapper.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Inspect then answer"]);
        root.startTurnClockForTesting();
        root.beginStreamForTesting();
        root.streamReasoningForTesting(
            "I need enough streamed reasoning to establish a token sample.");
        Thread.sleep(120.msecs);
        root.streamContentForTesting("I will inspect the target now.");
        assert(root.streamThinkingHeaderTextForTesting().indexOf("t/s") >= 0,
            "Tool-bound round never established live throughput");
        OpenCodeToolCall transition;
        transition.id = "call-token-transition";
        transition.name = "read";
        transition.arguments = `{"filePath":"missing-token-test.txt"}`;
        root.injectToolCallsForTesting([transition]);
        const settledHeader = root.lastAssistantThinkingHeaderTextForTesting();
        assert(settledHeader.indexOf("tokens") >= 0 &&
            settledHeader.indexOf("t/s") >= 0,
            "Thinking → tool-call transition lost token stats: " ~
            settledHeader);
        root.clickSendButtonForTesting();
        writeln("Tool-call transition preserves Thinking token throughput");
    }

    // Codex-style live group: each in-flight tool is its own child row under
    // one action group whose header speaks in the present tense while the tools
    // run. The rows carry the streamed body so the user sees progress, and they
    // settle into the turn's record as results arrive.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Do many things"]);
        OpenCodeToolCall one, two, three;
        one.name = "dshell";
        one.arguments = `{"command":"echo one"}`;
        two.name = "write";
        two.arguments = `{"filePath":"x.txt","content":"a\nb\n"}`;
        three.name = "read";
        three.arguments = `{"filePath":"y.txt"}`;
        root.injectToolProgressForTesting([one, two, three]);
        auto rows = root.liveToolRowTextsForTesting();
        assert(rows.length == 3,
            "Expected one live row per in-flight tool, got " ~
            to!string(rows.length));
        auto liveHeaders = root.toolGroupHeaderTextsForTesting();
        assert(liveHeaders.length == 1 &&
            liveHeaders[0].indexOf("Editing a file") >= 0 &&
            liveHeaders[0].indexOf("running a command") >= 0 &&
            liveHeaders[0].indexOf("exploring a file") >= 0,
            "Live action group header is wrong: " ~
            (liveHeaders.length ? liveHeaders[0] : "(none)"));
        auto diffs = root.liveToolRowDiffTextsForTesting();
        assert(diffs.length == 3,
            "Expected a diff slot per live row, got " ~ to!string(diffs.length));
        auto previews = root.liveToolRowPreviewsForTesting();
        assert(previews.length == 3 && previews[1].indexOf("a\nb") >= 0,
            "Live write row did not preview the streamed body: " ~
            (previews.length > 1 ? previews[1] : "(none)"));
        assert(driver.paint(), "Live action group did not paint");
        writeln("In-flight tools render as children of one live action group: ",
            liveHeaders[0]);
        // An unnamed tool must not render as a blank row.
        OpenCodeToolCall blank, named;
        blank.name = "";
        blank.arguments = `{}`;
        named.name = "write";
        named.arguments = `{"filePath":"z.txt","content":"x\n"}`;
        root.injectToolProgressForTesting([blank, named]);
        auto rows2 = root.liveToolRowTextsForTesting();
        assert(rows2.length == 1 && rows2[0].indexOf("Writing") >= 0,
            "Unnamed tool did not collapse to the named one: " ~
            (rows2.length ? rows2[0] : "(none)"));
        writeln("Unnamed tool does not mask the named one: ", rows2[0]);
    }

    // Codex-style stability: every assistant round keeps its OWN reasoning
    // attached to it, so a multi-round exchange is append-only — the Thinking
    // headers never merge, migrate down the transcript or vanish as rounds
    // settle. Each round's prose is followed by that round's own collapsible
    // action group, so the transcript interleaves paragraph -> collapsible.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Do the work"]);
        root.appendToolRequestTurnForTesting("I should read the file first.",
            "call-1", "read", `{"filePath":"a.txt"}`);
        root.appendToolReplyForTesting("call-1", "file body\n");
        root.appendToolRequestTurnForTesting("I should write the result.",
            "call-2", "write", `{"filePath":"out.txt","content":"hi"}`);
        root.appendToolReplyForTesting("call-2", "Wrote out.txt (+1 -0).");
        root.addConversationForTestingWithReasoning(["assistant"],
            ["Done — I read a.txt and wrote out.txt."], ["Now I can answer."]);
        root.tickTree(0.02);
        assert(driver.paint(), "Multi-round exchange paint failed");
        const int headers = root.thinkingHeaderCountForTesting();
        const auto texts = root.thinkingTextsForTesting();
        assert(headers == 3 && texts.length == 3,
            "Each round should keep its own Thinking header, got " ~
            to!string(headers));
        assert(texts[0].indexOf("read the file first") >= 0 &&
            texts[1].indexOf("write the result") >= 0 &&
            texts[2].indexOf("Now I can answer") >= 0,
            "Per-round Thinking is out of order or wrong: " ~
            texts[0] ~ " || " ~ texts[1] ~ " || " ~ texts[2]);
        // One collapsible action group per round, in round order.
        const auto groups = root.toolGroupHeaderTextsForTesting();
        assert(groups.length == 2,
            "Each tool round should keep its own action group, got " ~
            to!string(groups.length));
        // Stability: a canonical rebuild must render the identical transcript.
        root.rebuildForTesting();
        root.tickTree(0.02);
        const auto after = root.thinkingTextsForTesting();
        assert(after.length == texts.length,
            "A rebuild changed the number of Thinking blocks");
        foreach (i; 0 .. after.length)
            assert(after[i] == texts[i],
                "A rebuild reordered the Thinking blocks at " ~ to!string(i));
        root.toggleLastThinkingForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Expanded per-round Thinking did not paint");
        const exShots = buildPath(tempDir(), "aurora-opencode-exchange-shots");
        if (!exists(exShots)) mkdirRecurse(exShots);
        window.saveScreenshot(buildPath(exShots, "per-turn-thinking.ppm"));
        writeln("Each tool round keeps its own Thinking + action group "
            ~ "(stable order)");
    }

    // Regression: a reasoning-only stream must print "Thinking" once (the
    // in-bubble header), keep any phase row BELOW the live reply, and not
    // reserve a phantom text-cursor line while the answer is still empty.
    {
        root.newChatForTesting();
        // A phase row pinned before the reply arrives — the real
        // "Waiting for the model…" state — used to stay ABOVE the reply.
        root.setActivityForTesting("Waiting for the model…");
        root.addConversationForTestingWithReasoning(["user", "assistant", "user"],
            ["q1", "", "q2"], [null, "same reasoning", null]);
        // The waiting row must sit AFTER the trailing prompt, not nested under
        // the previous answer (the "waiting above the prompt" bug).
        assert(root.activityRowVisualIndexForTesting() ==
            root.messageColumnVisualCountForTesting() - 1,
            "Waiting row rendered above the prompt instead of after it");
        assert(driver.paint(), "Static reasoning layout failed");
        const int staticHeight = root.bubbleHeightForTesting(1);
        root.beginStreamForTesting();
        assert(driver.paint(), "Stream begin layout failed");
        assert(root.activityVisibleForTesting(),
            "A fresh stream should start with the activity row (no header yet)");
        root.streamReasoningForTesting("same reasoning");
        assert(driver.paint(), "Reasoning stream paint failed");
        assert(!root.activityVisibleForTesting(),
            "Reasoning stream must not show a second 'Thinking' activity row");
        const int activityIndex = root.activityRowVisualIndexForTesting();
        const int visualCount = root.messageColumnVisualCountForTesting();
        assert(activityIndex == -1 || activityIndex == visualCount - 1,
            "Any phase row must render after the live reply, never above it");
        const int liveHeight = root.bubbleHeightForTesting(3);
        assert(liveHeight == staticHeight,
            "A reasoning-only stream reserved a phantom cursor line: live=" ~
            to!string(liveHeight) ~ " static=" ~ to!string(staticHeight));
        writeln("Reasoning stream: one Thinking header, no phantom cursor");
    }

    // Regression: a request that fails before any assistant turn exists must
    // attach the error to a NEW assistant reply, never to the user's prompt.
    // The old code wrote "Error: …" into the last message, which was the user's
    // message when `chatBegin` had not fired yet, corrupting the prompt.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Please answer this."]);
        root.failAssistantMessageForTesting(
            "HTTP 500:\nraise_exception('System message must be at the beginning.')");
        assert(root.messageCountForTesting() == 2,
            "A failed request must add an assistant turn, got " ~
            to!string(root.messageCountForTesting()));
        assert(root.messageRoleForTesting(0) == "user" &&
            root.messageContentForTesting(0) == "Please answer this.",
            "The user prompt was corrupted by the error: " ~
            root.messageContentForTesting(0));
        assert(root.messageRoleForTesting(1) == "assistant",
            "The error was not attached to an assistant reply");
        assert(root.lastAssistantContentForTesting().indexOf("Error:") >= 0,
            "The error text is missing from the reply: " ~
            root.lastAssistantContentForTesting());
        assert(root.lastAssistantContentForTesting().indexOf(
            "```text\nHTTP 500:\nraise_exception") >= 0,
            "Provider error formatting corrupted newlines/underscores: " ~
            root.lastAssistantContentForTesting());
        // A later failure after a reply already exists must not add a phantom
        // extra assistant turn on top of it.
        root.failAssistantMessageForTesting("second failure");
        assert(root.messageCountForTesting() == 2,
            "A repeated failure added a phantom assistant turn");
        assert(!root.activityVisibleForTesting(),
            "A failed request left the activity row behind");
        assert(driver.paint(), "Failed-reply layout did not paint");
        writeln("Failure before chatBegin attaches to the reply, not the prompt");
    }

    // Edit tool: a real file edit must report a unified diff with green/red
    // counters (the collapsed part shows +N -M; the body shows line numbers).
    write(buildPath(workspaceDir, "editme.txt"), "alpha\nbeta\ngamma\n");
    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Rename beta"]);
    root.addConversationForTesting(["assistant"], [""]);
    OpenCodeToolCall editCall;
    editCall.id = "call_test_edit";
    editCall.name = "edit";
    editCall.arguments =
        `{"filePath":"editme.txt","oldString":"beta","newString":"BETA"}`;
    root.injectToolCallsForTesting([editCall]);
    // While the edit is running its result/diff is not known yet, so an
    // in-progress row must stand in for it (the old behavior showed nothing for
    // edits, only for read/glob/grep).
    auto liveEditRows = root.liveToolRowTextsForTesting();
    assert(liveEditRows.length == 1,
        "Edit did not show an in-progress row while running");
    assert(liveEditRows[0].indexOf("Edit") >= 0 &&
        liveEditRows[0].indexOf("editme.txt") >= 0,
        "In-progress edit row lacks the tool/file: " ~ liveEditRows[0]);
    writeln("In-progress edit row shown while the edit runs: ", liveEditRows[0]);
    assert(driver.paint(), "In-progress edit row did not paint");
    const liveShots = buildPath(tempDir(), "aurora-opencode-live-shots");
    if (!exists(liveShots)) mkdirRecurse(liveShots);
    window.saveScreenshot(buildPath(liveShots, "live-edit-row.ppm"));
    const editDeadline = Clock.currTime + 5.seconds;
    while (root.toolMessageCountForTesting() < 1 && Clock.currTime < editDeadline)
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    assert(root.toolMessageCountForTesting() == 1,
        "edit tool did not produce a tool result");
    assert(root.toolResultForTesting(0).indexOf("Edited") >= 0,
        "edit tool did not report success: " ~ root.toolResultForTesting(0));
    assert(readText(buildPath(workspaceDir, "editme.txt")).indexOf("BETA") >= 0,
        "edit tool did not apply the change to disk");
    assert(root.toolHasDiffForTesting(0),
        "edit tool did not report a diff body");
    assert(root.toolDiffAdditionsForTesting(0) >= 1,
        "edit diff should report at least one added line");
    assert(root.toolDiffDeletionsForTesting(0) >= 1,
        "edit diff should report at least one deleted line");
    // The collapsed action-group header must show the aggregate +N -M on its
    // right edge, so the added/removed lines are visible without expanding the
    // nested tools.
    assert(root.totalToolGroupAdditionsForTesting() >=
        root.toolDiffAdditionsForTesting(0) &&
        root.totalToolGroupDeletionsForTesting() >=
        root.toolDiffDeletionsForTesting(0),
        "action-group header did not aggregate the edit diff");
    writeln("Action-group header shows aggregate +",
        root.totalToolGroupAdditionsForTesting(), " -",
        root.totalToolGroupDeletionsForTesting(), " while collapsed");
    // The real edit call above was timed by `executeTool`; the duration rides
    // on the tool message, shows on the row, and aggregates into the collapsed
    // group header just like the diff counters.
    assert(root.toolElapsedMsForTesting(0) > 0,
        "real tool call did not report its elapsed time");
    assert(root.totalToolGroupElapsedMsForTesting() >=
        root.toolElapsedMsForTesting(0),
        "action-group header did not aggregate the tool duration");
    writeln("Tool duration shown on the row and group header: ",
        root.toolElapsedMsForTesting(0), "ms");
    assert(root.firstToolBubbleCollapsedForTesting(),
        "edit diff part should start collapsed");
    root.toggleFirstToolBubbleForTesting();
    assert(driver.paint(), "Expanded edit diff did not repaint");
    window.saveScreenshot(buildPath(toolShots, "edit-diff-expanded.ppm"));
    writeln("Edit tool reports a +adds/-dels diff");

    // Restart persistence: the edit's counters and unified diff body must
    // survive a save + reload. They used to be dropped, so after a restart the
    // expanded edit showed a bare one-line summary with no diff at all.
    {
        const addsBefore = root.toolDiffAdditionsForTesting(0);
        const delsBefore = root.toolDiffDeletionsForTesting(0);
        assert(addsBefore >= 1 && delsBefore >= 1,
            "precondition: edit reported a diff");
        root.persistForTesting();
        root.reloadSessionsForTesting();
        assert(root.toolHasDiffForTesting(0),
            "reloaded edit lost its diff body");
        assert(root.toolDiffAdditionsForTesting(0) == addsBefore &&
            root.toolDiffDeletionsForTesting(0) == delsBefore,
            "reloaded edit lost its diff counters");
        root.toggleFirstToolBubbleForTesting();
        assert(driver.paint(), "Restored edit diff did not repaint");
        window.saveScreenshot(buildPath(toolShots, "restored-edit-diff.ppm"));
        root.toggleFirstToolBubbleForTesting();
        writeln("Edit diff survives a save + reload");
    }

    // The tool-call wrapper (the assistant message that requested tools) is
    // not a reply: it must not render as a visible empty bubble, and must not
    // carry an action pill or token usage even if usage streamed first.
    foreach (index; 0 .. root.messageCountForTesting())
    {
        if (root.messageRoleForTesting(index) != "assistant") continue;
        assert(root.bubbleActionForTesting(index) == "",
            "Tool-call wrapper must not carry an action pill");
        assert(!root.bubbleHasUsageForTesting(index),
            "Tool-call wrapper must not show token usage");
        assert(root.bubbleHiddenForTesting(index),
            "Empty tool-call wrapper must not render as a visible bubble");
    }
    writeln("Tool-call wrapper is hidden, no pill, no token usage");

    // Hidden tool-call wrappers keep a column slot for index mapping but must
    // not take part in layout: a zero-height *visible* child still made the VBox
    // add its spacing around it, opening a phantom gap between messages.
    foreach (index; 0 .. root.messageCountForTesting())
    {
        if (!root.bubbleHiddenForTesting(index)) continue;
        assert(!root.bubbleVisibleForTesting(index),
            "Hidden bubble must be excluded from layout");
        assert(root.bubbleHeightForTesting(index) == 0,
            "Hidden bubble must have no height");
    }
    writeln("Hidden wrappers take no layout space");

    // The column here is [user, hidden wrapper, tool]: with the wrapper excluded
    // from layout the tool bubble sits exactly one VBox spacing (6 px) below the
    // user bubble, instead of 12 px (a spacing on each side of the zero-height
    // wrapper).
    if (root.messageCountForTesting() == 3 && root.bubbleHiddenForTesting(1))
    {
        const first = root.bubbleBoundsForTesting(0);
        const next = root.bubbleBoundsForTesting(2);
        assert(next.y - (first.y + first.height) == 6,
            "hidden wrapper added phantom spacing");
    }

    // A stack of collapsed one-line rows must share one pitch. A reasoning
    // "Thinking" header and a tool "Shell" row are both single-line headers; the
    // assistant rows used to reserve an extra timestamp footer (and a 2 px
    // shorter header), so their gaps alternated tall/short — the uneven spacing
    // seen in the screenshot. Every one-line row must now measure the same
    // height and sit exactly one column spacing apart. Each exchange's reasoning
    // is merged into a single block, so build two exchanges: one whose
    // tool-request turn carries the block above its tool row, and one whose
    // answer is reasoning-only.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["go"]);
        root.appendToolRequestTurnForTesting("reasoning one", "call-1", "dshell",
            `{"command":"echo hi"}`);
        root.appendToolReplyForTesting("call-1", "shell out");
        root.addConversationForTesting(["user"], ["again"]);
        root.addConversationForTestingWithReasoning(["assistant"], [""],
            ["reasoning two"]);
        // Trailing user keeps the last assistant reply from being the "latest"
        // one, so no Regenerate pill footer inflates a one-line row.
        root.addConversationForTesting(["user"], ["done"]);
        root.tickTree(0.02);
        assert(driver.paint(), "Uniform-pitch repaint failed");
        const int rowCount = root.messageCountForTesting();
        assert(rowCount == 6,
            "uniform-pitch scenario built the wrong column");
        // Visual rows: [user, Thinking, tool row, user, Thinking, user]; compare
        // the one-line assistant headers (1, 4) against the tool row (2).
        const expected = root.bubbleHeightForTesting(2);
        foreach (i; [cast(int) 1, 2, 4])
        {
            assert(root.bubbleHeightForTesting(i) == expected,
                "one-line rows have different heights: index " ~
                to!string(i) ~ " = " ~
                to!string(root.bubbleHeightForTesting(i)) ~ " vs " ~
                to!string(expected));
        }
        foreach (i; 0 .. rowCount - 1)
        {
            const a = root.bubbleBoundsForTesting(i);
            const b = root.bubbleBoundsForTesting(i + 1);
            assert(b.y - (a.y + a.height) == 6,
                "rows are not one column spacing apart at index " ~
                to!string(i));
        }
        window.saveScreenshot("build\\uniform-row-pitch.ppm");
        writeln("Collapsed rows share a uniform pitch (height=", expected,
            ", gap=6)");
    }

    // The Regenerate/RETRY pill is 18 px tall; reserving only a text line
    // (17 px) left it flush against — overlapping — the reply text ("no top
    // padding"). The latest reply must grow by the pill height + a 6 px gap.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant", "assistant"],
            ["q", "same reply", "same reply"]);
        root.tickTree(0.02);
        assert(driver.paint(), "footer reserve repaint failed");
        assert(root.bubbleActionForTesting(1) == "",
            "only the latest reply carries the pill");
        assert(root.bubbleActionForTesting(2) == "Regenerate",
            "latest reply missing the Regenerate pill");
        const plain = root.bubbleHeightForTesting(1);
        const withPill = root.bubbleHeightForTesting(2);
        assert(withPill == plain + 25,
            "Regenerate footer reserve wrong: " ~ to!string(withPill) ~
            " vs " ~ to!string(plain));
        // The pill sits fully inside the bubble, clear of the reply text.
        const pill = root.bubbleActionBoundsForTesting(2);
        assert(pill.height == 18 && pill.bottom() <= withPill,
            "Regenerate pill must fit inside the reply bubble");
        const continuePill = root.bubbleSecondaryActionBoundsForTesting(2);
        assert(continuePill.height == 18 && pill.right() < continuePill.x &&
            continuePill.bottom() <= withPill,
            "Continue pill overlaps Regenerate or leaves the reply bubble");
        writeln("Regenerate and Continue share a padded reply footer");
    }

    // Real transcript shape: collapsed tool rows interleaved with assistant
    // replies that carry reasoning + answer text, exactly like a restored
    // session (tools and replies alternate). Every restored message has a
    // `time`, but a bare timestamp must not reserve the footer line, or each
    // reply grows `fontPixelSize(1) + 4` px taller than the tool rows around it
    // and the transcript reads as alternating tight/wide gaps.
    {
        root.newChatForTesting();
        root.addConversationForTestingWithReasoning(
            ["tool", "assistant", "tool", "assistant", "tool"],
            ["shell out",
             "Both windows are up — old PID 27208 never touched, new fixed build PID 7216.",
             "shell out",
             "Both still running. Final check of the patched class to confirm it's self-consistent:",
             "shell out"],
            [null, "reasoning one", null, "reasoning two", null]);
        root.tickTree(0.02);
        assert(driver.paint(), "reply/tool repaint failed");
        int[5] bare;
        foreach (i; 0 .. 5)
            bare[i] = root.bubbleHeightForTesting(i);
        // Stamp a timestamp on every row, as a restored session does.
        foreach (i; 0 .. 5)
            root.setMessageTimeForTesting(i, "18:38");
        root.tickTree(0.02);
        assert(driver.paint(), "reply/tool repaint (time) failed");
        foreach (i; 0 .. 5)
            assert(root.bubbleHeightForTesting(i) == bare[i],
                "a bare timestamp added phantom height to row " ~ to!string(i) ~
                " (" ~ to!string(bare[i]) ~ " -> " ~
                to!string(root.bubbleHeightForTesting(i)) ~ ")");
        // Collapsed tool rows keep one pitch, and every bubble boundary sits
        // exactly one column spacing from the next.
        foreach (i; 0 .. 4)
        {
            const a = root.bubbleBoundsForTesting(i);
            const b = root.bubbleBoundsForTesting(i + 1);
            assert(b.y - (a.y + a.height) == 6,
                "rows are not one column spacing apart at index " ~
                to!string(i));
        }
        window.saveScreenshot("build\\uniform-row-pitch-replies.ppm");
        writeln("Replies and tool rows share one gap (no timestamp band)");
    }

    // Repetition guides rather than controls: all three identical calls execute
    // and the third result adds a hidden note asking the model to reconsider
    // its approach. No tool result is fabricated or skipped.
    const userCountBefore = root.userMessageCountForTesting();
    const repeatedToolCountBefore = root.toolMessageCountForTesting();
    OpenCodeToolCall loopCall;
    loopCall.id = "call_loop";
    loopCall.name = "dshell";
    loopCall.arguments = `{"command":"list"}`;
    foreach (round; 0 .. 3)
    {
        root.addConversationForTesting(["assistant"], [""]);
        const target = repeatedToolCountBefore + cast(int) round + 1;
        root.injectToolCallsForTesting([loopCall]);
        const repeatDeadline = Clock.currTime + 2.seconds;
        while (root.toolMessageCountForTesting() < target &&
            Clock.currTime < repeatDeadline)
        {
            root.tickTree(0.01);
            Thread.sleep(5.msecs);
        }
        assert(root.toolMessageCountForTesting() == target,
            "repeated tool request was not executed at round " ~
            to!string(round));
    }
    assert(root.userMessageCountForTesting() == userCountBefore + 1,
        "repeat guidance was not appended after the completed result");
    assert(root.lastUserMessageForTesting().indexOf("Progress guidance") >= 0,
        "repeat guidance was not marked as internal progress context");
    assert(root.toolRepeatCountForTesting() == 3,
        "repeat tracking was reset as if the tool had been blocked");
    assert(root.lastToolResultForTesting().indexOf("skipped") < 0,
        "repeated tool execution was replaced by a skipped result");
    writeln("Repeated identical tools execute and receive hidden guidance");

    // Repeated failures likewise remain real tool results. The runtime adds
    // guidance after the third result but does not block, finalize, or pretend
    // that the user supplied the instruction.
    root.addConversationForTesting(["assistant"], [""]);
    const failUserCountBefore = root.userMessageCountForTesting();
    root.injectToolResultForTesting("bash", "Error: module not found", true);
    root.injectToolResultForTesting("bash", "Error: module not found", true);
    root.injectToolResultForTesting("bash", "Error: module not found", true);
    assert(root.userMessageCountForTesting() == failUserCountBefore + 1,
        "repeated-failure guidance was not appended");
    assert(root.lastUserMessageForTesting().indexOf("Progress guidance") >= 0,
        "repeated-failure guidance was not marked as internal: " ~
        root.lastUserMessageForTesting());
    auto recoveryRequest = root.requestMessagesForTesting();
    assert(recoveryRequest.length > 0 && recoveryRequest[$ - 1].role == "system",
        "Internal progress guidance was sent as a fake user message");
    assert(recoveryRequest[$ - 1].content.indexOf(
        "Internal agent-control instruction") >= 0,
        "Internal progress guidance lost its control-role marker");
    writeln("Repeated failures execute and receive hidden guidance");

    // Let the earlier real workers settle before starting the sequential
    // long-horizon probe; otherwise their late result can consume its pending
    // slot and make the first distinct call appear to vanish.
    const evidenceSettleDeadline = Clock.currTime + 5.seconds;
    while (Clock.currTime < evidenceSettleDeadline &&
        (root.pendingToolResultsForTesting() > 0 ||
         root.liveToolCallCountForTesting() > 0 ||
         root.clientBusyForTesting()))
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    root.newChatForTesting();
    assert(root.initializeAutomaticPlanForTesting(
        "Add a folder button to appui.d"),
        "change request did not receive an application-owned task plan");
    assert(root.taskStepCountForTesting() == 3 &&
        root.taskStepStatusForTesting(0) == "in_progress",
        "automatic task plan did not begin in the inspection phase");
    root.addConversationForTesting(["assistant"], [""]);

    // Long-horizon regression: distinct evidence-gathering rounds are valid
    // progress. The old five-round exploration budget forcibly skipped these
    // calls, permanently preventing diagnostics and the autosave-prompt task
    // captured in the real failing transcript from reaching an edit.
    const evidenceBase = root.toolMessageCountForTesting();
    foreach (round; 0 .. 12)
    {
        if (round > 0)
            root.addConversationForTesting(["assistant"], [""]);
        OpenCodeToolCall variedRead;
        variedRead.id = "call_evidence_" ~ to!string(round);
        variedRead.name = "dshell";
        variedRead.arguments = `{"command":"list","pattern":"evidence-` ~
            to!string(round) ~ `-*"}`;
        root.injectToolCallsForTesting([variedRead]);
        const targetEvidenceCount = evidenceBase + cast(int) round + 1;
        const roundDeadline = Clock.currTime + 2.seconds;
        while (root.toolMessageCountForTesting() < targetEvidenceCount &&
            Clock.currTime < roundDeadline)
        {
            root.tickTree(0.01);
            Thread.sleep(5.msecs);
        }
        assert(root.toolMessageCountForTesting() == targetEvidenceCount,
            "distinct evidence round was skipped at round " ~ to!string(round));
    }
    assert(root.explorationCountForTesting() == 12,
        "distinct exploration was not counted toward the progress budget");
    assert(root.applyExplorationCheckpointForTesting(),
        "read-only budget did not produce an action checkpoint");
    assert(root.lastUserMessageForTesting().indexOf(
        "Exploration checkpoint") >= 0,
        "action checkpoint instruction was not appended");
    assert(root.taskStepStatusForTesting(0) == "completed" &&
        root.taskStepStatusForTesting(1) == "in_progress",
        "action checkpoint did not advance the automatic plan to implementation");
    writeln("Distinct evidence rounds remain available for long-horizon work");

    // A checkpoint is a decision point, not a blind cutoff. One focused lookup
    // remains available when a concrete unknown still blocks a safe edit.
    root.addConversationForTesting(["assistant"], [""]);
    OpenCodeToolCall focusedRead;
    focusedRead.id = "call_evidence_focused";
    focusedRead.name = "dshell";
    focusedRead.arguments = `{"command":"info","path":"."}`;
    const focusedTarget = root.toolMessageCountForTesting() + 1;
    root.injectToolCallsForTesting([focusedRead]);
    const focusedDeadline = Clock.currTime + 2.seconds;
    while (root.toolMessageCountForTesting() < focusedTarget &&
        Clock.currTime < focusedDeadline)
    {
        root.tickTree(0.01);
        Thread.sleep(5.msecs);
    }
    assert(root.toolMessageCountForTesting() == focusedTarget,
        "checkpoint prevented a justified focused inspection");
    assert(root.taskStatusForTesting() != "blocked",
        "focused post-checkpoint inspection incorrectly blocked the task");
    const exhaustedExplorationCount = root.explorationCountForTesting();
    // A failed patch and a comment-only edit must not reset the request-wide
    // evidence count or falsely satisfy the implementation/completion gate.
    root.injectToolResultForTesting("apply_patch", "patch context not found",
        true, `{"patch":"failed"}`);
    assert(root.explorationCountForTesting() == exhaustedExplorationCount,
        "failed mutation changed the request-wide exploration budget to " ~
        to!string(root.explorationCountForTesting()));
    root.injectToolResultForTesting("edit", "Edited comment", false,
        `{"filePath":"app.d"}`, 1, 0,
        "@@ -1,1 +1,2 @@\n code\n+// unlock reads\n");
    assert(root.explorationCountForTesting() == exhaustedExplorationCount,
        "comment-only mutation reset the request-wide exploration budget");
    assert(root.verificationStatusForTesting() != "required",
        "comment-only mutation falsely satisfied implementation progress");
    root.injectToolResultForTesting("edit", "Edited implementation", false,
        `{"filePath":"app.d"}`, 1, 1,
        "@@ -1 +1 @@\n-old behavior\n+new behavior\n");
    assert(root.explorationCountForTesting() == exhaustedExplorationCount,
        "substantive mutation reset the request-wide exploration budget");
    writeln("Exploration checkpoint guides action without disabling inspection");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["Make and verify a change"]);
    root.addConversationForTesting(["assistant"], [""]);
    root.injectToolResultForTesting("edit", "Edited app.d", false,
        `{"filePath":"app.d"}`, 1, 1,
        "@@ -1 +1 @@\n-old\n+new\n");
    assert(root.verificationStatusForTesting() == "required",
        "substantive mutation did not require verification");
    root.injectToolResultForTesting("run", "tests passed", false,
        `{"program":"dub","args":["test"]}`);
    assert(root.verificationStatusForTesting() == "passed",
        "successful focused check did not pass verification");
    root.addConversationForTesting(["assistant"], [""]);
    OpenCodeToolCall postVerifyRead;
    postVerifyRead.id = "call_post_verify_read";
    postVerifyRead.name = "dshell";
    postVerifyRead.arguments = `{"command":"list"}`;
    const postVerifyTarget = root.toolMessageCountForTesting() + 1;
    root.injectToolCallsForTesting([postVerifyRead]);
    const postVerifyDeadline = Clock.currTime + 2.seconds;
    while (root.toolMessageCountForTesting() < postVerifyTarget &&
        Clock.currTime < postVerifyDeadline)
    {
        root.tickTree(0.01);
        Thread.sleep(5.msecs);
    }
    assert(root.toolMessageCountForTesting() == postVerifyTarget,
        "a post-verification inspection was blocked");
    assert(root.lastToolResultForTesting().indexOf("skipped") < 0,
        "post-verification inspection received a fabricated skipped result");
    writeln("Passed verification does not revoke tool access");
    assert(!root.hasAutomaticTurnTimeoutForTesting() &&
        root.toolRoundLimitForTesting() == 0,
        "long-horizon work still has an automatic timeout or round cap");
    writeln("Long-horizon turns have no automatic timeout or round cap");

    // The repetition-guidance injections run real local tool workers and a follow-up
    // request. Drain their queued events here; otherwise one lands in the
    // middle of the cache/perf block below and calls rebuildMessageColumn(),
    // discarding the tool-row cache and making "re-expand shaped 0 rows" flaky.
    const toolSettleDeadline = Clock.currTime + 5.seconds;
    while (Clock.currTime < toolSettleDeadline &&
        (root.pendingToolResultsForTesting() > 0 ||
         root.liveToolCallCountForTesting() > 0 ||
         root.clientBusyForTesting()))
    {
        root.tickTree(0.02);
        Thread.sleep(20.msecs);
    }
    foreach (i; 0 .. 3)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    assert(root.pendingToolResultsForTesting() <= 0 &&
        root.liveToolCallCountForTesting() == 0,
        "injected tool workers did not settle before the cache test");

    // Tool outputs start collapsed (a compact header) and expand on click.
    assert(root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble should start collapsed");
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded tool bubble did not repaint");
    assert(!root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble did not expand on toggle");
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapsed tool bubble did not repaint");
    assert(root.firstToolBubbleCollapsedForTesting(),
        "Tool result bubble did not collapse again");
    writeln("Tool outputs collapse by default and expand on click");

    // Regression: expanding/collapsing a tool output must NOT snap the scroll
    // to the bottom. Scroll up, expand, and confirm the offset is preserved.
    const beforeScroll = root.scrollYForTesting();
    if (beforeScroll > 0)
    {
        root.scrollToForTesting(maxInt(0, beforeScroll / 2));
        root.tickTree(0.02);
        assert(driver.paint(), "Scroll-up did not repaint");
    }
    const midScroll = root.scrollYForTesting();
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expand did not repaint after scroll-up");
    const afterExpandScroll = root.scrollYForTesting();
    // Allow a tiny clamp drift (the max may shrink), but never a jump to the
    // bottom when the expanded bubble is above the fold.
    assert(afterExpandScroll <= midScroll + 4,
        "Expanding a tool output snapped the scroll down: " ~
        to!string(midScroll) ~ " -> " ~ to!string(afterExpandScroll));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Collapse did not repaint after scroll-up");
    writeln("Tool collapse/expand preserves the scroll position");

    const shotDir = buildPath(tempDir(), "aurora-opencode-collapse-shots");
    if (!exists(shotDir)) mkdirRecurse(shotDir);
    window.saveScreenshot(buildPath(shotDir, "tool-collapsed.ppm"));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    assert(driver.paint(), "Expanded tool bubble did not repaint");
    window.saveScreenshot(buildPath(shotDir, "tool-expanded.ppm"));
    root.toggleFirstToolBubbleForTesting();
    root.tickTree(0.02);
    writeln("Collapse screenshots: ", shotDir);

    // Regression: a mid-stream column rebuild (a throttled tool-argument delta
    // calls rebuildMessageColumn many times a second) must neither yank a
    // reader who scrolled up back to the bottom nor snap shut an output the
    // user expanded. Build a deliberately tall transcript so the view is
    // actually scrollable, then scroll to the top and force a rebuild.
    {
        root.newChatForTesting();
        import std.array : appender;
        auto body = appender!string();
        foreach (i; 0 .. 14)
            body.put("Filler line " ~ to!string(i) ~
                " padding the transcript so it overflows the viewport.\n");
        foreach (i; 0 .. 8)
        {
            root.addConversationForTesting(["user"],
                ["Question " ~ to!string(i)]);
            root.addConversationForTesting(["assistant"], [body.data]);
        }
        root.appendToolMessageForTesting("read", "tool body\n",
            `{"filePath":"tall.txt"}`, 0, 0, "");
        root.tickTree(0.02);
        assert(driver.paint(), "Tall transcript paint failed");
        root.scrollToForTesting(int.max);
        root.tickTree(0.02);
        const scrollRange = root.scrollYForTesting();
        assert(scrollRange > 0,
            "tall transcript should be scrollable, range=" ~
            to!string(scrollRange));
        // A frameless Windows resize margin overlaps the right side of the
        // client area. Aurora must let the retained scrollbar claim its own
        // pixels, or roughly half of this narrow track resizes the window.
        auto transcriptScroll = cast(ScrollView) findById(root, "oc-scroll");
        assert(transcriptScroll !is null &&
            transcriptScroll.verticalScrollbar().visible(),
            "tall transcript scrollbar should be visible");
        auto edgeScrollbar = transcriptScroll.verticalScrollbar();
        const edgePoint = edgeScrollbar.localToGlobal(Point(
            edgeScrollbar.bounds().width / 2,
            edgeScrollbar.bounds().height / 2));
        assert(window.onNativeClientControlAt(edgePoint),
            "borderless resize hit-test stole the scrollbar's track");
        writeln("Scrollbar wins over overlapping frameless resize margin");
        root.scrollToForTesting(0);
        root.tickTree(0.02);
        assert(!root.followForTesting(),
            "scrolling to the top should have disengaged auto-follow");
        assert(root.firstToolBubbleCollapsedForTesting(),
            "tool output should start collapsed");
        root.toggleFirstToolBubbleForTesting();
        root.tickTree(0.02);
        assert(!root.firstToolBubbleCollapsedForTesting(),
            "tool output did not expand before the rebuild test");
        root.rebuildForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Rebuild did not repaint");
        assert(!root.firstToolBubbleCollapsedForTesting(),
            "a rebuild collapsed the tool output the user had expanded");
        assert(root.scrollYForTesting() <= 4,
            "a rebuild yanked the scroll to " ~
            to!string(root.scrollYForTesting()));
        assert(!root.followForTesting(),
            "a rebuild re-engaged auto-follow after the user scrolled up");
        // Conversely, a reader who is at the bottom keeps following: removing the
        // forced follow must not disable auto-follow for new content. Leave the
        // view at the bottom so later tests start from the auto-follow state.
        root.scrollToForTesting(int.max);
        root.tickTree(0.02);
        assert(root.followForTesting(),
            "scrolling to the bottom should re-engage auto-follow");
        const bottom = root.scrollYForTesting();
        root.rebuildForTesting();
        root.tickTree(0.02);
        assert(root.followForTesting(),
            "a rebuild at the bottom should keep auto-follow engaged");
        assert(root.scrollYForTesting() == bottom,
            "a rebuild at the bottom should stay pinned to the bottom");
    }
    writeln("Rebuild keeps scroll position and expanded tool outputs");

    // Read bodies survive a restart: their text is persisted and the restored
    // Explored group still expands to render the read output (the reported
    // regression was that read/edit bodies went blank after a restart).
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Read both files"]);
        root.addConversationForTesting(["assistant"], [""]);
        root.appendToolMessageForTesting("read",
            "line one\nline two\nline three\n", `{"filePath":"a.txt"}`,
            0, 0, "", 1234);
        root.appendToolMessageForTesting("read", "second file\nbody\n",
            `{"filePath":"b.txt"}`, 0, 0, "", 4321);
        assert(root.contextGroupCountForTesting() == 1,
            "two reads did not fold into one context group");
        root.persistForTesting();
        root.reloadSessionsForTesting();
        assert(root.toolResultForTesting(0).indexOf("line one") >= 0,
            "restored read lost its content: " ~ root.toolResultForTesting(0));
        assert(root.toolResultForTesting(1).indexOf("second file") >= 0,
            "restored second read lost its content");
        // The duration is persisted with the message, so a reloaded transcript
        // still shows how long each tool took.
        assert(root.toolElapsedMsForTesting(0) == 1234,
            "restored tool lost its elapsed time: " ~
            to!string(root.toolElapsedMsForTesting(0)));
        assert(root.totalToolGroupElapsedMsForTesting() >= 1234,
            "restored group header lost the elapsed time");
        assert(root.contextGroupCountForTesting() == 1,
            "restored reads did not fold into a group");
        assert(root.firstToolGroupPartCountForTesting() == 2,
            "restored group lost a read part");
        root.toggleFirstToolGroupForTesting();
        assert(driver.paint(), "Restored read group did not repaint");
        window.saveScreenshot(buildPath(shotDir, "restored-reads-expanded.ppm"));
        root.toggleFirstToolGroupForTesting();
        writeln("Read bodies survive a save + reload");
    }

    // Conversation work-time timer: the composer footer shows how long the chat
    // has taken overall — every finished turn plus the turn in flight — ticking
    // in real time and surviving a restart.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"],
            ["Time this chat", "Done."]);
        assert(root.chatWorkedSecondsForTesting() == 0,
            "a fresh chat already had accumulated work time: " ~
            to!string(root.chatWorkedSecondsForTesting()) ~ " running=" ~
            to!string(root.chatTimerRunningForTesting()));
        root.setChatWorkedSecondsForTesting(67);
        assert(root.chatWorkedSecondsForTesting() == 67,
            "chat work time did not accumulate: " ~
            to!string(root.chatWorkedSecondsForTesting()));
        assert(root.chatTimerLabelForTesting() == "Total 1m 07s",
            "chat timer label wrong: " ~ root.chatTimerLabelForTesting());
        assert(driver.paint(), "Chat timer badge did not paint");
        root.persistForTesting();
        root.reloadSessionsForTesting();
        assert(root.chatWorkedSecondsForTesting() == 67,
            "chat work time did not survive a reload: " ~
            to!string(root.chatWorkedSecondsForTesting()));
        assert(root.chatTimerLabelForTesting() == "Total 1m 07s",
            "restored chat timer label wrong: " ~
            root.chatTimerLabelForTesting());
        // While a turn is in flight the badge is in its live (running) state.
        root.startTurnClockForTesting();
        assert(root.chatTimerRunningForTesting(),
            "chat timer should run during an active turn");
        root.finishStreamForTesting();
        assert(!root.chatTimerRunningForTesting(),
            "chat timer kept running after the turn finished");
        writeln("Chat timer accumulates the conversation's work time and persists");
    }

    // Collapse/expand performance: expanding a tool output used to shape every
    // row up front (600 rows, ~2 s of freeze). Now only the visible rows are
    // shaped and the layout is cached across toggles, so the first expand is
    // bounded and every later toggle does no shaping at all.
    root.newChatForTesting();
    {
        import std.array : appender;
        string[] roles, bodies;
        roles ~= "user"; bodies ~= "Do the work.";
        foreach (i; 0 .. 40)
        {
            roles ~= "assistant";
            bodies ~= "Reply number " ~ to!string(i) ~
                " with some **markdown** text, a `code` span, and a list:\n" ~
                "- one\n- two\n- three\n";
            roles ~= "user";
            bodies ~= "Follow-up " ~ to!string(i);
        }
        auto big = appender!string();
        foreach (i; 0 .. 4000)
            big.put("line " ~ to!string(i) ~
                " of a large tool output with some content\n");
        roles ~= "tool";
        bodies ~= big.data;
        root.addConversationForTesting(roles, bodies);
    }
    root.tickTree(0.02);
    assert(driver.paint(), "Large-output paint failed");

    size_t expandTool()
    {
        root.toggleFirstToolBubbleForTesting();
        root.tickTree(0.02);
        const before = root.bubbleShapeCountForTesting();
        const started = Clock.currTime;
        assert(driver.paint(), "Tool expand paint failed");
        const shapes = root.bubbleShapeCountForTesting() - before;
        const elapsed = (Clock.currTime - started).total!"msecs";
        assert(shapes <= 120,
            "Expanding a large tool output shaped too many rows: " ~
            to!string(shapes));
        assert(elapsed < 1500,
            "Expanding a large tool output was too slow: " ~
            to!string(elapsed) ~ " ms");
        return shapes;
    }
    void collapseTool()
    {
        root.toggleFirstToolBubbleForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Tool collapse paint failed");
    }
    const firstToolShapes = expandTool();
    // Regression: the lazy row culling subtracted a canvas-local `top` from a
    // surface-space clip, so an offset/scrolled tool body culled nearly every
    // row and rendered blank. With the clip converted to local coordinates the
    // expanded body must actually contain ink.
    {
        auto scroll = requireWidget!Widget(root, "oc-scroll");
        const origin = scroll.globalOrigin();
        const sb = scroll.bounds();
        auto surface = window.surface();
        size_t ink;
        const x0 = maxInt(0, origin.x);
        const y0 = maxInt(0, origin.y);
        const x1 = minInt(surface.width(), origin.x + sb.width - 20);
        const y1 = minInt(surface.height(), origin.y + sb.height);
        foreach (y; y0 .. y1)
            foreach (x; x0 .. x1)
            {
                const pixel = surface.pixels()[cast(size_t) y *
                    cast(size_t) surface.width() + cast(size_t) x];
                const lum = ((pixel >> 16) & 0xff) + ((pixel >> 8) & 0xff) +
                    (pixel & 0xff);
                if (lum > 200) ++ink;
            }
        writeln("Large tool output expand ink=", ink);
        window.saveScreenshot("build\\large-tool-expanded.ppm");
        assert(ink > 500,
            "Expanded large tool output rendered blank (ink=" ~
            to!string(ink) ~ ")");
    }
    collapseTool();
    const secondToolShapes = expandTool();
    assert(secondToolShapes == 0,
        "Re-expanding a tool output re-shaped rows: " ~
        to!string(secondToolShapes));
    collapseTool();
    writeln("Large tool output: first expand shapes=", firstToolShapes,
        ", re-expand shapes=", secondToolShapes);

    // Thinking block: a long reasoning block must also cache its wrapped shape
    // across toggles instead of re-shaping the whole text every time.
    root.newChatForTesting();
    {
        import std.array : appender;
        auto reason = appender!string();
        foreach (i; 0 .. 400)
            reason.put("Reasoning line " ~ to!string(i) ~
                " weighing the options and constraints carefully.\n");
        root.addConversationForTestingWithReasoning(["user", "assistant"],
            ["Think hard", "The answer."], [null, reason.data]);
    }
    root.tickTree(0.02);
    assert(driver.paint(), "Long-reasoning paint failed");
    {
        root.toggleLastThinkingForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Thinking expand paint failed");
        root.toggleLastThinkingForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Thinking collapse paint failed");
        const before = root.bubbleShapeCountForTesting();
        root.toggleLastThinkingForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Thinking re-expand paint failed");
        const reshaped = root.bubbleShapeCountForTesting() - before;
        // One wrapped block may be re-shaped at a newly-seen width, but it must
        // never be shaped per line. Anything above a couple means the
        // width-keyed cache regressed.
        assert(reshaped <= 2,
            "Re-expanding reasoning re-shaped too much: " ~ to!string(reshaped));
        writeln("Reasoning re-expand shapes=", reshaped);
    }

    // Empty-conversation intro overlay: a brand-new chat shows the welcome
    // block (suggestions measured and laid out) and hides it the moment the
    // first message arrives. Clicking a suggestion prefills the composer.
    {
        root.newChatForTesting();
        root.tickTree(0.02);
        assert(driver.paint(), "Empty-state intro did not paint");
        auto intro = requireWidget!Widget(root, "oc-intro");
        assert(root.introVisibleForTesting(),
            "Intro overlay should be visible on an empty conversation");
        const introBounds = intro.bounds();
        assert(introBounds.width > 0 && introBounds.height > 0,
            "Intro overlay should fill the transcript viewport");
        const suggestions = root.introSuggestionsForTesting();
        assert(suggestions.length > 0, "Intro overlay has no suggestions");
        // Staggered fade-in: visible immediately, fully opaque within a tick.
        assert(root.introFadeForTesting() < 1.0,
            "Intro overlay should still be fading in on first paint");
        root.tickTree(0.3);
        assert(root.introFadeForTesting() >= 1.0,
            "Intro overlay fade did not complete");
        assert(driver.paint(), "Faded intro did not paint");
        window.saveScreenshot("build\\intro-empty.ppm");
        const firstPill = root.introSuggestionBoundsForTesting(0);
        assert(firstPill.width > 0 && firstPill.height > 0,
            "Intro suggestion pill was not laid out");
        assert(root.clickIntroSuggestionForTesting(0),
            "Clicking an intro suggestion should prefill the composer");
        root.tickTree(0.02);
        assert(root.inputTextForTesting() == suggestions[0],
            "Intro suggestion did not populate the prompt input");
        assert(root.introVisibleForTesting(),
            "Prefilling the prompt should keep the intro (no message yet)");
        root.setInputForTesting("");

        // A real pointer press on the pill must reach the overlay through the
        // normal hit-test/dispatch path, not just the test callback.
        const pillOrigin = intro.localToGlobal(
            Point(firstPill.x, firstPill.y));
        driver.click(Point(pillOrigin.x + firstPill.width / 2,
            pillOrigin.y + firstPill.height / 2));
        root.tickTree(0.02);
        assert(root.inputTextForTesting() == suggestions[0],
            "A real click on an intro suggestion did not prefill the prompt");
        root.setInputForTesting("");
        writeln("Empty-state intro shows and prefills the composer");

        // The first message replaces the welcome with the transcript.
        root.addConversationForTesting(["user"], ["Hello there"]);
        root.tickTree(0.02);
        assert(driver.paint(), "Transcript after intro did not paint");
        assert(!root.introVisibleForTesting(),
            "Intro overlay should hide once a message exists");
        // Switching back to the still-empty chat brings it back.
        root.newChatForTesting();
        root.tickTree(0.02);
        assert(root.introVisibleForTesting(),
            "A fresh conversation should show the intro again");
        assert(root.introFadeForTesting() < 1.0,
            "Re-showing the intro should replay the fade");
        root.addConversationForTesting(["user"], ["Second chat prompt"]);
        root.tickTree(0.02);
        assert(!root.introVisibleForTesting(),
            "Intro overlay should stay hidden after the next prompt");
        writeln("Intro overlay tracks conversation emptiness");
    }

    // Rebuild: a Rebuild button in the toolbar, and a request that persists
    // state and hands the rebuild to a detached helper before closing the
    // window. The request is not exercised here (it would spawn a real build
    // and close the window under the test); the button wiring and the gating
    // predicates are.
    {
        auto rebuildButton = requireWidget!Button(root, "oc-rebuild");
        assert(rebuildButton.text() == "Rebuild"d,
            "Rebuild button must be labelled Rebuild");
        assert(!root.rebuildPendingForTesting(),
            "a rebuild must not be pending before one is requested");
        // This test binary is built into build\ inside the package, so the
        // executable does have a DUB recipe above it and can rebuild in place.
        assert(root.canRebuildForTesting(),
            "the packaged build should be able to rebuild itself");
        auto rebuildPlan = planRebuild(stateDir, true, 12345,
            buildPath(stateDir, "package", "aurora-opencode-pro.exe"));
        // Rebuild hands the work to the standalone rebuilder, so the argv it
        // would spawn is what is inspected: one implementation, one caller.
        auto scriptedPlan = rebuildPlan;
        scriptedPlan.workingDir = buildPath("C:\\", "repo with spaces");
        const helperArgv = rebuildHelperArgv(scriptedPlan);
        if (helperArgv.length > 0)
        {
            const helperLine = helperArgv.join(" ");
            assert(helperLine.indexOf("aurora-rebuilder.exe") >= 0,
                "Rebuild must use the standalone rebuilder: " ~ helperLine);
            assert(helperLine.indexOf("--rebuild") < 0 &&
                helperLine.indexOf("--no-rebuild") < 0,
                "a rebuild was requested, so no --no-rebuild flag belongs " ~
                "in the argv: " ~ helperLine);
            assert(helperLine.indexOf("repo with spaces") >= 0,
                "the package directory must be passed through verbatim: " ~
                helperLine);
            assert(helperLine.indexOf("--run") >= 0,
                "the relaunched app is watched so its exit code is " ~
                "recorded: " ~ helperLine);
        }
        else
            writeln("Rebuild helper not built; argv inspection skipped");
        writeln("Rebuild button present; rebuild-in-place available");
    }

    // The UI now publishes backend-neutral thread/item lifecycle records to an
    // append-only journal. This is the compatibility seam for future Codex and
    // provider-neutral runtimes, and must survive independently of sessions.json.
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user"], ["Build durable recovery"]);
        root.setTaskStateForTesting("Build durable recovery", "active",
            "not_required");
        root.applyPlanForTesting(
            `{"plan":[{"step":"Persist objective","status":"completed"},` ~
            `{"step":"Verify recovery","status":"in_progress"}]}`);
        root.startTurnClockForTesting();
        root.setInputForTesting("Keep it GUI-first");
        root.sendForTesting();
        root.stopTurnClockForTesting();
        assert(root.taskStepCountForTesting() == 2,
            "update_plan was not captured as durable checklist state");
        assert(root.queuedGuidanceCountForTesting() == 1,
            "active-turn guidance was not queued durably");
        assert(root.inputTextForTesting().length == 0,
            "queued active-turn guidance was not cleared from the composer");
        assert(root.queuedPromptBubbleCountForTesting() == 1,
            "a queued prompt did not appear as a pending transcript bubble");
        assert(root.queuedPromptBubbleTextForTesting(0) == "Keep it GUI-first",
            "the pending prompt bubble lost its text: " ~
            root.queuedPromptBubbleTextForTesting(0));
        assert(driver.paint(), "a queued prompt bubble did not paint");
        root.persistForTesting();
        root.reloadSessionsForTesting();
        assert(root.taskObjectiveForTesting() == "Build durable recovery" &&
            root.taskStepCountForTesting() == 2 &&
            root.queuedGuidanceCountForTesting() == 1,
            "task objective/checklist/guidance did not survive snapshot reload");
        assert(root.consumeGuidanceForTesting(),
            "queued guidance was not injected at a safe boundary");
        assert(root.queuedGuidanceCountForTesting() == 0,
            "consumed guidance remained queued");
        assert(root.queuedPromptBubbleCountForTesting() == 0,
            "the pending prompt bubble was not replaced by a real turn");
        assert(root.completionWouldContinueForTesting(),
            "unfinished durable checklist did not hold completion open");
        const checklistGate = root.incompleteChecklistGatePromptForTesting();
        assert(checklistGate.indexOf("call update_plan once") >= 0 &&
            checklistGate.indexOf("do not repeat the completion report") >= 0,
            "checklist reconciliation gate can still provoke a duplicate " ~
            "completion report: " ~ checklistGate);
        root.applyPlanForTesting(
            `{"plan":[{"step":"Persist objective","status":"completed"},` ~
            `{"step":"Verify recovery","status":"completed"}]}`);

        root.injectToolResultForTesting("edit", "Edited file", false,
            `{"path":"example.d"}`, 1, 1,
            "@@ -1,1 +1,1 @@\n-old\n+new\n");
        assert(root.completionNeedsVerificationForTesting(),
            "a successful file mutation did not arm the completion gate");
        root.injectToolResultForTesting("run", "Tests passed", false,
            `{"argv":["dub","test"]}`);
        assert(root.verificationStatusForTesting() == "passed" &&
            !root.completionNeedsVerificationForTesting(),
            "a focused successful check did not satisfy the completion gate");
        assert(!root.completionWouldContinueForTesting(),
            "completed checklist plus successful verification stayed open");

        root.restoreJournalOnlyForTesting();
        assert(root.taskObjectiveForTesting() == "Build durable recovery" &&
            root.taskStepCountForTesting() == 2 &&
            root.verificationStatusForTesting() == "passed",
            "journal-only recovery did not reconstruct durable task state");
        writeln("Durable goals, steering, verification, and journal replay work");

        const journalPath = buildPath(stateDir, "runtime-events.jsonl");
        assert(exists(journalPath), "agent runtime journal was not created");
        const events = readAgentRuntimeEvents(journalPath);
        assert(events.length > 0, "agent runtime journal contains no events");
        bool sawThread;
        bool sawItem;
        ulong previous;
        foreach (event; events)
        {
            assert(event.threadId.length > 0,
                "runtime event is missing its durable thread id");
            assert(event.sequence > previous,
                "runtime event sequence is not strictly increasing");
            previous = event.sequence;
            if (event.kind == AgentEventKind.threadStarted) sawThread = true;
            if (event.kind == AgentEventKind.itemAdded) sawItem = true;
        }
        assert(sawThread, "runtime journal has no thread.started event");
        assert(sawItem, "runtime journal has no item.added event");
        writeln("Durable agent runtime journal records thread/item events");
    }

    root.shutdownClient();
    window.close();
    try rmdirRecurse(stateDir);
    catch (Exception) {}
    writeln("Aurora OpenCode Pro headless smoke test passed.");
    return 0;
}


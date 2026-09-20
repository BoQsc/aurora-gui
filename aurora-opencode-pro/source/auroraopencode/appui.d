module auroraopencode.appui;

import aurora;
import auroraopencode.core;
import auroraopencode.logging : logError, logInfo, setLogDirectory;
import auroraopencode.crashguard : noteActivity;
import auroraopencode.markdown : MarkdownComposer, MdComposition, MdItemKind,
    paintMarkdown, parseMarkdown;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import auroraopencode.runtime : AgentEventKind, AgentRuntime,
    AgentRuntimeEvent, DurableAgentRuntime, projectAgentRuntimeEvents,
    deletedAgentRuntimeThreadIds;
import auroraopencode.rebuild : launchRebuild, planRebuild;
import auroraopencode.titlebar : OpenCodeTitleBar;
import auroraopencode.tools : buildSystemPrompt, builtinToolDefinitions,
    changeRecordDiff, executeTool, listChangeRecords,
    nativeOnlyToolDefinitions, partialStringArg, previewToolDiff,
    revertChangeRecord, ChangeContext, ChangeRecord, ToolCancellation,
    ToolExecution;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : canFind, max;
import std.array : appender;
import std.conv : to;
import std.datetime : Clock;
// `remove` is aliased because this module's widget base class declares its own
// `remove(Widget child)`, which otherwise wins name lookup inside the class.
import std.file : exists, isDir, fileRemove = remove, mkdirRecurse, readText, rename,
    thisExePath, timeLastModified, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : isFinite;
import std.path : baseName, buildPath;
import std.process : thisProcessID;
import std.string : indexOf, replace, startsWith, strip, toLower;
import std.utf : toUTF16z, toUTF32;
version (Windows)
{
    pragma(lib, "user32");
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock,
        GMEM_MOVEABLE, HWND, OpenClipboard, SetClipboardData;
    import core.sys.windows.shellapi : ShellExecuteW;
    import std.utf : toUTF16;
}

// ---------------------------------------------------------------------------
// Pro-only platform helpers: clipboard, external links, timestamps
// ---------------------------------------------------------------------------

version (Windows)
private bool writeSystemClipboardText(const(dchar)[] value)
{
    if (!OpenClipboard(null)) return false;
    scope (exit) CloseClipboard();
    if (!EmptyClipboard()) return false;

    auto encoded = toUTF16(value);
    const bytes = (encoded.length + 1) * wchar.sizeof;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory is null) return false;
    auto text = cast(wchar*) GlobalLock(memory);
    if (text is null)
    {
        GlobalFree(memory);
        return false;
    }
    foreach (index, ch; encoded) text[index] = ch;
    text[encoded.length] = 0;
    GlobalUnlock(memory);

    if (SetClipboardData(CF_UNICODETEXT, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }
    return true;
}

private void copyTextToClipboard(string text)
{
    version (Windows)
        writeSystemClipboardText(toUTF32(text));
}

version (Windows)
private void openLinkInBrowser(string url)
{
    ShellExecuteW(null, null, toUTF16z(url), null, null, 1);
}

version (Windows)
private void openFolderInExplorer(string path)
{
    // The "explore" verb targets the folder itself, so a click opens the
    // directory in File Explorer instead of running its default handler.
    ShellExecuteW(null, toUTF16z("explore"), toUTF16z(path), null, null, 1);
}

/// Directory that holds every persisted chat (sessions, pins, runtime
/// journal). Shared by the "Chats" button in the Settings dialog.
private string chatsDirectory()
{
    return opencodeStateDirectory();
}

/// Reveal the folder that stores the user's chats in the file manager.
private void openChatsFolder()
{
    const dir = chatsDirectory();
    if (!exists(dir)) mkdirRecurse(dir);
    version (Windows)
        openFolderInExplorer(dir);
}

/// Baseline offset of the first shaped line inside a layout box. The stats
/// (monospace) line box is taller than the UI label's, so centring each by its
/// own box height left the counters slightly above the visual middle; aligning
/// on baselines keeps them on the label's line.
private static double firstBaseline(TextLayout layout)
{
    return layout is null || layout.lines.length == 0
        ? 0.0 : layout.lines[0].baseline;
}

private string currentTimestamp()
{
    auto now = Clock.currTime;
    string pad(int value)
    {
        return value < 10 ? "0" ~ to!string(value) : to!string(value);
    }
    return pad(now.hour) ~ ":" ~ pad(now.minute);
}

private string formatThousands(int value)
{
    auto text = to!string(value);
    string result;
    int count;
    foreach_reverse (ch; text)
    {
        if (count == 3)
        {
            result = "," ~ result;
            count = 0;
        }
        result = ch ~ result;
        ++count;
    }
    return result;
}

private string formatTokenRate(int tenths)
{
    if (tenths <= 0) return "";
    return to!string(tenths / 10) ~ "." ~ to!string(tenths % 10) ~ " t/s";
}

/// Compact wall-clock duration for a tool run: `340ms`, `1.5s`, `2m03s`.
/// Negative or zero durations return "" so an unknown/instant time shows
/// nothing rather than a misleading `0ms`.
private string formatElapsedMs(long ms)
{
    if (ms <= 0) return "";
    if (ms < 1000) return to!string(ms) ~ "ms";
    // Round to 0.1s so a fast command does not read `0.0s`.
    const tenths = (ms + 50) / 100;
    const seconds = tenths / 10;
    if (seconds < 60)
        return to!string(seconds) ~ "." ~ to!string(tenths % 10) ~ "s";
    const minutes = seconds / 60;
    const rest = seconds % 60;
    return to!string(minutes) ~ "m" ~ (rest < 10 ? "0" : "") ~ to!string(rest) ~ "s";
}

// ---------------------------------------------------------------------------
// Chat message bubble
// ---------------------------------------------------------------------------

private final class MessageBubble : Widget
{
    private static immutable int padH = 10;
    private static immutable int padV = 6;
    private static immutable int gap = 4;
    // Breathing room between a collapsed "Thinking" header and the answer text
    // that follows it. The header and its reply share one bubble, so without this
    // the answer hugged the header: at 8 px it sat ~26 px below the header but
    // ~39 px above the next collapsed row. 20 px makes the two distances equal so
    // the answer looks vertically centred between the header and the next row.
    private static immutable int thinkingContentGap = 20;

    private string _role;
    private dstring _thinking;
    private dstring _content;
    private bool _streaming;
    private bool _failed;
    private string _error;
    private string _time;
    private string _usageText;
    // Live output-token count mirrored onto the Thinking header. It grows as
    // tokens stream (a local estimate refined by the provider's exact usage) and
    // stays after the turn ends, so the active row shows a number that only
    // increases instead of a phase word that vanishes and reads like a file
    // write.
    private long _liveTokens;
    private int _tokenRateTenths;
    private bool _tokensLive;
    private int _messageIndex;
    private bool _hidden;

    // Chat-quality actions (Pro): regenerate/retry the last reply, edit &
    // resend a user message.
    private string _actionLabel;
    private void delegate() _actionCallback;
    private Rect _actionRect;
    private bool _actionHover;
    private string _secondaryActionLabel;
    private void delegate() _secondaryActionCallback;
    private Rect _secondaryActionRect;
    private bool _secondaryActionHover;
    // Branch navigation (Pro): when an edited prompt or a regenerated reply has
    // sibling versions, the footer shows `‹ n/m ›` so the user can flip between
    // the kept runs. The callbacks switch the session's active leaf.
    private int _versionPosition;
    private int _versionTotal;
    private void delegate() _versionPrev;
    private void delegate() _versionNext;
    private Rect _versionPrevRect;
    private Rect _versionNextRect;
    private int _versionHover;
    private int _versionWidth;
    // Right-click requests a context menu (Regenerate / Edit & resend / Copy).
    void delegate(int messageIndex, Point globalPosition, string linkTarget)
        onContextMenuRequested;

    // Interactive affordances (Pro): message/code copy buttons and links.
    private int _hoverCopy = -1;
    private int _hoverLink = -1;
    private Rect[] _copyRects;
    private string[] _copyLabels;
    private Rect[] _linkRects;
    private string[] _linkUrls;

    // Text selection (Pro): drag across a message to select it, then copy from
    // the right-click menu. The paint pass records one segment per selectable
    // run (like the copy/link targets above); the mouse handlers map points to
    // a (segment, character) caret using the retained TextLayout geometry.
    private struct SelectSegment
    {
        TextLayout layout;
        int x;
        int y;
        int w;
        int h;
    }
    private SelectSegment[] _selSegments;
    private bool _selecting;
    private int _selAnchorSeg = -1;
    private size_t _selAnchorChar;
    private int _selFocusSeg = -1;
    private size_t _selFocusChar;
    private bool _textHover;
    // Payload of the last Ctrl+C on this bubble, exposed for the smoke test
    // (the clipboard itself is global state).
    private string _lastClipboardText;

    // Shaped text is expensive and wrapped layouts are never cached by the
    // text engine, so each bubble caches its own layout and reuses it across
    // measures and repaints. The ScrollView measures its content twice per
    // layout (once with and once without the scrollbar width), so a single
    // slot would thrash and re-shape every frame while dragging; a small
    // width-keyed set covers both measure widths.
    private static immutable int shapeCacheSize = 5;
    private int[shapeCacheSize] _contentWidths;
    private TextLayout[shapeCacheSize] _contentLayouts;
    private size_t[shapeCacheSize] _contentShapedGen;
    private size_t _contentCacheCount;
    private size_t _contentGen = 1;
    // The thinking block is wrapped, so its layout depends on width. The
    // ScrollView measures its content twice per layout (once without and once
    // with the scrollbar), which oscillates the width; a single-slot cache
    // thrashed and re-shaped the whole reasoning text on every toggle. Use the
    // same small width-keyed ring as the message content.
    private int[shapeCacheSize] _thinkingWidths;
    private TextLayout[shapeCacheSize] _thinkingLayouts;
    private size_t[shapeCacheSize] _thinkingShapedGens;
    private size_t _thinkingCacheCount;
    private size_t _thinkingGen = 1;

    private int[2] _mdWidths;
    private MdComposition[2] _mdCompositions;
    private size_t[2] _mdGens;
    private size_t _mdCount;

    // Incremental composition for streaming. Markdown grows by appending, and a
    // blank line ends a block, so everything up to the last blank line outside
    // a fence is stable: `MarkdownComposer` parses and composes it once and
    // only recomposes the current (growing) block per frame. Without this every
    // delta re-parsed and re-composed the whole message, making a long stream
    // quadratic (measured ~19 ms/frame at 120k, with 60 ms+ spikes). The
    // ScrollView measures at two widths, so keep one composer per width.
    private MarkdownComposer[2] _mdComposers;

    // Tool result bubbles (`tool` role) are a single element: the header shows
    // the command (⚙ name(args)) and the output below is collapsible. Clicking
    // the header toggles the output.
    private string _toolName;
    private string _toolArgs;

    // Collapse state: tool outputs start hidden behind a compact header.
    private bool _collapsed = true;
    private Rect _collapseRect;
    private bool _collapseHover;

    // File-mutating tool results (edit/write/remove) carry a computed diff: the
    // `+N -M` counters and the unified diff rendered as a line-numbered body
    // with green additions and red deletions. Non-diff tool output is rendered
    // as line-numbered plain monospace text instead.
    private int _diffAdditions;
    private int _diffDeletions;
    private string _diffText;
    private bool _hasDiff;
    // Wall-clock tool duration, shown on the tool header next to the diff
    // counters. 0 hides the label (older messages / non-tool bubbles).
    private long _toolElapsedMs;

    /// One rendered line of an expanded tool body. `kind` selects the row tint
    /// and text colour; line numbers are 0 when the column does not apply.
    private enum ToolLineKind : ubyte { context, add, del, hunk, plain }
    private struct ToolLine
    {
        ToolLineKind kind;
        int oldNo;
        int newNo;
        // The fully composed row text (line numbers + sign + body). Shaped
        // lazily and cached in `layout`; only rows that are actually visible
        // are ever shaped, so expanding a huge output stays instant.
        string visible;
        TextLayout layout;
    }
    private ToolLine[] _toolLines;
    private size_t _toolLinesGen;
    private size_t _toolLinesBuiltGen = size_t.max;
    private int _toolLinesWidth = -1;
    private int _toolLinesHeight;
    private double _toolLineHeight;
    private static immutable int maxRenderedToolLines = 600;

    // Thinking/reasoning block: collapsed into a slim header by default (like
    // the original opencode app), with a pulsing "Thinking…" indicator while
    // the assistant is still working. Click toggles the full reasoning text.
    private bool _thinkingCollapsed = true;
    private Rect _thinkingRect;
    private bool _thinkingHover;
    private double _thinkingElapsed;
    private bool _thinkingLive;

    /// Diagnostic: total number of text shapes performed by all bubbles.
    static __gshared size_t shapeCount;

    void setRole(string role)
    {
        _role = role;
        invalidate();
    }

    void setMessageIndex(int index)
    {
        _messageIndex = index;
    }

    /// The message index this bubble renders (used by the context menu so it
    /// never relies on a captured `foreach` slot).
    int messageIndex() const
    {
        return _messageIndex;
    }

    /// Hide the bubble entirely: it measures to zero height and paints nothing
    /// but keeps its slot so child-index ↔ message-index mapping stays intact.
    /// Used for tool-call wrappers that carried no content or reasoning.
    void setHidden(bool value)
    {
        if (_hidden == value) return;
        _hidden = value;
        // Exclude the bubble from layout entirely. It keeps its slot in the
        // column (so child index <-> message index mapping is intact), but a
        // merely zero-height child still made the VBox add its spacing around
        // it, opening a phantom gap between the surrounding messages.
        setVisible(!value);
        invalidate();
    }

    /// Test-only: whether this bubble is hidden.
    public bool hiddenForTesting()
    {
        return _hidden;
    }

    /// Test-only: the bubble role.
    public string roleForTesting()
    {
        return _role;
    }

    /// Test-only: how many codepoints of answer content this bubble holds.
    public int contentLengthForTesting() const
    {
        return cast(int) _content.length;
    }

    /// Test-only: the bubble's tool name ("" for a prose bubble).
    public string toolNameForTesting() const
    {
        return _toolName;
    }

    /// Test-only: a short prefix of the bubble's answer content.
    public string contentSnippetForTesting() const
    {
        const full = to!string(_content);
        return full.length <= 40 ? full : full[0 .. 40] ~ "…";
    }

    void setToolName(string name)
    {
        _toolName = name;
        invalidate();
    }

    void setToolArgs(string args)
    {
        _toolArgs = args;
        invalidate();
    }

    void setDiff(int additions, int deletions, string diff)
    {
        _diffAdditions = additions;
        _diffDeletions = deletions;
        _diffText = diff;
        _hasDiff = diff.length > 0 || additions > 0 || deletions > 0;
        ++_toolLinesGen;
        _toolLinesWidth = -1;
        invalidate();
    }

    /// Record how long the tool run took so the header can show it next to the
    /// diff counters. Milliseconds; 0 hides the label.
    void setToolElapsed(long elapsedMs)
    {
        if (_toolElapsedMs == elapsedMs) return;
        _toolElapsedMs = elapsedMs;
        invalidate();
    }

    void setCollapsed(bool value)
    {
        if (_collapsed == value) return;
        _collapsed = value;
        if (onSizeChanged !is null) onSizeChanged();
        invalidate();
    }

    /// Current collapsed state (used to persist the user's expand choice).
    bool collapsed() const
    {
        return _collapsed;
    }

    /// Fired when the bubble's measured size changes (collapse/expand), so the
    /// message column can re-layout and the scroll view can re-measure.
    void delegate() onSizeChanged;



    /// Test-only: current collapsed state.
    public bool collapsedForTesting()
    {
        return _collapsed;
    }

    /// Test-only: toggle the collapsed state like a click would.
    public void toggleCollapseForTesting()
    {
        setCollapsed(!_collapsed);
    }

    /// Test-only: the green/red diff counters and whether a diff body exists.
    public int diffAdditionsForTesting() { return _diffAdditions; }
    public int diffDeletionsForTesting() { return _diffDeletions; }
    public bool hasDiffForTesting() { return _hasDiff; }
    /// Test-only: the tool's wall-clock duration in milliseconds (0 when none).
    public long toolElapsedMsForTesting() const { return _toolElapsedMs; }

    /// Test-only: the tool header's compact argument text, without the
    /// `⚙ name`/toggle prefix. Used to prove arrays render as a command line
    /// rather than the opaque `args=[…]`.
    public string toolArgsDisplayForTesting()
    {
        return toolArgsDisplay();
    }

    void setThinkingCollapsed(bool value)
    {
        if (_thinkingCollapsed == value) return;
        _thinkingCollapsed = value;
        if (onSizeChanged !is null) onSizeChanged();
        invalidate();
    }

    /// Current thinking-block collapsed state (used to persist the choice).
    bool thinkingCollapsed() const
    {
        return _thinkingCollapsed;
    }

    /// Mark whether the assistant is still working, so the thinking header can
    /// animate a pulsing "Thinking…" indicator. Called from the root's tick.
    void setThinkingLive(bool value)
    {
        if (_thinkingLive == value) return;
        _thinkingLive = value;
        invalidate();
    }

    /// Advance the thinking animation clock. Called every frame while the
    /// assistant is streaming; only repaints when the indicator phase changes.
    void tickThinking(double deltaSeconds)
    {
        if (!_thinkingLive && !_tokensLive) return;
        const phase = cast(int) (_thinkingElapsed * 2);
        _thinkingElapsed += deltaSeconds;
        const next = cast(int) (_thinkingElapsed * 2);
        if (next != phase) invalidate();
    }

    /// Test-only: current thinking collapsed state.
    public bool thinkingCollapsedForTesting()
    {
        return _thinkingCollapsed;
    }

    /// Test-only: whether a reasoning header is present on this bubble.
    public bool hasThinkingForTesting() const
    {
        return _thinking.length > 0;
    }

    /// Test-only: the reasoning text held in this bubble's Thinking block, so a
    /// test can prove every tool round's reasoning is preserved when it is
    /// merged into one block per exchange.
    public string thinkingTextForTesting() const
    {
        return to!string(_thinking);
    }

    /// Test-only: toggle the thinking block like a click would.
    public void toggleThinkingForTesting()
    {
        setThinkingCollapsed(!_thinkingCollapsed);
    }

    void setThinking(string value)
    {
        _thinking = toUTF32(value);
        ++_thinkingGen;
        invalidate();
    }

    void setContent(string value)
    {
        _content = toUTF32(value);
        ++_contentGen;
        _contentCacheCount = 0;
        resetMarkdownCommit();
        invalidate();
    }

    void appendThinking(string chunk)
    {
        _thinking ~= toUTF32(chunk);
        ++_thinkingGen;
        invalidate();
    }

    void appendContent(string chunk)
    {
        _content ~= toUTF32(chunk);
        ++_contentGen;
        _contentCacheCount = 0;
        invalidate();
    }

    void setFailed(string error)
    {
        _failed = true;
        _error = error;
        invalidate();
    }

    void setTime(string value)
    {
        if (_time == value) return;
        _time = value;
        invalidate();
    }

    void setUsageText(string value)
    {
        if (_usageText == value) return;
        _usageText = value;
        invalidate();
    }

    /// Test-only: the current usage footer text.
    public string usageTextForTesting()
    {
        return _usageText;
    }

    /// Set the live/final output-token count shown on the Thinking header.
    /// `live` keeps the pulsing indicator running while the reply streams; the
    /// last value is kept after completion.
    void setLiveTokens(long tokens, bool live)
    {
        if (_liveTokens == tokens && _tokensLive == live) return;
        _liveTokens = tokens;
        _tokensLive = live;
        invalidate();
    }

    void setTokenRate(int tenths)
    {
        if (_tokenRateTenths == tenths) return;
        _tokenRateTenths = tenths;
        invalidate();
    }

    /// Test-only: the live/final token count held by this bubble.
    public long liveTokensForTesting() const
    {
        return _liveTokens;
    }

    void setAction(string label, void delegate() callback)
    {
        _actionLabel = label;
        _actionCallback = callback;
        invalidate();
    }

    void setSecondaryAction(string label, void delegate() callback)
    {
        _secondaryActionLabel = label;
        _secondaryActionCallback = callback;
        invalidate();
    }

    void clearAction()
    {
        if (_actionLabel.length == 0 && _actionCallback is null &&
            _secondaryActionLabel.length == 0 &&
            _secondaryActionCallback is null) return;
        _actionLabel = "";
        _actionCallback = null;
        _actionHover = false;
        _secondaryActionLabel = "";
        _secondaryActionCallback = null;
        _secondaryActionHover = false;
        invalidate();
    }

    /// Wire the branch navigation shown in the footer: `‹ position/total ›`.
    /// The callbacks switch the session's active leaf to the previous/next
    /// sibling version of this message.
    void setVersionInfo(int position, int total, void delegate() previous,
        void delegate() next)
    {
        _versionPosition = position;
        _versionTotal = total;
        _versionPrev = previous;
        _versionNext = next;
        invalidate();
    }

    /// Test-only: the `n/m` version label ("" when the message has no siblings).
    public string versionTextForTesting()
    {
        return _versionTotal > 1
            ? to!string(_versionPosition) ~ "/" ~ to!string(_versionTotal) : "";
    }

    /// Test-only: bounds of the `‹ n/m ›` nav (empty when there are no
    /// siblings). Used to assert it never overlaps the action pill.
    public Rect versionNavBoundsForTesting() const
    {
        if (_versionTotal <= 1 || _versionNextRect.width == 0)
            return Rect.init;
        const left = _versionPrevRect.x;
        const right = _versionNextRect.right();
        return Rect(left, _versionPrevRect.y, right - left,
            _versionPrevRect.height);
    }

    /// Test-only: bounds of the action pill (Regenerate / Retry).
    public Rect actionBoundsForTesting() const
    {
        return _actionRect;
    }

    public Rect secondaryActionBoundsForTesting() const
    {
        return _secondaryActionRect;
    }

    /// Test-only: invoke the previous-version arrow, if present.
    public bool invokeVersionPrevForTesting()
    {
        if (_versionTotal <= 1 || _versionPrev is null) return false;
        _versionPrev();
        return true;
    }

    /// Test-only: invoke the next-version arrow, if present.
    public bool invokeVersionNextForTesting()
    {
        if (_versionTotal <= 1 || _versionNext is null) return false;
        _versionNext();
        return true;
    }

    /// Test-only: the label of the current action pill.
    public string actionLabelForTesting()
    {
        return _actionLabel;
    }

    public string secondaryActionLabelForTesting()
    {
        return _secondaryActionLabel;
    }

    /// Test-only: invoke the current action pill's callback, if any.
    public bool invokeActionForTesting()
    {
        if (_actionLabel.length == 0 || _actionCallback is null) return false;
        _actionCallback();
        return true;
    }

    public bool invokeSecondaryActionForTesting()
    {
        if (_secondaryActionLabel.length == 0 ||
            _secondaryActionCallback is null) return false;
        _secondaryActionCallback();
        return true;
    }

    void setStreaming(bool value)
    {
        if (_streaming == value) return;
        _streaming = value;
        ++_contentGen;
        _contentCacheCount = 0;
        invalidate();
    }

    private TextLayout shapedThinking(int width)
    {
        foreach (index; 0 .. _thinkingCacheCount)
        {
            if (_thinkingShapedGens[index] == _thinkingGen &&
                _thinkingWidths[index] == width)
                return _thinkingLayouts[index];
        }

        auto layout = shape(_thinking, width);

        if (_thinkingCacheCount == shapeCacheSize)
        {
            for (size_t shift = 1; shift < shapeCacheSize; ++shift)
            {
                _thinkingWidths[shift - 1] = _thinkingWidths[shift];
                _thinkingLayouts[shift - 1] = _thinkingLayouts[shift];
                _thinkingShapedGens[shift - 1] = _thinkingShapedGens[shift];
            }
            --_thinkingCacheCount;
        }
        _thinkingWidths[_thinkingCacheCount] = width;
        _thinkingLayouts[_thinkingCacheCount] = layout;
        _thinkingShapedGens[_thinkingCacheCount] = _thinkingGen;
        ++_thinkingCacheCount;
        return layout;
    }

    private TextLayout shapedContent(int width)
    {
        foreach (index; 0 .. _contentCacheCount)
        {
            if (_contentShapedGen[index] == _contentGen &&
                _contentWidths[index] == width)
                return _contentLayouts[index];
        }

        dstring display = _content;
        auto layout = shape(display, width);

        if (_contentCacheCount == shapeCacheSize)
        {
            for (size_t shift = 1; shift < shapeCacheSize; ++shift)
            {
                _contentWidths[shift - 1] = _contentWidths[shift];
                _contentLayouts[shift - 1] = _contentLayouts[shift];
                _contentShapedGen[shift - 1] = _contentShapedGen[shift];
            }
            --_contentCacheCount;
        }
        _contentWidths[_contentCacheCount] = width;
        _contentLayouts[_contentCacheCount] = layout;
        _contentShapedGen[_contentCacheCount] = _contentGen;
        ++_contentCacheCount;
        return layout;
    }

    private void resetMarkdownCommit()
    {
        foreach (ref composer; _mdComposers)
            composer.reset();
    }

    private MarkdownComposer* composerFor(int width)
    {
        foreach (ref composer; _mdComposers)
            if (composer.width == width) return &composer;
        foreach (ref composer; _mdComposers)
            if (composer.width < 0)
            {
                composer.reset();
                composer.width = width;
                return &composer;
            }
        _mdComposers[0].reset();
        _mdComposers[0].width = width;
        return &_mdComposers[0];
    }

    private MdComposition markdownFor(int width)
    {
        foreach (index; 0 .. _mdCount)
        {
            if (_mdGens[index] == _contentGen && _mdWidths[index] == width)
                return _mdCompositions[index];
        }

        MdComposition composition;

        if (_mdCount == 2)
        {
            composition = _mdCompositions[0];
            _mdWidths[0] = _mdWidths[1];
            _mdCompositions[0] = _mdCompositions[1];
            _mdGens[0] = _mdGens[1];
            --_mdCount;
        }

        const lineWidth = maxInt(24, width);
        composerFor(lineWidth).compose(composition, _content, lineWidth,
            _streaming);

        _mdWidths[_mdCount] = width;
        _mdCompositions[_mdCount] = composition;
        _mdGens[_mdCount] = _contentGen;
        ++_mdCount;
        return composition;
    }

    private TextLayout shape(const(dchar)[] text, int width)
    {
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast(FontFace) theme().uiFont;
        options.pixelSize = opencodeFontBase;
        options.maxWidth = maxInt(1, width);
        options.wrap = true;
        ++shapeCount;
        // Shaping a bubble is the deepest and most fragile work the UI does,
        // and it runs inside a paint. An `Error` escaping here aborts the whole
        // process - a malformed message could take the app down while the user
        // was simply reading it. A bubble that cannot be shaped returns no
        // layout: the text is not drawn, the app stays up, and the reason is
        // recorded.
        try
            return fontSystem().textEngine.layout(text, options);
        catch (Throwable error)
        {
            logError("message shaping failed: " ~ error.toString());
            return null;
        }
    }

    /// Width of the right-aligned user bubble: capped at ~68% of the column so
    /// the turn sits against the right edge like a chat reply, never full-bleed.
    private static int userBubbleWidth(int totalWidth)
    {
        return minInt(maxInt(0, totalWidth),
            maxInt(160, cast(int) (totalWidth * 0.68)));
    }

    protected override Size onMeasure(Size available)
    {
        if (_hidden)
        {
            layoutHints().preferredWidth = 0;
            layoutHints().preferredHeight = 0;
            return Size(0, 0);
        }
        const innerWidth = maxInt(24, available.width - 2 * padH);
        int height = 2 * padV;
        if (_thinking.length > 0)
        {
            // Thinking header (slim) always; full reasoning only when expanded.
            // Use the tool header's height so a collapsed "Thinking" row and a
            // collapsed "Shell"/"Read" row are exactly the same height; a
            // header sized from a different text tier opened uneven gaps in a
            // mixed stack.
            height += toolHeaderHeight();
            if (!_thinkingCollapsed)
                height += shapedThinking(innerWidth).measuredSize().height + gap;
        }

        if (_role == "tool")
        {
            // Header (title + subtitle + diff counters) always; the rendered
            // body (unified diff or numbered output) only when expanded.
            height += toolHeaderHeight();
            if (!_collapsed)
                height += ensureToolLines(innerWidth) + gap;
        }
        else if (_role == "assistant")
        {
            if (_thinking.length > 0 && _content.length > 0)
                height += thinkingContentGap;
            if (_content.length > 0)
                height += cast(int) markdownFor(innerWidth).height;
        }
        else
        {
            // A user turn wraps inside its right-aligned panel, so measure with
            // that narrower width (onPaint must use the same width).
            const wrapWidth = _role == "user" ?
                maxInt(24, userBubbleWidth(available.width) - 2 * padH) :
                innerWidth;
            if (_content.length > 0)
                height += shapedContent(wrapWidth).measuredSize().height;
        }
        if (_failed)
            height += fontPixelSize(1) + 4;
        height += footerReserve();
        const measuredWidth = maxInt(innerWidth + 2 * padH, 64);
        const result = Size(minInt(measuredWidth, available.width), height);
        // VBox layout sizes children from layoutHints, not from the intrinsic
        // measure result, so publish the computed size back into the hints or
        // the bubble is laid out with zero height and never becomes visible.
        layoutHints().preferredWidth = result.width;
        layoutHints().preferredHeight = result.height;
        return result;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_hidden) return;
        // Paint runs no markers of its own, so a fault during composeRuns or
        // drawLayout had only the preceding rebuild's marker to point at. Naming
        // the bubble here (role, index, content size) makes the crashing widget
        // the last thing recorded. `noteActivity` collapses consecutive repeats,
        // so a steady repaint does not flood the log.
        noteActivity("MessageBubble.onPaint role=" ~ _role ~ " index=" ~
            to!string(_messageIndex) ~ " contentLen=" ~
            to!string(_content.length));
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;

        // Message flow mirrors the original opencode TUI (session/index.tsx):
        // the user's turn is a subtle panel with a colored left accent bar,
        // while the assistant's reply is not boxed at all and flows in the
        // reading column. Wrapping every turn in a full-width rounded card made
        // the transcript read like a list of cards instead of a conversation.
        const int accentW = 3;
        int userX;
        int userInnerWidth = maxInt(1, width - 2 * padH);
        if (_role == "user")
        {
            // Right-align the user's turn: a rounded panel hugging the right
            // edge with the accent bar on its right, like a chat reply.
            const panelW = userBubbleWidth(width);
            userX = maxInt(0, width - panelW);
            userInnerWidth = maxInt(24, panelW - 2 * padH);
            canvas.fillRoundedRect(Rect(userX, 0, panelW, height), 8,
                opencodePanel);
            canvas.fillRect(Rect(userX + panelW - accentW, 0, accentW, height),
                opencodeAccent);
        }
        else if (_failed)
        {
            canvas.fillRect(Rect(0, 0, accentW, height), opencodeErrorRed);
        }

        const innerWidth = maxInt(1, width - 2 * padH);
        int y = padV;

        if (_thinking.length > 0)
        {
            drawThinkingHeader(canvas, innerWidth, y);
            y += toolHeaderHeight();
            if (!_thinkingCollapsed)
            {
                auto layout = shapedThinking(innerWidth);
                noteActivity("paintThinking index=" ~ to!string(_messageIndex) ~
                    " width=" ~ to!string(innerWidth));
                canvas.drawLayout(Point(padH, y), layout, opencodeThinkingText);
                y += layout.measuredSize().height + gap;
            }
        }

        // Highlight the active selection using the previous paint's segment
        // geometry (drawn before the glyphs so the text stays readable).
        drawSelection(canvas);

        _copyRects.length = 0;
        _copyLabels.length = 0;
        _linkRects.length = 0;
        _linkUrls.length = 0;
        _selSegments.length = 0;

        if (_thinking.length > 0 && _content.length > 0)
            y += thinkingContentGap;

        const contentY = y;

        if (_role == "tool")
        {
            // Always show the tool header (▸/▾ title subtitle  +N -M); the
            // rendered body below it is shown only when expanded.
            drawToolHeader(canvas, innerWidth, y);
            y += toolHeaderHeight();
            if (!_collapsed)
                y += drawToolBody(canvas, innerWidth, y) + gap;
        }
        else if (_content.length > 0 || _streaming)
        {
            if (_role == "assistant")
            {
                auto composition = markdownFor(innerWidth);
                if (composition.items.length > 0)
                {
                    noteActivity("paintMarkdown index=" ~ to!string(_messageIndex) ~
                        " items=" ~ to!string(composition.items.length) ~
                        " width=" ~ to!string(innerWidth));
                    paintMarkdown(canvas, composition, padH, contentY);
                    collectMarkdownTargets(composition, contentY);
                }
            }
            else
            {
                const textX = _role == "user" ? userX + padH : padH;
                const textWidth = _role == "user" ? userInnerWidth : innerWidth;
                auto layout = shapedContent(textWidth);
                canvas.drawLayout(Point(textX, contentY), layout, opencodeText);
                if (layout.lines.length > 0)
                    _selSegments ~= SelectSegment(layout, textX, contentY,
                        maxInt(1, textWidth),
                        layout.measuredSize().height);
            }
        }

        if (_failed && _error.length > 0)
        {
            auto layout = canvas.layoutText(toUTF32(_error), 1, FontRole.ui,
                cast(FontFace) palette.uiFont, innerWidth, true);
            canvas.drawLayout(Point(padH, y + 4), layout, opencodeErrorRed);
        }

        // Only code-block copy pills remain; the per-message Copy pill was
        // removed (Copy lives in the right-click context menu).
        foreach (index; 0 .. _copyRects.length)
        {
            if (_copyLabels[index].length == 0) continue;
            drawCopyPill(canvas, _copyRects[index],
                _hoverCopy == cast(int) index);
        }
        drawVersionNav(canvas, width, height);
        drawActionPill(canvas, width, height);
        drawFooter(canvas, width, height);
    }
    private void drawActionPill(ref Canvas canvas, int width, int height)
    {
        _actionRect = Rect.init;
        _secondaryActionRect = Rect.init;
        if (_actionLabel.length == 0 || _actionCallback is null) return;
        auto labelLayout = canvas.layoutText(toUTF32(_actionLabel), 1,
            FontRole.ui, cast(FontFace) theme().uiFont, 200, false);
        const aw = maxInt(52, cast(int) labelLayout.width + 18);
        const x0 = padH + (_versionTotal > 1 ? _versionWidth + 6 : 0);
        _actionRect = Rect(x0, height - padV - 19, aw, 18);
        canvas.fillRoundedRect(_actionRect, 9,
            _actionHover ? opencodeAccent.withAlpha(150) : opencodeBorder);
        canvas.drawTextInRect(_actionRect, toUTF32(_actionLabel),
            _actionHover ? Color.rgb(255, 255, 255) : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
        if (_secondaryActionLabel.length == 0 ||
            _secondaryActionCallback is null) return;
        auto secondaryLayout = canvas.layoutText(
            toUTF32(_secondaryActionLabel), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, 200, false);
        const secondaryWidth = maxInt(52,
            cast(int) secondaryLayout.width + 18);
        _secondaryActionRect = Rect(_actionRect.right() + 6,
            height - padV - 19, secondaryWidth, 18);
        canvas.fillRoundedRect(_secondaryActionRect, 9,
            _secondaryActionHover ? opencodeAccent.withAlpha(150) :
                opencodeBorder);
        canvas.drawTextInRect(_secondaryActionRect,
            toUTF32(_secondaryActionLabel),
            _secondaryActionHover ? Color.rgb(255, 255, 255) : opencodeMuted,
            1, HorizontalAlign.center, VerticalAlign.middle, true);
    }

    /// Footer branch navigation: `‹ n/m ›`. `m > 1` means this prompt or reply
    /// has sibling runs (an earlier edit or generation) the user can flip back
    /// to; the arrows switch the session's visible branch.
    private void drawVersionNav(ref Canvas canvas, int width, int height)
    {
        _versionPrevRect = Rect.init;
        _versionNextRect = Rect.init;
        _versionWidth = 0;
        if (_versionTotal <= 1) return;
        const y = height - padV - 19;
        const label = to!string(_versionPosition) ~ "/" ~ to!string(_versionTotal);
        auto labelLayout = canvas.layoutText(toUTF32(label), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, 200, false);
        const chevronW = 16;
        int x = padH;
        _versionPrevRect = Rect(x, y, chevronW, 18);
        canvas.drawTextInRect(_versionPrevRect, toUTF32("‹"),
            _versionHover == 1 ? opencodeText : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
        x += chevronW;
        const textW = maxInt(22, cast(int) labelLayout.width + 8);
        canvas.drawTextInRect(Rect(x, y, textW, 18), toUTF32(label),
            opencodeMuted, 1, HorizontalAlign.center, VerticalAlign.middle,
            true);
        x += textW;
        _versionNextRect = Rect(x, y, chevronW, 18);
        canvas.drawTextInRect(_versionNextRect, toUTF32("›"),
            _versionHover == 2 ? opencodeText : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
        _versionWidth = x + chevronW - padH;
    }

    /// Header for a tool result: a ▸/▾ toggle, the tool's human title (Shell,
    /// Read, Edit, …), its subtitle (command / filename / pattern) and — for
    /// file-mutating tools — the green/red `+N -M` diff counters. Clicking the
    /// row shows or hides the rendered body below.
    private void drawToolHeader(ref Canvas canvas, int innerWidth, int top)
    {
        const h = toolHeaderHeight();
        _collapseRect = Rect(padH, top, maxInt(1, innerWidth), h);
        const toggle = _collapsed ? "▸" : "▾";
        string left = toggle ~ " " ~ humanToolTitle(_toolName);
        const subtitle = humanToolSubtitle(_toolName, _toolArgs);
        if (subtitle.length > 0) left ~= "  " ~ subtitle;

        int statsWidth;
        TextLayout addLayout, delLayout, elapsedLayout;
        if (_hasDiff && (_diffAdditions > 0 || _diffDeletions > 0))
        {
            addLayout = canvas.layoutText(toUTF32("+" ~ to!string(_diffAdditions)),
                1, FontRole.monospace, null, 200, false);
            delLayout = canvas.layoutText(toUTF32("-" ~ to!string(_diffDeletions)),
                1, FontRole.monospace, null, 200, false);
            statsWidth = cast(int) addLayout.width + 8 + cast(int) delLayout.width;
        }
        const elapsedText = _toolElapsedMs > 0
            ? formatElapsedMs(_toolElapsedMs) : "";
        if (elapsedText.length > 0)
        {
            elapsedLayout = canvas.layoutText(toUTF32(elapsedText), 1,
                FontRole.monospace, null, 200, false);
            if (statsWidth > 0) statsWidth += 8;
            statsWidth += cast(int) elapsedLayout.width;
        }

        const available = maxInt(1, innerWidth - statsWidth -
            (statsWidth > 0 ? 8 : 0));
        auto layout = canvas.layoutText(toUTF32(left), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, available, false);
        auto labelCanvas = canvas.clipped(Rect(padH, top, available, h));
        labelCanvas.drawLayout(Point(padH, top), layout,
            _collapseHover ? opencodeText : opencodeMuted);

        if (statsWidth > 0)
        {
            // Place the stats directly after the tool text so they sit next to
            // the message instead of the far right edge: the green/red `+N -M`
            // counters and the wall-clock duration. `TextLayout` is a class, so
            // an unassigned one is null - test for presence, never `.width > 0`.
            int x = padH + cast(int) layout.width + 8;
            // Align the counters/timer on the header label's baseline: the
            // monospace line box is taller than the UI label's, so centring
            // each by its own box height left the stats slightly high.
            const sy = cast(int)(top + layout.lines[0].baseline -
                firstBaseline(addLayout !is null ? addLayout : elapsedLayout));
            if (addLayout !is null)
            {
                canvas.drawLayout(Point(x, sy), addLayout, opencodeDiffAdd);
                canvas.drawLayout(Point(x + cast(int) addLayout.width + 8, sy),
                    delLayout, opencodeDiffDelete);
                x += cast(int) addLayout.width + 8 + cast(int) delLayout.width;
            }
            if (elapsedLayout !is null)
            {
                if (addLayout !is null) x += 8;
                canvas.drawLayout(Point(x, sy), elapsedLayout, opencodeMuted);
            }
        }
    }

    private static int toolHeaderHeight()
    {
        return opencodeFontBase + 2;
    }

    private static string padLeft(int value, int width)
    {
        auto text = to!string(value < 0 ? 0 : value);
        if (text.length >= width) return text;
        return "                    "[0 .. width - text.length] ~ text;
    }

    private static int hunkStart(string raw, char sign)
    {
        foreach (index, ch; raw)
        {
            if (ch != sign) continue;
            int value;
            size_t cursor = index + 1;
            while (cursor < raw.length && raw[cursor] >= '0' && raw[cursor] <= '9')
            {
                value = value * 10 + (raw[cursor] - '0');
                ++cursor;
            }
            return value;
        }
        return 0;
    }

    private TextLayout shapeMonoLine(dstring text)
    {
        TextLayoutOptions options;
        options.role = FontRole.monospace;
        options.pixelSize = opencodeFontBase;
        options.maxWidth = 100_000;
        options.wrap = false;
        ++shapeCount;
        return fontSystem().textEngine.layout(text, options);
    }

    /// Build (and cache) the shaped rows for the expanded tool body. Diffs are
    /// parsed into context/add/delete rows with old/new line numbers; plain tool
    /// output becomes numbered plain rows. Rows are capped so a giant output can
    /// never stall a frame.
    private int ensureToolLines(int innerWidth)
    {
        // Tool rows are monospace and never wrap (see shapeMonoLine), so a
        // row's shaped layout does not depend on the bubble width. Keying the
        // cache on width made the ScrollView's two measurement passes (with
        // and without the scrollbar) invalidate every shaped row on each
        // toggle, re-shaping the visible rows again every time. Rebuild only
        // when the content generation changes.
        if (_toolLinesBuiltGen == _toolLinesGen)
            return _toolLinesHeight;

        import std.string : splitLines;

        _toolLinesWidth = innerWidth;
        _toolLinesBuiltGen = _toolLinesGen;
        _toolLines.length = 0;

        string[] source;
        if (_hasDiff)
            source = splitLines(_diffText);
        else if (_content.length > 0)
            source = splitLines(to!string(_content));

        int oldNo, newNo, plainNo;
        size_t emitted;
        foreach (raw; source)
        {
            if (emitted >= maxRenderedToolLines) break;
            ToolLine line;
            string text = raw;
            if (_hasDiff)
            {
                if (raw.length > 0 && raw[0] == '@')
                {
                    line.kind = ToolLineKind.hunk;
                    oldNo = hunkStart(raw, '-') - 1;
                    newNo = hunkStart(raw, '+') - 1;
                    text = raw;
                }
                else if (raw.length > 0 && raw[0] == '+')
                {
                    line.kind = ToolLineKind.add;
                    line.newNo = ++newNo;
                    text = raw[1 .. $];
                }
                else if (raw.length > 0 && raw[0] == '-')
                {
                    line.kind = ToolLineKind.del;
                    line.oldNo = ++oldNo;
                    text = raw[1 .. $];
                }
                else
                {
                    line.kind = ToolLineKind.context;
                    line.oldNo = ++oldNo;
                    line.newNo = ++newNo;
                    text = raw.length > 0 && raw[0] == ' ' ? raw[1 .. $] : raw;
                }
            }
            else
            {
                line.kind = ToolLineKind.plain;
                line.newNo = ++plainNo;
            }

            const oldStr = line.oldNo > 0 ? padLeft(line.oldNo, 4) : "    ";
            const newStr = line.newNo > 0 ? padLeft(line.newNo, 4) : "    ";
            const sign = line.kind == ToolLineKind.add ? '+' :
                (line.kind == ToolLineKind.del ? '-' : ' ');
            const visibleText = line.kind == ToolLineKind.hunk
                ? text
                : oldStr ~ " " ~ newStr ~ " " ~ sign ~ " " ~ text;
            line.visible = visibleText;
            _toolLines ~= line;
            ++emitted;
        }

        // Height comes from the row count times one measured line; individual
        // rows are shaped on demand in drawToolBody. Shaping all of them up
        // front cost ~2 s for a 600-line output and made expand feel frozen.
        if (_toolLines.length > 0)
        {
            const reference = shapeMonoLine(toUTF32("0"));
            _toolLineHeight = reference.measuredSize().height;
        }
        if (_toolLineHeight <= 0)
            _toolLineHeight = opencodeFontBase + 2;
        _toolLinesHeight = cast(int) (_toolLines.length * _toolLineHeight);
        return _toolLinesHeight;
    }

    /// Paint the expanded tool body (diff or numbered plain text) and register
    /// each row as a selectable segment. Returns the height consumed.
    private int drawToolBody(ref Canvas canvas, int innerWidth, int top)
    {
        ensureToolLines(innerWidth);
        const count = cast(int) _toolLines.length;
        if (count == 0) return 0;
        const rowH = maxInt(1, cast(int) _toolLineHeight);
        const fullW = maxInt(1, innerWidth);

        // Shape and draw only the rows that intersect the visible clip. A
        // collapsed->expanded toggle over a large output used to shape every
        // row (hundreds of TextLayouts, ~2 s); now it shapes just the ~30 on
        // screen and caches them for later paints/scrolls.
        const clip = canvas.clipRect();
        int firstRow = 0;
        int lastRow = count;
        if (!clip.empty())
        {
            // `clipRect()` is in surface/draw-list coordinates while `top` is
            // canvas-local, so subtract the canvas origin first. Without this,
            // every row below a bubble that is offset down the window (or
            // scrolled) was culled as "above the clip" and the expanded body
            // rendered blank for read/edit parts lower in the transcript.
            const originY = canvas.toSurface(Point(0, 0)).y;
            firstRow = maxInt(0, cast(int) ((clip.y - originY - top) / rowH));
            lastRow = minInt(count,
                cast(int) ((clip.bottom() - originY - top) / rowH) + 2);
        }

        foreach (i; firstRow .. lastRow)
        {
            auto line = &_toolLines[cast(size_t) i];
            if (line.layout is null)
            {
                line.layout = shapeMonoLine(toUTF32(
                    line.visible.length > 0 ? line.visible : " "));
            }
            const y = top + i * rowH;
            if (line.kind == ToolLineKind.add)
                canvas.fillRect(Rect(padH, y, fullW, rowH), opencodeDiffAddBg);
            else if (line.kind == ToolLineKind.del)
                canvas.fillRect(Rect(padH, y, fullW, rowH), opencodeDiffDeleteBg);
            const color = line.kind == ToolLineKind.add ? opencodeDiffAdd :
                line.kind == ToolLineKind.del ? opencodeDiffDelete :
                line.kind == ToolLineKind.hunk ? opencodeMuted : opencodeText;
            auto clipped = canvas.clipped(Rect(padH, y, fullW, rowH));
            clipped.drawLayout(Point(padH, y), line.layout, color);
            if (line.layout.lines.length > 0)
                _selSegments ~= SelectSegment(line.layout, padH, y, fullW, rowH);
        }
        return count * rowH;
    }

    /// Compose the Thinking header line: `▸ Thinking`, the live/final token
    /// count once any token has arrived, and the pulsing `▌`/`▐` while the
    /// assistant is still working.
    private string thinkingHeaderText() const
    {
        const toggle = _thinkingCollapsed ? "▸" : "▾";
        string text = toggle ~ " Thinking";
        if (_liveTokens > 0)
            text ~= "  " ~ formatThousands(cast(int) _liveTokens) ~ " tokens";
        if (_tokenRateTenths > 0)
            text ~= "  " ~ formatTokenRate(_tokenRateTenths);
        if (_thinkingLive || _tokensLive)
        {
            // Pulsing indicator: cycle between ▌ and ▐ every half second.
            const phase = cast(int) (_thinkingElapsed * 2) & 1;
            text ~= phase == 0 ? " ▌" : " ▐";
        }
        return text;
    }

    /// Test-only: the exact Thinking header line as drawn.
    public string thinkingHeaderTextForTesting() const
    {
        return thinkingHeaderText();
    }

    /// Slim thinking header: `▸ Thinking` when collapsed (pulsing `▌` while
    /// the assistant is still working, plus the live token count), `▾ Thinking`
    /// when expanded. Clicking toggles the full reasoning text.
    private void drawThinkingHeader(ref Canvas canvas, int innerWidth, int top)
    {
        const live = _thinkingLive || _tokensLive;
        auto layout = canvas.layoutText(toUTF32(thinkingHeaderText()), 1,
            FontRole.ui, cast(FontFace) theme().uiFont, maxInt(1, innerWidth),
            true);
        const h = layout.measuredSize().height;
        _thinkingRect = Rect(padH, top, maxInt(1, innerWidth), h);
        // No chip background: reasoning is a single muted line ("▸ Thinking")
        // that expands in place, like ReasoningHeader in the original opencode
        // (session/index.tsx) rather than a filled button.
        canvas.drawLayout(Point(padH, top), layout,
            live ? opencodeAccent :
            (_thinkingHover ? opencodeText : opencodeMuted));
    }

    /// Compact display of the command arguments: `(name=value, ...)` for a
    /// JSON object, otherwise the raw text, truncated.
    private string toolArgsDisplay()
    {
        if (_toolArgs.length == 0) return "";
        string args = _toolArgs;
        JSONValue value;
        try value = parseJSON(args);
        catch (Exception) value = JSONValue.init;
        if (value.type == JSONType.object)
        {
            string[] parts;
            foreach (key, entry; value.object)
                parts ~= key ~ "=" ~ toolArgValue(entry, 0);
            string joined;
            foreach (index, part; parts)
            {
                if (index > 0) joined ~= ", ";
                joined ~= part;
            }
            if (joined.length > 72) joined = joined[0 .. 72] ~ "…";
            return "(" ~ joined ~ ")";
        }
        if (args.length > 40) args = args[0 .. 40] ~ "…";
        return "(" ~ args ~ ")";
    }

    /// Render one tool-argument value for the compact header. Arrays are
    /// flattened into a space-separated command line so an argv list reads
    /// like what will actually run (`program=cmd.exe, args=/c del "x"`),
    /// instead of the old opaque `args=[…]`.
    private static string toolArgValue(JSONValue entry, int depth)
    {
        switch (entry.type)
        {
            case JSONType.string:
                // Quote a single argument containing spaces so the argv list
                // stays readable and unambiguous.
                foreach (ch; entry.str)
                    if (ch == ' ')
                        return "\"" ~ entry.str ~ "\"";
                return entry.str;
            case JSONType.integer:
                return to!string(entry.integer);
            case JSONType.array:
                if (depth >= 2) return "[…]";
                string joined;
                foreach (index, item; entry.array)
                {
                    if (index > 0) joined ~= " ";
                    joined ~= toolArgValue(item, depth + 1);
                }
                return joined.length > 0 ? joined : "[]";
            case JSONType.object:
                return "{…}";
            case JSONType.true_:
                return "true";
            case JSONType.false_:
                return "false";
            case JSONType.null_:
                return "null";
            default:
                return "…";
        }
    }

    private void collectMarkdownTargets(ref MdComposition composition, int contentY)
    {
        foreach (item; composition.items)
        {
            // Selectable runs are the plain prose/heading/list text. Clipped
            // code lines keep their dedicated Copy pill instead.
            if (item.kind == MdItemKind.text && item.layout !is null &&
                !item.clipText)
                _selSegments ~= SelectSegment(item.layout,
                    cast(int)(padH + item.x), cast(int)(contentY + item.y),
                    maxInt(1, cast(int) item.w), maxInt(1, cast(int) item.h));

            if (item.kind == MdItemKind.text && item.target.length > 0)
            {
                _linkRects ~= Rect(cast(int)(padH + item.x),
                    cast(int)(contentY + item.y),
                    maxInt(1, cast(int) item.w), maxInt(1, cast(int) item.h));
                _linkUrls ~= to!string(item.target);
            }
            else if (item.kind == MdItemKind.panel)
            {
                const bx = cast(int)(padH + item.w) - 44;
                const by = cast(int)(contentY + item.y) + 4;
                _copyRects ~= Rect(bx, by, 40, 18);
                _copyLabels ~= to!string(item.codeText);
            }
        }
    }

    private void drawCopyPill(ref Canvas canvas, Rect rect, bool hovered)
    {
        canvas.fillRoundedRect(rect, rect.height / 2,
            hovered ? opencodeAccent : opencodeBorder);
        canvas.drawTextInRect(rect, "Copy"d,
            hovered ? Color.rgb(255, 255, 255) : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }

    /// True when a non-empty text range is selected in this bubble.
    public bool hasSelection()
    {
        return _selAnchorSeg >= 0 && _selFocusSeg >= 0 &&
            (_selAnchorSeg != _selFocusSeg ||
             _selAnchorChar != _selFocusChar);
    }

    /// The selected message text ("" when nothing is selected).
    public string selectedText()
    {
        if (!hasSelection()) return "";
        int firstSeg, lastSeg;
        size_t firstChar, lastChar;
        orderedSelection(firstSeg, firstChar, lastSeg, lastChar);
        string result;
        bool haveLine;
        double lastY;
        for (int seg = firstSeg; seg <= lastSeg; ++seg)
        {
            if (seg < 0 || seg >= cast(int) _selSegments.length) continue;
            const layout = _selSegments[seg].layout;
            const len = layout.text().length;
            const from = seg == firstSeg
                ? (firstChar < len ? firstChar : len) : 0;
            const endIndex = seg == lastSeg
                ? (lastChar < len ? lastChar : len) : len;
            if (endIndex <= from) continue;
            const y = _selSegments[seg].y;
            if (haveLine && y != lastY) result ~= '\n';
            result ~= to!string(layout.text()[from .. endIndex]);
            lastY = y;
            haveLine = true;
        }
        return result;
    }

    /// Select the whole message (right-click → Select all).
    public void selectAll()
    {
        if (_selSegments.length == 0) return;
        _selAnchorSeg = 0;
        _selAnchorChar = 0;
        _selFocusSeg = cast(int) _selSegments.length - 1;
        _selFocusChar = _selSegments[$ - 1].layout.text().length;
        invalidate();
    }

    /// Test-only: global origin of the first selectable run.
    public Point textOriginForTesting()
    {
        if (_selSegments.length == 0) return Point(-1, -1);
        const segment = _selSegments[0];
        return localToGlobal(Point(segment.x + 1,
            segment.y + maxInt(1, segment.h / 2)));
    }

    /// Test-only: global point just inside the right edge of the first run.
    public Point textEndForTesting()
    {
        if (_selSegments.length == 0) return Point(-1, -1);
        const segment = _selSegments[0];
        return localToGlobal(Point(segment.x + maxInt(1, segment.w - 1),
            segment.y + maxInt(1, segment.h / 2)));
    }

    private void orderedSelection(out int firstSeg, out size_t firstChar,
        out int lastSeg, out size_t lastChar)
    {
        const backwards = _selAnchorSeg > _selFocusSeg ||
            (_selAnchorSeg == _selFocusSeg &&
             _selAnchorChar > _selFocusChar);
        firstSeg = backwards ? _selFocusSeg : _selAnchorSeg;
        lastSeg = backwards ? _selAnchorSeg : _selFocusSeg;
        firstChar = backwards ? _selFocusChar : _selAnchorChar;
        lastChar = backwards ? _selAnchorChar : _selFocusChar;
    }

    private void drawSelection(ref Canvas canvas)
    {
        if (!hasSelection()) return;
        int firstSeg, lastSeg;
        size_t firstChar, lastChar;
        orderedSelection(firstSeg, firstChar, lastSeg, lastChar);
        foreach (segIndex, segment; _selSegments)
        {
            const index = cast(int) segIndex;
            if (index < firstSeg || index > lastSeg) continue;
            const layout = segment.layout;
            const len = layout.text().length;
            const from = index == firstSeg
                ? (firstChar < len ? firstChar : len) : 0;
            const endIndex = index == lastSeg
                ? (lastChar < len ? lastChar : len) : len;
            foreach (rect; layout.selectionRects(from, endIndex))
                canvas.fillRect(Rect(segment.x + cast(int) rect.x,
                    segment.y + cast(int) rect.y,
                    maxInt(1, cast(int) rect.width),
                    maxInt(1, cast(int) rect.height)), opencodeSelection);
        }
    }

    /// Map a bubble-local point to a (segment, character) caret.
    private bool selectSegmentAt(Point position, out int segIndex,
        out size_t charIndex)
    {
        segIndex = -1;
        charIndex = 0;
        foreach (index, segment; _selSegments)
        {
            if (position.x < segment.x || position.x >= segment.x + segment.w ||
                position.y < segment.y || position.y >= segment.y + segment.h)
                continue;
            segIndex = cast(int) index;
            charIndex = segment.layout.hitTest(position.x - segment.x,
                position.y - segment.y);
            return true;
        }
        return false;
    }

    /// Extend the selection to `position`, clamping to the nearest run when
    /// the pointer is dragged past the text so the tail still selects.
    private void extendSelection(Point position)
    {
        int segIndex;
        size_t charIndex;
        if (selectSegmentAt(position, segIndex, charIndex))
        {
            _selFocusSeg = segIndex;
            _selFocusChar = charIndex;
            return;
        }
        if (_selSegments.length == 0) return;
        int nearest;
        bool found;
        double nearestDistance;
        foreach (index, segment; _selSegments)
        {
            const centreY = segment.y + segment.h * 0.5;
            double distance = position.y - centreY;
            if (distance < 0) distance = -distance;
            if (!found || distance < nearestDistance)
            {
                nearest = cast(int) index;
                nearestDistance = distance;
                found = true;
            }
        }
        _selFocusSeg = nearest;
        _selFocusChar = position.y < _selSegments[nearest].y
            ? 0 : _selSegments[nearest].layout.text().length;
    }

    private void clearSelection()
    {
        if (_selAnchorSeg < 0 && _selFocusSeg < 0) return;
        _selAnchorSeg = -1;
        _selFocusSeg = -1;
        invalidate();
    }

    /// Whether this bubble reserves (and draws) the one-line meta footer.
    ///
    /// The footer is reserved only for real bottom-aligned meta: the token
    /// usage line, the Regenerate/Retry pill or the `‹ n/m ›` branch switcher.
    ///
    /// A bare timestamp must NOT reserve it. Every restored message carries a
    /// `time`, so reserving a line for it made each assistant reply and user
    /// turn `fontPixelSize(1) + 4` px taller than the collapsed Thinking / tool
    /// rows around them; the transcript then read as alternating tight and wide
    /// gaps (a reply measured 68 px against a tool row's 31 px). The time is
    /// still drawn when the footer is shown for usage / action / branch nav.
    private bool footerVisible() const
    {
        if (_role == "tool") return false;
        return _usageText.length > 0 || _actionLabel.length > 0 ||
            _secondaryActionLabel.length > 0 ||
            _versionTotal > 1;
    }

    /// Added height below the reply for the bottom-aligned footer. The
    /// Regenerate/Retry pill and the `‹ n/m ›` branch chevrons are 18 px tall
    /// and anchored at `height - padV - 19`; reserving only a text line
    /// (`fontPixelSize(1) + 4` = 17 px) left the pill touching — even
    /// overlapping — the last line of the reply, which read as "no top
    /// padding". Reserve the pill plus a 6 px gap so it clears the text the
    /// same way the reply clears its collapsed `Thinking` header.
    private int footerReserve() const
    {
        if (!footerVisible()) return 0;
        if (_actionLabel.length > 0 || _versionTotal > 1)
            return 19 + 6;
        return fontPixelSize(1) + 4;
    }

    private void drawFooter(ref Canvas canvas, int width, int height)
    {
        if (!footerVisible()) return;
        const footer = _usageText.length > 0 ? _usageText : _time;
        if (footer.length == 0) return;
        auto layout = canvas.layoutText(toUTF32(footer), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, maxInt(1, width - 2 * padH), false);
        const x = width - padH - cast(int) layout.width;
        const y = height - padV - cast(int) layout.height;
        canvas.drawLayout(Point(maxInt(0, x), maxInt(0, y)), layout,
            opencodeMuted);
    }

    override bool onMouseMove(ref Event event)
    {
        if (_selecting)
        {
            extendSelection(event.position);
            setCursor(CursorKind.text);
            invalidate();
            return true;
        }
        int nextCopy = -1;
        int nextLink = -1;
        foreach (index; 0 .. _copyRects.length)
        {
            if (_copyLabels[index].length > 0 &&
                _copyRects[index].contains(event.position))
            {
                nextCopy = cast(int) index;
                break;
            }
        }
        foreach (index; 0 .. _linkRects.length)
        {
            if (_linkRects[index].contains(event.position))
            {
                nextLink = cast(int) index;
                break;
            }
        }
        const overAction = _actionLabel.length > 0 && _actionCallback !is null &&
            _actionRect.contains(event.position);
        const overSecondaryAction = _secondaryActionLabel.length > 0 &&
            _secondaryActionCallback !is null &&
            _secondaryActionRect.contains(event.position);
        const overCollapse = _role == "tool" &&
            _collapseRect.contains(event.position);
        const overThinking = _thinking.length > 0 &&
            _thinkingRect.contains(event.position);
        int overVersion;
        if (_versionTotal > 1)
        {
            if (_versionPrevRect.contains(event.position)) overVersion = 1;
            else if (_versionNextRect.contains(event.position)) overVersion = 2;
        }
        int hoverSeg;
        size_t hoverChar;
        const overText = selectSegmentAt(event.position, hoverSeg, hoverChar);
        if (nextCopy != _hoverCopy || nextLink != _hoverLink ||
            overAction != _actionHover ||
            overSecondaryAction != _secondaryActionHover ||
            overCollapse != _collapseHover ||
            overThinking != _thinkingHover || overVersion != _versionHover ||
            overText != _textHover)
        {
            _hoverCopy = nextCopy;
            _hoverLink = nextLink;
            _actionHover = overAction;
            _secondaryActionHover = overSecondaryAction;
            _collapseHover = overCollapse;
            _thinkingHover = overThinking;
            _versionHover = overVersion;
            _textHover = overText;
            setCursor(nextCopy >= 0 || nextLink >= 0 || overAction ||
                overSecondaryAction ||
                overCollapse || overThinking || overVersion != 0
                ? CursorKind.hand :
                (overText ? CursorKind.text : CursorKind.arrow));
            invalidate();
        }
        return false;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            if (onContextMenuRequested !is null)
            {
                string linkTarget;
                foreach (index, rect; _linkRects)
                    if (rect.contains(event.position) &&
                        index < _linkUrls.length)
                    {
                        linkTarget = _linkUrls[index];
                        break;
                    }
                onContextMenuRequested(_messageIndex,
                    localToGlobal(event.position), linkTarget);
                return true;
            }
            return false;
        }
        if (event.button != MouseButton.left) return false;
        if (_thinking.length > 0 && _thinkingRect.contains(event.position))
        {
            ChatScrollView.holdPositionForNextLayout();
            setThinkingCollapsed(!_thinkingCollapsed);
            return true;
        }
        if (_role == "tool" && _collapseRect.contains(event.position))
        {
            ChatScrollView.holdPositionForNextLayout();
            setCollapsed(!_collapsed);
            return true;
        }
        if (_versionTotal > 1)
        {
            if (_versionPrevRect.contains(event.position) && _versionPrev !is null)
            {
                _versionPrev();
                return true;
            }
            if (_versionNextRect.contains(event.position) && _versionNext !is null)
            {
                _versionNext();
                return true;
            }
        }
        if (_actionLabel.length > 0 && _actionCallback !is null &&
            _actionRect.contains(event.position))
        {
            _actionCallback();
            return true;
        }
        if (_secondaryActionLabel.length > 0 &&
            _secondaryActionCallback !is null &&
            _secondaryActionRect.contains(event.position))
        {
            _secondaryActionCallback();
            return true;
        }
        if (_hoverCopy >= 0 && _hoverCopy < cast(int) _copyRects.length)
        {
            const text = _copyLabels[_hoverCopy];
            if (text.length > 0)
            {
                copyTextToClipboard(text);
                return true;
            }
        }
        if (_hoverLink >= 0 && _hoverLink < cast(int) _linkUrls.length)
        {
            version (Windows)
                openLinkInBrowser(_linkUrls[_hoverLink]);
            return true;
        }
        // Begin a text selection when the point lands on selectable text.
        int segIndex;
        size_t charIndex;
        if (selectSegmentAt(event.position, segIndex, charIndex))
        {
            _selecting = true;
            _selAnchorSeg = segIndex;
            _selAnchorChar = charIndex;
            _selFocusSeg = segIndex;
            _selFocusChar = charIndex;
            // Take keyboard focus so Ctrl+C/Ctrl+A target this bubble rather
            // than the composer while transcript text is selected. Ctrl+V is
            // handled by the root, which returns focus to the composer.
            setFocusable(true);
            requestFocus();
            captureMouse();
            invalidate();
            return true;
        }
        // A click on empty space drops any existing selection.
        clearSelection();
        return false;
    }

    override bool onMouseUp(ref Event event)
    {
        if (_selecting)
        {
            _selecting = false;
            releaseMouse();
            return true;
        }
        return false;
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.c)
        {
            if (hasSelection())
            {
                const payload = selectedText();
                copyTextToClipboard(payload);
                _lastClipboardText = payload;
            }
            return true;
        }
        if (shortcut && event.key == Key.a)
        {
            selectAll();
            return true;
        }
        return super.onKeyDown(event);
    }

    /// Test-only: the payload this bubble last copied with Ctrl+C.
    public string lastClipboardTextForTesting() const
    {
        return _lastClipboardText;
    }

    protected override void onMouseLeave()
    {
        if (_hoverCopy != -1 || _hoverLink != -1 || _actionHover ||
            _collapseHover || _thinkingHover || _versionHover != 0 ||
            _textHover)
        {
            _hoverCopy = -1;
            _hoverLink = -1;
            _actionHover = false;
            _collapseHover = false;
            _thinkingHover = false;
            _versionHover = 0;
            _textHover = false;
            setCursor(CursorKind.arrow);
            invalidate();
        }
    }
}

// ---------------------------------------------------------------------------
// Shared tool labels + in-progress tool row (Pro)
// ---------------------------------------------------------------------------

/// Human title for a tool, mirroring opencode's tool titles. Shared by the
/// completed tool bubble and the in-progress live row.
private string humanToolTitle(string toolName)
{
    switch (toolName)
    {
        case "bash":
        case "run":
        case "dshell":
            return "Shell";
        case "read":
            return "Read";
        case "write":
            return "Write";
        case "edit":
            return "Edit";
        case "apply_patch":
            return "Patch";
        case "open":
            return "Open";
        case "update_plan":
            return "Plan";
        case "remove":
            return "Delete";
        case "glob":
            return "Glob";
        case "grep":
            return "Grep";
        default:
            if (toolName.length == 0) return "Tool";
            return capitalizeFirst(toolName);
    }
}

/// Present-participle title used while a tool call is still being generated:
/// "Writing foo.html ..." reads better than the completed "Write".
private string humanToolProgressTitle(string toolName)
{
    switch (toolName)
    {
        case "bash":
        case "run":
        case "dshell":
            return "Running";
        case "read":
            return "Reading";
        case "write":
            return "Writing";
        case "edit":
            return "Editing";
        case "apply_patch":
            return "Applying";
        case "open":
            return "Opening";
        case "update_plan":
            return "Planning";
        case "remove":
            return "Deleting";
        case "glob":
            return "Listing";
        case "grep":
            return "Searching";
        default:
            if (toolName.length == 0) return "Preparing";
            return "Preparing " ~ toolName;
    }
}

private static string capitalizeFirst(string value)
{
    if (value.length == 0) return value;
    auto buffer = value.dup;
    if (buffer[0] >= 'a' && buffer[0] <= 'z')
        buffer[0] -= 32;
    return cast(string) buffer;
}

/// A short, tool-specific subtitle (the command, filename or pattern).
private string humanToolSubtitle(string toolName, string toolArgs)
{
    switch (toolName)
    {
        case "bash":
        case "run":
        case "dshell":
            auto command = toolArgFromArgs(toolArgs, "command");
            if (command.length == 0)
                command = toolArgFromArgs(toolArgs, "program");
            if (command.length == 0) command = toolArgFromArgs(toolArgs, "args");
            return command;
        case "read":
        case "write":
        case "edit":
            return basenameOf(toolArgFromArgs(toolArgs, "filePath"));
        case "apply_patch":
        {
            const files = patchFileCount(toolArgFromArgs(toolArgs, "patch"));
            if (files == 0) return "";
            return to!string(files) ~ (files == 1 ? " file" : " files");
        }
        case "update_plan":
        {
            const steps = planStepCount(toolArgs);
            if (steps == 0) return "";
            return to!string(steps) ~ (steps == 1 ? " step" : " steps");
        }
        case "glob":
        case "grep":
            return toolArgFromArgs(toolArgs, "pattern");
        case "remove":
            auto path = toolArgFromArgs(toolArgs, "path");
            if (path.length == 0) path = toolArgFromArgs(toolArgs, "filePath");
            return basenameOf(path);
        case "open":
            return toolArgFromArgs(toolArgs, "target");
        default:
            return toolArgFromArgs(toolArgs, "path");
    }
}

private string toolArgFromArgs(string toolArgs, string key)
{
    if (toolArgs.length == 0) return "";
    JSONValue value;
    try value = parseJSON(toolArgs);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object) return "";
    if (auto field = key in value.object)
        if (field.type == JSONType.string)
            return field.str;
    return "";
}

private static string basenameOf(string path)
{
    size_t cut;
    foreach (index, ch; path)
        if (ch == '/' || ch == '\\') cut = index + 1;
    return path[cut .. $];
}

private void appendUniquePath(ref string[] paths, string path)
{
    path = path.strip();
    if (path.length == 0 || paths.canFind(path)) return;
    paths ~= path;
}

/// Candidate paths carried by structured tool arguments. Unlike prose parsing,
/// these fields and patch directives have unambiguous file semantics.
private string[] toolArgumentPaths(string toolName, string toolArgs)
{
    string[] paths;
    switch (toolName)
    {
        case "read":
        case "edit":
        case "write":
            appendUniquePath(paths, toolArgFromArgs(toolArgs, "filePath"));
            break;
        case "remove":
        {
            auto path = toolArgFromArgs(toolArgs, "path");
            appendUniquePath(paths, path.length > 0 ? path :
                toolArgFromArgs(toolArgs, "filePath"));
            break;
        }
        case "open":
        {
            auto path = toolArgFromArgs(toolArgs, "target");
            if (!path.toLower().startsWith("http://") &&
                !path.toLower().startsWith("https://"))
                appendUniquePath(paths, path);
            break;
        }
        case "grep":
        case "glob":
        case "dshell":
            appendUniquePath(paths, toolArgFromArgs(toolArgs, "path"));
            break;
        case "apply_patch":
            foreach (line; toolArgFromArgs(toolArgs, "patch").splitLines())
            {
                const text = line.strip();
                foreach (prefix; ["*** Add File:", "*** Update File:",
                    "*** Delete File:", "*** Move to:"])
                    if (text.startsWith(prefix))
                        appendUniquePath(paths, text[prefix.length .. $]);
            }
            break;
        default:
            break;
    }
    return paths;
}

/// Extract a path from a structured tool-result line. Supported forms cover
/// dshell (`<path>…</path>`, `[f] …`), grep (`file:line:`), and common compiler
/// diagnostics (`file(line):`). The caller validates every candidate on disk.
private string outputPathCandidate(string line)
{
    auto text = line.strip();
    if (text.startsWith("<path>"))
    {
        const end = text.indexOf("</path>");
        if (end > 6) return text[6 .. cast(size_t) end];
    }
    if (text.startsWith("[f] ") || text.startsWith("[d] "))
    {
        text = text[4 .. $];
        const detail = text.indexOf("  (");
        return detail > 0 ? text[0 .. cast(size_t) detail] : text;
    }
    foreach (index, ch; text)
    {
        if (ch != ':' || index + 2 >= text.length) continue;
        size_t cursor = index + 1;
        if (text[cursor] < '0' || text[cursor] > '9') continue;
        while (cursor < text.length && text[cursor] >= '0' &&
            text[cursor] <= '9') ++cursor;
        if (cursor < text.length && (text[cursor] == ':' ||
            text[cursor] == ')'))
            return text[0 .. index];
    }
    const paren = text.indexOf('(');
    if (paren > 0) return text[0 .. cast(size_t) paren];
    return "";
}

unittest
{
    auto paths = toolArgumentPaths("apply_patch",
        `{"patch":"*** Begin Patch\n*** Update File: source/app.d\n*** Add File: docs/read me.md\n*** Delete File: old.txt\n*** End Patch"}`);
    assert(paths == ["source/app.d", "docs/read me.md", "old.txt"]);
    assert(toolArgumentPaths("read", `{"filePath":"source/app.d"}`) ==
        ["source/app.d"]);
    assert(toolArgumentPaths("open", `{"target":"https://example.com"}`).length == 0);
    assert(outputPathCandidate(`<path>C:\work\src</path>`) ==
        `C:\work\src`);
    assert(outputPathCandidate(`C:\work\main.d:42: error`) ==
        `C:\work\main.d`);
    assert(outputPathCandidate(`source/app.d(17): Error`) ==
        `source/app.d`);
}

private string resolveDisplayedPath(string path, string workspace)
{
    path = path.strip();
    if (path.length == 0) return "";
    if (!isAbsolutePath(path) && workspace.length > 0)
        path = buildPath(workspace, path);
    return path;
}

/// All validated paths represented by a tool bubble. Deleted patch targets are
/// retained when their containing directory still exists.
private string[] toolFilePaths(string toolName, string toolArgs,
    string toolOutput, string workspace)
{
    string[] result;
    void accept(string candidate)
    {
        const resolved = resolveDisplayedPath(candidate, workspace);
        if (resolved.length == 0) return;
        const folder = directoryOf(resolved);
        if (exists(resolved) || (folder.length > 0 && exists(folder)))
            appendUniquePath(result, resolved);
    }
    foreach (candidate; toolArgumentPaths(toolName, toolArgs))
        accept(candidate);
    foreach (line; toolOutput.splitLines())
        accept(outputPathCandidate(line));
    return result;
}

/// Whether `path` is absolute (drive-rooted, UNC or rooted) on Windows.
private static bool isAbsolutePath(string path)
{
    if (path.length == 0) return false;
    if (path[0] == '/' || path[0] == '\\') return true;
    return path.length >= 2 && path[1] == ':';
}

/// The directory part of `path` ("" when it has no separator).
private static string directoryOf(string path)
{
    size_t cut = size_t.max;
    foreach (index, ch; path)
        if (ch == '/' || ch == '\\') cut = index;
    return cut == size_t.max ? "" : path[0 .. cut];
}

/// Open File Explorer at the folder containing `filePath`, resolving a relative
/// path against `workspace`.
private void openFileLocation(string filePath, string workspace)
{
    version (Windows)
    {
        if (filePath.length == 0) return;
        const path = resolveDisplayedPath(filePath, workspace);
        const dir = exists(path) && isDir(path) ? path : directoryOf(path);
        if (dir.length > 0 && exists(dir)) openFolderInExplorer(dir);
    }
}

private void delegate() openFileLocationAction(string filePath,
    string workspace)
{
    return delegate() { openFileLocation(filePath, workspace); };
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
private int countOccurrences(string haystack, string needle)
{
    import std.string : indexOf;

    int count;
    size_t from;
    while (needle.length > 0)
    {
        const at = haystack.indexOf(needle, from);
        if (at < 0) break;
        ++count;
        from = at + needle.length;
    }
    return count;
}

/// Number of file sections in a Codex-format patch, for the action row
/// subtitle ("3 files").
private int patchFileCount(string patch)
{
    return countOccurrences(patch, "*** Add File:") +
        countOccurrences(patch, "*** Update File:") +
        countOccurrences(patch, "*** Delete File:");
}

/// Number of steps in an `update_plan` call, for the action row subtitle.
private int planStepCount(string toolArgs)
{
    JSONValue value;
    try value = parseJSON(toolArgs);
    catch (Exception) value = JSONValue.init;
    if (value.type != JSONType.object) return 0;
    if (auto field = "plan" in value.object)
        if (field.type == JSONType.array)
            return cast(int) field.array.length;
    return 0;
}

/// The body a mutating tool is producing, for the in-flight action row's
/// preview: `write` -> the file content streamed so far, `edit` -> the new
/// text, `bash`/`run`/`dshell` -> the command. Empty when there is nothing
/// meaningful to show (e.g. a read/write whose `content` has not arrived yet).
/// `partialStringArg` tolerates the truncated JSON a tool call streams.
private string humanToolDetail(string toolName, string toolArgs)
{
    switch (toolName)
    {
        case "write":
            return partialStringArg(toolArgs, "content");
        case "edit":
            return partialStringArg(toolArgs, "newString");
        case "bash":
        case "run":
        case "dshell":
            auto command = partialStringArg(toolArgs, "command");
            if (command.length == 0) command = partialStringArg(toolArgs, "program");
            return command;
        default:
            return "";
    }
}

/// A Codex-style natural-language summary of a run of tool actions, e.g.
/// "Edited a file, ran 2 commands" or "Explored 3 files". `live` phrases the
/// actions as present participles for the in-flight header ("Editing a file,
/// running commands"), so the same row reads as work-in-progress while a tool
/// runs and as a record once it is done. Action categories mirror Codex: a
/// file mutation (write/edit/remove), a command (bash/run/dshell), and
/// exploration (read/glob/grep).
private string actionGroupSummary(const(string)[] toolNames, bool live)
{
    int edits, commands, explores, plans;
    foreach (name; toolNames)
    {
        switch (name)
        {
            case "write":
            case "edit":
            case "apply_patch":
            case "remove":
                ++edits; break;
            case "bash":
            case "run":
            case "dshell":
                ++commands; break;
            case "read":
            case "glob":
            case "grep":
                ++explores; break;
            case "update_plan":
                ++plans; break;
            default:
                break;
        }
    }

    string[] pieces;
    if (edits > 0)
    {
        if (live)
            pieces ~= edits == 1 ? "editing a file"
                : "editing " ~ to!string(edits) ~ " files";
        else
            pieces ~= edits == 1 ? "edited a file"
                : "edited " ~ to!string(edits) ~ " files";
    }
    if (commands > 0)
    {
        if (live)
            pieces ~= commands == 1 ? "running a command"
                : "running " ~ to!string(commands) ~ " commands";
        else
            pieces ~= commands == 1 ? "ran a command"
                : "ran " ~ to!string(commands) ~ " commands";
    }
    if (explores > 0)
    {
        if (live)
            pieces ~= explores == 1 ? "exploring a file"
                : "exploring " ~ to!string(explores) ~ " files";
        else
            pieces ~= explores == 1 ? "explored a file"
                : "explored " ~ to!string(explores) ~ " files";
    }
    if (plans > 0)
        pieces ~= live ? "updating the plan" : "updated the plan";

    string summary;
    foreach (index, piece; pieces)
    {
        if (index > 0) summary ~= ", ";
        summary ~= piece;
    }
    if (summary.length == 0)
        summary = live ? "working" : "worked";
    return capitalizeFirst(summary);
}

/// Format an elapsed turn duration like Codex's completion separator: compact
/// seconds below a minute, then zero-padded seconds ("8s", "1m 07s").
/// Whole seconds; never negative.
private string formatTurnDuration(double seconds)
{
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    const total = cast(long) seconds;
    if (total < 60) return to!string(total) ~ "s";
    const remainder = total % 60;
    return to!string(total / 60) ~ "m " ~
        (remainder < 10 ? "0" : "") ~ to!string(remainder) ~ "s";
}

/// A vertical container that nests an assistant turn's tool results beneath it.
/// The base `Box.onMeasure` only *returns* its size; the parent VBox lays out
/// children from their layout hints, so without publishing the measured size
/// here the nest is given zero height and its tool rows never become visible.
private final class TurnNest : VBox
{
    this(Insets padding)
    {
        super(6, padding);
    }

    protected override Size onMeasure(Size available)
    {
        const result = super.onMeasure(available);
        layoutHints().preferredWidth = result.width;
        layoutHints().preferredHeight = result.height;
        return result;
    }
}

/// A lightweight in-progress tool row (Edit / Write / Delete / Shell) shown
/// while the tool executes, so the user can see what is happening before the
/// result (and its diff) is available. The context tools keep their aggregated
/// "Exploring" row; this covers the tool calls that mutate files or run
/// commands. The row is replaced by the real result bubble once the tool
/// reports back.
/// An in-flight tool call shown as a child of its turn's action group. It names
/// the call (title + subtitle, e.g. "Writing  app.d") and, when the group is
/// expanded, previews the body the call is producing (the file content for a
/// `write`, the command for a shell) so the user can watch the work instead of
/// guessing at a generic "Writing…". It is replaced by the real result bubble
/// (with its diff) once the tool reports back.
private final class LiveToolRow : Widget
{
    // Match MessageBubble/ToolGroupBubble insets so a live row shares the
    // reading column's left edge and leaves the same 6px above and below.
    private static immutable int padH = 10;
    private static immutable int padV = 6;
    // The preview is capped so a huge `write` body can never make the row
    // unbounded or stall a frame.
    private static immutable int maxDetailLines = 40;
    private static immutable int maxDetailLineChars = 240;

    private string _toolName;
    private string _title;
    private string _subtitle;
    // Provisional `+N -M` for a file-mutating tool whose arguments are still
    // streaming (or have just arrived). Replaced by the real result bubble's
    // counters once the tool reports back.
    private int _additions;
    private int _deletions;
    private bool _hasDiff;
    // Body preview (see `setDetail`), split into display rows on demand.
    private string _detail;
    private string[] _detailLines;
    private bool _detailTruncated;
    // Live wall-clock timer: shown while the command runs, so a long command
    // displays its elapsed time the same way a settled row shows its duration.
    private MonoTime _started;
    private long _fixedMs;      // > 0 freezes the value (tests / settled rows)
    private long _lastBucket = -1;

    void delegate() onSizeChanged;

    this()
    {
        setId("oc-live-tool");
        _started = MonoTime.currTime;
    }

    /// Freeze the elapsed value (tests and restored rows). 0 restores the live
    /// clock.
    void setElapsed(long ms)
    {
        _fixedMs = ms;
        invalidate();
    }

    private long elapsedMs() const
    {
        if (_fixedMs > 0) return _fixedMs;
        return cast(long) (MonoTime.currTime - _started).total!"msecs";
    }

    /// Test-only: the elapsed time currently displayed.
    public long toolElapsedMsForTesting() const { return elapsedMs(); }

    protected override void onTick(double deltaSeconds)
    {
        if (_fixedMs > 0) return;
        const ms = elapsedMs();
        // Repaint only when the visible label can change (0.1s buckets under a
        // second, whole seconds above) so a long command does not repaint every
        // frame.
        const bucket = ms < 1000 ? ms / 100 : ms / 1000;
        if (bucket == _lastBucket) return;
        _lastBucket = bucket;
        invalidate();
    }

    /// Name the call being shown. `title` is the human tool name (present
    /// participle while its arguments stream) and `subtitle` is the command or
    /// filename.
    void setSummary(string toolName, string title, string subtitle)
    {
        if (_toolName == toolName && _title == title && _subtitle == subtitle)
            return;
        _toolName = toolName;
        _title = title;
        _subtitle = subtitle;
        invalidate();
    }

    void setDiff(int additions, int deletions)
    {
        if (_additions == additions && _deletions == deletions) return;
        _additions = additions;
        _deletions = deletions;
        _hasDiff = additions > 0 || deletions > 0;
        invalidate();
    }

    /// Set the body previewed under the row (the streamed tool body). Empty
    /// hides the preview. Only the first `maxDetailLines` lines are kept.
    void setDetail(string detail)
    {
        if (_detail == detail) return;
        _detail = detail;
        rebuildDetailLines();
        invalidate();
    }

    private void rebuildDetailLines()
    {
        _detailLines.length = 0;
        _detailTruncated = false;
        if (_detail.length == 0) return;
        import std.string : splitLines;
        const lines = splitLines(_detail);
        foreach (index, raw; lines)
        {
            if (index >= maxDetailLines)
            {
                _detailTruncated = true;
                break;
            }
            _detailLines ~= raw.length > maxDetailLineChars
                ? raw[0 .. maxDetailLineChars] ~ "…" : raw;
        }
    }

    string toolNameForTesting() const { return _toolName; }
    int diffAdditionsForTesting() const { return _additions; }
    int diffDeletionsForTesting() const { return _deletions; }
    string previewForTesting() const { return _detail; }

    private int headerHeight()
    {
        return 2 * padV + opencodeFontBase + 2;
    }

    private int detailLineHeight()
    {
        return opencodeFontBase + 2;
    }

    private int detailHeight()
    {
        return cast(int) _detailLines.length * detailLineHeight() +
            (_detailTruncated ? detailLineHeight() : 0);
    }

    private string rowText() const
    {
        string text = _title;
        if (_subtitle.length > 0) text ~= "  " ~ _subtitle;
        return text;
    }

    string textForTesting() const { return rowText(); }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        const height = headerHeight() + detailHeight();
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = height;
        return Size(width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const h = headerHeight();
        const textX = padH;
        const innerWidth = maxInt(1, bounds().width - textX - padH);
        int statsWidth;
        TextLayout addLayout, delLayout, elapsedLayout;
        if (_hasDiff)
        {
            addLayout = canvas.layoutText(toUTF32("+" ~ to!string(_additions)),
                1, FontRole.monospace, null, 200, false);
            delLayout = canvas.layoutText(toUTF32("-" ~ to!string(_deletions)),
                1, FontRole.monospace, null, 200, false);
            statsWidth = cast(int) addLayout.width + 8 + cast(int) delLayout.width;
        }
        const elapsedText = formatElapsedMs(elapsedMs());
        if (elapsedText.length > 0)
        {
            elapsedLayout = canvas.layoutText(toUTF32(elapsedText), 1,
                FontRole.monospace, null, 200, false);
            if (statsWidth > 0) statsWidth += 8;
            statsWidth += cast(int) elapsedLayout.width;
        }
        const available = maxInt(1, innerWidth - statsWidth -
            (statsWidth > 0 ? 8 : 0));
        auto layout = canvas.layoutText(toUTF32(rowText()), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, available, false);
        const sy = (h - cast(int) layout.height) / 2;
        canvas.drawLayout(Point(textX, sy), layout, opencodeMuted);
        if (statsWidth > 0)
        {
            // The stats sit next to the header text: +N -M and the live elapsed
            // time. `TextLayout` is a class, so test `is null`, not `.width`.
            int x = textX + cast(int) layout.width + 8;
            // Baseline-align the counters/timer with the header label so the
            // taller monospace line box does not push them above the middle.
            const statSy = cast(int)(sy + layout.lines[0].baseline -
                firstBaseline(addLayout !is null ? addLayout : elapsedLayout));
            if (addLayout !is null)
            {
                canvas.drawLayout(Point(x, statSy), addLayout, opencodeDiffAdd);
                canvas.drawLayout(Point(x + cast(int) addLayout.width + 8, statSy),
                    delLayout, opencodeDiffDelete);
                x += cast(int) addLayout.width + 8 + cast(int) delLayout.width;
            }
            if (elapsedLayout !is null)
            {
                if (addLayout !is null) x += 8;
                canvas.drawLayout(Point(x, statSy), elapsedLayout, opencodeMuted);
            }
        }

        if (_detailLines.length == 0) return;
        // The streamed body, one monospace row per line, indented under the
        // header. Long lines are clipped to the row width (no wrap).
        int y = h;
        const lineH = detailLineHeight();
        const bodyX = padH;
        const bodyWidth = maxInt(1, bounds().width - bodyX - padH);
        foreach (line; _detailLines)
        {
            auto bodyLayout = canvas.layoutText(toUTF32(line), 1,
                FontRole.monospace, null, bodyWidth, false);
            canvas.drawLayout(Point(bodyX, y), bodyLayout, opencodeMuted);
            y += lineH;
        }
        if (_detailTruncated)
        {
            auto moreLayout = canvas.layoutText(
                toUTF32("… " ~ to!string(_detail.length) ~ " bytes"),
                1, FontRole.monospace, null, bodyWidth, false);
            canvas.drawLayout(Point(bodyX, y), moreLayout, opencodeMuted);
        }
    }
}

// ---------------------------------------------------------------------------
// Live activity row (Pro): spinner + phase label at the end of the transcript
// ---------------------------------------------------------------------------

/// A small always-visible "what is going on" row that sits at the end of the
/// conversation while the assistant is busy. It shows a pulsing dot, the
/// current phase ("Waiting for the model…", "Thinking…", "Running 2 tools…")
/// and the elapsed seconds. It fills the gaps where the transcript would
/// otherwise look frozen: after a prompt is sent (before the first token) and
/// between tool rounds. Once text streams, the reply's own Thinking header
/// carries the progress (a live token count) and this row is dropped. The dot is
/// drawn rather than a glyph so it never depends on font coverage.
private final class ActivityRow : Widget
{
    private string _label;
    private double _elapsed;
    private bool _live;

    // Same insets as every other transcript row so the gap above and below a
    // stacked collapsible row stays uniform.
    private static immutable int padH = 10;
    private static immutable int padV = 6;

    this()
    {
        setId("oc-activity");
    }

    /// Set the phase label. The elapsed clock keeps running across phase
    /// changes so the seconds describe how long the assistant has been working
    /// on the request, not just the current phase.
    void setLabel(string label)
    {
        if (_label == label) return;
        _label = label;
        invalidate();
    }

    void setLive(bool value)
    {
        if (_live == value) return;
        _live = value;
        // A fresh work session starts the clock; stopping clears it.
        _elapsed = 0.0;
        invalidate();
    }

    bool hasLabel() const { return _label.length > 0; }
    string textForTesting() const { return _label; }
    string displayTextForTesting() const { return displayText(); }

    private int pulseStep() const
    {
        return cast(int) (_elapsed * 4) % 4;
    }

    private string displayText() const
    {
        const seconds = cast(int) _elapsed;
        return _label ~ (seconds >= 1
            ? "  " ~ to!string(seconds) ~ "s" : "");
    }

    private int rowHeight()
    {
        // Match every other single-line transcript row (Thinking / tool /
        // group / live) so the activity row keeps the same gap as the rest.
        return 2 * padV + opencodeFontBase + 2;
    }

    protected override void onTick(double deltaSeconds)
    {
        if (!_live) return;
        const beforePulse = pulseStep();
        const beforeSeconds = cast(int) _elapsed;
        _elapsed += deltaSeconds;
        // Repaint only when the visible state changes: a long wait must not
        // repaint the whole window every frame.
        if (pulseStep() != beforePulse ||
            cast(int) _elapsed != beforeSeconds)
            invalidate();
    }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        const height = rowHeight();
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = height;
        return Size(width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const h = rowHeight();
        const centerY = h / 2;
        static immutable int[4] pulseAlphas = [80, 140, 220, 140];
        canvas.fillCircle(Point(padH - 6, centerY), 3,
            opencodeAccent.withAlpha(pulseAlphas[pulseStep()]));
        const textX = padH;
        auto layout = canvas.layoutText(toUTF32(displayText()), 1,
            FontRole.ui, cast(FontFace) theme().uiFont,
            maxInt(1, bounds().width - textX - padH), false);
        canvas.drawLayout(Point(textX,
            (h - cast(int) layout.height) / 2), layout, opencodeMuted);
    }
}

// ---------------------------------------------------------------------------
// Turn completion separator (Pro): Codex-style elapsed-work boundary
// ---------------------------------------------------------------------------

/// A durable boundary between the agent's working transcript and its final
/// answer. Keeping this separate from ToolGroupBubble is important: putting
/// "Worked for …" in an action header makes the elapsed time appear after the
/// preceding prose instead of immediately above the answer it introduces.
private final class TurnCompletionSeparator : Widget
{
    private static immutable int padH = 10;
    private static immutable int height = 30;
    private double _elapsedSeconds;

    this(double elapsedSeconds)
    {
        _elapsedSeconds = elapsedSeconds < 0 ? 0 : elapsedSeconds;
    }

    string textForTesting() const
    {
        return "Worked for " ~ formatTurnDuration(_elapsedSeconds);
    }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = height;
        return Size(width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const available = maxInt(1, width - 2 * padH);
        auto layout = canvas.layoutText(toUTF32(textForTesting()), 1,
            FontRole.ui, cast(FontFace) theme().uiFont, available, false);
        const labelWidth = cast(int) layout.width;
        const labelHeight = cast(int) layout.height;
        const gap = 8;
        const leadWidth = 20;
        const centerY = height / 2;
        const textX = padH + leadWidth + gap;
        const textY = maxInt(0, (height - labelHeight) / 2);

        canvas.fillRect(Rect(padH, centerY, leadWidth, 1), opencodeBorder);
        canvas.drawLayout(Point(textX, textY), layout, opencodeMuted);
        const tailX = textX + labelWidth + gap;
        if (tailX < width - padH)
            canvas.fillRect(Rect(tailX, centerY, width - padH - tailX, 1),
                opencodeBorder);
    }
}

// Action tool group (Pro): one foldable row for an assistant round's tools
// ---------------------------------------------------------------------------

/// A foldable group of consecutive context tool calls (Read / Glob / Grep),
/// mirroring opencode's single "Explored" row. The header summarises the run
/// ("Explored  2 reads, 1 search"); expanding reveals the individual tool rows
/// as children, each of which is itself a collapsible MessageBubble. This is
/// the second level of the tool-part hierarchy.
/// One collapsible per assistant turn that groups *all* of the turn's tool
/// results behind a Codex-style natural-language summary ("Edited a file, ran
/// 2 commands"). It is present while the tools run (present tense, `live`) and
/// stays as a record once they finish (past tense), so nothing "disappears".
/// Expanding reveals the individual tool parts, each itself a collapsible
/// MessageBubble (or a LiveToolRow while a call is still in flight).
private final class ToolGroupBubble : Widget
{
    // Mirror MessageBubble's text insets (its padH/padV are private) so the
    // action header sits on the same baseline and left edge as the sibling
    // Thinking / tool rows instead of being flush to the bubble edge.
    private static immutable int padH = 10;
    private static immutable int padV = 6;
    // Expanded children sit at the same left edge as the header text above
    // them; `onLayout` places them at `padH`, matching MessageBubble's text.

    private Widget[] _parts;
    private bool _collapsed = true;
    private bool _hover;
    private Rect _headerRect;
    // Live mode: the group is present while its tools are still running. The
    // header reads in the present tense ("Editing a file, running commands")
    // and flips to the past tense once every tool has reported back.
    private bool _live;

    // Optional persistence key so an expanded group stays expanded across the
    // many column rebuilds that happen while a reply streams.
    string collapseKey;
    void delegate(bool collapsed) onCollapseChanged;

    void delegate() onSizeChanged;



    this(Widget[] parts, bool live = false)
    {
        _parts = parts;
        _live = live;
        foreach (part; parts)
        {
            part.setVisible(false);
            add(part);
        }
    }

    /// The tool names of every child (settled bubbles and in-flight rows), used
    /// to build the Codex-style natural-language summary.
    private string[] childToolNames() const
    {
        string[] names;
        foreach (part; _parts)
        {
            if (auto bubble = cast(MessageBubble) part)
                names ~= bubble.toolNameForTesting();
            else if (auto row = cast(LiveToolRow) part)
                names ~= row.toolNameForTesting();
        }
        return names;
    }

    int partCount() const { return cast(int) _parts.length; }
    bool collapsed() const { return _collapsed; }
    bool collapsedForTesting() const { return _collapsed; }
    string headerTextForTesting() const { return headerText(); }

    void setCollapsed(bool value)
    {
        if (_collapsed == value) return;
        _collapsed = value;
        foreach (part; _parts)
            part.setVisible(!_collapsed);
        if (onCollapseChanged !is null) onCollapseChanged(_collapsed);
        if (onSizeChanged !is null) onSizeChanged();
        invalidate();
    }

    void toggle() { setCollapsed(!_collapsed); }

    /// Append an in-flight child row after construction: the live path learns
    /// about a running call only after the settled children are built.
    void addPart(Widget part)
    {
        _parts ~= part;
        part.setVisible(!_collapsed);
        add(part);
    }

    /// Mark the group as still working so its header reads in the present
    /// tense ("Editing a file") until a settled group replaces it.
    void setLive(bool value)
    {
        if (_live == value) return;
        _live = value;
        invalidate();
    }

    private int headerHeight()
    {
        return opencodeFontBase + 2;
    }

    private string headerText() const
    {
        auto summary = actionGroupSummary(childToolNames(), _live);
        return (_collapsed ? "▸" : "▾") ~ " " ~ summary;
    }

    /// Sum the child rows' added/removed line counts so the group header can
    /// show them without the user expanding the nested tools.
    private void diffTotals(out int additions, out int deletions)
    {
        additions = 0;
        deletions = 0;
        foreach (part; _parts)
        {
            if (auto bubble = cast(MessageBubble) part)
            {
                additions += bubble.diffAdditionsForTesting();
                deletions += bubble.diffDeletionsForTesting();
            }
            else if (auto row = cast(LiveToolRow) part)
            {
                additions += row.diffAdditionsForTesting();
                deletions += row.diffDeletionsForTesting();
            }
        }
    }

    /// Test-only: aggregate `+N` of the group's children.
    public int diffAdditionsForTesting()
    {
        int additions, deletions;
        diffTotals(additions, deletions);
        return additions;
    }

    /// Test-only: aggregate `-M` of the group's children.
    public int diffDeletionsForTesting()
    {
        int additions, deletions;
        diffTotals(additions, deletions);
        return deletions;
    }

    /// Parallel children share the same wall-clock interval, so the collapsed
    /// group header shows the longest child rather than adding their times.
    private long elapsedTotalMs()
    {
        long total;
        foreach (part; _parts)
        {
            if (auto bubble = cast(MessageBubble) part)
                total = max(total, bubble.toolElapsedMsForTesting());
            else if (auto row = cast(LiveToolRow) part)
                total = max(total, row.toolElapsedMsForTesting());
        }
        return total;
    }

    /// Test-only: aggregate tool duration of the group's children.
    public long elapsedMsForTesting() { return elapsedTotalMs(); }

    /// While the group is live its header shows a running total; repaint it when
    /// the displayed value changes so a long command's timer ticks even when no
    /// stream events arrive (the rows themselves are collapsed/hidden).
    protected override void onTick(double deltaSeconds)
    {
        if (!_live) return;
        const ms = elapsedTotalMs();
        const bucket = ms < 1000 ? ms / 100 : ms / 1000;
        if (bucket == _elapsedBucket) return;
        _elapsedBucket = bucket;
        invalidate();
    }

    private long _elapsedBucket = -1;

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        // Match MessageBubble's vertical padding so a collapsed group row is
        // the same height as a sibling Thinking / Shell / Read header row.
        double height = 2 * padV + headerHeight();
        if (!_collapsed)
        {
            const childWidth = maxInt(0, width - 2 * padH);
            foreach (part; _parts)
            {
                part.measure(Size(childWidth, available.height));
                const hint = part.layoutHints().preferredHeight;
                height += hint >= 0 ? hint : cast(double) part.bounds().height;
            }
        }
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = cast(int) height;
        return Size(width, cast(int) height);
    }

    protected override void onLayout()
    {
        if (_collapsed) return;
        const width = maxInt(0, bounds().width - 2 * padH);
        int y = 2 * padV + headerHeight();
        foreach (part; _parts)
        {
            const hint = part.layoutHints().preferredHeight;
            const childHeight = hint >= 0 ? hint : part.bounds().height;
            part.setBounds(Rect(padH, y, width, childHeight));
            y += childHeight;
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const h = headerHeight();
        const innerWidth = maxInt(1, bounds().width - 2 * padH);
        _headerRect = Rect(padH, padV, innerWidth, h);

        // Aggregate the children's diff counters so the user sees the added and
        // removed line counts on the right edge of the collapsed group header,
        // updating live as the tools stream.
        int additions, deletions;
        diffTotals(additions, deletions);
        int statsWidth;
        TextLayout addLayout, delLayout, elapsedLayout;
        if (additions > 0 || deletions > 0)
        {
            addLayout = canvas.layoutText(toUTF32("+" ~ to!string(additions)),
                1, FontRole.monospace, null, 200, false);
            delLayout = canvas.layoutText(toUTF32("-" ~ to!string(deletions)),
                1, FontRole.monospace, null, 200, false);
            statsWidth = cast(int) addLayout.width + 8 + cast(int) delLayout.width;
        }
        // The `+N -M` counters and elapsed timer are drawn on the header's
        // vertical midline (see `sy` below), not hugging the top edge.
        const elapsedText = formatElapsedMs(elapsedTotalMs());
        if (elapsedText.length > 0)
        {
            elapsedLayout = canvas.layoutText(toUTF32(elapsedText), 1,
                FontRole.monospace, null, 200, false);
            if (statsWidth > 0) statsWidth += 8;
            statsWidth += cast(int) elapsedLayout.width;
        }

        const textWidth = maxInt(1, innerWidth - statsWidth -
            (statsWidth > 0 ? 8 : 0));
        auto layout = canvas.layoutText(toUTF32(headerText()), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, textWidth, false);
        auto labelCanvas = canvas.clipped(Rect(padH, padV, textWidth, h));
        labelCanvas.drawLayout(Point(padH, padV), layout,
            _hover ? opencodeText : opencodeMuted);

        if (statsWidth > 0)
        {
            // `TextLayout` is a class: an unassigned one is null, so test for
            // presence rather than `.width > 0`.
            int x = padH + cast(int) layout.width + 8;
            // The label is drawn at `padV`, so put the counters/timer on its
            // baseline rather than their own box centre (which sat too high).
            const sy = cast(int)(padV + layout.lines[0].baseline -
                firstBaseline(addLayout !is null ? addLayout : elapsedLayout));
            if (addLayout !is null)
            {
                canvas.drawLayout(Point(x, sy), addLayout, opencodeDiffAdd);
                canvas.drawLayout(Point(x + cast(int) addLayout.width + 8, sy),
                    delLayout, opencodeDiffDelete);
                x += cast(int) addLayout.width + 8 + cast(int) delLayout.width;
            }
            if (elapsedLayout !is null)
            {
                if (addLayout !is null) x += 8;
                canvas.drawLayout(Point(x, sy), elapsedLayout, opencodeMuted);
            }
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.left &&
            _headerRect.contains(event.position))
        {
            ChatScrollView.holdPositionForNextLayout();
            toggle();
            return true;
        }
        return false;
    }

    protected override void onMouseEnter()
    {
        _hover = true;
        invalidate();
    }

    protected override void onMouseLeave()
    {
        if (!_hover) return;
        _hover = false;
        invalidate();
    }
}

// ---------------------------------------------------------------------------
// Context usage meter (Pro): small rectangular badge + hover tooltip
// ---------------------------------------------------------------------------

/// Hover tooltip panel. It never steals the pointer: while it is hovered it
/// reports the anchor as the hit target, so the tooltip stays open without
/// capturing input. Supports a plain text body or a titled multi-row body.
private final class HoverTooltip : Widget
{
    private dstring _title;
    private dstring[] _rows;
    private Widget _hoverOwner;

    this(Widget hoverOwner)
    {
        _hoverOwner = hoverOwner;
        layoutHints().excludeFromLayout = true;
    }

    void setContent(string title, const(string)[] rows)
    {
        _title = toUTF32(title);
        _rows.length = 0;
        foreach (row; rows)
            _rows ~= toUTF32(row);
        invalidate();
    }

    void setText(string text)
    {
        _title.length = 0;
        _rows.length = 0;
        foreach (line; text.splitLines)
            _rows ~= toUTF32(line);
        invalidate();
    }

    /// Test-only: the tooltip text, one row per line.
    public string textForTesting()
    {
        auto builder = appender!string();
        if (_title.length > 0) builder.put(to!string(_title));
        foreach (row; _rows)
        {
            if (builder.data.length > 0) builder.put("\n");
            builder.put(to!string(row));
        }
        return builder.data;
    }

    override Widget hitTest(Point globalPoint)
    {
        if (!visible() || !enabled()) return null;
        const local = globalToLocal(globalPoint);
        if (!containsLocal(local)) return null;
        return _hoverOwner;
    }

    protected override Size onMeasure(Size available)
    {
        const padH = 14;
        const padV = 12;
        const lineH = 18;
        const width = 272;
        int height = padV * 2;
        if (_title.length > 0) height += lineH + 6;
        height += cast(int) _rows.length * lineH;
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = height;
        return Size(width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        canvas.drawRoundedRect(Rect(0, 0, width, height), 8,
            opencodeElevated, opencodeBorder, 1);
        int y = 12;
        if (_title.length > 0)
        {
            canvas.drawText(Point(14, y), _title, palette.text, 1,
                FontRole.ui, cast(FontFace) palette.uiFont);
            y += 24;
        }
        foreach (row; _rows)
        {
            canvas.drawText(Point(14, y), row, opencodeMuted, 1,
                FontRole.ui, cast(FontFace) palette.uiFont);
            y += 18;
        }
    }
}

/// Split a string into lines (module-level helper used by HoverTooltip).
private string[] splitLines(string text)
{
    string[] lines;
    string current;
    foreach (ch; text)
    {
        if (ch == '\n')
        {
            lines ~= current;
            current = "";
        }
        else if (ch != '\r')
            current ~= ch;
    }
    if (current.length > 0) lines ~= current;
    return lines;
}

/// Reusable hover tooltip anchor: a small "(?)" chip that opens a popup
/// tooltip while hovered. Used in dialogs (e.g. the Legacy tools option).
private final class TooltipAnchor : Widget
{
    void delegate(bool open) onHoverChanged;
    private string _text;
    private bool _hover;

    this(Widget owner)
    {
        _hoverOwner = owner;
        layoutHints().preferredWidth = 18;
        layoutHints().minWidth = 18;
        layoutHints().preferredHeight = 18;
    }

    void setText(string text)
    {
        _text = text;
        invalidate();
    }

    string text() const @safe pure nothrow @nogc { return _text; }

    /// The widget that should report as the hover target so the tooltip stays
    /// open while the pointer moves over it.
    Widget hoverOwner() @safe pure nothrow @nogc { return _hoverOwner; }

    protected override Size onMeasure(Size available)
    {
        layoutHints().preferredWidth = 18;
        layoutHints().preferredHeight = 18;
        return Size(18, 18);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const rect = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRoundedRect(rect, rect.height / 2,
            _hover ? opencodeAccent : opencodeField);
        canvas.drawTextInRect(rect, "?"d,
            _hover ? Color.rgb(255, 255, 255) : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }

    protected override void onMouseEnter()
    {
        _hover = true;
        if (onHoverChanged !is null) onHoverChanged(true);
        invalidate();
    }

    protected override void onMouseLeave()
    {
        _hover = false;
        if (onHoverChanged !is null) onHoverChanged(false);
        invalidate();
    }

    private Widget _hoverOwner;
}

/// CheckBox that surfaces pointer enter/leave so a parent can drive a hover
/// tooltip straight from the control instead of a separate "?" badge.
private final class HoverCheckBox : CheckBox
{
    void delegate(bool hovered) onHoverChanged;

    this(string text = "", bool checked = false)
    {
        super(text, checked);
    }

    protected override void onMouseEnter()
    {
        super.onMouseEnter();
        if (onHoverChanged !is null) onHoverChanged(true);
    }

    protected override void onMouseLeave()
    {
        super.onMouseLeave();
        if (onHoverChanged !is null) onHoverChanged(false);
    }
}

/// Explanation shown when hovering the composer's Thinking toggle.
private immutable string thinkingToggleTooltipText =
    "Controls the model's reasoning effort. On sends " ~
    "reasoning_effort \"high\" so the model thinks longer before " ~
    "answering. Off sends \"none\" on a local server (disabling " ~
    "thinking) or \"low\" on a hosted provider. Models that do not " ~
    "support reasoning_effort ignore it.";

/// Small rectangular context meter in the toolbar. Shows the exact token
/// usage the API reported as a percentage of the model's context window, and
/// opens the hover tooltip with the full breakdown.
private final class ContextUsageBadge : Widget
{
    void delegate(bool open) onHoverChanged;

    private int _prompt = -1;
    private int _completion = -1;
    private int _total = -1;
    private int _limit = 128_000;
    private bool _estimated;

    this()
    {
        layoutHints().preferredWidth = 56;
        layoutHints().minWidth = 56;
        layoutHints().preferredHeight = 22;
    }

    void setModel(string model)
    {
        const limit = contextLimitForModel(model);
        if (limit == _limit) return;
        _limit = limit;
        invalidate();
    }

    void setUsage(int prompt, int completion, int total,
        bool estimated = false)
    {
        if (prompt == _prompt && completion == _completion && total == _total &&
            estimated == _estimated)
            return;
        _prompt = prompt;
        _completion = completion;
        _total = total;
        _estimated = estimated;
        invalidate();
    }

    int promptTokens() const @safe pure nothrow @nogc { return _prompt; }
    int completionTokens() const @safe pure nothrow @nogc { return _completion; }
    int totalTokens() const @safe pure nothrow @nogc { return _total; }
    int limit() const @safe pure nothrow @nogc { return _limit; }
    bool estimated() const @safe pure nothrow @nogc { return _estimated; }

    bool hasUsage() const @safe pure nothrow @nogc
    {
        return _total > 0 && _limit > 0;
    }

    int usagePercent() const
    {
        if (_total <= 0 || _limit <= 0) return 0;
        const long scaled = (cast(long) _total * 100 + _limit - 1) / _limit;
        return scaled >= 100 ? 100 : cast(int) scaled;
    }

    string labelForTesting()
    {
        return hasUsage()
            ? (_estimated ? "~" : "") ~ to!string(usagePercent) ~ "%"
            : "0%";
    }

    protected override Size onMeasure(Size available)
    {
        layoutHints().preferredWidth = 56;
        layoutHints().preferredHeight = 22;
        return Size(56, 22);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        canvas.fillRoundedRect(Rect(0, 0, width, height), height / 2,
            opencodeField);
        if (hasUsage())
        {
            const pct = usagePercent();
            const fillWidth = maxInt(1, (width - 4) * pct / 100);
            canvas.fillRoundedRect(Rect(2, 2, fillWidth, height - 4),
                (height - 4) / 2,
                pct >= 90 ? opencodeKeyMissing : opencodeAccent);
        }
        canvas.drawTextInRect(Rect(0, 0, width, height), toUTF32(labelForTesting),
            hasUsage() ? palette.text : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }

    protected override void onMouseEnter()
    {
        if (onHoverChanged !is null) onHoverChanged(true);
    }

    protected override void onMouseLeave()
    {
        if (onHoverChanged !is null) onHoverChanged(false);
    }
}

// ---------------------------------------------------------------------------
// Conversation work-time badge
// ---------------------------------------------------------------------------

/// A small live stopwatch for the whole conversation: the assistant's
/// accumulated working time across every finished turn on the active branch,
/// plus the turn currently in flight. It ticks while the agent works and holds
/// the total when it is idle, so the chat's overall cost is visible at a glance.
private final class ChatTimerBadge : Widget
{
    private double _seconds = 0.0;
    private bool _running;
    private long _shownSecond = -1;

    this()
    {
        layoutHints().preferredWidth = 104;
        layoutHints().minWidth = 104;
        layoutHints().preferredHeight = 22;
    }

    void setSeconds(double seconds, bool running)
    {
        // Guard the NaN default a double carries in D as well as negatives.
        if (!isFinite(seconds) || seconds < 0) seconds = 0;
        const second = cast(long) seconds;
        // Repaint only when the visible whole-second value or the running state
        // changes, so a 60 fps tick does not repaint the footer every frame.
        if (second == _shownSecond && running == _running) return;
        _seconds = seconds;
        _shownSecond = second;
        _running = running;
        invalidate();
    }

    string labelForTesting() const
    {
        return "Total " ~ formatTurnDuration(_seconds);
    }

    bool runningForTesting() const
    {
        return _running;
    }

    protected override Size onMeasure(Size available)
    {
        layoutHints().preferredWidth = 104;
        layoutHints().preferredHeight = 22;
        return Size(104, 22);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        canvas.fillRoundedRect(Rect(0, 0, width, height), height / 2,
            opencodeField);
        // A tiny clock face (circle + hands) instead of a glyph, so no font or
        // code page can turn it into a missing-character box.
        const cx = 13;
        const cy = height / 2;
        const mark = _running ? opencodeAccent : opencodeMuted;
        canvas.strokeCircle(Point(cx, cy), 5, mark, 1);
        canvas.drawLine(Point(cx, cy), Point(cx, cy - 3), mark, 1);
        canvas.drawLine(Point(cx, cy), Point(cx + 2, cy + 1), mark, 1);
        canvas.drawTextInRect(Rect(22, 0, width - 24, height),
            toUTF32(labelForTesting()), _running ? palette.text : opencodeMuted,
            1, HorizontalAlign.left, VerticalAlign.middle, false);
    }
}

// ---------------------------------------------------------------------------
// Chat input with Enter-to-send
// ---------------------------------------------------------------------------

private final class ChatInput : TextArea
{
    void delegate() onSendRequested;

    this()
    {
        super("");
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.enter && !event.shift())
        {
            if (onSendRequested !is null) onSendRequested();
            return true;
        }
        return super.onKeyDown(event);
    }
}

// ---------------------------------------------------------------------------
// Centered content column
// ---------------------------------------------------------------------------

/// Wraps a single child and centers it horizontally inside a maximum width,
/// matching the upstream opencode `container-3xl` column. The wrapper itself
/// always spans the full pane so scrollbars stay pinned to the pane edge; only
/// the child is capped and inset. The child of a scroll view is laid out
/// directly by the viewport, so publishing hints here is harmless there and
/// lets the same wrapper size a fixed-height composer inside a VBox.
private final class CenteredColumn : Widget
{
    private Widget _content;
    private int _maxWidth;

    this(Widget content, int maxWidth)
    {
        _content = content;
        _maxWidth = maxWidth;
        add(content);
    }

    private int centeredWidth(int total) const @safe pure nothrow @nogc
    {
        return _maxWidth > 0 ? minInt(total, _maxWidth) : total;
    }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        auto measured = _content.measure(Size(centeredWidth(width),
            available.height));
        // The framework may measure with a zero-height viewport before the
        // first layout, and intrinsic measures are clamped to it. Read the
        // child's published hint (like MessageBubble) so the composer keeps its
        // intended height regardless of the provisional available size.
        const childHeight = _content.layoutHints().preferredHeight >= 0 ?
            _content.layoutHints().preferredHeight : measured.height;
        // VBox layout sizes children from hints, not from the intrinsic measure
        // result, so the composer wrapper must publish its height back.
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = childHeight;
        return Size(width, childHeight);
    }

    protected override void onLayout()
    {
        const width = centeredWidth(bounds().width);
        _content.setBounds(Rect(maxInt(0, (bounds().width - width) / 2), 0,
            width, bounds().height));
    }
}

// ---------------------------------------------------------------------------
// Chat composer: bordered prompt panel with a bottom-right send button
// ---------------------------------------------------------------------------

private final class ChatComposer : Widget
{
    private static immutable int pad = 8;
    private static immutable int gap = 6;
    private static immutable int buttonWidth = 40;
    private static immutable int buttonHeight = 30;

    private Widget _field;
    private Widget _send;
    private Widget _controls;

    this(Widget field, Widget send, Widget controls = null)
    {
        _field = field;
        _send = send;
        _controls = controls;
        add(field);
        add(send);
        if (controls !is null) add(controls);
    }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        // Publish the intended height rather than a provisional-clamped one;
        // the first measure can arrive before the window has any bounds.
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = opencodeComposerHeight;
        return Size(width, opencodeComposerHeight);
    }

    protected override void onLayout()
    {
        const width = bounds().width;
        const height = bounds().height;
        const fieldHeight = maxInt(0, height - pad * 2 - buttonHeight - gap);
        _field.setBounds(Rect(pad, pad, maxInt(0, width - pad * 2),
            fieldHeight));
        const bottomY = maxInt(pad, height - pad - buttonHeight);
        _send.setBounds(Rect(maxInt(pad, width - pad - buttonWidth), bottomY,
            buttonWidth, buttonHeight));
        // Model/context/thinking/tools controls live under the text area, left
        // of the send button (upstream opencode's composer footer).
        if (_controls !is null)
            _controls.setBounds(Rect(pad, bottomY,
                maxInt(0, width - pad * 2 - buttonWidth - gap), buttonHeight));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.drawRoundedRect(Rect(0, 0, bounds().width, bounds().height),
            maxInt(8, palette.cornerRadius), palette.fieldBackground,
            palette.border, 1);
    }
}

/// Accent send button: a rounded rectangle with an up arrow (Send) or a square
/// (Stop) while a reply is streaming. Kept a `Button` subclass so the existing
/// `oc-send` lookup and busy-state text contract continue to work.
private final class ChatSendButton : Button
{
    private static immutable int buttonWidth = 40;
    private static immutable int buttonHeight = 30;

    this()
    {
        super("");
        layoutHints().preferredWidth = buttonWidth;
        layoutHints().minWidth = buttonWidth;
        layoutHints().preferredHeight = buttonHeight;
        layoutHints().minHeight = buttonHeight;
        layoutHints().fillCrossAxis = false;
    }

    protected override Size onMeasure(Size available)
    {
        layoutHints().preferredWidth = buttonWidth;
        layoutHints().preferredHeight = buttonHeight;
        return Size(minInt(buttonWidth, available.width),
            minInt(buttonHeight, available.height));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const rect = Rect(0, 0, bounds().width, bounds().height);
        const stopping = text() == "Stop"d;
        const background = stopping
            ? (pressed() ? palette.buttonPressed :
                (hovered() ? palette.buttonHover : palette.border))
            : (pressed() ? palette.accentPressed :
                (hovered() ? palette.accentHover : palette.accent));
        canvas.drawRoundedRect(rect, maxInt(6, palette.cornerRadius - 2),
            background, background.darker(20), 1);
        const white = Color.rgb(255, 255, 255);
        if (stopping)
            canvas.fillRect(Rect((bounds().width - 10) / 2,
                (bounds().height - 10) / 2, 10, 10), white);
        else
            drawIcon(canvas, IconKind.up, Rect((bounds().width - 16) / 2,
                (bounds().height - 16) / 2, 16, 16), white);
    }
}

// ---------------------------------------------------------------------------
// Auto-follow scroll view
// ---------------------------------------------------------------------------

private final class ChatScrollView : ScrollView
{
    bool follow = true;

    // Set by a collapsible widget (tool output / reasoning / tool group) right
    // before a user-driven expand/collapse. The freeze below then holds the
    // content offset across every layout until the block has finished
    // re-measuring, instead of snapping the viewport back to the bottom and
    // shoving the clicked row out of view. A single-layout hold is not enough:
    // an intervening layout (streaming, repaint, onSizeChanged invalidation)
    // can consume it before the real resize lands.
    private static bool _holdPending;
    private int _holdScrollY = -1;
    private int _lastMaxScroll = -1;

    this(Widget content)
    {
        super(content);
    }

    /// Keep the reader's position across the next content re-measure. Call
    /// immediately before applying a user-driven size change (collapse/expand)
    /// so the toggled row stays put instead of the view jumping to the bottom.
    static void holdPositionForNextLayout()
    {
        _holdPending = true;
    }

    protected override void onLayout()
    {
        if (_holdPending)
        {
            // Anchor the offset on the first held layout, then keep restoring it
            // each pass so the collapsed/expanded row stays put. Release only
            // once the content height stops changing (the resize has settled).
            if (_holdScrollY < 0)
            {
                _holdScrollY = scrollY();
                _lastMaxScroll = -1;
            }
            super.onLayout();
            auto max = maxScroll();
            auto target = _holdScrollY;
            if (target < 0) target = 0;
            if (target > max) target = max;
            if (scrollY() != target) setScrollY(target);
            if (_lastMaxScroll == max)
            {
                _holdPending = false;
                _holdScrollY = -1;
                follow = scrollY() >= max - 4;
            }
            else
            {
                _lastMaxScroll = max;
            }
            return;
        }
        super.onLayout();
        if (follow) setScrollY(maxScroll());
    }

    protected override void onScrollChanged()
    {
        // Any user scroll (thumb drag, track click, wheel, keys) moves away
        // from the auto-follow position. Re-engage follow only once the view
        // is back at the bottom; otherwise onLayout keeps snapping the
        // scrollbar back down and the user cannot scroll up at all.
        follow = scrollY() >= maxScroll() - 4;
    }
}

// ---------------------------------------------------------------------------
// Empty-conversation intro overlay
// ---------------------------------------------------------------------------

/// Prompt starters offered on the empty state. Kept short so each pill fits on
/// one line and the whole set packs into a couple of centered rows.
private immutable string[] defaultIntroSuggestions = [
    "Explain this codebase",
    "Find and fix a bug",
    "Write a test",
    "Refactor a file",
    "Summarize the project",
];

/// Shown over the transcript while the active conversation still has no
/// messages: a centered welcome block with tappable prompt suggestions that
/// prefill the composer. It is an overlay child of the scroll view (full
/// viewport bounds, excluded from layout) so it never disturbs message layout,
/// and it is hidden the moment the first bubble appears. The block fades in
/// once, then stays put; that single motion marks the empty state without
/// adding per-frame work to a live transcript.
private final class IntroOverlay : Widget
{
    /// Fired with the suggestion's prompt text when a pill is clicked.
    void delegate(string prompt) onSuggestion;

    private static immutable int margin = 24;
    private static immutable int iconSize = 44;
    private static immutable int pillHeight = 34;
    private static immutable int pillPadH = 14;
    private static immutable int pillGap = 8;
    private static immutable int rowGap = 10;
    private static immutable double fadeSeconds = 0.18;

    private string _title = "What can I help you with?";
    private string _subtitle;
    private string[] _suggestions;
    private double _fade;
    private int _hover = -1;
    // Pill geometry is recorded during paint (like MessageBubble's copy/link
    // targets) so hover and click map a point back to the right suggestion
    // without measuring anything twice.
    private Rect[] _pillRects;
    private string[] _pillLabels;

    void setSubtitle(string value)
    {
        if (_subtitle == value) return;
        _subtitle = value;
        invalidate();
    }

    void setSuggestions(const(string)[] values)
    {
        if (sameLabels(_suggestions, values)) return;
        _suggestions = values.dup;
        _hover = -1;
        invalidate();
    }

    /// Restart the fade-in. Called every time the overlay becomes visible again
    /// so the welcome animates in for each new conversation, not just at start.
    void replay()
    {
        _fade = 0.0;
        _hover = -1;
        invalidate();
    }

    /// Test-only: current fade progress (0 = transparent, 1 = fully shown).
    public double fadeForTesting() const { return _fade; }

    /// Test-only: the suggestion labels rendered as pills.
    public string[] suggestionsForTesting() const { return _suggestions.dup; }

    /// Test-only: bounds of the pill at `index` (empty before the first paint).
    public Rect suggestionBoundsForTesting(int index) const
    {
        return index >= 0 && index < cast(int) _pillRects.length
            ? _pillRects[index] : Rect.init;
    }

    /// Test-only: click the pill at `index` exactly as a left click would.
    public bool clickSuggestionForTesting(int index)
    {
        if (index < 0 || index >= cast(int) _pillLabels.length) return false;
        if (onSuggestion is null) return false;
        onSuggestion(_pillLabels[index]);
        return true;
    }

    private static bool sameLabels(const(string)[] a, const(string)[] b)
    {
        if (a.length != b.length) return false;
        foreach (index; 0 .. a.length)
            if (a[index] != b[index]) return false;
        return true;
    }

    private TextLayout layoutFor(const(dchar)[] text, int pixelSize,
        int maxWidth = 0, bool wrap = false)
    {
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast(FontFace) theme().uiFont;
        options.pixelSize = pixelSize;
        options.maxWidth = maxWidth;
        options.wrap = wrap;
        return fontSystem().textEngine.layout(text, options);
    }

    private Color faded(Color color) const
    {
        return color.withAlpha(cast(int) (color.a * _fade));
    }

    private int pillAt(Point position) const
    {
        foreach (index, rect; _pillRects)
            if (rect.contains(position)) return cast(int) index;
        return -1;
    }

    protected override Size onMeasure(Size available)
    {
        // The overlay fills its parent and takes its bounds from the layout
        // pass; it never contributes an intrinsic size.
        return available;
    }

    protected override void onTick(double deltaSeconds)
    {
        if (_fade >= 1.0) return;
        _fade += deltaSeconds / fadeSeconds;
        if (_fade >= 1.0) _fade = 1.0;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;

        const contentWidth = maxInt(160,
            minInt(width - 2 * margin, opencodeContentMaxWidth));
        auto titleLayout = layoutFor(toUTF32(_title), opencodeFontDisplay);
        TextLayout subtitleLayout;
        if (_subtitle.length > 0)
            // The workspace path can be long; wrap it inside the content column
            // rather than letting it run past the pane edges.
            subtitleLayout = layoutFor(toUTF32(_subtitle), opencodeFontBase,
                contentWidth, true);
        const titleH = cast(int) titleLayout.measuredSize().height;
        const subtitleH = subtitleLayout is null ? 0 :
            cast(int) subtitleLayout.measuredSize().height;

        int[] pillWidths;
        foreach (suggestion; _suggestions)
        {
            auto layout = layoutFor(toUTF32(suggestion), opencodeFontBase);
            // A single suggestion wider than the column is capped so its pill
            // still fits; the label is then elided at paint time.
            pillWidths ~= minInt(contentWidth,
                cast(int) layout.measuredSize().width + 2 * pillPadH);
        }

        // Pack the pills into centered rows that fit the content column.
        struct PillRow { size_t first; size_t count; int width; }
        PillRow[] rows;
        size_t cursor;
        while (cursor < _suggestions.length)
        {
            int rowWidth;
            size_t count;
            while (cursor + count < _suggestions.length)
            {
                const extra = pillWidths[cursor + count] +
                    (count == 0 ? 0 : pillGap);
                if (count > 0 && rowWidth + extra > contentWidth) break;
                rowWidth += extra;
                ++count;
            }
            if (count == 0)
            {
                count = 1;
                rowWidth = pillWidths[cursor];
            }
            rows ~= PillRow(cursor, count, rowWidth);
            cursor += count;
        }

        int pillsH;
        if (rows.length > 0)
            pillsH = cast(int) rows.length * pillHeight +
                rowGap * (cast(int) rows.length - 1);

        int block = iconSize + 18 + titleH + 8 + subtitleH;
        if (rows.length > 0) block += 26 + pillsH;
        int y = maxInt(24, (height - block) / 2 - 16);
        const centerX = width / 2;

        drawIcon(canvas, IconKind.terminal,
            Rect(centerX - iconSize / 2, y, iconSize, iconSize),
            faded(opencodeAccent));
        y += iconSize + 18;

        const titleX = maxInt(0,
            (width - cast(int) titleLayout.measuredSize().width) / 2);
        canvas.drawLayout(Point(titleX, y), titleLayout, faded(opencodeText));
        y += titleH + 8;

        if (subtitleH > 0)
        {
            const subtitleX = maxInt(0,
                (width - cast(int) subtitleLayout.measuredSize().width) / 2);
            canvas.drawLayout(Point(subtitleX, y), subtitleLayout,
                faded(opencodeMuted));
            y += subtitleH;
        }

        _pillRects.length = 0;
        _pillLabels.length = 0;
        if (rows.length == 0) return;
        y += 26;
        foreach (row; rows)
        {
            int x = maxInt(0, (width - row.width) / 2);
            foreach (offset; 0 .. row.count)
            {
                const index = row.first + offset;
                const rect = Rect(x, y, pillWidths[index], pillHeight);
                const hovered = cast(int) index == _hover;
                canvas.drawRoundedRect(rect, pillHeight / 2,
                    faded(hovered ? opencodeSelection : opencodeField),
                    faded(hovered ? opencodeAccent : opencodeBorder), 1);
                // Draw through the pill's inner rect so a capped (too-wide)
                // label elides instead of spilling past the rounded edge.
                canvas.drawTextInRect(
                    Rect(x + pillPadH, y, maxInt(1, pillWidths[index] - 2 * pillPadH),
                        pillHeight),
                    toUTF32(_suggestions[index]),
                    faded(hovered ? opencodeText : opencodeMuted), 1,
                    HorizontalAlign.center, VerticalAlign.middle, true,
                    FontRole.ui, cast(FontFace) theme().uiFont);
                _pillRects ~= rect;
                _pillLabels ~= _suggestions[index];
                x += pillWidths[index] + pillGap;
            }
            y += pillHeight + rowGap;
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const next = pillAt(event.position);
        if (next != _hover)
        {
            _hover = next;
            setCursor(next >= 0 ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        return false;
    }

    protected override void onMouseLeave()
    {
        if (_hover == -1) return;
        _hover = -1;
        invalidate();
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        const index = pillAt(event.position);
        if (index < 0 || onSuggestion is null) return false;
        onSuggestion(_pillLabels[index]);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Session sidebar list (Pro: context menu, Delete key)
// ---------------------------------------------------------------------------

public final class SessionListView : ListView
{
    void delegate(int index, Point globalPosition) onContextMenuRequested;
    void delegate(int index) onDeleteRequested;

    private int _hoverRow = -1;
    // List indices whose conversation is actively working. A small pulsing
    // bar is drawn before their title while `_activityAnimating` drives it.
    private int[] _activityRows;
    private double _activityElapsed;
    private bool _activityAnimating;

    this()
    {
        super();
        // Butt the scrollbar against the split-pane divider so no panel band
        // shows between the conversation list and the width handle.
        setScrollbarInset(0);
    }

    /// Mark which rows are busy. Called whenever the live turn changes or the
    /// visible rows are rebuilt; the list only repaints when the set changes.
    void setActivityRows(int[] rows)
    {
        if (_activityRows == rows) return;
        if (rows.length > 0 && !_activityAnimating) _activityElapsed = 0.0;
        _activityRows = rows;
        _activityAnimating = rows.length > 0;
        invalidate();
    }

    string activityRowsForTesting() const
    {
        auto out_ = appender!string();
        foreach (i, row; _activityRows)
        {
            if (i > 0) out_.put(",");
            out_.put(to!string(row));
        }
        return out_.data;
    }

    private int activityPulseStep() const
    {
        return cast(int) (_activityElapsed * 4) % 4;
    }

    // Animate the busy bars. Repaints only when the visible pulse step changes
    // so an idle list costs nothing.
    protected override void onTick(double deltaSeconds)
    {
        if (!_activityAnimating) return;
        const before = activityPulseStep();
        _activityElapsed += deltaSeconds;
        if (activityPulseStep() != before) invalidate();
    }

    // Single-line conversation rows: a highlighted capsule for the active chat,
    // the title, and a right-aligned last-activity time. No repeated model name,
    // message count, or per-row icon (every row shared the same one).
    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const rowHeight = rowHeight();
        if (rowHeight <= 0) return;

        auto content = canvas.clipped(Rect(0, 0, width, height));
        const offset = scrollOffset();
        const selected = selectedIndex();
        const count = cast(int) items().length;
        const first = offset / rowHeight;
        const last = clampInt((offset + height) / rowHeight + 1, 0, count);

        foreach (index; first .. last)
        {
            const item = items()[cast(size_t) index];
            const y = index * rowHeight - offset;
            const row = Rect(2, y + 1, maxInt(0, width - 4), rowHeight - 2);

            if (index == selected)
            {
                content.fillRoundedRect(row, 6, opencodeSelection);
                content.fillRect(Rect(2, y + 1, 3, rowHeight - 2), opencodeAccent);
            }
            else if (index == _hoverRow)
                content.fillRoundedRect(row, 6, opencodePressed);

            // A small pulsing bar before the title marks a conversation that is
            // actively working (model thinking, running tools, streaming).
            if (_activityAnimating && _activityRows.canFind(index))
            {
                static immutable int[4] pulseAlphas = [70, 130, 210, 130];
                const bar = Rect(8, y + (rowHeight - 10) / 2, 3, 10);
                content.fillRect(bar,
                    opencodeAccent.withAlpha(pulseAlphas[activityPulseStep()]));
            }

            // Leave a clear gutter between the right-aligned time and the
            // scrollbar, which sits flush against the panel edge
            // (setScrollbarInset(0) in the constructor).
            enum rightPad = 18;
            enum titleGap = 10;
            int trailWidth = 0;
            if (item.secondary.length > 0)
            {
                trailWidth = content.measureText(item.secondary, 1).width;
                content.drawTextInRect(
                    Rect(width - trailWidth - rightPad, y, trailWidth, rowHeight),
                    item.secondary, opencodeMuted, 1,
                    HorizontalAlign.right, VerticalAlign.middle, true);
            }

            const titleColor = item.disabled || item.dimmed ? opencodeMuted
                : (index == selected ? opencodeText : opencodeText.withAlpha(230));
            const textLeft = 14;
            const textWidth = maxInt(0, width - textLeft -
                (trailWidth > 0 ? trailWidth + rightPad + titleGap : rightPad));
            content.drawTextInRect(Rect(textLeft, y, textWidth, rowHeight),
                item.text, titleColor, theme().fontScale,
                HorizontalAlign.left, VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        setCursor(CursorKind.arrow);
        const next = indexAt(event.position);
        if (next != _hoverRow)
        {
            _hoverRow = next;
            invalidate();
        }
        return true;
    }

    override void onMouseLeave()
    {
        _hoverRow = -1;
        setCursor(CursorKind.arrow);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            const row = indexAt(event.position);
            if (row >= 0 && onContextMenuRequested !is null)
                onContextMenuRequested(row, localToGlobal(event.position));
            return true;
        }
        return super.onMouseDown(event);
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.deleteKey && selectedIndex() >= 0)
        {
            if (onDeleteRequested !is null) onDeleteRequested(selectedIndex());
            return true;
        }
        return super.onKeyDown(event);
    }
}

// ---------------------------------------------------------------------------
// Project rail: a stack of rounded rectangles, one per project
// ---------------------------------------------------------------------------

public final class ProjectListView : ListView
{
    void delegate(int index, Point globalPosition) onContextMenuRequested;

    private int _hoverRow = -1;

    private static dchar upperInitial(dstring text)
    {
        if (text.length == 0) return '?';
        uint code = text[0];
        if (code >= 'a' && code <= 'z') code -= 32;
        return cast(dchar) code;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const rowHeight = rowHeight();
        if (rowHeight <= 0) return;

        auto content = canvas.clipped(Rect(0, 0, width, height));
        const offset = scrollOffset();
        const selected = selectedIndex();
        const count = cast(int) items().length;
        const first = offset / rowHeight;
        const last = clampInt((offset + height) / rowHeight + 1, 0, count);

        foreach (index; first .. last)
        {
            const item = items()[cast(size_t) index];
            const y = index * rowHeight - offset;
            const tile = Rect(4, y + 3, maxInt(0, width - 8), rowHeight - 6);
            const active = index == selected;

            content.fillRoundedRect(tile, 8, active ? opencodeSelection
                : (index == _hoverRow ? opencodeField : opencodeElevated));
            if (active)
                content.drawRoundedRect(tile, 8, Color.rgba(0, 0, 0, 0),
                    opencodeAccent, 1);

            const badge = Rect(tile.x + 7, tile.y + (tile.height - 22) / 2,
                22, 22);
            content.fillRoundedRect(badge, 6,
                opencodeAccent.withAlpha(active ? 220 : 95));
            content.drawTextInRect(badge, [upperInitial(item.text)],
                Color.rgb(255, 255, 255), 1,
                HorizontalAlign.center, VerticalAlign.middle, true);

            const textLeft = badge.right() + 8;
            const textWidth = maxInt(0, tile.right() - textLeft - 8);
            const titleColor = item.disabled || item.dimmed ? opencodeMuted
                : (active ? opencodeText : opencodeText.withAlpha(220));
            content.drawTextInRect(Rect(textLeft, tile.y, textWidth, tile.height),
                item.text, titleColor, theme().fontScale,
                HorizontalAlign.left, VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        setCursor(CursorKind.arrow);
        const next = indexAt(event.position);
        if (next != _hoverRow)
        {
            _hoverRow = next;
            invalidate();
        }
        return true;
    }

    override void onMouseLeave()
    {
        _hoverRow = -1;
        setCursor(CursorKind.arrow);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            const row = indexAt(event.position);
            if (row >= 0 && onContextMenuRequested !is null)
                onContextMenuRequested(row, localToGlobal(event.position));
            return true;
        }
        return super.onMouseDown(event);
    }
}

// ---------------------------------------------------------------------------
// Main root
// ---------------------------------------------------------------------------

/// All mutable execution state owned by one conversation. The root temporarily
/// loads one of these into its existing event handlers, then saves it back.
/// This keeps the mature streaming/tool code intact while allowing every chat
/// to have an independent client, request, tool queue, watchdog, and Stop token.
private final class ConversationRuntime
{
    OpenCodeClient client;
    ToolCancellation cancellation;
    OpenCodeEvent[] eventScratch;
    ulong activeRequestId;
    int activeRequestSession = -1;
    bool batchingToolResults;
    bool toolTranscriptDirty;
    OpenCodeToolCall[] pendingToolCalls;
    int pendingToolResults;
    OpenCodeToolCall[] liveToolCalls;
    OpenCodeToolCall[] preparingToolCalls;
    bool toolContinuationPaused;
    string lastToolSignature;
    int lastToolRepeatCount;
    string lastFailureSignature;
    int lastFailureRepeatCount;
    string pendingProgressGuidance;
    long liveOutputBytes;
    long liveOutputTokens;
    int liveTokenRateTenths;
    long tokenRateBaseTokens;
    MonoTime tokenRateStartedAt;
    bool tokenRateStarted;
    int liveTotalTokens;
    bool suppressDoneStatus;
    MessageBubble streamBubble;
    ActivityRow activityRow;
    MonoTime chatStartedAt;
    bool receivedFirstDelta;
    int lastColdStartSeconds = -1;
    MonoTime turnStartedAt;
    string turnUserId;
    int turnSessionIndex = -1;
    bool turnTiming;
    bool turnCancelled;
    bool stopPending;
    MonoTime stopRequestedAt;
    bool turnInFlight;

    this(string baseUrl, string apiKey)
    {
        client = new OpenCodeClient(baseUrl, apiKey);
        cancellation = new ToolCancellation();
    }

    bool busy()
    {
        return stopPending || turnInFlight || turnTiming || client.busy() ||
            pendingToolCalls.length > 0 || pendingToolResults > 0;
    }
}

public final class OpenCodeRoot : VBox
{
    private GuiWindow _window;
    private OpenCodeClient _client;
    private ConversationRuntime[string] _conversationRuntimes;
    private string _loadedRuntimeId;
    private ToolCancellation _toolCancellation;
    private int _processingRuntimeSession = -1;
    private Settings _settings;
    private ChatSession[] _sessions;
    private int _current = -1;
    // Rebuilding every bubble in a runaway transcript can allocate hundreds of
    // megabytes and was the trigger shared by the recent layout/markdown access
    // violations. Keep the full graph in storage, but materialize it in pages.
    private size_t _visibleMessageLimit = messageHistoryPageSize;
    private static immutable size_t messageHistoryPageSize = 120;
    private string[] _models = defaultModels.dup;

    private ProjectState _projectState;
    private ProjectListView _projectRail;
    private VBox _projectsColumn;
    private Label _projectsHeader;
    private Button _newProjectButton;
    private IconButton _railToggle;
    private OpenCodeTitleBar _titleBar;
    private TitleBarSnapPreview _snapPreview;
    private SplitPane _sessionsSplit;
    private Label _sessionsHeader;
    private IconButton _openFolderButton;
    private Label _sessionsPath;
    private VBox _sessionsHeaderColumn;
    private Button _newChatButton;
    private bool _sessionsRatioDirty;

    private SessionListView _sessionList;
    private ChatScrollView _messagesScroll;
    private VBox _messageColumn;
    private IntroOverlay _introOverlay;
    private ChatInput _input;
    private ChatSendButton _sendButton;
    private ChatComposer _composer;
    private Button _modelButton;
    private CheckBox _thinkingBox;
    private CheckBox _toolsBox;
    private Label _keyBadge;
    private Label _status;
    private TextField _filterField;
    private int[] _sessionIndices;
    // Conversation ids pinned to the top of the sidebar. Persisted in
    // pins.json so pins survive restarts without touching session state.
    private string[] _pinnedSessionIds;
    private string _filterText;
    private string _lastUsageText;
    // Live output-token counter for the in-flight reply. The provider usually
    // reports exact `usage` only at/near the end of the stream, so the UI counts
    // a local estimate from the streamed bytes and swaps in the provider's exact
    // completion count when it arrives. Rendered on the live reply's Thinking
    // header and kept after the turn completes.
    private long _liveOutputBytes;
    private long _liveOutputTokens;
    private int _liveTokenRateTenths;
    private long _tokenRateBaseTokens;
    private MonoTime _tokenRateStartedAt;
    private bool _tokenRateStarted;
    private int _liveTotalTokens;
    private bool _suppressDoneStatus;
    // Index (into the current session's `messages`) of a user prompt the user
    // chose to edit. Send replaces it with a sibling branch so the original
    // run survives; -1 when no edit is pending.
    private int _editMessageIndex = -1;

    private MessageBubble _streamBubble;
    // The live "what is going on" row pinned to the end of the transcript while
    // the assistant works. Retained across rebuilds so its pulse and elapsed
    // clock keep running; the column re-adds it whenever a label is set.
    private ActivityRow _activityRow;
    // UI-only expand state, keyed by the globally-unique message id. The
    // transcript is rebuilt from scratch as the reply and its tools stream, so
    // without this a tool output or reasoning block the user opened would snap
    // shut again on the next rebuild (looks like content randomly vanishing).
    private bool[string] _collapsedTool;
    private bool[string] _thinkingCollapsed;
    // Expand state of a turn's action group, keyed independently of the tool
    // bubbles (which keep their own). Without it an expanded group would collapse
    // on every streamed tool-argument rebuild.
    private bool[string] _groupCollapsed;
    private PopupOverlay _activePopup;
    // Settings-dialog input fields, kept while the dialog is open so a chosen
    // provider preset can fill them and the smoke test can read them back.
    // Null when the dialog is closed.
    private TextField _settingsBaseField;
    private TextField _settingsKeyField;
    private TextField _settingsModelField;
    private Button _settingsProviderButton;
    // Recycled by OpenCodeClient.drain. Keeping it on the root makes event
    // delivery allocation-free after the queue reaches its normal capacity.
    private OpenCodeEvent[] _eventScratch;
    private ulong _nextRequestId;
    private ulong _activeRequestId;
    private int _activeRequestSession = -1;
    // Tool results often arrive together after a parallel read lane. Defer the
    // expensive full transcript reconstruction until the drained batch ends.
    private bool _batchingToolResults;
    private bool _toolTranscriptDirty;

    // Tool loop: the model may request tool calls, the app executes them, and
    // the enriched history is re-sent until the model answers with text.
    private OpenCodeToolCall[] _pendingToolCalls;
    private int _pendingToolResults;
    // The subset of `_pendingToolCalls` that has not reported yet, used to paint
    // the live "Exploring" context row while tools are still running.
    private OpenCodeToolCall[] _liveToolCalls;
    // Tool calls whose arguments the model is still generating (the stream has
    // announced their names but not finished). Shown as in-progress rows so a
    // large payload (a whole file for `write`) does not look like a stall.
    private OpenCodeToolCall[] _preparingToolCalls;
    private bool _toolContinuationPaused; // test-only: hold the loop after results

    // Repetition is a signal for guidance, not permission to reject a tool.
    // The requested call still runs; after its result is recorded, a hidden
    // progress note asks the model to explain what changed or vary its approach.
    private string _lastToolSignature;
    private int _lastToolRepeatCount;
    private static immutable int repeatGuidanceThreshold = 3;

    // Progress guidance: a model can also get stuck retrying a
    // failing command with slightly different arguments (so the exact-call
    // signature above never matches). Track the last failure's signature
    // (tool name + first line of output); when the SAME failure repeats, the
    // model may not be making progress. A success clears it; repeated failures
    // still execute and receive a hidden suggestion to change approach.
    private string _lastFailureSignature;
    private int _lastFailureRepeatCount;
    private string _pendingProgressGuidance;
    private static immutable int failureGuidanceThreshold = 3;
    // Successful context calls are not automatically useful progress. Count
    // exploration across the whole user request (a mutation does not buy a new
    // search budget), then force the model to act on the evidence already read.
    // This catches varied read/grep loops and prevents trivial edits from being
    // used to reset the guard.
    private static immutable int explorationCheckpointCalls = 10;
    // Bound read-only fan-out. A model can emit dozens of independent searches;
    // one OS thread per call hurts throughput and responsiveness on laptops.
    private static immutable size_t maxParallelToolWorkers = 4;

    // Session persistence is intentionally off the mutation hot path. Bursts of
    // tool results collapse to one save, while shutdown/restart still flushes.
    private bool _stateDirty;
    private MonoTime _persistDue;
    private static immutable int persistDebounceMs = 150;

    // Backend-neutral lifecycle stream. sessions.json remains the compatibility
    // snapshot while this append-only journal becomes the durable seam between
    // the UI and whichever engine (Aurora, Codex, or another provider) runs a
    // thread. Journal failure must never make the chat unusable.
    private AgentRuntime _runtime;
    private bool _runtimeErrorReported;

    private ContextUsageBadge _usageBadge;
    // The context meter tracks model-visible input, never cumulative
    // input+output usage. Provider usage is optional on OpenAI-compatible
    // streaming endpoints, so cache a full-request estimate per conversation.
    private int[string] _estimatedContextTokens;
    private int[string] _reportedContextTokens;
    private int[string] _reportedCompletionTokens;
    private bool[string] _contextWasCompacted;
    // A newly submitted request is newer than any usage persisted on an older
    // assistant reply. Keep showing its estimate until this request supplies
    // an exact total of its own.
    private bool[string] _preferEstimatedContext;
    private HoverTooltip _usageTooltip;
    private bool _usageTooltipOpen;
    // Payload of the most recent message "Copy" context-menu action; retained
    // so tests can verify what a Copy would put on the clipboard.
    private string _lastMessageCopy;
    // Hover-intent delay so the tooltip does not flash open just because the
    // pointer swept across the badge on its way to the send button.
    private bool _usageTooltipPending;
    private double _usageTooltipHoverSeconds;
    private static immutable double usageTooltipDelaySeconds = 0.45;

    // Generic hover tooltip (used for dialog options such as Legacy tools).
    private TooltipAnchor _legacyTooltipAnchor;
    private HoverTooltip _legacyTooltip;
    private bool _legacyTooltipOpen;

    // Hover tooltip for the composer's Thinking toggle, explaining what it does.
    private TooltipAnchor _thinkingTooltipAnchor;
    private HoverTooltip _thinkingTooltip;
    private bool _thinkingTooltipOpen;

    private MonoTime _chatStartedAt;
    private bool _receivedFirstDelta;
    private int _lastColdStartSeconds = -1;

    // Per-user-turn clock for the action-group header ("Worked for 0m 3s"). The
    // clock spans the whole turn — every tool-continuation round re-enters the
    // request path, but only the user-initiated request starts it. Completed
    // durations are kept per turn (keyed by the id of the user message that
    // opened it) so every finished turn in the session shows its time for the
    // rest of the run.
    private MonoTime _turnStartedAt;
    private string _turnUserId;
    private int _turnSessionIndex = -1;
    private bool _turnTiming;
    /// Set when the user stops a turn so late tool results cannot restart it.
    private bool _turnCancelled;
    // Logical cancellation is immediate, but WinINet may need a short moment to
    // unwind its worker after the request handle is closed. During that gap the
    // transcript is already stopped and the composer cannot start a conflicting
    // request on the same client.
    private bool _stopPending;
    private MonoTime _stopRequestedAt;
    private static immutable long stopDetachTimeoutMs = 2_000;
    private double[string] _turnDurations;
    // Long model reasoning is not a failure. Network/HTTP errors are surfaced by
    // the client and the user retains an explicit Stop action; the UI never
    // cancels a healthy request merely because no visible token arrived within
    // an arbitrary wall-clock interval.

    // Live "how long has this chat taken" stopwatch in the composer footer. The
    // total is the sum of every finished turn's `workedSeconds` on the active
    // branch plus the turn in flight; `_timerBadgeAccum` throttles the recompute
    // to a few times a second instead of every frame.
    private ChatTimerBadge _timerBadge;
    private double _timerBadgeAccum = 0.0;
    private long _lastTimerTotal = -1;
    private bool _lastTimerRunning;

    // Pro: the "Worked for …" completion separator is still fragile (its
    // appearance depends on turn-timing key matches and finishing on a prose
    // reply), so it is opt-in via `Settings.showWorkedFor` and off by default.

    // Rebuild: compile the package with DUB and relaunch the app. A detached
    // helper does the work after this window closes (see auroraopencode.rebuild);
    // the pending flag keeps the transcript live until the helper is started.
    private bool _rebuildPending;

    private ConversationRuntime runtimeForSession(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return null;
        const id = _sessions[sessionIndex].id;
        if (auto existing = id in _conversationRuntimes)
            return *existing;
        auto created = new ConversationRuntime(_settings.baseUrl,
            _settings.apiKey);
        // The headless harness can pause automatic continuations globally;
        // carry that test mode into chats created afterward.
        created.toolContinuationPaused = _toolContinuationPaused;
        _conversationRuntimes[id] = created;
        return created;
    }

    /// Persist the handler scratch fields into the conversation currently
    /// loaded in the root. This is deliberately mechanical: the event handlers
    /// remain single-context code, while onTick swaps contexts between queues.
    private void saveLoadedRuntime()
    {
        if (_loadedRuntimeId.length == 0) return;
        auto found = _loadedRuntimeId in _conversationRuntimes;
        if (found is null) return;
        auto rt = *found;
        rt.client = _client;
        rt.cancellation = _toolCancellation;
        rt.eventScratch = _eventScratch;
        rt.activeRequestId = _activeRequestId;
        rt.activeRequestSession = _activeRequestSession;
        rt.batchingToolResults = _batchingToolResults;
        rt.toolTranscriptDirty = _toolTranscriptDirty;
        rt.pendingToolCalls = _pendingToolCalls;
        rt.pendingToolResults = _pendingToolResults;
        rt.liveToolCalls = _liveToolCalls;
        rt.preparingToolCalls = _preparingToolCalls;
        rt.toolContinuationPaused = _toolContinuationPaused;
        rt.lastToolSignature = _lastToolSignature;
        rt.lastToolRepeatCount = _lastToolRepeatCount;
        rt.lastFailureSignature = _lastFailureSignature;
        rt.lastFailureRepeatCount = _lastFailureRepeatCount;
        rt.pendingProgressGuidance = _pendingProgressGuidance;
        rt.liveOutputBytes = _liveOutputBytes;
        rt.liveOutputTokens = _liveOutputTokens;
        rt.liveTokenRateTenths = _liveTokenRateTenths;
        rt.tokenRateBaseTokens = _tokenRateBaseTokens;
        rt.tokenRateStartedAt = _tokenRateStartedAt;
        rt.tokenRateStarted = _tokenRateStarted;
        rt.liveTotalTokens = _liveTotalTokens;
        rt.suppressDoneStatus = _suppressDoneStatus;
        rt.streamBubble = _streamBubble;
        rt.activityRow = _activityRow;
        rt.chatStartedAt = _chatStartedAt;
        rt.receivedFirstDelta = _receivedFirstDelta;
        rt.lastColdStartSeconds = _lastColdStartSeconds;
        rt.turnStartedAt = _turnStartedAt;
        rt.turnUserId = _turnUserId;
        rt.turnSessionIndex = _turnSessionIndex;
        rt.turnTiming = _turnTiming;
        rt.turnCancelled = _turnCancelled;
        rt.stopPending = _stopPending;
        rt.stopRequestedAt = _stopRequestedAt;
        rt.turnInFlight = _turnInFlight;
    }

    private void loadRuntime(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        const id = _sessions[sessionIndex].id;
        if (_loadedRuntimeId == id) return;
        saveLoadedRuntime();
        auto rt = runtimeForSession(sessionIndex);
        _loadedRuntimeId = id;
        _client = rt.client;
        _toolCancellation = rt.cancellation;
        _eventScratch = rt.eventScratch;
        _activeRequestId = rt.activeRequestId;
        _activeRequestSession = rt.activeRequestSession;
        _batchingToolResults = rt.batchingToolResults;
        _toolTranscriptDirty = rt.toolTranscriptDirty;
        _pendingToolCalls = rt.pendingToolCalls;
        _pendingToolResults = rt.pendingToolResults;
        _liveToolCalls = rt.liveToolCalls;
        _preparingToolCalls = rt.preparingToolCalls;
        _toolContinuationPaused = rt.toolContinuationPaused;
        _lastToolSignature = rt.lastToolSignature;
        _lastToolRepeatCount = rt.lastToolRepeatCount;
        _lastFailureSignature = rt.lastFailureSignature;
        _lastFailureRepeatCount = rt.lastFailureRepeatCount;
        _pendingProgressGuidance = rt.pendingProgressGuidance;
        _liveOutputBytes = rt.liveOutputBytes;
        _liveOutputTokens = rt.liveOutputTokens;
        _liveTokenRateTenths = rt.liveTokenRateTenths;
        _tokenRateBaseTokens = rt.tokenRateBaseTokens;
        _tokenRateStartedAt = rt.tokenRateStartedAt;
        _tokenRateStarted = rt.tokenRateStarted;
        _liveTotalTokens = rt.liveTotalTokens;
        _suppressDoneStatus = rt.suppressDoneStatus;
        _streamBubble = rt.streamBubble;
        _activityRow = rt.activityRow;
        _chatStartedAt = rt.chatStartedAt;
        _receivedFirstDelta = rt.receivedFirstDelta;
        _lastColdStartSeconds = rt.lastColdStartSeconds;
        _turnStartedAt = rt.turnStartedAt;
        _turnUserId = rt.turnUserId;
        _turnSessionIndex = rt.turnSessionIndex;
        _turnTiming = rt.turnTiming;
        _turnCancelled = rt.turnCancelled;
        _stopPending = rt.stopPending;
        _stopRequestedAt = rt.stopRequestedAt;
        _turnInFlight = rt.turnInFlight;
    }

    private void closeRuntimeClients()
    {
        saveLoadedRuntime();
        if (_conversationRuntimes.length == 0 && _client !is null)
            _client.closeSession();
        foreach (rt; _conversationRuntimes)
            rt.client.closeSession();
    }

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        setLogDirectory(buildPath(opencodeStateDirectory(), "logs"));
        _runtime = new DurableAgentRuntime(buildPath(opencodeStateDirectory(),
            "runtime-events.jsonl"));
        _settings = loadSettings();
        _projectState = loadProjects();
        migrateWorkspaceIntoProjects();
        foreach (project; _projectState.projects)
            ensureProjectDirectory(project);
        buildUi();
        updateProjectRail();
        restoreSessions();
        syncCurrentToActiveProject();
        if (_current >= 0)
            loadRuntime(_current);
        else
        {
            _client = new OpenCodeClient(_settings.baseUrl, _settings.apiKey);
            _toolCancellation = new ToolCancellation();
        }
        // The restored selection is applied before the first layout. Revealing
        // it at that point would measure against a zero-height viewport and
        // seed the list's scroll offset at the bottom.
        updateSessionList(false);
        updateSessionsHeader();
        updateKeyBadge();
        updateSendButton();
        _client.fetchModels();
        _input.requestFocus();
        prepareResumeAfterCrash();
    }

    // -- resume after an unexpected shutdown ------------------------------

    /// Ticks to wait after startup before continuing, so the restored
    /// conversation has been laid out before it is extended.
    private static immutable int resumeDelayTicks = 3;

    private int _resumeCountdown;
    private string _resumePrompt;

    private static string activeTurnMarkerPath()
    {
        return buildPath(opencodeStateDirectory(), "turn-active");
    }

    /// Distinguish a crash during agent work from an unrelated idle UI crash.
    /// The supervisor resumes only when this marker survives an interrupted
    /// turn, avoiding an unsolicited API request after every abnormal exit.
    private static void setTurnActiveMarker(bool active, string threadId = "")
    {
        const path = activeTurnMarkerPath();
        if (active)
        {
            try write(path, threadId.length > 0 ? threadId ~ "\n" : "active\n");
            catch (Exception error)
                logError("could not mark active turn: " ~ error.msg);
        }
        else if (exists(path))
        {
            try fileRemove(path);
            catch (Exception) {}
        }
    }

    /**
     * Continue the conversation after an unexpected shutdown.
     *
     * The app cannot detect its own crash - the deaths that matter bypass the
     * exception filter entirely, so nothing in-process runs - and so the
     * supervisor records the event for the next start to find. When that record
     * is present, the conversation is reopened, a note explaining how the
     * process ended is added to it, and the request is resumed, so a crash
     * costs a delay rather than the turn.
     */
    private void prepareResumeAfterCrash()
    {
        const path = buildPath(opencodeStateDirectory(), "restart-resume.json");
        if (!exists(path)) return;
        string cause;
        try
        {
            auto value = parseJSON(readText(path));
            if (auto field = "cause" in value.object)
                cause = field.str;
        }
        catch (Exception error)
            logError("resume note unreadable: " ~ error.msg);
        // Consumed once: a single crash must not replay on every later launch.
        try fileRemove(path);
        catch (Exception) {}
        if (_current < 0)
        {
            logInfo("resume skipped: no conversation to continue");
            return;
        }
        // Prefer the exact thread recorded when the turn began instead of the
        // last sidebar selection saved by an unrelated UI update.
        try
        {
            const activeId = readText(activeTurnMarkerPath()).strip();
            if (activeId.length > 0 && activeId != "active")
                foreach (i, session; _sessions)
                    if (session.id == activeId)
                    {
                        _current = cast(int) i;
                        loadRuntime(_current);
                        break;
                    }
        }
        catch (Exception) {}
        _resumePrompt = "The application closed unexpectedly (" ~
            (cause.length > 0 ? cause : "cause unknown") ~
            "). Continue the durable objective and checklist from where you " ~
            "left off. Apply any queued guidance before claiming completion.";
        _resumeCountdown = resumeDelayTicks;
        logInfo("resume queued for the restored conversation");
    }

    /// Test-only / shutdown hook: release the shared network session.
    public void shutdownClient()
    {
        // Persist on the way out regardless of the debounce flag: a reply that
        // arrived moments before the window closed is otherwise lost, which is
        // why the last message could vanish across a restart.
        persistState();
        closeRuntimeClients();
    }

    /// Test-only: whether a rebuild has been requested and the window is about
    /// to close for the rebuild helper.
    public bool rebuildPendingForTesting() const
    {
        return _rebuildPending;
    }

    /// Test-only: whether this build can rebuild itself in place (the
    /// executable lives under a DUB package). A deployed copy outside a
    /// package can still relaunch, but there is nothing for DUB to build.
    public bool canRebuildForTesting() const
    {
        return planRebuild(opencodeStateDirectory(), true, thisProcessID,
            thisExePath()).workingDir.length > 0;
    }

    /// Rebuild the package with DUB and relaunch the app.
    ///
    /// The rebuild cannot happen in-process: DUB must overwrite the running
    /// executable, which Windows keeps locked until we exit. So a detached
    /// helper is started first; it waits for this process to disappear, runs
    /// the build, and relaunches the binary. State is persisted before the
    /// window closes so the new instance restores where we left off.
    ///
    public void requestRebuild()
    {
        if (_rebuildPending) return;
        _rebuildPending = true;
        updateStatus("Rebuilding with DUB, then relaunching...");

        // Flush every piece of state the new instance reads on startup.
        persistState();
        saveProjects(_projectState);
        closeRuntimeClients();

        auto plan = planRebuild(opencodeStateDirectory(), true,
            thisProcessID, thisExePath());
        if (!launchRebuild(plan))
        {
            _rebuildPending = false;
            updateStatus("Rebuild failed: could not start the rebuild helper.");
            return;
        }
        _window.close();
    }

    /// The stock CheckBox reserves a fixed 12 px per character, which leaves a
    /// wide dead gap trailing its label (the composer's Thinking toggle used to
    /// push the Tools toggle ~70 px away). Measure the label and hug it instead
    /// so the two toggles read as a tight pair.
    private void hugCheckBoxLabel(CheckBox box, string label)
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast(FontFace) palette.uiFont;
        options.pixelSize = fontPixelSize(palette.fontScale);
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(toUTF32(label), options)
            .measuredSize();
        // CheckBox paints its indicator at x=3 (18 px wide) and the text at
        // x=28, so 28 px of left chrome plus a small trailing pad.
        const width = maxInt(32, 28 + measured.width + 8);
        box.layoutHints().preferredWidth = width;
        box.layoutHints().minWidth = width;
    }

    private void buildUi()
    {
        // Frameless window: the vendored TitleBar is the whole top band and the
        // old toolbar row lives inside it as the bar's content widget.
        _titleBar = add(new OpenCodeTitleBar(_window));
        _titleBar.setId("oc-titlebar");
        _titleBar.onSnapPreview = &updateSnapPreview;

        auto toolbar = new HBox(8, Insets(10, 4));

        // The model selector, context meter, thinking and tools toggles live in
        // the composer footer under the prompt input (upstream opencode keeps
        // them there). The title band only holds the window-level actions.
        auto composerControls = new HBox(8);
        composerControls.setId("oc-composer-controls");

        _modelButton = composerControls.add(new Button(_settings.model));
        _modelButton.setId("oc-model");
        _modelButton.onClick = delegate() { showModelPicker(); };

        _usageBadge = composerControls.add(new ContextUsageBadge());
        _usageBadge.setId("oc-usage");
        _usageBadge.setModel(_settings.model);
        _usageBadge.onHoverChanged = delegate(bool open)
        {
            if (open)
            {
                // Arm the hover-intent timer; onTick opens the tooltip once the
                // pointer has rested on the badge long enough.
                _usageTooltipPending = true;
                _usageTooltipHoverSeconds = 0.0;
            }
            else
            {
                _usageTooltipPending = false;
                _usageTooltipHoverSeconds = 0.0;
                if (_usageTooltipOpen) setContextUsageTooltipOpen(false);
            }
        };

        auto thinkingBox = new HoverCheckBox("Thinking");
        _thinkingBox = composerControls.add(thinkingBox);
        _thinkingBox.setId("oc-thinking");
        hugCheckBoxLabel(_thinkingBox, "Thinking");
        _thinkingBox.setChecked(_settings.thinking, false);
        _thinkingBox.onChanged = delegate(bool value)
        {
            _settings.thinking = value;
            if (_current >= 0) _sessions[_current].thinking = value;
            saveSettingsNow();
        };
        // The tooltip hangs off the Thinking checkbox itself rather than a
        // separate "?" badge, so hovering the control explains it.
        thinkingBox.onHoverChanged = delegate(bool open)
        {
            if (_thinkingTooltip is null)
                _thinkingTooltip = new HoverTooltip(_thinkingBox);
            setTooltipOpen(_thinkingBox, thinkingToggleTooltipText,
                _thinkingTooltip, _thinkingTooltipOpen, open, true);
        };

        _toolsBox = composerControls.add(new CheckBox("Tools"));
        _toolsBox.setId("oc-tools");
        hugCheckBoxLabel(_toolsBox, "Tools");
        _toolsBox.setChecked(_settings.toolsEnabled, false);
        _toolsBox.onChanged = delegate(bool value)
        {
            _settings.toolsEnabled = value;
            saveSettingsNow();
            updateStatus(value
                ? "Tools enabled — the model uses the D-native " ~
                  "run/read/write/remove/glob/grep/dshell tools."
                : "Tools disabled.");
        };

        // Push the conversation timer to the right edge of the footer so it is
        // always visible, even when a long model name and the toggles fill the
        // row (it was easy to miss tucked in after the "?").
        composerControls.add(new Spacer());
        _timerBadge = composerControls.add(new ChatTimerBadge());
        _timerBadge.setId("oc-timer");

        toolbar.add(new Spacer());

        auto exportButton = toolbar.add(new Button("Export", IconKind.save));
        exportButton.onClick = delegate() { exportCurrentConversation(); };

        auto changesButton = toolbar.add(new Button("Changes", IconKind.folder));
        changesButton.setId("oc-changes");
        changesButton.onClick = delegate() { showChangesDialog(); };

        auto profileButton = toolbar.add(new Button("Profile", IconKind.user));
        profileButton.setId("oc-profile");
        profileButton.onClick = delegate() { showProfileDialog(); };

        auto settingsButton = toolbar.add(new Button("Settings", IconKind.settings));
        settingsButton.onClick = delegate() { showSettingsDialog(); };

        // Rebuild the package with DUB and relaunch. The window closes first so
        // DUB can overwrite the running .exe.
        auto rebuildButton = toolbar.add(new Button("Rebuild", IconKind.refresh));
        rebuildButton.setId("oc-rebuild");
        rebuildButton.onClick = delegate() { requestRebuild(); };

        _keyBadge = toolbar.add(new Label(""));
        _keyBadge.setId("oc-key");
        _keyBadge.setScale(1);

        _titleBar.setContent(toolbar);

        auto body = add(new HBox(0));
        body.layoutHints().flex = 1.0;

        auto projectsColumn = new VBox(4, Insets(4));
        projectsColumn.layoutHints().preferredWidth = 48;
        projectsColumn.setBackground(opencodeBackground);
        _projectsColumn = projectsColumn;

        auto railHeader = projectsColumn.add(new HBox(2));
        railHeader.layoutHints().preferredHeight = 40;
        _projectsHeader = railHeader.add(new Label("Projects"));
        _projectsHeader.setScale(1);
        _projectsHeader.setColor(opencodeMuted);
        railHeader.add(new Spacer());
        _railToggle = railHeader.add(new IconButton(IconKind.chevronRight));
        _railToggle.setId("oc-rail-toggle");
        _railToggle.setFlat(true);
        _railToggle.onClick = delegate() { toggleProjectsRail(); };

        _projectRail = projectsColumn.add(new ProjectListView());
        _projectRail.setId("oc-projects");
        _projectRail.layoutHints().flex = 1.0;
        _projectRail.setRowHeight(40);
        _projectRail.onSelectionChanged = delegate(int index)
        {
            selectProject(index);
        };
        _projectRail.onContextMenuRequested = delegate(int row, Point point)
        {
            showProjectContextMenu(row, point);
        };
        _newProjectButton = projectsColumn.add(
            new Button("New project", IconKind.newDocument));
        _newProjectButton.setId("oc-new-project");
        _newProjectButton.onClick = delegate() { showNewProjectDialog(); };

        Insets sidebarPadding = Insets(8);
        // No right padding: the conversation list (and its scrollbar) must run
        // flush to the split-pane divider on the right.
        sidebarPadding.right = 0;
        auto sidebar = new VBox(4, sidebarPadding);
        sidebar.layoutHints().minWidth = 190;
        sidebar.layoutHints().preferredWidth = 300;
        sidebar.setBackground(opencodePanel);
        // Header labels and the search field keep their right margin; only the
        // scrollable conversation list is flush with the divider.
        Insets headerPadding;
        headerPadding.right = 8;
        // 8 px between rows so the New chat button and the Search chats field
        // read as a matched pair (they once sat 2 px apart with mismatched
        // heights).
        auto headerColumn = new VBox(8, headerPadding);
        headerColumn.setId("oc-header-column");
        _sessionsHeaderColumn = headerColumn;
        // Title row: project name with a small "open folder" button beside it,
        // so a click reveals the active workspace in File Explorer.
        auto titleRow = headerColumn.add(new HBox(6));
        titleRow.setId("oc-project-title-row");
        // A plain HBox reports no intrinsic height, and the header VBox (and
        // updateSessionsHeaderHeight) size children purely from their layout
        // hints. Without an explicit height the row collapsed to 0 px and both
        // the project title and the folder button vanished. Pin it to the
        // control height so it matches the row's tallest child.
        titleRow.layoutHints().minHeight = opencodeControlHeight;
        titleRow.layoutHints().preferredHeight = opencodeControlHeight;
        _sessionsHeader = titleRow.add(new Label("Sandbox"));
        _sessionsHeader.setId("oc-project-title");
        _sessionsHeader.setScale(1);
        _sessionsHeader.setColor(opencodeText);
        _openFolderButton = titleRow.add(new IconButton(IconKind.folder));
        _openFolderButton.setId("oc-open-folder");
        _openFolderButton.setFlat(true);
        _openFolderButton.onClick = delegate()
        {
            const workspace = activeWorkspace();
            openFolderInExplorer(workspace.length > 0 ? workspace : ".");
        };
        titleRow.add(new Spacer());
        _sessionsPath = headerColumn.add(new Label(""));
        _sessionsPath.setId("oc-project-path");
        _sessionsPath.setScale(1);
        _sessionsPath.setColor(opencodeMuted);
        _newChatButton = headerColumn.add(new Button("New chat", IconKind.newDocument));
        _newChatButton.setId("oc-new");
        // Match the search field's height so the two controls read as a pair.
        // Pin minHeight too: the nested VBox lays a child out at
        // max(minHeight, preferredHeight); leaving them mismatched once made
        // the column too short and the list overlapped the field's bottom.
        _newChatButton.layoutHints().preferredHeight = opencodeControlHeight;
        _newChatButton.layoutHints().minHeight = opencodeControlHeight;
        _newChatButton.onClick = delegate() { newChat(); };
        _filterField = headerColumn.add(new TextField(""));
        _filterField.setId("oc-filter");
        _filterField.setPlaceholder("Search chats");
        _filterField.layoutHints().preferredHeight = opencodeControlHeight;
        _filterField.layoutHints().minHeight = opencodeControlHeight;
        _filterField.onChanged = delegate()
        {
            _filterText = _filterField.textUtf8().strip();
            updateSessionList();
        };
        sidebar.add(headerColumn);
        updateSessionsHeaderHeight();
        _sessionList = sidebar.add(new SessionListView());
        _sessionList.setId("oc-sessions");
        _sessionList.layoutHints().flex = 1.0;
        _sessionList.setRowHeight(opencodeSessionRowHeight);
        _sessionList.onSelectionChanged = delegate(int index)
        {
            selectSessionByRow(index);
        };
        _sessionList.onContextMenuRequested = delegate(int row, Point point)
        {
            showSessionContextMenu(row, point);
        };
        _sessionList.onDeleteRequested = delegate(int row)
        {
            deleteSessionAtRow(row);
        };

        auto chatPanel = new VBox(0);
        chatPanel.layoutHints().flex = 1.0;

        _messageColumn = new VBox(6, Insets(12, 8));
        _messageColumn.setId("oc-messages");
        auto messageCenter = new CenteredColumn(_messageColumn,
            opencodeContentMaxWidth);
        messageCenter.setId("oc-message-center");
        _messagesScroll = new ChatScrollView(messageCenter);
        _messagesScroll.setId("oc-scroll");
        _messagesScroll.layoutHints().flex = 1.0;

        // Welcome overlay lives inside the transcript viewport (so it scrolls
        // with nothing and never competes with the message column's layout) and
        // is painted above it. It is hidden as soon as the conversation has a
        // message; `updateIntroOverlay` keeps that in step.
        _introOverlay = _messagesScroll.add(new IntroOverlay());
        _introOverlay.setId("oc-intro");
        _introOverlay.layoutHints().excludeFromLayout = true;
        _introOverlay.layoutHints().overlayFillParent = true;
        _introOverlay.layoutHints().allowOverflow = true;
        _introOverlay.setSuggestions(defaultIntroSuggestions);
        _introOverlay.onSuggestion = delegate(string prompt)
        {
            _input.setText(prompt);
            _input.requestFocus();
            updateStatus("");
        };
        _introOverlay.setVisible(false);

        _input = new ChatInput();
        _input.setId("oc-input");
        _input.setShowBorder(false);
        _input.setTransparentBackground(true);
        _input.setFocusDecoration(false);
        _input.setPadding(6);
        _input.setWordWrap(true);
        _input.setPlaceholder("Ask anything...");
        _input.onSendRequested = delegate() { sendMessage(); };
        _sendButton = new ChatSendButton();
        _sendButton.setId("oc-send");
        _sendButton.onClick = delegate()
        {
            // A visible Stop button must always stop. Composer text is guidance
            // only when submitted with Enter; it must never turn a Stop click
            // into a hidden "keep going" operation.
            if (turnIsBusy()) stopActiveTurn();
            else sendMessage();
        };

        auto composer = new ChatComposer(_input, _sendButton, composerControls);
        composer.setId("oc-composer");
        _composer = composer;
        auto composerCenter = new CenteredColumn(composer,
            opencodeContentMaxWidth);
        composerCenter.setId("oc-composer-center");
        // The top-level VBox sizes children from hints and is never measured
        // itself, so publish the composer's height here or it lays out to zero.
        composerCenter.layoutHints().preferredHeight = opencodeComposerHeight;
        composerCenter.layoutHints().minHeight = opencodeComposerHeight;

        chatPanel.add(_messagesScroll);
        chatPanel.add(composerCenter);

        _sessionsSplit = new SplitPane(sidebar, chatPanel,
            Orientation.horizontal);
        _sessionsSplit.setId("oc-split");
        _sessionsSplit.layoutHints().flex = 1.0;
        _sessionsSplit.setRatio(_projectState.sessionsRatio, false);
        _sessionsSplit.onRatioChanged = delegate(double ratio)
        {
            // Dragging fires per pixel; persist once per tick instead of on
            // every mouse-move.
            _projectState.sessionsRatio = ratio;
            _sessionsRatioDirty = true;
        };

        body.add(projectsColumn);
        body.add(_sessionsSplit);

        _status = add(new Label("Ready"));
        _status.setId("oc-status");
        _status.layoutHints().preferredHeight = 24;
        _status.setScale(1);

        // Drag-snap preview: added last, painted above all content, and excluded
        // from the VBox flow so it never consumes layout space.
        _snapPreview = add(new TitleBarSnapPreview());
        _snapPreview.setId("oc-snap");
        _snapPreview.layoutHints().excludeFromLayout = true;
        _snapPreview.layoutHints().overlayFillParent = true;
        _snapPreview.layoutHints().allowOverflow = true;

        applyProjectsRailState();
    }

    // -- projects ---------------------------------------------------------

    /// Apply the collapsed/expanded presentation of the project rail.
    private void applyProjectsRailState()
    {
        const collapsed = _projectState.projectsCollapsed;
        _projectsColumn.layoutHints().preferredWidth = collapsed ? 48 : 150;
        _projectsHeader.setVisible(!collapsed);
        _newProjectButton.setText(collapsed ? "" : "New project");
        _newProjectButton.layoutHints().preferredWidth = collapsed ? 40 : 138;
        _railToggle.setIcon(collapsed ? IconKind.chevronRight
            : IconKind.chevronDown);
        _projectsColumn.invalidate();
    }

    /// Flip the rail between icon width and the full project list.
    private void toggleProjectsRail()
    {
        _projectState.projectsCollapsed = !_projectState.projectsCollapsed;
        applyProjectsRailState();
        saveProjects(_projectState);
    }

    /// Map a drag-snap preview from screen to window-local coordinates.
    private void updateSnapPreview(TitleBarSnapTarget target, Rect bounds)
    {
        if (_snapPreview is null) return;
        if (target == TitleBarSnapTarget.none)
        {
            _snapPreview.hide();
            return;
        }
        Rect origin;
        if (!_window.windowBounds(origin))
        {
            _snapPreview.hide();
            return;
        }
        _snapPreview.show(Rect(bounds.x - origin.x, bounds.y - origin.y,
            bounds.width, bounds.height));
    }

    private int activeProjectIndex()
    {
        if (_projectState.projects.length == 0) return -1;
        foreach (index, project; _projectState.projects)
            if (project.id == _projectState.activeId) return cast(int) index;
        return 0;
    }

    private string activeProjectId()
    {
        const index = activeProjectIndex();
        return index >= 0 ? _projectState.projects[cast(size_t) index].id
            : sandboxProjectId;
    }

    /// The folder the active project's tools run in.
    private string activeWorkspace()
    {
        const index = activeProjectIndex();
        if (index < 0) return ".";
        const path = _projectState.projects[cast(size_t) index].path;
        return path.length > 0 ? path : ".";
    }

    private Project* activeProject()
    {
        const index = activeProjectIndex();
        return index >= 0 ? &_projectState.projects[cast(size_t) index] : null;
    }

    /// The folder a specific conversation's tools run in. Resolved from the
    /// conversation's own project so switching projects mid-run cannot retarget
    /// an in-flight tool batch.
    private string workspaceForSession(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return activeWorkspace();
        const id = _sessions[cast(size_t) sessionIndex].projectId;
        foreach (project; _projectState.projects)
            if (project.id == id && project.path.length > 0) return project.path;
        return activeWorkspace();
    }

    /// A session with no project id predates projects and lives in the sandbox.
    private static string sessionProjectId(const ref ChatSession session)
    {
        return session.projectId.length > 0
            ? session.projectId : sandboxProjectId;
    }

    /// Keep the open conversation inside the active project: if the current
    /// session belongs elsewhere (e.g. restored `current` or a project switch),
    /// open that project's most recent chat, or none when it has no chats.
    private void syncCurrentToActiveProject()
    {
        const projectId = activeProjectId();
        if (_current >= 0 && _current < cast(int) _sessions.length &&
            sessionProjectId(_sessions[_current]) == projectId)
            return;
        int candidate = -1;
        foreach (index, session; _sessions)
            if (sessionProjectId(session) == projectId)
                candidate = cast(int) index;
        if (candidate >= 0)
        {
            selectSession(candidate);
            return;
        }
        saveLoadedRuntime();
        _loadedRuntimeId = "";
        _current = -1;
        _streamBubble = null;
        _activityRow = null;
        _pendingToolCalls.length = 0;
        _liveToolCalls.length = 0;
        _preparingToolCalls.length = 0;
        _pendingToolResults = 0;
        _turnCancelled = false;
        clearActivity();
        rebuildMessageColumn();
        if (_status !is null) updateStatus("");
    }

    /// Adopt a workspace set by an older build as a real project so it is not
    /// silently lost now that the workspace follows the active project.
    private void migrateWorkspaceIntoProjects()
    {
        if (_settings.workspace.length == 0) return;
        foreach (project; _projectState.projects)
            if (project.path == _settings.workspace) return;
        Project project;
        project.id = newProjectId();
        project.name = projectNameFromPath(_settings.workspace);
        project.path = _settings.workspace;
        _projectState.projects ~= project;
        _projectState.activeId = project.id;
        saveProjects(_projectState);
    }

    private static string projectNameFromPath(string path)
    {
        const name = baseName(path);
        return name.length > 0 ? name : path;
    }

    private void updateProjectRail()
    {
        if (_projectRail is null) return;
        ListItem[] items;
        foreach (project; _projectState.projects)
            items ~= ListItem(project.name, IconKind.none, "");
        _projectRail.setItems(items);
        const index = activeProjectIndex();
        if (index >= 0) _projectRail.setSelectedIndex(index, false);
    }

    private void updateSessionsHeader()
    {
        if (_sessionsHeader is null) return;
        const project = activeProject();
        _sessionsHeader.setText(project is null ? "Sandbox" : project.name);
        if (_sessionsPath !is null)
            _sessionsPath.setText(project is null ? "" : project.path);
        updateSessionsHeaderHeight();
    }

    // The header/search block is a nested VBox, so the outer sidebar sizes it
    // from an explicit preferredHeight (VBox.onLayout lays children out from
    // their hints only and never uses a child's measured size). Derive the
    // height from the box's own spacing/padding and its laid-out children so it
    // can never drift again: a hardcoded gap total (e.g. "18" for three 6px
    // gaps) silently went stale when the spacing changed to 8 and clipped the
    // search field's bottom border. Recompute whenever the labels' text changes.
    private void updateSessionsHeaderHeight()
    {
        auto box = _sessionsHeaderColumn;
        if (box is null) return;
        const padding = box.padding();
        int height = padding.top + padding.bottom;
        int count = 0;
        foreach (child; box.children())
        {
            if (!child.visible() || child.layoutHints().excludeFromLayout) continue;
            const hints = child.layoutHints();
            height += maxInt(hints.minHeight,
                hints.preferredHeight >= 0 ? hints.preferredHeight : hints.minHeight);
            ++count;
        }
        if (count > 1) height += box.spacing() * (count - 1);
        box.layoutHints().preferredHeight = height;
    }

    private void selectProject(int index)
    {
        if (index < 0 || index >= cast(int) _projectState.projects.length)
            return;
        const id = _projectState.projects[cast(size_t) index].id;
        if (id == _projectState.activeId)
        {
            if (_projectRail !is null) _projectRail.setSelectedIndex(index, false);
            return;
        }
        _projectState.activeId = id;
        saveProjects(_projectState);
        updateSessionsHeader();
        syncCurrentToActiveProject();
        updateSessionList(false);
        _input.requestFocus();
    }

    private void showNewProjectDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 400;

        auto title = content.add(new Label("New project"));
        title.setPixelSize(opencodeFontTitle);

        auto nameLabel = content.add(new Label("Name"));
        nameLabel.setScale(1);
        nameLabel.setColor(opencodeMuted);
        auto nameField = content.add(new TextField(""));
        nameField.setId("oc-project-name");
        nameField.setPlaceholder("My project");

        auto pathLabel = content.add(new Label("Folder"));
        pathLabel.setScale(1);
        pathLabel.setColor(opencodeMuted);
        auto pathField = content.add(new TextField(""));
        pathField.setId("oc-project-path-input");
        pathField.setPlaceholder("C:\\path\\to\\folder");

        auto errorLabel = content.add(new Label(""));
        errorLabel.setScale(1);
        errorLabel.setColor(opencodeErrorRed);

        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto cancel = footer.add(new Button("Cancel"));
        cancel.setId("oc-project-cancel");
        cancel.onClick = delegate() { dismissPopup(); };
        auto create = footer.add(new Button("Create"));
        create.setId("oc-project-create");
        create.setAccent(true);
        create.onClick = delegate()
        {
            const name = nameField.textUtf8().strip();
            const path = pathField.textUtf8().strip();
            if (name.length == 0)
            {
                errorLabel.setText("Give the project a name.");
                return;
            }
            if (path.length == 0)
            {
                errorLabel.setText("Pick a folder.");
                return;
            }
            Project project;
            project.id = newProjectId();
            project.name = name;
            project.path = path;
            ensureProjectDirectory(project);
            _projectState.projects ~= project;
            _projectState.activeId = project.id;
            saveProjects(_projectState);
            dismissPopup();
            updateProjectRail();
            updateSessionsHeader();
            syncCurrentToActiveProject();
            updateSessionList(false);
            updateStatus("Created project " ~ name ~ ".");
        };

        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(420, 300));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
        nameField.requestFocus();
    }

    private void showProjectContextMenu(int index, Point globalPosition)
    {
        if (index < 0 || index >= cast(int) _projectState.projects.length)
            return;
        const project = _projectState.projects[cast(size_t) index];
        const isSandbox = project.id == sandboxProjectId;
        ContextMenuItem[] items;
        if (!isSandbox)
            items ~= ContextMenuItem.command("Rename", IconKind.settings,
                delegate() { showRenameProjectDialog(index); });
        items ~= ContextMenuItem.command("New chat here", IconKind.terminal,
            delegate()
            {
                _projectState.activeId = project.id;
                saveProjects(_projectState);
                updateProjectRail();
                updateSessionsHeader();
                updateSessionList(false);
                newChat();
            });
        if (!isSandbox)
            items ~= ContextMenuItem.command("Remove", IconKind.trash,
                delegate() { removeProject(index); });
        showContextMenu(_projectRail, globalPosition, items);
    }

    private void showRenameProjectDialog(int index)
    {
        if (index < 0 || index >= cast(int) _projectState.projects.length)
            return;
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 400;

        auto title = content.add(new Label("Rename project"));
        title.setPixelSize(opencodeFontTitle);

        auto nameField = content.add(
            new TextField(_projectState.projects[cast(size_t) index].name));
        nameField.setId("oc-project-rename");

        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto cancel = footer.add(new Button("Cancel"));
        cancel.setId("oc-project-rename-cancel");
        cancel.onClick = delegate() { dismissPopup(); };
        auto save = footer.add(new Button("Rename"));
        save.setId("oc-project-rename-save");
        save.setAccent(true);
        save.onClick = delegate()
        {
            const name = nameField.textUtf8().strip();
            if (name.length == 0) return;
            _projectState.projects[cast(size_t) index].name = name;
            saveProjects(_projectState);
            dismissPopup();
            updateProjectRail();
            updateSessionsHeader();
            updateSessionList(false);
        };
        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(420, 200));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
        nameField.requestFocus();
    }

    private void removeProject(int index)
    {
        if (index < 0 || index >= cast(int) _projectState.projects.length)
            return;
        const project = _projectState.projects[cast(size_t) index];
        if (project.id == sandboxProjectId) return;
        foreach (ref session; _sessions)
            if (session.projectId == project.id)
                session.projectId = sandboxProjectId;
        _projectState.projects = _projectState.projects[0 .. cast(size_t) index]
            ~ _projectState.projects[cast(size_t) index + 1 .. $];
        if (_projectState.activeId == project.id)
            _projectState.activeId = sandboxProjectId;
        saveProjects(_projectState);
        persistState();
        updateProjectRail();
        updateSessionsHeader();
        syncCurrentToActiveProject();
        updateSessionList(false);
        updateStatus("Removed project " ~ project.name ~ ".");
    }

    // -- sessions ---------------------------------------------------------

    private void newChat()
    {
        saveLoadedRuntime();
        if (_loadedRuntimeId.length == 0 && _sessions.length == 0 &&
            _client !is null)
            _client.closeSession();
        ChatSession session;
        session.id = newSessionId();
        session.title = "New chat";
        session.model = _settings.model;
        session.thinking = _settings.thinking;
        session.projectId = activeProjectId();
        _sessions ~= session;
        _current = cast(int) _sessions.length - 1;
        loadRuntime(_current);
        publishRuntimeEvent(AgentEventKind.threadStarted, session,
            "", "", "", runtimeThreadPayload(session));
        _visibleMessageLimit = messageHistoryPageSize;
        _editMessageIndex = -1;
        _filterText = "";
        if (_filterField !is null) _filterField.setText("", false);
        rebuildMessageColumn();
        updateSessionList();
        markDirty();
        _input.requestFocus();
        updateStatus("New conversation. Ask away!");
        refreshUsageBadge();
        refreshTimerBadge(true);
    }

    private void selectSession(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return;
        saveLoadedRuntime();
        _current = index;
        loadRuntime(index);
        _visibleMessageLimit = messageHistoryPageSize;
        _editMessageIndex = -1;
        if (turnIsBusy() && index == turnOwnerSessionIndex() &&
            _sessions[index].messages.length > 0 &&
            _sessions[index].messages[$ - 1].role == "assistant")
        {
            // Reattach a live bubble when returning to the conversation that is
            // still streaming. The durable message collected every background
            // delta while another chat was selected.
            const message = _sessions[index].messages[$ - 1];
            _streamBubble = new MessageBubble();
            _streamBubble.setRole("assistant");
            _streamBubble.setContent(message.content);
            _streamBubble.setThinking(message.reasoning);
            _streamBubble.setThinkingLive(true);
            _streamBubble.setStreaming(true);
            _streamBubble.setMessageIndex(
                cast(int) _sessions[index].messages.length - 1);
            _streamBubble.setLiveTokens(_liveOutputTokens, true);
            _streamBubble.setTokenRate(_liveTokenRateTenths);
        }
        rebuildMessageColumn();
        _settings.model = _sessions[index].model;
        _settings.thinking = _sessions[index].thinking;
        _modelButton.setText(_settings.model);
        _thinkingBox.setChecked(_settings.thinking, false);
        markDirty();
        updateStatus("");
        refreshUsageBadge();
        refreshTimerBadge(true);
    }

    private void selectSessionByRow(int row)
    {
        if (row < 0 || row >= cast(int) _sessionIndices.length) return;
        selectSession(_sessionIndices[row]);
    }

    private void publishRuntimeEvent(AgentEventKind kind,
        const ref ChatSession session, string turnId = "", string itemId = "",
        string itemKind = "", string payloadJson = "{}")
    {
        if (_runtime is null || session.id.length == 0) return;
        AgentRuntimeEvent event;
        event.kind = kind;
        event.threadId = session.id;
        event.turnId = turnId;
        event.itemId = itemId;
        event.itemKind = itemKind;
        event.payloadJson = payloadJson;
        if (!_runtime.publish(event) && !_runtimeErrorReported)
        {
            _runtimeErrorReported = true;
            logError("agent runtime journal unavailable: " ~
                _runtime.lastError());
        }
    }

    private static string runtimeThreadPayload(const ref ChatSession session)
    {
        JSONValue payload;
        payload["title"] = session.title;
        payload["model"] = session.model;
        payload["thinking"] = session.thinking;
        payload["projectId"] = session.projectId;
        payload["activeLeafId"] = session.activeLeafId;
        payload["objective"] = session.objective;
        payload["taskStatus"] = session.taskStatus;
        payload["verificationStatus"] = session.verificationStatus;
        JSONValue steps = JSONValue(string[].init);
        foreach (step; session.taskSteps)
        {
            JSONValue value;
            value["text"] = step.text;
            value["status"] = step.status;
            steps.array ~= value;
        }
        payload["taskSteps"] = steps;
        JSONValue guidance = JSONValue(string[].init);
        foreach (item; session.queuedGuidance) guidance.array ~= JSONValue(item);
        payload["queuedGuidance"] = guidance;
        return payload.toString();
    }

    /// Machine-readable task state supplied on every request.  This is the
    /// durable equivalent of Codex's thread goal: compaction and restarts cannot
    /// silently erase the objective or turn an unfinished checklist into "done".
    private static string durableTaskPrompt(const ref ChatSession session)
    {
        if (session.objective.length == 0 && session.taskSteps.length == 0 &&
            session.verificationStatus.length == 0) return "";
        auto prompt = appender!string();
        prompt.put("\n\n# Durable Task State\n");
        prompt.put("Objective: " ~ (session.objective.length > 0
            ? session.objective : "(not set)") ~ "\n");
        string currentRequest;
        foreach (index; activeMessagePath(session))
        {
            const message = session.messages[index];
            if (message.role == "user" && !message.internal)
                currentRequest = message.content;
        }
        if (currentRequest.length > 0 && currentRequest != session.objective)
            prompt.put("Current request: " ~ currentRequest ~ "\n");
        prompt.put("Status: " ~ (session.taskStatus.length > 0
            ? session.taskStatus : "active") ~ "\n");
        prompt.put("Verification: " ~ (session.verificationStatus.length > 0
            ? session.verificationStatus : "not_required") ~ "\n");
        if (session.taskSteps.length > 0)
        {
            prompt.put("Checklist:\n");
            foreach (step; session.taskSteps)
                prompt.put("- [" ~ step.status ~ "] " ~ step.text ~ "\n");
        }
        prompt.put("Treat this state as authoritative. Update the plan as work " ~
            "changes. Do not claim completion while verification is required " ~
            "or a checklist item remains pending/in_progress.\n");
        return prompt.data;
    }

    private static bool likelyChangeRequest(string text)
    {
        const lower = text.toLower().strip();
        foreach (prefix; ["add ", "build ", "change ", "create ", "delete ",
            "fix ", "implement ", "make ", "move ", "refactor ", "remove ",
            "rename ", "replace ", "update "])
            if (lower.length >= prefix.length &&
                lower[0 .. prefix.length] == prefix) return true;
        return lower.canFind("\\") || lower.canFind("/") ||
            lower.canFind(".d") || lower.canFind(".ts") ||
            lower.canFind(".js") || lower.canFind(".py");
    }

    private static bool isAutomaticTaskPlan(const ref ChatSession session)
    {
        return session.taskSteps.length == 3 &&
            session.taskSteps[0].text == "Inspect the relevant code" &&
            session.taskSteps[1].text == "Implement the requested changes" &&
            session.taskSteps[2].text == "Run focused verification";
    }

    private static void initializeAutomaticTaskPlan(ref ChatSession session)
    {
        session.taskSteps = [
            TaskStep("Inspect the relevant code", "in_progress"),
            TaskStep("Implement the requested changes", "pending"),
            TaskStep("Run focused verification", "pending"),
        ];
    }

    private static void advanceAutomaticPlanToImplementation(
        ref ChatSession session)
    {
        if (!isAutomaticTaskPlan(session)) return;
        session.taskSteps[0].status = "completed";
        session.taskSteps[1].status = "in_progress";
    }

    private static void completeAutomaticImplementation(ref ChatSession session)
    {
        if (!isAutomaticTaskPlan(session)) return;
        session.taskSteps[0].status = "completed";
        session.taskSteps[1].status = "completed";
        session.taskSteps[2].status = "in_progress";
    }

    private static void completeAutomaticVerification(ref ChatSession session)
    {
        if (!isAutomaticTaskPlan(session)) return;
        foreach (ref step; session.taskSteps) step.status = "completed";
    }

    private void publishThreadUpdated(const ref ChatSession session)
    {
        publishRuntimeEvent(AgentEventKind.threadUpdated, session,
            "", "", "", runtimeThreadPayload(session));
    }

    /// A turn is keyed by the real user message that opened it. Tool results
    /// and internal recovery instructions remain part of that same turn.
    private static string runtimeTurnId(const ref ChatSession session)
    {
        string result;
        foreach (index; activeMessagePath(session))
        {
            const message = session.messages[index];
            if (message.role == "user" && !message.internal)
                result = message.id;
        }
        return result;
    }

    private static string runtimeItemKind(const ref ChatMessage message)
    {
        if (message.internal) return "controlMessage";
        if (message.role == "user") return "userMessage";
        if (message.role == "assistant") return "agentMessage";
        if (message.role == "tool") return "functionCallOutput";
        return "message";
    }

    /// Preserve structured source data so recovery never needs to reinterpret
    /// a rendered chat bubble.
    private static string runtimeMessagePayload(const ref ChatMessage message)
    {
        JSONValue payload;
        payload["role"] = message.role;
        payload["content"] = message.content;
        payload["parentId"] = message.parentId;
        if (message.reasoning.length > 0)
            payload["reasoning"] = message.reasoning;
        if (message.time.length > 0) payload["time"] = message.time;
        if (message.failed) payload["failed"] = true;
        if (message.finishReason.length > 0)
            payload["finishReason"] = message.finishReason;
        if (message.internal) payload["internal"] = true;
        if (message.toolCallId.length > 0)
            payload["toolCallId"] = message.toolCallId;
        if (message.toolName.length > 0) payload["toolName"] = message.toolName;
        if (message.toolArgs.length > 0) payload["toolArgs"] = message.toolArgs;
        if (message.toolCalls.length > 0)
        {
            JSONValue calls = JSONValue(string[].init);
            foreach (call; message.toolCalls)
            {
                JSONValue value;
                value["id"] = call.id;
                value["name"] = call.name;
                value["arguments"] = call.arguments;
                calls.array ~= value;
            }
            payload["toolCalls"] = calls;
        }
        if (message.totalTokens > 0 || message.completionTokens > 0)
        {
            payload["promptTokens"] = message.promptTokens;
            payload["completionTokens"] = message.completionTokens;
            payload["totalTokens"] = message.totalTokens;
        }
        if (message.tokensPerSecondTenths > 0)
            payload["tokensPerSecondTenths"] = message.tokensPerSecondTenths;
        if (message.diffAdditions > 0)
            payload["diffAdditions"] = message.diffAdditions;
        if (message.diffDeletions > 0)
            payload["diffDeletions"] = message.diffDeletions;
        if (message.toolDiff.length > 0) payload["toolDiff"] = message.toolDiff;
        if (message.toolElapsedMs > 0)
            payload["toolElapsedMs"] = message.toolElapsedMs;
        if (isFinite(message.workedSeconds) && message.workedSeconds > 0)
            payload["workedSeconds"] = message.workedSeconds;
        return payload.toString();
    }

    private void publishMessageEvent(AgentEventKind kind,
        const ref ChatSession session, const ref ChatMessage message)
    {
        publishRuntimeEvent(kind, session, runtimeTurnId(session), message.id,
            runtimeItemKind(message), runtimeMessagePayload(message));
    }

    private static string errorPayload(string error)
    {
        JSONValue payload;
        payload["error"] = error;
        return payload.toString();
    }

    /// Append a message as a child of the active leaf and advance the leaf so
    /// the new message becomes the visible tip. All new turns (user prompts,
    /// assistant replies, tool results, recovery notes) go through here so the
    /// message graph stays consistent and branches never lose their parent.
    private void appendMessage(ref ChatSession session,
        ChatMessage message)
    {
        if (session.id.length == 0) session.id = newSessionId();
        message.id = newMessageId();
        message.parentId = session.activeLeafId;
        session.messages ~= message;
        session.activeLeafId = message.id;
        publishMessageEvent(AgentEventKind.itemAdded, session,
            session.messages[$ - 1]);
    }

    /// When a tool batch is abandoned (the loop guard or the round cap fired),
    /// the assistant message already carries `tool_calls`. The API requires a
    /// `tool` reply for every id before any following message, so record an
    /// explanatory result per call — otherwise the stored transcript is invalid
    /// and the next request fails with HTTP 400.
    private void appendSkippedToolResults(ref ChatSession session,
        const(OpenCodeToolCall)[] calls, string reason)
    {
        foreach (call; calls)
        {
            ChatMessage result;
            result.role = "tool";
            result.content = reason;
            result.toolCallId = call.id;
            result.toolName = call.name;
            result.failed = true;
            appendMessage(session, result);
        }
    }

    /// Horizontal inset for a tool result nested under the assistant turn that
    /// requested it. Kept at 0 so every collapsible transcript row — a nested
    /// tool result, a top-level "Explored" group, a live/Thinking row, the
    /// replies themselves — shares one left edge instead of stepping in as the
    /// nesting deepens. The nest still exists to group a turn's rows and to
    /// publish its measured size (see `TurnNest`).
    private static immutable int toolNestIndent = 0;

    private void rebuildMessageColumn()
    {
        // A full message-column rebuild is the heaviest thing the UI does and
        // the most likely place for a fault, so record it before the work. A
        // crash here then names this step rather than leaving only an address.
        noteActivity("rebuildMessageColumn sessions=" ~ to!string(_sessions.length) ~
            " current=" ~ to!string(_current));
        // A rebuild discards the column's children; detach the two reused
        // widgets first so a nested parent (a turn container) does not leave
        // them attached and reporting visible after they are dropped.
        if (_activityRow !is null && _activityRow.parent() !is null)
            _activityRow.parent().remove(_activityRow);
        if (_streamBubble !is null && _streamBubble.parent() !is null)
            _streamBubble.parent().remove(_streamBubble);
        _messageColumn.clearChildren();
        if (_current < 0)
        {
            updateIntroOverlay();
            return;
        }
        const session = &_sessions[_current];
        const fullPath = activeMessagePath(*session);
        const hiddenCount = fullPath.length > _visibleMessageLimit
            ? fullPath.length - _visibleMessageLimit : 0;
        const path = hiddenCount > 0 ? fullPath[hiddenCount .. $] : fullPath;
        if (hiddenCount > 0)
        {
            const nextPage = hiddenCount < messageHistoryPageSize
                ? hiddenCount : messageHistoryPageSize;
            auto older = new Button("Load " ~ to!string(nextPage) ~
                " older messages");
            older.onClick = delegate()
            {
                _visibleMessageLimit += messageHistoryPageSize;
                rebuildMessageColumn();
                _messagesScroll.invalidate();
            };
            _messageColumn.add(older);
        }
        // Only the latest real assistant reply shows its token usage in the
        // footer. Tool-call wrappers (empty content + tool requests) never do.
        int latestAssistantIndex = -1;
        foreach_reverse (slot, index; path)
        {
            const message = session.messages[index];
            if (message.role == "assistant" && message.toolCalls.length == 0)
            {
                latestAssistantIndex = cast(int) index;
                break;
            }
        }
        // Branch version counts per message (siblings = same parent+role), so
        // edited prompts / regenerated replies can show `< n/m >` in the
        // footer. Computed once per rebuild rather than per bubble.
        size_t[] versionPositions, versionTotals;
        computeSiblingVersions(*session, versionPositions, versionTotals);

        // Codex-style per-round layout: each assistant round shows its own
        // chain of thought (a collapsible `▸ Thinking` block), then its prose
        // paragraph, then its own collapsible action group. A user turn that
        // spans several rounds therefore reads as a clean, append-only
        // `paragraph -> collapsible -> paragraph -> collapsible` sequence
        // instead of one merged group stranded at the turn's start. Reasoning
        // stays visible (never hidden) — open source, so the user can inspect
        // it; it is just collapsed by default. The live reply streams its
        // reasoning into `_streamBubble`, which a rebuild renders from the
        // message, so the in-flight round shows its own Thinking too.
        auto thinkingText = new string[](path.length);
        foreach (slot, index; path)
            thinkingText[slot] = session.messages[index].reasoning;

        // Nesting: a `tool` result belongs to the assistant turn that requested
        // it. Match each result's `toolCallId` to the assistant whose `toolCalls`
        // names it, so results render as indented children of that turn instead
        // of as top-level siblings. `owner[slot]` is the owning slot
        // (size_t.max = orphan, kept top level).
        auto owner = new size_t[](path.length);
        foreach (ref o; owner) o = size_t.max;
        foreach (slot, index; path)
        {
            const message = session.messages[index];
            if (message.role != "assistant" || message.toolCalls.length == 0)
                continue;
            foreach (call; message.toolCalls)
            {
                if (call.id.length == 0) continue;
                foreach (childSlot; slot + 1 .. path.length)
                {
                    const candidate = session.messages[path[childSlot]];
                    if (candidate.role == "tool" &&
                        candidate.toolCallId == call.id)
                    {
                        owner[childSlot] = slot;
                        break;
                    }
                }
            }
        }
        // Map every user turn to its last prose assistant message and remember
        // whether that turn contained actual agent work. Codex deliberately
        // omits "Worked for" on a plain direct answer; reasoning or tool use is
        // what makes the completion boundary useful rather than visual noise.
        size_t[string] finalAssistantByTurn;
        bool[string] actualWorkByTurn;
        string scannedTurn;
        foreach (index; path)
        {
            const candidate = session.messages[index];
            if (candidate.internal) continue;
            if (candidate.role == "user")
            {
                scannedTurn = candidate.id;
                continue;
            }
            if (scannedTurn.length > 0 && candidate.role == "assistant" &&
                (candidate.reasoning.length > 0 ||
                 candidate.toolCalls.length > 0))
                actualWorkByTurn[scannedTurn] = true;
            if (scannedTurn.length > 0 && candidate.role == "assistant" &&
                candidate.toolCalls.length == 0)
                finalAssistantByTurn[scannedTurn] = index;
        }
        string openTurn = "";

        // In-flight rows (streamed tool arguments, running tools, activity) and
        // the streaming reply belong to the newest *top-level* turn, and only
        // when that turn is an assistant reply. If the newest turn is the user
        // prompt (the request was just sent, before the reply turn exists) there
        // is no host: the rows go to the bottom, after the prompt. Nesting them
        // under the previous answer put "Waiting for the model…" ABOVE the prompt
        // that triggered it.
        const bool isLive = viewingTurnOwner() &&
            ((_activityRow !is null && _activityRow.hasLabel()) ||
             _preparingToolCalls.length > 0 || _liveToolCalls.length > 0);
        size_t liveHostSlot = size_t.max;
        if (isLive)
            foreach_reverse (slot, index; path)
            {
                if (owner[slot] != size_t.max) continue; // owned tool result
                if (session.messages[index].role == "assistant")
                    liveHostSlot = slot;
                break;
            }
        bool liveRowsAdded = false;
        size_t slot = 0;
        while (slot < path.length)
        {
            const index = path[slot];
            const message = session.messages[index];

            // A rebuild's per-slot work is where the 2026-09-18 faults landed:
            // the last marker before the crash was always `rebuildMessageColumn`,
            // with no `onPaint` after it, so death was in build/measure rather
            // than paint. Naming the slot and message here makes the last
            // recorded step the exact one that faulted.
            // Sampling retains a useful crash breadcrumb without turning every
            // rebuild of a 120-row page into 120 synchronous log writes.
            if (slot == 0 || slot + 1 == path.length || slot % 20 == 0)
                noteActivity("rebuild slot=" ~ to!string(slot) ~ "/" ~
                    to!string(path.length) ~ " index=" ~ to!string(index) ~
                    " role=" ~ message.role ~ " toolCalls=" ~
                    to!string(message.toolCalls.length) ~ " internal=" ~
                    to!string(message.internal));


            // Synthetic control turns (max-rounds / loop recovery) steer the
            // model but are not the user's words: keep them out of the
            // transcript so the UI does not show a fake user prompt at the
            // point the agent hit a limit.
            if (message.internal)
            {
                ++slot;
                continue;
            }

            // A user prompt opens a new turn. Its settled clock is rendered at
            // the final-answer boundary below.
            if (message.role == "user")
                openTurn = message.id;

            // Owned results render as children of their assistant turn.
            if (owner[slot] != size_t.max)
            {
                ++slot;
                continue;
            }

            if (message.role == "assistant")
            {
                if (openTurn.length > 0 && message.toolCalls.length == 0)
                {
                    auto finalIndex = openTurn in finalAssistantByTurn;
                    auto duration = openTurn in _turnDurations;
                    auto didWork = openTurn in actualWorkByTurn;
                    if (_settings.showWorkedFor &&
                        finalIndex !is null && *finalIndex == index &&
                        duration !is null && didWork !is null && *didWork)
                        _messageColumn.add(
                            new TurnCompletionSeparator(*duration));
                }
                if (_streamBubble !is null &&
                    _streamBubble.messageIndex() == cast(int) index)
                {
                    // Re-add the live reply instead of a fresh bubble so a
                    // rebuild during streaming does not drop in-flight text.
                    _messageColumn.add(_streamBubble);
                }
                else
                {
                    _messageColumn.add(buildMessageBubble(index, message,
                        latestAssistantIndex, versionPositions, versionTotals,
                        thinkingText[slot]));
                }
                // This round's own tool results, in the order the model
                // requested them: the round's prose is followed by its own
                // collapsible action group, so a multi-round turn reads as
                // paragraph -> collapsible -> paragraph -> collapsible instead
                // of one group stranded at the turn's start.
                size_t[] childSlots;
                foreach (call; message.toolCalls)
                {
                    if (call.id.length == 0) continue;
                    foreach (childSlot; slot + 1 .. path.length)
                    {
                        if (owner[childSlot] != slot) continue;
                        if (session.messages[path[childSlot]].toolCallId ==
                            call.id)
                        {
                            childSlots ~= childSlot;
                            break;
                        }
                    }
                }
                if (childSlots.length > 0 || slot == liveHostSlot)
                {
                    Insets nestPad;
                    nestPad.left = toolNestIndent;
                    auto nest = new TurnNest(nestPad);
                    auto group = addToolSlots(nest, childSlots, path, *session,
                        latestAssistantIndex, versionPositions, versionTotals,
                        session.messages[path[slot]].id);
                    if (slot == liveHostSlot)
                    {
                        group = addLiveToolRows(group, nest,
                            "assistant:" ~ session.messages[path[slot]].id);
                        liveRowsAdded = true;
                    }
                    _messageColumn.add(nest);
                }
                ++slot;
                continue;
            }

            // Orphan tool results (no owning assistant turn in the path) fold
            // into one action group, exactly like a turn's own tools.
            if (message.role == "tool")
            {
                size_t end = slot;
                while (end < path.length && owner[end] == size_t.max &&
                    session.messages[path[end]].role == "tool")
                    ++end;
                Widget[] parts;
                foreach (member; slot .. end)
                    parts ~= buildMessageBubble(path[member],
                        session.messages[path[member]],
                        latestAssistantIndex, versionPositions,
                        versionTotals);
                auto group = new ToolGroupBubble(parts);
                wireToolGroup(group, session.messages[path[slot]].id);
                _messageColumn.add(group);
                slot = end;
                continue;
            }
            if (_streamBubble !is null &&
                _streamBubble.messageIndex() == cast(int) index)
            {
                _messageColumn.add(_streamBubble);
                ++slot;
                continue;
            }
            _messageColumn.add(buildMessageBubble(index,
                session.messages[index], latestAssistantIndex,
                versionPositions, versionTotals));
            ++slot;
        }
        // Live rows with no assistant turn to nest under (e.g. a tool progress
        // event before any reply exists) stay at the end of the column.
        if (isLive && !liveRowsAdded)
            addLiveToolRows(null, _messageColumn, "live");
        // Deliberately do NOT set `_messagesScroll.follow = true` here. A rebuild
        // happens many times while a reply and its tools stream (e.g. every
        // throttled tool-argument delta), and forcing follow each time yanked a
        // reader who had scrolled up back to the bottom. Callers that append a
        // new message already turn follow on when a jump is actually wanted.
        _messageColumn.invalidate();
        // The column is a retained layer; let the ScrollView re-measure and
        // update the content height / auto-follow after the message set changes.
        _messagesScroll.invalidate();
        // Now that the column is populated, decide whether the welcome overlay
        // belongs over it (empty conversation) or not.
        updateIntroOverlay();
        refreshBubbleActions();
    }

    /// Show the welcome overlay only while the active conversation has no
    /// visible messages. A brand-new chat, a restored-but-empty chat and the
    /// no-session state all qualify; anything with a bubble (including a live
    /// prompt) hides it. Called from the rebuild so it tracks exactly what the
    /// transcript shows. Re-showing replays the fade so the intro animates in
    /// for each new conversation rather than only once per run.
    private void updateIntroOverlay()
    {
        if (_introOverlay is null) return;
        const empty = messageColumnVisuals().length == 0;
        if (empty) updateIntroSubtitle();
        if (_introOverlay.visible() == empty) return;
        _introOverlay.setVisible(empty);
        if (empty) _introOverlay.replay();
    }

    /// Point the overlay's subtitle at the workspace the tools will run in, so
    /// the empty state says where the agent is actually operating.
    private void updateIntroSubtitle()
    {
        if (_introOverlay is null) return;
        const workspace = activeWorkspace();
        _introOverlay.setSubtitle(workspace.length > 0 && workspace != "."
            ? "Working in " ~ workspace : "");
    }

    /// Every transcript widget in visual reading order, flattening an assistant
    /// turn's nested container so tests and the action-pill pass see tools and
    /// replies in order regardless of nesting depth.
    private Widget[] messageColumnVisuals()
    {
        Widget[] result;
        foreach (child; _messageColumn.children())
        {
            if (auto nest = cast(VBox) child)
                foreach (inner; nest.children()) result ~= inner;
            else
                result ~= child;
        }
        return result;
    }

    /// Add one round's owned tool results to `target` as a Codex-style action
    /// group (a single collapsible summarising that round's tools) and return it
    /// so the live path can append its in-flight rows. `collapseKey` is the
    /// round's assistant message id, so an expanded group stays expanded across
    /// the rebuilds that happen while the round streams. Returns null when the
    /// round ran no tools.
    private ToolGroupBubble addToolSlots(VBox target, const(size_t)[] slots,
        const(size_t)[] path, ref const ChatSession session,
        int latestAssistantIndex, size_t[] versionPositions,
        size_t[] versionTotals, string collapseKey)
    {
        if (slots.length == 0) return null;
        Widget[] parts;
        foreach (slot; slots)
        {
            const index = path[slot];
            parts ~= buildMessageBubble(index, session.messages[index],
                latestAssistantIndex, versionPositions, versionTotals);
        }
        auto group = new ToolGroupBubble(parts);
        wireToolGroup(group, collapseKey);
        target.add(group);
        return group;
    }

    /// Wire an action group's size callback and re-apply its saved expand state
    /// so a group the user opened stays open across streamed rebuilds.
    private void wireToolGroup(ToolGroupBubble group, string key)
    {
        group.collapseKey = "group:" ~ key;
        group.onSizeChanged = delegate()
        {
            _messageColumn.invalidate();
            _messagesScroll.invalidate();
        };
        group.onCollapseChanged = delegate(bool collapsed)
        {
            if (group.collapseKey.length > 0)
                _groupCollapsed[group.collapseKey] = collapsed;
        };
        if (auto saved = group.collapseKey in _groupCollapsed)
            group.setCollapsed(*saved);
    }

    /// Build the in-flight row for one tool call: name/subtitle, a provisional
    /// `+N -M`, and the streamed body preview. `running` means the arguments
    /// have fully arrived (the tool is executing) so the title is past tense.
    private LiveToolRow buildLiveToolRow(const(OpenCodeToolCall) call,
        bool running)
    {
        auto row = new LiveToolRow();
        const title = running ? humanToolTitle(call.name)
            : humanToolProgressTitle(call.name);
        row.setSummary(call.name, title,
            humanToolSubtitle(call.name, call.arguments));
        int additions, deletions;
        if (previewToolDiff(call.name, call.arguments, additions, deletions))
            row.setDiff(additions, deletions);
        row.setDetail(humanToolDetail(call.name, call.arguments));
        return row;
    }

    /// Append every in-flight tool call as a live child of `group` (creating a
    /// group when the round has no settled tools yet) so the action row is
    /// present while tools run and becomes the record once their result bubbles
    /// arrive. With nothing in flight, falls back to the generic phase row.
    /// Returns the group (possibly newly created), or null when there was
    /// nothing in flight and only the phase row was added.
    private ToolGroupBubble addLiveToolRows(ToolGroupBubble group, VBox target,
        string key)
    {
        OpenCodeToolCall[] inFlight;
        foreach (call; _liveToolCalls)
            if (call.name.length > 0) inFlight ~= call;
        foreach (call; _preparingToolCalls)
            if (call.name.length > 0) inFlight ~= call;
        if (inFlight.length > 0)
        {
            if (group is null)
            {
                group = new ToolGroupBubble(new Widget[0]);
                wireToolGroup(group, key);
                target.add(group);
            }
            foreach (call; inFlight)
            {
                bool running;
                foreach (live; _liveToolCalls)
                    if (live.id == call.id) { running = true; break; }
                group.addPart(buildLiveToolRow(call, running));
            }
            group.setLive(true);
            return group;
        }
        if (activityRowWanted())
            target.add(_activityRow);
        return null;
    }

    /// True for the read-only context tools that fold into an "Explored" group.
    private static bool isContextTool(ref const ChatMessage message)
    {
        if (message.role != "tool") return false;
        switch (message.toolName)
        {
            case "read":
            case "glob":
            case "grep":
                return true;
            default:
                return false;
        }
    }

    /// For every message, its 0-based position among siblings (same parent and
    /// role) and the sibling count. A count > 1 marks a message that has an
    /// earlier/later branch run the user can switch to.
    private static void computeSiblingVersions(const ref ChatSession session,
        out size_t[] positions, out size_t[] totals)
    {
        positions.length = session.messages.length;
        totals.length = session.messages.length;
        size_t[string] count, seen;
        foreach (message; session.messages)
        {
            const key = message.parentId ~ "\x1f" ~ message.role;
            count[key] = count.get(key, 0) + 1;
        }
        foreach (index, message; session.messages)
        {
            const key = message.parentId ~ "\x1f" ~ message.role;
            const order = seen.get(key, 0);
            seen[key] = order + 1;
            positions[index] = order;
            totals[index] = count.get(key, 0);
        }
    }

    /// Build the retained bubble for one message, wiring its context menu,
    /// collapse callback and usage footer. Shared by the plain and grouped
    /// paths in rebuildMessageColumn.
    private MessageBubble buildMessageBubble(size_t index,
        ref const ChatMessage message, int latestAssistantIndex,
        size_t[] versionPositions, size_t[] versionTotals,
        string thinkingText = "")
    {
        auto bubble = new MessageBubble();
        bubble.setRole(message.role);
        bubble.setMessageIndex(cast(int) index);
        // Edited prompts / regenerated replies have sibling runs; show the
        // `< n/m >` branch switcher so the user can flip back and continue.
        if (index < versionTotals.length && versionTotals[index] > 1)
        {
            bubble.setVersionInfo(cast(int) versionPositions[index] + 1,
                cast(int) versionTotals[index],
                versionAction(index, -1), versionAction(index, +1));
        }
        bubble.setContent(message.content);
        // A tool-call wrapper with no prose and no reasoning to show is not a
        // visible reply; keep its slot (for index mapping) but collapse it away.
        // A tool-request turn that DID reason stays visible as its own
        // `▸ Thinking` header above its tool rows (each round keeps its own).
        if (message.role == "assistant" && message.toolCalls.length > 0 &&
            message.content.length == 0 && thinkingText.length == 0 &&
            !message.failed)
        {
            bubble.setHidden(true);
        }
        if (message.toolName.length > 0)
            bubble.setToolName(message.toolName);
        if (message.toolArgs.length > 0)
            bubble.setToolArgs(message.toolArgs);
        if (message.role == "tool")
        {
            bubble.setDiff(message.diffAdditions, message.diffDeletions,
                message.toolDiff);
            bubble.setToolElapsed(message.toolElapsedMs);
        }
        // The reasoning passed in is this turn's own chain of thought, so each
        // round shows an expandable "Thinking" block attached to the reply it
        // belongs to — a stable, append-only transcript.
        const showThinking = thinkingText.length > 0;
        if (showThinking)
            bubble.setThinking(thinkingText);
        // Re-apply the user's expand choices before wiring the change callback:
        // a rebuild while the assistant is still streaming must not collapse a
        // tool output or reasoning block the user opened.
        const persistId = message.id;
        if (persistId.length > 0)
        {
            if (auto saved = persistId in _collapsedTool)
                bubble.setCollapsed(*saved);
            if (auto saved = persistId in _thinkingCollapsed)
                bubble.setThinkingCollapsed(*saved);
        }
        if (message.role == "tool" || showThinking)
        {
            // Expanding/collapsing changes the bubble height; re-measure
            // the column WITHOUT snapping the scroll to the bottom, and
            // remember the choice so the next rebuild preserves it.
            bubble.onSizeChanged = delegate()
            {
                if (persistId.length > 0)
                {
                    _collapsedTool[persistId] = bubble.collapsed();
                    _thinkingCollapsed[persistId] = bubble.thinkingCollapsed();
                }
                _messageColumn.invalidate();
                _messagesScroll.invalidate();
            };
        }
        if (message.time.length > 0)
            bubble.setTime(message.time);
        if (message.failed)
            bubble.setFailed("");
        bubble.onContextMenuRequested =
            delegate(int messageIndex, Point globalPosition, string linkTarget)
            {
                showMessageContextMenu(bubble.messageIndex(),
                    globalPosition, bubble, linkTarget);
            };
        // Persisted token usage appears only on the latest assistant reply.
        if (cast(int) index == latestAssistantIndex &&
            (message.totalTokens > 0 || message.completionTokens > 0 ||
             message.tokensPerSecondTenths > 0))
        {
            const tokenText = message.totalTokens > 0
                ? formatThousands(message.totalTokens) ~ " total"
                : formatThousands(message.completionTokens) ~ " output";
            bubble.setUsageText(" • " ~ tokenText ~
                (message.tokensPerSecondTenths > 0 && thinkingText.length == 0
                    ? " · " ~ formatTokenRate(message.tokensPerSecondTenths)
                    : ""));
        }
        // Persist the output-token count on the Thinking header for any turn
        // that produced one, so it survives a column rebuild.
        if (message.completionTokens > 0)
            bubble.setLiveTokens(message.completionTokens, false);
        if (message.tokensPerSecondTenths > 0)
            bubble.setTokenRate(message.tokensPerSecondTenths);
        return bubble;
    }

    /// Only the latest assistant REPLY carries an action pill ("Regenerate",
    /// or "Retry" when it failed). Tool-call wrappers (assistant messages that
    /// merely requested tools) and every other bubble stay clean — their
    /// actions are available from the right-click context menu instead. The
    /// live streaming reply shows no pill. Runs after every message change so
    /// the pills always match the messages.
    private void refreshBubbleActions()
    {
        if (_current < 0) return;
        const children = messageColumnVisuals();
        if (children.length == 0) return;
        const session = &_sessions[_current];

        // The pill belongs to the last MessageBubble that is not the live reply.
        // Groups (which are not MessageBubbles) are skipped, and the message is
        // resolved by the bubble's own stored index rather than its child slot,
        // because a context group can make the two diverge.
        MessageBubble target;
        for (size_t i = children.length; i > 0; --i)
        {
            auto child = cast(MessageBubble) children[i - 1];
            if (child is null) continue;
            if (_streamBubble !is null && child is _streamBubble) continue;
            target = child;
            break;
        }

        foreach (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            bubble.clearAction();
            if (target is null || bubble !is target) continue;
            const messageIndex = bubble.messageIndex();
            if (messageIndex < 0 ||
                messageIndex >= cast(int) session.messages.length)
                continue;
            const message = session.messages[cast(size_t) messageIndex];
            // Only a real assistant reply gets a visible pill; a tool-call
            // wrapper (empty content + tool requests) is not a reply.
            if (message.role == "assistant" && message.toolCalls.length == 0)
            {
                bubble.setAction(message.failed ? "Retry" : "Regenerate",
                    regenerateAction(_current, messageIndex));
                if (!message.failed)
                    bubble.setSecondaryAction("Continue",
                        continueAction(_current, messageIndex));
            }
        }
    }

    /// Delegate factory for the Regenerate/Retry pill. D captures the reused
    /// `foreach` loop slot when a closure is created inline (the loop variable
    /// is shared, so every pill would target the final message), so the
    /// session/message indices are bound through a factory function instead.
    private void delegate() regenerateAction(int sessionIndex, int messageIndex)
    {
        return delegate() { regenerateLastReply(sessionIndex, messageIndex); };
    }

    /// Delegate factory for the Edit & resend pill (see regenerateAction).
    private void delegate() editResendAction(int sessionIndex, int messageIndex)
    {
        return delegate() { editAndResend(sessionIndex, messageIndex); };
    }

    /// Delegate factory for a branch-version arrow (see regenerateAction).
    private void delegate() versionAction(size_t messageIndex, int direction)
    {
        const sessionIndex = _current;
        const index = cast(int) messageIndex;
        return delegate() { switchMessageBranch(sessionIndex, index, direction); };
    }

    /// Switch the visible branch to a sibling version of `messageIndex` (an
    /// edited prompt or a regenerated reply), then follow that run to its tip.
    /// The old run stays in `messages` so the user can come back at any time.
    private void switchMessageBranch(int sessionIndex, int messageIndex,
        int direction)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 ||
            messageIndex >= cast(int) session.messages.length)
            return;
        if (_client.busy() || _turnTiming ||
            _pendingToolCalls.length > 0 || _pendingToolResults > 0)
        {
            _client.cancel();
            // Abandon the interrupted turn so the killed tool's late result
            // cannot restart the chat via a continuation request.
            _turnCancelled = true;
            _toolCancellation.cancel();
            _suppressDoneStatus = true;
        }
        cancelPendingTools();
        const siblings = siblingMessages(*session,
            cast(size_t) messageIndex);
        if (siblings.length < 2) return;
        int position = -1;
        foreach (i, index; siblings)
            if (cast(int) index == messageIndex)
            {
                position = cast(int) i;
                break;
            }
        if (position < 0) return;
        const target = position + direction;
        if (target < 0 || target >= cast(int) siblings.length) return;
        const leaf = deepestDescendant(*session,
            siblings[cast(size_t) target]);
        session.activeLeafId = session.messages[leaf].id;
        publishThreadUpdated(*session);
        _streamBubble = null;
        _editMessageIndex = -1;
        rebuildMessageColumn();
        updateSessionList(false);
        markDirty();
        refreshUsageBadge();
        updateStatus("Viewing version " ~ to!string(target + 1) ~ " of " ~
            to!string(siblings.length) ~ ".");
    }


    private void addUserBubble(string text)
    {
        auto bubble = new MessageBubble();
        bubble.setRole("user");
        bubble.setContent(text);
        if (_current >= 0 && _sessions[_current].messages.length > 0)
        {
            const last = _sessions[_current].messages[$ - 1];
            if (last.time.length > 0) bubble.setTime(last.time);
            bubble.setMessageIndex(
                cast(int) _sessions[_current].messages.length - 1);
            bubble.onContextMenuRequested =
                delegate(int messageIndex, Point globalPosition,
                    string linkTarget)
                {
                    showMessageContextMenu(bubble.messageIndex(),
                        globalPosition, bubble, linkTarget);
                };
        }
        _messageColumn.add(bubble);
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
        // The first prompt was appended straight to the column (no rebuild yet
        // — that happens when the reply begins), so drop the welcome overlay
        // now instead of leaving it over the user's own message for a frame.
        updateIntroOverlay();
        refreshBubbleActions();
    }

    private void beginAssistantMessage()
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        _preparingToolCalls.length = 0;
        // Each assistant turn counts its own output from zero.
        _liveOutputBytes = 0;
        _liveOutputTokens = 0;
        _liveTokenRateTenths = 0;
        _tokenRateBaseTokens = 0;
        _tokenRateStarted = false;
        _liveTotalTokens = 0;
        auto session = &_sessions[sessionIndex];
        ChatMessage message;
        message.role = "assistant";
        message.time = currentTimestamp();
        appendMessage(*session, message);

        if (_current != sessionIndex)
        {
            markDirty();
            updateSessionList(false);
            return;
        }

        _streamBubble = new MessageBubble();
        _streamBubble.setRole("assistant");
        _streamBubble.setStreaming(true);
        // Tag it with its message slot so a rebuild mid-stream (e.g. when a
        // tool-call progress event arrives) can re-add the same live bubble
        // instead of orphaning it.
        _streamBubble.setMessageIndex(cast(int) session.messages.length - 1);
        // The request headers are in; the model is now thinking or about to
        // emit its first token. Keep the in-flow row honest about the phase
        // without the "Writing…" wording, which read like a file write and
        // vanished at completion (the Thinking header's token count now carries
        // that progress signal).
        setActivity(session.thinking ? "Thinking…" : "Waiting for the model…");
        // Rebuild rather than appending the bubble directly: a row already
        // pinned for a previous phase (e.g. "Waiting for the model…") would
        // otherwise stay ABOVE the reply it describes. rebuildMessageColumn
        // nests the live reply before its phase row.
        rebuildMessageColumn();
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
        refreshBubbleActions();
    }

    private void appendStreamDelta(string text, bool reasoning)
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        if (!_receivedFirstDelta)
        {
            _receivedFirstDelta = true;
            updateStatus("Generating…");
        }
        // Reasoning and answer text are different phases. Reasoning is shown by
        // the in-bubble "▸ Thinking" header, which pulses while it streams. The
        // header also carries a live output-token count that keeps climbing for
        // BOTH phases and is kept after the turn ends; the generic phase word
        // ("Writing…") was dropped because it vanished at completion and read
        // like a file write.
        auto session = &_sessions[sessionIndex];
        if (session.messages.length == 0) return;
        auto message = &session.messages[$ - 1];
        if (reasoning)
        {
            message.reasoning ~= text;
            if (_streamBubble !is null && _current == sessionIndex)
            {
                _streamBubble.appendThinking(text);
                _streamBubble.setThinkingLive(true);
            }
            // The header now speaks for this phase; drop "Waiting for the model…".
            clearActivity();
        }
        else
        {
            if (_streamBubble !is null && _current == sessionIndex)
                _streamBubble.setThinkingLive(false);
            message.content ~= text;
            if (_streamBubble !is null && _current == sessionIndex)
                _streamBubble.appendContent(text);
            // Drop the "Waiting for the model…" row now that the answer itself
            // is visibly streaming (no "Writing…" replacement any more).
            clearActivity();
        }
        // Advance the live token counter with an ~4-bytes-per-token estimate;
        // the provider's exact completion count replaces it via `usage`/`done`.
        _liveOutputBytes += cast(long) text.length;
        const estimate = (_liveOutputBytes + 3) / 4;
        if (estimate > _liveOutputTokens) _liveOutputTokens = estimate;
        updateLiveTokenRate();
        if (_streamBubble is null || _current != sessionIndex)
        {
            markDirty();
            return;
        }
        _streamBubble.setLiveTokens(_liveOutputTokens, true);
        _streamBubble.setTokenRate(_liveTokenRateTenths);
        // A reasoning reply already has the compact stats in its Thinking
        // header. Only reserve the footer for direct replies with no header.
        if (!_streamBubble.hasThinkingForTesting())
            _streamBubble.setUsageText(liveTokenStatsText());
        // The streamed text changes the bubble height, so the ScrollView must
        // re-measure to keep auto-follow at the bottom as the reply grows.
        _messagesScroll.invalidate();
    }

    /// Decode throughput begins at the first observed token sample, excluding
    /// request/connection/model cold-start latency (time-to-first-token).
    private void updateLiveTokenRate()
    {
        const now = MonoTime.currTime;
        if (!_tokenRateStarted)
        {
            _tokenRateStarted = true;
            _tokenRateStartedAt = now;
            _tokenRateBaseTokens = _liveOutputTokens;
            return;
        }
        const elapsedMs = (now - _tokenRateStartedAt).total!"msecs";
        const produced = _liveOutputTokens - _tokenRateBaseTokens;
        if (elapsedMs >= 100 && produced > 0)
            _liveTokenRateTenths = cast(int)
                ((produced * 10_000 + elapsedMs / 2) / elapsedMs);
    }

    private string liveTokenStatsText() const
    {
        string result = " • ";
        if (_liveTotalTokens > 0)
            result ~= formatThousands(_liveTotalTokens) ~ " total";
        else
            result ~= "~" ~ formatThousands(cast(int) _liveOutputTokens) ~
                " output";
        if (_liveTokenRateTenths > 0)
            result ~= " · " ~ formatTokenRate(_liveTokenRateTenths);
        return result;
    }

    private void finishAssistantMessage(bool cancelled, int promptTokens = 0,
        int completionTokens = 0, int totalTokens = 0, bool terminal = true,
        string finishReason = "")
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (terminal || cancelled) setTurnActiveMarker(false);
        setTurnInFlight(false);
        _preparingToolCalls.length = 0;
        clearActivity();
        // The turn is over: freeze its clock before rebuilding so the durable
        // completion separator appears immediately above the final answer.
        if (terminal || cancelled) freezeTurnTiming();
        if (_streamBubble !is null)
        {
            // Settle the final count (exact when the provider reported it) and
            // stop the pulse; the header keeps the number so the row stays
            // meaningful after the phase indicator is gone.
            // Provider usage is authoritative even when byte/4 overshot. The
            // old max-only rule looked monotonic but could leave a wrong count.
            if (completionTokens > 0)
                _liveOutputTokens = completionTokens;
            updateLiveTokenRate();
            _streamBubble.setLiveTokens(_liveOutputTokens, false);
            _streamBubble.setTokenRate(_liveTokenRateTenths);
            _streamBubble.setThinkingLive(false);
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        // The synthetic (`finishStreamForTesting`) and estimate-only paths pass
        // no explicit completion count; persist the live count so a rebuild
        // still shows it on the Thinking header after the stream bubble is gone.
        if (completionTokens == 0 && _liveOutputTokens > 0)
            completionTokens = cast(int) _liveOutputTokens;
        if (sessionIndex >= 0 && sessionIndex < cast(int) _sessions.length &&
            _sessions[sessionIndex].messages.length > 0)
        {
            auto message = &_sessions[sessionIndex].messages[$ - 1];
            if (message.time.length == 0) message.time = currentTimestamp();
            message.finishReason = cancelled ? "cancelled" : finishReason;
            if (completionTokens > 0 || totalTokens > 0)
            {
                message.promptTokens = promptTokens;
                message.completionTokens = completionTokens;
                message.totalTokens = totalTokens;
            }
            message.tokensPerSecondTenths = _liveTokenRateTenths;
            publishMessageEvent(AgentEventKind.itemUpdated,
                _sessions[sessionIndex], *message);
        }
        if (sessionIndex >= 0 && sessionIndex < cast(int) _sessions.length &&
            (terminal || cancelled))
            publishRuntimeEvent(cancelled ? AgentEventKind.turnInterrupted :
                AgentEventKind.turnCompleted, _sessions[sessionIndex],
                runtimeTurnId(_sessions[sessionIndex]));
        // The streamed bubble was built for streaming only (no timestamp, usage
        // footer, context menu or collapse wiring). Rebuild so the settled view
        // is canonical immediately — otherwise the transcript silently
        // rearranges the next time anything triggers a rebuild.
        rebuildMessageColumn();
        string status = cancelled ? "Stopped." : terminal ? "Done." :
            "Continuing…";
        if (!cancelled && totalTokens > 0)
        {
            _lastUsageText = " • " ~ formatThousands(totalTokens) ~ " tokens";
            status ~= _lastUsageText;
        }
        if (_suppressDoneStatus)
            _suppressDoneStatus = false;
        else
            updateStatus(status);
        _messagesScroll.invalidate();
        markDirty();
        refreshBubbleActions();
        refreshUsageBadge();
    }

    private void delegate() continueAction(int sessionIndex, int messageIndex)
    {
        return delegate() { continueFromReply(sessionIndex, messageIndex); };
    }

    private static string incompleteChecklistGatePrompt()
    {
        return "Completion gate: reconcile the durable checklist before " ~
            "producing another user-facing report. If the unfinished items " ~
            "are already complete, call update_plan once to mark them " ~
            "completed, then respond with only a brief checklist " ~
            "confirmation; do not repeat the completion report. Otherwise " ~
            "continue with the next concrete unfinished item and update the " ~
            "checklist. If blocked, report the exact blocker.";
    }

    /// A provider `done` is not automatically task completion.  First consume
    /// queued steering; then, for file-changing work, require a focused check
    /// before the durable task can enter the completed state.
    private void continueOrCompleteTask(bool cancelled)
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        auto session = &_sessions[sessionIndex];
        if (cancelled)
        {
            session.taskStatus = "blocked";
            publishThreadUpdated(*session);
            markDirty();
            return;
        }
        if (appendQueuedGuidance(*session))
        {
            session.taskStatus = "active";
            publishThreadUpdated(*session);
            setTurnActiveMarker(true, session.id);
            setTurnInFlight(true);
            updateStatus("Applying queued guidance…");
            startChatRequest(sessionIndex, false);
            return;
        }
        if (hasIncompleteTaskSteps(*session))
        {
            if (session.taskStatus != "reviewing")
            {
                session.taskStatus = "reviewing";
                ChatMessage gate;
                gate.role = "user";
                gate.internal = true;
                gate.content = incompleteChecklistGatePrompt();
                appendMessage(*session, gate);
                publishThreadUpdated(*session);
                markDirty();
                if (_current == sessionIndex) rebuildMessageColumn();
                updateStatus("Reviewing unfinished checklist…");
                startChatRequest(sessionIndex, false);
                return;
            }
            session.taskStatus = "blocked";
            updateStatus("Finished with checklist items still incomplete.");
            publishThreadUpdated(*session);
            markDirty();
            return;
        }
        if (session.verificationStatus == "required")
        {
            if (session.taskStatus != "verifying")
            {
                session.taskStatus = "verifying";
                ChatMessage gate;
                gate.role = "user";
                gate.internal = true;
                gate.content = "Completion gate: files changed in this task, " ~
                    "but no successful verification has been recorded since " ~
                    "the last change. Run the most focused relevant check now. " ~
                    "Do not claim completion unless it succeeds; if it cannot " ~
                    "be run, report the concrete blocker.";
                appendMessage(*session, gate);
                publishThreadUpdated(*session);
                markDirty();
                if (_current == sessionIndex) rebuildMessageColumn();
                setTurnActiveMarker(true, session.id);
                setTurnInFlight(true);
                updateStatus("Verifying before completion…");
                startChatRequest(sessionIndex, false);
                return;
            }
            session.taskStatus = "blocked";
            session.verificationStatus = "failed";
            updateStatus("Finished with verification still incomplete.");
        }
        else
            session.taskStatus = "completed";
        publishThreadUpdated(*session);
        markDirty();
    }

    private bool taskContinuesAfterDone(bool cancelled) const
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (cancelled || sessionIndex < 0 ||
            sessionIndex >= cast(int) _sessions.length) return false;
        const session = _sessions[sessionIndex];
        if (session.queuedGuidance.length > 0) return true;
        if (hasIncompleteTaskSteps(session) &&
            session.taskStatus != "reviewing") return true;
        return session.verificationStatus == "required" &&
            session.taskStatus != "verifying";
    }

    private void failAssistantMessage(string error)
    {
        const sessionIndex = turnOwnerSessionIndex();
        setTurnActiveMarker(false);
        setTurnInFlight(false);
        _preparingToolCalls.length = 0;
        freezeTurnTiming();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
        {
            clearActivity();
            updateStatus("Error: " ~ error);
            return;
        }
        auto session = &_sessions[sessionIndex];
        // The failure can arrive before any assistant turn exists (the request
        // was rejected before the first streamed byte, so `chatBegin` never
        // fired). Create the reply turn first: without this the error text was
        // appended to the USER's prompt and marked it failed, corrupting the
        // history and rendering the user's own message as an error.
        if (session.messages.length == 0 ||
            session.messages[$ - 1].role != "assistant")
        {
            ChatMessage reply;
            reply.role = "assistant";
            reply.time = currentTimestamp();
            appendMessage(*session, reply);
        }
        clearActivity();
        auto message = &session.messages[$ - 1];
        message.content ~= (message.content.length == 0 ? "" : "\n\n") ~
            "Error:\n\n```text\n" ~
            error.replace("```", "`` `") ~ "\n```";
        message.failed = true;
        session.taskStatus = "blocked";
        publishThreadUpdated(*session);
        publishMessageEvent(AgentEventKind.itemUpdated, *session, *message);
        publishRuntimeEvent(AgentEventKind.turnFailed, *session,
            runtimeTurnId(*session), "", "", errorPayload(error));
        if (_streamBubble !is null)
        {
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        // Render the canonical settled view (the streamed bubble lacked the
        // timestamp footer, context menu and collapse wiring).
        rebuildMessageColumn();
        updateStatus("Request failed. See the conversation for details.");
        markDirty();
        refreshBubbleActions();
    }

    // -- tool loop ---------------------------------------------------------

    /// Drop any in-flight tool batch state. Used when the user branches away
    /// (edit/regenerate/version switch) so late tool results from the abandoned
    /// run cannot append to the newly selected branch.
    private void cancelPendingTools()
    {
        setTurnActiveMarker(false);
        setTurnInFlight(false);
        const hadLiveRows = _preparingToolCalls.length > 0 ||
            _liveToolCalls.length > 0;
        _pendingToolCalls.length = 0;
        _liveToolCalls.length = 0;
        _preparingToolCalls.length = 0;
        _pendingToolResults = 0;
        _lastToolSignature = "";
        _lastToolRepeatCount = 0;
        _lastFailureSignature = "";
        _lastFailureRepeatCount = 0;
        _pendingProgressGuidance = "";
        clearActivity();
        // Branching away abandons the turn: stop its clock so it cannot keep
        // ticking while another branch is displayed.
        freezeTurnTiming();
        // A live tool row has no label of its own, so `clearActivity` alone
        // leaves it pinned to the abandoned run; rebuild to drop it.
        if (hadLiveRows) rebuildMessageColumn();
    }

    /// Show (or update) the in-flow activity row. It fills the gaps where the
    /// transcript would otherwise look frozen: before the first token and
    /// between tool rounds. While live tool rows exist they already say what is
    /// happening, so the row is suppressed rather than duplicating them. A
    /// non-empty label pins the row to the end of the column; an empty one
    /// removes it.
    private void setActivity(string label)
    {
        if (_activityRow is null) _activityRow = new ActivityRow();
        const wasPresent = _activityRow.parent() !is null;
        _activityRow.setLabel(label);
        _activityRow.setLive(label.length > 0);
        if (_current < 0) return;
        const present = activityRowWanted();
        // Only rebuild when the row enters or leaves the transcript; a phase
        // change within the same row is a cheap invalidate.
        if (wasPresent != present) rebuildMessageColumn();
        else _activityRow.invalidate();
    }

    /// Whether the phase row should currently be part of the transcript. It is
    /// shown only when it has a label and there is no live tool row to speak for
    /// the current step (a live row plus the phase row was pure redundancy).
    private bool activityRowWanted() const
    {
        return _activityRow !is null && _activityRow.hasLabel() &&
            viewingTurnOwner() &&
            _preparingToolCalls.length == 0 && _liveToolCalls.length == 0;
    }

    /// Remove the in-flow activity row (reply finished, failed or cancelled).
    private void clearActivity()
    {
        if (_activityRow is null) return;
        const wasPresent = _activityRow.parent() !is null;
        _activityRow.setLabel("");
        _activityRow.setLive(false);
        if (wasPresent && _current >= 0 && viewingTurnOwner())
            rebuildMessageColumn();
    }

    /// The model is still generating tool-call arguments: it has named the
    /// tools but the stream has not finished. Refresh the single aggregate live
    /// row so the UI shows what is coming while a large payload (a whole file
    /// for `write`) streams in, instead of looking stalled after the assistant
    /// text.
    private void handleToolCallProgress(const OpenCodeEvent event)
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        if (event.toolCalls.length == 0) return;
        const previousShape = toolProgressRenderShape(_preparingToolCalls);
        const nextShape = toolProgressRenderShape(event.toolCalls);
        const activityWasPresent = _activityRow !is null &&
            _activityRow.parent() !is null;
        _preparingToolCalls = event.toolCalls.dup;
        updateStatus("Preparing tools…");
        // The aggregate live row already says what is being prepared, so the
        // generic phase row would only duplicate it. Drop it; it comes back
        // when the next round waits on the model with no live row to show.
        clearActivity();
        // Tool arguments commonly arrive a few bytes per SSE event. Rebuilding
        // 120 retained widgets for every fragment caused multi-GB growth. The
        // live preview only needs a refresh when a tool appears/changes or each
        // 512-byte detail bucket; `clearActivity` already rebuilt when it
        // removed the phase row.
        if (!activityWasPresent && _current == sessionIndex &&
            previousShape != nextShape)
            rebuildMessageColumn();
    }

    private static string toolProgressRenderShape(
        const(OpenCodeToolCall)[] calls)
    {
        auto shape = appender!string();
        foreach (call; calls)
        {
            int additions, deletions;
            previewToolDiff(call.name, call.arguments, additions, deletions);
            shape.put(call.id ~ ":" ~ call.name ~ ":" ~
                to!string(call.arguments.length / 512) ~ ":" ~
                to!string(additions) ~ ":" ~ to!string(deletions) ~ ";");
        }
        return shape.data;
    }

    private static bool isReadOnlyExplorationTool(string name)
    {
        return name == "read" || name == "grep" || name == "glob" ||
            name == "dshell";
    }

    private static bool isCommentOnlyChangedLine(string body)
    {
        if (body.length == 0) return true;
        if (body[0] == '*') return true;
        if (body.length >= 2 &&
            (body[0 .. 2] == "//" || body[0 .. 2] == "/*" ||
             body[0 .. 2] == "*/")) return true;
        return false;
    }

    /// A successful mutation only advances task state when it changed the
    /// requested artifact. Whitespace/comment-only edits are useful at times,
    /// but they must not let a stuck model satisfy the implementation gate.
    private static bool isSubstantiveMutation(string name, bool failed,
        int additions, int deletions, string diff)
    {
        if (failed || !isMutatingTool(name)) return false;
        if (diff.length == 0)
            return name == "remove" || additions > 0 || deletions > 0;
        foreach (line; diff.splitLines())
        {
            if (line.length < 2 || (line[0] != '+' && line[0] != '-'))
                continue;
            if (line.length >= 3 &&
                (line[0 .. 3] == "+++" || line[0 .. 3] == "---"))
                continue;
            const body = strip(line[1 .. $]);
            if (!isCommentOnlyChangedLine(body)) return true;
        }
        return false;
    }

    private static int readOnlyExplorationCount(const ref ChatSession session)
    {
        int count;
        bool mutated;
        foreach (index; activeMessagePath(session))
        {
            const message = session.messages[index];
            if (message.role == "user" && !message.internal)
            {
                count = 0;
                mutated = false;
                continue;
            }
            if (message.role != "tool") continue;
            if (isSubstantiveMutation(message.toolName, message.failed,
                message.diffAdditions, message.diffDeletions,
                message.toolDiff))
            {
                mutated = true;
                continue;
            }
            // Native read/search calls count across the entire user request.
            // A successful edit is progress, but it must not erase the
            // evidence budget and reopen an unbounded inspection loop.
            // Before the first real edit, generic process execution counts too
            // so a model cannot evade the budget with `run python open(...)`.
            if (isReadOnlyExplorationTool(message.toolName) ||
                (!mutated && (message.toolName == "run" ||
                    message.toolName == "bash")))
                ++count;
        }
        return count;
    }

    private static bool hasSubstantiveMutation(
        const ref ChatSession session)
    {
        bool found;
        foreach (index; activeMessagePath(session))
        {
            const message = session.messages[index];
            if (message.role == "user" && !message.internal)
            {
                found = false;
                continue;
            }
            if (message.role == "tool" && isSubstantiveMutation(
                message.toolName, message.failed, message.diffAdditions,
                message.diffDeletions, message.toolDiff))
                found = true;
        }
        return found;
    }

    private static bool hasExplorationCheckpoint(
        const ref ChatSession session)
    {
        bool found;
        foreach (index; activeMessagePath(session))
        {
            const message = session.messages[index];
            if (message.role == "user" && !message.internal)
            {
                found = false;
                continue;
            }
            if (message.internal && message.content.length >= 23 &&
                message.content[0 .. 23] == "Exploration checkpoint:")
                found = true;
        }
        return found;
    }

    /// Add orchestration guidance only after the current assistant tool_calls
    /// has received every tool result. This preserves strict tool pairing and
    /// keeps the note hidden from the user-facing transcript.
    private bool appendPendingProgressGuidance(ref ChatSession session)
    {
        if (_pendingProgressGuidance.length == 0) return false;
        ChatMessage guidance;
        guidance.role = "user";
        guidance.internal = true;
        guidance.content = "Progress guidance: " ~ _pendingProgressGuidance;
        appendMessage(session, guidance);
        _pendingProgressGuidance = "";
        publishThreadUpdated(session);
        markDirty();
        if (viewingTurnOwner()) rebuildMessageColumn();
        return true;
    }

    private void appendExplorationCheckpoint(ref ChatSession session)
    {
        advanceAutomaticPlanToImplementation(session);
        ChatMessage checkpoint;
        checkpoint.role = "user";
        checkpoint.internal = true;
        checkpoint.content = "Exploration checkpoint: you likely have enough " ~
            "source evidence to act. Prefer the smallest correct edit now. " ~
            "Focused inspection remains available when one concrete unknown " ~
            "still blocks the edit, but do not repeat known reads or broaden " ~
            "the search scope. If a command reaches a soft deadline, inspect " ~
            "its progress report and decide whether a longer wait is justified.";
        appendMessage(session, checkpoint);
        publishThreadUpdated(session);
        markDirty();
        if (viewingTurnOwner()) rebuildMessageColumn();
        updateStatus("Evidence gathered — asking the model to edit…");
    }

    /// The model requested tool calls. Finalize the assistant message with the
    /// request (so it persists and is replayed on regeneration), then execute
    /// each tool on a worker thread. Results are pushed back through the
    /// client's event queue as toolResult events.
    private void handleToolCalls(const OpenCodeEvent event)
    {
        _preparingToolCalls.length = 0;
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        auto session = &_sessions[sessionIndex];
        if (session.messages.length == 0) return;
        auto message = &session.messages[$ - 1];
        if (message.role != "assistant") return;

        if (!_settings.toolsEnabled || event.toolCalls.length == 0)
        {
            message.content ~= (message.content.length == 0 ? "" : "\n\n") ~
                "⚠ The model requested tools, but tools are disabled.";
            message.failed = true;
            finishAssistantMessage(false);
            return;
        }

        message.toolCalls = event.toolCalls.dup;
        // The tool request ends this assistant reply (reasoning phase included)
        // but the user turn continues, so `finishAssistantMessage` never runs
        // between rounds. Persist the live output-token count and throughput
        // onto the message BEFORE the stream bubble is torn down below; the
        // rebuild that follows otherwise renders the Thinking header from a
        // message with zeroed stats and the token / t/s indicator disappears
        // instead of keeping its place. The continuation's `chatBegin` cannot
        // do this: it runs after this teardown, when `_streamBubble` is null.
        if (_liveOutputTokens > 0 &&
            message.completionTokens < cast(int) _liveOutputTokens)
            message.completionTokens = cast(int) _liveOutputTokens;
        if (_liveTokenRateTenths > 0)
            message.tokensPerSecondTenths = _liveTokenRateTenths;
        publishMessageEvent(AgentEventKind.itemUpdated, *session, *message);
        if (_streamBubble !is null)
        {
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        markDirty();

        // Repeated calls still execute. On the third consecutive identical
        // batch, schedule a hidden note for the next model round so it can use
        // the fresh result while reconsidering its approach.
        const signature = toolCallSignature(event.toolCalls);
        if (signature.length > 0 && signature == _lastToolSignature)
        {
            ++_lastToolRepeatCount;
        }
        else
        {
            _lastToolSignature = signature;
            _lastToolRepeatCount = 1;
        }
        if (_lastToolRepeatCount == repeatGuidanceThreshold)
        {
            _pendingProgressGuidance = "The same tool batch has now run three " ~
                "consecutive times. Its newest result is available. Before " ~
                "requesting it again, identify what changed or what new fact " ~
                "another repetition would establish; otherwise choose the " ~
                "next different action that advances the task.";
        }

        const toolCount = event.toolCalls.length;
        // Publish the running calls before the rebuild: it must already show the
        // live rows, otherwise they blink out for one frame.
        _pendingToolCalls = event.toolCalls.dup;
        _liveToolCalls = event.toolCalls.dup;
        _pendingToolResults = cast(int) event.toolCalls.length;
        updateStatus("Running " ~ to!string(toolCount) ~ " tool call(s)…");
        // Each running call already gets its own live row (or the aggregated
        // "Exploring" row for context tools), so the generic phase row is
        // redundant; hide it while the tool rows speak for themselves.
        clearActivity();

        // Show the live "Exploring" row while the context tools are running.
        if (_current == sessionIndex) rebuildMessageColumn();
        const requestId = _activeRequestId;
        const workspace = workspaceForSession(sessionIndex);
        ChangeContext changeContext;
        changeContext.conversationId = _sessions[sessionIndex].id;
        changeContext.turnId = to!string(requestId);
        // Reset before the worker is visible to the UI. A Stop click can only
        // occur after this handler returns, so the worker can no longer clear a
        // cancellation that the user just requested.
        _toolCancellation.reset();
        // The UI may clear/replace its live arrays as soon as the user cancels
        // or navigates. Give the worker an immutable batch it exclusively owns.
        auto workerCalls = _pendingToolCalls.dup;
        auto client = _client;
        auto cancellation = _toolCancellation;
        auto worker = new Thread({
            runToolWorker(client, sessionIndex, requestId,
                workerCalls, workspace, cancellation, changeContext);
        });
        worker.isDaemon = true;
        worker.start();
    }

    /// A stable signature for a batch of tool calls (name + arguments), used
    /// to detect the model repeating the same calls.
    private static string toolCallSignature(const(OpenCodeToolCall)[] calls)
    {
        if (calls.length == 0) return "";
        auto builder = appender!string();
        foreach (call; calls)
            builder.put(call.name ~ "(" ~ call.arguments ~ ");");
        return builder.data;
    }

    /// Worker thread body: execute each tool in the batch and push the results
    /// back into the client event queue, which the UI drains on the next tick.
    /// Consecutive read-only calls run together; mutating or process-launching
    /// calls are exclusive and retain model order. Results are also published
    /// in model order, not completion order, so parallelism cannot reshuffle
    /// the transcript.
    private static void runToolWorker(OpenCodeClient client, int sessionIndex,
        ulong requestId, const(OpenCodeToolCall)[] calls, string workspace,
        ToolCancellation cancellation, ChangeContext changeContext)
    {
        size_t slot;
        while (slot < calls.length)
        {
            if (!toolSupportsParallel(calls[slot]))
            {
                publishToolResult(client, calls[slot],
                    executeTool(calls[slot], workspace, cancellation,
                        changeContext), requestId);
                ++slot;
                continue;
            }

            // Only a contiguous read-only lane is concurrent. An edit/write/
            // patch/run acts as a barrier, so a later read can observe it and
            // two workspace mutations can never race each other.
            size_t end = slot + 1;
            while (end < calls.length && toolSupportsParallel(calls[end]))
                ++end;
            // Run the lane in bounded waves. Four concurrent filesystem reads
            // saturate typical laptop storage without creating an unbounded
            // collection of stacks and scheduler contention.
            size_t wave = slot;
            while (wave < end)
            {
                const waveEnd = wave + maxParallelToolWorkers < end
                    ? wave + maxParallelToolWorkers : end;
                ParallelToolJob[] jobs;
                Thread[] workers;
                foreach (call; calls[wave .. waveEnd])
                {
                    auto job = new ParallelToolJob(call, workspace,
                        cancellation);
                    jobs ~= job;
                    auto worker = new Thread(&job.run);
                    worker.isDaemon = true;
                    workers ~= worker;
                    worker.start();
                }
                foreach (worker; workers) worker.join();
                foreach (job; jobs)
                    publishToolResult(client, job.call, job.execution,
                        requestId);
                wave = waveEnd;
            }
            slot = end;
        }
    }

    /// Explicit allow-list, like Codex's per-tool `supports_parallel` metadata.
    /// Unknown tools default to exclusive. `dshell` only exposes where/list/
    /// info and is therefore read-only; process execution and all file-changing
    /// tools deliberately stay out of this list.
    private static bool toolSupportsParallel(const ref OpenCodeToolCall call)
    {
        return call.name == "read" || call.name == "glob" ||
            call.name == "grep" || call.name == "dshell";
    }

    private static final class ParallelToolJob
    {
        OpenCodeToolCall call;
        string workspace;
        ToolExecution execution;
        ToolCancellation cancellation;

        this(const ref OpenCodeToolCall source, string workspace,
            ToolCancellation cancellation)
        {
            this.call = source;
            this.workspace = workspace;
            this.cancellation = cancellation;
        }

        void run()
        {
            execution = executeTool(call, workspace, cancellation);
        }
    }

    private static void publishToolResult(OpenCodeClient client,
        const ref OpenCodeToolCall call, const ToolExecution execution,
        ulong requestId)
    {
        OpenCodeEvent result;
        result.kind = OpenCodeEventKind.toolResult;
        result.text = execution.output;
        result.toolName = call.name;
        result.toolCallId = call.id;
        result.toolFailed = execution.failed;
        result.diffAdditions = execution.additions;
        result.diffDeletions = execution.deletions;
        result.diffText = execution.diff;
        result.elapsedMs = execution.elapsedMs;
        result.reasoning = false;
        result.requestId = requestId;
        client.pushLocalEvent(result);
    }

    /// A tool finished executing: append a `tool` role message with its output
    /// and, once every call in the batch has reported, re-send the enriched
    /// history so the model can answer with the results available.
    private void applyToolResult(const OpenCodeEvent event)
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length ||
            _turnCancelled || _pendingToolCalls.length == 0) return;
        auto session = &_sessions[sessionIndex];

        // The command arguments come from the original tool call, matched by
        // its id, so the result bubble can show the full command.
        string toolArgs;
        foreach (call; _pendingToolCalls)
        {
            if (call.id == event.toolCallId)
            {
                toolArgs = call.arguments;
                break;
            }
        }
        // Drop the reported call from the live set so the "Exploring" row only
        // counts the context tools that are still running.
        foreach (i, call; _liveToolCalls)
            if (call.id == event.toolCallId)
            {
                _liveToolCalls =
                    _liveToolCalls[0 .. i] ~ _liveToolCalls[i + 1 .. $];
                break;
            }

        ChatMessage toolMessage;
        toolMessage.role = "tool";
        toolMessage.content = event.text;
        toolMessage.toolCallId = event.toolCallId;
        toolMessage.toolName = event.toolName;
        toolMessage.toolArgs = toolArgs;
        toolMessage.failed = event.toolFailed;
        toolMessage.diffAdditions = event.diffAdditions;
        toolMessage.diffDeletions = event.diffDeletions;
        toolMessage.toolDiff = event.diffText;
        toolMessage.toolElapsedMs = event.elapsedMs;
        toolMessage.time = currentTimestamp();
        appendMessage(*session, toolMessage);

        if (!event.toolFailed && event.toolName == "update_plan")
            applyDurablePlan(*session, toolArgs);
        if (isSubstantiveMutation(event.toolName, event.toolFailed,
            event.diffAdditions, event.diffDeletions, event.diffText))
        {
            completeAutomaticImplementation(*session);
            session.verificationStatus = "required";
            session.taskStatus = "active";
            publishThreadUpdated(*session);
        }
        else if (!event.toolFailed && isVerificationTool(event.toolName,
            toolArgs) &&
            session.verificationStatus == "required")
        {
            completeAutomaticVerification(*session);
            session.verificationStatus = "passed";
            session.taskStatus = "active";
            publishThreadUpdated(*session);
        }

        // Progress guidance: remember the last failure signature
        // (tool name + first output line) and how many times in a row it has
        // repeated. Any success is progress and clears it.
        if (event.toolFailed)
        {
            const failSignature =
                event.toolName ~ "|" ~ firstLineOf(event.text);
            if (failSignature == _lastFailureSignature)
                ++_lastFailureRepeatCount;
            else
            {
                _lastFailureSignature = failSignature;
                _lastFailureRepeatCount = 1;
            }
            if (_lastFailureRepeatCount == failureGuidanceThreshold)
                _pendingProgressGuidance = "The same tool failure occurred " ~
                    "three times. The failure is recorded; do not assume the " ~
                    "tool is forbidden, but change inputs or approach unless " ~
                    "another attempt tests a specific new hypothesis.";
        }
        else
        {
            _lastFailureSignature = "";
            _lastFailureRepeatCount = 0;
        }

        // Rebuild the column so consecutive context tool results (read/glob/
        // grep) fold into a single "Explored" group and diffs pick up their
        // green/red counters and line-numbered bodies. Tool runs are infrequent
        // enough that a full rebuild is cheaper than tracking the grouping
        // incrementally, and it snaps the scroll to the newest output while the
        // model is still working (matching the previous incremental behaviour).
        _toolTranscriptDirty = true;
        if (!_batchingToolResults)
            flushToolTranscriptChanges();

        --_pendingToolResults;
        if (_pendingToolResults <= 0)
        {
            _pendingToolCalls.length = 0;
            _liveToolCalls.length = 0;
            _preparingToolCalls.length = 0;
            _messagesScroll.invalidate();
            refreshBubbleActions();
            appendPendingProgressGuidance(*session);
            if (!_toolContinuationPaused)
            {
                appendQueuedGuidance(*session);
                if (readOnlyExplorationCount(*session) >=
                    explorationCheckpointCalls &&
                    !hasExplorationCheckpoint(*session))
                    appendExplorationCheckpoint(*session);
                startChatRequest(sessionIndex, false);
            }
        }
    }

    private static bool isMutatingTool(string name)
    {
        return name == "write" || name == "edit" || name == "apply_patch" ||
            name == "remove";
    }

    private static bool isVerificationTool(string name, string arguments)
    {
        if (name != "run" && name != "bash") return false;
        try
        {
            auto root = parseJSON(arguments);
            if (root.type == JSONType.object)
                if (auto background = "background" in root.object)
                    if (background.type == JSONType.true_) return false;
        }
        catch (Exception) {}
        const lower = arguments.toLower();
        foreach (signal; ["test", "build", "check", "lint", "verify",
            "compile", "pytest", "unittest", "dmd", "dub", "cargo",
            "npm run", "pnpm", "yarn"])
            if (lower.canFind(signal)) return true;
        return false;
    }

    private void applyDurablePlan(ref ChatSession session, string arguments)
    {
        JSONValue root;
        try root = parseJSON(arguments);
        catch (Exception) return;
        if (root.type != JSONType.object) return;
        auto plan = "plan" in root.object;
        if (plan is null || plan.type != JSONType.array) return;
        TaskStep[] steps;
        foreach (item; plan.array)
        {
            if (item.type != JSONType.object) return;
            TaskStep step;
            if (auto field = "step" in item.object)
                if (field.type == JSONType.string) step.text = field.str;
            if (auto field = "status" in item.object)
                if (field.type == JSONType.string) step.status = field.str;
            if (step.text.length == 0 || step.status.length == 0) return;
            steps ~= step;
        }
        session.taskSteps = steps;
        bool complete = steps.length > 0;
        foreach (step; steps)
            if (step.status != "completed") complete = false;
        if (session.taskStatus != "reviewing" || complete)
            session.taskStatus = "active";
        publishThreadUpdated(session);
    }

    private static bool hasIncompleteTaskSteps(const ref ChatSession session)
    {
        foreach (step; session.taskSteps)
            if (step.status != "completed") return true;
        return false;
    }

    /// Move guidance entered during a live turn into the transcript only at a
    /// valid message boundary (after all tool results, or after a prose reply).
    private bool appendQueuedGuidance(ref ChatSession session)
    {
        if (session.queuedGuidance.length == 0) return false;
        foreach (text; session.queuedGuidance)
        {
            ChatMessage guidance;
            guidance.role = "user";
            guidance.content = text;
            guidance.time = currentTimestamp();
            appendMessage(session, guidance);
        }
        session.queuedGuidance.length = 0;
        session.taskStatus = "active";
        publishThreadUpdated(session);
        markDirty();
        rebuildMessageColumn();
        return true;
    }

    /// First non-empty, trimmed line of a tool output, used as the failure
    /// signature for progress-based loop detection.
    private static string firstLineOf(string text)
    {
        import std.string : splitLines, strip;
        foreach (line; splitLines(text))
        {
            const trimmed = strip(line);
            if (trimmed.length > 0) return trimmed;
        }
        return "";
    }

    // -- sending ----------------------------------------------------------

    private bool turnIsBusy()
    {
        return _stopPending || _turnInFlight || _turnTiming || _client.busy() ||
            _pendingToolCalls.length > 0 || _pendingToolResults > 0;
    }

    /// Stop is a local state transition first and an I/O cancellation second.
    /// Invalidate the request id before closing handles so already-queued or
    /// late events cannot append output, restart a tool continuation, or keep
    /// the UI trapped in Stop mode.
    private void stopActiveTurn()
    {
        const sessionIndex = turnOwnerSessionIndex();
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;

        _turnCancelled = true;

        // Reject all remaining network and tool events from this turn before
        // asking the workers to stop.
        _activeRequestId = 0;
        _activeRequestSession = -1;
        _toolCancellation.cancel();
        _client.cancel();
        _stopPending = _client.busy();
        _stopRequestedAt = MonoTime.currTime;

        if (_streamBubble !is null)
        {
            _streamBubble.setThinkingLive(false);
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        cancelPendingTools();

        auto session = &_sessions[sessionIndex];
        // Guidance was already submitted by the user and persisted while this
        // turn was live. Stopping must not silently erase it. Move it into the
        // visible transcript without starting another request; the following
        // turn can then apply it with its original wording intact.
        const preservedGuidance = appendQueuedGuidance(*session);
        session.taskStatus = "blocked";
        publishThreadUpdated(*session);
        publishRuntimeEvent(AgentEventKind.turnInterrupted, *session,
            runtimeTurnId(*session));
        markDirty();
        if (_current == sessionIndex) rebuildMessageColumn();
        updateSessionList(false);
        const preservedStatus = preservedGuidance
            ? " Queued guidance was preserved in the chat and was not applied."
            : "";
        updateStatus((_stopPending
            ? "Stopped. Releasing the network request…" : "Stopped.") ~
            preservedStatus);
        updateSendButton();
    }

    private void sendMessage()
    {
        if (_stopPending)
        {
            updateStatus("Stopped. Waiting for the previous request to close…");
            return;
        }
        if (turnIsBusy())
        {
            if (_current != turnOwnerSessionIndex())
            {
                updateStatus("Another conversation is still working. " ~
                    "Select it to steer or stop that turn.");
                return;
            }
            // Text entered while work is active is steering, not an implicit
            // stop.  Queue it durably and inject it at the next valid message
            // boundary.  Clicking the stop-shaped send button with no text
            // keeps the explicit cancellation behaviour.
            const guidance = _input.textUtf8().strip();
            if (guidance.length > 0 && _current >= 0)
            {
                auto session = &_sessions[_current];
                session.queuedGuidance ~= guidance;
                session.taskStatus = "active";
                _input.setText("");
                publishThreadUpdated(*session);
                markDirty();
                updateStatus("Guidance queued — applying at the next safe step…");
                return;
            }
            stopActiveTurn();
            return;
        }

        const text = _input.textUtf8().strip();
        if (text.length == 0) return;

        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        if (session.title == "New chat" || session.title.length == 0)
        {
            session.title = text.length > 60 ? text[0 .. 60] ~ "…" : text;
            updateSessionList();
        }
        session.model = _settings.model;
        session.thinking = _settings.thinking;
        // The objective describes the thread's durable purpose. Short
        // follow-ups such as "launch it" or "check the log" refine that work;
        // replacing the objective with them made compaction erase why the work
        // existed. A completed/blocked turn still gets a fresh checklist and
        // verification state, while the original objective remains stable.
        const resetTaskState = session.objective.length == 0 ||
            session.taskStatus == "completed" || session.taskStatus == "blocked";
        if (session.objective.length == 0)
            session.objective = text;
        if (resetTaskState)
        {
            session.taskSteps.length = 0;
            session.verificationStatus = "not_required";
            if (_settings.toolsEnabled && likelyChangeRequest(text))
                initializeAutomaticTaskPlan(*session);
        }
        session.taskStatus = "active";
        publishThreadUpdated(*session);

        // Editing a prompt: branch from the original prompt's parent so the
        // edited turn becomes a sibling and the old run is kept, not truncated.
        if (_editMessageIndex >= 0)
        {
            if (_editMessageIndex < cast(int) session.messages.length &&
                session.messages[cast(size_t) _editMessageIndex].role == "user")
                session.activeLeafId = session.messages[
                    cast(size_t) _editMessageIndex].parentId;
            _editMessageIndex = -1;
        }

        ChatMessage userMessage;
        userMessage.role = "user";
        userMessage.content = text;
        userMessage.time = currentTimestamp();
        appendMessage(*session, userMessage);
        addUserBubble(text);
        _input.setText("");
        markDirty();
        _lastToolSignature = "";
        _lastToolRepeatCount = 0;
        _lastFailureSignature = "";
        _lastFailureRepeatCount = 0;
        _pendingProgressGuidance = "";
        _pendingToolCalls.length = 0;
        _liveToolCalls.length = 0;
        _preparingToolCalls.length = 0;
        _pendingToolResults = 0;
        _turnCancelled = false;
        startChatRequest(_current);
    }

    /// Start the streaming request for the current session history. When
    /// tools are enabled, the structured history (including tool calls and
    /// results) is sent together with the tool definitions and a steering
    /// prompt that directs the model toward the native D tools.
    /// Build the outgoing history from the active branch, defensively. A stored
    /// assistant message may carry `tool_calls` whose results never arrived
    /// (the app was closed mid-tool, a tool run was abandoned, or a save
    /// predates the tool-reply guarantee). The provider rejects an assistant
    /// `tool_calls` message that is not immediately followed by a `tool`
    /// message for every call id ("insufficient tool messages following
    /// tool_calls message", HTTP 400), so keep the calls only when the full
    /// contiguous set of replies is present; otherwise downgrade the assistant
    /// to a plain message and drop the orphan tool replies.
    private static size_t requestMessageBytes(
        const(ChatRequestMessage)[] messages)
    {
        size_t total;
        foreach (m; messages)
        {
            total += m.role.length + m.content.length + m.toolCallId.length + 16;
            foreach (call; m.toolCalls)
                total += call.name.length + call.arguments.length + 16;
        }
        return total;
    }

    /// Conservative local fallback for providers that omit streamed usage.
    /// Count the exact compacted messages plus advertised tool schemas, then
    /// apply the same four-bytes-per-token approximation used by compaction.
    private static int estimateRequestTokens(
        const(ChatRequestMessage)[] messages,
        const(OpenCodeToolDef)[] tools)
    {
        const size_t bytes = requestMessageBytes(messages) +
            requestToolDefinitionBytes(tools);
        const size_t tokens = (bytes + 3) / 4;
        return tokens > cast(size_t) int.max ? int.max : cast(int) tokens;
    }

    private static size_t requestToolDefinitionBytes(
        const(OpenCodeToolDef)[] tools)
    {
        size_t bytes;
        foreach (tool; tools)
            bytes += tool.name.length + tool.description.length +
                tool.parametersJson.length + 64;
        return bytes;
    }

    /// A short, UTF-8-safe first-line excerpt for deterministic checkpoints.
    /// Compaction must never copy a multi-megabyte message into its summary.
    private static string checkpointSnippet(string text, size_t limit = 480)
    {
        const line = firstLineOf(text);
        if (line.length <= limit) return line;
        size_t cut = limit;
        while (cut > 0 &&
            (cast(ubyte) line[cut] & cast(ubyte) 0xC0) == cast(ubyte) 0x80)
            --cut;
        return line[0 .. cut] ~ "...";
    }

    /// Remove old, completed tool-call envelopes instead of replaying hundreds
    /// of stale calls on every continuation. The real user/assistant dialogue
    /// remains intact and the newest tool groups remain verbatim. A compact
    /// system note tells the model what was removed so omission cannot be
    /// mistaken for work that never happened.
    private static ChatRequestMessage[] collapseCompletedToolHistory(
        ChatRequestMessage[] messages)
    {
        size_t groupCount;
        size_t lastInstruction;
        bool haveInstruction;
        foreach (i, m; messages)
        {
            if (m.role == "user" || m.role == "system" ||
                m.role == "developer")
            {
                lastInstruction = i;
                haveInstruction = true;
            }
            if (m.role == "assistant" && m.toolCalls.length > 0)
                ++groupCount;
        }
        // Only an actively continuing tool round needs its exact envelope. A
        // later user/control instruction starts a new round, so every earlier
        // completed envelope can be checkpointed. Keeping eight old groups was
        // both expensive and fragile: one legacy group with missing reasoning
        // could make the provider reject an otherwise unrelated follow-up.
        size_t groupsAfterInstruction;
        foreach (i, m; messages)
            if (m.role == "assistant" && m.toolCalls.length > 0 &&
                (!haveInstruction || i > lastInstruction))
                ++groupsAfterInstruction;
        const size_t keepRecentToolGroups = groupsAfterInstruction > 0 ? 1 : 0;
        if (groupCount <= keepRecentToolGroups) return messages;

        const collapseCount = groupCount - keepRecentToolGroups;
        int[string] callCounts;
        string[] callOrder;
        size_t seenGroups;
        foreach (m; messages)
        {
            if (m.role != "assistant" || m.toolCalls.length == 0) continue;
            if (seenGroups++ >= collapseCount) break;
            foreach (call; m.toolCalls)
            {
                if (call.name !in callCounts) callOrder ~= call.name;
                ++callCounts[call.name];
            }
        }

        string objective = "Continue the user's current task.";
        foreach (m; messages)
            if (m.role == "user")
            {
                const excerpt = checkpointSnippet(m.content, 700);
                if (excerpt.length > 0) objective = excerpt;
                break;
            }

        string[] concreteOutcomes;
        string[] failures;
        size_t groupsSeen;
        foreach (m; messages)
        {
            if (m.role == "assistant" && m.toolCalls.length > 0)
            {
                if (groupsSeen++ >= collapseCount) break;
                continue;
            }
            if (groupsSeen > 0 && groupsSeen <= collapseCount &&
                m.role == "tool")
            {
                const excerpt = checkpointSnippet(m.content, 700);
                if (excerpt.length == 0) continue;
                const lower = excerpt.toLower();
                const failed = lower.canFind("error") ||
                    lower.canFind("failed") ||
                    lower.canFind("cannot") ||
                    lower.canFind("tool call skipped") ||
                    lower.canFind("exited with code");
                if (failed)
                {
                    failures ~= excerpt;
                    if (failures.length > 6) failures = failures[1 .. $];
                }
                else
                {
                    concreteOutcomes ~= excerpt;
                    if (concreteOutcomes.length > 12)
                        concreteOutcomes = concreteOutcomes[1 .. $];
                }
            }
        }

        auto noteText = appender!string();
        noteText.put("## Objective\n- " ~ objective ~
            "\n\n## Important Details\n- Earlier completed tool activity " ~
            "was checkpointed after " ~ to!string(collapseCount) ~
            " rounds.\n- Tool activity: ");
        foreach (i, name; callOrder)
        {
            if (i > 0) noteText.put(", ");
            noteText.put(name ~ " x" ~ to!string(callCounts[name]));
        }
        noteText.put(".\n\n## Work State\n### Completed\n");
        if (concreteOutcomes.length == 0)
            noteText.put("- No concrete successful outcome was retained.\n");
        else
            foreach (outcome; concreteOutcomes)
                noteText.put("- " ~ outcome ~ "\n");
        noteText.put("\n### Active\n- Continue from the retained recent " ~
            "messages and tool results.\n\n### Blocked\n");
        if (failures.length == 0)
            noteText.put("- (none recorded in the checkpointed tool rounds)\n");
        else
            foreach (failure; failures)
                noteText.put("- " ~ failure ~ "\n");
        noteText.put("\n## Next Move\n- Use the retained recent context; " ~
            "make a targeted lookup only when an exact fact is missing. Do not " ~
            "repeat old exploration merely because raw output was shortened.");
        ChatRequestMessage note;
        note.role = "system";
        note.content = noteText.data;

        ChatRequestMessage[] result;
        bool inserted;
        size_t collapsed;
        size_t slot;
        while (slot < messages.length)
        {
            auto m = messages[slot];
            if (collapsed < collapseCount && m.role == "assistant" &&
                m.toolCalls.length > 0)
            {
                if (!inserted)
                {
                    result ~= note;
                    inserted = true;
                }
                ++collapsed;
                ++slot;
                while (slot < messages.length && messages[slot].role == "tool")
                    ++slot;
                continue;
            }
            result ~= m;
            ++slot;
        }
        return result;
    }

    /// Deterministically shrink a request only when it approaches the model's
    /// context budget. Keeping the model-visible prefix stable below that limit
    /// avoids needless context churn on every tool continuation.
    private static ChatRequestMessage[] compactRequestMessages(
        ChatRequestMessage[] messages, int contextLimit,
        size_t fixedRequestBytes = 0)
    {
        if (messages.length == 0) return messages;
        if (contextLimit <= 0) return messages;
        // Reserve 10% or 20k tokens (whichever is larger), capped at 40% for
        // small windows. This follows the same preflight/headroom shape as
        // Codex and OpenCode rather than compacting on every continuation.
        const size_t contextTokens = cast(size_t) contextLimit;
        const size_t proportionalReserve = contextTokens / 10;
        size_t reserveTokens = proportionalReserve > 20_000
            ? proportionalReserve : 20_000;
        const size_t maximumReserve = contextTokens * 4 / 10;
        if (reserveTokens > maximumReserve) reserveTokens = maximumReserve;
        const size_t budget = (contextTokens - reserveTokens) * 4;
        size_t total = fixedRequestBytes + requestMessageBytes(messages);
        if (total <= budget) return messages;

        messages = collapseCompletedToolHistory(messages);
        total = fixedRequestBytes + requestMessageBytes(messages);
        if (total <= budget) return messages;

        auto result = messages.dup;
        immutable toolNote =
            "(tool output shortened during checkpoint compaction)";

        // Pass 1: shorten old tool results while keeping the newest exact. The
        // assistant tool-call envelope remains adjacent, so the provider still
        // receives a structurally valid exchange.
        enum size_t keepRecentTools = 1;
        size_t[] toolIndexes;
        foreach (i, m; result)
            if (m.role == "tool") toolIndexes ~= i;
        if (toolIndexes.length > keepRecentTools)
        {
            foreach (idx; toolIndexes[0 .. $ - keepRecentTools])
            {
                if (total <= budget) break;
                if (result[idx].content.length <= toolNote.length) continue;
                total -= result[idx].content.length - toolNote.length;
                result[idx].content = toolNote;
            }
        }

        // Pass 2: replace older dialogue with one structured handoff rather
        // than dozens of content-free "message elided" placeholders. The full
        // transcript remains persisted; only this model request is compacted.
        enum size_t protectTail = 8;
        if (total > budget)
        {
            size_t protectHead;
            foreach (i, m; result)
            {
                protectHead = i + 1;
                if (m.role != "system") break;
            }
            bool[] remove = new bool[](result.length);
            string[] userDetails;
            string[] completed;
            string[] blockers;
            foreach (i, m; result)
            {
                if (i < protectHead) continue;
                if (i + protectTail >= result.length) continue;
                if (m.role == "system" || m.role == "tool") continue;
                if (i == protectHead && m.role == "user") continue;
                if (m.toolCalls.length > 0) continue;
                remove[i] = true;
                const excerpt = checkpointSnippet(m.content);
                if (excerpt.length == 0) continue;
                if (m.role == "user")
                {
                    userDetails ~= excerpt;
                    if (userDetails.length > 8)
                        userDetails = userDetails[1 .. $];
                }
                else if (m.role == "assistant")
                {
                    completed ~= excerpt;
                    if (completed.length > 8)
                        completed = completed[1 .. $];
                    const lower = excerpt.toLower();
                    if (lower.canFind("error") || lower.canFind("cannot") ||
                        lower.canFind("couldn't") || lower.canFind("blocked"))
                    {
                        blockers ~= excerpt;
                        if (blockers.length > 4)
                            blockers = blockers[1 .. $];
                    }
                }
            }

            auto checkpoint = appender!string();
            string objective = "Continue the user's current task.";
            foreach (m; result)
                if (m.role == "user")
                {
                    const excerpt = checkpointSnippet(m.content, 700);
                    if (excerpt.length > 0) objective = excerpt;
                    break;
                }
            checkpoint.put("## Objective\n- " ~ objective ~
                "\n\n## Important Details\n");
            if (userDetails.length == 0) checkpoint.put("- (none)\n");
            else foreach (detail; userDetails) checkpoint.put("- " ~ detail ~ "\n");
            checkpoint.put("\n## Work State\n### Completed\n");
            if (completed.length == 0) checkpoint.put("- (none)\n");
            else foreach (item; completed) checkpoint.put("- " ~ item ~ "\n");
            checkpoint.put("\n### Active\n- Continue from the retained recent " ~
                "messages and exact tool results.\n\n### Blocked\n");
            if (blockers.length == 0) checkpoint.put("- (none)\n");
            else foreach (item; blockers) checkpoint.put("- " ~ item ~ "\n");
            checkpoint.put("\n## Next Move\n- Complete the current request, " ~
                "then run focused verification and report the result.");

            ChatRequestMessage checkpointMessage;
            checkpointMessage.role = "system";
            checkpointMessage.content = checkpoint.data;
            ChatRequestMessage[] compacted;
            bool inserted;
            foreach (i, m; result)
            {
                if (remove[i])
                {
                    if (!inserted)
                    {
                        compacted ~= checkpointMessage;
                        inserted = true;
                    }
                    continue;
                }
                compacted ~= m;
            }
            result = compacted;
        }
        return result;
    }

    private static ChatRequestMessage[] buildRequestMessages(
        const ref ChatSession session)
    {
        ChatRequestMessage[] messages;
        const path = activeMessagePath(session);
        size_t slot = 0;
        while (slot < path.length)
        {
            const message = session.messages[path[slot]];
            if (message.role == "assistant" && message.toolCalls.length > 0)
            {
                bool[string] outstanding;
                foreach (call; message.toolCalls)
                    outstanding[call.id] = true;
                size_t replyEnd = slot + 1;
                while (replyEnd < path.length &&
                    session.messages[path[replyEnd]].role == "tool")
                {
                    const replyId = session.messages[path[replyEnd]].toolCallId;
                    if (replyId in outstanding) outstanding.remove(replyId);
                    ++replyEnd;
                }
                if (outstanding.length == 0)
                {
                    ChatRequestMessage request;
                    request.role = message.role;
                    request.content = message.content;
                    request.reasoningContent = message.reasoning;
                    request.toolCalls = message.toolCalls.dup;
                    messages ~= request;
                    foreach (k; slot + 1 .. replyEnd)
                    {
                        const reply = session.messages[path[k]];
                        ChatRequestMessage tool;
                        tool.role = reply.role;
                        tool.content = reply.content;
                        tool.toolCallId = reply.toolCallId;
                        messages ~= tool;
                    }
                }
                else if (message.content.length > 0 ||
                    message.reasoning.length > 0)
                {
                    ChatRequestMessage request;
                    request.role = message.role;
                    request.content = message.content;
                    request.reasoningContent = message.reasoning;
                    messages ~= request;
                }
                slot = replyEnd;
                continue;
            }
            if (message.role == "tool")
            {
                // Orphan reply that does not follow a kept tool_calls message.
                ++slot;
                continue;
            }
            ChatRequestMessage request;
            // Recovery/finalization guidance is application control state, not
            // something the user said. Keep it in the durable graph for replay,
            // but send it under the system role so it cannot overwrite or
            // impersonate the user's intent in later model turns.
            request.role = message.internal ? "system" : message.role;
            request.content = message.internal
                ? "Internal agent-control instruction:\n" ~ message.content
                : message.content;
            if (message.role == "assistant")
                request.reasoningContent = message.reasoning;
            request.toolCallId = message.toolCallId;
            messages ~= request;
            ++slot;
        }
        return messages;
    }

    /// The id of the user message that opened the turn the user is currently in:
    /// the last user message on the active path. Keying the clock by it keeps an
    /// edit/regenerate of an earlier prompt timing the right turn.
    private string activeTurnUserId(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return "";
        auto session = &_sessions[sessionIndex];
        string id;
        foreach (index; activeMessagePath(*session))
            if (session.messages[index].role == "user" &&
                !session.messages[index].internal)
                id = session.messages[index].id;
        return id;
    }

    /// Freeze the current turn clock and store its total. Called once when the
    /// turn truly ends, never for a tool-continuation round.
    private void freezeTurnTiming()
    {
        if (!_turnTiming) return;
        if (_turnUserId.length > 0)
        {
            const duration = (MonoTime.currTime - _turnStartedAt).total!"seconds";
            _turnDurations[_turnUserId] = duration;
            // Stamp the total on the user message that opened the turn. The
            // conversation timer sums those stamps, and overwriting (rather than
            // adding) means regenerating a turn replaces its old time instead of
            // double-counting it.
            if (_turnSessionIndex >= 0 &&
                _turnSessionIndex < cast(int) _sessions.length)
            {
                auto session = &_sessions[_turnSessionIndex];
                foreach (ref message; session.messages)
                    if (message.id == _turnUserId)
                    {
                        message.workedSeconds = duration;
                        break;
                    }
                markDirty();
            }
        }
        _turnTiming = false;
        refreshTimerBadge(true);
    }

    /// Start (or restart) the turn clock for a user-initiated request.
    private void beginTurnTiming(int sessionIndex)
    {
        _turnStartedAt = MonoTime.currTime;
        _turnUserId = activeTurnUserId(sessionIndex);
        _turnSessionIndex = sessionIndex;
        _turnTiming = true;
        refreshTimerBadge(true);
    }

    /// Whether the turn currently on the clock was opened by a user message on
    /// `sessionIndex`'s active branch. Matching the message id (not just the
    /// index) matters because the index can be reused after a reload or a
    /// session delete, which would otherwise leak one chat's live time into
    /// another.
    private bool turnBelongsTo(int sessionIndex)
    {
        if (!_turnTiming || sessionIndex != _turnSessionIndex ||
            _turnUserId.length == 0)
            return false;
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return false;
        auto session = &_sessions[sessionIndex];
        foreach (index; activeMessagePath(*session))
            if (session.messages[index].role == "user" &&
                session.messages[index].id == _turnUserId)
                return true;
        return false;
    }

    /// The assistant's accumulated working time for a conversation: every
    /// finished turn's duration on the active branch, plus the turn currently
    /// in flight. Keying on the user messages that opened each turn is what
    /// makes a branch total only the work on its own path.
    private double sessionWorkedSeconds(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return 0;
        auto session = &_sessions[sessionIndex];
        double total = 0.0;
        foreach (index; activeMessagePath(*session))
        {
            const message = session.messages[index];
            // D default-initializes floating point to NaN, so an untouched
            // `workedSeconds` must be skipped or it poisons the whole sum.
            if (message.role == "user" && !message.internal &&
                isFinite(message.workedSeconds) && message.workedSeconds > 0)
                total += message.workedSeconds;
        }
        if (turnBelongsTo(sessionIndex))
        {
            const live = (MonoTime.currTime - _turnStartedAt).total!"seconds";
            if (live > 0) total += live;
        }
        return total;
    }

    /// Push the conversation's accumulated work time into the composer badge.
    /// Throttled by the caller; `force` is for session switches and freezes.
    private void refreshTimerBadge(bool force = false)
    {
        if (_timerBadge is null) return;
        const total = sessionWorkedSeconds(_current);
        const running = turnBelongsTo(_current);
        if (!force && cast(long) total == _lastTimerTotal &&
            running == _lastTimerRunning)
            return;
        _lastTimerTotal = cast(long) total;
        _lastTimerRunning = running;
        _timerBadge.setSeconds(total, running);
    }

    private void startChatRequest(int sessionIndex, bool userTurn = true)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        auto session = &_sessions[sessionIndex];
        ChatRequestMessage[] messages;
        if (_settings.toolsEnabled)
        {
            ChatRequestMessage systemPrompt;
            systemPrompt.role = "system";
            const workspace = workspaceForSession(sessionIndex);
            version (Windows)
                const platform = "win32";
            else version (Posix)
                const platform = "posix";
            else
                const platform = "unknown";
            // Native tools are the main tool set; the legacy shell tool is an
            // opt-in addition from Settings.
            systemPrompt.content = buildSystemPrompt(!_settings.legacyTools,
                workspace, platform) ~ durableTaskPrompt(*session);
            messages ~= systemPrompt;
        }
        else
        {
            const taskPrompt = durableTaskPrompt(*session);
            if (taskPrompt.length > 0)
            {
                ChatRequestMessage systemPrompt;
                systemPrompt.role = "system";
                systemPrompt.content = taskPrompt;
                messages ~= systemPrompt;
            }
        }
        OpenCodeToolDef[] tools;
        if (_settings.toolsEnabled)
            tools = _settings.legacyTools
                ? builtinToolDefinitions()
                : nativeOnlyToolDefinitions();
        auto rawRequestMessages = buildRequestMessages(*session);
        const rawRequestBytes = requestMessageBytes(rawRequestMessages);
        const fixedRequestBytes = requestMessageBytes(messages) +
            requestToolDefinitionBytes(tools);
        auto compactedRequestMessages = compactRequestMessages(
            rawRequestMessages, contextLimitForModel(session.model),
            fixedRequestBytes);
        _contextWasCompacted[session.id] =
            requestMessageBytes(compactedRequestMessages) < rawRequestBytes;
        messages ~= compactedRequestMessages;
        const estimatedTokens = estimateRequestTokens(messages, tools);
        _estimatedContextTokens[session.id] = estimatedTokens;
        _preferEstimatedContext[session.id] = true;
        if (_current == sessionIndex && _usageBadge !is null)
        {
            _usageBadge.setModel(session.model);
            _usageBadge.setUsage(estimatedTokens, 0, estimatedTokens, true);
            refreshContextUsageTooltip();
        }
        // The OpenCode gateway routes by a stable per-conversation id; it
        // rejects requests without one. The first message id is stable for
        // this conversation across turns and restarts.
        _client.setOpenCodeSession(sessionRoutingKey(*session));
        _client.startChatMessages(messages, tools, session.model,
            session.thinking, ++_nextRequestId);
        _activeRequestId = _nextRequestId;
        _activeRequestSession = sessionIndex;
        _chatStartedAt = MonoTime.currTime;
        _receivedFirstDelta = false;
        _lastColdStartSeconds = -1;
        // A user-initiated request opens a new turn clock; a tool-continuation
        // round re-enters here without `userTurn`, so the one clock spans the
        // whole turn (and one action group owns its tools).
        if (userTurn)
        {
            beginTurnTiming(sessionIndex);
            setTurnActiveMarker(true, session.id);
            setTurnInFlight(true);
            JSONValue payload;
            payload["model"] = session.model;
            payload["thinking"] = session.thinking;
            publishRuntimeEvent(AgentEventKind.turnStarted, *session,
                _turnUserId, "", "", payload.toString());
        }
        updateStatus("Generating…");
        // Fill the request round-trip immediately: the transcript shows a live
        // "waiting" row from the moment Send is pressed until the first event.
        setActivity("Waiting for the model…");
        updateSendButton();
    }

    /// Regenerate an assistant reply (or retry it when it failed): everything
    /// from that reply onward is dropped and the request re-runs with the
    /// history that produced it.
    private void regenerateLastReply(int sessionIndex, int messageIndex)
    {
        if (!prepareRegenerate(sessionIndex, messageIndex)) return;
        startChatRequest(sessionIndex);
    }

    private static bool truncatedFinishReason(string reason)
    {
        const lower = reason.toLower();
        return lower == "length" || lower == "max_tokens" ||
            lower == "max_output_tokens" || lower == "max_output_length";
    }

    /// Extend the current branch after a settled assistant reply. Unlike
    /// Regenerate, this keeps the reply as context and appends a hidden control
    /// turn. The instruction is derived from the actual terminal/task state so
    /// the model resumes rather than repeating completed work.
    private void continueFromReply(int sessionIndex, int messageIndex)
    {
        if (!prepareContinue(sessionIndex, messageIndex)) return;
        startChatRequest(sessionIndex);
    }

    private bool prepareContinue(int sessionIndex, int messageIndex)
    {
        if (sessionIndex != _current || _client.busy() || _turnTiming ||
            _pendingToolCalls.length > 0 || _pendingToolResults > 0 ||
            _liveToolCalls.length > 0 || _preparingToolCalls.length > 0)
            return false;
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return false;
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 ||
            messageIndex >= cast(int) session.messages.length) return false;
        const message = session.messages[cast(size_t) messageIndex];
        if (message.role != "assistant" || message.failed ||
            message.toolCalls.length > 0 ||
            session.activeLeafId != message.id) return false;

        ChatMessage continuation;
        continuation.role = "user";
        continuation.internal = true;
        continuation.time = currentTimestamp();
        if (truncatedFinishReason(message.finishReason))
            continuation.content = "Continuation request: the provider ended " ~
                "the previous response at its output limit. Continue exactly " ~
                "from the point where it stopped. Do not repeat or summarize " ~
                "text already present, and preserve the current branch.";
        else if (message.finishReason == "cancelled" ||
            session.taskStatus == "active" ||
            session.taskStatus == "blocked" ||
            session.taskStatus == "reviewing" ||
            session.taskStatus == "verifying" ||
            hasIncompleteTaskSteps(*session) ||
            session.verificationStatus == "required")
        {
            continuation.content = "Continuation request: resume the current " ~
                "task from its durable objective, checklist, files, and tool " ~
                "results. Keep completed work, do not repeat successful " ~
                "inspection or edits, take the next concrete pending action, " ~
                "then run only the focused verification still needed. If a " ~
                "real blocker remains, report it precisely.";
            session.taskStatus = "active";
        }
        else
            continuation.content = "Continuation request: extend the previous " ~
                "answer with the next useful details. Do not repeat or " ~
                "summarize material already present.";

        appendMessage(*session, continuation);
        publishThreadUpdated(*session);
        markDirty();
        rebuildMessageColumn();
        updateStatus("Continuing from the current reply…");
        return true;
    }

    /// Point the active leaf just before an assistant reply so a fresh reply is
    /// generated as a sibling branch. The old reply (and its continuation) stays
    /// in `messages`, available through the `‹ n/m ›` branch switcher. Returns
    /// false when there is nothing to regenerate.
    private bool prepareRegenerate(int sessionIndex, int messageIndex)
    {
        if (_client.busy() || _turnTiming ||
            _pendingToolCalls.length > 0 || _pendingToolResults > 0) return false;
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return false;
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return false;
        const message = session.messages[cast(size_t) messageIndex];
        if (message.role != "assistant") return false;
        cancelPendingTools();
        session.activeLeafId = message.parentId;
        publishThreadUpdated(*session);
        _streamBubble = null;
        _editMessageIndex = -1;
        rebuildMessageColumn();
        return true;
    }

    /// Start editing a user message: prefill the composer with its text. The
    /// next Send branches from that prompt's parent, keeping the original run
    /// as a sibling version rather than discarding it.
    private void editAndResend(int sessionIndex, int messageIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        if (_client.busy() || _turnTiming ||
            _pendingToolCalls.length > 0 || _pendingToolResults > 0)
        {
            _client.cancel();
            // Abandon the interrupted turn so the killed tool's late result
            // cannot restart the chat via a continuation request.
            _turnCancelled = true;
            _toolCancellation.cancel();
            _suppressDoneStatus = true;
        }
        cancelPendingTools();
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return;
        const message = session.messages[cast(size_t) messageIndex];
        if (message.role != "user") return;
        _streamBubble = null;
        _editMessageIndex = messageIndex;
        if (sessionIndex == _current)
        {
            _input.setText(message.content);
            _input.requestFocus();
        }
        markDirty();
        updateStatus("Editing prompt — press Send to replace it " ~
            "(the previous run is kept).");
    }

    // -- model picker -----------------------------------------------------

    private void showModelPicker()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(4, Insets(6));
        content.layoutHints().preferredWidth = 280;
        auto list = content.add(new ListView());
        list.layoutHints().preferredHeight = 340;
        ListItem[] items;
        foreach (model; _models)
            items ~= ListItem(model, IconKind.terminal, "");
        list.setItems(items);
        for (int index = 0; index < cast(int) _models.length; ++index)
        {
            if (_models[cast(size_t) index] == _settings.model)
                list.setSelectedIndex(index, false);
        }
        list.onActivated = delegate(int index)
        {
            if (index >= 0 && index < cast(int) _models.length)
            {
                _settings.model = _models[cast(size_t) index];
                if (_current >= 0) _sessions[_current].model = _settings.model;
                _modelButton.setText(_settings.model);
                saveSettingsNow();
                markDirty();
                refreshUsageBadge();
            }
            dismissPopup();
        };
        list.onSelectionChanged = delegate(int index) {};

        auto popup = new PopupOverlay(content, _modelButton);
        const origin = _modelButton.globalOrigin();
        // The model button sits in the composer footer at the window bottom, so
        // the picker opens upward (a "below" placement would land off-screen and
        // be clamped over the conversation).
        popup.setAnchor(Rect(origin.x, origin.y, _modelButton.size().width,
            _modelButton.size().height), PopupPlacement.above);
        popup.setBackdrop(Color.rgba(0, 0, 0, 90));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    private string changeConversationLabel(string id) const
    {
        foreach (session; _sessions)
            if (session.id == id)
                return session.title.length > 0 ? session.title : "New chat";
        return id.length > 12 ? id[0 .. 12] ~ "…" : id;
    }

    private static string displayChangePath(string path, string workspace)
    {
        if (workspace.length > 0 && path.length > workspace.length &&
            path[0 .. workspace.length].toLower() == workspace.toLower() &&
            (path[workspace.length] == '/' || path[workspace.length] == '\\'))
            return path[workspace.length + 1 .. $];
        return path;
    }

    private void showChangeDiffDialog(ChangeRecord record)
    {
        if (_activePopup !is null) _activePopup.dismiss();
        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 760;
        auto title = content.add(new Label(record.changeKind ~ " — " ~
            displayChangePath(record.path, record.workspace)));
        title.setPixelSize(opencodeFontTitle);
        auto meta = content.add(new Label(record.timestamp ~ " · " ~
            changeConversationLabel(record.conversationId) ~ " · " ~
            record.toolName));
        meta.setScale(1);
        meta.setColor(opencodeMuted);
        auto viewer = new TextArea(changeRecordDiff(record));
        viewer.setReadOnly(true);
        viewer.layoutHints().preferredHeight = 430;
        viewer.layoutHints().minHeight = 220;
        content.add(viewer);
        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto back = footer.add(new Button("Back"));
        back.onClick = delegate()
        {
            dismissPopup();
            showChangesDialog();
        };
        content.add(footer);
        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(800, 560));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    /// Aurora-owned, Git-independent file history for the active workspace.
    /// Rows are append-only audit records; every revert is another reversible
    /// record and exact after-byte checks prevent overwriting subsequent work.
    // -- profile / usage dialog -------------------------------------------

    private void showProfileDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        long totalTokens, promptTokens, completionTokens;
        int replies, sessionsWithUsage;
        foreach (ref session; _sessions)
        {
            bool used;
            foreach (ref message; session.messages)
            {
                if (message.totalTokens > 0 || message.completionTokens > 0)
                {
                    totalTokens += message.totalTokens;
                    promptTokens += message.promptTokens;
                    completionTokens += message.completionTokens;
                    used = true;
                }
                if (message.role == "assistant") ++replies;
            }
            if (used) ++sessionsWithUsage;
        }

        string withThousands(long value)
        {
            auto text = to!string(value);
            string outText;
            int count;
            for (int i = cast(int) text.length; i > 0; --i)
            {
                outText = text[i - 1] ~ outText;
                if (++count % 3 == 0 && i > 1) outText = "," ~ outText;
            }
            return outText;
        }

        Color usageCellColor(int value, int peak)
        {
            if (value <= 0) return Color.rgba(60, 60, 60, 255);
            if (peak <= 1) return Color.rgba(57, 211, 83, 255);
            const fraction = cast(double) value / cast(double) peak;
            if (fraction < 0.25) return Color.rgba(14, 68, 41, 255);
            if (fraction < 0.5) return Color.rgba(0, 109, 50, 255);
            if (fraction < 0.75) return Color.rgba(38, 166, 65, 255);
            return Color.rgba(57, 211, 83, 255);
        }

        string barText(long value, long peak)
        {
            const width = 24;
            const filled = peak > 0 ? cast(int)(value * width / peak) : 0;
            string outBar;
            foreach (i; 0 .. width)
                outBar ~= i < filled ? "█" : "░";
            return outBar;
        }

        auto content = new VBox(10, Insets(16));
        content.layoutHints().preferredWidth = 720;

        auto title = content.add(new Label("Profile"));
        title.setPixelSize(opencodeFontTitle);
        auto hint = content.add(new Label(
            "Token usage across every conversation in this workspace."));
        hint.setScale(1);
        hint.setColor(opencodeMuted);

        auto summary = content.add(new Label(
            withThousands(totalTokens) ~ " tokens total  ·  " ~
            withThousands(promptTokens) ~ " input  ·  " ~
            withThousands(completionTokens) ~ " output"));
        summary.setScale(1);
        auto detail = content.add(new Label(
            to!string(replies) ~ " assistant replies  ·  " ~
            to!string(sessionsWithUsage) ~ " conversation(s) with recorded usage"));
        detail.setScale(1);
        detail.setColor(opencodeMuted);

        // Contribution-style grid: one cell per assistant reply in the active
        // conversation, shaded by token count (darker for lighter turns).
        int[] activity;
        if (_current >= 0 && _current < cast(int) _sessions.length)
            foreach (ref message; _sessions[_current].messages)
                if (message.role == "assistant")
                    activity ~= (message.totalTokens > 0
                        ? message.totalTokens : message.completionTokens);

        const columns = 13;
        const rowsCount = 7;
        const cells = columns * rowsCount;
        int[] window = activity.length > cells ? activity[$ - cells .. $] : activity;
        int peakCell;
        foreach (value; window) if (value > peakCell) peakCell = value;

        auto gridLabel = content.add(new Label("Recent activity (active chat)"));
        gridLabel.setScale(1);
        gridLabel.setColor(opencodeMuted);
        auto grid = content.add(new VBox(2));
        auto gridRows = new HBox[rowsCount];
        foreach (r; 0 .. rowsCount)
            gridRows[r] = grid.add(new HBox(2));
        const offset = cells - cast(int) window.length;
        foreach (k; 0 .. cells)
        {
            auto cell = new Label("·");
            cell.setScale(1);
            if (k >= offset)
            {
                const value = window[k - offset];
                cell.setText("█");
                cell.setColor(usageCellColor(value, peakCell));
            }
            else
                cell.setColor(Color.rgba(60, 60, 60, 255));
            gridRows[k % rowsCount].add(cell);
        }

        // Per-conversation totals with proportional bars.
        long peakSession;
        foreach (ref session; _sessions)
        {
            long sessionTotal;
            foreach (ref message; session.messages)
                sessionTotal += message.totalTokens;
            if (sessionTotal > peakSession) peakSession = sessionTotal;
        }
        auto listLabel = content.add(new Label("Usage by conversation"));
        listLabel.setScale(1);
        listLabel.setColor(opencodeMuted);
        auto list = content.add(new ListView());
        list.setId("oc-profile-list");
        list.layoutHints().preferredHeight = 300;
        ListItem[] items;
        foreach (index, ref session; _sessions)
        {
            long sessionTotal;
            int msgs;
            foreach (ref message; session.messages)
            {
                sessionTotal += message.totalTokens;
                if (message.role == "assistant") ++msgs;
            }
            if (sessionTotal == 0 && msgs == 0) continue;
            const name = session.title.length > 0 ? session.title : "New chat";
            const marker = cast(int) index == _current ? "▸ " : "";
            const secondary = to!string(msgs) ~ " replies · " ~
                withThousands(sessionTotal) ~ " tokens  " ~
                barText(sessionTotal, peakSession);
            items ~= ListItem(marker ~ name, IconKind.settings, secondary);
        }
        if (items.length == 0)
            items ~= ListItem("No usage recorded yet", IconKind.settings,
                "Send a message to start tracking tokens.");
        list.setItems(items);

        auto footer = content.add(new HBox(8));
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto close = footer.add(new Button("Close"));
        close.setId("oc-profile-close");
        close.onClick = delegate() { dismissPopup(); };

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(760, 560));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    private void showChangesDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();
        const workspace = activeWorkspace();
        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 820;
        auto title = content.add(new Label("File changes"));
        title.setPixelSize(opencodeFontTitle);
        auto hint = content.add(new Label(
            "Aurora snapshots — independent of Git. Reverts are undoable and " ~
            "stop on newer file changes. External programs are not tracked."));
        hint.setScale(1);
        hint.setColor(opencodeMuted);

        auto filter = new CheckBox("Current conversation only");
        filter.setChecked(false, false);
        content.add(filter);
        auto header = content.add(new Label(
            "File                                      Change · Diff · Time · Conversation"));
        header.setScale(1);
        header.setColor(opencodeMuted);
        auto list = content.add(new ListView());
        list.setId("oc-changes-list");
        list.layoutHints().preferredHeight = 380;
        ChangeRecord[] visible;
        bool[string] reverted;

        auto status = content.add(new Label(""));
        status.setScale(1);
        status.setColor(opencodeMuted);
        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        auto diffButton = footer.add(new Button("View diff"));
        diffButton.setId("oc-changes-diff");
        auto folderButton = footer.add(new Button("Open folder", IconKind.folder));
        folderButton.setId("oc-changes-folder");
        auto fileButton = footer.add(new Button("Revert file"));
        fileButton.setId("oc-changes-revert-file");
        auto actionButton = footer.add(new Button("Revert action"));
        actionButton.setId("oc-changes-revert-action");
        auto turnButton = footer.add(new Button("Revert turn"));
        turnButton.setId("oc-changes-revert-turn");
        footer.add(new Spacer());
        auto close = footer.add(new Button("Close"));
        close.setId("oc-changes-close");
        content.add(footer);

        bool isReverted(const ref ChangeRecord record)
        {
            return (record.id in reverted) !is null;
        }
        void updateButtons()
        {
            const index = list.selectedIndex();
            const valid = index >= 0 && index < cast(int) visible.length;
            const reversible = valid && !isReverted(visible[index]);
            diffButton.setEnabled(valid);
            folderButton.setEnabled(valid);
            fileButton.setEnabled(reversible);
            actionButton.setEnabled(reversible);
            turnButton.setEnabled(reversible);
        }
        void refresh()
        {
            const all = listChangeRecords(workspace);
            reverted = null;
            string[string] reverter;
            foreach (record; all)
                if (record.revertOf.length > 0)
                    foreach (candidate; all)
                        if (("|" ~ record.revertOf ~ "|").canFind(
                            "|" ~ candidate.id ~ "|"))
                            reverter[candidate.id] = record.id;
            bool activeRecord(string id, int depth = 0)
            {
                if (depth > cast(int) all.length) return true;
                if (auto reverseId = id in reverter)
                    return !activeRecord(*reverseId, depth + 1);
                return true;
            }
            foreach (record; all)
                if (!activeRecord(record.id)) reverted[record.id] = true;
            visible.length = 0;
            ListItem[] rows;
            const currentId = _current >= 0 ? _sessions[_current].id : "";
            for (size_t offset; offset < all.length; ++offset)
            {
                const record = all[$ - 1 - offset];
                if (filter.checked() && record.conversationId != currentId)
                    continue;
                visible ~= record;
                const marker = isReverted(record) ? "↶ " : "";
                const relative = displayChangePath(record.path, workspace);
                const secondary = record.changeKind ~ " · +" ~
                    to!string(record.additions) ~ " -" ~
                    to!string(record.deletions) ~ " · " ~ record.timestamp ~
                    " · " ~ changeConversationLabel(record.conversationId);
                auto icon = record.changeKind == "Created" ? IconKind.newDocument :
                    (record.changeKind == "Deleted" ? IconKind.trash :
                        IconKind.settings);
                auto row = ListItem(marker ~ relative, icon, secondary);
                row.dimmed = isReverted(record);
                rows ~= row;
            }
            list.setItems(rows);
            if (rows.length > 0) list.setSelectedIndex(0, false);
            status.setText(rows.length == 0 ?
                "No Aurora-managed file changes in this workspace." :
                to!string(rows.length) ~ " recorded file change(s). " ~
                "↶ means already reverted.");
            updateButtons();
        }
        ChangeRecord selectedRecord()
        {
            const index = list.selectedIndex();
            return index >= 0 && index < cast(int) visible.length ?
                visible[index] : ChangeRecord.init;
        }
        void runRevert(bool action, bool turn)
        {
            const record = selectedRecord();
            if (record.id.length == 0) return;
            ChangeContext context;
            context.conversationId = _current >= 0 ?
                _sessions[_current].id : "manual";
            context.turnId = "manual-revert-" ~
                to!string(Clock.currTime.stdTime);
            const outcome = revertChangeRecord(workspace, record.id, action,
                context, turn);
            status.setText(outcome.message);
            if (outcome.succeeded) refresh();
        }
        filter.onChanged = delegate(bool value) { refresh(); };
        list.onSelectionChanged = delegate(int index) { updateButtons(); };
        list.onActivated = delegate(int index)
        {
            const record = selectedRecord();
            if (record.id.length > 0) showChangeDiffDialog(record);
        };
        diffButton.onClick = delegate()
        {
            const record = selectedRecord();
            if (record.id.length > 0) showChangeDiffDialog(record);
        };
        folderButton.onClick = delegate()
        {
            const record = selectedRecord();
            if (record.id.length > 0) openFileLocation(record.path, workspace);
        };
        fileButton.onClick = delegate() { runRevert(false, false); };
        actionButton.onClick = delegate() { runRevert(true, false); };
        turnButton.onClick = delegate() { runRevert(false, true); };
        close.onClick = delegate() { dismissPopup(); };
        refresh();

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(860, 590));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    // -- settings dialog --------------------------------------------------

    private void showSettingsDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 520;

        auto title = content.add(new Label("Settings"));
        title.setPixelSize(opencodeFontTitle);

        // Provider preset picker: choosing one fills the base URL, key and
        // model fields below, all of which stay editable.
        auto providerRow = new HBox(8);
        providerRow.layoutHints().preferredHeight = 32;
        auto providerLabel = providerRow.add(new Label("Provider"));
        providerLabel.layoutHints().preferredWidth = 110;
        providerLabel.setScale(1);
        auto providerButton = providerRow.add(
            new Button(providerPresetLabel(_settings.baseUrl)));
        providerButton.setId("oc-provider");
        providerButton.layoutHints().flex = 1.0;
        providerButton.onClick = delegate()
        {
            ContextMenuItem[] items;
            foreach (index; 0 .. providerPresets.length)
                items ~= providerMenuItem(cast(int) index);
            const origin = providerButton.globalOrigin();
            // Keep the Settings dialog open: showContextMenuBelow dismisses
            // every transient popup, including this dialog.
            showContextMenuKeepPopups(providerButton,
                Point(origin.x, origin.y + providerButton.size().height),
                items);
        };
        _settingsProviderButton = providerButton;

        auto baseRow = new HBox(8);
        baseRow.layoutHints().preferredHeight = 32;
        auto baseLabel = baseRow.add(new Label("API base URL"));
        baseLabel.layoutHints().preferredWidth = 110;
        baseLabel.setScale(1);
        auto baseField = baseRow.add(new TextField(_settings.baseUrl));
        baseField.setId("oc-settings-base");
        baseField.layoutHints().flex = 1.0;
        _settingsBaseField = baseField;

        auto keyRow = new HBox(8);
        keyRow.layoutHints().preferredHeight = 32;
        auto keyLabel = keyRow.add(new Label("API key"));
        keyLabel.layoutHints().preferredWidth = 110;
        keyLabel.setScale(1);
        auto keyField = keyRow.add(new TextField(_settings.apiKey));
        keyField.setId("oc-settings-key");
        keyField.layoutHints().flex = 1.0;
        _settingsKeyField = keyField;

        auto hint = content.add(new Label(
            "llama-server: http://127.0.0.1:8080/v1 (API key may be blank)."));
        hint.setScale(1);
        hint.setColor(opencodeMuted);

        auto modelRow = new HBox(8);
        modelRow.layoutHints().preferredHeight = 32;
        auto modelLabel = modelRow.add(new Label("Model"));
        modelLabel.layoutHints().preferredWidth = 110;
        modelLabel.setScale(1);
        auto modelField = modelRow.add(new TextField(_settings.model));
        modelField.setId("oc-model-field");
        modelField.layoutHints().flex = 1.0;
        _settingsModelField = modelField;

        auto workspaceRow = new HBox(8);
        workspaceRow.layoutHints().preferredHeight = 32;
        auto workspaceLabel = workspaceRow.add(new Label("Project folder"));
        workspaceLabel.layoutHints().preferredWidth = 110;
        workspaceLabel.setScale(1);
        auto workspaceField = workspaceRow.add(
            new TextField(activeWorkspace()));
        workspaceField.setId("oc-workspace");
        workspaceField.layoutHints().flex = 1.0;
        auto workspaceHint = content.add(new Label(
            "Folder where the active project's tools (bash/read/write/glob/" ~
            "grep) operate. Switch projects in the rail on the left."));
        workspaceHint.setScale(1);
        workspaceHint.setColor(opencodeMuted);

        // Legacy tools: an opt-in extra on top of the native D tools. Its
        // label shows a small hover tooltip explaining what it is.
        auto legacyRow = new HBox(8);
        legacyRow.layoutHints().preferredHeight = 32;
        auto legacyCheck = new CheckBox("Legacy tools");
        legacyCheck.setId("oc-legacy");
        legacyCheck.setChecked(_settings.legacyTools, false);
        legacyCheck.onChanged = delegate(bool value)
        {
            _settings.legacyTools = value;
            saveSettingsNow();
        };
        legacyRow.add(legacyCheck);
        auto legacyTip = new TooltipAnchor(legacyCheck);
        legacyTip.setText(
            "Also lets the model use the legacy bash/cmd/powershell shell " ~
            "tool in addition to the native " ~
            "run/read/write/remove/glob/grep/dshell tools. Off by default.");
        _legacyTooltipAnchor = legacyTip;
        legacyTip.onHoverChanged = delegate(bool open)
        {
            if (_legacyTooltip is null)
                _legacyTooltip = new HoverTooltip(legacyTip);
            setTooltipOpen(legacyTip, _legacyTooltip, _legacyTooltipOpen,
                open);
        };
        legacyRow.add(legacyTip);
        content.add(legacyRow);

        // "Worked for …" separator: an opt-in display extra. Off by default
        // because its appearance is unreliable, so it lives here rather than in
        // the always-on transcript.
        auto workedRow = new HBox(8);
        workedRow.layoutHints().preferredHeight = 32;
        auto workedCheck = new CheckBox("Worked-for separator");
        workedCheck.setId("oc-workedfor");
        workedCheck.setChecked(_settings.showWorkedFor, false);
        workedCheck.onChanged = delegate(bool value)
        {
            _settings.showWorkedFor = value;
            saveSettingsNow();
            if (_current >= 0) rebuildMessageColumn();
        };
        workedRow.add(workedCheck);
        content.add(workedRow);

        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        auto promptButton = footer.add(new Button("System prompt"));
        promptButton.setId("oc-system-prompt-open");
        promptButton.onClick = delegate() { showSystemPromptDialog(); };
        auto chatsButton = footer.add(new Button("Chats folder"));
        chatsButton.setId("oc-chats-folder-open");
        // Reveals the directory that stores persisted chats in the file manager.
        chatsButton.onClick = delegate() { openChatsFolder(); };
        footer.add(new Spacer());
        auto cancelButton = footer.add(new Button("Cancel"));
        cancelButton.onClick = delegate() { dismissPopup(); };
        auto saveButton = footer.add(new Button("Save", IconKind.save));
        saveButton.setAccent(true);
        saveButton.onClick = delegate()
        {
            const baseUrl = baseField.textUtf8().strip();
            const apiKey = keyField.textUtf8().strip();
            const model = modelField.textUtf8().strip();
            const workspace = workspaceField.textUtf8().strip();
            if (baseUrl.length > 0) _settings.baseUrl = baseUrl;
            _settings.apiKey = apiKey;
            if (model.length > 0)
            {
                _settings.model = model;
                if (_current >= 0) _sessions[_current].model = _settings.model;
                updateModelButton();
                refreshUsageBadge();
            }
            if (auto project = activeProject())
            {
                if (workspace.length > 0 && workspace != project.path)
                {
                    project.path = workspace;
                    ensureProjectDirectory(*project);
                    saveProjects(_projectState);
                    updateSessionsHeader();
                }
            }
            saveLoadedRuntime();
            foreach (rt; _conversationRuntimes)
                rt.client.setCredentials(_settings.baseUrl, _settings.apiKey);
            _client.setCredentials(_settings.baseUrl, _settings.apiKey);
            saveSettingsNow();
            updateKeyBadge();
            _client.fetchModels();
            updateStatus("Settings saved.");
            dismissPopup();
        };

        content.add(providerRow);
        content.add(baseRow);
        content.add(keyRow);
        content.add(modelRow);
        content.add(hint);
        content.add(workspaceRow);
        content.add(workspaceHint);
        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(540, 510));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate()
        {
            _activePopup = null;
            _settingsBaseField = null;
            _settingsKeyField = null;
            _settingsModelField = null;
            _settingsProviderButton = null;
        };
        openPopup(popup);
        popup.focusFirst();
    }

    /// A provider preset as a context-menu command bound to its own index (a
    /// factory, so each item captures a distinct index).
    private ContextMenuItem providerMenuItem(int index)
    {
        const preset = providerPresets[cast(size_t) index];
        return ContextMenuItem.command(preset.name,
            delegate() { applyProviderPreset(index); });
    }

    /// Fill the Settings base URL/key/model fields for a provider preset.
    /// Staged: nothing is written to disk until the dialog's Save is pressed.
    private void applyProviderPreset(int index)
    {
        if (index < 0 || index >= cast(int) providerPresets.length) return;
        const preset = providerPresets[cast(size_t) index];
        if (_settingsBaseField !is null) _settingsBaseField.setText(preset.baseUrl);
        if (_settingsKeyField !is null)
            _settingsKeyField.setText(readProviderKey(preset.id));
        if (_settingsModelField !is null)
            _settingsModelField.setText(preset.model);
        if (_settingsProviderButton !is null)
            _settingsProviderButton.setText(preset.name);
    }

    /// Show the exact system prompt that is sent with every request, in a
    /// read-only, scrollable viewer. Reuses the live settings (legacy-tools
    /// toggle) and the active workspace, so what you see is what the model gets.
    private void showSystemPromptDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        version (Windows)
            const platform = "win32";
        else version (Posix)
            const platform = "posix";
        else
            const platform = "unknown";
        string prompt = buildSystemPrompt(!_settings.legacyTools,
            activeWorkspace(), platform);
        if (_current >= 0) prompt ~= durableTaskPrompt(_sessions[_current]);

        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 640;

        auto title = content.add(new Label("System prompt"));
        title.setPixelSize(opencodeFontTitle);

        auto hint = content.add(new Label(
            "Sent as the system message on every request."));
        hint.setScale(1);
        hint.setColor(opencodeMuted);

        auto viewer = new TextArea(prompt);
        viewer.setId("oc-system-prompt");
        viewer.setReadOnly(true);
        viewer.layoutHints().preferredHeight = 420;
        viewer.layoutHints().minHeight = 200;
        content.add(viewer);

        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto close = footer.add(new Button("Close"));
        close.onClick = delegate() { dismissPopup(); };
        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(680, 540));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    private void openPopup(PopupOverlay popup)
    {
        _activePopup = popup;
        auto root = popupRoot(this);
        root.add(popup);
        // Composited overlays are normally sized by the base layout pass via
        // `overlayFillParent`, but that pass only runs while the base is dirty.
        // Adding a composited child marks only the composition dirty, so a popup
        // opened after another composited popup (e.g. a context menu) was
        // dismissed can keep zero bounds and dismiss itself on the first click.
        // Size it explicitly, exactly as showContextMenu does for menus.
        popup.setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
    }

    private void dismissPopup()
    {
        if (_activePopup !is null)
        {
            auto popup = _activePopup;
            _activePopup = null;
            popup.dismiss();
        }
    }

    // -- model / key refresh ---------------------------------------------

    private void applyModels(string[] modelIds)
    {
        _models = modelIds.dup;
        // The OpenCode Go endpoint's /models lists models served over other
        // API shapes (Anthropic /messages, OpenAI /responses). This client
        // speaks /chat/completions only, so drop those ids instead of letting
        // the picker offer a model whose request would fail. Keep the full list
        // if filtering leaves nothing (an unexpected catalog change).
        if (isOpenCodeApiBaseUrl(_client.baseUrl()))
        {
            string[] chatModels;
            foreach (model; _models)
                if (openCodeGoSupportsChatCompletions(model))
                    chatModels ~= model;
            if (chatModels.length > 0) _models = chatModels;
        }
        if (_models.length == 0) _models = defaultModels.dup;
        bool found;
        foreach (model; _models)
            if (model == _settings.model) found = true;
        if (!found)
        {
            // A model saved while the other provider was active can still
            // identify the same model: CommandCode uses `vendor/model` ids and
            // OpenCode the bare id. Match on the normalized form rather than
            // silently jumping to the first model in the list.
            const wanted = normalizedModelId(_settings.model);
            foreach (model; _models)
            {
                if (normalizedModelId(model) != wanted) continue;
                _settings.model = model;
                found = true;
                break;
            }
        }
        if (!found && _models.length > 0)
            _settings.model = _models[0];
        if (!_client.busy())
            updateStatus("Models refreshed.");
        refreshUsageBadge();
    }

    private void updateModelButton()
    {
        _modelButton.setText(_settings.model);
    }

    private void updateKeyBadge()
    {
        const hasKey = _settings.apiKey.length > 0;
        const local = isLoopbackApiBaseUrl(_settings.baseUrl);
        _keyBadge.setText(hasKey ? "Key set" : local ? "Local API" : "No key");
        _keyBadge.setColor(hasKey || local ? opencodeKeyOk : opencodeKeyMissing);
    }

    private void flushToolTranscriptChanges()
    {
        if (!_toolTranscriptDirty) return;
        _toolTranscriptDirty = false;
        if (viewingTurnOwner())
        {
            rebuildMessageColumn();
            _messagesScroll.invalidate();
            refreshBubbleActions();
        }
        markDirty();
    }

    private void updateStatus(string text)
    {
        if (_processingRuntimeSession >= 0 &&
            _processingRuntimeSession != _current) return;
        _status.setText(text);
    }

    private void updateSendButton()
    {
        // The button must reflect the whole turn, not just an in-flight
        // request: between tool rounds no request is streaming, so keying on
        // the client alone flips "Stop" back to "Send" while the agent is
        // still working. `_turnTiming` spans the turn and survives those gaps.
        const busy = turnIsBusy();
        _sendButton.setText(_stopPending ? "Stopping…" : busy ? "Stop" : "Send");
        _sendButton.setEnabled(!_stopPending);
        _sendButton.setAccent(!busy);
    }

    // -- context usage meter ---------------------------------------------

    /// Show model-visible input for the latest request. Completion and total
    /// billing usage are not context occupancy and must not move this meter.
    private void refreshUsageBadge()
    {
        if (_usageBadge is null) return;
        _usageBadge.setModel(_settings.model);
        int prompt = -1, completion = -1, total = -1;
        bool estimated;
        if (_current >= 0)
        {
            auto session = &_sessions[_current];
            const preferEstimate = session.id in _preferEstimatedContext &&
                _preferEstimatedContext[session.id];
            if (!preferEstimate)
            {
                if (auto reported = session.id in _reportedContextTokens)
                {
                    prompt = *reported;
                    total = *reported;
                    if (auto output = session.id in _reportedCompletionTokens)
                        completion = *output;
                }
                else foreach_reverse (slot, index; activeMessagePath(*session))
                {
                    auto message = &session.messages[index];
                    if (message.role == "assistant" && message.promptTokens > 0)
                    {
                        prompt = message.promptTokens;
                        completion = message.completionTokens;
                        total = message.promptTokens;
                        break;
                    }
                }
            }
            if (total <= 0)
                if (auto fallback = session.id in _estimatedContextTokens)
                {
                    prompt = *fallback;
                    completion = 0;
                    total = *fallback;
                    estimated = true;
                }
        }
        _usageBadge.setUsage(prompt, completion, total, estimated);
        refreshContextUsageTooltip();
    }

    private string[] contextUsageTooltipRows()
    {
        string[] rows;
        const hasUsage = _usageBadge !is null && _usageBadge.hasUsage();
        rows ~= "Model: " ~ _settings.model;
        rows ~= "Context limit: " ~
            formatThousands(_usageBadge is null ? 0 : _usageBadge.limit()) ~
            " tokens";
        if (hasUsage)
        {
            rows ~= (_usageBadge.estimated() ? "Estimated active input: " :
                "Active input: ") ~
                formatThousands(_usageBadge.totalTokens()) ~
                " tokens (" ~ to!string(_usageBadge.usagePercent()) ~ "%)";
            if (_usageBadge.estimated())
                rows ~= "Provider usage unavailable; estimate includes " ~
                    "instructions, compacted messages, and tool schemas.";
            else
            {
                rows ~= "Last output: " ~
                    formatThousands(_usageBadge.completionTokens()) ~ " tokens";
            }
            if (_current >= 0)
            {
                const sessionId = _sessions[_current].id;
                if (sessionId in _contextWasCompacted &&
                    _contextWasCompacted[sessionId])
                    rows ~= "Older context was compacted for this request; " ~
                        "the full chat remains saved.";
            }
        }
        else
        {
            rows ~= "Used: —";
            rows ~= "Send a message to start metering context.";
        }
        return rows;
    }

    private void setContextUsageTooltipOpen(bool open)
    {
        if (open)
        {
            if (_usageTooltip is null)
                _usageTooltip = new HoverTooltip(_usageBadge);
            _usageTooltip.setContent("Context usage",
                contextUsageTooltipRows());
            popupRoot(this).add(_usageTooltip);
            positionContextUsageTooltip();
            _usageTooltipOpen = true;
        }
        else
        {
            _usageTooltipOpen = false;
            if (_usageTooltip !is null && _usageTooltip.parent() !is null)
                _usageTooltip.parent().remove(_usageTooltip);
        }
    }

    /// Open/close the generic hover tooltip anchored to a TooltipAnchor.
    private void setTooltipOpen(TooltipAnchor anchor, HoverTooltip tooltip,
        ref bool open, bool value)
    {
        if (value)
        {
            tooltip.setText(anchor.text());
            popupRoot(this).add(tooltip);
            positionTooltip(anchor, tooltip);
            open = true;
        }
        else
        {
            open = false;
            if (tooltip.parent() !is null)
                tooltip.parent().remove(tooltip);
        }
    }

    /// Open/close a hover tooltip from any anchor widget with explicit text.
    private void setTooltipOpen(Widget anchor, string text, HoverTooltip tooltip,
        ref bool open, bool value, bool above = false)
    {
        if (value)
        {
            tooltip.setText(text);
            popupRoot(this).add(tooltip);
            positionTooltip(anchor, tooltip, above);
            open = true;
        }
        else
        {
            open = false;
            if (tooltip.parent() !is null)
                tooltip.parent().remove(tooltip);
        }
    }

    /// Position a generic tooltip near its anchor, clamped to the window.
    /// When `above` is set the tooltip is placed over the anchor, otherwise
    /// under it.
    private void positionTooltip(Widget anchor, HoverTooltip tooltip,
        bool above = false)
    {
        const origin = anchor.localToGlobal(Point(0, 0));
        const anchorRect = Rect(origin.x, origin.y, anchor.bounds().width,
            anchor.bounds().height);
        const measured = tooltip.measure(Size(int.max, int.max));
        const gap = 6;
        int x = anchorRect.x;
        int y = above
            ? anchorRect.y - measured.height - gap
            : anchorRect.bottom() + gap;
        x = clampInt(x, 8, maxInt(8, bounds().width - measured.width - 8));
        y = clampInt(y, 8, maxInt(8, bounds().height - measured.height - 8));
        tooltip.setBounds(Rect(x, y, measured.width, measured.height));
    }

    private void refreshContextUsageTooltip()
    {
        if (!_usageTooltipOpen || _usageTooltip is null) return;
        _usageTooltip.setContent("Context usage", contextUsageTooltipRows());
        positionContextUsageTooltip();
    }

    private void positionContextUsageTooltip()
    {
        if (_usageTooltip is null || _usageBadge is null) return;
        const origin = _usageBadge.localToGlobal(Point(0, 0));
        const anchor = Rect(origin.x, origin.y, _usageBadge.bounds().width,
            _usageBadge.bounds().height);
        const measured = _usageTooltip.measure(Size(int.max, int.max));
        const gap = 6;
        int x = anchor.x;
        // The badge lives in the composer footer at the window bottom, so the
        // tooltip opens above it (below would fall off-screen and be clamped).
        int y = anchor.y - measured.height - gap;
        x = clampInt(x, 8, maxInt(8, bounds().width - measured.width - 8));
        y = clampInt(y, 8, maxInt(8, bounds().height - measured.height - 8));
        _usageTooltip.setBounds(Rect(x, y, measured.width, measured.height));
    }

    // True while an agent turn is running. Its owning conversation may differ
    // from the selected view; the sidebar marker stays with the owner.
    private bool _turnInFlight;

    /// The selected conversation is only a view. Network/tool events continue
    /// to belong to the conversation that started the request even when the
    /// user opens or selects another chat while it works in the background.
    private int turnOwnerSessionIndex() const
    {
        const requestActive = _turnInFlight || _activeRequestId != 0;
        if (requestActive && _activeRequestSession >= 0 &&
            _activeRequestSession < cast(int) _sessions.length)
            return _activeRequestSession;
        if (_turnTiming && _turnSessionIndex >= 0 &&
            _turnSessionIndex < cast(int) _sessions.length)
            return _turnSessionIndex;
        return _current;
    }

    private bool viewingTurnOwner() const
    {
        return _current >= 0 && _current == turnOwnerSessionIndex();
    }

    private int[] activeSessionRows()
    {
        int[] rows;
        foreach (i, sessionIndex; _sessionIndices)
        {
            const id = _sessions[sessionIndex].id;
            bool active;
            if (id == _loadedRuntimeId)
                active = _turnInFlight;
            else if (auto found = id in _conversationRuntimes)
                active = (*found).turnInFlight;
            if (active)
            {
                rows ~= cast(int) i;
            }
        }
        return rows;
    }

    private void setTurnInFlight(bool active)
    {
        if (_turnInFlight == active) return;
        _turnInFlight = active;
        if (_sessionList !is null) _sessionList.setActivityRows(activeSessionRows());
    }

    private void updateSessionList(bool revealCurrent = true)
    {
        ListItem[] items;
        int[] indices;
        const projectId = activeProjectId();
        // Newest conversation first: sessions are appended on creation, so walk
        // the array backwards and keep the real indices for row -> session.
        // Pinned conversations are listed first; each group stays newest-first.
        foreach (bool pinnedPass; [true, false])
        {
            foreach_reverse (index, session; _sessions)
            {
                // Sessions restored from an older build have no project; they
                // belong to the sandbox.
                if (sessionProjectId(session) != projectId) continue;
                const pinned = isSessionPinned(session.id);
                if (pinned != pinnedPass) continue;
                const title = session.title.length > 0 ? session.title
                    : "New chat";
                if (_filterText.length > 0 &&
                    !canFind(title.toLower(), _filterText.toLower()))
                    continue;
                indices ~= cast(int) index;
                string secondary;
                const path = activeMessagePath(session);
                if (path.length > 0)
                    secondary = session.messages[path[$ - 1]].time;
                items ~= ListItem(pinned ? "★ " ~ title : title,
                    IconKind.none, secondary);
            }
        }
        _sessionIndices = indices;
        _sessionList.setItems(items);
        _sessionList.setActivityRows(activeSessionRows());
        int row = -1;
        foreach (i, sessionIndex; _sessionIndices)
            if (sessionIndex == _current) row = cast(int) i;
        if (row >= 0)
            _sessionList.setSelectedIndex(row, false, revealCurrent);
        else
            _sessionList.setSelectedIndex(-1, false);
    }

    // -- Pro session management ------------------------------------------

    private void deleteSessionAtRow(int row)
    {
        if (row < 0 || row >= cast(int) _sessionIndices.length) return;
        deleteSession(_sessionIndices[row]);
    }

    private void deleteSession(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length) return;
        saveLoadedRuntime();
        const removedId = _sessions[sessionIndex].id;
        auto removedRuntime = removedId in _conversationRuntimes;
        if (removedRuntime !is null && (*removedRuntime).busy())
        {
            updateStatus("Stop the running turn before deleting this conversation.");
            return;
        }
        const removed = _sessions[sessionIndex];
        publishRuntimeEvent(AgentEventKind.threadDeleted, removed);
        _sessions = _sessions[0 .. sessionIndex] ~
            _sessions[sessionIndex + 1 .. $];
        if (removedRuntime !is null)
        {
            (*removedRuntime).client.closeSession();
            _conversationRuntimes.remove(removedId);
        }
        if (_current == sessionIndex)
            _current = _sessions.length > 0
                ? minInt(sessionIndex, cast(int) _sessions.length - 1)
                : -1;
        else if (_current > sessionIndex)
            --_current;
        foreach (rt; _conversationRuntimes)
        {
            if (rt.activeRequestSession > sessionIndex)
                --rt.activeRequestSession;
            if (rt.turnSessionIndex > sessionIndex)
                --rt.turnSessionIndex;
        }
        _loadedRuntimeId = "";
        if (_current >= 0) loadRuntime(_current);
        _streamBubble = null;
        _editMessageIndex = -1;
        rebuildMessageColumn();
        updateSessionList();
        markDirty();
        updateStatus(_sessions.length == 0 ? "No conversations yet." : "");
        refreshUsageBadge();
    }

    private void showMessageContextMenu(int messageIndex, Point globalPosition,
        MessageBubble sourceBubble = null, string linkTarget = "")
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return;
        const message = session.messages[cast(size_t) messageIndex];
        const hasSelection = sourceBubble !is null &&
            sourceBubble.hasSelection();
        auto items = [
            ContextMenuItem.command(hasSelection ? "Copy selection"
                : "Copy message", IconKind.save, delegate()
            {
                const payload = hasSelection
                    ? sourceBubble.selectedText() : message.content;
                copyTextToClipboard(payload);
                _lastMessageCopy = payload;
            }, "Ctrl+C"),
        ];
        if (sourceBubble !is null)
        {
            items ~= ContextMenuItem.command("Select all", IconKind.terminal,
                delegate()
                {
                    sourceBubble.selectAll();
                });
        }
        if (message.role == "assistant")
        {
            items ~= ContextMenuItem.command(
                message.failed ? "Retry" : "Regenerate",
                IconKind.refresh, delegate()
                {
                    regenerateLastReply(_current, messageIndex);
                });
            if (!message.failed && message.toolCalls.length == 0)
                items ~= ContextMenuItem.command("Continue",
                    IconKind.chevronRight,
                    delegate()
                    {
                        continueFromReply(_current, messageIndex);
                    });
        }
        else if (message.role == "user")
        {
            items ~= ContextMenuItem.command("Edit & resend", IconKind.settings,
                delegate()
                {
                    editAndResend(_current, messageIndex);
                });
        }
        const workspace = workspaceForSession(_current);
        string[] filePaths;
        if (message.role == "tool")
            filePaths = toolFilePaths(message.toolName,
                message.toolArgs, message.content, workspace);
        if (linkTarget.length > 0 &&
            !linkTarget.toLower().startsWith("http://") &&
            !linkTarget.toLower().startsWith("https://"))
        {
            auto localTarget = linkTarget;
            if (localTarget.toLower().startsWith("file:///"))
                localTarget = localTarget[8 .. $];
            const resolved = resolveDisplayedPath(localTarget, workspace);
            const parent = directoryOf(resolved);
            if (exists(resolved) || (parent.length > 0 && exists(parent)))
                appendUniquePath(filePaths, resolved);
        }
        if (filePaths.length == 1)
            items ~= ContextMenuItem.command("Open containing folder",
                IconKind.folder,
                openFileLocationAction(filePaths[0], workspace));
        else if (filePaths.length > 1)
        {
            ContextMenuItem[] children;
            foreach (filePath; filePaths)
            {
                auto label = basenameOf(filePath);
                if (label.length == 0) label = filePath;
                children ~= ContextMenuItem.command(label,
                    IconKind.folder,
                    openFileLocationAction(filePath, workspace));
            }
            items ~= ContextMenuItem.submenuItem(
                "Open containing folder", IconKind.folder, children);
        }
        showContextMenu(_messageColumn, globalPosition, items);
    }

    private void showSessionContextMenu(int row, Point globalPosition)
    {
        if (row < 0 || row >= cast(int) _sessionIndices.length) return;
        const sessionIndex = _sessionIndices[row];
        auto items = [
            ContextMenuItem.command("Open", IconKind.terminal, delegate()
            {
                selectSession(sessionIndex);
            }, "Enter"),
            ContextMenuItem.command(
                isSessionPinned(_sessions[sessionIndex].id)
                    ? "Unpin conversation" : "Pin conversation",
                IconKind.none, delegate()
                {
                    toggleSessionPin(sessionIndex);
                }),
            ContextMenuItem.command("Rename…", IconKind.settings, delegate()
            {
                showRenameSession(sessionIndex);
            }),
            ContextMenuItem.command("Delete", IconKind.trash, delegate()
            {
                deleteSession(sessionIndex);
            }, "Del"),
        ];
        showContextMenu(_sessionList, globalPosition, items);
    }

    // -- Pinned conversations --------------------------------------------

    private bool isSessionPinned(const string id)
    {
        return id.length > 0 && _pinnedSessionIds.canFind(id);
    }

    private void toggleSessionPin(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        const id = _sessions[sessionIndex].id;
        if (id.length == 0) return;
        if (_pinnedSessionIds.canFind(id))
        {
            string[] kept;
            foreach (pin; _pinnedSessionIds)
                if (pin != id) kept ~= pin;
            _pinnedSessionIds = kept;
        }
        else
        {
            _pinnedSessionIds ~= id;
        }
        savePinnedSessions();
        updateSessionList(false);
    }

    private void loadPinnedSessions()
    {
        const path = buildPath(opencodeStateDirectory(), "pins.json");
        if (!exists(path)) return;
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type != JSONType.array) return;
            string[] ids;
            foreach (item; value.array)
                if (item.type == JSONType.string && item.str.length > 0)
                    ids ~= item.str;
            _pinnedSessionIds = ids;
        }
        catch (Exception error)
            logError("could not read pinned conversations: " ~ error.msg);
    }

    private void savePinnedSessions()
    {
        try
        {
            ensureStateDirectory();
            JSONValue root = JSONValue(string[].init);
            foreach (id; _pinnedSessionIds)
                root.array ~= JSONValue(id);
            writeFileAtomically(
                buildPath(opencodeStateDirectory(), "pins.json"),
                root.toString());
        }
        catch (Exception error)
            logError("could not save pinned conversations: " ~ error.msg);
    }

    private void showRenameSession(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length) return;
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(16));
        content.layoutHints().preferredWidth = 360;
        auto title = content.add(new Label("Rename conversation"));
        title.setPixelSize(opencodeFontTitle);
        auto field = content.add(new TextField(_sessions[sessionIndex].title));
        field.setId("oc-rename-field");
        field.layoutHints().preferredHeight = 30;
        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 36;
        footer.add(new Spacer());
        auto cancelButton = footer.add(new Button("Cancel"));
        cancelButton.onClick = delegate() { dismissPopup(); };
        auto saveButton = footer.add(new Button("Save", IconKind.save));
        saveButton.setId("oc-rename-save");
        saveButton.setAccent(true);
        saveButton.onClick = delegate()
        {
            const name = field.textUtf8().strip();
            if (name.length > 0)
            {
                _sessions[sessionIndex].title = name;
                publishThreadUpdated(_sessions[sessionIndex]);
                updateSessionList();
                markDirty();
            }
            dismissPopup();
        };
        footer.add(saveButton);
        content.add(footer);

        auto popup = new PopupOverlay(content, _sessionList);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(380, 180));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
        field.requestFocus();
    }

    private void exportCurrentConversation()
    {
        if (_current < 0) return;
        const session = &_sessions[_current];
        ensureStateDirectory();
        const exportDir = buildPath(opencodeStateDirectory(), "exports");
        try mkdirRecurse(exportDir);
        catch (Exception) {}
        string safeTitle;
        foreach (ch; session.title)
        {
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == ' ')
                safeTitle ~= ch;
            else
                safeTitle ~= '_';
        }
        while (safeTitle.length > 0 && safeTitle[$ - 1] == ' ')
            safeTitle = safeTitle[0 .. $ - 1];
        if (safeTitle.length == 0) safeTitle = "conversation";
        auto builder = appender!string();
        builder.put("# " ~ session.title ~ "\n\n");
        builder.put("Model: " ~ session.model ~ "  •  Thinking: " ~
            (session.thinking ? "on" : "off") ~ "\n\n---\n\n");
        foreach (index; activeMessagePath(*session))
        {
            const message = session.messages[index];
            builder.put("## " ~ (message.role == "user" ? "User" :
                (message.role == "tool" ? "Tool (" ~ message.toolName ~ ")" :
                    "Assistant")));
            if (message.time.length > 0)
                builder.put(" (" ~ message.time ~ ")");
            builder.put("\n\n" ~ message.content ~ "\n\n---\n\n");
        }
        const path = buildPath(exportDir, safeTitle ~ ".md");
        try
        {
            write(path, builder.data);
            updateStatus("Exported to " ~ path);
        }
        catch (Exception error)
        {
            updateStatus("Export failed: " ~ error.msg);
        }
    }

    // -- persistence ------------------------------------------------------

    private void markDirty()
    {
        _stateDirty = true;
        _persistDue = MonoTime.currTime + msecs(persistDebounceMs);
        // Message/task mutations are already appended synchronously to the
        // durable runtime journal, which startup treats as the recovery
        // authority. Re-serializing every conversation here made each streamed
        // tool result rewrite tens of megabytes. Keep the compatibility JSON
        // snapshot debounced; a crash between snapshots is recovered by replay.
    }

    /**
     * Write the newest state to the durable copy the next start reads.
     *
     * Kept deliberately separate from `persistState`: this one runs at the
     * moment a message changes, so it must not do anything that can block or
     * throw into the UI path. A failure here is logged and dropped, leaving
     * the previous copy - and the debounced save - as the fallback.
     */
    private void persistRecoveryState()
    {
        if (_recoveryBlocked) return;
        try
        {
            ensureStateDirectory();
            JSONValue root;
            JSONValue list = JSONValue(string[].init);
            foreach (session; _sessions)
                list.array ~= sessionToJson(session);
            root["sessions"] = list;
            root["current"] = _current;
            writeFileAtomically(
                buildPath(opencodeStateDirectory(), "sessions.recovery.json"),
                root.toString());
        }
        catch (Throwable error)
        {
            // One failure disables the copy for this run rather than letting a
            // broken path retry on every message.
            _recoveryBlocked = true;
            try logError("recovery save failed: " ~ error.toString());
            catch (Throwable) {}
        }
    }

    private bool _recoveryBlocked;

    private void saveSettingsNow()
    {
        saveSettings(_settings);
    }

    private void persistState()
    {
        _stateDirty = false;
        ensureStateDirectory();
        JSONValue root;
        JSONValue list = JSONValue(string[].init);
        foreach (session; _sessions)
            list.array ~= sessionToJson(session);
        root["sessions"] = list;
        root["current"] = _current;
        const path = buildPath(opencodeStateDirectory(), "sessions.json");
        try writeFileAtomically(path, root.toString());
        catch (Exception error)
        {
            logError("persist sessions failed: " ~ error.msg);
        }
    }

    /**
     * Replace a file's contents without ever leaving it half-written.
     *
     * A plain write truncates first, so being killed part-way through leaves a
     * truncated file - which is how a crash or a restart could cost the whole
     * conversation history: the next start read the partial file, failed to
     * parse it, and (before that was fixed) discarded every session. Writing to
     * a temporary file and renaming it over the target makes the replacement
     * atomic: the target is either the old file or the new one, never a
     * fragment of either. The previous contents are kept as `.bak` so a damaged
     * primary still has a readable fallback.
     */
    private static void writeFileAtomically(string path, string contents)
    {
        // Write the new contents beside the target first: a crash here only
        // ever risks the temporary file, never the live one.
        const temporary = path ~ ".tmp";
        write(temporary, contents);
        // Keep the last good copy as `.bak` for recovery, without moving the
        // primary out of the way. This is best effort; a failure here must not
        // prevent the save.
        if (exists(path))
        {
            const backup = path ~ ".bak";
            try
            {
                if (exists(backup)) fileRemove(backup);
                write(backup, readText(path));
            }
            catch (Exception)
            {
                // A missing backup is not a reason to fail the save.
            }
        }
        // Install the new contents with a single atomic replace
        // (MoveFileEx + MOVEFILE_REPLACE_EXISTING, via std.file.rename): the
        // target is always either the whole old file or the whole new one.
        // The primary is never renamed away first, so there is no instant at
        // which it does not exist. That window is what let a crash mid-save
        // leave no sessions.json at all and blank the conversation list.
        rename(temporary, path);
    }

    private static JSONValue sessionToJson(const ref ChatSession session)
    {
        JSONValue root;
        if (session.id.length > 0) root["id"] = session.id;
        root["title"] = session.title;
        root["model"] = session.model;
        root["thinking"] = session.thinking;
        if (session.projectId.length > 0)
            root["project"] = session.projectId;
        if (session.objective.length > 0) root["objective"] = session.objective;
        if (session.taskStatus.length > 0)
            root["taskStatus"] = session.taskStatus;
        if (session.verificationStatus.length > 0)
            root["verificationStatus"] = session.verificationStatus;
        if (session.taskSteps.length > 0)
        {
            JSONValue steps = JSONValue(string[].init);
            foreach (step; session.taskSteps)
            {
                JSONValue value;
                value["text"] = step.text;
                value["status"] = step.status;
                steps.array ~= value;
            }
            root["taskSteps"] = steps;
        }
        if (session.queuedGuidance.length > 0)
        {
            JSONValue guidance = JSONValue(string[].init);
            foreach (item; session.queuedGuidance)
                guidance.array ~= JSONValue(item);
            root["queuedGuidance"] = guidance;
        }
        if (session.activeLeafId.length > 0)
            root["activeLeaf"] = session.activeLeafId;
        JSONValue messages = JSONValue(string[].init);
        foreach (message; session.messages)
        {
            JSONValue messageJson;
            if (message.id.length > 0)
                messageJson["id"] = message.id;
            if (message.parentId.length > 0)
                messageJson["parentId"] = message.parentId;
            messageJson["role"] = message.role;
            messageJson["content"] = message.content;
            if (message.reasoning.length > 0)
                messageJson["reasoning"] = message.reasoning;
            if (message.time.length > 0)
                messageJson["time"] = message.time;
            if (message.failed)
                messageJson["failed"] = true;
            if (message.finishReason.length > 0)
                messageJson["finishReason"] = message.finishReason;
            if (message.internal)
                messageJson["internal"] = true;
            if (message.totalTokens > 0 || message.completionTokens > 0)
            {
                messageJson["promptTokens"] = message.promptTokens;
                messageJson["completionTokens"] = message.completionTokens;
                messageJson["totalTokens"] = message.totalTokens;
            }
            if (message.tokensPerSecondTenths > 0)
                messageJson["tokensPerSecondTenths"] =
                    message.tokensPerSecondTenths;
            if (message.toolCalls.length > 0)
            {
                JSONValue calls = JSONValue(string[].init);
                foreach (call; message.toolCalls)
                {
                    JSONValue callJson;
                    callJson["id"] = call.id;
                    callJson["name"] = call.name;
                    callJson["arguments"] = call.arguments;
                    calls.array ~= callJson;
                }
                messageJson["toolCalls"] = calls;
            }
            if (message.toolCallId.length > 0)
                messageJson["toolCallId"] = message.toolCallId;
            if (message.toolName.length > 0)
                messageJson["toolName"] = message.toolName;
            if (message.toolArgs.length > 0)
                messageJson["toolArgs"] = message.toolArgs;
            // File-mutating tools carry a computed diff. It must survive a
            // restart: without it an expanded edit loses its green/red `+N -M`
            // counters and its line-numbered unified body (the old behavior
            // showed only the one-line tool summary).
            if (message.diffAdditions > 0)
                messageJson["diffAdditions"] = message.diffAdditions;
            if (message.diffDeletions > 0)
                messageJson["diffDeletions"] = message.diffDeletions;
            if (message.toolDiff.length > 0)
                messageJson["toolDiff"] = message.toolDiff;
            // The tool's wall-clock duration must also survive a restart, so a
            // reloaded transcript still shows how long each command took.
            if (message.toolElapsedMs > 0)
                messageJson["toolElapsedMs"] = message.toolElapsedMs;
            // A finished turn's working time is stored on its opening user
            // message, so the conversation timer survives a restart.
            if (isFinite(message.workedSeconds) && message.workedSeconds > 0)
                messageJson["workedSeconds"] = message.workedSeconds;
            messages.array ~= messageJson;
        }
        root["messages"] = messages;
        return root;
    }

    private void restoreSessions()
    {
        _sessions.length = 0;
        loadPinnedSessions();
        const dir = opencodeStateDirectory();
        // Crash-safe saving renames sessions.json through .bak/.tmp in several
        // steps and also writes a per-message recovery copy, so a crash can
        // leave the live file holding only the newest conversation while the
        // rest of the history survives in a sibling snapshot. Load every
        // snapshot and merge them (keeping the most complete copy of each
        // conversation) instead of trusting a single file.
        import std.file : dirEntries, SpanMode;
        string[] candidates = [
            buildPath(dir, "sessions.recovery.json"),
            buildPath(dir, "sessions.json"),
        ];
        try
        {
            import std.algorithm.searching : startsWith;
            import std.path : baseName;
            import std.string : indexOf;
            foreach (entry; dirEntries(dir, SpanMode.breadth))
            {
                if (!entry.isFile) continue;
                const name = baseName(entry.name);
                if (!name.startsWith("sessions")) continue;
                if (name.indexOf(".json") < 0) continue;
                // A quarantined (`.bad`) or manually preserved
                // (`.preserve-...`) copy is known not to parse. Reading it
                // every launch only reproduces the same error and wastes the
                // restore; `.bak`/`.tmp` are left in because they can be the
                // last complete save.
                if (name.indexOf(".bad") >= 0 ||
                    name.indexOf(".preserve") >= 0) continue;
                candidates ~= entry.name;
            }
        }
        catch (Exception scanError)
            logError("could not scan the state directory: " ~ scanError.msg);

        int preferredCurrent = -1;
        foreach (candidate; candidates)
        {
            if (!exists(candidate)) continue;
            try
            {
                auto value = parseJSON(readText(candidate));
                if (value.type != JSONType.object) continue;
                if (auto found = "current" in value.object)
                    if (preferredCurrent < 0)
                        preferredCurrent = cast(int) found.integer;
                if (auto found = "sessions" in value.object)
                {
                    if (found.type != JSONType.array) continue;
                    foreach (sessionValue; found.array)
                    {
                        if (sessionValue.type != JSONType.object) continue;
                        ChatSession session;
                        if (auto field = "id" in sessionValue.object)
                            session.id = field.str;
                        if (auto field = "title" in sessionValue.object)
                            session.title = field.str;
                        if (auto field = "model" in sessionValue.object)
                            session.model = field.str;
                        if (auto field = "thinking" in sessionValue.object)
                            session.thinking = field.type == JSONType.true_;
                        if (auto field = "project" in sessionValue.object)
                            session.projectId = field.str;
                        if (auto field = "objective" in sessionValue.object)
                            session.objective = field.str;
                        if (auto field = "taskStatus" in sessionValue.object)
                            session.taskStatus = field.str;
                        if (auto field = "verificationStatus" in
                            sessionValue.object)
                            session.verificationStatus = field.str;
                        if (auto field = "taskSteps" in sessionValue.object)
                            if (field.type == JSONType.array)
                                foreach (item; field.array)
                                {
                                    if (item.type != JSONType.object) continue;
                                    TaskStep step;
                                    if (auto f = "text" in item.object)
                                        if (f.type == JSONType.string)
                                            step.text = f.str;
                                    if (auto f = "status" in item.object)
                                        if (f.type == JSONType.string)
                                            step.status = f.str;
                                    if (step.text.length > 0)
                                        session.taskSteps ~= step;
                                }
                        if (auto field = "queuedGuidance" in sessionValue.object)
                            if (field.type == JSONType.array)
                                foreach (item; field.array)
                                    if (item.type == JSONType.string)
                                        session.queuedGuidance ~= item.str;
                        if (session.projectId.length == 0)
                            session.projectId = sandboxProjectId;
                        if (auto field = "activeLeaf" in sessionValue.object)
                            session.activeLeafId = field.str;
                        if (auto field = "messages" in sessionValue.object)
                        {
                            if (field.type == JSONType.array)
                            {
                                foreach (messageValue; field.array)
                                {
                                    if (messageValue.type != JSONType.object)
                                        continue;
                                    ChatMessage message;
                                    if (auto f = "id" in messageValue.object)
                                        message.id = f.str;
                                    if (auto f = "parentId" in messageValue.object)
                                        message.parentId = f.str;
                                    if (auto f = "role" in messageValue.object)
                                        message.role = f.str;
                                    if (auto f = "content" in messageValue.object)
                                        message.content = f.str;
                                    if (auto f = "reasoning" in messageValue.object)
                                        message.reasoning = f.str;
                                    if (auto f = "time" in messageValue.object)
                                        message.time = f.str;
                                    if (auto f = "failed" in messageValue.object)
                                        message.failed = f.type == JSONType.true_;
                                    if (auto f = "finishReason" in
                                        messageValue.object)
                                        if (f.type == JSONType.string)
                                            message.finishReason = f.str;
                                    if (auto f = "internal" in messageValue.object)
                                        message.internal = f.type == JSONType.true_;
                                    if (auto f = "promptTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.promptTokens = cast(int) f.integer;
                                    if (auto f = "completionTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.completionTokens = cast(int) f.integer;
                                    if (auto f = "totalTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.totalTokens = cast(int) f.integer;
                                    if (auto f = "tokensPerSecondTenths" in
                                        messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.tokensPerSecondTenths =
                                                cast(int) f.integer;
                                    if (auto f = "toolCallId" in messageValue.object)
                                        message.toolCallId = f.str;
                                    if (auto f = "toolName" in messageValue.object)
                                        message.toolName = f.str;
                                    if (auto f = "toolArgs" in messageValue.object)
                                        message.toolArgs = f.str;
                                    if (auto f = "diffAdditions" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.diffAdditions = cast(int) f.integer;
                                    if (auto f = "diffDeletions" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.diffDeletions = cast(int) f.integer;
                                    if (auto f = "toolDiff" in messageValue.object)
                                        message.toolDiff = f.str;
                                    if (auto f = "toolElapsedMs" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.toolElapsedMs = cast(long) f.integer;
                                    if (auto f = "workedSeconds" in messageValue.object)
                                    {
                                        if (f.type == JSONType.integer)
                                            message.workedSeconds = cast(double) f.integer;
                                        else if (f.type == JSONType.float_)
                                            message.workedSeconds = f.floating;
                                    }
                                    if (auto f = "toolCalls" in messageValue.object)
                                    {
                                        if (f.type == JSONType.array)
                                        {
                                            foreach (callValue; f.array)
                                            {
                                                if (callValue.type != JSONType.object)
                                                    continue;
                                                OpenCodeToolCall call;
                                                if (auto c = "id" in callValue.object)
                                                    call.id = c.str;
                                                if (auto c = "name" in callValue.object)
                                                    call.name = c.str;
                                                if (auto c = "arguments" in callValue.object)
                                                    call.arguments = c.str;
                                                message.toolCalls ~= call;
                                            }
                                        }
                                    }
                                    session.messages ~= message;
                                }
                            }
                        }
                        mergeRestoredSession(session);
                                    }
                                }
                            }
                        catch (Exception error)
                        {
                            // A single unreadable snapshot must not discard the
                            // sessions already merged from the other snapshots.
                            logError("skipping unreadable sessions snapshot " ~
                                candidate ~ ": " ~ error.msg);
                        }
                        }
        // The event journal is the recovery authority. Merge it after every
        // snapshot so the latest flushed item/task update wins even when the
        // compatibility JSON cache was missing or saved a moment earlier.
        if (_runtime !is null)
        {
            const events = _runtime.history();
            foreach (deletedId; deletedAgentRuntimeThreadIds(events))
                foreach_reverse (index; 0 .. _sessions.length)
                    if (_sessions[index].id == deletedId)
                        _sessions = _sessions[0 .. index] ~
                            _sessions[index + 1 .. $];
            foreach (session; projectAgentRuntimeEvents(events))
                mergeJournalSession(session);
        }
        // Repair/backfill the message graph for sessions saved before branching
        // existed (or with dangling links), once, after the snapshots have been
        // merged. Repairing during parsing minted ids for legacy (id-less)
        // messages before the merge compared them, so the same file loaded
        // twice looked like two different conversations and was duplicated.
        foreach (ref session; _sessions)
        {
            ensureMessageGraph(session);
            if (session.id.length == 0)
            {
                // A legacy transcript has no thread id. Derive it from the
                // now-stable opening message so it remains the same thereafter.
                session.id = session.messages.length > 0
                    ? "t-" ~ session.messages[0].id : newSessionId();
            }
            if (session.taskSteps.length == 0 &&
                (session.taskStatus == "active" ||
                 session.taskStatus == "reviewing" ||
                 session.taskStatus == "verifying") &&
                likelyChangeRequest(session.objective))
            {
                initializeAutomaticTaskPlan(session);
                publishThreadUpdated(session);
                _stateDirty = true;
                _persistDue = MonoTime.currTime;
            }
        }
        if (preferredCurrent >= 0 && preferredCurrent < cast(int) _sessions.length)
            _current = preferredCurrent;
        if (_sessions.length > 0)
        {
            // The snapshot's `current` index may no longer address the merged
            // list (a snapshot with more sessions was written after the merge
            // order was fixed, or a stale `_current` survived from before the
            // reload). Clamp it or `_sessions[_current]` faults on the first
            // access after a reload.
            if (_current < 0 || _current >= cast(int) _sessions.length)
                _current = 0;
            _settings.model = _sessions[_current].model;
            _settings.thinking = _sessions[_current].thinking;
            _modelButton.setText(_settings.model);
            _thinkingBox.setChecked(_settings.thinking, false);
            rebuildMessageColumn();
        }
        else
            _current = -1;
        refreshUsageBadge();
    }

    /// Merge a session parsed from a snapshot into the live list. When the same
    /// conversation is already present (matched by title and opening message),
    /// keep whichever copy holds more messages so a partial snapshot can never
    /// replace a more complete one.
    /**
     * Whether two restored sessions are the same conversation rather than two
     * chats that merely share a title and opening prompt. Every chat the user
     * has not titled is called "New chat", and a scripted run can even produce
     * byte-identical transcripts, so title + first content is not distinctive:
     * matching on it merged independent conversations and dropped one, which
     * shifted every later index (and made a reload address the wrong session).
     * Message ids are minted once per message and are copied into every
     * snapshot of the same conversation, so they identify it; the content
     * fallback only applies to legacy sessions saved before ids existed.
     */
    private static bool sameRestoredConversation(const ref ChatSession a,
        const ref ChatSession b)
    {
        if (a.id.length > 0 && b.id.length > 0) return a.id == b.id;
        if (a.title != b.title) return false;
        if (a.messages.length == 0 || b.messages.length == 0)
            return a.messages.length == b.messages.length;
        const firstA = a.messages[0];
        const firstB = b.messages[0];
        if (firstA.id.length > 0 && firstB.id.length > 0)
            return firstA.id == firstB.id;
        return firstA.content == firstB.content;
    }

    private void mergeRestoredSession(ChatSession session)
    {
        foreach (ref existing; _sessions)
        {
            if (!sameRestoredConversation(existing, session)) continue;
            if (session.messages.length > existing.messages.length)
                existing = session;
            return;
        }
        _sessions ~= session;
    }

    private void mergeJournalSession(ChatSession recovered)
    {
        foreach (ref existing; _sessions)
        {
            if (!sameRestoredConversation(existing, recovered)) continue;
            if (recovered.title.length > 0) existing.title = recovered.title;
            if (recovered.model.length > 0) existing.model = recovered.model;
            if (recovered.projectId.length > 0)
                existing.projectId = recovered.projectId;
            existing.thinking = recovered.thinking;
            if (recovered.objective.length > 0)
                existing.objective = recovered.objective;
            if (recovered.taskStatus.length > 0)
                existing.taskStatus = recovered.taskStatus;
            if (recovered.verificationStatus.length > 0)
                existing.verificationStatus = recovered.verificationStatus;
            if (recovered.taskSteps.length > 0)
                existing.taskSteps = recovered.taskSteps.dup;
            existing.queuedGuidance = recovered.queuedGuidance.dup;
            foreach (message; recovered.messages)
            {
                bool found;
                foreach (ref current; existing.messages)
                    if (current.id == message.id)
                    {
                        const oldWorked = current.workedSeconds;
                        const oldRate = current.tokensPerSecondTenths;
                        const oldElapsed = current.toolElapsedMs;
                        const oldAdds = current.diffAdditions;
                        const oldDeletes = current.diffDeletions;
                        const oldDiff = current.toolDiff;
                        current = message;
                        if ((!isFinite(current.workedSeconds) ||
                            current.workedSeconds <= 0) &&
                            isFinite(oldWorked) && oldWorked > 0)
                            current.workedSeconds = oldWorked;
                        if (current.tokensPerSecondTenths == 0)
                            current.tokensPerSecondTenths = oldRate;
                        if (current.toolElapsedMs == 0)
                            current.toolElapsedMs = oldElapsed;
                        if (current.diffAdditions == 0)
                            current.diffAdditions = oldAdds;
                        if (current.diffDeletions == 0)
                            current.diffDeletions = oldDeletes;
                        if (current.toolDiff.length == 0)
                            current.toolDiff = oldDiff;
                        found = true;
                        break;
                    }
                if (!found) existing.messages ~= message;
            }
            if (recovered.activeLeafId.length > 0)
                existing.activeLeafId = recovered.activeLeafId;
            return;
        }
        _sessions ~= recovered;
    }

    /// Move an unreadable sessions file aside so the next launch starts clean
    /// without destroying the bytes that caused the failure.
    private void quarantineSessionsFile(string path)
    {
        const broken = path ~ ".bad";
        try
        {
            if (exists(broken)) fileRemove(broken);
            rename(path, broken);
            logError("unreadable sessions file moved to " ~ broken);
        }
        catch (Exception moveError)
            logError("could not move the sessions file aside: " ~ moveError.msg);
    }

    // -- tick -------------------------------------------------------------

    protected override void onTick(double deltaSeconds)
    {
        // Resume after an unexpected shutdown, once the restored transcript has
        // been laid out. Sending earlier would extend a conversation whose
        // widgets are not built yet.
        if (_resumeCountdown > 0 && --_resumeCountdown == 0 &&
            _resumePrompt.length > 0)
        {
            const prompt = _resumePrompt;
            _resumePrompt = "";
            logInfo("resuming after an unexpected shutdown");
            if (_current >= 0)
            {
                appendQueuedGuidance(_sessions[_current]);
                ChatMessage recovery;
                recovery.role = "user";
                recovery.internal = true;
                recovery.content = prompt;
                recovery.time = currentTimestamp();
                appendMessage(_sessions[_current], recovery);
                markDirty();
                startChatRequest(_current);
            }
            updateStatus("Resuming after an unexpected shutdown…");
        }

        // Hover-intent delay for the context tooltip.
        if (_usageTooltipPending && !_usageTooltipOpen)
        {
            _usageTooltipHoverSeconds += deltaSeconds;
            if (_usageTooltipHoverSeconds >= usageTooltipDelaySeconds)
            {
                _usageTooltipPending = false;
                setContextUsageTooltipOpen(true);
            }
        }

        // Each conversation owns a separate client and event queue. Service
        // all of them on every UI tick, then restore the selected context.
        saveLoadedRuntime();
        const selectedRuntimeSession = _current;
        foreach (runtimeIndex; 0 .. _sessions.length)
        {
            const runtimeId = _sessions[runtimeIndex].id;
            if (runtimeId != _loadedRuntimeId &&
                (runtimeId in _conversationRuntimes) is null)
                continue;
            _processingRuntimeSession = cast(int) runtimeIndex;
            loadRuntime(cast(int) runtimeIndex);
        _client.drain(_eventScratch);
        _batchingToolResults = true;
        size_t eventIndex;
        while (eventIndex < _eventScratch.length)
        {
            auto event = _eventScratch[eventIndex];
            // Cancellation, navigation, and a subsequent request can all race
            // with a worker's final queue push. Never attach those stale bytes
            // or tool results to a different conversation/branch.
            if (event.requestId != 0 && event.requestId != _activeRequestId)
            {
                ++eventIndex;
                continue;
            }
            // Providers commonly send a few bytes per SSE record. Merge only
            // adjacent fragments of the same channel, preserving exact ordering
            // between reasoning, prose, tools, usage, and terminal events.
            if (event.kind == OpenCodeEventKind.delta)
            {
                const reasoning = event.reasoning;
                auto merged = appender!string();
                while (eventIndex < _eventScratch.length &&
                    _eventScratch[eventIndex].kind == OpenCodeEventKind.delta &&
                    _eventScratch[eventIndex].reasoning == reasoning &&
                    _eventScratch[eventIndex].requestId == event.requestId)
                {
                    merged.put(_eventScratch[eventIndex].text);
                    ++eventIndex;
                }
                appendStreamDelta(merged.data, reasoning);
                continue;
            }
            ++eventIndex;
            final switch (event.kind)
            {
                case OpenCodeEventKind.chatBegin:
                    beginAssistantMessage();
                    break;
                case OpenCodeEventKind.delta:
                    assert(false, "delta handled by the coalescing path");
                    break;
                case OpenCodeEventKind.usage:
                    // The provider reports live token usage while streaming;
                    // surface it on the growing reply and the context meter.
                    // The stream bubble is always the latest assistant reply.
                    // The exact completion count replaces the local estimate on
                    // the Thinking header; the total goes in the footer.
                    _liveTotalTokens = event.totalTokens;
                    if (event.promptTokens > 0)
                    {
                        const owner = turnOwnerSessionIndex();
                        if (owner >= 0 && owner < cast(int) _sessions.length)
                        {
                            _reportedContextTokens[_sessions[owner].id] =
                                event.promptTokens;
                            _reportedCompletionTokens[_sessions[owner].id] =
                                event.completionTokens;
                            _preferEstimatedContext[_sessions[owner].id] = false;
                        }
                    }
                    if (event.completionTokens > 0)
                        _liveOutputTokens = event.completionTokens;
                    updateLiveTokenRate();
                    if (_streamBubble !is null)
                    {
                        _streamBubble.setLiveTokens(_liveOutputTokens, true);
                        _streamBubble.setTokenRate(_liveTokenRateTenths);
                        if (!_streamBubble.hasThinkingForTesting())
                            _streamBubble.setUsageText(liveTokenStatsText());
                    }
                    // Only the viewed conversation owns the badge. A background
                    // turn keeps recording its usage in the maps above, but its
                    // numbers must never overwrite the meter for a different
                    // chat the user is looking at (that mixed one session's
                    // tokens with another session's context limit).
                    if (_usageBadge !is null && viewingTurnOwner())
                    {
                        if (event.promptTokens > 0)
                            _usageBadge.setUsage(event.promptTokens,
                                event.completionTokens, event.promptTokens);
                        refreshContextUsageTooltip();
                    }
                    break;
                case OpenCodeEventKind.toolCallDelta:
                    handleToolCallProgress(event);
                    break;
                case OpenCodeEventKind.toolCalls:
                    handleToolCalls(event);
                    break;
                case OpenCodeEventKind.toolResult:
                    applyToolResult(event);
                    break;
                case OpenCodeEventKind.done:
                    const completedRequestId = event.requestId;
                    const taskContinues = taskContinuesAfterDone(event.cancelled);
                    finishAssistantMessage(event.cancelled, event.promptTokens,
                        event.completionTokens, event.totalTokens,
                        !taskContinues, event.finishReason);
                    continueOrCompleteTask(event.cancelled);
                    // A continuation started above owns a new id. Only clear the
                    // completed request when no replacement was launched.
                    if (_activeRequestId == completedRequestId)
                    {
                        _activeRequestId = 0;
                        _activeRequestSession = -1;
                    }
                    break;
                case OpenCodeEventKind.error:
                    failAssistantMessage(event.text);
                    if (_activeRequestId == event.requestId)
                    {
                        _activeRequestId = 0;
                        _activeRequestSession = -1;
                    }
                    break;
                case OpenCodeEventKind.models:
                    applyModels(event.modelIds);
                    break;
                case OpenCodeEventKind.modelsError:
                    // Discovery is independent of chat. Keep the configured
                    // model usable and never turn this into a failed reply or
                    // overwrite the more important status of an active turn.
                    if (!_client.busy())
                        updateStatus("Could not refresh models: " ~ event.text);
                    break;
            }
        }
        _batchingToolResults = false;
        flushToolTranscriptChanges();

        // `stopActiveTurn` releases all logical/UI state immediately. The only
        // remaining gate is the old WinINet worker; re-enable Send as soon as
        // closing its handle has unwound the worker.
        if (_stopPending && !_client.busy())
        {
            _stopPending = false;
            updateStatus("Stopped.");
            updateSendButton();
        }
        else if (_stopPending &&
            (MonoTime.currTime - _stopRequestedAt).total!"msecs" >=
                stopDetachTimeoutMs)
        {
            // A provider/WinINet stack that ignores handle cancellation must
            // not own the composer forever. Detach its daemon worker and give
            // subsequent turns a fresh client; the retired client's queue is
            // no longer drained, so it cannot leak late output into the UI.
            auto retired = _client;
            retired.closeSession();
            _client = new OpenCodeClient(_settings.baseUrl, _settings.apiKey);
            _stopPending = false;
            updateStatus("Stopped.");
            updateSendButton();
        }

        // The upstream model can take several seconds to return its first
        // token (cold start). Surface that as a live countdown so the UI
        // never looks frozen, and switch back to a normal status the moment
        // the first streamed fragment arrives.
        if (_client.busy() && !_receivedFirstDelta)
        {
            const elapsed = MonoTime.currTime - _chatStartedAt;
            const seconds = cast(int) elapsed.total!"seconds";
            if (seconds >= 2 && seconds != _lastColdStartSeconds)
            {
                _lastColdStartSeconds = seconds;
                updateStatus("Cold-starting the model… " ~
                    to!string(seconds) ~ "s — first reply can take a while");
            }
        }

        // Animate the pulsing "Thinking…" indicator while reasoning streams.
        if (_streamBubble !is null)
            _streamBubble.tickThinking(deltaSeconds);

            saveLoadedRuntime();
        }
        _processingRuntimeSession = -1;
        if (selectedRuntimeSession >= 0 &&
            selectedRuntimeSession < cast(int) _sessions.length)
        {
            loadRuntime(selectedRuntimeSession);
            // A background runtime may have updated the shared usage widget;
            // restore the selected chat's durable usage before painting.
            refreshUsageBadge();
        }

        if (_sessionsRatioDirty)
        {
            _sessionsRatioDirty = false;
            saveProjects(_projectState);
        }

        if (_stateDirty && MonoTime.currTime >= _persistDue)
            persistState();

        // Tick the conversation stopwatch a few times a second rather than every
        // frame: the displayed value only changes once per whole second.
        _timerBadgeAccum += deltaSeconds;
        if (_timerBadgeAccum >= 0.2)
        {
            _timerBadgeAccum = 0;
            refreshTimerBadge();
        }

        updateSendButton();
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.n)
        {
            newChat();
            return true;
        }
        if (shortcut && event.key == Key.v)
        {
            // Paste into the composer from anywhere in the window. After
            // selecting transcript text the bubble holds focus, so Ctrl+V must
            // bring the caret back to the input before pasting.
            _input.requestFocus();
            _input.pasteFromClipboard();
            return true;
        }
        return false;
    }

    // -- test accessors ---------------------------------------------------

    /// Test-only: full text of the latest assistant message in the current session.
    public string lastAssistantContentForTesting()
    {
        if (_current < 0) return "";
        auto session = &_sessions[_current];
        const path = activeMessagePath(*session);
        if (path.length == 0) return "";
        return session.messages[path[$ - 1]].content;
    }

    /// Test-only: number of persisted chat sessions.
    public size_t sessionCountForTesting() const
    {
        return _sessions.length;
    }

    public int currentSessionForTesting() const
    {
        return _current;
    }

    public int turnOwnerSessionForTesting() const
    {
        foreach (index, session; _sessions)
        {
            if (session.id == _loadedRuntimeId && _turnInFlight)
                return cast(int) index;
            if (auto found = session.id in _conversationRuntimes)
                if ((*found).turnInFlight) return cast(int) index;
        }
        return turnOwnerSessionIndex();
    }

    public void selectSessionForTesting(int index)
    {
        selectSession(index);
    }

    public string lastMessageContentInSessionForTesting(int index) const
    {
        if (index < 0 || index >= cast(int) _sessions.length ||
            _sessions[index].messages.length == 0) return "";
        return _sessions[index].messages[$ - 1].content;
    }

    public string activeSessionRowsForTesting() const
    {
        return _sessionList is null ? "" : _sessionList.activityRowsForTesting();
    }

    public bool sessionTurnBusyForTesting(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return false;
        const id = _sessions[sessionIndex].id;
        if (id == _loadedRuntimeId)
            return _turnInFlight || _turnTiming || _stopPending ||
                _activeRequestId != 0 || _pendingToolResults > 0;
        if (auto found = id in _conversationRuntimes)
            return (*found).busy();
        return false;
    }

    public void setTaskStateForTesting(string objective, string status,
        string verification)
    {
        if (_current < 0) return;
        _sessions[_current].objective = objective;
        _sessions[_current].taskStatus = status;
        _sessions[_current].verificationStatus = verification;
        publishThreadUpdated(_sessions[_current]);
        markDirty();
    }

    public void setLastFinishReasonForTesting(string reason)
    {
        if (_current < 0) return;
        const path = activeMessagePath(_sessions[_current]);
        if (path.length == 0) return;
        auto message = &_sessions[_current].messages[path[$ - 1]];
        message.finishReason = reason;
        publishMessageEvent(AgentEventKind.itemUpdated,
            _sessions[_current], *message);
        markDirty();
        rebuildMessageColumn();
    }

    public string taskObjectiveForTesting() const
    {
        return _current < 0 ? "" : _sessions[_current].objective;
    }

    public string taskStatusForTesting() const
    {
        return _current < 0 ? "" : _sessions[_current].taskStatus;
    }

    public string verificationStatusForTesting() const
    {
        return _current < 0 ? "" : _sessions[_current].verificationStatus;
    }

    public size_t taskStepCountForTesting() const
    {
        return _current < 0 ? 0 : _sessions[_current].taskSteps.length;
    }

    public string taskStepStatusForTesting(int index) const
    {
        if (_current < 0 || index < 0 ||
            index >= cast(int) _sessions[_current].taskSteps.length) return "";
        return _sessions[_current].taskSteps[cast(size_t) index].status;
    }

    public bool initializeAutomaticPlanForTesting(string request)
    {
        if (_current < 0 || !likelyChangeRequest(request)) return false;
        initializeAutomaticTaskPlan(_sessions[_current]);
        return true;
    }

    public void applyPlanForTesting(string arguments)
    {
        if (_current >= 0) applyDurablePlan(_sessions[_current], arguments);
    }

    public void queueGuidanceForTesting(string guidance)
    {
        if (_current < 0 || guidance.strip().length == 0) return;
        _sessions[_current].queuedGuidance ~= guidance.strip();
        publishThreadUpdated(_sessions[_current]);
        markDirty();
    }

    public size_t queuedGuidanceCountForTesting() const
    {
        return _current < 0 ? 0 : _sessions[_current].queuedGuidance.length;
    }

    public bool consumeGuidanceForTesting()
    {
        return _current >= 0 && appendQueuedGuidance(_sessions[_current]);
    }

    public bool completionNeedsVerificationForTesting() const
    {
        return _current >= 0 &&
            _sessions[_current].verificationStatus == "required";
    }

    public bool completionWouldContinueForTesting() const
    {
        return taskContinuesAfterDone(false);
    }

    public string incompleteChecklistGatePromptForTesting() const
    {
        return incompleteChecklistGatePrompt();
    }

    public int explorationCountForTesting() const
    {
        return _current < 0 ? 0 :
            readOnlyExplorationCount(_sessions[_current]);
    }

    public bool applyExplorationCheckpointForTesting()
    {
        if (_current < 0 || readOnlyExplorationCount(_sessions[_current]) <
            explorationCheckpointCalls ||
            hasExplorationCheckpoint(_sessions[_current])) return false;
        appendExplorationCheckpoint(_sessions[_current]);
        return true;
    }

    /// Discard the compatibility snapshot in memory and replay only the durable
    /// event journal, mirroring the startup fallback without touching disk.
    public void restoreJournalOnlyForTesting()
    {
        _sessions = _runtime is null ? null :
            projectAgentRuntimeEvents(_runtime.history());
        _current = _sessions.length > 0 ? cast(int) _sessions.length - 1 : -1;
        if (_current >= 0) rebuildMessageColumn();
    }

    /// Test-only: title of a session.
    public string sessionTitleForTesting(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return "";
        return _sessions[index].title;
    }

    /// Test-only: the session-array index shown at a visible list row
    /// (row 0 is the top of the list).
    public int visibleSessionIndexAtRowForTesting(int row) const
    {
        if (row < 0 || row >= cast(int) _sessionIndices.length) return -1;
        return _sessionIndices[row];
    }

    // -- project test accessors -------------------------------------------

    /// Test-only: project names in rail order (the sandbox is always first).
    public string[] projectNamesForTesting()
    {
        string[] names;
        foreach (project; _projectState.projects) names ~= project.name;
        return names;
    }

    public int projectCountForTesting() const
    {
        return cast(int) _projectState.projects.length;
    }

    public int activeProjectIndexForTesting()
    {
        return activeProjectIndex();
    }

    public string activeProjectNameForTesting()
    {
        const index = activeProjectIndex();
        return index >= 0
            ? _projectState.projects[cast(size_t) index].name : "";
    }

    public string activeProjectIdForTesting()
    {
        return activeProjectId();
    }

    public void removeProjectForTesting(int index)
    {
        removeProject(index);
    }

    public string activeProjectPathForTesting()
    {
        const index = activeProjectIndex();
        return index >= 0
            ? _projectState.projects[cast(size_t) index].path : "";
    }

    /// Test-only: the project id a session belongs to.
    public string sessionProjectForTesting(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return "";
        return _sessions[index].projectId;
    }

    /// Test-only: number of session rows currently visible for the active
    /// project (after the project and text filters).
    public int visibleSessionCountForTesting() const
    {
        return cast(int) _sessionIndices.length;
    }

    public void selectProjectForTesting(int index)
    {
        selectProject(index);
    }

    /// Test-only: the sessions/chat divider ratio.
    public double sessionsRatioForTesting()
    {
        return _sessionsSplit is null ? _projectState.sessionsRatio
            : _sessionsSplit.ratio();
    }

    /// Test-only: nudge the sessions/chat divider like a small drag.
    public void dragSessionsDividerForTesting(int deltaX)
    {
        if (_sessionsSplit is null) return;
        const width = maxInt(1, _sessionsSplit.bounds().width);
        _sessionsSplit.setRatio(_sessionsSplit.ratio() +
            cast(double) deltaX / width);
    }

    /// Test-only: true while the project rail is collapsed to icon width.
    public bool projectsRailCollapsedForTesting()
    {
        return _projectState.projectsCollapsed;
    }

    /// Test-only: the rail's current preferred width in logical pixels.
    public int projectsRailWidthForTesting()
    {
        return _projectsColumn is null
            ? 0 : _projectsColumn.layoutHints().preferredWidth;
    }

    /// Test-only: flip the project rail like clicking the toggle button.
    public void toggleProjectsRailForTesting()
    {
        toggleProjectsRail();
    }

    /// Test-only: true when the merged custom titlebar owns the top band.
    public bool hasCustomTitleBarForTesting()
    {
        return _titleBar !is null;
    }

    /// Test-only: the window-level title shown at the left of the titlebar.
    public string titleBarTitleForTesting()
    {
        return _titleBar is null ? "" : _titleBar.title().to!string;
    }

    /// Test-only: the width reserved for the left title region.
    public int titleBarTitleWidthForTesting()
    {
        return _titleBar is null ? 0 : _titleBar.titleRect().width;
    }

    public void openNewProjectDialogForTesting()
    {
        showNewProjectDialog();
    }

    /// Test-only: create a project directly (bypassing the dialog).
    public void addProjectForTesting(string name, string path)
    {
        Project project;
        project.id = newProjectId();
        project.name = name;
        project.path = path;
        ensureProjectDirectory(project);
        _projectState.projects ~= project;
        _projectState.activeId = project.id;
        saveProjects(_projectState);
        updateProjectRail();
        updateSessionsHeader();
        syncCurrentToActiveProject();
        updateSessionList(false);
    }

    /// Test-only: append a conversation (parallel role/content arrays) without
    /// network activity, then rebuild the message column.
    public void addConversationForTesting(const(string)[] roles,
        const(string)[] contents)
    {
        addConversationForTestingWithReasoning(roles, contents, null);
    }

    /// Test-only: like `addConversationForTesting` but with optional reasoning
    /// text per message (used to exercise the thinking block).
    public void addConversationForTestingWithReasoning(const(string)[] roles,
        const(string)[] contents, const(string)[] reasoning)
    {
        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        foreach (index; 0 .. roles.length)
        {
            ChatMessage message;
            message.role = roles[index];
            message.content = contents[index];
            if (reasoning !is null && index < reasoning.length)
                message.reasoning = reasoning[index];
            appendMessage(*session, message);
        }
        rebuildMessageColumn();
        // Production appends mark the conversation dirty, which also refreshes
        // the immediate recovery snapshot. Mirror that here, or a test that
        // saves then reloads sees a stale recovery copy of this chat (empty)
        // alongside the saved one and resolves `current` to the stale entry.
        markDirty();
    }

    /// Test-only: stamp a completed time on the message at physical `index` so
    /// its bubble reserves the meta footer exactly like a live session.
    public void setMessageTimeForTesting(int index, string time)
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        if (index < 0 || index >= cast(int) session.messages.length) return;
        session.messages[cast(size_t) index].time = time;
        rebuildMessageColumn();
    }

    /// Test-only: number of text shapes performed by message bubbles.
    public size_t bubbleShapeCountForTesting() const
    {
        return MessageBubble.shapeCount;
    }





    /// Test-only: number of messages in the visible (active-branch) path of the
    /// current session.
    public int messageCountForTesting()
    {
        if (_current < 0) return 0;
        return cast(int) activeMessagePath(_sessions[_current]).length;
    }

    /// Test-only: whether the empty-conversation intro overlay is showing.
    public bool introVisibleForTesting() const
    {
        return _introOverlay !is null && _introOverlay.visible();
    }

    /// Test-only: the intro overlay's fade progress (0..1).
    public double introFadeForTesting() const
    {
        return _introOverlay is null ? 0.0 : _introOverlay.fadeForTesting();
    }

    /// Test-only: the prompt suggestions shown on the empty state.
    public string[] introSuggestionsForTesting() const
    {
        return _introOverlay is null ? null
            : _introOverlay.suggestionsForTesting();
    }

    /// Test-only: bounds of the intro suggestion pill at `index`.
    public Rect introSuggestionBoundsForTesting(int index) const
    {
        return _introOverlay is null ? Rect.init
            : _introOverlay.suggestionBoundsForTesting(index);
    }

    /// Test-only: click an intro suggestion as a mouse press would.
    public bool clickIntroSuggestionForTesting(int index)
    {
        return _introOverlay !is null &&
            _introOverlay.clickSuggestionForTesting(index);
    }



    /// Test-only: total messages stored for the current session, including
    /// abandoned branch runs that are not on the visible path.
    public int totalMessageCountForTesting()
    {
        if (_current < 0) return 0;
        return cast(int) _sessions[_current].messages.length;
    }

    /// Test-only: number of sibling versions of the message at physical
    /// `index` (1 when it has no branch alternatives).
    public int messageVersionCountForTesting(int index)
    {
        if (_current < 0) return 0;
        auto session = &_sessions[_current];
        if (index < 0 || index >= cast(int) session.messages.length) return 0;
        return cast(int) siblingMessages(*session,
            cast(size_t) index).length;
    }

    /// Test-only: role of the message at `index`.
    public string messageRoleForTesting(int index)
    {
        if (_current < 0) return "";
        if (index < 0 || index >= cast(int) _sessions[_current].messages.length)
            return "";
        return _sessions[_current].messages[cast(size_t) index].role;
    }

    /// Test-only: content of the message at `index`.
    public string messageContentForTesting(int index)
    {
        if (_current < 0) return "";
        if (index < 0 || index >= cast(int) _sessions[_current].messages.length)
            return "";
        return _sessions[_current].messages[cast(size_t) index].content;
    }

    /// Test-only: route a failure through the reply-failure path exactly as the
    /// `error` event does (no network round-trip).
    public void failAssistantMessageForTesting(string error)
    {
        failAssistantMessage(error);
    }

    /// Test-only: invoke the action pill on the bubble at `index` exactly as a
    /// mouse click would, exercising the real delegate captured for that
    /// bubble (regression: foreach closures must not all target the last
    /// message).
    public bool invokeBubbleActionForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.invokeActionForTesting();
    }

    /// Test-only: the message bubble at child `index` (null when out of range).
    private MessageBubble messageBubbleForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return null;
        return cast(MessageBubble) children[cast(size_t) index];
    }

    /// Test-only: open the right-click context menu for the message at
    /// `index`, exactly as a right-click on that bubble would.
    public void openMessageContextMenuForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        showMessageContextMenu(bubble is null ? index : bubble.messageIndex(),
            Point(10, 10), bubble);
    }

    /// Test-only: select all text in the message bubble at `index`.
    public bool selectAllMessageTextForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        if (bubble is null) return false;
        bubble.selectAll();
        return true;
    }

    /// Test-only: the selected text of the message bubble at `index`.
    public string selectedMessageTextForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? "" : bubble.selectedText();
    }

    /// Test-only: the text the message bubble at `index` last copied via Ctrl+C.
    public string copiedMessageTextForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? "" : bubble.lastClipboardTextForTesting();
    }

    /// Test-only: the global origin of the first selectable run in the bubble.
    public Point messageTextOriginForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? Point(-1, -1)
            : bubble.textOriginForTesting();
    }

    /// Test-only: the global far edge (right, middle) of the first run.
    public Point messageTextEndForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? Point(-1, -1) : bubble.textEndForTesting();
    }

    /// Test-only: payload of the most recent message Copy menu action.
    public string lastCopiedMessageTextForTesting()
    {
        return _lastMessageCopy;
    }

    /// Test-only: feed a usage event as the client would while streaming.
    public void feedUsageForTesting(int prompt, int completion, int total)
    {
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.usage;
        event.promptTokens = prompt;
        event.completionTokens = completion;
        event.totalTokens = total;
        _liveTotalTokens = total;
        if (completion > 0) _liveOutputTokens = completion;
        updateLiveTokenRate();
        if (_streamBubble !is null)
        {
            _streamBubble.setLiveTokens(_liveOutputTokens, true);
            _streamBubble.setTokenRate(_liveTokenRateTenths);
            if (!_streamBubble.hasThinkingForTesting())
                _streamBubble.setUsageText(liveTokenStatsText());
        }
    }

    /// Test-only: whether the bubble at `index` shows token usage text.
    public bool bubbleHasUsageForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.usageTextForTesting().length > 0;
    }

    /// Test-only: whether the bubble at `index` is hidden (zero-size slot).
    public bool bubbleHiddenForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.hiddenForTesting();
    }

    /// Test-only: the current laid-out height of the bubble at `index`.
    public int bubbleHeightForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return 0;
        return children[cast(size_t) index].bounds().height;
    }

    /// Test-only: the message-column-relative bounds of the bubble at `index`
    /// (hidden bubbles keep a slot but are excluded from layout). Returned
    /// relative to the column rather than the window so nesting (which shifts a
    /// child's absolute origin) cannot skew row-pitch measurements.
    public Rect bubbleBoundsForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return Rect.init;
        const child = children[cast(size_t) index];
        const origin = child.globalOrigin();
        const base = _messageColumn.globalOrigin();
        return Rect(origin.x - base.x, origin.y - base.y,
            child.bounds().width, child.bounds().height);
    }

    /// Test-only: whether the bubble at `index` takes part in layout/painting.
    public bool bubbleVisibleForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return false;
        return children[cast(size_t) index].visible();
    }

    /// Test-only: current input text.
    public string inputTextForTesting()
    {
        return _input.textUtf8();
    }

    /// Test-only: edit-and-resend the user message at `index` in the current
    /// session.
    public void editAndResendForTesting(int index)
    {
        editAndResend(_current, index);
    }

    /// Test-only: the pending edit target (-1 when no prompt is being edited).
    public int pendingEditIndexForTesting()
    {
        return _editMessageIndex;
    }

    /// Test-only: cancel a pending edit without submitting it.
    public void cancelPendingEditForTesting()
    {
        _editMessageIndex = -1;
    }

    /// Test-only: replace the composer text directly (bypassing keystrokes).
    public void setInputForTesting(string text)
    {
        _input.setText(text);
    }

    public void sendForTesting()
    {
        sendMessage();
    }

    public void clickSendButtonForTesting()
    {
        if (_sendButton.onClick !is null) _sendButton.onClick();
    }

    public string sendButtonTextForTesting() const
    {
        return _sendButton is null ? "" : to!string(_sendButton.text());
    }

    public bool turnBusyForTesting()
    {
        return turnIsBusy();
    }

    public void stopTurnClockForTesting()
    {
        freezeTurnTiming();
    }

    /// Test-only: apply a pending edit and append the edited prompt as a sibling
    /// branch without starting a network request. Returns the new physical
    /// message index, or -1 when there is nothing to edit.
    public int commitEditForTesting(string text)
    {
        if (_current < 0 || _editMessageIndex < 0) return -1;
        auto session = &_sessions[_current];
        if (_editMessageIndex >= cast(int) session.messages.length) return -1;
        const target = session.messages[cast(size_t) _editMessageIndex];
        if (target.role != "user") return -1;
        session.activeLeafId = target.parentId;
        ChatMessage message;
        message.role = "user";
        message.content = text;
        message.time = currentTimestamp();
        appendMessage(*session, message);
        _editMessageIndex = -1;
        rebuildMessageColumn();
        updateSessionList(false);
        markDirty();
        return cast(int) session.messages.length - 1;
    }

    /// Test-only: force the visible branch to a sibling version of the message
    /// at physical `index` (-1 previous / +1 next).
    public void switchMessageBranchForTesting(int index, int direction)
    {
        switchMessageBranch(_current, index, direction);
    }

    /// Test-only: the `n/m` version label on the bubble at child `index`.
    public string bubbleVersionForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? "" : bubble.versionTextForTesting();
    }

    /// Test-only: bounds of the version nav on the bubble at child `index`.
    public Rect bubbleVersionNavBoundsForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? Rect.init : bubble.versionNavBoundsForTesting();
    }

    /// Test-only: bounds of the action pill on the bubble at child `index`.
    public Rect bubbleActionBoundsForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? Rect.init : bubble.actionBoundsForTesting();
    }

    public Rect bubbleSecondaryActionBoundsForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? Rect.init :
            bubble.secondaryActionBoundsForTesting();
    }

    /// Test-only: click the previous-version arrow on the bubble at child
    /// `index`, exactly as a mouse click would.
    public bool invokeBubbleVersionPrevForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble !is null && bubble.invokeVersionPrevForTesting();
    }

    /// Test-only: click the next-version arrow on the bubble at child `index`.
    public bool invokeBubbleVersionNextForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble !is null && bubble.invokeVersionNextForTesting();
    }

    /// Test-only: true when the last assistant reply was removed in
    /// preparation for a regenerate.
    public bool prepareRegenerateForTesting()
    {
        if (_current < 0) return false;
        const path = activeMessagePath(_sessions[_current]);
        if (path.length == 0) return false;
        return prepareRegenerate(_current, cast(int) path[$ - 1]);
    }

    /// Test-only: append the same state-aware hidden turn as the Continue pill
    /// without opening a network request.
    public bool prepareContinueForTesting()
    {
        if (_current < 0) return false;
        const path = activeMessagePath(_sessions[_current]);
        if (path.length == 0) return false;
        return prepareContinue(_current, cast(int) path[$ - 1]);
    }

    /// Test-only: action-pill label on the last bubble ("" when none).
    public string lastBubbleActionForTesting()
    {
        const children = messageColumnVisuals();
        if (children.length == 0) return "";
        auto bubble = cast(MessageBubble) children[$ - 1];
        return bubble is null ? "" : bubble.actionLabelForTesting();
    }

    public string lastBubbleSecondaryActionForTesting()
    {
        const children = messageColumnVisuals();
        if (children.length == 0) return "";
        auto bubble = cast(MessageBubble) children[$ - 1];
        return bubble is null ? "" : bubble.secondaryActionLabelForTesting();
    }

    /// Test-only: action-pill label on the bubble at `index`.
    public string bubbleActionForTesting(int index)
    {
        const children = messageColumnVisuals();
        if (index < 0 || index >= cast(int) children.length) return "";
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble is null ? "" : bubble.actionLabelForTesting();
    }

    /// Test-only: record API-reported usage on the current session's last
    /// message and refresh the toolbar context meter (mirrors the done/usage
    /// events without any network activity).
    public void recordContextUsageForTesting(int prompt, int completion, int total)
    {
        if (_current >= 0)
        {
            auto session = &_sessions[_current];
            if (prompt > 0)
            {
                _reportedContextTokens[session.id] = prompt;
                _reportedCompletionTokens[session.id] = completion;
                _preferEstimatedContext[session.id] = false;
            }
            const path = activeMessagePath(*session);
            if (path.length > 0)
            {
                auto message = &session.messages[path[$ - 1]];
                message.promptTokens = prompt;
                message.completionTokens = completion;
                message.totalTokens = total;
            }
        }
        refreshUsageBadge();
    }

    public void recordEstimatedContextUsageForTesting(int total)
    {
        if (_current < 0) return;
        _estimatedContextTokens[_sessions[_current].id] = total;
        _preferEstimatedContext[_sessions[_current].id] = true;
        refreshUsageBadge();
    }

    /// Test-only: the text currently painted on the context badge.
    public string contextUsageTextForTesting()
    {
        return _usageBadge is null ? "" : _usageBadge.labelForTesting();
    }

    /// Test-only: the context tooltip text ("" when closed).
    public string contextTooltipTextForTesting()
    {
        return isContextTooltipOpenForTesting() && _usageTooltip !is null
            ? _usageTooltip.textForTesting() : "";
    }

    /// Test-only: whether the hover context tooltip is currently open.
    public bool isContextTooltipOpenForTesting()
    {
        return _usageTooltipOpen && _usageTooltip !is null &&
            _usageTooltip.parent() !is null;
    }

    /// Test-only: the context tooltip's global bounds (Rect.init when closed).
    public Rect contextTooltipBoundsForTesting()
    {
        if (_usageTooltip is null || _usageTooltip.parent() is null)
            return Rect.init;
        const origin = _usageTooltip.localToGlobal(Point(0, 0));
        return Rect(origin.x, origin.y, _usageTooltip.bounds().width,
            _usageTooltip.bounds().height);
    }

    public bool isThinkingTooltipOpenForTesting()
    {
        return _thinkingTooltipOpen && _thinkingTooltip !is null &&
            _thinkingTooltip.parent() !is null;
    }

    public Rect thinkingTooltipBoundsForTesting()
    {
        if (_thinkingTooltip is null || _thinkingTooltip.parent() is null)
            return Rect.init;
        const origin = _thinkingTooltip.localToGlobal(Point(0, 0));
        return Rect(origin.x, origin.y, _thinkingTooltip.bounds().width,
            _thinkingTooltip.bounds().height);
    }

    public string thinkingTooltipTextForTesting()
    {
        return isThinkingTooltipOpenForTesting() && _thinkingTooltip !is null
            ? _thinkingTooltip.textForTesting() : "";
    }

    /// Test-only: the context badge's global bounds.
    public Rect contextBadgeBoundsForTesting()
    {
        if (_usageBadge is null) return Rect.init;
        const origin = _usageBadge.localToGlobal(Point(0, 0));
        return Rect(origin.x, origin.y, _usageBadge.bounds().width,
            _usageBadge.bounds().height);
    }

    /// Test-only: enable tools and set the workspace directory they run in.
    public void enableToolsForTesting(string workspace)
    {
        _settings.toolsEnabled = true;
        _settings.workspace = workspace;
        if (auto project = activeProject())
        {
            project.path = workspace;
            ensureProjectDirectory(*project);
            saveProjects(_projectState);
        }
        if (_toolsBox !is null) _toolsBox.setChecked(true, false);
    }

    /// Test-only: start a fresh conversation (used by tool-loop tests).
    public void newChatForTesting()
    {
        newChat();
    }

    /// Test-only: persist the current sessions to disk immediately.
    public void persistForTesting()
    {
        persistState();
    }

    /// Test-only: reload sessions.json exactly as app startup does, so a test
    /// can prove branch ids / active leaf / version history survive a save.
    public void reloadSessionsForTesting()
    {
        restoreSessions();
    }

    /// Test-only: labels of the in-progress tool rows currently in the column
    /// (one per running Edit / Write / Delete / Shell call), recursing into
    /// their turn's action group where the rows now live.
    public string[] liveToolRowTextsForTesting()
    {
        string[] labels;
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto row = cast(LiveToolRow) part)
                        labels ~= row.textForTesting();
                continue;
            }
            if (auto row = cast(LiveToolRow) child)
                labels ~= row.textForTesting();
        }
        return labels;
    }

    /// Test-only: provisional `+N -M` counters of the in-progress tool rows
    /// ("" when a row has no diff yet), in column order.
    public string[] liveToolRowDiffTextsForTesting()
    {
        string[] labels;
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto row = cast(LiveToolRow) part)
                        labels ~= liveDiffText(row);
                continue;
            }
            if (auto row = cast(LiveToolRow) child)
                labels ~= liveDiffText(row);
        }
        return labels;
    }

    private static string liveDiffText(LiveToolRow row)
    {
        return row.diffAdditionsForTesting() > 0 ||
            row.diffDeletionsForTesting() > 0
            ? "+" ~ to!string(row.diffAdditionsForTesting()) ~
                " -" ~ to!string(row.diffDeletionsForTesting())
            : "";
    }

    /// Test-only: aggregate duration of the in-flight rows, or -1 when there is
    /// no live row. Used to prove the running timer reaches the group header.
    public long totalLiveToolElapsedMsForTesting()
    {
        long total = -1;
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto row = cast(LiveToolRow) part)
                    {
                        if (total < 0) total = 0;
                        total += row.toolElapsedMsForTesting();
                    }
                continue;
            }
            if (auto row = cast(LiveToolRow) child)
            {
                if (total < 0) total = 0;
                total += row.toolElapsedMsForTesting();
            }
        }
        return total;
    }

    /// Test-only: freeze the elapsed value shown by the in-flight tool rows so
    /// the running timer and the group aggregate can be asserted without
    /// sleeping (0 restores the live clock).
    public void setLiveToolElapsedForTesting(long ms)
    {
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto row = cast(LiveToolRow) part)
                        row.setElapsed(ms);
                continue;
            }
            if (auto row = cast(LiveToolRow) child)
                row.setElapsed(ms);
        }
    }

    /// Test-only: streamed body previews of the in-flight tool rows, in column
    /// order (proves the user can see what a tool is producing while it runs).
    public string[] liveToolRowPreviewsForTesting()
    {
        string[] previews;
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto row = cast(LiveToolRow) part)
                        previews ~= row.previewForTesting();
                continue;
            }
            if (auto row = cast(LiveToolRow) child)
                previews ~= row.previewForTesting();
        }
        return previews;
    }

    /// Test-only: the Codex-style header of every action group in the column, in
    /// order (e.g. "Edited a file, ran 2 commands"), so a test can prove the
    /// summary and the live/complete tense.
    public string[] toolGroupHeaderTextsForTesting()
    {
        string[] headers;
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                headers ~= group.headerTextForTesting();
        return headers;
    }

    /// Test-only: the phase text currently shown in the live activity row
    /// ("" when the row is not in the transcript). Drives the "what is going
    /// on" indicator so a smoke test can prove it appears, updates and clears.
    public void setActivityForTesting(string label)
    {
        setActivity(label);
    }

    /// Test-only: clear the live activity row exactly as reply completion does.
    public void clearActivityForTesting()
    {
        clearActivity();
    }

    /// Test-only: whether the live activity row is part of the transcript.
    public bool activityVisibleForTesting()
    {
        return _activityRow !is null && _activityRow.parent() !is null;
    }

    /// Test-only: the live activity row's phase text ("" when absent).
    public string activityTextForTesting()
    {
        return _activityRow is null ? "" : _activityRow.textForTesting();
    }

    /// Test-only: the live activity row's rendered text including the elapsed
    /// suffix ("…  3s"), so a smoke test can prove the clock advances.
    public string activityDisplayTextForTesting()
    {
        return _activityRow is null ? "" : _activityRow.displayTextForTesting();
    }

    /// Test-only: start a live assistant turn exactly as a `chatBegin` event
    /// does, so a smoke test can drive the streaming phases (reasoning, then
    /// answer) without a real network round-trip.
    public void beginStreamForTesting()
    {
        beginAssistantMessage();
    }

    /// Test-only: start the turn clock exactly as a user-initiated request does,
    /// so a smoke test can prove the final-answer separator times the turn
    /// without a real network round-trip.
    public void startTurnClockForTesting()
    {
        _activeRequestSession = _current;
        beginTurnTiming(_current);
        setTurnInFlight(true);
    }

    /// Test-only: deliver a streamed reasoning (chain-of-thought) fragment.
    public void streamReasoningForTesting(string text)
    {
        streamDeltaInSessionForTesting(turnOwnerSessionForTesting(), text,
            true);
    }

    /// Test-only: deliver a streamed answer fragment.
    public void streamContentForTesting(string text)
    {
        streamDeltaInSessionForTesting(turnOwnerSessionForTesting(), text,
            false);
    }

    public void streamContentInSessionForTesting(int sessionIndex, string text)
    {
        streamDeltaInSessionForTesting(sessionIndex, text, false);
    }

    /// Test-only: queue a real client event so onTick must drain and route two
    /// conversation queues, rather than calling the stream handler directly.
    public void queueContentInSessionForTesting(int sessionIndex, string text)
    {
        auto rt = runtimeForSession(sessionIndex);
        if (rt is null) return;
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.delta;
        event.text = text;
        rt.client.pushLocalEvent(event);
    }

    private void streamDeltaInSessionForTesting(int sessionIndex, string text,
        bool reasoning)
    {
        const selected = _current;
        if (sessionIndex >= 0) loadRuntime(sessionIndex);
        appendStreamDelta(text, reasoning);
        saveLoadedRuntime();
        if (selected >= 0) loadRuntime(selected);
    }

    /// Test-only: finish the live assistant turn exactly as a `done` event does
    /// (clears the phase row, drops the streaming flag).
    public void finishStreamForTesting()
    {
        finishStreamInSessionForTesting(turnOwnerSessionForTesting());
    }

    public void finishStreamInSessionForTesting(int sessionIndex)
    {
        const selected = _current;
        if (sessionIndex >= 0) loadRuntime(sessionIndex);
        finishAssistantMessage(false);
        saveLoadedRuntime();
        if (selected >= 0) loadRuntime(selected);
    }

    /// Test-only: the live output-token count of the streaming reply (0 when
    /// nothing is streaming).
    public long streamLiveTokensForTesting()
    {
        return _streamBubble is null ? 0 : _streamBubble.liveTokensForTesting();
    }

    /// Test-only: the exact Thinking header line of the streaming reply.
    public string streamThinkingHeaderTextForTesting()
    {
        return _streamBubble is null ? ""
            : _streamBubble.thinkingHeaderTextForTesting();
    }

    /// Test-only: the live/final token count on the flattened bubble at `index`.
    public long bubbleLiveTokensForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? 0 : bubble.liveTokensForTesting();
    }

    /// Test-only: the Thinking header line of the flattened bubble at `index`.
    public string bubbleThinkingHeaderTextForTesting(int index)
    {
        auto bubble = messageBubbleForTesting(index);
        return bubble is null ? "" : bubble.thinkingHeaderTextForTesting();
    }

    /// Test-only: the most recent assistant reply bubble in the column (null
    /// when there is none).
    private MessageBubble lastAssistantBubbleForTesting()
    {
        MessageBubble found;
        foreach (child; messageColumnVisuals())
            if (auto bubble = cast(MessageBubble) child)
                if (bubble.roleForTesting() == "assistant")
                    found = bubble;
        return found;
    }

    /// Test-only: the live/final token count on the most recent assistant reply
    /// in the column (0 when there is none).
    public long lastAssistantLiveTokensForTesting()
    {
        auto bubble = lastAssistantBubbleForTesting();
        return bubble is null ? 0 : bubble.liveTokensForTesting();
    }

    /// Test-only: the Thinking header line of the most recent assistant reply.
    public string lastAssistantThinkingHeaderTextForTesting()
    {
        auto bubble = lastAssistantBubbleForTesting();
        return bubble is null ? "" : bubble.thinkingHeaderTextForTesting();
    }

    /// Test-only: visual index of the live activity row in the flattened
    /// transcript (-1 when absent). Proves the phase row renders AFTER the live
    /// reply it describes, never above it.
    public int activityRowVisualIndexForTesting()
    {
        if (_activityRow is null) return -1;
        foreach (i, widget; messageColumnVisuals())
            if (widget is _activityRow) return cast(int) i;
        return -1;
    }

    /// Test-only: number of flattened transcript visuals (nested turn
    /// containers expanded), matching `messageColumnVisuals` order.
    public int messageColumnVisualCountForTesting()
    {
        return cast(int) messageColumnVisuals().length;
    }

    /// Test-only: messages retained in the graph but not materialized in the
    /// current transcript page.
    public size_t hiddenHistoryCountForTesting()
    {
        if (_current < 0) return 0;
        const count = activeMessagePath(_sessions[_current]).length;
        return count > _visibleMessageLimit ? count - _visibleMessageLimit : 0;
    }

    public void loadOlderHistoryForTesting()
    {
        _visibleMessageLimit += messageHistoryPageSize;
        rebuildMessageColumn();
    }

    /// Test-only: settled turn-boundary labels in transcript order.
    public string[] turnCompletionTextsForTesting()
    {
        string[] texts;
        foreach (child; messageColumnVisuals())
            if (auto separator = cast(TurnCompletionSeparator) child)
                texts ~= separator.textForTesting();
        return texts;
    }

    /// Test-only: one human-readable line per flattened transcript visual (id,
    /// role, hidden flag, whether it shows a Thinking header, content length,
    /// live/activity text, visibility and laid-out height), so a test can prove
    /// exactly what the column shows at each streaming phase.
    public string[] columnDebugForTesting()
    {
        string[] lines;
        foreach (i, child; messageColumnVisuals())
        {
            string desc = to!string(i) ~ ":";
            if (auto bubble = cast(MessageBubble) child)
            {
                desc ~= "bubble role=" ~ bubble.roleForTesting() ~
                    " hidden=" ~ (bubble.hiddenForTesting() ? "1" : "0") ~
                    " think=" ~ (bubble.hasThinkingForTesting() ? "1" : "0") ~
                    " content=" ~ to!string(bubble.contentLengthForTesting());
                if (bubble.liveTokensForTesting() > 0)
                    desc ~= " tokens=" ~
                        to!string(bubble.liveTokensForTesting());
                if (bubble.toolNameForTesting().length > 0)
                    desc ~= " tool=" ~ bubble.toolNameForTesting();
                if (bubble.contentLengthForTesting() > 0)
                    desc ~= " txt=\"" ~
                        bubble.contentSnippetForTesting() ~ "\"";
            }
            else if (auto group = cast(ToolGroupBubble) child)
                desc ~= "GROUP " ~ group.headerTextForTesting() ~
                    " parts=" ~ to!string(group.partCount());
            else if (auto separator = cast(TurnCompletionSeparator) child)
                desc ~= "SEPARATOR " ~ separator.textForTesting();
            else if (auto row = cast(LiveToolRow) child)
                desc ~= "LIVEROW " ~ row.textForTesting();
            else if (auto act = cast(ActivityRow) child)
                desc ~= "ACTROW " ~ act.textForTesting();
            else
                desc ~= child.id();
            desc ~= " vis=" ~ (child.visible() ? "1" : "0") ~
                " h=" ~ to!string(child.bounds().height);
            lines ~= desc;
        }
        return lines;
    }

    /// Test-only: inject a tool-call progress event (the model is still
    /// streaming the arguments), exactly as the client would deliver it.
    public void injectToolProgressForTesting(const(OpenCodeToolCall)[] calls)
    {
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.toolCallDelta;
        event.toolCalls = calls.dup;
        handleToolCallProgress(event);
    }

    /// Test-only: append a completed `tool` message with its diff metadata,
    /// simulating a restored/executed result without running a real tool.
    public void appendToolMessageForTesting(string toolName, string content,
        string args, int additions, int deletions, string diff,
        long elapsedMs = 0)
    {
        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        ChatMessage message;
        message.role = "tool";
        message.toolName = toolName;
        message.content = content;
        message.toolArgs = args;
        message.diffAdditions = additions;
        message.diffDeletions = deletions;
        message.toolDiff = diff;
        message.toolElapsedMs = elapsedMs;
        message.time = currentTimestamp();
        appendMessage(*session, message);
        rebuildMessageColumn();
    }

    /// Test-only: append an assistant turn that only requested tools (reasoning
    /// + `toolCalls`, no prose), exactly as a tool-loop round is persisted.
    public void appendToolRequestTurnForTesting(string reasoning, string callId,
        string name, string args)
    {
        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        ChatMessage message;
        message.role = "assistant";
        message.reasoning = reasoning;
        message.toolCalls = [OpenCodeToolCall(callId, name, args)];
        message.time = currentTimestamp();
        appendMessage(*session, message);
        rebuildMessageColumn();
    }

    /// Test-only: the number of visible reasoning headers in the transcript
    /// (one per assistant turn that reasoned — Codex-style per-turn reasoning).
    public int thinkingHeaderCountForTesting()
    {
        int count;
        foreach (child; messageColumnVisuals())
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.hasThinkingForTesting() && !bubble.hiddenForTesting())
                ++count;
        }
        return count;
    }

    /// Test-only: the text of the first visible "Thinking" block.
    public string thinkingTextForTesting()
    {
        auto all = thinkingTextsForTesting();
        return all.length > 0 ? all[0] : "";
    }

    /// Test-only: the text of every visible "Thinking" block in transcript
    /// order, so a test can prove each round keeps its own reasoning attached to
    /// its turn and that a rebuild does not reorder or merge them.
    public string[] thinkingTextsForTesting()
    {
        string[] texts;
        foreach (child; messageColumnVisuals())
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.hasThinkingForTesting() && !bubble.hiddenForTesting())
                texts ~= bubble.thinkingTextForTesting();
        }
        return texts;
    }

    /// Test-only: the sanitized outgoing message list for the current session
    /// (the exact history `startChatRequest` would send, minus the system
    /// prompt and tool definitions).
    public ChatRequestMessage[] requestMessagesForTesting()
    {
        if (_current < 0) return null;
        return buildRequestMessages(_sessions[_current]);
    }

    /// Test-only: the compacted outgoing list for the current session at the
    /// given context limit (what `startChatRequest` would send).
    public ChatRequestMessage[] compactedRequestMessagesForTesting(
        int contextLimit)
    {
        if (_current < 0) return null;
        return compactRequestMessages(buildRequestMessages(_sessions[_current]),
            contextLimit);
    }

    /// Test-only: append an assistant message carrying `tool_calls` and no
    /// reply, simulating a transcript persisted mid-tool (the HTTP 400 case).
    public void appendDanglingToolCallsForTesting(string callId)
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        ChatMessage message;
        message.role = "assistant";
        message.toolCalls = [OpenCodeToolCall(callId, "read", "{}")];
        appendMessage(*session, message);
        rebuildMessageColumn();
    }

    /// Test-only: append a `tool` reply for `callId` as the active leaf's child.
    public void appendToolReplyForTesting(string callId, string content)
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        ChatMessage message;
        message.role = "tool";
        message.content = content;
        message.toolCallId = callId;
        appendMessage(*session, message);
        rebuildMessageColumn();
    }

    /// Test-only: open the settings dialog and return the legacy checkbox, or
    /// null when absent.
    public CheckBox legacyToolsCheckboxForTesting()
    {
        showSettingsDialog();
        return cast(CheckBox) findWidgetById(this, "oc-legacy");
    }

    /// Test-only: open the settings dialog and return the legacy tooltip text
    /// ("" when the tooltip anchor is missing).
    public string legacyToolsTooltipForTesting()
    {
        showSettingsDialog();
        return _legacyTooltipAnchor !is null ? _legacyTooltipAnchor.text() : "";
    }

    /// Test-only: open the settings dialog and return the "Worked-for
    /// separator" checkbox, or null when absent.
    public CheckBox workedForCheckboxForTesting()
    {
        showSettingsDialog();
        return cast(CheckBox) findWidgetById(this, "oc-workedfor");
    }

    /// Test-only: toggle the Worked-for separator as the dialog checkbox does,
    /// without opening the dialog.
    public void setShowWorkedForForTesting(bool value)
    {
        _settings.showWorkedFor = value;
        if (_current >= 0) rebuildMessageColumn();
    }

    /// Test-only: open Settings and report whether the "System prompt" button
    /// that opens the prompt viewer is present.
    public bool systemPromptButtonPresentForTesting()
    {
        showSettingsDialog();
        return findWidgetById(this, "oc-system-prompt-open") !is null;
    }

    /// Test-only: open Settings and report whether the "Chats folder" button
    /// that reveals the chats directory is present.
    public bool chatsFolderButtonPresentForTesting()
    {
        showSettingsDialog();
        return findWidgetById(this, "oc-chats-folder-open") !is null;
    }

    /// Test-only: open the system-prompt viewer and return the exact text it
    /// shows (the system message that would be sent on the next request).
    public string systemPromptViewerTextForTesting()
    {
        showSystemPromptDialog();
        auto viewer = cast(TextArea) findWidgetById(this, "oc-system-prompt");
        return viewer is null ? "" : viewer.textUtf8();
    }

    /// Test-only: dismiss whatever popup is open.
    public void dismissPopupForTesting()
    {
        dismissPopup();
    }

    /// Test-only: the provider preset names offered by the Settings dialog.
    public string[] providerPresetNamesForTesting()
    {
        string[] names;
        foreach (preset; providerPresets) names ~= preset.name;
        return names;
    }

    /// Test-only: open Settings and report whether the provider picker exists.
    public bool providerSelectorPresentForTesting()
    {
        showSettingsDialog();
        return findWidgetById(this, "oc-provider") !is null;
    }

    /// Test-only: open Settings, apply the provider preset at `index`, and
    /// return the base URL and model it filled in, as "baseUrl\nmodel".
    public string selectProviderForTesting(int index)
    {
        showSettingsDialog();
        applyProviderPreset(index);
        const baseUrl = _settingsBaseField !is null
            ? _settingsBaseField.textUtf8() : "";
        const model = _settingsModelField !is null
            ? _settingsModelField.textUtf8() : "";
        return baseUrl ~ "\n" ~ model;
    }

    /// Test-only: open Settings, open the Provider dropdown, and return the
    /// number of items in its context menu (negative = a failure stage).
    public int providerMenuCountForTesting()
    {
        showSettingsDialog();
        if (_settingsProviderButton is null) return -1;
        _settingsProviderButton.onClick();
        auto root = popupRoot(this);
        if (root is null) return -2;
        foreach (child; root.children())
            if (auto menu = cast(ContextMenu) child)
                return cast(int) menu.items().length;
        return -3;
    }

    /// Test-only: open Settings, open the real Provider dropdown, invoke the
    /// item at `index` through its context-menu action, and return the
    /// resulting "baseUrl\nmodel".
    public string chooseProviderFromMenuForTesting(int index)
    {
        showSettingsDialog();
        if (_settingsProviderButton is null) return "";
        _settingsProviderButton.onClick();
        auto root = popupRoot(this);
        if (root is null) return "";
        ContextMenu menu;
        foreach (child; root.children())
            if (auto candidate = cast(ContextMenu) child) menu = candidate;
        if (menu is null) return "";
        const items = menu.items();
        if (index < 0 || index >= cast(int) items.length) return "";
        if (items[cast(size_t) index].action !is null)
            items[cast(size_t) index].action();
        // Read the fields BEFORE dismissing anything: dismissContextMenus calls
        // dismissTransientPopups, which also closes the Settings PopupOverlay
        // and nulls these members.
        const baseUrl = _settingsBaseField !is null
            ? _settingsBaseField.textUtf8() : "";
        const model = _settingsModelField !is null
            ? _settingsModelField.textUtf8() : "";
        dismissContextMenus(this);
        return baseUrl ~ "\n" ~ model;
    }

    /// Test-only: depth-first search for a widget by id.
    private static Widget findWidgetById(Widget widget, string requestedId)
    {
        if (widget is null) return null;
        if (widget.id() == requestedId) return widget;
        foreach (child; widget.children())
        {
            auto found = findWidgetById(child, requestedId);
            if (found !is null) return found;
        }
        return null;
    }

    /// Test-only: pause the tool loop after results arrive so the headless
    /// test can inspect the appended tool messages without a network request.
    public void pauseToolContinuationForTesting()
    {
        _toolContinuationPaused = true;
    }

    /// Test-only: inject a completed tool call (assistant message with the
    /// tool request) into the loop exactly as the client would deliver it.
    public void injectToolCallsForTesting(const(OpenCodeToolCall)[] calls)
    {
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.toolCalls;
        event.toolCalls = calls.dup;
        event.text = "I'll check that.";
        handleToolCalls(event);
    }

    /// Test-only: consecutive repeat count used to trigger progress guidance.
    public int toolRepeatCountForTesting()
    {
        return _lastToolRepeatCount;
    }

    /// Test-only: simulate a finished tool call with a given outcome, driving
    /// the same path as a real toolResult event. Seeds a one-call pending
    /// batch when none is open so a test can feed repeated failures.
    public void injectToolResultForTesting(string name, string output,
        bool failed, string arguments = "{}", int additions = 0,
        int deletions = 0, string diff = "")
    {
        if (_pendingToolCalls.length == 0)
        {
            OpenCodeToolCall call;
            call.id = "call_inject";
            call.name = name;
            call.arguments = arguments;
            _pendingToolCalls = [call];
            _liveToolCalls = [call];
            _pendingToolResults = 1;
        }
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.toolResult;
        event.toolName = name;
        event.toolCallId = _pendingToolCalls[0].id;
        event.text = output;
        event.toolFailed = failed;
        event.diffAdditions = additions;
        event.diffDeletions = deletions;
        event.diffText = diff;
        applyToolResult(event);
    }

    /// Test-only: a network request is in flight.
    public bool clientBusyForTesting()
    {
        return _client !is null && _client.busy();
    }

    /// Long-horizon turns are ended only by the user, a provider/network error,
    /// or normal model completion—not by a local inactivity timer or round cap.
    public bool hasAutomaticTurnTimeoutForTesting() const { return false; }
    public int toolRoundLimitForTesting() const { return 0; }

    /// Test-only: tool calls injected but not yet reported back.
    public int pendingToolResultsForTesting() const
    {
        return _pendingToolResults;
    }

    /// Test-only: tool calls still marked "running" on the live row.
    public int liveToolCallCountForTesting() const
    {
        return cast(int) _liveToolCalls.length;
    }

    /// Test-only: number of `user` role messages (used to detect the injected
    /// hidden progress-guidance message).
    public int userMessageCountForTesting()
    {
        if (_current < 0) return 0;
        auto session = &_sessions[_current];
        int count;
        foreach (index; activeMessagePath(*session))
            if (session.messages[index].role == "user") ++count;
        return count;
    }

    /// Test-only: content of the last `user` role message on the active path
    /// (used to inspect the injected recovery instruction).
    public string lastUserMessageForTesting()
    {
        if (_current < 0) return "";
        auto session = &_sessions[_current];
        foreach_reverse (index; activeMessagePath(*session))
            if (session.messages[index].role == "user")
                return session.messages[index].content;
        return "";
    }

    /// Test-only: number of `tool` role messages in the current session.
    public int toolMessageCountForTesting()
    {
        if (_current < 0) return 0;
        auto session = &_sessions[_current];
        int count;
        foreach (index; activeMessagePath(*session))
            if (session.messages[index].role == "tool") ++count;
        return count;
    }

    /// Test-only: content of the last `tool` role message ("" when none).
    public string lastToolResultForTesting()
    {
        if (_current < 0) return "";
        auto session = &_sessions[_current];
        foreach_reverse (slot, index; activeMessagePath(*session))
        {
            const message = session.messages[index];
            if (message.role == "tool") return message.content;
        }
        return "";
    }

    /// Test-only: content of the `tool` role message at index `n` ("" when
    /// there is no such tool message).
    public string toolResultForTesting(int n)
    {
        if (_current < 0) return "";
        auto session = &_sessions[_current];
        int seen;
        foreach (index; activeMessagePath(*session))
        {
            const message = session.messages[index];
            if (message.role != "tool") continue;
            if (seen == n) return message.content;
            ++seen;
        }
        return "";
    }

    /// Test-only: every `tool` result bubble in visual order, recursing into
    /// context groups so a test can address a tool part by ordinal even after
    /// folding.
    private MessageBubble[] toolBubblesForTesting()
    {
        MessageBubble[] result;
        foreach (child; messageColumnVisuals())
        {
            if (auto group = cast(ToolGroupBubble) child)
            {
                foreach (part; group._parts)
                    if (auto partBubble = cast(MessageBubble) part)
                        result ~= partBubble;
                continue;
            }
            if (auto bubble = cast(MessageBubble) child)
                if (bubble.roleForTesting() == "tool")
                    result ~= bubble;
        }
        return result;
    }

    /// Test-only: whether the first `tool` result bubble is currently
    /// collapsed (tool outputs start collapsed by default).
    public bool firstToolBubbleCollapsedForTesting()
    {
        auto bubbles = toolBubblesForTesting();
        return bubbles.length > 0 && bubbles[0].collapsedForTesting();
    }

    /// Test-only: the message scroll view's current scroll offset.
    public int scrollYForTesting()
    {
        return _messagesScroll.scrollY();
    }

    /// Test-only: the `tool` result bubble at index `n`'s compact argument
    /// text (`(name=value, ...)`) so tests can assert arrays render readably.
    public string toolArgsDisplayForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return "";
        return bubbles[cast(size_t) n].toolArgsDisplayForTesting();
    }

    /// Test-only: scroll the message view to a specific offset.
    public void scrollToForTesting(int value)
    {
        _messagesScroll.setScrollY(value);
    }

    /// Test-only: force a full transcript rebuild, exactly as a throttled
    /// tool-argument delta does mid-stream, so a test can prove rebuilds keep
    /// the reader's scroll position and expand choices.
    public void rebuildForTesting()
    {
        rebuildMessageColumn();
        _messagesScroll.invalidate();
    }

    /// Test-only: whether the transcript is currently auto-following the bottom.
    public bool followForTesting()
    {
        return _messagesScroll.follow;
    }

    /// Test-only: whether the last assistant bubble that shows a thinking block
    /// is currently collapsed (thinking starts collapsed by default).
    public bool lastThinkingCollapsedForTesting()
    {
        const children = messageColumnVisuals();
        foreach_reverse (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "assistant") continue;
            if (!bubble.hasThinkingForTesting()) continue;
            return bubble.thinkingCollapsedForTesting();
        }
        return false;
    }

    /// Test-only: toggle the last assistant bubble that shows a thinking block.
    public void toggleLastThinkingForTesting()
    {
        const children = messageColumnVisuals();
        foreach_reverse (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "assistant") continue;
            if (!bubble.hasThinkingForTesting()) continue;
            bubble.toggleThinkingForTesting();
            _messageColumn.invalidate();
            _messagesScroll.invalidate();
            return;
        }
    }

    /// Test-only: expand (or collapse) the first `tool` result bubble and
    /// reflow the scroll view, exactly as a click would.
    public void toggleFirstToolBubbleForTesting()
    {
        auto bubbles = toolBubblesForTesting();
        if (bubbles.length == 0) return;
        bubbles[0].toggleCollapseForTesting();
        _messageColumn.invalidate();
        _messagesScroll.invalidate();
    }

    /// Test-only: expand (or collapse) the `tool` result bubble at ordinal `n`
    /// (recursing into context groups) and reflow the scroll view.
    public void toggleToolBubbleForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return;
        bubbles[cast(size_t) n].toggleCollapseForTesting();
        _messageColumn.invalidate();
        _messagesScroll.invalidate();
    }

    /// Test-only: number of folded context groups in the column.
    public int contextGroupCountForTesting()
    {
        int count;
        foreach (child; messageColumnVisuals())
            if (cast(ToolGroupBubble) child !is null) ++count;
        return count;
    }

    /// Test-only: whether the first folded context group starts collapsed.
    public bool firstToolGroupCollapsedForTesting()
    {
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                return group.collapsedForTesting();
        return false;
    }

    /// Test-only: expand (or collapse) the first folded context group and
    /// reflow the scroll view, exactly as a header click would.
    public void toggleFirstToolGroupForTesting()
    {
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
            {
                group.toggle();
                _messageColumn.invalidate();
                _messagesScroll.invalidate();
                return;
            }
    }

    /// Test-only: number of tool parts folded inside the first context group.
    public int firstToolGroupPartCountForTesting()
    {
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                return group.partCount();
        return 0;
    }

    /// Test-only: aggregate `+N` across every action-group header (the counters
    /// shown on the right edge of a collapsed group).
    public int totalToolGroupAdditionsForTesting()
    {
        int total;
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                total += group.diffAdditionsForTesting();
        return total;
    }

    /// Test-only: aggregate `-M` across every action-group header.
    public int totalToolGroupDeletionsForTesting()
    {
        int total;
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                total += group.diffDeletionsForTesting();
        return total;
    }

    /// Test-only: the green additions counter for the `tool` bubble at `n`.
    public int toolDiffAdditionsForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return 0;
        return bubbles[cast(size_t) n].diffAdditionsForTesting();
    }

    /// Test-only: the red deletions counter for the `tool` bubble at `n`.
    public int toolDiffDeletionsForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return 0;
        return bubbles[cast(size_t) n].diffDeletionsForTesting();
    }

    /// Test-only: whether the `tool` bubble at `n` has a diff body.
    public bool toolHasDiffForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return false;
        return bubbles[cast(size_t) n].hasDiffForTesting();
    }

    /// Test-only: the wall-clock duration shown for the `tool` bubble at `n`.
    public long toolElapsedMsForTesting(int n)
    {
        auto bubbles = toolBubblesForTesting();
        if (n < 0 || n >= cast(int) bubbles.length) return 0;
        return bubbles[cast(size_t) n].toolElapsedMsForTesting();
    }

    /// Test-only: aggregate tool duration across every action-group header.
    public long totalToolGroupElapsedMsForTesting()
    {
        long total;
        foreach (child; messageColumnVisuals())
            if (auto group = cast(ToolGroupBubble) child)
                total += group.elapsedMsForTesting();
        return total;
    }

    /// Test-only: the composer timer's label, e.g. "0s" or "1m 07s".
    public string chatTimerLabelForTesting()
    {
        return _timerBadge is null ? "" : _timerBadge.labelForTesting();
    }

    /// Test-only: whether the composer timer is in its live (working) state.
    public bool chatTimerRunningForTesting()
    {
        return _timerBadge !is null && _timerBadge.runningForTesting();
    }

    /// Test-only: the conversation's accumulated assistant working seconds.
    public double chatWorkedSecondsForTesting()
    {
        return sessionWorkedSeconds(_current);
    }

    /// Test-only: stamp the active conversation's accumulated work time on its
    /// last user message (as a finished turn would) and refresh the badge.
    public void setChatWorkedSecondsForTesting(double seconds)
    {
        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        foreach_reverse (ref message; session.messages)
            if (message.role == "user")
            {
                message.workedSeconds = seconds;
                break;
            }
        // Production writes the value through `freezeTurnTiming`, which marks
        // the session dirty (refreshing the crash-recovery snapshot too). Mirror
        // that here or a reload can resolve to a stale recovery copy.
        markDirty();
        refreshTimerBadge(true);
    }

    /// Test-only: the centered conversation column's laid-out width. It is the
    /// min of the scroll viewport and `opencodeContentMaxWidth`.
    public int messageColumnWidthForTesting()
    {
        return _messageColumn.bounds().width;
    }

    /// Test-only: the centered conversation column's horizontal offset inside
    /// its centering wrapper (positive when the pane is wider than the cap).
    public int messageColumnXForTesting()
    {
        return _messageColumn.bounds().x;
    }

    /// Test-only: the centering wrapper's viewport width, so tests can verify
    /// the column is centered as (wrapper - column) / 2.
    public int messageCenterWidthForTesting()
    {
        auto parent = _messageColumn.parent();
        return parent is null ? 0 : parent.bounds().width;
    }

    /// Test-only: the composer panel's height.
    public int composerHeightForTesting()
    {
        return _composer.bounds().height;
    }

    /// Test-only: the composer panel's width.
    public int composerWidthForTesting()
    {
        return _composer.bounds().width;
    }
}

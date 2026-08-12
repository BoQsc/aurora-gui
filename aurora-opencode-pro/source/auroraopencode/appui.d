module auroraopencode.appui;

import aurora;
import auroraopencode.core;
import auroraopencode.logging : logError, setLogDirectory;
import auroraopencode.markdown : MarkdownBlock, MdComposition, MdItemKind,
    composeMarkdownInto, paintMarkdown, parseMarkdown;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import auroraopencode.tools : buildSystemPrompt, builtinToolDefinitions,
    executeTool, nativeOnlyToolDefinitions;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.string : strip, toLower;
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

// ---------------------------------------------------------------------------
// Chat message bubble
// ---------------------------------------------------------------------------

private final class MessageBubble : Widget
{
    private static immutable int padH = 14;
    private static immutable int padV = 10;
    private static immutable int gap = 6;

    private string _role;
    private dstring _thinking;
    private dstring _content;
    private bool _streaming;
    private bool _failed;
    private string _error;
    private string _time;
    private string _usageText;
    private int _messageIndex;
    private bool _hidden;

    // Chat-quality actions (Pro): regenerate/retry the last reply, edit &
    // resend a user message.
    private string _actionLabel;
    private void delegate() _actionCallback;
    private Rect _actionRect;
    private bool _actionHover;
    // Right-click requests a context menu (Regenerate / Edit & resend / Copy).
    void delegate(int messageIndex, Point globalPosition) onContextMenuRequested;

    // Interactive affordances (Pro): message/code copy buttons and links.
    private int _hoverCopy = -1;
    private int _hoverLink = -1;
    private Rect[] _copyRects;
    private string[] _copyLabels;
    private Rect[] _linkRects;
    private string[] _linkUrls;

    // Shaped text is expensive and wrapped layouts are never cached by the
    // text engine, so each bubble caches its own layout and reuses it across
    // measures and repaints. The ScrollView measures its content twice per
    // layout (once with and once without the scrollbar width), so a single
    // slot would thrash and re-shape every frame while dragging; a small
    // width-keyed set covers both measure widths.
    private static immutable int shapeCacheSize = 3;
    private int[shapeCacheSize] _contentWidths;
    private TextLayout[shapeCacheSize] _contentLayouts;
    private size_t[shapeCacheSize] _contentShapedGen;
    private size_t _contentCacheCount;
    private size_t _contentGen = 1;
    private TextLayout _thinkingLayout;
    private int _thinkingLayoutWidth = -1;
    private size_t _thinkingShapedGen;
    private size_t _thinkingGen = 1;

    private MarkdownBlock[] _mdBlocks;
    private size_t _mdBlocksGen;
    private int[2] _mdWidths;
    private MdComposition[2] _mdCompositions;
    private size_t[2] _mdGens;
    private size_t _mdCount;

    // Tool result bubbles (`tool` role) are a single element: the header shows
    // the command (⚙ name(args)) and the output below is collapsible. Clicking
    // the header toggles the output.
    private string _toolName;
    private string _toolArgs;

    // Collapse state: tool outputs start hidden behind a compact header.
    private bool _collapsed = true;
    private Rect _collapseRect;
    private bool _collapseHover;

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

    /// Hide the bubble entirely: it measures to zero height and paints nothing
    /// but keeps its slot so child-index ↔ message-index mapping stays intact.
    /// Used for tool-call wrappers that carried no content or reasoning.
    void setHidden(bool value)
    {
        if (_hidden == value) return;
        _hidden = value;
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

    void setCollapsed(bool value)
    {
        if (_collapsed == value) return;
        _collapsed = value;
        if (onSizeChanged !is null) onSizeChanged();
        invalidate();
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

    void setThinkingCollapsed(bool value)
    {
        if (_thinkingCollapsed == value) return;
        _thinkingCollapsed = value;
        if (onSizeChanged !is null) onSizeChanged();
        invalidate();
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
        if (!_thinkingLive) return;
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

    void setAction(string label, void delegate() callback)
    {
        _actionLabel = label;
        _actionCallback = callback;
        invalidate();
    }

    void clearAction()
    {
        if (_actionLabel.length == 0 && _actionCallback is null) return;
        _actionLabel = "";
        _actionCallback = null;
        _actionHover = false;
        invalidate();
    }

    /// Test-only: the label of the current action pill.
    public string actionLabelForTesting()
    {
        return _actionLabel;
    }

    /// Test-only: invoke the current action pill's callback, if any.
    public bool invokeActionForTesting()
    {
        if (_actionLabel.length == 0 || _actionCallback is null) return false;
        _actionCallback();
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
        if (_thinkingLayout !is null && _thinkingLayoutWidth == width &&
            _thinkingShapedGen == _thinkingGen)
            return _thinkingLayout;
        _thinkingLayout = shape(_thinking, width);
        _thinkingLayoutWidth = width;
        _thinkingShapedGen = _thinkingGen;
        return _thinkingLayout;
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

    private MdComposition markdownFor(int width)
    {
        foreach (index; 0 .. _mdCount)
        {
            if (_mdGens[index] == _contentGen && _mdWidths[index] == width)
                return _mdCompositions[index];
        }

        if (_mdBlocks is null || _mdBlocksGen != _contentGen)
        {
            _mdBlocks = parseMarkdown(_content);
            _mdBlocksGen = _contentGen;
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
        composeMarkdownInto(composition, _mdBlocks,
            maxInt(24, width), _streaming);
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
        options.pixelSize = fontPixelSize(2);
        options.maxWidth = maxInt(1, width);
        options.wrap = true;
        ++shapeCount;
        return fontSystem().textEngine.layout(text, options);
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
        const pixelSize = fontPixelSize(2);
        int height = 2 * padV;
        if (_thinking.length > 0)
        {
            // Thinking header (slim) always; full reasoning only when expanded.
            height += fontPixelSize(1) + 4;
            if (!_thinkingCollapsed)
                height += shapedThinking(innerWidth).measuredSize().height + gap;
        }

        if (_role == "tool")
        {
            // Header (command) always; output below when expanded.
            height += fontPixelSize(1) + 4;
            if (!_collapsed && _content.length > 0)
                height += shapedContent(innerWidth).measuredSize().height + gap;
        }
        else if (_role == "assistant")
        {
            if (_content.length > 0)
                height += cast(int) markdownFor(innerWidth).height;
            else if (_streaming)
                height += pixelSize + 2;
        }
        else
        {
            if (_content.length > 0)
                height += shapedContent(innerWidth).measuredSize().height;
            else if (_streaming)
                height += pixelSize + 2;
        }
        if (_failed)
            height += fontPixelSize(1) + 4;
        if (_time.length > 0 || _usageText.length > 0 ||
            _actionLabel.length > 0 ||
            (_role == "tool" && _toolName.length > 0))
            height += fontPixelSize(1) + 4;
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
        const palette = theme();
        const width = bounds().width;
        const height = bounds().height;
        const background = _role == "user" ? opencodeUserBubble :
            opencodeAssistantBubble;
        canvas.fillRoundedRect(Rect(0, 0, width, height), 10, background);
        if (_failed)
            canvas.strokeRect(Rect(0, 0, width, height), opencodeErrorRed, 1);

        const innerWidth = maxInt(1, width - 2 * padH);
        int y = padV;

        if (_thinking.length > 0)
        {
            drawThinkingHeader(canvas, innerWidth, y);
            y += fontPixelSize(1) + 4;
            if (!_thinkingCollapsed)
            {
                auto layout = shapedThinking(innerWidth);
                canvas.drawLayout(Point(padH, y), layout, opencodeThinkingText);
                y += layout.measuredSize().height + gap;
            }
        }

        _copyRects.length = 0;
        _copyLabels.length = 0;
        _linkRects.length = 0;
        _linkUrls.length = 0;

        const contentY = y;

        if (_role == "tool")
        {
            // Always show the command header (⚙ name(args) ▸/▾); the output
            // below it is shown only when expanded.
            drawToolHeader(canvas, innerWidth, y);
            y += fontPixelSize(1) + 4;
            if (!_collapsed && _content.length > 0)
            {
                auto layout = shapedContent(innerWidth);
                canvas.drawLayout(Point(padH, y), layout, opencodeText);
                y += layout.measuredSize().height + gap;
            }
        }
        else if (_content.length > 0 || _streaming)
        {
            if (_role == "assistant")
            {
                auto composition = markdownFor(innerWidth);
                if (composition.items.length > 0)
                {
                    paintMarkdown(canvas, composition, padH, contentY);
                    collectMarkdownTargets(composition, contentY);
                }
                else if (_streaming)
                {
                    auto layout = canvas.layoutText("▌"d, 2, FontRole.ui, null,
                        innerWidth, false);
                    canvas.drawLayout(Point(padH, contentY), layout, palette.text);
                }
            }
            else
            {
                auto layout = shapedContent(innerWidth);
                canvas.drawLayout(Point(padH, contentY), layout, opencodeText);
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
        drawActionPill(canvas, width, height);
        drawFooter(canvas, width, height);
    }
    private void drawActionPill(ref Canvas canvas, int width, int height)
    {
        _actionRect = Rect.init;
        if (_actionLabel.length == 0 || _actionCallback is null) return;
        auto labelLayout = canvas.layoutText(toUTF32(_actionLabel), 1,
            FontRole.ui, cast(FontFace) theme().uiFont, 200, false);
        const aw = maxInt(52, cast(int) labelLayout.width + 18);
        _actionRect = Rect(padH, height - padV - 19, aw, 18);
        canvas.fillRoundedRect(_actionRect, 9,
            _actionHover ? opencodeAccent.withAlpha(150) : opencodeBorder);
        canvas.drawTextInRect(_actionRect, toUTF32(_actionLabel),
            _actionHover ? Color.rgb(255, 255, 255) : opencodeMuted, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }

    /// Header for a tool result: the command (⚙ name(args)) with a ▸/▾ toggle
    /// indicator. Clicking it shows or hides the output below.
    private void drawToolHeader(ref Canvas canvas, int innerWidth, int top)
    {
        const label = _toolName.length > 0 ? _toolName : "tool";
        const toggle = _collapsed ? "▸" : "▾";
        const text = toggle ~ " ⚙ " ~ label ~ toolArgsDisplay();
        auto layout = canvas.layoutText(toUTF32(text), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, maxInt(1, innerWidth), true);
        const h = layout.measuredSize().height;
        _collapseRect = Rect(padH, top, maxInt(1, innerWidth), h);
        canvas.fillRoundedRect(_collapseRect, 4,
            _collapseHover ? opencodeSelection : opencodeField);
        canvas.drawLayout(Point(padH, top), layout,
            _collapseHover ? opencodeText : opencodeMuted);
    }

    /// Slim thinking header: `▸ Thinking` when collapsed (pulsing `▌` while
    /// the assistant is still working), `▾ Thinking` when expanded. Clicking
    /// toggles the full reasoning text.
    private void drawThinkingHeader(ref Canvas canvas, int innerWidth, int top)
    {
        const toggle = _thinkingCollapsed ? "▸" : "▾";
        string text = toggle ~ " Thinking";
        if (_thinkingLive)
        {
            // Pulsing indicator: cycle between ▌ and ▐ every half second.
            const phase = cast(int) (_thinkingElapsed * 2) & 1;
            text ~= phase == 0 ? " ▌" : " ▐";
        }
        auto layout = canvas.layoutText(toUTF32(text), 1, FontRole.ui,
            cast(FontFace) theme().uiFont, maxInt(1, innerWidth), true);
        const h = layout.measuredSize().height;
        _thinkingRect = Rect(padH, top, maxInt(1, innerWidth), h);
        canvas.fillRoundedRect(_thinkingRect, 4,
            _thinkingHover ? opencodeSelection : opencodeField);
        canvas.drawLayout(Point(padH, top), layout,
            _thinkingLive ? opencodeAccent :
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
            {
                if (entry.type == JSONType.string)
                    parts ~= key ~ "=" ~ entry.str;
                else if (entry.type == JSONType.integer)
                    parts ~= key ~ "=" ~ to!string(entry.integer);
                else if (entry.type == JSONType.array)
                    parts ~= key ~ "=[…]";
                else
                    parts ~= key;
            }
            string joined;
            foreach (index, part; parts)
            {
                if (index > 0) joined ~= ", ";
                joined ~= part;
            }
            if (joined.length > 50) joined = joined[0 .. 50] ~ "…";
            return "(" ~ joined ~ ")";
        }
        if (args.length > 40) args = args[0 .. 40] ~ "…";
        return "(" ~ args ~ ")";
    }

    private void collectMarkdownTargets(ref MdComposition composition, int contentY)
    {
        foreach (item; composition.items)
        {
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

    private void drawFooter(ref Canvas canvas, int width, int height)
    {
        const footer = _usageText.length > 0 ? _usageText :
            (_role == "tool" && _toolName.length > 0 ? "⚙ " ~ _toolName : _time);
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
        const overCollapse = _role == "tool" &&
            _collapseRect.contains(event.position);
        const overThinking = _thinking.length > 0 &&
            _thinkingRect.contains(event.position);
        if (nextCopy != _hoverCopy || nextLink != _hoverLink ||
            overAction != _actionHover || overCollapse != _collapseHover ||
            overThinking != _thinkingHover)
        {
            _hoverCopy = nextCopy;
            _hoverLink = nextLink;
            _actionHover = overAction;
            _collapseHover = overCollapse;
            _thinkingHover = overThinking;
            setCursor(nextCopy >= 0 || nextLink >= 0 || overAction ||
                overCollapse || overThinking ? CursorKind.hand : CursorKind.arrow);
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
                onContextMenuRequested(_messageIndex,
                    localToGlobal(event.position));
                return true;
            }
            return false;
        }
        if (event.button != MouseButton.left) return false;
        if (_thinking.length > 0 && _thinkingRect.contains(event.position))
        {
            setThinkingCollapsed(!_thinkingCollapsed);
            return true;
        }
        if (_role == "tool" && _collapseRect.contains(event.position))
        {
            setCollapsed(!_collapsed);
            return true;
        }
        if (_actionLabel.length > 0 && _actionCallback !is null &&
            _actionRect.contains(event.position))
        {
            _actionCallback();
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
        return false;
    }

    protected override void onMouseLeave()
    {
        if (_hoverCopy != -1 || _hoverLink != -1 || _actionHover ||
            _collapseHover || _thinkingHover)
        {
            _hoverCopy = -1;
            _hoverLink = -1;
            _actionHover = false;
            _collapseHover = false;
            _thinkingHover = false;
            setCursor(CursorKind.arrow);
            invalidate();
        }
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

    void setUsage(int prompt, int completion, int total)
    {
        if (prompt == _prompt && completion == _completion && total == _total)
            return;
        _prompt = prompt;
        _completion = completion;
        _total = total;
        invalidate();
    }

    int promptTokens() const @safe pure nothrow @nogc { return _prompt; }
    int completionTokens() const @safe pure nothrow @nogc { return _completion; }
    int totalTokens() const @safe pure nothrow @nogc { return _total; }
    int limit() const @safe pure nothrow @nogc { return _limit; }

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
        return hasUsage() ? to!string(usagePercent) ~ "%" : "ctx";
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
// Auto-follow scroll view
// ---------------------------------------------------------------------------

private final class ChatScrollView : ScrollView
{
    bool follow = true;

    this(Widget content)
    {
        super(content);
    }

    protected override void onLayout()
    {
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
// Session sidebar list (Pro: context menu, Delete key)
// ---------------------------------------------------------------------------

public final class SessionListView : ListView
{
    void delegate(int index, Point globalPosition) onContextMenuRequested;
    void delegate(int index) onDeleteRequested;

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
// Main root
// ---------------------------------------------------------------------------

public final class OpenCodeRoot : VBox
{
    private GuiWindow _window;
    private OpenCodeClient _client;
    private Settings _settings;
    private ChatSession[] _sessions;
    private int _current = -1;
    private string[] _models = defaultModels.dup;

    private SessionListView _sessionList;
    private ChatScrollView _messagesScroll;
    private VBox _messageColumn;
    private ChatInput _input;
    private Button _sendButton;
    private Button _modelButton;
    private CheckBox _thinkingBox;
    private CheckBox _toolsBox;
    private Label _keyBadge;
    private Label _status;
    private TextField _filterField;
    private int[] _sessionIndices;
    private string _filterText;
    private string _lastUsageText;
    private bool _suppressDoneStatus;

    private MessageBubble _streamBubble;
    private PopupOverlay _activePopup;

    // Tool loop: the model may request tool calls, the app executes them, and
    // the enriched history is re-sent until the model answers with text.
    private OpenCodeToolCall[] _pendingToolCalls;
    private int _pendingToolResults;
    private int _toolRounds;
    private static immutable int maxToolRounds = 12;
    private bool _toolContinuationPaused; // test-only: hold the loop after results

    // Doom-loop recovery (mirrors the original opencode app): when the model
    // repeats the same tool call with identical input, it is likely stuck in a
    // loop. After the same signature repeats a few times, break the loop and
    // ask the model to answer directly instead of running more tools.
    private string _lastToolSignature;
    private int _lastToolRepeatCount;
    private static immutable int doomLoopRepeatThreshold = 3;

    private ContextUsageBadge _usageBadge;
    private HoverTooltip _usageTooltip;
    private bool _usageTooltipOpen;

    // Generic hover tooltip (used for dialog options such as Legacy tools).
    private TooltipAnchor _legacyTooltipAnchor;
    private HoverTooltip _legacyTooltip;
    private bool _legacyTooltipOpen;

    private MonoTime _chatStartedAt;
    private bool _receivedFirstDelta;
    private int _lastColdStartSeconds = -1;

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        setLogDirectory(buildPath(opencodeStateDirectory(), "logs"));
        _settings = loadSettings();
        _client = new OpenCodeClient(_settings.baseUrl, _settings.apiKey);
        buildUi();
        restoreSessions();
        // The restored selection is applied before the first layout. Revealing
        // it at that point would measure against a zero-height viewport and
        // seed the list's scroll offset at the bottom.
        updateSessionList(false);
        updateKeyBadge();
        updateSendButton();
        _client.fetchModels();
        _input.requestFocus();
    }

    /// Test-only / shutdown hook: release the shared network session.
    public void shutdownClient()
    {
        _client.closeSession();
    }

    private void buildUi()
    {
        auto toolbar = add(new HBox(8, Insets(10, 6)));
        toolbar.layoutHints().preferredHeight = 52;

        auto newChatButton = toolbar.add(new Button("New chat", IconKind.newDocument));
        newChatButton.setId("oc-new");
        newChatButton.onClick = delegate() { newChat(); };

        _modelButton = toolbar.add(new Button(_settings.model));
        _modelButton.setId("oc-model");
        _modelButton.onClick = delegate() { showModelPicker(); };

        _usageBadge = toolbar.add(new ContextUsageBadge());
        _usageBadge.setId("oc-usage");
        _usageBadge.setModel(_settings.model);
        _usageBadge.onHoverChanged = delegate(bool open)
        {
            setContextUsageTooltipOpen(open);
        };

        _thinkingBox = toolbar.add(new CheckBox("Thinking"));
        _thinkingBox.setId("oc-thinking");
        _thinkingBox.setChecked(_settings.thinking, false);
        _thinkingBox.onChanged = delegate(bool value)
        {
            _settings.thinking = value;
            if (_current >= 0) _sessions[_current].thinking = value;
            saveSettingsNow();
        };

        _toolsBox = toolbar.add(new CheckBox("Tools"));
        _toolsBox.setId("oc-tools");
        _toolsBox.setChecked(_settings.toolsEnabled, false);
        _toolsBox.onChanged = delegate(bool value)
        {
            _settings.toolsEnabled = value;
            saveSettingsNow();
            updateStatus(value
                ? "Tools enabled — the model uses the D-native " ~
                  "run/read/write/glob/grep/dshell tools."
                : "Tools disabled.");
        };

        toolbar.add(new Spacer());

        auto exportButton = toolbar.add(new Button("Export", IconKind.save));
        exportButton.onClick = delegate() { exportCurrentConversation(); };

        auto settingsButton = toolbar.add(new Button("Settings", IconKind.settings));
        settingsButton.onClick = delegate() { showSettingsDialog(); };

        _keyBadge = toolbar.add(new Label(""));
        _keyBadge.setId("oc-key");
        _keyBadge.setScale(1);

        auto body = add(new HBox(0));
        body.layoutHints().flex = 1.0;

        auto sidebar = new VBox(6, Insets(8));
        sidebar.layoutHints().preferredWidth = 220;
        auto sidebarHeader = sidebar.add(new Label("Conversations"));
        sidebarHeader.setScale(1);
        sidebarHeader.setColor(opencodeMuted);
        _filterField = sidebar.add(new TextField(""));
        _filterField.setId("oc-filter");
        _filterField.layoutHints().preferredHeight = 26;
        _filterField.onChanged = delegate()
        {
            _filterText = _filterField.textUtf8().strip();
            updateSessionList();
        };
        _sessionList = sidebar.add(new SessionListView());
        _sessionList.setId("oc-sessions");
        _sessionList.layoutHints().flex = 1.0;
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

        _messageColumn = new VBox(6, Insets(12));
        _messageColumn.setId("oc-messages");
        _messagesScroll = new ChatScrollView(_messageColumn);
        _messagesScroll.setId("oc-scroll");
        _messagesScroll.layoutHints().flex = 1.0;

        auto inputRow = new HBox(8, Insets(12, 8));
        inputRow.layoutHints().preferredHeight = 88;
        _input = new ChatInput();
        _input.setId("oc-input");
        _input.layoutHints().flex = 1.0;
        _input.onSendRequested = delegate() { sendMessage(); };
        _sendButton = new Button("Send");
        _sendButton.setId("oc-send");
        _sendButton.setAccent(true);
        _sendButton.onClick = delegate() { sendMessage(); };

        inputRow.add(_input);
        inputRow.add(_sendButton);

        chatPanel.add(_messagesScroll);
        chatPanel.add(inputRow);

        body.add(sidebar);
        body.add(chatPanel);

        _status = add(new Label("Ready"));
        _status.setId("oc-status");
        _status.layoutHints().preferredHeight = 26;
        _status.setScale(1);
    }

    // -- sessions ---------------------------------------------------------

    private void newChat()
    {
        ChatSession session;
        session.title = "New chat";
        session.model = _settings.model;
        session.thinking = _settings.thinking;
        _sessions ~= session;
        _current = cast(int) _sessions.length - 1;
        _streamBubble = null;
        _pendingToolCalls.length = 0;
        _pendingToolResults = 0;
        _toolRounds = 0;
        _lastToolSignature = "";
        _lastToolRepeatCount = 0;
        _filterText = "";
        if (_filterField !is null) _filterField.setText("", false);
        rebuildMessageColumn();
        updateSessionList();
        markDirty();
        _input.requestFocus();
        updateStatus("New conversation. Ask away!");
        refreshUsageBadge();
    }

    private void selectSession(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return;
        _current = index;
        _streamBubble = null;
        _pendingToolCalls.length = 0;
        _pendingToolResults = 0;
        _toolRounds = 0;
        _lastToolSignature = "";
        _lastToolRepeatCount = 0;
        rebuildMessageColumn();
        _settings.model = _sessions[index].model;
        _settings.thinking = _sessions[index].thinking;
        _modelButton.setText(_settings.model);
        _thinkingBox.setChecked(_settings.thinking, false);
        markDirty();
        updateStatus("");
        refreshUsageBadge();
    }

    private void selectSessionByRow(int row)
    {
        if (row < 0 || row >= cast(int) _sessionIndices.length) return;
        selectSession(_sessionIndices[row]);
    }

    private void rebuildMessageColumn()
    {
        _messageColumn.clearChildren();
        if (_current < 0) return;
        const session = &_sessions[_current];
        // Only the latest real assistant reply shows its token usage in the
        // footer. Tool-call wrappers (empty content + tool requests) never do.
        int latestAssistantIndex = -1;
        foreach_reverse (index, message; session.messages)
        {
            if (message.role == "assistant" && message.toolCalls.length == 0)
            {
                latestAssistantIndex = cast(int) index;
                break;
            }
        }
        foreach (index, message; session.messages)
        {
            auto bubble = new MessageBubble();
            bubble.setRole(message.role);
            bubble.setMessageIndex(cast(int) index);
            bubble.setContent(message.content);
            // A tool-call wrapper with no content/reasoning is not a visible
            // reply; keep its slot (for index mapping) but collapse it away.
            if (message.role == "assistant" && message.toolCalls.length > 0 &&
                message.content.length == 0 && message.reasoning.length == 0 &&
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
                // Expanding/collapsing changes the bubble height; re-measure
                // the column WITHOUT snapping the scroll to the bottom.
                bubble.onSizeChanged = delegate()
                {
                    _messageColumn.invalidate();
                    _messagesScroll.invalidate();
                };
            }
            if (message.reasoning.length > 0)
                bubble.setThinking(message.reasoning);
            if (message.time.length > 0)
                bubble.setTime(message.time);
            if (message.failed)
                bubble.setFailed("");
            bubble.onContextMenuRequested =
                delegate(int messageIndex, Point globalPosition)
                {
                    showMessageContextMenu(cast(int) index, globalPosition);
                };
            // Persisted token usage appears only on the latest assistant reply.
            if (cast(int) index == latestAssistantIndex &&
                message.totalTokens > 0)
            {
                bubble.setUsageText(" • " ~
                    formatThousands(message.totalTokens) ~ " tokens");
            }
            _messageColumn.add(bubble);
        }
        _messagesScroll.follow = true;
        _messageColumn.invalidate();
        // The column is a retained layer; let the ScrollView re-measure and
        // update the content height / auto-follow after the message set changes.
        _messagesScroll.invalidate();
        refreshBubbleActions();
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
        const children = _messageColumn.children();
        if (children.length == 0) return;
        const session = &_sessions[_current];

        // The pill belongs to the last bubble that is not the live reply.
        size_t actionIndex;
        bool found;
        for (size_t i = children.length; i > 0; --i)
        {
            auto child = cast(MessageBubble) children[i - 1];
            if (child is null) continue;
            if (_streamBubble !is null && child is _streamBubble) continue;
            actionIndex = i - 1;
            found = true;
            break;
        }

        foreach (index, child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            bubble.clearAction();
            if (!found || index != actionIndex ||
                index >= session.messages.length)
                continue;
            const message = session.messages[index];
            // Only a real assistant reply gets a visible pill; a tool-call
            // wrapper (empty content + tool requests) is not a reply.
            if (message.role == "assistant" && message.toolCalls.length == 0)
                bubble.setAction(message.failed ? "Retry" : "Regenerate",
                    regenerateAction(_current, cast(int) index));
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
                delegate(int messageIndex, Point globalPosition)
                {
                    showMessageContextMenu(
                        cast(int) _sessions[_current].messages.length - 1,
                        globalPosition);
                };
        }
        _messageColumn.add(bubble);
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
        refreshBubbleActions();
    }

    private void beginAssistantMessage()
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        ChatMessage message;
        message.role = "assistant";
        message.time = currentTimestamp();
        session.messages ~= message;

        _streamBubble = new MessageBubble();
        _streamBubble.setRole("assistant");
        _streamBubble.setStreaming(true);
        _messageColumn.add(_streamBubble);
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
        refreshBubbleActions();
    }

    private void appendStreamDelta(string text, bool reasoning)
    {
        if (_current < 0 || _streamBubble is null) return;
        if (!_receivedFirstDelta)
        {
            _receivedFirstDelta = true;
            updateStatus("Generating…");
        }
        auto session = &_sessions[_current];
        if (session.messages.length == 0) return;
        auto message = &session.messages[$ - 1];
        if (reasoning)
        {
            message.reasoning ~= text;
            _streamBubble.appendThinking(text);
            _streamBubble.setThinkingLive(true);
        }
        else
        {
            message.content ~= text;
            _streamBubble.appendContent(text);
        }
        // The streamed text changes the bubble height, so the ScrollView must
        // re-measure to keep auto-follow at the bottom as the reply grows.
        _messagesScroll.invalidate();
    }

    private void finishAssistantMessage(bool cancelled, int promptTokens = 0,
        int completionTokens = 0, int totalTokens = 0)
    {
        if (_streamBubble !is null)
        {
            _streamBubble.setThinkingLive(false);
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        if (_current >= 0 && _sessions[_current].messages.length > 0)
        {
            auto message = &_sessions[_current].messages[$ - 1];
            if (message.time.length == 0) message.time = currentTimestamp();
            if (totalTokens > 0)
            {
                message.promptTokens = promptTokens;
                message.completionTokens = completionTokens;
                message.totalTokens = totalTokens;
            }
        }
        string status = cancelled ? "Stopped." : "Done.";
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

    private void failAssistantMessage(string error)
    {
        if (_current < 0)
        {
            updateStatus("Error: " ~ error);
            return;
        }
        auto session = &_sessions[_current];
        if (session.messages.length == 0)
            beginAssistantMessage();
        auto message = &session.messages[$ - 1];
        message.content ~= (message.content.length == 0 ? "" : "\n\n") ~
            "Error: " ~ error;
        message.failed = true;
        if (_streamBubble is null)
        {
            _streamBubble = new MessageBubble();
            _streamBubble.setRole("assistant");
            _messageColumn.add(_streamBubble);
        }
        _streamBubble.setStreaming(false);
        _streamBubble.setFailed(error);
        _streamBubble = null;
        _messagesScroll.invalidate();
        updateStatus("Error: " ~ error);
        markDirty();
        refreshBubbleActions();
    }

    // -- tool loop ---------------------------------------------------------

    /// The model requested tool calls. Finalize the assistant message with the
    /// request (so it persists and is replayed on regeneration), then execute
    /// each tool on a worker thread. Results are pushed back through the
    /// client's event queue as toolResult events.
    private void handleToolCalls(const OpenCodeEvent event)
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
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
        if (_streamBubble !is null)
        {
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        // Rebuild so the tool-call wrapper re-renders: an assistant message
        // with tool requests and no content/reasoning becomes a hidden slot,
        // not a visible empty bubble.
        rebuildMessageColumn();
        markDirty();

        // Doom-loop recovery: the same tool call repeated with identical input
        // means the model is stuck. Break the loop and ask it to answer with
        // what it already knows instead of running more tools.
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
        if (_lastToolRepeatCount >= doomLoopRepeatThreshold)
        {
            ChatMessage recovery;
            recovery.role = "user";
            recovery.content = "You appear to be repeating the same tool call " ~
                "(" ~ signature ~ ") without making progress. Stop calling " ~
                "tools and answer the user's question directly with what you " ~
                "have already learned.";
            session.messages ~= recovery;
            markDirty();
            _toolRounds = 0;
            _lastToolSignature = "";
            _lastToolRepeatCount = 0;
            updateStatus("Tool loop detected — asking the model to answer…");
            _messagesScroll.follow = true;
            _messagesScroll.invalidate();
            startChatRequest(_current);
            return;
        }

        if (_toolRounds >= maxToolRounds)
        {
            // Last-chance final request: tell the model to stop and answer.
            ChatMessage finalize;
            finalize.role = "user";
            finalize.content = "You have reached the maximum number of tool " ~
                "calls. Stop using tools now and answer the user's question " ~
                "directly with what you have learned so far.";
            session.messages ~= finalize;
            markDirty();
            _toolRounds = 0;
            _lastToolSignature = "";
            _lastToolRepeatCount = 0;
            updateStatus("Finalizing — asking the model to answer…");
            _messagesScroll.follow = true;
            _messagesScroll.invalidate();
            startChatRequest(_current);
            return;
        }
        ++_toolRounds;
        updateStatus("Running " ~ to!string(event.toolCalls.length) ~
            " tool call(s)…");

        _pendingToolCalls = event.toolCalls.dup;
        _pendingToolResults = cast(int) event.toolCalls.length;
        const sessionIndex = _current;
        const workspace = _settings.workspace;
        auto client = _client;
        auto worker = new Thread({
            runToolWorker(client, sessionIndex, _pendingToolCalls, workspace);
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
    private static void runToolWorker(OpenCodeClient client, int sessionIndex,
        const(OpenCodeToolCall)[] calls, string workspace)
    {
        foreach (call; calls)
        {
            auto execution = executeTool(call, workspace);
            OpenCodeEvent result;
            result.kind = OpenCodeEventKind.toolResult;
            result.text = execution.output;
            result.toolName = call.name;
            result.toolCallId = call.id;
            result.toolFailed = execution.failed;
            result.reasoning = false;
            client.pushLocalEvent(result);
        }
    }

    /// A tool finished executing: append a `tool` role message with its output
    /// and, once every call in the batch has reported, re-send the enriched
    /// history so the model can answer with the results available.
    private void applyToolResult(const OpenCodeEvent event)
    {
        if (_current < 0 || _pendingToolCalls.length == 0) return;
        auto session = &_sessions[_current];

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

        ChatMessage toolMessage;
        toolMessage.role = "tool";
        toolMessage.content = event.text;
        toolMessage.toolCallId = event.toolCallId;
        toolMessage.toolName = event.toolName;
        toolMessage.toolArgs = toolArgs;
        toolMessage.time = currentTimestamp();
        session.messages ~= toolMessage;

        auto bubble = new MessageBubble();
        bubble.setRole("tool");
        bubble.setContent(event.text);
        bubble.setToolName(event.toolName);
        bubble.setToolArgs(toolArgs);
        if (event.toolFailed)
            bubble.setFailed("");
        // Expanding/collapsing changes the bubble height; re-measure the
        // column WITHOUT snapping the scroll to the bottom.
        bubble.onSizeChanged = delegate()
        {
            _messageColumn.invalidate();
            _messagesScroll.invalidate();
        };
        _messageColumn.add(bubble);
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
        markDirty();

        --_pendingToolResults;
        if (_pendingToolResults <= 0)
        {
            _pendingToolCalls.length = 0;
            _messagesScroll.invalidate();
            refreshBubbleActions();
            if (!_toolContinuationPaused)
                startChatRequest(_current);
        }
    }

    // -- sending ----------------------------------------------------------

    private void sendMessage()
    {
        if (_client.busy())
        {
            _client.cancel();
            updateStatus("Stopping…");
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

        ChatMessage userMessage;
        userMessage.role = "user";
        userMessage.content = text;
        userMessage.time = currentTimestamp();
        session.messages ~= userMessage;
        addUserBubble(text);
        _input.setText("");
        markDirty();
        _toolRounds = 0;
        _lastToolSignature = "";
        _lastToolRepeatCount = 0;
        _pendingToolCalls.length = 0;
        _pendingToolResults = 0;
        startChatRequest(_current);
    }

    /// Start the streaming request for the current session history. When
    /// tools are enabled, the structured history (including tool calls and
    /// results) is sent together with the tool definitions and a steering
    /// prompt that directs the model toward the native D tools.
    private void startChatRequest(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        auto session = &_sessions[sessionIndex];
        ChatRequestMessage[] messages;
        if (_settings.toolsEnabled)
        {
            ChatRequestMessage systemPrompt;
            systemPrompt.role = "system";
            const workspace = _settings.workspace.length > 0
                ? _settings.workspace : ".";
            version (Windows)
                const platform = "win32";
            else version (Posix)
                const platform = "posix";
            else
                const platform = "unknown";
            // Native tools are the main tool set; the legacy shell tool is an
            // opt-in addition from Settings.
            systemPrompt.content = buildSystemPrompt(!_settings.legacyTools,
                workspace, platform);
            messages ~= systemPrompt;
        }
        foreach (message; session.messages)
        {
            ChatRequestMessage request;
            request.role = message.role;
            request.content = message.content;
            request.toolCallId = message.toolCallId;
            request.toolCalls = message.toolCalls.dup;
            messages ~= request;
        }
        OpenCodeToolDef[] tools;
        if (_settings.toolsEnabled)
            tools = _settings.legacyTools
                ? builtinToolDefinitions()
                : nativeOnlyToolDefinitions();
        _client.startChatMessages(messages, tools, _settings.model,
            _settings.thinking);
        _chatStartedAt = MonoTime.currTime;
        _receivedFirstDelta = false;
        _lastColdStartSeconds = -1;
        updateStatus("Generating…");
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

    /// Remove an assistant reply (and everything after it) so its history is
    /// ready to re-run. Returns false when there is nothing to regenerate.
    private bool prepareRegenerate(int sessionIndex, int messageIndex)
    {
        if (_client.busy()) return false;
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return false;
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return false;
        if (session.messages[messageIndex].role != "assistant") return false;
        session.messages = session.messages[0 .. messageIndex];
        _streamBubble = null;
        rebuildMessageColumn();
        return true;
    }

    /// Edit-and-resend a user message: cancel any in-flight reply, truncate
    /// the conversation at that message, and prefill the input with its text.
    private void editAndResend(int sessionIndex, int messageIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length)
            return;
        if (_client.busy())
        {
            _client.cancel();
            _suppressDoneStatus = true;
        }
        auto session = &_sessions[sessionIndex];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return;
        const message = session.messages[messageIndex];
        if (message.role != "user") return;
        session.messages = session.messages[0 .. messageIndex];
        _streamBubble = null;
        rebuildMessageColumn();
        _input.setText(message.content);
        _input.requestFocus();
        markDirty();
        updateStatus("Editing — press Send to re-send.");
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
        popup.setAnchor(Rect(origin.x, origin.y, _modelButton.size().width,
            _modelButton.size().height), PopupPlacement.below);
        popup.setBackdrop(Color.rgba(0, 0, 0, 90));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    // -- settings dialog --------------------------------------------------

    private void showSettingsDialog()
    {
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(14));
        content.layoutHints().preferredWidth = 520;

        auto title = content.add(new Label("Settings"));
        title.setScale(3);

        auto baseRow = new HBox(8);
        baseRow.layoutHints().preferredHeight = 40;
        auto baseLabel = baseRow.add(new Label("API base URL"));
        baseLabel.layoutHints().preferredWidth = 110;
        baseLabel.setScale(1);
        auto baseField = baseRow.add(new TextField(_settings.baseUrl));
        baseField.layoutHints().flex = 1.0;

        auto keyRow = new HBox(8);
        keyRow.layoutHints().preferredHeight = 40;
        auto keyLabel = keyRow.add(new Label("API key"));
        keyLabel.layoutHints().preferredWidth = 110;
        keyLabel.setScale(1);
        auto keyField = keyRow.add(new TextField(_settings.apiKey));
        keyField.layoutHints().flex = 1.0;

        auto hint = content.add(new Label(
            "Key loads from your settings file, OPENCODE_API_KEY, or the " ~
            "opencode-api server key file by default."));
        hint.setScale(1);
        hint.setColor(opencodeMuted);

        auto workspaceRow = new HBox(8);
        workspaceRow.layoutHints().preferredHeight = 40;
        auto workspaceLabel = workspaceRow.add(new Label("Workspace"));
        workspaceLabel.layoutHints().preferredWidth = 110;
        workspaceLabel.setScale(1);
        auto workspaceField = workspaceRow.add(
            new TextField(_settings.workspace));
        workspaceField.setId("oc-workspace");
        workspaceField.layoutHints().flex = 1.0;
        auto workspaceHint = content.add(new Label(
            "Directory where tools (bash/read/write/glob/grep) operate. " ~
            "Leave empty to use the app directory."));
        workspaceHint.setScale(1);
        workspaceHint.setColor(opencodeMuted);

        // Legacy tools: an opt-in extra on top of the native D tools. Its
        // label shows a small hover tooltip explaining what it is.
        auto legacyRow = new HBox(8);
        legacyRow.layoutHints().preferredHeight = 40;
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
            "tool in addition to the native run/read/write/glob/grep/dshell " ~
            "tools. Off by default.");
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

        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 42;
        footer.add(new Spacer());
        auto cancelButton = footer.add(new Button("Cancel"));
        cancelButton.onClick = delegate() { dismissPopup(); };
        auto saveButton = footer.add(new Button("Save", IconKind.save));
        saveButton.setAccent(true);
        saveButton.onClick = delegate()
        {
            const baseUrl = baseField.textUtf8().strip();
            const apiKey = keyField.textUtf8().strip();
            const workspace = workspaceField.textUtf8().strip();
            if (baseUrl.length > 0) _settings.baseUrl = baseUrl;
            _settings.apiKey = apiKey;
            _settings.workspace = workspace;
            _client.setCredentials(_settings.baseUrl, _settings.apiKey);
            saveSettingsNow();
            updateKeyBadge();
            _client.fetchModels();
            updateStatus("Settings saved.");
            dismissPopup();
        };

        content.add(baseRow);
        content.add(keyRow);
        content.add(hint);
        content.add(workspaceRow);
        content.add(workspaceHint);
        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(540, 430));
        popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
        popup.focusFirst();
    }

    private void openPopup(PopupOverlay popup)
    {
        _activePopup = popup;
        popupRoot(this).add(popup);
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
        if (_models.length == 0) _models = defaultModels.dup;
        bool found;
        foreach (model; _models)
            if (model == _settings.model) found = true;
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
        _keyBadge.setText(hasKey ? "Key set" : "No key");
        _keyBadge.setColor(hasKey ? opencodeKeyOk : opencodeKeyMissing);
    }

    private void updateStatus(string text)
    {
        _status.setText(text);
    }

    private void updateSendButton()
    {
        const busy = _client.busy();
        _sendButton.setText(busy ? "Stop" : "Send");
        _sendButton.setAccent(!busy);
    }

    // -- context usage meter ---------------------------------------------

    /// Recompute the toolbar context badge from the current session's latest
    /// assistant reply that carries API-reported usage.
    private void refreshUsageBadge()
    {
        if (_usageBadge is null) return;
        _usageBadge.setModel(_settings.model);
        int prompt = -1, completion = -1, total = -1;
        if (_current >= 0)
        {
            auto session = &_sessions[_current];
            for (int index = cast(int) session.messages.length - 1;
                index >= 0; --index)
            {
                auto message = &session.messages[cast(size_t) index];
                if (message.role == "assistant" && message.totalTokens > 0)
                {
                    prompt = message.promptTokens;
                    completion = message.completionTokens;
                    total = message.totalTokens;
                    break;
                }
            }
        }
        _usageBadge.setUsage(prompt, completion, total);
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
            rows ~= "Used: " ~ formatThousands(_usageBadge.totalTokens()) ~
                " tokens (" ~ to!string(_usageBadge.usagePercent()) ~ "%)";
            rows ~= "Prompt: " ~ formatThousands(_usageBadge.promptTokens()) ~
                " tokens";
            rows ~= "Completion: " ~
                formatThousands(_usageBadge.completionTokens()) ~ " tokens";
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

    /// Position a generic tooltip under its anchor, clamped to the window.
    private void positionTooltip(Widget anchor, HoverTooltip tooltip)
    {
        const origin = anchor.localToGlobal(Point(0, 0));
        const anchorRect = Rect(origin.x, origin.y, anchor.bounds().width,
            anchor.bounds().height);
        const measured = tooltip.measure(Size(int.max, int.max));
        const gap = 6;
        int x = anchorRect.x;
        int y = anchorRect.bottom() + gap;
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
        int y = anchor.bottom() + gap;
        x = clampInt(x, 8, maxInt(8, bounds().width - measured.width - 8));
        y = clampInt(y, 8, maxInt(8, bounds().height - measured.height - 8));
        _usageTooltip.setBounds(Rect(x, y, measured.width, measured.height));
    }

    private void updateSessionList(bool revealCurrent = true)
    {
        ListItem[] items;
        int[] indices;
        foreach (index, session; _sessions)
        {
            const title = session.title.length > 0 ? session.title : "New chat";
            if (_filterText.length > 0 &&
                !canFind(title.toLower(), _filterText.toLower()))
                continue;
            indices ~= cast(int) index;
            const secondary = session.messages.length == 0
                ? session.model
                : session.model ~ " • " ~ to!string(session.messages.length) ~ " msgs";
            items ~= ListItem(title, IconKind.terminal, secondary);
        }
        _sessionIndices = indices;
        _sessionList.setItems(items);
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
        _sessions = _sessions[0 .. sessionIndex] ~
            _sessions[sessionIndex + 1 .. $];
        if (_current == sessionIndex)
            _current = _sessions.length > 0
                ? minInt(sessionIndex, cast(int) _sessions.length - 1)
                : -1;
        else if (_current > sessionIndex)
            --_current;
        _streamBubble = null;
        rebuildMessageColumn();
        updateSessionList();
        markDirty();
        updateStatus(_sessions.length == 0 ? "No conversations yet." : "");
        refreshUsageBadge();
    }

    private void showMessageContextMenu(int messageIndex, Point globalPosition)
    {
        if (_current < 0) return;
        auto session = &_sessions[_current];
        if (messageIndex < 0 || messageIndex >= cast(int) session.messages.length)
            return;
        const message = session.messages[cast(size_t) messageIndex];
        auto items = [
            ContextMenuItem.command("Copy message", IconKind.save, delegate()
            {
                copyTextToClipboard(message.content);
            }, "Ctrl+C"),
        ];
        if (message.role == "assistant")
        {
            items ~= ContextMenuItem.command(
                message.failed ? "Retry" : "Regenerate",
                IconKind.refresh, delegate()
                {
                    regenerateLastReply(_current, messageIndex);
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

    private void showRenameSession(int sessionIndex)
    {
        if (sessionIndex < 0 || sessionIndex >= cast(int) _sessions.length) return;
        if (_activePopup !is null) _activePopup.dismiss();

        auto content = new VBox(8, Insets(14));
        content.layoutHints().preferredWidth = 360;
        auto title = content.add(new Label("Rename conversation"));
        title.setScale(3);
        auto field = content.add(new TextField(_sessions[sessionIndex].title));
        field.setId("oc-rename-field");
        field.layoutHints().preferredHeight = 34;
        auto footer = new HBox(8);
        footer.layoutHints().preferredHeight = 42;
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
        foreach (message; session.messages)
        {
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
        persistState();
    }

    private void saveSettingsNow()
    {
        saveSettings(_settings);
    }

    private void persistState()
    {
        saveSettings(_settings);
        ensureStateDirectory();
        JSONValue root;
        JSONValue list = JSONValue(string[].init);
        foreach (session; _sessions)
            list.array ~= sessionToJson(session);
        root["sessions"] = list;
        root["current"] = _current;
        try write(buildPath(opencodeStateDirectory(), "sessions.json"),
            root.toString());
        catch (Exception error)
        {
            logError("persist sessions failed: " ~ error.msg);
        }
    }

    private static JSONValue sessionToJson(const ref ChatSession session)
    {
        JSONValue root;
        root["title"] = session.title;
        root["model"] = session.model;
        root["thinking"] = session.thinking;
        JSONValue messages = JSONValue(string[].init);
        foreach (message; session.messages)
        {
            JSONValue messageJson;
            messageJson["role"] = message.role;
            messageJson["content"] = message.content;
            if (message.reasoning.length > 0)
                messageJson["reasoning"] = message.reasoning;
            if (message.time.length > 0)
                messageJson["time"] = message.time;
            if (message.failed)
                messageJson["failed"] = true;
            if (message.totalTokens > 0)
            {
                messageJson["promptTokens"] = message.promptTokens;
                messageJson["completionTokens"] = message.completionTokens;
                messageJson["totalTokens"] = message.totalTokens;
            }
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
            messages.array ~= messageJson;
        }
        root["messages"] = messages;
        return root;
    }

    private void restoreSessions()
    {
        _sessions.length = 0;
        const path = buildPath(opencodeStateDirectory(), "sessions.json");
        if (!exists(path)) return;
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type != JSONType.object) return;
            if (auto found = "sessions" in value.object)
            {
                if (found.type == JSONType.array)
                {
                    foreach (sessionValue; found.array)
                    {
                        if (sessionValue.type != JSONType.object) continue;
                        ChatSession session;
                        if (auto field = "title" in sessionValue.object)
                            session.title = field.str;
                        if (auto field = "model" in sessionValue.object)
                            session.model = field.str;
                        if (auto field = "thinking" in sessionValue.object)
                            session.thinking = field.type == JSONType.true_;
                        if (auto field = "messages" in sessionValue.object)
                        {
                            if (field.type == JSONType.array)
                            {
                                foreach (messageValue; field.array)
                                {
                                    if (messageValue.type != JSONType.object)
                                        continue;
                                    ChatMessage message;
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
                                    if (auto f = "promptTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.promptTokens = cast(int) f.integer;
                                    if (auto f = "completionTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.completionTokens = cast(int) f.integer;
                                    if (auto f = "totalTokens" in messageValue.object)
                                        if (f.type == JSONType.integer)
                                            message.totalTokens = cast(int) f.integer;
                                    if (auto f = "toolCallId" in messageValue.object)
                                        message.toolCallId = f.str;
                                    if (auto f = "toolName" in messageValue.object)
                                        message.toolName = f.str;
                                    if (auto f = "toolArgs" in messageValue.object)
                                        message.toolArgs = f.str;
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
                        _sessions ~= session;
                    }
                }
            }
            if (auto found = "current" in value.object)
            {
                const index = cast(int) found.integer;
                if (index >= 0 && index < cast(int) _sessions.length)
                    _current = index;
            }
            if (_sessions.length > 0)
            {
                if (_current < 0) _current = 0;
                _settings.model = _sessions[_current].model;
                _settings.thinking = _sessions[_current].thinking;
                _modelButton.setText(_settings.model);
                _thinkingBox.setChecked(_settings.thinking, false);
                rebuildMessageColumn();
            }
            refreshUsageBadge();
        }
        catch (Exception error)
        {
            logError("restore sessions failed: " ~ error.msg);
            _sessions.length = 0;
            _current = -1;
        }
    }

    // -- tick -------------------------------------------------------------

    protected override void onTick(double deltaSeconds)
    {
        OpenCodeEvent[] events;
        _client.drain(events);
        foreach (event; events)
        {
            final switch (event.kind)
            {
                case OpenCodeEventKind.chatBegin:
                    beginAssistantMessage();
                    break;
                case OpenCodeEventKind.delta:
                    appendStreamDelta(event.text, event.reasoning);
                    break;
                case OpenCodeEventKind.usage:
                    // The provider reports live token usage while streaming;
                    // surface it on the growing reply and the context meter.
                    // The stream bubble is always the latest assistant reply.
                    if (_streamBubble !is null && event.totalTokens > 0)
                        _streamBubble.setUsageText(
                            " • " ~ formatThousands(event.totalTokens) ~
                            " tokens");
                    if (_usageBadge !is null)
                    {
                        _usageBadge.setUsage(event.promptTokens,
                            event.completionTokens, event.totalTokens);
                        refreshContextUsageTooltip();
                    }
                    break;
                case OpenCodeEventKind.toolCalls:
                    handleToolCalls(event);
                    break;
                case OpenCodeEventKind.toolResult:
                    applyToolResult(event);
                    break;
                case OpenCodeEventKind.done:
                    finishAssistantMessage(event.cancelled, event.promptTokens,
                        event.completionTokens, event.totalTokens);
                    break;
                case OpenCodeEventKind.error:
                    failAssistantMessage(event.text);
                    break;
                case OpenCodeEventKind.models:
                    applyModels(event.modelIds);
                    break;
            }
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

        updateSendButton();
    }

    override bool onKeyDown(ref Event event)
    {
        if ((event.control() || event.meta()) && event.key == Key.n)
        {
            newChat();
            return true;
        }
        return false;
    }

    // -- test accessors ---------------------------------------------------

    /// Test-only: full text of the latest assistant message in the current session.
    public string lastAssistantContentForTesting()
    {
        if (_current < 0 || _sessions[_current].messages.length == 0) return "";
        return _sessions[_current].messages[$ - 1].content;
    }

    /// Test-only: number of persisted chat sessions.
    public size_t sessionCountForTesting() const
    {
        return _sessions.length;
    }

    /// Test-only: title of a session.
    public string sessionTitleForTesting(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return "";
        return _sessions[index].title;
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
            session.messages ~= message;
        }
        rebuildMessageColumn();
    }

    /// Test-only: number of text shapes performed by message bubbles.
    public size_t bubbleShapeCountForTesting() const
    {
        return MessageBubble.shapeCount;
    }

    /// Test-only: message count of the current session.
    public int messageCountForTesting()
    {
        if (_current < 0) return 0;
        return cast(int) _sessions[_current].messages.length;
    }

    /// Test-only: role of the message at `index`.
    public string messageRoleForTesting(int index)
    {
        if (_current < 0) return "";
        if (index < 0 || index >= cast(int) _sessions[_current].messages.length)
            return "";
        return _sessions[_current].messages[cast(size_t) index].role;
    }

    /// Test-only: invoke the action pill on the bubble at `index` exactly as a
    /// mouse click would, exercising the real delegate captured for that
    /// bubble (regression: foreach closures must not all target the last
    /// message).
    public bool invokeBubbleActionForTesting(int index)
    {
        const children = _messageColumn.children();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.invokeActionForTesting();
    }

    /// Test-only: open the right-click context menu for the message at
    /// `index`, exactly as a right-click on that bubble would.
    public void openMessageContextMenuForTesting(int index)
    {
        showMessageContextMenu(index, Point(10, 10));
    }

    /// Test-only: feed a usage event as the client would while streaming.
    public void feedUsageForTesting(int prompt, int completion, int total)
    {
        OpenCodeEvent event;
        event.kind = OpenCodeEventKind.usage;
        event.promptTokens = prompt;
        event.completionTokens = completion;
        event.totalTokens = total;
        if (_streamBubble !is null)
            _streamBubble.setUsageText(" • " ~ formatThousands(total) ~
                " tokens");
    }

    /// Test-only: whether the bubble at `index` shows token usage text.
    public bool bubbleHasUsageForTesting(int index)
    {
        const children = _messageColumn.children();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.usageTextForTesting().length > 0;
    }

    /// Test-only: whether the bubble at `index` is hidden (zero-size slot).
    public bool bubbleHiddenForTesting(int index)
    {
        const children = _messageColumn.children();
        if (index < 0 || index >= cast(int) children.length) return false;
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble !is null && bubble.hiddenForTesting();
    }

    /// Test-only: the current laid-out height of the bubble at `index`.
    public int bubbleHeightForTesting(int index)
    {
        const children = _messageColumn.children();
        if (index < 0 || index >= cast(int) children.length) return 0;
        return children[cast(size_t) index].bounds().height;
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

    /// Test-only: true when the last assistant reply was removed in
    /// preparation for a regenerate.
    public bool prepareRegenerateForTesting()
    {
        if (_current < 0) return false;
        return prepareRegenerate(_current,
            cast(int) _sessions[_current].messages.length - 1);
    }

    /// Test-only: action-pill label on the last bubble ("" when none).
    public string lastBubbleActionForTesting()
    {
        const children = _messageColumn.children();
        if (children.length == 0) return "";
        auto bubble = cast(MessageBubble) children[$ - 1];
        return bubble is null ? "" : bubble.actionLabelForTesting();
    }

    /// Test-only: action-pill label on the bubble at `index`.
    public string bubbleActionForTesting(int index)
    {
        const children = _messageColumn.children();
        if (index < 0 || index >= cast(int) children.length) return "";
        auto bubble = cast(MessageBubble) children[cast(size_t) index];
        return bubble is null ? "" : bubble.actionLabelForTesting();
    }

    /// Test-only: record API-reported usage on the current session's last
    /// message and refresh the toolbar context meter (mirrors the done/usage
    /// events without any network activity).
    public void recordContextUsageForTesting(int prompt, int completion, int total)
    {
        if (_current >= 0 && _sessions[_current].messages.length > 0)
        {
            auto message = &_sessions[_current].messages[$ - 1];
            message.promptTokens = prompt;
            message.completionTokens = completion;
            message.totalTokens = total;
        }
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

    /// Test-only: enable tools and set the workspace directory they run in.
    public void enableToolsForTesting(string workspace)
    {
        _settings.toolsEnabled = true;
        _settings.workspace = workspace;
        if (_toolsBox !is null) _toolsBox.setChecked(true, false);
    }

    /// Test-only: start a fresh conversation (used by tool-loop tests).
    public void newChatForTesting()
    {
        newChat();
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

    /// Test-only: the current doom-loop repeat count for the last tool call.
    public int toolRepeatCountForTesting()
    {
        return _lastToolRepeatCount;
    }

    /// Test-only: number of `user` role messages (used to detect the injected
    /// doom-loop recovery message).
    public int userMessageCountForTesting()
    {
        if (_current < 0) return 0;
        int count;
        foreach (message; _sessions[_current].messages)
            if (message.role == "user") ++count;
        return count;
    }

    /// Test-only: number of `tool` role messages in the current session.
    public int toolMessageCountForTesting()
    {
        if (_current < 0) return 0;
        int count;
        foreach (message; _sessions[_current].messages)
            if (message.role == "tool") ++count;
        return count;
    }

    /// Test-only: content of the last `tool` role message ("" when none).
    public string lastToolResultForTesting()
    {
        if (_current < 0) return "";
        auto session = &_sessions[_current];
        foreach_reverse (message; session.messages)
        {
            if (message.role == "tool") return message.content;
        }
        return "";
    }

    /// Test-only: content of the `tool` role message at index `n` ("" when
    /// there is no such tool message).
    public string toolResultForTesting(int n)
    {
        if (_current < 0) return "";
        int seen;
        foreach (message; _sessions[_current].messages)
        {
            if (message.role != "tool") continue;
            if (seen == n) return message.content;
            ++seen;
        }
        return "";
    }

    /// Test-only: whether the first `tool` result bubble is currently
    /// collapsed (tool outputs start collapsed by default).
    public bool firstToolBubbleCollapsedForTesting()
    {
        const children = _messageColumn.children();
        foreach (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "tool") continue;
            return bubble.collapsedForTesting();
        }
        return false;
    }

    /// Test-only: the message scroll view's current scroll offset.
    public int scrollYForTesting()
    {
        return _messagesScroll.scrollY();
    }

    /// Test-only: scroll the message view to a specific offset.
    public void scrollToForTesting(int value)
    {
        _messagesScroll.setScrollY(value);
    }

    /// Test-only: whether the last assistant bubble's thinking block is
    /// currently collapsed (thinking starts collapsed by default).
    public bool lastThinkingCollapsedForTesting()
    {
        const children = _messageColumn.children();
        foreach_reverse (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "assistant") continue;
            return bubble.thinkingCollapsedForTesting();
        }
        return false;
    }

    /// Test-only: toggle the last assistant bubble's thinking block.
    public void toggleLastThinkingForTesting()
    {
        const children = _messageColumn.children();
        foreach_reverse (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "assistant") continue;
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
        const children = _messageColumn.children();
        foreach (child; children)
        {
            auto bubble = cast(MessageBubble) child;
            if (bubble is null) continue;
            if (bubble.roleForTesting() != "tool") continue;
            bubble.toggleCollapseForTesting();
            _messageColumn.invalidate();
            _messagesScroll.invalidate();
            return;
        }
    }
}

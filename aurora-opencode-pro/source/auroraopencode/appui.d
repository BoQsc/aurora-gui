module auroraopencode.appui;

import aurora;
import auroraopencode.core;
import auroraopencode.markdown : MarkdownBlock, MdComposition, MdItemKind,
    composeMarkdownInto, paintMarkdown, parseMarkdown;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
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

    /// Diagnostic: total number of text shapes performed by all bubbles.
    static __gshared size_t shapeCount;

    void setRole(string role)
    {
        _role = role;
        invalidate();
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
        const innerWidth = maxInt(24, available.width - 2 * padH);
        const pixelSize = fontPixelSize(2);
        int height = 2 * padV;
        if (_thinking.length > 0)
            height += shapedThinking(innerWidth).measuredSize().height + gap;
        if (_role == "assistant")
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
        if (_time.length > 0 || _usageText.length > 0)
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
            auto layout = shapedThinking(innerWidth);
            canvas.drawLayout(Point(padH, y), layout, opencodeThinkingText);
            y += layout.measuredSize().height + gap;
        }

        _copyRects.length = 0;
        _copyLabels.length = 0;
        _linkRects.length = 0;
        _linkUrls.length = 0;

        const contentY = y;

        if (_content.length > 0 || _streaming)
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

        addMessageCopyTarget(width);
        foreach (index; 0 .. _copyRects.length)
        {
            if (_copyLabels[index].length == 0) continue;
            drawCopyPill(canvas, _copyRects[index],
                _hoverCopy == cast(int) index);
        }
        drawFooter(canvas, width, height);
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

    private void addMessageCopyTarget(int width)
    {
        _copyRects ~= Rect(width - padH - 40, 5, 40, 18);
        _copyLabels ~= to!string(_content);
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
        if (nextCopy != _hoverCopy || nextLink != _hoverLink)
        {
            _hoverCopy = nextCopy;
            _hoverLink = nextLink;
            setCursor(nextCopy >= 0 || nextLink >= 0 ?
                CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        return false;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
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
        if (_hoverCopy != -1 || _hoverLink != -1)
        {
            _hoverCopy = -1;
            _hoverLink = -1;
            setCursor(CursorKind.arrow);
            invalidate();
        }
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
    private Label _keyBadge;
    private Label _status;
    private TextField _filterField;
    private int[] _sessionIndices;
    private string _filterText;
    private string _lastUsageText;

    private MessageBubble _streamBubble;
    private PopupOverlay _activePopup;

    private MonoTime _chatStartedAt;
    private bool _receivedFirstDelta;
    private int _lastColdStartSeconds = -1;

    this(GuiWindow window)
    {
        super(0);
        _window = window;
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

        _thinkingBox = toolbar.add(new CheckBox("Thinking"));
        _thinkingBox.setId("oc-thinking");
        _thinkingBox.setChecked(_settings.thinking, false);
        _thinkingBox.onChanged = delegate(bool value)
        {
            _settings.thinking = value;
            if (_current >= 0) _sessions[_current].thinking = value;
            saveSettingsNow();
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
        _filterText = "";
        if (_filterField !is null) _filterField.setText("", false);
        rebuildMessageColumn();
        updateSessionList();
        markDirty();
        _input.requestFocus();
        updateStatus("New conversation. Ask away!");
    }

    private void selectSession(int index)
    {
        if (index < 0 || index >= cast(int) _sessions.length) return;
        _current = index;
        _streamBubble = null;
        rebuildMessageColumn();
        _settings.model = _sessions[index].model;
        _settings.thinking = _sessions[index].thinking;
        _modelButton.setText(_settings.model);
        _thinkingBox.setChecked(_settings.thinking, false);
        markDirty();
        updateStatus("");
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
        foreach (message; session.messages)
        {
            auto bubble = new MessageBubble();
            bubble.setRole(message.role);
            bubble.setContent(message.content);
            if (message.reasoning.length > 0)
                bubble.setThinking(message.reasoning);
            if (message.time.length > 0)
                bubble.setTime(message.time);
            _messageColumn.add(bubble);
        }
        _messagesScroll.follow = true;
        _messageColumn.invalidate();
        // The column is a retained layer; let the ScrollView re-measure and
        // update the content height / auto-follow after the message set changes.
        _messagesScroll.invalidate();
    }

    private void addUserBubble(string text)
    {
        auto bubble = new MessageBubble();
        bubble.setRole("user");
        bubble.setContent(text);
        _messageColumn.add(bubble);
        _messagesScroll.follow = true;
        _messagesScroll.invalidate();
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
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        if (_current >= 0 && _sessions[_current].messages.length > 0)
        {
            auto message = &_sessions[_current].messages[$ - 1];
            if (message.time.length == 0) message.time = currentTimestamp();
        }
        string status = cancelled ? "Stopped." : "Done.";
        if (!cancelled && totalTokens > 0)
        {
            _lastUsageText = " • " ~ formatThousands(totalTokens) ~ " tokens";
            status ~= _lastUsageText;
        }
        updateStatus(status);
        _messagesScroll.invalidate();
        markDirty();
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

        string[] roles;
        string[] contents;
        foreach (message; session.messages)
        {
            roles ~= message.role;
            contents ~= message.content;
        }

        _client.startChat(roles, contents, _settings.model, _settings.thinking);
        _chatStartedAt = MonoTime.currTime;
        _receivedFirstDelta = false;
        _lastColdStartSeconds = -1;
        markDirty();
        updateStatus("Generating…");
        updateSendButton();
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
            if (baseUrl.length > 0) _settings.baseUrl = baseUrl;
            _settings.apiKey = apiKey;
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
        content.add(footer);

        auto popup = new PopupOverlay(content, this);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(540, 300));
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
            builder.put("## " ~ (message.role == "user" ? "User" : "Assistant"));
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
        catch (Exception) {}
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
        }
        catch (Exception)
        {
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
        if (_current < 0) newChat();
        auto session = &_sessions[_current];
        foreach (index; 0 .. roles.length)
        {
            ChatMessage message;
            message.role = roles[index];
            message.content = contents[index];
            session.messages ~= message;
        }
        rebuildMessageColumn();
    }

    /// Test-only: number of text shapes performed by message bubbles.
    public size_t bubbleShapeCountForTesting() const
    {
        return MessageBubble.shapeCount;
    }
}

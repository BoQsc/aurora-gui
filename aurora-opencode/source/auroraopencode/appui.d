module auroraopencode.appui;

import aurora;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import core.time : msecs;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : format, strip;
import std.utf : toUTF32;

// ---------------------------------------------------------------------------
// Aurora OpenCode - a lightweight desktop chat client for the OpenAI
// compatible opencode API, built with Aurora-D. Mirror of the web proxy at
// https://opencode-api.boqsc.eu/go/v1 (Go plan) / /v1 (Zen plan).
// ---------------------------------------------------------------------------

private immutable string defaultBaseUrl = "https://opencode-api.boqsc.eu/go/v1";
private immutable string defaultModel = "deepseek-v4-flash";

private immutable string[] defaultModels = [
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "gpt-5.6-luna",
    "qwen3.8-max",
    "glm-5.2",
    "grok-4.5",
    "kimi-k3",
    "minimax-m3",
    "mimo-v2.5-pro",
    "hy3"
];

private immutable string[] defaultKeyFileCandidates = [
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode-api/data/key.txt",
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode/data/arena/key.txt"
];

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

private immutable Color opencodeBackground = Color.fromHex(0x111114);
private immutable Color opencodePanel = Color.fromHex(0x16161b);
private immutable Color opencodeElevated = Color.fromHex(0x1c1c23);
private immutable Color opencodeField = Color.fromHex(0x202028);
private immutable Color opencodeBorder = Color.fromHex(0x33333d);
private immutable Color opencodeText = Color.fromHex(0xe8e8ec);
private immutable Color opencodeMuted = Color.fromHex(0x9a9aa5);
private immutable Color opencodeAccent = Color.fromHex(0x8b7cf6);
private immutable Color opencodeSelection = Color.fromHex(0x2b2b36);
private immutable Color opencodePressed = Color.fromHex(0x2f2f3b);
private immutable Color opencodeUserBubble = Color.fromHex(0x2a2f45);
private immutable Color opencodeAssistantBubble = Color.fromHex(0x1f1f27);
private immutable Color opencodeThinkingText = Color.fromHex(0x8d8d99);
private immutable Color opencodeErrorRed = Color.fromHex(0xff6b6b);
private immutable Color opencodeKeyOk = Color.fromHex(0x6fd08c);
private immutable Color opencodeKeyMissing = Color.fromHex(0xffa94d);

public Theme opencodeTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = opencodeBackground;
    theme.panelBackground = opencodePanel;
    theme.panelElevated = opencodeElevated;
    theme.text = opencodeText;
    theme.textMuted = opencodeMuted;
    theme.border = opencodeBorder;
    theme.accent = opencodeAccent;
    theme.selection = opencodeSelection;
    theme.selectionText = opencodeText;
    theme.fieldBackground = opencodeField;
    theme.buttonBackground = opencodeField;
    theme.buttonHover = opencodeSelection;
    theme.buttonPressed = opencodePressed;
    theme.cornerRadius = 8;
    theme.controlHeight = 38;
    return theme;
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

private struct ChatMessage
{
    string role;       // "user" | "assistant"
    string content;
    string reasoning;
}

private struct ChatSession
{
    string title;
    string model;
    bool thinking;
    ChatMessage[] messages;
}

private struct Settings
{
    string baseUrl = defaultBaseUrl;
    string apiKey = "";
    string model = defaultModel;
    bool thinking;
}

private __gshared string stateDirectoryOverride;

/// Test-only: redirect persistence to an isolated directory.
public void setOpencodeStateDirectoryForTesting(string path)
{
    stateDirectoryOverride = path;
}

private string opencodeStateDirectory()
{
    if (stateDirectoryOverride.length > 0) return stateDirectoryOverride;
    const appData = environment.get("APPDATA");
    const base = appData.length > 0 ? appData : ".";
    return buildPath(base, "Aurora OpenCode");
}

private void ensureStateDirectory()
{
    const directory = opencodeStateDirectory();
    if (!exists(directory)) mkdirRecurse(directory);
}

private string readDefaultKeyFile()
{
    foreach (candidate; defaultKeyFileCandidates)
    {
        try
        {
            if (!exists(candidate)) continue;
            const value = readText(candidate).strip();
            if (value.length > 0) return value;
        }
        catch (Exception) {}
    }
    return "";
}

private Settings loadSettings()
{
    Settings settings;
    const path = buildPath(opencodeStateDirectory(), "settings.json");
    if (exists(path))
    {
        try
        {
            auto value = parseJSON(readText(path));
            if (value.type == JSONType.object)
            {
                if (auto found = "baseUrl" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.baseUrl = found.str;
                if (auto found = "apiKey" in value.object)
                    if (found.type == JSONType.string)
                        settings.apiKey = found.str;
                if (auto found = "model" in value.object)
                    if (found.type == JSONType.string && found.str.length > 0)
                        settings.model = found.str;
                if (auto found = "thinking" in value.object)
                    if (found.type == JSONType.true_ || found.type == JSONType.false_)
                        settings.thinking = found.type == JSONType.true_;
            }
        }
        catch (Exception) {}
    }
    if (settings.apiKey.length == 0)
        settings.apiKey = environment.get("OPENCODE_API_KEY");
    if (settings.apiKey.length == 0)
        settings.apiKey = readDefaultKeyFile();
    if (settings.model.length == 0) settings.model = defaultModel;
    return settings;
}

private void saveSettings(const ref Settings settings)
{
    ensureStateDirectory();
    JSONValue root;
    root["baseUrl"] = settings.baseUrl;
    root["apiKey"] = settings.apiKey;
    root["model"] = settings.model;
    root["thinking"] = settings.thinking;
    try write(buildPath(opencodeStateDirectory(), "settings.json"),
        root.toString());
    catch (Exception) {}
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
        if (_streaming) display ~= "▌"d;
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
        if (_content.length > 0)
            height += shapedContent(innerWidth).measuredSize().height;
        else if (_streaming)
            height += pixelSize + 2;
        if (_failed)
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

        if (_content.length > 0 || _streaming)
        {
            auto layout = shapedContent(innerWidth);
            canvas.drawLayout(Point(padH, y), layout,
                _role == "user" ? opencodeText : palette.text);
        }

        if (_failed && _error.length > 0)
        {
            auto layout = canvas.layoutText(toUTF32(_error), 1, FontRole.ui,
                cast(FontFace) palette.uiFont, innerWidth, true);
            canvas.drawLayout(Point(padH, y + 4), layout, opencodeErrorRed);
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

    override void setScrollY(int value)
    {
        super.setScrollY(value);
        // Any user scroll (thumb drag, track click, wheel, keys) moves away
        // from the auto-follow position. Re-engage follow only once the view
        // is back at the bottom; otherwise onLayout keeps snapping the
        // scrollbar back down and the user cannot scroll up at all.
        follow = scrollY() >= maxScroll() - 4;
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

    private ListView _sessionList;
    private ChatScrollView _messagesScroll;
    private VBox _messageColumn;
    private ChatInput _input;
    private Button _sendButton;
    private Button _modelButton;
    private CheckBox _thinkingBox;
    private Label _keyBadge;
    private Label _status;

    private MessageBubble _streamBubble;
    private PopupOverlay _activePopup;

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        _settings = loadSettings();
        _client = new OpenCodeClient(_settings.baseUrl, _settings.apiKey);
        buildUi();
        restoreSessions();
        updateSessionList();
        updateKeyBadge();
        updateSendButton();
        _client.fetchModels();
        _input.requestFocus();
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
        _sessionList = sidebar.add(new ListView());
        _sessionList.setId("oc-sessions");
        _sessionList.layoutHints().flex = 1.0;
        _sessionList.onSelectionChanged = delegate(int index)
        {
            selectSession(index);
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

    private void finishAssistantMessage(bool cancelled)
    {
        if (_streamBubble !is null)
        {
            _streamBubble.setStreaming(false);
            _streamBubble = null;
        }
        updateStatus(cancelled ? "Stopped." : "Done.");
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

    private void updateSessionList()
    {
        ListItem[] items;
        foreach (session; _sessions)
        {
            const title = session.title.length > 0 ? session.title : "New chat";
            const secondary = session.messages.length == 0
                ? session.model
                : session.model ~ " • " ~ to!string(session.messages.length) ~ " msgs";
            items ~= ListItem(title, IconKind.terminal, secondary);
        }
        _sessionList.setItems(items);
        if (_current >= 0)
            _sessionList.setSelectedIndex(_current, false);
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
    {        OpenCodeEvent[] events;
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
                    finishAssistantMessage(event.cancelled);
                    break;
                case OpenCodeEventKind.error:
                    failAssistantMessage(event.text);
                    break;
                case OpenCodeEventKind.models:
                    applyModels(event.modelIds);
                    break;
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


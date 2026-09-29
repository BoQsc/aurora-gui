module auroraopencode.minichat;

// ===========================================================================
// Optional floating mini chat.
//
// A small always-on-top, frameless overlay that shows the last few messages of
// the current conversation plus a one-line input, so the user can read and
// steer while a fullscreen game keeps focus (Alt-Tabbing can crash an
// exclusive-fullscreen game). OFF by default; the Settings dialog owns the
// `Settings.floatingMiniChat` switch. Per-frame history length comes from
// `Settings.floatingMiniChatLines`.
//
// Threading: a second GuiWindow owns its own Win32 message loop, and a Win32
// window is thread-affine, so the overlay is created and run on a dedicated
// thread. The two threads never touch each other's widgets:
//   * UI thread -> overlay: `publishMessages` stores an immutable snapshot
//     under a mutex; the overlay thread reads it on its own tick (`drain`).
//   * overlay -> UI thread: `publishPrompt` stores a pending prompt; the main
//     window's onTick drains it with `takePrompt` and submits it.
// To drop the feature: delete this file, the `floatingMiniChat*` Settings, the
// `minichat` hooks in appui.d, and the `noActivate` option in the aurora
// WindowOptions. Nothing else references it.
// ===========================================================================

import aurora;
import auroraopencode.core : opencodeAccent, opencodeBorder, opencodeMuted,
    opencodePanel, opencodeText, opencodeTheme;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.string : strip;
import std.utf : toUTF8;

/// One line shown in the mini chat: a role ("user"/"assistant") and text.
public struct MiniChatLine
{
    string role;
    string text;
}

/// Collapse a message body to a single trimmed display line, capped at `limit`
/// visible characters (a trailing ellipsis marks the cut). Newlines, tabs and
/// runs of spaces collapse to one space so a multi-line reply still reads on a
/// thin overlay row.
public string miniChatOneLine(string raw, int limit = 200)
{
    dstring text;
    bool pendingSpace;
    foreach (dchar ch; raw)
    {
        if (ch == '\n' || ch == '\r' || ch == '\t' || ch == ' ' ||
            ch == '\u00a0')
        {
            if (text.length > 0) pendingSpace = true;
            continue;
        }
        if (pendingSpace)
        {
            text ~= ' ';
            pendingSpace = false;
        }
        text ~= ch;
        if (limit > 0 && text.length >= limit)
        {
            text ~= '…';
            break;
        }
    }
    return toUTF8(text);
}

unittest
{
    assert(miniChatOneLine("  hello   world  ") == "hello world");
    assert(miniChatOneLine("line one\nline two") == "line one line two");
    assert(miniChatOneLine("a\t\tb") == "a b");
    assert(miniChatOneLine("") == "");
    assert(miniChatOneLine("   ") == "");
    assert(miniChatOneLine("abcdefghij", 5) == "abcde…");
}

/// The overlay's own root widget. It is built and ticked only on the host's
/// dedicated thread, so it never reads another thread's state directly.
final class MiniChatOverlay : VBox
{
    private MiniChatHost _host;
    private GuiWindow _window;
    private VBox _messages;
    private TextField _input;
    private Button _send;

    /// Fired on the overlay thread when the user submits the input. The host
    /// stores the text and the main window's onTick consumes it.
    void delegate(string text) onSubmit;

    this(MiniChatHost host)
    {
        super(6, Insets(8));
        _host = host;
        setId("mini-root");
        setBackground(opencodePanel);
        setBorder(opencodeBorder, 10);
        layoutHints().flex = 1.0;

        // A real titlebar doubles as a drag handle (system move) and a Close
        // button, so the window can be moved/closed without a native frame.
        auto bar = new TitleBar();
        bar.setId("mini-titlebar");
        bar.setTitle("Aurora mini chat");
        bar.setShowIcon(false);
        bar.setShowMinimize(false);
        bar.setShowMaximize(false);
        bar.setShowClose(true);
        bar.setBarHeight(28);
        bar.setSystemMoveOnDrag(true);
        bar.setDoubleClickMaximizes(false);
        bar.setSnapEnabled(false);
        bar.onClose = delegate() { if (_window !is null) _window.close(); };
        add(bar);

        _messages = new VBox(4);
        _messages.setId("mini-messages");
        _messages.layoutHints().flex = 1.0;
        add(_messages);
        showEmpty();

        auto row = new HBox(6);
        row.setId("mini-input-row");
        _input = new TextField();
        _input.setId("mini-input");
        _input.layoutHints().flex = 1.0;
        _input.onSubmitted = &submit;
        row.add(_input);
        _send = new Button("Send");
        _send.setId("mini-send");
        _send.onClick = &submit;
        row.add(_send);
        add(row);
    }

    private void showEmpty()
    {
        auto empty = new Label("No messages yet.");
        empty.setColor(opencodeMuted);
        _messages.add(empty);
    }

    /// Bind the owning window so the titlebar Close button and the stop path
    /// can end the overlay. Set/cleared only on the overlay thread.
    void bindWindow(GuiWindow window)
    {
        _window = window;
    }

    private void submit()
    {
        const text = _input.textUtf8().strip();
        if (text.length == 0) return;
        _input.setText("");
        if (onSubmit !is null) onSubmit(text);
    }

    protected override void onTick(double deltaSeconds)
    {
        if (_host is null) return;
        _host.drain(this);
        if (_host.stopRequested() && _window !is null)
            _window.close();
    }

    /// Rebuild the message rows. Runs on the overlay thread only.
    void setMessages(MiniChatLine[] lines)
    {
        _messages.clearChildren();
        if (lines.length == 0)
        {
            showEmpty();
            return;
        }
        foreach (line; lines)
        {
            const isUser = line.role == "user";
            auto label = new Label((isUser ? "You  " : "AI  ") ~ line.text);
            label.setColor(isUser ? opencodeAccent : opencodeText);
            _messages.add(label);
        }
    }

    /// Test-only: the current input text.
    string inputTextForTesting() const
    {
        return _input is null ? "" : _input.textUtf8();
    }

    /// Test-only: replace the input text (bypassing keystrokes).
    void setInputForTesting(string text)
    {
        if (_input !is null) _input.setText(text);
    }

    /// Test-only: how many message labels are shown right now.
    size_t messageRowCountForTesting() const
    {
        return _messages is null ? 0 : _messages.children().length;
    }
}

/// Owns the overlay window, its thread, and the two cross-thread hand-offs.
final class MiniChatHost
{
    private Mutex _mutex;
    private Thread _thread;
    private MiniChatLine[] _pendingMessages;
    private bool _messagesDirty;
    private string _pendingPrompt;
    private bool _promptPending;
    private bool _stop;

    this()
    {
        _mutex = new Mutex();
    }

    /// Create the overlay window on its own thread and run its native loop.
    void start()
    {
        if (_thread !is null) return;
        _thread = new Thread(&threadMain);
        _thread.isDaemon = true;
        _thread.start();
    }

    /// Ask the overlay to close (on its own thread, at its next tick).
    void stop()
    {
        synchronized (_mutex) _stop = true;
    }

    private void threadMain()
    {
        auto overlay = new MiniChatOverlay(this);
        overlay.onSubmit = delegate(string text)
        {
            publishPrompt(text);
        };

        WindowOptions options;
        options.title = "Aurora mini chat";
        options.width = 340;
        options.height = 300;
        options.decorated = false;
        options.resizable = false;
        options.alwaysOnTop = true;
        // Never steal the foreground when it first appears.
        options.startNoActivate = true;
        // WS_EX_NOACTIVATE would also block the user from clicking into the
        // input to type, so the window stays activatable on an explicit click.
        options.noActivate = false;
        options.renderer = RendererPreference.software;
        options.vsync = false;
        options.lowLatency = false;
        options.extendedScrollInput = false;
        options.nativeVerticalScrollHost = false;
        options.enableFullscreenShortcut = false;

        auto window = new GuiWindow(options, opencodeTheme());
        overlay.bindWindow(window);
        window.setRoot(overlay);
        placeBottomRight(window);
        window.run();
        overlay.bindWindow(null);
    }

    /// Put the overlay in the bottom-right corner of the primary work area,
    /// inset by a small margin. Best-effort: on any failure the framework's
    /// default placement stands.
    private void placeBottomRight(GuiWindow window)
    {
        Rect bounds;
        Rect work;
        if (!window.queryWorkArea(Point(0, 0), work)) return;
        if (work.empty) return;
        if (!window.windowBounds(bounds)) return;
        const margin = 16;
        window.setWindowPosition(Point(work.right() - bounds.width - margin,
            work.bottom() - bounds.height - margin));
    }

    /// UI thread: replace the snapshot the overlay will render next tick.
    void publishMessages(MiniChatLine[] messages)
    {
        synchronized (_mutex)
        {
            _pendingMessages = messages.dup;
            _messagesDirty = true;
        }
    }

    /// Overlay thread: apply a new snapshot, if one is pending.
    void drain(MiniChatOverlay overlay)
    {
        MiniChatLine[] messages;
        bool have;
        synchronized (_mutex)
        {
            if (_messagesDirty)
            {
                _messagesDirty = false;
                messages = _pendingMessages;
                have = true;
            }
        }
        if (have) overlay.setMessages(messages);
    }

    private void publishPrompt(string text)
    {
        synchronized (_mutex)
        {
            _pendingPrompt = text;
            _promptPending = true;
        }
    }

    /// UI thread: take the pending overlay prompt exactly once.
    bool takePrompt(out string text)
    {
        synchronized (_mutex)
        {
            if (!_promptPending) return false;
            _promptPending = false;
            text = _pendingPrompt;
            _pendingPrompt = "";
            return true;
        }
    }

    bool stopRequested()
    {
        synchronized (_mutex) return _stop;
    }
}

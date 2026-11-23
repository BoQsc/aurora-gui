module opencodelite.controller;

import opencodelite.history : ConversationState, loadConversation, saveConversation;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, openAiBaseUrl, openAiModel,
    isOpenAiBaseUrl, isOpenCodeBaseUrl, openCodeBaseUrl, openCodeModel,
    saveSettings;
import std.conv : to;
import std.string : strip;

/// The small host-facing surface the controller needs. Implementations are the
/// embedded registry and an external host control client.
interface LiteView
{
    string text(string id);
    bool setText(string id, string text);
    bool setEnabled(string id, bool enabled);
}

/**
 * V2 is still host-rendered, but now owns a persistent conversation session,
 * explicit new-session/retry controls, and a richer session status.
 */
final class LiteController
{
    private LiteView _view;
    private ChatSession _session;
    private LiteSettings _settings;
    private string _transcript;
    private string _status = "Ready";
    private string _lastPrompt;
    private uint _messages;
    private bool _lastFailed;

    this(LiteView view, LiteSettings settings)
    {
        _view = view;
        _settings = settings;
        _session = new ChatSession(_settings);
        const history = loadConversation();
        _transcript = history.transcript;
        _messages = history.messages;
        _lastPrompt = history.lastPrompt;
        _lastFailed = history.failed;
    }

    void handleAction(string node, string action)
    {
        if (action == "send")
        {
            if (_session.busy())
                stop();
            else
                send();
        }
        else if (action == "stop")
            stop();
        else if (action == "save")
            saveConnection();
        else if (action == "clear")
            clearSession();
        else if (action == "retry")
            retryLast();
        else if (action == "preset-opencode")
            applyPreset(openCodeBaseUrl, openCodeModel, "OpenCode API preset");
        else if (action == "preset-openai")
            applyPreset(openAiBaseUrl, openAiModel,
                "OpenAI-compatible preset");
    }

    private void applyPreset(string baseUrl, string model, string label)
    {
        rememberKey();
        _settings.baseUrl = baseUrl;
        _settings.model = model;
        _settings.apiKey = isOpenCodeBaseUrl(baseUrl)
            ? _settings.openCodeKey
            : isOpenAiBaseUrl(baseUrl) ? _settings.openAiKey : "";
        _view.setText("lite-base", baseUrl);
        _view.setText("lite-model", model);
        _view.setText("lite-key", "");
        updateKeyState();
        setStatus(label);
    }

    private void rememberKey()
    {
        const entered = _view.text("lite-key").strip;
        if (entered.length > 0)
            _settings.apiKey = entered;
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeKey = _settings.apiKey;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiKey = _settings.apiKey;
    }

    private void saveConnection()
    {
        _settings.baseUrl = _view.text("lite-base").strip;
        _settings.model = _view.text("lite-model").strip;
        rememberKey();
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            _view.setText("lite-key", "");
            updateKeyState();
            setStatus("Settings saved");
        }
        catch (Exception error)
        {
            setStatus("Settings error: " ~ error.msg);
        }
    }

    private void send()
    {
        if (_session.busy())
            return;
        const prompt = _view.text("lite-input").strip;
        if (prompt.length == 0)
            return;
        saveConnection();
        _lastPrompt = prompt;
        _lastFailed = false;
        ++_messages;
        _transcript ~= "\nYou: " ~ prompt ~ "\nAssistant: ";
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        setStatus("Waiting for response...");
        _view.setText("lite-send", "Stop");
        updateSession();
        persist();
        _session.send(prompt);
    }

    private void retryLast()
    {
        if (_lastPrompt.length == 0 || _session.busy())
            return;
        _view.setText("lite-input", _lastPrompt);
        send();
    }

    private void clearSession()
    {
        if (_session.busy())
            _session.cancel();
        _transcript = "New session.\n";
        _lastPrompt = "";
        _lastFailed = false;
        _messages = 0;
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        _view.setText("lite-send", "Send");
        setStatus("Ready");
        updateSession();
        persist();
    }

    private void stop()
    {
        _session.cancel();
        setStatus("Stopping...");
    }

    void service(double deltaSeconds)
    {
        foreach (event; _session.drain())
        {
            switch (event.kind)
            {
                case SessionEventKind.delta:
                    _transcript ~= event.text;
                    _view.setText("lite-transcript", _transcript);
                    break;
                case SessionEventKind.done:
                    _transcript ~= event.text == "Stopped"
                        ? "\n[stopped]\n" : "\n";
                    _view.setText("lite-transcript", _transcript);
                    setStatus(event.text);
                    _view.setText("lite-send", "Send");
                    _lastFailed = false;
                    updateSession();
                    persist();
                    break;
                case SessionEventKind.failed:
                    _transcript ~= "\n[error] " ~ event.text ~ "\n";
                    _view.setText("lite-transcript", _transcript);
                    setStatus("Error");
                    _view.setText("lite-send", "Send");
                    _lastFailed = true;
                    updateSession();
                    persist();
                    break;
                default:
                    break;
            }
        }
    }

    /// Reapply controller-owned values after a scene reload or controller attach.
    void refreshView()
    {
        _view.setText("lite-base", _settings.baseUrl);
        _view.setText("lite-model", _settings.model);
        _view.setText("lite-key", "");
        updateKeyState();
        _view.setText("lite-transcript", _transcript);
        _view.setText("lite-send", _session.busy() ? "Stop" : "Send");
        setStatus(_status);
        updateSession();
    }

    private void updateSession()
    {
        _view.setText("lite-session",
            "Session - " ~ to!string(_messages) ~
            (_messages == 1 ? " message" : " messages"));
        _view.setEnabled("lite-retry", _lastFailed && !_session.busy());
    }

    private void persist()
    {
        try
        {
            ConversationState state;
            state.transcript = _transcript;
            state.messages = _messages;
            state.lastPrompt = _lastPrompt;
            state.failed = _lastFailed;
            saveConversation(state);
        }
        catch (Exception)
        {
            // The host remains usable even if the history file is unwritable.
        }
    }

    private void setStatus(string value)
    {
        _status = value;
        _view.setText("lite-status", value);
    }

    private void updateKeyState()
    {
        _view.setText("lite-key-state", _settings.apiKey.length > 0
            ? "Key set" : "No key");
    }
}

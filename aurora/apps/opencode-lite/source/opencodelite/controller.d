module opencodelite.controller;

import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, saveSettings;
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
 * Lite's entire GUI surface is host-owned. This controller owns only the
 * conversation/network/settings policy and updates host nodes by id.
 */
final class LiteController
{
    private LiteView _view;
    private ChatSession _session;
    private LiteSettings _settings;
    private string _transcript = "No conversation yet.\n";
    private string _status = "Ready";

    this(LiteView view, LiteSettings settings)
    {
        _view = view;
        _settings = settings;
        _session = new ChatSession(_settings);
    }

    void handleAction(string node, string action)
    {
        if (action == "send")
            send();
        else if (action == "stop")
            stop();
        else if (action == "save")
            saveConnection();
    }

    private void saveConnection()
    {
        _settings.baseUrl = _view.text("lite-base").strip;
        _settings.model = _view.text("lite-model").strip;
        _settings.apiKey = _view.text("lite-key").strip;
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
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
        _transcript ~= "\nYou: " ~ prompt ~ "\nAssistant: ";
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        setStatus("Waiting for response...");
        _view.setEnabled("lite-send", false);
        _view.setEnabled("lite-stop", true);
        _session.send(prompt);
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
                    _view.setEnabled("lite-send", true);
                    _view.setEnabled("lite-stop", false);
                    break;
                case SessionEventKind.failed:
                    _transcript ~= "\n[error] " ~ event.text ~ "\n";
                    _view.setText("lite-transcript", _transcript);
                    setStatus("Error");
                    _view.setEnabled("lite-send", true);
                    _view.setEnabled("lite-stop", false);
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
        _view.setText("lite-key", _settings.apiKey);
        _view.setText("lite-transcript", _transcript);
        setStatus(_status);
        _view.setEnabled("lite-send", !_session.busy());
        _view.setEnabled("lite-stop", _session.busy());
    }

    private void setStatus(string value)
    {
        _status = value;
        _view.setText("lite-status", value);
    }
}

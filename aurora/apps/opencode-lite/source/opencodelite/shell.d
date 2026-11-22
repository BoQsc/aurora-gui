module opencodelite.shell;

import aurora;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, loadSettings, saveSettings;
import std.string : strip;

/// The reusable chat panel. It can be the direct-window root or a host component.
final class LiteShell : VBox
{
    private ChatSession _session;
    private LiteSettings _settings;
    private TextArea _transcript;
    private TextArea _input;
    private TextField _baseUrl;
    private TextField _model;
    private TextField _apiKey;
    private Button _send;
    private Button _stop;
    private Label _status;
    private string _assistant;

    this()
    {
        super(8, Insets(14));
        _settings = loadSettings();
        _session = new ChatSession(_settings);

        auto heading = add(new Label("Aurora OpenCode Lite"));
        heading.setScale(2);
        heading.layoutHints().preferredHeight = 34;

        auto connection = add(new HBox(6));
        connection.layoutHints().preferredHeight = 32;
        auto baseLabel = connection.add(new Label("Base URL"));
        baseLabel.layoutHints().preferredWidth = 72;
        _baseUrl = connection.add(new TextField(_settings.baseUrl));
        _baseUrl.setPlaceholder("https://api.openai.com/v1");
        _baseUrl.layoutHints().flex = 1.0;
        auto modelLabel = connection.add(new Label("Model"));
        modelLabel.layoutHints().preferredWidth = 64;
        _model = connection.add(new TextField(_settings.model));
        _model.setPlaceholder("gpt-4o-mini");
        _model.layoutHints().preferredWidth = 180;

        auto credentials = add(new HBox(6));
        credentials.layoutHints().preferredHeight = 32;
        auto keyLabel = credentials.add(new Label("API key"));
        keyLabel.layoutHints().preferredWidth = 72;
        _apiKey = credentials.add(new TextField(_settings.apiKey));
        _apiKey.setPlaceholder("sk-...");
        _apiKey.layoutHints().flex = 1.0;
        auto save = credentials.add(new Button("Save"));
        save.onClick = &saveConnection;
        _status = credentials.add(new Label("Ready"));
        _status.layoutHints().preferredWidth = 160;

        _transcript = add(new TextArea("No conversation yet.\n"));
        _transcript.setReadOnly(true);
        _transcript.setWordWrap(true);
        _transcript.setPlaceholder("Conversation appears here");
        _transcript.layoutHints().flex = 1.0;

        _input = add(new TextArea(""));
        _input.setPlaceholder("Type a prompt and press Send");
        _input.setWordWrap(true);
        _input.layoutHints().preferredHeight = 92;

        auto actions = add(new HBox(8));
        actions.layoutHints().preferredHeight = 38;
        actions.add(new Spacer());
        _stop = actions.add(new Button("Stop"));
        _stop.setEnabled(false);
        _stop.onClick = &stopStream;
        _send = actions.add(new Button("Send"));
        _send.setAccent(true);
        _send.onClick = &sendPrompt;
    }

    private void saveConnection()
    {
        _settings.baseUrl = _baseUrl.textUtf8().strip;
        _settings.model = _model.textUtf8().strip;
        _settings.apiKey = _apiKey.textUtf8().strip;
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            _status.setText("Settings saved");
        }
        catch (Exception error)
        {
            _status.setText("Settings error: " ~ error.msg);
        }
    }

    private void sendPrompt()
    {
        if (_session.busy())
            return;
        const prompt = _input.textUtf8().strip;
        if (prompt.length == 0)
            return;
        saveConnection();
        _assistant = "";
        appendTranscript("\nYou: " ~ prompt ~ "\nAssistant: ");
        _input.setText("");
        _session.send(prompt);
        _send.setEnabled(false);
        _stop.setEnabled(true);
        _status.setText("Waiting for response...");
    }

    private void stopStream()
    {
        _session.cancel();
        _status.setText("Stopping...");
    }

    private void appendTranscript(string text)
    {
        _transcript.setText(_transcript.textUtf8() ~ text);
    }

    protected override void onTick(double deltaSeconds)
    {
        foreach (event; _session.drain())
        {
            switch (event.kind)
            {
                case SessionEventKind.delta:
                    _assistant ~= event.text;
                    appendTranscript(event.text);
                    break;
                case SessionEventKind.done:
                    appendTranscript(event.text == "Stopped"
                        ? "\n[stopped]\n" : "\n");
                    _send.setEnabled(true);
                    _stop.setEnabled(false);
                    _status.setText(event.text);
                    break;
                case SessionEventKind.failed:
                    appendTranscript("\n[error] " ~ event.text ~ "\n");
                    _send.setEnabled(true);
                    _stop.setEnabled(false);
                    _status.setText("Error");
                    break;
                default:
                    break;
            }
        }
    }
}

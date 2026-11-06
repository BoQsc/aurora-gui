/**
 * The provider sheet: where the writer points Aurora Write at a model.
 *
 * A modal panel with a dimmed backdrop. It covers the whole root while open so a
 * stray click cannot move the caret behind it; the root closes it on Escape.
 */
module aurorawrite.settingssheet;

import aurora;

private enum int sheetWidth = 520;
private enum int sheetHeight = 372;
private enum int gap = 12;

final class SettingsSheet : Widget
{
    void delegate() onSave;
    void delegate() onCancel;

    private Label _title;
    private Label _hint;
    private Label _baseUrlLabel;
    private Label _modelLabel;
    private Label _keyLabel;
    private TextField _baseUrlField;
    private TextField _modelField;
    private TextField _keyField;
    private Button _save;
    private Button _cancel;
    private string _originNote;

    this()
    {
        _title = add(new Label("Model provider"));
        _title.setPixelSize(19);
        _hint = add(new Label(""));
        _hint.setPixelSize(12);
        _hint.setEllipsis(false);

        _baseUrlLabel = add(new Label("Endpoint"));
        _baseUrlLabel.setPixelSize(12);
        _baseUrlField = add(new TextField());
        _baseUrlField.setPlaceholder("https://api.example.com/v1");
        _baseUrlField.setPixelSizeOverride(14);

        _modelLabel = add(new Label("Model"));
        _modelLabel.setPixelSize(12);
        _modelField = add(new TextField());
        _modelField.setPlaceholder("model-name");
        _modelField.setPixelSizeOverride(14);

        _keyLabel = add(new Label("API key"));
        _keyLabel.setPixelSize(12);
        _keyField = add(new TextField());
        _keyField.setPlaceholder("sk-...");
        _keyField.setPixelSizeOverride(14);

        _save = add(new Button("Save"));
        _save.onClick = delegate() { if (onSave !is null) onSave(); };
        _cancel = add(new Button("Cancel"));
        _cancel.onClick = delegate() { if (onCancel !is null) onCancel(); };

        setVisible(false);
    }

    bool open() const @safe pure nothrow @nogc { return visible(); }

    void setOriginNote(string note)
    {
        _originNote = note;
        refreshHint();
    }

    void setProvider(string baseUrl, string apiKey, string model)
    {
        _baseUrlField.setText(baseUrl, false);
        _keyField.setText(apiKey, false);
        _modelField.setText(model, false);
        refreshHint();
    }

    string baseUrl() { return _baseUrlField.textUtf8(); }
    string apiKey() { return _keyField.textUtf8(); }
    string model() { return _modelField.textUtf8(); }

    void show()
    {
        setVisible(true);
        refreshHint();
        _baseUrlField.requestFocus();
    }

    void hide()
    {
        setVisible(false);
    }

    private void refreshHint()
    {
        const origin = _originNote.length > 0
            ? _originNote : "Runs on any OpenAI-compatible /chat/completions endpoint.";
        _hint.setText(origin);
    }

    protected override void onLayout()
    {
        const width = bounds().width;
        const height = bounds().height;
        const sheetX = maxInt(24, (width - sheetWidth) / 2);
        const sheetY = maxInt(24, (height - sheetHeight) / 2);
        const left = sheetX + 28;
        const fieldWidth = sheetWidth - 56;
        int y = sheetY + 26;

        _title.setBounds(Rect(left, y, fieldWidth, 26));
        y += 30;
        _hint.setBounds(Rect(left, y, fieldWidth, 34));
        y += 44;

        _baseUrlLabel.setBounds(Rect(left, y, fieldWidth, 16));
        y += 18;
        _baseUrlField.setBounds(Rect(left, y, fieldWidth, 32));
        y += 42;

        _modelLabel.setBounds(Rect(left, y, fieldWidth, 16));
        y += 18;
        _modelField.setBounds(Rect(left, y, fieldWidth, 32));
        y += 42;

        _keyLabel.setBounds(Rect(left, y, fieldWidth, 16));
        y += 18;
        _keyField.setBounds(Rect(left, y, fieldWidth, 32));
        y += 44;

        const buttonY = sheetY + sheetHeight - 28 - 34;
        _save.setBounds(Rect(left, buttonY, 96, 34));
        _cancel.setBounds(Rect(left + 104, buttonY, 96, 34));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, Color.rgba(16, 18, 20, 120));

        const sheetX = maxInt(24, (bounds().width - sheetWidth) / 2);
        const sheetY = maxInt(24, (bounds().height - sheetHeight) / 2);
        const sheet = Rect(sheetX, sheetY, sheetWidth, sheetHeight);
        canvas.fillRoundedRect(sheet.translated(0, 3), 12,
            palette.shadow.withAlpha(60));
        canvas.drawRoundedRect(sheet, 12, palette.panelElevated, palette.border, 1);
    }
}

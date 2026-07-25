module demos.font_gallery;

import aurora;
import std.path : baseName;

/** Paints specimens directly so every size, role, and glyph path is exercised. */
final class FontSpecimen : Widget
{
    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, palette.cornerRadius, palette.panelBackground,
            palette.border, 1);

        auto content = canvas.translated(22, 22).clipped(
            Rect(0, 0, maxInt(0, full.width - 44), maxInt(0, full.height - 44)));
        int y = 0;
        content.drawText(Point(0, y), "Aurora Typography"d, palette.text, 4);
        y += 46;
        content.drawText(Point(0, y), "Sphinx of black quartz, judge my vow."d,
            palette.text, 3);
        y += 35;
        content.drawText(Point(0, y),
            "AVATAR  office affinity ffi — kerning, ligatures & Á"d,
            palette.accent, 2);
        y += 30;
        content.drawText(Point(0, y),
            "Café naïve façade • Ελληνικά • Кириллица • 日本語"d,
            palette.text, 2);
        y += 29;
        content.drawText(Point(0, y),
            "Mixed bidi: English العربية 123 עברית • سلام"d,
            palette.text, 2);
        y += 38;
        content.drawLine(Point(0, y), Point(maxInt(0, full.width - 44), y),
            palette.border);
        y += 18;
        content.drawText(Point(0, y), "Monospace / editor face"d,
            palette.textMuted, 2, FontRole.monospace, palette.monospaceFont);
        y += 28;
        content.drawText(Point(0, y),
            "0123456789  []{}()  =>  int answer = 6 * 7;"d,
            palette.text, 2, FontRole.monospace, palette.monospaceFont);
        y += 30;
        content.drawText(Point(0, y),
            "One shaped layout and A8 atlas feed both Vulkan and software."d,
            palette.textMuted, 1);
    }
}

final class FontGalleryRoot : VBox
{
    private GuiWindow _window;
    private TextField _path;
    private Label _status;
    private Button _themeButton;
    private bool _dark;

    this(GuiWindow window, string initialPath = "")
    {
        super(8, Insets(10));
        _window = window;

        auto toolbar = add(new HBox(7));
        toolbar.layoutHints().preferredHeight = 42;
        _path = toolbar.add(new TextField(initialPath));
        _path.setPlaceholder("Path to an OpenType .ttf, .ttc, or static-CFF .otf font");
        _path.layoutHints().flex = 1.0;
        _path.layoutHints().preferredWidth = 460;
        _path.onSubmitted = delegate() { loadFont(); };

        auto load = toolbar.add(new Button("Load font", IconKind.open));
        load.setAccent(true);
        load.onClick = delegate() { loadFont(); };

        auto defaults = toolbar.add(new Button("System", IconKind.refresh));
        defaults.onClick = delegate()
        {
            _window.setFonts(SystemFonts.sans(), SystemFonts.monospace());
            _path.setText("", false);
            updateStatus("Restored discovered system fonts");
        };

        _themeButton = toolbar.add(new Button("Dark", IconKind.settings));
        _themeButton.onClick = delegate() { toggleTheme(); };

        auto specimen = add(new FontSpecimen());
        specimen.layoutHints().flex = 1.0;
        specimen.layoutHints().minHeight = 330;

        _status = add(new Label());
        _status.setScale(1);
        _status.layoutHints().preferredHeight = 28;
        if (initialPath.length > 0)
            updateStatus("Loaded " ~ baseName(initialPath));
        else
            updateStatus("System UI: " ~ _window.fontSystem().uiFace.path());
    }

    private void loadFont()
    {
        const path = _path.textUtf8();
        if (path.length == 0)
        {
            updateStatus("Enter a .ttf, .ttc, or .otf path first");
            _path.requestFocus();
            return;
        }
        try
        {
            auto face = FontFace.load(path);
            _window.setFonts(face);
            updateStatus("Loaded " ~ baseName(path));
        }
        catch (Exception error)
        {
            updateStatus("Font load failed: " ~ error.msg);
        }
    }

    private void toggleTheme()
    {
        _dark = !_dark;
        _window.setTheme(_dark ? Theme.dark() : Theme.light());
        _themeButton.setText(_dark ? "Light" : "Dark");
    }

    private void updateStatus(string message)
    {
        _status.setText(message ~ "   |   Renderer: " ~ _window.rendererName());
    }
}

int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Font Gallery";
    options.width = 980;
    options.height = 620;
    if (args.length > 1) options.uiFontPath = args[1];
    if (args.length > 2) options.monospaceFontPath = args[2];

    auto window = new GuiWindow(options, Theme.light());
    const initialPath = args.length > 1 ? args[1] : "";
    window.setRoot(new FontGalleryRoot(window, initialPath));
    return window.run();
}

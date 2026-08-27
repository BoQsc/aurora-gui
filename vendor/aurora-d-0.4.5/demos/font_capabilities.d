module demos.font_capabilities;

/**
 * Aurora font capabilities demo.
 *
 * Renders a single window that walks through everything the pure-D font
 * engine now supports, using real system fonts so nothing needs to be
 * downloaded:
 *
 *   - Grid-fit (TrueType bytecode hinted) text at multiple scales.
 *   - Kerning, ligatures, combining marks, and bidi.
 *   - Color emoji (Segoe UI Emoji) — COLR/CBDT color glyphs.
 *   - A variable font (InterVariable) shown at several weights.
 *   - Complex-script shaping (Nirmala UI Devanagari reordering).
 *   - CJK fallback (Malgun Gothic) and monospace (Consolas).
 *
 * Each specimen paints its own panel so the glyph path and colors are
 * exercised through the real renderer (Vulkan or software).
 */

import aurora;
import std.file : exists;
import std.utf : toUTF32;

/// A font file available on this machine, or null (specimen is hidden).
private string firstFont(string[] candidates)
{
    foreach (path; candidates)
        if (exists(path)) return path;
    return null;
}

/// One labelled specimen panel.
final class Specimen : Widget
{
    private string _title;
    private const(dchar)[] _text;
    private FontFace _font;
    private FontRole _role;
    private int _scale;
    private Color _tint;

    this(string title, string text, FontFace font, int scale,
        FontRole role = FontRole.ui, Color tint = Color(0, 0, 0, 0))
    {
        _title = title;
        _text = text.toUTF32;
        _font = font;
        _scale = scale;
        _role = role;
        _tint = tint;
        layoutHints().minHeight = 64;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, palette.cornerRadius, palette.panelBackground,
            palette.border, 1);

        auto content = canvas.translated(18, 14).clipped(
            Rect(0, 0, maxInt(0, full.width - 36), maxInt(0, full.height - 28)));
        content.drawText(Point(0, 0), _title.toUTF32, palette.textMuted, 1);
        const color = _tint.a == 0 ? palette.text : _tint;
        content.drawText(Point(0, 30), _text, color, _scale, _role, _font);
    }
}

final class CapabilitiesRoot : VBox
{
    this(GuiWindow window)
    {
        super(8, Insets(10));

        const windir = "C:\\Windows\\Fonts\\";

        // Resolve a variable font from the repo's test assets, else skip.
        string interPath = firstFont([
            "vendor/aurora-d-0.4.5/tests/fonts/InterVariable.ttf",
            "tests/fonts/InterVariable.ttf"
        ]);
        const emojiPath = windir ~ "seguiemj.ttf";
        const indicPath = windir ~ "Nirmala.ttf";
        const cjkPath = windir ~ "malgun.ttf";
        const monoPath = windir ~ "consola.ttf";

        auto header = add(new Label());
        header.setText("Aurora-D font engine — every capability in one window");
        header.layoutHints().preferredHeight = 30;

        auto hintRow = add(new HBox(8));
        hintRow.layoutHints().fillCrossAxis = true;

        // Hinted body text — crisp grid-fitted sampling at 3 scales.
        auto hint = hintRow.add(new Specimen("Grid-fit hinting",
            "Sphinx of black quartz, judge my vow.",
            null, 3));
        hint.layoutHints().flex = 1.0;
        auto hintSmall = hintRow.add(new Specimen("Hinted caption",
            "The quick brown fox jumps over the lazy dog.",
            null, 1));
        hintSmall.layoutHints().flex = 1.0;
        auto hintMono = hintRow.add(new Specimen("Monospace",
            "int answer = 6 * 7; // => 42",
            FontFace.tryLoad(monoPath), 2, FontRole.monospace));
        hintMono.layoutHints().flex = 1.0;

        // Kerning, ligatures, combining marks, bidi.
        auto typoRow = add(new HBox(8));
        typoRow.layoutHints().fillCrossAxis = true;
        auto liga = typoRow.add(new Specimen("Ligatures + kerning",
            "office ffi AV To Yo A\u0301", null, 2));
        liga.layoutHints().flex = 1.0;
        auto bidi = typoRow.add(new Specimen("Bidi (Arabic/Hebrew)",
            "English \u0633\u0644\u0627\u0645 \u05E2\u05D1\u05E8\u05D9\u05EA 123",
            null, 2));
        bidi.layoutHints().flex = 1.0;

        // Color emoji.
        if (exists(emojiPath) && FontFace.tryLoad(emojiPath) !is null)
        {
            auto emoji = add(new Specimen("Color emoji (COLR/CBDT)",
                "Emoji: \U0001F600 \U0001F389 \U0001F49A \U0001F680 \U0001F4A1",
                FontFace.load(emojiPath), 3));
            emoji.layoutHints().fillCrossAxis = true;
        }

        // Variable font at a couple of weights.
        if (exists(interPath) && FontFace.tryLoad(interPath) !is null)
        {
            auto inter = FontFace.load(interPath);
            auto varRow = add(new HBox(8));
            varRow.layoutHints().fillCrossAxis = true;

            const defaultCoords = inter.variationAxisCount() > 0
                ? variationDefaults(inter) : null;
            // Light (300).
            auto lightFace = FontFace.load(interPath);
            if (lightFace.variationAxisCount() > 0)
                setWeight(lightFace, 300);
            varRow.add(new Specimen("Variable font — Light (300)",
                "The quick brown fox", lightFace, 2))
                .layoutHints().flex = 1.0;

            auto boldFace = FontFace.load(interPath);
            if (boldFace.variationAxisCount() > 0)
                setWeight(boldFace, 900);
            varRow.add(new Specimen("Variable font — Black (900)",
                "The quick brown fox", boldFace, 2))
                .layoutHints().flex = 1.0;
        }

        // Complex-script (Indic) reordering + CJK fallback.
        auto scriptRow = add(new HBox(8));
        scriptRow.layoutHints().fillCrossAxis = true;
        auto indic = scriptRow.add(new Specimen("Complex-script (Indic)",
            "\u0930\u094D\u0915\u093F \u0928\u092E\u0938\u094D\u0924\u0947",
            exists(indicPath) ? FontFace.load(indicPath) : null, 2));
        indic.layoutHints().flex = 1.0;
        auto cjk = scriptRow.add(new Specimen("CJK + fallback",
            "\u4F60\u597D\u4E16\u754C \u30AB\u30BF\u30AB\u30CA",
            exists(cjkPath) ? FontFace.load(cjkPath) : null, 2));
        cjk.layoutHints().flex = 1.0;

        auto status = add(new Label());
        status.setText("Renderer: " ~ window.rendererName() ~
            "   |   UI font: " ~ SystemFonts.sans().path());
        status.layoutHints().preferredHeight = 26;
    }

    private static long[] variationDefaults(FontFace face)
    {
        long[] coords;
        coords.length = face.variationAxisCount();
        foreach (i; 0 .. coords.length)
            coords[i] = 0L << 16;
        return coords;
    }

    private static void setWeight(FontFace face, double weight)
    {
        // Build design coordinates: default everything, then weight axis.
        long[] coords;
        coords.length = face.variationAxisCount();
        foreach (i; 0 .. coords.length)
            coords[i] = cast(long) (weight * 65536.0);
        face.setVariationCoords(coords);
    }
}

version (AuroraHeadless)
{
    // The interactive entry point is compiled only for the GUI executable;
    // the headless smoke provides its own main and imports the testable
    // classes.
}
else
{
    int main(string[] args)
    {
        if (args.length >= 3 && args[1] == "--screenshot")
            return runScreenshot(args[2]);

        WindowOptions options;
        options.title = "Aurora-D Font Capabilities";
        options.width = 1080;
        options.height = 680;

        auto window = new GuiWindow(options, Theme.light());
        window.setRoot(new CapabilitiesRoot(window));
        return window.run();
    }

    private int runScreenshot(string outputPath)
    {
        WindowOptions options;
        options.title = "Aurora-D Font Capabilities";
        options.width = 1080;
        options.height = 680;
        options.renderer = RendererPreference.software;
        auto window = new GuiWindow(options, Theme.light());
        auto root = new CapabilitiesRoot(window);
        window.setRoot(root);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(options.width, options.height));
        driver.paint();
        window.saveScreenshot(outputPath);
        window.close();
        return 0;
    }
}

module aurorafontviewer.fontviewer;

import aurora;
import aurora.text.fontmanager : SystemFontInventory, InstalledFont, FontWeight;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.path : baseName;
import std.string : strip;
import std.utf : toUTF32;

/** A single font family shown in the list (deduplicated by family name). */
private struct FamilyEntry
{
    string familyName;
    InstalledFont best; /// The face used for the specimen (regular, else first).
    int memberCount;
}

private FamilyEntry[] enumerateFamilies()
{
    FamilyEntry[] result;
    foreach (font; SystemFontInventory.installed())
    {
        const fam = font.familyName;
        bool found;
        foreach (ref entry; result)
        {
            if (entry.familyName == fam)
            {
                ++entry.memberCount;
                if (font.weight == FontWeight.normal && !font.italic &&
                    (entry.best.weight != FontWeight.normal || entry.best.italic))
                    entry.best = font;
                found = true;
                break;
            }
        }
        if (found) continue;
        FamilyEntry entry;
        entry.familyName = fam;
        entry.memberCount = 1;
        if (font.weight == FontWeight.normal && !font.italic)
            entry.best = font;
        else
            entry.best = font;
        result ~= entry;
    }
    result.sort!((a, b) => a.familyName < b.familyName);
    return result;
}

/** Live specimen pane that paints the selected family with Aurora's engine. */
final class SpecimenView : Widget
{
    private FontFace _face;
    private string _familyName;

    this()
    {
        layoutHints().minWidth = 420;
        layoutHints().flex = 1.0;
    }

    void setFamily(FontFace face, string familyName)
    {
        _face = face;
        _familyName = familyName;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, palette.panelBackground);

        if (_face is null)
        {
            canvas.drawTextInRect(full,
                "No font selected. Pick a family from the list on the left."d,
                palette.textMuted, 2, HorizontalAlign.center, VerticalAlign.middle);
            return;
        }

        auto content = canvas.translated(26, 24).clipped(
            Rect(0, 0, maxInt(0, bounds().width - 52), maxInt(0, bounds().height - 48)));
        int y = 0;

        content.drawText(Point(0, y), toUTF32("Family: " ~ _familyName),
            palette.accent, 2, FontRole.ui, _face);
        y += 34;

        content.drawText(Point(0, y),
            "Sphinx of black quartz, judge my vow."d,
            palette.text, 3, FontRole.ui, _face);
        y += 40;

        content.drawText(Point(0, y),
            "AVATAR  office affinity ffi — kerning, ligatures & A\u0301"d,
            palette.text, 2, FontRole.ui, _face);
        y += 31;

        content.drawText(Point(0, y),
            "0123456789  abcdefghijklmnopqrstuvwxyz  ABCDEFGHIJKLMNOPQRSTUVWXYZ"d,
            palette.text, 2, FontRole.ui, _face);
        y += 31;

        content.drawLine(Point(0, y), Point(maxInt(0, bounds().width - 52), y),
            palette.border);
        y += 20;

        content.drawText(Point(0, y), toUTF32("The quick brown fox jumps over the lazy dog."),
            palette.text, 4, FontRole.ui, _face);
        y += 48;

        content.drawText(Point(0, y),
            "Caf\u00e9 na\u00efve fa\u00e7ade \u2022 \u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac \u2022 \u041a\u0438\u0440\u0438\u043b\u043b\u0438\u0446\u0430 \u2022 \u65e5\u672c\u8a9e"d,
            palette.textMuted, 2, FontRole.ui, _face);
        y += 29;

        content.drawText(Point(0, y), "\u4f60\u597d \u4e16\u754c  \u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35\u0e04\u0e23\u0e31\u0e1a"d,
            palette.textMuted, 2, FontRole.ui, _face);
    }
}

final class FontViewerRoot : HBox
{
    private GuiWindow _window;
    private ListView _list;
    private SpecimenView _specimen;
    private Label _status;
    private FamilyEntry[] _families;

    this(GuiWindow window)
    {
        super(8);
        _window = window;

        _families = enumerateFamilies();

        _list = new ListView();
        _list.setRowHeight(40);
        _list.setShowBorder(true);
        _list.layoutHints().preferredWidth = 300;
        _list.layoutHints().minWidth = 260;
        _list.layoutHints().flex = 0.0;
        _list.onSelectionChanged = delegate(int index)
        {
            selectFamily(index);
        };

        string[] names;
        foreach (entry; _families)
            names ~= entry.familyName ~ (entry.memberCount > 1 ?
                format("  (%d)", entry.memberCount) : "");
        _list.setStrings(names);

        auto left = new VBox(6);
        left.layoutHints().preferredWidth = 300;
        left.layoutHints().minWidth = 260;
        left.layoutHints().flex = 0.0;
        left.add(_list);

        auto right = new VBox(6);
        right.layoutHints().flex = 1.0;
        _specimen = new SpecimenView();
        right.add(_specimen);
        _status = new Label();
        _status.setScale(1);
        right.add(_status);

        // Root is an HBox: family list on the left, specimen on the right.
        add(left);
        add(right);

        if (_families.length > 0)
            _list.setSelectedIndex(0);
    }

    int familyCount() const @safe pure nothrow @nogc
    {
        return cast(int) _families.length;
    }

    /// Test-only: select a family by index and paint its specimen.
    void selectFamilyForTesting(int index)
    {
        selectFamily(index);
        _specimen.invalidate();
    }

    private void selectFamily(int index)
    {
        if (index < 0 || index >= cast(int) _families.length) return;
        const entry = _families[cast(size_t) index];
        auto face = FontFace.tryLoad(entry.best.path, entry.best.faceIndex);
        if (face is null)
        {
            _specimen.setFamily(null, entry.familyName);
            _status.setText("Could not load " ~ entry.familyName);
            return;
        }
        _specimen.setFamily(face, entry.familyName);
        _status.setText(entry.familyName ~ "  |  " ~ baseName(entry.best.path) ~
            "  |  members: " ~ entry.memberCount.to!string);
    }
}

private int runScreenshot(string outputPath, int familyIndex)
{
    auto options = fontViewerWindowOptions();
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new FontViewerRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1080, 720));
    if (root.familyCount() > 0)
    {
        const index = familyIndex < 0 ? 0 :
            familyIndex >= root.familyCount() ? root.familyCount() - 1 : familyIndex;
        root.selectFamilyForTesting(index);
    }
    driver.paint();
    window.saveScreenshot(outputPath);
    window.close();
    return 0;
}

private WindowOptions fontViewerWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora Font Viewer";
    options.width = 1080;
    options.height = 720;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    return options;
}

int run(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
    {
        int index = 0;
        if (args.length >= 4)
        {
            try
                index = strip(args[3]).to!int;
            catch (Exception)
            {
                // Accept an exact family name for reproducible font captures.
                bool found;
                foreach (i, family; enumerateFamilies())
                    if (family.familyName == strip(args[3]))
                    {
                        index = cast(int) i;
                        found = true;
                        break;
                    }
                if (!found) return 2;
            }
        }
        return runScreenshot(args[2], index);
    }
    if (args.length >= 2 && args[1] == "--screenshot")
        return runScreenshot("font-viewer.ppm", 0);

    // The theme is resolved by the window; use a decorator that yields a
    // clean workspace without a native title bar. Aurora's own text engine
    // renders every glyph here - there is no FFmpeg and no OS font API.
    auto window = new GuiWindow(fontViewerWindowOptions(), Theme.light());
    window.setRoot(new FontViewerRoot(window));
    return window.run();
}

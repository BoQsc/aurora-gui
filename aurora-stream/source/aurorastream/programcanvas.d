module aurorastream.programcanvas;

import aurora;
import std.algorithm.comparison : min;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.utf : toUTF32;

/// Kinds of sources that can be composited into the Aurora-rendered program
/// canvas. Screen/window/game capture is deliberately not a source yet: the
/// current milestone replaces direct desktop capture with an Aurora-rendered
/// canvas, so the available sources are all rendered by Aurora itself.
enum ProgramSourceKind : ubyte
{
    color,
    image,
    text
}

/// One composited layer of the program canvas. Rectangles are normalized to
/// the selected source canvas (0..1 each axis), so the same layout works for
/// any of the 1080p, 1440p, or 4K source canvases.
struct ProgramSource
{
    ProgramSourceKind kind;
    bool enabled = true;

    double x = 0.0;
    double y = 0.0;
    double width = 1.0;
    double height = 1.0;

    /// 0..1 composite opacity.
    double opacity = 1.0;

    /// Fill color for a color source, text color for a text source.
    Color color = Color.rgb(0, 0, 0);

    /// Text for a text source.
    string text;
    /// Aurora font size multiplier for a text source.
    int textScale = 3;

    /// Persisted image path for an image source. The loaded pixels live in
    /// `image` and are not serialized.
    string imagePath;
    RgbaImage image;
}

ProgramSource defaultColorSource(Color color = Color.rgb(0, 0, 0))
{
    ProgramSource source;
    source.kind = ProgramSourceKind.color;
    source.color = color;
    return source;
}

ProgramSource defaultImageSource(string path, RgbaImage image = null)
{
    ProgramSource source;
    source.kind = ProgramSourceKind.image;
    source.x = 0.05;
    source.y = 0.05;
    source.width = 0.9;
    source.height = 0.9;
    source.imagePath = path;
    source.image = image;
    return source;
}

ProgramSource defaultTextSource(string text = "LIVE", Color color = Color.rgb(255, 255, 255))
{
    ProgramSource source;
    source.kind = ProgramSourceKind.text;
    source.x = 0.1;
    source.y = 0.78;
    source.width = 0.8;
    source.height = 0.16;
    source.color = color;
    source.text = text;
    return source;
}

ProgramSource[] copySources(const ProgramSource[] sources)
{
    ProgramSource[] result;
    result.reserve(sources.length);
    foreach (source; sources)
        result ~= cast(ProgramSource) source;
    return result;
}

private Rect sourceDest(const ProgramSource source, Rect target)
{
    return Rect(
        target.x + cast(int) (source.x * target.width),
        target.y + cast(int) (source.y * target.height),
        maxInt(1, cast(int) (source.width * target.width)),
        maxInt(1, cast(int) (source.height * target.height)));
}

/// Composite every enabled source into `target`, bottom source first. Works
/// with both draw-list canvases (widget onPaint) and immediate surface
/// canvases (worker-side frame rendering), matching the titlelayer approach.
void paintProgramCanvas(Canvas canvas, const ProgramSource[] sources,
    Rect target)
{
    foreach (source; sources)
    {
        if (!source.enabled) continue;
        const dest = sourceDest(source, target);
        const alpha = cast(ubyte) ((source.opacity * 255.0 + 0.5));
        final switch (source.kind)
        {
            case ProgramSourceKind.color:
                canvas.fillRect(dest, source.color.withAlpha(alpha));
                break;
            case ProgramSourceKind.image:
                if (source.image is null) break;
                canvas.drawImage(dest, cast(RgbaImage) source.image,
                    source.image.bounds(), Color(255, 255, 255, alpha), true);
                break;
            case ProgramSourceKind.text:
                if (source.text.length == 0) break;
                canvas.drawTextInRect(dest, toUTF32(source.text),
                    source.color.withAlpha(alpha), source.textScale,
                    HorizontalAlign.center, VerticalAlign.middle, false);
                break;
        }
    }
}

/// Aspect-preserving letterbox rectangle for the live preview widget.
private Rect aspectTarget(Size logical, Rect outer)
{
    if (logical.width <= 0 || logical.height <= 0) return outer;
    const scale = min(cast(double) outer.width / logical.width,
        cast(double) outer.height / logical.height);
    const width = maxInt(1, cast(int) (logical.width * scale));
    const height = maxInt(1, cast(int) (logical.height * scale));
    return Rect(outer.x + (outer.width - width) / 2,
        outer.y + (outer.height - height) / 2, width, height);
}

/// Live preview of the Aurora-rendered program canvas. The composite is drawn
/// directly into the widget canvas letterboxed to the selected source canvas
/// aspect ratio, so it always matches what the broadcaster will encode.
final class ProgramCanvasPreview : Widget
{
    private ProgramSource[] _sources;
    private Size _logicalSize = Size(1920, 1080);

    void setSources(const ProgramSource[] sources, Size logicalSize)
    {
        _sources = copySources(sources);
        if (logicalSize.width > 0 && logicalSize.height > 0)
            _logicalSize = logicalSize;
        invalidate();
    }

    const(ProgramSource)[] sources() const { return _sources; }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, Color.rgb(4, 5, 7));
        if (_sources.length == 0)
        {
            canvas.drawTextInRect(full,
                "Aurora program canvas is empty.\n" ~
                "Add color, image, or text sources in Settings → Program canvas."d,
                Color.rgb(120, 130, 142), 1, HorizontalAlign.center,
                VerticalAlign.middle, false);
            return;
        }
        const target = aspectTarget(_logicalSize, full);
        paintProgramCanvas(canvas, _sources, target);
    }
}

/// A compact source-list editor for the Aurora program canvas. Rows are
/// rebuilt whenever the structure changes (add/remove/reorder); in-place edits
/// such as text and opacity mutate the model directly.
final class ProgramCanvasEditor : VBox
{
    private ProgramSource[] _sources;
    private VBox _list;
    private HBox _addRow;
    private Button _addColor;
    private Button _addImage;
    private Button _addText;
    private Label _status;

    /// Fired after any source-list change with a snapshot of the sources.
    void delegate(const ProgramSource[] sources) onSourcesChanged;

    this()
    {
        super(6);
        _list = add(new VBox(4));
        _addRow = add(new HBox(6));
        _addColor = _addRow.add(new Button("Add color"));
        _addColor.onClick = delegate() { addColor(); };
        _addImage = _addRow.add(new Button("Add image"));
        _addImage.onClick = delegate() { addImage(); };
        _addText = _addRow.add(new Button("Add text"));
        _addText.onClick = delegate() { addText(); };
        _status = add(new Label(""));
        _status.setScale(1);
        _status.setColor(Color.fromHex(0x9ca8b5));
        _status.layoutHints().preferredHeight = 20;
        rebuild();
    }

    void setSources(const ProgramSource[] sources)
    {
        _sources = copySources(sources);
        rebuild();
    }

    /// Disables every editable child control so source editing cannot race the
    /// canvas frame pump while streaming.
    void setControlsEnabled(bool value)
    {
        setEnabled(value);
        disableTree(this, value);
    }

    private static void disableTree(Widget root, bool value)
    {
        foreach (child; root.children())
        {
            child.setEnabled(value);
            disableTree(child, value);
        }
    }

    const(ProgramSource)[] sources() const { return _sources; }

    void setStatus(string value)
    {
        _status.setText(value);
    }

    private void notifyChanged()
    {
        if (onSourcesChanged !is null) onSourcesChanged(_sources);
    }

    private void addColor()
    {
        _sources ~= defaultColorSource();
        rebuild();
        notifyChanged();
    }

    private void addImage()
    {
        showFileDialog(this, FileDialogOptions(title: "Add image source"),
            delegate(string path)
            {
                RgbaImage image;
                try image = loadPngImage(path);
                catch (Exception error)
                {
                    setStatus("Could not load " ~ path ~ ": " ~ error.msg);
                }
                _sources ~= defaultImageSource(path, image);
                rebuild();
                notifyChanged();
            });
    }

    private void addText()
    {
        _sources ~= defaultTextSource();
        rebuild();
        notifyChanged();
    }

    private void moveSource(int index, int delta)
    {
        const target = index + delta;
        if (index < 0 || target < 0 || target >= cast(int) _sources.length)
            return;
        auto value = _sources[cast(size_t) index];
        _sources[cast(size_t) index] = _sources[cast(size_t) target];
        _sources[cast(size_t) target] = value;
        rebuild();
        notifyChanged();
    }

    private void removeSource(int index)
    {
        if (index < 0 || index >= cast(int) _sources.length) return;
        _sources = _sources[0 .. cast(size_t) index] ~
            _sources[cast(size_t) index + 1 .. $];
        rebuild();
        notifyChanged();
    }

    private string kindLabel(const ProgramSource source) const
    {
        final switch (source.kind)
        {
            case ProgramSourceKind.color:
                return "Color " ~ colorHex(source.color);
            case ProgramSourceKind.image:
                return "Image";
            case ProgramSourceKind.text:
                return "Text";
        }
    }

    private void rebuild()
    {
        if (_list is null) return;
        _list.clearChildren();

        foreach (index, source; _sources)
        {
            const captured = cast(int) index;
            auto row = _list.add(new HBox(5));
            row.layoutHints().preferredHeight = 38;

            auto enabled = row.add(new CheckBox("", source.enabled));
            enabled.layoutHints().preferredWidth = 34;
            enabled.onChanged = delegate(bool value)
            {
                _sources[cast(size_t) captured].enabled = value;
                notifyChanged();
            };

            auto label = row.add(new Label(kindLabel(source)));
            label.setScale(1);
            label.setColor(Color.fromHex(0xc8d0da));
            label.layoutHints().flex = 1.0;
            label.setEllipsis(true);

            if (source.kind == ProgramSourceKind.text)
            {
                auto field = row.add(new TextField(source.text));
                field.layoutHints().preferredWidth = 120;
                field.onChanged = delegate()
                {
                    _sources[cast(size_t) captured].text = field.textUtf8();
                    notifyChanged();
                };
            }

            auto slider = row.add(new Slider(0.0, 1.0, source.opacity));
            slider.layoutHints().preferredWidth = 90;
            slider.onChanged = delegate(double value)
            {
                _sources[cast(size_t) captured].opacity = value;
                notifyChanged();
            };

            auto up = row.add(new Button("▲"));
            up.layoutHints().preferredWidth = 30;
            up.layoutHints().preferredHeight = 30;
            up.onClick = delegate() { moveSource(captured, -1); };

            auto down = row.add(new Button("▼"));
            down.layoutHints().preferredWidth = 30;
            down.layoutHints().preferredHeight = 30;
            down.onClick = delegate() { moveSource(captured, +1); };

            auto remove = row.add(new Button("✕"));
            remove.layoutHints().preferredWidth = 30;
            remove.layoutHints().preferredHeight = 30;
            remove.onClick = delegate() { removeSource(captured); };
        }

        layoutTree();
        invalidate();
    }
}

private string colorHex(Color color) @safe
{
    return format("#%02X%02X%02X", color.r, color.g, color.b);
}

private Color colorFromHex(string value) @safe
{
    if (value.length < 7 || value[0] != '#') return Color.rgb(0, 0, 0);
    try return Color.fromHex(cast(uint) to!uint(value[1 .. $], 16));
    catch (Exception) return Color.rgb(0, 0, 0);
}

JSONValue programSourcesToJson(const ProgramSource[] sources)
{
    JSONValue array = JSONValue.emptyArray;
    foreach (source; sources)
    {
        JSONValue item = JSONValue.emptyObject;
        item["kind"] = programSourceKindName(source.kind);
        item["enabled"] = source.enabled;
        item["x"] = source.x;
        item["y"] = source.y;
        item["width"] = source.width;
        item["height"] = source.height;
        item["opacity"] = source.opacity;
        item["color"] = colorHex(source.color);
        item["text"] = source.text;
        item["textScale"] = source.textScale;
        item["imagePath"] = source.imagePath;
        array.array ~= item;
    }
    return array;
}

ProgramSource[] programSourcesFromJson(const JSONValue value)
{
    ProgramSource[] sources;
    if (value.type != JSONType.array) return sources;
    foreach (item; value.array)
    {
        if (item.type != JSONType.object) continue;
        ProgramSource source;
        source.kind = programSourceKindFromName(jsonString(item, "kind",
            "color"));
        source.enabled = jsonBool(item, "enabled", true);
        source.x = jsonDouble(item, "x", source.x);
        source.y = jsonDouble(item, "y", source.y);
        source.width = jsonDouble(item, "width", source.width);
        source.height = jsonDouble(item, "height", source.height);
        source.opacity = jsonDouble(item, "opacity", 1.0);
        source.color = colorFromHex(jsonString(item, "color", "#000000"));
        source.text = jsonString(item, "text", "");
        source.textScale = jsonInt(item, "textScale", 3);
        source.imagePath = jsonString(item, "imagePath", "");
        if (source.imagePath.length > 0)
        {
            try source.image = loadPngImage(source.imagePath);
            catch (Exception) source.image = null;
        }
        sources ~= source;
    }
    return sources;
}

private string jsonString(const JSONValue object, string key, string fallback)
{
    const value = key in object;
    if (value is null || value.type != JSONType.string) return fallback;
    return value.str;
}

private bool jsonBool(const JSONValue object, string key, bool fallback)
{
    const value = key in object;
    if (value is null || (value.type != JSONType.true_ &&
        value.type != JSONType.false_)) return fallback;
    return value.boolean;
}

private double jsonDouble(const JSONValue object, string key, double fallback)
{
    const value = key in object;
    if (value is null) return fallback;
    if (value.type == JSONType.integer) return cast(double) value.integer;
    if (value.type == JSONType.float_) return value.floating;
    return fallback;
}

private int jsonInt(const JSONValue object, string key, int fallback)
{
    const value = key in object;
    if (value is null || value.type != JSONType.integer)
        return fallback;
    return cast(int) value.integer;
}

string programSourceKindName(ProgramSourceKind kind) @safe pure nothrow
{
    final switch (kind)
    {
        case ProgramSourceKind.color: return "color";
        case ProgramSourceKind.image: return "image";
        case ProgramSourceKind.text: return "text";
    }
}

ProgramSourceKind programSourceKindFromName(string value) @safe pure nothrow
{
    switch (value)
    {
        case "image": return ProgramSourceKind.image;
        case "text": return ProgramSourceKind.text;
        default: return ProgramSourceKind.color;
    }
}

unittest
{
    // A full-canvas color source fills every pixel with the authored color.
    auto sources = [defaultColorSource(Color.rgb(20, 60, 120))];
    auto surface = new Surface(64, 36);
    auto fonts = new FontSystem();
    auto canvas = Canvas(surface, fonts);
    paintProgramCanvas(canvas, sources, Rect(0, 0, 64, 36));
    assert(surface.pixel(5, 5) == Color.rgb(20, 60, 120).argb());
    assert(surface.pixel(63, 35) == Color.rgb(20, 60, 120).argb());

    // A hidden source contributes nothing; a half-canvas color source covers
    // only its normalized rectangle.
    sources ~= defaultColorSource(Color.rgb(255, 0, 0));
    sources[1].enabled = false;
    surface.clear(Color.rgb(0, 0, 0));
    paintProgramCanvas(canvas, sources, Rect(0, 0, 64, 36));
    assert(surface.pixel(10, 10) == Color.rgb(20, 60, 120).argb());
}

unittest
{
    // Text sources render non-background pixels inside their rect.
    auto textSource = defaultTextSource("LIVE", Color.rgb(255, 255, 255));
    textSource.x = 0.0;
    textSource.y = 0.2;
    textSource.width = 1.0;
    textSource.height = 0.6;
    auto sources = [defaultColorSource(Color.rgb(0, 0, 0)), textSource];
    auto surface = new Surface(96, 54);
    auto fonts = new FontSystem();
    auto canvas = Canvas(surface, fonts);
    paintProgramCanvas(canvas, sources, Rect(0, 0, 96, 54));
    bool textPixels;
    foreach (pixel; surface.pixels())
        if (pixel != Color.rgb(0, 0, 0).argb()) { textPixels = true; break; }
    assert(textPixels);
}

unittest
{
    // Image sources scale the authored pixels into their rectangle.
    ubyte[16 * 16 * 4] rgba;
    foreach (index; 0 .. rgba.length)
        rgba[index] = (index % 4 == 3) ? 255 : cast(ubyte) (index * 7);
    auto image = new RgbaImage(16, 16, rgba);
    auto sources = [defaultColorSource(Color.rgb(0, 0, 0)),
        defaultImageSource("", image)];
    auto surface = new Surface(64, 36);
    auto fonts = new FontSystem();
    auto canvas = Canvas(surface, fonts);
    paintProgramCanvas(canvas, sources, Rect(0, 0, 64, 36));
    bool imagePixels;
    foreach (pixel; surface.pixels())
        if (pixel != Color.rgb(0, 0, 0).argb()) { imagePixels = true; break; }
    assert(imagePixels);
}

unittest
{
    // Normalized rects survive JSON round-trips, and image paths reload.
    auto sources = [defaultColorSource(Color.rgb(255, 128, 0)),
        defaultTextSource("Aurora", Color.rgb(255, 255, 255))];
    const encoded = programSourcesToJson(sources);
    const restored = programSourcesFromJson(encoded);
    assert(restored.length == 2);
    assert(restored[0].kind == ProgramSourceKind.color);
    assert(restored[0].color == Color.rgb(255, 128, 0));
    assert(restored[1].kind == ProgramSourceKind.text);
    assert(restored[1].text == "Aurora");
    assert(restored[1].x == sources[1].x);
    assert(restored[1].width == sources[1].width);
}

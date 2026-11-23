module opencodelite.widgets;

import aurora;
import aurorahost.component : ComponentContext, ComponentFactory;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.utf : toUTF32;

/// Declarative card/header widget shared by every scene instance.
final class UniversalWidget : Widget
{
    private dstring _kicker;
    private dstring _title;
    private dstring _subtitle;
    private Color _accent;
    private Color _background;
    private Color _border;
    private Color _textColor;
    private Color _mutedColor;
    private int _radius;
    private int _padding;
    private bool _shadow;
    private bool _accentBar;

    this(JSONValue props)
    {
        _kicker = toUTF32(readString(props, "kicker", ""));
        _title = toUTF32(readString(props, "title", ""));
        _subtitle = toUTF32(readString(props, "subtitle", ""));
        _accent = readColor(props, "accent", Color.rgb(0x69, 0xd2, 0xa8));
        _background = readColor(props, "background", Color.rgb(0x15, 0x1f, 0x29));
        _border = readColor(props, "border", Color.rgb(0x2b, 0x3a, 0x48));
        _textColor = readColor(props, "textColor", Color.rgb(0xe6, 0xed, 0xf5));
        _mutedColor = readColor(props, "mutedColor", Color.rgb(0x7d, 0x8e, 0xa3));
        _radius = readInt(props, "radius", 8, 0, 32);
        _padding = readInt(props, "padding", 12, 2, 40);
        _shadow = readBool(props, "shadow", true);
        _accentBar = readBool(props, "accentBar", true);
        setFocusable(false);
        setCursor(CursorKind.arrow);
    }

    protected override Size onMeasure(Size available)
    {
        return Size(maxInt(120, available.width), 58);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const w = bounds().width;
        const h = bounds().height;
        if (w <= 0 || h <= 0)
            return;
        const body = Rect(0, 0, w, h);
        if (_shadow)
            canvas.fillRoundedRect(Rect(2, 3, maxInt(1, w - 4), maxInt(1, h - 4)),
                _radius, Color.rgba(0, 0, 0, 85));
        canvas.drawRoundedRect(body, _radius, _background, _border, 1);
        if (_accentBar)
            canvas.fillRoundedRect(Rect(0, _radius, 4, maxInt(1, h - _radius * 2)),
                2, _accent);

        const lineCount = (_kicker.length > 0 ? 1 : 0) +
            (_title.length > 0 ? 1 : 0) + (_subtitle.length > 0 ? 1 : 0);
        if (lineCount == 0)
            return;
        const innerHeight = maxInt(lineCount, h - _padding * 2);
        const lineHeight = innerHeight / lineCount;
        int y = _padding + (h - _padding * 2 - lineHeight * lineCount) / 2;
        const textX = _padding + 6;
        const textWidth = maxInt(1, w - _padding * 2 - 6);
        if (_kicker.length > 0)
        {
            canvas.drawTextInRect(Rect(textX, y, textWidth, lineHeight),
                _kicker, _accent, 1, HorizontalAlign.left,
                VerticalAlign.middle, true);
            y += lineHeight;
        }
        if (_title.length > 0)
        {
            canvas.drawTextInRect(Rect(textX, y, textWidth, lineHeight),
                _title, _textColor, lineHeight >= 24 ? 2 : 1,
                HorizontalAlign.left, VerticalAlign.middle, true);
            y += lineHeight;
        }
        if (_subtitle.length > 0)
            canvas.drawTextInRect(Rect(textX, y, textWidth, lineHeight),
                _subtitle, _mutedColor, 1, HorizontalAlign.left,
                VerticalAlign.middle, true);
    }
}

ComponentFactory universalWidgetFactory()
{
    return delegate(ComponentContext context, JSONValue props)
    {
        return new UniversalWidget(props);
    };
}

private string readString(JSONValue props, string key, string fallback)
{
    auto found = key in props.object;
    return found !is null && (*found).type == JSONType.string ? (*found).str : fallback;
}

private bool readBool(JSONValue props, string key, bool fallback)
{
    auto found = key in props.object;
    return found !is null && (*found).type == JSONType.true_ ? true :
        found !is null && (*found).type == JSONType.false_ ? false : fallback;
}

private int readInt(JSONValue props, string key, int fallback, int low, int high)
{
    auto found = key in props.object;
    if (found is null || (*found).type != JSONType.integer)
        return fallback;
    const value = cast(int) (*found).integer;
    return value < low ? low : value > high ? high : value;
}

private Color readColor(JSONValue props, string key, Color fallback)
{
    const text = readString(props, key, "");
    if (text.length != 7 && text.length != 9) return fallback;
    if (text[0] != '#') return fallback;
    try
    {
        const r = to!int(text[1 .. 3], 16);
        const g = to!int(text[3 .. 5], 16);
        const b = to!int(text[5 .. 7], 16);
        const a = text.length == 9 ? to!int(text[7 .. 9], 16) : 255;
        return Color.rgba(r, g, b, a);
    }
    catch (Exception)
        return fallback;
}

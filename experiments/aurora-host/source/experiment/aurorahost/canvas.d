module experiment.aurorahost.canvas;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.types : Point, Rect;
import aurora.widget : Widget;
import std.exception : enforce;
import std.format : format;
import std.utf : toUTF32;

struct CanvasCommand
{
    string op;
    int x;
    int y;
    int x2;
    int y2;
    int width;
    int height;
    int radius;
    int thickness = 1;
    int scale = 2;
    string text;
    Color color;
}

struct CanvasSpec
{
    int width;
    int height;
    int flex;
    bool hasBackground;
    Color background;
    CanvasCommand[] commands;
}

private int hexValue(char digit, string label)
{
    if (digit >= '0' && digit <= '9') return digit - '0';
    if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
    if (digit >= 'A' && digit <= 'F') return digit - 'A' + 10;
    throw new Exception(format("%s contains a non-hex color digit", label));
}

Color parseCanvasColor(string value, string label)
{
    enforce(value.length == 7 || value.length == 9,
        format("%s must be #RRGGBB or #RRGGBBAA", label));
    enforce(value[0] == '#', format("%s must start with #", label));
    const r = hexValue(value[1], label) * 16 + hexValue(value[2], label);
    const g = hexValue(value[3], label) * 16 + hexValue(value[4], label);
    const b = hexValue(value[5], label) * 16 + hexValue(value[6], label);
    const a = value.length == 9 ?
        hexValue(value[7], label) * 16 + hexValue(value[8], label) : 255;
    return Color(cast(ubyte) r, cast(ubyte) g, cast(ubyte) b, cast(ubyte) a);
}

/**
 * Retained custom-drawing leaf. The scene supplies a portable command list;
 * Aurora records it into the normal scene draw list and repaints only when the
 * widget is invalidated.
 */
class CanvasWidget : Widget
{
    private CanvasSpec _spec;

    this(const CanvasSpec spec)
    {
        _spec.width = spec.width;
        _spec.height = spec.height;
        _spec.flex = spec.flex;
        _spec.hasBackground = spec.hasBackground;
        _spec.background = spec.background;
        _spec.commands = spec.commands.dup;
        if (spec.width > 0)
            layoutHints().preferredWidth = spec.width;
        if (spec.height > 0)
            layoutHints().preferredHeight = spec.height;
        if (spec.flex > 0)
            layoutHints().flex = spec.flex;
    }

    void setCommands(CanvasCommand[] commands)
    {
        _spec.commands = commands;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_spec.hasBackground)
            canvas.fillRect(full, _spec.background);

        foreach (command; _spec.commands)
        {
            switch (command.op)
            {
                case "rect":
                    canvas.fillRect(
                        Rect(command.x, command.y, command.width, command.height),
                        command.color);
                    break;
                case "roundedRect":
                    canvas.fillRoundedRect(
                        Rect(command.x, command.y, command.width, command.height),
                        command.radius, command.color);
                    break;
                case "line":
                    canvas.drawLine(
                        Point(command.x, command.y),
                        Point(command.x2, command.y2),
                        command.color, command.thickness);
                    break;
                case "circle":
                    canvas.fillCircle(
                        Point(command.x, command.y),
                        command.radius, command.color);
                    break;
                case "ring":
                    canvas.strokeCircle(
                        Point(command.x, command.y),
                        command.radius, command.color, command.thickness);
                    break;
                case "text":
                    canvas.drawText(
                        Point(command.x, command.y),
                        toUTF32(command.text), command.color, command.scale);
                    break;
                default:
                    break;
            }
        }
    }
}

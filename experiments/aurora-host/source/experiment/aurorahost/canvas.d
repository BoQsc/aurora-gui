module experiment.aurorahost.canvas;

import experiment.aurorahost.events : HostEvent;
import aurora : Canvas, Color, Event, Key, MouseButton, Point, PointF, Rect,
    RgbaImage, Widget;
import std.algorithm : canFind;
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
    string src;
    Color color;
    RgbaImage image;
}

struct CanvasSpec
{
    int width;
    int height;
    int flex;
    bool hasBackground;
    Color background;
    CanvasCommand[] commands;
    string[] events;
    int tickHz;
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
    private bool _pointerEvents;
    private bool _keyEvents;
    private bool _tickEvents;
    private double _tickInterval;
    private double _tickAccumulator;
    private double _time;
    private bool _pressed;

    void delegate(HostEvent) onInput;

    this(const CanvasSpec spec)
    {
        auto source = cast(CanvasSpec) spec;
        _spec.width = source.width;
        _spec.height = source.height;
        _spec.flex = source.flex;
        _spec.hasBackground = source.hasBackground;
        _spec.background = source.background;
        _spec.commands = source.commands.dup;
        _spec.events = source.events.dup;
        _spec.tickHz = source.tickHz;
        configureEvents(source.events, source.tickHz);
        if (spec.width > 0)
            layoutHints().preferredWidth = spec.width;
        if (spec.height > 0)
            layoutHints().preferredHeight = spec.height;
        if (spec.flex > 0)
            layoutHints().flex = spec.flex;
    }

    void configureEvents(string[] events, int tickHz)
    {
        _pointerEvents = events.canFind("pointer");
        _keyEvents = events.canFind("key");
        _tickEvents = events.canFind("tick");
        _tickInterval = tickHz > 0 ? 1.0 / tickHz : 0.0;
        _tickAccumulator = 0.0;
        setFocusable(_keyEvents);
    }

    void setTick(int hz)
    {
        enforce(hz >= 0 && hz <= 240, "tick rate must be between 0 and 240");
        _tickInterval = hz > 0 ? 1.0 / hz : 0.0;
        _tickAccumulator = 0.0;
    }

    void setCommands(CanvasCommand[] commands)
    {
        _spec.commands = commands;
        invalidate();
    }

    private void emit(HostEvent event)
    {
        if (onInput !is null)
            onInput(event);
    }

    private void emitPointer(string kind, int x, int y, MouseButton button,
        uint modifiers, int wheelX = 0, int wheelY = 0)
    {
        HostEvent event;
        event.name = "pointer";
        event.kind = kind;
        event.x = x;
        event.y = y;
        event.wheelX = wheelX;
        event.wheelY = wheelY;
        event.button = button;
        event.modifiers = modifiers;
        emit(event);
    }

    private void emitKey(string kind, Key key, uint modifiers)
    {
        HostEvent event;
        event.name = "key";
        event.kind = kind;
        event.key = key;
        event.modifiers = modifiers;
        emit(event);
    }

    void injectPointer(string kind, int x, int y, MouseButton button,
        uint modifiers, int wheelX = 0, int wheelY = 0)
    {
        if (_pointerEvents)
            emitPointer(kind, x, y, button, modifiers, wheelX, wheelY);
    }

    void injectKey(string kind, Key key, uint modifiers)
    {
        if (_keyEvents)
            emitKey(kind, key, modifiers);
    }

    override bool onMouseDown(ref Event event)
    {
        if (!_pointerEvents || event.button != MouseButton.left)
            return false;
        requestFocus();
        captureMouse();
        _pressed = true;
        emitPointer("down", event.position.x, event.position.y, event.button,
            event.modifiers);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_pointerEvents)
            return false;
        emitPointer("move", event.position.x, event.position.y, event.button,
            event.modifiers);
        return _pressed;
    }

    override bool onMouseUp(ref Event event)
    {
        if (!_pointerEvents || event.button != MouseButton.left)
            return false;
        if (_pressed)
            releaseMouse();
        _pressed = false;
        emitPointer("up", event.position.x, event.position.y, event.button,
            event.modifiers);
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (!_pointerEvents)
            return false;
        emitPointer("wheel", event.position.x, event.position.y, event.button,
            event.modifiers, event.wheelX, event.wheelY);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (!_keyEvents)
            return false;
        emitKey("down", event.key, event.modifiers);
        return true;
    }

    override bool onKeyUp(ref Event event)
    {
        if (!_keyEvents)
            return false;
        emitKey("up", event.key, event.modifiers);
        return true;
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        if (!_pressed || !_pointerEvents)
            return false;
        const local = globalToLocal(globalPosition.rounded());
        emitPointer("move", local.x, local.y, MouseButton.none, 0);
        return true;
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _pressed && _pointerEvents;
    }

    protected override void onTick(double deltaSeconds)
    {
        _time += deltaSeconds;
        if (!_tickEvents || _tickInterval <= 0.0)
            return;
        _tickAccumulator += deltaSeconds;
        if (_tickAccumulator < _tickInterval)
            return;
        HostEvent event;
        event.name = "tick";
        event.kind = "tick";
        event.delta = _tickAccumulator;
        _tickAccumulator = 0.0;
        emit(event);
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
                case "image":
                    if (command.image !is null)
                        canvas.drawImage(
                            Rect(command.x, command.y, command.width,
                                command.height),
                            command.image);
                    break;
                default:
                    break;
            }
        }
    }
}

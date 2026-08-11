module aurora.event;

import aurora.types : DisplayScale, Point, PointF, Size;
import aurora.dragdrop : DragAction, DragActions, DragPayload;

enum EventType : ubyte
{
    none,
    paint,
    resizeStarted,
    resized,
    resizeEnded,
    mouseMove,
    mouseDown,
    mouseUp,
    mouseWheel,
    mouseEnter,
    mouseLeave,
    keyDown,
    keyUp,
    textInput,
    focusGained,
    focusLost,
    tick,
    dragEntered,
    dragMoved,
    dragLeft,
    dropped,
    filesDropped,
    closeRequested
}

enum MouseButton : ubyte
{
    none,
    left,
    middle,
    right,
    extra1,
    extra2
}

enum KeyModifier : uint
{
    none = 0,
    shift = 1u << 0,
    control = 1u << 1,
    alt = 1u << 2,
    meta = 1u << 3,
    capsLock = 1u << 4,
    numLock = 1u << 5
}

bool hasModifier(uint modifiers, KeyModifier modifier) @safe pure nothrow @nogc
{
    return (modifiers & cast(uint) modifier) != 0;
}

enum Key : ushort
{
    unknown,
    backspace,
    tab,
    enter,
    escape,
    space,
    pageUp,
    pageDown,
    end,
    home,
    left,
    up,
    right,
    down,
    insert,
    deleteKey,
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    minus,
    equal,
    leftBracket,
    rightBracket,
    backslash,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash
}

struct Event
{
    EventType type;
    Point position;
    Point globalPosition;
    /** Subpixel logical coordinates derived directly from native pixels. */
    PointF precisePosition;
    PointF preciseGlobalPosition;
    bool hasPrecisePosition;
    Size size;
    Size framebufferSize;
    DisplayScale displayScale;
    MouseButton button;
    int wheelX;
    int wheelY;
    /** Absolute vertical scroll position supplied by a native scrollbar. */
    int verticalScrollPosition;
    bool hasVerticalScrollPosition;
    Key key;
    uint modifiers;
    dstring text;
    /** Native file paths dropped into the host window, when supported. */
    string[] paths;
    /** Rich platform-neutral data associated with a drag/drop event. */
    DragPayload dragPayload;
    /** Source operations available for this drag. */
    DragActions allowedDragActions;
    /** Platform/modifier-derived preferred operation before target policy. */
    DragAction suggestedDragAction;
    /** Operation selected by the target; leave as none to reject. */
    DragAction dragAction;
    bool repeat;
    int clickCount = 1;
    long timestampMs;
    double deltaSeconds = 0.0;

    bool shift() const @safe pure nothrow @nogc
    {
        return hasModifier(modifiers, KeyModifier.shift);
    }

    bool control() const @safe pure nothrow @nogc
    {
        return hasModifier(modifiers, KeyModifier.control);
    }

    bool alt() const @safe pure nothrow @nogc
    {
        return hasModifier(modifiers, KeyModifier.alt);
    }

    bool meta() const @safe pure nothrow @nogc
    {
        return hasModifier(modifiers, KeyModifier.meta);
    }
}

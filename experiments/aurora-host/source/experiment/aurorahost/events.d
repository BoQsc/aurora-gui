module experiment.aurorahost.events;

import aurora.event : Key, MouseButton;
import std.conv : to;

/** A host-neutral event delivered to a scene node or the control client. */
struct HostEvent
{
    string node;
    string name;
    string kind;
    int x;
    int y;
    int wheelX;
    int wheelY;
    MouseButton button;
    Key key;
    uint modifiers;
    double delta;
    size_t cursor;
    size_t anchor;
    size_t length;
    int line;
    int column;
}

string buttonName(MouseButton button)
{
    switch (button)
    {
        case MouseButton.left: return "left";
        case MouseButton.middle: return "middle";
        case MouseButton.right: return "right";
        case MouseButton.extra1: return "extra1";
        case MouseButton.extra2: return "extra2";
        default: return "none";
    }
}

string keyName(Key key)
{
    switch (key)
    {
        case Key.backspace: return "backspace";
        case Key.tab: return "tab";
        case Key.enter: return "enter";
        case Key.escape: return "escape";
        case Key.space: return "space";
        case Key.pageUp: return "pageUp";
        case Key.pageDown: return "pageDown";
        case Key.end: return "end";
        case Key.home: return "home";
        case Key.left: return "left";
        case Key.up: return "up";
        case Key.right: return "right";
        case Key.down: return "down";
        case Key.insert: return "insert";
        case Key.deleteKey: return "delete";
        case Key.minus: return "minus";
        case Key.equal: return "equal";
        case Key.leftBracket: return "leftBracket";
        case Key.rightBracket: return "rightBracket";
        case Key.backslash: return "backslash";
        case Key.semicolon: return "semicolon";
        case Key.apostrophe: return "apostrophe";
        case Key.grave: return "grave";
        case Key.comma: return "comma";
        case Key.period: return "period";
        case Key.slash: return "slash";
        default: break;
    }
    if (key >= Key.a && key <= Key.z)
        return to!string(cast(char) ('a' + cast(int) key - cast(int) Key.a));
    if (key >= Key.digit0 && key <= Key.digit9)
        return to!string(cast(char) ('0' + cast(int) key - cast(int) Key.digit0));
    if (key >= Key.f1 && key <= Key.f12)
        return "f" ~ to!string(cast(int) key - cast(int) Key.f1 + 1);
    return "unknown";
}

module auroraremote.input;

import aurora.event : Key, KeyModifier, MouseButton;

enum RemoteInputKind : ubyte
{
    mouseMove = 1,
    mouseButton = 2,
    mouseWheel = 3,
    keyPress = 4
}

ubyte[] mouseMovePacket(ushort x, ushort y)
{
    return [cast(ubyte) RemoteInputKind.mouseMove,
        cast(ubyte)(x >> 8), cast(ubyte) x,
        cast(ubyte)(y >> 8), cast(ubyte) y];
}

ubyte[] mouseButtonPacket(MouseButton button, bool down)
{
    return [cast(ubyte) RemoteInputKind.mouseButton,
        cast(ubyte) button, cast(ubyte)(down ? 1 : 0)];
}

ubyte[] mouseWheelPacket(short delta)
{
    return [cast(ubyte) RemoteInputKind.mouseWheel,
        cast(ubyte)(cast(ushort) delta >> 8), cast(ubyte) delta];
}

ubyte[] keyPressPacket(Key key, uint modifiers)
{
    return [cast(ubyte) RemoteInputKind.keyPress,
        cast(ubyte)(cast(ushort) key >> 8), cast(ubyte) key,
        cast(ubyte)(modifiers >> 24), cast(ubyte)(modifiers >> 16),
        cast(ubyte)(modifiers >> 8), cast(ubyte) modifiers];
}

version (Windows)
{
    import core.sys.windows.windows : DWORD, INPUT, INPUT_KEYBOARD, INPUT_MOUSE,
        KEYEVENTF_KEYUP, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
        MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
        MOUSEEVENTF_WHEEL, SendInput, VK_BACK, VK_CONTROL, VK_DELETE, VK_DOWN,
        VK_END, VK_ESCAPE, VK_F1, VK_HOME, VK_INSERT, VK_LEFT, VK_MENU,
        VK_NEXT, VK_OEM_1, VK_OEM_2, VK_OEM_3, VK_OEM_4, VK_OEM_5,
        VK_OEM_6, VK_OEM_7, VK_OEM_COMMA, VK_OEM_MINUS, VK_OEM_PERIOD,
        VK_OEM_PLUS, VK_PRIOR, VK_RETURN, VK_RIGHT, VK_SHIFT, VK_SPACE,
        VK_TAB, VK_UP;

    private enum DWORD MOUSEEVENTF_VIRTUALDESK = 0x4000;

    private ushort virtualKey(Key key)
    {
        if (key >= Key.a && key <= Key.z)
            return cast(ushort)('A' + (key - Key.a));
        if (key >= Key.digit0 && key <= Key.digit9)
            return cast(ushort)('0' + (key - Key.digit0));
        if (key >= Key.f1 && key <= Key.f12)
            return cast(ushort)(VK_F1 + (key - Key.f1));
        switch (key)
        {
            case Key.backspace: return VK_BACK;
            case Key.tab: return VK_TAB;
            case Key.enter: return VK_RETURN;
            case Key.escape: return VK_ESCAPE;
            case Key.space: return VK_SPACE;
            case Key.pageUp: return VK_PRIOR;
            case Key.pageDown: return VK_NEXT;
            case Key.end: return VK_END;
            case Key.home: return VK_HOME;
            case Key.left: return VK_LEFT;
            case Key.up: return VK_UP;
            case Key.right: return VK_RIGHT;
            case Key.down: return VK_DOWN;
            case Key.insert: return VK_INSERT;
            case Key.deleteKey: return VK_DELETE;
            case Key.minus: return VK_OEM_MINUS;
            case Key.equal: return VK_OEM_PLUS;
            case Key.leftBracket: return VK_OEM_4;
            case Key.rightBracket: return VK_OEM_6;
            case Key.backslash: return VK_OEM_5;
            case Key.semicolon: return VK_OEM_1;
            case Key.apostrophe: return VK_OEM_7;
            case Key.grave: return VK_OEM_3;
            case Key.comma: return VK_OEM_COMMA;
            case Key.period: return VK_OEM_PERIOD;
            case Key.slash: return VK_OEM_2;
            case Key.unknown: return 0;
            default: return 0;
        }
    }

    private void sendKeyboard(ushort key, bool up)
    {
        INPUT input;
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = key;
        input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        SendInput(1, &input, INPUT.sizeof);
    }

    private void pressKey(ushort key, uint modifiers)
    {
        if (key == 0) return;
        const shift = (modifiers & KeyModifier.shift) != 0;
        const control = (modifiers & KeyModifier.control) != 0;
        const alt = (modifiers & KeyModifier.alt) != 0;
        if (shift) sendKeyboard(VK_SHIFT, false);
        if (control) sendKeyboard(VK_CONTROL, false);
        if (alt) sendKeyboard(VK_MENU, false);
        sendKeyboard(key, false);
        sendKeyboard(key, true);
        if (alt) sendKeyboard(VK_MENU, true);
        if (control) sendKeyboard(VK_CONTROL, true);
        if (shift) sendKeyboard(VK_SHIFT, true);
    }

    void applyRemoteInput(const(ubyte)[] packet)
    {
        if (packet.length == 0) return;
        const kind = cast(RemoteInputKind) packet[0];
        INPUT input;
        if (kind == RemoteInputKind.mouseMove && packet.length == 5)
        {
            input.type = INPUT_MOUSE;
            input.mi.dx = cast(int)((cast(uint) packet[1] << 8) | packet[2]);
            input.mi.dy = cast(int)((cast(uint) packet[3] << 8) | packet[4]);
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                MOUSEEVENTF_VIRTUALDESK;
            SendInput(1, &input, INPUT.sizeof);
        }
        else if (kind == RemoteInputKind.mouseButton && packet.length == 3)
        {
            input.type = INPUT_MOUSE;
            const down = packet[2] != 0;
            if (packet[1] == MouseButton.left)
                input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
            else if (packet[1] == MouseButton.right)
                input.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
            else if (packet[1] == MouseButton.middle)
                input.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
            if (input.mi.dwFlags != 0) SendInput(1, &input, INPUT.sizeof);
        }
        else if (kind == RemoteInputKind.mouseWheel && packet.length == 3)
        {
            input.type = INPUT_MOUSE;
            const delta = cast(short)((cast(ushort) packet[1] << 8) | packet[2]);
            input.mi.mouseData = cast(DWORD) cast(int) delta;
            input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            SendInput(1, &input, INPUT.sizeof);
        }
        else if (kind == RemoteInputKind.keyPress && packet.length == 7)
        {
            const key = cast(Key)((cast(ushort) packet[1] << 8) | packet[2]);
            const modifiers = (cast(uint) packet[3] << 24) |
                (cast(uint) packet[4] << 16) |
                (cast(uint) packet[5] << 8) | packet[6];
            pressKey(virtualKey(key), modifiers);
        }
    }
}
else void applyRemoteInput(const(ubyte)[] packet) {}

module aurora.theme;

import aurora.color : Color;
import aurora.font : FontFace, TextScale;

struct Theme
{
    Color windowBackground;
    Color panelBackground;
    Color panelElevated;
    Color text;
    Color textMuted;
    Color border;
    Color accent;
    Color accentHover;
    Color accentPressed;
    Color selection;
    Color selectionText;
    Color fieldBackground;
    Color buttonBackground;
    Color buttonHover;
    Color buttonPressed;
    Color disabled;
    Color danger;
    Color taskbar;
    Color taskbarHover;
    Color shadow;

    FontFace uiFont;
    FontFace monospaceFont;

    int cornerRadius = 6;
    int borderWidth = 1;
    int controlHeight = 38;
    // The default body tier maps to a readable 17 px logical EM size.
    int fontScale = cast(int) TextScale.body;
    int spacing = 8;

    static Theme light() @safe pure nothrow @nogc
    {
        Theme t;
        t.windowBackground = Color.fromHex(0xf4f6f8);
        t.panelBackground = Color.fromHex(0xffffff);
        t.panelElevated = Color.fromHex(0xffffff);
        t.text = Color.fromHex(0x20242a);
        t.textMuted = Color.fromHex(0x66707a);
        t.border = Color.fromHex(0xc9d0d8);
        t.accent = Color.fromHex(0x246bfd);
        t.accentHover = Color.fromHex(0x3d7cff);
        t.accentPressed = Color.fromHex(0x1855cf);
        t.selection = Color.fromHex(0xbfd5ff);
        t.selectionText = Color.fromHex(0x10234a);
        t.fieldBackground = Color.fromHex(0xffffff);
        t.buttonBackground = Color.fromHex(0xe8edf3);
        t.buttonHover = Color.fromHex(0xdce5ee);
        t.buttonPressed = Color.fromHex(0xcbd7e4);
        t.disabled = Color.fromHex(0xaab1b9);
        t.danger = Color.fromHex(0xd94b4b);
        t.taskbar = Color.fromHex(0x1f252d, 246);
        t.taskbarHover = Color.fromHex(0x37414d);
        t.shadow = Color.rgba(0, 0, 0, 70);
        return t;
    }

    static Theme dark() @safe pure nothrow @nogc
    {
        Theme t;
        t.windowBackground = Color.fromHex(0x171b21);
        t.panelBackground = Color.fromHex(0x20262e);
        t.panelElevated = Color.fromHex(0x2a323d);
        t.text = Color.fromHex(0xf1f4f8);
        t.textMuted = Color.fromHex(0xaab4c0);
        t.border = Color.fromHex(0x424d59);
        t.accent = Color.fromHex(0x4f8cff);
        t.accentHover = Color.fromHex(0x6ca0ff);
        t.accentPressed = Color.fromHex(0x3974df);
        t.selection = Color.fromHex(0x315b99);
        t.selectionText = Color.fromHex(0xffffff);
        t.fieldBackground = Color.fromHex(0x151a20);
        t.buttonBackground = Color.fromHex(0x303945);
        t.buttonHover = Color.fromHex(0x3b4755);
        t.buttonPressed = Color.fromHex(0x222a33);
        t.disabled = Color.fromHex(0x6e7883);
        t.danger = Color.fromHex(0xff6b6b);
        t.taskbar = Color.fromHex(0x11161d, 244);
        t.taskbarHover = Color.fromHex(0x2a333e);
        t.shadow = Color.rgba(0, 0, 0, 120);
        return t;
    }
}

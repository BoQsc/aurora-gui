/** Aurora Write's calm paper palette. */
module aurorawrite.theme;

import aurora : Color, Theme, TextScale;

/// The writing surface theme: warm paper with deep ink, or charcoal at night.
Theme writeTheme(bool dark)
{
    auto theme = dark ? Theme.dark() : Theme.light();
    if (dark)
    {
        theme.windowBackground = Color.fromHex(0x121417);
        theme.panelBackground = Color.fromHex(0x181b1f);
        theme.panelElevated = Color.fromHex(0x23272d);
        theme.text = Color.fromHex(0xe8e4de);
        theme.textMuted = Color.fromHex(0x99a1ab);
        theme.border = Color.fromHex(0x353c44);
        theme.accent = Color.fromHex(0x5ec8b6);
        theme.accentHover = Color.fromHex(0x77d7c6);
        theme.accentPressed = Color.fromHex(0x45b2a1);
        theme.selection = Color.fromHex(0x2b4b47);
        theme.selectionText = Color.fromHex(0xf2fbf9);
        theme.fieldBackground = Color.fromHex(0x181b1f);
        theme.buttonBackground = Color.fromHex(0x262b31);
        theme.buttonHover = Color.fromHex(0x30363d);
        theme.buttonPressed = Color.fromHex(0x22272c);
        theme.disabled = Color.fromHex(0x6b747e);
        theme.danger = Color.fromHex(0xf4736a);
        theme.shadow = Color.rgba(0, 0, 0, 150);
    }
    else
    {
        theme.windowBackground = Color.fromHex(0xf7f4ee);
        theme.panelBackground = Color.fromHex(0xfffdf9);
        theme.panelElevated = Color.fromHex(0xfffdf9);
        theme.text = Color.fromHex(0x1e2328);
        theme.textMuted = Color.fromHex(0x6d757d);
        theme.border = Color.fromHex(0xdcd6cc);
        theme.accent = Color.fromHex(0x0f766e);
        theme.accentHover = Color.fromHex(0x0d8b81);
        theme.accentPressed = Color.fromHex(0x0a5f58);
        theme.selection = Color.fromHex(0xcfe9e4);
        theme.selectionText = Color.fromHex(0x10231f);
        theme.fieldBackground = Color.fromHex(0xfffdf9);
        theme.buttonBackground = Color.fromHex(0xf0ece3);
        theme.buttonHover = Color.fromHex(0xe6e0d5);
        theme.buttonPressed = Color.fromHex(0xd9d2c5);
        theme.disabled = Color.fromHex(0xb2aba0);
        theme.danger = Color.fromHex(0xc0392b);
        theme.shadow = Color.rgba(60, 50, 40, 60);
    }
    theme.cornerRadius = 8;
    theme.controlHeight = 34;
    theme.fontScale = cast(int) TextScale.body;
    theme.spacing = 8;
    return theme;
}

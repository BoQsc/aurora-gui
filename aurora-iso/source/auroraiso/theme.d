/**
 * Aurora ISO visual theme: a calm slate-blue palette that gives the toolkit a
 * distinct identity from the other Aurora apps while staying legible.
 */
module auroraiso.theme;

import aurora;

public Theme auroraIsoTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x101418);
    theme.panelBackground = Color.fromHex(0x181e24);
    theme.panelElevated = Color.fromHex(0x202830);
    theme.text = Color.fromHex(0xeef2f6);
    theme.textMuted = Color.fromHex(0x93a0ac);
    theme.border = Color.fromHex(0x33404c);
    theme.accent = Color.fromHex(0x39a0ff);
    theme.accentHover = Color.fromHex(0x5cb4ff);
    theme.accentPressed = Color.fromHex(0x2a7fd0);
    theme.selection = Color.fromHex(0x25506f);
    theme.selectionText = Color.fromHex(0xffffff);
    theme.fieldBackground = Color.fromHex(0x0d1115);
    theme.buttonBackground = Color.fromHex(0x263039);
    theme.buttonHover = Color.fromHex(0x2f3b46);
    theme.buttonPressed = Color.fromHex(0x1d252c);
    theme.disabled = Color.fromHex(0x66717c);
    theme.danger = Color.fromHex(0xff6b6b);
    theme.cornerRadius = 7;
    theme.controlHeight = 34;
    return theme;
}

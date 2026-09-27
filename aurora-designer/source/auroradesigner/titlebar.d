module auroradesigner.titlebar;

import aurora;

/**
 * The Aurora Designer titlebar.
 *
 * Frameless window chrome built on the vendored `TitleBar` exactly like the
 * Notepad's: slim bar, compact Win10-style caption buttons, owner-driven
 * window move, work-area maximize/restore, restore-on-drag, drag snapping,
 * and an owner-drawn system menu.
 */
final class DesignerTitleBar : FramelessWindowTitleBar
{
    private bool _dark;

    this(GuiWindow window)
    {
        super(window);
        setTitle("Untitled — Aurora Designer");
        setIcon(IconKind.settings);
        setBarHeight(28);
        setIconSize(14);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(36);
        setTitleFontSize(12);
        setDarkMode(true);

    }

    /// Re-apply the designer palette (dark by default).
    void setDarkMode(bool dark)
    {
        _dark = dark;
        if (dark)
        {
            setBackground(Color.fromHex(0x202020));
            setInactiveBackground(Color.fromHex(0x191919));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0xffffff));
            setMutedTextColor(Color.fromHex(0xa0a0a0));
            setButtonHoverColor(Color.fromHex(0x3c3c3c));
            setButtonPressedColor(Color.fromHex(0x4a4a4a));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
        else
        {
            setBackground(Color.fromHex(0xf5f5f5));
            setInactiveBackground(Color.fromHex(0xe8e8e8));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x6a6a6a));
            setButtonHoverColor(Color.fromHex(0xe5e5e5));
            setButtonPressedColor(Color.fromHex(0xcccccc));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    bool darkMode() const @safe pure nothrow @nogc { return _dark; }

    void setDocumentTitle(string name, bool dirty)
    {
        setTitle((dirty ? "*" : "") ~ name ~ " — Aurora Designer");
    }
}

/** The Aurora Write window titlebar. */
module aurorawrite.titlebar;

import aurora : Color, FramelessWindowTitleBar, GuiWindow, HorizontalAlign;

/** Product identity only: Aurora owns movement, snapping and the system menu. */
final class WriteTitleBar : FramelessWindowTitleBar
{
    this(GuiWindow window)
    {
        super(window);
        setTitle("Untitled — Aurora Write");
        setBarHeight(38);
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(44);
        setTitleFontSize(13);
        setDarkMode(false);
    }

    void setDarkMode(bool dark)
    {
        if (dark)
        {
            setBackground(Color.fromHex(0x121417));
            setInactiveBackground(Color.fromHex(0x0e1013));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0xe8e4de));
            setMutedTextColor(Color.fromHex(0x99a1ab));
            setButtonHoverColor(Color.fromHex(0x262b31));
            setButtonPressedColor(Color.fromHex(0x1b1f23));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
        else
        {
            setBackground(Color.fromHex(0xf7f4ee));
            setInactiveBackground(Color.fromHex(0xefeae1));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1e2328));
            setMutedTextColor(Color.fromHex(0x6d757d));
            setButtonHoverColor(Color.fromHex(0xe6e0d5));
            setButtonPressedColor(Color.fromHex(0xd9d2c5));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    /// Show the document name and an unsaved marker.
    void setDocumentTitle(string name, bool dirty)
    {
        setTitle((dirty ? "*" : "") ~ name ~ " — Aurora Write");
    }
}

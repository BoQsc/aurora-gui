module auroranotepad.titlebar;

import aurora;
import auroranotepad.notepadsize : NotepadCaptionButtonWidth,
    NotepadStatusFontPixelSize, NotepadTitleBarHeight;

/**
 * The Aurora Notepad titlebar.
 *
 * Product identity and palette stay local. Aurora's
 * `FramelessWindowTitleBar` owns movement, maximize/restore,
 * restore-on-drag, snapping, preview mapping, and the system menu.
 */
final class NotepadTitleBar : FramelessWindowTitleBar
{
    this(GuiWindow window)
    {
        super(window);

        setTitle("Untitled — Aurora Notepad");
        setIcon(IconKind.notepad);
        setBarHeight(NotepadTitleBarHeight);
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(NotepadCaptionButtonWidth);
        setTitleFontSize(NotepadStatusFontPixelSize);
        setDarkMode(false);
    }

    /** Re-apply the Notepad light or dark palette (Windows 10). */
    void setDarkMode(bool dark)
    {
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
            setBackground(Color.fromHex(0xffffff));
            setInactiveBackground(Color.fromHex(0xf0f0f0));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x6a6a6a));
            setButtonHoverColor(Color.fromHex(0xe5e5e5));
            setButtonPressedColor(Color.fromHex(0xcccccc));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    /** Update the visible title from a document name and dirty marker. */
    void setDocumentTitle(string name, bool dirty)
    {
        setTitle((dirty ? "*" : "") ~ name ~ " — Aurora Notepad");
    }
}

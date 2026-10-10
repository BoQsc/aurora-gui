module auroraopencode.titlebar;

import aurora;
import auroraopencode.core : opencodeBackground, opencodeMuted,
    opencodePressed, opencodeSelection, opencodeText, opencodeTitleBarHeight;
import std.datetime : SysTime;
import std.file : thisExePath, timeLastModified;
import std.format : format;

/// `YYYY-MM-DD HH:MM UTC`, when the running executable was linked, rendered in
/// UTC so the same binary shows the identical stamp on any machine regardless
/// of the viewing computer's timezone.
private string executableBuildStamp()
{
    try
    {
        const built = timeLastModified(thisExePath()).toUTC();
        return format("%04d-%02d-%02d %02d:%02d UTC",
            built.year, cast(int) built.month, built.day,
            built.hour, built.minute);
    }
    catch (Exception)
    {
        return "";
    }
}

/**
 * The Aurora OpenCode Pro titlebar.
 *
 * The product owns its identity, palette, and merged toolbar content. Aurora's
 * `FramelessWindowTitleBar` owns movement, maximize/restore,
 * restore-on-drag, snapping, preview mapping, and the system menu.
 */
public final class OpenCodeTitleBar : FramelessWindowTitleBar
{
    public static immutable int titleBarHeight = opencodeTitleBarHeight;

    this(GuiWindow window)
    {
        super(window);
        const stamp = executableBuildStamp();
        const title = stamp.length > 0
            ? "Aurora OpenCode  " ~ stamp
            : "Aurora OpenCode";
        setTitle(title);
        setTitleWidth(measuredTitleWidth(title));
        setIcon(IconKind.terminal);
        setBarHeight(titleBarHeight);
        layoutHints().preferredHeight = titleBarHeight;
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(46);
        applyPalette();
    }

    /// Width that fits `text` at the caption font plus a small side pad.
    private int measuredTitleWidth(string text)
    {
        import std.utf : toUTF32;

        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast(FontFace) palette.uiFont;
        options.pixelSize = fontPixelSize(palette.fontScale);
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(toUTF32(text), options)
            .measuredSize();
        return maxInt(120, measured.width + 16);
    }

    private void applyPalette()
    {
        setBackground(opencodeBackground);
        setInactiveBackground(opencodeBackground.lighter(6));
        setBorderColor(Color.rgba(0, 0, 0, 0));
        setTextColor(opencodeText);
        setMutedTextColor(opencodeMuted);
        setButtonHoverColor(opencodePressed);
        setButtonPressedColor(opencodeSelection);
        setCloseHoverColor(Color.fromHex(0xe81123));
        setClosePressedColor(Color.fromHex(0xc42b1c));
    }
}

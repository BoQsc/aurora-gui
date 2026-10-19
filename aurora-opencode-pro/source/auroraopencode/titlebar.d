module auroraopencode.titlebar;

import aurora;
import auroraopencode.core : opencodeAccent, opencodeBackground, opencodeMuted,
    opencodePressed, opencodeSelection, opencodeText, opencodeTitleBarHeight;
import std.datetime : SysTime, UTC;
import std.file : thisExePath, timeLastModified;
import std.format : format;
import std.stdio : File;

/// `YYYY.MM.DD`, when the running executable was linked, rendered in UTC so the
/// same binary shows the identical stamp on any machine regardless of the
/// viewing computer's timezone.
///
/// The time comes from the PE header's link timestamp that the toolchain bakes
/// into the binary, not from the file's last-write time. An update installs a
/// downloaded release by replacing the EXE, which rewrites the file's mtime and
/// so would report the *install* time; the header value travels inside the
/// binary, so it keeps reporting the build time through any copy or rename. The
/// file mtime is only a fallback for a header that cannot be read.
private string executableBuildStamp()
{
    const exe = thisExePath();
    SysTime built;
    if (!peLinkTime(exe, built))
    {
        try built = timeLastModified(exe).toUTC();
        catch (Exception) return "";
    }
    return format("%04d.%02d.%02d", built.year, cast(int) built.month,
        built.day);
}

/// The link time recorded in `path`'s PE header, in UTC. False when the file is
/// missing, too small, not a PE image, or carries a zero timestamp.
private bool peLinkTime(string path, out SysTime when)
{
    enum size_t headerBytes = 0x400;
    auto head = new ubyte[headerBytes];
    size_t length;
    try
    {
        auto file = File(path, "rb");
        scope (exit) file.close();
        length = file.rawRead(head).length;
    }
    catch (Exception) return false;
    if (length < 0x40) return false;
    // The DOS stub stores the PE header offset at 0x3c; the header starts with
    // "PE\0\0" + a COFF header whose first field is the link time.
    const lfanew = readU32le(head, 0x3c);
    if (lfanew == 0 || lfanew + 12 > length) return false;
    if (head[lfanew] != cast(ubyte) 'P' ||
        head[lfanew + 1] != cast(ubyte) 'E' ||
        head[lfanew + 2] != 0 || head[lfanew + 3] != 0)
        return false;
    const stamp = readU32le(head, lfanew + 8);
    if (stamp == 0) return false;
    when = SysTime.fromUnixTime(cast(long) stamp, UTC());
    return true;
}

/// A little-endian `uint` at `offset`, the layout PE uses for its fields.
private uint readU32le(const(ubyte)[] bytes, size_t offset)
{
    return cast(uint) bytes[offset] |
        (cast(uint) bytes[offset + 1] << 8) |
        (cast(uint) bytes[offset + 2] << 16) |
        (cast(uint) bytes[offset + 3] << 24);
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
    // The release-edition mark drawn right of the product name, as in the
    // release artwork.
    private enum int proChipWidth = 34;
    private enum int proChipHeight = 16;
    private enum int proChipGap = 8;
    private int _preferredTitleWidth;

    this(GuiWindow window)
    {
        super(window);
        const stamp = executableBuildStamp();
        const title = stamp.length > 0
            ? "Aurora OpenCode  " ~ stamp
            : "Aurora OpenCode";
        setTitle(title);
        // Reserve the chip inside the same band, so the toolbar content that
        // follows always starts after it instead of overlapping.
        _preferredTitleWidth = measuredTitleWidth(title) + proChipGap +
            proChipWidth;
        setTitleMinWidth(1);
        setTitleWidth(_preferredTitleWidth);
        setIcon(IconKind.terminal);
        setBarHeight(titleBarHeight);
        layoutHints().preferredHeight = titleBarHeight;
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(46);
        applyPalette();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        super.onPaint(canvas);
        const band = titleRect();
        if (band.width < proChipWidth + 4 || band.height <= 0) return;
        // The base titlebar paints plain title text only, so the "Pro" chip is
        // drawn here, inside the room the constructor reserved for it.
        const rect = Rect(band.right() - proChipWidth - 2,
            (bounds().height - proChipHeight) / 2, proChipWidth, proChipHeight);
        canvas.drawRoundedRect(rect, proChipHeight / 2,
            opencodeAccent.withAlpha(38), opencodeAccent.withAlpha(140), 1);
        canvas.drawTextInRect(rect, "Pro"d, opencodeAccent, 1,
            HorizontalAlign.center, VerticalAlign.middle, false);
    }

    protected override void onLayout()
    {
        if (content() !is null && bounds().width > 0)
        {
            const actionsWidth = content().measure().width;
            const titleSpace = titleRect().width + contentRect().width - actionsWidth;
            setTitleWidth(maxInt(1, minInt(_preferredTitleWidth, titleSpace)));
        }
        super.onLayout();
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

module aurorastream.bitratedropdown;

import aurora;
import std.format : format;

/// Selector for a video bitrate override in kbps. 0 means "Auto" — the value
/// derived from the selected quality preset (1080p=12 Mbps, 1440p=24 Mbps,
/// 4K=35 Mbps).
final class BitrateDropdown : Button
{
    private int _selectedKbps;

    void delegate(int selectedKbps) onChanged;

    this(int selectedKbps = 0)
    {
        super("");
        _selectedKbps = normalized(selectedKbps);
        onClick = delegate() { openBitrateMenu(); };
        updateCaption();
    }

    int selectedKbps() const @safe pure nothrow @nogc
    {
        return _selectedKbps;
    }

    void setSelectedKbps(int value, bool notify = true)
    {
        const next = normalized(value);
        if (next == _selectedKbps) return;
        _selectedKbps = next;
        updateCaption();
        if (notify && onChanged !is null) onChanged(_selectedKbps);
    }

    private static int[] options() @safe pure nothrow
    {
        return [0, 6_000, 9_000, 12_000, 16_000, 24_000, 35_000];
    }

    private static int normalized(int value) @safe pure nothrow
    {
        foreach (option; options())
            if (option == value) return value;
        return 0;
    }

    private static string caption(int kbps) @safe pure
    {
        if (kbps == 0) return "Auto";
        return format("%d Mbps", kbps / 1000);
    }

    private void updateCaption()
    {
        setText(caption(_selectedKbps) ~ "  ▼");
        layoutHints().minWidth = 110;
        layoutHints().preferredWidth = 120;
    }

    private ContextMenuItem item(int kbps)
    {
        const captured = kbps;
        return ContextMenuItem.check(caption(kbps) ~
            (kbps == 0 ? " (from quality)" : " CBR"),
            _selectedKbps == kbps,
            delegate() { setSelectedKbps(captured); });
    }

    private void openBitrateMenu()
    {
        ContextMenuItem[] items;
        foreach (kbps; options())
            items ~= item(kbps);
        showContextMenuBelow(this, items);
    }
}

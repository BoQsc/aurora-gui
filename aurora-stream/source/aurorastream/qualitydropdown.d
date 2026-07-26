module aurorastream.qualitydropdown;

import aurora;
import aurorastream.broadcast : BroadcastQuality;

/** Compact selector for the one common source-canvas resolution. */
final class SourceQualityDropdown : Button
{
    private BroadcastQuality _selectedQuality;

    void delegate(BroadcastQuality selectedQuality) onChanged;

    this(BroadcastQuality selectedQuality = BroadcastQuality.fullHD)
    {
        super("");
        _selectedQuality = normalizedQuality(selectedQuality);
        onClick = delegate() { openQualityMenu(); };
        updateCaption();
    }

    BroadcastQuality selectedQuality() const @safe pure nothrow @nogc
    {
        return _selectedQuality;
    }

    void setSelectedQuality(BroadcastQuality value, bool notify = true)
    {
        const next = normalizedQuality(value);
        if (next == _selectedQuality) return;
        _selectedQuality = next;
        updateCaption();
        if (notify && onChanged !is null) onChanged(_selectedQuality);
    }

    private static BroadcastQuality normalizedQuality(BroadcastQuality value)
        @safe pure nothrow @nogc
    {
        switch (value)
        {
            case BroadcastQuality.twoK:
            case BroadcastQuality.fourK:
                return value;
            default:
                return BroadcastQuality.fullHD;
        }
    }

    private static string caption(BroadcastQuality quality)
    {
        switch (quality)
        {
            case BroadcastQuality.twoK:
                return "1440p60 / 2K — 2560×1440";
            case BroadcastQuality.fourK:
                return "2160p60 / 4K — 3840×2160";
            default:
                return "1080p60 — 1920×1080";
        }
    }

    private static string menuLabel(BroadcastQuality quality)
    {
        if (quality == BroadcastQuality.fullHD)
            return caption(quality) ~ " (default)";
        return caption(quality);
    }

    private void updateCaption()
    {
        setText(caption(_selectedQuality) ~ "  ▼");
        layoutHints().minWidth = 280;
        layoutHints().preferredWidth = 500;
    }

    private ContextMenuItem qualityItem(BroadcastQuality quality)
    {
        const captured = quality;
        return ContextMenuItem.check(menuLabel(quality),
            _selectedQuality == quality,
            delegate() { setSelectedQuality(captured); });
    }

    private void openQualityMenu()
    {
        ContextMenuItem[] items = [
            qualityItem(BroadcastQuality.fullHD),
            qualityItem(BroadcastQuality.twoK),
            qualityItem(BroadcastQuality.fourK)
        ];

        showContextMenuBelow(this, items);
    }
}

unittest
{
    auto dropdown = new SourceQualityDropdown();
    assert(dropdown.selectedQuality() == BroadcastQuality.fullHD);
    dropdown.setSelectedQuality(BroadcastQuality.twoK, false);
    assert(dropdown.selectedQuality() == BroadcastQuality.twoK);
    dropdown.setSelectedQuality(BroadcastQuality.fourK, false);
    assert(dropdown.selectedQuality() == BroadcastQuality.fourK);
}

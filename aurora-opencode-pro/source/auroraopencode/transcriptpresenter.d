module auroraopencode.transcriptpresenter;

import aurora : VBox, Widget, ScrollView, Size, Rect, Insets, maxInt;

/// Retain row instances by item identity and presentation revision. The caller
/// supplies the revision key; this cache owns no conversation execution state.
public final class StableRowCache(T, Version)
{
    private struct Entry { T row; Version presentation; ulong used; }
    private Entry[string] _entries;
    private ulong _projection;
    private string _thread;
    void begin(string thread)
    {
        if (thread != _thread) { _entries = null; _thread = thread; }
        ++_projection;
    }
    T find(string id, const ref Version presentation)
    {
        auto entry = id in _entries;
        if (entry is null || entry.presentation != presentation) return T.init;
        entry.used = _projection;
        return entry.row;
    }
    void remember(string id, Version presentation, T row)
    {
        _entries[id] = Entry(row, presentation, _projection);
    }
    void end()
    {
        string[] expired;
        foreach (id, entry; _entries) if (entry.used != _projection) expired ~= id;
        foreach (id; expired) _entries.remove(id);
    }
}

/// Long materialized pages lay out only the viewport plus overscan. Offscreen
/// row heights remain in the index; estimates are corrected when visited.
/// Short pages retain exact eager measurement for existing paging behavior.
public final class TranscriptPresenter : VBox
{
    private struct Height { int width = -1; int pixels = 64; ulong revision; bool known; }
    private Height[Widget] _heights;
    private bool[Widget] _virtualHidden;
    private int[] _rowHeights;
    private int _totalHeight;
    private enum size_t virtualThreshold = 400;
    private enum int overscan = 700;
    bool delegate() following;
    void delegate(int) onAnchorCorrection;

    this(int spacing = 0, Insets padding = Insets(0)) { super(spacing, padding); }

    void beginProjection()
    {
        foreach (row; _virtualHidden.keys) row.setVisible(true);
        _virtualHidden = null;
    }

    void endProjection()
    {
        Height[Widget] kept;
        foreach (row; children())
            if (auto height = row in _heights) kept[row] = *height;
        _heights = kept;
    }

    private ScrollView viewport()
    {
        for (auto node = parent(); node !is null; node = node.parent())
            if (auto view = cast(ScrollView) node) return view;
        return null;
    }

    protected override Size onMeasure(Size available)
    {
        if (children().length < virtualThreshold) return super.onMeasure(available);
        auto view = viewport();
        const pad = padding();
        const width = maxInt(0, available.width - pad.left - pad.right);
        const page = view !is null ? maxInt(1, view.bounds().height) : 700;
        const top = view !is null ? view.scrollY() : 0;
        const follow = following !is null && following();
        const estimatedBottom = maxInt(_totalHeight, cast(int) children().length * 64);
        const lower = follow ? maxInt(0, estimatedBottom - page - overscan) : maxInt(0, top - overscan);
        const upper = follow ? int.max : top + page + overscan;
        _rowHeights.length = children().length;
        int cursor = pad.top;
        int correction;
        foreach (i, row; children())
        {
            auto old = row in _heights;
            Height height = old is null ? Height.init : *old;
            const before = height.pixels;
            const intrinsicallyVisible = row.visible() || row in _virtualHidden;
            if (!intrinsicallyVisible) height.pixels = 0;
            else if (cursor + before >= lower && cursor <= upper)
            {
                row.setVisible(true);
                _virtualHidden.remove(row);
                if (!height.known || height.width != width || height.revision != row.layoutRevision())
                {
                    height.pixels = row.measure(Size(width, int.max)).height;
                    height.width = width;
                    height.revision = row.layoutRevision();
                    height.known = true;
                }
                if (!follow && cursor + before <= top) correction += height.pixels - before;
            }
            _heights[row] = height;
            _rowHeights[i] = height.pixels;
            cursor += height.pixels + (height.pixels > 0 ? spacing() : 0);
        }
        _totalHeight = cursor + pad.bottom;
        if (correction && onAnchorCorrection !is null) onAnchorCorrection(correction);
        return Size(available.width, _totalHeight);
    }

    protected override void onLayout()
    {
        if (children().length < virtualThreshold) { super.onLayout(); return; }
        auto view = viewport();
        const top = view !is null ? view.scrollY() : 0;
        const page = view !is null ? view.bounds().height : 700;
        const pad = padding();
        int cursor = pad.top;
        foreach (i, row; children())
        {
            const height = i < _rowHeights.length ? _rowHeights[i] : 64;
            const visible = height > 0 && cursor + height >= top - overscan && cursor <= top + page + overscan;
            if (visible)
            {
                if (row in _virtualHidden) { row.setVisible(true); _virtualHidden.remove(row); }
            }
            else if (row.visible()) { row.setVisible(false); _virtualHidden[row] = true; }
            row.setBounds(Rect(pad.left, cursor,
                maxInt(0, bounds().width - pad.left - pad.right), height));
            cursor += height + (height > 0 ? spacing() : 0);
        }
    }
}

module auroraopencode.transcriptpresenter;

import aurora : VBox, Widget, ScrollView, Size, Rect, Insets, maxInt;

// Shared with the projection so deferred construction and viewport measurement
// start together, including ordinary medium-sized conversations.
public enum size_t transcriptVirtualThreshold = 80;

/// A cheap transcript descriptor. Expensive text/markdown widgets are created
/// only when this row enters the measured viewport, and retained while visible.
public final class DeferredTranscriptRow : Widget
{
    private Widget delegate() _factory;
    private Widget _row;
    bool delegate(Widget) allowRelease;
    long messageIndex = -1;
    this(Widget delegate() factory) { _factory = factory; }
    Widget materialized() { return _row; }
    Widget ensureMaterialized()
    {
        if (_row is null) { _row = _factory(); add(_row); }
        return _row;
    }
    void release()
    {
        if (_row is null || (allowRelease !is null && !allowRelease(_row))) return;
        clearChildren();
        _row = null;
    }
    protected override Size onMeasure(Size available)
    {
        ensureMaterialized();
        const measured = _row.measure(available);
        // The ordinary VBox path places children from their layout hints.
        // Deferred rows also occur below the presenter's virtualization limit.
        layoutHints().preferredWidth = measured.width;
        layoutHints().preferredHeight = measured.height;
        return measured;
    }
    protected override void onLayout()
    {
        if (_row !is null) _row.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

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
    void forget(string id) { _entries.remove(id); }
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
    private int _measuredTop = int.min;
    private Widget _insertAnchor;
    private int _insertAnchorScreenY;
    private int _insertAnchorTop;
    private bool _projecting;
    private Widget[] _projectedRows;
    private enum size_t virtualThreshold = transcriptVirtualThreshold;
    private enum int overscan = 700;
    bool delegate() following;
    void delegate(int) onAnchorCorrection;

    this(int spacing = 0, Insets padding = Insets(0)) { super(spacing, padding); }

    /// Preserve a retained row's screen position while older descriptors are
    /// prepended. Total-height deltas include unrelated offscreen estimates;
    /// anchor to the row itself instead, without measuring the whole history.
    void preserveTopInsertAnchor(Widget row)
    {
        auto view = viewport();
        if (row is null || view is null) return;
        _insertAnchor = row;
        _insertAnchorTop = view.scrollY();
        _insertAnchorScreenY = row.bounds().y - _insertAnchorTop;
    }

    void beginProjection()
    {
        assert(!_projecting);
        _projecting = true;
        _projectedRows = null;
    }

    protected override void addChild(Widget child)
    {
        if (_projecting) _projectedRows ~= child;
        else super.addChild(child);
    }

    override void clearChildren()
    {
        if (_projecting) _projectedRows = null;
        else super.clearChildren();
    }

    override Widget[] children() @safe pure nothrow @nogc
    { return _projecting ? _projectedRows : super.children(); }
    override const(Widget)[] children() const @safe pure nothrow @nogc
    { return _projecting ? _projectedRows : super.children(); }

    void endProjection()
    {
        assert(_projecting);
        _projecting = false;
        const changed = reconcileChildren(_projectedRows);
        _projectedRows = null;
        // Streaming commonly projects the same retained rows. Their height
        // revisions are checked during measurement; rebuilding both indexes
        // here only allocates and hashes the unchanged history again.
        if (!changed) return;
        Height[Widget] kept;
        bool[Widget] hidden;
        foreach (row; children())
        {
            if (auto height = row in _heights) kept[row] = *height;
            if (row in _virtualHidden)
            {
                if (children().length < virtualThreshold) row.setVisible(true);
                else hidden[row] = true;
            }
        }
        _heights = kept;
        _virtualHidden = hidden;
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
        int top = view !is null ? view.scrollY() : 0;
        const follow = following !is null && following();
        _measuredTop = top;
        int estimatedBottom = pad.top + pad.bottom;
        int estimatedCursor = pad.top;
        bool anchored;
        foreach (row; children())
        {
            if (row is _insertAnchor)
            {
                top = estimatedCursor - _insertAnchorScreenY;
                anchored = true;
            }
            if (!row.visible() && row !in _virtualHidden) continue;
            auto indexed = row in _heights;
            const pixels = indexed is null ? 64 : indexed.pixels;
            estimatedBottom += pixels + (pixels > 0 ? spacing() : 0);
            estimatedCursor += pixels + (pixels > 0 ? spacing() : 0);
        }
        const lower = follow ? maxInt(0, estimatedBottom - page - overscan) : maxInt(0, top - overscan);
        const upper = follow ? int.max : top + page + overscan;
        _rowHeights.length = children().length;
        int cursor = pad.top;
        int correction;
        int anchorTop;
        foreach (i, row; children())
        {
            if (anchored && row is _insertAnchor)
                anchorTop = cursor - _insertAnchorScreenY;
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
                if (!follow && !anchored && cursor + before <= top) correction += height.pixels - before;
            }
            _heights[row] = height;
            _rowHeights[i] = height.pixels;
            cursor += height.pixels + (height.pixels > 0 ? spacing() : 0);
        }
        _totalHeight = cursor + pad.bottom;
        if (anchored)
        {
            correction = anchorTop - _insertAnchorTop;
            _insertAnchorTop = anchorTop;
            _measuredTop = anchorTop;
        }
        if (correction && onAnchorCorrection !is null) onAnchorCorrection(correction);
        return Size(available.width, _totalHeight);
    }

    protected override void onLayout()
    {
        scope(exit) _insertAnchor = null;
        if (children().length < virtualThreshold) { super.onLayout(); return; }
        auto view = viewport();
        const top = view !is null ? view.scrollY() : 0;
        const page = view !is null ? view.bounds().height : 700;
        const pad = padding();
        // ScrollView does not invalidate a child's measure cache when its
        // offset changes. Measure the newly exposed range before laying it out.
        if (top != _measuredTop)
        {
            const before = _totalHeight;
            onMeasure(Size(bounds().width, int.max));
            if (before != _totalHeight) invalidate();
        }
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
            if (!visible)
                if (auto deferred = cast(DeferredTranscriptRow) row) deferred.release();
            row.setBounds(Rect(pad.left, cursor,
                maxInt(0, bounds().width - pad.left - pad.right), height));
            cursor += height + (height > 0 ? spacing() : 0);
        }
    }
}

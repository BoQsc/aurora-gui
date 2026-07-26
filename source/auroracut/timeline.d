module auroracut.timeline;

import aurora;
import auroracut.model : ClipKind, EditorModel, EffectProperty, KeyframeInterpolation, TimelineClip, TrackAddress, TrackKind;
import auroracut.util : clampValue, formatTimecode;
import std.format : format;
import std.math : fabs;
import std.utf : toUTF32;

private enum SequenceRulerHeight = 24;
private enum AutomaticFitDurationLimit = 180.0;
private enum NewTrackDropGap = 8;

private enum PointerMode : ubyte
{
    none,
    playhead,
    clipPress,
    clipDrag,
    clipResizeStart,
    clipResizeEnd,
    marqueeSelect,
    textCreate,
    transitionCreate,
    labelResize,
    trackResize
}

private enum TimelineTool : ubyte
{
    selection,
    cut,
    text,
    transition
}

/**
 * Tiny independently retained playhead layer.
 *
 * Moving the transport now changes only this 12-pixel-wide compositor layer;
 * the ruler, clip bodies, waveforms, and track labels stay cached.  The layer
 * is input-transparent so timeline hit testing continues to bubble to the
 * TimelineWidget underneath it.
 */
private final class TimelinePlayheadLayer : Widget
{
    this()
    {
        setComposited(true);
        setEnabled(false);
        layoutHints().excludeFromLayout = true;
        layoutHints().allowOverflow = true;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (bounds().width <= 0 || bounds().height <= 0) return;
        const x = bounds().width / 2;
        const color = Color.fromHex(0xff4d4f);
        // Keep the playhead marker below ruler text. The old marker covered
        // the 00:00:00 label and made the timeline look offset or corrupted.
        const lineTop = minInt(SequenceRulerHeight - 1, bounds().height);
        if (lineTop < bounds().height)
            canvas.fillRect(Rect(x - 1, lineTop, 2, bounds().height - lineTop), color);
        if (bounds().height >= SequenceRulerHeight)
            canvas.fillRoundedRect(Rect(x - 5, SequenceRulerHeight - 9, 10, 8), 2, color);
    }
}

/**
 * Compact, virtualized, multi-track sequence view. Clips are painted only when
 * visible and hit-testing uses the model's sorted absolute-time tracks.
 */
final class TimelineWidget : Widget
{
    private EditorModel _model;
    private double _playhead = 0.0;
    private double _pixelsPerSecond = 110.0;
    private double _scrollSeconds = 0.0;
    // Start in fit mode so the first sequence item is shown from 00:00:00
    // instead of the transport silently scrolling the viewport forward.
    private bool _fitView = true;
    private bool _fitAllDurations;
    private bool _snappingEnabled = true;
    private int _verticalScroll;
    private int _labelColumnWidth = 30;
    private TimelineTool _activeTool = TimelineTool.selection;
    private TrackAddress _selectedTrack = TrackAddress(TrackKind.video, 0);
    private int _selectedIndex = -1;

    private PointerMode _pointerMode;
    private TrackAddress _pressTrack;
    private int _pressIndex = -1;
    private Point _pressPoint;
    private double _grabOffset = 0.0;
    private int _pressClickCount;
    private ulong[] _selectedClipIds;
    private Point _marqueeOrigin;
    private Point _marqueeCurrent;
    private bool _marqueeMoved;
    private TrackAddress _textCreateTrack;
    private double _textCreateStart;
    private double _textCreateEnd;
    private bool _textCreateMoved;
    private TrackAddress _resizeTrack;
    private int _resizeStartY;
    private int _resizeStartHeight;
    private TimelineClip _resizeClip;
    private double _resizePreviewStart;
    private double _resizePreviewEnd;

    private bool _ghostVisible;
    private bool _ghostValid;
    private bool _ghostNewTrack;
    private TrackAddress _ghostTrack;
    private double _ghostStart = 0.0;
    private double _ghostDuration = 0.0;

    private bool _externalDrag;
    private size_t _externalAssetIndex;


    // Paint instrumentation doubles as a guard against accidental O(n)
    // timeline rendering regressions. Only clips intersecting the viewport are
    // counted and painted.
    private size_t _lastPaintedClipCount;

    // Text conversion is intentionally kept out of the hot paint path. During
    // playback the timeline may repaint 30 times per second; re-encoding every
    // clip name and ruler label would create continuous GC pressure.
    private string[] _cachedAssetNames;
    private dstring[] _cachedAssetTitles;
    private dstring[] _videoTrackLabels;
    private dstring[] _audioTrackLabels;
    private dstring[ulong] _textClipTitles;
    private dstring[long] _rulerTextCache;
    private dstring _sequenceText;
    private dstring _dropMediaText;
    private dstring _missingText;
    private dstring _stateMuted;
    private dstring _stateHidden;
    private dstring _stateDisabled;
    private dstring _stateMutedHidden;
    private dstring _stateMutedDisabled;
    private dstring _ghostTrackText;
    private dstring _selectionToolText;
    private dstring _cutToolText;
    private dstring _textToolText;
    private dstring _transitionToolText;
    private dstring[4] _toolTips;
    private int _hoverToolIndex = -1;
    private bool _scrubGestureActive;
    private TimelinePlayheadLayer _playheadLayer;
    private bool _hasWorkIn;
    private bool _hasWorkOut;
    private double _workIn;
    private double _workOut;

    void delegate(double time) onPlayheadChanged;
    void delegate() onHorizontalViewportChanged;
    void delegate() onScrubStarted;
    void delegate() onScrubEnded;
    void delegate(TrackAddress track, int index) onSelectionChanged;
    void delegate() onDeleteRequested;
    void delegate() onSplitRequested;
    void delegate() onPreviewRequested;
    void delegate(TrackAddress track, int index, Point globalPosition)
        onContextMenuRequested;
    void delegate(TrackAddress track, int index) onClipActivated;
    void delegate(TrackAddress source, int index, TrackAddress destination,
        double start) onClipMoveRequested;
    void delegate(TrackAddress track, int index, double start, double end)
        onClipResizeRequested;
    void delegate(size_t assetIndex, TrackAddress destination, double start)
        onMediaDropRequested;
    void delegate(string[] paths, TrackAddress destination, double start)
        onExplorerMediaDropRequested;
    void delegate(TrackKind kind) onAddTrackRequested;
    void delegate(TrackAddress track, double time) onCutToolRequested;
    void delegate(TrackAddress track, double start, double end) onTextToolRequested;
    void delegate(TrackAddress track, int index, bool fadeIn, double duration)
        onTransitionToolRequested;
    void delegate(double time) onSetInRequested;
    void delegate(double time) onSetOutRequested;
    void delegate() onClearRangeRequested;

    this(EditorModel model)
    {
        _model = model;
        // A full word cannot fit in the intentionally compact V1/A1 label column.
        // Leave the corner header clean instead of rendering a clipped "T...".
        _sequenceText = null;
        _dropMediaText = toUTF32("Drop media here");
        _missingText = toUTF32("Missing");
        _stateMuted = toUTF32("M");
        _stateHidden = toUTF32("H");
        _stateDisabled = toUTF32("D");
        _stateMutedHidden = toUTF32("MH");
        _stateMutedDisabled = toUTF32("MD");
        _selectionToolText = toUTF32("↖");
        _cutToolText = toUTF32("✂");
        _textToolText = toUTF32("T");
        _transitionToolText = toUTF32("↔");
        _toolTips[0] = toUTF32("Selection (V)");
        _toolTips[1] = toUTF32("Cut (C)");
        _toolTips[2] = toUTF32("Text (T)");
        _toolTips[3] = toUTF32("Transition (R)");
        refreshTextCaches();
        setFocusable(true);
        setCursor(CursorKind.arrow);
        // Static timeline content remains in the cached base scene. Only the
        // narrow playhead is a retained compositor layer, so transport motion
        // cannot repaint thousands of clips or the complete editor window.
        _playheadLayer = add(new TimelinePlayheadLayer());
        layoutHints().minHeight = 118;
        layoutHints().preferredHeight = 190;
    }

    double playhead() const @safe pure nothrow @nogc { return _playhead; }
    TrackAddress selectedTrack() const @safe pure nothrow @nogc { return _selectedTrack; }
    int selectedIndex() const @safe pure nothrow @nogc { return _selectedIndex; }
    size_t selectedCountForTesting() const @safe pure nothrow @nogc
    {
        return _selectedClipIds.length;
    }
    int hoveredToolForTesting() const @safe pure nothrow @nogc
    {
        return _hoverToolIndex;
    }
    double pixelsPerSecond() const @safe pure nothrow @nogc { return _pixelsPerSecond; }
    double scrollSecondsForTesting() const @safe pure nothrow @nogc { return _scrollSeconds; }
    double horizontalScroll() const @safe pure nothrow @nogc { return _scrollSeconds; }
    double horizontalVisibleDuration() const
    {
        return visibleDuration();
    }
    double horizontalScrollMaximum() const
    {
        const maximum = _model.sequenceDuration() - visibleDuration();
        return maximum > 0.0 ? maximum : 0.0;
    }
    double horizontalContentDuration() const
    {
        return _model.sequenceDuration();
    }
    int horizontalViewportLeft() const
    {
        return labelWidth();
    }
    bool fitViewForTesting() const @safe pure nothrow @nogc { return _fitView; }
    int verticalScroll() const @safe pure nothrow @nogc { return _verticalScroll; }
    bool draggingClip() const @safe pure nothrow @nogc
    {
        return _pointerMode == PointerMode.clipDrag ||
            _pointerMode == PointerMode.clipResizeStart ||
            _pointerMode == PointerMode.clipResizeEnd || _externalDrag;
    }
    size_t lastPaintedClipCountForTesting() const @safe pure nothrow @nogc
    {
        return _lastPaintedClipCount;
    }
    int clipBodyHeightForTesting() const @safe pure nothrow @nogc
    {
        return maxInt(18, minInt(22, 24 - 4));
    }

    int timeOriginXForTesting() const
    {
        return timeOriginX();
    }

    double timeAtXForTesting(int x) const
    {
        return timeForX(x);
    }

    double snappedStartForTesting(double desired, double duration,
        TrackAddress address, ulong excludedClipId = 0) const
    {
        return snappedStart(desired, duration, address, excludedClipId);
    }

    double snappedEdgeForTesting(double desired, double minimum,
        double maximum, TrackAddress address, ulong excludedClipId = 0) const
    {
        return snappedEdge(desired, minimum, maximum, address, excludedClipId);
    }

    void setWorkArea(bool hasIn, double inPoint, bool hasOut, double outPoint)
    {
        inPoint = inPoint < 0.0 ? 0.0 : inPoint;
        outPoint = outPoint < 0.0 ? 0.0 : outPoint;
        if (hasIn && hasOut && outPoint < inPoint)
        {
            const swap = inPoint;
            inPoint = outPoint;
            outPoint = swap;
        }
        if (_hasWorkIn == hasIn && _hasWorkOut == hasOut &&
            fabs(_workIn - inPoint) < 0.000_000_5 &&
            fabs(_workOut - outPoint) < 0.000_000_5) return;
        _hasWorkIn = hasIn;
        _hasWorkOut = hasOut;
        _workIn = inPoint;
        _workOut = outPoint;
        invalidate();
    }

    private void refreshTextCaches()
    {
        _cachedAssetNames.length = _model.assets.length;
        _cachedAssetTitles.length = _model.assets.length;
        foreach (index, asset; _model.assets)
        {
            if (_cachedAssetNames[index] != asset.name)
            {
                _cachedAssetNames[index] = asset.name;
                _cachedAssetTitles[index] = toUTF32(asset.name);
            }
        }

        _videoTrackLabels.length = _model.trackCount(TrackKind.video);
        foreach (lane; 0 .. _videoTrackLabels.length)
            _videoTrackLabels[lane] = toUTF32(TrackAddress(TrackKind.video, lane).label());
        _audioTrackLabels.length = _model.trackCount(TrackKind.audio);
        foreach (lane; 0 .. _audioTrackLabels.length)
            _audioTrackLabels[lane] = toUTF32(TrackAddress(TrackKind.audio, lane).label());

        _textClipTitles.clear();
        foreach (timelineTrack; _model.videoTracks)
            foreach (clip; timelineTrack.clips)
                if (clip.kind == ClipKind.text)
                    _textClipTitles[clip.id] = toUTF32(
                        clip.text.length > 0 ? clip.text : "Title");
    }

    private dstring trackLabelText(TrackAddress address) const
    {
        const labels = address.kind == TrackKind.video ?
            _videoTrackLabels : _audioTrackLabels;
        return address.lane < labels.length ? labels[address.lane] : null;
    }

    private dstring assetTitleText(const TimelineClip clip) const
    {
        if (clip.kind == ClipKind.text)
        {
            if (auto found = clip.id in _textClipTitles) return *found;
            return _missingText;
        }
        return clip.assetIndex < _cachedAssetTitles.length ?
            _cachedAssetTitles[clip.assetIndex] : _missingText;
    }

    private dstring rulerLabel(double value)
    {
        const key = cast(long) (value * 1000.0 + (value >= 0.0 ? 0.5 : -0.5));
        if (auto found = key in _rulerTextCache) return *found;
        if (_rulerTextCache.length > 512) _rulerTextCache.clear();
        const converted = toUTF32(formatTimecode(value, false));
        _rulerTextCache[key] = converted;
        return converted;
    }

    private void beginScrubGesture()
    {
        if (_scrubGestureActive) return;
        _scrubGestureActive = true;
        if (onScrubStarted !is null) onScrubStarted();
    }

    private void endScrubGesture()
    {
        if (!_scrubGestureActive) return;
        _scrubGestureActive = false;
        if (onScrubEnded !is null) onScrubEnded();
    }

    void setPlayhead(double value, bool notify = true)
    {
        const maximum = _model.sequenceDuration();
        const next = clampValue(value, 0.0, maximum > 0.0 ? maximum : 0.0);
        if (fabs(next - _playhead) < 0.000_000_5) return;
        _playhead = next;
        const previousScroll = _scrollSeconds;
        revealPlayhead();
        // Auto-follow changes every clip's X coordinate and therefore needs a
        // static timeline rebuild. Ordinary playhead movement is transform-only.
        if (fabs(previousScroll - _scrollSeconds) >= 0.000_000_5)
        {
            invalidate();
            notifyHorizontalViewportChanged();
        }
        syncPlayheadLayer();
        if (notify && onPlayheadChanged !is null) onPlayheadChanged(_playhead);
    }

    void setSelection(TrackAddress track, int index, bool notify = true)
    {
        if (!_model.validTrack(track))
        {
            track = TrackAddress(TrackKind.video, 0);
            index = -1;
        }
        else
        {
            const clips = _model.trackValue(track).clips;
            if (index < 0 || index >= cast(int) clips.length) index = -1;
        }
        if (_selectedTrack == track && _selectedIndex == index &&
            (_selectedClipIds.length <= 1 || index < 0))
        {
            // Re-clicking an already selected sequence item still makes the
            // Sequence the active Preview context after Project Media was used.
            if (notify && onSelectionChanged !is null)
                onSelectionChanged(_selectedTrack, _selectedIndex);
            return;
        }
        _selectedTrack = track;
        _selectedIndex = index;
        _selectedClipIds.length = 0;
        if (index >= 0)
            _selectedClipIds ~= _model.trackValue(track).clips[cast(size_t) index].id;
        revealTrack(track);
        invalidate();
        if (notify && onSelectionChanged !is null)
            onSelectionChanged(_selectedTrack, _selectedIndex);
    }

    /** Repaint-only notification for clip audio/transform changes. */
    void visualChanged()
    {
        invalidate();
    }

    void modelChanged()
    {
        if (!_model.validTrack(_selectedTrack))
        {
            _selectedTrack = TrackAddress(TrackKind.video, 0);
            _selectedIndex = -1;
        }
        else
        {
            const clips = _model.trackValue(_selectedTrack).clips;
            if (_selectedIndex >= cast(int) clips.length)
                _selectedIndex = clips.length == 0 ? -1 : cast(int) clips.length - 1;
        }
        _selectedClipIds.length = 0;
        if (_selectedIndex >= 0 && _model.validTrack(_selectedTrack))
            _selectedClipIds ~= _model.trackValue(_selectedTrack)
                .clips[cast(size_t) _selectedIndex].id;
        const maximum = _model.sequenceDuration();
        if (_playhead > maximum) _playhead = maximum;
        refreshTextCaches();
        if (maximum <= 0.0)
        {
            // A fresh empty sequence should auto-fit its first real clip.
            _fitView = true;
            _fitAllDurations = false;
        }
        if (_fitView) applyFitView();
        else clampScroll();
        clampVerticalScroll();
        syncPlayheadLayer();
        notifyHorizontalViewportChanged();
        invalidate();
    }

    void setHorizontalScroll(double value)
    {
        const next = clampValue(value, 0.0, horizontalScrollMaximum());
        if (fabs(next - _scrollSeconds) < 0.000_000_5) return;
        _fitView = false;
        _fitAllDurations = false;
        _scrollSeconds = next;
        syncPlayheadLayer();
        invalidate();
        notifyHorizontalViewportChanged();
    }

    void zoomIn() { setZoom(_pixelsPerSecond * 1.25); }
    void zoomOut() { setZoom(_pixelsPerSecond / 1.25); }

    /** Return to the normal editing tool. Text fields call this when they gain
     * focus so typing can never leave the timeline armed to create titles. */
    bool snappingEnabled() const @safe pure nothrow @nogc { return _snappingEnabled; }

    void setSnappingEnabled(bool value)
    {
        if (_snappingEnabled == value) return;
        _snappingEnabled = value;
        invalidate();
    }

    void activateSelectionTool()
    {
        setActiveTool(TimelineTool.selection);
    }

    private void applyFitView()
    {
        const duration = _model.sequenceDuration();
        _scrollSeconds = 0.0;
        if (duration <= 0.0)
        {
            notifyHorizontalViewportChanged();
            return;
        }
        // Automatic first-clip fitting is intended for ordinary editing shots,
        // not hour-long or synthetic stress timelines. Long sequences retain
        // a practical zoom and use normal viewport following. The explicit Fit
        // command still fits any duration.
        if (!_fitAllDurations && duration > AutomaticFitDurationLimit)
        {
            _pixelsPerSecond = 110.0;
            _fitView = false;
            clampScroll();
            notifyHorizontalViewportChanged();
            return;
        }
        const usableWidth = maxInt(1, bounds().width - labelWidth() - 16);
        _pixelsPerSecond = clampValue(cast(double) usableWidth / duration,
            14.0, 900.0);
        clampScroll();
        notifyHorizontalViewportChanged();
    }

    void zoomToFit()
    {
        _fitView = true;
        _fitAllDurations = true;
        applyFitView();
        syncPlayheadLayer();
        invalidate();
    }

    void setZoom(double value)
    {
        const old = _pixelsPerSecond;
        const next = clampValue(value, 14.0, 900.0);
        if (old == next) return;
        _fitView = false;
        _fitAllDurations = false;
        _pixelsPerSecond = next;
        const anchor = _playhead;
        _scrollSeconds = anchor - (anchor - _scrollSeconds) * old / _pixelsPerSecond;
        clampScroll();
        syncPlayheadLayer();
        notifyHorizontalViewportChanged();
        invalidate();
    }

    /** Begin a project-bin drag; actual activation starts on first update. */
    void beginExternalDrag(size_t assetIndex)
    {
        _externalAssetIndex = assetIndex;
        _externalDrag = true;
        clearGhost();
    }

    bool updateExternalDrag(size_t assetIndex, Point globalPosition)
    {
        _externalAssetIndex = assetIndex;
        _externalDrag = true;
        const local = globalToLocal(globalPosition);
        if (!containsLocal(local))
        {
            clearGhost();
            return false;
        }
        const duration = assetIndex < _model.assets.length
            ? _model.assets[assetIndex].duration : 0.0;
        updateGhost(local, duration, assetIndex, 0);
        return _ghostVisible && _ghostValid;
    }

    bool endExternalDrag(size_t assetIndex, Point globalPosition, bool commit = true)
    {
        bool accepted = updateExternalDrag(assetIndex, globalPosition);
        const target = _ghostTrack;
        const start = _ghostStart;
        clearExternalDrag();
        if (commit && accepted && onMediaDropRequested !is null)
            onMediaDropRequested(assetIndex, target, start);
        return accepted;
    }

    void cancelExternalDrag()
    {
        clearExternalDrag();
    }

    Rect clipRectForTesting(TrackAddress address, int index) const
    {
        if (!_model.validTrack(address)) return Rect.init;
        const clips = _model.trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return Rect.init;
        return clipRect(address, clips[cast(size_t) index]);
    }

    Rect trackRectForTesting(TrackAddress address) const
    {
        return trackRect(address);
    }

    Point newTrackDropPointForTesting(TrackKind kind, double time) const
    {
        Rect rect;
        if (kind == TrackKind.video)
            rect = trackRect(TrackAddress(TrackKind.video,
                _model.trackCount(TrackKind.video) - 1));
        else
            rect = trackRect(TrackAddress(TrackKind.audio,
                _model.trackCount(TrackKind.audio) - 1));
        const y = kind == TrackKind.video ? rect.y + 1 : rect.bottom() - 2;
        return localToGlobal(Point(xForTime(time), y));
    }

    Point pointForTrackTime(TrackAddress address, double time) const
    {
        const rect = trackRect(address);
        return localToGlobal(Point(xForTime(time), rect.y + rect.height / 2));
    }


    /** Locate a keyframe marker near a global pointer position. */
    bool keyframeAtGlobalPoint(TrackAddress address, int index, Point globalPosition,
        out EffectProperty property, out double localTime,
        out KeyframeInterpolation interpolation) const
    {
        if (!_model.validTrack(address)) return false;
        const clips = _model.trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return false;
        const local = globalToLocal(globalPosition);
        const clip = clips[cast(size_t) index];
        const rect = clipRect(address, clip);
        if (!rect.contains(local)) return false;
        int bestDistance = 7;
        bool found;
        foreach (keyframe; clip.keyframes)
        {
            const markerX = xForTime(clip.start + keyframe.time);
            const distance = markerX > local.x ? markerX - local.x : local.x - markerX;
            if (distance > bestDistance) continue;
            bestDistance = distance;
            property = keyframe.property;
            localTime = keyframe.time;
            interpolation = keyframe.interpolation;
            found = true;
        }
        return found;
    }

    double timeAtGlobalPoint(Point globalPosition) const
    {
        return timeForX(globalToLocal(globalPosition).x);
    }

    // Left side is a narrow tool column plus a compact, user-resizable track
    // label column. The ruler origin begins at this exact X coordinate.
    private int toolColumnWidth() const @safe pure nothrow @nogc { return 30; }
    private int labelColumnWidth() const @safe pure nothrow @nogc { return _labelColumnWidth; }
    private int labelWidth() const @safe pure nothrow @nogc
    {
        return toolColumnWidth() + labelColumnWidth();
    }
    private int rulerHeight() const @safe pure nothrow @nogc { return SequenceRulerHeight; }
    private int minTrackHeight() const @safe pure nothrow @nogc { return 18; }
    private int trackGap() const @safe pure nothrow @nogc { return 1; }

    private int trackHeight(TrackAddress address) const
    {
        if (!_model.validTrack(address)) return minTrackHeight();
        const value = _model.trackValue(address).height;
        return clampInt(value, minTrackHeight(), 144);
    }

    private int rowStride(TrackAddress address) const
    {
        return trackHeight(address) + trackGap();
    }

    private size_t totalRows() const
    {
        return _model.trackCount(TrackKind.video) + _model.trackCount(TrackKind.audio);
    }

    private int contentTrackHeight() const
    {
        int total;
        foreach (row; 0 .. totalRows())
            total += rowStride(addressForRow(row));
        return total;
    }

    private int maxVerticalScroll() const
    {
        return maxInt(0, NewTrackDropGap + contentTrackHeight() -
            maxInt(0, bounds().height - rulerHeight()));
    }

    private void clampVerticalScroll()
    {
        _verticalScroll = clampInt(_verticalScroll, 0, maxVerticalScroll());
    }

    private size_t rowForAddress(TrackAddress address) const
    {
        const videoCount = _model.trackCount(TrackKind.video);
        if (address.kind == TrackKind.video)
            return videoCount - 1 - address.lane;
        return videoCount + address.lane;
    }

    private TrackAddress addressForRow(size_t row) const
    {
        const videoCount = _model.trackCount(TrackKind.video);
        if (row < videoCount)
            return TrackAddress(TrackKind.video, videoCount - 1 - row);
        return TrackAddress(TrackKind.audio, row - videoCount);
    }

    private int rowTop(size_t targetRow) const
    {
        int y;
        foreach (row; 0 .. targetRow)
            y += rowStride(addressForRow(row));
        return y;
    }

    private Rect trackRect(TrackAddress address) const
    {
        if (!_model.validTrack(address)) return Rect.init;
        const row = rowForAddress(address);
        const y = rulerHeight() + NewTrackDropGap + rowTop(row) - _verticalScroll;
        return Rect(0, y, bounds().width, trackHeight(address));
    }

    private void revealTrack(TrackAddress address)
    {
        if (!_model.validTrack(address)) return;
        const top = rowTop(rowForAddress(address));
        const height = trackHeight(address);
        const viewport = maxInt(1, bounds().height - rulerHeight() - NewTrackDropGap);
        if (top < _verticalScroll) _verticalScroll = top;
        else if (top + height > _verticalScroll + viewport)
            _verticalScroll = top + height - viewport;
        clampVerticalScroll();
    }

    private void notifyHorizontalViewportChanged()
    {
        if (onHorizontalViewportChanged !is null)
            onHorizontalViewportChanged();
    }

    private double visibleDuration() const
    {
        return cast(double) maxInt(1, bounds().width - labelWidth()) /
            _pixelsPerSecond;
    }

    private void clampScroll()
    {
        const maximum = _model.sequenceDuration() - visibleDuration();
        _scrollSeconds = clampValue(_scrollSeconds, 0.0,
            maximum > 0.0 ? maximum : 0.0);
    }

    private void revealPlayhead()
    {
        const visible = visibleDuration();
        if (_playhead < _scrollSeconds) _scrollSeconds = _playhead;
        else if (_playhead > _scrollSeconds + visible)
            _scrollSeconds = _playhead - visible * 0.85;
        clampScroll();
    }

    private int xForTime(double value) const
    {
        return labelWidth() + cast(int) ((value - _scrollSeconds) *
            _pixelsPerSecond + 0.5);
    }

    private int timeOriginX() const
    {
        return xForTime(0.0);
    }

    private void syncPlayheadLayer()
    {
        if (_playheadLayer is null) return;
        const x = xForTime(_playhead);
        const shown = bounds().height > 0 && x >= labelWidth() && x < bounds().width;
        _playheadLayer.setVisible(shown);
        if (!shown) return;
        _playheadLayer.setBounds(Rect(x - 6, 0, 12, bounds().height));
    }

    private double timeForX(int x) const
    {
        if (x <= labelWidth()) return _scrollSeconds;
        return _scrollSeconds + cast(double) (x - labelWidth()) /
            _pixelsPerSecond;
    }

    private bool overLabelResizeHandle(Point point) const
    {
        return point.x >= labelWidth() - 3 && point.x <= labelWidth() + 3;
    }

    private bool resizeTrackAtY(int y, out TrackAddress address) const
    {
        foreach (row; 0 .. totalRows())
        {
            const candidate = addressForRow(row);
            const rect = trackRect(candidate);
            if (rect.empty()) continue;
            if (y >= rect.bottom() - 3 && y <= rect.bottom() + 3)
            {
                address = candidate;
                return true;
            }
            if (y >= rect.y - 3 && y <= rect.y + 3 && row > 0)
            {
                address = addressForRow(row - 1);
                return true;
            }
        }
        return false;
    }

    private int toolIndexAt(Point point) const
    {
        if (point.x < 2 || point.x >= toolColumnWidth() - 2) return -1;
        const top = 2;
        const size = 20;
        foreach (index; 0 .. 4)
        {
            const y = top + cast(int) index * (size + 2);
            if (point.y >= y && point.y < y + size) return cast(int) index;
        }
        return -1;
    }

    private void setActiveTool(TimelineTool tool)
    {
        if (_activeTool == tool) return;
        _activeTool = tool;
        setCursor(tool == TimelineTool.cut ? CursorKind.resizeDiagonalNESW :
            (tool == TimelineTool.text ? CursorKind.text :
            (tool == TimelineTool.transition ? CursorKind.resizeHorizontal :
             CursorKind.arrow)));
        invalidate();
    }

    private bool trackAtY(int y, out TrackAddress address) const
    {
        const localY = y - rulerHeight() + _verticalScroll;
        if (localY < 0) return false;
        int cursor;
        foreach (row; 0 .. totalRows())
        {
            const candidate = addressForRow(row);
            const height = trackHeight(candidate);
            if (localY >= cursor && localY < cursor + height)
            {
                address = candidate;
                return true;
            }
            cursor += height + trackGap();
        }
        return false;
    }

    private int clipAtPoint(TrackAddress address, Point point) const
    {
        if (point.x < labelWidth() || !trackRect(address).contains(point)) return -1;
        return _model.clipAtTime(address, timeForX(point.x));
    }

    private Rect clipRect(TrackAddress address, const TimelineClip clip) const
    {
        const row = trackRect(address);
        if (row.empty()) return Rect.init;
        int x0 = xForTime(clip.start);
        int x1 = xForTime(clip.end());
        x0 = maxInt(labelWidth(), x0);
        x1 = minInt(bounds().width, x1);
        const bodyHeight = maxInt(18, minInt(22, row.height - 4));
        const bodyY = row.y + maxInt(2, (row.height - bodyHeight) / 2);
        return Rect(x0, bodyY, maxInt(3, x1 - x0), bodyHeight);
    }


    private int clipEdgeAtPoint(TrackAddress address, int index, Point point) const
    {
        if (!_model.validTrack(address)) return 0;
        const clips = _model.trackValue(address).clips;
        if (index < 0 || index >= cast(int) clips.length) return 0;
        const rect = clipRect(address, clips[cast(size_t) index]);
        if (!rect.contains(point)) return 0;
        const threshold = minInt(6, maxInt(3, rect.width / 4));
        if (point.x <= rect.x + threshold) return -1;
        if (point.x >= rect.right() - threshold) return 1;
        return 0;
    }

    private size_t firstVisibleClip(const TimelineClip[] clips, double start) const
    {
        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (clips[middle].end() < start) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    private bool candidateTrackAt(Point point, out TrackAddress address,
        out bool createsTrack) const
    {
        createsTrack = false;
        if (point.y < rulerHeight() || point.y >= bounds().height) return false;

        const videoCount = _model.trackCount(TrackKind.video);
        const audioCount = _model.trackCount(TrackKind.audio);
        const firstVideo = trackRect(TrackAddress(TrackKind.video, videoCount - 1));
        const lastAudio = trackRect(TrackAddress(TrackKind.audio, audioCount - 1));

        // The top third of the highest V track and bottom third of the lowest A
        // track become unobtrusive "new track" targets only while dragging.
        if (point.y <= firstVideo.y + maxInt(6, firstVideo.height / 3))
        {
            address = TrackAddress(TrackKind.video, videoCount);
            createsTrack = true;
            return true;
        }
        if (point.y >= lastAudio.bottom() - maxInt(6, lastAudio.height / 3))
        {
            address = TrackAddress(TrackKind.audio, audioCount);
            createsTrack = true;
            return true;
        }

        if (trackAtY(point.y, address)) return true;

        // In the one-pixel separators, choose the nearest row.
        int bestDistance = int.max;
        foreach (row; 0 .. totalRows())
        {
            const candidate = addressForRow(row);
            const rect = trackRect(candidate);
            const distance = point.y < rect.y ? rect.y - point.y :
                (point.y >= rect.bottom() ? point.y - rect.bottom() + 1 : 0);
            if (distance < bestDistance)
            {
                bestDistance = distance;
                address = candidate;
            }
        }
        return bestDistance <= 4;
    }

    private size_t lowerBoundByStart(const TimelineClip[] clips, double value) const
    {
        size_t low;
        size_t high = clips.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (clips[middle].start < value) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    private double snapThreshold() const
    {
        const pixelThreshold = 12.0 / _pixelsPerSecond;
        return pixelThreshold > 0.20 ? pixelThreshold : 0.20;
    }

    private double snappedEdge(double desired, double minimum, double maximum,
        TrackAddress address, ulong excludedId) const
    {
        if (maximum < minimum)
        {
            const swap = minimum;
            minimum = maximum;
            maximum = swap;
        }
        desired = clampValue(desired, minimum, maximum);
        if (!_snappingEnabled) return desired;

        const threshold = snapThreshold();
        double result = desired;
        double best = threshold + 1.0;

        void consider(double candidate)
        {
            if (candidate < minimum || candidate > maximum) return;
            const distance = fabs(candidate - desired);
            if (distance <= threshold && distance < best)
            {
                best = distance;
                result = candidate;
            }
        }

        consider(0.0);
        consider(_playhead);
        if (_model.validTrack(address))
        {
            const clips = _model.trackValue(address).clips;
            const center = lowerBoundByStart(clips, desired);
            const begin = center > 4 ? center - 4 : 0;
            const finish = center + 5 < clips.length ? center + 5 : clips.length;
            foreach (index; begin .. finish)
            {
                const clip = clips[index];
                if (clip.id == excludedId) continue;
                consider(clip.start);
                consider(clip.end());
            }
        }
        return result;
    }

    private double snappedStart(double desired, double duration,
        TrackAddress address, ulong excludedId) const
    {
        desired = desired < 0.0 ? 0.0 : desired;
        if (!_snappingEnabled) return desired;
        const threshold = snapThreshold();
        if (desired <= threshold) return 0.0;
        double result = desired;
        double best = threshold + 1.0;

        void consider(double candidate)
        {
            const distance = fabs(candidate - desired);
            if (distance <= threshold && distance < best)
            {
                best = distance;
                result = candidate < 0.0 ? 0.0 : candidate;
            }
        }

        consider(0.0);
        consider(_playhead);
        consider(_playhead - duration);
        if (_model.validTrack(address))
        {
            // Tracks are sorted and non-overlapping. Inspect a small window
            // around the candidate start and end rather than scanning every
            // clip for every mouse-move event. This keeps dragging responsive
            // even on tracks containing tens of thousands of clips.
            const clips = _model.trackValue(address).clips;
            size_t[2] centers = [lowerBoundByStart(clips, desired),
                lowerBoundByStart(clips, desired + duration)];
            foreach (center; centers)
            {
                const begin = center > 3 ? center - 3 : 0;
                const finish = center + 4 < clips.length ? center + 4 : clips.length;
                foreach (index; begin .. finish)
                {
                    const clip = clips[index];
                    if (clip.id == excludedId) continue;
                    consider(clip.start);
                    consider(clip.end());
                    consider(clip.start - duration);
                    consider(clip.end() - duration);
                }
            }
        }
        return result;
    }

    private void autoScrollDuringDrag(Point local)
    {
        bool changed;
        bool horizontalChanged;
        const horizontalBand = 28;
        if (local.x < labelWidth() + horizontalBand)
        {
            const next = _scrollSeconds - visibleDuration() * 0.025;
            const old = _scrollSeconds;
            _scrollSeconds = next;
            clampScroll();
            changed = old != _scrollSeconds;
            horizontalChanged = changed;
            if (changed) { _fitView = false; _fitAllDurations = false; }
        }
        else if (local.x > bounds().width - horizontalBand)
        {
            const old = _scrollSeconds;
            _scrollSeconds += visibleDuration() * 0.025;
            clampScroll();
            changed = old != _scrollSeconds;
            horizontalChanged = changed;
            if (changed) { _fitView = false; _fitAllDurations = false; }
        }

        const verticalBand = 18;
        if (local.y < rulerHeight() + verticalBand && _verticalScroll > 0)
        {
            _verticalScroll = maxInt(0, _verticalScroll - 22);
            changed = true;
        }
        else if (local.y > bounds().height - verticalBand &&
            _verticalScroll < maxVerticalScroll())
        {
            _verticalScroll = minInt(maxVerticalScroll(), _verticalScroll + 22);
            changed = true;
        }
        if (horizontalChanged) notifyHorizontalViewportChanged();
        if (changed) invalidate();
    }

    private void updateGhost(Point local, double duration, size_t assetIndex,
        ulong excludedClipId)
    {
        autoScrollDuringDrag(local);
        TrackAddress target;
        bool createsTrack;
        if (!candidateTrackAt(local, target, createsTrack) || duration <= 0.0)
        {
            clearGhost();
            return;
        }

        double desired = local.x < labelWidth() ? _playhead : timeForX(local.x);
        if (_pointerMode == PointerMode.clipDrag) desired -= _grabOffset;
        if (_model.sequenceDuration() <= 0.000_001 && excludedClipId == 0)
            desired = 0.0;
        desired = snappedStart(desired, duration, target, excludedClipId);

        const ghostLabelChanged = !_ghostVisible || _ghostTrack != target ||
            _ghostNewTrack != createsTrack;
        _ghostVisible = true;
        _ghostTrack = target;
        _ghostNewTrack = createsTrack;
        if (createsTrack && ghostLabelChanged)
            _ghostTrackText = toUTF32("New " ~ target.label());
        _ghostDuration = duration;
        _ghostStart = desired < 0.0 ? 0.0 : desired;
        _ghostValid = assetIndex < _model.assets.length &&
            _model.canPlace(assetIndex, target.kind);
        invalidate();
    }

    private void clearGhost()
    {
        const changed = _ghostVisible;
        _ghostVisible = false;
        _ghostValid = false;
        _ghostNewTrack = false;
        if (changed) invalidate();
    }

    private void clearExternalDrag()
    {
        _externalDrag = false;
        clearGhost();
    }

    protected override void onBoundsChanged()
    {
        if (_fitView) applyFitView();
        else clampScroll();
        clampVerticalScroll();
        syncPlayheadLayer();
        notifyHorizontalViewportChanged();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        _lastPaintedClipCount = 0;
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, Color.fromHex(0x171a1f));
        canvas.fillRect(Rect(0, 0, bounds().width, rulerHeight()),
            Color.fromHex(0x20242a));
        canvas.fillRect(Rect(toolColumnWidth() - 1, 0, 1, bounds().height),
            palette.border);
        canvas.fillRect(Rect(labelWidth() - 1, 0, 1, bounds().height),
            palette.border);

        drawRuler(canvas);
        foreach (row; 0 .. totalRows())
        {
            const address = addressForRow(row);
            const rect = trackRect(address);
            if (rect.bottom() <= rulerHeight() || rect.y >= bounds().height) continue;
            drawTrack(canvas, address);
        }
        drawWorkArea(canvas);
        drawTimelineGuides(canvas);
        drawResizePreview(canvas);
        drawGhost(canvas);
        drawTextCreatePreview(canvas);
        drawMarqueeSelection(canvas);

        // Keep the tool rail above every track layer. Track rows intentionally
        // span the full timeline height, so drawing the rail first allowed V1/A1
        // backgrounds to erase the Cut and Text buttons.
        drawToolColumn(canvas);
        drawToolTooltip(canvas);

        if (maxVerticalScroll() > 0)
        {
            const viewport = maxInt(1, bounds().height - rulerHeight() - NewTrackDropGap);
            const thumbHeight = maxInt(18, viewport * viewport /
                maxInt(1, contentTrackHeight()));
            const travel = maxInt(1, viewport - thumbHeight);
            const y = rulerHeight() + travel * _verticalScroll /
                maxInt(1, maxVerticalScroll());
            canvas.fillRoundedRect(Rect(bounds().width - 6, y, 4, thumbHeight),
                2, palette.textMuted.withAlpha(135));
        }
        canvas.strokeRect(full, palette.border.withAlpha(190), 1);
    }

    private void drawToolColumn(ref Canvas canvas)
    {
        const palette = theme();
        const width = toolColumnWidth();
        canvas.fillRect(Rect(0, 0, width, bounds().height), Color.fromHex(0x20242a));
        canvas.fillRect(Rect(width - 1, 0, 1, bounds().height), palette.border);
        foreach (index; 0 .. 4)
        {
            const y = 2 + cast(int) index * 22;
            const selected = cast(TimelineTool) index == _activeTool;
            const rect = Rect(4, y, maxInt(1, width - 8), 20);
            const label = index == 0 ? _selectionToolText :
                (index == 1 ? _cutToolText :
                (index == 2 ? _textToolText : _transitionToolText));
            canvas.drawRoundedRect(rect, 3, selected ? palette.accent :
                Color.fromHex(0x2a3038), selected ? palette.accentHover : palette.border, 1);
            canvas.drawTextInRect(rect, label, selected ? Color.rgb(255, 255, 255) :
                palette.textMuted, 1, HorizontalAlign.center, VerticalAlign.middle, true);
        }
    }


    private void drawToolTooltip(ref Canvas canvas)
    {
        if (_hoverToolIndex < 0 || _hoverToolIndex >= 4 ||
            _pointerMode != PointerMode.none) return;
        const y = 2 + _hoverToolIndex * 22;
        const width = 112;
        const rect = Rect(toolColumnWidth() + 4, y, width, 20);
        canvas.drawRoundedRect(rect, 3, Color.fromHex(0x111418).withAlpha(245),
            theme().border, 1);
        canvas.drawTextInRect(Rect(rect.x + 6, rect.y, rect.width - 12, rect.height),
            _toolTips[cast(size_t) _hoverToolIndex], theme().text, 1,
            HorizontalAlign.left, VerticalAlign.middle, true);
    }

    private void drawRuler(ref Canvas canvas)
    {
        const palette = theme();
        const duration = visibleDuration();
        double interval = 1.0;
        if (_pixelsPerSecond < 30.0) interval = 10.0;
        else if (_pixelsPerSecond < 55.0) interval = 5.0;
        else if (_pixelsPerSecond < 100.0) interval = 2.0;
        else if (_pixelsPerSecond > 500.0) interval = 0.2;
        else if (_pixelsPerSecond > 250.0) interval = 0.5;

        const firstIndex = cast(long) (_scrollSeconds / interval);
        const first = firstIndex * interval;
        for (double value = first;
             value <= _scrollSeconds + duration + interval; value += interval)
        {
            const x = xForTime(value);
            if (x < labelWidth() || x >= bounds().width) continue;
            canvas.fillRect(Rect(x, 14, 1, 10), palette.border);
            const labelOffset = x <= labelWidth() + 1 ? 7 : 3;
            canvas.drawTextInRect(Rect(x + labelOffset, 0, 78, 15),
                rulerLabel(value), palette.textMuted, 1,
                HorizontalAlign.left, VerticalAlign.middle, true);
        }
        canvas.drawTextInRect(Rect(toolColumnWidth() + 5, 0,
                maxInt(0, labelColumnWidth() - 8), rulerHeight()),
            _sequenceText, palette.textMuted, 1,
            HorizontalAlign.left, VerticalAlign.middle, true);
    }

    private void drawWorkArea(ref Canvas canvas)
    {
        if (!_hasWorkIn && !_hasWorkOut) return;
        const start = _hasWorkIn ? _workIn : 0.0;
        const finish = _hasWorkOut ? _workOut : _model.sequenceDuration();
        const startX = xForTime(start);
        const finishX = xForTime(finish);
        const shade = Color.rgba(0, 0, 0, 82);
        const trackTop = rulerHeight();
        const trackHeightPixels = maxInt(0, bounds().height - trackTop);

        if (startX > labelWidth())
        {
            const right = minInt(bounds().width, startX);
            if (right > labelWidth())
                canvas.fillRect(Rect(labelWidth(), trackTop,
                    right - labelWidth(), trackHeightPixels), shade);
        }
        if (finishX < bounds().width)
        {
            const left = maxInt(labelWidth(), finishX);
            if (left < bounds().width)
                canvas.fillRect(Rect(left, trackTop,
                    bounds().width - left, trackHeightPixels), shade);
        }
    }

    private void drawTimelineGuides(ref Canvas canvas)
    {
        const origin = timeOriginX();
        if (origin >= labelWidth() && origin < bounds().width)
            canvas.fillRect(Rect(origin, 0, 1, bounds().height),
                theme().accent.withAlpha(100));

        if (_hasWorkIn)
        {
            const x = xForTime(_workIn);
            if (x >= labelWidth() && x < bounds().width)
            {
                const color = Color.fromHex(0x4fc3f7);
                canvas.fillRect(Rect(x, 0, 2, bounds().height), color.withAlpha(205));
                canvas.fillRoundedRect(Rect(x - 3, 1, 8, 8), 2, color);
            }
        }
        if (_hasWorkOut)
        {
            const x = xForTime(_workOut);
            if (x >= labelWidth() && x < bounds().width)
            {
                const color = Color.fromHex(0xffb74d);
                canvas.fillRect(Rect(x - 1, 0, 2, bounds().height), color.withAlpha(205));
                canvas.fillRoundedRect(Rect(x - 4, 1, 8, 8), 2, color);
            }
        }
    }

    private void drawTrack(ref Canvas canvas, TrackAddress address)
    {
        const palette = theme();
        const rect = trackRect(address);
        const track = _model.trackValue(address);
        const selectedTrack = address == _selectedTrack;
        const base = address.kind == TrackKind.video ?
            Color.fromHex(0x1c2027) : Color.fromHex(0x1a2020);
        // Track paint starts after the permanent tool rail. This prevents
        // row backgrounds and separators from ever erasing S/C/T controls.
        canvas.fillRect(Rect(toolColumnWidth(), rect.y,
                maxInt(0, bounds().width - toolColumnWidth()), rect.height),
            track.disabled ? base.darker(26) : base);
        // The track-label background must begin after the tool rail. Previously
        // it started at x=0 and painted over the Cut and Text tool buttons.
        canvas.fillRect(Rect(toolColumnWidth(), rect.y,
                maxInt(0, labelColumnWidth() - 1), rect.height),
            selectedTrack ? Color.fromHex(0x303844) : Color.fromHex(0x242930));
        canvas.drawTextInRect(Rect(toolColumnWidth() + 5, rect.y,
                maxInt(18, labelColumnWidth() - 8), rect.height),
            trackLabelText(address), track.disabled ? palette.disabled : palette.text,
            1, HorizontalAlign.left, VerticalAlign.middle, true);
        dstring state;
        if (track.muted && track.disabled)
            state = address.kind == TrackKind.video ?
                _stateMutedHidden : _stateMutedDisabled;
        else if (track.muted)
            state = _stateMuted;
        else if (track.disabled)
            state = address.kind == TrackKind.video ? _stateHidden : _stateDisabled;
        if (state.length > 0)
            canvas.drawTextInRect(Rect(labelWidth() - 22, rect.y, 18, rect.height), state,
                palette.textMuted, 1, HorizontalAlign.right, VerticalAlign.middle, true);
        canvas.fillRect(Rect(toolColumnWidth(), rect.bottom() - 1,
                maxInt(0, bounds().width - toolColumnWidth()), 1),
            palette.border.withAlpha(105));

        if (address.kind == TrackKind.audio)
            drawEmbeddedAudioProxies(canvas, address);

        const clips = track.clips;
        const visibleEnd = _scrollSeconds + visibleDuration();
        size_t index = firstVisibleClip(clips, _scrollSeconds);
        for (; index < clips.length; ++index)
        {
            const clip = clips[index];
            if (clip.start > visibleEnd) break;
            const clipBounds = clipRect(address, clip);
            if (clipBounds.empty()) continue;
            ++_lastPaintedClipCount;
            const selected = clipIsSelected(clip.id);
            const color = clip.isText() ? Color.fromHex(0x2f9b63) :
                (address.kind == TrackKind.video ?
                    Color.fromHex(0x6359a8) : Color.fromHex(0x2f8a62));
            const fill = clip.muted || track.muted ? color.darker(38) : color;
            canvas.drawRoundedRect(clipBounds, 2, fill,
                selected ? palette.accentHover : color.lighter(24), selected ? 2 : 1);

            if (clipBounds.width > 18)
            {
                canvas.drawTextInRect(Rect(clipBounds.x + 4, clipBounds.y,
                        maxInt(0, clipBounds.width - 8), clipBounds.height),
                    assetTitleText(clip), Color.rgb(255, 255, 255), 1,
                    HorizontalAlign.left, VerticalAlign.middle, true);
            }
            if (address.kind == TrackKind.audio && clipBounds.width > 8)
            {
                const center = clipBounds.y + clipBounds.height / 2;
                for (int x = clipBounds.x + 4; x < clipBounds.right() - 3; x += 8)
                {
                    const amount = 1 + cast(int) ((clip.id + cast(ulong) x * 7) % 4);
                    canvas.fillRect(Rect(x, center - amount, 1, amount * 2),
                        Color.rgba(235, 255, 245, 120));
                }
            }

            foreach (keyframe; clip.keyframes)
            {
                const markerX = xForTime(clip.start + keyframe.time);
                if (markerX < clipBounds.x || markerX >= clipBounds.right()) continue;
                const markerY = clipBounds.bottom() - 5;
                const markerColor = Color.fromHex(0xffd45a);
                final switch (keyframe.interpolation)
                {
                    case KeyframeInterpolation.linear:
                        canvas.fillRect(Rect(markerX - 2, markerY - 2, 5, 5),
                            markerColor.withAlpha(220));
                        canvas.fillRect(Rect(markerX - 3, markerY, 7, 1), markerColor);
                        break;
                    case KeyframeInterpolation.bezier:
                        canvas.fillRoundedRect(Rect(markerX - 3, markerY - 3, 7, 7),
                            3, markerColor);
                        break;
                    case KeyframeInterpolation.hold:
                        canvas.drawRoundedRect(Rect(markerX - 3, markerY - 3, 7, 7),
                            1, Color.fromHex(0x2b2b2b), markerColor, 2);
                        break;
                }
            }
        }

        if (clips.length == 0 && bounds().width > labelWidth() + 120)
            canvas.drawTextInRect(Rect(labelWidth() + 10, rect.y,
                    bounds().width - labelWidth() - 16, rect.height),
                _dropMediaText, palette.textMuted.withAlpha(115), 1,
                HorizontalAlign.left, VerticalAlign.middle, true);
    }

    private void drawEmbeddedAudioProxies(ref Canvas canvas, TrackAddress audioTrack)
    {
        const audioCount = _model.trackCount(TrackKind.audio);
        if (audioCount == 0) return;
        const visibleEnd = _scrollSeconds + visibleDuration();
        foreach (videoLane; 0 .. _model.trackCount(TrackKind.video))
        {
            const targetLane = videoLane < audioCount ? videoLane : 0;
            if (audioTrack.lane != targetLane) continue;
            const videoTrack = _model.trackValue(TrackAddress(TrackKind.video, videoLane));
            size_t index = firstVisibleClip(videoTrack.clips, _scrollSeconds);
            for (; index < videoTrack.clips.length; ++index)
            {
                const clip = videoTrack.clips[index];
                if (clip.start > visibleEnd) break;
                if (!clip.audioProxyVisible || clip.isText()) continue;
                if (clip.assetIndex >= _model.assets.length || !_model.assets[clip.assetIndex].hasAudio)
                    continue;
                const bounds = clipRect(audioTrack, clip);
                if (bounds.empty()) continue;
                const color = Color.fromHex(0x5fa8ff);
                canvas.drawRoundedRect(bounds, 2, color.withAlpha(40), color.withAlpha(145), 1);
                const center = bounds.y + bounds.height / 2;
                for (int x = bounds.x + 4; x < bounds.right() - 3; x += 8)
                {
                    const amount = 1 + cast(int) ((clip.id + cast(ulong) x * 5) % 4);
                    canvas.fillRect(Rect(x, center - amount, 1, amount * 2),
                        color.withAlpha(135));
                }
            }
        }
    }

    private void drawResizePreview(ref Canvas canvas)
    {
        if (_pointerMode != PointerMode.clipResizeStart &&
            _pointerMode != PointerMode.clipResizeEnd) return;
        const row = trackRect(_pressTrack);
        if (row.empty()) return;
        const x0 = maxInt(labelWidth(), xForTime(_resizePreviewStart));
        const x1 = minInt(bounds().width, xForTime(_resizePreviewEnd));
        const bodyHeight = maxInt(18, minInt(22, row.height - 4));
        const bodyY = row.y + maxInt(2, (row.height - bodyHeight) / 2);
        const rect = Rect(x0, bodyY, maxInt(3, x1 - x0), bodyHeight);
        canvas.drawRoundedRect(rect, 2, theme().accent.withAlpha(60),
            theme().accentHover, 2);
    }

    private void drawGhost(ref Canvas canvas)
    {
        if (!_ghostVisible) return;
        Rect row;
        if (_ghostNewTrack)
        {
            if (_ghostTrack.kind == TrackKind.video)
                row = trackRect(TrackAddress(TrackKind.video,
                    _model.trackCount(TrackKind.video) - 1));
            else
                row = trackRect(TrackAddress(TrackKind.audio,
                    _model.trackCount(TrackKind.audio) - 1));
        }
        else
            row = trackRect(_ghostTrack);
        if (row.empty()) return;

        int x0 = maxInt(labelWidth(), xForTime(_ghostStart));
        int x1 = minInt(bounds().width, xForTime(_ghostStart + _ghostDuration));
        const ghostHeight = maxInt(18, minInt(22, row.height - 4));
        const rect = Rect(x0, row.y + maxInt(2, (row.height - ghostHeight) / 2),
            maxInt(4, x1 - x0), ghostHeight);
        const color = _ghostValid ? theme().accent : Color.fromHex(0xd65454);
        canvas.fillRoundedRect(rect, 2, color.withAlpha(105));
        canvas.strokeRect(rect, color, 1);
        if (_ghostNewTrack)
            canvas.drawTextInRect(Rect(labelWidth() + 4, row.y,
                    maxInt(80, bounds().width - labelWidth() - 8), row.height),
                _ghostTrackText, color, 1,
                HorizontalAlign.right, VerticalAlign.middle, true);
    }

    private bool clipIsSelected(ulong id) const
    {
        foreach (selectedId; _selectedClipIds)
            if (selectedId == id) return true;
        return false;
    }

    private Rect normalizedDragRect(Point first, Point second) const
    {
        int left = minInt(first.x, second.x);
        int top = minInt(first.y, second.y);
        int right = maxInt(first.x, second.x);
        int bottom = maxInt(first.y, second.y);
        // A horizontal marquee on one track is a natural gesture. Give a
        // zero-height drag a small vertical hit band instead of treating it as
        // an empty rectangle.
        if (bottom - top < 6)
        {
            const center = (top + bottom) / 2;
            top = center - 3;
            bottom = center + 4;
        }
        left = maxInt(labelWidth(), left);
        top = maxInt(rulerHeight(), top);
        right = minInt(bounds().width, right);
        bottom = minInt(bounds().height, bottom);
        return Rect(left, top, maxInt(0, right - left), maxInt(0, bottom - top));
    }

    private void updateMarqueeSelection()
    {
        _selectedClipIds.length = 0;
        const selectionRect = normalizedDragRect(_marqueeOrigin, _marqueeCurrent);
        bool havePrimary;
        foreach (row; 0 .. totalRows())
        {
            const address = addressForRow(row);
            const trackRectValue = trackRect(address);
            if (trackRectValue.intersection(selectionRect).empty()) continue;
            const clips = _model.trackValue(address).clips;
            foreach (index, clip; clips)
            {
                const rect = clipRect(address, clip);
                if (rect.empty() || rect.intersection(selectionRect).empty()) continue;
                _selectedClipIds ~= clip.id;
                if (!havePrimary)
                {
                    _selectedTrack = address;
                    _selectedIndex = cast(int) index;
                    havePrimary = true;
                }
            }
        }
        if (!havePrimary)
        {
            TrackAddress address = _selectedTrack;
            if (trackAtY(_marqueeOrigin.y, address)) _selectedTrack = address;
            _selectedIndex = -1;
        }
    }

    private void drawMarqueeSelection(ref Canvas canvas)
    {
        if (_pointerMode != PointerMode.marqueeSelect || !_marqueeMoved) return;
        const rect = normalizedDragRect(_marqueeOrigin, _marqueeCurrent);
        if (rect.empty()) return;
        const color = theme().accent;
        canvas.fillRect(rect, color.withAlpha(34));
        canvas.strokeRect(rect, color.withAlpha(220), 1);
    }

    private void drawTextCreatePreview(ref Canvas canvas)
    {
        if (_pointerMode != PointerMode.textCreate || !_textCreateMoved ||
            !_model.validTrack(_textCreateTrack)) return;
        const start = _textCreateStart < _textCreateEnd ?
            _textCreateStart : _textCreateEnd;
        const finish = _textCreateStart < _textCreateEnd ?
            _textCreateEnd : _textCreateStart;
        const row = trackRect(_textCreateTrack);
        if (row.empty()) return;
        const x0 = maxInt(labelWidth(), xForTime(start));
        const x1 = minInt(bounds().width, xForTime(finish));
        const bodyHeight = maxInt(18, minInt(22, row.height - 4));
        const rect = Rect(x0, row.y + maxInt(2, (row.height - bodyHeight) / 2),
            maxInt(3, x1 - x0), bodyHeight);
        const color = Color.fromHex(0xc47bd8);
        canvas.fillRoundedRect(rect, 2, color.withAlpha(105));
        canvas.strokeRect(rect, color, 1);
    }

    private void restoreToolCursor()
    {
        if (_activeTool == TimelineTool.cut) setCursor(CursorKind.resizeDiagonalNESW);
        else if (_activeTool == TimelineTool.text) setCursor(CursorKind.text);
        else if (_activeTool == TimelineTool.transition) setCursor(CursorKind.resizeHorizontal);
        else setCursor(CursorKind.arrow);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return false;
        requestFocus();

        TrackAddress address = _selectedTrack;
        const overTrack = trackAtY(event.position.y, address);
        const index = overTrack ? clipAtPoint(address, event.position) : -1;

        if (event.button == MouseButton.right)
        {
            if (overTrack) setSelection(address, index);
            if (onContextMenuRequested !is null)
                onContextMenuRequested(overTrack ? address : _selectedTrack,
                    overTrack ? index : _selectedIndex, event.globalPosition);
            return true;
        }

        const toolIndex = toolIndexAt(event.position);
        if (toolIndex >= 0)
        {
            setActiveTool(cast(TimelineTool) toolIndex);
            return true;
        }

        // The ruler is always a transport surface. Selection, Cut and Text
        // tools must never prevent moving the timeline playhead.
        if (event.position.y < rulerHeight() && event.position.x >= labelWidth())
        {
            beginScrubGesture();
            setPlayhead(timeForX(event.position.x));
            _pointerMode = PointerMode.playhead;
            captureMouse();
            return true;
        }

        if (overLabelResizeHandle(event.position))
        {
            _pointerMode = PointerMode.labelResize;
            captureMouse();
            setCursor(CursorKind.resizeHorizontal);
            return true;
        }

        TrackAddress resizeTarget;
        if (resizeTrackAtY(event.position.y, resizeTarget) &&
            event.position.x >= toolColumnWidth())
        {
            _pointerMode = PointerMode.trackResize;
            _resizeTrack = resizeTarget;
            _resizeStartY = event.position.y;
            _resizeStartHeight = trackHeight(resizeTarget);
            captureMouse();
            setCursor(CursorKind.resizeVertical);
            return true;
        }

        // Double-click empty sequence space, keep the second press held,
        // and drag a marquee across one or more tracks to select every item
        // touched by the rectangle. A normal single drag remains the playhead
        // scrub gesture, preserving fast transport access.
        if (_activeTool == TimelineTool.selection && overTrack && index < 0 &&
            event.position.x >= labelWidth() && event.clickCount >= 2)
        {
            _pointerMode = PointerMode.marqueeSelect;
            _marqueeOrigin = event.position;
            _marqueeCurrent = event.position;
            _marqueeMoved = false;
            captureMouse();
            setCursor(CursorKind.arrow);
            return true;
        }

        if (_activeTool == TimelineTool.transition)
        {
            if (overTrack && index >= 0 && event.position.x >= labelWidth())
            {
                TimelineClip clip;
                if (_model.copyClip(address, index, clip))
                {
                    const t = timeForX(event.position.x);
                    const fromStart = t - clip.start;
                    const fromEnd = clip.end() - t;
                    const fadeInSide = fromStart <= fromEnd;
                    const rawDuration = fadeInSide ? fromStart : fromEnd;
                    const duration = rawDuration < 0.0 ? 0.0 :
                        (rawDuration > clip.duration() ? clip.duration() : rawDuration);
                    setSelection(address, index);
                    if (onTransitionToolRequested !is null)
                        onTransitionToolRequested(address, index, fadeInSide, duration);
                }
            }
            return true;
        }

        if (_activeTool == TimelineTool.cut)
        {
            if (overTrack && event.position.x >= labelWidth())
            {
                const t = timeForX(event.position.x);
                setPlayhead(t);
                if (index >= 0 && onCutToolRequested !is null)
                {
                    setSelection(address, index);
                    onCutToolRequested(address, t);
                }
            }
            return true;
        }

        if (_activeTool == TimelineTool.text)
        {
            // Clicking an existing item selects it instead of continuously
            // creating more text clips. Text placement is intentionally a
            // one-shot operation and then returns to Selection.
            if (overTrack && index >= 0)
            {
                setSelection(address, index);
                setActiveTool(TimelineTool.selection);
                if (event.clickCount >= 2 && onClipActivated !is null)
                    onClipActivated(address, index);
                return true;
            }
            if (overTrack && address.kind == TrackKind.video &&
                event.position.x >= labelWidth())
            {
                // Text items are created only by defining their duration with
                // a drag. A click without a meaningful drag creates nothing and
                // leaves the Text tool armed for another attempt.
                _pointerMode = PointerMode.textCreate;
                _textCreateTrack = address;
                _textCreateStart = timeForX(event.position.x);
                _textCreateEnd = _textCreateStart;
                _textCreateMoved = false;
                setPlayhead(_textCreateStart);
                captureMouse();
            }
            return true;
        }

        if (overTrack && index >= 0)
        {
            setSelection(address, index);
            TimelineClip clip;
            if (!_model.copyClip(address, index, clip)) return true;
            const edge = clipEdgeAtPoint(address, index, event.position);
            if (edge != 0)
            {
                _pressTrack = address;
                _pressIndex = index;
                _resizeClip = clip;
                _resizePreviewStart = clip.start;
                _resizePreviewEnd = clip.end();
                _pointerMode = edge < 0 ? PointerMode.clipResizeStart :
                    PointerMode.clipResizeEnd;
                captureMouse();
                setCursor(CursorKind.resizeHorizontal);
                invalidate();
                return true;
            }
            _pointerMode = PointerMode.clipPress;
            _pressTrack = address;
            _pressIndex = index;
            _pressPoint = event.position;
            _grabOffset = timeForX(event.position.x) - clip.start;
            _pressClickCount = event.clickCount;
            captureMouse();
            return true;
        }

        if (overTrack) setSelection(address, -1);
        if (event.position.x >= labelWidth())
        {
            beginScrubGesture();
            setPlayhead(timeForX(event.position.x));
            _pointerMode = PointerMode.playhead;
            captureMouse();
        }
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_pointerMode == PointerMode.marqueeSelect)
        {
            _marqueeCurrent = event.position;
            const dx = _marqueeCurrent.x - _marqueeOrigin.x;
            const dy = _marqueeCurrent.y - _marqueeOrigin.y;
            _marqueeMoved = dx * dx + dy * dy >= 16;
            if (_marqueeMoved) updateMarqueeSelection();
            setCursor(CursorKind.arrow);
            invalidate();
            return true;
        }
        if (_pointerMode == PointerMode.textCreate)
        {
            autoScrollDuringDrag(event.position);
            _textCreateEnd = timeForX(event.position.x);
            _textCreateMoved = fabs(_textCreateEnd - _textCreateStart) >= 0.05;
            setCursor(CursorKind.text);
            invalidate();
            return true;
        }
        if (_pointerMode == PointerMode.labelResize)
        {
            _labelColumnWidth = clampInt(event.position.x - toolColumnWidth(), 24, 120);
            if (_fitView) applyFitView();
            else
            {
                clampScroll();
                notifyHorizontalViewportChanged();
            }
            syncPlayheadLayer();
            invalidate();
            return true;
        }
        if (_pointerMode == PointerMode.trackResize)
        {
            const next = _resizeStartHeight + event.position.y - _resizeStartY;
            _model.setTrackHeight(_resizeTrack, next);
            clampVerticalScroll();
            syncPlayheadLayer();
            invalidate();
            return true;
        }
        if (_pointerMode == PointerMode.clipResizeStart ||
            _pointerMode == PointerMode.clipResizeEnd)
        {
            autoScrollDuringDrag(event.position);
            const t = timeForX(event.position.x);
            if (_pointerMode == PointerMode.clipResizeStart)
            {
                _resizePreviewStart = snappedEdge(t, 0.0,
                    _resizeClip.end() - 0.05, _pressTrack, _resizeClip.id);
                _resizePreviewEnd = _resizeClip.end();
            }
            else
            {
                _resizePreviewStart = _resizeClip.start;
                _resizePreviewEnd = snappedEdge(t,
                    _resizeClip.start + 0.05, double.max, _pressTrack,
                    _resizeClip.id);
            }
            setCursor(CursorKind.resizeHorizontal);
            invalidate();
            return true;
        }
        if (_pointerMode == PointerMode.playhead)
        {
            setPlayhead(timeForX(event.position.x));
            return true;
        }
        if (_pointerMode == PointerMode.clipPress)
        {
            const dx = event.position.x - _pressPoint.x;
            const dy = event.position.y - _pressPoint.y;
            if (dx * dx + dy * dy < 16) return true;
            _pointerMode = PointerMode.clipDrag;
            setCursor(CursorKind.move);
        }
        if (_pointerMode == PointerMode.clipDrag)
        {
            if (!_model.validTrack(_pressTrack)) return true;
            const clips = _model.trackValue(_pressTrack).clips;
            if (_pressIndex < 0 || _pressIndex >= cast(int) clips.length) return true;
            const clip = clips[cast(size_t) _pressIndex];
            updateGhost(event.position, clip.duration(), clip.assetIndex, clip.id);
            return true;
        }

        const nextHoverTool = toolIndexAt(event.position);
        if (nextHoverTool != _hoverToolIndex)
        {
            _hoverToolIndex = nextHoverTool;
            invalidate();
        }

        TrackAddress hoverTrack;
        int hoverIndex = -1;
        bool overClipEdge;
        if (_activeTool == TimelineTool.selection && trackAtY(event.position.y, hoverTrack))
        {
            hoverIndex = clipAtPoint(hoverTrack, event.position);
            overClipEdge = hoverIndex >= 0 &&
                clipEdgeAtPoint(hoverTrack, hoverIndex, event.position) != 0;
        }
        if (overClipEdge) setCursor(CursorKind.resizeHorizontal);
        else if (overLabelResizeHandle(event.position)) setCursor(CursorKind.resizeHorizontal);
        else if (resizeTrackAtY(event.position.y, hoverTrack)) setCursor(CursorKind.resizeVertical);
        else restoreToolCursor();
        return super.onMouseMove(event);
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || _pointerMode == PointerMode.none)
            return false;
        const mode = _pointerMode;
        _pointerMode = PointerMode.none;
        releaseMouse();
        restoreToolCursor();
        endScrubGesture();

        if (mode == PointerMode.labelResize || mode == PointerMode.trackResize)
            return true;
        if (mode == PointerMode.marqueeSelect)
        {
            if (_marqueeMoved) updateMarqueeSelection();
            if (onSelectionChanged !is null)
                onSelectionChanged(_selectedTrack, _selectedIndex);
            invalidate();
            return true;
        }
        if (mode == PointerMode.textCreate)
        {
            const start = _textCreateStart < _textCreateEnd ?
                _textCreateStart : _textCreateEnd;
            const finish = _textCreateStart < _textCreateEnd ?
                _textCreateEnd : _textCreateStart;
            if (_textCreateMoved && finish - start >= 0.25 &&
                onTextToolRequested !is null)
            {
                // Leave Text mode before the callback focuses the Inspector.
                // This removes a re-entrancy window where typing or clicking
                // during focus transfer could create another title item.
                setActiveTool(TimelineTool.selection);
                onTextToolRequested(_textCreateTrack, start, finish);
            }
            invalidate();
            return true;
        }
        if (mode == PointerMode.clipResizeStart || mode == PointerMode.clipResizeEnd)
        {
            if (onClipResizeRequested !is null)
                onClipResizeRequested(_pressTrack, _pressIndex,
                    _resizePreviewStart, _resizePreviewEnd);
            invalidate();
            return true;
        }

        if (mode == PointerMode.clipDrag)
        {
            const valid = _ghostVisible && _ghostValid;
            const destination = _ghostTrack;
            const start = _ghostStart;
            clearGhost();
            if (valid && onClipMoveRequested !is null)
                onClipMoveRequested(_pressTrack, _pressIndex, destination, start);
            return true;
        }
        if (mode == PointerMode.clipPress && _pressClickCount >= 2 &&
            onClipActivated !is null)
        {
            onClipActivated(_pressTrack, _pressIndex);
        }
        return true;
    }

    protected override void onMouseLeave()
    {
        if (_hoverToolIndex >= 0)
        {
            _hoverToolIndex = -1;
            invalidate();
        }
    }

    override bool onMouseWheel(ref Event event)
    {
        if (event.control() || event.meta())
        {
            setZoom(event.wheelY > 0 ? _pixelsPerSecond * 1.15 :
                _pixelsPerSecond / 1.15);
        }
        else if (event.shift() || maxVerticalScroll() == 0)
        {
            _fitView = false;
            _fitAllDurations = false;
            _scrollSeconds -= cast(double) event.wheelY * visibleDuration() * 0.10;
            clampScroll();
            syncPlayheadLayer();
            notifyHorizontalViewportChanged();
            invalidate();
        }
        else
        {
            _verticalScroll = clampInt(_verticalScroll - event.wheelY * 22,
                0, maxVerticalScroll());
            invalidate();
        }
        return true;
    }

    override bool onFilesDropped(ref Event event)
    {
        TrackAddress target;
        bool createsTrack;
        if (!candidateTrackAt(event.position, target, createsTrack) ||
            event.position.x < labelWidth()) return false;
        const start = snappedStart(timeForX(event.position.x), 0.0, target, 0);
        if (onExplorerMediaDropRequested !is null)
            onExplorerMediaDropRequested(event.paths, target, start);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape && (_externalDrag ||
            _pointerMode == PointerMode.clipDrag ||
            _pointerMode == PointerMode.clipResizeStart ||
            _pointerMode == PointerMode.clipResizeEnd ||
            _pointerMode == PointerMode.marqueeSelect ||
            _pointerMode == PointerMode.textCreate ||
            _pointerMode == PointerMode.playhead ||
            _pointerMode == PointerMode.trackResize ||
            _pointerMode == PointerMode.labelResize))
        {
            clearExternalDrag();
            clearGhost();
            _pointerMode = PointerMode.none;
            releaseMouse();
            setCursor(CursorKind.arrow);
            endScrubGesture();
            return true;
        }
        // Command shortcuts belong to the editor. Do not reinterpret
        // Ctrl+C/Ctrl+V/Ctrl+D as Cut, Selection, or timeline tool keys.
        if (event.control() || event.meta()) return false;
        switch (event.key)
        {
            case Key.left:
                setPlayhead(_playhead - (event.shift() ? 1.0 : 0.1));
                return true;
            case Key.right:
                setPlayhead(_playhead + (event.shift() ? 1.0 : 0.1));
                return true;
            case Key.home:
                setPlayhead(0.0);
                return true;
            case Key.end:
                setPlayhead(_model.sequenceDuration());
                return true;
            case Key.deleteKey:
                if (onDeleteRequested !is null) onDeleteRequested();
                return true;
            case Key.v:
                setActiveTool(TimelineTool.selection);
                return true;
            case Key.c:
                setActiveTool(TimelineTool.cut);
                return true;
            case Key.t:
                setActiveTool(TimelineTool.text);
                return true;
            case Key.r:
                setActiveTool(TimelineTool.transition);
                return true;
            case Key.s:
                if (onSplitRequested !is null) onSplitRequested();
                return true;
            case Key.space:
                if (onPreviewRequested !is null) onPreviewRequested();
                return true;
            case Key.i:
                if (event.shift())
                {
                    if (onClearRangeRequested !is null) onClearRangeRequested();
                }
                else if (onSetInRequested !is null)
                    onSetInRequested(_playhead);
                return true;
            case Key.o:
                if (event.shift())
                {
                    if (onClearRangeRequested !is null) onClearRangeRequested();
                }
                else if (onSetOutRequested !is null)
                    onSetOutRequested(_playhead);
                return true;
            default:
                return false;
        }
    }
}


/** Compact horizontal sequence scrollbar. The thumb size represents the
 * visible portion of the sequence and dragging it pans without changing zoom. */
final class TimelineHorizontalScrollbar : Widget
{
    private TimelineWidget _timeline;
    private bool _draggingThumb;
    private int _thumbGrabOffset;

    this(TimelineWidget timeline)
    {
        _timeline = timeline;
        setFocusable(true);
        setCursor(CursorKind.hand);
        setComposited(true);
        layoutHints().minHeight = 9;
        layoutHints().preferredHeight = 11;
    }

    Rect trackRectForTesting() const
    {
        return trackRect();
    }

    Rect thumbRectForTesting() const
    {
        return thumbRect();
    }

    private Rect trackRect() const
    {
        const left = _timeline is null ? 2 :
            clampInt(_timeline.horizontalViewportLeft(), 2, maxInt(2, bounds().width - 2));
        return Rect(left, 2, maxInt(1, bounds().width - left - 2),
            maxInt(4, bounds().height - 4));
    }

    private Rect thumbRect() const
    {
        const track = trackRect();
        if (_timeline is null || track.empty()) return track;
        const visible = _timeline.horizontalVisibleDuration();
        const content = _timeline.horizontalContentDuration();
        const total = content > visible ? content : visible;
        const minimumThumb = minInt(24, track.width);
        const width = clampInt(cast(int) (cast(double) track.width * visible /
            (total > 0.000_001 ? total : 1.0) + 0.5), minimumThumb, track.width);
        const travel = maxInt(0, track.width - width);
        const maximum = _timeline.horizontalScrollMaximum();
        const x = track.x + (maximum <= 0.000_001 ? 0 :
            cast(int) (cast(double) travel * _timeline.horizontalScroll() /
                maximum + 0.5));
        return Rect(x, track.y, width, track.height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const track = trackRect();
        const thumb = thumbRect();
        const maximum = _timeline is null ? 0.0 :
            _timeline.horizontalScrollMaximum();
        canvas.fillRoundedRect(track, maxInt(2, track.height / 2),
            theme().border.withAlpha(70));
        canvas.fillRoundedRect(thumb, maxInt(2, thumb.height / 2),
            (maximum > 0.000_001 ? theme().textMuted : theme().disabled)
                .withAlpha(_draggingThumb ? 230 : 170));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || _timeline is null ||
            _timeline.horizontalScrollMaximum() <= 0.000_001)
            return false;
        const track = trackRect();
        if (!track.contains(event.position)) return false;
        requestFocus();
        const thumb = thumbRect();
        _draggingThumb = true;
        _thumbGrabOffset = thumb.contains(event.position) ?
            event.position.x - thumb.x : thumb.width / 2;
        captureMouse();
        updateThumb(event.position.x);
        invalidate();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_draggingThumb) return false;
        updateThumb(event.position.x);
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_draggingThumb) return false;
        updateThumb(event.position.x);
        _draggingThumb = false;
        releaseMouse();
        invalidate();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (_timeline is null || event.wheelY == 0 ||
            _timeline.horizontalScrollMaximum() <= 0.000_001) return false;
        _timeline.setHorizontalScroll(_timeline.horizontalScroll() -
            cast(double) event.wheelY * _timeline.horizontalVisibleDuration() * 0.10);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (_timeline is null) return false;
        switch (event.key)
        {
            case Key.home:
                _timeline.setHorizontalScroll(0.0);
                return true;
            case Key.end:
                _timeline.setHorizontalScroll(_timeline.horizontalScrollMaximum());
                return true;
            case Key.pageUp:
                _timeline.setHorizontalScroll(_timeline.horizontalScroll() -
                    _timeline.horizontalVisibleDuration() * 0.85);
                return true;
            case Key.left:
                _timeline.setHorizontalScroll(_timeline.horizontalScroll() -
                    _timeline.horizontalVisibleDuration() * 0.15);
                return true;
            case Key.pageDown:
                _timeline.setHorizontalScroll(_timeline.horizontalScroll() +
                    _timeline.horizontalVisibleDuration() * 0.85);
                return true;
            case Key.right:
                _timeline.setHorizontalScroll(_timeline.horizontalScroll() +
                    _timeline.horizontalVisibleDuration() * 0.15);
                return true;
            default:
                return false;
        }
    }

    private void updateThumb(int pointerX)
    {
        const track = trackRect();
        const thumb = thumbRect();
        const travel = maxInt(1, track.width - thumb.width);
        const x = clampInt(pointerX - _thumbGrabOffset, track.x,
            track.right() - thumb.width);
        _timeline.setHorizontalScroll(cast(double) (x - track.x) /
            cast(double) travel * _timeline.horizontalScrollMaximum());
    }
}

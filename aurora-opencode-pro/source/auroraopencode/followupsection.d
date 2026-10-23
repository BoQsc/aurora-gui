module auroraopencode.followupsection;

import aurora;
import aurora.text.layout : TextLayoutOptions;
import auroraopencode.core : ChatSession, activeMessagePath, opencodeMuted, opencodeBorder;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import auroraopencode.completionhandoff : completionHandoffMarker;
import std.conv : to;
import std.datetime : Clock;
import std.string : startsWith, indexOf;
import std.utf : toUTF32;

struct FollowUpRange
{
    size_t markerIndex, startSlot, endSlot;
    long finalAnswerIndex = -1;
    bool work, live, stopped;
    double elapsedSeconds = 0;
    long startedTicks;
}

private long messageTicks(string id)
{
    if (!id.startsWith("m")) return 0;
    const end = id.indexOf('-');
    if (end <= 1) return 0;
    try return to!long(id[1 .. end]);
    catch (Exception) return 0;
}

// Existing message IDs contain durable wall-clock ticks. No control prompt or
// model request changes are needed to present and time these hidden boundaries.
FollowUpRange[] followUpRanges(const ref ChatSession session, const(size_t)[] path, bool running)
{
    FollowUpRange[] ranges;
    size_t current = size_t.max;
    foreach (slot, index; path)
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal)
        {
            if (current != size_t.max) ranges[current].endSlot = slot;
            current = size_t.max;
        }
        if (message.internal && message.role == "user" &&
            (message.content.startsWith(taskContinuationMarker) ||
             message.content.startsWith(completionHandoffMarker)))
        {
            if (current == size_t.max)
            {
                FollowUpRange range;
                range.markerIndex = index; range.startSlot = slot; range.endSlot = path.length;
                range.startedTicks = messageTicks(message.id);
                ranges ~= range; current = ranges.length - 1;
            }
            ranges[current].work |= message.content.startsWith(taskContinuationMarker);
        }
        if (current != size_t.max && message.role == "assistant" && !message.internal && !message.toolCalls.length)
        {
            ranges[current].finalAnswerIndex = cast(long) index;
            ranges[current].stopped = message.finishReason == "cancelled";
        }
    }
    foreach (ref range; ranges)
    {
        range.stopped |= session.messages[range.markerIndex].finishReason == "cancelled";
        range.stopped |= range.endSlot == path.length && session.turnStatus == "interrupted";
        const recorded = session.messages[range.markerIndex].workedSeconds;
        range.live = running && range.endSlot == path.length && recorded <= 0;
        if (recorded > 0) range.elapsedSeconds = recorded;
        else if (range.startedTicks > 0)
        {
            const end = range.live ? Clock.currTime.stdTime : messageTicks(session.messages[path[range.endSlot - 1]].id);
            range.elapsedSeconds = end > range.startedTicks ? (end - range.startedTicks) / 10_000_000.0 : 0;
        }
    }
    return ranges;
}

// workedSeconds already persists independently of model prose. On an internal
// boundary it records this section's elapsed time; conversation totals count
// only human user messages, so this does not add time twice.
size_t[] freezeFollowUpTimers(ref ChatSession session, bool stopped = false)
{
    const path = activeMessagePath(session);
    size_t[] changed;
    foreach (range; followUpRanges(session, path, false))
        if (range.endSlot == path.length && range.startedTicks > 0)
        {
            auto marker = &session.messages[range.markerIndex];
            bool updated;
            if (marker.workedSeconds <= 0)
            {
                const ticks = Clock.currTime.stdTime - range.startedTicks;
                marker.workedSeconds = ticks > 0 ? ticks / 10_000_000.0 : 0.001;
                updated = true;
            }
            if (stopped && marker.finishReason != "cancelled")
            { marker.finishReason = "cancelled"; updated = true; }
            if (updated) changed ~= range.markerIndex;
        }
    return changed;
}

/// A quiet, keyboard-accessible divider. Folding affects presentation only;
/// original messages, tool results and their controls remain retained children.
final class AutomaticFollowUpSection : VBox
{
    private bool _collapsed = true;
    private bool[Widget] _visibility;
    private FollowUpRange _range;
    private TextLayout _noticeLayout, _labelLayout;
    private int _headerHeight, _lineY;
    private string _label;
    void delegate(bool) onCollapseChanged;

    this()
    {
        super(6, Insets(0));
        setId("oc-automatic-follow-up");
        setFocusable(true);
    }
    bool collapsed() const { return _collapsed; }
    string label() const { return _label; }
    string notice() const
    {
        const text = _range.work
            ? "Extra review may improve the result. Expand for checks and any remaining work."
            : "An additional summary may make the result easier to review.";
        return text ~ (_range.live ? " You can stop it at any time." : "");
    }
    void restoreRows()
    {
        foreach (row, visible; _visibility) row.setVisible(visible);
        _visibility = null;
    }
    void update(Widget[] rows, FollowUpRange range)
    {
        restoreRows();
        reconcileChildren(rows);
        _range = range;
        updateLabel(); applyVisibility(); invalidate();
    }
    private void updateLabel()
    {
        double elapsed = _range.elapsedSeconds;
        if (_range.live && _range.startedTicks > 0)
        {
            const ticks = Clock.currTime.stdTime - _range.startedTicks;
            elapsed = ticks > 0 ? ticks / 10_000_000.0 : 0;
        }
        const seconds = cast(long) elapsed;
        const time = seconds >= 60 ? to!string(seconds / 60) ~ "m " ~ to!string(seconds % 60) ~ "s" : to!string(seconds) ~ "s";
        const text = (_range.work ? "Automatic follow-up" : "Additional summary") ~ " · " ~
            (_range.live ? "Running" : _range.stopped ? "Stopped" : "Finished") ~ " · " ~ time;
        if (_label != text) { _label = text; invalidate(); }
    }
    private void applyVisibility()
    {
        foreach (row; children())
        {
            if (row !in _visibility) _visibility[row] = row.visible();
            row.setVisible(!_collapsed && _visibility[row]);
        }
    }
    void setCollapsed(bool value)
    {
        if (_collapsed == value) return;
        _collapsed = value; applyVisibility(); invalidate();
        if (onCollapseChanged !is null) onCollapseChanged(value);
    }
    protected override void onTick(double deltaSeconds) { if (_range.live) updateLabel(); }
    protected override Size onMeasure(Size available)
    {
        TextLayoutOptions options;
        options.role = FontRole.ui; options.overrideFace = cast() theme().uiFont;
        options.pixelSize = fontPixelSize(1); options.wrap = true;
        options.maxWidth = maxInt(1, available.width - 24);
        _noticeLayout = fontSystem().textEngine.layout(toUTF32(notice()), options);
        _labelLayout = fontSystem().textEngine.layout(toUTF32((_collapsed ? "▸ " : "▾ ") ~ _label), options);
        _lineY = 16 + cast(int) _noticeLayout.height;
        _headerHeight = _lineY + cast(int) _labelLayout.height + 12;
        int body;
        if (!_collapsed) foreach (row; children()) if (row.visible())
            body += row.measure(Size(available.width, available.height)).height + spacing();
        layoutHints().preferredWidth = available.width;
        layoutHints().preferredHeight = _headerHeight + body;
        return Size(available.width, _headerHeight + body);
    }
    protected override void onLayout()
    {
        int y = _headerHeight;
        foreach (row; children()) if (row.visible())
        {
            const height = row.layoutHints().preferredHeight;
            row.setBounds(Rect(0, y, bounds().width, maxInt(0, height)));
            y += maxInt(0, height) + spacing();
        }
    }
    protected override void onPaint(ref Canvas canvas)
    {
        if (_noticeLayout is null || _labelLayout is null) return;
        canvas.drawLayout(Point(10, 6), _noticeLayout, opencodeMuted);
        canvas.drawLayout(Point(10, _lineY), _labelLayout, opencodeMuted);
        const x = 18 + cast(int) _labelLayout.width;
        if (x < bounds().width - 10)
            canvas.fillRect(Rect(x, _lineY + cast(int) _labelLayout.height / 2,
                bounds().width - 10 - x, 1), opencodeBorder);
    }
    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || event.position.y >= _headerHeight) return false;
        requestFocus(); setCollapsed(!_collapsed); return true;
    }
    override bool onKeyDown(ref Event event)
    {
        if (event.key != Key.enter && event.key != Key.space) return super.onKeyDown(event);
        setCollapsed(!_collapsed); return true;
    }
    override bool onMouseMove(ref Event event)
    { setCursor(event.position.y < _headerHeight ? CursorKind.hand : CursorKind.arrow); return false; }
    protected override void onMouseLeave() { setCursor(CursorKind.arrow); }
}

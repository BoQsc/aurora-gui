module auroradesktop.calendar;

import aurora;
import aurora.widgets.popup : dismissTransientPopups, popupRoot;
import core.stdc.time : time_t, tm, localtime, time;
import std.conv : to;
import std.utf : toUTF32;

/**
 * A Windows-10-style calendar flyout that slides upward from the taskbar clock.
 *
 * It renders a month grid (current month by default) with prev/next navigation,
 * highlights today, and animates from below the clock up to its resting place.
 * The popup is a TransientPopup so it dismisses on click-away / Escape.
 */
final class CalendarPopup : TransientPopup
{
    private Rect _panelRect;
    private int _margin = 8;
    private int _gap = 6;
    private int _panelWidth = 340;
    private int _panelHeight = 360;
    private int _year;
    private int _month; // 1..12
    private int _todayDay;
    private int _todayMonth;
    private int _todayYear;
    private double _anim;
    private int _startY;
    private int _restY;

    this(Widget focusReturn = null)
    {
        super(focusReturn);
        setCursor(CursorKind.arrow);
        initToday();
    }

    void initToday()
    {
        time_t raw;
        time(&raw);
        auto info = localtime(&raw);
        if (info !is null)
        {
            _todayDay = info.tm_mday;
            _todayMonth = info.tm_mon + 1;
            _todayYear = info.tm_year + 1900;
            _year = _todayYear;
            _month = _todayMonth;
        }
        else
        {
            import core.stdc.time : time_t;
            _todayDay = 1; _todayMonth = 1; _todayYear = 2000;
            _year = 2000; _month = 1;
        }
    }

    Rect panelRect() const @safe pure nothrow @nogc
    {
        return _panelRect;
    }

    override bool popupContains(Point globalPoint) const
        @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    bool show(Widget owner, Rect globalAnchor)
    {
        auto root = popupRoot(owner);
        if (root is null) return false;
        dismissTransientPopups(root);
        prepareToOpen(owner);
        _anchorGlobal = globalAnchor;
        root.add(this);
        setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
        root.bringChildToFront(this);
        recalculateLayout();
        // Remember the resting position (above the clock), then start just
        // below it and slide up. The resting Y must be captured BEFORE the
        // panel origin is moved, or the animation would target the start.
        _restY = _panelRect.y;
        _startY = _panelRect.y + _panelHeight;
        setPanelOrigin(Point(_panelRect.x, _startY));
        _anim = 0.0;
        requestFocus();
        invalidate();
        return true;
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        const consume = _anchorGlobal.contains(globalPoint);
        dismiss();
        return consume;
    }

    private Rect _anchorGlobal;

    private void recalculateLayout()
    {
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            return;
        }
        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);
        const width = minInt(_panelWidth, availableWidth);
        const height = minInt(_panelHeight, availableHeight);
        const rootOrigin = globalOrigin();
        const anchor = Rect(_anchorGlobal.x - rootOrigin.x,
            _anchorGlobal.y - rootOrigin.y, _anchorGlobal.width, _anchorGlobal.height);
        int x = anchor.x + anchor.width / 2 - width / 2;
        int y = anchor.y - height - _gap;
        if (y < _margin) y = anchor.bottom() + _gap;
        x = clampInt(x, _margin, maxInt(_margin, bounds().width - width - _margin));
        y = clampInt(y, _margin, maxInt(_margin, bounds().height - height - _margin));
        _panelRect = Rect(x, y, width, height);
    }

    // Place the panel (clamped) at a specific origin; used for the slide.
    private void setPanelOrigin(Point origin)
    {
        int x = clampInt(origin.x, _margin,
            maxInt(_margin, bounds().width - _panelRect.width - _margin));
        int y = origin.y;
        _panelRect = Rect(x, cast(int) (origin.y), _panelRect.width,
            _panelRect.height);
        invalidate();
    }

    protected override void onTick(double deltaSeconds)
    {
        super.onTick(deltaSeconds);
        if (_anim < 1.0)
        {
            _anim += deltaSeconds / 0.20;
            if (_anim > 1.0) _anim = 1.0;
            // Ease-out; slide from start (below the clock) up to rest (above).
            const t = 1.0 - (1.0 - _anim) * (1.0 - _anim);
            const y = cast(int) (_startY + (_restY - _startY) * t);
            _panelRect.y = y;
            invalidate();
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_panelRect.empty()) return;
        const palette = theme();
        canvas.fillRoundedRect(_panelRect.translated(4, 5), 9,
            palette.shadow.withAlpha(145));
        canvas.drawRoundedRect(_panelRect, 9, palette.panelElevated,
            palette.border.withAlpha(230), 1);
        paintCalendarBody(canvas);
    }

    private void paintCalendarBody(ref Canvas canvas)
    {
        const palette = theme();
        const inner = _panelRect.inset(12);
        // Header: "< Month Year >" with prev/next buttons.
        const header = Rect(inner.x, inner.y, inner.width, 30);
        canvas.drawTextInRect(Rect(header.x, header.y, header.width - 70,
            header.height), toUTF32(monthName(_month) ~ " " ~ _year.to!string),
            palette.text, 2, HorizontalAlign.center, VerticalAlign.middle, true);
        drawCalendarNav(canvas, Rect(header.right() - 64, header.y, 64, header.height));

        // Day-of-week labels.
        const dowY = header.bottom() + 6;
        string[] dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        const cellW = inner.width / 7;
        foreach (i, name; dow)
        {
            canvas.drawTextInRect(Rect(inner.x + cast(int) i * cellW, dowY, cellW, 22),
                toUTF32(name), palette.textMuted, 1, HorizontalAlign.center,
                VerticalAlign.middle, true);
        }

        // Day grid.
        const gridY = dowY + 26;
        const daysInMonth = daysInMonth(_year, _month);
        const firstWeekday = firstWeekday(_year, _month); // 0=Sunday
        const rows = (firstWeekday + daysInMonth + 6) / 7;
        const cellH = (inner.bottom() - gridY) / maxInt(6, rows);
        foreach (day; 0 .. daysInMonth)
        {
            const idx = firstWeekday + day;
            const column = idx % 7;
            const row = idx / 7;
            const cell = Rect(inner.x + column * cellW,
                gridY + row * cellH, cellW, cellH);
            const isToday = (day + 1 == _todayDay &&
                _month == _todayMonth && _year == _todayYear);
            if (isToday)
                canvas.fillCircle(Point(cell.x + cell.width / 2,
                        cell.y + cell.height / 2), 16, palette.accent);
            canvas.drawTextInRect(cell, toUTF32((day + 1).to!string),
                isToday ? Color.rgb(255, 255, 255) : palette.text, 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
        }
    }

    private void drawCalendarNav(ref Canvas canvas, Rect rect)
    {
        const palette = theme();
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        // Left/right chevrons.
        canvas.drawLine(Point(cx - 14, cy - 5), Point(cx - 20, cy), palette.text, 1);
        canvas.drawLine(Point(cx - 20, cy), Point(cx - 14, cy + 5), palette.text, 1);
        canvas.drawLine(Point(cx + 14, cy - 5), Point(cx + 20, cy), palette.text, 1);
        canvas.drawLine(Point(cx + 20, cy), Point(cx + 14, cy + 5), palette.text, 1);
        _navLeftRect = Rect(cx - 26, cy - 10, 26, 20);
        _navRightRect = Rect(cx + 2, cy - 10, 26, 20);
    }

    private Rect _navLeftRect;
    private Rect _navRightRect;

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return true;
        if (!_panelRect.contains(event.position))
        {
            dismiss();
            return true;
        }
        if (_navLeftRect.contains(event.position))
        {
            --_month;
            if (_month < 1) { _month = 12; --_year; }
            invalidate();
            return true;
        }
        if (_navRightRect.contains(event.position))
        {
            ++_month;
            if (_month > 12) { _month = 1; ++_year; }
            invalidate();
            return true;
        }
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape)
        {
            dismiss();
            return true;
        }
        return false;
    }

    // --- date helpers ---------------------------------------------------
    private static bool isLeap(int y)
    {
        return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    }

    private static int daysInMonth(int y, int m)
    {
        static immutable int[12] len = [31, 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31];
        if (m >= 1 && m <= 12)
            return len[m - 1] + (m == 2 && isLeap(y) ? 1 : 0);
        return 30;
    }

    // Zeller / Sakamoto: weekday of the first of the month (0=Sunday).
    private static int firstWeekday(int y, int m)
    {
        // Sakamoto's algorithm (0=Sunday).
        static immutable int[12] t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
        if (m < 3) y -= 1;
        return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + 1) % 7;
    }

    private static string monthName(int m)
    {
        static immutable string[12] names = ["January", "February", "March",
            "April", "May", "June", "July", "August", "September", "October",
            "November", "December"];
        return (m >= 1 && m <= 12) ? names[m - 1] : "";
    }
}

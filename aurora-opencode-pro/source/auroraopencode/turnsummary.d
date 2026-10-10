module auroraopencode.turnsummary;

import aurora;
import aurora.text.layout : TextLayoutOptions;
import auroraopencode.core : opencodeText, opencodeMuted, opencodeBorder,
    opencodeAccent, opencodePanel;
import std.utf : toUTF32;
import std.array : join;
import std.conv : to;
import std.string : split, strip;

/// A readable header derived from existing prose, never a generated claim.
public string turnOpeningSentence(string content)
{
    const text = toUTF32(content.split().join(" ").strip());
    enum limit = 240;
    foreach (i, ch; text)
    {
        if (i >= limit) return to!string(text[0 .. limit]).strip() ~ "…";
        if ((ch == '.' || ch == '!' || ch == '?') &&
            (i + 1 == text.length || text[i + 1] == ' '))
            return to!string(text[0 .. i + 1]);
    }
    return to!string(text);
}

/// Presentation only: the original transcript rows remain searchable children.
public final class TurnWorkSummary : VBox
{
    private bool _collapsed;
    private bool[Widget] _visibility;
    private string _title, _detail;
    private TextLayout _titleLayout, _detailLayout;
    private int _headerHeight;
    private bool _hover, _attention;
    void delegate(bool) onCollapseChanged;

    this() { super(6, Insets(0)); setId("oc-turn-work"); setFocusable(true); }
    bool collapsed() const { return _collapsed; }
    string title() const { return _title; }
    string detail() const { return _detail; }
    void setOpening(string value)
    {
        if (value.length == 0 || _title == value) return;
        _title = value;
        invalidate();
    }

    // Restore intrinsic visibility before retained rows participate in a new
    // projection. Collapsing must not become a message's own hidden state.
    void restoreRows()
    {
        foreach (row, visible; _visibility) row.setVisible(visible);
        _visibility = null;
    }

    void update(Widget[] rows, string title, string detail, bool attention)
    {
        restoreRows();
        reconcileChildren(rows);
        _title = title;
        _detail = detail;
        _attention = attention;
        applyVisibility();
        invalidate();
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
        _collapsed = value;
        applyVisibility();
        if (onCollapseChanged !is null) onCollapseChanged(value);
        invalidate();
    }

    protected override Size onMeasure(Size available)
    {
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() theme().uiFont;
        options.pixelSize = fontPixelSize(1);
        options.wrap = true;
        options.maxWidth = maxInt(1, available.width - 24);
        _titleLayout = fontSystem().textEngine.layout(
            toUTF32((_collapsed ? "▸ " : "▾ ") ~ _title), options);
        _detailLayout = fontSystem().textEngine.layout(toUTF32(_detail), options);
        _headerHeight = 20 + cast(int) _titleLayout.height +
            cast(int) _detailLayout.height + 4;
        int body;
        if (!_collapsed)
            foreach (row; children())
            {
                if (!row.visible()) continue;
                if (body > 0) body += spacing();
                body += row.measure(Size(maxInt(1, available.width - 18), available.height)).height;
            }
        const height = _headerHeight + body;
        layoutHints().preferredWidth = available.width;
        layoutHints().preferredHeight = height;
        return Size(available.width, height);
    }

    protected override void onLayout()
    {
        int y = _headerHeight;
        foreach (row; children())
        {
            if (!row.visible()) continue;
            const hint = row.layoutHints().preferredHeight;
            const height = hint >= 0 ? hint : row.bounds().height;
            row.setBounds(Rect(18, y, maxInt(1, bounds().width - 18), height));
            y += height + spacing();
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_titleLayout is null || _detailLayout is null) return;
        canvas.drawRoundedRect(Rect(1, 1, maxInt(0, bounds().width - 2),
            maxInt(0, _headerHeight - 6)), 6, opencodePanel,
            focused() ? opencodeAccent : opencodeBorder, 1);
        canvas.drawLayout(Point(12, 8), _titleLayout,
            opencodeText);
        canvas.drawLayout(Point(12, 12 + cast(int) _titleLayout.height),
            _detailLayout, opencodeMuted);
        if (!_collapsed && bounds().height > _headerHeight)
            canvas.drawLine(Point(7, _headerHeight),
                Point(7, bounds().height - 2), opencodeBorder, 1);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || event.position.y >= _headerHeight)
            return false;
        requestFocus();
        setCollapsed(!_collapsed);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key != Key.enter && event.key != Key.space)
            return super.onKeyDown(event);
        setCollapsed(!_collapsed);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        const hover = event.position.y < _headerHeight;
        if (_hover != hover) { _hover = hover; invalidate(); }
        setCursor(hover ? CursorKind.hand : CursorKind.arrow);
        return false;
    }

    protected override void onMouseLeave()
    { _hover = false; setCursor(CursorKind.arrow); invalidate(); }
}

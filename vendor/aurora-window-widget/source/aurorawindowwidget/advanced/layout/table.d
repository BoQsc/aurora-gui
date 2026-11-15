// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.layout.table;

import aurora.canvas : Canvas;
import aurora.event : Event, MouseButton;
import aurora.layout : HBox, VBox;
import aurora.types : CursorKind, Insets, Rect;
import aurora.widget : Widget;
import aurora.widgets.label : Label;

/// Column-aligned read-only text grid with single-row selection.
class Table : VBox
{
    private int[] _widths;
    private HBox _header;
    private VBox _rows;
    private TableRow[] _rowWidgets;
    private int _selected = -1;

    void delegate(int index) onSelectionChanged;

    this(string[] columns, int[] widths = null)
    {
        super(0, Insets(0));
        _header = add(new HBox(0));
        _header.layoutHints().preferredHeight = 30;
        _rows = add(new VBox(0, Insets(0)));
        _rows.layoutHints().flex = 1.0;
        layoutHints().minWidth = 160;
        layoutHints().minHeight = 80;
        _widths = widths is null ? new int[columns.length] : widths.dup;
        foreach (index, column; columns)
        {
            auto cell = _header.add(new Label(column));
            cell.layoutHints().preferredWidth = columnWidth(cast(int) index);
            cell.layoutHints().minWidth = 0;
        }
    }

    int selectedIndex() const @safe pure nothrow @nogc { return _selected; }
    int rowCount() const @safe pure nothrow @nogc
    {
        return cast(int) _rowWidgets.length;
    }

    private int columnWidth(int index) const @safe pure nothrow @nogc
    {
        return index >= 0 && index < cast(int) _widths.length &&
            _widths[index] > 0 ? _widths[index] : 100;
    }

    /// Append one row; cells are plain text matched to the column order.
    void addRow(string[] cells)
    {
        _rowWidgets ~= _rows.add(new TableRow(this,
            cast(int) _rowWidgets.length, cells, _widths));
        invalidate();
    }

    void select(int index, bool notify = true)
    {
        if (index < 0 || index >= cast(int) _rowWidgets.length) return;
        if (index == _selected) return;
        _selected = index;
        foreach (row; _rowWidgets) row.refresh();
        if (notify && onSelectionChanged !is null)
            onSelectionChanged(_selected);
    }
}

/// One clickable row inside a Table.
private final class TableRow : HBox
{
    private Table _table;
    private int _index;

    this(Table table, int index, string[] cells, const(int)[] widths)
    {
        super(0, Insets(0));
        _table = table;
        _index = index;
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = 28;
        foreach (cellIndex, cell; cells)
        {
            auto label = add(new Label(cell));
            label.layoutHints().preferredWidth =
                cellIndex < cast(int) widths.length && widths[cellIndex] > 0 ?
                widths[cellIndex] : 100;
            label.layoutHints().minWidth = 0;
        }
    }

    void refresh()
    {
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        if (_table.selectedIndex == _index)
            canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
                palette.selection);
        else if (hovered())
            canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
                palette.buttonHover);
        canvas.fillRect(Rect(0, bounds().height - 1, bounds().width, 1),
            palette.border);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        _table.select(_index);
        return true;
    }
}
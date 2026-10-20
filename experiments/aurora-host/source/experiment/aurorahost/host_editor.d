module experiment.aurorahost.host_editor;

import aurora;

import std.algorithm : max, min, sort;
import std.conv : to;
import std.math : ceil, floor;
import std.utf : toUTF32, toUTF8;

version (Windows)
{
    pragma(lib, "user32");
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GetActiveWindow, GetClipboardData, GlobalAlloc,
        GlobalFree, GlobalLock, GlobalUnlock, GMEM_MOVEABLE, HGLOBAL,
        IsClipboardFormatAvailable, OpenClipboard, SetClipboardData;
    import std.string : fromStringz;
    import std.utf : toUTF16;
}

private dchar[] processClipboard;

version (Windows)
private dchar[] readSystemClipboardText()
{
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
    if (!OpenClipboard(null)) return null;
    scope (exit) CloseClipboard();

    auto memory = GetClipboardData(CF_UNICODETEXT);
    if (memory is null) return null;
    auto text = cast(const(wchar)*) GlobalLock(memory);
    if (text is null) return null;
    scope (exit) GlobalUnlock(memory);
    try return toUTF32(fromStringz(text)).dup;
    catch (Exception) return null;
}

version (Windows)
private bool writeSystemClipboardText(const(dchar)[] value)
{
    auto owner = GetActiveWindow();
    if (owner is null || !OpenClipboard(owner)) return false;
    scope (exit) CloseClipboard();
    if (!EmptyClipboard()) return false;

    auto encoded = toUTF16(value);
    const bytes = (encoded.length + 1) * wchar.sizeof;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory is null) return false;
    auto text = cast(wchar*) GlobalLock(memory);
    if (text is null)
    {
        GlobalFree(memory);
        return false;
    }
    foreach (index, ch; encoded) text[index] = ch;
    text[encoded.length] = 0;
    GlobalUnlock(memory);

    if (SetClipboardData(CF_UNICODETEXT, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }
    return true;
}

private void writeClipboardText(const(dchar)[] value)
{
    processClipboard = value.dup;
    version (AuroraHeadless) {}
    else version (Windows) writeSystemClipboardText(value);
}

private dchar[] readClipboardText()
{
    version (AuroraHeadless) {}
    else version (Windows)
    {
        auto systemText = readSystemClipboardText();
        if (systemText.length > 0) return systemText;
    }
    return processClipboard.dup;
}

private struct EditState
{
    dchar[] buffer;
    size_t cursor;
    size_t anchor;
}

struct EditorTextStyle
{
    size_t start;
    size_t end;
    Color color;
}

/**
 * Host-owned multi-line editor.
 *
 * The stock Aurora text editor shapes and paints the complete document on
 * every frame. This implementation keeps the complete buffer and selection in
 * the host, but builds a display-row index once per edit and shapes only the
 * rows intersecting the viewport. Large documents therefore keep constant
 * paint cost, and the host owns every visible glyph, selection rectangle, and
 * caret pixel.
 *
 * Wrapped rows use the monospace cell advance for the row map and clipped
 * per-chunk layouts for exact glyph placement. Unwrapped documents scroll
 * horizontally without shaping invisible lines.
 */
class HostTextEditor : Widget
{
    private dchar[] _buffer;
    private size_t _cursor;
    private size_t _anchor;
    private bool _multiline;
    private bool _readOnly;
    private bool _wordWrap;
    private bool _showLineNumbers;
    private bool _highlightCurrentLine;
    private int _scrollLine;
    private int _scrollX;
    private int _preferredX = -1;
    private bool _dragSelecting;
    private bool _userScrolled;
    private double _caretClock;
    private bool _caretVisible = true;
    private bool _showBorder = true;
    private bool _customTextColor;
    private Color _textColor;
    private int _fontPixelSize;
    private EditorTextStyle[] _textStyles;
    private int _padding = 8;
    private int _rowHeight;
    private double _cellWidth;
    private int _charsPerRow;
    private Scrollbar _verticalScrollbar;
    private EditState[] _undo;
    private EditState[] _redo;

    private size_t[] _lineStarts;
    private size_t[] _lineRowStart;
    private size_t _totalRows;
    private bool _lineIndexDirty = true;
    private int _gutterWidth;

    void delegate() onChanged;
    void delegate() onCursorMoved;

    this(string text = "", bool multiline = true)
    {
        _multiline = multiline;
        setFocusable(true);
        setCursor(CursorKind.text);
        layoutHints().minWidth = 80;
        layoutHints().minHeight = multiline ? 80 : 38;
        layoutHints().preferredHeight = multiline ? 180 : 40;
        if (multiline) layoutHints().flex = 1.0;

        _verticalScrollbar = new Scrollbar();
        _verticalScrollbar.layoutHints().excludeFromLayout = true;
        _verticalScrollbar.setLineStep(3);
        _verticalScrollbar.onValueChanged = delegate(int value)
        {
            if (_scrollLine == value) return;
            _userScrolled = true;
            _scrollLine = value;
            invalidate();
        };
        add(_verticalScrollbar);

        setText(text, false);
    }

    bool multiline() const @safe pure nothrow @nogc { return _multiline; }
    bool readOnly() const @safe pure nothrow @nogc { return _readOnly; }
    bool wordWrap() const @safe pure nothrow @nogc { return _wordWrap; }
    bool lineNumbers() const @safe pure nothrow @nogc { return _showLineNumbers; }
    bool currentLineHighlight() const @safe pure nothrow @nogc
    {
        return _highlightCurrentLine;
    }
    int fontPixelSizeOverride() const @safe pure nothrow @nogc
    {
        return _fontPixelSize;
    }
    size_t styleCount() const @safe pure nothrow @nogc
    {
        return _textStyles.length;
    }
    size_t cursorIndex() const @safe pure nothrow @nogc { return _cursor; }
    size_t selectionAnchor() const @safe pure nothrow @nogc { return _anchor; }
    bool hasSelection() const @safe pure nothrow @nogc { return _cursor != _anchor; }
    const(dchar)[] textView() const @safe pure nothrow @nogc { return _buffer; }
    Scrollbar verticalScrollbar() @safe pure nothrow @nogc
    {
        return _verticalScrollbar;
    }

    string textUtf8() const
    {
        return toUTF8(_buffer.idup);
    }

    dstring textUtf32() const
    {
        return _buffer.idup;
    }

    void setText(string value, bool notify = true)
    {
        setText(toUTF32(value), notify);
    }

    void setText(dstring value, bool notify = true)
    {
        dchar[] normalized;
        normalized.reserve(value.length);
        foreach (ch; value)
        {
            if (ch == '\r') continue;
            if (ch == '\t')
            {
                normalized ~= "    "d;
                continue;
            }
            if (!_multiline && ch == '\n')
            {
                normalized ~= ' ';
                continue;
            }
            normalized ~= ch;
        }
        _buffer = normalized;
        _cursor = _buffer.length;
        _anchor = _cursor;
        _undo.length = 0;
        _redo.length = 0;
        _scrollLine = 0;
        _scrollX = 0;
        _preferredX = -1;
        _lineIndexDirty = true;
        _textStyles.length = 0;
        rebuildLineIndex();
        resetCaret();
        if (notify) notifyChanged();
        else invalidate();
    }

    void setReadOnly(bool value)
    {
        _readOnly = value;
        invalidate();
    }

    void setWordWrap(bool value)
    {
        value = value && _multiline;
        if (_wordWrap == value) return;
        _wordWrap = value;
        _scrollX = 0;
        rebuildRowMap();
        ensureCursorVisible();
        invalidate();
    }

    void setLineNumbers(bool value)
    {
        if (_showLineNumbers == value) return;
        _showLineNumbers = value;
        _gutterWidth = 0;
        rebuildLineIndex();
        rebuildGutter();
        rebuildRowMap();
        ensureCursorVisible();
        invalidate();
    }

    void setCurrentLineHighlight(bool value)
    {
        if (_highlightCurrentLine == value) return;
        _highlightCurrentLine = value;
        invalidate();
    }

    void setFontPixelSize(int value)
    {
        value = value > 0 ? value : 0;
        if (_fontPixelSize == value) return;
        _fontPixelSize = value;
        _rowHeight = 0;
        _cellWidth = 0;
        rebuildGutter();
        rebuildRowMap();
        ensureCursorVisible();
        invalidate();
    }

    void setTextStyles(EditorTextStyle[] styles)
    {
        _textStyles = styles.dup;
        _textStyles.sort!((a, b) => a.start < b.start);
        invalidate();
    }

    void setShowBorder(bool value)
    {
        _showBorder = value;
        invalidate();
    }

    void setTextColor(Color value)
    {
        _customTextColor = true;
        _textColor = value;
        invalidate();
    }

    void setPadding(int value)
    {
        value = maxInt(0, value);
        if (_padding == value) return;
        _padding = value;
        rebuildRowMap();
        ensureCursorVisible();
        invalidate();
    }

    int lineCount()
    {
        rebuildLineIndex();
        return cast(int) _lineStarts.length;
    }

    int cursorLine()
    {
        return cast(int) lineForLogical(_cursor);
    }

    int cursorColumn()
    {
        rebuildLineIndex();
        const line = lineForLogical(_cursor);
        const start = lineStart(line);
        auto boundaries = graphemeBoundaries(_buffer[start .. _cursor]);
        return boundaries.length > 0 ? cast(int) boundaries.length - 1 : 0;
    }

    void selectAll()
    {
        _anchor = 0;
        _cursor = _buffer.length;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    void selectNone()
    {
        _anchor = _cursor;
        resetCaret();
        invalidate();
    }

    void setCursorIndex(size_t index, bool extendSelection = false)
    {
        _cursor = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        if (!extendSelection) _anchor = _cursor;
        _preferredX = -1;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    void setSelection(size_t anchor, size_t cursor)
    {
        rebuildLineIndex();
        _anchor = floorGraphemeBoundary(_buffer, min(anchor, _buffer.length));
        _cursor = floorGraphemeBoundary(_buffer, min(cursor, _buffer.length));
        _preferredX = -1;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    void insertTextAtCursor(const(dchar)[] value)
    {
        if (!_readOnly) insertText(value);
    }

    void cutToClipboard()
    {
        if (_readOnly || !hasSelection()) return;
        writeClipboardText(_buffer[selectionStart() .. selectionEnd()]);
        deleteSelection();
    }

    void copyToClipboard()
    {
        if (hasSelection())
            writeClipboardText(_buffer[selectionStart() .. selectionEnd()]);
    }

    void pasteFromClipboard()
    {
        if (_readOnly) return;
        auto text = readClipboardText();
        if (text.length > 0) pasteText(text);
    }

    void deleteSelectionCommand()
    {
        if (_readOnly || !hasSelection()) return;
        deleteSelection();
    }

    void undo()
    {
        if (_readOnly || _undo.length == 0) return;
        _redo ~= EditState(_buffer.dup, _cursor, _anchor);
        auto state = _undo[$ - 1];
        _undo.length = _undo.length - 1;
        restoreState(state);
        notifyChanged();
    }

    void redo()
    {
        if (_readOnly || _redo.length == 0) return;
        _undo ~= EditState(_buffer.dup, _cursor, _anchor);
        auto state = _redo[$ - 1];
        _redo.length = _redo.length - 1;
        restoreState(state);
        notifyChanged();
    }

    private void restoreState(EditState state)
    {
        _buffer = state.buffer;
        _cursor = floorGraphemeBoundary(_buffer, min(state.cursor, _buffer.length));
        _anchor = floorGraphemeBoundary(_buffer, min(state.anchor, _buffer.length));
        _preferredX = -1;
        _lineIndexDirty = true;
        _textStyles.length = 0;
        rebuildLineIndex();
        ensureCursorVisible();
    }

    private size_t selectionStart() const @safe pure nothrow @nogc
    {
        return min(_cursor, _anchor);
    }

    private size_t selectionEnd() const @safe pure nothrow @nogc
    {
        return max(_cursor, _anchor);
    }

    private void checkpoint()
    {
        _undo ~= EditState(_buffer.dup, _cursor, _anchor);
        if (_undo.length > 100) _undo = _undo[$ - 100 .. $];
        _redo.length = 0;
    }

    private void replaceRange(size_t start, size_t end,
        const(dchar)[] replacement)
    {
        if (_readOnly) return;
        if (start > end)
        {
            const swap = start;
            start = end;
            end = swap;
        }
        start = min(start, _buffer.length);
        end = min(end, _buffer.length);
        if (start == end)
            start = end = floorGraphemeBoundary(_buffer, start);
        else
        {
            start = floorGraphemeBoundary(_buffer, start);
            end = ceilGraphemeBoundary(_buffer, end);
        }
        checkpoint();
        _buffer = _buffer[0 .. start] ~ replacement ~ _buffer[end .. $];
        _cursor = start + replacement.length;
        _anchor = _cursor;
        _preferredX = -1;
        _lineIndexDirty = true;
        _textStyles.length = 0;
        rebuildLineIndex();
        ensureCursorVisible();
        resetCaret();
        notifyChanged();
    }

    private void insertText(const(dchar)[] value)
    {
        replaceRange(selectionStart(), selectionEnd(), value);
    }

    private void pasteText(const(dchar)[] value)
    {
        dchar[] filtered;
        foreach (ch; value)
        {
            if (ch == '\r') continue;
            if (ch == '\t')
            {
                filtered ~= "    "d;
                continue;
            }
            if (ch == '\n')
            {
                filtered ~= _multiline ? ch : ' ';
                continue;
            }
            if (ch < 32 || ch == 127) continue;
            filtered ~= ch;
        }
        if (filtered.length > 0) insertText(filtered);
    }

    private void deleteSelection()
    {
        if (hasSelection()) replaceRange(selectionStart(), selectionEnd(), null);
    }

    private void rebuildLineIndex()
    {
        if (!_lineIndexDirty) return;
        _lineStarts.length = 0;
        _lineStarts.reserve(_buffer.length / 48 + 2);
        _lineStarts ~= 0;
        foreach (index, ch; _buffer)
            if (ch == '\n') _lineStarts ~= index + 1;
        _lineIndexDirty = false;
        rebuildGutter();
        rebuildRowMap();
    }

    private size_t lineStart(size_t line) const @safe pure nothrow @nogc
    {
        return line < _lineStarts.length ? _lineStarts[line] : _buffer.length;
    }

    private size_t lineEnd(size_t line) const @safe pure nothrow @nogc
    {
        return line + 1 < _lineStarts.length ?
            _lineStarts[line + 1] - 1 : _buffer.length;
    }

    private size_t lineForLogical(size_t index) const @safe pure nothrow @nogc
    {
        if (_lineStarts.length == 0) return 0;
        size_t low = 0;
        size_t high = _lineStarts.length;
        index = min(index, _buffer.length);
        while (low + 1 < high)
        {
            const middle = low + (high - low) / 2;
            if (_lineStarts[middle] <= index) low = middle;
            else high = middle;
        }
        return low;
    }

    private int contentWidth() const @safe pure nothrow @nogc
    {
        return maxInt(1, bounds().width - _gutterWidth - _padding * 2 - 11);
    }

    private int contentHeight() const @safe pure nothrow @nogc
    {
        return maxInt(1, bounds().height - _padding * 2);
    }

    private TextLayoutOptions layoutOptions()
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.monospace;
        options.overrideFace = cast() palette.monospaceFont;
        options.pixelSize = _fontPixelSize > 0 ? _fontPixelSize :
            fontPixelSize(palette.fontScale);
        options.wrap = false;
        options.maxWidth = 0;
        return options;
    }

    private TextLayout shapeText(const(dchar)[] text)
    {
        return fontSystem().textEngine.layoutCached(text, layoutOptions());
    }

    private TextLayout chunkLayout(size_t start, size_t end)
    {
        if (end <= start)
        {
            dchar[] empty;
            return shapeText(empty);
        }
        return shapeText(_buffer[start .. end]);
    }

    private int measuredRowHeight()
    {
        if (_rowHeight > 0) return _rowHeight;
        auto layout = shapeText("Mg"d);
        double height = layout.lines.length > 0 ? layout.lines[0].height : 0;
        _rowHeight = maxInt(1, cast(int) ceil(height));
        return _rowHeight;
    }

    private double measuredCellWidth()
    {
        if (_cellWidth > 0) return _cellWidth;
        auto layout = shapeText("0000000000"d);
        _cellWidth = layout.measuredSize().width / 10.0;
        if (_cellWidth <= 0) _cellWidth = 8.0;
        return _cellWidth;
    }

    private void rebuildGutter()
    {
        _gutterWidth = 0;
        if (!_showLineNumbers) return;
        size_t digits = 1;
        for (size_t value = _lineStarts.length; value >= 10; value /= 10)
            ++digits;
        _gutterWidth = maxInt(28,
            cast(int) ceil(measuredCellWidth() * cast(double) digits) + 16);
    }

    private void rebuildRowMap()
    {
        if (_lineStarts.length == 0)
        {
            _lineRowStart = [0, 0];
            _totalRows = 1;
            return;
        }

        if (_wordWrap)
        {
            const capacity = maxInt(1,
                cast(int) floor(contentWidth() / measuredCellWidth()));
            if (_charsPerRow != capacity)
            {
                _charsPerRow = capacity;
                _scrollX = 0;
            }
        }
        else
            _charsPerRow = 0;

        _lineRowStart.length = _lineStarts.length + 1;
        size_t total;
        foreach (line; 0 .. _lineStarts.length)
        {
            _lineRowStart[line] = total;
            const length = lineEnd(line) - lineStart(line);
            const rows = _wordWrap ?
                maxInt(1, cast(int) ((length + _charsPerRow - 1) /
                    _charsPerRow)) : 1;
            total += cast(size_t) rows;
        }
        _lineRowStart[$ - 1] = total;
        _totalRows = total;
        _scrollLine = clampInt(_scrollLine, 0, maxScrollLine());
    }

    private int visibleRows()
    {
        return maxInt(1, contentHeight() / measuredRowHeight());
    }

    private int maxScrollLine()
    {
        return maxInt(0, cast(int) _totalRows - visibleRows());
    }

    private size_t rowLine(size_t row, out size_t subline) const
        @safe pure nothrow @nogc
    {
        subline = 0;
        if (_lineRowStart.length < 2) return 0;
        size_t low = 0;
        size_t high = _lineRowStart.length - 1;
        while (low + 1 < high)
        {
            const middle = low + (high - low) / 2;
            if (_lineRowStart[middle] <= row) low = middle;
            else high = middle;
        }
        subline = row - _lineRowStart[low];
        return low;
    }

    private void rowChunk(size_t row, out size_t start, out size_t end)
    {
        size_t subline;
        const line = rowLine(row, subline);
        const begin = lineStart(line);
        const finish = lineEnd(line);
        if (!_wordWrap)
        {
            start = begin;
            end = finish;
            return;
        }
        const offset = subline * cast(size_t) maxInt(1, _charsPerRow);
        start = min(finish, begin + offset);
        end = min(finish, start + cast(size_t) maxInt(1, _charsPerRow));
    }

    private size_t rowForCursor()
    {
        const line = lineForLogical(_cursor);
        const offset = _cursor - lineStart(line);
        const subline = _wordWrap ?
            offset / cast(size_t) maxInt(1, _charsPerRow) : 0;
        return _lineRowStart.length > line ?
            _lineRowStart[line] + subline : 0;
    }

    private int lineHeightFor(TextLayout layout)
    {
        if (layout is null || layout.lines.length == 0) return measuredRowHeight();
        return maxInt(1, cast(int) ceil(layout.lines[0].height));
    }

    private int textOriginY(size_t row, TextLayout layout)
    {
        const rowTop = _padding + cast(int) (row - _scrollLine) *
            measuredRowHeight();
        return rowTop + maxInt(0,
            (measuredRowHeight() - lineHeightFor(layout)) / 2);
    }

    private int textOriginX()
    {
        return _gutterWidth + _padding - (_wordWrap ? 0 : _scrollX);
    }

    private void ensureCursorVisible()
    {
        rebuildLineIndex();
        const row = rowForCursor();
        const rows = visibleRows();
        if (cast(int) row < _scrollLine)
            _scrollLine = cast(int) row;
        else if (cast(int) row >= _scrollLine + rows)
            _scrollLine = cast(int) row - rows + 1;
        _scrollLine = clampInt(_scrollLine, 0, maxScrollLine());

        if (!_wordWrap)
        {
            size_t start;
            size_t end;
            rowChunk(row, start, end);
            auto layout = chunkLayout(start, end);
            const local = _cursor - start;
            int caretX;
            if (layout.lines.length > 0)
                caretX = cast(int) floor(
                    layout.caretPosition(local, CaretAffinity.downstream).x);
            const viewport = contentWidth();
            if (caretX < _scrollX)
                _scrollX = maxInt(0, caretX);
            else if (caretX > _scrollX + viewport - 2)
                _scrollX = maxInt(0, caretX - viewport + 2);
            const maxHorizontal = maxInt(0,
                cast(int) ceil(cast(double) layout.measuredSize().width) -
                viewport);
            _scrollX = clampInt(_scrollX, 0, maxHorizontal);
        }
        else
            _scrollX = 0;
    }

    private void synchronizeScrollbar()
    {
        if (_verticalScrollbar is null) return;
        const rows = visibleRows();
        const maximum = maxScrollLine();
        _scrollLine = clampInt(_scrollLine, 0, maximum);
        _verticalScrollbar.setBounds(Rect(maxInt(0, bounds().width - 11), 4,
            9, maxInt(1, bounds().height - 8)));
        _verticalScrollbar.setPageStep(maxInt(1, rows - 1));
        _verticalScrollbar.setRange(0, maximum, rows);
        _verticalScrollbar.setValue(_scrollLine, false);
        _verticalScrollbar.setVisible(maximum > 0);
    }

    private size_t firstStyleAt(size_t start)
    {
        size_t low;
        size_t high = _textStyles.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (_textStyles[middle].end <= start) low = middle + 1;
            else high = middle;
        }
        return low;
    }

    private void drawSegment(ref Canvas canvas, TextLayout layout, size_t start,
        size_t end, size_t segmentStart, size_t segmentEnd, int x, int y,
        Color color)
    {
        if (segmentEnd <= segmentStart) return;
        const localStart = segmentStart - start;
        const offset = layout.lines.length > 0 ?
            cast(int) floor(layout.caretPosition(localStart,
                CaretAffinity.downstream).x + 0.5) : 0;
        auto segment = chunkLayout(segmentStart, segmentEnd);
        canvas.drawLayout(Point(x + offset, y), segment, color);
    }

    private void drawRow(ref Canvas canvas, size_t start, size_t end,
        TextLayout layout, int x, int y, Color foreground)
    {
        if (_textStyles.length == 0)
        {
            canvas.drawLayout(Point(x, y), layout, foreground);
            return;
        }

        size_t cursor = start;
        for (size_t index = firstStyleAt(start);
            index < _textStyles.length && _textStyles[index].start < end;
            ++index)
        {
            const style = _textStyles[index];
            const styleStart = max(style.start, start);
            const styleEnd = min(style.end, end);
            if (styleEnd <= styleStart) continue;
            drawSegment(canvas, layout, start, end, cursor, styleStart, x, y,
                foreground);
            drawSegment(canvas, layout, start, end, styleStart, styleEnd, x, y,
                style.color);
            cursor = max(cursor, styleEnd);
        }
        drawSegment(canvas, layout, start, end, cursor, end, x, y, foreground);
    }

    private void notifyChanged()
    {
        _userScrolled = false;
        if (onChanged !is null) onChanged();
        if (onCursorMoved !is null) onCursorMoved();
        invalidate();
    }

    private void notifyCursor()
    {
        _userScrolled = false;
        if (onCursorMoved !is null) onCursorMoved();
        invalidate();
    }

    private void resetCaret()
    {
        _caretClock = 0.0;
        _caretVisible = true;
    }

    private CaretPosition caretAtPoint(Point point)
    {
        synchronizeScrollbar();
        const rowHeight = measuredRowHeight();
        int row = _scrollLine + maxInt(0, (point.y - _padding) / rowHeight);
        if (row >= cast(int) _totalRows) row = cast(int) _totalRows - 1;
        if (row < 0) row = 0;

        size_t start;
        size_t end;
        rowChunk(cast(size_t) row, start, end);
        auto layout = chunkLayout(start, end);
        if (layout.lines.length == 0 ||
            point.y < textOriginY(cast(size_t) row, layout) - rowHeight)
            return CaretPosition.init;
        const localX = point.x - textOriginX();
        const localY = point.y - textOriginY(cast(size_t) row, layout);
        auto hit = layout.hitTestCaret(localX, localY);
        hit.logicalIndex = min(hit.logicalIndex, end - start) + start;
        return hit;
    }

    private bool isWord(dchar ch) const @safe pure nothrow @nogc
    {
        return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
               (ch >= '0' && ch <= '9') || ch == '_' || ch >= 128;
    }

    private void selectWordAt(size_t index)
    {
        if (_buffer.length == 0)
        {
            _cursor = _anchor = 0;
            return;
        }
        index = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        if (index == _buffer.length)
            index = previousGraphemeBoundary(_buffer, index);
        if (!isWord(_buffer[index]))
        {
            _anchor = index;
            _cursor = nextGraphemeBoundary(_buffer, index);
            return;
        }
        size_t start = index;
        size_t end = index;
        while (start > 0)
        {
            const previous = previousGraphemeBoundary(_buffer, start);
            if (!isWord(_buffer[previous])) break;
            start = previous;
        }
        while (end < _buffer.length && isWord(_buffer[end]))
            end = nextGraphemeBoundary(_buffer, end);
        _anchor = start;
        _cursor = end;
    }

    private void selectLineAt(size_t index)
    {
        const line = lineForLogical(index);
        _anchor = lineStart(line);
        _cursor = lineEnd(line);
        if (_cursor < _buffer.length) ++_cursor;
    }

    private size_t previousWord(size_t index) const
    {
        index = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        if (index == 0) return 0;
        index = previousGraphemeBoundary(_buffer, index);
        while (index > 0 && !isWord(_buffer[index]))
            index = previousGraphemeBoundary(_buffer, index);
        while (index > 0)
        {
            const previous = previousGraphemeBoundary(_buffer, index);
            if (!isWord(_buffer[previous])) break;
            index = previous;
        }
        return index;
    }

    private size_t nextWord(size_t index) const
    {
        index = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        while (index < _buffer.length && isWord(_buffer[index]))
            index = nextGraphemeBoundary(_buffer, index);
        while (index < _buffer.length && !isWord(_buffer[index]))
            index = nextGraphemeBoundary(_buffer, index);
        return index;
    }

    private void moveCursor(size_t next, bool extendSelection,
        bool preservePreferredX = false)
    {
        _cursor = floorGraphemeBoundary(_buffer, min(next, _buffer.length));
        if (!extendSelection) _anchor = _cursor;
        if (!preservePreferredX) _preferredX = -1;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    private void moveVertical(int delta, bool extendSelection)
    {
        const row = rowForCursor();
        if (_preferredX < 0)
        {
            size_t start;
            size_t end;
            rowChunk(row, start, end);
            auto layout = chunkLayout(start, end);
            _preferredX = layout.lines.length > 0 ?
                cast(int) floor(layout.caretPosition(_cursor - start,
                    CaretAffinity.downstream).x) : 0;
        }
        int target = cast(int) row + delta;
        target = clampInt(target, 0, cast(int) _totalRows - 1);
        size_t start;
        size_t end;
        rowChunk(cast(size_t) target, start, end);
        auto layout = chunkLayout(start, end);
        size_t next = start;
        if (layout.lines.length > 0)
        {
            auto hit = layout.hitTestCaret(_preferredX,
                lineHeightFor(layout) * 0.5);
            next = start + min(hit.logicalIndex, end - start);
        }
        moveCursor(next, extendSelection, true);
    }

    protected override void onBoundsChanged()
    {
        _rowHeight = 0;
        _cellWidth = 0;
        rebuildGutter();
        rebuildRowMap();
        ensureCursorVisible();
    }

    protected override void onFocusChanged(bool value)
    {
        resetCaret();
        if (!value)
        {
            _dragSelecting = false;
            releaseMouse();
        }
    }

    protected override void onTick(double deltaSeconds)
    {
        if (!focused()) return;
        if (hasSelection()) return;
        _caretClock += deltaSeconds;
        if (_caretClock >= 0.5)
        {
            _caretClock -= 0.5;
            _caretVisible = !_caretVisible;
            invalidate();
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_showBorder)
            canvas.drawRoundedRect(full, palette.cornerRadius,
                palette.fieldBackground, focused() ? palette.accent :
                palette.border, focused() ? 2 : 1);
        else
            canvas.fillRect(full, palette.fieldBackground);

        rebuildLineIndex();
        synchronizeScrollbar();
        const inset = _showBorder ? 2 : 0;
        auto content = canvas.clipped(full.inset(inset));
        if (!_userScrolled) ensureCursorVisible();
        synchronizeScrollbar();

        const foreground = _customTextColor ? _textColor :
            (_readOnly ? palette.textMuted : palette.text);
        const first = cast(size_t) maxInt(0, _scrollLine);
        const last = min(_totalRows, first + cast(size_t) visibleRows() + 1);
        const selectionStart = this.selectionStart();
        const selectionEnd = this.selectionEnd();
        const hasSelection = selectionStart != selectionEnd;
        const caretRow = rowForCursor();

        if (_gutterWidth > 0)
            content.fillRect(Rect(0, 0, _gutterWidth, bounds().height),
                palette.buttonBackground);
        if (_highlightCurrentLine && caretRow >= first && caretRow < last)
        {
            const bandY = _padding + cast(int) (caretRow -
                cast(size_t) _scrollLine) * measuredRowHeight();
            content.fillRect(Rect(0, bandY, bounds().width, measuredRowHeight()),
                Color.rgba(palette.accent.r, palette.accent.g,
                    palette.accent.b, 20));
        }
        if (_gutterWidth > 0)
            content.fillRect(Rect(_gutterWidth - 1, 0, 1, bounds().height),
                palette.border);

        foreach (row; first .. last)
        {
            size_t start;
            size_t end;
            rowChunk(row, start, end);
            auto layout = chunkLayout(start, end);
            const x = textOriginX();
            const y = textOriginY(row, layout);
            size_t line;
            size_t subline;
            line = rowLine(row, subline);

            if (hasSelection && selectionEnd > start && selectionStart < end)
            {
                const localStart = max(selectionStart, start) - start;
                const localEnd = min(selectionEnd, end) - start;
                foreach (rect; layout.selectionRects(localStart, localEnd))
                    content.fillRect(rect.translated(x, y), palette.selection);
            }
            if (layout.lines.length > 0)
                drawRow(content, start, end, layout, x, y, foreground);
            if (_gutterWidth > 0 && subline == 0)
            {
                auto number = shapeText(toUTF32(to!string(line + 1)));
                const width = cast(int) ceil(
                    cast(double) number.measuredSize().width);
                content.drawLayout(
                    Point(_gutterWidth - 8 - width,
                        textOriginY(row, number)),
                    number, line == lineForLogical(_cursor) ?
                        palette.accent : palette.textMuted);
            }
        }

        if (_caretVisible && focused() && !hasSelection)
        {
            const row = caretRow;
            size_t start;
            size_t end;
            rowChunk(row, start, end);
            auto layout = chunkLayout(start, end);
            if (layout.lines.length > 0)
            {
                const local = _cursor - start;
                const caret = layout.caretPosition(local,
                    CaretAffinity.downstream);
                const x = textOriginX() + cast(int) floor(caret.x + 0.5);
                const y = textOriginY(row, layout) +
                    cast(int) floor(caret.y + 1.0);
                const height = maxInt(2, cast(int) ceil(caret.height) - 2);
                content.fillRect(Rect(x, y, 1, height), foreground);
            }
            else
            {
                const x = textOriginX();
                const y = textOriginY(row, layout);
                content.fillRect(Rect(x, y + 1, 1,
                    maxInt(2, measuredRowHeight() - 4)), foreground);
            }
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        requestFocus();
        const hit = caretAtPoint(event.position);
        const index = hit.logicalIndex;
        if (event.clickCount >= 3)
            selectLineAt(index);
        else if (event.clickCount == 2)
            selectWordAt(index);
        else
        {
            _cursor = index;
            if (!event.shift()) _anchor = _cursor;
        }
        _preferredX = -1;
        _dragSelecting = true;
        captureMouse();
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_dragSelecting) return true;
        const hit = caretAtPoint(event.position);
        _cursor = hit.logicalIndex;
        _preferredX = -1;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_dragSelecting) return false;
        _dragSelecting = false;
        releaseMouse();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (!_multiline && event.wheelX == 0 && !event.shift()) return false;
        if (!_wordWrap && (event.shift() || event.wheelX != 0))
        {
            const delta = event.wheelX != 0 ? event.wheelX : event.wheelY;
            _scrollX = maxInt(0, _scrollX - delta * measuredRowHeight());
            invalidate();
            return true;
        }
        const delta = event.wheelY != 0 ? event.wheelY : event.wheelX;
        _scrollLine = clampInt(_scrollLine - delta * 3, 0, maxScrollLine());
        _userScrolled = true;
        synchronizeScrollbar();
        invalidate();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (shortcut)
        {
            switch (event.key)
            {
                case Key.a:
                    selectAll();
                    return true;
                case Key.c:
                    copyToClipboard();
                    return true;
                case Key.x:
                    cutToClipboard();
                    return true;
                case Key.v:
                    pasteFromClipboard();
                    return true;
                case Key.z:
                    if (event.shift()) redo(); else undo();
                    return true;
                case Key.y:
                    redo();
                    return true;
                case Key.home:
                    moveCursor(0, event.shift());
                    return true;
                case Key.end:
                    moveCursor(_buffer.length, event.shift());
                    return true;
                default:
                    break;
            }
        }

        switch (event.key)
        {
            case Key.left:
                if (!event.shift() && hasSelection())
                    moveCursor(selectionStart(), false);
                else if (shortcut)
                    moveCursor(previousWord(_cursor), event.shift());
                else
                    moveCursor(previousGraphemeBoundary(_buffer, _cursor),
                        event.shift());
                return true;
            case Key.right:
                if (!event.shift() && hasSelection())
                    moveCursor(selectionEnd(), false);
                else if (shortcut)
                    moveCursor(nextWord(_cursor), event.shift());
                else
                    moveCursor(nextGraphemeBoundary(_buffer, _cursor),
                        event.shift());
                return true;
            case Key.up:
                if (_multiline) moveVertical(-1, event.shift());
                return _multiline;
            case Key.down:
                if (_multiline) moveVertical(1, event.shift());
                return _multiline;
            case Key.pageUp:
                if (_multiline) moveVertical(-visibleRows(), event.shift());
                return _multiline;
            case Key.pageDown:
                if (_multiline) moveVertical(visibleRows(), event.shift());
                return _multiline;
            case Key.home:
                moveCursor(lineStart(lineForLogical(_cursor)), event.shift());
                return true;
            case Key.end:
                moveCursor(lineEnd(lineForLogical(_cursor)), event.shift());
                return true;
            case Key.backspace:
                if (_readOnly) return true;
                if (hasSelection()) deleteSelection();
                else if (_cursor > 0)
                    replaceRange(shortcut ? previousWord(_cursor) :
                        previousGraphemeBoundary(_buffer, _cursor), _cursor, null);
                return true;
            case Key.deleteKey:
                if (_readOnly) return true;
                if (hasSelection()) deleteSelection();
                else if (_cursor < _buffer.length)
                    replaceRange(_cursor, shortcut ? nextWord(_cursor) :
                        nextGraphemeBoundary(_buffer, _cursor), null);
                return true;
            case Key.enter:
                if (_multiline && !_readOnly) insertText("\n"d);
                return _multiline;
            case Key.tab:
                if (!_readOnly) insertText("    "d);
                return true;
            case Key.escape:
                if (hasSelection())
                {
                    _anchor = _cursor;
                    invalidate();
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    override bool onTextInput(ref Event event)
    {
        if (_readOnly || event.text.length == 0) return false;
        dchar[] filtered;
        foreach (ch; event.text)
        {
            if (ch < 32 || ch == 127) continue;
            filtered ~= ch;
        }
        if (filtered.length == 0) return false;
        insertText(filtered);
        return true;
    }
}

class HostTextArea : HostTextEditor
{
    this(string text = "")
    {
        super(text, true);
    }
}

unittest
{
    auto editor = new HostTextArea("one\ntwo\nthree");
    assert(editor.lineCount() == 3);
    assert(editor.cursorIndex() == editor.textView.length);
    editor.setSelection(0, 0);
    assert(editor.cursorLine() == 0);
    assert(editor.cursorColumn() == 0);
    editor.setSelection(editor.textView.length, editor.textView.length);
    assert(editor.cursorLine() == 2);
}
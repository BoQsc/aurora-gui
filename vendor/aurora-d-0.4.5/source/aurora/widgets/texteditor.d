module aurora.widgets.texteditor;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
import aurora.font : FontFace, FontRole, fontPixelSize;
import aurora.text.atlas : FontSystem;
import aurora.text.layout : CaretAffinity, CaretPosition, TextLayout, TextLayoutOptions;
import aurora.text.titlepaint : TitlePaintStyle, paintTitleBackdrop,
    paintTitleForeground, titlePaintMargin;
import aurora.text.unicode.bidi : ParagraphDirection;
import aurora.text.unicode.grapheme : ceilGraphemeBoundary,
    floorGraphemeBoundary, graphemeBoundaries, nextGraphemeBoundary,
    previousGraphemeBoundary;
import aurora.types : CursorKind, HorizontalAlign, Point, Rect, Size,
    clampInt, maxInt;
import aurora.widget : Widget;
import aurora.widgets.scrollbar : Scrollbar;
import std.algorithm.comparison : max, min;
import std.math : ceil, floor;
import std.utf : toUTF32, toUTF8;

version (Windows)
{
    pragma(lib, "user32");
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GetClipboardData, GlobalAlloc, GlobalFree,
        GlobalLock, GlobalUnlock, GMEM_MOVEABLE, HGLOBAL,
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
    if (!OpenClipboard(null)) return false;
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
    version (Windows)
        writeSystemClipboardText(value);
}

private dchar[] readClipboardText()
{
    version (Windows)
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
    CaretAffinity affinity = CaretAffinity.downstream;
}

/**
 * Multi-line or single-line UTF-32 editor.
 *
 * Document indices remain logical UTF-32 offsets. Display, mouse hit-testing,
 * selection, horizontal movement, and caret placement use TextLayout, so bidi
 * text, ligatures, fallback fonts, and combining sequences remain coherent.
 */
class TextEditor : Widget
{
    private dchar[] _buffer;
    private size_t _cursor;
    private size_t _anchor;
    private bool _multiline;
    private bool _readOnly;
    private bool _wordWrap;
    private ParagraphDirection _paragraphDirection = ParagraphDirection.automatic;
    private bool _dragSelecting;
    private int _scrollLine;
    private int _scrollX;
    private Scrollbar _verticalScrollbar;
    private int _preferredX = -1;
    private CaretAffinity _caretAffinity = CaretAffinity.downstream;
    private double _caretClock = 0.0;
    private bool _caretVisible = true;
    private bool _caretEnabled = true;
    private dstring _placeholder;
    private EditState[] _undo;
    private EditState[] _redo;
    private bool _showBorder = true;
    private bool _transparentBackground;
    private bool _focusDecoration = true;
    // Direct composition titles size their widget to the complete glyph layout;
    // they must never horizontally/vertically scroll like a document field.
    private bool _canvasTextMode;
    private FontRole _fontRole = FontRole.monospace;
    private FontFace _fontFace;
    private int _pixelSizeOverride;
    private bool _customTextColor;
    private Color _textColor;
    // Optional title-style painting. Input, caret and selection still use this
    // same TextLayout; these effects do not create a second text surface.
    private int _titleStrokeWidth;
    private Color _titleStrokeColor;
    private int _titleShadowOffsetX;
    private int _titleShadowOffsetY;
    private int _titleShadowBlur;
    private Color _titleShadowColor;
    private bool _titleUnderline;
    private bool _titleBox;
    private Color _titleBoxColor;
    private double _titleLayerOpacity = 1.0;
    private HorizontalAlign _titleHorizontal = HorizontalAlign.left;
    private int _padding = 8;

    private TextLayout _textLayout;
    private bool _layoutDirty = true;
    private int _layoutPixelSize;
    private int _layoutMaxWidth;
    private bool _layoutWordWrap;
    private ParagraphDirection _layoutParagraphDirection = ParagraphDirection.automatic;
    private HorizontalAlign _layoutTitleHorizontal = HorizontalAlign.left;
    private ulong _layoutFaceIdentity;
    private ulong _layoutFontRevision;

    void delegate() onChanged;
    void delegate() onCursorMoved;
    void delegate() onSubmitted;

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
            _scrollLine = value;
            invalidate();
        };
        add(_verticalScrollbar);
        setText(text, false);
    }

    bool multiline() const @safe pure nothrow @nogc { return _multiline; }
    bool readOnly() const @safe pure nothrow @nogc { return _readOnly; }
    bool wordWrap() const @safe pure nothrow @nogc { return _wordWrap; }
    ParagraphDirection paragraphDirection() const @safe pure nothrow @nogc
    {
        return _paragraphDirection;
    }
    size_t cursorIndex() const @safe pure nothrow @nogc { return _cursor; }
    CaretAffinity caretAffinity() const @safe pure nothrow @nogc
    {
        return _caretAffinity;
    }
    size_t selectionAnchor() const @safe pure nothrow @nogc { return _anchor; }
    bool hasSelection() const @safe pure nothrow @nogc { return _cursor != _anchor; }
    Scrollbar verticalScrollbar() @safe pure nothrow @nogc
    {
        return _verticalScrollbar;
    }
    const(dchar)[] textView() const @safe pure nothrow @nogc { return _buffer; }

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
        _caretAffinity = CaretAffinity.downstream;
        markLayoutDirty();
        resetCaret();
        if (notify) notifyChanged();
        else invalidate();
    }

    void clear()
    {
        if (!_readOnly) replaceRange(0, _buffer.length, null);
    }

    void setReadOnly(bool value)
    {
        _readOnly = value;
        invalidate();
    }

    /** Keep an editable text surface visible while a composed replacement
     * frame is prepared, without leaving a blinking insertion caret behind. */
    void setCaretEnabled(bool value)
    {
        if (_caretEnabled == value) return;
        _caretEnabled = value;
        invalidate();
    }

    /** Wrap multiline content at Unicode line-break opportunities. */
    void setWordWrap(bool value)
    {
        value = value && _multiline;
        if (_wordWrap == value) return;
        _wordWrap = value;
        _scrollX = 0;
        markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    /** Override automatic paragraph direction for all editor paragraphs. */
    void setParagraphDirection(ParagraphDirection value)
    {
        if (_paragraphDirection == value) return;
        _paragraphDirection = value;
        _caretAffinity = CaretAffinity.downstream;
        markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    void setPlaceholder(string value)
    {
        _placeholder = toUTF32(value);
        invalidate();
    }

    void setShowBorder(bool value)
    {
        _showBorder = value;
        invalidate();
    }

    /** Leave composed content visible behind overlay editors while retaining
     * normal text selection and caret painting. */
    void setTransparentBackground(bool value)
    {
        if (_transparentBackground == value) return;
        _transparentBackground = value;
        invalidate();
    }

    /** Disable field-like focus chrome when the editor itself is the rendered
     * canvas object, such as direct title editing in a composition preview. */
    void setFocusDecoration(bool value)
    {
        if (_focusDecoration == value) return;
        _focusDecoration = value;
        invalidate();
    }


    /** Disable document scrolling/chrome when this editor is itself a canvas
     * title layer sized to its complete shaped text layout. */
    void setCanvasTextMode(bool value)
    {
        if (_canvasTextMode == value) return;
        _canvasTextMode = value;
        _scrollLine = 0;
        _scrollX = 0;
        markLayoutDirty();
        invalidate();
    }

    /** Use an application-selected face for this editor without replacing the
     * window's global UI or monospace font. A null face uses the selected role's
     * normal primary/fallback collection. */
    void setFontFace(FontFace value, FontRole role = FontRole.ui)
    {
        if (_fontFace is value && _fontRole == role) return;
        _fontFace = value;
        _fontRole = role;
        markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    /** Override the normal UI-scaled font size for direct canvas title editing. */
    void setPixelSizeOverride(int value)
    {
        value = maxInt(0, value);
        if (_pixelSizeOverride == value) return;
        _pixelSizeOverride = value;
        markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    /** Paint editable text, selection caret, and placeholder using title color. */
    void setTextColor(Color value)
    {
        _customTextColor = true;
        _textColor = value;
        invalidate();
    }

    void clearTextColor()
    {
        if (!_customTextColor) return;
        _customTextColor = false;
        invalidate();
    }

    /** Paint authored title effects through the editor's one glyph layout. */
    /** Apply opacity once to the complete canvas-title layer. */
    void setTitleLayerOpacity(double value)
    {
        if (value < 0.0) value = 0.0;
        else if (value > 1.0) value = 1.0;
        if (_titleLayerOpacity == value) return;
        _titleLayerOpacity = value;
        invalidate();
    }

    void setTitleEffects(int strokeWidth, Color strokeColor,
        int shadowOffsetX, int shadowOffsetY, int shadowBlur,
        Color shadowColor, bool underline, bool box, Color boxColor)
    {
        _titleStrokeWidth = clampInt(strokeWidth, 0, 8);
        _titleStrokeColor = strokeColor;
        _titleShadowOffsetX = shadowOffsetX;
        _titleShadowOffsetY = shadowOffsetY;
        _titleShadowBlur = clampInt(shadowBlur, 0, 8);
        _titleShadowColor = shadowColor;
        _titleUnderline = underline;
        _titleBox = box;
        _titleBoxColor = boxColor;
        invalidate();
    }

    /** Align each line within the canvas-title layout's measured width. */
    void setTitleHorizontalAlignment(HorizontalAlign value)
    {
        if (_titleHorizontal == value) return;
        _titleHorizontal = value;
        markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    private int selectedPixelSize(int scale) const @safe pure nothrow @nogc
    {
        return _pixelSizeOverride > 0 ? _pixelSizeOverride : fontPixelSize(scale);
    }

    void setPadding(int value)
    {
        value = maxInt(0, value);
        if (_padding == value) return;
        _padding = value;
        if (_wordWrap) markLayoutDirty();
        ensureCursorVisible();
        invalidate();
    }

    /** Measured glyph layout size for live composition-title placement. */
    Size contentSize()
    {
        return ensureLayout().measuredSize();
    }

    /** Symmetric room needed around glyphs for box, stroke and shadow paint. */
    int titleEffectMargin() const @safe pure nothrow @nogc
    {
        TitlePaintStyle style;
        style.strokeWidth = _titleStrokeWidth;
        style.shadowOffsetX = _titleShadowOffsetX;
        style.shadowOffsetY = _titleShadowOffsetY;
        style.shadowBlur = _titleShadowBlur;
        return titlePaintMargin(style);
    }

    int cursorLine()
    {
        return cast(int) ensureLayout().lineForLogical(_cursor);
    }

    int cursorColumn()
    {
        const start = lineStart(_cursor);
        auto boundaries = graphemeBoundaries(_buffer[start .. _cursor]);
        return boundaries.length > 0 ? cast(int) boundaries.length - 1 : 0;
    }

    int lineCount()
    {
        return cast(int) ensureLayout().lines.length;
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

    /** Move the caret to a grapheme boundary, optionally preserving anchor. */
    void setCursorIndex(size_t index, bool extendSelection = false)
    {
        _cursor = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        if (!extendSelection) _anchor = _cursor;
        _preferredX = -1;
        _caretAffinity = CaretAffinity.downstream;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    /** Set a logical grapheme-aligned selection. */
    void setSelection(size_t anchor, size_t cursor)
    {
        _anchor = floorGraphemeBoundary(_buffer, min(anchor, _buffer.length));
        _cursor = floorGraphemeBoundary(_buffer, min(cursor, _buffer.length));
        _preferredX = -1;
        _caretAffinity = CaretAffinity.downstream;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    void undo()
    {
        if (_readOnly || _undo.length == 0) return;
        _redo ~= EditState(_buffer.dup, _cursor, _anchor, _caretAffinity);
        auto state = _undo[$ - 1];
        _undo.length = _undo.length - 1;
        restoreState(state);
        notifyChanged();
    }

    void redo()
    {
        if (_readOnly || _redo.length == 0) return;
        _undo ~= EditState(_buffer.dup, _cursor, _anchor, _caretAffinity);
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
        _caretAffinity = state.affinity;
        markLayoutDirty();
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
        _undo ~= EditState(_buffer.dup, _cursor, _anchor, _caretAffinity);
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
        _caretAffinity = CaretAffinity.downstream;
        markLayoutDirty();
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

    private size_t lineStart(size_t index) const @safe pure nothrow @nogc
    {
        index = min(index, _buffer.length);
        while (index > 0 && _buffer[index - 1] != '\n') --index;
        return index;
    }

    private size_t lineEnd(size_t index) const @safe pure nothrow @nogc
    {
        index = min(index, _buffer.length);
        while (index < _buffer.length && _buffer[index] != '\n') ++index;
        return index;
    }

    private bool isWord(dchar ch) const @safe pure nothrow @nogc
    {
        return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
               (ch >= '0' && ch <= '9') || ch == '_' || ch >= 128;
    }

    private size_t previousWord(size_t index) const @safe pure nothrow @nogc
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

    private size_t nextWord(size_t index) const @safe pure nothrow @nogc
    {
        index = floorGraphemeBoundary(_buffer, min(index, _buffer.length));
        while (index < _buffer.length && isWord(_buffer[index]))
            index = nextGraphemeBoundary(_buffer, index);
        while (index < _buffer.length && !isWord(_buffer[index]))
            index = nextGraphemeBoundary(_buffer, index);
        return index;
    }

    private void moveCursor(size_t next, bool extendSelection,
        bool preservePreferredX = false,
        CaretAffinity affinity = CaretAffinity.downstream)
    {
        _cursor = floorGraphemeBoundary(_buffer, min(next, _buffer.length));
        if (!extendSelection) _anchor = _cursor;
        if (!preservePreferredX) _preferredX = -1;
        _caretAffinity = affinity;
        ensureCursorVisible();
        resetCaret();
        notifyCursor();
    }

    private void moveVisual(int delta, bool extendSelection)
    {
        auto layout = ensureLayout();
        const next = layout.visualCaretMove(_cursor, _caretAffinity, delta);
        moveCursor(next.logicalIndex, extendSelection, false, next.affinity);
    }

    private void moveLineEdge(bool rightEdge, bool extendSelection)
    {
        auto layout = ensureLayout();
        const current = layout.caretPosition(_cursor, _caretAffinity);
        const next = layout.lineEdgeCaret(current.lineIndex, rightEdge);
        moveCursor(next.logicalIndex, extendSelection, false, next.affinity);
    }

    private void moveVertical(int deltaLines, bool extendSelection)
    {
        auto layout = ensureLayout();
        if (layout.lines.length == 0) return;
        auto caret = layout.caretPosition(_cursor, _caretAffinity);
        if (_preferredX < 0) _preferredX = cast(int) floor(caret.x + 0.5);
        const target = clampInt(cast(int) caret.lineIndex + deltaLines, 0,
            cast(int) layout.lines.length - 1);
        const line = layout.lines[target];
        const next = layout.hitTestCaret(_preferredX,
            line.y + line.height * 0.5);
        moveCursor(next.logicalIndex, extendSelection, true, next.affinity);
    }

    private void notifyChanged()
    {
        if (onChanged !is null) onChanged();
        if (onCursorMoved !is null) onCursorMoved();
        invalidate();
    }

    private void notifyCursor()
    {
        if (onCursorMoved !is null) onCursorMoved();
        invalidate();
    }

    private void resetCaret()
    {
        _caretClock = 0.0;
        _caretVisible = true;
    }

    private void markLayoutDirty()
    {
        _layoutDirty = true;
        _textLayout = null;
    }

    private int wrappedLayoutWidth() const @safe pure nothrow @nogc
    {
        if (!_multiline || !_wordWrap) return 0;
        return maxInt(1, bounds().width - _padding * 2 - 8);
    }

    private TextLayoutOptions layoutOptions() const
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = _fontRole;
        if (_fontFace !is null)
            options.overrideFace = cast() _fontFace;
        else
            options.overrideFace = cast() (_fontRole == FontRole.monospace ?
                palette.monospaceFont : palette.uiFont);
        options.pixelSize = selectedPixelSize(palette.fontScale);
        options.wrap = _multiline && _wordWrap;
        options.maxWidth = wrappedLayoutWidth();
        options.paragraphDirection = _paragraphDirection;
        return options;
    }

    private ulong selectedFaceIdentity() const
    {
        if (_fontFace !is null) return _fontFace.identity;
        const palette = theme();
        const face = _fontRole == FontRole.monospace ?
            palette.monospaceFont : palette.uiFont;
        return face is null ? 0 : face.identity;
    }

    private bool layoutParametersChanged()
    {
        const palette = theme();
        return _layoutPixelSize != selectedPixelSize(palette.fontScale) ||
            _layoutMaxWidth != wrappedLayoutWidth() ||
            _layoutWordWrap != _wordWrap ||
            _layoutParagraphDirection != _paragraphDirection ||
            _layoutTitleHorizontal != _titleHorizontal ||
            _layoutFaceIdentity != selectedFaceIdentity() ||
            _layoutFontRevision != fontSystem().revision;
    }

    private void rememberLayoutParameters()
    {
        const palette = theme();
        _layoutPixelSize = selectedPixelSize(palette.fontScale);
        _layoutMaxWidth = wrappedLayoutWidth();
        _layoutWordWrap = _wordWrap;
        _layoutParagraphDirection = _paragraphDirection;
        _layoutTitleHorizontal = _titleHorizontal;
        _layoutFaceIdentity = selectedFaceIdentity();
        _layoutFontRevision = fontSystem().revision;
    }

    private void alignCanvasTitleLayout(TextLayout layout)
    {
        if (!_canvasTextMode || layout is null ||
            _titleHorizontal == HorizontalAlign.left) return;
        foreach (lineIndex, ref line; layout.lines)
        {
            double offset;
            final switch (_titleHorizontal)
            {
                case HorizontalAlign.left: continue;
                case HorizontalAlign.center:
                    offset = (layout.width - line.width) * 0.5;
                    break;
                case HorizontalAlign.right:
                    offset = layout.width - line.width;
                    break;
            }
            if (offset <= 0.000_001) continue;
            line.x += offset;
            foreach (ref run; layout.runs)
                if (run.lineIndex == lineIndex) run.x += offset;
            foreach (ref glyph; layout.glyphs)
                if (glyph.lineIndex == lineIndex) glyph.x += offset;
            foreach (ref cluster; layout.visualClusters)
                if (cluster.lineIndex == lineIndex)
                {
                    cluster.xMin += offset;
                    cluster.xMax += offset;
                }
            foreach (ref caret; layout.carets)
                if (caret.lineIndex == lineIndex) caret.x += offset;
        }
    }

    private TextLayout ensureLayout()
    {
        if (_textLayout is null || _layoutDirty || layoutParametersChanged())
        {
            _textLayout = fontSystem().textEngine.layout(_buffer, layoutOptions());
            alignCanvasTitleLayout(_textLayout);
            _layoutDirty = false;
            rememberLayoutParameters();
        }
        return _textLayout;
    }

    private TextLayout ensureLayout(ref Canvas canvas)
    {
        if (_textLayout is null || _layoutDirty || layoutParametersChanged())
        {
            _textLayout = fontSystem().textEngine.layout(_buffer,
                layoutOptions());
            alignCanvasTitleLayout(_textLayout);
            _layoutDirty = false;
            rememberLayoutParameters();
        }
        return _textLayout;
    }

    private int fallbackLineHeight()
    {
        auto layout = ensureLayout();
        if (layout.lines.length == 0) return maxInt(1, _layoutPixelSize);
        return maxInt(1, cast(int) ceil(layout.lines[0].height));
    }

    private int visibleLineCount()
    {
        return maxInt(1, (bounds().height - _padding * 2) /
            maxInt(1, fallbackLineHeight()));
    }

    private int maxScrollLine()
    {
        auto layout = ensureLayout();
        return maxInt(0, cast(int) layout.lines.length - visibleLineCount());
    }

    override bool nativeVerticalScrollInfo(Point localPosition, out Widget source,
        out int position, out int maximum, out int pageSize)
    {
        if (_verticalScrollbar is null || !_verticalScrollbar.visible())
        {
            source = null;
            position = 0;
            maximum = 0;
            pageSize = 1;
            return false;
        }
        return _verticalScrollbar.nativeVerticalScrollInfo(localPosition, source,
            position, maximum, pageSize);
    }

    protected override void onLayout()
    {
        synchronizeVerticalScrollbar();
    }

    private void synchronizeVerticalScrollbar()
    {
        if (_verticalScrollbar is null) return;
        const maximum = (!_canvasTextMode && _multiline) ? maxScrollLine() : 0;
        const rows = visibleLineCount();
        _scrollLine = clampInt(_scrollLine, 0, maximum);
        _verticalScrollbar.setBounds(Rect(maxInt(0, bounds().width - 10), 4,
            8, maxInt(1, bounds().height - 8)));
        _verticalScrollbar.setPageStep(maxInt(1, rows - 1));
        _verticalScrollbar.setRange(0, maximum, rows);
        _verticalScrollbar.setValue(_scrollLine, false);
        _verticalScrollbar.setVisible(maximum > 0);
    }

    private double scrollOriginY(TextLayout layout) const
    {
        if (layout.lines.length == 0) return 0.0;
        const index = min(cast(size_t) maxInt(0, _scrollLine),
            layout.lines.length - 1);
        return layout.lines[index].y;
    }

    private void ensureCursorVisible()
    {
        auto layout = ensureLayout();
        if (_canvasTextMode)
        {
            _scrollLine = 0;
            _scrollX = 0;
            return;
        }
        if (layout.lines.length == 0) return;
        auto caret = layout.caretPosition(_cursor, _caretAffinity);
        const rows = visibleLineCount();
        if (caret.lineIndex < cast(size_t) _scrollLine)
            _scrollLine = cast(int) caret.lineIndex;
        else if (caret.lineIndex >= cast(size_t) (_scrollLine + rows))
            _scrollLine = cast(int) caret.lineIndex - rows + 1;
        _scrollLine = clampInt(_scrollLine, 0,
            maxInt(0, cast(int) layout.lines.length - rows));

        if (_wordWrap)
            _scrollX = 0;
        else
        {
            const viewport = maxInt(1, bounds().width - _padding * 2 - 8);
            if (caret.x < _scrollX)
                _scrollX = maxInt(0, cast(int) floor(caret.x));
            else if (caret.x > _scrollX + viewport - 2)
                _scrollX = maxInt(0, cast(int) ceil(caret.x) - viewport + 2);
            const maxHorizontal = maxInt(0,
                cast(int) ceil(layout.width) - viewport);
            _scrollX = clampInt(_scrollX, 0, maxHorizontal);
        }
    }

    private CaretPosition caretAtPoint(Point point)
    {
        auto layout = ensureLayout();
        const x = point.x - _padding + _scrollX;
        const y = point.y - _padding + scrollOriginY(layout);
        return layout.hitTestCaret(x, y);
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
        _caretAffinity = CaretAffinity.downstream;
    }

    private void selectLineAt(size_t index)
    {
        _anchor = lineStart(index);
        _cursor = lineEnd(index);
        if (_cursor < _buffer.length) ++_cursor;
        _caretAffinity = CaretAffinity.downstream;
    }

    protected override void onBoundsChanged()
    {
        if (_wordWrap) markLayoutDirty();
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
        if (!_transparentBackground)
        {
            if (_showBorder)
                canvas.drawRoundedRect(full, palette.cornerRadius,
                    palette.fieldBackground, focused() ? palette.accent :
                    palette.border, focused() ? 2 : 1);
            else
                canvas.fillRect(full, palette.fieldBackground);
        }
        else if (_focusDecoration && focused())
            canvas.drawRoundedRect(full.inset(1), palette.cornerRadius,
                palette.fieldBackground.withAlpha(18), palette.accent.withAlpha(190), 1);

        const inset = !_transparentBackground && _showBorder ? 2 : 0;
        auto content = canvas.clipped(full.inset(inset));
        auto layout = ensureLayout(canvas);
        ensureCursorVisible();
        synchronizeVerticalScrollbar();
        const originX = _padding - _scrollX;
        const originY = _padding - cast(int) floor(scrollOriginY(layout));

        if (_buffer.length == 0 && _placeholder.length > 0 && !focused())
        {
            content.drawText(Point(_padding, _padding), _placeholder,
                palette.textMuted, palette.fontScale, FontRole.monospace,
                palette.monospaceFont);
        }
        else
        {
            const foreground = _customTextColor ? _textColor :
                (_readOnly ? palette.textMuted : palette.text);

            TitlePaintStyle titleStyle;
            titleStyle.foreground = foreground;
            titleStyle.strokeWidth = _titleStrokeWidth;
            titleStyle.strokeColor = _titleStrokeColor;
            titleStyle.shadowOffsetX = _titleShadowOffsetX;
            titleStyle.shadowOffsetY = _titleShadowOffsetY;
            titleStyle.shadowBlur = _titleShadowBlur;
            titleStyle.shadowColor = _titleShadowColor;
            titleStyle.underline = _titleUnderline;
            titleStyle.box = _titleBox;
            titleStyle.boxColor = _titleBoxColor;
            titleStyle.layerOpacity = _titleLayerOpacity;
            const titleOrigin = Point(originX, originY);
            paintTitleBackdrop(content, layout, titleOrigin, titleStyle);
            // Normal document fields may retain a selection while inactive,
            // but a live canvas title must never paint stale character
            // highlighting after focus leaves its direct editor.
            if (hasSelection() && (!_canvasTextMode || focused()))
            {
                foreach (selection; layout.selectionRects(selectionStart(),
                    selectionEnd()))
                    content.fillRect(selection.translated(originX, originY),
                        palette.selection);
            }
            paintTitleForeground(content, layout, titleOrigin, titleStyle);
        }

        if (_caretEnabled && focused() && _caretVisible)
        {
            const caret = layout.caretPosition(_cursor, _caretAffinity);
            const x = originX + cast(int) floor(caret.x + 0.5);
            const y = originY + cast(int) floor(caret.y + 1.0);
            const height = maxInt(2, cast(int) ceil(caret.height) - 2);
            content.fillRect(Rect(x, y, 2, height),
                _customTextColor ? _textColor : palette.text);
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
            _caretAffinity = hit.affinity;
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
        _caretAffinity = hit.affinity;
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
        if (_canvasTextMode) return false;
        if (!_multiline && event.wheelX == 0 && !event.shift()) return false;
        if (!_wordWrap && (event.shift() || event.wheelX != 0))
        {
            const delta = event.wheelX != 0 ? event.wheelX : event.wheelY;
            _scrollX = maxInt(0, _scrollX - delta * maxInt(8,
                _layoutPixelSize));
            ensureCursorVisible();
            invalidate();
            return true;
        }
        synchronizeVerticalScrollbar();
        return _verticalScrollbar.visible() &&
            _verticalScrollbar.onMouseWheel(event);
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
                    if (hasSelection())
                        writeClipboardText(_buffer[selectionStart() ..
                            selectionEnd()]);
                    return true;
                case Key.x:
                    if (hasSelection())
                    {
                        writeClipboardText(_buffer[selectionStart() ..
                            selectionEnd()]);
                        if (!_readOnly) deleteSelection();
                    }
                    return true;
                case Key.v:
                    if (!_readOnly)
                    {
                        auto text = readClipboardText();
                        if (text.length > 0) pasteText(text);
                    }
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
                    moveVisual(-1, event.shift());
                return true;
            case Key.right:
                if (!event.shift() && hasSelection())
                    moveCursor(selectionEnd(), false);
                else if (shortcut)
                    moveCursor(nextWord(_cursor), event.shift());
                else
                    moveVisual(1, event.shift());
                return true;
            case Key.up:
                if (_multiline) moveVertical(-1, event.shift());
                return _multiline;
            case Key.down:
                if (_multiline) moveVertical(1, event.shift());
                return _multiline;
            case Key.pageUp:
                if (_multiline) moveVertical(-visibleLineCount(), event.shift());
                return _multiline;
            case Key.pageDown:
                if (_multiline) moveVertical(visibleLineCount(), event.shift());
                return _multiline;
            case Key.home:
                moveLineEdge(false, event.shift());
                return true;
            case Key.end:
                moveLineEdge(true, event.shift());
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
                if (_multiline)
                {
                    if (!_readOnly) insertText("\n"d);
                }
                else if (onSubmitted !is null)
                    onSubmitted();
                return true;
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

class TextArea : TextEditor
{
    this(string text = "")
    {
        super(text, true);
    }
}

class TextField : TextEditor
{
    this(string text = "")
    {
        super(text, false);
        layoutHints().preferredHeight = 40;
        layoutHints().minHeight = 38;
    }
}

unittest
{
    auto editor = new TextArea("one\ntwo");
    editor.setCursorIndex(0);

    Event input;
    input.type = EventType.textInput;
    input.text = "A"d;
    assert(editor.onTextInput(input));
    assert(editor.textUtf8() == "Aone\ntwo");
    assert(editor.cursorIndex() == 1);

    Event undoEvent;
    undoEvent.type = EventType.keyDown;
    undoEvent.key = Key.z;
    undoEvent.modifiers = cast(uint) KeyModifier.control;
    assert(editor.onKeyDown(undoEvent));
    assert(editor.textUtf8() == "one\ntwo");

    editor.setSelection(0, 3);
    Event copyEvent;
    copyEvent.type = EventType.keyDown;
    copyEvent.key = Key.c;
    copyEvent.modifiers = cast(uint) KeyModifier.control;
    assert(editor.onKeyDown(copyEvent));

    editor.setCursorIndex(editor.textView().length);
    Event pasteEvent;
    pasteEvent.type = EventType.keyDown;
    pasteEvent.key = Key.v;
    pasteEvent.modifiers = cast(uint) KeyModifier.control;
    assert(editor.onKeyDown(pasteEvent));
    assert(editor.textUtf8() == "one\ntwoone");

    // Combining sequences and emoji ZWJ sequences are indivisible edits.
    editor.setText("A\u0301B", false);
    editor.setCursorIndex(2);
    Event backspace;
    backspace.type = EventType.keyDown;
    backspace.key = Key.backspace;
    assert(editor.onKeyDown(backspace));
    assert(editor.textUtf32() == "B"d);
    assert(editor.cursorIndex() == 0);

    editor.setText("x\U0001F469\u200D\U0001F4BBy", false);
    editor.setCursorIndex(1);
    Event right;
    right.type = EventType.keyDown;
    right.key = Key.right;
    assert(editor.onKeyDown(right));
    assert(editor.cursorIndex() == 4);

    editor.setText("one two three four five", false);
    editor.setBounds(Rect(0, 0, 100, 100));
    editor.setWordWrap(true);
    assert(editor.wordWrap());
    assert(editor.lineCount() > 1);
    editor.setParagraphDirection(ParagraphDirection.rightToLeft);
    assert(editor.paragraphDirection() == ParagraphDirection.rightToLeft);
    editor.setParagraphDirection(ParagraphDirection.automatic);
    editor.setWordWrap(false);

    // Physical arrow movement traverses every bidi insertion state.  The same
    // logical boundary can occur at two visual positions, distinguished by
    // affinity, so retaining that state prevents a caret from getting stuck.
    editor.setText("abc אבג 123", false);
    editor.setCursorIndex(0);
    immutable size_t[] bidiOrder = [1, 2, 3, 4, 8, 9, 10, 11, 8, 7, 6, 5, 4];
    foreach (expected; bidiOrder)
    {
        assert(editor.onKeyDown(right));
        assert(editor.cursorIndex() == expected);
    }
    assert(editor.caretAffinity() == CaretAffinity.downstream);
}

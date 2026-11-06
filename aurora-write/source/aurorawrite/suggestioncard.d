/**
 * The caret card: the small list that appears just above the word being typed.
 *
 * It is painted and hit-tested as one floating panel that never takes focus, so
 * the writer keeps typing while it is open. It shows the target word and a
 * one-sentence definition, up to eight numbered choices, and the highlighted
 * choice's own one-sentence gloss in place of the key hints.
 */
module aurorawrite.suggestioncard;

import aurora;
import aurorawrite.concision : Analysis, ConciseChoice, maxChoices, wordCount;
import std.utf : toUTF32;

private enum int panelPadding = 14;
private enum int headerHeight = 20;
private enum int definitionLineHeight = 18;
private enum int chipHeight = 26;
private enum int chipGap = 6;
private enum int rowGap = 4;
private enum int footerHeight = 16;
private enum int cornerRadius = 10;
private enum int minimumWidth = 340;
private enum int maximumWidth = 560;
private enum int screenMargin = 8;
private enum int anchorGap = 8;

private enum int headerPixelSize = 16;
private enum int statusPixelSize = 12;
private enum int definitionPixelSize = 14;
private enum int chipPixelSize = 14;
private enum int footerPixelSize = 11;

final class SuggestionCard : Widget
{
    /// Called with the chosen index when the writer activates a choice.
    void delegate(int index) onApply;

    private Analysis _analysis;
    private string _status;
    private bool _open;
    private int _selected = -1;
    private int _hover = -1;
    private Rect _anchorCaret;
    private bool _hasAnchor;
    private int _availableWidth;
    private int _availableHeight;
    private Rect[] _chipRects;
    private string[] _definitionLines;
    private string _headerText;
    private Size _panel;
    /// Diagnostic counter for the interaction probe: content re-layouts.
    size_t diagnosticRelayoutCount;

    this()
    {
        // Never focusable: the caret must stay in the editor while the card is
        // open, or the next keystroke would have nowhere to land.
        setFocusable(false);
    }

    bool open() const @safe pure nothrow @nogc { return _open; }

    int choiceCount() const @safe pure nothrow @nogc
    {
        return cast(int) _analysis.choices.length;
    }

    int selected() const @safe pure nothrow @nogc { return _selected; }

    /// The status line currently shown in the card header.
    string status() const @safe pure nothrow @nogc { return _status; }

    const(Analysis)* analysis() const @safe pure nothrow @nogc
    {
        return &_analysis;
    }

    Size panelSize() const @safe pure nothrow @nogc { return _panel; }

    /// The choosable entry for an index, or `null`.
    const(ConciseChoice)* choice(int index) const @safe pure nothrow @nogc
    {
        if (index < 0 || index >= choiceCount()) return null;
        return &_analysis.choices[cast(size_t) index];
    }

    /// The choice the writer would activate right now (selection, else first).
    const(ConciseChoice)* activeChoice() const @safe pure nothrow @nogc
    {
        if (_hover >= 0) return choice(_hover);
        if (_selected >= 0) return choice(_selected);
        return choice(0);
    }

    void dismiss()
    {
        if (!_open) return;
        _open = false;
        _selected = -1;
        _hover = -1;
        setVisible(false);
        invalidate();
    }

    /// Show the analysis for the current word, keeping the caret anchor.
    void present(Analysis analysis, string status)
    {
        // Re-measuring identical content (for example after a failed model
        // reply) would only cost layout time.
        const unchanged = _open && status == _status &&
            sameContent(analysis, _analysis);
        _analysis = analysis;
        _status = status;
        _selected = -1;
        _hover = -1;
        _open = analysis.choices.length > 0;
        setVisible(_open);
        if (unchanged && _panel.width > 0)
            setBounds(panelRect());
        else
            relayout();
        invalidate();
    }

    private static bool sameContent(ref const Analysis left,
        ref const Analysis right) @safe pure nothrow
    {
        if (left.target != right.target) return false;
        if (left.definition != right.definition) return false;
        if (left.choices.length != right.choices.length) return false;
        foreach (index, ref choice; left.choices)
            if (choice.text != right.choices[index].text) return false;
        return true;
    }

    /// Replace the status line without disturbing the choices (e.g. progress).
    void setStatus(string status)
    {
        if (_status == status) return;
        _status = status;
        if (_open) invalidate();
    }

    /**
     * Remember where the caret is and place the panel above it.
     *
     * This runs on every keystroke right after `present`, so it only re-measures
     * when the anchor change can alter the layout (a new window width); moving
     * the panel is otherwise a bounds update.
     */
    void anchorAt(Rect caretInParent, int parentWidth, int parentHeight)
    {
        const widthChanged = _availableWidth != parentWidth;
        const moved = !_hasAnchor || _anchorCaret != caretInParent;
        _anchorCaret = caretInParent;
        _hasAnchor = true;
        _availableWidth = parentWidth;
        _availableHeight = parentHeight;
        if (widthChanged || _panel.width == 0)
        {
            relayout();
            return;
        }
        if (moved) setBounds(panelRect());
    }

    void moveSelection(int delta)
    {
        const count = choiceCount();
        if (count == 0) return;
        if (_selected < 0)
            _selected = delta < 0 ? count - 1 : 0;
        else
            _selected = ((_selected + delta) % count + count) % count;
        _hover = -1;
        invalidate();
    }

    void selectIndex(int index)
    {
        const count = choiceCount();
        _selected = index >= 0 && index < count ? index : -1;
        _hover = -1;
        invalidate();
    }

    /// Activate the current choice through `onApply`.
    bool applyActive()
    {
        if (activeChoice() is null) return false;
        const index = _hover >= 0 ? _hover : (_selected >= 0 ? _selected : 0);
        if (onApply !is null) onApply(index);
        return true;
    }

    // --- Geometry -------------------------------------------------------

    private Size measure(string text, int pixelSize)
    {
        if (text.length == 0) return Size(0, 0);
        return fontSystem().textEngine.layoutCached(text.toUTF32,
            textOptions(pixelSize)).measuredSize();
    }

    /// Greedy word wrap into at most `maxLines` lines of `width` pixels.
    private string[] wrap(string text, int width, int pixelSize, int maxLines)
    {
        string[] lines;
        if (text.length == 0 || width <= 0 || maxLines <= 0) return lines;
        string line;
        foreach (word; splitWords(text))
        {
            const candidate = line.length == 0 ? word : line ~ " " ~ word;
            if (measure(candidate, pixelSize).width <= width)
            {
                line = candidate;
                continue;
            }
            if (line.length > 0) lines ~= line;
            line = word;
            if (cast(int) lines.length == maxLines)
            {
                line = "";
                break;
            }
        }
        if (line.length > 0)
        {
            if (cast(int) lines.length < maxLines) lines ~= line;
            else lines[$ - 1] = lines[$ - 1] ~ "...";
        }
        else if (cast(int) lines.length == maxLines && lines.length > 0 &&
            !endsWithDots(lines[$ - 1]))
            lines[$ - 1] = lines[$ - 1] ~ "...";
        return lines;
    }

    /// The longest prefix of `text` that fits `width`, with an ellipsis.
    private string truncate(string text, int width, int pixelSize)
    {
        if (width <= 0) return "";
        if (measure(text, pixelSize).width <= width) return text;
        string best;
        foreach (word; splitWords(text))
        {
            const candidate = best.length == 0 ? word : best ~ " " ~ word;
            if (measure(candidate ~ "...", pixelSize).width > width) break;
            best = candidate;
        }
        return best.length > 0 ? best ~ "..." : "";
    }

    /// Recompute content height, width and chip rectangles for the anchor.
    private void relayout()
    {
        ++diagnosticRelayoutCount;
        const width = panelWidth();
        const contentWidth = width - panelPadding * 2;
        _definitionLines = wrap(_analysis.definition, contentWidth,
            definitionPixelSize, 2);

        const statusText = savingsText().length > 0 ? savingsText() : _status;
        const statusWidth = measure(statusText, statusPixelSize).width;
        _headerText = truncate(_analysis.target, contentWidth -
            (statusWidth > 0 ? statusWidth + 12 : 0), headerPixelSize);

        _chipRects = [];
        _chipRects.reserve(_analysis.choices.length);
        int rowTop = 0;
        int cursorX = 0;
        foreach (index, ref choice; _analysis.choices)
        {
            const label = choiceLabel(cast(int) index, choice);
            const chipWidth = maxInt(52, measure(label, chipPixelSize).width + 34);
            if (cursorX > 0 && cursorX + chipWidth > contentWidth)
            {
                cursorX = 0;
                rowTop += chipHeight + rowGap;
            }
            _chipRects ~= Rect(cursorX, rowTop, chipWidth, chipHeight);
            cursorX += chipWidth + chipGap;
        }

        const chipRows = _chipRects.length == 0 ? 0 : rowTop + chipHeight;
        const definitionBlock = cast(int) _definitionLines.length *
            definitionLineHeight + (_definitionLines.length > 0 ? 2 : 0);
        const height = contentTop() + headerHeight + definitionBlock +
            (chipRows > 0 ? chipRows + 6 : 0) + 4 + footerHeight + panelPadding;
        _panel = Size(width, height);
        setBounds(panelRect());
    }

    private int panelWidth()
    {
        const available = _availableWidth > 2 * screenMargin
            ? _availableWidth - 2 * screenMargin : maximumWidth;
        const width = available < maximumWidth ? available : maximumWidth;
        return width < minimumWidth ? minimumWidth : width;
    }

    /// First painted row below the panel's top border.
    private int contentTop() const @safe pure nothrow @nogc
    {
        return panelPadding + 2;
    }

    /// Height of the wrapped choice block (0 when there are no choices).
    private int chipRowsHeight() const @safe pure nothrow @nogc
    {
        int rows = 0;
        foreach (ref rect; _chipRects)
            if (rect.y + chipHeight > rows) rows = rect.y + chipHeight;
        return rows;
    }

    /// Top of the choice block, shared by paint, hit-testing and tests.
    private int chipBlockTop() const @safe pure nothrow @nogc
    {
        const definitionBlock = cast(int) _definitionLines.length *
            definitionLineHeight + (_definitionLines.length > 0 ? 2 : 0);
        return contentTop() + headerHeight + definitionBlock +
            (_chipRects.length > 0 ? 6 : 0);
    }

    /// A choice chip's rectangle in card-local coordinates.
    Rect chipRect(int index) const @safe pure nothrow @nogc
    {
        if (index < 0 || index >= cast(int) _chipRects.length)
            return Rect(0, 0, 0, 0);
        return _chipRects[cast(size_t) index].translated(panelPadding,
            chipBlockTop());
    }

    private Rect panelRect()
    {
        if (!_hasAnchor) return Rect(0, 0, _panel.width, _panel.height);
        const width = _panel.width;
        const height = _panel.height;
        int x = _anchorCaret.x - 18;
        const maxX = maxInt(screenMargin, _availableWidth - width - screenMargin);
        x = clampInt(x, screenMargin, maxX);
        int y = _anchorCaret.y - height - anchorGap;
        if (y < screenMargin)
            y = _anchorCaret.y + _anchorCaret.height + anchorGap;
        const maxY = maxInt(screenMargin, _availableHeight - height - screenMargin);
        y = clampInt(y, screenMargin, maxY);
        return Rect(x, y, width, height);
    }

    /// "−2 words" for the active choice, empty when it saves nothing.
    private string savingsText()
    {
        auto active = activeChoice();
        if (active is null) return "";
        if (_hover < 0 && _selected < 0) return "";
        const saved = wordCount(_analysis.target) - active.words;
        if (saved <= 0) return active.words == 0 ? "cut" : "";
        return (saved == 1 ? "-" : "-") ~ intText(saved) ~
            (saved == 1 ? " word" : " words");
    }

    private string choiceLabel(int index, ref const ConciseChoice choice)
    {
        const text = choice.text.length == 0 ? "cut" : choice.text;
        return text ~ "   " ~ intText(index + 1);
    }

    private string footerText()
    {
        auto active = activeChoice();
        if (active !is null && (_hover >= 0 || _selected >= 0) &&
            active.gloss.length > 0)
            return active.gloss;
        // The key hints are always present while idle: the whole interaction is
        // invisible without them, since the card takes no focus.
        return "Tab  cycle    Ctrl+Enter  apply    Ctrl+1-8  pick    Esc  hide";
    }

    // --- Painting -------------------------------------------------------

    protected override void onPaint(ref Canvas canvas)
    {
        if (!_open) return;
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);

        canvas.fillRoundedRect(full.translated(1, 2), cornerRadius,
            palette.shadow.withAlpha(46));
        canvas.drawRoundedRect(full, cornerRadius, palette.panelElevated,
            palette.border, 1);

        auto content = canvas.clipped(full);
        int y = contentTop();
        const contentRight = bounds().width - panelPadding;

        // Header: the target on the left, savings or status on the right.
        auto header = fontSystem().textEngine.layoutCached(_headerText.toUTF32,
            textOptions(headerPixelSize));
        content.drawLayout(Point(panelPadding,
            y + (headerHeight - header.measuredSize().height) / 2), header,
            palette.text);
        const statusText = savingsText().length > 0 ? savingsText() : _status;
        if (statusText.length > 0)
        {
            auto status = fontSystem().textEngine.layoutCached(statusText.toUTF32,
                textOptions(statusPixelSize));
            content.drawLayout(Point(contentRight - status.measuredSize().width,
                y + (headerHeight - status.measuredSize().height) / 2), status,
                savingsText().length > 0 ? palette.accent : palette.textMuted);
        }
        y += headerHeight;

        foreach (line; _definitionLines)
        {
            auto layout = fontSystem().textEngine.layoutCached(line.toUTF32,
                textOptions(definitionPixelSize));
            content.drawLayout(Point(panelPadding, y), layout, palette.textMuted);
            y += definitionLineHeight;
        }
        if (_definitionLines.length > 0) y += 2;
        y = chipBlockTop();

        // Choices in reading order: the word first, its number at the right.
        foreach (candidate, ref rect; _chipRects)
        {
            const chip = rect.translated(panelPadding, y);
            const hovered = cast(int) candidate == _hover;
            const chosen = cast(int) candidate == _selected && _hover < 0;
            const active = hovered || chosen;
            canvas.fillRoundedRect(chip, 7,
                active ? palette.accent : palette.buttonBackground);
            if (!active) canvas.strokeRect(chip, palette.border, 1);
            const ink = active ? palette.windowBackground : palette.text;
            auto label = fontSystem().textEngine.layoutCached(
                choiceLabel(cast(int) candidate,
                    _analysis.choices[candidate]).toUTF32,
                textOptions(chipPixelSize));
            content.drawLayout(Point(chip.x + 10,
                chip.y + (chip.height - label.measuredSize().height) / 2), label,
                ink);
        }

        // Footer: the highlighted choice's gloss, else the key hints.
        const footer = footerText();
        if (footer.length > 0)
        {
            auto layout = fontSystem().textEngine.layoutCached(
                truncate(footer, contentRight - panelPadding, footerPixelSize)
                    .toUTF32, textOptions(footerPixelSize));
            content.drawLayout(Point(panelPadding, bounds().height - panelPadding -
                layout.measuredSize().height), layout, palette.textMuted);
        }
    }

    private TextLayoutOptions textOptions(int pixelSize)
    {
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() theme().uiFont;
        options.pixelSize = pixelSize;
        options.wrap = false;
        return options;
    }

    // --- Pointer --------------------------------------------------------

    private int chipAt(Point position)
    {
        foreach (index, ref rect; _chipRects)
        {
            if (chipRect(cast(int) index).contains(position)) return cast(int) index;
        }
        return -1;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_open) return false;
        const hover = chipAt(event.position);
        if (hover != _hover)
        {
            _hover = hover;
            setCursor(hover >= 0 ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (!_open || event.button != MouseButton.left) return false;
        const index = chipAt(event.position);
        if (index < 0) return false;
        _selected = index;
        if (onApply !is null) onApply(index);
        return true;
    }
}

/// Split on runs of whitespace.
private string[] splitWords(string text) @safe pure
{
    string[] words;
    size_t start = 0;
    foreach (index, char value; text)
    {
        if (value != ' ' && value != '\t' && value != '\n' && value != '\r')
            continue;
        if (index > start) words ~= text[start .. index];
        start = index + 1;
    }
    if (text.length > start) words ~= text[start .. $];
    return words;
}

private bool endsWithDots(string value) @safe pure nothrow
{
    return value.length >= 3 && value[$ - 3 .. $] == "...";
}

/// Minimal positive-int formatter (no std.conv import on the paint path).
private string intText(long value) @safe pure nothrow
{
    char[24] buffer;
    size_t index = buffer.length;
    const negative = value < 0;
    ulong magnitude = negative ? cast(ulong) -value : cast(ulong) value;
    do
    {
        buffer[--index] = cast(char) ('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude > 0);
    if (negative) buffer[--index] = '-';
    return buffer[index .. $].idup;
}

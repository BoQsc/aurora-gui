module aurorastream.clipboardfield;

import aurora : Canvas, ContextMenuItem, Event, EventType, FontRole, Key,
    KeyModifier, MouseButton, Point, Rect, TextField, TextLayoutOptions,
    fontPixelSize, showContextMenu;
import std.algorithm.comparison : max, min;
import std.math : ceil, floor;
import std.utf : toUTF8, toUTF16, toUTF32;

version (Windows)
{
    import core.sys.windows.windows;
}

/**
 * Aurora text field with native operating-system clipboard integration.
 *
 * Aurora-D 0.4.5 keeps copied text in a process-local buffer. That is useful
 * between Aurora controls, but stream keys are normally copied from a browser.
 * This field mirrors Copy/Cut to the Windows Unicode clipboard and reads Paste
 * from it, while retaining Aurora's normal selection, undo and fallback logic.
 */
final class ClipboardTextField : TextField
{
    private bool _passwordMode;
    private dstring _passwordPlaceholder;
    private int _passwordScrollX;

    this(string text = "")
    {
        super(text);
    }

    void setPasswordMode(bool value)
    {
        if (_passwordMode == value) return;
        _passwordMode = value;
        _passwordScrollX = 0;
        invalidate();
    }

    bool passwordMode() const @safe pure nothrow @nogc
    {
        return _passwordMode;
    }

    override void setPlaceholder(string value)
    {
        _passwordPlaceholder = toUTF32(value);
        super.setPlaceholder(value);
    }

    /** Paste operating-system clipboard text through the field's normal edit
     * path. The compact stream-key buttons request replacement of the full
     * current value, while Ctrl+V retains ordinary insertion behavior. */
    bool pasteFromSystemClipboard(bool replaceAll = false)
    {
        string clipboardText;
        if (!readSystemClipboard(clipboardText) || clipboardText.length == 0)
            return false;

        if (replaceAll) selectAll();
        Event input;
        input.type = EventType.textInput;
        input.text = toUTF32(clipboardText);
        if (input.text.length == 0) return false;
        return super.onTextInput(input);
    }

    private string selectedTextUtf8()
    {
        const start = min(cursorIndex(), selectionAnchor());
        const end = max(cursorIndex(), selectionAnchor());
        if (start == end) return "";
        return toUTF8(textView()[start .. end]);
    }


    private void copySelectionToSystemClipboard()
    {
        if (!hasSelection()) return;
        writeSystemClipboard(selectedTextUtf8());

        Event copy;
        copy.type = EventType.keyDown;
        copy.key = Key.c;
        copy.modifiers = cast(uint) KeyModifier.control;
        super.onKeyDown(copy);
    }

    private void cutSelectionToSystemClipboard()
    {
        if (!hasSelection() || readOnly()) return;
        writeSystemClipboard(selectedTextUtf8());

        Event cut;
        cut.type = EventType.keyDown;
        cut.key = Key.x;
        cut.modifiers = cast(uint) KeyModifier.control;
        super.onKeyDown(cut);
    }

    private bool systemClipboardContainsText()
    {
        string value;
        return readSystemClipboard(value) && value.length > 0;
    }

    private void openTextContextMenu(Point pointerPosition)
    {
        const selected = hasSelection();
        const canEdit = !readOnly();
        const canPaste = canEdit && systemClipboardContainsText();
        const hasText = textView().length > 0;

        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Cut", delegate() {
            cutSelectionToSystemClipboard();
        }, "Ctrl+X", canEdit && selected);
        items ~= ContextMenuItem.command("Copy", delegate() {
            copySelectionToSystemClipboard();
        }, "Ctrl+C", selected);
        items ~= ContextMenuItem.command("Paste", delegate() {
            pasteFromSystemClipboard(false);
        }, "Ctrl+V", canPaste);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Select all", delegate() {
            selectAll();
        }, "Ctrl+A", hasText);
        // Aurora's general editor context menu treats the supplied point as a
        // bottom-left anchor and opens upward. Native text-field menus are
        // expected to begin beside the pointer instead. Offset by this menu's
        // exact compact height so its top-left corner lands at the click.
        enum menuHeight = 3 * 2 + 4 * 22 + 4;
        const anchor = Point(pointerPosition.x - 2,
            pointerPosition.y + menuHeight + 2);
        showContextMenu(this, anchor, items);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            requestFocus();
            // Reconstruct the pointer from this field's local event position.
            // This avoids depending on a stale or differently transformed
            // global event coordinate and keeps the menu at the real click.
            openTextContextMenu(localToGlobal(event.position));
            return true;
        }
        return super.onMouseDown(event);
    }

    override bool onKeyDown(ref Event event)
    {
        const shortcut = event.control() || event.meta();
        if (!shortcut) return super.onKeyDown(event);

        switch (event.key)
        {
            case Key.c:
                if (hasSelection()) writeSystemClipboard(selectedTextUtf8());
                // Also keep Aurora's process-local clipboard as a fallback.
                return super.onKeyDown(event);

            case Key.x:
                if (hasSelection()) writeSystemClipboard(selectedTextUtf8());
                // Aurora performs the actual deletion and undo checkpoint.
                return super.onKeyDown(event);

            case Key.v:
                if (pasteFromSystemClipboard(false)) return true;
                return super.onKeyDown(event);

            default:
                // Ctrl+A, Ctrl+Z, Ctrl+Y and navigation remain owned by Aurora.
                return super.onKeyDown(event);
        }
    }

    /**
     * Paint a password field without ever placing the secret in the draw list.
     * TextField still owns editing, selection, undo, and hit-testing; stream
     * keys are ASCII and the monospace mask keeps one visual cell per input
     * character, preserving those logical positions.
     */
    protected override void onPaint(ref Canvas canvas)
    {
        if (!_passwordMode)
        {
            super.onPaint(canvas);
            return;
        }

        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, palette.cornerRadius,
            palette.fieldBackground, focused() ? palette.accent :
            palette.border, focused() ? 2 : 1);

        auto content = canvas.clipped(full.inset(2));
        const source = textView();
        if (source.length == 0)
        {
            _passwordScrollX = 0;
            if (_passwordPlaceholder.length > 0 && !focused())
                content.drawText(Point(8, 8), _passwordPlaceholder,
                    palette.textMuted, palette.fontScale, FontRole.monospace,
                    palette.monospaceFont);
            return;
        }

        dchar[] masked;
        masked.length = source.length;
        foreach (index, character; source)
            masked[index] = character == '\n' ? '\n' : '*';

        TextLayoutOptions options;
        options.role = FontRole.monospace;
        options.overrideFace = cast() palette.monospaceFont;
        options.pixelSize = fontPixelSize(palette.fontScale);
        auto layout = fontSystem().textEngine.layout(masked, options);

        const padding = 8;
        const viewport = max(1, bounds().width - padding * 2 - 8);
        const caret = layout.caretPosition(cursorIndex(), caretAffinity());
        if (caret.x < _passwordScrollX)
            _passwordScrollX = max(0, cast(int) floor(caret.x));
        else if (caret.x > _passwordScrollX + viewport - 2)
            _passwordScrollX = max(0,
                cast(int) ceil(caret.x) - viewport + 2);
        const maxHorizontal = max(0,
            cast(int) ceil(layout.width) - viewport);
        _passwordScrollX = min(_passwordScrollX, maxHorizontal);

        const originX = padding - _passwordScrollX;
        const originY = padding;
        if (hasSelection())
        {
            const selectionStart = min(cursorIndex(), selectionAnchor());
            const selectionEnd = max(cursorIndex(), selectionAnchor());
            foreach (selection; layout.selectionRects(selectionStart,
                selectionEnd))
                content.fillRect(selection.translated(originX, originY),
                    palette.selection);
        }
        content.drawLayout(Point(originX, originY), layout, palette.text);

        if (focused())
        {
            const x = originX + cast(int) floor(caret.x + 0.5);
            const y = originY + cast(int) floor(caret.y + 1.0);
            const height = max(2, cast(int) ceil(caret.height) - 2);
            content.fillRect(Rect(x, y, 2, height), palette.text);
        }
    }
}

version (Windows)
private bool openSystemClipboard()
{
    HWND owner = GetActiveWindow();
    if (owner is null) owner = GetForegroundWindow();
    if (owner is null) return false;

    // Clipboard ownership is shared system-wide. Retry briefly when another
    // application still has it open instead of randomly losing the shortcut.
    foreach (_; 0 .. 8)
    {
        if (OpenClipboard(owner)) return true;
        Sleep(5);
    }
    return false;
}

private bool writeSystemClipboard(string value)
{
    version (Windows)
    {
        if (!openSystemClipboard()) return false;
        scope (exit) CloseClipboard();

        if (!EmptyClipboard()) return false;

        const wide = toUTF16(value);
        const byteCount = (wide.length + 1) * wchar.sizeof;
        HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, byteCount);
        if (memory is null) return false;

        auto destination = cast(wchar*) GlobalLock(memory);
        if (destination is null)
        {
            GlobalFree(memory);
            return false;
        }

        destination[0 .. wide.length] = wide[];
        destination[wide.length] = 0;
        GlobalUnlock(memory);

        // After success the clipboard owns memory and must free it itself.
        if (SetClipboardData(CF_UNICODETEXT, memory) is null)
        {
            GlobalFree(memory);
            return false;
        }
        return true;
    }
    else
    {
        return false;
    }
}

private bool readSystemClipboard(out string value)
{
    value = "";
    version (Windows)
    {
        if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return false;
        if (!openSystemClipboard()) return false;
        scope (exit) CloseClipboard();

        HANDLE data = GetClipboardData(CF_UNICODETEXT);
        if (data is null) return false;

        auto source = cast(const(wchar)*) GlobalLock(cast(HGLOBAL) data);
        if (source is null) return false;
        scope (exit) GlobalUnlock(cast(HGLOBAL) data);

        size_t length;
        while (source[length] != 0) ++length;
        value = toUTF8(source[0 .. length]);
        return true;
    }
    else
    {
        return false;
    }
}

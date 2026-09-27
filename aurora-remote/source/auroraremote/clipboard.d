module auroraremote.clipboard;

version (Windows)
{
    pragma(lib, "user32");
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GetClipboardData, GlobalAlloc, GlobalFree, GlobalLock,
        GlobalUnlock, GMEM_MOVEABLE, IsClipboardFormatAvailable,
        OpenClipboard, SetClipboardData;
    import std.string : fromStringz;
    import std.utf : toUTF16, toUTF8;
}

string readClipboardText()
{
    version (Windows)
    {
        if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return "";
        if (!OpenClipboard(null))
            throw new Exception("Windows clipboard is busy.");
        scope (exit) CloseClipboard();
        auto memory = GetClipboardData(CF_UNICODETEXT);
        if (memory is null) return "";
        auto text = cast(const(wchar)*) GlobalLock(memory);
        if (text is null) throw new Exception("Could not read the clipboard.");
        scope (exit) GlobalUnlock(memory);
        return toUTF8(fromStringz(text)).idup;
    }
    else return "";
}

void writeClipboardText(string value)
{
    version (Windows)
    {
        if (!OpenClipboard(null))
            throw new Exception("Windows clipboard is busy.");
        scope (exit) CloseClipboard();
        if (!EmptyClipboard()) throw new Exception("Could not clear the clipboard.");
        auto encoded = toUTF16(value);
        const bytes = (encoded.length + 1) * wchar.sizeof;
        auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if (memory is null) throw new Exception("Could not allocate clipboard memory.");
        auto target = cast(wchar*) GlobalLock(memory);
        if (target is null)
        {
            GlobalFree(memory);
            throw new Exception("Could not access clipboard memory.");
        }
        foreach (index, ch; encoded) target[index] = ch;
        target[encoded.length] = 0;
        GlobalUnlock(memory);
        if (SetClipboardData(CF_UNICODETEXT, memory) is null)
        {
            GlobalFree(memory);
            throw new Exception("Could not update the clipboard.");
        }
    }
}

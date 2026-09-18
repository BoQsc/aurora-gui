module auroradesktop.inputlang;

/**
 * Windows input-language enumeration and switching for the taskbar input
 * indicator (the "ENG"/"LIT" flyout). Kept separate from `system.d` so the
 * pure-Aurora widgets stay testable with a hand-supplied language list.
 */

import std.utf : toUTF8;

/// One installed keyboard input language.
struct InputLanguage
{
    /// Keyboard layout handle (HKL) as an integer (0 when unknown).
    size_t hkl;
    /// Display name, e.g. "English (United States)".
    string name;
    /// Keyboard layout description, e.g. "US keyboard".
    string keyboard;
    /// Three-letter indicator, e.g. "ENG".
    string abbrev;
    /// True for the currently active input language.
    bool active;
}

version (Windows)
{
    import core.sys.windows.windef : WORD, DWORD, HKL, LCID, LPARAM;
    import core.sys.windows.winnt : SORT_DEFAULT, MAKELCID;
    import core.sys.windows.winnls : GetLocaleInfoW, LOCALE_SLANGUAGE,
        LOCALE_SENGLANGUAGE, LOCALE_SCOUNTRY, LOCALE_SENGCOUNTRY, LCTYPE;
    import core.sys.windows.winbase : GetWindowThreadProcessId;
    import core.sys.windows.winuser : GetKeyboardLayoutList, GetKeyboardLayout,
        ActivateKeyboardLayout, GetForegroundWindow, PostMessageW,
        WM_INPUTLANGCHANGEREQUEST;

    private string localeText(LCID lcid, LCTYPE type)
    {
        wchar[256] buffer;
        const written = GetLocaleInfoW(lcid, type, buffer.ptr,
            cast(int) buffer.length);
        if (written <= 1) return "";
        try
            return toUTF8(buffer[0 .. written - 1]);
        catch (Exception)
            return "";
    }

    /// "English (United States)" -> "ENG", "Lithuanian" -> "LIT".
    private string indicatorFor(string language)
    {
        size_t length;
        while (length < language.length && language[length] != ' ' &&
            language[length] != '(')
            ++length;
        if (length == 0) return "";
        if (length > 3) length = 3;
        char[] chars = language[0 .. length].dup;
        foreach (ref c; chars)
            if (c >= 'a' && c <= 'z') c -= 32;
        return cast(string) chars;
    }

    /// Friendly keyboard description for a layout KLID ("00000409" -> "US
    /// keyboard"). Falls back to "" for unknown layouts.
    private string keyboardFor(string klid)
    {
        switch (klid)
        {
            case "00000401": return "Arabic (101) keyboard";
            case "00000405": return "Czech keyboard";
            case "00000406": return "Danish keyboard";
            case "00000407": return "German keyboard";
            case "00000408": return "Greek keyboard";
            case "00000409": return "US keyboard";
            case "00010409": return "United States-Dvorak";
            case "00020409": return "United States-International";
            case "00030409": return "United States-Dvorak for left hand";
            case "00040409": return "United States-Dvorak for right hand";
            case "0000040a": return "Spanish keyboard";
            case "0000080a": return "Latin American keyboard";
            case "0000040b": return "Finnish keyboard";
            case "0000040c": return "French keyboard";
            case "0000040e": return "Hungarian keyboard";
            case "00000410": return "Italian keyboard";
            case "00000411": return "Japanese keyboard";
            case "00000412": return "Korean keyboard";
            case "00000414": return "Norwegian keyboard";
            case "00000415": return "Polish (Programmers) keyboard";
            case "00000416": return "Portuguese (Brazil ABNT) keyboard";
            case "00000419": return "Russian keyboard";
            case "0000041b": return "Slovak keyboard";
            case "0000041d": return "Swedish keyboard";
            case "0000041f": return "Turkish Q keyboard";
            case "0001041f": return "Turkish F keyboard";
            case "00000422": return "Ukrainian keyboard";
            case "00000423": return "Belarusian keyboard";
            case "00000424": return "Slovenian keyboard";
            case "00000425": return "Estonian keyboard";
            case "00000426": return "Latvian keyboard";
            case "00000427": return "Lithuanian keyboard";
            case "00010427": return "Lithuanian IBM keyboard";
            case "00020427": return "Lithuanian New keyboard";
            case "00000809": return "United Kingdom keyboard";
            case "00000c09": return "Canadian Multilingual Standard keyboard";
            case "00001009": return "Canadian French keyboard";
            default: return "";
        }
    }
}

/**
 * Installed keyboard input languages in Windows order, with the active one
 * marked. Returns an empty list on a non-Windows backend.
 */
InputLanguage[] inputLanguages()
{
    InputLanguage[] result;
    version (Windows)
    {
        const count = GetKeyboardLayoutList(0, null);
        if (count <= 0) return result;
        auto handles = new HKL[count];
        const actual = GetKeyboardLayoutList(count, handles.ptr);
        const active = activeInputLanguage();
        foreach (i; 0 .. actual)
        {
            const hkl = cast(size_t) handles[i];
            const langid = cast(WORD) (hkl & 0xFFFF);
            LCID lcid = cast(LCID) MAKELCID(langid, SORT_DEFAULT);

            InputLanguage language;
            language.hkl = hkl;
            language.name = localeText(lcid, LOCALE_SLANGUAGE);
            if (language.name.length == 0)
                language.name = localeText(lcid, LOCALE_SENGLANGUAGE);

            // Derive the canonical layout id from the language id
            // ("00000409" for en-US, "00000427" for lt-LT): GetKeyboardLayoutName
            // only reports the calling thread's layout, not an arbitrary HKL.
            import std.format : format;
            const klid = format("0000%04x", langid);
            language.keyboard = keyboardFor(klid);
            if (language.keyboard.length == 0)
            {
                const country = localeText(lcid, LOCALE_SCOUNTRY);
                const english = localeText(lcid, LOCALE_SENGCOUNTRY);
                language.keyboard = (country.length > 0 ? country : english) ~
                    " keyboard";
            }

            language.abbrev = indicatorFor(language.name);
            if (language.abbrev.length == 0) language.abbrev = "???";
            language.active = language.hkl == active;
            result ~= language;
        }
    }
    return result;
}

/// Keyboard layout handle of the current foreground input language (0 when
/// unknown / non-Windows).
size_t activeInputLanguage()
{
    version (Windows)
    {
        auto foreground = GetForegroundWindow();
        DWORD pid;
        DWORD thread;
        if (foreground !is null)
            thread = GetWindowThreadProcessId(foreground, &pid);
        else
            thread = 0;
        return cast(size_t) GetKeyboardLayout(thread);
    }
    else
    {
        return 0;
    }
}

/// Activate an input language by its layout handle, like picking it from the
/// Windows language flyout (applies to the foreground window's thread and to
/// this process).
void activateInputLanguage(size_t hkl)
{
    version (Windows)
    {
        auto layout = cast(HKL) hkl;
        if (layout is null) return;
        auto foreground = GetForegroundWindow();
        if (foreground !is null)
            PostMessageW(foreground, WM_INPUTLANGCHANGEREQUEST, 0,
                cast(LPARAM) layout);
        ActivateKeyboardLayout(layout, 0);
    }
}

/// Three-letter indicator of the active input language ("ENG" fallback).
string inputLanguageAbbrev()
{
    foreach (language; inputLanguages())
        if (language.active) return language.abbrev;
    return "ENG";
}

/// Display name of the active input language ("" when unknown).
string inputLanguageName()
{
    foreach (language; inputLanguages())
        if (language.active) return language.name;
    return "";
}

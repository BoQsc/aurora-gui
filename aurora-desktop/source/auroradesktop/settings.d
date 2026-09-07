module auroradesktop.settings;

import std.file : exists, readText, write;
import std.string : splitLines, strip;

/**
 * The tiny persisted desktop shell choice: the newer Windows shell taskbar
 * (search pill, system tray, two-line clock) or the previous classic look.
 * Stored as a one-line `aurora-desktop.ini` next to the working directory so
 * the toggle survives restarts without any registry or platform dependency.
 */
struct DesktopSettings
{
    bool modernShell = true;
    bool hideSystemCursor = true;
}

private string settingsPath()
{
    return "aurora-desktop.ini";
}

DesktopSettings loadDesktopSettings() nothrow
{
    DesktopSettings result;
    try
    {
        if (!exists(settingsPath()))
            return result;
        foreach (line; readText(settingsPath()).splitLines())
        {
            const cleaned = line.strip();
            if (cleaned.length == 0 || cleaned[0] == '#' || cleaned[0] == ';')
                continue;
            if (cleaned == "modernShell=0" || cleaned == "modernShell=false")
                result.modernShell = false;
            else if (cleaned == "modernShell=1" || cleaned == "modernShell=true")
                result.modernShell = true;
            else if (cleaned == "hideSystemCursor=0" ||
                cleaned == "hideSystemCursor=false")
                result.hideSystemCursor = false;
            else if (cleaned == "hideSystemCursor=1" ||
                cleaned == "hideSystemCursor=true")
                result.hideSystemCursor = true;
        }
    }
    catch (Exception)
    {
    }
    return result;
}

void saveDesktopSettings(const ref DesktopSettings settings) nothrow
{
    try
    {
        write(settingsPath(),
            "# Aurora Desktop shell choice (written by System Settings).\n" ~
            "modernShell=" ~ (settings.modernShell ? "1" : "0") ~ "\n" ~
            "hideSystemCursor=" ~ (settings.hideSystemCursor ? "1" : "0") ~ "\n");
    }
    catch (Exception)
    {
    }
}

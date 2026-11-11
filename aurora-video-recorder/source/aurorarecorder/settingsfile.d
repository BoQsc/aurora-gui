module aurorarecorder.settingsfile;

/**
 * Persisted recorder settings: a tiny `key=value` text file next to the
 * executable (`aurora-video-recorder.ini`), so a portable copy keeps its
 * folder and hotkey. Values are only read back if they parse into the same
 * closed set of options the UI offers.
 */

import aurorarecorder.hotkey : HotkeyChord, chordFromText, hotkeyToText;
import aurorarecorder.recorder : RecorderOptions;
import aurorarecorder.settings : CaptureTarget, frameRatePresets,
    nearestPreset, qualityPresets;

import std.file : exists, readText, write;
import std.format : format;
import std.path : buildPath;
import std.string : indexOf, splitLines, strip;

/// Default file name for the stored settings.
enum string settingsFileName = "aurora-video-recorder.ini";

/// Path of the settings file in `folder` (the executable's directory).
string settingsPath(string folder)
{
    return folder.length > 0 ? buildPath(folder, settingsFileName) : "";
}

/// Settings saved on disk, as stored. Absent keys keep their defaults.
struct StoredSettings
{
    RecorderOptions options;
    HotkeyChord hotkey;
    bool hasHotkey;
}

/**
 * Render settings as `key=value` lines. The hotkey is written as its display
 * text (`Ctrl+Shift+R`) so the file stays hand-editable.
 */
string serializeSettings(const ref RecorderOptions options, HotkeyChord hotkey)
{
    string text;
    text ~= format("capture=%s\n", options.target == CaptureTarget.primaryMonitor ?
        "primary" : "all");
    text ~= format("fps=%d\n", options.fps);
    text ~= format("quality=%d\n", options.quality);
    text ~= format("cursor=%s\n", options.drawCursor ? "on" : "off");
    text ~= format("folder=%s\n", options.outputFolder);
    text ~= format("hotkey=%s\n", hotkey.valid() ? hotkeyToText(hotkey) : "");
    return text;
}

/**
 * Parse stored settings, starting from `defaults`. Unreadable or invalid
 * values are ignored individually, so a hand-edited file never blocks startup.
 */
StoredSettings parseSettings(string text, RecorderOptions defaults)
{
    StoredSettings stored;
    stored.options = defaults;

    foreach (line; splitLines(text))
    {
        const trimmed = strip(line);
        if (trimmed.length == 0 || trimmed[0] == '#' || trimmed[0] == ';')
            continue;
        const separator = indexOf(trimmed, "=");
        if (separator <= 0) continue;
        const key = strip(trimmed[0 .. separator]);
        const value = strip(trimmed[separator + 1 .. $]);

        if (key == "capture")
        {
            if (value == "primary")
                stored.options.target = CaptureTarget.primaryMonitor;
            else if (value == "all")
                stored.options.target = CaptureTarget.wholeScreen;
        }
        else if (key == "fps")
        {
            import std.conv : to;
            try stored.options.fps = nearestPreset(value.to!int, frameRatePresets);
            catch (Exception) {}
        }
        else if (key == "quality")
        {
            import std.conv : to;
            try stored.options.quality =
                nearestPreset(value.to!int, qualityPresets);
            catch (Exception) {}
        }
        else if (key == "cursor")
        {
            if (value == "on") stored.options.drawCursor = true;
            else if (value == "off") stored.options.drawCursor = false;
        }
        else if (key == "folder" && value.length > 0)
        {
            stored.options.outputFolder = value;
        }
        else if (key == "hotkey")
        {
            stored.hasHotkey = true;
            // An empty value means the user disabled the hotkey.
            stored.hotkey = value.length > 0 ? chordFromText(value) :
                HotkeyChord.init;
        }
    }
    return stored;
}

/// Read the settings file; `exists`-less or unreadable files give `defaults`.
StoredSettings loadSettings(string path, RecorderOptions defaults)
{
    StoredSettings stored;
    stored.options = defaults;
    if (path.length == 0 || !exists(path)) return stored;
    try
        return parseSettings(readText(path), defaults);
    catch (Exception)
        return stored;
}

/// Write the settings file; false when it could not be written.
bool saveSettings(string path, const ref RecorderOptions options,
    HotkeyChord hotkey)
{
    if (path.length == 0) return false;
    try
    {
        write(path, serializeSettings(options, hotkey));
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

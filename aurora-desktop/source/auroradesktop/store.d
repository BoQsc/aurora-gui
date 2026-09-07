module auroradesktop.store;

import std.file : exists, readText, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : File;
import std.path : baseName, dirName, buildPath;

/**
 * Persistent desktop session state, saved as JSON next to the working
 * directory (`desktop_state.json`). The shell owns everything here: window
 * bounds/minimized/maximized, desktop icon labels + positions, and the
 * taskbar pinned-task order and titles. It does NOT require any registry or
 * platform dependency, and it is written atomically (tmp + rename) so a crash
 * mid-save cannot truncate the previous state.
 */
struct DesktopState
{
    int schema = 1;
    WindowState[] windows;
    IconState[] icons;
    TaskState[] pinnedTasks;
    bool taskbarModernShell = true;
    bool hideSystemCursor = true;
}

/// A window's geometry + visibility so it can be restored across sessions.
struct WindowState
{
    string title;
    int x, y, width, height;
    bool maximized;
    bool minimized;
    string contentId; // correlates to which app window (notepad/system/...)
}

/// A desktop icon's label + grid position.
struct IconState
{
    string label;
    int x, y;
}

/// A pinned taskbar entry (command or window), in display order.
struct TaskState
{
    string title;
    string iconName;
    string kind; // "window" or "command"
}

private string statePath()
{
    // Next to the working directory (like aurora-desktop.ini).
    return "desktop_state.json";
}

// ---------------------------------------------------------------------------
// IconKind <-> string helpers for JSON. IconKind is a ubyte enum with no
// toString/fromString, so map a stable name here.
// ---------------------------------------------------------------------------

import aurora.icons : IconKind;

IconKind iconKindFromName(string name)
{
    switch (name)
    {
        case "file": return IconKind.file;
        case "folder": return IconKind.folder;
        case "home": return IconKind.home;
        case "computer": return IconKind.computer;
        case "notepad": return IconKind.notepad;
        case "trash": return IconKind.trash;
        case "save": return IconKind.save;
        case "open": return IconKind.open;
        case "newDocument": return IconKind.newDocument;
        case "up": return IconKind.up;
        case "refresh": return IconKind.refresh;
        case "search": return IconKind.search;
        case "start": return IconKind.start;
        case "close": return IconKind.close;
        case "minimize": return IconKind.minimize;
        case "maximize": return IconKind.maximize;
        case "clock": return IconKind.clock;
        case "settings": return IconKind.settings;
        case "terminal": return IconKind.terminal;
        case "image": return IconKind.image;
        case "music": return IconKind.music;
        case "drive": return IconKind.drive;
        case "chevronRight": return IconKind.chevronRight;
        case "chevronDown": return IconKind.chevronDown;
        case "chevronUp": return IconKind.chevronUp;
        case "wifi": return IconKind.wifi;
        case "volume": return IconKind.volume;
        case "volumeMuted": return IconKind.volumeMuted;
        case "battery": return IconKind.battery;
        case "batteryCharging": return IconKind.batteryCharging;
        case "power": return IconKind.power;
        default: return IconKind.none;
    }
}

string iconKindName(IconKind kind)
{
    final switch (kind)
    {
        case IconKind.file: return "file";
        case IconKind.folder: return "folder";
        case IconKind.home: return "home";
        case IconKind.computer: return "computer";
        case IconKind.notepad: return "notepad";
        case IconKind.trash: return "trash";
        case IconKind.save: return "save";
        case IconKind.open: return "open";
        case IconKind.newDocument: return "newDocument";
        case IconKind.up: return "up";
        case IconKind.refresh: return "refresh";
        case IconKind.search: return "search";
        case IconKind.start: return "start";
        case IconKind.close: return "close";
        case IconKind.minimize: return "minimize";
        case IconKind.maximize: return "maximize";
        case IconKind.clock: return "clock";
        case IconKind.settings: return "settings";
        case IconKind.terminal: return "terminal";
        case IconKind.image: return "image";
        case IconKind.music: return "music";
        case IconKind.drive: return "drive";
        case IconKind.chevronRight: return "chevronRight";
        case IconKind.chevronDown: return "chevronDown";
        case IconKind.chevronUp: return "chevronUp";
        case IconKind.wifi: return "wifi";
        case IconKind.volume: return "volume";
        case IconKind.volumeMuted: return "volumeMuted";
        case IconKind.battery: return "battery";
        case IconKind.batteryCharging: return "batteryCharging";
        case IconKind.power: return "power";
        case IconKind.none: return "none";
    }
}

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

void saveDesktopState(const ref DesktopState state) nothrow
{
    try
    {
        JSONValue root;
        root["schema"] = state.schema;
        root["taskbarModernShell"] = state.taskbarModernShell;
        root["hideSystemCursor"] = state.hideSystemCursor;

        JSONValue[] winArray;
        foreach (w; state.windows)
        {
            JSONValue v;
            v["title"] = w.title;
            v["x"] = w.x;
            v["y"] = w.y;
            v["width"] = w.width;
            v["height"] = w.height;
            v["maximized"] = w.maximized;
            v["minimized"] = w.minimized;
            v["contentId"] = w.contentId;
            winArray ~= v;
        }
        root["windows"] = JSONValue(winArray);

        JSONValue[] iconArray;
        foreach (i; state.icons)
        {
            JSONValue v;
            v["label"] = i.label;
            v["x"] = i.x;
            v["y"] = i.y;
            iconArray ~= v;
        }
        root["icons"] = JSONValue(iconArray);

        JSONValue[] taskArray;
        foreach (t; state.pinnedTasks)
        {
            JSONValue v;
            v["title"] = t.title;
            v["icon"] = t.iconName;
            v["kind"] = t.kind;
            taskArray ~= v;
        }
        root["pinnedTasks"] = JSONValue(taskArray);

        const path = statePath();
        const tmp = path ~ ".tmp";
        write(tmp, root.toPrettyString() ~ "\n");
        // Atomic replace: rename over dest on the same volume.
        if (exists(path))
            rename(path, path ~ ".bak");
        rename(tmp, path);
    }
    catch (Exception e)
    {
        try
        {
            write("desktop_state.err", e.msg);
        }
        catch (Exception)
        {
        }
    }
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

DesktopState loadDesktopState() nothrow
{
    DesktopState result;
    try
    {
        if (!exists(statePath()))
            return result;
        auto root = parseJSON(readText(statePath()));
        if (root.type != JSONType.object)
            return result;
        if (key(root, "schema").type == JSONType.integer)
            result.schema = cast(int) key(root, "schema").integer;
        auto kv = key(root, "taskbarModernShell");
        result.taskbarModernShell = kv.type == JSONType.true_ ? true :
            kv.type == JSONType.false_ ? false :
            kv.type == JSONType.integer ? kv.integer != 0 : true;
        kv = key(root, "hideSystemCursor");
        result.hideSystemCursor = kv.type == JSONType.true_ ? true :
            kv.type == JSONType.false_ ? false :
            kv.type == JSONType.integer ? kv.integer != 0 : true;

        auto wins = arr(root, "windows");
        foreach (v; wins)
        {
            if (v.type != JSONType.object) continue;
            WindowState w;
            w.title = str(v, "title");
            w.x = intOf(v, "x");
            w.y = intOf(v, "y");
            w.width = intOf(v, "width");
            w.height = intOf(v, "height");
            w.maximized = boolOf(v, "maximized");
            w.minimized = boolOf(v, "minimized");
            w.contentId = str(v, "contentId");
            result.windows ~= w;
        }

        auto icons = arr(root, "icons");
        foreach (v; icons)
        {
            if (v.type != JSONType.object) continue;
            IconState i;
            i.label = str(v, "label");
            i.x = intOf(v, "x");
            i.y = intOf(v, "y");
            result.icons ~= i;
        }

        auto tasks = arr(root, "pinnedTasks");
        foreach (v; tasks)
        {
            if (v.type != JSONType.object) continue;
            TaskState t;
            t.title = str(v, "title");
            t.iconName = str(v, "icon");
            t.kind = str(v, "kind");
            result.pinnedTasks ~= t;
        }
    }
    catch (Exception)
    {
    }
    return result;
}

// ---------------------------------------------------------------------------
// JSON accessor helpers (type-safe defaults).
// ---------------------------------------------------------------------------

private JSONValue key(const ref JSONValue object, string name)
{
    if (object.type != JSONType.object) return JSONValue(null);
    return name in object ? object[name] : JSONValue(null);
}

private JSONValue[] arr(const ref JSONValue object, string name)
{
    auto value = key(object, name);
    return value.type == JSONType.array ? value.array : null;
}

private string str(const ref JSONValue object, string name)
{
    auto value = key(object, name);
    return value.type == JSONType.string ? value.str : "";
}

private int intOf(const ref JSONValue object, string name)
{
    auto value = key(object, name);
    return value.type == JSONType.integer ? cast(int) value.integer : 0;
}

private bool boolOf(const ref JSONValue object, string name)
{
    auto value = key(object, name);
    return value.type == JSONType.true_ ? true :
        value.type == JSONType.false_ ? false :
        value.type == JSONType.integer ? value.integer != 0 : false;
}

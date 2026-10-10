module aurorarustdesk.settings;

import aurorarustdesk.identity : identityFolder;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.string : indexOf, splitLines, strip;

enum AccessPermission : uint
{
    view = 1,
    input = 2,
    files = 4,
    clipboard = 8,
    all = view | input | files | clipboard
}

struct RustDeskSettings
{
    string serverHost = "127.0.0.1";
    ushort serverPort = 21_116;
    bool useRelay;
    ushort directPort = 21_118;
    bool permanentPassword;
    uint permissions = AccessPermission.all;
    bool keepRunningInTray = true;
}

private string settingsPath()
{
    return buildPath(identityFolder(), "settings.conf");
}

RustDeskSettings loadSettings()
{
    RustDeskSettings result;
    if (!exists(settingsPath())) return result;
    foreach (rawLine; readText(settingsPath()).splitLines())
    {
        const line = strip(rawLine);
        const separator = line.indexOf('=');
        if (separator <= 0) continue;
        const key = line[0 .. separator];
        const value = line[separator + 1 .. $];
        try
        {
            switch (key)
            {
                case "server_host": result.serverHost = value; break;
                case "server_port": result.serverPort = to!ushort(value); break;
                case "use_relay": result.useRelay = value == "1"; break;
                case "direct_port": result.directPort = to!ushort(value); break;
                case "permanent_password": result.permanentPassword = value == "1"; break;
                case "permissions": result.permissions = to!uint(value); break;
                case "keep_tray": result.keepRunningInTray = value != "0"; break;
                default: break;
            }
        }
        catch (Exception) {}
    }
    result.permissions &= cast(uint) AccessPermission.all;
    result.permissions |= AccessPermission.view;
    return result;
}

void saveSettings(const RustDeskSettings value)
{
    mkdirRecurse(identityFolder());
    const text = "server_host=" ~ value.serverHost ~ "\n" ~
        "server_port=" ~ to!string(value.serverPort) ~ "\n" ~
        "use_relay=" ~ (value.useRelay ? "1" : "0") ~ "\n" ~
        "direct_port=" ~ to!string(value.directPort) ~ "\n" ~
        "permanent_password=" ~ (value.permanentPassword ? "1" : "0") ~ "\n" ~
        "permissions=" ~ to!string(value.permissions) ~ "\n" ~
        "keep_tray=" ~ (value.keepRunningInTray ? "1" : "0") ~ "\n";
    write(settingsPath(), text);
}

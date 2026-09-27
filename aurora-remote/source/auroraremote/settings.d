module auroraremote.settings;

import auroraremote.capsule : AccessPermission;
import auroraremote.identity : identityFolder;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.string : indexOf, splitLines, strip;

struct RemoteSettings
{
    string directHost;
    ushort directPort = 47_831;
    bool useRelay;
    string relayHost;
    ushort relayPort = 47_832;
    bool unattended;
    uint permissions = AccessPermission.all;
    bool keepRunningInTray = true;
}

private string settingsPath()
{
    return buildPath(identityFolder(), "settings.conf");
}

RemoteSettings loadSettings()
{
    RemoteSettings result;
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
                case "direct_host": result.directHost = value; break;
                case "direct_port": result.directPort = to!ushort(value); break;
                case "use_relay": result.useRelay = value == "1"; break;
                case "relay_host": result.relayHost = value; break;
                case "relay_port": result.relayPort = to!ushort(value); break;
                case "unattended": result.unattended = value == "1"; break;
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

void saveSettings(const RemoteSettings value)
{
    mkdirRecurse(identityFolder());
    const text = "direct_host=" ~ value.directHost ~ "\n" ~
        "direct_port=" ~ to!string(value.directPort) ~ "\n" ~
        "use_relay=" ~ (value.useRelay ? "1" : "0") ~ "\n" ~
        "relay_host=" ~ value.relayHost ~ "\n" ~
        "relay_port=" ~ to!string(value.relayPort) ~ "\n" ~
        "unattended=" ~ (value.unattended ? "1" : "0") ~ "\n" ~
        "permissions=" ~ to!string(value.permissions) ~ "\n" ~
        "keep_tray=" ~ (value.keepRunningInTray ? "1" : "0") ~ "\n";
    write(settingsPath(), text);
}

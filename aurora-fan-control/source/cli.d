module cli;

// Command-line front end. See fan-control.ps1's behaviour, ported to D.

import std.stdio : writeln, writefln, stderr;
import std.conv : to;
import std.algorithm : canFind, filter;
import std.array : array;
import std.datetime : Clock;
import std.format : format;
import std.utf : toUTF16z;

import core.sys.windows.windef;
import core.sys.windows.winnt;
import core.sys.windows.winbase : GetModuleFileNameW, Sleep;

import wmi;

private string exePath()
{
    wchar[1024] buf;
    DWORD n = GetModuleFileNameW(null, buf.ptr, cast(DWORD)buf.length);
    if (n == 0) return "";
    return buf[0 .. n].to!string;
}

private bool ensureElevated(string[] args)
{
    // Re-launch this executable with the "runas" verb (UAC prompt), forwarding args.
    string exe = exePath();
    string argLine;
    foreach (a; args[1 .. $])
    {
        if (a.length) argLine ~= " ";
        argLine ~= a;
    }
    argLine ~= " --elevated";
    auto r = ShellExecuteW(null, "runas"w.ptr, exe.toUTF16z, argLine.toUTF16z, null, 1 /*SW_SHOWNORMAL*/);
    return cast(size_t)r > 32;
}

int usage()
{
    writeln("Usage: fanctl <command> [options]");
    writeln();
    writeln("Commands:");
    writeln("  status              Show fan count, speeds, cooling state, temps (default)");
    writeln("  monitor [sec] [n]   Print temps/speeds every <sec> seconds, <n> times (0 = forever)");
    writeln("  cooling on|off      Extreme cooling: force fans to max, or return to auto");
    writeln("  thermal [id]        Show (no id) or select the thermal table id (try 1..3)");
    writeln("  default             Restore defaults (cooling auto, thermal table 0)");
    writeln();
    writeln("Options:");
    writeln("  --no-elevate        Do not request Administrator rights (reads will fail)");
    return 1;
}

int runCli(string[] args)
{
    string[] rest = args.length > 1 ? args[1 .. $] : [];
    bool noElevate = rest.canFind("--no-elevate");
    bool alreadyElevated = rest.canFind("--elevated");
    rest = rest.filter!(a => a != "--no-elevate" && a != "--elevated").array;

    string action = rest.length ? rest[0] : (args.length > 1 ? "status" : "");
    if (action == "" || action == "-h" || action == "--help")
        return usage();
    // Validate before touching WMI, so a typo prints usage instead of a UAC prompt.
    if (action != "status" && action != "monitor" && action != "cooling" && action != "thermal" && action != "default")
        return usage();

    // Verify we can reach the interface; if not, offer to elevate.
    // Ask for Administrator rights up front; root\WMI needs them.
    if (!noElevate && !alreadyElevated && !isElevated())
    {
        writeln("Requesting Administrator rights (UAC)...");
        if (ensureElevated(args)) return 0;
    }

    string err;
    if (!tryOpen(err))
    {
        stderr.writefln("ERROR: %s", err);
        return 1;
    }

    try
    {
        auto dev = new FanDevice();

        switch (action)
        {
            case "status":
                printStatus(dev);
                break;

            case "monitor":
            {
                int sec  = rest.length > 1 ? to!int(rest[1]) : 2;
                int n    = rest.length > 2 ? to!int(rest[2]) : 0;
                int i = 0;
                while (true)
                {
                    auto t = dev.telemetry();
                    writefln("[%s] CPU %d C  GPU %d C  Fan1 %d RPM  Fan2 %d RPM  cooling %s",
                        Clock.currTime().toLocalTime().toSimpleString()[11 .. 19],
                        t.cpuTemp, t.gpuTemp, t.fan1Speed, t.fan2Speed, coolingText(t.coolingStatus));
                    i++;
                    if (n > 0 && i >= n) break;
                    Sleep(cast(uint)(sec * 1000));
                }
                break;
            }

            case "cooling":
            {
                if (rest.length < 2 || (rest[1] != "on" && rest[1] != "off"))
                    return usage();
                dev.setCooling(rest[1] == "on");
                writeln("Cooling boost set to ", rest[1], "  ->  now ", coolingText(dev.read("GetFanCoolingStatus")));
                break;
            }

            case "thermal":
            {
                if (rest.length < 2)
                {
                    writeln("Current thermal table: ", dev.read("GetThermalTableID"));
                    break;
                }
                uint id = to!uint(rest[1]);
                dev.setThermalTable(id);
                writeln("Thermal table set to ", id, "  ->  now ", dev.read("GetThermalTableID"));
                break;
            }

            case "default":
                dev.setCooling(false);
                dev.setThermalTable(0);
                writeln("Restored defaults: cooling auto, thermal table 0");
                break;

            default:
                return usage();
        }
    }
    catch (Exception e)
    {
        stderr.writefln("ERROR: %s", e.msg);
        return 1;
    }

    return 0;
}

void printStatus(FanDevice dev)
{
    auto t = dev.telemetry();
    writeln("Class          : LENOVO_GAMEZONE_DATA");
    writeln("Fan count      : ", t.fanCount);
    writeln("Fan 1 speed    : ", t.fan1Speed, " RPM");
    writeln("Fan 2 speed    : ", t.fan2Speed, " RPM");
    writeln("Fan max speed  : ", t.fanMaxSpeed, " RPM");
    writeln("Cooling boost  : ", coolingText(t.coolingStatus), "   supported=", t.coolingSupported);
    writeln("Thermal table  : ", t.thermalTable);
    writeln("CPU temp       : ", t.cpuTemp, " C");
    writeln("GPU temp       : ", t.gpuTemp, " C");
}

int main(string[] args)
{
    return runCli(args);
}

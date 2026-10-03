module wmi;

// Fan access for Lenovo Legion laptops via the "Game Zone" ACPI/WMI interface
// (root\WMI : LENOVO_GAMEZONE_DATA).
//
// The WBEM COM calls live in a small C shim (shim/wmi_shim.c) compiled into
// wmi_shim.dll with MinGW-w64, which ships the real wbemcli.h. Hand-declaring
// the IWbem* interfaces in D did not match this machine's WMI proxy vtable, so
// the SDK header is used instead. This module just loads the DLL and calls it.
//
// Administrator rights are required (root\WMI denies a non-elevated process).

version (Windows):

import core.sys.windows.windef;
import core.sys.windows.winnt;
import core.sys.windows.winbase : LoadLibraryW, FreeLibrary, GetProcAddress;

import std.conv : to;
import std.format : format;
import std.utf : toUTF16z;

// ShellExecuteW for the UAC re-launch (declared here; not in druntime).
pragma(lib, "shell32");
extern (Windows) HINSTANCE ShellExecuteW(HWND, const(wchar)*, const(wchar)*, const(wchar)*, const(wchar)*, int);

// Token-elevation check (advapi32/kernel32; not in druntime).
pragma(lib, "advapi32");
extern (Windows) BOOL OpenProcessToken(HANDLE, DWORD, HANDLE*);
extern (Windows) BOOL GetTokenInformation(HANDLE, int, void*, DWORD, DWORD*);
extern (Windows) BOOL CloseHandle(HANDLE);
extern (Windows) HANDLE GetCurrentProcess();

bool isElevated()
{
    HANDLE tok = null;
    if (!OpenProcessToken(GetCurrentProcess(), 0x0008 /*TOKEN_QUERY*/, &tok))
        return false;
    DWORD elev = 0;
    DWORD ret = 0;
    BOOL ok = GetTokenInformation(tok, 20 /*TokenElevation*/, &elev, DWORD.sizeof, &ret);
    CloseHandle(tok);
    return ok != 0 && elev != 0;
}

private alias FcOpen  = extern (C) int  function(void**);
private alias FcClose = extern (C) void function(void*);
private alias FcRead  = extern (C) int  function(void*, const(wchar)*, uint*);
private alias FcWrite = extern (C) int  function(void*, const(wchar)*, uint);

class WmiException : Exception
{
    int hr;
    this(string msg, int hr = 0, string file = __FILE__, size_t line = __LINE__)
    {
        this.hr = hr;
        super(msg, file, line);
    }
}

struct FanTelemetry
{
    uint fanCount;
    uint fan1Speed;
    uint fan2Speed;
    uint fanMaxSpeed;
    uint coolingSupported;
    uint coolingStatus;
    uint thermalTable;
    uint cpuTemp;
    uint gpuTemp;
}

string coolingText(uint status)
{
    switch (status)
    {
        case 1:  return "ON  (max fan)";
        case 0:  return "off (auto)";
        default: return format("unknown (%d)", status);
    }
}

final class FanDevice
{
    private HMODULE dll;
    private void* dev;
    private FcOpen  fcOpen;
    private FcClose fcClose;
    private FcRead  fcRead;
    private FcWrite fcWrite;

    this()
    {
        dll = LoadLibraryW("wmi_shim.dll"w.ptr);
        if (dll is null)
            throw new WmiException("cannot load wmi_shim.dll (keep it next to the executable)");

        fcOpen  = cast(FcOpen)  GetProcAddress(dll, "fc_open");
        fcClose = cast(FcClose) GetProcAddress(dll, "fc_close");
        fcRead  = cast(FcRead)  GetProcAddress(dll, "fc_read");
        fcWrite = cast(FcWrite) GetProcAddress(dll, "fc_write");
        if (fcOpen is null || fcClose is null || fcRead is null || fcWrite is null)
        {
            FreeLibrary(dll);
            dll = null;
            throw new WmiException("wmi_shim.dll is missing an export");
        }

        int hr = fcOpen(&dev);
        if (hr != 0)
        {
            FreeLibrary(dll);
            dll = null;
            throw new WmiException(format("opening root\\WMI failed: 0x%08X", cast(uint)hr), hr);
        }
    }

    ~this()
    {
        if (dev) fcClose(dev);
        if (dll) FreeLibrary(dll);
    }

    uint read(string method)
    {
        uint value;
        int hr = fcRead(dev, toUTF16z(method), &value);
        if (hr != 0)
            throw new WmiException(format("reading %s failed: 0x%08X", method, cast(uint)hr), hr);
        return value;
    }

    void write(string method, uint value)
    {
        int hr = fcWrite(dev, toUTF16z(method), value);
        if (hr != 0)
            throw new WmiException(format("calling %s failed: 0x%08X", method, cast(uint)hr), hr);
    }

    FanTelemetry telemetry()
    {
        FanTelemetry t;
        t.fanCount         = read("GetFanCount");
        t.fan1Speed        = read("GetFan1Speed");
        t.fan2Speed        = read("GetFan2Speed");
        t.fanMaxSpeed      = read("GetFanMaxSpeed");
        t.coolingSupported = read("IsSupportFanCooling");
        t.coolingStatus    = read("GetFanCoolingStatus");
        t.thermalTable     = read("GetThermalTableID");
        t.cpuTemp          = read("GetCPUTemp");
        t.gpuTemp          = read("GetGPUTemp");
        return t;
    }

    void setCooling(bool on)      { write("SetFanCooling", on ? 1 : 0); }
    void setThermalTable(uint id) { write("SetThermalTableID", id); }
}

bool tryOpen(out string error)
{
    try
    {
        auto dev = new FanDevice();
        return true;
    }
    catch (Exception e)
    {
        error = e.msg;
        return false;
    }
}

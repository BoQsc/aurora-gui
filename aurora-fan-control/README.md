# aurora-fan-control

Manual fan control for Lenovo Legion laptops on Windows, written in **D**, talking
to the Lenovo "Game Zone" ACPI/WMI interface (`root\WMI : LENOVO_GAMEZONE_DATA`)
— the same interface Lenovo Nerve Center / Vantage uses. No kernel driver.

Developed and verified against a **Lenovo Legion Y520-15IKBM** (system model 80YY,
Insyde BIOS 5XCN26WW, EC 1.26).

## Layout

```
dub.json            two build configurations: cli and gui
source/wmi.d        loads wmi_shim.dll and exposes FanDevice (telemetry + setters)
source/cli.d        command-line front end   -> fanctl.exe
source/gui.d        Win32 front end          -> fan-control-gui.exe
shim/wmi_shim.c     C wrapper over the real WBEM interfaces (wbemcli.h)
shim/build.bat      builds wmi_shim.dll with MinGW-w64
wmi_shim.dll        the built shim (must sit next to the executables)
```

## Why a C shim

druntime has no WBEM bindings. Hand-declaring the `IWbem*` interfaces in D did
not match this machine's WMI proxy vtable, so the shim is compiled against the
real `wbemcli.h` (shipped with MinGW-w64) and loaded at runtime. It is the only
C in the project; the applications are D.

## Build

Requires DMD (or LDC), DUB, and MinGW-w64 gcc.

```
shim\build.bat                 # -> wmi_shim.dll   (edit the GCC path if needed)
dub build --config=cli         # -> fanctl.exe
dub build --config=gui         # -> fan-control-gui.exe
```

MinGW `gcc` used here: `C:\SysGCC\mingw64\bin\gcc.exe`.
Links `ole32`, `oleaut32`, `wbemuuid` (shim) and `shell32`, `advapi32` (D).

## Run

Both front ends request Administrator rights automatically (UAC); `root\WMI`
denies access otherwise.

```
fanctl.exe status                 # fan count, speeds, cooling state, thermal table, temps
fanctl.exe monitor 2 0            # every 2 s, forever
fanctl.exe cooling on             # force fans to max (extreme cooling)
fanctl.exe cooling off            # back to automatic
fanctl.exe thermal                # show current thermal table id
fanctl.exe thermal 1              # select thermal table
fanctl.exe default                # restore defaults (cooling auto, thermal table 0)

fan-control-gui.exe               # windowed UI (live readout + buttons)
fan-control-gui.exe --selftest out.bmp   # render offscreen to a BMP and exit
```

The GUI has **Cooling ON / Cooling OFF**, a **Thermal [1..3] + Apply** selector,
and a **Restore Defaults** button (cooling auto + thermal table 0).

`--no-elevate` skips the UAC request (reads then fail); `--elevated` marks an
already-elevated re-launch.

## How it works (shim)

`LENOVO_GAMEZONE_DATA` methods return their result in a `Data` parameter.
Sequence: `CoCreateInstance(CLSID_WbemLocator)` → `ConnectServer("ROOT\\WMI")` →
**`CoSetProxyBlanket`** (without it every call fails access-denied, even
elevated) → `GetObject` the class → `GetMethod` → `SpawnInstance` (from the
out-signature when the method has no in-params) → `Put("Data")` for setters →
`ExecMethod`. Methods are invoked on the class path, and if that is refused, on
the instance path (`LENOVO_GAMEZONE_DATA.InstanceName="ACPI\\PNP0C14\\GMZN_0"`).
`GetObject`/`ExecMethod` take real BSTRs, so arguments are `SysAllocString`ed.

## Scope and limits

The Y520 has no arbitrary per-fan RPM targets. "Manual control" means the
extreme-cooling boost on/off plus the firmware thermal table, plus monitoring.
Extreme cooling runs the fans at full speed; use it briefly. `GetCPUTemp`/
`GetGPUTemp` return 0 on this model (the firmware does not populate them).

## Status / verification

- Shim + both configs build (DMD 2.112, MinGW-w64 gcc 13.1).
- **Live read works (elevated):** `fanctl status` returns Fan count 2,
  Fan 1 3400 RPM, Fan 2 ~3000 RPM, max 3400 RPM, cooling supported, thermal 0.
- **Live write works (elevated):** `fanctl cooling off` calls `SetFanCooling`
  and reads back the new state.
- Non-elevated `fanctl status` prints "Requesting Administrator rights (UAC)..."
  and re-launches elevated; the GUI does the same.
- GUI `--selftest` renders the window to a BMP (layout verified).

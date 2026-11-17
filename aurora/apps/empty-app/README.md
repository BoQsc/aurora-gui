# Empty App

A D-only live app core. The application runtime stays alive while the D logic
DLL is rebuilt and reloaded; the host window and runtime process do not restart.

## Pieces

- `runtime.d` — stable D runtime. It owns the surface, loads a D logic DLL, and
  polls a reload signal. It never exits on a logic edit.
- `logic.d` — betterC D DLL. Exports
  `aurora_logic_frame(ubyte* pixels, int width, int height, int build)`.
- `live_reload_test.py` — project verification. It builds the runtime and a
  second logic DLL, signals the running runtime, and checks that the host/runtime
  PIDs stay fixed while the frame changes.

## Build and verify

From the repository root:

```text
python -B apps/empty-app/live_reload_test.py
```

The DLL build command is:

```text
dmd -betterC -shared -L/NOENTRY -L/EXPORT:aurora_logic_frame -of=logic-1.dll logic.d
```

The runtime loads the DLL with `LoadLibraryA`; the next DLL is loaded in the
same process. Old DLLs stay loaded for the life of the dev runtime.

## Next

Edit `logic.d` to change the frame. A D dev driver can watch the source, build a
new DLL, and write the reload signal; the host and runtime stay up.

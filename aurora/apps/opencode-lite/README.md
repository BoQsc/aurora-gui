# Aurora OpenCode Lite

A small, independent OpenCode client built from the Aurora v2 host core.

## Architecture

The standard GUI belongs to `aurora-host-core`, not this app:

- the host scene defines the title, layout, fields, buttons, status, and
  transcript;
- the host runtime owns the window, scene application, live reload, and input;
- the app controller owns only chat/session/settings/network policy and updates
  host scene nodes by id.

The final product is one zero-CRT EXE with an embedded default scene. On first
launch it materializes that scene at
`%LOCALAPPDATA%\AuroraOpenCodeLite\lite.scene.json` and watches it, so the
default portable launch is live-editable. Delete the file to restore the
embedded default. Pass `--scene <file>` to use another live scene. The
controller survives reloads, so an in-flight stream and its transcript survive
too.

The old direct-window `source/app.d`/`LiteShell` path remains only as the
explicit `direct-prototype` configuration. It is not the default and is not a
template for future apps.

## Live-first development

Keep the standalone host running. While it is open:

```bat
python verify.py
```

This automatically selects the live check: it rebuilds the controller DLL and
validates the scene, but never rebuilds the locked standalone EXE or restarts
the host. The default is intentionally live-first.

The full gate is opt-in and requires the host to be stopped at an explicit
restart point:

```bat
python verify.py --full
```

Running `--full` while the host is open is refused. `tools/build_standalone.py`
also refuses to rebuild while the standalone is running. Do not kill or
relaunch the host just to apply scene/controller changes.

## Live code development

For controller-code iteration, run the host without its embedded controller:

```bat
build\aurora-opencode-lite-host.exe --external-controller --listen 8791
```

Then build and attach the separately restartable controller:

```bat
dub build --config=controller --compiler=dmd
build\aurora-opencode-lite-controller.exe --port 8791
```

The controller talks to the host over its TCP control channel. Edit, rebuild,
and restart the controller without closing the host window. The host PID and
scene stay alive. The production standalone keeps the embedded controller; the
external controller is the live-code development path.

This external-controller path is the safe isolation boundary. A controller
process can crash, hang, or hit a native access violation without taking down
the host window; restart it and reconnect.

For in-process controller reloads, build the optional controller DLL:

```bat
dub build --config=plugin --compiler=dmd
```

The host automatically loads `opencode-lite-controller.dll` from beside the EXE
and watches it. Pass `--plugin <dll>` to select another path, or `--no-plugin`
to disable in-process loading. Replacing the DLL reinitializes the controller
without closing the host. The standalone EXE still contains the embedded
controller when no plugin is present.

In-process plugins are **not** process-isolated. A native access violation or
a deliberately blocking plugin can still affect the host process. Use the
external controller when process isolation is required.

## Dependency boundary

- Standard GUI and scene runtime: `aurora-host-core`;
- framework: `aurora-d` and `aurora-standard`;
- single-file runtime: `aurora-exp-win32-crt` and `aurora-exp-coff`;
- OS network API: WinHTTP.

No parent application code, `vendor/` framework copy, or
`aurora-opencode-core` is used. The app never depends on the `aurora-host`
CLI package; it depends on `aurora-host-core`.

If a needed feature is generic, add it to host-core with tests. Do not recreate
it as app-specific GUI code.

## Build

Primary host-scene build:

```bat
dub build --config=host-lite --compiler=dmd
```

Standalone release:

```bat
python -B tools/build_standalone.py
```

Output: `build/aurora-opencode-lite-standalone.exe`.

## Verify

```bat
python -B verify.py
```

The gate builds the host-scene app, runs HTTP cancellation, mock conversation,
settings round-trip, and live scene reload with an in-flight stream; then it
builds the standalone EXE and checks OS-only imports, subsystem, icon, size, and
startup.

Latest measured release result:

- size: `5,153,891` bytes;
- imports: `advapi32`, `avrt`, `gdi32`, `kernel32`, `ole32`, `shell32`,
  `user32`, `winhttp`, `winmm`, `ws2_32`;
- PE subsystem: `2` (WINDOWS);
- embedded icon: `1`;
- warm startup: median `115.0 ms`.

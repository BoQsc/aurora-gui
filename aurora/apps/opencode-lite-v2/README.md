# Aurora OpenCode Lite V2

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
`%LOCALAPPDATA%\AuroraOpenCodeLiteV2\lite.scene.json` and watches it, so the
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

### Live-development rule

During development, never call `Stop-Process` on a healthy host to apply a
scene, controller, or policy change. A stopped host that is launched again is a
new process and a new window; that is the duplicate-window/closed-window
workflow failure.

- Scene changes: use live reload.
- Controller changes: rebuild the controller and restart only the controller.
- Verification: use `verify.py --live`.
- Host-core changes: use one explicitly announced, controlled relaunch. Do not
  quietly replace the live window.
- Tests that need separate hosts: use a distinct `--instance-group`,
  `--no-activate`, and `--start-minimized`; never the production instance group.

## Live code development

For controller-code iteration, run the host without its embedded controller:

```bat
build\aurora-opencode-lite-v2-host.exe --external-controller --listen 8792
```

Then build and attach the separately restartable controller:

```bat
dub build --config=controller --compiler=dmd
build\aurora-opencode-lite-v2-controller.exe --port 8792
```

The controller talks to the host over its TCP control channel. Edit, rebuild,
and restart the controller without closing the host window. The host PID and
scene stay alive.

Pressing Enter in the message field submits it through the same `send` action
as the Send button; it does not insert a newline.

## Command-line host control

`aurora-opencode-lite-v2-cli.exe` connects to the running host and requires no
cursor, focus, restore, or visible window:

```bat
build\aurora-opencode-lite-v2-cli.exe --port 8792 list
build\aurora-opencode-lite-v2-cli.exe --port 8792 get lite-input
build\aurora-opencode-lite-v2-cli.exe --port 8792 set lite-input "hello"
build\aurora-opencode-lite-v2-cli.exe --port 8792 trigger lite-provider-openai preset-openai
```

The CLI uses the host control protocol, so it works while the app is minimized
or behind other windows. It never creates another app window.

Host-core supports optional `commandLine` menus that list active scene controls
and dispatch their actions without pointer geometry. The app does not show this
menu by default; the command-menu test injects it into a temporary test scene.

The standalone defaults to this process-isolated controller when
`aurora-opencode-lite-v2-controller.exe` is beside it. A native fault in the
controller or one of its network workers therefore leaves the host window alive.
The host can reconnect a restarted controller. In-process plugins are an
explicit `--plugin` live-development opt-in, not the production default.

The reusable supervisor lives in
`aurorahost.controller_supervisor.ControllerSupervisor` in host-core. Hostlite
supplies only the executable, port, retry limit, and logging callback. If the
controller exits, the host relaunches it without restarting the window, up to a
bounded number of consecutive exits. `--controller-port <port>` isolates
parallel test hosts and their controllers. The controller is a D executable and
is spawned with its console suppressed, so only the app window is visible.

## Single-window policy

The host is a single-window application. `hostlite` acquires
`aurorahost.single_instance.HostInstance` before creating the window. A second
launch finds the running window by title, activates it, and exits without
creating another window. Start with `--no-single-instance` only for isolated
tests.

Intentional parallel instances are explicit: give each test process a distinct
`--instance-group <name>` (for example, `--instance-group test-a` and
`--instance-group test-b`). `--allow-duplicate-instance` is the deliberate
escape hatch. The default app launch has neither and remains single-instance.

Each run writes `run-state.json` under the app's local data directory. A normal
window close records `closed`; an unexpected process exit leaves
`running`/`failed`, which the next launch reports as an unclean shutdown. This
keeps host diagnostics from disappearing with the window.

Future host apps should use the same host-core module:

```d
HostInstance instance;
if (!instance.acquire("MyApp|" ~ scene.window.title))
{
    activateWindow(scene.window.title);
    return 0;
}
```

Live development should reuse the running instance and validator checks should
use the live path. Do not repeatedly launch the standalone while iterating.

This external-controller path is the safe isolation boundary. A controller
process can crash, hang, or hit a native access violation without taking down
the host window; restart it and reconnect.

For in-process controller reloads, build the optional controller DLL:

```bat
dub build --config=plugin --compiler=dmd
```

The host automatically loads `opencode-lite-v2-controller.dll` from beside the EXE
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

Output: `build/aurora-opencode-lite-v2-standalone.exe`.

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

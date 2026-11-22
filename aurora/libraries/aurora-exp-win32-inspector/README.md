# aurora-exp-win32-inspector

A friendly GUI for the binary-format laboratory. It opens a PE image, shows
every modeled directory, verifies that a rebuild is byte-identical, emits the
minimal executable, and maps and runs that executable with the laboratory
loader.

The inspector is a separate package so `aurora-exp-win32-image` stays free of
GUI dependencies: the inspector depends on `aurora-d` and on the image library
by path.

## Window

| Region | What it shows |
|---|---|
| Toolbar | Open image, Verify rebuild, Emit minimal, Run emitted, Save report |
| Sidebar | file name, PE32/PE32+, machine, subsystem, image base, entry, size, sections, imports, exports, resources, directories, relocations, debug entries, certificates |
| Verification | PASS/FAIL for the byte-exact rebuild, with the first difference when it fails |
| Inspection | monospace, word-wrapped report: headers, sections, data directories, imports, exports, resources, relocations, debug/CodeView, certificates, delay imports, TLS, exceptions, bound imports |
| Footer | last action result |

`Open image…` uses the in-window Aurora file dialog. `Save report…` writes the
same text to a file of your choice. `Emit minimal` writes a 1,536-byte PE32+
executable to `build/inspector/minimal-hello.exe` next to the inspector
executable; `Run emitted` maps it at any base with the loader, executes its
entry point, and reports the thread exit code.

## Build and run

From this folder:

```bat
dub build --config=default --compiler=dmd
win32-inspector.exe ..\..\..\aurora\aurora-host\aurora-host.exe
```

The image argument is optional; without it, use `Open image…`. The executable
links as a Windows GUI subsystem app, so no console window appears.

## Tests

```bat
dub build --config=headless-smoke --compiler=dmd
win32-inspector-headless.exe build\smoke.ppm ..\..\..\aurora\aurora-host\aurora-host.exe

dub build --config=interaction --compiler=dmd
win32-inspector-interaction.exe ..\..\..\aurora\aurora-host\aurora-host.exe
```

- `headless-smoke` lays out the window, loads the image, paints two frames, and
  writes a PPM.
- `interaction` drives the real widget input path with `UiTestDriver`: it opens
  and dismisses the file dialog with Escape, clicks Verify and requires `PASS`,
  clicks Emit and requires a written image, and clicks Run emitted and requires
  thread exit code 0.

## Scope

The inspector is read-only for image content. Mutations that the library
supports (timestamp stamping, in-place resource replacement) remain on the
`pe-roundtrip` command line; adding them to the GUI is a later action surface,
not a missing inspection capability.

Both the inspector and its DUB dependencies carry the repository
`portable-release` build type and the 0BSD manifest license.

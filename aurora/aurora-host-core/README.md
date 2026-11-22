# Aurora Host Core

`aurora-host-core` is the reusable retained-scene host runtime.

It owns the standard GUI and platform boundary used by every host-based Aurora
program:

- scene parsing and validation;
- host window creation, layout, painting, input, and frame service;
- scene application and live scene reload;
- control/shared-surface contracts;
- generic widgets, text editing, dialogs, icons, and host chrome.

The `aurora-host` package is the thin CLI/dev shell over this core. Applications
may depend on `aurora-host-core` for the standard GUI, but must not depend on
the `aurora-host` CLI package. Application domain policy stays in the app and
updates scenes through the host APIs; it does not get copied into core.

Build:

```bat
dub build --config=library --compiler=dmd
```

The host boundary checker treats `aurora-host-core` as host code and rejects
apps that import `aurorahost.*` without depending on core, or that depend on the
host CLI.

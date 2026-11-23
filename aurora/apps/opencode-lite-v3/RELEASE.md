# Aurora OpenCode Lite v3 — Core Prototype

Version: 3.0.0

This is **not a live v3 application** and has not been integrated into the
running v2 program. It is a separate headless v3 core/prototype.

The live program was intentionally never touched during this work. A real v3
live release still requires a stable GUI shell, controller/network integration,
and a live update path that preserves the existing window.

Included:

- stable process-module shell
- module ABI contract (ABI 1, schema 3)
- v1→v2 module hot-swap proof
- multi-session command surface
- visual multi-session scene definition
- persisted sessions and v2 conversation import
- streaming/stop/retry controller surface
- headless verification gate

Not included:

- live provider/network integration in the v3 shell
- full visual host wiring
- full remote CLI/socket parity

Run the gate:

```bat
python verify.py
```

#!/usr/bin/env python3
"""Enforce the Aurora Windows GUI-subsystem rule.

A windowed Aurora app that links as a console (CUI) subsystem opens a console
window on double-click, and that console steals the taskbar button with an
exe-path title and no icon. Every DUB configuration whose main source creates a
`GuiWindow` must therefore link as the Windows GUI subsystem:

    "lflags-windows": ["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"]

CLI-only tools (no GuiWindow) keep the console subsystem. Windowed apps that
also need stdout for CLI diagnostics should `AllocConsole()` on demand.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

GUI_SUBSYSTEM_FLAG = "/SUBSYSTEM:WINDOWS"
GUI_ENTRY_FLAG = "/ENTRY:mainCRTStartup"
REQUIRED_LFLAGS = {GUI_SUBSYSTEM_FLAG, GUI_ENTRY_FLAG}
GUI_WINDOW_MARKERS = ("GuiWindow", "new GuiWindow", "options.title")


def is_windowed_app(main_source: str) -> bool:
    """Heuristic: a main source that constructs a GuiWindow is a windowed app."""
    return "GuiWindow" in main_source and "new GuiWindow" in main_source


def configuration_entries(recipe: dict):
    """Yield (name, dict) for each buildable configuration in a recipe."""
    configs = recipe.get("configurations")
    if isinstance(configs, list) and configs:
        for config in configs:
            if isinstance(config, dict) and config.get("mainSourceFile"):
                yield config.get("name", "?") or "?", config
        return
    if recipe.get("mainSourceFile"):
        yield "default", recipe


def is_headless_test(config: dict) -> bool:
    """Headless test executables print results to stdout and must keep the
    console subsystem (no real window is opened at runtime)."""
    versions = config.get("versions", [])
    if "AuroraHeadless" in versions:
        return True
    main = config.get("mainSourceFile", "")
    return isinstance(main, str) and main.replace("\\", "/").startswith("tests/")


def verify_manifest(path: Path, repo_root: Path) -> list[str]:
    failures: list[str] = []
    relative = path.relative_to(repo_root)
    try:
        recipe = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{relative}: cannot read DUB recipe: {error}"]

    for name, config in configuration_entries(recipe):
        if is_headless_test(config):
            continue
        main_file = config.get("mainSourceFile")
        if not main_file:
            continue
        main_path = path.parent / main_file
        if not main_path.is_file():
            continue
        try:
            source = main_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        # CLI-only tools are allowed to stay console-subsystem.
        if not is_windowed_app(source):
            continue

        lflags = config.get("lflags-windows", [])
        missing = sorted(REQUIRED_LFLAGS - set(lflags))
        if missing:
            failures.append(
                f"{relative} [{name}]: windowed app is not GUI-subsystem; "
                f"add to lflags-windows: {', '.join(missing)}"
            )
        else:
            print(
                f"GUI-subsystem ok: {relative} [{name}] "
                f"({main_file})"
            )
    return failures


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    manifests = sorted(
        path
        for path in repo_root.rglob("dub.json")
        if not any(part in {".dub", "build", "dist"} for part in path.parts)
    )
    if not manifests:
        print("ERROR: no dub.json manifests were found", file=sys.stderr)
        return 1

    failures: list[str] = []
    for path in manifests:
        failures.extend(verify_manifest(path, repo_root))

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        print(
            "\nEvery windowed Aurora app must link the Windows GUI subsystem so "
            "double-clicking it does not open a console that steals the taskbar "
            "icon. If the app also needs stdout for CLI diagnostics, allocate a "
            "console on demand (AllocConsole + freopen) instead of keeping the "
            "console subsystem.",
            file=sys.stderr,
        )
        return 1

    print("GUI-subsystem policy satisfied by every windowed Aurora DUB configuration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

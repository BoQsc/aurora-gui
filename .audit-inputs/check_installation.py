# SPDX-License-Identifier: 0BSD
"""Assert the installed launcher is the build the desktop shortcuts expect.

The desktop shortcuts start Steam with steam://rungameid/<id>; Steam runs
TerraForest.exe with --path "<project>". Only the Godot binary accepts --path,
so the file must be that binary (180,860,936 bytes), not an export template.
"""
import os
import pathlib
import sys

PROJECT = pathlib.Path(__file__).resolve().parents[1]
EXE = PROJECT / "TerraForest.exe"
EXE_BYTES = 180_860_936
SHORTCUT_IDS = ("16329458564139581440", "17039750085069504512")

failures = 0


def check(ok: bool, label: str) -> None:
    global failures
    print(("PASS " if ok else "FAIL ") + label)
    if not ok:
        failures += 1


size = EXE.stat().st_size if EXE.exists() else -1
check(size == EXE_BYTES, f"TerraForest.exe is the path-capable Godot binary ({size} bytes)")

desktop = pathlib.Path(os.path.expanduser("~/Desktop"))
for name, appid in zip(("TerraForest.lnk", "TerraForest Last World.lnk"), SHORTCUT_IDS):
    link = desktop / name
    raw = link.read_bytes() if link.exists() else b""
    wanted = f"steam://rungameid/{appid}".encode("utf-16-le")
    check(bool(raw) and wanted in raw, f"{name} launches through Steam again")

print(f"INSTALLATION failures={failures}")
sys.exit(1 if failures else 0)

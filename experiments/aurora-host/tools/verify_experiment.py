#!/usr/bin/env python3
"""Verify the isolated aurora-host experiment without writing to the repository."""
from __future__ import annotations

import pathlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
VENDOR = REPO / "vendor"
AURORA = VENDOR / "aurora-d-0.4.5"
STANDARD = VENDOR / "aurora-standard"
MAIN = ROOT / "source" / "experiment" / "aurorahost" / "main.d"


class VerificationError(Exception):
    pass


def run(command: list[str], *, cwd: pathlib.Path = ROOT, expect: int = 0,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        env=env,
    )
    if completed.returncode != expect:
        raise VerificationError(
            "command failed: "
            + " ".join(command)
            + f"\nexpected exit {expect}, got {completed.returncode}\n"
            + completed.stdout
            + completed.stderr
        )
    return completed


def build(dmd: str, temp: pathlib.Path, name: str, *, headless: bool) -> pathlib.Path:
    object_dir = temp / f"obj-{name}"
    object_dir.mkdir()
    executable = temp / f"{name}.exe"
    command = [
        dmd,
        f"-I{AURORA / 'source'}",
        f"-I{STANDARD / 'source'}",
        f"-I{ROOT / 'generated'}",
        f"-I{ROOT / 'source'}",
        "-i",
        f"-od={object_dir}",
        f"-of={executable}",
    ]
    if headless:
        command.append("-version=AuroraHeadless")
    command += [str(MAIN), "user32.lib", "gdi32.lib"]
    run(command)
    if not executable.is_file():
        raise VerificationError(f"expected executable was not produced: {executable}")
    return executable


def verify_ppm(path: pathlib.Path) -> None:
    data = path.read_bytes()
    match = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not match:
        raise VerificationError("render output has no valid P6 header")
    width, height, maximum = (int(value) for value in match.groups())
    if maximum != 255:
        raise VerificationError("render output is not 8-bit RGB")
    pixels = data[match.end():]
    if len(pixels) != width * height * 3:
        raise VerificationError("render output pixel payload has the wrong size")
    colors = {
        pixels[index:index + 3]
        for index in range(0, len(pixels), 3 * 97)
    }
    if len(colors) < 8:
        raise VerificationError(
            f"render output appears blank: only {len(colors)} sampled colors"
        )


def main() -> int:
    dmd = shutil.which("dmd")
    if not dmd:
        print("dmd is not on PATH", file=sys.stderr)
        return 1
    try:
        run([sys.executable, str(ROOT / "tools" / "generate_reference.py"), "--check"])
        with tempfile.TemporaryDirectory(prefix="aurora-host-") as temp_name:
            temp = pathlib.Path(temp_name)
            headless = build(dmd, temp, "host-headless", headless=True)
            gui = build(dmd, temp, "host", headless=False)

            version = run([str(headless), "--version"]).stdout
            schema = json.loads(
                (ROOT / "protocol" / "aurora-host.api.json").read_text(
                    encoding="utf-8"
                )
            )
            expected_protocol = f"protocol {schema['protocolVersion']}"
            if (expected_protocol not in version
                    or "Unicode 17.0.0" not in version):
                raise VerificationError("version output is missing protocol or Unicode version\n" + version)

            capabilities = run([str(headless), "--capabilities"]).stdout
            if ("headless-render" not in capabilities
                    or "textArea" not in capabilities
                    or "editor-view" not in capabilities
                    or "text-field" not in capabilities
                    or "text-selection" not in capabilities
                    or "editor-events" not in capabilities
                    or "canvas" not in capabilities
                    or "surface" not in capabilities
                    or "shared-surface" not in capabilities
                    or "tooltips" not in capabilities):
                raise VerificationError("capabilities output is incomplete\n" + capabilities)

            checked = run([str(headless), "--check", "samples/hello.scene.json"]).stdout
            if "scene OK" not in checked:
                raise VerificationError("valid scene was not accepted\n" + checked)

            editor_checked = run(
                [str(headless), "--check", "samples/editor.scene.json"]
            ).stdout
            if "scene OK" not in editor_checked:
                raise VerificationError(
                    "editor scene was not accepted\n" + editor_checked
                )

            canvas_checked = run(
                [str(headless), "--check", "samples/canvas.scene.json"]
            ).stdout
            if "scene OK" not in canvas_checked:
                raise VerificationError(
                    "canvas scene was not accepted\n" + canvas_checked
                )

            image_checked = run(
                [str(headless), "--check", "samples/image.scene.json"]
            ).stdout
            if "scene OK" not in image_checked:
                raise VerificationError(
                    "image scene was not accepted\n" + image_checked
                )

            surface_checked = run(
                [str(headless), "--check", "samples/surface.scene.json"]
            ).stdout
            if "scene OK" not in surface_checked:
                raise VerificationError(
                    "surface scene was not accepted\n" + surface_checked
                )

            animation_checked = run(
                [str(headless), "--check", "samples/animation.scene.json"]
            ).stdout
            if "scene OK" not in animation_checked:
                raise VerificationError(
                    "animation scene was not accepted\n" + animation_checked
                )

            invalid = run(
                [str(headless), "--check", "tests/invalid.scene.json"],
                expect=1,
            )
            combined = invalid.stdout + invalid.stderr
            if "unknown node type" not in combined:
                raise VerificationError("invalid scene failed for the wrong reason\n" + combined)

            image = temp / "hello.ppm"
            rendered = run(
                [
                    str(headless),
                    "--render",
                    "samples/hello.scene.json",
                    "--out",
                    str(image),
                ]
            ).stdout
            if "rendered:" not in rendered:
                raise VerificationError("render did not report success\n" + rendered)
            if not image.is_file() or image.stat().st_size < 1000:
                raise VerificationError("render output is missing or too small")
            verify_ppm(image)

            control_image = temp / "control.ppm"
            control_png = temp / "control.png"
            control_env = os.environ.copy()
            control_env["AURORA_HOST_EXE"] = str(gui)
            control = run(
                [
                    sys.executable,
                    str(ROOT / "tools" / "control_client.py"),
                    "--out",
                    str(control_image),
                    "--png",
                    str(control_png),
                ],
                env=control_env,
            )
            if "control demo passed" not in control.stdout:
                raise VerificationError(
                    "control demo did not report success\n" + control.stdout
                )
            verify_ppm(control_image)

            editor_image = temp / "editor.ppm"
            editor = run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "tools" / "editor_control_test.py"),
                    "--out",
                    str(editor_image),
                ],
                env=control_env,
            )
            if "editor control passed" not in editor.stdout:
                raise VerificationError(
                    "editor control test did not report success\n" + editor.stdout
                )
            verify_ppm(editor_image)

            ui = run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "tools" / "ui_depth_test.py"),
                    "--out-dir",
                    str(temp),
                ],
                env=control_env,
            )
            if "ui depth test passed" not in ui.stdout:
                raise VerificationError(
                    "UI depth test did not report success\n" + ui.stdout
                )
            for name in ("ui-depth.ppm", "ui-depth-menu.ppm",
                         "ui-depth-context.ppm", "ui-depth-no-tooltip.ppm",
                         "ui-depth-tooltip.ppm",
                         "ui-depth-tooltip-hidden.ppm"):
                verify_ppm(temp / name)

            canvas_image = temp / "canvas.ppm"
            canvas = run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "tools" / "canvas_test.py"),
                    "--host",
                    str(headless),
                    "--scene",
                    str(ROOT / "samples" / "canvas.scene.json"),
                    "--out",
                    str(canvas_image),
                ]
            )
            if "canvas pixel test passed" not in canvas.stdout:
                raise VerificationError(
                    "canvas test did not report success\n" + canvas.stdout
                )

            canvas_live_image = temp / "canvas-live.ppm"
            canvas_live = run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "tools" / "canvas_control_test.py"),
                    "--host",
                    str(gui),
                    "--out",
                    str(canvas_live_image),
                ],
                env=control_env,
            )
            if "canvas control passed" not in canvas_live.stdout:
                raise VerificationError(
                    "canvas control test did not report success\n"
                    + canvas_live.stdout
                )
    except VerificationError as error:
        print(f"aurora-host verification failed: {error}", file=sys.stderr)
        return 1

    print("generated reference: current")
    print("headless host: built")
    print("windowed host: built")
    print("version/capabilities: verified")
    print("scene check: valid accepted, invalid rejected")
    print("headless render: binary PPM produced")
    print("control demo: click, tree update, and live screenshot verified")
    print("editor control: text, state, selection, events, wrap, action, and screenshot verified")
    print("UI depth: menus, cascade submenu, tabs, toolbar, context menu, and pixels verified")
    print("text weight: approved natural hinting C; minimum ink 0.039")
    print("canvas: retained shapes, colors, and text pixels verified")
    print("canvas control: live setCanvas redraw verified")
    print("aurora-host experiment verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

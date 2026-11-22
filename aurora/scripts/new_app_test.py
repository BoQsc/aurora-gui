#!/usr/bin/env python3
"""Create a throwaway app from the base, then build and smoke-test it."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from new_app import APPS, create_app  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    name = f"scaffold-check-{os.getpid()}"
    module_name = name.replace("-", "_")
    title = "Scaffold Check"
    app = create_app(name, title)
    blank_name = f"scaffold-blank-{os.getpid()}"
    blank_title = "Scaffold Blank"
    blank_app = create_app(blank_name, blank_title, blank=True)
    try:
        for filename in ("module.d", "run.py", "smoke_test.py",
                         "interaction_test.py", "README.md",
                         f"RUN-{name}.bat"):
            require((app / filename).is_file(), f"missing {filename}")
        require((app / "module.d").read_text(encoding="utf-8").startswith(
            f"module {module_name};"), "module was not renamed")
        require(title in (app / "run.py").read_text(encoding="utf-8"),
                "window title was not replaced")
        require(f'"build" / "{name}"' in
                (app / "run.py").read_text(encoding="utf-8"),
                "launcher output folder was not renamed")
        require(not (app / "build").exists(), "generator copied build output")
        require(not (app / "preview.png").exists(),
                "generator copied base artwork")
        require("enum bool BlankMode = false;" in
                (app / "module.d").read_text(encoding="utf-8"),
                "reference app should keep the demo pages")
        require("enum bool BlankMode = true;" in
                (blank_app / "module.d").read_text(encoding="utf-8"),
                "blank app did not enable BlankMode")
        require("one blank workbench page" in
                (blank_app / "README.md").read_text(encoding="utf-8"),
                "blank README was not generated")

        for generated, generated_title in ((app, title),
                                           (blank_app, blank_title)):
            completed = subprocess.run(
                [sys.executable, "-B", str(generated / "smoke_test.py")],
                cwd=str(generated),
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=120,
            )
            output = completed.stdout + completed.stderr
            require(completed.returncode == 0,
                    f"generated smoke test failed:\n{output}")
            require(f"PASS {generated_title} live host" in completed.stdout,
                    f"generated smoke test did not pass:\n{output}")
        print(f"PASS scaffold generator app={app.name} blank={blank_app.name}")
    finally:
        shutil.rmtree(app, ignore_errors=True)
        shutil.rmtree(blank_app, ignore_errors=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL scaffold generator: {error}", file=sys.stderr)
        raise SystemExit(1)

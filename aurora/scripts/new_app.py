#!/usr/bin/env python3
"""Create a new Aurora live app from aurora/apps/base."""
from __future__ import annotations

import argparse
import re
import shutil
import tempfile
from pathlib import Path

AURORA = Path(__file__).resolve().parents[1]
APPS = AURORA / "apps"
TEMPLATE = APPS / "base"
NAME_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
COPY_FILES = ("module.d", "run.py", "smoke_test.py", "interaction_test.py")


def default_title(name: str) -> str:
    return name.replace("_", " ").replace("-", " ").title()


def validate(name: str, title: str) -> None:
    if not NAME_RE.fullmatch(name):
        raise ValueError("name must match [a-z][a-z0-9_-]*")
    if name == "base":
        raise ValueError("choose a name other than 'base'")
    if not title.strip():
        raise ValueError("title must not be empty")
    for forbidden in ('"', "\\", "\n", "\r"):
        if forbidden in title:
            raise ValueError(f"title must not contain {forbidden!r}")


def transform(filename: str, text: str, name: str, module_name: str,
              title: str, location: str, blank: bool) -> str:
    brand = title.upper()
    text = text.replace("module base;", f"module {module_name};")
    text = text.replace("AURORA BASE", f"AURORA {brand}")
    text = text.replace("Aurora Base", title)
    text = text.replace('"BASE"', f'"{brand}"')
    text = text.replace("BASE / 0.1", f"{brand} / 0.1")
    text = text.replace("aurora/apps/base/run.py", f"{location}/run.py")
    text = text.replace('"build" / "base"', f'"build" / "{name}"')
    text = text.replace("aurora-base-input-", f"aurora-{name}-input-")
    text = text.replace("aurora-base-", f"aurora-{name}-")
    if filename == "smoke_test.py":
        text = text.replace("base must not use", f"{module_name} must not use")
        text = text.replace("base must render", f"{module_name} must render")
        text = text.replace("base must publish",
                            f"{module_name} must publish")
    if filename == "run.py":
        text = text.replace("Aurora Base", title)
    if blank:
        text = text.replace("enum bool BlankMode = false;",
                            "enum bool BlankMode = true;")
    return text


def render_readme(title: str, name: str, location: str,
                  blank: bool) -> str:
    scope = ("one blank workbench page" if blank
             else "three reference pages")
    body = ("Replace `drawHome` with your content."
            if blank else
            "Replace `drawHome`, `drawActivity`, and `drawGuide`.")
    return f"""# {title}

Generated from `aurora/apps/base`.

## Run

```text
python -B {location}/run.py
```

Or double-click [`RUN-{name}.bat`](RUN-{name}.bat). The launcher starts
`aurora-hotswap`, builds `module.d`, opens the host window, and watches the
source. Edit `module.d` while the window is open; hotswap rebuilds in place.
Startup prints ordered `[trace]` stages and the detail stays in
`build/{name}/hotswap.log`.

## What you own

- The dark shell, {scope}, hit testing, keyboard handling, and session state
  live in `module.d`.
- The host owns the window, surface mapping, DPI scaling, and the input ring.
- All text uses `aurora.Canvas` and the shared text engine. Do not add a native
  text path or a private rasterizer.

## Files

| File | Role |
|---|---|
| [`module.d`](module.d) | The app. |
| [`run.py`](run.py) | Detached live-workflow launcher. |
| [`smoke_test.py`](smoke_test.py) | Build/first-frame check. |
| [`interaction_test.py`](interaction_test.py) | Pointer, keyboard, and state check through the host control channel. |

## Make it yours

1. Rename the module and title in `module.d`, `run.py`, and the tests if you
   have not already.
2. {body}
3. Keep the `LiveSurface` publish loop, `Base.onInput`, and the dark palette
   hooks.
4. Replace the sample state keys in `saveState`/`loadState`.
5. Run the smoke and interaction tests before the first live session.

## Verify

```text
python -B {location}/smoke_test.py
python -B {location}/interaction_test.py
```

`build/{name}.exe` is a child module. It is not a standalone application:
aurora-hotswap supplies `--surface` and `--state`. Double-clicking it hands off
to `run.py` when the launcher is next to the project.
"""


def create_app(name: str, title: str | None = None, apps_root: Path = APPS,
               template: Path = TEMPLATE, blank: bool = False) -> Path:
    title = title or default_title(name)
    validate(name, title)
    module_name = name.replace("-", "_")
    apps_root = apps_root.resolve()
    template = template.resolve()
    destination = apps_root / name
    if destination.exists():
        raise FileExistsError(f"destination already exists: {destination}")
    if not (template / "module.d").is_file():
        raise FileNotFoundError(f"missing template: {template}")

    location = (f"aurora/apps/{name}"
                if apps_root == APPS.resolve() else destination.as_posix())
    staging = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=str(apps_root)))
    try:
        for filename in COPY_FILES:
            source = template / filename
            text = source.read_text(encoding="utf-8")
            (staging / filename).write_text(
                transform(filename, text, name, module_name, title, location,
                          blank),
                encoding="utf-8",
            )
        bat = (template / "RUN-BASE.bat").read_text(encoding="utf-8")
        (staging / f"RUN-{name}.bat").write_text(bat, encoding="utf-8")
        (staging / "README.md").write_text(
            render_readme(title, name, location, blank), encoding="utf-8")
        staging.rename(destination)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a new Aurora live app from the base.")
    parser.add_argument("name",
                        help="folder name: [a-z][a-z0-9_-]* "
                             "(module uses underscores)")
    parser.add_argument("--title", help="window and README title")
    parser.add_argument("--blank", action="store_true",
                        help="generate a single blank workbench page")
    parser.add_argument("--apps-root", type=Path, default=APPS,
                        help=argparse.SUPPRESS)
    parser.add_argument("--template", type=Path, default=TEMPLATE,
                        help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        destination = create_app(args.name, args.title, args.apps_root,
                                 args.template, args.blank)
    except (ValueError, FileExistsError, FileNotFoundError) as error:
        parser.error(str(error))
    location = (f"aurora/apps/{args.name}"
                if destination.parent == APPS else destination.as_posix())
    print(f"Created {destination}")
    print(f"Run:    python -B {location}/run.py")
    print(f"Verify: python -B {location}/smoke_test.py")
    print(f"        python -B {location}/interaction_test.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

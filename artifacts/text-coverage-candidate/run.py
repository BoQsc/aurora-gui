"""Build and capture the candidate without changing the installed app binaries.

Windows, DMD and Pillow are required. Live Vulkan captures briefly open the
probe's own window and validate two changing markers before accepting images.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageEnhance
from review import make_review


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/text-coverage-candidate/review"


def env(policy, contrast="0.5"):
    result = os.environ.copy()
    for key in ("AURORA_FONT_RENDER_MODE", "AURORA_FONT", "AURORA_UI_FONT",
                "AURORA_MONOSPACE_FONT", "AURORA_UI_BOLD_FONT"):
        result.pop(key, None)
    result.update(AURORA_TEXT_COVERAGE=policy, AURORA_TEXT_CONTRAST=contrast,
                  AURORA_HINTING="0", PYTHONWARNINGS="ignore::DeprecationWarning")
    return result


def run(command, label, environment=None, required=True):
    start = time.perf_counter()
    result = subprocess.run(command, cwd=ROOT, env=environment,
                            capture_output=True, text=True, encoding="utf-8", errors="replace")
    record = {"label": label, "exit_code": result.returncode,
              "seconds": time.perf_counter() - start,
              "output": result.stdout + result.stderr}
    print(label, result.returncode, flush=True)
    if result.returncode and required:
        raise RuntimeError(record["output"])
    return record


def build(native=False):
    out = BUILD / ("native" if native else "headless")
    out.mkdir(parents=True, exist_ok=True)
    exe = out / "capture.exe"
    includes = ["vendor/aurora-d-0.4.5/source", "vendor/aurora-standard/source",
                "aurora-notepad/source", "experiments/aurora-host/source",
                "experiments/aurora-host/generated"]
    command = ["dmd", "-i", "-O", *["-I" + str(ROOT / p) for p in includes],
               "-od=" + str(out), "-of=" + str(exe), str(HERE / "capture.d"),
               "user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib"]
    if not native:
        command.append("-version=AuroraHeadless")
    run(command, "build " + out.name)
    return exe


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    evidence = {"status": "pending-user-review", "decision": None,
                "default_changed": False, "corpus": {}, "captures": []}
    headless = build()
    native = build(True)
    for policy in ("legacy", "foreground"):
        for font, path in (("segoe", "segoeui.ttf"), ("consolas", "consola.ttf")):
            out = BUILD / (font + "-" + policy)
            run([sys.executable, str(ROOT / "scripts/compare-font-rendering.py"),
                 "--font", str(Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts" / path),
                 "--sizes", "11", "12", "13", "17", "18", "20", "26", "--out", str(out)],
                font + " " + policy, env(policy))
            evidence["corpus"][font + "-" + policy] = json.loads((out / "manifest.json").read_text("utf-8"))
        for app, themes in (("notepad", ("light", "dark")),
                            ("host", ("light", "dark")), ("padpp", ("light",))):
            for theme in themes:
                for dpi in (96, 144):
                    name = f"{app}-{theme}-{dpi}-{policy}"
                    prefix = BUILD / name
                    record = run([str(headless), app, str(prefix), theme, str(dpi)], name, env(policy))
                    evidence["captures"].append(record)
                    with Image.open(prefix.with_suffix(".ppm")) as image:
                        image.save(HERE / (name + ".png"))
        prefix = BUILD / ("gpu-" + policy)
        record = run([str(native), "native", str(prefix)], "GPU " + policy, env(policy), required=False)
        evidence["captures"].append(record)
        if record["exit_code"] == 0:
            for stage in (0, 1):
                with Image.open(str(prefix) + f"-{stage}.ppm") as image:
                    image.save(HERE / f"gpu-{policy}-{stage}.png")
    # Also preserve the host's present, stronger override as a distinct A image.
    for dpi in (96, 144):
        name = f"padpp-light-{dpi}-current-host"
        prefix = BUILD / name
        evidence["captures"].append(run([str(headless), "padpp", str(prefix), "light", str(dpi)],
                                         name, env("legacy", "0.75")))
        with Image.open(prefix.with_suffix(".ppm")) as image:
            image.save(HERE / (name + ".png"))
    for name in ("padpp-light-96", "padpp-light-144", "notepad-light-96", "notepad-dark-96",
                 "notepad-light-144", "notepad-dark-144", "host-light-96", "host-dark-96",
                 "host-light-144", "host-dark-144"):
        a = HERE / (name + "-legacy.png")
        b = HERE / (name + "-foreground.png")
        with Image.open(a) as baseline, Image.open(b) as candidate:
            diff = ImageEnhance.Brightness(ImageChops.difference(baseline, candidate)).enhance(6)
            difference = BUILD / (name + "-difference.png")
            diff.save(difference)
        make_review(a, b, name + ": A legacy / B foreground coverage", HERE / name, difference)
    (HERE / "evidence.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    run([sys.executable, str(HERE / "package.py")], "package review")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

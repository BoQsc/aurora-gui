"""Capture approved C and opt-in D in real app layouts.

Uses the existing review harness, isolated binaries, and validated live Vulkan
markers. No installed application executable or running user window is changed.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "build-validation/native-text-next/capture"
sys.path.insert(0, str(HERE.parent / "text-coverage-candidate"))
from review import make_review


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    includes = ["vendor/aurora-d-0.4.5/source", "vendor/aurora-standard/source",
                "aurora-notepad/source", "experiments/aurora-host/source",
                "experiments/aurora-host/generated"]
    records = []

    def run(command, env=None):
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        records.append({"command": [str(x) for x in command], "exit_code": result.returncode,
                        "output": result.stdout + result.stderr})
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result

    executables = {}
    for target in ("headless", "native"):
        obj = BUILD / (target + "-obj")
        obj.mkdir(exist_ok=True)
        exe = BUILD / (target + ".exe")
        command = ["dmd", "-i", "-O", *["-I" + str(ROOT / p) for p in includes],
                   "-od=" + str(obj), "-of=" + str(exe),
                   str(HERE.parent / "text-coverage-candidate/capture.d"),
                   "user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib"]
        if target == "headless":
            command.append("-version=AuroraHeadless")
        run(command)
        executables[target] = exe
    for mode, experiment in (("C", None), ("D", "native-next")):
        env = os.environ.copy()
        for key in ("AURORA_FONT_RENDER_MODE", "AURORA_FONT", "AURORA_UI_FONT",
                    "AURORA_MONOSPACE_FONT", "AURORA_UI_BOLD_FONT"):
            env.pop(key, None)
        env.update(AURORA_HINTING="natural", AURORA_TEXT_COVERAGE="foreground", AURORA_TEXT_CONTRAST="0.5")
        env.pop("AURORA_TEXT_EXPERIMENT", None)
        if experiment: env["AURORA_TEXT_EXPERIMENT"] = experiment
        for app, themes in (("notepad", ("light", "dark")), ("host", ("light", "dark")),
                            ("padpp", ("light",))):
            for theme in themes:
                for dpi in (96, 144):
                    name = f"{app}-{theme}-{dpi}-{mode}"
                    prefix = BUILD / name
                    result = run([executables["headless"], app, prefix, theme, dpi], env)
                    print(result.stdout.strip(), flush=True)
                    with Image.open(prefix.with_suffix(".ppm")) as image:
                        image.save(HERE / (name + ".png"))
        prefix = BUILD / ("gpu-" + mode)
        result = run([executables["native"], "native", prefix], env)
        print(mode, result.stdout.strip(), flush=True)
        for stage in (0, 1):
            for suffix in (f"-{stage}", f"-software-{stage}"):
                with Image.open(str(prefix) + suffix + ".ppm") as image:
                    image.save(HERE / ("gpu-" + mode + suffix + ".png"))
    for app, themes in (("notepad", ("light", "dark")), ("host", ("light", "dark")),
                        ("padpp", ("light",))):
        for theme in themes:
            for dpi in (96, 144):
                name = f"{app}-{theme}-{dpi}"
                folder = HERE / name
                make_review(HERE / (name + "-C.png"), HERE / (name + "-D.png"),
                            name + ": approved C / experimental D", folder)
    (HERE / "captures.json").write_text(json.dumps(records, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()

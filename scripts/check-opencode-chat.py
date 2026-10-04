"""Build and run OpenCode chat regressions without accessing a model provider."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check(package, source, name, *, unittest=False, run_args=()):
    folder = ROOT / package
    output = folder / "build" / (name + ".exe")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [shutil.which("dmd") or "dmd", "-i", "-version=AuroraHeadless"]
    if unittest:
        command.append("-unittest")
    for include in [folder / "source", ROOT / "aurora-opencode-core/source",
                    ROOT / "vendor/aurora-d-0.4.5/source", folder / "shared"]:
        command.append("-I" + str(include))
    command.extend(str(folder / path) for path in source)
    command.extend(["user32.lib", "gdi32.lib", "shell32.lib", "wininet.lib",
                    "winmm.lib", "-of=" + str(output)])
    print(f"Building {name}", flush=True)
    subprocess.run(command, cwd=folder, check=True, timeout=180)
    args = [str(output)]
    args.extend(run_args)
    if name == "chat-flow-smoke":
        artifacts = ROOT / "artifacts/opencode-chat-review"
        artifacts.mkdir(parents=True, exist_ok=True)
        args.append(str(artifacts / "baseline-transcript.ppm"))
    print(f"Running {name}", flush=True)
    subprocess.run(args, cwd=folder, check=True, timeout=180)
    if name == "chat-flow-smoke":
        from PIL import Image
        for image in artifacts.glob("*.ppm"):
            with Image.open(image) as screenshot:
                screenshot.save(image.with_suffix(".png"))
            image.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pro", action="store_true", help="Also run the full Pro headless suite")
    options = parser.parse_args()
    # The vendored contextmenu module provides the unittest entry point.
    # DUB's generated test main conflicts with it, so invoke DMD directly.
    check("aurora-opencode-core", ["source/auroraopencode/core.d",
          "source/auroraopencode/opencode_client.d", "source/auroraopencode/markdown.d",
          "source/auroraopencode/runtime.d"], "chat-core-unittests", unittest=True)
    check("aurora-opencode-core", ["tests/tool_sse_test.d"], "tool-sse-test")
    check("aurora-opencode", ["tests/chat_flow_smoke.d"], "chat-flow-smoke")
    check("aurora-opencode", ["tests/headless_smoke.d"], "baseline-headless-smoke")
    if options.pro:
        check("aurora-opencode-pro", ["tests/chat_consistency_smoke.d"], "chat-consistency-smoke")
        check("aurora-opencode-pro", ["tests/process_flow_smoke.d"], "process-flow-smoke")
        check("aurora-opencode-pro", ["tests/headless_pro_smoke.d"], "chat-pro-smoke")
        import runpy
        runpy.run_path(str(ROOT / "scripts/check-opencode-pro-flow.py"))["main"]()
        from PIL import Image
        artifacts = ROOT / "artifacts/opencode-chat-review"
        for folder, name, target in [
            ("aurora-opencode-tool-shots", "explored-expanded", "pro-tools"),
            ("aurora-opencode-exchange-shots", "per-turn-thinking", "pro-tool-rounds"),
        ]:
            with Image.open(Path(tempfile.gettempdir()) / folder / (name + ".ppm")) as shot:
                shot.save(artifacts / (target + ".png"))
    print("All OpenCode chat checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(1)

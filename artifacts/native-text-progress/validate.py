"""Run focused checks and record full outputs without modifying installed apps."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "vendor/aurora-d-0.4.5"
BUILD = ROOT / "build-validation/native-text-progress/validation"


def run(command, cwd=ROOT, env=None):
    result = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                            capture_output=True, text=True, encoding="utf-8", errors="replace")
    return {"command": [str(x) for x in command], "workdir": str(cwd.relative_to(ROOT)),
            "exit_code": result.returncode, "output": result.stdout + result.stderr}


def focused(name, source, unit=False):
    out = BUILD / name
    out.mkdir(parents=True, exist_ok=True)
    exe = out / (name + ".exe")
    command = ["dmd", "-i", "-I" + str(CORE / "source"), "-od=" + str(out), "-of=" + str(exe)]
    if unit:
        command += ["-unittest", "-main"]
    else:
        command += ["-version=AuroraHeadless"]
    records = [run([*command, str(CORE / source), "user32.lib", "gdi32.lib"], CORE)]
    if records[-1]["exit_code"] == 0:
        modes = ("legacy", "foreground") if name in ("font-quality", "dpi") else (None,)
        profiles = [(mode, hint) for hint in (None, "0") for mode in modes] if name in ("font-quality", "dpi", "window-dpi") else [(mode, None) for mode in modes]
        for mode, hint in profiles:
            env = os.environ.copy()
            for key in ("AURORA_TEXT_COVERAGE", "AURORA_TEXT_CONTRAST", "AURORA_HINTING"):
                env.pop(key, None)
            if mode:
                env["AURORA_TEXT_COVERAGE"] = mode
            if hint is not None:
                env["AURORA_HINTING"] = hint
            records.append(run([exe], CORE, env))
            records[-1]["coverage_override"] = mode
            records[-1]["hinting_override"] = hint
    print(name, "passed" if all(r["exit_code"] == 0 for r in records) else "FAILED", flush=True)
    return {"name": name, "records": records}


def main():
    checks = []
    natural = "--natural" in sys.argv
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        pending = [pool.submit(focused, name, source, unit) for name, source, unit in (
            ("coverage", "tests/text_coverage.d", False),
            ("font-quality", "tests/font_quality_regression.d", False),
            ("dpi", "tests/dpi_rendering.d", False),
            ("window-dpi", "tests/window_dpi_regression.d", False),
            ("hinter-unit", "source/aurora/text/hinter.d", True),
            ("hinting-windows", "tests/hinting_windows_regression.d", False)) if not natural]
        checks.extend(task.result() for task in pending)
    test_env = os.environ.copy()
    for key in ("AURORA_TEXT_COVERAGE", "AURORA_TEXT_CONTRAST", "AURORA_HINTING"):
        test_env.pop(key, None)
    if natural:
        test_env["AURORA_HINTING"] = "natural"
        # Reuse the freshly built focused executables; preserve failing checks.
        for name in ("font-quality", "dpi", "window-dpi"):
            checks.append({"name": name, "records": [run(
                [BUILD / name / (name + ".exe")], CORE, test_env)]})
    for name, command in (
        ("standards", [sys.executable, "scripts/audit-aurora-standards.py"]),
        ("python", [sys.executable, "-W", "ignore", "-m", "unittest",
                    "scripts.tests.test_font_comparison", "scripts.tests.test_aurora_standards_audit"]),
        ("host-verifier", [sys.executable, "experiments/aurora-host/tools/verify_experiment.py"])):
        if natural and name != "host-verifier":
            continue
        record = run(command, env=test_env)
        checks.append({"name": name, "records": [record]})
        print(name, "passed" if record["exit_code"] == 0 else "FAILED", flush=True)
    host = ROOT / "build-validation/native-text-progress/host-release/aurora-host-experiment.exe"
    env = test_env.copy()
    env["AURORA_HOST_EXE"] = str(host)
    checks.append({"name": "padpp-self-test", "records": [run(
        [sys.executable, "-u", "-B", "padpp.py", "--self-test", "--host", host],
        ROOT / "experiments/aurora-host-notepadpp", env)]})
    print("padpp-self-test", checks[-1]["records"][-1]["exit_code"], flush=True)
    binaries = [host, ROOT / "build-validation/native-text-progress/notepad-release/aurora-notepad.exe"]
    result = {"date": "2026-10-20", "coverage_default": "foreground", "hinting_default": "natural",
              "hinting_under_test": "explicit natural" if natural else "shared default natural, with unhinted compatibility regressions",
              "weight_profile": "owner-approved C (0.039)",
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in (CORE / "source/aurora/text/hinter.d", CORE / "source/aurora/text/truetype.d",
                            CORE / "source/aurora/font.d", CORE / "source/aurora/canvas.d",
                            CORE / "source/aurora/text/atlas.d", CORE / "source/aurora/text/coverage.d")},
              "checks": checks, "release_binaries": {str(p.relative_to(ROOT)): {
                  "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                  for p in binaries},
              "known_failure": "Older Notepad tests/headless_smoke.d:120 drag/restore assertion; reproduced in both coverage modes in original validation."}
    (HERE / ("validation-natural.json" if natural else "validation.json")).write_text(json.dumps(result, indent=2), encoding="utf-8")
    return int(any(r["exit_code"] for check in checks for r in check["records"]))


if __name__ == "__main__":
    raise SystemExit(main())

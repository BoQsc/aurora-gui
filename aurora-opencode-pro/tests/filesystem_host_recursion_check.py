"""Regression: a filesystem tool host must never re-spawn its own image.

`runFilesystemTool` spawns a tool host as this image. Production handles the
helper flag in main before any tool runs; an image that does not handle it
re-runs its whole program instead, and every generation then spawned the next
one. One direct run of a contract test left hundreds of copies resident.

The spawn now carries a marker, so a spawned image that cannot host refuses
instead of continuing the chain.

Run from the package root:  python tests/filesystem_host_recursion_check.py
"""

import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE_EXE = ROOT / "build" / "filesystem_host_spawn_probe.exe"
TEST_EXE = ROOT / "build" / "final_plan_mode.exe"
HOST_EXE = ROOT / "build" / "filesystem_host.exe"
IMAGE = "filesystem_host_spawn_probe.exe"
CONTRACT_IMAGE = "final_plan_mode.exe"
MARKER = "AURORA_FILESYSTEM_HOST_SPAWN"
REFUSAL = "cannot host filesystem tools"
DMD_ARGS = [
    "-lowmem", "-Isource", "-Ishared", "-I../vendor/aurora-d-0.4.5/source",
    "-I../aurora-opencode-core/source", "-Jassets", "-i", "user32.lib",
    "gdi32.lib", "shell32.lib", "wininet.lib", "winmm.lib",
]


def build(source: str, exe: Path) -> None:
    cmd = ["dmd", *DMD_ARGS, "-of=" + str(exe), source]
    done = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    if done.returncode != 0:
        print(done.stdout.decode("utf-8", "replace"))
        raise SystemExit("compile failed: " + source)


def count(image: str) -> int:
    done = subprocess.run(
        ["tasklist", "/fi", "imagename eq " + image, "/fo", "csv", "/nh"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return done.stdout.lower().count(image.encode())


def run(program: Path, env: dict, timeout: int) -> tuple:
    started = time.time()
    try:
        done = subprocess.run([str(program)], cwd=ROOT, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout)
        code = done.returncode
        text = done.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        code = "timeout"
        text = ""
    return code, text, time.time() - started


def base_env() -> dict:
    env = dict(os.environ)
    env.pop("AURORA_FILESYSTEM_HOST", None)
    env.pop(MARKER, None)
    return env


def main() -> int:
    build("tests/filesystem_host.d", HOST_EXE)
    build("tests/filesystem_host_spawn_probe.d", PROBE_EXE)
    build("tests/plan_mode_contracts.d", TEST_EXE)

    # 1. A spawned image that cannot host must refuse, not spawn again.
    env = base_env()
    env[MARKER] = "1"
    code, text, elapsed = run(PROBE_EXE, env, timeout=60)
    if code == "timeout":
        raise SystemExit("a spawned image never finished; the chain is back")
    if REFUSAL not in text:
        raise SystemExit("the spawned image did not refuse:\n" + text[-1500:])
    if count(IMAGE):
        raise SystemExit("probe copies are still resident")
    print("PASS a spawned image refuses instead of re-spawning itself (%.1fs)"
          % elapsed)

    # 2. A run without any host stays bounded instead of chaining.
    code, text, elapsed = run(PROBE_EXE, base_env(), timeout=120)
    if code == "timeout":
        raise SystemExit("running without a host never finished")
    if elapsed > 60:
        raise SystemExit("unbounded host retries: %.1fs" % elapsed)
    if count(IMAGE):
        raise SystemExit("probe copies are still resident")
    print("PASS a run without a host stays bounded (%.1fs)" % elapsed)

    # 3. The contracts themselves still pass through the real fixture host.
    env = base_env()
    env["AURORA_FILESYSTEM_HOST"] = str(HOST_EXE)
    code, text, elapsed = run(TEST_EXE, env, timeout=300)
    if code != 0:
        print(text)
        raise SystemExit("plan mode contracts failed with a real host")
    if count(CONTRACT_IMAGE):
        raise SystemExit("contract copies are still resident")
    print("PASS plan mode contracts pass through the fixture host (%.1fs)"
          % elapsed)
    print("filesystem host recursion check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

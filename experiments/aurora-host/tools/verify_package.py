#!/usr/bin/env python3
"""Verify an extracted aurora-host package without using repository paths."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_crt_imports import verify_crt_imports  # noqa: E402


class VerificationError(Exception):
    pass


class LineReader(threading.Thread):
    def __init__(self, stream, name: str):
        super().__init__(daemon=True, name=name)
        self.stream = stream
        self.lines: queue.Queue[str | None] = queue.Queue()

    def run(self) -> None:
        try:
            for line in self.stream:
                self.lines.put(line.rstrip("\r\n"))
        finally:
            self.lines.put(None)

    def next_line(self, timeout: float = 20.0, label: str = "line") -> str:
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty as error:
            raise VerificationError(f"timed out waiting for {label}") from error
        if line is None:
            raise VerificationError(f"host exited before {label}")
        return line


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_manifest(root: Path) -> None:
    manifest = root / "MANIFEST.sha256"
    if not manifest.is_file():
        raise VerificationError("package has no MANIFEST.sha256")
    resolved_root = root.resolve()
    for number, line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        parts = line.split("  ", 1)
        if len(parts) != 2:
            raise VerificationError(f"malformed manifest line {number}: {line!r}")
        expected, relative = parts
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise VerificationError(f"manifest path escapes package: {relative}")
        path = (root / relative_path).resolve()
        if path == resolved_root or resolved_root not in path.parents:
            raise VerificationError(f"manifest path escapes package: {relative}")
        if not path.is_file():
            raise VerificationError(f"manifest file is missing: {relative}")
        actual = sha256(path)
        if actual.lower() != expected.lower():
            raise VerificationError(
                f"manifest mismatch for {relative}: {actual} != {expected}"
            )


def run(executable: Path, arguments: list[str], cwd: Path) -> str:
    completed = subprocess.run(
        [str(executable), *arguments],
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=180,
    )
    if completed.returncode != 0:
        raise VerificationError(
            f"command failed: {executable.name} {' '.join(arguments)}\n"
            f"exit {completed.returncode}\n{completed.stdout}{completed.stderr}"
        )
    return completed.stdout + completed.stderr


def verify_ppm(path: Path) -> tuple[int, int]:
    if not path.is_file():
        raise VerificationError(f"render output is missing: {path}")
    data = path.read_bytes()
    match = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not match:
        raise VerificationError(f"render output is not a P6 PPM: {path}")
    width, height, maximum = (int(value) for value in match.groups())
    if width <= 0 or height <= 0 or maximum != 255:
        raise VerificationError(f"invalid PPM dimensions or range: {path}")
    if len(data) <= match.end():
        raise VerificationError(f"render output has no pixels: {path}")
    return width, height


class HostSession:
    def __init__(self, executable: Path, root: Path):
        self.process = subprocess.Popen(
            [str(executable), "--run", "samples/hello.scene.json", "--control"],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.stdout = LineReader(self.process.stdout, "host-stdout")
        self.stderr = LineReader(self.process.stderr, "host-stderr")
        self.stdout.start()
        self.stderr.start()
        self.next_id = 0

    def wait_ready(self) -> None:
        while True:
            line = self.stdout.next_line(label="READY")
            if line == "READY":
                return
            print(f"host: {line}")

    def send(self, command: str, **fields) -> dict:
        self.next_id += 1
        request_id = self.next_id
        payload = {"id": request_id, "command": command, **fields}
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.stdout.next_line(label=f"response to {command}")
            if line.startswith("EVENT "):
                continue
            if not line.startswith("RESPONSE "):
                print(f"host: {line}")
                continue
            response = json.loads(line[len("RESPONSE "):])
            if response.get("id") == request_id:
                return response
            print(f"unexpected response: {line}")

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.send("close")
            except Exception:
                pass
        try:
            code = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            code = self.process.wait(timeout=5)
        if code != 0:
            stderr = []
            while True:
                try:
                    line = self.stderr.lines.get_nowait()
                except queue.Empty:
                    break
                if line is None:
                    break
                if line:
                    stderr.append(line)
            raise VerificationError(
                f"host exited with {code}" + ("\n" + "\n".join(stderr) if stderr else "")
            )


def verify_control(executable: Path, root: Path) -> None:
    session = HostSession(executable, root)
    try:
        session.wait_ready()
        ping = session.send("ping")
        if ping.get("ok") is not True:
            raise VerificationError(f"ping failed: {ping}")
        tree = session.send("tree")
        nodes = tree.get("nodes", [])
        if tree.get("ok") is not True or not any(
            node.get("id") == "hello" for node in nodes
        ):
            raise VerificationError(f"tree did not contain the hello node: {tree}")
    finally:
        session.close()


def verify_package(package: Path) -> None:
    if not package.is_file():
        raise VerificationError(f"package archive is missing: {package}")
    with tempfile.TemporaryDirectory(prefix="aurora-host-verify-") as temporary:
        extraction = Path(temporary)
        with zipfile.ZipFile(package) as archive:
            archive.extractall(extraction)
        roots = [path for path in extraction.iterdir() if path.is_dir()]
        if len(roots) != 1:
            raise VerificationError(
                f"expected one package directory, found {len(roots)}"
            )
        root = roots[0]
        verify_manifest(root)

        executable = root / "aurora-host-experiment.exe"
        if not executable.is_file():
            raise VerificationError("package has no aurora-host-experiment.exe")
        forbidden = [
            path.name for path in root.rglob("*")
            if path.name.lower() in {"msvcr120.dll", "libcmt.lib"}
        ]
        if forbidden:
            raise VerificationError(
                "package must not bundle the CRT: " + ", ".join(sorted(forbidden))
            )
        crt_errors = verify_crt_imports(executable)
        if crt_errors:
            raise VerificationError(
                "package CRT imports are invalid:\n" + "\n".join(crt_errors)
            )

        version = run(executable, ["--version"], root)
        if "aurora-host-experiment" not in version:
            raise VerificationError(f"unexpected version output: {version!r}")

        checked = run(executable, ["--check", "samples/hello.scene.json"], root)
        if "scene OK:" not in checked:
            raise VerificationError(f"check did not accept the sample: {checked!r}")

        for scene in ("hello", "image"):
            output = root / "out" / f"{scene}.ppm"
            run(
                executable,
                ["--render", f"samples/{scene}.scene.json", "--out", str(output)],
                root,
            )
            width, height = verify_ppm(output)
            print(f"render: {scene} {width}x{height}")

        verify_control(executable, root)
        print("CRT imports: Windows msvcrt.dll only")
        print("control: ping, tree, and close verified")
        print(f"package verification passed: {package}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True, help="package zip to extract and test")
    args = parser.parse_args()
    verify_package(Path(args.package).resolve())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (VerificationError, OSError, subprocess.SubprocessError) as error:
        print(f"package verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)

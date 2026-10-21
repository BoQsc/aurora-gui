#!/usr/bin/env python3
"""Build a portable, deterministically staged windows-x64 host package."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
EXECUTABLE = "aurora-host-experiment.exe"
BUILD_CONFIG = "host"


class PackagingError(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def copy_file(source: Path, target: Path) -> None:
    if not source.is_file():
        raise PackagingError(f"required package input is missing: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def dmd_license() -> Path:
    compiler = shutil.which("dmd")
    if not compiler:
        raise PackagingError("dmd is not on PATH")
    compiler_path = Path(compiler).resolve()
    for parent in compiler_path.parents:
        candidate = parent / "license.txt"
        if candidate.is_file():
            return candidate
    raise PackagingError(
        f"could not find the DMD/Phobos license.txt above {compiler_path}"
    )


def build_executable(destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    command = [
        "dub",
        "build",
        "--config=" + BUILD_CONFIG,
        "--build=release",
        "--dest=" + str(destination),
    ]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise PackagingError(
            "release build failed:\n"
            + " ".join(command)
            + "\n"
            + completed.stdout
            + completed.stderr
        )
    executable = destination / EXECUTABLE
    if not executable.is_file():
        raise PackagingError(f"release build did not produce {executable}")
    return executable


def package_readme(version: str) -> str:
    return f"""Aurora host experiment {version} (Windows x64)

This package contains the isolated retained-scene host, sample scenes, their
relative image asset, and the applicable license notices.

Runtime
  Windows x64 with the system msvcrt.dll. No Visual C++ Redistributable is
  required; the package does not bundle a redistributable CRT.

Run from this directory
  {EXECUTABLE} --version
  {EXECUTABLE} --check samples/hello.scene.json
  {EXECUTABLE} --render samples/hello.scene.json --out out/hello.ppm
  {EXECUTABLE} --render samples/image.scene.json --out out/image.ppm
  {EXECUTABLE} --run samples/hello.scene.json
  {EXECUTABLE} --run samples/hello.scene.json --control

PACKAGING.md defines the package contract and control-channel format.
MANIFEST.sha256 is the integrity authority for the staged files.
"""


def write_manifest(stage: Path) -> None:
    entries = []
    for path in sorted(stage.rglob("*")):
        if not path.is_file() or path.name == "MANIFEST.sha256":
            continue
        entries.append(f"{sha256(path)}  {path.relative_to(stage).as_posix()}")
    (stage / "MANIFEST.sha256").write_text(
        "\n".join(entries) + "\n", encoding="utf-8", newline="\n"
    )


def write_metadata(stage: Path, version: str) -> None:
    metadata = {
        "name": "aurora-host-experiment",
        "version": version,
        "platform": "windows-x64",
        "entryPoint": EXECUTABLE,
        "build": {
            "program": "dub",
            "config": BUILD_CONFIG,
            "buildType": "release",
        },
        "runtimePrerequisite": "None; uses Windows system msvcrt.dll",
        "bundledRuntime": False,
    }
    (stage / "PACKAGE-METADATA.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n"
    )


def stage_package(stage: Path, executable: Path, version: str) -> None:
    copy_file(executable, stage / EXECUTABLE)
    copy_file(ROOT / "PACKAGING.md", stage / "PACKAGING.md")
    copy_file(ROOT / "LICENSE", stage / "licenses" / "LICENSE")
    copy_file(ROOT / "LICENSE-CC0.txt", stage / "licenses" / "LICENSE-CC0.txt")
    copy_file(
        ROOT / "THIRD-PARTY-NOTICES.md",
        stage / "licenses" / "THIRD-PARTY-NOTICES.md",
    )
    copy_file(
        REPO / "vendor" / "aurora-d-0.4.5" / "LICENSE",
        stage / "licenses" / "aurora-d" / "LICENSE",
    )
    copy_file(
        REPO / "vendor" / "aurora-d-0.4.5" / "LICENSE-UNICODE.txt",
        stage / "licenses" / "aurora-d" / "LICENSE-UNICODE.txt",
    )
    copy_file(
        REPO / "vendor" / "aurora-d-0.4.5" / "Microsoft-Terminal-MIT.txt",
        stage / "licenses" / "aurora-d" / "Microsoft-Terminal-MIT.txt",
    )
    copy_file(
        REPO / "vendor" / "aurora-standard" / "LICENSE",
        stage / "licenses" / "aurora-standard" / "LICENSE",
    )
    copy_file(
        REPO / "vendor" / "aurora-standard" / "LICENSE-UNICODE.txt",
        stage / "licenses" / "aurora-standard" / "LICENSE-UNICODE.txt",
    )
    copy_file(dmd_license(), stage / "licenses" / "DMD-license.txt")
    shutil.copytree(ROOT / "samples", stage / "samples")
    (stage / "README.md").write_text(
        package_readme(version), encoding="utf-8", newline="\n"
    )
    write_metadata(stage, version)
    write_manifest(stage)


def write_zip(stage: Path, target: Path) -> None:
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(stage.rglob("*")):
            if not path.is_file():
                continue
            name = f"{stage.name}/{path.relative_to(stage).as_posix()}"
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build the self-contained aurora-host Windows package."
    )
    parser.add_argument(
        "--out",
        required=True,
        help="new package directory, for example build/package/aurora-host-0.1.0-win64",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="remove an existing package directory and zip at the requested path first",
    )
    parser.add_argument(
        "--executable",
        help="stage this already-built host executable instead of running dub",
    )
    args = parser.parse_args()

    output = (ROOT / args.out).resolve()
    zip_path = output.parent / (output.name + ".zip")
    if output.exists() and not args.clean:
        raise PackagingError(f"package directory already exists: {output}")
    if zip_path.exists() and not args.clean:
        raise PackagingError(f"package archive already exists: {zip_path}")

    version = json.loads((ROOT / "dub.json").read_text(encoding="utf-8"))["version"]
    name = f"aurora-host-{version}-win64"
    if output.name != name:
        raise PackagingError(
            f"output directory must be named {name!r} to keep the package layout stable"
        )
    if output.exists():
        if output.is_dir():
            shutil.rmtree(output)
        else:
            output.unlink()
    if zip_path.exists():
        zip_path.unlink()

    output.parent.mkdir(parents=True, exist_ok=True)
    build_dir = output.parent / (output.name + "-build")
    if not args.executable and build_dir.exists():
        shutil.rmtree(build_dir)
    try:
        with tempfile.TemporaryDirectory(prefix="aurora-host-package-") as temporary:
            work = Path(temporary)
            if args.executable:
                executable = (ROOT / args.executable).resolve()
                if not executable.is_file():
                    raise PackagingError(f"executable is missing: {executable}")
            else:
                executable = build_executable(build_dir)
            stage = work / "stage" / name
            stage_package(stage, executable, version)
            shutil.copytree(stage, output)
            write_zip(output, zip_path)
    finally:
        if not args.executable:
            shutil.rmtree(build_dir, ignore_errors=True)

    print(f"package: {output}")
    print(f"archive: {zip_path}")
    print(f"executable sha256: {sha256(output / EXECUTABLE)}")
    print(f"files: {sum(1 for path in output.rglob('*') if path.is_file())}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PackagingError, OSError, subprocess.SubprocessError) as error:
        print(f"package failed: {error}", file=sys.stderr)
        raise SystemExit(1)

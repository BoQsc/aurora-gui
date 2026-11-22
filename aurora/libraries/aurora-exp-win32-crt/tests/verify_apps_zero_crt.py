#!/usr/bin/env python3
"""Link the portable Aurora applications with the Aurora CRT.

For each application, this gate generates a fixture from the app's real
`dub.json` (source paths, string imports, libraries, versions), adds the Aurora
CRT and `/NODEFAULTLIB` flags, builds it, patches the PE TLS directory, and
requires no Microsoft CRT import.

Run from anywhere; paths resolve from the repository root.

Usage: verify_apps_zero_crt.py [--app NAME]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"
OUTPUT = REPO / "build" / "zero-crt" / "apps"

sys.path.insert(0, str(PACKAGE / "tests"))
from verify_zero_crt import CheckError  # noqa: E402

sys.path.insert(0, str(REPO / "experiments" / "aurora-host" / "tools"))
from pe_imports import read_imports  # noqa: E402

FORBIDDEN_PREFIXES = (
    "msvcrt", "msvcr", "ucrt", "vcruntime", "api-ms-win-crt",
)

APPLICATIONS = {
    "aurora-cut": REPO / "aurora-cut",
    "aurora-designer": REPO / "aurora" / "aurora-designer",
    "aurora-font-viewer": REPO / "aurora-font-viewer",
    "aurora-image-viewer": REPO / "aurora-image-viewer",
    "aurora-notepad": REPO / "aurora-notepad",
    "aurora-opencode": REPO / "aurora-opencode",
    "aurora-opencode-pro": REPO / "aurora-opencode-pro",
    "aurora-remote": REPO / "aurora-remote",
    "aurora-stream": REPO / "aurora-stream",
}

NODEFAULTLIB = [
    "/NODEFAULTLIB:msvcrt",
    "/NODEFAULTLIB:libcmt",
    "/NODEFAULTLIB:oldnames",
    "/ENTRY:mainCRTStartup",
    "kernel32.lib",
    "/EXPORT:_tls_used",
    "/EXPORT:_tls_index",
]


def dub_path() -> str:
    found = shutil.which("dub")
    if found:
        return found
    fallback = Path(r"C:\D\dmd2\windows\bin64\dub.exe")
    if fallback.is_file():
        return str(fallback)
    raise CheckError("dub was not found on PATH")


def resolve(app_dir: Path, value: str) -> str:
    path = Path(value)
    return str(path if path.is_absolute() else (app_dir / path).resolve())


def relative(target: Path | str, fixture_dir: Path) -> str:
    return os.path.relpath(str(target), str(fixture_dir)).replace("\\", "/")


def selected_config(data: dict) -> dict:
    if data.get("mainSourceFile"):
        return data
    for config in data.get("configurations", []):
        if config.get("mainSourceFile") and config.get("targetType", "executable") == "executable":
            return config
    raise CheckError("no executable configuration found")


def build_fixture(name: str, app_dir: Path) -> Path:
    manifest = app_dir / "dub.json"
    if not manifest.is_file():
        raise CheckError(f"{name}: missing {manifest}")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    config = selected_config(data)

    source_paths: list[str] = []
    for value in [*data.get("sourcePaths", []), *config.get("sourcePaths", [])]:
        resolved = resolve(app_dir, value)
        if resolved not in source_paths:
            source_paths.append(resolved)
    string_paths: list[str] = []
    for value in [*data.get("stringImportPaths", []),
                  *config.get("stringImportPaths", [])]:
        resolved = resolve(app_dir, value)
        if resolved not in string_paths:
            string_paths.append(resolved)

    libraries: list[str] = []
    for value in [*data.get("libs-windows", []), *config.get("libs-windows", [])]:
        if value not in libraries:
            libraries.append(value)

    dflags: list[str] = []
    for value in [*data.get("dflags-windows", []),
                  *config.get("dflags-windows", [])]:
        if value not in dflags:
            dflags.append(value)

    versions: list[str] = []
    for value in [*data.get("versions", []), *config.get("versions", [])]:
        if value not in versions:
            versions.append(value)

    subsystem_flags: list[str] = []
    for value in [*data.get("lflags-windows", []),
                  *config.get("lflags-windows", [])]:
        if value.startswith("/SUBSYSTEM:") and value not in subsystem_flags:
            subsystem_flags.append(value)

    fixture_dir = OUTPUT / name

    dependencies: dict[str, dict[str, str]] = {}
    for dep_name, dep in data.get("dependencies", {}).items():
        if isinstance(dep, dict) and "path" in dep:
            dependencies[dep_name] = {
                "path": relative(resolve(app_dir, dep["path"]), fixture_dir)
            }
        else:
            dependencies[dep_name] = dep
    dependencies["aurora-exp-win32-crt"] = {
        "path": relative(PACKAGE, fixture_dir)
    }

    main_absolute = Path(resolve(app_dir, config["mainSourceFile"]))
    excluded: list[str] = []
    for path in source_paths:
        root = Path(path)
        if root == app_dir or app_dir in root.parents:
            for candidate in root.rglob("*.d"):
                if candidate.resolve() == main_absolute.resolve():
                    continue
                try:
                    text = candidate.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                if "int main(" in text:
                    excluded.append(relative(candidate, fixture_dir))

    fixture = {
        "name": name + "-zero-crt",
        "description": f"Verification fixture: {name} linked with the Aurora CRT",
        "authors": data.get("authors", ["Aurora libraries"]),
        "copyright": data.get("copyright", "Copyright (C) 2026 aurora-gui contributors"),
        "license": "0BSD",
        "sourcePaths": [relative(path, fixture_dir) for path in source_paths],
        "stringImportPaths": [relative(path, fixture_dir) for path in string_paths],
        "targetName": name + "-zero-crt",
        "targetType": "executable",
        "targetPath": "build",
        "mainSourceFile": relative(resolve(app_dir, config["mainSourceFile"]),
                                   fixture_dir),
        "sourceFiles": [relative(resolve(app_dir, config["mainSourceFile"]),
                                 fixture_dir)],
        "excludedSourceFiles": sorted(set(excluded)),
        "versions": versions,
        "libs-windows": libraries,
        "dflags-windows": [*dflags, "-mscrtlib=msvcrt"],
        "lflags-windows": [*NODEFAULTLIB, *subsystem_flags],
        "buildTypes": {
            "portable-release": {
                "buildOptions": ["releaseMode", "optimize", "inline"],
                "dflags-windows-dmd": ["-mscrtlib=libcmt"],
                "dflags-windows-ldc": ["-mscrtlib=libcmt"],
            }
        },
        "dependencies": dependencies,
    }

    if "subConfigurations" in data:
        fixture["subConfigurations"] = data["subConfigurations"]

    fixture_dir.mkdir(parents=True, exist_ok=True)
    (fixture_dir / "dub.json").write_text(
        json.dumps(fixture, indent=2) + "\n", encoding="utf-8"
    )
    return fixture_dir


def pe_subsystem(executable: Path) -> int:
    data = executable.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    optional = pe + 24
    return struct.unpack_from("<H", data, optional + 68)[0]


def verify_app(name: str, app_dir: Path, environment: dict[str, str]) -> list[str]:
    fixture = build_fixture(name, app_dir)
    result = subprocess.run(
        [dub_path(), "build", "--compiler=dmd"],
        cwd=fixture,
        capture_output=True,
        text=True,
        timeout=900,
        env=environment,
    )
    if result.returncode != 0:
        raise CheckError(
            f"{name}: build failed\n" + result.stdout + result.stderr
        )
    executable = fixture / "build" / (name + "-zero-crt.exe")
    if not executable.is_file():
        raise CheckError(f"{name}: no executable produced")
    fixture_data = json.loads(
        (fixture / "dub.json").read_text(encoding="utf-8"))
    expected = 2 if any(flag.startswith("/SUBSYSTEM:WINDOWS")
                        for flag in fixture_data["lflags-windows"]) else 3
    actual = pe_subsystem(executable)
    if actual != expected:
        raise CheckError(
            f"{name}: PE subsystem {actual}, expected {expected}; "
            "the app's /SUBSYSTEM flag was not propagated")
    imports = read_imports(executable)
    forbidden = sorted(
        dll for dll in imports if dll.startswith(FORBIDDEN_PREFIXES)
    )
    if forbidden:
        raise CheckError(
            f"{name}: imports Microsoft CRT libraries: {', '.join(forbidden)}"
        )
    return sorted(imports)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", choices=sorted(APPLICATIONS))
    args = parser.parse_args()

    names = [args.app] if args.app else list(APPLICATIONS)
    built = subprocess.run(
        [dub_path(), "build", "--config=link", "--compiler=dmd"],
        cwd=COFF, capture_output=True, text=True, timeout=300,
    )
    if built.returncode != 0:
        print("coff-link build failed\n" + built.stdout + built.stderr,
              file=sys.stderr)
        return 1
    environment = os.environ.copy()
    environment["LINKCMD64"] = str(LINKER)
    failures: list[tuple[str, str]] = []
    for name in names:
        try:
            imports = verify_app(name, APPLICATIONS[name], environment)
            print(f"{name}: zero-CRT link ok — {', '.join(imports)}")
        except CheckError as error:
            failures.append((name, str(error)))
            print(f"{name}: FAILED", file=sys.stderr)
    if failures:
        for name, message in failures:
            print(f"--- {name} ---\n{message}", file=sys.stderr)
        print(f"portable-app zero-CRT verification failed: "
              f"{len(failures)}/{len(names)} apps", file=sys.stderr)
        return 1
    print(f"portable-app zero-CRT verification passed: {len(names)} apps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

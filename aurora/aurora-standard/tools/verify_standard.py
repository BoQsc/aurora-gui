#!/usr/bin/env python3
"""Verify the frozen aurora-standard package.

The verifier is intentionally self-contained: it uses the Python standard
library and a D compiler on PATH. It writes only to a temporary directory.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "MANIFEST.sha256"
SOURCE = ROOT / "source"
DEFAULT_SPEC = ROOT / "spec" / "unicode" / "17.0.0"
EXCLUDED_DIRS = {".dub", "__pycache__", "build"}
EXCLUDED_NAMES = {"MANIFEST.sha256", "dub.selections.json"}
EXCLUDED_SUFFIXES = {".exe", ".obj", ".pdb", ".lib"}

EXPECTED_RESULTS = {
    "GraphemeBreakTest": (766, 2756),
    "LineBreakTest": (19338, 79825),
    "BidiCharacterTest": (91707, 717503),
    "BidiTest": (770241, 3049617),
}


class VerificationError(Exception):
    pass


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_bytes(path: pathlib.Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n")


def package_files() -> list[pathlib.Path]:
    result: list[pathlib.Path] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDED_DIRS for part in relative.parts):
            continue
        if path.name in EXCLUDED_NAMES or path.suffix.lower() in EXCLUDED_SUFFIXES:
            continue
        result.append(path)
    return result


def write_manifest() -> None:
    lines = [
        f"{sha256_file(path)}  {path.relative_to(ROOT).as_posix()}\n"
        for path in package_files()
    ]
    MANIFEST.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote {MANIFEST} ({len(lines)} entries)")


def verify_manifest() -> None:
    if not MANIFEST.is_file():
        raise VerificationError("MANIFEST.sha256 is missing")
    expected: dict[str, str] = {}
    for number, line in enumerate(
        MANIFEST.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        digest, separator, relative = line.partition("  ")
        if not separator or len(digest) != 64:
            raise VerificationError(f"invalid manifest line {number}")
        expected[relative] = digest
    actual = {
        path.relative_to(ROOT).as_posix()
        for path in package_files()
    }
    missing = sorted(set(expected) - actual)
    extra = sorted(actual - set(expected))
    if missing or extra:
        raise VerificationError(
            "manifest coverage differs: "
            f"missing={missing[:10]} extra={extra[:10]}"
        )
    for relative, digest in expected.items():
        if sha256_file(ROOT / relative) != digest:
            raise VerificationError(f"manifest hash mismatch: {relative}")
    print(f"manifest: {len(expected)} files verified")


def verify_versions() -> None:
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    metadata = json.loads((ROOT / "dub.json").read_text(encoding="utf-8"))
    if metadata.get("version") != version:
        raise VerificationError(
            f"VERSION {version} differs from dub.json {metadata.get('version')}"
        )
    if metadata.get("name") != "aurora-standard":
        raise VerificationError("dub.json name is not aurora-standard")
    print(f"version: {version}")


def verify_regeneration() -> None:
    with tempfile.TemporaryDirectory(prefix="aurora-standard-gen-") as temp_name:
        generated = pathlib.Path(temp_name) / "properties.d"
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "tools" / "generate_unicode.py"),
                "--data",
                str(DEFAULT_SPEC),
                "--output",
                str(generated),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise VerificationError(
                "Unicode generator failed:\n" + completed.stderr
            )
        checked_in = SOURCE / "aurora" / "standard" / "text" / "unicode" / "properties.d"
        if normalized_bytes(generated) != normalized_bytes(checked_in):
            raise VerificationError(
                "generated Unicode table differs from source/aurora/standard/text/unicode/properties.d"
            )
    print("regeneration: byte-identical after LF normalization")


def dmd_executable() -> str:
    executable = shutil.which("dmd")
    if not executable:
        raise VerificationError("dmd is not on PATH")
    return executable


def verify_api_surface(dmd: str, temp: pathlib.Path) -> None:
    api_json = temp / "api.json"
    modules = [
        SOURCE / "aurora" / "standard" / "text" / "unicode" / "properties.d",
        SOURCE / "aurora" / "standard" / "text" / "unicode" / "bidi.d",
        SOURCE / "aurora" / "standard" / "text" / "unicode" / "grapheme.d",
        SOURCE / "aurora" / "standard" / "text" / "unicode" / "linebreak.d",
    ]
    completed = subprocess.run(
        [dmd, "-o-", f"-Xf={api_json}", f"-I{SOURCE}", "-i", *map(str, modules)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise VerificationError(
            "compiler API extraction failed:\n" + completed.stderr
        )
    compiled = {module["name"]: module for module in json.loads(api_json.read_text(encoding="utf-8"))}
    documented = json.loads((ROOT / "api" / "surface.json").read_text(encoding="utf-8"))
    documented_modules = {module["name"]: module for module in documented["modules"]}
    if set(compiled) != set(documented_modules):
        raise VerificationError(
            "API module set differs: "
            f"compiled={sorted(compiled)} documented={sorted(documented_modules)}"
        )
    for name, module in documented_modules.items():
        public = {
            member["name"]
            for member in compiled[name].get("members", [])
            if member.get("protection") == "public"
            and not member["name"].startswith("__unittest")
        }
        described = {symbol["name"] for symbol in module["symbols"]}
        if public != described:
            raise VerificationError(
                f"API surface mismatch for {name}: "
                f"missing={sorted(public - described)} extra={sorted(described - public)}"
            )
    print(f"api surface: {len(documented_modules)} modules verified")


def run_checked(command: list[str], *, cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd or ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise VerificationError(
            "command failed: " + " ".join(command) + "\n" + completed.stdout + completed.stderr
        )
    return completed


def verify_consumer(dmd: str, temp: pathlib.Path) -> None:
    executable = temp / "consumer.exe"
    run_checked(
        [
            dmd,
            f"-I{SOURCE}",
            "-i",
            f"-od={temp}",
            f"-of={executable}",
            str(ROOT / "tests" / "consumer.d"),
        ]
    )
    completed = run_checked([str(executable)])
    if "aurora-standard consumer: OK" not in completed.stdout:
        raise VerificationError("consumer test did not report success")
    print("consumer: documented API compiles and passes")


def verify_conformance(dmd: str, temp: pathlib.Path) -> None:
    executable = temp / "unicode-conformance.exe"
    run_checked(
        [
            dmd,
            f"-I{SOURCE}",
            "-i",
            f"-od={temp}",
            f"-of={executable}",
            str(ROOT / "tests" / "unicode_conformance.d"),
        ]
    )
    completed = run_checked([str(executable), str(DEFAULT_SPEC)])
    for name, (cases, boundaries) in EXPECTED_RESULTS.items():
        pattern = rf"{name}\s+(\d+)/(\d+) cases; (\d+)/(\d+) boundaries"
        match = re.search(pattern, completed.stdout)
        if not match:
            raise VerificationError(f"missing conformance result for {name}")
        actual = tuple(int(value) for value in match.groups())
        if actual != (cases, cases, boundaries, boundaries):
            raise VerificationError(
                f"conformance result changed for {name}: {actual}"
            )
    print("conformance: 882052 cases and 3849701 boundaries verified")


def main() -> int:
    if "--write-manifest" in sys.argv[1:]:
        write_manifest()
        return 0

    try:
        verify_manifest()
        verify_versions()
        verify_regeneration()
        dmd = dmd_executable()
        with tempfile.TemporaryDirectory(prefix="aurora-standard-verify-") as temp_name:
            temp = pathlib.Path(temp_name)
            verify_api_surface(dmd, temp)
            verify_consumer(dmd, temp)
            verify_conformance(dmd, temp)
    except VerificationError as error:
        print(f"aurora-standard verification failed: {error}", file=sys.stderr)
        return 1
    print("aurora-standard verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

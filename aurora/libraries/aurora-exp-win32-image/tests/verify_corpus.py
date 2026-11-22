#!/usr/bin/env python3
"""Exercise the binary-format laboratory end to end.

Covers, in order:

* byte-identical rebuild of every readable .exe/.dll in the repository;
* import-table agreement with experiments/aurora-host/tools/pe_imports.py;
* generation of a minimal PE32+ executable that actually runs and exits 0;
* timestamp stamping that changes exactly the four timestamp bytes;
* in-place resource replacement that survives reload and shrinks the slot;
* the malformed-image and mutation self-tests built into the instrument.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import filecmp
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
TOOL = REPO / "aurora" / "libraries" / "aurora-exp-win32-image" / "pe-roundtrip.exe"
LOADER = REPO / "aurora" / "libraries" / "aurora-exp-win32-image" / "pe-load.exe"
EMIT_LOAD_TEST = REPO / "aurora" / "libraries" / "aurora-exp-win32-image" / "pe-emit-load-test.exe"
OUT = REPO / "build" / "crt-probe" / "verify"
SKIP_PARTS = {".dub", "build", "dist", "build-validation"}

sys.path.insert(0, str(REPO / "experiments" / "aurora-host" / "tools"))
from pe_imports import read_imports  # noqa: E402
from check_pe_icon import verify_pe_icon  # noqa: E402

RESOURCE_LINE = re.compile(
    r"resource type=.*?\((\d+)\) name=#(\d+) lang=(\d+) rva=0x[0-9A-F]+ size=(\d+)"
)


class CheckError(Exception):
    pass


def run_tool(*arguments: object) -> str:
    result = subprocess.run(
        [str(TOOL), *map(str, arguments)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise CheckError(
            "tool failed: " + " ".join(map(str, arguments))
            + "\nstdout:\n" + result.stdout + "\nstderr:\n" + result.stderr
        )
    return result.stdout


def parse_imports(output: str) -> dict[str, int]:
    imports: dict[str, int] = {}
    for line in output.splitlines():
        if line.startswith("dll "):
            _, dll, count = line.split()
            imports[dll.lower()] = int(count)
    return imports


def check_oracle(source: Path, output: str) -> None:
    expected = read_imports(source)
    actual = parse_imports(output)
    if set(actual) != {name.lower() for name in expected}:
        raise CheckError(f"{source}: imported DLL set differs from the oracle")
    for name, symbols in expected.items():
        if actual[name.lower()] != len(symbols):
            raise CheckError(f"{source}: {name} symbol count differs from the oracle")


def check_corpus() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    images = [
        path
        for path in [*REPO.rglob("*.exe"), *REPO.rglob("*.dll")]
        if not any(part in SKIP_PARTS for part in path.parts)
    ]
    checked = 0
    for image in sorted(images):
        try:
            with image.open("rb"):
                pass
        except OSError:
            continue
        target = OUT / f"{image.parent.name}-{image.name}"
        output = run_tool(image, target, "--quiet")
        if "rebuilt=identical" not in output:
            raise CheckError(f"{image}: rebuild was not identical")
        if not filecmp.cmp(image, target, shallow=False):
            raise CheckError(f"{image}: written bytes differ from the input")
        checked += 1
    if checked < 30:
        raise CheckError(f"corpus shrank to {checked} images")
    return checked


def check_emit() -> None:
    emitted = OUT / "emitted-hello.exe"
    output = run_tool("--emit", emitted)
    if "sections=2" not in output or "directory 5 model=relocations" not in output:
        raise CheckError("emitted image is not relocatable")
    completed = subprocess.run([str(emitted)], capture_output=True, timeout=30)
    if completed.returncode != 0:
        raise CheckError(f"emitted executable exited {completed.returncode}")
    reloaded = run_tool(emitted, "--quiet")
    if "rebuilt=identical" not in reloaded or "imports=0" not in reloaded:
        raise CheckError("emitted image did not re-parse as a clean identity")


def run_loader(*arguments: object) -> tuple[int, str]:
    result = subprocess.run(
        [str(LOADER), *map(str, arguments)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result.returncode, result.stdout + result.stderr


def check_loader() -> None:
    emitted = OUT / "emitted-hello.exe"
    code, output = run_loader(emitted, "--map-only")
    if code != 0:
        raise CheckError("loader map-only failed: " + output)
    for marker in ("mapped=yes", "relocations=0", "imports=0", "section .text at="):
        if marker not in output:
            raise CheckError(f"loader output is missing {marker}: " + output)
    code, output = run_loader(emitted)
    if code != 0 or "threadExit=0" not in output:
        raise CheckError("loader did not run the entry to exit code 0: " + output)


def check_emit_load_test() -> None:
    result = subprocess.run(
        [str(EMIT_LOAD_TEST)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0 or "emit-load: ok" not in result.stdout:
        raise CheckError(
            "emit-load end-to-end test failed:\n"
            + result.stdout + result.stderr
        )


def check_stamp(source: Path) -> None:
    stamped = OUT / "stamped.exe"
    output = run_tool(source, stamped, "--stamp", "1234567890")
    before = source.read_bytes()
    after = stamped.read_bytes()
    if len(before) != len(after):
        raise CheckError("stamp changed the image size")
    differences = [index for index, pair in enumerate(zip(before, after)) if pair[0] != pair[1]]
    lfanew = int.from_bytes(before[0x3C:0x40], "little")
    expected = list(range(lfanew + 8, lfanew + 12))
    if differences != expected:
        raise CheckError(f"stamp changed {differences}, expected {expected}")
    reloaded = run_tool(stamped, "--quiet")
    if "timeDateStamp=1234567890" not in reloaded:
        raise CheckError("stamp did not survive re-parsing")
    if "rebuilt=identical" not in reloaded:
        raise CheckError("stamped image did not rebuild identically")


def check_resource(source: Path) -> None:
    output = run_tool(source)
    match = RESOURCE_LINE.search(output)
    if not match:
        raise CheckError("source image has no ID-named resource to replace")
    type_id, name_id, language_id, size = (int(value) for value in match.groups())
    selector = f"{type_id}/{name_id}/{language_id}"

    original = OUT / "resource-original.bin"
    run_tool(source, "--dump-resource", selector, original)
    data = original.read_bytes()
    if len(data) != size:
        raise CheckError("dumped resource size differs from the reported size")

    shortened = OUT / "resource-shortened.bin"
    shortened.write_bytes(data[:-1])
    replaced = OUT / "resource-replaced.exe"
    run_tool(source, replaced, "--replace-resource", selector, shortened)

    extracted = OUT / "resource-extracted.bin"
    run_tool(replaced, "--dump-resource", selector, extracted)
    if extracted.read_bytes() != data[:-1]:
        raise CheckError("replaced resource bytes do not round-trip")

    replaced_output = run_tool(replaced)
    replacement = RESOURCE_LINE.search(replaced_output)
    if not replacement or int(replacement.group(4)) != size - 1:
        raise CheckError("replaced resource size was not updated")
    if "rebuilt=identical" not in run_tool(replaced, "--quiet"):
        raise CheckError("replaced image did not rebuild identically")


def check_self_tests(source: Path, expect_resources: bool) -> None:
    output = run_tool(source, "--self-test")
    for marker in (
        "truncated file=rejected",
        "broken PE signature=rejected",
        "impossible section count=rejected",
        "self-test=ok",
        "timestamp-stamp=4-bytes",
    ):
        if marker not in output:
            raise CheckError(f"{source}: self-test missing {marker}")
    if expect_resources and "resource-replace=ok" not in output:
        raise CheckError(f"{source}: self-test did not exercise resource replacement")


def check_icon_oracle(source: Path) -> int:
    frames = verify_pe_icon(source)
    if frames <= 0:
        raise CheckError(f"{source}: icon oracle found no frames")
    return frames


def main() -> int:
    if not TOOL.is_file():
        print(f"missing tool: {TOOL}", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    host = REPO / "aurora" / "aurora-host" / "aurora-host.exe"
    opencode = REPO / "aurora-opencode-pro" / "aurora-opencode-pro.exe"

    try:
        corpus = check_corpus()
        check_oracle(host, run_tool(host))
        check_oracle(opencode, run_tool(opencode))
        check_emit()
        check_loader()
        check_emit_load_test()
        check_stamp(host)
        check_resource(opencode)
        frames = check_icon_oracle(opencode)
        check_self_tests(host, expect_resources=False)
        check_self_tests(opencode, expect_resources=True)
    except CheckError as error:
        print(f"laboratory verification failed: {error}", file=sys.stderr)
        return 1

    print(f"laboratory verification passed: {corpus} corpus images, generation, "
          f"manual loading, emit-load test, stamping, resource replacement, "
          f"{frames} icon frames, self-tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

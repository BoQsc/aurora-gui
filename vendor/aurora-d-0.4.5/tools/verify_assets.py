#!/usr/bin/env python3
"""Verify Aurora-D source metadata and reproducible generated assets.

This tool intentionally uses only the Python standard library so it can run on
all supported development hosts without installing a package.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

AUTHORED_SUFFIXES = {".d", ".json", ".manifest", ".md", ".ps1", ".py", ".rc", ".sh"}
TOP_TEXT_FILES = {
    ".editorconfig",
    ".gitignore",
    "CHANGELOG.md",
    "LICENSE",
    "LICENSE-UNICODE.txt",
    "README.md",
    "dub.json",
}
REQUIRED_UCD = {
    "ArabicShaping.txt",
    "BidiBrackets.txt",
    "BidiCharacterTest.txt",
    "BidiMirroring.txt",
    "BidiTest.txt",
    "DerivedBidiClass.txt",
    "DerivedCoreProperties.txt",
    "EastAsianWidth.txt",
    "GraphemeBreakProperty.txt",
    "GraphemeBreakTest.txt",
    "LineBreak.txt",
    "LineBreakTest.txt",
    "PropertyValueAliases.txt",
    "Scripts.txt",
    "UnicodeData.txt",
    "emoji-data.txt",
}


class VerificationError(RuntimeError):
    pass


def run(command: list[str], cwd: Path) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=cwd, check=True)


def compare_bytes(expected: Path, actual: Path, label: str) -> None:
    if expected.read_bytes() != actual.read_bytes():
        raise VerificationError(f"{label} is stale: regenerate {expected}")


def package_version(root: Path) -> str:
    metadata = json.loads((root / "dub.json").read_text(encoding="utf-8"))
    version = metadata.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise VerificationError("dub.json must contain a semantic x.y.z version")
    return version


def verify_versions(root: Path, version: str) -> None:
    version_source = (root / "source/aurora/versioning.d").read_text(encoding="utf-8")
    match = re.search(r'enum\s+AuroraVersion\s*=\s*"([^"]+)"\s*;', version_source)
    if match is None or match.group(1) != version:
        raise VerificationError("source/aurora/versioning.d and dub.json versions differ")

    pieces = [int(piece) for piece in version.split(".")]
    for name, expected in zip(
        ("AuroraVersionMajor", "AuroraVersionMinor", "AuroraVersionPatch"), pieces
    ):
        match = re.search(rf"enum\s+{name}\s*=\s*(\d+)\s*;", version_source)
        if match is None or int(match.group(1)) != expected:
            raise VerificationError(f"{name} does not match {version}")

    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    headings = re.findall(
        rf"^##\s+{re.escape(version)}(?:\s|$)", changelog, re.MULTILINE
    )
    if len(headings) != 1:
        raise VerificationError(
            f"CHANGELOG.md must have exactly one {version} release heading; "
            f"found {len(headings)}"
        )

    readme = (root / "README.md").read_text(encoding="utf-8")
    if version not in readme:
        raise VerificationError(f"README.md does not mention version {version}")


def verify_ucd(root: Path) -> None:
    ucd = root / "tools/unicode/17.0.0"
    missing = sorted(name for name in REQUIRED_UCD if not (ucd / name).is_file())
    if missing:
        raise VerificationError("Unicode 17 data is incomplete: " + ", ".join(missing))
    duplicate = root / "ucd-17.0.0"
    if duplicate.exists():
        raise VerificationError("duplicate top-level ucd-17.0.0 directory must not be packaged")


def verify_generated_assets(root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="aurora-assets-") as temp_name:
        temp = Path(temp_name)
        generated_unicode = temp / "properties.d"
        run(
            [
                sys.executable,
                str(root / "tools/generate_unicode.py"),
                "--data",
                str(root / "tools/unicode/17.0.0"),
                "--output",
                str(generated_unicode),
            ],
            root,
        )
        compare_bytes(
            root / "source/aurora/text/unicode/properties.d",
            generated_unicode,
            "generated Unicode property table",
        )

        generated_shader_root = temp / "shader-tree"
        run(
            [
                sys.executable,
                str(root / "tools/make_spirv.py"),
                "--output-root",
                str(generated_shader_root),
            ],
            root,
        )
        for relative in (
            "shaders/aurora.vert.spv",
            "shaders/aurora.frag.spv",
            "source/aurora/vulkan/shaders.d",
        ):
            compare_bytes(root / relative, generated_shader_root / relative, relative)


def markdown_targets(text: str) -> list[str]:
    # Aurora's authored Markdown uses ordinary inline links and images. Reference
    # definitions are checked separately below.
    result = re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", text)
    result += re.findall(r"^\s*\[[^\]]+\]:\s*(\S+)", text, re.MULTILINE)
    return result


def normalize_markdown_target(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<") and ">" in raw:
        raw = raw[1 : raw.index(">")]
    elif " " in raw:
        raw = raw.split(" ", 1)[0]
    return unquote(raw)


def verify_document_links(root: Path) -> None:
    failures: list[str] = []
    markdown_files = sorted([root / "README.md", root / "CHANGELOG.md", *root.glob("docs/*.md")])
    for document in markdown_files:
        text = document.read_text(encoding="utf-8")
        for raw in markdown_targets(text):
            target = normalize_markdown_target(raw)
            if not target or target.startswith("#"):
                continue
            parsed = urlsplit(target)
            if parsed.scheme in {"http", "https", "mailto"}:
                continue
            if parsed.scheme or parsed.netloc:
                failures.append(f"{document.relative_to(root)}: unsupported link {target}")
                continue
            candidate = (document.parent / parsed.path).resolve()
            try:
                candidate.relative_to(root.resolve())
            except ValueError:
                failures.append(f"{document.relative_to(root)}: link escapes package: {target}")
                continue
            if not candidate.exists():
                failures.append(f"{document.relative_to(root)}: missing target {target}")
    if failures:
        raise VerificationError("broken documentation links:\n  " + "\n  ".join(failures))


def authored_files(root: Path) -> list[Path]:
    result: list[Path] = []
    for name in TOP_TEXT_FILES:
        path = root / name
        if path.is_file():
            result.append(path)
    for directory in ("source", "demos", "tests", "scripts", "tools", "docs", "resources"):
        for path in (root / directory).rglob("*"):
            if not path.is_file():
                continue
            if "tools/unicode" in path.as_posix() or "docs/screenshots" in path.as_posix():
                continue
            if path.suffix in AUTHORED_SUFFIXES:
                result.append(path)
    return sorted(set(result))


def verify_text_hygiene(root: Path) -> None:
    problems: list[str] = []
    for path in authored_files(root):
        relative = path.relative_to(root)
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            problems.append(f"{relative}: not UTF-8 ({error})")
            continue
        if "\r" in text:
            problems.append(f"{relative}: contains CR line endings")
        if text and not text.endswith("\n"):
            problems.append(f"{relative}: lacks a final newline")
        for line_number, line in enumerate(text.splitlines(), 1):
            if line.rstrip(" \t") != line:
                problems.append(f"{relative}:{line_number}: trailing whitespace")
                break
    if problems:
        raise VerificationError("source text hygiene failed:\n  " + "\n  ".join(problems))


def verify_script_syntax(root: Path) -> None:
    for script in sorted((root / "scripts").glob("*.sh")):
        run(["sh", "-n", str(script)], root)
    for script in sorted((root / "tools").glob("*.py")):
        try:
            compile(script.read_text(encoding="utf-8"), str(script), "exec")
        except SyntaxError as error:
            raise VerificationError(f"invalid Python syntax in {script.relative_to(root)}: {error}") from error

    if os.name != "nt":
        missing_execute = []
        for script in [*(root / "scripts").glob("*.sh"), *(root / "tools").glob("*.py")]:
            if not (script.stat().st_mode & stat.S_IXUSR):
                missing_execute.append(str(script.relative_to(root)))
        if missing_execute:
            raise VerificationError("scripts are not executable: " + ", ".join(sorted(missing_execute)))


def verify_json(root: Path) -> None:
    for path in sorted(root.rglob("*.json")):
        if any(part in {".dub", "build", "dist"} for part in path.parts):
            continue
        json.loads(path.read_text(encoding="utf-8"))


def verify_no_symlinks(root: Path) -> None:
    links: list[str] = []
    for name in TOP_TEXT_FILES:
        path = root / name
        if path.is_symlink():
            links.append(name)
    for directory in ("source", "demos", "tests", "scripts", "shaders", "tools", "docs", "resources"):
        directory_path = root / directory
        if directory_path.is_symlink():
            links.append(directory)
            continue
        for path in directory_path.rglob("*"):
            if path.is_symlink():
                links.append(str(path.relative_to(root)))
    if links:
        raise VerificationError("release inputs contain symlinks: " + ", ".join(sorted(links)))



def verify_retained_compositor(root: Path) -> None:
    metadata = json.loads((root / "dub.json").read_text(encoding="utf-8"))
    configurations = {config.get("name"): config for config in metadata.get("configurations", [])}
    compositor = configurations.get("compositor-test")
    if compositor is None or compositor.get("mainSourceFile") != "tests/compositor.d":
        raise VerificationError("DUB compositor-test configuration is missing or incorrect")
    latency = configurations.get("latency-test")
    if latency is None or latency.get("mainSourceFile") != "tests/latency.d":
        raise VerificationError("DUB latency-test configuration is missing or incorrect")

    required_files = (
        "source/aurora/render/scene.d",
        "tests/compositor.d",
        "tests/latency.d",
        "docs/RETAINED_COMPOSITOR.md",
    )
    missing_files = [name for name in required_files if not (root / name).is_file()]
    if missing_files:
        raise VerificationError(
            "retained-compositor release files are missing: " + ", ".join(missing_files)
        )

    markers = {
        "source/aurora/widget.d": (
            "setComposited",
            "invalidateTransform",
            "invalidateComposition",
        ),
        "source/aurora/window.d": (
            "transformOnlyFrames",
            "layerOrderBuilds",
            "lateLatchScene",
            "synchronizedPointerLayerId",
            "_orderedLayers",
            "RenderScene",
        ),
        "source/aurora/render/vulkan.d": (
            "GpuLayerGeometry",
            "FrameResources",
            "_presentSemaphores[imageIndex]",
            "scene.lateLatch()",
            "geometryUploads",
            "vkCmdSetViewport",
        ),
        "source/aurora/render/software.d": (
            "CachedLayerSurface",
            "compositePremultiplied",
        ),
        "tests/compositor.d": (
            "layerBuilds == 0",
            "layerOrderBuilds == 0",
            "setVisible(false)",
        ),
        "tests/vulkan_smoke.d": (
            "warmupGeometryUploads() >= 2",
            "rendererStats.geometryUploads == 0",
            "transformOnlyFrames",
        ),
        "tests/latency.d": (
            "lateLatchSamples == 1",
            "synchronizedDragPointer = true",
            "renderer.layerDraws == 2",
        ),
    }
    for relative, required in markers.items():
        text = (root / relative).read_text(encoding="utf-8")
        absent = [marker for marker in required if marker not in text]
        if absent:
            raise VerificationError(
                f"retained compositor markers missing from {relative}: " + ", ".join(absent)
            )

    for script in ("scripts/verify.sh", "scripts/verify.ps1"):
        script_text = (root / script).read_text(encoding="utf-8")
        if "compositor-test" not in script_text:
            raise VerificationError(f"{script} does not run compositor-test")
        if "latency-test" not in script_text:
            raise VerificationError(f"{script} does not run latency-test")



def verify_taskbar_reorder(root: Path) -> None:
    metadata = json.loads((root / "dub.json").read_text(encoding="utf-8"))
    configurations = {config.get("name"): config for config in metadata.get("configurations", [])}
    shell = configurations.get("desktop-shell-test")
    if shell is None or shell.get("mainSourceFile") != "tests/desktop_shell.d":
        raise VerificationError("DUB desktop-shell-test configuration is missing or incorrect")

    markers = {
        "source/aurora/widgets/desktop.d": (
            "class TaskDragProxy",
            "root.add(_dragProxy)",
            "updateDragProxyPosition",
            "visualSlotForEntry",
            "dragAnchorGlobalPosition",
            "moveEntryInternal(originalIndex, finalIndex, false)",
            "onPointerLatch(PointF globalPosition)",
        ),
        "tests/desktop_shell.d": (
            "testPointerLockedTaskDrag",
            "dragAnchorGlobalPosition() == late",
            "entryOrder() == expected",
            "driver.setHostFocus(false)",
        ),
        "tests/shell_visual.d": (
            "aurora-task-drag.ppm",
            "dragAnchorGlobalPosition() == PointF(target)",
        ),
        "docs/DESKTOP_INTERACTIONS.md": (
            "root-level retained drag proxy",
            "model is not mutated during motion",
        ),
    }
    for relative, required in markers.items():
        text = (root / relative).read_text(encoding="utf-8")
        absent = [marker for marker in required if marker not in text]
        if absent:
            raise VerificationError(
                f"pointer-locked taskbar markers missing from {relative}: "
                + ", ".join(absent)
            )

    desktop_source = (root / "source/aurora/widgets/desktop.d").read_text(encoding="utf-8")
    if "reorderFromPointer" in desktop_source:
        raise VerificationError("legacy mutate-on-motion taskbar reorder path remains present")

    for script in ("scripts/verify.sh", "scripts/verify.ps1"):
        if "desktop-shell-test" not in (root / script).read_text(encoding="utf-8"):
            raise VerificationError(f"{script} does not run desktop-shell-test")

    run([sys.executable, str(root / "tools/verify_taskbar_reorder.py")], root)

def verify_windows_manifest(root: Path) -> None:
    import xml.etree.ElementTree as ET

    manifest = root / "resources/windows/aurora.manifest"
    resource = root / "resources/windows/aurora.rc"
    embed_script = root / "scripts/embed-windows-manifest.ps1"
    if not manifest.is_file() or not resource.is_file() or not embed_script.is_file():
        raise VerificationError("Windows DPI deployment resources are missing")
    try:
        tree = ET.parse(manifest)
    except ET.ParseError as error:
        raise VerificationError(f"invalid Windows manifest XML: {error}") from error
    names = {element.tag.rsplit("}", 1)[-1]: (element.text or "").strip()
             for element in tree.iter()}
    if names.get("dpiAwareness") != "PerMonitorV2, PerMonitor":
        raise VerificationError("Windows manifest must declare PerMonitorV2, PerMonitor")
    if names.get("dpiAware") != "true/pm":
        raise VerificationError("Windows manifest must declare true/pm fallback awareness")
    resource_text = resource.read_text(encoding="utf-8")
    if "RT_MANIFEST" not in resource_text or "aurora.manifest" not in resource_text:
        raise VerificationError("Windows resource script does not embed aurora.manifest")
    embed_text = embed_script.read_text(encoding="utf-8")
    if "mt.exe" not in embed_text or "-outputresource:" not in embed_text:
        raise VerificationError("optional Windows manifest script is incomplete")

    # The default DMD ZIP contains lld-link but not the Windows SDK Manifest
    # Tool. Keep ordinary `dub run` independent of mt.exe; manifest-first
    # deployment remains an explicit opt-in through the script above.
    metadata = json.loads((root / "dub.json").read_text(encoding="utf-8"))
    executable_configs = {
        "notepad",
        "file-explorer",
        "desktop",
        "taskbar",
        "font-gallery",
        "vulkan-smoke",
    }
    found = {config.get("name"): config for config in metadata.get("configurations", [])}
    for name in sorted(executable_configs):
        config = found.get(name)
        if config is None:
            raise VerificationError(f"missing DUB executable configuration: {name}")
        flags = [str(flag).lower() for flag in config.get("lflags-windows", [])]
        forbidden = [
            flag for flag in flags
            if flag == "/manifest:embed" or flag.startswith("/manifestinput:")
        ]
        if forbidden:
            raise VerificationError(
                f"DUB configuration {name} requires mt.exe by default: {forbidden}"
            )

    win32_source = (root / "source/aurora/platform/win32.d").read_text(encoding="utf-8")
    required_runtime_markers = (
        "shared static this()",
        "initializeDpiAwareness();",
        "SetProcessDpiAwarenessContext",
        "wmDpiChanged",
    )
    missing = [marker for marker in required_runtime_markers if marker not in win32_source]
    if missing:
        raise VerificationError(
            "Win32 runtime DPI activation is incomplete: " + ", ".join(missing)
        )

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()

    try:
        version = package_version(root)
        verify_versions(root, version)
        verify_ucd(root)
        verify_no_symlinks(root)
        verify_windows_manifest(root)
        verify_retained_compositor(root)
        verify_taskbar_reorder(root)
        verify_json(root)
        verify_script_syntax(root)
        verify_text_hygiene(root)
        verify_document_links(root)
        verify_generated_assets(root)
    except (VerificationError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Asset verification failed: {error}", file=sys.stderr)
        return 1

    d_files = [*root.glob("source/**/*.d"), *root.glob("demos/*.d"), *root.glob("tests/*.d")]
    d_lines = sum(len(path.read_text(encoding="utf-8").splitlines()) for path in d_files)
    print(
        f"Asset verification passed for Aurora-D {version}: "
        f"{len(d_files)} D files, {d_lines:,} D lines."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

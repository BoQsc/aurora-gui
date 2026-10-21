#!/usr/bin/env python3
"""Enforce the aurora-host responsibility boundary."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

POLICY_PATH = Path("protocol") / "aurora-host.boundary.json"
SKIP_DIRS = {".git", ".dub", "__pycache__", "build", "node_modules"}
IMPORT_RE = re.compile(
    r"^\s*(?:(?:public|private|static)\s+)*import\s+([^;]+);",
    re.MULTILINE,
)
MODULE_RE = re.compile(r"^([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)")


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _iter_files(root: Path, names: tuple[str, ...]):
    root = root.resolve()
    for directory, subdirectories, filenames in os.walk(root):
        subdirectories[:] = sorted(
            name for name in subdirectories if name not in SKIP_DIRS
        )
        for name in sorted(filenames):
            if name.endswith(names):
                yield Path(directory) / name


def _imports(text: str):
    for clause in IMPORT_RE.findall(text):
        clause = clause.split(":", 1)[0]
        for item in clause.split(","):
            item = item.strip()
            if "=" in item:
                item = item.split("=", 1)[1].strip()
            match = MODULE_RE.match(item)
            if match:
                yield match.group(1)


def _allowed(module: str, prefixes: list[str]) -> bool:
    return any(
        module == prefix or module.startswith(prefix + ".")
        for prefix in prefixes
    )


def _package_for(path: Path, packages: set[Path]) -> Path | None:
    for parent in path.parents:
        if parent in packages:
            return parent
    return None


def _path(value: object) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        path = value.get("path")
        if isinstance(path, str):
            return path
    return None


def _check_policy(root: Path) -> tuple[list[str], dict | None]:
    policy_file = root / POLICY_PATH
    if not policy_file.is_file():
        return [f"missing boundary policy: {policy_file}"], None
    try:
        policy = _read_json(policy_file)
    except (OSError, ValueError) as error:
        return [f"cannot read boundary policy: {error}"], None
    errors: list[str] = []
    for key in ("package", "namespace", "responsibility"):
        if not isinstance(policy.get(key), str) or not policy[key]:
            errors.append(f"boundary policy has no {key}")
    dependencies = policy.get("allowedDependencies")
    if not isinstance(dependencies, dict) or not dependencies:
        errors.append("boundary policy has no allowedDependencies")
    prefixes = policy.get("allowedImportPrefixes")
    if not isinstance(prefixes, list) or not prefixes or not all(
        isinstance(prefix, str) and prefix for prefix in prefixes
    ):
        errors.append("boundary policy has no allowedImportPrefixes")
    return errors, policy


def _check_manifest(root: Path, policy: dict) -> list[str]:
    errors: list[str] = []
    manifest = root / "dub.json"
    if not manifest.is_file():
        return [f"missing host manifest: {manifest}"]
    try:
        document = _read_json(manifest)
    except (OSError, ValueError) as error:
        return [f"cannot read host manifest: {error}"]
    if document.get("name") != policy["package"]:
        errors.append(
            f"host package is {document.get('name')!r}, "
            f"expected {policy['package']!r}"
        )
    dependencies = document.get("dependencies")
    if not isinstance(dependencies, dict):
        return errors + ["host manifest has no dependencies object"]
    allowed = policy["allowedDependencies"]
    for name in sorted(set(dependencies) - set(allowed)):
        errors.append(f"host has unapproved dependency: {name}")
    for name in sorted(set(allowed) - set(dependencies)):
        errors.append(f"host is missing required dependency: {name}")
    for name, expected in allowed.items():
        actual = _path(dependencies.get(name))
        if actual is None:
            errors.append(f"host dependency {name} has no path")
        elif actual.replace("\\", "/") != expected.replace("\\", "/"):
            errors.append(
                f"host dependency {name} points to {actual!r}, "
                f"expected {expected!r}"
            )
    return errors


def _check_host_imports(root: Path, policy: dict) -> list[str]:
    errors: list[str] = []
    source = root / "source"
    files = list(_iter_files(source, (".d", ".di"))) if source.is_dir() else []
    generated = root / "generated"
    if generated.is_dir():
        files += list(_iter_files(generated, (".d", ".di")))
    if not files:
        return [f"host source directories have no D files: {source}, {generated}"]
    prefixes = policy["allowedImportPrefixes"]
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            errors.append(f"cannot read host source {path}: {error}")
            continue
        for module in sorted(set(_imports(text))):
            if not _allowed(module, prefixes):
                relative = path.relative_to(root)
                errors.append(
                    f"{relative}: host imports forbidden module {module!r}"
                )
    return errors


def _check_leaf(root: Path, repo: Path, policy: dict) -> list[str]:
    errors: list[str] = []
    host_name = policy["package"]
    namespace = policy["namespace"]
    manifests = list(_iter_files(repo, ("dub.json",)))
    packages = {manifest.parent.resolve() for manifest in manifests}
    for manifest in manifests:
        try:
            manifest_relative = manifest.resolve().relative_to(root.resolve())
        except ValueError:
            manifest_relative = None
        if manifest_relative is not None:
            continue
        try:
            document = _read_json(manifest)
        except (OSError, ValueError):
            continue
        dependencies = document.get("dependencies")
        if not isinstance(dependencies, dict):
            continue
        for name, value in dependencies.items():
            if name == host_name:
                errors.append(
                    f"{manifest}: repository package depends on host {host_name!r}"
                )
            dependency_path = _path(value)
            if dependency_path:
                target = (manifest.parent / dependency_path).resolve()
                if target == root.resolve():
                    errors.append(f"{manifest}: dependency path targets the host")

    for path in _iter_files(repo, (".d", ".di")):
        if _package_for(path.resolve(), packages) is None:
            # Evidence captures and ignored build output are not packages and
            # cannot create a build dependency on the host.
            continue
        try:
            path.resolve().relative_to(root.resolve())
            continue
        except ValueError:
            pass
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for module in sorted(set(_imports(text))):
            if module == namespace or module.startswith(namespace + "."):
                errors.append(
                    f"{path}: outside code imports host namespace {module!r}"
                )
    return errors


def verify_boundary(root: Path, repo: Path) -> list[str]:
    """Return all structural responsibility violations."""
    root = Path(root).resolve()
    repo = Path(repo).resolve()
    if not root.is_dir():
        return [f"host root is not a directory: {root}"]
    if not repo.is_dir():
        return [f"repository root is not a directory: {repo}"]
    errors, policy = _check_policy(root)
    if policy is None:
        return errors
    errors += _check_manifest(root, policy)
    errors += _check_host_imports(root, policy)
    errors += _check_leaf(root, repo, policy)
    return sorted(set(errors))


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Enforce aurora-host's responsibility boundary"
    )
    parser.add_argument("--root", type=Path, default=root)
    parser.add_argument("--repo", type=Path, default=root.parents[1])
    arguments = parser.parse_args(argv)
    errors = verify_boundary(arguments.root, arguments.repo)
    if errors:
        print("aurora-host boundary check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("aurora-host boundary check passed: dependencies, imports, and leaf status")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
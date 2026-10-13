"""Record build inputs and verify the public release's exact source commit."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

UPSTREAM_URL = "https://github.com/BoQsc/aurora-gui.git"


def git(package: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(package), *args],
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError("Could not verify build source: " + result.stderr.strip())
    return result.stdout.strip()


def source_inputs(package: Path) -> dict:
    package = package.resolve()
    repository = Path(git(package, "rev-parse", "--show-toplevel")).resolve()
    scopes = [package / "source", package / "shared", package / "assets",
              repository / "aurora-opencode-core/source",
              repository / "vendor/aurora-d-0.4.5/source"]
    files = []
    for scope in scopes:
        if scope.is_dir():
            files.extend(path for path in scope.rglob("*") if path.is_file()
                         and (scope.name == "assets" or path.suffix == ".d"))
    files.extend(path for path in [
        package / "dub.json", repository / "aurora-opencode-core/dub.json",
        package / "tools/embed-icon.bat", package / "tools/build_provenance.py",
        package / "tools/publish-forge.py",
        repository / "scripts/verify-windows-portability.py",
    ] if path.is_file())
    digest = hashlib.sha256()
    for path in sorted(set(files), key=lambda path: path.relative_to(repository).as_posix()):
        digest.update(path.relative_to(repository).as_posix().encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    relevant = [str(scope) for scope in scopes] + [str(path) for path in files
                if path.parent not in scopes and path.suffix != ".d"]
    dirty = bool(git(package, "status", "--porcelain", "--untracked-files=all", "--", *relevant))
    return {"source_commit": git(package, "rev-parse", "HEAD"),
            "source_branch": (package / "assets/maintainer-source-branch.txt").read_text().strip(),
            "source_fingerprint": digest.hexdigest(), "source_dirty": dirty}


def record(package: Path, phase: str, executable: str = "aurora-opencode-pro.exe") -> None:
    pending = package / ("build-source-pending-" + executable + ".json")
    complete = package / ("build-source-" + executable + ".json")
    current = source_inputs(package)
    if phase == "begin":
        pending.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        return
    expected = json.loads(pending.read_text(encoding="utf-8"))
    if current != expected:
        raise RuntimeError("Source changed during compilation. Rebuild before installing or publishing this executable.")
    current["binary_sha256"] = hashlib.sha256((package / executable).read_bytes()).hexdigest()
    temporary = complete.with_suffix(".tmp")
    temporary.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    temporary.replace(complete)
    pending.unlink()


def verify_release_source(package: Path, executable: Path) -> dict:
    recorded = json.loads((package / ("build-source-" + executable.name + ".json")).read_text(encoding="utf-8"))
    current = source_inputs(package)
    if current["source_dirty"]:
        raise RuntimeError("Commit the build source before publishing the public update.")
    if any(recorded.get(key) != value for key, value in current.items()):
        raise RuntimeError("Executable source provenance is stale. Rebuild from the committed source.")
    if recorded.get("binary_sha256") != hashlib.sha256(executable.read_bytes()).hexdigest():
        raise RuntimeError("Executable changed after the recorded build.")
    branch = current["source_branch"]
    remote = git(package, "ls-remote", UPSTREAM_URL, "refs/heads/" + branch)
    if not remote or remote.split()[0] != current["source_commit"]:
        raise RuntimeError("Publish the exact source commit to maintainer branch " + branch + " before the binary update.")
    return {**current, "source_repo": "BoQsc/aurora-gui"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["begin", "finish"])
    parser.add_argument("--exe", default="aurora-opencode-pro.exe")
    args = parser.parse_args()
    record(Path(__file__).resolve().parents[1], args.phase, args.exe)


if __name__ == "__main__":
    main()


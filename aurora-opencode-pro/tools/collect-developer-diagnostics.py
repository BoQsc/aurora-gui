"""Read-only Aurora source diagnostics. Uses only Python's standard library.

Run on the affected computer, then share the generated JSON report.
No settings, source, Git state, or chat files are changed. API keys, chat
contents, raw settings, process command lines, and log contents are excluded.
"""

import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


SKIP_DIRECTORIES = {
    ".git", ".dub", ".cache", "node_modules", "vendor", "build", "bin",
    "dist", "target", "threads", "chats", "logs", "attachments", "models",
    "developer-tools", "__pycache__",
}


def path_from(value):
    return Path(os.path.expandvars(str(value).strip().strip('"'))).absolute()


def metadata(path, hash_image=False):
    result = {"path": str(path)}
    try:
        result["exists"] = path.exists()
        if not result["exists"]:
            return result
        stat = path.stat()
        result.update(is_directory=path.is_dir(), size=stat.st_size,
                      modified_utc=datetime.fromtimestamp(
                          stat.st_mtime, timezone.utc).isoformat())
        if hash_image and path.is_file() and stat.st_size <= 100_000_000:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            result["sha256"] = digest.hexdigest()
    except OSError as error:
        result["error"] = type(error).__name__
    return result


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return (value if isinstance(value, dict) else {}), None
    except (OSError, ValueError) as error:
        # Do not include exception context or snippets of configuration data.
        return {}, type(error).__name__


def directory_entries(path):
    try:
        return sorted(entry.name for entry in path.iterdir())[:100]
    except OSError as error:
        return {"error": type(error).__name__}


def package_probe(path):
    recipe, recipe_error = read_json(path / "dub.json")
    markers = {
        "shared_rebuild": metadata(path / "shared" / "rebuild.d"),
        "dub_json": metadata(path / "dub.json"),
        "dub_sdl": metadata(path / "dub.sdl"),
        "source_app": metadata(path / "source" / "app.d"),
        "git_at_folder": metadata(path / ".git"),
        "git_at_parent": metadata(path.parent / ".git"),
    }
    return {
        "folder": metadata(path),
        "markers": markers,
        "dub_package_name": recipe.get("name") if isinstance(recipe.get("name"), str) else None,
        "dub_json_read_error": recipe_error,
        "recognized_by_1634_build": markers["shared_rebuild"].get("exists", False),
        "folder_entries": directory_entries(path),
        "shared_entries": directory_entries(path / "shared"),
    }


def source_search(root, max_directories=2500, max_depth=7):
    queue = deque([(root, 0)])
    visited = 0
    packages = []
    errors = []
    while queue and visited < max_directories:
        folder, depth = queue.popleft()
        visited += 1
        try:
            if not folder.is_dir() or folder.is_symlink():
                continue
            if (folder / "dub.json").is_file() or (folder / "dub.sdl").is_file() or (
                    folder / "shared" / "rebuild.d").is_file():
                packages.append(package_probe(folder))
            if depth >= max_depth:
                continue
            with os.scandir(folder) as entries:
                for entry in entries:
                    if entry.name.lower() in SKIP_DIRECTORIES or entry.name.startswith("."):
                        continue
                    if os.name == "nt" and entry.stat(follow_symlinks=False).st_file_attributes & 0x400:
                        continue  # Skip junctions/reparse points as well as symlinks.
                    if entry.is_dir(follow_symlinks=False):
                        if len(queue) + visited >= max_directories:
                            return {"root": str(root), "directories_checked": visited,
                                    "truncated": True, "packages": packages, "errors": errors}
                        queue.append((Path(entry.path), depth + 1))
        except OSError as error:
            if len(errors) < 30:
                errors.append({"path": str(folder), "error": type(error).__name__})
    return {"root": str(root), "directories_checked": visited,
            "truncated": bool(queue), "packages": packages, "errors": errors}


def run_read_only(arguments, timeout=10):
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, errors="replace",
            timeout=timeout, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return result.returncode, result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, type(error).__name__


def aurora_processes():
    if os.name != "nt":
        return {"unavailable": "Windows process inspection requires Windows"}
    powershell = shutil.which("powershell.exe")
    if not powershell:
        return {"unavailable": "PowerShell was not found"}
    # Never request CommandLine, environment variables, or process memory.
    command = (
        "$ErrorActionPreference='SilentlyContinue'; "
        "@(Get-Process | Where-Object {$_.ProcessName -like '*aurora*'} | "
        "ForEach-Object { [PSCustomObject]@{ name=$_.ProcessName; pid=$_.Id; "
        "exe=$_.Path; responding=$_.Responding; "
        "started_utc=if ($_.StartTime) {$_.StartTime.ToUniversalTime().ToString('o')} else {$null} "
        "} }) | ConvertTo-Json -Compress"
    )
    status, output = run_read_only([powershell, "-NoProfile", "-NonInteractive", "-Command", command])
    if status != 0:
        return {"unavailable": "Process inspection failed or timed out"}
    try:
        value = json.loads(output) if output else []
        return value if isinstance(value, list) else [value]
    except ValueError:
        return {"unavailable": "Could not parse process inspection"}


def collect(state, exe=None, include_processes=True):
    settings, settings_error = read_json(state / "settings.json")
    # Whitelist only the fields needed to diagnose source discovery.
    safe_settings = {key: settings[key] for key in (
        "developerMode", "developerSourceDir", "developerAutoReapply", "workspace"
    ) if key in settings and isinstance(settings[key], (str, bool))}
    processes = aurora_processes() if include_processes else []
    candidates = [state / "source", state / "source" / "aurora-gui" / "aurora-opencode-pro",
                  state / "source" / "aurora-gui-main" / "aurora-opencode-pro",
                  state / "source" / "aurora-opencode-pro"]
    configured = safe_settings.get("developerSourceDir")
    if isinstance(configured, str) and configured.strip():
        saved = path_from(configured)
        candidates.extend([saved, saved / "aurora-opencode-pro", saved.parent])
    images = [path_from(exe)] if exe else []
    if isinstance(processes, list):
        images.extend(path_from(process["exe"]) for process in processes
                      if isinstance(process, dict) and process.get("exe"))
    for image in images:
        candidates.extend(list(image.parents)[:8])
    probes = []
    seen = set()
    for path in candidates:
        key = str(path).casefold()
        if key not in seen:
            seen.add(key)
            probes.append(package_probe(path))
    tools = {}
    for tool in ("git", "dub", "dmd", "gh"):
        found = shutil.which(tool)
        if not found:
            private = state / "developer-tools" / tool / ("cmd/git.exe" if tool == "git" else "bin/gh.exe")
            found = str(private) if tool in ("git", "gh") and private.is_file() else None
        tools[tool] = {"path": found}
        if found:
            status, version = run_read_only([found, "--version"])
            tools[tool].update(version_exit_code=status, version=version[:500])
    rebuilds = []
    for path in [state / "rebuildstate.json", *(p / "rebuildstate.json" for p in candidates)]:
        if not path.is_file() or any(item["path"] == str(path) for item in rebuilds):
            continue
        value, error = read_json(path)
        rebuilds.append({"path": str(path), "read_error": error, "state": {
            key: value[key] for key in ("status", "phase", "exe", "dir", "startedAt", "finishedAt", "durationMs", "exitCode")
            if key in value and isinstance(value[key], (str, int))
        }})
    return {
        "report_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "computer": {"os": platform.platform(), "python": sys.version.split()[0],
                     "architecture": platform.machine()},
        "state_directory": metadata(state),
        "state_entries": directory_entries(state),
        "source_entries": directory_entries(state / "source"),
        "settings_file": metadata(state / "settings.json"),
        "settings_read_error": settings_error,
        "developer_settings": safe_settings,
        "aurora_processes": processes,
        "executables": [metadata(path, hash_image=True) for path in dict.fromkeys(images)],
        "toolchain": tools,
        "source_candidate_checks": probes,
        "source_search": source_search(state),
        "rebuild_states": rebuilds,
        "excluded": ["API keys and tokens", "chat contents", "raw settings",
                     "log contents", "process command lines", "source file contents"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", help="Optional Aurora state directory override")
    parser.add_argument("--exe", help="Optional path to the affected Aurora executable")
    parser.add_argument("--output", help="Optional report filename")
    args = parser.parse_args()
    appdata = os.environ.get("APPDATA")
    if not args.state_dir and not appdata:
        parser.error("APPDATA was not found; supply --state-dir with the Aurora OpenCode data folder")
    state = path_from(args.state_dir) if args.state_dir else Path(appdata) / "Aurora OpenCode"
    print("Collecting Aurora source diagnostics (no network requests or app changes)...", flush=True)
    report = collect(state, args.exe)
    name = "aurora-developer-diagnostics-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + ".json"
    output = path_from(args.output) if args.output else Path(__file__).resolve().parent / name
    try:
        output.write_text(json.dumps(report, indent=2, ensure_ascii=True), encoding="utf-8")
    except OSError:
        if args.output:
            raise
        output = Path(tempfile.gettempdir()) / name
        output.write_text(json.dumps(report, indent=2, ensure_ascii=True), encoding="utf-8")
    print("Report saved to:", output, flush=True)
    print("Send that JSON file back. API keys and chat contents are excluded.", flush=True)


if __name__ == "__main__":
    main()

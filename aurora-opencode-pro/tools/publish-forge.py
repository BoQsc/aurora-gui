"""Publish a changed Aurora OpenCode EXE to its Forge update channel.

The credential is never included in the executable or repository. Locally it
stays in ``%APPDATA%/Aurora OpenCode/forge-publisher.json``; in CI it comes from
the ``FORGE_PUBLISHER_KEY`` (and optional ``FORGE_PUBLISHER_ID``) environment
variables, so the release workflow can publish with a repository secret and no
config file. Publishing is best effort: a network outage must not turn a
successful build into a failed build.

Dynamic CRT builds are allowed for users with the runtime installed. PE imports
are still validated, and required runtime DLLs are recorded in release metadata.
Use --required in CI or when explicitly publishing: missing credentials and
upload/delivery failures then return a failing exit code.

Two files are published together, so the update check never depends on a server
feature that may not exist:

* ``aurora-opencode-pro.exe`` - the executable itself;
* ``release.json`` - ``{sha256, size, url}`` describing that executable, served
  from the project's hosted site and read by ``auroraopencode.updater``.
"""

from __future__ import annotations

import hashlib
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import urllib.request


EXE_NAME = "aurora-opencode-pro.exe"
FORGE_URL = "https://forge.boqsc.eu"
ENV_KEY = "FORGE_PUBLISHER_KEY"
ENV_ID = "FORGE_PUBLISHER_ID"


def runtime_dependencies(package: Path, executable: Path) -> list[str]:
    verifier = package.parent / "scripts/verify-windows-portability.py"
    spec = importlib.util.spec_from_file_location("aurora_portability", verifier)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(name for name in module.imported_dlls(executable)
                  if module.FORBIDDEN_CRT_DLL.match(name))


def public_metadata(project: str) -> dict:
    request = urllib.request.Request(
        f"{FORGE_URL}/~/{project}/release.json",
        headers={"Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def verify_delivery(project: str, expected: dict) -> None:
    if public_metadata(project) != expected:
        raise RuntimeError("public release.json does not match the uploaded release")
    request = urllib.request.Request(expected["url"], headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=120) as response:
        digest = hashlib.sha256()
        size = 0
        while block := response.read(256 * 1024):
            digest.update(block)
            size += len(block)
            if size > expected["size"]:
                raise RuntimeError("public download exceeds expected size")
    if size != expected["size"] or digest.hexdigest() != expected["sha256"]:
        raise RuntimeError("public EXE does not match the uploaded release")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--required", action="store_true")
    args = parser.parse_args(argv)
    package = Path(__file__).resolve().parents[1]
    executable = package / EXE_NAME
    appdata = os.environ.get("APPDATA")
    config_path = (
        Path(appdata) / "Aurora OpenCode" / "forge-publisher.json"
        if appdata
        else None
    )
    if not executable.is_file():
        print("Forge publish skipped: executable missing.")
        return 1 if args.required else 0

    if os.environ.get("FORGE_PUBLISH_SKIP") == "1":
        print("Forge publish skipped for this local rebuild.")
        return 1 if args.required else 0

    try:
        config = {}
        local_config = False
        channel = (package / "assets/update-project.txt").read_text(encoding="utf-8").strip()
        # CI supplies the credential through the environment; a local build
        # reads it from the publisher config beside the user's other state.
        env_key = os.environ.get(ENV_KEY, "").strip()
        if env_key:
            project_id = os.environ.get(ENV_ID, "").strip() or channel
            key = env_key
        elif config_path is not None and config_path.is_file():
            config = json.loads(config_path.read_text(encoding="utf-8"))
            local_config = True
            if config.get("enabled") is not True:
                print("Forge publish disabled in local publisher config.")
                return 1 if args.required else 0
            project_id = config.get("id", "")
            key = config.get("key", "")
        else:
            print("Forge publish skipped: publisher config missing.")
            return 1 if args.required else 0
        if project_id != channel:
            raise ValueError("invalid Forge project id")
        if not isinstance(key, str) or not key.startswith("fsk_"):
            raise ValueError("invalid Forge key")

        dependencies = runtime_dependencies(package, executable)
        if dependencies:
            print("Publishing with installed runtime required: " + ", ".join(dependencies))

        content = executable.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        if not 0 < len(content) <= 25 * 1024 * 1024:
            raise ValueError("EXE exceeds the updater's supported size")
        description = {
            "sha256": digest, "size": len(content),
            "url": f"{FORGE_URL}/~/{project_id}/{EXE_NAME}",
            "runtime_dlls": dependencies,
            "version": json.loads((package / "dub.json").read_text(encoding="utf-8"))["version"],
        }
        try:
            unchanged = public_metadata(project_id) == description
        except Exception:
            unchanged = False
        if unchanged:
            verify_delivery(project_id, description)
            print("Forge release unchanged; public download verified.")
            return 0
        request = urllib.request.Request(
            f"{FORGE_URL}/api/files?path={EXE_NAME}",
            data=content,
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/octet-stream",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            if response.status != 201:
                raise RuntimeError(f"Forge returned HTTP {response.status}")

        # Publish the tiny description beside the EXE. The update check reads
        # this (the project's hosted site) when the release API is unavailable.
        metadata = json.dumps(description).encode("utf-8")
        meta_request = urllib.request.Request(
            f"{FORGE_URL}/api/files?path=release.json",
            data=metadata,
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(meta_request, timeout=60) as response:
            if response.status != 201:
                raise RuntimeError(
                    f"Forge returned HTTP {response.status} for release.json"
                )
        verify_delivery(project_id, description)
        config["published_sha256"] = digest
        if local_config:
            temporary = config_path.with_suffix(".json.tmp")
            temporary.write_text(
                json.dumps(config, indent=2) + "\n", encoding="utf-8"
            )
            temporary.replace(config_path)
        print(f"Published and publicly verified {EXE_NAME} to Forge project {project_id} ({digest[:12]}).")
    except Exception as error:
        print(f"Forge publish pending: {error}", file=sys.stderr)
        return 1 if args.required else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

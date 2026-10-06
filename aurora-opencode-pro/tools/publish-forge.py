"""Publish a changed portable Aurora OpenCode EXE to its Forge update channel.

The credential is never included in the executable or repository. Locally it
stays in ``%APPDATA%/Aurora OpenCode/forge-publisher.json``; in CI it comes from
the ``FORGE_PUBLISHER_KEY`` (and optional ``FORGE_PUBLISHER_ID``) environment
variables, so the release workflow can publish with a repository secret and no
config file. Publishing is best effort: a network outage must not turn a
successful build into a failed build.

Only the portable build is ever published. The portability check below is the
reason: a release built without the MSVC static CRT imports the dynamic C
runtime and would not start on a machine that lacks it. That check is what makes
the GitHub workflow (which has the toolchain) the publisher, and a local
``dub build`` inert.

Two files are published together, so the update check never depends on a server
feature that may not exist:

* ``aurora-opencode-pro.exe`` - the portable executable itself;
* ``release.json`` - ``{sha256, size, url}`` describing that executable, served
  from the project's hosted site and read by ``auroraopencode.updater``.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request


EXE_NAME = "aurora-opencode-pro.exe"
FORGE_URL = "https://forge.boqsc.eu"
PROJECT_ID = "fg_9fdcaacf6d3ae23e"
ENV_KEY = "FORGE_PUBLISHER_KEY"
ENV_ID = "FORGE_PUBLISHER_ID"


def main() -> int:
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
        return 0

    if os.environ.get("FORGE_PUBLISH_SKIP") == "1":
        print("Forge publish skipped for this local rebuild.")
        return 0

    try:
        config = {}
        # CI supplies the credential through the environment; a local build
        # reads it from the publisher config beside the user's other state.
        env_key = os.environ.get(ENV_KEY, "").strip()
        if env_key:
            project_id = os.environ.get(ENV_ID, "").strip() or PROJECT_ID
            key = env_key
        elif config_path is not None and config_path.is_file():
            config = json.loads(config_path.read_text(encoding="utf-8"))
            if config.get("enabled") is not True:
                print("Forge publish disabled in local publisher config.")
                return 0
            project_id = config.get("id", "")
            key = config.get("key", "")
        else:
            print("Forge publish skipped: publisher config missing.")
            return 0
        if project_id != PROJECT_ID:
            raise ValueError("invalid Forge project id")
        if not isinstance(key, str) or not key.startswith("fsk_"):
            raise ValueError("invalid Forge key")

        verifier = package.parent / "scripts" / "verify-windows-portability.py"
        checked = subprocess.run(
            [sys.executable, str(verifier), "--skip-manifests", str(executable)],
            capture_output=True,
            text=True,
            timeout=45,
        )
        if checked.returncode:
            print("Forge publish skipped: EXE did not pass portability checks.")
            print((checked.stderr or checked.stdout).strip()[-500:])
            return 0

        content = executable.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        if digest == config.get("published_sha256"):
            print("Forge publish skipped: EXE is unchanged.")
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
        metadata = json.dumps(
            {
                "sha256": digest,
                "size": len(content),
                "url": f"{FORGE_URL}/~/{project_id}/{EXE_NAME}",
            }
        ).encode("utf-8")
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
        config["published_sha256"] = digest
        if config_path is not None:
            config_path.write_text(
                json.dumps(config, indent=2) + "\n", encoding="utf-8"
            )
        print(f"Published {EXE_NAME} to Forge project {project_id} ({digest[:12]}).")
    except Exception as error:
        print(f"Forge publish pending: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Publish a changed portable Aurora OpenCode EXE to its Forge update channel.

The Forge credential stays in ``%APPDATA%/Aurora OpenCode/forge-publisher.json``
and is never included in the executable or repository. Publishing is best effort:
a network outage must not turn a successful local build into a failed build.
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


def main() -> int:
    package = Path(__file__).resolve().parents[1]
    executable = package / EXE_NAME
    config_path = Path(os.environ["APPDATA"]) / "Aurora OpenCode" / "forge-publisher.json"
    if not executable.is_file():
        print("Forge publish skipped: executable missing.")
        return 0

    try:
        if config_path.is_file():
            config = json.loads(config_path.read_text(encoding="utf-8"))
            if config.get("enabled") is not True:
                print("Forge publish disabled in local publisher config.")
                return 0
        else:
            print("Forge publish skipped: publisher config missing.")
            return 0
        project_id = config["id"]
        key = config["key"]
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
        config["published_sha256"] = digest
        config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        print(f"Published {EXE_NAME} to Forge project {project_id} ({digest[:12]}).")
    except Exception as error:
        print(f"Forge publish pending: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

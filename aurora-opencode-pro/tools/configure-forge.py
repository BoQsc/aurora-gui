"""Create a Forge update project once and retain its credential locally."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new", action="store_true", required=True,
                        help="Create a new channel; existing installations need a manual upgrade")
    parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    config_path = Path(os.environ["APPDATA"]) / "Aurora OpenCode/forge-publisher.json"
    if config_path.exists():
        raise SystemExit("Publisher config already exists; it was left untouched.")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request("https://forge.boqsc.eu/api/key", data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        issued = json.load(response)
    project = issued.get("id", "")
    key = issued.get("key", "")
    if not re.fullmatch(r"fg_[0-9a-f]{16}", project) or not key.startswith("fsk_"):
        raise SystemExit("Forge returned an invalid publisher credential.")
    # Persist the one-time credential before changing the app's public channel.
    with config_path.open("x", encoding="utf-8") as output:
        json.dump({"enabled": True, "id": project, "key": key}, output, indent=2)
        output.write("\n")
    (package / "assets/update-project.txt").write_text(project + "\n", encoding="utf-8")
    print("Publisher configured; credential saved outside the repository.")
    print(f"Public update channel: https://forge.boqsc.eu/~/{project}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

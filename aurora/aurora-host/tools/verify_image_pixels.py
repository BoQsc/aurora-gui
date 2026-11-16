"""Render the image scene through the headless host and assert decoded pixels."""
from __future__ import annotations

import json
import subprocess
import sys

from host_session import EXE, ROOT, ppm_counts, screenshot_path

SCENE = ROOT / "samples" / "image.scene.json"
COLORS = {(255, 0, 0), (0, 200, 0), (0, 80, 255), (255, 255, 255)}


def main() -> int:
    output = screenshot_path("aurora-host-image-headless.ppm")
    result = subprocess.run(
        [str(EXE), "--render", str(SCENE), "--out", str(output)],
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"headless render failed with {result.returncode}")
    counts = ppm_counts(output, COLORS)
    missing = {str(color): count for color, count in counts.items() if count < 10000}
    if missing:
        raise RuntimeError(f"headless image quadrants incomplete: {missing!r}; {counts!r}")
    print(json.dumps({"output": str(output), "colors": {str(k): v for k, v in counts.items()}}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

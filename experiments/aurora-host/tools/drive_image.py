"""Open the image-asset scene in a window and verify its decoded pixels."""
from __future__ import annotations

import json
import sys

from host_session import EXE, ROOT, Host, ppm_counts, screenshot_path

SCENE = ROOT / "samples" / "image.scene.json"
COLORS = {(255, 0, 0), (0, 200, 0), (0, 80, 255), (255, 255, 255)}


def main() -> int:
    if not EXE.exists():
        raise RuntimeError(f"missing executable: {EXE}")
    host = Host(SCENE)
    try:
        tree = host.request("tree")
        caption = [node for node in tree["nodes"] if node["id"] == "caption"]
        if not caption:
            raise RuntimeError(f"caption node missing: {tree!r}")
        screenshot = screenshot_path("aurora-host-image.ppm")
        host.request("screenshot", path=str(screenshot))
        counts = ppm_counts(screenshot, COLORS)
        missing = {str(color): count for color, count in counts.items() if count == 0}
        if missing:
            raise RuntimeError(f"image quadrants missing: {missing!r}; counts={counts!r}")
        print(
            json.dumps(
                {
                    "screenshot": str(screenshot),
                    "caption": caption[0],
                    "colors": {str(color): count for color, count in counts.items()},
                },
                indent=2,
            )
        )
        return 0
    finally:
        host.close()
        if host.errors:
            print("host stderr:\n" + "\n".join(host.errors), file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())

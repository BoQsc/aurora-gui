"""Find how far a joint can rotate before the rig self-intersects.

Authoring a clean clip needs the rig's usable range, not a guess. This sweeps
one node through an angle range, scans every frame with collision checks, and
prints the largest angle that stays clean.

Usage:
    python tests/probe_joint_limits.py --node RightLeg --axis x \
        --from 0 --to 100 --steps 21 [--scene build/rig.glb]
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACK = ROOT / "build" / "live-ack.json"
FRAMES = ROOT / "build" / "live-frames.json"
LIVE = ROOT / "build" / "probe-live.json"
FIXTURE = ROOT / "build" / "rig.glb"
EXECUTABLES = ("build/verify/aurora-mesh.exe", "aurora-mesh.exe")


def find_executable():
    for candidate in EXECUTABLES:
        path = ROOT / candidate
        if path.exists():
            return path
    raise SystemExit("aurora-mesh executable not found; run `dub build` first")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", required=True)
    parser.add_argument("--axis", default="x")
    parser.add_argument("--from", dest="start", type=float, default=0.0)
    parser.add_argument("--to", type=float, default=100.0)
    parser.add_argument("--steps", type=int, default=21)
    parser.add_argument("--scene", default=str(FIXTURE))
    parser.add_argument("--hold", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args()

    scene = Path(args.scene)
    if not scene.exists():
        print(f"skipped: rigged scene not present ({scene})")
        return 0
    angles = [
        args.start + (args.to - args.start) * index / (args.steps - 1)
        for index in range(args.steps)
    ]
    duration = args.hold
    keys = [
        {"time": duration * index / (args.steps - 1),
         "worldAxis": args.axis, "angle": round(angle, 3)}
        for index, angle in enumerate(angles)
    ]
    document = {
        "revision": 1,
        "commands": [
            {"type": "new-animation", "name": "Sweep", "duration": duration,
             "tracks": [{"node": args.node, "keys": keys}]},
            {"type": "scan-frames", "collisions": True},
            {"type": "audit"},
        ],
    }
    for stale in (ACK, FRAMES):
        if stale.exists():
            stale.unlink()
    LIVE.write_text(json.dumps(document))
    exe = find_executable()
    process = subprocess.Popen(
        [str(exe), "--glb", str(scene), "--glb-anim", "none",
         "--live", str(LIVE), "--width", "640", "--height", "480"],
        cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.time() + args.timeout
        ack = {}
        while time.time() < deadline:
            try:
                ack = json.loads(ACK.read_text())
            except (OSError, ValueError):
                ack = {}
            if ack.get("revision") == 1 and ack.get("frameScan", 0) >= 1 \
                    and not ack.get("scanRunning"):
                break
            time.sleep(0.2)
        report = json.loads(FRAMES.read_text())
    finally:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()

    frames = report["frames"]
    print(f"{args.node} {args.axis}: {len(frames)} frames, "
          f"{report['invalidFrames']} invalid")
    print("  angle  collisions  limbHits  valid")
    for frame in frames:
        angle = angles[round(frame["frame"] * (args.steps - 1) /
                            max(1, len(frames) - 1))]
        print(f"  {angle:6.1f}  {frame['collisions']:10d}  "
              f"{frame['limbHits']:8d}  {frame['valid']}")
    clean = [angles[round(frame["frame"] * (args.steps - 1) /
                          max(1, len(frames) - 1))]
             for frame in frames if frame["valid"]]
    if clean:
        print(f"clean range: {min(clean):.1f} .. {max(clean):.1f} degrees")
    else:
        print("no clean frame in the swept range")
    return 0 if len(clean) == len(frames) else 1


if __name__ == "__main__":
    sys.exit(main())

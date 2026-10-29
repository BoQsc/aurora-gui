"""Replay an authored animation clip through the live protocol and audit it.

The clips in ``assets/animations`` are plain descriptions (node, world axis,
angle, translation keys). This harness wraps a clip into a live command
document, runs the editor headlessly against a rigged scene, waits for the
frame scan, and asserts the clip is clean:

* every frame bakes and validates (no non-finite vertices, no invalid faces)
* no self-intersections beyond the baseline pose
* no limb/torso proximity hits and awareness stays valid
* optional ``watch``: a named node really travels far enough
* optional ``grip``: a socketed prop keeps a constant offset in its carrier's
  frame, so it cannot drift out of a hand

Usage:
    python tests/replay_clip.py [--scene PATH] [--clip PATH] [--timeout SECONDS]

The default scene is the generated rig fixture (``build/rig.glb``). Clips that
name a scene in ``"scene"`` use it instead; if that scene is missing the run is
skipped with exit code 0, so a user supplied reference asset never blocks CI.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACK = ROOT / "build" / "live-ack.json"
BONES = ROOT / "build" / "bones.json"
LIVE = ROOT / "build" / "replay-live.json"
FRAMES = ROOT / "build" / "live-frames.json"

FIXTURE = ROOT / "build" / "rig.glb"
DEFAULT_CLIP = ROOT / "assets" / "animations" / "right-snap-kick.json"
EXECUTABLES = ("build/verify/aurora-mesh.exe", "aurora-mesh.exe")


def find_executable():
    for candidate in EXECUTABLES:
        path = ROOT / candidate
        if path.exists():
            return path
    override = os.environ.get("AURORA_MESH")
    if override and Path(override).exists():
        return Path(override)
    raise SystemExit("aurora-mesh executable not found; run `dub build` first")


def animation_command(clip):
    command = {
        "type": "new-animation",
        "name": clip.get("name", "Replay"),
        "duration": clip["duration"],
        "loop": clip.get("loop", True),
        "additive": clip.get("additive", False),
        "tracks": [
            {"node": track["node"], "keys": track["keys"]}
            for track in clip["tracks"]
        ],
    }
    if clip.get("follow"):
        command["follow"] = clip["follow"]
    return command


def write_live(revision, commands):
    LIVE.parent.mkdir(parents=True, exist_ok=True)
    LIVE.write_text(json.dumps({"revision": revision, "commands": commands}))


def read_ack():
    for _ in range(4):
        try:
            return json.loads(ACK.read_text())
        except (OSError, ValueError):
            time.sleep(0.05)
    return {}


def read_bones():
    try:
        return json.loads(BONES.read_text())
    except (OSError, ValueError):
        return {}


def read_frames():
    try:
        return json.loads(FRAMES.read_text())
    except (OSError, ValueError):
        return {}


def wait_for(predicate, timeout):
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        last = read_ack()
        if predicate(last):
            return last
        time.sleep(0.2)
    return last


def nodes_by_name(bones):
    return {node["name"]: node for node in bones.get("nodes", [])}


def rotation_basis(node):
    axes = node["axes"]
    return [[axes["x"][i], axes["y"][i], axes["z"][i]] for i in range(3)]


def grip_offset(bones, grip):
    """Prop offset expressed in the carrier frame (constant while gripped)."""
    by_name = nodes_by_name(bones)
    carrier = by_name[grip["pivotNode"]]
    prop = by_name[grip["socketNode"]]
    basis = rotation_basis(carrier)
    delta = [prop["position"][i] - carrier["position"][i] for i in range(3)]
    return [sum(basis[row][col] * delta[row] for row in range(3))
            for col in range(3)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene", default=None,
                        help="rigged GLB to animate (default: the fixture)")
    parser.add_argument("--clip", default=str(DEFAULT_CLIP))
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--sheet", default=None,
                        help="frame sheet PPM path (default: build/replay-<clip>.ppm)")
    args = parser.parse_args()

    clip_path = Path(args.clip)
    clip = json.loads(clip_path.read_text())
    scene = Path(args.scene or clip.get("scene") or FIXTURE)
    if not scene.is_absolute():
        scene = ROOT / scene
    if not scene.exists():
        print(f"skipped: rigged scene not present ({scene})")
        return 0
    sheet = Path(args.sheet) if args.sheet else (
        ROOT / "build" / f"replay-{clip_path.stem}.ppm")
    exe = find_executable()
    for stale in (ACK, BONES, FRAMES):
        if stale.exists():
            stale.unlink()
    if sheet.exists():
        sheet.unlink()

    frames = round(clip["duration"] * clip.get("fps", 30))
    follow = clip.get("follow", [])
    # A follow entry generates one socket track with a key per target key.
    generated = sum(len(track["keys"]) for track in clip["tracks"]
                    if any(entry["target"] == track["node"] for entry in follow))
    expected_tracks = len(clip["tracks"]) + len(follow)
    expected_keys = sum(len(track["keys"]) for track in clip["tracks"]) \
        + generated
    checks_enabled = clip.get("checks", {})
    collision_audit = checks_enabled.get("collisions", True)
    failures = []

    def check(name, passed, value):
        print(f"{'ok  ' if passed else 'FAIL'} {name} = {value}")
        if not passed:
            failures.append(f"{name} = {value}")

    # Revision 1: rest pose inventory (grip reference and watch origin).
    write_live(1, [{"type": "list-bones"}])
    process = subprocess.Popen(
        [str(exe), "--glb", str(scene), "--glb-anim", "none",
         "--live", str(LIVE), "--width", "900", "--height", "700"],
        cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda ack: BONES.exists(), args.timeout)
        rest = read_bones()
        if not rest:
            failures.append("rest bone inventory was not written")
            rest = {"nodes": []}

        # Revision 2: author the clip, scan every frame with collision checks.
        write_live(2, [
            animation_command(clip),
            {"type": "scan-frames", "collisions": collision_audit},
            {"type": "audit"},
            {"type": "capture-sheet", "path": str(sheet)},
        ])
        ack = wait_for(
            lambda a: a.get("revision") == 2 and a.get("frameScan") == frames
            and not a.get("scanRunning")
            and len(read_frames().get("frames", [])) == frames, args.timeout)

        check("revision", ack.get("revision") == 2, ack.get("revision"))
        check("status", ack.get("status") == "ok", ack.get("status"))
        check("valid", ack.get("valid") is True, ack.get("valid"))
        check("frames", ack.get("frameScan") == frames,
              f"{ack.get('frameScan')} of {frames}")
        check("invalidFrames", ack.get("invalidFrames") == 0,
              ack.get("invalidFrames"))
        check("limbHits", ack.get("limbHits") == 0, ack.get("limbHits"))
        check("awarenessValid", ack.get("awarenessValid") is True,
              ack.get("awarenessValid"))
        if collision_audit:
            check("collisions", ack.get("collisions") == 0,
                  ack.get("collisions"))
        else:
            print("skip collisions: the clip disables the collision audit")
        check("clip", ack.get("clip") == clip.get("name", "Replay"),
              ack.get("clip"))
        check("tracks", ack.get("tracks") == expected_tracks,
              ack.get("tracks"))
        check("keys", ack.get("keys") == expected_keys, ack.get("keys"))
        if follow:
            check("follows", ack.get("follows") == len(follow),
                  ack.get("follows"))
        # The sheet is rendered after the scan, so wait for it to land.
        deadline = time.time() + min(args.timeout, 300.0)
        while time.time() < deadline and not sheet.exists():
            time.sleep(0.2)
        check("sheet", sheet.exists(), str(sheet.name))

        # The acknowledgements summarise the last check; the scan report is the
        # per frame truth, so assert against it directly.
        report = {}
        try:
            report = json.loads(FRAMES.read_text())
        except (OSError, ValueError):
            pass
        scanned = report.get("frames", [])
        check("frameReport", len(scanned) == frames,
              f"{len(scanned)} of {frames} frames")
        if scanned:
            collisions = sum(int(frame.get("collisions", 0)) for frame in scanned)
            limb_hits = sum(int(frame.get("limbHits", 0)) for frame in scanned)
            bad = [frame["frame"] for frame in scanned if not frame.get("valid")]
            bounds = [frame["frame"] for frame in scanned
                      if not frame.get("boundsValid", True)]
            if collision_audit:
                check("frameCollisions", collisions == 0, collisions)
            check("frameLimbHits", limb_hits == 0, limb_hits)
            check("invalidFrameList", not bad, bad)
            check("boundsValid", not bounds, bounds)

        # Sample the clip at even times: the clip stays authored across
        # revisions, so this only changes the clock.
        reference_grip = grip_offset(rest, clip["grip"]) if clip.get("grip") \
            else None
        watch = clip.get("watch")
        rest_position = None
        if watch:
            nodes = nodes_by_name(rest)
            rest_position = nodes[watch["node"]]["position"]
        worst_grip = 0.0
        travel = 0.0
        samples = 9
        for sample_index in range(samples):
            sample = clip["duration"] * sample_index / (samples - 1)
            revision = 3 + sample_index
            write_live(revision, [
                {"type": "time", "time": sample},
                {"type": "pause"},
                {"type": "list-bones"},
            ])
            wait_for(lambda a, rev=revision: a.get("revision") == rev,
                     args.timeout)
            bones = read_bones()
            if not bones:
                failures.append(f"sample {sample:.2f}s produced no bone list")
                continue
            if reference_grip is not None:
                offset = grip_offset(bones, clip["grip"])
                worst_grip = max(worst_grip, max(
                    abs(offset[i] - reference_grip[i]) for i in range(3)))
            if watch:
                position = nodes_by_name(bones)[watch["node"]]["position"]
                travel = max(travel, sum(
                    (position[i] - rest_position[i]) ** 2
                    for i in range(3)) ** 0.5)
        if reference_grip is not None:
            check("gripDrift", worst_grip < 0.003, f"{worst_grip * 1000.0:.2f} mm")
        if watch:
            check("travel", travel >= watch["minTravel"],
                  f"{travel:.3f} m (minimum {watch['minTravel']} m)")
    finally:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()

    if failures:
        print(f"animation {clip.get('name')} failed:")
        for failure in failures:
            print("  -", failure)
        return 1
    print(f"animation {clip.get('name')} is clean: {frames} frames, "
          f"{expected_tracks} tracks, {expected_keys} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())

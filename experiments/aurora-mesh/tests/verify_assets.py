"""Generate and check the durable animation assets.

Writes the rig fixture with the app, verifies the emitted GLB really carries a
skin, joint indices, weights, and inverse bind matrices with the expected bone
names, then runs the structural clip tests.
"""

import json
import struct
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLES = ("build/verify/aurora-mesh.exe", "aurora-mesh.exe")
REQUIRED_BONES = (
    "Hips", "Spine", "Spine2", "Neck", "Head",
    "LeftArm", "LeftForeArm", "LeftHand",
    "RightArm", "RightForeArm", "RightHand",
    "LeftUpLeg", "LeftLeg", "LeftFoot",
    "RightUpLeg", "RightLeg", "RightFoot",
)


def find_executable():
    for candidate in EXECUTABLES:
        path = ROOT / candidate
        if path.exists():
            return path
    override = ROOT / "aurora-mesh.exe"
    if override.exists():
        return override
    raise SystemExit("aurora-mesh executable not found; run `dub build` first")


def export_fixture(executable, target):
    subprocess.run([str(executable), "--export-rig", str(target)],
                   cwd=str(ROOT), check=True)
    data = target.read_bytes()
    assert data[:4] == b"glTF", "not a GLB container"
    length = struct.unpack_from("<I", data, 12)[0]
    document = json.loads(data[20:20 + length].decode("utf-8"))
    skins = document.get("skins", [])
    assert len(skins) == 1, f"expected one skin, found {len(skins)}"
    skin = skins[0]
    attributes = document["meshes"][0]["primitives"][0]["attributes"]
    assert "JOINTS_0" in attributes, "mesh has no joint indices"
    assert "WEIGHTS_0" in attributes, "mesh has no skin weights"
    assert skin["inverseBindMatrices"] >= 0, "skin has no inverse bind matrices"
    names = {node.get("name", "") for node in document["nodes"]}
    missing = [name for name in REQUIRED_BONES if name not in names]
    assert not missing, f"fixture is missing bones: {missing}"
    assert len(skin["joints"]) == len(REQUIRED_BONES) + 3, skin["joints"]
    return document


def main():
    executable = find_executable()
    target = ROOT / "build" / "rig.glb"
    document = export_fixture(executable, target)
    print(f"fixture: {len(document['nodes'])} nodes, "
          f"{len(document['skins'][0]['joints'])} joints, "
          f"{target.stat().st_size} bytes")
    sys.path.insert(0, str(ROOT / "tests"))
    suite = unittest.TestLoader().discover(str(ROOT / "tests"),
                                           pattern="test_animation_clip.py")
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())

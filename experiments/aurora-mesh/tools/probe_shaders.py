"""Probe SPIR-V module variants against the local Vulkan driver.

The viewer exposes `--gpu-probe <vertex.spv> <fragment.spv>`, so a failing
module can be bisected by editing words instead of rebuilding the application.
"""

import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "probe")
EXE = os.path.join(ROOT, "build", "verify", "aurora-mesh.exe")

MAGIC = 0x07230203


def words_from(name, path):
    text = open(os.path.join(ROOT, path), encoding="utf-8").read()
    block = text.split(name + " = [")[1].split("];")[0]
    return [int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{8})u", block)]


def save(name, words):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with open(path, "wb") as handle:
        handle.write(struct.pack("<" + "I" * len(words), *words))
    return path


def split_module(words):
    """Split into header, sections by opcode, so variants can be reassembled."""
    header, body = words[:5], words[5:]
    instructions, index = [], 0
    while index < len(body):
        count = body[index] >> 16
        instructions.append(body[index:index + count])
        index += count
    return header, instructions


def join_module(header, instructions):
    return header + [word for instruction in instructions
                     for word in instruction]


def opcode(instruction):
    return instruction[0] & 0xFFFF


def operands(instruction):
    return instruction[1:]


def probe(vertex, fragment):
    result = subprocess.run([EXE, "--gpu-probe", vertex, fragment],
                            capture_output=True, text=True, timeout=120)
    return result.returncode, (result.stdout + result.stderr).strip()


def main():
    mine_vertex = words_from("meshVertexPassthroughSpirv",
                             "source/auroramesh/mesh_shaders.d")
    mine_fragment = words_from("constantFragmentSpirv",
                               "source/auroramesh/mesh_shaders.d")
    aurora_vertex = words_from("vertexShaderSpirv",
                               "../../vendor/aurora-d-0.4.5/source/aurora/vulkan/shaders.d")
    aurora_fragment = words_from("fragmentShaderSpirv",
                                 "../../vendor/aurora-d-0.4.5/source/aurora/vulkan/shaders.d")

    pairs = [
        ("aurora", save("aurora_v.spv", aurora_vertex),
         save("aurora_f.spv", aurora_fragment)),
        ("mine", save("mine_v.spv", mine_vertex),
         save("mine_f.spv", mine_fragment)),
        ("aurora-vertex-mine-fragment", save("aurora_v.spv", aurora_vertex),
         save("mine_f.spv", mine_fragment)),
        ("mine-vertex-aurora-fragment", save("mine_v.spv", mine_vertex),
         save("aurora_f.spv", aurora_fragment)),
    ]

    for label, vertex, fragment in pairs:
        code, output = probe(vertex, fragment)
        print(f"{label:32s} exit={code:4d} {output}")


if __name__ == "__main__":
    sys.exit(main())

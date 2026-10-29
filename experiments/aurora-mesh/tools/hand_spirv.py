"""Emit a hand-written minimal SPIR-V pair for probing.

The words are transcribed directly from the SPIR-V specification's opcode
order rather than produced by the generator, so probing them isolates the
generator from the module format itself.
"""

import os
import struct
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "probe")
EXE = os.path.join(ROOT, "build", "verify", "aurora-mesh.exe")

MAGIC, VERSION = 0x07230203, 0x00010000

VERTEX = [
    MAGIC, VERSION, 0, 11, 0,
    0x00020011, 1,                          # OpCapability Shader
    0x0003000E, 0, 1,                       # OpMemoryModel Logical GLSL450
    0x0007000F, 0, 5, 0x6E69616D, 0, 6, 8,  # OpEntryPoint Vertex %5 "main" %6 %8
    0x00040047, 6, 30, 0,                   # OpDecorate %6 Location 0
    0x00040047, 8, 11, 0,                   # OpDecorate %8 BuiltIn Position
    0x00020013, 1,                          # %1 = OpTypeVoid
    0x00030021, 2, 1,                       # %2 = OpTypeFunction %1
    0x00030016, 3, 32,                      # %3 = OpTypeFloat 32
    0x00040017, 4, 3, 4,                    # %4 = OpTypeVector %3 4
    0x00040020, 7, 1, 4,                    # %7 = OpTypePointer Input %4
    0x00040020, 9, 3, 4,                    # %9 = OpTypePointer Output %4
    0x0004003B, 7, 6, 1,                    # %6 = OpVariable %7 Input
    0x0004003B, 9, 8, 3,                    # %8 = OpVariable %9 Output
    0x00050036, 1, 5, 0, 2,                 # %5 = OpFunction %1 None %2
    0x0004003D, 4, 10, 6,                   # %10 = OpLoad %4 %6
    0x0003003E, 8, 10,                      # OpStore %8 %10
    0x000100FD,                             # OpReturn
    0x00010038,                             # OpFunctionEnd
]

FRAGMENT = [
    MAGIC, VERSION, 0, 12, 0,
    0x00020011, 1,                          # OpCapability Shader
    0x0003000E, 0, 1,                       # OpMemoryModel Logical GLSL450
    0x0007000F, 4, 5, 0x6E69616D, 0, 6,     # OpEntryPoint Fragment %5 "main" %6
    0x00030010, 5, 7,                       # OpExecutionMode %5 OriginUpperLeft
    0x00040047, 6, 30, 0,                   # OpDecorate %6 Location 0
    0x00020013, 1,                          # %1 = OpTypeVoid
    0x00030021, 2, 1,                       # %2 = OpTypeFunction %1
    0x00030016, 3, 32,                      # %3 = OpTypeFloat 32
    0x00040017, 4, 3, 4,                    # %4 = OpTypeVector %3 4
    0x00040020, 7, 3, 4,                    # %7 = OpTypePointer Output %4
    0x0004003B, 7, 6, 3,                    # %6 = OpVariable %7 Output
    0x0004002B, 3, 10, 0,                   # %10 = OpConstant %3 0
    0x00050036, 1, 5, 0, 2,                 # %5 = OpFunction %1 None %2
    0x00060050, 4, 11, 10, 10, 10, 10,      # %11 = OpCompositeConstruct %4 …
    0x0003003E, 6, 11,                      # OpStore %6 %11
    0x000100FD,                             # OpReturn
    0x00010038,                             # OpFunctionEnd
]


def save(name, words):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with open(path, "wb") as handle:
        handle.write(struct.pack("<" + "I" * len(words), *words))
    return path


def probe(vertex, fragment):
    result = subprocess.run([EXE, "--gpu-probe", vertex, fragment],
                            capture_output=True, text=True, timeout=120)
    return result.returncode, (result.stdout + result.stderr).strip()


if __name__ == "__main__":
    import probe_shaders
    hand_v = save("hand_v.spv", VERTEX)
    hand_f = save("hand_f.spv", FRAGMENT)
    aurora_v = save("aurora_v.spv", probe_shaders.words_from(
        "vertexShaderSpirv",
        "../../vendor/aurora-d-0.4.5/source/aurora/vulkan/shaders.d"))
    aurora_f = save("aurora_f.spv", probe_shaders.words_from(
        "fragmentShaderSpirv",
        "../../vendor/aurora-d-0.4.5/source/aurora/vulkan/shaders.d"))
    for label, vertex, fragment in (
            ("aurora+aurora", aurora_v, aurora_f),
            ("aurora+hand", aurora_v, hand_f),
            ("hand+hand", hand_v, hand_f)):
        print(f"{label:16s} {probe(vertex, fragment)}")

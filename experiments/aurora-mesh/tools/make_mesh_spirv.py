#!/usr/bin/env python3
"""Generate the aurora-mesh 3D shaders as SPIR-V words, with no external toolchain.

Aurora ships its 2D shaders the same way (tools/make_spirv.py), because a shader
compiler is not a build dependency. This emitter writes three modules:

* mesh vertex shader: transforms a rigid model matrix and bakes Lambert lighting
  from a uniform light, so the fragment stage stays a texture multiply;
* mesh fragment shader: base colour times material texture;
* flat fragment shader: the push-constant colour, used by wireframe and grid
  lines that share the mesh vertex shader.

Modules are emitted in the order SPIR-V requires: capabilities, entry points,
execution modes, annotations, types and constants, then functions. The emitter
also rejects malformed streams itself, because a driver that receives one may
crash instead of returning an error.
"""
import argparse
import struct
from pathlib import Path

MAGIC = 0x07230203
VERSION = 0x00010000

OP_CAPABILITY, OP_EXT_INST_IMPORT, OP_MEMORY_MODEL = 17, 11, 14
OP_ENTRY_POINT, OP_EXECUTION_MODE = 15, 16
OP_DECORATE, OP_MEMBER_DECORATE = 71, 72
OP_TYPE_VOID, OP_TYPE_FLOAT, OP_TYPE_VECTOR, OP_TYPE_MATRIX = 19, 22, 23, 24
OP_TYPE_BOOL = 20
OP_TYPE_INT = 21
OP_TYPE_IMAGE, OP_TYPE_SAMPLER, OP_TYPE_SAMPLED_IMAGE = 25, 26, 27
OP_TYPE_RUNTIME_ARRAY = 29
OP_TYPE_STRUCT, OP_TYPE_POINTER, OP_TYPE_FUNCTION = 30, 32, 33
OP_CONSTANT, OP_FUNCTION, OP_FUNCTION_END, OP_VARIABLE = 43, 54, 56, 59
OP_LABEL = 248
OP_CONSTANT_COMPOSITE = 44
OP_VARIABLE_INIT = 59
OP_LOAD, OP_STORE, OP_ACCESS_CHAIN = 61, 62, 65
OP_VECTOR_SHUFFLE, OP_COMPOSITE_CONSTRUCT, OP_COMPOSITE_EXTRACT = 79, 80, 81
OP_IMAGE_SAMPLE_IMPLICIT = 87
OP_IMAGE_WRITE = 99
OP_FADD, OP_FMUL, OP_VECTOR_TIMES_SCALAR = 129, 133, 142
OP_FSUB, OP_CONVERT_U_TO_F = 130, 112
OP_IADD, OP_IMUL = 128, 132
OP_UDIV, OP_FDIV = 134, 136
OP_UMOD = 137
OP_SLT, OP_FORDGE, OP_FORDLE = 177, 190, 188
OP_ULT, OP_BITCAST = 176, 124
OP_LOGICAL_OR, OP_LOGICAL_AND, OP_SELECT = 166, 167, 169
OP_ATOMIC_UMAX, OP_CONVERT_F_TO_U = 323, 109
OP_CONSTANT_TRUE = 41
OP_BRANCH, OP_BRANCH_CONDITIONAL, OP_SELECTION_MERGE = 249, 250, 247
OP_PHI, OP_LOOP_MERGE = 245, 246
OP_MATRIX_TIMES_VECTOR, OP_DOT = 145, 148
OP_EXT_INST, OP_RETURN = 12, 253

DECO_BLOCK, DECO_COLUMN_MAJOR, DECO_MATRIX_STRIDE = 2, 5, 7
DECO_BUILTIN, DECO_BINDING, DECO_LOCATION = 11, 33, 30
DECO_DESCRIPTOR_SET, DECO_OFFSET = 34, 35
DECO_BUFFER_BLOCK = 3
DECO_ARRAY_STRIDE = 6

BUILTIN_POSITION = 0
BUILTIN_GLOBAL_INVOCATION_ID = 28
BUILTIN_VERTEX_INDEX = 42
EXECUTION_ORIGIN_UPPER_LEFT = 7
EXECUTION_FRAGMENT, EXECUTION_VERTEX = 4, 0
EXECUTION_GLCOMPUTE, EXECUTION_LOCAL_SIZE = 5, 17
SC_UNIFORM_CONSTANT, SC_UNIFORM, SC_PUSH_CONSTANT = 0, 2, 9
SC_INPUT, SC_OUTPUT = 1, 3
SC_STORAGE_BUFFER = 12
GLSL_FMAX, GLSL_NORMALIZE = 40, 69

# Fixed logical layout: sections are concatenated in this order.
SECTION_CAPS, SECTION_ENTRY, SECTION_MODE, SECTION_ANNOTATION = 0, 1, 2, 3
SECTION_TYPES, SECTION_FUNCTION = 4, 5

# Type, constant, and module-scope variable declarations belong to the global
# section even when a helper emits them while describing a function body.
GLOBAL_OPCODES = frozenset(range(19, 49)) | {OP_VARIABLE}

FLOAT_BITS = lambda value: struct.unpack("<I", struct.pack("<f", value))[0]


def string_words(text):
    data = text.encode("utf-8") + b"\0"
    data += b"\0" * ((4 - len(data) % 4) % 4)
    return list(struct.unpack("<" + "I" * (len(data) // 4), data))


def encode(opcode, *operands):
    return [((1 + len(operands)) << 16) | opcode, *operands]


def validate(body, bound):
    """Reject malformed streams before a driver has to look at them."""
    index = 0
    while index < len(body):
        count = body[index] >> 16
        if count == 0:
            raise SystemExit(f"zero-length instruction at word {index}")
        instruction = body[index:index + count]
        if len(instruction) != count:
            raise SystemExit(f"truncated instruction at word {index}")
        for operand in instruction[1:]:
            if operand is None:
                raise SystemExit(f"None operand in instruction at word {index}")
            if not isinstance(operand, int):
                raise SystemExit(f"non-integer operand at word {index}")
        index += count


class Builder:
    """Minimal SPIR-V assembler with automatic result ids and section order."""

    def __init__(self):
        self.sections = [[] for _ in range(6)]
        self.section = SECTION_CAPS
        self.next_id = 1
        self.glsl = None
        # Pointer types and module-scope variables are collected and emitted as
        # two groups, which is the layout Aurora's drivers have accepted.
        self.deferred_pointers = []
        self.deferred_variables = []

    def take(self):
        value = self.next_id
        self.next_id += 1
        return value

    def op(self, opcode, *operands):
        section = SECTION_TYPES if opcode in GLOBAL_OPCODES else self.section
        self.sections[section] += [((1 + len(operands)) << 16) | opcode,
                                   *operands]

    def op_result(self, opcode, type_id, *operands):
        result = self.take()
        self.op(opcode, type_id, result, *operands)
        return result

    def type_op(self, opcode, *operands):
        result = self.take()
        self.op(opcode, result, *operands)
        return result

    def in_section(self, section):
        self.section = section

    def capability(self, value):
        self.op(OP_CAPABILITY, value)

    def memory_model(self, addressing, memory):
        self.op(OP_MEMORY_MODEL, addressing, memory)

    def glsl_ext(self):
        self.glsl = self.take()
        self.op(OP_EXT_INST_IMPORT, self.glsl, *string_words("GLSL.std.450"))

    def entry_point(self, model, function, name, interface):
        previous = self.section
        self.section = SECTION_ENTRY
        self.op(OP_ENTRY_POINT, model, function, *string_words(name), *interface)
        self.section = previous

    def execution_mode(self, entry, mode, *extra):
        previous = self.section
        self.section = SECTION_MODE
        self.op(OP_EXECUTION_MODE, entry, mode, *extra)
        self.section = previous

    def decorate(self, target, decoration, *extra):
        previous = self.section
        self.section = SECTION_ANNOTATION
        self.op(OP_DECORATE, target, decoration, *extra)
        self.section = previous

    def member_decorate(self, struct_id, member, decoration, *extra):
        previous = self.section
        self.section = SECTION_ANNOTATION
        self.op(OP_MEMBER_DECORATE, struct_id, member, decoration, *extra)
        self.section = previous

    def variable(self, type_id, storage):
        pointer = self.take()
        variable = self.take()
        self.deferred_pointers += encode(OP_TYPE_POINTER, pointer, storage,
                                         type_id)
        self.deferred_variables += encode(OP_VARIABLE, pointer, variable,
                                          storage)
        return variable

    def constant_float(self, type_id, value):
        return self.op_result(OP_CONSTANT, type_id, FLOAT_BITS(value))

    def constant_uint(self, type_id, value):
        return self.op_result(OP_CONSTANT, type_id, value)

    def module(self):
        body = []
        for index, section in enumerate(self.sections):
            body += section
            if index == SECTION_TYPES:
                body += self.deferred_pointers + self.deferred_variables
        validate(body, self.next_id)
        return [MAGIC, VERSION, 0, self.next_id, 0] + body


def shared_prologue(b):
    """Capabilities, the GLSL library, and the scalar/vector/matrix types."""
    b.capability(1)  # Shader
    b.glsl_ext()
    b.memory_model(0, 1)  # Logical, GLSL450
    b.in_section(SECTION_TYPES)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    vec2 = b.type_op(OP_TYPE_VECTOR, f32, 2)
    vec3 = b.type_op(OP_TYPE_VECTOR, f32, 3)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    mat4 = b.type_op(OP_TYPE_MATRIX, vec4, 4)
    return {"void": void, "function_type": function_type, "f32": f32, "u32": u32,
            "vec2": vec2, "vec3": vec3, "vec4": vec4, "mat4": mat4,
            "main": b.take()}


def uniform_block(b, t):
    """std140 block: model-view-projection, model, light with ambient, params."""
    struct = b.type_op(OP_TYPE_STRUCT, t["mat4"], t["mat4"], t["vec4"],
                       t["vec4"])
    b.decorate(struct, DECO_BLOCK)
    for member, (offset, stride) in enumerate(((0, 16), (64, 16), (128, 0),
                                              (144, 0))):
        b.member_decorate(struct, member, DECO_OFFSET, offset)
        if stride:
            b.member_decorate(struct, member, DECO_COLUMN_MAJOR)
            b.member_decorate(struct, member, DECO_MATRIX_STRIDE, stride)
    block = b.variable(struct, SC_UNIFORM)
    b.decorate(block, DECO_DESCRIPTOR_SET, 0)
    b.decorate(block, DECO_BINDING, 0)
    return block


def push_color(b, t):
    struct = b.type_op(OP_TYPE_STRUCT, t["vec4"])
    b.decorate(struct, DECO_BLOCK)
    b.member_decorate(struct, 0, DECO_OFFSET, 0)
    return b.variable(struct, SC_PUSH_CONSTANT)


def member_load(b, t, block, storage, index, member_type):
    index_id = b.constant_uint(t["u32"], index)
    pointer = b.type_op(OP_TYPE_POINTER, storage, member_type)
    target = b.op_result(OP_ACCESS_CHAIN, pointer, block, index_id)
    return b.op_result(OP_LOAD, member_type, target)


def uniform_member(b, t, block, index, member_type):
    return member_load(b, t, block, SC_UNIFORM, index, member_type)


def constant_vertex_shader(x=0.015625, y=0.015625):
    """Emit gl_Position = vec4(x, y, 0, 1) with no inputs at all.

    The default half-pixel offset in a 64x64 target puts the vertex on a pixel
    centre, so a point draw cannot be lost to a boundary-coverage tie.
    """
    b = Builder()
    t = shared_prologue(b)
    gl_position = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(gl_position, DECO_BUILTIN, BUILTIN_POSITION)
    b.entry_point(EXECUTION_VERTEX, t["main"], "main", [gl_position])
    at_x = b.constant_float(t["f32"], x)
    at_y = b.constant_float(t["f32"], y)
    zero = b.constant_float(t["f32"], 0.0)
    one = b.constant_float(t["f32"], 1.0)
    position = b.op_result(OP_CONSTANT_COMPOSITE, t["vec4"], at_x, at_y, zero,
                           one)
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    b.op(OP_STORE, gl_position, position)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def clip_vertex_shader():
    """Copy a clip-space position to gl_Position, with no uniform or constant."""
    b = Builder()
    t = shared_prologue(b)
    in_position = b.variable(t["vec4"], SC_INPUT)
    gl_position = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(in_position, DECO_LOCATION, 0)
    b.decorate(gl_position, DECO_BUILTIN, BUILTIN_POSITION)
    b.entry_point(EXECUTION_VERTEX, t["main"], "main",
                  [in_position, gl_position])
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    position = b.op_result(OP_LOAD, t["vec4"], in_position)
    b.op(OP_STORE, gl_position, position)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def mesh_vertex_shader(level=2):
    """Level 0 transforms a position, 1 adds the push-constant tint, 2 lights."""
    b = Builder()
    t = shared_prologue(b)
    block = uniform_block(b, t)
    push = push_color(b, t)

    # Position and normal arrive as vec4 because 3-component 32-bit vertex
    # attributes are optional in Vulkan; the fourth component is padding.
    in_position = b.variable(t["vec4"], SC_INPUT)
    in_normal = b.variable(t["vec4"], SC_INPUT) if level >= 2 else None
    in_uv = b.variable(t["vec2"], SC_INPUT) if level >= 2 else None
    gl_position = b.variable(t["vec4"], SC_OUTPUT)
    out_color = b.variable(t["vec3"], SC_OUTPUT) if level >= 1 else None
    out_uv = b.variable(t["vec2"], SC_OUTPUT) if level >= 2 else None
    located = [(in_position, 0)]
    if level >= 1:
        located.append((out_color, 0))
    if level >= 2:
        located += [(in_normal, 1), (in_uv, 2), (out_uv, 1)]
    for target, location in located:
        b.decorate(target, DECO_LOCATION, location)
    b.decorate(gl_position, DECO_BUILTIN, BUILTIN_POSITION)

    b.entry_point(EXECUTION_VERTEX, t["main"], "main",
                  [variable for variable in (in_position, in_normal, in_uv,
                                             gl_position, out_color, out_uv)
                   if variable is not None])
    zero = b.constant_float(t["f32"], 0.0)
    one = b.constant_float(t["f32"], 1.0)

    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())

    position = b.op_result(OP_LOAD, t["vec4"], in_position)
    mvp = uniform_member(b, t, block, 0, t["mat4"])
    clip = b.op_result(OP_MATRIX_TIMES_VECTOR, t["vec4"], mvp, position)
    b.op(OP_STORE, gl_position, clip)

    if level == 0:
        b.op(OP_RETURN)
        b.op(OP_FUNCTION_END)
        return b.module()

    tint = member_load(b, t, push, SC_PUSH_CONSTANT, 0, t["vec4"])
    tint3 = b.op_result(OP_VECTOR_SHUFFLE, t["vec3"], tint, tint, 0, 1, 2)
    if level == 1:
        b.op(OP_STORE, out_color, tint3)
        b.op(OP_RETURN)
        b.op(OP_FUNCTION_END)
        return b.module()

    flat_normal = b.op_result(OP_LOAD, t["vec4"], in_normal)
    model = uniform_member(b, t, block, 1, t["mat4"])
    world_normal = b.op_result(OP_MATRIX_TIMES_VECTOR, t["vec4"], model,
                               flat_normal)
    world_normal3 = b.op_result(OP_VECTOR_SHUFFLE, t["vec3"], world_normal,
                                world_normal, 0, 1, 2)
    unit_normal = b.op_result(OP_EXT_INST, t["vec3"], b.glsl, GLSL_NORMALIZE,
                              world_normal3)

    # The light direction is stored negated, so a plain dot gives the cosine.
    light = uniform_member(b, t, block, 2, t["vec4"])
    light_dir = b.op_result(OP_VECTOR_SHUFFLE, t["vec3"], light, light, 0, 1, 2)
    ambient = b.op_result(OP_COMPOSITE_EXTRACT, t["f32"], light, 3)
    lambert = b.op_result(OP_DOT, t["f32"], unit_normal, light_dir)
    lambert = b.op_result(OP_EXT_INST, t["f32"], b.glsl, GLSL_FMAX, lambert,
                          zero)
    params = uniform_member(b, t, block, 3, t["vec4"])
    diffuse_weight = b.op_result(OP_COMPOSITE_EXTRACT, t["f32"], params, 0)
    diffuse = b.op_result(OP_FMUL, t["f32"], lambert, diffuse_weight)
    total = b.op_result(OP_FADD, t["f32"], diffuse, ambient)

    lit = b.op_result(OP_VECTOR_TIMES_SCALAR, t["vec3"], tint3, total)
    b.op(OP_STORE, out_color, lit)

    uv = b.op_result(OP_LOAD, t["vec2"], in_uv)
    b.op(OP_STORE, out_uv, uv)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def fragment_prologue():
    b = Builder()
    b.capability(1)
    b.glsl_ext()
    b.memory_model(0, 1)
    b.in_section(SECTION_TYPES)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    vec2 = b.type_op(OP_TYPE_VECTOR, f32, 2)
    vec3 = b.type_op(OP_TYPE_VECTOR, f32, 3)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    main = b.take()
    b.execution_mode(main, EXECUTION_ORIGIN_UPPER_LEFT)
    return b, {"void": void, "function_type": function_type, "f32": f32,
               "u32": u32,
               "vec2": vec2, "vec3": vec3, "vec4": vec4, "main": main}


def mesh_fragment_shader():
    b, t = fragment_prologue()
    # A combined image sampler maps directly onto a sampler2D variable.
    image = b.type_op(OP_TYPE_IMAGE, t["f32"], 1, 0, 0, 0, 1, 0)
    sampled = b.type_op(OP_TYPE_SAMPLED_IMAGE, image)
    sampler = b.variable(sampled, SC_UNIFORM_CONSTANT)
    b.decorate(sampler, DECO_DESCRIPTOR_SET, 0)
    b.decorate(sampler, DECO_BINDING, 1)

    color_in = b.variable(t["vec3"], SC_INPUT)
    uv_in = b.variable(t["vec2"], SC_INPUT)
    color_out = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(color_in, DECO_LOCATION, 0)
    b.decorate(uv_in, DECO_LOCATION, 1)
    b.decorate(color_out, DECO_LOCATION, 0)
    b.entry_point(EXECUTION_FRAGMENT, t["main"], "main",
                  [color_in, uv_in, color_out])
    one = b.constant_float(t["f32"], 1.0)

    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    combined = b.op_result(OP_LOAD, sampled, sampler)
    uv = b.op_result(OP_LOAD, t["vec2"], uv_in)
    texel = b.op_result(OP_IMAGE_SAMPLE_IMPLICIT, t["vec4"], combined, uv)
    texel3 = b.op_result(OP_VECTOR_SHUFFLE, t["vec3"], texel, texel, 0, 1, 2)
    color = b.op_result(OP_LOAD, t["vec3"], color_in)
    shaded = b.op_result(OP_FMUL, t["vec3"], color, texel3)
    result = b.op_result(OP_COMPOSITE_CONSTRUCT, t["vec4"], shaded, one)
    b.op(OP_STORE, color_out, result)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def flat_fragment_shader():
    """Wireframe, grid, and selection lines: one push-constant colour."""
    b, t = fragment_prologue()
    push = push_color(b, t)
    color_out = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(color_out, DECO_LOCATION, 0)
    b.entry_point(EXECUTION_FRAGMENT, t["main"], "main", [color_out])

    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    color = member_load(b, t, push, SC_PUSH_CONSTANT, 0, t["vec4"])
    b.op(OP_STORE, color_out, color)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def constant_fragment_shader():
    """A fragment shader with no push constants and no inputs."""
    b, t = fragment_prologue()
    color_out = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(color_out, DECO_LOCATION, 0)
    b.entry_point(EXECUTION_FRAGMENT, t["main"], "main", [color_out])
    values = [b.constant_float(t["f32"], value)
              for value in (0.7, 0.8, 0.9, 1.0)]
    color = b.op_result(OP_CONSTANT_COMPOSITE, t["vec4"],
                        *(pointer for pointer in values))

    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    b.op(OP_STORE, color_out, color)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def mesh_vertex_passthrough():
    """The smallest useful vertex shader: no uniforms, no blocks."""
    b = Builder()
    b.capability(1)
    b.memory_model(0, 1)
    b.in_section(SECTION_TYPES)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    in_position = b.variable(vec4, SC_INPUT)
    gl_position = b.variable(vec4, SC_OUTPUT)
    main = b.take()
    b.decorate(in_position, DECO_LOCATION, 0)
    b.decorate(gl_position, DECO_BUILTIN, BUILTIN_POSITION)
    b.entry_point(EXECUTION_VERTEX, main, "main", [in_position, gl_position])

    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, void, main, 0, function_type)
    b.op(OP_LABEL, b.take())
    position = b.op_result(OP_LOAD, vec4, in_position)
    b.op(OP_STORE, gl_position, position)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def compute_store_shader():
    """GLCompute: store a constant into a storage buffer, no rasterizer needed."""
    b = Builder()
    b.capability(1)  # Shader
    b.glsl_ext()
    b.memory_model(0, 1)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    struct = b.type_op(OP_TYPE_STRUCT, u32)
    b.decorate(struct, DECO_BUFFER_BLOCK)
    b.member_decorate(struct, 0, DECO_OFFSET, 0)
    buffer = b.variable(struct, SC_UNIFORM)
    b.decorate(buffer, DECO_DESCRIPTOR_SET, 0)
    b.decorate(buffer, DECO_BINDING, 0)
    main = b.take()
    b.entry_point(EXECUTION_GLCOMPUTE, main, "main", [])
    b.execution_mode(main, EXECUTION_LOCAL_SIZE, 1, 1, 1)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, void, main, 0, function_type)
    b.op(OP_LABEL, b.take())
    zero = b.constant_uint(u32, 0)
    member_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, u32)
    target = b.op_result(OP_ACCESS_CHAIN, member_pointer, buffer, zero)
    value = b.constant_uint(u32, 7)
    b.op(OP_STORE, target, value)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def compute_paint_shader(write_image=True):
    """GLCompute: paint a per-invocation colour into a storage image.

    The pixel-writing primitive a compute rasterizer needs, so one dispatch shows
    whether image writes survive the readback at all.
    """
    b = Builder()
    b.capability(1)
    b.glsl_ext()
    b.memory_model(0, 1)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    uvec3 = b.type_op(OP_TYPE_VECTOR, u32, 3)
    ivec2 = b.type_op(OP_TYPE_VECTOR, u32, 2)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    if write_image:
        # OpTypeImage: float, 2D, depth 0, arrayed 0, ms 0, sampled 2, Rgba8.
        image_type = b.type_op(OP_TYPE_IMAGE, f32, 1, 0, 0, 0, 2, 4)
        image = b.variable(image_type, SC_UNIFORM_CONSTANT)
        b.decorate(image, DECO_DESCRIPTOR_SET, 0)
        b.decorate(image, DECO_BINDING, 0)
    # A storage buffer beside the image proves each invocation really ran. Keep
    # the single member shape the proven store shader uses.
    block = b.type_op(OP_TYPE_STRUCT, u32)
    b.decorate(block, DECO_BUFFER_BLOCK)
    b.member_decorate(block, 0, DECO_OFFSET, 0)
    buffer = b.variable(block, SC_UNIFORM)
    b.decorate(buffer, DECO_DESCRIPTOR_SET, 0)
    b.decorate(buffer, DECO_BINDING, 1 if write_image else 0)
    identifier = b.variable(uvec3, SC_INPUT)
    b.decorate(identifier, DECO_BUILTIN, BUILTIN_GLOBAL_INVOCATION_ID)
    main = b.take()
    b.entry_point(EXECUTION_GLCOMPUTE, main, "main", [identifier])
    b.execution_mode(main, EXECUTION_LOCAL_SIZE, 8, 8, 1)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, void, main, 0, function_type)
    b.op(OP_LABEL, b.take())
    index = b.op_result(OP_LOAD, uvec3, identifier)
    x = b.op_result(OP_COMPOSITE_EXTRACT, u32, index, 0)
    y = b.op_result(OP_COMPOSITE_EXTRACT, u32, index, 1)
    coord = b.op_result(OP_COMPOSITE_CONSTRUCT, ivec2, x, y)
    scale = b.constant_float(f32, 1.0 / 64.0)
    red = b.op_result(OP_FMUL, f32,
                      b.op_result(OP_CONVERT_U_TO_F, f32, x), scale)
    green = b.op_result(OP_FMUL, f32,
                        b.op_result(OP_CONVERT_U_TO_F, f32, y), scale)
    half = b.constant_float(f32, 0.5)
    one = b.constant_float(f32, 1.0)
    texel = b.op_result(OP_COMPOSITE_CONSTRUCT, vec4, red, green, half, one)
    if write_image:
        # Opaque image types are loaded from their UniformConstant pointer first.
        loaded = b.op_result(OP_LOAD, image_type, image)
        b.op(OP_IMAGE_WRITE, loaded, coord, texel)
    # Record 1000 * x + y per invocation so the host can see which ones ran.
    # 42 + 1000 * x + y: any value at or above 42 proves the invocation ran,
    # even if the builtin reported zeros.
    thousand = b.constant_uint(u32, 1000)
    sentinel = b.constant_uint(u32, 42)
    stamp = b.op_result(OP_IADD, u32, sentinel,
                        b.op_result(OP_IADD, u32,
                                    b.op_result(OP_IMUL, u32, x, thousand), y))
    member_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, u32)
    slot = b.op_result(OP_ACCESS_CHAIN, member_pointer, buffer,
                       b.constant_uint(u32, 0))
    b.op(OP_STORE, slot, stamp)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def compute_raster_shader():
    """GLCompute rasterizer: one invocation per candidate pixel.

    The host lists every (pixel, triangle) pair that could cover a pixel, so the
    kernel needs no loops: each invocation runs edge coverage, an atomic depth
    test and, when it wins, writes the shaded colour into a storage image.
    """
    b = Builder()
    b.capability(1)
    b.glsl_ext()
    b.memory_model(0, 1)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    uvec3 = b.type_op(OP_TYPE_VECTOR, u32, 3)
    # Image coordinates take signed integers.
    s32 = b.type_op(OP_TYPE_INT, 32, 1)
    ivec2 = b.type_op(OP_TYPE_VECTOR, s32, 2)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    boolean = b.type_op(OP_TYPE_BOOL)

    image_type = b.type_op(OP_TYPE_IMAGE, f32, 1, 0, 0, 0, 2, 4)
    image = b.variable(image_type, SC_UNIFORM_CONSTANT)
    b.decorate(image, DECO_DESCRIPTOR_SET, 0)
    b.decorate(image, DECO_BINDING, 0)

    float_array = b.type_op(OP_TYPE_RUNTIME_ARRAY, f32)
    b.decorate(float_array, DECO_ARRAY_STRIDE, 4)
    triangles_block = b.type_op(OP_TYPE_STRUCT, float_array)
    b.decorate(triangles_block, DECO_BUFFER_BLOCK)
    b.member_decorate(triangles_block, 0, DECO_OFFSET, 0)
    triangles = b.variable(triangles_block, SC_UNIFORM)
    b.decorate(triangles, DECO_DESCRIPTOR_SET, 0)
    b.decorate(triangles, DECO_BINDING, 1)

    uint_array = b.type_op(OP_TYPE_RUNTIME_ARRAY, u32)
    b.decorate(uint_array, DECO_ARRAY_STRIDE, 4)
    entries_block = b.type_op(OP_TYPE_STRUCT, uint_array)
    b.decorate(entries_block, DECO_BUFFER_BLOCK)
    b.member_decorate(entries_block, 0, DECO_OFFSET, 0)
    entries = b.variable(entries_block, SC_UNIFORM)
    b.decorate(entries, DECO_DESCRIPTOR_SET, 0)
    b.decorate(entries, DECO_BINDING, 2)
    depth = b.variable(entries_block, SC_STORAGE_BUFFER)
    b.decorate(depth, DECO_DESCRIPTOR_SET, 0)
    b.decorate(depth, DECO_BINDING, 3)

    # Push constant: how many candidate entries the host wrote.
    count_block = b.type_op(OP_TYPE_STRUCT, u32)
    b.decorate(count_block, DECO_BUFFER_BLOCK)
    b.member_decorate(count_block, 0, DECO_OFFSET, 0)
    count_variable = b.variable(count_block, SC_PUSH_CONSTANT)

    identifier = b.variable(uvec3, SC_INPUT)
    b.decorate(identifier, DECO_BUILTIN, BUILTIN_GLOBAL_INVOCATION_ID)
    main = b.take()
    b.entry_point(EXECUTION_GLCOMPUTE, main, "main", [identifier])
    b.execution_mode(main, EXECUTION_LOCAL_SIZE, 64, 1, 1)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, void, main, 0, function_type)
    b.op(OP_LABEL, b.take())

    zero = b.constant_uint(u32, 0)
    four = b.constant_uint(u32, 4)
    sixteen = b.constant_uint(u32, 16)
    one_float = b.constant_float(f32, 1.0)
    half = b.constant_float(f32, 0.5)
    thousand = b.constant_float(f32, 1000.0)

    float_element = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, f32)
    float_array_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, float_array)
    uint_element = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, u32)
    uint_array_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, uint_array)
    # The depth buffer is a storage buffer so the kernel can test it atomically.
    depth_array_pointer = b.type_op(OP_TYPE_POINTER, SC_STORAGE_BUFFER, uint_array)
    depth_element = b.type_op(OP_TYPE_POINTER, SC_STORAGE_BUFFER, u32)

    def load_uint(source, index):
        first = b.op_result(OP_ACCESS_CHAIN, uint_array_pointer, source, zero)
        slot = b.op_result(OP_ACCESS_CHAIN, uint_element, first, index)
        return b.op_result(OP_LOAD, u32, slot)

    def load_triangle(base, offset):
        index = b.op_result(OP_IADD, u32, base, b.constant_uint(u32, offset))
        first = b.op_result(OP_ACCESS_CHAIN, float_array_pointer, triangles, zero)
        slot = b.op_result(OP_ACCESS_CHAIN, float_element, first, index)
        return b.op_result(OP_LOAD, f32, slot)

    def multiply(left, right):
        return b.op_result(OP_FMUL, f32, left, right)

    def subtract(left, right):
        return b.op_result(OP_FSUB, f32, left, right)

    def plus(left, right):
        return b.op_result(OP_FADD, f32, left, right)

    def edge(ax, ay, bx, by, px, py):
        return subtract(multiply(subtract(bx, ax), subtract(py, ay)),
                        multiply(subtract(by, ay), subtract(px, ax)))

    identifier_value = b.op_result(OP_LOAD, uvec3, identifier)
    invocation = b.op_result(OP_COMPOSITE_EXTRACT, u32, identifier_value, 0)
    # The host pads the entry list to a whole number of workgroups, so every
    # invocation has an entry to read; padding points at a degenerate triangle.
    entry_base = b.op_result(OP_IMUL, u32, invocation, four)
    def entry_field(offset):
        return load_uint(entries, b.op_result(OP_IADD, u32, entry_base,
                                              b.constant_uint(u32, offset)))
    pixel = entry_field(0)
    pixel_x = entry_field(1)
    pixel_y = entry_field(2)
    triangle = entry_field(3)
    triangle_base = b.op_result(OP_IMUL, u32, triangle, sixteen)
    px = plus(b.op_result(OP_CONVERT_U_TO_F, f32, pixel_x), half)
    py = plus(b.op_result(OP_CONVERT_U_TO_F, f32, pixel_y), half)
    x0 = load_triangle(triangle_base, 0)
    y0 = load_triangle(triangle_base, 1)
    z0 = load_triangle(triangle_base, 2)
    l0 = load_triangle(triangle_base, 3)
    x1 = load_triangle(triangle_base, 4)
    y1 = load_triangle(triangle_base, 5)
    z1 = load_triangle(triangle_base, 6)
    l1 = load_triangle(triangle_base, 7)
    x2 = load_triangle(triangle_base, 8)
    y2 = load_triangle(triangle_base, 9)
    z2 = load_triangle(triangle_base, 10)
    l2 = load_triangle(triangle_base, 11)
    red = load_triangle(triangle_base, 12)
    green = load_triangle(triangle_base, 13)
    blue = load_triangle(triangle_base, 14)
    alpha = load_triangle(triangle_base, 15)

    area = edge(x0, y0, x1, y1, x2, y2)
    wa = b.op_result(OP_FDIV, f32, edge(x1, y1, x2, y2, px, py), area)
    wb = b.op_result(OP_FDIV, f32, edge(x2, y2, x0, y0, px, py), area)
    wc = b.op_result(OP_FDIV, f32, edge(x0, y0, x1, y1, px, py), area)
    positive = b.op_result(OP_LOGICAL_AND, boolean,
                           b.op_result(OP_LOGICAL_AND, boolean,
                                       b.op_result(OP_FORDGE, boolean, wa,
                                                   b.constant_float(f32, 0.0)),
                                       b.op_result(OP_FORDGE, boolean, wb,
                                                   b.constant_float(f32, 0.0))),
                           b.op_result(OP_FORDGE, boolean, wc,
                                       b.constant_float(f32, 0.0)))
    negative = b.op_result(OP_LOGICAL_AND, boolean,
                           b.op_result(OP_LOGICAL_AND, boolean,
                                       b.op_result(OP_FORDLE, boolean, wa,
                                                   b.constant_float(f32, 0.0)),
                                       b.op_result(OP_FORDLE, boolean, wb,
                                                   b.constant_float(f32, 0.0))),
                           b.op_result(OP_FORDLE, boolean, wc,
                                       b.constant_float(f32, 0.0)))
    inside = b.op_result(OP_LOGICAL_OR, boolean, positive, negative)
    inverse_z = plus(plus(multiply(wa, z0), multiply(wb, z1)), multiply(wc, z2))
    packed = b.op_result(OP_CONVERT_F_TO_U, u32, multiply(inverse_z, thousand))
    chosen = b.op_result(OP_SELECT, u32, inside, packed, zero)
    depth_first = b.op_result(OP_ACCESS_CHAIN, depth_array_pointer, depth, zero)
    depth_slot = b.op_result(OP_ACCESS_CHAIN, depth_element, depth_first, pixel)
    # Probe: publish the loaded corner sum so the host can see the vertex data.
    probe_slot = b.op_result(OP_ACCESS_CHAIN, depth_element, depth_first, zero)
    b.op(OP_STORE, probe_slot,
         b.op_result(OP_CONVERT_F_TO_U, u32, plus(plus(x0, x1), x2)))
    # The depth test is not in place yet: buffer atomics fault this driver, so
    # the next step resolves per-pixel depth deterministically instead.
    b.op(OP_STORE, depth_slot, chosen)
    won = inside

    merge_inner = b.take()
    work_inner = b.take()
    b.op(OP_SELECTION_MERGE, merge_inner, 0)
    b.op(OP_BRANCH_CONDITIONAL, won, work_inner, merge_inner)
    b.op(OP_LABEL, work_inner)
    depth_value = b.op_result(OP_FDIV, f32, one_float, inverse_z)
    intensity = multiply(plus(plus(multiply(wa, l0), multiply(wb, l1)),
                              multiply(wc, l2)), depth_value)
    texel = b.op_result(OP_COMPOSITE_CONSTRUCT, vec4,
                        multiply(red, intensity), multiply(green, intensity),
                        multiply(blue, intensity), alpha)
    coordinate = b.op_result(OP_COMPOSITE_CONSTRUCT, ivec2,
                             b.op_result(OP_BITCAST, s32, pixel_x),
                             b.op_result(OP_BITCAST, s32, pixel_y))
    loaded_image = b.op_result(OP_LOAD, image_type, image)
    b.op(OP_IMAGE_WRITE, loaded_image, coordinate, texel)
    b.op(OP_BRANCH, merge_inner)
    b.op(OP_LABEL, merge_inner)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def compute_depth_raster_shader():
    """GLCompute: one invocation per pixel, looping that pixel's candidates.

    The host bins candidate triangles per pixel, so each invocation resolves the
    nearest surface deterministically. No atomics are needed, and the result does
    not depend on invocation order.
    """
    b = Builder()
    b.capability(1)
    b.glsl_ext()
    b.memory_model(0, 1)
    u32 = b.type_op(OP_TYPE_INT, 32, 0)
    uvec3 = b.type_op(OP_TYPE_VECTOR, u32, 3)
    s32 = b.type_op(OP_TYPE_INT, 32, 1)
    ivec2 = b.type_op(OP_TYPE_VECTOR, s32, 2)
    f32 = b.type_op(OP_TYPE_FLOAT, 32)
    vec4 = b.type_op(OP_TYPE_VECTOR, f32, 4)
    boolean = b.type_op(OP_TYPE_BOOL)

    image_type = b.type_op(OP_TYPE_IMAGE, f32, 1, 0, 0, 0, 2, 4)
    image = b.variable(image_type, SC_UNIFORM_CONSTANT)
    b.decorate(image, DECO_DESCRIPTOR_SET, 0)
    b.decorate(image, DECO_BINDING, 0)

    float_array = b.type_op(OP_TYPE_RUNTIME_ARRAY, f32)
    b.decorate(float_array, DECO_ARRAY_STRIDE, 4)
    triangles_block = b.type_op(OP_TYPE_STRUCT, float_array)
    b.decorate(triangles_block, DECO_BUFFER_BLOCK)
    b.member_decorate(triangles_block, 0, DECO_OFFSET, 0)
    triangles = b.variable(triangles_block, SC_UNIFORM)
    b.decorate(triangles, DECO_DESCRIPTOR_SET, 0)
    b.decorate(triangles, DECO_BINDING, 1)

    uint_array = b.type_op(OP_TYPE_RUNTIME_ARRAY, u32)
    b.decorate(uint_array, DECO_ARRAY_STRIDE, 4)
    uint_block = b.type_op(OP_TYPE_STRUCT, uint_array)
    b.decorate(uint_block, DECO_BUFFER_BLOCK)
    b.member_decorate(uint_block, 0, DECO_OFFSET, 0)
    candidates = b.variable(uint_block, SC_UNIFORM)
    b.decorate(candidates, DECO_DESCRIPTOR_SET, 0)
    b.decorate(candidates, DECO_BINDING, 2)
    starts = b.variable(uint_block, SC_UNIFORM)
    b.decorate(starts, DECO_DESCRIPTOR_SET, 0)
    b.decorate(starts, DECO_BINDING, 3)
    params = b.variable(uint_block, SC_UNIFORM)
    b.decorate(params, DECO_DESCRIPTOR_SET, 0)
    b.decorate(params, DECO_BINDING, 4)

    identifier = b.variable(uvec3, SC_INPUT)
    b.decorate(identifier, DECO_BUILTIN, BUILTIN_GLOBAL_INVOCATION_ID)
    main = b.take()
    b.entry_point(EXECUTION_GLCOMPUTE, main, "main", [identifier])
    b.execution_mode(main, EXECUTION_LOCAL_SIZE, 64, 1, 1)
    void = b.type_op(OP_TYPE_VOID)
    function_type = b.type_op(OP_TYPE_FUNCTION, void)
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, void, main, 0, function_type)
    entry_label = b.take()
    b.op(OP_LABEL, entry_label)

    zero = b.constant_uint(u32, 0)
    one = b.constant_uint(u32, 1)
    sixteen = b.constant_uint(u32, 16)
    zero_float = b.constant_float(f32, 0.0)
    zero_vec = b.op_result(OP_CONSTANT_COMPOSITE, vec4, zero_float, zero_float,
                           zero_float, zero_float)
    half = b.constant_float(f32, 0.5)

    float_element = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, f32)
    float_array_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, float_array)
    uint_element = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, u32)
    uint_array_pointer = b.type_op(OP_TYPE_POINTER, SC_UNIFORM, uint_array)

    def load_uint(source, index):
        first = b.op_result(OP_ACCESS_CHAIN, uint_array_pointer, source, zero)
        slot = b.op_result(OP_ACCESS_CHAIN, uint_element, first, index)
        return b.op_result(OP_LOAD, u32, slot)

    def load_triangle(base, offset):
        index = b.op_result(OP_IADD, u32, base, b.constant_uint(u32, offset))
        first = b.op_result(OP_ACCESS_CHAIN, float_array_pointer, triangles, zero)
        slot = b.op_result(OP_ACCESS_CHAIN, float_element, first, index)
        return b.op_result(OP_LOAD, f32, slot)

    def multiply(left, right):
        return b.op_result(OP_FMUL, f32, left, right)

    def subtract(left, right):
        return b.op_result(OP_FSUB, f32, left, right)

    def plus(left, right):
        return b.op_result(OP_FADD, f32, left, right)

    def edge(ax, ay, bx, by, px, py):
        return subtract(multiply(subtract(bx, ax), subtract(py, ay)),
                        multiply(subtract(by, ay), subtract(px, ax)))

    identifier_value = b.op_result(OP_LOAD, uvec3, identifier)
    pixel = b.op_result(OP_COMPOSITE_EXTRACT, u32, identifier_value, 0)
    width = load_uint(params, zero)
    pixel_x = b.op_result(OP_UMOD, u32, pixel, width)
    pixel_y = b.op_result(OP_UDIV, u32, pixel, width)
    # The host bins per 8x8 tile, so one lookup serves 64 pixels.
    tile_columns = load_uint(params, b.constant_uint(u32, 2))
    eight = b.constant_uint(u32, 8)
    tile = b.op_result(OP_IADD, u32,
                       b.op_result(OP_IMUL, u32,
                                   b.op_result(OP_UDIV, u32, pixel_y, eight),
                                   tile_columns),
                       b.op_result(OP_UDIV, u32, pixel_x, eight))
    first_candidate = load_uint(starts, tile)
    last_candidate = load_uint(starts, b.op_result(OP_IADD, u32, tile, one))
    px = plus(b.op_result(OP_CONVERT_U_TO_F, f32, pixel_x), half)
    py = plus(b.op_result(OP_CONVERT_U_TO_F, f32, pixel_y), half)

    header = b.take()
    body = b.take()
    merge = b.take()
    # The loop-carried values are referenced by the header's Phi nodes, so their
    # result ids are allocated before the body defines them.
    next_cursor = b.take()
    next_nearest = b.take()
    next_colour = b.take()
    b.op(OP_BRANCH, header)
    b.op(OP_LABEL, header)
    cursor = b.op_result(OP_PHI, u32, first_candidate, entry_label, next_cursor, body)
    nearest = b.op_result(OP_PHI, f32, zero_float, entry_label, next_nearest, body)
    nearest_colour = b.op_result(OP_PHI, vec4, zero_vec, entry_label,
                                 next_colour, body)
    more = b.op_result(OP_ULT, boolean, cursor, last_candidate)
    b.op(OP_LOOP_MERGE, merge, body, 0)
    b.op(OP_BRANCH_CONDITIONAL, more, body, merge)
    b.op(OP_LABEL, body)

    triangle = load_uint(candidates, cursor)
    triangle_base = b.op_result(OP_IMUL, u32, triangle, sixteen)
    x0 = load_triangle(triangle_base, 0)
    y0 = load_triangle(triangle_base, 1)
    z0 = load_triangle(triangle_base, 2)
    l0 = load_triangle(triangle_base, 3)
    x1 = load_triangle(triangle_base, 4)
    y1 = load_triangle(triangle_base, 5)
    z1 = load_triangle(triangle_base, 6)
    l1 = load_triangle(triangle_base, 7)
    x2 = load_triangle(triangle_base, 8)
    y2 = load_triangle(triangle_base, 9)
    z2 = load_triangle(triangle_base, 10)
    l2 = load_triangle(triangle_base, 11)
    red = load_triangle(triangle_base, 12)
    green = load_triangle(triangle_base, 13)
    blue = load_triangle(triangle_base, 14)
    alpha = load_triangle(triangle_base, 15)

    area = edge(x0, y0, x1, y1, x2, y2)
    wa = b.op_result(OP_FDIV, f32, edge(x1, y1, x2, y2, px, py), area)
    wb = b.op_result(OP_FDIV, f32, edge(x2, y2, x0, y0, px, py), area)
    wc = b.op_result(OP_FDIV, f32, edge(x0, y0, x1, y1, px, py), area)
    positive = b.op_result(OP_LOGICAL_AND, boolean,
                           b.op_result(OP_LOGICAL_AND, boolean,
                                       b.op_result(OP_FORDGE, boolean, wa, zero_float),
                                       b.op_result(OP_FORDGE, boolean, wb, zero_float)),
                           b.op_result(OP_FORDGE, boolean, wc, zero_float))
    negative = b.op_result(OP_LOGICAL_AND, boolean,
                           b.op_result(OP_LOGICAL_AND, boolean,
                                       b.op_result(OP_FORDLE, boolean, wa, zero_float),
                                       b.op_result(OP_FORDLE, boolean, wb, zero_float)),
                           b.op_result(OP_FORDLE, boolean, wc, zero_float))
    inside = b.op_result(OP_LOGICAL_OR, boolean, positive, negative)
    inverse_z = plus(plus(multiply(wa, z0), multiply(wb, z1)), multiply(wc, z2))
    closer = b.op_result(OP_LOGICAL_AND, boolean, inside,
                         b.op_result(OP_FORDGE, boolean, inverse_z, nearest))
    looks_right = b.op_result(OP_LOGICAL_AND, boolean, inside,
                              b.op_result(OP_FORDGE, boolean, inverse_z, zero_float))
    keep = b.op_result(OP_LOGICAL_AND, boolean, closer, looks_right)
    depth = b.op_result(OP_FDIV, f32, b.constant_float(f32, 1.0), inverse_z)
    intensity = multiply(plus(plus(multiply(wa, l0), multiply(wb, l1)),
                              multiply(wc, l2)), depth)
    texel = b.op_result(OP_COMPOSITE_CONSTRUCT, vec4,
                        multiply(red, intensity), multiply(green, intensity),
                        multiply(blue, intensity), alpha)
    b.op(OP_SELECT, f32, next_nearest, keep, inverse_z, nearest)
    b.op(OP_SELECT, vec4, next_colour, keep, texel, nearest_colour)
    b.op(OP_IADD, u32, next_cursor, cursor, one)
    b.op(OP_BRANCH, header)

    b.op(OP_LABEL, merge)
    covered = b.op_result(OP_FORDGE, boolean, nearest, zero_float)
    # Every invocation writes its own pixel, so one readback carries both the
    # colour and the coverage: transparent alpha means nothing was drawn here.
    final_colour = b.op_result(OP_SELECT, vec4, covered, nearest_colour,
                               zero_vec)
    coordinate = b.op_result(OP_COMPOSITE_CONSTRUCT, ivec2,
                             b.op_result(OP_BITCAST, s32, pixel_x),
                             b.op_result(OP_BITCAST, s32, pixel_y))
    loaded_image = b.op_result(OP_LOAD, image_type, image)
    b.op(OP_IMAGE_WRITE, loaded_image, coordinate, final_colour)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def index_triangle_vertex_shader():
    """gl_Position derived from gl_VertexIndex: no attributes, no buffers.

    The three invocations get distinct positions, so no vertex-fetch problem can
    collapse the triangle, and any leftover failure is rasterization itself.
    """
    b = Builder()
    t = shared_prologue(b)
    index_in = b.variable(t["u32"], SC_INPUT)
    b.decorate(index_in, DECO_BUILTIN, BUILTIN_VERTEX_INDEX)
    gl_position = b.variable(t["vec4"], SC_OUTPUT)
    b.decorate(gl_position, DECO_BUILTIN, BUILTIN_POSITION)
    b.entry_point(EXECUTION_VERTEX, t["main"], "main",
                  [index_in, gl_position])
    b.in_section(SECTION_FUNCTION)
    b.op(OP_FUNCTION, t["void"], t["main"], 0, t["function_type"])
    b.op(OP_LABEL, b.take())
    index_value = b.op_result(OP_LOAD, t["u32"], index_in)
    as_float = b.op_result(OP_CONVERT_U_TO_F, t["f32"], index_value)
    one = b.constant_float(t["f32"], 1.0)
    half = b.constant_float(t["f32"], 0.5)
    zero = b.constant_float(t["f32"], 0.0)
    x = b.op_result(OP_FSUB, t["f32"], as_float, one)
    square = b.op_result(OP_FMUL, t["f32"], as_float, as_float)
    y = b.op_result(OP_FSUB, t["f32"], square, half)
    position = b.op_result(OP_COMPOSITE_CONSTRUCT, t["vec4"], x, y, zero, one)
    b.op(OP_STORE, gl_position, position)
    b.op(OP_RETURN)
    b.op(OP_FUNCTION_END)
    return b.module()


def write_d(path, modules):
    def fmt(words_list):
        lines = []
        for i in range(0, len(words_list), 8):
            lines.append("    " + ", ".join(f"0x{word:08x}u"
                                            for word in words_list[i:i + 8]))
        return ",\n".join(lines)

    source = ("module auroramesh.mesh_shaders;\n\n"
              "// Generated by tools/make_mesh_spirv.py; do not edit.\n")
    for name, words_list in modules:
        source += f"\nimmutable uint[] {name} = [\n{fmt(words_list)}\n];\n"
    path.write_text(source)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[1] / "source" /
                        "auroramesh" / "mesh_shaders.d")
    args = parser.parse_args()
    modules = [("meshVertexConstantSpirv", constant_vertex_shader()),
               ("meshVertexClipSpirv", clip_vertex_shader()),
               ("meshVertexSpirv", mesh_vertex_shader()),
               ("meshFragmentSpirv", mesh_fragment_shader()),
               ("flatFragmentSpirv", flat_fragment_shader()),
               # Graded variants keep device bring-up diagnosable without a
               # shader compiler.
               ("meshVertexPositionSpirv", mesh_vertex_shader(0)),
               ("meshVertexTintSpirv", mesh_vertex_shader(1)),
               ("meshVertexPassthroughSpirv", mesh_vertex_passthrough()),
               ("constantFragmentSpirv", constant_fragment_shader())]
    modules.append(("computeStoreSpirv", compute_store_shader()))
    modules.append(("indexTriangleSpirv", index_triangle_vertex_shader()))
    modules.append(("computePaintSpirv", compute_paint_shader()))
    modules.append(("computeRasterSpirv", compute_depth_raster_shader()))
    write_d(args.output, modules)
    print("; ".join(f"{name}: {len(words_list)} words"
                    for name, words_list in modules))


if __name__ == "__main__":
    main()

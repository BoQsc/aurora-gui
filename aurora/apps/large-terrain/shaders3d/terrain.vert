#version 450

layout(push_constant) uniform PushConstants {
    mat4 mvp;
} pc;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;
layout(location = 2) in float inMaterial;

layout(location = 0) out vec3 outColor;
layout(location = 1) out vec3 outWorldPosition;
layout(location = 2) out float outMaterial;

void main()
{
    gl_Position = pc.mvp * vec4(inPosition, 1.0);
    outColor = inColor;
    outWorldPosition = inPosition;
    outMaterial = inMaterial;
}

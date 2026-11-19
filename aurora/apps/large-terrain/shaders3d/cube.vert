#version 450

layout(push_constant) uniform PushConstants {
    mat4 mvp;
    vec4 fogColor;
    vec4 fogParams;
    vec4 tint;
    vec4 camera;
} pc;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 outColor;
layout(location = 1) out vec3 outWorldPosition;

void main()
{
    gl_Position = pc.mvp * vec4(inPosition, 1.0);
    outColor = inColor;
    outWorldPosition = inPosition;
}

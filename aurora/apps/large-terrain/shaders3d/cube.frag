#version 450

layout(push_constant) uniform PushConstants {
    mat4 mvp;
    vec4 fogColor;
    vec4 fogParams;
    vec4 tint;
    vec4 camera;
} pc;

layout(location = 0) in vec3 inColor;
layout(location = 1) in vec3 inWorldPosition;

layout(location = 0) out vec4 outColor;

void main()
{
    vec3 color = inColor * pc.tint.rgb * pc.tint.a;
    float distanceToCamera = length(inWorldPosition - pc.camera.xyz);
    float fogDistance = max(0.0, distanceToCamera - pc.fogParams.y);
    float fogAmount = 1.0 - exp(-pow(fogDistance * pc.fogParams.x, 1.35));
    color = mix(color, pc.fogColor.rgb, clamp(fogAmount, 0.0, 1.0));
    outColor = vec4(color, 1.0);
}

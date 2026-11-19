#version 450

layout(binding = 0) uniform sampler2DArray terrainAlbedo;
layout(binding = 1) uniform sampler2DArray terrainNormal;
layout(binding = 2) uniform sampler2DArray terrainOrm;
layout(binding = 3) readonly buffer DetailBuffer
{
    float detailValue;
} detailData;

layout(push_constant) uniform PushConstants {
    mat4 mvp;
    vec4 fogColor;
    vec4 fogParams;
    vec4 tint;
    vec4 camera;
} pc;

layout(location = 0) in vec3 inColor;
layout(location = 1) in vec3 inWorldPosition;
layout(location = 2) in float inMaterial;

layout(location = 0) out vec4 outColor;

void main()
{
    float layer = clamp(floor(inMaterial + 0.5), 0.0, 15.0);
    vec2 uv = inWorldPosition.xz * 0.16;
    vec3 albedo = texture(terrainAlbedo, vec3(uv, layer)).rgb;
    vec3 normalSample = texture(terrainNormal, vec3(uv, layer)).xyz * 2.0 - 1.0;
    vec3 orm = texture(terrainOrm, vec3(uv, layer)).rgb;
    float detail = 0.86 + 0.14 * normalSample.z;
    float ao = mix(0.65, 1.0, orm.r);
    float roughness = orm.g;
    float highlight = (1.0 - roughness) * 0.10;

    vec3 color = (albedo * inColor * detail * detailData.detailValue * ao +
        albedo * highlight) * pc.tint.rgb * pc.tint.a;

    // v2 aerial perspective: distant terrain settles into the sky horizon
    // instead of ending at a hard far-plane edge.
    float distanceToCamera = length(inWorldPosition - pc.camera.xyz);
    float fogDistance = max(0.0, distanceToCamera - pc.fogParams.y);
    float fogAmount = 1.0 - exp(-pow(fogDistance * pc.fogParams.x, 1.35));
    color = mix(color, pc.fogColor.rgb, clamp(fogAmount, 0.0, 1.0));

    outColor = vec4(color, 1.0);
}

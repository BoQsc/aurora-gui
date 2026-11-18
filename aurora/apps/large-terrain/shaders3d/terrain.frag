#version 450

layout(binding = 0) uniform sampler2DArray terrainAlbedo;
layout(binding = 1) uniform sampler2DArray terrainNormal;
layout(binding = 2) uniform sampler2DArray terrainOrm;
layout(binding = 3) readonly buffer DetailBuffer
{
    float detailValue;
} detailData;


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

    outColor = vec4(albedo * inColor * detail * detailData.detailValue * ao +
        albedo * highlight, 1.0);
}

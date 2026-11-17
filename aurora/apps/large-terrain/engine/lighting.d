module engine.lighting;

struct LightingModel
{
    float[3] sunDirection;
    float[3] sunColor;
    float ambient = 0.28f;
    float sunIntensity = 1.15f;
}

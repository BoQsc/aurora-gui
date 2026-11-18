module engine.lighting;

struct LightingModel
{
    float[3] sunDirection;
    float[3] sunColor;
    float[3] skyColor;
    float[3] groundColor;
    float ambient = 0.28f;
    float sunIntensity = 1.15f;
}

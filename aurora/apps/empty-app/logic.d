module logic;

enum Revision = 1;

struct LogicState
{
    int build;
    int pointerX;
    int pointerY;
    int pointerDown;
    int keyCode;
    int value;
}

extern(C) void aurora_logic_frame(ubyte* pixels, int width, int height,
    LogicState* state)
{
    immutable ubyte bgR = Revision == 2 ? 20 : 15;
    immutable ubyte bgG = Revision == 2 ? 40 : 23;
    immutable ubyte bgB = Revision == 2 ? 90 : 42;
    immutable ubyte accentR = Revision == 2 ? 120 : 80;
    immutable ubyte accentG = Revision == 2 ? 220 : 160;
    immutable ubyte accentB = Revision == 2 ? 255 : 255;
    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            const offset = (y * width + x) * 4;
            const band = (x / 24 + y / 24) % 2 == 0;
            pixels[offset] = band ? accentR : bgR;
            pixels[offset + 1] = band ? accentG : bgG;
            pixels[offset + 2] = band ? accentB : bgB;
            pixels[offset + 3] = 255;
        }
    }
    const size = 18;
    const left = state.pointerX - size / 2;
    const top = state.pointerY - size / 2;
    foreach (y; top .. top + size)
    {
        foreach (x; left .. left + size)
        {
            if (x < 0 || x >= width || y < 0 || y >= height) continue;
            const offset = (y * width + x) * 4;
            pixels[offset] = state.pointerDown ? 255 : accentR;
            pixels[offset + 1] = state.pointerDown ? 255 : accentG;
            pixels[offset + 2] = state.pointerDown ? 255 : accentB;
            pixels[offset + 3] = 255;
        }
    }
    state.value++;
}

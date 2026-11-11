module floating_pet_render_probe;

// Renders the floating pet overlay through a real platform window and saves the
// frame, so the creature can be inspected outside the headless test harness.
// The headless capture path in floating_pet_smoke.d records the panel and label
// text but not custom-painted children, which is enough to miss the creature
// entirely; this probe uses the same window the app ships.
//
// Build (no AuroraHeadless):
//   dmd -i -Isource -Ishared -I../aurora-opencode-core/source
//       -I../vendor/aurora-d-0.4.5/source -Jassets -ofbuild/pet-smoke/probe.exe
//       tests/floating_pet_render_probe.d user32.lib gdi32.lib shell32.lib
//       wininet.lib winmm.lib

import aurora;
import auroraopencode.pet : PetHost, PetMood;
import std.path : buildPath;
import std.stdio : writeln;

int main()
{
    auto host = new PetHost();
    auto window = host.renderForTesting(
        "Quiet for a while. Want me to suggest a next step?");
    if (window is null)
    {
        writeln("overlay window unavailable");
        return 1;
    }
    const overlay = host.renderedOverlayForTesting();
    const face = overlay is null ? Rect.init : overlay.faceBoundsForTesting();
    writeln("face bounds ", face.width, "x", face.height, " paints ",
        overlay is null ? -1 : overlay.facePaintCountForTesting());
    if (overlay !is null)
    {
        const painted = overlay.facePaintBoxForTesting();
        writeln("face painted at ", painted.x, ",", painted.y, " ",
            painted.width, "x", painted.height);
    }
    window.saveScreenshot("build/pet-smoke/real-overlay.ppm");
    writeln("saved build/pet-smoke/real-overlay.ppm");
    return 0;
}

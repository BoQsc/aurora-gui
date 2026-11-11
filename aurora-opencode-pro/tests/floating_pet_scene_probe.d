module floating_pet_scene_probe;

// Minimal probe for the text-only foreground sampler, so a crash in the full
// smoke suite can be attributed to the Win32 calls rather than the app fixture.
//
// Build:
//   dmd -i -Isource -Ishared -I../aurora-opencode-core/source
//       -I../vendor/aurora-d-0.4.5/source -Jassets
//       -ofbuild/pet-smoke/scene-probe.exe tests/floating_pet_scene_probe.d
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib

import auroraopencode.pet : petSceneDigest, sampleForegroundScene;
import std.stdio : writeln;

int main()
{
    writeln("sampling foreground window");
    auto scene = sampleForegroundScene();
    writeln("app=", scene.app);
    writeln("title=", scene.title);
    writeln("digest=", petSceneDigest(scene.app, scene.title));
    return 0;
}

module floating_pet_live_probe;

// Shows the real floating pet overlay for a few seconds so the desktop can be
// captured while it runs. The smoke tests paint a window that never enters the
// app's run loop; this probe exercises the production path instead.
//
// Build:
//   dmd -i -Isource -Ishared -I../aurora-opencode-core/source
//       -I../vendor/aurora-d-0.4.5/source -Jassets
//       -ofbuild/pet-smoke/live.exe tests/floating_pet_live_probe.d
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib

import auroraopencode.pet : PetHost;
import core.thread : Thread;
import core.time : seconds;
import std.stdio : writeln;

int main()
{
    auto host = new PetHost();
    host.publishText("Quiet for a while. Want me to suggest a next step?");
    host.start();
    writeln("pet overlay running");
    Thread.sleep(8.seconds);
    host.stop();
    Thread.sleep(1.seconds);
    writeln("pet overlay stopped");
    return 0;
}

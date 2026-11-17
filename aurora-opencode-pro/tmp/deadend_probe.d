module deadend_probe;

import auroraopencode.taskcontinuation : taskBlockerError;
import std.stdio : writeln;

void tryInput(string label, string json)
{
    writeln("== ", label);
    writeln("  -> ", taskBlockerError(json, false));
}

void main()
{
    // Actual rejected payload from the referenced conversation (13:55).
    tryInput("conversation 13:55 payload",
        `{"blocked_steps":["step-2B5645466BE64B17"],` ~
        `"checked":["Clean producer-only 20 s run: 1200 frames, over16=15, over20=5, max 45.382 ms"],` ~
        `"independent_work_complete":true,` ~
        `"question":"Should I keep the hard 60 fps guarantee on the current DWM windowed host, or may I switch to an exclusive-fullscreen presentation path?",` ~
        `"reason":"The remaining change alters the presentation contract, which is a user-owned requirement.",` ~
        `"required_fact":"Which presentation path the 60 fps guarantee applies to"}`);
    // Accepted variant from the same conversation (13:49).
    tryInput("conversation 13:49 payload",
        `{"blocked_steps":["step-F69CECA436A8F41E"],` ~
        `"checked":["Producer-only interval sampling","High process/thread priority"],` ~
        `"independent_work_complete":true,` ~
        `"question":"Should the hard 60 fps guarantee target the current DWM windowed host, or may I replace it with an exclusive-fullscreen path?",` ~
        `"reason":"The next change alters the presentation contract and cannot be chosen without the user.",` ~
        `"required_fact":"Whether the 100% stable 60 fps guarantee must hold in the current DWM windowed host or may use exclusive fullscreen"}`);
    // A genuine permission question must stay rejected.
    tryInput("routine permission",
        `{"checked":["Build output"],"independent_work_complete":true,` ~
        `"question":"Should I continue with the routine build?",` ~
        `"reason":"Build not run yet","required_fact":"Whether to continue"}`);
}

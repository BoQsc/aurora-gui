module computer_progress_test;

import auroraopencode.computerprogress;
import auroraopencode.requestintent;
import std.file : read;
import std.stdio : writeln;

int main(string[] args)
{
    foreach (text; ["why you couldn't complete",
        "I did killswitch because you didn't progress, I want to know why you didn't progress",
        "Explain why the game didn't run.", "Why couldn't you play the tutorial?",
        "Explain why and how to fix it."])
        assert(explanationOnlyRequest(text), text);
    foreach (text; ["yes", "continue", "try to play the tutorial",
        "Explain why and fix it", "Why is it slow? Please test the API.",
        "Can you inspect why it failed?", "I want you to continue and explain why"])
        assert(!explanationOnlyRequest(text), text);

    enum w = 384, h = 216;
    auto rgb = new ubyte[w * h * 3];
    rgb[] = 80;
    auto first = observeDesktop(w, h, rgb);
    auto noisy = rgb.dup;
    foreach (ref p; noisy) ++p;
    assert(!desktopVisiblyChanged(first, observeDesktop(w, h, noisy)));
    foreach (y; 95 .. 105) foreach (x; 95 .. 105)
        noisy[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = 200;
    auto animation = observeDesktop(w, h, noisy);
    assert(!desktopVisiblyChanged(first, animation), "Small animation defeated stall detection");
    auto hover = rgb.dup;
    // A pulsing Continue button and taskbar clock must not count as progress.
    foreach (y; 12 .. 16) foreach (x; 326 .. 380)
        hover[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = 220;
    foreach (y; 210 .. 214) foreach (x; 340 .. 370)
        hover[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = 220;
    assert(!desktopVisiblyChanged(first, observeDesktop(w, h, hover)),
        "Hover/clock animation masqueraded as progress");

    DesktopClickProgress progress;
    foreach (i; 0 .. 3)
    {
        assert(!progress.refuses(1, false, 180 + i * 4, 110, first));
        progress.record(1, false, 180 + i * 4, 110, first, animation);
    }
    assert(progress.refuses(1, false, 190, 112, first), "Coordinate jitter evaded the guard");
    assert(progress.refuses(1, false, 190, 112, first), "A full frame reset a stalled cluster");
    assert(progress.offerFocusedRecovery());
    assert(!progress.refuses(1, false, 190, 112, first), "Focused evidence did not permit a retry");
    progress.record(1, false, 190, 112, first, first);
    assert(progress.refuses(1, false, 192, 112, first));
    assert(!progress.offerFocusedRecovery(), "Focused evidence repeatedly reset the retry budget");
    assert(progress.refuses(1, false, 192, 112, first));
    assert(!progress.refuses(1, false, 192, 112, first, 8), "A different mouse button was not a new approach");
    assert(!progress.refuses(2, false, 190, 112, first), "A different window inherited a stall");
    progress.reset();
    foreach (i; 0 .. 3) progress.record(1, false, 180, 110, first, first);
    assert(!progress.refuses(1, true, 180, 110, first), "Changing delivery mode could not recover");
    foreach (i; 0 .. 3) progress.record(1, false, 180, 110, first, first);
    assert(!progress.refuses(1, false, 500, 110, first), "A different control was blocked");
    progress.reset();
    foreach (i; 0 .. 3) progress.record(1, false, 180, 110, first, first);
    auto changed = rgb.dup;
    foreach (y; 0 .. 15) foreach (x; 20 .. 300)
        changed[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = 220;
    auto dialogue = observeDesktop(w, h, changed);
    assert(desktopVisiblyChanged(first, dialogue), "Dialogue advancement was ignored");
    assert(!progress.refuses(1, false, 180, 110, dialogue), "New dialogue did not release the guard");
    progress.reset();
    foreach (i; 0 .. 3) progress.record(1, false, 180, 110, first, first);
    progress.reset(); // Production resets after a successful crop/new user request.
    assert(!progress.refuses(1, false, 180, 110, first));
    assert(!progress.refuses(1, false, 180, 110, DesktopObservation.init));
    auto pixels = new ubyte[4 * 3 * 3];
    foreach (i, ref p; pixels) p = cast(ubyte) i;
    auto crop = cropDesktop(4, 3, pixels, 2, 1, 4, 4);
    assert(crop.x == 2 && crop.y == 1 && crop.width == 2 && crop.height == 2);
    assert(crop.rgb == pixels[18 .. 24] ~ pixels[30 .. 36]);
    crop = cropDesktop(4, 3, pixels, -10, -10, 2, 2);
    assert(crop.x == 0 && crop.y == 0 && crop.rgb == pixels[0 .. 6] ~ pixels[12 .. 18]);

    DesktopDragProgress drags;
    foreach (i; 0 .. 3)
    {
        assert(!drags.refuses(1, false, 700 + i * 300, 450, 1500 + i * 100, 470, 32));
        drags.record(1, false, 700 + i * 300, 450, 1500 + i * 100, 470, 32);
    }
    assert(drags.refuses(1, false, 1400, 450, 1800, 450, 32),
        "Coordinate jitter escaped the same-direction drag limit");
    assert(drags.offerFocusedRecovery());
    assert(!drags.refuses(1, false, 1400, 450, 1800, 450, 32));
    drags.record(1, false, 1400, 450, 1800, 450, 32);
    assert(drags.refuses(1, false, 1500, 450, 1750, 450, 32));
    assert(!drags.offerFocusedRecovery());
    assert(!drags.refuses(1, false, 1500, 450, 700, 450, 32), "Reversing direction was blocked");
    foreach (i; 0 .. 3) drags.record(1, false, 700, 450, 1500, 450, 32);
    assert(!drags.refuses(1, false, 700, 450, 1500, 450, 2), "A different button was blocked");
    foreach (i; 0 .. 3) drags.record(1, false, 700, 450, 1500, 450, 32);
    assert(!drags.refuses(2, false, 700, 450, 1500, 450, 32), "New target inherited a drag limit");

    if (args.length > 1)
    {
        assert(args.length == 6, "Replay expects before + four post-click RGB frames");
        auto before = observeDesktop(1920, 1080, cast(ubyte[]) read(args[1]));
        int[2][4] points = [[1010, 385], [1080, 400], [1035, 345], [1188, 458]];
        progress.reset();
        foreach (i; 0 .. 4)
        {
            auto after = observeDesktop(1920, 1080, cast(ubyte[]) read(args[i + 2]));
            assert(!progress.refuses(1, false, points[i][0], points[i][1], before));
            progress.record(1, false, points[i][0], points[i][1], before, after);
            before = after;
        }
        assert(progress.refuses(1, false, 1190, 450, before), "The actual CoH stall escaped detection");
        writeln("PASS: actual CoH frames stop the fifth click after the initial overlay transition");
    }
    writeln("PASS: jitter, animation, dialogue, targets, delivery modes, recovery, diagnostic intent");
    return 0;
}

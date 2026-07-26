module tests.audio_clock_smoke;

import auroracut.playback : PcmAudioPlayer;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.stdio : writeln;

int main(string[] arguments)
{
    assert(arguments.length == 2, "Usage: audio-clock-smoke <audio-or-video-file>");

    auto player = new PcmAudioPlayer();
    scope (exit) player.shutdown();

    assert(player.start(arguments[1], 0.0, 1.0, 0.05),
        "PCM preview audio request was not accepted");

    double lastPosition;
    foreach (_; 0 .. 250)
    {
        double position;
        if (player.clockPosition(position))
        {
            assert(position >= 0.0, "PCM preview audio clock went negative");
            if (position > lastPosition + 0.005)
            {
                player.stop();
                writeln("Aurora Cut PCM audio clock smoke test passed.");
                return 0;
            }
            lastPosition = position;
        }
        Thread.sleep(10.msecs);
    }

    const error = player.error();
    const stats = player.stats();
    assert(false, error.length > 0 ? error :
        "PCM preview audio clock did not become active; requests=" ~
        stats.requests.to!string ~ " processes=" ~
        stats.processesStarted.to!string);
}

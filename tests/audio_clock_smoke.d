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

    enum double displayStartTime = 5.0;
    assert(player.start(arguments[1], 0.0, 1.0, 0.05, displayStartTime),
        "PCM preview audio request was not accepted");

    double firstPosition = -1.0;
    foreach (_; 0 .. 250)
    {
        double position;
        if (player.clockPosition(position))
        {
            assert(position >= displayStartTime,
                "PCM preview audio clock used media time instead of display time");
            if (firstPosition < 0.0) firstPosition = position;
            if (position > firstPosition + 0.005)
            {
                player.stop();
                writeln("Aurora Cut PCM audio clock smoke test passed.");
                return 0;
            }
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

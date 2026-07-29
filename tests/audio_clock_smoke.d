module tests.audio_clock_smoke;

import auroracut.playback : PcmAudioPlayer;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.math : fabs;
import std.stdio : writeln;

int main(string[] arguments)
{
    assert(arguments.length == 2, "Usage: audio-clock-smoke <audio-or-video-file>");

    auto player = new PcmAudioPlayer();
    scope (exit) player.shutdown();

    enum double pausedDisplayStartTime = 7.0;
    assert(player.start(arguments[1], 0.0, 1.0, 0.05,
        pausedDisplayStartTime, true),
        "Paused PCM preview audio request was not accepted");
    double pausedFirst = -1.0;
    foreach (_; 0 .. 250)
    {
        double position;
        if (player.clockPosition(position))
        {
            pausedFirst = position;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(pausedFirst >= pausedDisplayStartTime,
        "Paused PCM preview audio clock did not become ready");
    Thread.sleep(120.msecs);
    double pausedSecond;
    assert(player.clockPosition(pausedSecond),
        "Paused PCM preview audio clock disappeared before resume");
    assert(fabs(pausedSecond - pausedFirst) < 0.003,
        "Paused PCM preview audio advanced before resume");
    assert(player.resume(), "Paused PCM preview audio could not be resumed");
    bool resumedAdvanced;
    foreach (_; 0 .. 250)
    {
        double position;
        if (player.clockPosition(position) && position > pausedFirst + 0.005)
        {
            resumedAdvanced = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(resumedAdvanced, "Paused PCM preview audio did not advance after resume");
    player.stop();

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

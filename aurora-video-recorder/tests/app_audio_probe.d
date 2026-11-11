// Scratch probe: run the same controller path the app uses, with screen sound on.
import aurorarecorder.recorder : RecorderController, RecorderOptions,
    locateFfmpeg;
import aurorarecorder.encoder : RecorderPhase;
import aurorarecorder.settings : Timestamp;
import core.thread : Thread, dur;
import std.datetime : Clock, LocalTime;
import std.stdio : writeln;

void main(string[] args)
{
    RecorderOptions options;
    options.systemAudio = true;
    RecorderController.normalizeOptions(options);
    auto controller = new RecorderController(options, locateFfmpeg(args.length > 1 ? args[1] : ""));
    writeln("ffmpeg=", controller.ffmpegPath(), " folder=", options.outputFolder);

    const now = Clock.currTime(LocalTime());
    Timestamp stamp;
    stamp.year = now.year; stamp.month = now.month; stamp.day = now.day;
    stamp.hour = now.hour; stamp.minute = now.minute; stamp.second = now.second;

    if (!controller.start(stamp)) { writeln("start failed: ", controller.lastMessage()); return; }
    foreach (i; 0 .. 120)
    {
        auto s = controller.poll();
        if (s.phase == RecorderPhase.recording && s.frames >= 20) break;
        if (s.phase == RecorderPhase.failed) { writeln("FAILED ", s.error); return; }
        Thread.sleep(dur!"msecs"(50));
    }
    controller.stop();
    foreach (i; 0 .. 200)
    {
        controller.poll();
        if (!controller.hasEncoder()) break;
        Thread.sleep(dur!"msecs"(50));
    }
    writeln("done; last=", controller.lastFinishedPath());
    controller.shutdown();
}

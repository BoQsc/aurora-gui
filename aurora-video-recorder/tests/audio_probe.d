// Scratch probe: does the encoder's audio pipeline produce an MP4 with sound?
import aurorarecorder.encoder : RecorderPhase, RecordingJob, ScreenEncoder;
import aurorarecorder.settings : CaptureRect;
import core.thread : Thread, dur;
import std.datetime : Clock;
import std.stdio : writeln;

void main(string[] args)
{
    const ffmpeg = args.length > 1 ? args[1] : "";
    RecordingJob job;
    job.outputPath = "C:\\Users\\windows10\\AppData\\Local\\Temp\\vr-sys.mp4";
    job.rect = CaptureRect(0, 0, 320, 240);
    job.fps = 10;
    job.quality = 28;
    job.drawCursor = false;
    job.ffmpegPath = ffmpeg;
    job.systemAudio = true;
    job.systemAudioRate = 44100;
    job.systemAudioChannels = 2;

    auto encoder = new ScreenEncoder(job);
    encoder.start();
    const deadline = Clock.currTime + dur!"seconds"(10);
    while (encoder.status.snapshot.frames == 0 && Clock.currTime < deadline &&
        encoder.status.snapshot.phase != RecorderPhase.failed)
        Thread.sleep(dur!"msecs"(20));
    writeln("phase=", encoder.status.snapshot.phase, " frames=",
        encoder.status.snapshot.frames, " err=", encoder.status.snapshot.error);
    Thread.sleep(dur!"seconds"(3));
    encoder.stop();
    encoder.join(20000);
    writeln("final phase=", encoder.status.snapshot.phase,
        " err=", encoder.status.snapshot.error);
}

module recorder_timing_acceptance;
import aurorarecorder.encoder;
import aurorarecorder.settings : CaptureRect;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : buildPath;

int main(string[] args)
{
    assert(args.length == 3);
    mkdirRecurse(args[2]);
    foreach (fps; [30,60])
    {
        RecordingJob job;
        job.outputPath=buildPath(args[2],"independent-"~to!string(fps)~".mp4");
        job.ffmpegPath=args[1];job.rect=CaptureRect(0,0,640,480);
        job.fps=fps;job.quality=23;job.drawCursor=false;
        auto encoder=new ScreenEncoder(job);encoder.start();
        auto deadline=MonoTime.currTime+10.seconds;
        while(encoder.status().snapshot().phase==RecorderPhase.starting && MonoTime.currTime<deadline)
            Thread.sleep(5.msecs);
        assert(encoder.status().snapshot().phase==RecorderPhase.recording,"Actual encoder never started");
        const start=MonoTime.currTime;
        Thread.sleep(6.seconds);
        const stop=MonoTime.currTime;encoder.stop();
        assert(encoder.join(20000),"Actual encoder did not finish");
        auto status=encoder.status().snapshot();
        assert(status.phase==RecorderPhase.finished,status.error);
        writeln("MEASURE ",fps," ",(stop-start).total!"msecs"," ",status.frames);
    }
    return 0;
}

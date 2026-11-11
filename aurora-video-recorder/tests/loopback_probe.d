// Scratch probe: does WASAPI loopback capture arrive, and is the format sane?
import aurorarecorder.loopback : SystemAudioCapture;
import core.thread : Thread, dur;
import std.stdio : writeln, stdout;

void main()
{
    auto capture = new SystemAudioCapture();
    const started = capture.start();
    writeln("started=", started, " error=[", capture.errorText(), "]");
    if (!started) return;
    const format = capture.format();
    writeln("rate=", format.sampleRate, " channels=", format.channels);

    long bytes;
    long nonZeroBytes;
    foreach (_; 0 .. 120)
    {
        auto data = capture.take();
        if (data.length > 0)
        {
            bytes += data.length;
            foreach (b; data)
                if (b != 0) { ++nonZeroBytes; break; }
        }
        Thread.sleep(dur!"msecs"(25));
    }
    writeln("captured bytes=", bytes, " packetsWithSignal=", nonZeroBytes);
    capture.shutdown();
}

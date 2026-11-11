// Scratch probe: exercise only the COM setup up to the format read.
import aurorarecorder.loopback : SystemAudioCapture;
import core.stdc.stdio : FILE, fopen, fclose, fprintf;
import std.string : toStringz;

void logMsg(string m)
{
    FILE* f = fopen("C:\\Users\\windows10\\AppData\\Local\\Temp\\vr-lb.txt", "ab");
    if (f !is null) { fprintf(f, "%s\n", m.toStringz); fclose(f); }
}

void main()
{
    logMsg("before start");
    auto capture = new SystemAudioCapture();
    const started = capture.start();
    logMsg("after start");
    import core.stdc.stdio : printf;
    const err = capture.errorText;
    printf("started=%d error=%s\n", started ? 1 : 0,
        err.length > 0 ? err.toStringz : "none".ptr);
    if (!started) return;
    const f = capture.format();
    printf("rate=%u ch=%u\n", f.sampleRate, f.channels);
    capture.shutdown();
    logMsg("done");
}

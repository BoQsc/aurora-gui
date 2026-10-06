module auroraopencode.latency;

import core.sync.mutex : Mutex;
import core.time : MonoTime;
import auroraopencode.logging : logInfo;
import std.conv : to;

enum LatencyStage { accepted, serialized, connected, uploaded, headers, firstByte,
    firstToken, applied, paintSubmitted, settled }

struct LatencySnapshot
{
    ulong requestId;
    long[10] microseconds;
    long requestBytes;
    string transport;
    uint protocol;
}

/// A retained trace belongs to one request, including UI work that runs after
/// its provider worker has returned or the next continuation has started.
class RequestLatency
{
    private Mutex mutex;
    private long start;
    private LatencySnapshot value;

    this(ulong requestId, long startedTicks = 0)
    {
        mutex = new Mutex();
        start = startedTicks ? startedTicks : MonoTime.currTime.ticks;
        value.requestId = requestId;
        value.microseconds[] = -1;
    }

    bool mark(LatencyStage stage, long atTicks = 0)
    {
        synchronized (mutex)
        {
            if (value.microseconds[stage] >= 0) return false;
            const ticks = (atTicks ? atTicks : MonoTime.currTime.ticks) - start;
            value.microseconds[stage] = cast(long) (cast(double) ticks * 1_000_000 / MonoTime.ticksPerSecond);
            return true;
        }
    }

    void wire(long bytes, string transport, uint protocol = 0)
    {
        synchronized (mutex)
        {
            value.requestBytes = bytes;
            value.transport = transport;
            value.protocol = protocol;
        }
    }

    LatencySnapshot snapshot() { synchronized (mutex) return value; }

    void report(string milestone)
    {
        const data = snapshot();
        string text = "request latency: id=" ~ to!string(data.requestId) ~ " milestone=" ~ milestone;
        foreach (stage; 0 .. data.microseconds.length)
            text ~= " " ~ to!string(cast(LatencyStage) stage) ~ "Us=" ~ to!string(data.microseconds[stage]);
        text ~= " bytes=" ~ to!string(data.requestBytes) ~ " transport=" ~ data.transport ~
            " protocol=" ~ to!string(data.protocol);
        logInfo(text);
    }
}

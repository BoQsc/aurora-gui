module engine.frame_clock;

import core.thread : Thread;
import core.time : MonoTime, msecs;

struct FrameClock
{
    double targetSeconds = 1.0 / 60.2;

    void waitUntil(MonoTime frameStart) const
    {
        while (true)
        {
            const elapsed = (MonoTime.currTime - frameStart)
                .total!"usecs" / 1000000.0;
            if (elapsed >= targetSeconds) break;
            const remaining = targetSeconds - elapsed;
            if (remaining > 0.002)
                Thread.sleep((cast(long) ((remaining - 0.002) * 1000.0))
                    .msecs);
            else
                do {} while ((MonoTime.currTime - frameStart)
                    .total!"usecs" < cast(long) (targetSeconds * 1000000.0));
        }
    }
}

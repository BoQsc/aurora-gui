module checkout_wait_contracts;

import auroraopencode.checkout : CheckoutLease;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    auto directory = buildPath(tempDir(), "checkout-wait-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory);
    auto held = new CheckoutLease(directory);
    scope (exit) held.release();

    auto mutex = new Mutex();
    auto wake = new Condition(mutex);
    bool cancelled, waitingSeen, acquired, stopped;
    auto waiter = new Thread({
        try
        {
            auto lease = new CheckoutLease(directory,
                () {
                    synchronized (mutex) { return cancelled; }
                },
                -1,
                (string message) {
                    synchronized (mutex) { waitingSeen = true; wake.notifyAll(); }
                });
            synchronized (mutex) { acquired = true; wake.notifyAll(); }
            lease.release();
        }
        catch (Exception error)
        {
            synchronized (mutex)
            {
                stopped = error.msg.indexOf("Stopped while waiting") >= 0;
                wake.notifyAll();
            }
        }
    });
    waiter.start();
    const deadline = MonoTime.currTime + 5.seconds;
    synchronized (mutex)
        while (!waitingSeen && !acquired && !stopped && MonoTime.currTime < deadline)
            wake.wait(50.msecs);
    assert(waitingSeen, "The no-deadline waiter never reported that it was waiting");
    synchronized (mutex) { cancelled = true; wake.notifyAll(); }
    waiter.join();
    assert(stopped && !acquired, "Cancellation did not stop the no-deadline checkout wait");

    held.release();
    auto reacquired = new CheckoutLease(directory, null, -1);
    reacquired.release();
    writeln("PASS checkout lease waits without a deadline, stops on cancellation, and reacquires after release");
    return 0;
}
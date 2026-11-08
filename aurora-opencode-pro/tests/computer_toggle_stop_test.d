module computer_toggle_stop_test;

// Turning "Experimental computer use" off must stop the desktop at once. A call
// that is already running (the streaming `loop` and the batch path) has to end
// between its steps, and calls issued afterwards must be refused - without
// touching the kill-switch latch, which stays sticky for its own reason.
// Every step here is a `wait`, so the test proves the stop path without sending
// any input to the real desktop.

import auroraopencode.computeruse : ComputerUseResult, clearComputerUseAbort,
    computerUseAbortActive, experimentalComputerUseEnabled,
    experimentalComputerUseExecute, setComputerUseSetting;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

private long elapsedSince(MonoTime started)
{
    return (MonoTime.currTime - started).total!"msecs";
}

int main()
{
    clearComputerUseAbort();
    setComputerUseSetting(true);
    scope (exit) setComputerUseSetting(false);
    assert(experimentalComputerUseEnabled(),
        "the Settings switch did not enable computer use");

    // 1. A running `loop` - the action that keeps the desktop under control in
    // real use - must stop when the switch is turned off mid-call.
    const workspace = buildPath(tempDir(), "aurora-toggle-" ~ randomUUID().toString());
    mkdirRecurse(workspace);
    scope (exit) rmdirRecurse(workspace);
    write(buildPath(workspace, "computer-macros.json"),
        `{"tick": [{"action": "wait", "duration_ms": 50}]}`);

    ComputerUseResult running;
    Throwable workerError;
    auto worker = new Thread(delegate void() {
        try running = experimentalComputerUseExecute(
            `{"action":"loop","name":"tick","seconds":5,"interval_ms":150,"screenshot":false}`,
            workspace);
        catch (Throwable error) workerError = error;
    });
    const started = MonoTime.currTime;
    worker.start();
    Thread.sleep(msecs(400));
    setComputerUseSetting(false);
    worker.join();
    const elapsed = elapsedSince(started);

    assert(workerError is null, "the running loop threw: " ~ workerError.msg);
    assert(running.failed,
        "the loop kept controlling the desktop after the switch was turned off: " ~
        running.output);
    assert(running.output.indexOf("switched off in Settings") >= 0,
        "the stop did not name the Settings switch: " ~ running.output);
    assert(elapsed < 2500,
        "the loop ran its 5 s budget instead of stopping (" ~ to!string(elapsed) ~ " ms)");
    assert(!computerUseAbortActive(),
        "switching computer use off latched the kill switch instead of stopping the call");
    writeln("loop stopped after ", elapsed, " ms of a 5000 ms budget");

    // 2. A batch that is already running stops between its steps.
    setComputerUseSetting(true);
    ComputerUseResult batch;
    worker = new Thread(delegate void() {
        try batch = experimentalComputerUseExecute(
            `{"steps":[{"action":"wait","duration_ms":3000},{"action":"wait","duration_ms":3000}],"screenshot":false}`,
            workspace);
        catch (Throwable error) workerError = error;
    });
    const batchStarted = MonoTime.currTime;
    worker.start();
    Thread.sleep(msecs(300));
    setComputerUseSetting(false);
    worker.join();
    const batchElapsed = elapsedSince(batchStarted);
    assert(workerError is null, "the running batch threw: " ~ workerError.msg);
    assert(batch.failed && batch.output.indexOf("switched off in Settings") >= 0,
        "the batch did not stop on the switch: " ~ batch.output);
    assert(batchElapsed < 2500,
        "the batch kept running (" ~ to!string(batchElapsed) ~ " ms)");
    assert(batch.output.indexOf("step 2") < 0,
        "the batch ran its second step after the switch was turned off: " ~ batch.output);
    writeln("batch stopped after ", batchElapsed, " ms");

    // 3. A call emitted after the toggle off never reaches the desktop.
    auto afterOff = experimentalComputerUseExecute(
        `{"action":"wait","duration_ms":10,"screenshot":false}`, workspace);
    assert(afterOff.failed, "computer use still drove the desktop while switched off");
    assert(afterOff.output.indexOf("turned off in Settings") >= 0,
        "the refusal did not name the Settings switch: " ~ afterOff.output);
    assert(afterOff.output.indexOf("Nothing was sent") >= 0,
        "the refusal did not state that nothing was sent: " ~ afterOff.output);

    // 4. Turning the switch back on is enough; the stop is not a sticky latch.
    setComputerUseSetting(true);
    auto afterOn = experimentalComputerUseExecute(
        `{"action":"wait","duration_ms":10,"screenshot":false}`, workspace);
    assert(!afterOn.failed,
        "re-enabling computer use did not restore it: " ~ afterOn.output);

    writeln("PASS: switching computer use off stops a running loop and batch at " ~
        "their next step, refuses later calls, and clears without a new message");
    return 0;
}

module read_only_checkout_contracts;

// Focused verification that an inspection tool never takes the exclusive
// cross-process checkout lock. While another source operation holds that lock,
// a native inspector (`checksum`) must still run, and a mutation must still wait
// for the lock and abandon the wait when the turn is stopped. Before the fix an
// inspection waited the full 45 s and then failed with "Source checkout is still
// in use", which is how two conversations -- or a desktop session and a
// command-line session -- blocked each other's reads.
//
// The probes run on their own threads: a Windows named mutex is recursive for
// the thread that owns it, so a probe on the holding thread would acquire it.
//
// Run:
//   dmd -i -Iaurora-opencode-pro/source -Iaurora-opencode-pro/shared \
//       -Iaurora-opencode-core/source -Ivendor/aurora-d-0.4.5/source \
//       -Jaurora-opencode-pro/assets -of=build/read_only_checkout_contracts.exe \
//       aurora-opencode-pro/tests/read_only_checkout_contracts.d \
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//   build/read_only_checkout_contracts.exe

import auroraopencode.checkout : CheckoutLease;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ToolCancellation, ToolExecution, executeTool,
    developerSourceDirectoryHandler;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : mkdirRecurse, readText, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.string : indexOf;
import std.stdio : writeln;

private OpenCodeToolCall toolCall(string name, JSONValue arguments)
{
    return OpenCodeToolCall("fixture-" ~ name, name, arguments.toString);
}

private void hold(string path, void delegate() probe)
{
    auto held = new CheckoutLease(path);
    scope (exit) held.release();
    probe();
}

int main()
{
    string root = buildPath(tempDir(), "aurora-read-only-checkout-" ~
        to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    string source = buildPath(root, "source");
    mkdirRecurse(source);
    // A checkout marker is what makes a file inside the source share the
    // source's checkout identity, exactly as a real developer checkout does.
    mkdirRecurse(buildPath(source, ".git"));
    string note = buildPath(source, "notes.txt");
    write(note, "hello\n");
    // The workspace is not the source: the source is reached through the tool's
    // own path, which is the branch that used to take the cross-process lock.
    developerSourceDirectoryHandler = () => source;
    scope (exit) developerSourceDirectoryHandler = null;

    JSONValue arguments;
    arguments["filePath"] = note;
    ToolExecution observed;
    ToolExecution refused;
    long observedMs;
    long refusedMs;
    bool exclusive;

    hold(source, () {
        // A second acquisition must be refused: the lock really is held and
        // exclusive for the whole probe below.
        bool rejected;
        auto contender = new Thread({
            try
            {
                auto blocked = new CheckoutLease(source, null, 0);
                blocked.release();
            }
            catch (Exception) rejected = true;
        });
        contender.start();
        contender.join();
        exclusive = rejected;

        // A stopped turn is the only reason this mutation may stop waiting.
        auto cancellation = new ToolCancellation();
        auto stopper = new Thread({ Thread.sleep(150.msecs); cancellation.cancel(); });
        stopper.start();
        auto mutation = new Thread({
            const started = MonoTime.currTime;
            arguments["content"] = "rewritten\n";
            refused = executeTool(toolCall("write", arguments), root, cancellation);
            refusedMs = (MonoTime.currTime - started).total!"msecs";
        });
        mutation.start();
        mutation.join();
        stopper.join();

        auto inspection = new Thread({
            const started = MonoTime.currTime;
            observed = executeTool(toolCall("checksum", arguments), root,
                new ToolCancellation());
            observedMs = (MonoTime.currTime - started).total!"msecs";
        });
        inspection.start();
        inspection.join();
    });

    assert(exclusive, "the checkout lock must be exclusive while it is held");
    assert(observed.output.indexOf("still in use") < 0, observed.output);
    assert(!observed.failed,
        "an inspection must not wait for the source lock: " ~ observed.output);
    assert(observedMs < 5_000,
        "an inspection waited " ~ to!string(observedMs) ~ " ms for the lock");
    writeln("PASS: checksum read the source while a source operation held the lock (",
        observedMs, " ms)");

    assert(refused.failed && readText(note) == "hello\n",
        "a write must not proceed while the checkout lock is held: " ~
        refused.output);
    assert(refusedMs < 5_000,
        "a stopped write kept waiting " ~ to!string(refusedMs) ~ " ms");
    writeln("PASS: a write still waited for the source lock and stopped without changes");

    // With the lock free the same write succeeds, so the refusal above came from
    // the lock and not from an unrelated error in the fixture.
    arguments["content"] = "allowed\n";
    const applied = executeTool(toolCall("write", arguments), root,
        new ToolCancellation());
    assert(!applied.failed && readText(note) == "allowed\n", applied.output);
    writeln("read_only_checkout_contracts: PASS");
    return 0;
}

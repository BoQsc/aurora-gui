module rebuild_handoff_contracts;
import rebuild : writeSupervisorHandoff, consumeSupervisorHandoff, clearSupervisorHandoff, errorLines,
    runSupervisedChild, runRebuildHelperMode, rebuildHelperFlag, writeRebuildState,
    readRebuildOutcome, RebuildState, RebuildStatus;
import auroraopencode.checkout : canonicalPath;
import core.time : MonoTime;
import std.conv : to;
import std.datetime : Clock;
import std.file : mkdirRecurse, tempDir, exists, write, thisExePath, copy;
import std.json : JSONValue;
import std.path : buildPath, dirName, baseName;
import std.process : thisProcessID;
import std.stdio : writeln;

int main(string[] args)
{
    if (args.length > 1 && args[1] == rebuildHelperFlag)
        return runRebuildHelperMode(args);
    if (baseName(thisExePath()) == "handoff-child.exe")
    {
        assert(writeSupervisorHandoff(dirName(thisExePath()), thisExePath(), thisProcessID));
        return 42; // Requested shutdown can still end with a crash/nonzero exit.
    }
    const state = buildPath(tempDir(), "aurora-handoff-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    const image = buildPath(state, "app.exe");
    write(image, "fixture");
    assert(writeSupervisorHandoff(state, image, 123));
    assert(!consumeSupervisorHandoff(state, image, 456), "Another child must not consume a handoff");
    assert(consumeSupervisorHandoff(state, image, 123));
    assert(!consumeSupervisorHandoff(state, image, 123), "A request must be consumed once");
    assert(writeSupervisorHandoff(state, image, 123));
    assert(!consumeSupervisorHandoff(state, buildPath(state, "other.exe"), 123));
    JSONValue stale;
    stale["exe"] = canonicalPath(image);
    stale["created"] = Clock.currTime.toUnixTime() - 600;
    const marker = buildPath(state, "supervisor-handoff-123.json");
    write(marker, stale.toString());
    assert(!consumeSupervisorHandoff(state, image, 123) && !exists(marker));
    write(marker, "unfinished JSON");
    assert(!consumeSupervisorHandoff(state, image, 123) && !exists(marker));
    assert(writeSupervisorHandoff(state, image, 123));
    clearSupervisorHandoff(state, 123);
    assert(!consumeSupervisorHandoff(state, image, 123));
    assert(!writeSupervisorHandoff("", image, 123));
    RebuildState record;
    record.status = RebuildStatus.ok;
    record.phase = "relaunching";
    record.publishStatus = "failed";
    record.publishDetail = "publisher config missing";
    record.publishLog = buildPath(state, "publish.log");
    assert(writeRebuildState(state, record));
    const outcome = readRebuildOutcome(state);
    assert(outcome.publishStatus == "failed" &&
        outcome.publishDetail == "publisher config missing" &&
        outcome.publishLog == record.publishLog);
    const child = buildPath(state, "handoff-child.exe");
    copy(thisExePath(), child);
    bool handedOff;
    assert(runSupervisedChild(child, state, buildPath(state, "supervisor.log"), handedOff) == 42);
    assert(handedOff, "A requested rebuild must suppress restart even when shutdown exits abnormally");
    auto errors = errorLines("Linking app\nError C:\\app\\app.exe: Access is denied.\nfile.d(10): Error: failed\nLINK : fatal error LNK1104: cannot open file\n");
    assert(errors.length == 3 && errors[0] == "Error C:\\app\\app.exe: Access is denied.");
    writeln("PASS: rebuild/update handoffs are child-specific, fresh and single-use; linker failures appear in reports");
    return 0;
}

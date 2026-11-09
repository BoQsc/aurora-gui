module large_verification_contracts;

import auroraopencode.verificationrecipe : runVerificationRecipe, VerificationRun;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.stdio : File, writeln;
import std.json : JSONValue;
import std.string : indexOf;

void main()
{
    const workspace = absolutePath("large-verification-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(workspace);
    const artifact = buildPath(workspace, "handoff.zip");
    const bytes = 70UL * 1024 * 1024;
    {
        auto file = File(artifact, "wb");
        file.seek(bytes - 1);
        ubyte[] tail = [7]; file.rawWrite(tail); file.close();
    }
    write(buildPath(workspace, "check.py"), "# checker input\n");
    write(buildPath(workspace, "verify.json"),
        `{"inputs":["handoff.zip","check.py"],"steps":[{"kind":"tests","command":{"program":"fixture-checker"}}]}`);
    int checks;
    auto accepted = runVerificationRecipe(`{"recipe":"verify.json"}`, workspace,
        (JSONValue) { ++checks; return VerificationRun("Archive checks passed", false, false); });
    assert(accepted.passed && checks == 1, "A real >64 MiB tracked artifact could not be verified: " ~ accepted.output);
    auto changed = runVerificationRecipe(`{"recipe":"verify.json"}`, workspace,
        (JSONValue) {
            auto file = File(artifact, "r+b"); file.seek(bytes - 1);
            ubyte[] tail = [9]; file.rawWrite(tail); file.close();
            return VerificationRun("Checker said pass", false, false);
        });
    assert(!changed.passed && changed.output.indexOf("changed") >= 0,
        "A changed tracked archive was accepted despite the verifier's before/after hashes");
    int cancellationChecks;
    bool executed;
    auto cancelled = runVerificationRecipe(`{"recipe":"verify.json"}`, workspace,
        (JSONValue) { executed = true; return VerificationRun("Unexpected execution", false, false); },
        () => ++cancellationChecks > 20);
    assert(!cancelled.passed && !executed && cancelled.output.indexOf("cancelled") >= 0,
        "Stop was not observed while streaming a large verification input");
    writeln("PASS large tracked archive verification, changed-input rejection and cancellation during hashing");
}

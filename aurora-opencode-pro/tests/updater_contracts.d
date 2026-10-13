module updater_contracts;

import auroraopencode.updater : checkForUpdate;
import auroraopencode.developerworkflow : maintainerSourceBranch;
import core.time : MonoTime;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toLower, strip;

void main()
{
    const state = buildPath(tempDir(), "aurora-update-contracts-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    const executable = buildPath(state, "current.exe");
    const content = "fixture executable";
    write(executable, content);
    JSONValue release;
    release["sha256"] = toLower(toHexString(sha256Of(content)));
    release["size"] = content.length;
    release["url"] = "https://forge.boqsc.eu/~/" ~ import("update-project.txt").toLower.strip ~ "/aurora-opencode-pro.exe";
    release["source_commit"] = "0123456789012345678901234567890123456789";
    release["source_branch"] = maintainerSourceBranch;
    release["source_dirty"] = false;
    auto result = checkForUpdate(executable, state, () => release.toString());
    assert(!result.available && result.error.length == 0);
    assert(result.sourceRevision == release["source_commit"].str && result.sourceBranch == maintainerSourceBranch,
        "Current binaries must retain release provenance for source-only synchronization");
    release["source_dirty"] = true;
    assert(checkForUpdate(executable, state, () => release.toString()).error.length > 0);
    release.object.remove("source_dirty");
    release.object.remove("source_commit");
    release.object.remove("source_branch");
    result = checkForUpdate(executable, state, () => release.toString());
    assert(!result.available && result.error.length == 0 && result.sourceRevision.length == 0);
    writeln("PASS: Update retains source provenance for current binaries and rejects dirty releases");
}

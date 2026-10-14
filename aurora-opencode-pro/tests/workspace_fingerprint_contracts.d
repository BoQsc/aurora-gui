module workspace_fingerprint_contracts;
import auroraopencode.workspacefingerprint;
import core.time : Duration, MonoTime;
import std.array : replicate;
import std.conv : to;
import std.file : mkdirRecurse, write, rename, remove, rmdir;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    const root = absolutePath("fingerprint-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    const empty = workspaceFingerprint(root); assert(empty.length == 64);
    assert(workspaceFingerprint(root) == empty);
    write(buildPath(root,"source.d"),"int value = 1;\n");
    const first = workspaceFingerprint(root); assert(first.length == 64 && first != empty);
    write(buildPath(root,"source.d"),"int value = 2;\n");
    assert(workspaceFingerprint(root) != first, "Same-sized source edits must be detected");
    const second = workspaceFingerprint(root);
    rename(buildPath(root,"source.d"), buildPath(root,"renamed.d"));
    assert(workspaceFingerprint(root) != second);
    const renamed = workspaceFingerprint(root);
    mkdirRecurse(buildPath(root,"empty-folder"));
    assert(workspaceFingerprint(root) != renamed, "Empty directory changes matter");
    rmdir(buildPath(root,"empty-folder"));
    assert(workspaceFingerprint(root) == renamed);
    write(buildPath(root,"untracked.hidden"),"new");
    assert(workspaceFingerprint(root) != renamed, "No ignore rules may hide mutations");
    remove(buildPath(root,"untracked.hidden"));
    assert(workspaceFingerprint(root) == renamed);
    assert(workspaceFingerprint(root, () => true) == "");
    assert(workspaceFingerprint(root, null, Duration.zero) == "");
    assert(workspaceFingerprint(buildPath(root,"absent")) == "");
    write(buildPath(root,"large.bin"), "x".replicate(cast(size_t) workspaceSnapshotMaxBytes + 1));
    assert(workspaceFingerprint(root) == "", "Oversized snapshots must remain unknown");
    remove(buildPath(root,"large.bin"));
    foreach(i; 0 .. workspaceSnapshotMaxFiles + 1) write(buildPath(root,"file-" ~ to!string(i)),"");
    assert(workspaceFingerprint(root) == "", "Incomplete inventories must remain unknown");
    writeln("PASS complete content/path/directory snapshots; cancellation, deadline, missing path, byte and file limits remain conservative");
    return 0;
}

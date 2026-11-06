module patch_sections_contracts;
import auroraopencode.appui : PatchSectionRow, patchSectionRows;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool;
import core.time : MonoTime;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;

/// A multi-file `apply_patch` must read as a list: one row per patched file,
/// saying what happened to it and that file's own `+N -M`. Before the tool
/// stored per-file sections, every file's hunks arrived as one blob under a
/// single "Patch" header, so the reader could not tell which hunk belonged to
/// which file. These are the exact rows the tool card renders.
int main()
{
    // Keep the scratch workspace outside the package: a patch aimed inside
    // Aurora's own source tree is treated as a developer-source edit.
    const workspace = buildPath(tempDir(), "patch-sections-" ~
        to!string(MonoTime.currTime.ticks));
    if (exists(workspace)) rmdirRecurse(workspace);
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(buildPath(workspace, "state"));

    auto runPatch = (string id, string patch) {
        OpenCodeToolCall call;
        call.id = id;
        call.name = "apply_patch";
        call.arguments = `{"patch":` ~ patch ~ `}`;
        return executeTool(call, workspace);
    };

    // Adds, updates and deletes in one call: three labelled rows, each with only
    // its own change counts.
    write(buildPath(workspace, "keep.txt"), "keep\nold\n");
    write(buildPath(workspace, "gone.txt"), "bye\n");
    auto result = runPatch("multi",
        `"*** Begin Patch\n*** Add File: sub/new.txt\n+hello\n+world\n` ~
        `*** Update File: keep.txt\n@@\n keep\n-old\n+new\n` ~
        `*** Delete File: gone.txt\n*** End Patch"`);
    assert(!result.failed, "apply_patch failed: " ~ result.output);
    auto rows = patchSectionRows(result.diff);
    assert(rows.length == 3,
        "the tool card would render " ~ to!string(rows.length) ~
        " file rows, expected one per patched file: " ~ result.diff);
    assert(rows[0].path == "sub/new.txt" && rows[0].action == "added" &&
        rows[0].additions == 2 && rows[0].deletions == 0,
        "added file row is wrong: " ~ result.diff);
    assert(rows[1].path == "keep.txt" && rows[1].action == "updated" &&
        rows[1].additions == 1 && rows[1].deletions == 1,
        "updated file row is wrong: " ~ result.diff);
    assert(rows[2].path == "gone.txt" && rows[2].action == "deleted" &&
        rows[2].additions == 0 && rows[2].deletions == 1,
        "deleted file row is wrong: " ~ result.diff);
    assert(result.additions == 3 && result.deletions == 2,
        "the patch's aggregate counts changed: " ~ result.output);
    writeln("PASS multi-file apply_patch lists added, updated and deleted " ~
        "files with per-file counts");

    // A Move-to names its destination and counts only the content it changed.
    write(buildPath(workspace, "move-source.txt"), "keep me\nold\n");
    auto moved = runPatch("move",
        `"*** Begin Patch\n*** Update File: move-source.txt\n` ~
        `*** Move to: moved/target.txt\n@@\n keep me\n-old\n+new\n*** End Patch"`);
    assert(!moved.failed, "apply_patch move failed: " ~ moved.output);
    rows = patchSectionRows(moved.diff);
    assert(rows.length == 1 && rows[0].path == "moved/target.txt" &&
        rows[0].action == "moved" && rows[0].additions == 1 &&
        rows[0].deletions == 1,
        "a Move-to must be one 'moved' row: " ~ moved.diff);

    // A pure rename changes no lines: the row still names the file.
    write(buildPath(workspace, "rename-source.txt"), "same\n");
    auto renamed = runPatch("rename",
        `"*** Begin Patch\n*** Update File: rename-source.txt\n` ~
        `*** Move to: renamed/target.txt\n*** End Patch"`);
    assert(!renamed.failed, "apply_patch rename failed: " ~ renamed.output);
    rows = patchSectionRows(renamed.diff);
    assert(rows.length == 1 && rows[0].path == "renamed/target.txt" &&
        rows[0].action == "moved" && rows[0].additions == 0 &&
        rows[0].deletions == 0,
        "a pure rename must still list the moved file: " ~ renamed.diff);
    writeln("PASS moved paths are listed once, counting only changed lines");

    // A conversation saved before the sections existed has bare hunks: it still
    // renders its diff, and it must not invent file rows.
    auto legacy = patchSectionRows("@@ -1,1 +1,1 @@\n-old\n+new\n");
    assert(legacy.length == 0,
        "a legacy hunk-only diff invented file rows: " ~
        to!string(legacy.length));
    assert(patchSectionRows("").length == 0);
    writeln("PASS restored hunk-only diffs stay a plain diff");
    return 0;
}

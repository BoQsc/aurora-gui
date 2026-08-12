module auroraopencode_pro_tools_test;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.tools : executeTool, resolveToolPath;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
    write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

private OpenCodeToolCall makeCall(string name, string args)
{
    OpenCodeToolCall call;
    call.id = "call_test";
    call.name = name;
    call.arguments = args;
    return call;
}

int main()
{
    const dir = buildPath(tempDir(), "aurora-opencode-tools-test");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "src"));
    write(buildPath(dir, "src", "main.d"), "import std.stdio;\nvoid main() {}\n");
    write(buildPath(dir, "README.md"), "aurora tools test\n");

    // read a file from the workspace (relative path)
    auto readResult = executeTool(makeCall("read",
        `{"filePath":"src/main.d"}`), dir);
    assert(!readResult.failed, "read failed: " ~ readResult.output);
    assert(readResult.output.indexOf("void main") >= 0,
        "read did not return file contents");

    // write a new file then read it back
    auto writeResult = executeTool(makeCall("write",
        `{"filePath":"src/generated.txt","content":"hello from tool"}`), dir);
    assert(!writeResult.failed, "write failed: " ~ writeResult.output);
    assert(readText(buildPath(dir, "src", "generated.txt")) ==
        "hello from tool", "write did not persist the content");

    // glob with ** recursion
    auto globResult = executeTool(makeCall("glob", `{"pattern":"**/*.d"}`),
        dir);
    assert(!globResult.failed, "glob failed: " ~ globResult.output);
    assert(globResult.output.indexOf("main.d") >= 0,
        "glob did not recurse into src/");

    // grep finds the marker text
    auto grepResult = executeTool(makeCall("grep", `{"pattern":"aurora"}`),
        dir);
    assert(!grepResult.failed, "grep failed: " ~ grepResult.output);
    assert(grepResult.output.indexOf("README.md") >= 0,
        "grep did not find the matching file");

    // bash echo round-trips through the shell
    auto bashResult = executeTool(makeCall("bash",
        `{"command":"echo aurora-tool-echo"}`), dir);
    assert(!bashResult.failed, "bash failed: " ~ bashResult.output);
    assert(bashResult.output.indexOf("aurora-tool-echo") >= 0,
        "bash echo output missing: " ~ bashResult.output);

    // unknown tools report a clear error rather than crashing
    auto unknownResult = executeTool(makeCall("nope", "{}"), dir);
    assert(unknownResult.failed, "unknown tool should fail");

    writeln("Aurora OpenCode Pro tools module test passed.");
    try rmdirRecurse(dir);
    catch (Exception) {}
    return 0;
}

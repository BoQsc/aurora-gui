// Probe for the tool-host spawn guard. This program is not a filesystem tool
// host: it asks for a host-only tool (read) and prints what came back, so the
// refusal is observable instead of silent. Driven by
// tests/filesystem_host_recursion_check.py; not part of the architecture list.
module filesystem_host_spawn_probe;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.tools : ChangeContext, executeTool;

import std.file : tempDir;
import std.stdio : writeln;

int main()
{
    auto result = executeTool(
        OpenCodeToolCall("probe", "read", `{"filePath":"missing.txt"}`),
        tempDir(), null, ChangeContext.init);
    writeln(result.failed ? "failed" : "ok");
    writeln(result.output);
    return 0;
}

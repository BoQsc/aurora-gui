module calculator_contracts;

import auroraopencode.calculator;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler;
import auroraopencode.opencode_client;
import auroraopencode.taskpolicy : diagnosticToolAllowed, analysisToolAllowed;
import std.json : parseJSON;
import std.math : isClose;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;

int main()
{
    assert(isClose(evaluateArithmetic("49 * .9"), 44.1, 1e-12));
    assert(isClose(evaluateArithmetic("49 * .9 + 5"), 49.1, 1e-12));
    assert(evaluateArithmetic("2+3*4") == 14);
    assert(evaluateArithmetic("(2+3)*4") == 20);
    assert(evaluateArithmetic("-2^2") == -4);
    assert(evaluateArithmetic("2^3^2") == 512);
    assert(evaluateArithmetic("2^-2") == .25);
    assert(evaluateArithmetic("17%5") == 2);
    assert(evaluateArithmetic("1e2 + 2.5e-1") == 100.25);
    assert(evaluateArithmetic(" \t-(-2)\n") == 2);
    foreach (expression; ["", ".", "1e", "1e+", "1/0", "3%0", "1e999", "(-1)^.5", "2^9999",
            "1 2", "2**3", "1+", "(1+2", "1+2)", "NaN", "Infinity", "__import__('os')", "1; write('x')"])
    {
        bool rejected;
        try evaluateArithmetic(expression); catch (Exception) { rejected = true; }
        assert(rejected, expression);
    }
    bool rejected;
    try evaluateArithmetic(new char[513]); catch (Exception) { rejected = true; }
    assert(rejected);
    rejected = false;
    import std.array : replicate;
    try evaluateArithmetic("(".replicate(40) ~ "1" ~ ")".replicate(40)); catch (Exception) { rejected = true; }
    assert(rejected);
    writeln("PASS bounded arithmetic, scientific literals, precedence, powers and invalid/unsafe input");

    const args = `{"expressions":["49*.9","49*.9+5","17%5"]}`;
    const result = executeTool(OpenCodeToolCall("math", "calculate", args), ".");
    assert(!result.failed && !result.verification.passed);
    const values = parseJSON(result.output)["results"].array;
    assert(values.length == 3 && isClose(values[0]["value"].floating, 44.1, 1e-12));
    assert(isClose(values[1]["value"].floating, 49.1, 1e-12));
    assert(executeTool(OpenCodeToolCall("bad", "calculate", `{"expressions":["1+2","1/0"]}`), ".").failed);
    assert(executeTool(OpenCodeToolCall("bad", "calculate", `{"expressions":[]}`), ".").failed);
    foreach (definitions; [nativeOnlyToolDefinitions(), builtinToolDefinitions()])
    {
        size_t found;
        foreach (tool; definitions) if (tool.name == "calculate") ++found;
        assert(found == 1);
    }
    assert(diagnosticToolAllowed("calculate"));
    foreach (name; ["calculate", "read", "run", "verify", "read_plan", "update_plan"])
        assert(analysisToolAllowed(name));
    foreach (name; ["write", "apply_patch", "download", "rebuild", "sync", "assign"])
        assert(!analysisToolAllowed(name));
    auto calculation = OpenCodeToolCall("math", "calculate", args);
    assert(parallelTool(calculation));
    auto client = new OpenCodeClient("", "");
    scope(exit) client.closeSession();
    ChangeContext context;
    context.analysisOnly = true; context.diagnosticReadOnly = true;
    const before = toolWorkspaceRevision(".");
    auto batch = scheduleToolBatch(client, 91, [OpenCodeToolCall("math", "calculate", args)], ".", new ToolCancellation(), context);
    bool settled;
    const deadline = MonoTime.currTime + 5.seconds;
    while (!settled && MonoTime.currTime < deadline)
    {
        OpenCodeEvent[] events;
        client.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning)
            {
                assert(!event.toolFailed && !event.workspaceChanged && !event.verificationPassed, event.text);
                settled = true;
            }
        Thread.sleep(1.msecs);
    }
    assert(settled && toolWorkspaceRevision(".") == before);
    writeln("PASS native and legacy tool registration, analysis/reviewer scheduling and no workspace effects");
    return 0;
}

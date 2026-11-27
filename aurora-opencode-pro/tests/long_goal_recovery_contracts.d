module long_goal_recovery_contracts;
import auroraopencode.core;
import auroraopencode.agentloop;
import auroraopencode.requestpolicy;
import auroraopencode.executioncontrol : executionState;
import auroraopencode.tools : executeTool, nativeOnlyToolDefinitions, installDeveloperToolSource,
    restoreDeveloperToolSource, rebuildRequestHandler;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, tempDir;
import std.path : buildPath, absolutePath;
import std.process : environment;
import std.string : indexOf;
import std.stdio : writeln;

void add(ref ChatSession s, ChatMessage m)
{
    m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    s.activeLeafId = m.id; s.messages ~= m;
}
void say(ref ChatSession s, string role, string content, bool internal = false)
{
    ChatMessage m; m.role = role; m.content = content; m.internal = internal; add(s, m);
}
bool hasTool(const PreparedRequest request, string name)
{
    foreach (tool; request.tools) if (tool.name == name) return true;
    return false;
}
int main()
{
    ChatSession loop;
    say(loop, "user", "Implement and verify the entire requested delivery.");
    loop.contract.intent = loop.contract.currentIntent = "implementation";
    loop.goal = loop.messages[0].content; loop.goalStatus = "active";
    loop.verificationStatus = "required";
    ChatMessage read; read.role = "tool"; read.toolName = "read";
    read.content = "The same unchanged file contents";
    foreach (notice; 0 .. 2)
    {
        foreach (i; 0 .. 3)
        {
            read.toolArgs = i % 2 ? `{"limit":200,"filePath":"source.txt"}` : `{"filePath":"source.txt"}`;
            add(loop, read);
        }
        const guidance = stagnantToolGuidance(loop);
        assert(guidance.indexOf("Run the next declared behavioral check") >= 0);
        say(loop, "user", guidance, true);
        assert(!stagnantToolGuidance(loop).length, "A reminder repeated without another observation");
    }
    assert(observationRecovery(loop).focused(), "Ignored inspection reminders did not change strategy");
    RequestPolicy policy; policy.toolsEnabled = true;
    policy.availableTools = [OpenCodeToolDef("read", "read", "{}"), OpenCodeToolDef("dshell", "list", "{}"),
        OpenCodeToolDef("update_plan", "plan", "{}"), OpenCodeToolDef("rebuild", "rebuild", "{}"),
        OpenCodeToolDef("run", "run", "{}"), OpenCodeToolDef("verify", "verify", "{}"),
        OpenCodeToolDef("write", "write", "{}"), OpenCodeToolDef("goal_complete", "complete", "{}")];
    auto focused = prepareAgentRequest(loop, policy);
    assert(!hasTool(focused, "read") && !hasTool(focused, "dshell") && !hasTool(focused, "update_plan") && !hasTool(focused, "rebuild"));
    assert(!hasTool(focused, "run") && hasTool(focused, "verify") && hasTool(focused, "write"),
        "Focused recovery left a direct file-viewer bypass or lost its productive tools");
    assert(focused.messages[0].content.indexOf("next declared acceptance check") >= 0);
    policy.diagnosticReview = true;
    assert(hasTool(prepareAgentRequest(loop, policy), "read"), "A read-only diagnosis was forced to mutate");
    policy.diagnosticReview = false;
    ChatMessage viewer; viewer.role = "tool"; viewer.toolName = "run";
    viewer.toolArgs = `{"program":"python","args":["-B","-c","print(open('source.txt').read())"]}`;
    viewer.content = read.content; add(loop, viewer);
    assert(observationRecovery(loop).focused() && !hasTool(prepareAgentRequest(loop, policy), "read"),
        "A Python file viewer reset the observation loop");
    RequestPolicy fallback = policy;
    fallback.availableTools = [OpenCodeToolDef("run", "run", "{}"), OpenCodeToolDef("write", "write", "{}")];
    assert(hasTool(prepareAgentRequest(loop, fallback), "run"), "A provider without verify lost its execution fallback");
    ChatMessage receipt; receipt.role = "tool"; receipt.toolName = "verify";
    receipt.verificationCheck = "verify:tests"; receipt.verificationScope = "stable";
    receipt.toolArgs = `{"inputs":["source.txt"],"steps":[{"kind":"tests","command":{"program":"checker"}}]}`;
    receipt.content = `{"inputsSha256":"A","passed":true,"steps":[{"command":{"program":"checker"}}]}`;
    add(loop, receipt);
    assert(!observationRecovery(loop).focused(), "A new check result did not retire recovery");
    foreach (notice; 0 .. 2)
    {
        foreach (i; 0 .. 3) add(loop, read);
        say(loop, "user", stagnantToolGuidance(loop), true);
    }
    // A new call ID/receipt with unchanged inputs and command supplies no new
    // progress. It must not reopen read tools and restart the same file tour.
    add(loop, receipt);
    assert(observationRecovery(loop).focused() && !hasTool(prepareAgentRequest(loop, policy), "read"),
        "An already-passed unchanged checker reset no-progress recovery");
    receipt.content = `{"inputsSha256":"B","passed":true,"steps":[{"command":{"program":"checker"}}]}`;
    add(loop, receipt);
    assert(!observationRecovery(loop).focused(), "A check on changed actual inputs was ignored");
    ChatMessage check; check.role = "tool"; check.toolName = "run";
    check.failed = true; check.content = "A concrete checker failure identifying the next repair";
    add(loop, check);
    assert(hasTool(prepareAgentRequest(loop, policy), "read"), "A real checker failure did not restore targeted inspection");
    writeln("PASS repeated unchanged inspection escalates to an action/check, then restores normal capabilities");

    ChatSession ledger;
    say(ledger, "user", "Implement and check the delivery.");
    ChatMessage failed; failed.role = "tool"; failed.toolName = "run"; failed.toolCallId = "initial";
    failed.failed = true; failed.verificationScope = "old"; failed.verificationCheck = "verify:tests";
    failed.toolArgs = `{"program":"python","args":["run_checks.py","--phase","1"]}`;
    failed.content = "Transient worker failure, exit 75"; add(ledger, failed);
    ChatMessage passed = failed; passed.failed = false; passed.toolCallId = "retry"; passed.verificationScope = "current";
    passed.toolArgs = `{"program":"python","args":["-B","run_checks.py","--phase","1"]}`;
    passed.content = "PHASE 1 PASSED"; add(ledger, passed);
    assert(executionState(ledger).remaining.indexOf("Behavioral check") < 0,
        "Disabling Python cache writes prevented the successful retry from resolving its failure");
    failed.toolCallId = "script-flag";
    failed.toolArgs = `{"program":"python","args":["probe.py","-B"]}`; add(ledger, failed);
    passed.toolArgs = `{"program":"python","args":["-B","probe.py"]}`; add(ledger, passed);
    assert(executionState(ledger).remaining.indexOf("Behavioral check") >= 0,
        "A script argument was incorrectly discarded as an interpreter flag");
    writeln("PASS Python cache-control retry identity preserves actual script arguments");

    ChatSession complete;
    say(complete, "user", "Implement the full delivery.");
    complete.contract.intent = complete.contract.currentIntent = "implementation";
    complete.goal = complete.messages[0].content; complete.goalStatus = "completed";
    complete.verificationStatus = "passed";
    ChatMessage finished; finished.role = "tool"; finished.toolName = "goal_complete";
    finished.content = "Goal completed with accepted current-source evidence."; add(complete, finished);
    auto finalReply = prepareAgentRequest(complete, policy);
    assert(!finalReply.tools.length && finalReply.messages[0].content.indexOf("Produce the final response now") >= 0,
        "A validated completed goal could start another audit or rebuild instead of its final reply");
    say(complete, "user", "Inspect the current log and identify its failures.");
    assert(hasTool(prepareAgentRequest(complete, policy), "read"), "A later real request inherited the prior goal's final-only handoff");
    writeln("PASS validated goal completion delivers its final reply; a new human request retains its tools");

    const root = absolutePath(buildPath(tempDir(), "aurora-recovery-scope-" ~ to!string(MonoTime.currTime.ticks)));
    mkdirRecurse(root); setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    auto previousSource = installDeveloperToolSource("");
    scope(exit) restoreDeveloperToolSource(previousSource);
    auto previousHandler = rebuildRequestHandler;
    scope(exit) rebuildRequestHandler = previousHandler;
    bool reached;
    rebuildRequestHandler = (string reason) { reached = true; return false; };
    auto denied = executeTool(OpenCodeToolCall("outside", "rebuild", "{}"), root);
    assert(denied.failed && !reached && denied.output.indexOf("own source") >= 0,
        "An unrelated task invoked Aurora's rebuild when developer source was unset");
    const source = buildPath(root, "aurora-opencode-pro");
    mkdirRecurse(buildPath(source, "shared")); write(buildPath(source, "shared", "rebuild.d"), "module rebuild;");
    executeTool(OpenCodeToolCall("self", "rebuild", "{}"), source);
    assert(reached, "An actual Aurora source workspace lost its rebuild bridge");
    const previousRoot = environment.get("AURORA_TOOL_ROOT", "");
    scope(exit) environment["AURORA_TOOL_ROOT"] = previousRoot;
    environment["AURORA_TOOL_ROOT"] = root;
    reached = false;
    assert(executeTool(OpenCodeToolCall("isolated", "rebuild", "{}"), source).failed && !reached);
    foreach (tool; nativeOnlyToolDefinitions())
        assert(tool.name != "rebuild" && tool.name != "sync" && tool.name != "computer" && tool.name != "open",
            "An isolated task advertised forbidden application/desktop operations");
    writeln("PASS unrelated and isolated tasks cannot invoke self-maintenance; legitimate source rebuilds remain available");
    return 0;
}

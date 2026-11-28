module failed_check_guidance_contracts;
import auroraopencode.core;
import auroraopencode.executioncontrol;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    ChatSession s; s.verificationStatus = "passed";
    ChatMessage user; user.id = "human"; user.role = "user"; user.content = "Fix the routing project and verify it.";
    ChatMessage failed; failed.id = failed.toolCallId = "named-failure"; failed.parentId = user.id;
    failed.role = "tool"; failed.toolName = "run"; failed.failed = true;
    failed.verificationScope = "workspace|1"; failed.verificationCheck = "verify:tests";
    failed.toolArgs = `{"program":"python","args":["-B","-m","unittest","tests.test_routes.CliTests.test_atomic","-v"],"check":"tests","inputs":["routes.py","tests"]}`;
    failed.content = "A real named test failed.";
    s.messages = [user, failed]; s.activeLeafId = failed.id;
    const pending = executionState(s).remaining;
    assert(pending.indexOf("tests.test_routes.CliTests.test_atomic") >= 0,
        "Recovery supplied a call ID without the concrete pending checker invocation");
    assert(pending.indexOf("check_revisions") < 0, "Named-test recovery suggested an unsupported inline-check correction");
    ChatMessage passing = failed; passing.id = "unrelated"; passing.parentId = failed.id;
    passing.toolCallId = passing.id; passing.failed = false; passing.content = "Passed";
    passing.toolArgs = `{"program":"python","args":["-B","-m","unittest","discover","-v"]}`;
    s.messages ~= passing; s.activeLeafId = passing.id;
    assert(executionState(s).remaining.indexOf("named-failure") >= 0,
        "An unrelated successful suite waived the named invocation");
    passing.id = "rerun"; passing.parentId = s.activeLeafId; passing.toolCallId = passing.id;
    passing.toolArgs = failed.toolArgs; s.messages ~= passing; s.activeLeafId = passing.id;
    assert(!executionState(s).remaining.length, "The actual successful named rerun remained unresolved");
    ChatMessage recipe = failed; recipe.toolName = "verify";
    recipe.toolArgs = `{"inputs":["routes.py"],"steps":[{"kind":"tests","command":{"program":"python","args":["already_passed.py"]}},{"kind":"tests","command":{"program":"python","args":["actually_failed.py"]}}]}`;
    recipe.content = `{"passed":false,"failedStep":{"kind":"tests","command":{"program":"python","args":["actually_failed.py"]}},"steps":[{"command":{"program":"python","args":["already_passed.py"]},"passed":true},{"command":{"program":"python","args":["actually_failed.py"]},"passed":false}]}` ~
        "\nAssistant check-recovery guidance (not program output): Diagnose the mismatch.";
    const pendingCommands = checkCommands(recipe);
    assert(pendingCommands.length == 1 && pendingCommands[0].indexOf("actually_failed.py") >= 0,
        "A failed recipe demanded repetition of its already successful steps or lost its native report behind guidance");
    writeln("PASS named failures expose exact retry commands; unrelated successes cannot waive checks; actual reruns settle them");
    return 0;
}

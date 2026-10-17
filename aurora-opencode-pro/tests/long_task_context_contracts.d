module long_task_context_contracts;
import auroraopencode.core;
import auroraopencode.taskcontext;
import auroraopencode.taskflow;
import auroraopencode.taskpolicy;
import std.array : replicate;
import std.conv : to;
import std.json : parseJSON;
import std.string : indexOf;
import std.utf : validate;
import std.stdio : writeln;

void receipt(ref ChatSession s, string id, string check, bool failed = false)
{
    ChatMessage m;
    m.id = id; m.parentId = s.activeLeafId; m.role = "tool"; m.toolName = "verify";
    m.toolCallId = "call-" ~ id; m.verificationCheck = check;
    m.verificationScope = s.verificationScope; m.failed = failed;
    s.messages ~= m; s.activeLeafId = id;
}
int main()
{
    ChatSession s;
    ChatMessage request; request.id = "request"; request.role = "user";
    request.content = "Improve browser rendering and interaction.";
    s.messages ~= request; s.activeLeafId = request.id;
    acceptTaskRequest(s, request.content, request.id);
    s.objective = request.content;
    s.verificationScope = "checkout|process|1";
    s.verificationStatus = "required";
    s.taskSteps = [TaskStep("Fix sizing", "in_progress", "sizing", "edit", "Six independent sizing cases match")];
    foreach (i; 0 .. 18) s.taskSteps ~= TaskStep("Earlier completed outcome " ~ to!string(i), "completed", "old-" ~ to!string(i));
    s.taskSteps ~= TaskStep("Verify render", "pending", "render", "verify", "Independent render matches");
    s.taskSteps ~= TaskStep("Verify tests", "pending", "tests", "verify", "Regression tests pass");
    s.contract.work = workContextForPlan(s, s.taskSteps);
    s.contract.work.detourReason = "Reduce the failing fourth case";
    s.contract.work.returnTo = "Finish sizing corpus";
    s.contract.constraints = ["Keep user changes", "Preserve complete history"];
    s.contract.decisions = ["Use the independent reference"];
    foreach (i; 0 .. 1000) s.contract.decisions ~= "Plan change: " ~ to!string(i) ~ " λ🙂".replicate(100);
    const saved = activeTaskStateJson(s);
    foreach (budget; [900, 6000, 12000, 16000])
    {
        const context = taskContext(s, request.content, true, budget);
        validate(context);
        assert(context.length <= budget);
        assert(context.indexOf("sizing") >= 0 && context.indexOf("Finish sizing corpus") >= 0);
        assert(context.indexOf("Keep user changes") >= 0);
        if (budget >= 6000)
        {
            assert(context.indexOf("render") >= 0 && context.indexOf("tests") >= 0);
            assert(context.indexOf("old-17") >= 0);
        }
    }
    assert(activeTaskStateJson(s) == saved, "Projection mutated full durable records");
    receipt(s, "compile", "verify:compile");
    receipt(s, "tests", "verify:tests");
    receipt(s, "render", "verify:render");
    assert(!satisfiesEvidence(verificationCoverage(s), requiredEvidence(s)));
    assert(evidenceMatches(s, s.taskSteps[$ - 2], "call-render"));
    assert(evidenceMatches(s, s.taskSteps[$ - 1], "call-tests"));
    assert(!evidenceMatches(s, s.taskSteps[$ - 1], "call-compile"));
    assert(taskContext(s, "", true).indexOf("call-render = verify:render") >= 0);
    receipt(s, "interaction", "verify:interaction");
    assert(satisfiesEvidence(verificationCoverage(s), requiredEvidence(s)));
    auto complete = parseJSON(`{"plan":[{"id":"tests","step":"Verify tests","status":"completed","evidence":["call-tests"]}]}`);
    auto completed = normalizedPlan(s, complete["plan"], s.taskSteps);
    const checked = completed[$ - 1];
    assert(checked.status == "completed" && supportedStep(s, checked));
    receipt(s, "failed-render", "", true);
    assert(!satisfiesEvidence(verificationCoverage(s), requiredEvidence(s)));
    assert(!evidenceMatches(s, s.taskSteps[$ - 2], "call-render"));
    assert(supportedStep(s, checked), "A recorded historical outcome disappeared");
    receipt(s, "tests-again", "verify:tests");
    assert(evidenceMatches(s, s.taskSteps[$ - 1], "call-tests-again"));
    s.verificationScope = "checkout|process|2";
    assert(!evidenceMatches(s, s.taskSteps[$ - 1], "call-tests-again"));
    assert(!satisfiesEvidence(verificationCoverage(s), requiredEvidence(s)));
    assert(supportedStep(s, checked));
    receipt(s, "new-tests", "verify:tests");
    s.messages[$ - 1].toolCallId = "call-tests";
    assert(taskEvidenceIndex(s)["call-tests"] == "verify-current|verify:tests",
        "A provider's reused call ID selected an earlier receipt");
    ChatSession restored; restoreActiveTaskState(restored, activeTaskStateJson(s));
    assert(restored.verificationScope == s.verificationScope);
    ChatSession renderOnly; renderOnly.objective = "Correct the web browser layout";
    assert(requiredEvidence(renderOnly).length == 3, "Product name invented an interaction requirement");
    writeln("PASS bounded UTF-8 task context preserves objective, position, return point, constraints and full saved audit");
    writeln("PASS partial checks support outcomes; aggregate coverage, failed checks and changed source remain enforced");
    return 0;
}

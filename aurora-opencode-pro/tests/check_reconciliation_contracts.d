module check_reconciliation_contracts;

import auroraopencode.core;
import auroraopencode.checkreconciliation;
import auroraopencode.toolsettlement;
import auroraopencode.executioncontrol;
import auroraopencode.verificationrecipe;
import auroraopencode.opencode_client : OpenCodeEvent;
import auroraopencode.checkout : checkoutIdentity;
import auroraopencode.effectfacts : EffectFacts, installEffectFacts;
import core.time : MonoTime;
import std.conv : to;
import std.file : tempDir, mkdirRecurse, write;
import std.path : buildPath;
import std.json;
import std.stdio : writeln;

int main()
{
    const root = buildPath(tempDir(), "aurora-check-reconciliation-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root); write(buildPath(root, "invoice.py"), "actual checked source");
    write(buildPath(root, "unrelated.py"), "unrelated");
    ChatSession s; s.contract.intent = s.contract.currentIntent = "implementation";
    s.verificationScope = checkoutIdentity(root) ~ "|7";
    ChatMessage human; human.id = "human"; human.role = "user"; human.content = "Fix and verify the invoice.";
    s.messages ~= human; s.activeLeafId = human.id;
    ChatMessage old; old.id = old.toolCallId = "failed-inline"; old.parentId = s.activeLeafId;
    old.role = "tool"; old.toolName = "verify"; old.failed = true;
    old.verificationCheck = "verify:tests"; old.verificationScope = s.verificationScope;
    old.toolArgs = `{"inputs":["invoice.py"],"steps":[{"kind":"tests","command":{"program":"python","args":["-c","assert price(74,True)==71.6"]}}]}`;
    old.content = `{"passed":false}`; s.messages ~= old; s.activeLeafId = old.id;
    const args = `{"inputs":["invoice.py"],"check_revisions":[{"failed_call_id":"failed-inline","reason":"The requested float calculation rounds in binary; exact equality was the erroneous hypothesis. The corrected case keeps the same inputs and expected amount."}],"steps":[{"kind":"tests","command":{"program":"python","args":["-c","import math; assert math.isclose(price(74,True),71.6,rel_tol=1e-9)"]}}]}`;
    auto result = runVerificationRecipe(args, root, (JSONValue) => VerificationRun("corrected case passed", false, false, "tests"));
    assert(result.passed);
    OpenCodeEvent event; event.toolName = "verify"; event.toolCallId = "corrected";
    event.text = result.output; event.verificationPassed = true; event.verificationExitCode = 0; event.verificationCheck = "verify:tests";
    event.verificationRevision = 7;
    ToolResultPolicy policy; policy.workspace = policy.verificationWorkspace = root; policy.currentRevision = 7;
    auto settled = settleToolResult(s, event, args, policy);
    assert(settled.acceptedVerification && recordedCheckRevision(settled.message, old.id), settled.message.content);
    auto current = settled.message; current.id = "corrected"; current.parentId = s.activeLeafId;
    s.messages ~= current; s.activeLeafId = current.id; s.verificationStatus = "passed";
    assert(!executionState(s).remaining.length, "A grounded current correction still blocks completion");
    writeln("PASS actual settlement records the explained correction and resolves only its original ad hoc failure");

    foreach (kind; 0 .. 10)
    {
        auto bad = parseJSON(args);
        ChatSession target = s; target.messages = s.messages[0 .. 2].dup; target.activeLeafId = old.id;
        if (kind == 0) bad["check_revisions"].array[0]["failed_call_id"] = "invented";
        if (kind == 1) bad["check_revisions"].array[0]["reason"] = "done";
        auto proof = parseJSON(result.output);
        if (kind == 2) proof["inputs"] = JSONValue(["unrelated.py"]);
        if (kind == 3) { auto named = parseJSON(old.toolArgs); named["steps"].array[0]["command"]["args"] = JSONValue(["test_invoice.py"]); target.messages[1].toolArgs = named.toString(); }
        if (kind == 4) proof["steps"].array[0]["kind"] = "compile";
        if (kind == 5) target.messages[1].toolArgs = `{"recipe":"user-tests.json"}`;
        if (kind == 6) proof["passed"] = false;
        if (kind == 7) { auto newer = human; newer.id = "later-request"; newer.parentId = old.id; target.messages ~= newer; target.activeLeafId = newer.id; }
        if (kind == 8) target.messages[0].content = "Preserve this supplied test: assert price(74,True)==71.6";
        if (kind == 9) { auto named = parseJSON(old.toolArgs); named["steps"].array[0]["command"]["args"] = JSONValue(["-c", "import unittest; unittest.main()"]); target.messages[1].toolArgs = named.toString(); }
        string error;
        const accepted = validatedCheckRevisions(target, bad.toString(), root, proof, error);
        assert(!accepted.array.length && error.length, "An invalid correction escaped validation: " ~ to!string(kind));
    }
    writeln("PASS invented receipts, empty reasons, unrelated inputs, named tests and compilation-only evidence cannot reconcile failures");
    event.verificationRevision = 6;
    auto stale = settleToolResult(s, event, args, policy);
    assert(!recordedCheckRevision(stale.message, old.id), "A stale proof reconciled a current check");
    auto facts = new EffectFacts;
    auto previous = installEffectFacts(facts);
    string captureError;
    const captured = validatedCheckRevisions(s, args, root, parseJSON(result.output), captureError);
    assert(!captureError.length && captured.array.length == 1 && facts.toJson().object.length > 0);
    installEffectFacts(new EffectFacts(facts.toJson()));
    string replayError;
    const replayed = validatedCheckRevisions(s, args, root, parseJSON(result.output), replayError);
    installEffectFacts(previous);
    assert(!replayError.length && captured == replayed, "Check correction depends on uncaptured filesystem observations");
    return 0;
}

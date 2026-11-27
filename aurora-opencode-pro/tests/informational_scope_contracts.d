module informational_scope_contracts;

import auroraopencode.core;
import auroraopencode.requestintent;
import auroraopencode.taskflow : acceptTaskRequest;
import auroraopencode.turnpolicy;
import auroraopencode.taskpolicy : requiredEvidence;
import std.stdio : writeln;

void add(ref ChatSession session, string role, string text, string tool = "", bool failed = false)
{
    import std.conv : to;
    ChatMessage m; m.id = "m" ~ to!string(session.messages.length); m.parentId = session.activeLeafId;
    m.role = role; m.content = text; m.toolName = tool; m.failed = failed;
    session.messages ~= m; session.activeLeafId = m.id;
    if (role == "user") acceptTaskRequest(session, text, m.id);
}

int main()
{
    foreach (question; [
        "Calculate a total for 7 items at 2.50. Apply a 20% discount, then add 3 shipping. Return only the amount.",
        "Please compute 16 * 1.25, then add tax at 5%. Return JSON.",
        "Calculate the total from invoice.csv and return the amount."])
    {
        assert(requestIntent(question) == RequestIntent.analysis, question);
        assert(!artifactChangeRequested(question), "Arithmetic implied a file mutation: " ~ question);
        ChatSession s; add(s, "user", question);
        add(s, "tool", "The exact computed amount", "calculate");
        add(s, "assistant", "17.00");
        TurnPolicy policy; policy.toolsEnabled = true;
        assert(!requiredEvidence(s).length && decideTurn(s, policy).action == TurnAction.settle,
            "A calculation answer required an implementation artifact and verification ceremony");
    }
    foreach (action; [
        "Calculate totals and write invoice.json.",
        "Calculate costs and implement the missing billing module.",
        "Calculate 8*9 and edit summary.txt.",
        "Calculate 5 + 7, then add a CLI to calculator.py.",
        "Compute the answer and save it in answer.txt.",
        "Apply a discount to billing.py and verify it."])
        assert(requestIntent(action) == RequestIntent.implementation, action);
    writeln("PASS supplied calculations settle from grounded results; requested artifacts still require delivery");

    const diagnostic = "Diagnose the failing test from its specification. Execute the reproducer. Do not edit files. " ~
        "Return only JSON keys actual, required, test_expected (numbers), repair ('test' or 'implementation').";
    assert(requestIntent(diagnostic) == RequestIntent.analysis);
    assert(!artifactChangeRequested(diagnostic), "A response field was parsed as an instruction to repair");
    ChatSession s; add(s, "user", diagnostic);
    add(s, "tool", "AssertionError: 12 != 13", "run", true);
    add(s, "assistant", `{"actual":12,"required":12,"test_expected":13,"repair":"test"}`);
    TurnPolicy policy; policy.toolsEnabled = true;
    const decision = decideTurn(s, policy);
    assert(decision.action == TurnAction.settle, "A requested failing diagnosis was forced to repair the unchanged test");
    assert(requestIntent("Analyze the error. Return JSON keys repair, test. Then implement the fix.") == RequestIntent.implementation);
    assert(requestIntent("Return JSON keys result, save. Please save the report to report.json.") == RequestIntent.implementation);
    assert(requestIntent("Return JSON keys result, save, then implement the fix.") == RequestIntent.implementation);
    writeln("PASS response-field labels cannot authorize repair or create an endless diagnostic recovery");
    return 0;
}

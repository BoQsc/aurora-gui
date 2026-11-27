module numerical_grounding_contracts;
import auroraopencode.core;
import auroraopencode.taskflow : acceptTaskRequest;
import auroraopencode.executioncontrol;
import auroraopencode.numericalgrounding;
import auroraopencode.answercontract : answerContract;
import auroraopencode.turnpolicy;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

void add(ref ChatSession s, string role, string content, string tool = "", string args = "")
{
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = content; m.toolName = tool; m.toolArgs = args;
    s.messages ~= m; s.activeLeafId = m.id;
    if (role == "user") acceptTaskRequest(s, content, m.id);
}
bool continues(ref ChatSession s, bool tools = true)
{
    const state = executionState(s);
    return executionShouldContinue(s, tools, state);
}
int main()
{
    const question = "Read invoice.py without changing files. Independently calculate the current result for 49 with a coupon and the required result under the original rule.";
    assert(numericalCodeRequest(question));
    ChatSession s; add(s, "user", question);
    add(s, "tool", "Existing code has a different delivery threshold", "read", `{"filePath":"invoice.py"}`);
    add(s, "assistant", "Current result 48.60");
    assert(continues(s), "An unexecuted numerical claim about current code was allowed to finish");
    s.goal = "An earlier project"; s.goalStatus = "paused";
    TurnPolicy policy; policy.toolsEnabled = true;
    const decision = decideTurn(s, policy);
    assert(decision.action == TurnAction.request && !decision.advanceGoal && s.goalStatus == "paused");
    add(s, "tool", "48.60", "calculate", `{"expression":"(49+5)*.9"}`);
    assert(numericalProbeMissing(s), "Calculating an intended formula was mistaken for running the existing code");
    add(s, "tool", "source file text", "run", `{"program":"python","args":["-c","print(open('invoice.py').read())"]}`);
    assert(numericalProbeMissing(s), "A Python file viewer supplied no observed function result");
    add(s, "tool", "44.1", "run", `{"program":"python","args":["-B","-c","from invoice import total; print(total(49,True))"]}`);
    assert(!numericalProbeMissing(s) && !continues(s));
    assert(s.verificationStatus == "not_required", "Numerical grounding created a verification/artifact ceremony");
    foreach (plain; ["Calculate 19 * 4.75 plus 8 * 3.20.", "Explain Python lists.",
            "Review invoice.py for bugs; do not edit files.",
            "Independently calculate invoice.py results without running code.",
            "Independently compute invoice.py values; do not execute code."])
        assert(!numericalCodeRequest(plain), plain);
    ChatSession unavailable; add(unavailable, "user", question);
    assert(!continues(unavailable, false));
    add(unavailable, "tool", "Traceback: ModuleNotFoundError: invoice", "run",
        `{"program":"python","args":["-B","-c","import invoice; print(invoice.total(49,True))"]}`);
    unavailable.messages[$ - 1].failed = true;
    assert(!numericalProbeMissing(unavailable), "An unavailable implementation forced an endless analysis retry");
    assert(answerContract(question, "").indexOf(numericalGroundingInstruction) >= 0);
    assert(answerContract(question, "", false).indexOf(numericalGroundingInstruction) < 0,
        "An execution-disabled review was instructed to invoke unavailable tools");
    writeln("PASS explicit numerical code questions need a relevant read-only execution; simple answers and explicit no-execution scope stay lightweight");
    return 0;
}

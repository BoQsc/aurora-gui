module check_revision_contracts;

import auroraopencode.core;
import auroraopencode.executioncontrol;
import std.conv : to;
import std.json : JSONValue;
import std.stdio : writeln;

void check(ref ChatSession s, string script, bool failed)
{
    JSONValue command; command["program"] = "python"; command["args"] = JSONValue(["-B", "-c", script]);
    JSONValue step; step["kind"] = "tests"; step["command"] = command;
    JSONValue arguments; arguments["inputs"] = JSONValue(["invoice.py"]); arguments["steps"] = JSONValue([step]);
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = "tool"; m.toolName = "verify"; m.toolCallId = m.id; m.failed = failed;
    m.toolArgs = arguments.toString(); m.content = failed ? `{"passed":false}` : `{"passed":true}`;
    m.verificationCheck = "verify:tests"; m.verificationScope = "source";
    s.messages ~= m; s.activeLeafId = m.id;
}

enum prefix = "from invoice import total\n";
enum body = "\nfor subtotal, coupon, expected in cases:\n    actual = total(subtotal, coupon)\n    assert abs(actual-expected)<1e-9\n";
enum oldScript = prefix ~ "cases = [(10,True,14),(60,True,59)]" ~ body;
enum corrected = prefix ~ "cases = [(0,False,5),(10,True,14),(60,True,54)]" ~ body;

int main()
{
    ChatSession s; check(s, oldScript, true);
    assert(executionState(s).remaining.length);
    check(s, corrected, false);
    assert(!executionState(s).remaining.length,
        "A corrected inline expectation still requires rerunning its impossible superseded value");
    writeln("PASS passing corrected expectations retain and rerun every original case");

    foreach (unrelated; [
        prefix ~ "cases = [(0,False,5)]" ~ body,
        prefix ~ "cases = [(10,True,14)]" ~ body,
        prefix ~ "cases = [(10,True,14),(60,True,54)]\nassert True\n",
        "print('ok')",
        prefix ~ "cases = [(10,True,14),(60,True,54)]\nfor subtotal, coupon, expected in cases:\n    actual=total(subtotal,coupon)\n    assert abs(actual-expected)<999\n"])
    {
        ChatSession rejected; check(rejected, oldScript, true); check(rejected, unrelated, false);
        assert(executionState(rejected).remaining.length, "An unrelated, reduced or weakened check concealed a failure");
    }
    ChatSession actualFailure; check(actualFailure, oldScript, true); check(actualFailure, corrected, true);
    assert(executionState(actualFailure).remaining.length, "A failing revised checker concealed a failure");
    writeln("PASS unrelated passes, dropped inputs, weakened assertions and failing revisions preserve obligations");
    return 0;
}

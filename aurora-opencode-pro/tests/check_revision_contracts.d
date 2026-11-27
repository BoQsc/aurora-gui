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
    enum oldBytes = "from pathlib import Path\nassert Path('catalog.json').read_bytes() == b'{\"ok\":true}'\nassert price(60) == 54\n";
    enum newBytes = "from pathlib import Path\nassert Path('catalog.json').read_bytes() == b'{\"ok\":true}\\r\\n'\nassert price(60) == 54\n";
    ChatSession bytes; check(bytes, oldBytes, true); check(bytes, newBytes, false);
    assert(!executionState(bytes).remaining.length, "A corrected literal assertion still requires its known-false old expectation");
    foreach (bad; ["from pathlib import Path\nassert Path('catalog.json').exists()\nassert price(60) == 54\n",
                  "from pathlib import Path\nassert price(60) == 54\n"])
    {
        ChatSession lost; check(lost, oldBytes, true); check(lost, bad, false);
        assert(executionState(lost).remaining.length, "A changed assertion subject or missing assertion was accepted");
    }
    writeln("PASS corrected equality literals retain assertion subjects, operators and all other checker logic");
    enum generatorBody = "; assert all(math.isclose(total(*a),e,rel_tol=0,abs_tol=1e-9) for a,e in checks)";
    enum tupleExpected = "import math; from invoice import total; checks=[((0,),(5,)),((100,True),(95,))]" ~ generatorBody;
    enum scalarExpected = "import math; from invoice import total; checks=[((0,),5),((100,True),90)]" ~ generatorBody;
    ChatSession generator; check(generator, tupleExpected, true); check(generator, scalarExpected, false);
    assert(!executionState(generator).remaining.length,
        "A corrected generator checker retaining nested argument tuples cannot resolve its wrong expected values");
    ChatSession missingInput; check(missingInput, tupleExpected, true);
    check(missingInput, "import math; from invoice import total; checks=[((0,),5)]" ~ generatorBody, false);
    assert(executionState(missingInput).remaining.length, "A generator revision dropped an original invocation");
    writeln("PASS generator checks retain nested argument tuples while correcting expected values");
    ChatSession userOwned;
    ChatMessage human; human.role = "user"; human.id = "supplied";
    human.content = "Preserve this supplied assertion: assert Path('catalog.json').read_bytes() == b'{\"ok\":true}'";
    userOwned.messages ~= human; userOwned.activeLeafId = human.id;
    check(userOwned, oldBytes, true); check(userOwned, newBytes, false);
    assert(executionState(userOwned).remaining.length, "An automatic revision altered an explicitly user-supplied assertion");
    return 0;
}

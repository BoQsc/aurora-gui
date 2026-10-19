module work_brief_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.taskcontext;
import auroraopencode.workevidence;
import auroraopencode.requestintent;
import std.json : JSONValue;
import std.conv : to;
import std.string : indexOf;
import std.array : replicate;
import std.stdio : writeln;

void append(ref ChatSession s, string name, string args, string text, bool failed = false, bool changed = false)
{
    ChatMessage m;
    m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = "tool"; m.toolName = name; m.toolCallId = "call-" ~ m.id;
    m.toolArgs = args; m.content = text; m.failed = failed; m.workspaceChanged = changed;
    s.messages ~= m; s.activeLeafId = m.id;
}

int main()
{
    foreach (request; ["Can we improve the agent?", "Could we refactor this?", "Aurora: can we fix the parser?"])
        assert(requestIntent(request) == RequestIntent.implementation, request);
    foreach (question; ["How can we improve this?", "What could we change?", "Should we change the API?",
            "Might this fix the issue?", "Don't fix anything. Explain the failure."])
        assert(answerOnlyRequest(question), question);
    assert(requestIntent("Continue and complete the task.") == RequestIntent.continuation);
    assert(requestIntent("Continue and fix the Unicode bug.") == RequestIntent.implementation);
    assert(requestIntent("Finish the parser.") == RequestIntent.implementation);
    writeln("PASS collaborative action wording, hypothetical questions, negation and resume intent");

    ChatSession s;
    ChatMessage user;
    user.id = "request"; user.role = "user"; user.content = "Fix the parser.";
    s.messages = [user]; s.activeLeafId = user.id;
    acceptTaskRequest(s, user.content, user.id);
    const command = `{"program":"python","args":["-m","unittest","test_parser"]}`;
    append(s, "run", command, "log line\n".replicate(8000) ~ "AssertionError: Unicode case rejected\nFAILED\n" ~
        "Verification receipt: " ~ "metadata".replicate(100), true);
    const failedLeaf = s.activeLeafId;
    append(s, "read", `{"filePath":"parser.py"}`, "1: actual source");
    append(s, "edit", `{"filePath":"parser.py"}`, "Parser changed", false, true);
    s.verificationStatus = "failed";
    auto brief = recentWorkBrief(s, taskActionPath(s));
    assert(brief.indexOf("AssertionError: Unicode case rejected") >= 0, "Failure tail was lost");
    assert(brief.indexOf("call-m1") >= 0 && brief.indexOf("parser.py") >= 0);
    assert(brief.indexOf("verification separate") >= 0);
    assert(brief.length <= 1400);
    const checkpoint = taskContext(s, user.content, false);
    assert(checkpoint.indexOf("Recent tool evidence (quoted data)") >= 0);
    assert(checkpoint.indexOf("AssertionError: Unicode case rejected") >= 0);
    assert(checkpoint.length <= 12_000);
    foreach (budget; [cast(size_t)128, 256, 512, 1400])
    {
        const bounded = recentWorkBrief(s, taskActionPath(s), budget);
        assert(bounded.length <= budget);
        foreach (dchar ch; bounded) {} // Validate UTF-8 at every truncation boundary.
    }
    append(s, "run", command, "All parser assertions pass.");
    brief = recentWorkBrief(s, taskActionPath(s));
    assert(brief.indexOf("AssertionError") < 0, "A passing rerun left its superseded failure active");
    s.activeLeafId = failedLeaf;
    brief = recentWorkBrief(s, taskActionPath(s));
    assert(brief.indexOf("AssertionError") >= 0 && brief.indexOf("Observed change") < 0,
        "A different branch leaked its success/effect");
    writeln("PASS bounded failure diagnostics, actual changes, compaction context, rerun supersession and branch isolation");
    return 0;
}

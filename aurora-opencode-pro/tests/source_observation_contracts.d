module source_observation_contracts;

import auroraopencode.core;
import auroraopencode.sourceobservations;
import auroraopencode.requestpolicy;
import auroraopencode.planprogress;
import auroraopencode.numericalgrounding;
import auroraopencode.tools : nativeOnlyToolDefinitions;
import std.conv : to;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.stdio : writeln;

void add(ref ChatSession s, string role, string text, string tool = "", string args = "", bool changed = false, bool failed = false)
{
    ChatMessage m; m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = text; m.toolName = tool; m.toolArgs = args;
    m.toolCallId = "call-" ~ m.id; m.workspaceChanged = changed; m.failed = failed;
    s.messages ~= m; s.activeLeafId = m.id;
}

int main()
{
    ChatSession s; s.contract.workspace = absolutePath("source-memory-fixture");
    s.verificationStatus = "required";
    add(s, "user", "Implement the requested package and verify it.");
    add(s, "tool", "1: Customer rate is 0.0175, not the archived rate.\n", "read", `{"filePath":"rules.txt"}`);
    const branch = s.activeLeafId;
    add(s, "tool", "1: {\"units\":123,\"estimated\":false}\n", "read", `{"filePath":"input.json","offset":1,"limit":4}`);
    add(s, "tool", "Wrote client.py", "write", `{"filePath":"client.py","content":"implementation"}`, true);
    s.compactedThroughMessageId = s.activeLeafId;
    auto context = retainedSourceContext(s, 6000);
    assert(context.indexOf("0.0175") >= 0 && context.indexOf("123") >= 0 && context.indexOf("call-m1") >= 0,
        "An unrelated edit erased the authoritative input observations");
    assert(context.indexOf(`"offset":1`) >= 0 && context.indexOf(`"limit":4`) >= 0);
    assert(s.verificationStatus == "required", "A retained observation fabricated verification");
    assert(retainedSourceContext(s, 40).length == 0);
    foreach (budget; 512 .. 1400) assert(retainedSourceContext(s, budget).length <= budget);
    RequestPolicy policy; policy.toolsEnabled = true; policy.compactionEnabled = true; policy.contextLimit = 32000;
    policy.availableTools = nativeOnlyToolDefinitions();
    s.compactionSummary = "Earlier context.";
    const wire = prepareAgentRequest(s, policy);
    bool retained;
    foreach (m; wire.messages) if (m.content.indexOf("# Retained source observations") >= 0) retained = true;
    policy.compactionEnabled = false;
    const withoutMemory = prepareAgentRequest(s, policy);
    assert(retained && wire.tools == withoutMemory.tools,
        "Retaining source data changed ordinary capabilities or lost the observations");

    JSONValue edit; edit["filePath"] = buildPath(s.contract.workspace, "rules.txt");
    add(s, "tool", "Edited", "edit", edit.toString(), true);
    s.compactedThroughMessageId = s.activeLeafId;
    context = retainedSourceContext(s, 6000);
    assert(context.indexOf("0.0175") < 0 && context.indexOf("123") >= 0, "A changed resource retained its old observation");
    add(s, "tool", "Error: unavailable", "read", `{"filePath":"input.json"}`, false, true);
    assert(!retainedSourceContext(s, 6000).length, "A failed refresh retained an earlier accessible-file claim");
    s.activeLeafId = branch; s.compactedThroughMessageId = branch;
    assert(retainedSourceContext(s, 6000).indexOf("0.0175") >= 0, "A sibling branch invalidated this branch's observation");
    add(s, "tool", "Command changed workspace", "run", `{"program":"generator","args":[]}`, true);
    assert(!retainedSourceContext(s, 6000).length, "Unknown command effects retained possibly stale source context");
    s.activeLeafId = branch; s.compactedThroughMessageId = branch;
    add(s, "tool", "Partial patch failure", "apply_patch", "{}", false, true);
    assert(!retainedSourceContext(s, 6000).length, "A partial unscoped mutation retained possibly stale context");
    s.activeLeafId = branch; s.compactedThroughMessageId = branch;
    add(s, "user", "A different task with new inputs.");
    assert(!retainedSourceContext(s, 6000).length, "A new real user request inherited old source snapshots");

    ChatSession numeric;
    add(numeric, "user", "Read invoice.py without changing files. Independently calculate its current result.");
    add(numeric, "tool", "Source", "read", `{"filePath":"invoice.py"}`);
    add(numeric, "tool", "44.1", "calculate", `{"expression":"49*.9"}`);
    add(numeric, "tool", "Listed", "dshell", `{"command":"list"}`);
    assert(!planProgressGuidance(numeric).length, "A short numerical answer acquired planning upkeep");
    assert(numericalProbeMissing(numeric), "Efficiency guidance bypassed actual numerical grounding");
    add(numeric, "tool", "44.1", "run", `{"program":"python","args":["-B","-c","import invoice; print(invoice.total(49,True))"]}`);
    assert(!numericalProbeMissing(numeric) && !planProgressGuidance(numeric).length);
    assert(numericalProbeContext(numeric).indexOf("44.1") >= 0);
    const handoff = prepareAgentRequest(numeric, policy);
    bool observation;
    foreach (m; handoff.messages) if (m.content.indexOf("# Numerical observation handoff") >= 0) observation = true;
    assert(observation && handoff.tools == withoutMemory.tools, "Numerical evidence handoff removed capabilities");
    add(numeric, "tool", "Concrete execution failure", "run", "{}", false, true);
    assert(!numericalProbeContext(numeric).length, "The handoff hid a later concrete failure");
    add(numeric, "user", "A new question.");
    assert(!numericalProbeContext(numeric).length, "A new request inherited the earlier numerical handoff");
    ChatSession written;
    written.contract.workspace = s.contract.workspace; written.verificationStatus = "required";
    add(written, "user", "Implement and verify the package.");
    JSONValue payload; payload["filePath"] = "package.py";
    payload["content"] = "from collections import deque\ndef solve(edges, start, end):\n" ~
        "    # BODY_IS_NOT_A_VERIFICATION_RECEIPT\n" ~ "    return None\n";
    add(written, "tool", "Wrote package.py", "write", payload.toString(), true);
    written.compactedThroughMessageId = written.activeLeafId;
    const api = retainedSourceContext(written, 2500);
    assert(api.indexOf("requested_declarations_only") >= 0 && api.indexOf("def solve(edges, start, end)") >= 0);
    assert(api.indexOf("BODY_IS_NOT_A_VERIFICATION_RECEIPT") < 0 && written.verificationStatus == "required");
    add(written, "tool", "Partial failed rewrite", "write", payload.toString(), true, true);
    assert(!retainedSourceContext(written, 2500).length, "A failed rewrite retained its earlier declaration snapshot");
    add(written, "user", "Implement the package according to requirements.txt.");
    add(written, "tool", "1: def unrelated(): pass\n", "read", `{"filePath":"other.py"}`);
    add(written, "tool", "1: The requested acceptance rule remains authoritative.\n", "read", `{"filePath":"requirements.txt"}`);
    written.compactedThroughMessageId = written.activeLeafId;
    const ordered = retainedSourceContext(written, 2500);
    assert(ordered.indexOf(`"file":"requirements.txt"`) < ordered.indexOf(`"file":"other.py"`),
        "An unrelated file displaced the user-named acceptance source");
    writeln("PASS bounded exact source context; per-resource/unknown-effect invalidation; branch and request isolation; unchanged grounding, verification and tool access");
    return 0;
}

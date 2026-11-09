module compaction_working_set_contracts;
import auroraopencode.core;
import auroraopencode.contextpolicy;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.requestpolicy;
import auroraopencode.tools : nativeOnlyToolDefinitions;
import auroraopencode.controlhistory;
import auroraopencode.requestbuilder : projectRequestMessages;
import std.json : JSONValue, JSONType, parseJSON;
import std.array : replicate;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

void add(ref ChatSession s, ChatMessage m)
{
    m.parentId = s.activeLeafId; s.activeLeafId = m.id; s.messages ~= m;
}
int main()
{
    size_t fullBytes, compactBytes;
    JSONValue semanticSchema(JSONValue value)
    {
        if (value.type==JSONType.object)
        {
            auto object=value.object; object.remove("description");
            foreach (key,ref child;object) child=semanticSchema(child);
            return JSONValue(object);
        }
        if (value.type==JSONType.array)
        {
            auto items=value.array;
            foreach(ref child;items) child=semanticSchema(child);
            return JSONValue(items);
        }
        return value;
    }
    foreach(tool;nativeOnlyToolDefinitions())
    {
        const small=compactContextTool(tool,32000);
        const large=compactContextTool(tool,64000);
        fullBytes+=requestToolDefinitionBytes([tool]);compactBytes+=requestToolDefinitionBytes([small]);
        assert(large.parametersJson==tool.parametersJson && large.description==tool.description);
        assert(semanticSchema(parseJSON(small.parametersJson))==semanticSchema(parseJSON(tool.parametersJson)),
            "Small-context schema altered fields, required properties, enums or types");
    }
    assert(fullBytes>compactBytes+5000,"Small-context tool prose still crowds out the working set");
    writeln("SCHEMA full=",fullBytes," small=",compactBytes," saved=",fullBytes-compactBytes);
    ChatSession controls;
    ChatMessage control;control.id="human";control.role="user";control.content="Keep the original rule.";add(controls,control);
    foreach(i;0..3)
    {
        control.id="state"~to!string(i);control.internal=true;
        control.content=durableTaskCheckpointPrefix~" obsolete state ".replicate(200);add(controls,control);
    }
    control.id="wrapper";control.role="assistant";control.internal=false;control.content="";
    control.toolCalls=[OpenCodeToolCall("live","read",`{"filePath":"source.txt"}`)];add(controls,control);
    control.id="result";control.role="tool";control.toolCalls=null;control.toolName="read";
    control.toolCallId="live";control.content="Exact latest file contents";add(controls,control);
    assert(!controlHistoryCompactionNeeded(controls) && controlHistoryCompactionNeeded(controls,true));
    control.id="boundary";control.role="user";control.internal=true;control.toolName="";control.toolCallId="";control.content=controlHistoryBoundary;add(controls,control);
    control.id="current";control.content=durableTaskCheckpointPrefix~" Current state";add(controls,control);
    const wire=projectRequestMessages(controls);
    assert(wire.length==4 && wire[0].content=="Keep the original rule.");
    assert(wire[1].toolCalls[0].id=="live" && wire[2].toolCallId=="live" && wire[2].content=="Exact latest file contents");
    assert(wire[3].content=="Internal agent-control instruction:\n"~control.content && controls.messages.length==8,"Retiring internal state changed saved history or current evidence");
    control.id="new-human";control.internal=false;control.content="Fix fullscreen instead.";add(controls,control);
    const nextTurn=projectRequestMessages(controls);
    assert(nextTurn.length==4 && nextTurn[$-1].content==control.content,
        "An earlier task checkpoint was promoted into a system instruction on a new request");
    ChatSession s; s.id = "working-set";
    ChatMessage user; user.id = "request"; user.role = "user";
    user.content = "Implement the package without losing the original goal."; add(s,user);
    user.id="rate-decision"; user.content="The customer rate is 0.0175 per unit."; add(s,user);
    ChatMessage ack; ack.id="ack"; ack.role="assistant"; ack.content="Recorded."; add(s,ack);
    user.id="cap-decision"; user.content="The refund credit cap is 0.04; finish the original task."; add(s,user);
    foreach (i; 0 .. 18)
    {
        ChatMessage a; a.id="a"~to!string(i); a.role="assistant";
        a.toolCalls=[OpenCodeToolCall("c"~to!string(i),"read",`{"filePath":"old.txt"}`)]; add(s,a);
        ChatMessage t; t.id="t"~to!string(i); t.role="tool"; t.toolName="read";
        t.toolCallId="c"~to!string(i); t.content="older exact data ".replicate(200); add(s,t);
    }
    ChatMessage a; a.id="current-read"; a.role="assistant";
    foreach (i; 0 .. 3) a.toolCalls ~= OpenCodeToolCall("live"~to!string(i),"read",`{"filePath":"source.txt"}`);
    add(s,a);
    foreach (i; 0 .. 3)
    {
        ChatMessage t; t.id="live-result"~to!string(i); t.role="tool"; t.toolName="read";
        t.toolCallId="live"~to!string(i); t.content=("source-file-"~to!string(i)~"\n").replicate(110); add(s,t);
    }
    bool created,fallback;
    const fixed=69_200; // Current batch exceeds the target tail but fits history capacity.
    const request=prepareCompactedRequest(s,32000,fixed,created,fallback);
    assert(created,"Fixture did not compact");
    assert(requestMessageBytes(request)+fixed<=compactionBudgetBytes(32000),"Checkpoint consumes the entire available history budget");
    foreach (i; 0 .. 3)
    {
        bool exact;
        foreach (m; request) if (m.toolCallId=="live"~to!string(i))
            exact=m.content==("source-file-"~to!string(i)~"\n").replicate(110);
        assert(exact,"Compaction discarded a file from the current tool batch");
    }
    assert(s.messages.length==44,"Compaction changed saved history");
    bool retainedRate;
    foreach (m;request) if (m.content.indexOf("0.0175")>=0) retainedRate=true;
    assert(retainedRate,"Compaction dropped an earlier customer decision");
    const saved=s.compactionSummary;
    assert(!applyModelCompactionSummary(s,s.compactedThroughMessageId,s.activeLeafId,
        "Faithful but oversized refinement. ".replicate(220),32000,false,saved.length),
        "Optional model refinement exceeded the reserved checkpoint capacity");
    assert(s.compactionSummary==saved);
    assert(applyModelCompactionSummary(s,s.compactedThroughMessageId,s.activeLeafId,
        "Goal: finish the original implementation. Evidence: earlier observations remain saved. Next: act on the current source and run checks.",
        32000,false,compactionSummaryCapacity(32000,fixed)));
    assert(s.compactionSummary.indexOf("0.0175")>=0,"Model refinement erased the authoritative customer decision");
    ChatSession rolling; rolling.id = "long-work";
    user.id = "long-request"; user.content = "Keep rate 0.0175 and finish the requested source change.";
    add(rolling, user);
    rolling.contract.id = "long-task"; rolling.contract.startMessageId = user.id;
    foreach (i; 0 .. 30)
    {
        ChatMessage call; call.id = "long-call" ~ to!string(i); call.role = "assistant";
        call.toolCalls = [OpenCodeToolCall(call.id, "read", `{"filePath":"source.txt"}`)]; add(rolling, call);
        ChatMessage output; output.id = "long-output" ~ to!string(i); output.role = "tool";
        output.toolName = "read"; output.toolCallId = call.id; output.toolArgs = call.toolCalls[0].arguments;
        output.content = ("unique source window " ~ to!string(i) ~ "\n").replicate(1000); add(rolling, output);
    }
    RequestPolicy rollingPolicy; rollingPolicy.toolsEnabled = true; rollingPolicy.compactionEnabled = true;
    rollingPolicy.contextLimit = 500_000;
    const originalLast = rolling.messages[$ - 1].content;
    auto rolled = prepareAgentRequest(rolling, rollingPolicy);
    assert(!rolled.checkpointCreated && rolling.messages.length == 61, "Tool activity overrode the selected context target or destroyed saved history");
    assert(rolled.messages[$ - 1].content == originalLast, "Rolling checkpoint lost the current native tool result");
    rollingPolicy.contextLimit = 32_000;
    assert(prepareAgentRequest(rolling, rollingPolicy).checkpointCreated, "Selected smaller context target was not honored");
    ChatSession pasted;
    user.id="large-user";user.content="Keep rate 0.0175 and original reference.\n"~"Read-only audit row. ".replicate(10000)~"\nFinish with CSV and JSON.";
    const fullPaste=user.content;add(pasted,user);
    bool pastedCheckpoint,pastedFallback;
    const pastedWire=prepareCompactedRequest(pasted,32000,35_000,pastedCheckpoint,pastedFallback);
    assert(requestMessageBytes(pastedWire)+35_000<=compactionBudgetBytes(32000),"One large user paste bypassed the configured context budget");
    assert(pasted.messages[0].content==fullPaste,"Bounding the request erased original user instructions");
    assert(pastedWire[$-1].content.indexOf("0.0175")>=0 && pastedWire[$-1].content.indexOf("CSV and JSON")>=0);
    writeln("PASS constrained windows retain the complete current tool batch within the actual remaining budget");
    return 0;
}

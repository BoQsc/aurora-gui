module compaction_working_set_contracts;
import auroraopencode.core;
import auroraopencode.contextpolicy;
import auroraopencode.contextcheckpoint : requestMessageBytes;
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
    const fixed=50_000; // Current batch exceeds the target tail but fits history capacity.
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
    writeln("PASS constrained windows retain the complete current tool batch within the actual remaining budget");
    return 0;
}

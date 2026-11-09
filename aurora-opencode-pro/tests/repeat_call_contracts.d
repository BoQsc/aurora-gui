module repeat_call_contracts;
import auroraopencode.core;
import auroraopencode.taskflow : stalledExecutionTools;
import auroraopencode.workevidence : observedSourceKeys;
import std.conv : to;
import std.stdio : writeln;
void main()
{
    ChatSession searches;
    foreach (i; 0 .. 20)
    {
        ChatMessage q; q.id="q" ~ to!string(i); q.parentId=searches.activeLeafId; q.role="tool"; q.toolName="grep";
        q.toolArgs=`{"pattern":"varied query"}`;
        q.content="Search complete · " ~ to!string(i) ~ "s\nFind: query" ~ to!string(i) ~ "\nFile: /source.d\n1: same source fact";
        searches.messages ~= q; searches.activeLeafId=q.id;
    }
    assert(stalledExecutionTools(searches)>=16,"Changed search headings hid repeated source-line observations");
    auto changed=searches.messages[$ - 1]; changed.content="File: /source.d\n1: actually changed source";
    searches.messages[$ - 1]=changed;
    assert(stalledExecutionTools(searches)==0,"Changed bytes failed to count as a new finding");
    ChatMessage window; window.role="tool"; window.toolName="read"; window.toolArgs=`{"filePath":"/source.d"}`;
    window.content="1: actually changed source\n2: new source line";
    assert(observedSourceKeys(window)[0]==observedSourceKeys(changed)[0],"Overlapping native reads and searches compared query metadata instead of source facts");
    changed.failed=true; assert(observedSourceKeys(changed).length==0);
    writeln("PASS actual source facts detect repeated research across query variations and preserve changed-source freshness");
}

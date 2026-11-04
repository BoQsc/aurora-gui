module goal_planning_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : tempDir, mkdirRecurse, exists, readText;
import std.path : buildPath;
import std.json : JSONValue;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    const directory=buildPath(tempDir(),"goal-planning-"~to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(directory);
    Settings settings; settings.workspace=directory; settings.apiKey=""; settings.quickTitle=false; saveSettings(settings);
    WindowOptions options; options.renderer=RendererPreference.software;
    auto window=new GuiWindow(options,opencodeTheme()); auto root=new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    void pump() { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    const ready=MonoTime.currTime+5.seconds;
    while(root.startupPendingForTesting() && MonoTime.currTime<ready) pump();
    void fresh(string goal)
    {
        root.newChatForTesting(); root.pauseToolContinuationForTesting();
        root.addConversationForTesting(["user","assistant"],[goal,""]);
        root.setGoalForTesting(goal,"active");
    }
    void run(OpenCodeToolCall[] calls)
    {
        root.addConversationForTesting(["assistant"],[""]);
        const target=root.toolMessageCountForTesting()+cast(int)calls.length;
        root.injectToolCallsForTesting(calls);
        const deadline=MonoTime.currTime+5.seconds;
        while((root.toolMessageCountForTesting()<target || root.pendingToolResultsForTesting()>0) && MonoTime.currTime<deadline) pump();
        assert(root.toolMessageCountForTesting()==target);
    }
    OpenCodeToolCall writeCall(string id,string path)
    { return OpenCodeToolCall(id,"write",`{"filePath":`~JSONValue(path).toString~`,"content":"valid output"}`); }
    fresh("Write one small note.");
    const simple=buildPath(directory,"simple.txt"); run([writeCall("simple",simple)]);
    assert(exists(simple),"A small goal acquired a planning round");
    fresh("Implement and verify the two-module package.");
    const first=buildPath(directory,"first.txt"), second=buildPath(directory,"second.txt");
    run([writeCall("first",first),writeCall("second",second)]);
    assert(exists(first) && exists(second),"Normal goal work was deferred for custom planning bookkeeping");
    assert(readText(first)=="valid output");
    writeln("PASS small and multi-file goal mutations execute without synthetic planning preflights");
    return 0;
}

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
    assert(exists(simple),"A single small mutation was blocked for planning");
    root.setStrictPlanEnabledForTesting(true);
    scope(exit) root.setStrictPlanEnabledForTesting(false);
    fresh("Implement and verify the two-module package.");
    const first=buildPath(directory,"first.txt"), second=buildPath(directory,"second.txt");
    run([writeCall("first",first),writeCall("second",second)]);
    assert(!exists(first) && !exists(second),
        "A multi-file goal change ran before its plan was recorded");
    run([OpenCodeToolCall("plan","update_plan",
        `{"explanation":"Plan before the multi-file change.","plan":[`~
        `{"step":"Write both outputs","status":"in_progress"},`~
        `{"step":"Verify both outputs","status":"pending"}]}`)]);
    run([writeCall("first-retry",first),writeCall("second-retry",second)]);
    assert(exists(first) && exists(second),"Planned goal work was deferred again");
    assert(readText(first)=="valid output");
    writeln("PASS multi-file goal work records the plan first, then executes; a single small mutation stays direct");
    return 0;
}

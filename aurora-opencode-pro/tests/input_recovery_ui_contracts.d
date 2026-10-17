module input_recovery_ui_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import core.time : MonoTime, seconds, msecs;
import core.thread : Thread;
import std.file : tempDir, mkdirRecurse, readText;
import std.path : buildPath;
import std.conv : to;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const base=environment.get("AURORA_CONTRACT_PROVIDER_BASE",""); assert(base.length);
    const directory=buildPath(tempDir(),"aurora-input-recovery-"~to!string(MonoTime.currTime.ticks));
    const workspace=buildPath(directory,"workspace"); mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings; settings.baseUrl=base; settings.apiKey="fixture"; settings.model="recovery-fixture";
    settings.workspace=workspace; settings.toolsEnabled=true; settings.quickTitle=false; settings.legacyTools=false;
    saveSettings(settings);
    WindowOptions options; options.renderer=RendererPreference.software;
    auto window=new GuiWindow(options,opencodeTheme()); auto root=new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient(); auto driver=new UiTestDriver(window);
    void pump(){window.onNativeTick(0.02);root.projectTranscriptForTesting();assert(driver.paint());Thread.sleep(5.msecs);}
    void until(bool delegate() condition)
    {
        const deadline=MonoTime.currTime+20.seconds;
        while(!condition()&&MonoTime.currTime<deadline)pump();
        assert(condition(),root.lastAssistantErrorForTesting()~" "~root.lastAssistantContentForTesting());
    }
    until(delegate(){return !root.startupPendingForTesting();});
    root.newChatForTesting();
    root.addConversationForTesting(["user","assistant"],["Resume the paused fixture.","Delivered this turn; waiting for permission to close a window."]);
    root.setTaskStateForTesting("Write the recovered document","active","not_required");
    root.applyPlanForTesting(`{"plan":[{"id":"resume","step":"Write recovered document","kind":"edit","status":"in_progress"}]}`);
    root.setTaskStateForTesting("Write the recovered document","waiting_input","not_required");
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(),"completed");
    root.prepareResumeForTesting();
    assert(root.taskStatusForTesting()=="active","A stale waiting_input flag was trusted without an essential input request");
    until(delegate(){return root.lastAssistantContentForTesting()=="Recovered document completed."&&!root.turnBusyForTesting();});
    assert(root.taskStatusForTesting()=="completed"&&readText(buildPath(workspace,"resumed.md"))=="Recovered");
    writeln("PASS the visible saved false pause resumes without another user message");

    root.newChatForTesting(); root.setInputForTesting("Resolve the technical input fixture."); root.sendForTesting();
    until(delegate(){return root.lastAssistantContentForTesting()=="Technical obstacle recovered."&&!root.turnBusyForTesting();});
    assert(root.taskStatusForTesting()=="completed"&&readText(buildPath(workspace,"resolved.md"))=="Resolved");
    writeln("PASS a permission request embedded inside a long question is rejected and execution continues");

    root.newChatForTesting(); root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user"],["Deploy the prepared fixture."]);
    root.setTaskStateForTesting("Deploy prepared fixture","active","not_required");
    root.applyPlanForTesting(`{"plan":[{"id":"deploy","step":"Deploy prepared fixture","status":"in_progress"}]}`);
    root.addConversationForTesting(["assistant"],[""]);
    root.injectToolCallsForTesting([OpenCodeToolCall("required-fact","request_input",`{"reason":"No deployment destination in local configuration","required_fact":"Deployment destination","question":"Which deployment server should I use?","checked":["Local deployment configuration"],"independent_work_complete":true}`)]);
    until(delegate(){return root.pendingToolResultsForTesting()==0&&root.toolMessageCountForTesting()==1;});
    assert(root.taskStatusForTesting()=="waiting_input",root.lastToolResultForTesting());
    root.persistForTesting();root.reloadSessionsForTesting();root.prepareResumeForTesting();
    foreach(_;0..20)pump();
    assert(root.taskStatusForTesting()=="waiting_input"&&!root.turnBusyForTesting());
    root.newChatForTesting(); root.addConversationForTesting(["user"],["Resume the paused fixture."]);
    root.setTaskStateForTesting("Write the stopped document","waiting_input","not_required");
    root.setSessionTurnStatusForTesting(root.currentSessionForTesting(),"interrupted");
    root.prepareResumeForTesting(); foreach(_;0..20)pump();
    assert(root.turnStatusForTesting()=="interrupted"&&!root.turnBusyForTesting());
    writeln("PASS essential missing facts and explicit Stop remain respected across restore");
    root.clearPendingResumeForTesting();window.close();return 0;
}

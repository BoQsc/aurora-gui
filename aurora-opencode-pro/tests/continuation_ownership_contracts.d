module continuation_ownership_contracts;
import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core;
import auroraopencode.computeruse : setComputerUseSetting;
import core.thread : Thread;
import core.time : MonoTime,seconds,msecs;
import std.file : mkdirRecurse,tempDir;
import std.path : buildPath;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    const state=buildPath(tempDir(),"continuation-owner-"~to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);setOpencodeStateDirectoryForTesting(state);
    Settings settings;settings.baseUrl="http://127.0.0.1:9";settings.apiKey="";
    settings.quickTitle=false;settings.workspace=state;settings.autoGoalFromFirstMessage=false;saveSettings(settings);
    WindowOptions options;options.renderer=RendererPreference.software;
    auto window=new GuiWindow(options,opencodeTheme());auto root=new OpenCodeRoot(window);window.setRoot(root);
    scope(exit) { setComputerUseSetting(false);root.shutdownClient(); }
    const ready=MonoTime.currTime+5.seconds;
    while(root.startupPendingForTesting()&&MonoTime.currTime<ready) {window.onNativeTick(0.02);Thread.sleep(5.msecs);}
    setComputerUseSetting(true);
    root.newChatForTesting();
    root.addConversationForTesting(["user","assistant"],["The tools belong on separate inventory pages.","The requested layout is still pending."]);
    root.setTaskStateForTesting("Ensure 1 on 1 exactness to mockup","active","required");
    root.setTaskIntentForTesting("conversation","conversation");
    root.setGoalForTesting("Ensure 1 on 1 exactness to mockup","paused");
    const count=root.totalMessageCountForTesting();
    root.startTurnClockForTesting();root.settleTaskAfterDoneForTesting();
    assert(root.totalMessageCountForTesting()==count,"A second controller appended an automatic continuation after settlement");
    assert(!root.turnBusyForTesting(),"A settled turn retained a clock or flight flag");
    const deadline=MonoTime.currTime+6.seconds;
    while(MonoTime.currTime<deadline) {window.onNativeTick(0.02);Thread.sleep(5.msecs);}
    assert(root.totalMessageCountForTesting()==count && !root.turnBusyForTesting(),"Watchdog or deferred retry resurrected the settled turn");
    root.newChatForTesting();
    root.addConversationForTesting(["user","assistant"],["Return one JSON object.",""]);
    root.beginStreamForTesting();root.streamContentForTesting("The answer follows.\n{\"ok\":true}");root.finishStreamForTesting();
    assert(root.lastAssistantContentForTesting()==`{"ok":true}`);
    root.persistForTesting();root.reloadSessionsForTesting();
    assert(root.lastAssistantContentForTesting()==`{"ok":true}`,"Normalized JSON changed after reload");
    writeln("PASS one continuation owner with computer use enabled; paused legacy goal, settlement/watchdog, exact JSON and reload");
    return 0;
}

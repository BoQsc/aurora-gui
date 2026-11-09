module flow_task_probe;
import aurora;
import aurora.widgets.contextmenu : ContextMenu;
import aurora.widgets.popup : currentTransientPopup;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : ChatSession, ChatMessage;
version(EmptySendProbe) import auroraopencode.conversationactor;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.file : mkdirRecurse, write;
import std.path : absolutePath;
import std.stdio : writeln;
import std.utf : toUTF8;

Widget find(Widget w, string id)
{
    if (w.id() == id) return w;
    foreach(c; w.children()) { auto found=find(c,id); if(found !is null)return found; }
    return null;
}
Button label(Widget w, string text)
{
    if(!w.visible())return null;
    if(auto b=cast(Button)w) if(toUTF8(b.text())==text && b.bounds().width>0)return b;
    foreach(c;w.children()) {auto found=label(c,text);if(found !is null)return found;}
    return null;
}
Point center(Widget w)
{
    auto p=w.localToGlobal(Point(0,0));return Point(p.x+w.bounds().width/2,p.y+w.bounds().height/2);
}
int main(string[] args)
{
    assert(args.length==4);
    const state=absolutePath(args[2]);mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    write(state ~ "/settings.json",`{"apiKey":"fixture","baseUrl":"http://127.0.0.1:1/v1","toolsEnabled":false,"quickTitle":false}`);
    WindowOptions options;options.width=1000;options.height=700;options.renderer=RendererPreference.software;
    auto window=new GuiWindow(options,opencodeTheme());auto root=new OpenCodeRoot(window);window.setRoot(root);
    scope(exit)root.shutdownClient();
    foreach(_;0..150){window.onNativeTick(0.02);Thread.sleep(2.msecs);}
    root.newChatForTesting();auto driver=new UiTestDriver(window);
    void paint(){root.tickTree(0.02);assert(driver.paint());}
    paint();paint();
    version(EmptySendProbe)
    {
        auto send=cast(Button)find(root,"oc-send");assert(send !is null);
        auto count=root.messageCountForTesting();driver.click(center(send));paint();
        assert(root.messageCountForTesting()==count && !root.turnBusyForTesting(),"Empty Send started work");
        // Calling the registered action directly also must not dispatch.
        if(send.onClick !is null)send.onClick();paint();
        assert(root.messageCountForTesting()==count && !root.turnBusyForTesting(),"Empty Send handler dispatched");
        root.setInputForTesting("a real message");paint();assert(send.enabled(),"Typing did not enable Send");
        root.setInputForTesting(" \r\n ");paint();
        driver.click(center(send));paint();assert(root.messageCountForTesting()==count,"Whitespace Send dispatched");
        root.startTurnClockForTesting();root.setInputForTesting("");paint();
        assert(send.enabled() && toUTF8(send.text())=="Stop","Busy Stop became disabled");
        driver.click(center(send));paint();assert(!root.turnBusyForTesting(),"Stop no longer stops");
        writeln("PASS empty/whitespace Send inert; typing enabled; busy Stop and event dispatch preserved");
        ChatSession initial;initial.id="independent-empty";initial.model="fixture";
        ChatMessage u;u.id="user";u.role="user";u.content="Completed earlier task";
        ChatMessage answer;answer.id="answer";answer.role="assistant";answer.parentId="user";answer.content="Done";
        initial.messages=[u,answer];initial.activeLeafId="answer";initial.turnStatus="completed";initial.taskStatus="completed";
        ActorConfiguration config;config.baseUrl=args[3];config.apiKey="fixture";config.workspace=state;config.outageBudgetMs=0;
        auto actor=new ConversationActor(initial,config,null);
        actor.post(ActorCommand(ActorCommandKind.start,""));
        Thread.sleep(1000.msecs);actor.close();auto settled=actor.takeFinalSession();
        assert(settled.messages.length==2 && settled.turnStatus=="completed","Idle empty start dispatched a continuation");
        auto resume=new ConversationActor(initial,config,null);
        ActorCommand continuation;continuation.kind=ActorCommandKind.continueAnswer;continuation.targetId="answer";
        resume.post(continuation);
        auto deadline=MonoTime.currTime+5.seconds;
        bool completed;
        while(MonoTime.currTime<deadline)
        {
            auto changes=resume.takeChanges();
            if(!resume.activity().busy && changes.length){completed=true;break;}
            Thread.sleep(10.msecs);
        }
        resume.close();auto continued=resume.takeFinalSession();
        assert(continued.messages.length>2 && continued.messages[$-1].content=="CONTINUED","Explicit Continue did not execute");
        writeln("PASS idle empty actor submission inert; explicit Continue reaches provider and completes");

    }
    else
    {
        auto checkpoint=find(root,"oc-checkpoint");assert(checkpoint !is null && checkpoint.visible());
        assert(label(root,"Export") is null,"Export still takes toolbar space");
        driver.moveTo(center(checkpoint));foreach(_;0..30){root.tickTree(0.02);Thread.sleep(2.msecs);}paint();
        auto action=label(root,"Export");
        auto menu=cast(ContextMenu)currentTransientPopup(root);
        if(menu !is null)
        {
            bool found;foreach(item;menu.items()) if(toUTF8(item.label)=="Export") found=item.enabled && item.action !is null;
            assert(found,"Hover menu has no enabled Export action");
            driver.click(Point(4,690));paint();assert(currentTransientPopup(root) is null,"Hover menu did not dismiss");
            writeln("PASS toolbar space freed; Checkpoint hover reveals an enabled Export menu action; outside click dismisses");return 0;
        }
        assert(action !is null,"Hovering Checkpoint did not reveal Export");
        auto cp=checkpoint.localToGlobal(Point(0,0));auto ep=action.localToGlobal(Point(0,0));
        assert(ep.y>=cp.y+checkpoint.bounds().height-2,"Export was not placed beneath Checkpoint");
        assert(action.onClick !is null && root.hitTest(center(action)) is action,"Export is not actionable");
        driver.moveTo(center(action));paint();assert(label(root,"Export") !is null,"Entering Export dismissed it");
        driver.moveTo(Point(4,690));paint();assert(label(root,"Export") is null,"Export did not dismiss on leave");
        writeln("PASS toolbar space freed; Checkpoint hover reveals actionable Export; hover continuity and dismissal");
    }
    return 0;
}

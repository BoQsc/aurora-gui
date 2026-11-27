module plan_progress_contracts;
import auroraopencode.core;
import auroraopencode.planprogress;
import auroraopencode.requestpolicy;
import auroraopencode.controlhistory : controlStateKind, ControlStateKind;
import auroraopencode.turnpolicy;
import auroraopencode.tools : nativeOnlyToolDefinitions;
import std.conv : to;
import std.string : indexOf, startsWith;
import std.stdio : writeln;
void main()
{
    ChatSession s;
    void add(string role, string text, string tool="", bool internal=false)
    {
        ChatMessage m;m.id="m"~to!string(s.messages.length);m.parentId=s.activeLeafId;
        m.role=role;m.content=text;m.toolName=tool;m.internal=internal;
        s.messages~=m;s.activeLeafId=m.id;
    }
    add("user","Implement the multi-step fix.");const first=s.activeLeafId;
    RequestPolicy policy;policy.toolsEnabled=true;policy.availableTools=nativeOnlyToolDefinitions();
    auto initial=prepareAgentRequest(s,policy);bool suggestion;
    foreach(m;initial.messages)if(m.content.indexOf(initialPlanSuggestion)>=0)suggestion=true;
    assert(suggestion,"First response lacks optional planning suggestion");
    foreach(_;0..2)add("tool","Source","read");assert(!planProgressGuidance(s).length);
    add("tool","Source","read");auto reminder=planProgressGuidance(s);
    assert(reminder.startsWith(planProgressMarker) && reminder.indexOf("consider")>=0);
    add("user",reminder,"",true);assert(controlStateKind(s.messages[$-1])==ControlStateKind.progress);
    assert(!planProgressGuidance(s).length);auto restored=s;assert(!planProgressGuidance(restored).length);
    auto wire=prepareAgentRequest(s,policy);bool visible;
    foreach(m;wire.messages)if(m.content.indexOf(planProgressMarker)>=0)visible=true;
    assert(visible,"New advisory was filtered out");
    assert(wire.tools.length==initial.tools.length && !planReconciliationDue(s),"Review became a tool gate");
    foreach(_;0..4)add("tool","Edited","edit");assert(!planProgressGuidance(s).length);
    add("tool","Edited","edit");assert(planProgressGuidance(s).length,"Ignoring reminder disabled subsequent reviews");
    add("user",planProgressGuidance(s),"",true);
    s.taskSteps=[TaskStep("Current outcome","in_progress")];add("tool","Plan","update_plan");
    assert(planProgress(s).results==0);add("tool","Checked","verify");
    assert(!planProgressGuidance(s).length,"Phase change forced immediate reconciliation");
    foreach(_;0..40)add("tool","Running","process");foreach(_;0..4)add("tool","Plan read","read_plan");
    assert(planProgress(s).results==1,"Polling advanced review cadence");
    foreach(_;0..4)add("tool","Source","grep");
    assert(planProgressGuidance(s).indexOf("plan still matches")>=0 && s.taskSteps[0].status=="in_progress");
    // A plan whose in-progress outcome no longer matches the work is reviewed
    // at the phase transition, before another tool-result window elapses.
    {
        ChatSession p;
        void push(string role,string text,string tool="",bool internal=false)
        {
            ChatMessage m;m.id="p"~to!string(p.messages.length);m.parentId=p.activeLeafId;
            m.role=role;m.content=text;m.toolName=tool;m.internal=internal;
            p.messages~=m;p.activeLeafId=m.id;
        }
        push("user","Implement the phased fix.");
        p.taskSteps=[TaskStep("Inspect the source","in_progress","inspect","research")];
        push("tool","Source","read");push("tool","Source","read");
        assert(!planProgressGuidance(p).length,"A short investigation reviewed a current plan too early");
        push("tool","Changed","edit");
        auto editing=planProgressGuidance(p);
        assert(editing.indexOf("Editing has started")>=0,"The first edit did not review a research-phase plan early");
        assert(planNeedsRefresh(p),"The visible checklist did not mark a phase mismatch stale");
        push("user",editing,"",true);
        assert(!planProgressGuidance(p).length,"A phase review repeated without another phase change");
        push("tool","Changed","edit");
        assert(!planProgressGuidance(p).length,"The phase review became a second window");
        push("tool","Checked","verify");
        auto checking=planProgressGuidance(p);
        assert(checking.indexOf("Verification has started")>=0,"Verification did not review an edit-phase plan early");
        push("user",checking,"",true);
        assert(!planProgressGuidance(p).length);
    }
    s.taskStatus="waiting_input";assert(!planProgressGuidance(s).length);
    s.taskStatus="completed";assert(!planProgressGuidance(s).length);
    s.taskStatus="active";s.verificationStatus="passed";s.taskSteps[0].status="completed";
    assert(!planProgressGuidance(s).length,"Finished work acquired review debt");
    s.activeLeafId=first;assert(planProgress(s).results==0);add("user","A new task.");
    assert(planProgress(s).results==0);auto next=prepareAgentRequest(s,policy);
    foreach(m;next.messages)assert(m.content.indexOf(planProgressMarker)<0);
    TurnPolicy turn;turn.toolsEnabled=true;s.taskSteps=null;
    add("assistant","The requested answer is complete.");
    assert(decideTurn(s,turn).action==TurnAction.settle,"Missing optional plan prevented completion");
    writeln("PASS optional initial planning; early unplanned suggestion; phase-timed and five-result reviews; reset/reload/branch safety; unchanged tools and no completion debt");
}

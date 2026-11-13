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
    foreach(_;0..4)add("tool","Source","read");assert(!planProgressGuidance(s).length);
    add("tool","Source","read");auto reminder=planProgressGuidance(s);
    assert(reminder.startsWith(planProgressMarker) && reminder.indexOf("consider")>=0);
    add("user",reminder,"",true);assert(controlStateKind(s.messages[$-1])==ControlStateKind.progress);
    assert(!planProgressGuidance(s).length);auto restored=s;assert(!planProgressGuidance(restored).length);
    auto wire=prepareAgentRequest(s,policy);bool visible;
    foreach(m;wire.messages)if(m.content.indexOf(planProgressMarker)>=0)visible=true;
    assert(visible,"New advisory was filtered out");
    assert(wire.tools.length==initial.tools.length && !planReconciliationDue(s),"Review became a tool gate");
    foreach(_;0..4)add("tool","Edited","edit");assert(!planProgressGuidance(s).length);
    add("tool","Source","read");assert(planProgressGuidance(s).length,"Ignoring reminder disabled subsequent reviews");
    add("user",planProgressGuidance(s),"",true);
    s.taskSteps=[TaskStep("Current outcome","in_progress")];add("tool","Plan","update_plan");
    assert(planProgress(s).results==0);add("tool","Checked","verify");
    assert(!planProgressGuidance(s).length,"Phase change forced immediate reconciliation");
    foreach(_;0..40)add("tool","Running","process");foreach(_;0..4)add("tool","Plan read","read_plan");
    assert(planProgress(s).results==1,"Polling advanced review cadence");
    foreach(_;0..4)add("tool","Source","grep");
    assert(planProgressGuidance(s).indexOf("plan still matches")>=0 && s.taskSteps[0].status=="in_progress");
    s.taskStatus="waiting_input";assert(!planProgressGuidance(s).length);
    s.taskStatus="completed";assert(!planProgressGuidance(s).length);
    s.taskStatus="active";s.verificationStatus="passed";s.taskSteps[0].status="completed";
    assert(!planProgressGuidance(s).length,"Finished work acquired review debt");
    s.activeLeafId=first;assert(planProgress(s).results==0);add("user","A new task.");
    assert(planProgress(s).results==0);auto next=prepareAgentRequest(s,policy);
    foreach(m;next.messages)assert(m.content.indexOf(planProgressMarker)<0);
    TurnPolicy turn;turn.toolsEnabled=true;s.taskSteps=null;
    assert(decideTurn(s,turn).action==TurnAction.settle,"Missing optional plan prevented completion");
    writeln("PASS optional initial planning; recurring five-result review; reset/reload/branch safety; unchanged tools and no completion debt");
}

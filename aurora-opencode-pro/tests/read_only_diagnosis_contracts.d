module read_only_diagnosis_contracts;
import auroraopencode.core;
import auroraopencode.tools;
import auroraopencode.toolscheduler : toolWorkspaceRevision;
import auroraopencode.toolsettlement;
import auroraopencode.opencode_client : OpenCodeEvent;
import auroraopencode.taskflow : acceptTaskRequest;
import auroraopencode.taskpolicy : verificationScope;
import auroraopencode.executioncontrol;
import auroraopencode.numericalclaims;
import core.time : MonoTime;
import std.conv : to;
import std.file : mkdirRecurse, write, readText;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession s, ChatMessage m)
{ m.parentId=s.activeLeafId; s.activeLeafId=m.id; s.messages~=m; }

int main()
{
    const root=absolutePath("read-only-diagnosis-" ~ to!string(MonoTime.currTime.ticks));
    const workspace=buildPath(root,"workspace"); mkdirRecurse(buildPath(workspace,".git"));
    setOpencodeStateDirectoryForTesting(buildPath(root,"state"));
    const implementation="def cost(hours, rate):\n    return hours * rate\n";
    const test="import unittest\nfrom cost import cost\nclass CostTests(unittest.TestCase):\n def test_cost(self): self.assertEqual(cost(3,4),13)\n";
    write(buildPath(workspace,"cost.py"),implementation);
    write(buildPath(workspace,"test_cost.py"),test);
    ChatSession s;
    ChatMessage user; user.id="human"; user.role="user";
    user.content="Diagnose test_cost.py using cost.py. Execute the failing unittest reproducer, independently calculate the required result, and identify which side is wrong. Do not edit files. Return only JSON keys actual, required, test_expected (numbers), repair.";
    append(s,user); acceptTaskRequest(s,user.content,user.id);
    s.contract.workspace=workspace; s.verificationScope=verificationScope(workspace,toolWorkspaceRevision(workspace));
    assert(s.contract.intent=="analysis" && s.verificationStatus=="not_required");
    foreach (name; ["test_cost.py","cost.py"])
    {
        JSONValue args; args["filePath"]=buildPath(workspace,name);
        auto result=executeTool(OpenCodeToolCall("read-"~name,"read",args.toString()),workspace);
        assert(!result.failed,result.output);
        ChatMessage read; read.id="read-"~name; read.role="tool"; read.toolName="read";
        read.toolArgs=args.toString(); read.content=result.output; append(s,read);
    }
    ToolSettlement recordRun(string id, string[] argv)
    {
        JSONValue args; args["program"]="python"; args["args"]=JSONValue(argv); args["workdir"]=workspace;
        auto result=executeTool(OpenCodeToolCall(id,"run",args.toString()),workspace);
        OpenCodeEvent event; event.toolName="run"; event.toolCallId=id; event.text=result.output;
        event.toolFailed=result.failed; event.verificationCheck=result.verification.check;
        event.verificationPassed=result.verification.passed; event.verificationExitCode=result.verification.exitCode;
        auto policy=ToolResultPolicy(false,workspace,workspace,"now",toolWorkspaceRevision(workspace));
        const previous=s.verificationStatus;
        auto settled=settleToolResult(s,event,args.toString(),policy);
        settled.message.id=id; append(s,settled.message);
        advanceToolTaskState(s,settled,event,args.toString(),previous,s.verificationScope);
        return settled;
    }
    auto failed=recordRun("reproducer",["-B","-m","unittest","test_cost","-v"]);
    assert(failed.message.failed && failed.currentFailure && !failed.acceptedVerification);
    assert(failed.message.content.indexOf("12 != 13")>=0);
    assert(s.verificationStatus=="not_required", "A requested negative observation became a requirement to repair a read-only task");
    auto calculated=recordRun("arithmetic",["-B","-c","from cost import cost; print('actual',cost(3,4)); print('required',3*4)"]);
    assert(!calculated.message.failed);
    ChatMessage answer; answer.id="answer"; answer.role="assistant";
    answer.content=`{"actual":12,"required":12,"test_expected":13,"repair":"test"}`; append(s,answer);
    assert(!unobservedNumericalClaim(s).length, "An observed assertion expectation required a fabricated calculation");
    auto state=executionState(s);
    assert(!state.numericalGroundingMissing && state.remaining.indexOf("Behavioral check")<0);
    assert(!executionShouldContinue(s,true,state), "A grounded read-only diagnosis could not settle");
    s.messages[$-1].content=`{"actual":12,"required":13,"test_expected":13}`;
    assert(unobservedNumericalClaim(s)=="13", "An assertion literal supplied proof of an uncomputed required value");
    s.messages[$-1].content=`{"actual":12,"required":12,"test_expected":4}`;
    assert(unobservedNumericalClaim(s)=="4", "An assertion input was mistaken for its expected argument");
    s.messages[$-1].content=`{"actual":12,"required":12,"test_expected":14}`;
    assert(unobservedNumericalClaim(s)=="14");
    // Source examples, comments and call inputs cannot masquerade as expected
    // arguments. A changed or failed refresh discards the observed source fact.
    auto evidence=s;
    auto readIndex=size_t.max;
    foreach (i, message; evidence.messages) if (message.id=="read-test_cost.py") readIndex=i;
    assert(readIndex!=size_t.max);
    foreach (source; ["1: # self.assertEqual(cost(3,4),14)\n",
            "1: example = 'self.assertEqual(cost(3,4),14)'\n",
            "1: \"\"\"example\n2: self.assertEqual(cost(3,4),14)\n3: \"\"\"\n",
            "1: self.assertEqual(cost(3,14),13)\n",
            "1: self.assertAlmostEqual(cost(3,4),13,14)\n"])
    {
        evidence.messages[readIndex].content=source;
        assert(unobservedNumericalClaim(evidence)=="14");
    }
    evidence=s; evidence.messages[readIndex].failed=true;
    evidence.messages[$-1].content=`{"actual":12,"required":12,"test_expected":13}`;
    assert(unobservedNumericalClaim(evidence)=="13");
    evidence=s; evidence.messages[readIndex+1].workspaceChanged=true;
    evidence.messages[$-1].content=`{"actual":12,"required":12,"test_expected":13}`;
    assert(unobservedNumericalClaim(evidence)=="13");
    auto repair=s; repair.contract.intent=repair.contract.currentIntent="implementation";
    repair.verificationStatus="passed";
    OpenCodeEvent event; event.toolName="run";
    advanceToolTaskState(repair,failed,event,failed.message.toolArgs,"passed",repair.verificationScope);
    assert(repair.verificationStatus=="required", "A failed implementation check was treated as an observation");
    auto mutated=s; mutated.verificationStatus="not_required"; event.workspaceChanged=true;
    advanceToolTaskState(mutated,failed,event,failed.message.toolArgs,"not_required",mutated.verificationScope);
    assert(mutated.verificationStatus=="required", "A mutation during analysis escaped verification");
    assert(readText(buildPath(workspace,"cost.py"))==implementation && readText(buildPath(workspace,"test_cost.py"))==test);
    writeln("PASS expected failed diagnostics remain failed observations; source assertion facts differ from computed claims; implementation and mutation verification stay strict");
    return 0;
}

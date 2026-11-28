module working_set_overflow_contracts;
import auroraopencode.core;
import auroraopencode.requestpolicy;
import auroraopencode.contextpolicy;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.controlhistory;
import auroraopencode.tools : nativeOnlyToolDefinitions;
import auroraopencode.workingcontext : completedWorkingSet;
import std.array : replicate;
import std.conv : to;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : indexOf;

void add(ref ChatSession s, ChatMessage m)
{ m.parentId=s.activeLeafId; s.activeLeafId=m.id; s.messages~=m; }
int main()
{
    foreach (writing; [false,true])
    {
        ChatSession s;
        ChatMessage human; human.id="human"; human.role="user";
        human.content="Implement the requested source and verify the behavior. Keep the customer rate 0.0175."; add(s,human);
        s.contract.intent=s.contract.currentIntent="implementation";
        s.contract.startMessageId=human.id;
        s.contract.constraints=["Preserve the customer rate 0.0175 exactly"];
        typeof(s.contract.workItems[0]) required;
        required.required=true;required.step.id="required-export";required.step.text="Deliver the requested export";
        required.step.status="pending";s.contract.workItems=[required];
        s.verificationStatus="required";
        ChatMessage call; call.id="batch"; call.role="assistant";
        call.reasoning="Provider-required reasoning. ".replicate(writing ? 800 : 15);
        foreach(i;0..3)
        {
            JSONValue args; args["filePath"]="source"~to!string(i)~".py";
            if(writing) args["content"]="def solve():\n"~"    # native requested source\n".replicate(80)~"    # BODY_"~to!string(i)~"\n"~"    # native requested source\n".replicate(80);
            call.toolCalls~=OpenCodeToolCall("call"~to!string(i),writing ? "write" : "read",args.toString());
        }
        add(s,call);
        foreach(i;0..3)
        {
            ChatMessage tool; tool.id="result"~to!string(i); tool.role="tool";
            tool.toolName=call.toolCalls[i].name; tool.toolArgs=call.toolCalls[i].arguments;
            tool.toolCallId=call.toolCalls[i].id;
            tool.content=writing ? "Wrote source successfully" : "1: exact observed source line\n".replicate(95)~"100: BODY_"~to!string(i)~"\n"~"101: exact observed source line\n".replicate(95);
            add(s,tool);
        }
        ChatMessage state; state.id="state"; state.role="user"; state.internal=true;
        state.content=durableTaskCheckpointPrefix~" Relevant current state. ".replicate(95); add(s,state);
        RequestPolicy policy; policy.toolsEnabled=policy.compactionEnabled=true; policy.contextLimit=32000;
        policy.availableTools=nativeOnlyToolDefinitions();
        auto minimal=prepareAgentRequest(s,policy);
        const fixed=requestMessageBytes(minimal.messages[0..2])+requestToolDefinitionBytes(minimal.tools)+64;
        assert(fixed<53_000);
        policy.baseSystemPrompt="S".replicate(53_000-fixed);
        const saved=s.messages.dup;
        const prepared=prepareAgentRequest(s,policy);
        assert(requestMessageBytes(prepared.messages)+requestToolDefinitionBytes(prepared.tools)+64<=compactionBudgetBytes(32000));
        foreach(i;0..3)
        {
            bool found;
            foreach(m;prepared.messages)
            {
                if(m.content.indexOf("BODY_"~to!string(i))>=0) found=true;
                foreach(c;m.toolCalls) if(c.arguments.indexOf("BODY_"~to!string(i))>=0) found=true;
            }
            assert(found,"Compaction discarded a current completed observation or written body");
        }
        assert(prepared.tools==minimal.tools && s.messages==saved && s.verificationStatus=="required",
            "Working-set preservation changed capabilities, history or verification");
        auto partial=s;partial.messages=s.messages[0..$-2].dup;partial.activeLeafId=partial.messages[$-1].id;
        assert(!completedWorkingSet(partial,null).length,"An incomplete protocol exchange was rebased");
    }
    writeln("PASS overflowing completed batches preserve executed data within the selected context; original reasoning/history and verification remain intact");
    return 0;
}

module active_observation_contracts;
import auroraopencode.core;
import auroraopencode.requestpolicy;
import auroraopencode.contextcheckpoint : requestMessageBytes;
import auroraopencode.contextpolicy : compactionBudgetBytes;
import std.array : replicate;
import std.stdio : writeln;

void add(ref ChatSession s, ChatMessage m)
{ m.parentId = s.activeLeafId; s.activeLeafId = m.id; s.messages ~= m; }

int main()
{
    ChatSession s;
    ChatMessage u; u.id = "human"; u.role = "user";
    u.content = "Implement using instructions.txt and verify the requested behavior."; add(s, u);
    ChatMessage call; call.id = "old-call"; call.role = "assistant";
    call.toolCalls = [OpenCodeToolCall("old", "read", `{"filePath":"instructions.txt"}`)]; add(s, call);
    ChatMessage old; old.id = "old-output"; old.role = "tool"; old.toolName = "read"; old.toolCallId = "old";
    old.toolArgs = call.toolCalls[0].arguments; old.content = "Retained earlier source data. ".replicate(120); add(s, old);
    s.compactedThroughMessageId = old.id; s.compactionSummary = "Earlier source observations remain saved.";
    call.id = "current-call"; call.toolCalls = [OpenCodeToolCall("current", "read", `{"filePath":"implementation.py"}`)]; add(s, call);
    ChatMessage current; current.id = "current-output"; current.role = "tool";
    current.toolName = "read"; current.toolCallId = "current"; current.toolArgs = call.toolCalls[0].arguments;
    current.content = "FRESH_SOURCE_WINDOW\n" ~ "fresh code ".replicate(700); add(s, current);
    call.id = "bookkeeping"; call.toolCalls = [OpenCodeToolCall("plan", "update_plan", `{"plan":[]}`)]; add(s, call);
    ChatMessage plan; plan.id = "plan-result"; plan.role = "tool"; plan.toolName = "update_plan";
    plan.toolCallId = "plan"; plan.content = "Plan bookkeeping updated."; add(s, plan);
    RequestPolicy policy; policy.toolsEnabled = true; policy.compactionEnabled = true; policy.contextLimit = 32000;
    policy.baseSystemPrompt = "S".replicate(64000);
    const wire = prepareAgentRequest(s, policy);
    bool exact;
    foreach (m; wire.messages) if (m.toolCallId == "current") exact = m.content == current.content;
    assert(exact, "Retained source memory displaced a fresh source result that fits without it");
    assert(requestMessageBytes(wire.messages) <= compactionBudgetBytes(policy.contextLimit));
    assert(s.messages[$ - 3].content == current.content, "Context allocation changed saved evidence");
    writeln("PASS fresh tool evidence takes priority over optional retained memory; complete transcript and context bounds preserved");
    return 0;
}

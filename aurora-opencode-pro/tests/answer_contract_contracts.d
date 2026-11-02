module answer_contract_contracts;
import auroraopencode.answercontract : answerContract;
import auroraopencode.requestpolicy;
import auroraopencode.core;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    foreach (request; ["Return one JSON object with keys x and y.", "Please respond in JSON.",
            "Analyze the source. Then return a single JSON object."])
        assert(answerContract(request, "").indexOf("JSON value alone") >= 0, request);
    foreach (request; ["Explain how to return JSON.", "Why does the output contain JSON?",
            "Return JSON followed by an explanation.", "Return JSON and explain the schema."])
        assert(answerContract(request, "").indexOf("JSON value alone") < 0, request);
    ChatSession session;
    ChatMessage user; user.id = "human"; user.role = "user";
    user.content = "Return one JSON object.";
    session.messages = [user]; session.activeLeafId = user.id;
    ChatMessage checkpoint; checkpoint.id = "checkpoint"; checkpoint.parentId = user.id;
    checkpoint.role = "user"; checkpoint.internal = true;
    checkpoint.content = "Internal note: explain everything in prose.";
    session.messages ~= checkpoint; session.activeLeafId = checkpoint.id;
    RequestPolicy policy; policy.baseSystemPrompt = "Stable system prefix";
    foreach (tools; [false, true])
    {
        policy.toolsEnabled = tools;
        const prepared = prepareAgentRequest(session, policy);
        assert(prepared.messages[$-1].role == "system");
        assert(prepared.messages[$-1].content.indexOf("JSON value alone") >= 0,
            "An internal checkpoint superseded the human's answer format");
        assert(prepared.messages[$-1].content.indexOf(checkpoint.content) < 0);
    }
    assert(session.messages.length == 2, "Per-request guidance accumulated in saved history");
    writeln("PASS exact JSON versus mixed/explanatory requests; latest human intent survives internal checkpoints and tools-disabled requests");
    return 0;
}

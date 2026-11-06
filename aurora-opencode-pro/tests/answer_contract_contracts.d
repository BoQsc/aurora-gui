module answer_contract_contracts;
import auroraopencode.answercontract : answerContract, normalizedJsonAnswer;
import auroraopencode.requestpolicy;
import auroraopencode.core;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    foreach (request; ["Return one JSON object with keys x and y.", "Please respond in JSON.", "Answer only: return one JSON object.",
            "Analyze the source. Then return a single JSON object."])
        assert(answerContract(request, "").indexOf("JSON value alone") >= 0, request);
    foreach (request; ["Explain how to return JSON.", "Why does the output contain JSON?",
            "Return JSON followed by an explanation.", "Return JSON and explain the schema."])
        assert(answerContract(request, "").indexOf("JSON value alone") < 0, request);
    assert(answerContract("Why does the provider stall?", "").indexOf("Do not stop at an explanation") >= 0,
        "A why-question did not authorize resolution");
    assert(answerContract("Explain why the provider stalls.", "").indexOf("Do not stop at an explanation") < 0,
        "An explicit explanation request became a repair instruction");
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
        const contractIndex = tools ? 1 : 0;
        assert(prepared.messages[contractIndex].role == "system");
        assert(prepared.messages[contractIndex].content.indexOf("JSON value alone") >= 0,
            "An internal checkpoint superseded the human's answer format");
        assert(prepared.messages[contractIndex].content.indexOf(checkpoint.content) < 0);
    }
    assert(session.messages.length == 2, "Per-request guidance accumulated in saved history");
    const instruction="Return one JSON object.";
    const exact=`{"reference":"RECON-Q7-8162","alice":"0.06","bob":"0.09","refund_month":"2026-04"}`;
    assert(normalizedJsonAnswer(instruction,"The refund changes April.\n\n"~exact)==exact);
    assert(normalizedJsonAnswer("Answer only: return one JSON object.","The refund changes April.\n\n"~exact)==exact);
    assert(normalizedJsonAnswer(instruction,"```json\n"~exact~"\n```")==exact);
    assert(normalizedJsonAnswer(instruction,`A value: {"text":"braces } and escaped \"quote\"","array":[1,2]}`)==`{"text":"braces } and escaped \"quote\"","array":[1,2]}`);
    foreach (unchanged; [`{"a":1} or {"a":2}`, `{"a":`, `{"a":invalid}`, "Unavailable"])
        assert(normalizedJsonAnswer(instruction,unchanged)==unchanged);
    assert(normalizedJsonAnswer("Return JSON and explain it.","Explanation\n"~exact)=="Explanation\n"~exact);
    writeln("PASS exact JSON versus mixed/explanatory requests; latest human intent survives internal checkpoints and tools-disabled requests");
    return 0;
}

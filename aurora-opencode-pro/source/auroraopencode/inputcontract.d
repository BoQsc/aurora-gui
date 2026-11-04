module auroraopencode.inputcontract;
import auroraopencode.core : TaskStep, ChatSession;
import std.regex : matchFirst;
import std.string : toLower;

/// A plan may explicitly track asking for a fact. That bookkeeping action is
/// fulfilled by request_input itself; it must not prevent that call from waiting.
bool inputRequestStep(const ref TaskStep step)
{
    if (step.kind == "edit" || step.kind == "verify") return false;
    const text = step.text.toLower();
    return cast(bool)matchFirst(text, `^(request|ask)\b.*\b(request_input|task_blocker|ask_user)\b`) &&
        !matchFirst(text, `\b(implement|write|edit|test|verify|build|run|generate|deliver|produce|ship|fix|repair|check)\b`);
}

void settleInputRequestSteps(ref ChatSession session, string receipt)
{
    void settle(ref TaskStep step)
    {
        if (step.status == "completed" || !inputRequestStep(step)) return;
        step.status = "completed"; step.blocker = ""; step.evidence = [receipt];
    }
    foreach (ref step; session.taskSteps) settle(step);
    foreach (ref item; session.contract.workItems) if (item.required) settle(item.step);
    foreach (ref plan; session.nestedPlans) foreach (ref step; plan.steps) settle(step);
}

/// Both ordinary agents and orchestration use the same missing-information
/// contract. Routing must not provide a weaker permission-to-stop shortcut.
public enum requestInputSchema = `{"type":"object","properties":{"reason":{"type":"string"},"required_fact":{"type":"string","description":"An essential fact absent from the user's messages and available sources. Never ask to confirm an already supplied fact."},"question":{"type":"string"},"checked":{"type":"array","items":{"type":"string"},"description":"User messages, sources and alternatives already inspected. Recover earlier user replies with read_history before declaring a fact missing."},"independent_work_complete":{"type":"boolean","description":"True after completing all work that does not depend on the missing fact"},"blocked_steps":{"type":"array","items":{"type":"string"},"description":"IDs of every remaining outcome/action that genuinely depends on this missing fact. Finish all other work first; required when more than one outcome remains."}},"required":["reason","required_fact","question","checked","independent_work_complete"]}`;

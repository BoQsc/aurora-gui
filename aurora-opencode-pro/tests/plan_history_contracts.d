module plan_history_contracts;

import auroraopencode.core;
import auroraopencode.planhistory;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : writeln;

ChatSession grow(int count)
{
    ChatSession session;
    session.objective = "Revise the delivery";
    session.taskStatus = "active";
    session.taskSteps = [TaskStep("Inspect inputs", "in_progress", "inspect",
        "research", "Inputs understood", ["read-input"])];
    session.nestedPlans = [NestedPlan(1, [TaskStep("Read parser", "pending",
        "parser", "research")])];
    foreach (i; 0 .. count)
    {
        session.taskSteps[0].status = i % 2 ? "in_progress" : "pending";
        recordPlanHistory(session, "update_plan", "Revision " ~ to!string(i), i + 1);
    }
    return session;
}

int main()
{
    // A plan revision keeps the objective, status, steps, acceptance, evidence
    // and timestamp that produced it.
    ChatSession session;
    session.objective = "Ship the parser fix";
    session.taskStatus = "active";
    session.taskSteps = [
        TaskStep("Inspect inputs", "in_progress", "inspect", "research",
            "Inputs understood", ["read-input"]),
        TaskStep("Patch parser", "pending", "patch", "edit", "Fix is present")];
    recordPlanHistory(session, "update_plan",
        parseJSON(`{"explanation":"Initial plan"}`), 100);
    assert(session.planHistory.length == 1);
    assert(session.planHistory[0].at == 100);
    assert(session.planHistory[0].source == "update_plan");
    assert(session.planHistory[0].explanation == "Initial plan");
    assert(session.planHistory[0].objective == session.objective);
    assert(session.planHistory[0].status == "active");
    assert(session.planHistory[0].steps == session.taskSteps);
    assert(session.planHistory[0].nestedPlans.length == 0);

    // Repeating the same snapshot does not grow the history.
    recordPlanHistory(session, "update_plan", "", 101);
    assert(session.planHistory.length == 1,
        "An unchanged plan was recorded twice");

    // A status change is a real revision even when the step text is unchanged.
    session.taskSteps[0].status = "completed";
    recordPlanHistory(session, "update_plan", "", 102);
    assert(session.planHistory.length == 2);
    assert(session.planHistory[$ - 1].steps[0].status == "completed");
    assert(session.planHistory[$ - 1].explanation.length == 0);

    // Subplans are snapshotted as part of the same revision stream.
    session.nestedPlans = [NestedPlan(2, [TaskStep("Add fixture", "pending",
        "fixture", "edit", "Fixture exists")])];
    recordPlanHistory(session, "subplan",
        parseJSON(`{"reason":"Detail the edit"}`), 103);
    assert(session.planHistory.length == 3);
    assert(session.planHistory[$ - 1].source == "subplan");
    assert(session.planHistory[$ - 1].explanation == "Detail the edit");
    assert(session.planHistory[$ - 1].nestedPlans.length == 1);
    assert(session.planHistory[$ - 1].nestedPlans[0].steps[0].id == "fixture");

    // The history is part of the persisted session and survives a round trip
    // with every structural detail intact.
    JSONValue stored;
    writeTaskContract(stored, session);
    assert(stored["planHistory"].type == JSONType.array);
    ChatSession restored;
    readTaskContract(restored, stored);
    assert(restored.planHistory.length == session.planHistory.length);
    foreach (i; 0 .. session.planHistory.length)
    {
        assert(restored.planHistory[i].at == session.planHistory[i].at);
        assert(restored.planHistory[i].source == session.planHistory[i].source);
        assert(restored.planHistory[i].explanation ==
            session.planHistory[i].explanation);
        assert(restored.planHistory[i].steps == session.planHistory[i].steps);
        assert(restored.planHistory[i].nestedPlans ==
            session.planHistory[i].nestedPlans);
    }
    auto historyJson = planHistoryToJson(session.planHistory);
    assert(planHistoryFromJson(historyJson) == session.planHistory);

    // A background writer receives independent arrays.
    auto snapshot = snapshotChatSessions([session])[0];
    session.taskSteps[1].text = "Changed after snapshot";
    session.planHistory[$ - 1].steps[0].text = "Changed history after snapshot";
    assert(snapshot.planHistory[$ - 1].steps[0].text == "Inspect inputs",
        "Snapshot shared plan history with the live conversation");

    // Archived task state must not nest the whole history again.
    const archived = parseJSON(activeTaskStateJson(session));
    assert(!("planHistory" in archived.object),
        "Archived task snapshot duplicated the plan history");

    // The history is bounded, keeping the newest revisions.
    auto bounded = grow(cast(int) maxPlanHistoryEntries + 40);
    assert(bounded.planHistory.length == maxPlanHistoryEntries);
    assert(bounded.planHistory[$ - 1].at == maxPlanHistoryEntries + 40);
    assert(bounded.planHistory[$ - 1].explanation ==
        "Revision " ~ to!string(maxPlanHistoryEntries + 39));

    // Nothing is recorded for a conversation that has never had a plan.
    ChatSession empty;
    recordPlanHistory(empty, "update_plan", "", 200);
    assert(empty.planHistory.length == 0);

    writeln("PASS plan history records every revision, deduplicates, survives persistence, is copied and stays bounded");
    return 0;
}

module auroraopencode.goalmutation;

import auroraopencode.core : ChatSession, TaskContract, activeTaskStateJson, restoreActiveTaskState;
import auroraopencode.planhistory : recordPlanHistory;

/// Successful goal completion proves the requested outcome. Reflect that in
/// the advisory plan rather than requiring another model round for checkboxes.
public void reconcileCompletedGoalPlan(ref ChatSession session)
{
    import auroraopencode.planmode : experimentalStrictPlanEnabled;
    if (experimentalStrictPlanEnabled()) return;
    bool changed;
    foreach (ref step; session.taskSteps)
        if (step.status != "completed") { step.status = "completed"; changed = true; }
    foreach (ref plan; session.nestedPlans)
        foreach (ref step; plan.steps)
            if (step.status != "completed") { step.status = "completed"; changed = true; }
    if (changed) recordPlanHistory(session, "goal_complete", "Reconciled the advisory plan with the accepted goal completion.");
}

public void resetTaskForNewGoal(ref ChatSession session)
{
    if (session.objective.length || session.contract.id.length)
        session.taskArchive ~= activeTaskStateJson(session);
    recordPlanHistory(session, "goal_changed", "The goal changed; the previous plan was archived.");
    session.objective = session.goal;
    session.contract = TaskContract.init;
    session.contract.goal = session.goal;
    session.taskSteps = null; session.nestedPlans = null;
    session.verificationStatus = "not_required"; session.taskStatus = "active";
}

/// Explicit goal resume restores that goal, never an unrelated current task.
public void restoreGoalTask(ref ChatSession session)
{
    if (!session.goal.length || session.contract.goal == session.goal) return;
    foreach_reverse (snapshot; session.taskArchive)
    {
        ChatSession saved; restoreActiveTaskState(saved, snapshot);
        if (saved.contract.goal != session.goal && saved.contract.requestedOutcome != session.goal &&
            saved.objective != session.goal) continue;
        auto archive = session.taskArchive ~ activeTaskStateJson(session);
        restoreActiveTaskState(session, snapshot);
        session.contract.goal = session.goal;
        session.taskArchive = archive;
        recordPlanHistory(session, "goal_resumed", "Restored the explicitly resumed goal's saved task.");
        return;
    }
    resetTaskForNewGoal(session);
}

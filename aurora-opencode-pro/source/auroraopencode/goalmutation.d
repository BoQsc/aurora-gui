module auroraopencode.goalmutation;

import auroraopencode.core : ChatSession, TaskContract, activeTaskStateJson, restoreActiveTaskState;
import auroraopencode.planhistory : recordPlanHistory;

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

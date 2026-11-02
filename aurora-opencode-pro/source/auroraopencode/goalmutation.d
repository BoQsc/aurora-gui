module auroraopencode.goalmutation;

import auroraopencode.core : ChatSession, TaskContract, activeTaskStateJson;
import auroraopencode.planhistory : recordPlanHistory;

public void resetTaskForNewGoal(ref ChatSession session)
{
    if (session.objective.length || session.contract.id.length)
        session.taskArchive ~= activeTaskStateJson(session);
    recordPlanHistory(session, "goal_changed", "The goal changed; the previous plan was archived.");
    session.objective = session.goal;
    session.contract = TaskContract.init;
    session.taskSteps = null; session.nestedPlans = null;
    session.verificationStatus = "not_required"; session.taskStatus = "active";
}

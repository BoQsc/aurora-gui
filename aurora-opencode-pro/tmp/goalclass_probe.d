import auroraopencode.goalmode;
import auroraopencode.requestintent;
import auroraopencode.goalmode : goalIsAnswerOnly, goalIsAnswerTurn;
import std.stdio;

void main()
{
    string[] goals = [
        "Let's ensure 100% stable 60 fps, make anything less than 60fps as total critical failure.",
        "Let's ensure 100% stable 60 fps",
        "Let's make aurora host v2 properly, resolve the missing thin presenter",
        "Investigate and fix the terrain cadence bug",
        "Bring the terrain to a measured 60 fps",
        "Ensure the build reports zero frames over 16.67 ms",
    ];
    foreach (goal; goals)
    {
        const intent = requestIntent(goal);
        writeln("goal: ", goal);
        writeln("  answerOnly=", answerOnlyRequest(goal),
            " intent=", intent, " answerGoal=", goalIsAnswerOnly(goal),
            " answerTurn=", goalIsAnswerTurn(goal));
    }
}

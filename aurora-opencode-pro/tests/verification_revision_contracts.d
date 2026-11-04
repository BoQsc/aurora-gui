module verification_revision_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.toolscheduler : toolWorkspaceRevision, invalidateToolWorkspace;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    const state = absolutePath("verification-revision-state");
    const workspace = buildPath(state, "workspace");
    mkdirRecurse(workspace);
    setOpencodeStateDirectoryForTesting(state);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:9"; settings.apiKey = "fixture";
    settings.workspace = workspace; settings.quickTitle = false;
    settings.autoGoalFromFirstMessage = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    root.newChatForTesting();
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Fix and test the code", ""]);
    root.setGoalForTesting("Fix and test the code", "active");
    root.injectToolResultForTesting("write", "Wrote app.d", false, `{"filePath":"app.d"}`, 1);
    assert(root.verificationStatusForTesting() == "required");

    const checkedRevision = toolWorkspaceRevision(workspace);
    invalidateToolWorkspace(workspace); // another chat edits after the check settles
    root.injectToolResultForTesting("verify", `{}`, false, `{}`, 0, 0, "", null,
        "verify:tests,compile", checkedRevision);
    assert(root.verificationStatusForTesting() == "required",
        "A delayed recipe receipt inherited a newer source revision");
    root.injectToolResultForTesting("run", "Tests passed", false, `{}`, 0, 0, "", null,
        "unittest", checkedRevision);
    assert(root.verificationStatusForTesting() == "required",
        "A delayed direct check inherited a newer source revision");
    root.injectToolResultForTesting("verify", `{}`, false, `{}`, 0, 0, "", null,
        "verify:tests,compile");
    assert(root.verificationStatusForTesting() == "passed", "Current evidence was rejected");

    // A later checker attempt that cannot be scoped to the current workspace
    // must not erase the current accepted verification.
    root.injectToolResultForTesting("verify", "stale checker", false, `{}`, 0, 0, "", null,
        "verify:tests", checkedRevision);
    assert(root.verificationStatusForTesting() == "passed",
        "A stale checker attempt cleared a current accepted verification");

    // No intervening service tick: completion itself must revalidate the receipt.
    invalidateToolWorkspace(workspace);
    root.injectToolResultForTesting("goal_complete", "Done", false,
        `{"summary":"Finished","evidence":["call_inject"]}`);
    assert(root.verificationStatusForTesting() == "required");
    assert(root.goalStatusForTesting() == "active", "Stale evidence completed the goal");
    root.injectToolResultForTesting("verify", `{}`, false, `{}`, 0, 0, "", null,
        "verify:tests,compile");
    root.injectToolResultForTesting("goal_complete", "Done", false,
        `{"summary":"Finished","evidence":["call_inject"]}`);
    assert(root.goalStatusForTesting() == "completed", "Fresh evidence could not complete the goal");
    writeln("PASS stale recipe/direct receipt rejection, completion-time invalidation and fresh-check recovery");
    return 0;
}

module computer_intent_test;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings,
    setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.computeruse : requestComputerUseAbort, computerUseAbortActive,
    beginComputerUseUserRequest, clearComputerUseAbort, experimentalComputerUseExecute,
    setComputerUseSetting;
import std.file : tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.string : indexOf;
import std.stdio : writeln;

int main()
{
    auto directory = buildPath(tempDir(), "aurora-intent-test-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    setOpencodeStateDirectoryForTesting(directory);
    Settings settings;
    settings.baseUrl = "http://127.0.0.1:1/v1";
    settings.apiKey = "";
    settings.quickTitle = false;
    settings.toolsEnabled = true;
    settings.experimentalComputerUse = true;
    saveSettings(settings);
    WindowOptions options;
    options.title = "Computer intent regression";
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.pauseToolContinuationForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Play the tutorial", "Starting"]);
    root.setTaskStateForTesting("Play the tutorial", "active", "not_required");
    root.injectToolResultForTesting("update_plan", "Plan updated", false,
        `{"plan":[{"step":"Select squad","status":"in_progress"},{"step":"Finish tutorial","status":"pending"}]}`);
    root.addConversationForTesting(["user", "assistant"],
        ["why you couldn't complete", "The tutorial dialogue still needed Continue."]);
    assert(root.ensureDurableTaskCheckpointForTesting());
    assert(root.lastUserMessageForTesting().indexOf("latest request asks for an explanation") >= 0);
    root.addConversationForTesting(["assistant"], ["Here is the explanation."]);
    const before = root.totalMessageCountForTesting();
    clearComputerUseAbort(); // Prove suppression comes from intent, not the stop latch.
    root.completeTurnInSessionForTesting(root.currentSessionForTesting());
    assert(root.totalMessageCountForTesting() == before,
        "An explanation triggered plan reconciliation or automatic continuation");
    assert(root.turnStatusForTesting() == "completed");
    assert(root.taskStatusForTesting() == "active");
    assert(root.taskStepStatusForTesting(0) == "in_progress");
    assert(root.taskStepStatusForTesting(1) == "pending");
    assert(!root.clientBusyForTesting(), "An explanation restarted the model request");

    requestComputerUseAbort();
    beginComputerUseUserRequest("I did killswitch because you didn't progress, I want to know why you didn't progress");
    assert(computerUseAbortActive(), "A diagnostic message lifted the kill switch");
    clearComputerUseAbort();
    auto rejected = experimentalComputerUseExecute(`{"action":"click","x":-100,"y":-100,"screenshot":false}`, "");
    assert(rejected.failed && rejected.output.indexOf("latest user request asks for an explanation") >= 0,
        "Diagnostic intent allowed desktop input");
    rejected = experimentalComputerUseExecute(`{"steps":[{"action":"key","name":"space"}]}`, "");
    assert(rejected.failed && rejected.output.indexOf("latest user request asks for an explanation") >= 0,
        "A batch bypassed diagnostic intent");
    requestComputerUseAbort();
    beginComputerUseUserRequest("continue");
    assert(!computerUseAbortActive(), "An explicit resume did not lift the stop");
    root.addConversationForTesting(["user"], ["Continue the tutorial"]);
    assert(root.ensureDurableTaskCheckpointForTesting());
    assert(root.lastUserMessageForTesting().indexOf("latest request asks for an explanation") < 0,
        "An explicit resume retained diagnostic intent");
    setComputerUseSetting(false);
    writeln("PASS: explanation ends the turn, preserves pending work, blocks input/batches, preserves stop, permits explicit resume");
    return 0;
}

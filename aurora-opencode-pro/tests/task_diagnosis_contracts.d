module task_diagnosis_contracts;

import aurora;
import auroraopencode.core;
import auroraopencode.appui;
import auroraopencode.tools : runFilesystemHelperMode;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse, write, readText, exists, tempDir, thisExePath;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.json : JSONValue;
import std.stdio : writeln;

int main(string[] arguments)
{
    if (arguments.length == 3 && arguments[1] == "--check")
        return readText(arguments[2]) == "expected\n" ? 0 : 1;
    const helper = runFilesystemHelperMode(arguments); if (helper >= 0) return helper;
    const directory = absolutePath(buildPath(tempDir(), "aurora-diagnosis-" ~ to!string(MonoTime.currTime.ticks)));
    const source = buildPath(directory,"source");
    const workspace = buildPath(directory,"sandbox");
    mkdirRecurse(buildPath(source,".git")); mkdirRecurse(workspace);
    const input = buildPath(source,"input.txt"); write(input,"expected\n");
    JSONValue command; command["program"] = thisExePath();
    command["args"] = JSONValue(["--check", input]);
    JSONValue step; step["kind"] = "tests"; step["command"] = command;
    JSONValue recipe; recipe["inputs"] = JSONValue(["input.txt"]); recipe["steps"] = JSONValue([step]);
    const recipePath = buildPath(source,"verify.json"); write(recipePath,recipe.toPrettyString());
    setOpencodeStateDirectoryForTesting(buildPath(directory,"state"));
    Settings settings; settings.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE","");
    assert(settings.baseUrl.length);
    settings.apiKey = "fixture"; settings.model = "diagnosis-main";
    settings.diagnosticModel = "diagnosis-review"; settings.workspace = workspace;
    settings.toolsEnabled = true; settings.legacyTools = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options,opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    void pump()
    {
        window.onNativeTick(0.03); root.projectTranscriptForTesting();
        assert(driver.paint()); Thread.sleep(3.msecs);
    }
    const loaded = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < loaded) pump();
    root.newChatForTesting();
    root.setTaskStateForTesting("Fix and verify the helper", "active", "required");
    root.applyPlanForTesting(`{"plan":[{"step":"Verify the helper","status":"in_progress"}]}`);
    root.setInputForTesting("DIAGNOSE: Fix and verify the helper. Source: " ~ source ~ "\nRECIPE: " ~ recipePath);
    root.sendForTesting();
    const done = MonoTime.currTime + 25.seconds;
    while (root.turnBusyForTesting() && MonoTime.currTime < done) pump();
    assert(!root.turnBusyForTesting(), root.lastAssistantErrorForTesting());
    assert(root.verificationStatusForTesting() == "passed",root.lastAssistantErrorForTesting());
    assert(root.lastAssistantContentForTesting() == "Verified the helper after diagnostic review.");
    assert(!exists(buildPath(source,"forbidden.txt")), "Diagnostic model mutated source despite its read-only scope");
    writeln("PASS stalled task routes to configured reviewer, rejects its write, returns to main model and accepts real verification");
    window.close(); return 0;
}

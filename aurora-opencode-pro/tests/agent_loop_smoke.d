module agent_loop_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting,
    OpenCodeToolCall;
import auroraopencode.outputguard;
import auroraopencode.logging : setLogDirectory, flushLogs;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.datetime : Clock;
import std.file : mkdirRecurse, tempDir, write, readText;
import std.process : environment;
import std.json : JSONValue;
import std.path : buildPath;
import std.string : indexOf, startsWith;
import std.array : replicate;
import std.stdio : writeln;

private void untilIdle(OpenCodeRoot root)
{
    const deadline = MonoTime.currTime + 10.seconds;
    while (root.turnBusyForTesting() && MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    assert(!root.turnBusyForTesting(), "Output recovery did not settle");
}

int main(string[] args)
{
    assert(args.length == 2);
    const state = buildPath(tempDir(), "aurora-agent-loop-" ~ to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    setLogDirectory(buildPath(state, "logs"));
    environment["AURORA_PROVIDER_TRACE"] = "1";
    scope(exit) environment.remove("AURORA_PROVIDER_TRACE");
    JSONValue settings;
    settings["baseUrl"] = args[1];
    settings["apiKey"] = "fixture";
    settings["model"] = "fixture";
    settings["workspace"] = state;
    settings["quickTitle"] = false;
    settings["toolsEnabled"] = true;
    write(buildPath(state, "settings.json"), settings.toString());
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    foreach (_; 0 .. 30) { root.tickTree(0.02); Thread.sleep(10.msecs); }

    root.newChatForTesting();
    root.setInputForTesting("fixture: recover-xml");
    root.sendForTesting();
    untilIdle(root);
    assert(root.lastAssistantContentForTesting() == "Recovered.");
    assert(root.toolMessageCountForTesting() == 1,
        "Printed tool markup executed or the structured recovery call was lost");
    foreach (message; root.requestMessagesForTesting())
        assert(message.content.indexOf("<invoke") < 0,
            "Recovery fed failed XML back into the provider");
    writeln("PASS real HTTP XML failure -> one recovery -> structured call executes exactly once");

    root.newChatForTesting();
    root.setInputForTesting("fixture: stuck-xml");
    root.sendForTesting();
    untilIdle(root);
    assert(root.taskStatusForTesting() == "blocked" &&
        root.lastAssistantErrorForTesting().startsWith(outputFailurePrefix));
    assert(root.toolMessageCountForTesting() == 0);
    foreach (_; 0 .. 30) { root.tickTree(0.02); Thread.sleep(10.msecs); }
    assert(!root.turnBusyForTesting(), "A stalled response restarted after its recovery budget");
    writeln("PASS repeated malformed output settles with a visible failure and zero tools");

    root.newChatForTesting();
    root.setInputForTesting("fixture: recover-prose");
    root.sendForTesting();
    untilIdle(root);
    assert(root.lastAssistantContentForTesting() == "Recovered prose.");
    writeln("PASS prose loop recovers without a fabricated tool call");
    assert(flushLogs(3000));
    const trace = readText(buildPath(state, "logs", "errors.log"));
    assert(trace.indexOf("provider-wire request=") >= 0 &&
        trace.indexOf("kind=request") >= 0 && trace.indexOf("kind=sse") >= 0 &&
        trace.indexOf("text_tool_calls") >= 0 && trace.indexOf("tool_calls") >= 0,
        "The real transport did not record request, wire channels and failure evidence");
    assert(trace.indexOf("fixture: recover") < 0,
        "The configured fixture API key leaked through request content");
    writeln("PASS opt-in real transport diagnostics preserve channels and redact the API key");

    root.pauseToolContinuationForTesting();
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["Build and debug the program", ""]);
    enum build = `{"program":"dmd","args":["source/app.d"]}`;
    foreach (_; 0 .. 12) root.injectToolResultForTesting("run", "compiled", false, build);
    assert(root.exactToolRunCountForTesting("run", build) == 12);
    root.beginStreamForTesting();
    root.injectToolCallsForTesting([OpenCodeToolCall("repeat-1", "run", build)]);
    assert(root.taskStatusForTesting() == "active",
        "An exhausted call did not receive its bounded recovery");
    root.beginStreamForTesting();
    root.injectToolCallsForTesting([OpenCodeToolCall("repeat-2", "run", build)]);
    assert(root.taskStatusForTesting() == "blocked",
        "Skipped repeated calls opened an unlimited provider loop");
    root.injectToolResultForTesting("edit", "Edited implementation", false,
        `{"filePath":"source/app.d"}`, 1, 1, "@@ -1 +1 @@\n-old\n+new\n");
    assert(root.exactToolRunCountForTesting("run", build) == 0,
        "A changed source file did not release the identical rebuild command");
    root.injectToolResultForTesting("run", "compiled", false, build);
    assert(root.exactToolRunCountForTesting("run", build) == 1);
    root.injectToolResultForTesting("edit", "Edited comment", false,
        `{"filePath":"source/app.d"}`, 1, 1, "@@ -1 +1 @@\n-// old\n+// new\n");
    assert(root.exactToolRunCountForTesting("run", build) == 0,
        "The build guard reused the stricter implementation-progress gate");
    root.injectToolResultForTesting("run", "compiled", false, build);
    root.addConversationForTesting(["user"], ["Rebuild again"]);
    assert(root.exactToolRunCountForTesting("run", build) == 0);
    writeln("PASS edits and new user instructions release identical build commands");
    root.newChatForTesting();
    const previous = "An earlier answer with unique evidence. ".replicate(20);
    root.addConversationForTesting(["user", "assistant", "assistant"],
        ["Debug this", previous, previous ~ " A few new words."]);
    assert(root.replayedAnswerForTesting(), "A whole-answer replay escaped detection");
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant", "user", "assistant"],
        ["Debug this", previous, "Please repeat the answer", previous]);
    assert(!root.replayedAnswerForTesting(), "A new human instruction was classified as replay");
    writeln("PASS whole-answer replay detection respects new user instructions");
    return 0;
}

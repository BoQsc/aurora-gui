// Headless contract test for the experimental orchestrator's subagent chats.
//
// It drives the real OpenCodeRoot: the plan lists named, single-word subagents;
// one `assign` gives each assigned subagent its own nested chat, linked to the
// parent conversation and carrying its subagent id; two of those subagent chats
// run their turns AT THE SAME INSTANT (parallel orchestration, not one
// sequential hop after another); and a click opens a subagent's own chat.
//
// The provider endpoint is deliberately refused: the contract under test is the
// app's own dispatch and chat wiring, and the app's own headless tests likewise
// never make a live provider round-trip inside the harness.
//
// Build (from aurora-opencode-pro):
//   dmd -version=AuroraHeadless -i -Isource -I..\aurora-opencode-core\source
//       -I..\vendor\aurora-d-0.4.5\source tests\orchestrator_headless_smoke.d
//       user32.lib gdi32.lib shell32.lib wininet.lib winmm.lib
//       -of=build\orchestrator-headless-smoke.exe
module orchestrator_headless_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting,
    OpenCodeToolCall;
import auroraopencode.logging : setLogDirectory;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime : Clock;
import std.file : mkdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : stderr;
import std.string : indexOf;

/// Unbuffered progress, so a failure still leaves the trail behind.
private void say(string text)
{
    stderr.writeln(text);
    stderr.flush();
}

/// The assign arguments for a batch of subagents.
private string assignArgsJson(string[] agentIds, string task)
{
    string inner;
    foreach (index, id; agentIds)
    {
        if (index > 0) inner ~= ",";
        inner ~= `{"agent_id":"` ~ id ~ `","task":"` ~ task ~ `"}`;
    }
    return `{"assignments":[` ~ inner ~ `]}`;
}

void main()
{
    const state = buildPath(tempDir(),
        "aurora-orchestrator-headless-" ~ to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    setLogDirectory(buildPath(state, "logs"));
    JSONValue settings;
    // A refused endpoint: no provider round-trip is needed to prove the wiring.
    settings["baseUrl"] = "http://127.0.0.1:1";
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
    scope (exit) root.shutdownClient();
    foreach (_; 0 .. 30) { root.tickTree(0.02); Thread.sleep(10.msecs); }

    root.newChatForTesting();
    root.addConversationForTesting(["user"],
        ["Build and review the feature, then report based on facts."]);
    const hub = root.currentSessionForTesting();
    const hubId = root.sessionIdForTesting(hub);

    // The plan lists the named subagents before any round, all idle.
    root.enableExperimentalOrchestratorForTesting();
    auto planRows = root.subagentPlanRowsForTesting();
    assert(planRows.length == 3, "the plan must list the three named subagents");
    foreach (row; planRows)
    {
        const colon = row.indexOf(":");
        assert(colon > 0, `a plan subagent row must be "name:status": ` ~ row);
        const name = row[0 .. colon];
        assert(name.indexOf(" ") < 0,
            "a subagent name must be a single word: " ~ name);
        assert(row[colon + 1 .. $] == "idle",
            "an unassigned subagent starts idle: " ~ row);
    }
    say("PASS the plan lists Builder, Reviewer and Researcher as idle");

    const sessionsBefore = root.sessionCountForTesting();

    // The orchestrator dispatches a round of two subagents at once.
    root.beginStreamForTesting();
    root.injectToolCallsForTesting(
        [OpenCodeToolCall("assign-1", "assign",
            assignArgsJson(["builder", "reviewer"], "Do your part"))]);

    // Watch for the moment both subagent chats have a turn in flight together.
    size_t maxWorking;
    const deadline = MonoTime.currTime + 30.seconds;
    while (MonoTime.currTime < deadline)
    {
        root.tickTree(0.02);
        size_t working;
        foreach (row; root.subagentPlanRowsForTesting())
            if (row.canFind(":working")) ++working;
        if (working > maxWorking) maxWorking = working;
        if (maxWorking >= 2 && root.subagentChatCountForTesting(hub) >= 2) break;
        Thread.sleep(10.msecs);
    }

    assert(maxWorking >= 2,
        "the assigned subagents must run at the same time (parallel rounds)");
    say("PASS round one ran " ~ to!string(maxWorking) ~
        " subagents with a turn in flight at the same instant");

    assert(root.subagentChatCountForTesting(hub) == 2,
        "one assign round must create exactly one nested chat per assigned subagent");
    assert(root.sessionCountForTesting() == sessionsBefore + 2,
        "a round must create exactly one nested chat per assigned subagent");

    bool[string] found;
    foreach (index; 0 .. cast(int) root.sessionCountForTesting())
    {
        if (index == hub) continue;
        assert(root.sessionParentForTesting(index) == hubId,
            "a nested chat must name its parent conversation");
        const agentId = root.sessionSubagentForTesting(index);
        assert(agentId.length > 0, "a nested chat must carry its subagent id");
        found[agentId] = true;
    }
    assert("builder" in found && "reviewer" in found,
        "the assigned subagents own the nested chats");
    assert("researcher" !in found,
        "an unassigned subagent must not get a nested chat");
    say("PASS every nested chat links to its parent and its subagent id");

    // The plan reports the assigned subagents from their own chats; the
    // unassigned one stays idle.
    planRows = root.subagentPlanRowsForTesting();
    assert(planRows.length == 3, "the plan still lists three named subagents");
    foreach (row; planRows)
    {
        const colon = row.indexOf(":");
        const name = row[0 .. colon];
        const status = row[colon + 1 .. $];
        if (name == "Builder" || name == "Reviewer")
            assert(status != "idle",
                "a dispatched subagent must read its own nested chat: " ~ row);
        else
            assert(status == "idle", "an unassigned subagent stays idle: " ~ row);
    }
    say("PASS the plan reflects the subagents' own nested chats");

    // The nested chats open on click and stay out of the top-level list.
    int childIndex;
    foreach (index; 0 .. cast(int) root.sessionCountForTesting())
        if (index != hub && root.sessionSubagentForTesting(index) == "builder")
            childIndex = index;
    root.selectSessionForTesting(childIndex);
    assert(root.currentSessionForTesting() == childIndex,
        "clicking a subagent must open its own nested chat");
    say("PASS clicking a subagent opens its own nested chat");

    // A subagent's own chat runs as one participant: it must not list itself
    // (or its peers) as subagents under its plan.
    assert(root.subagentPlanRowsForTesting().length == 0,
        "a subagent's own chat must not list subagents under its plan");
    say("PASS a subagent's own chat lists no subagents under its plan");

    say("orchestrator headless smoke: all checks passed");
}

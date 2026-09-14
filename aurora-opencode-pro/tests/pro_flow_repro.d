module pro_flow_repro;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall, opencodeTheme,
    setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs;
import std.datetime : Clock, seconds;
import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;

private void dump(OpenCodeRoot root, string phase)
{
    writeln("\n--- ", phase, " ---");
    foreach (line; root.columnDebugForTesting())
        writeln("  ", line);
}

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-opencode-pro-flow-repro");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    const realMode = args.length > 1 && args[1] == "real";
    if (realMode)
    {
        import std.json : parseJSON;
        import std.file : readText;
        const src = buildPath(environment.get("APPDATA"),
            "Aurora OpenCode", "sessions.json");
        auto doc = parseJSON(readText(src));
        size_t best;
        foreach (i, s; doc["sessions"].array)
            if (s["title"].str == "how are you") best = i;
        doc["current"] = cast(long) best;
        writeln("selected session index ", best, " (",
            doc["sessions"].array[best]["title"].str, ")");
        write(buildPath(stateDir, "sessions.json"), doc.toString());
    }
    else
        write(buildPath(stateDir, "sessions.json"), `{"sessions":[],"current":-1}`);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "repro";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.tickTree(0.02);

    if (realMode)
    {
        root.reloadSessionsForTesting();
        root.tickTree(0.02);
        writeln("sessions=", root.sessionCountForTesting(),
            " visuals=", root.messageColumnVisualCountForTesting(),
            " thinkingHeaders=", root.thinkingHeaderCountForTesting(),
            " toolMessages=", root.toolMessageCountForTesting());
        dump(root, "real session column");
        return 0;
    }

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["build a game"]);

    root.beginStreamForTesting();
    dump(root, "after beginStream (activity)");

    root.streamReasoningForTesting("The user wants a single HTML game.");
    dump(root, "after reasoning stream");

    root.streamContentForTesting("I'll build a complete, self-contained platformer.");
    dump(root, "after content stream");

    OpenCodeToolCall writeCall;
    writeCall.name = "write";
    writeCall.arguments =
        `{"filePath":"game.html","content":"<html>\n<body>\n</body>\n</html>"}`;
    root.injectToolProgressForTesting([writeCall]);
    dump(root, "after tool-call progress (args streaming)");

    root.pauseToolContinuationForTesting();
    root.injectToolCallsForTesting([writeCall]);
    dump(root, "after handleToolCalls (running)");

    const deadline = Clock.currTime + 5.seconds;
    while (root.toolMessageCountForTesting() < 1 && Clock.currTime < deadline)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    dump(root, "after round 1 tool result");

    // Round 2: the model reasons again, then edits the file.
    root.beginStreamForTesting();
    root.streamReasoningForTesting("Now let me add physics.");
    dump(root, "round 2 reasoning live");

    root.streamContentForTesting("Adding the physics loop now.");
    OpenCodeToolCall editCall;
    editCall.name = "edit";
    editCall.arguments =
        `{"filePath":"game.html","oldString":"body","newString":"body + js"}`;
    root.injectToolProgressForTesting([editCall]);
    root.injectToolCallsForTesting([editCall]);
    const deadline2 = Clock.currTime + 5.seconds;
    while (root.toolMessageCountForTesting() < 2 && Clock.currTime < deadline2)
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
    }
    dump(root, "after round 2 tool result");

    // Final answer turn.
    root.beginStreamForTesting();
    root.streamReasoningForTesting("Everything is done.");
    root.streamContentForTesting("Done — the game is ready.");
    dump(root, "final answer streaming");

    root.finishStreamForTesting();
    dump(root, "after finish (phase row removed)");

    return 0;
}

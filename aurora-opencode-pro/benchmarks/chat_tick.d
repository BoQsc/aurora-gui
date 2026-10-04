module chat_tick;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : sort;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;

int main(string[] args)
{
    assert(args.length == 2, "Pass an isolated state directory");
    mkdirRecurse(args[1]);
    setOpencodeStateDirectoryForTesting(args[1]);
    write(buildPath(args[1], "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false,"quickTitle":false}`);
    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    foreach (_; 0 .. 30) { root.tickTree(0.02); Thread.sleep(10.msecs); }
    foreach (_; 0 .. 100)
    {
        root.newChatForTesting();
        root.addConversationForTesting(["user", "assistant"], ["Prompt", "Answer"]);
    }
    string[] roles, bodies;
    foreach (i; 0 .. 1500)
    {
        roles ~= i % 2 ? "assistant" : "user";
        bodies ~= "Long conversation entry " ~ to!string(i);
    }
    root.addConversationForTesting(roles, bodies);
    // Keep the timer active without network traffic so background persistence
    // cannot interfere. No paint or provider generation is in this benchmark.
    root.startTurnClockForTesting();
    foreach (_; 0 .. 20) root.tickTree(0.016);
    foreach (trial; 0 .. 5)
    {
        long[] samples;
        foreach (_; 0 .. 300)
        {
            const started = MonoTime.currTime;
            root.tickTree(0.016);
            samples ~= (MonoTime.currTime - started).total!"usecs";
        }
        samples.sort();
        writeln("tick_median_us=", samples[150], " tick_p95_us=", samples[285]);
    }
    root.shutdownClient();
    return 0;
}
